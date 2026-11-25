import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An iPhone or iPad usbmuxd lists.
class UsbmuxDevice {
  const UsbmuxDevice({
    required this.deviceId,
    required this.serial,
    required this.connectionType,
  });

  /// usbmuxd's handle for this attachment (changes on every replug).
  final int deviceId;

  /// The UDID.
  final String serial;

  /// `USB` or `Network`.
  final String connectionType;

  bool get isUsb => connectionType == 'USB';
}

/// What a `Listen` connection to usbmuxd reports (see [UsbmuxClient.listen]).
enum UsbmuxEventKind {
  /// usbmuxd took the Listen: what follows is its device events.
  listening,

  /// A device came (or, right after [listening], is already there).
  attached,

  /// A device went. Also sent for every device still attached when the
  /// Listen connection drops (usbmuxd restarting): the next [listening]
  /// reports each one attached again.
  detached,

  /// The Listen connection dropped (after its [detached] events); it is
  /// opened again after the client's retry delay.
  lost,
}

/// One message of a `Listen` connection. [device] is set for [attached]
/// (the device as [UsbmuxClient.listDevices] would list it) and for
/// [detached] when the attachment was reported before (usbmuxd's Detached
/// names only the `DeviceID`).
class UsbmuxEvent {
  const UsbmuxEvent(this.kind, {this.deviceId, this.device});
  final UsbmuxEventKind kind;
  final int? deviceId;
  final UsbmuxDevice? device;

  @override
  String toString() =>
      'UsbmuxEvent(${kind.name}${deviceId == null ? '' : ' $deviceId'}'
      '${device == null ? '' : ' ${device!.serial} ${device!.connectionType}'})';
}

/// The 16-byte-header plist messages of one usbmuxd connection, from its
/// bytes as they arrive: several messages in one chunk, or one split across
/// chunks. [add] returns each complete message's plist body; a header no
/// usbmuxd writes throws a [FormatException] (nothing after it can be framed).
class UsbmuxFramer {
  final _buf = BytesBuilder();

  /// The longest message taken; usbmuxd's are a few KB.
  static const maxMessage = 1 << 20;

  List<Uint8List> add(List<int> chunk) {
    _buf.add(chunk);
    final out = <Uint8List>[];
    var bytes = _buf.takeBytes();
    var at = 0;
    while (bytes.length - at >= 16) {
      final length = ByteData.sublistView(bytes, at, at + 4).getUint32(0, Endian.little);
      if (length < 16 || length > maxMessage) {
        throw FormatException('usbmuxd sent a malformed header (length $length)');
      }
      if (bytes.length - at < length) break;
      out.add(Uint8List.fromList(Uint8List.sublistView(bytes, at + 16, at + length)));
      at += length;
    }
    if (at < bytes.length) _buf.add(Uint8List.sublistView(bytes, at));
    return out;
  }
}

/// A usbmuxd plist message: the 16-byte little-endian header (length,
/// version 1, type 8, [tag]) and the XML body.
Uint8List usbmuxMessage(Map<String, Object> message, int tag) {
  final body = utf8.encode(Plist.encode(message));
  final header = ByteData(16)
    ..setUint32(0, 16 + body.length, Endian.little)
    ..setUint32(4, 1, Endian.little)
    ..setUint32(8, 8, Endian.little)
    ..setUint32(12, tag, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body]);
}

/// usbmuxd's answer to a Connect that did not open a stream.
class UsbmuxRefused implements Exception {
  const UsbmuxRefused(this.code);

  /// 2 bad device, 3 connection refused (nothing listens on the port), 5 bad
  /// version, 6 malformed.
  final int code;

  @override
  String toString() => 'usbmuxd refused the connection (result $code)';
}

/// A client of usbmuxd (`/var/run/usbmuxd`), the daemon through which a Mac
/// (or Windows, with Apple's device drivers) reaches iOS devices: their list,
/// and a TCP stream to a port on one of them over its USB cable, as `iproxy`
/// does. Messages are XML plists after a 16-byte little-endian header
/// (length, version 1, type 8, tag). After a Connect that succeeds the
/// socket is the stream itself.
class UsbmuxClient {
  UsbmuxClient({
    this.path = '/var/run/usbmuxd',
    this.timeout = const Duration(seconds: 5),
    this.listenRetry = const Duration(seconds: 1),
  });

  final String path;
  final Duration timeout;

  /// How long [listen] waits before it opens its connection again after it
  /// dropped (usbmuxd restarting) or could not be opened.
  final Duration listenRetry;

  static const _progName = 'extendedscreen';

  /// The devices usbmuxd knows, by USB or network.
  Future<List<UsbmuxDevice>> listDevices() async {
    final link = await _open();
    try {
      final reply = await link.request({
        'MessageType': 'ListDevices',
        'ClientVersionString': _progName,
        'ProgName': _progName,
      }, 1);
      final list = reply['DeviceList'];
      if (list is! List) return const [];
      return [
        for (final entry in list)
          if (entry is Map &&
              entry['DeviceID'] is int &&
              entry['Properties'] is Map)
            UsbmuxDevice(
              deviceId: entry['DeviceID'] as int,
              serial: '${(entry['Properties'] as Map)['SerialNumber'] ?? ''}',
              connectionType:
                  '${(entry['Properties'] as Map)['ConnectionType'] ?? ''}',
            ),
      ];
    } finally {
      link.close();
    }
  }

  /// A stream to [port] on device [deviceId]. Throws [UsbmuxRefused] when
  /// usbmuxd says no (nothing listening there, say).
  Future<UsbmuxStream> connect(int deviceId, int port) async {
    final link = await _open();
    try {
      final reply = await link.request({
        'MessageType': 'Connect',
        'ClientVersionString': _progName,
        'ProgName': _progName,
        'DeviceID': deviceId,
        // In network byte order, as a 16-bit value.
        'PortNumber': ((port & 0xFF) << 8) | ((port >> 8) & 0xFF),
      }, 2);
      final code = reply['Number'];
      if (code != 0) throw UsbmuxRefused(code is int ? code : -1);
      return link.asStream();
    } catch (_) {
      link.close();
      rethrow;
    }
  }

  /// usbmuxd's device events, on one long-lived `Listen` connection:
  /// [UsbmuxEventKind.listening] once usbmuxd took it, then an attached event
  /// for each device already there and an attached or detached one as each
  /// comes and goes. Messages are framed by [UsbmuxFramer], so several in one
  /// chunk and one split across chunks are both read. When the connection
  /// drops (usbmuxd restarting, a malformed message) every device it had
  /// reported is reported detached, then [UsbmuxEventKind.lost], and it is
  /// opened again after [listenRetry], for as long as the stream is listened
  /// to. Cancelling the subscription closes it. Errors are not added to the
  /// stream: a Listen that cannot be opened is just tried again.
  Stream<UsbmuxEvent> listen() {
    late final StreamController<UsbmuxEvent> out;
    var cancelled = false;
    Socket? current;
    Completer<void>? sleeping;

    Future<void> run() async {
      while (!cancelled) {
        final known = <int, UsbmuxDevice>{};
        var opened = false;
        try {
          final socket = current = await Socket.connect(
                  InternetAddress(path, type: InternetAddressType.unix), 0)
              .timeout(timeout);
          if (cancelled) {
            socket.destroy();
            break;
          }
          opened = true;
          socket.add(usbmuxMessage({
            'MessageType': 'Listen',
            'ClientVersionString': _progName,
            'ProgName': _progName,
            'kLibUSBMuxVersion': 3,
          }, 1));
          final framer = UsbmuxFramer();
          await for (final chunk in socket) {
            for (final body in framer.add(chunk)) {
              if (cancelled) break;
              final msg = Plist.decode(utf8.decode(body, allowMalformed: true));
              final id = msg['DeviceID'];
              switch (msg['MessageType']) {
                case 'Result':
                  final code = msg['Number'];
                  if (code != 0) throw UsbmuxRefused(code is int ? code : -1);
                  out.add(const UsbmuxEvent(UsbmuxEventKind.listening));
                case 'Attached' when id is int:
                  final props = msg['Properties'];
                  final device = UsbmuxDevice(
                    deviceId: id,
                    serial: props is Map ? '${props['SerialNumber'] ?? ''}' : '',
                    connectionType:
                        props is Map ? '${props['ConnectionType'] ?? ''}' : '',
                  );
                  known[id] = device;
                  out.add(UsbmuxEvent(UsbmuxEventKind.attached,
                      deviceId: id, device: device));
                case 'Detached' when id is int:
                  out.add(UsbmuxEvent(UsbmuxEventKind.detached,
                      deviceId: id, device: known.remove(id)));
              }
            }
            if (cancelled) break;
          }
        } catch (_) {
          // Dropped, refused or malformed: reported below, then tried again.
        } finally {
          current?.destroy();
          current = null;
        }
        if (cancelled) break;
        for (final MapEntry(:key, :value) in known.entries) {
          out.add(UsbmuxEvent(UsbmuxEventKind.detached,
              deviceId: key, device: value));
        }
        if (opened) out.add(const UsbmuxEvent(UsbmuxEventKind.lost));
        final wake = sleeping = Completer<void>();
        final timer = Timer(listenRetry, () {
          if (!wake.isCompleted) wake.complete();
        });
        await wake.future;
        timer.cancel();
        sleeping = null;
      }
    }

    out = StreamController<UsbmuxEvent>(
      onListen: () => unawaited(run()),
      onCancel: () {
        cancelled = true;
        current?.destroy();
        final s = sleeping;
        if (s != null && !s.isCompleted) s.complete();
      },
    );
    return out.stream;
  }

  Future<_Link> _open() async => _Link(await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix), 0)
      .timeout(timeout), timeout);
}

/// A stream to a port on an iOS device, opened by [UsbmuxClient.connect].
class UsbmuxStream {
  UsbmuxStream._(this._socket, this.data);

  final Socket _socket;

  /// What the device sends.
  final Stream<Uint8List> data;

  void add(List<int> bytes) => _socket.add(bytes);

  void close() => _socket.destroy();
}

/// One connection to usbmuxd. A Dart socket can be listened to once, so one
/// subscription feeds a controller: replies are read from it, and after a
/// Connect the rest of it is the device's stream.
class _Link {
  _Link(this._socket, this._timeout) {
    _sub = _socket.listen((chunk) {
      _buf.add(chunk);
      _drain();
    }, onError: (Object e) {
      _fail(e);
      _out.addError(e);
    }, onDone: () {
      _fail(const SocketException('usbmuxd closed the connection'));
      _out.close();
    });
  }

  final Socket _socket;
  final Duration _timeout;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder();
  Completer<Uint8List>? _reply;
  bool _streaming = false;
  final _out = StreamController<Uint8List>();

  /// The longest reply taken; usbmuxd's are a few KB (a device list).
  static const maxReply = 1 << 20;

  void _fail(Object e) {
    final reply = _reply;
    if (reply != null && !reply.isCompleted) reply.completeError(e);
  }

  void _drain() {
    if (_streaming) {
      final bytes = _buf.takeBytes();
      if (bytes.isNotEmpty) _out.add(bytes);
      return;
    }
    final reply = _reply;
    if (reply == null || reply.isCompleted) return;
    final bytes = _buf.toBytes();
    if (bytes.length < 16) return;
    final length = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.little);
    if (length < 16 || length > maxReply) {
      // Not a header usbmuxd writes: nothing after it can be framed either.
      _buf.clear();
      reply.completeError(
          FormatException('usbmuxd sent a malformed header (length $length)'));
      _socket.destroy();
      return;
    }
    if (bytes.length < length) return;
    _buf.clear();
    if (bytes.length > length) _buf.add(Uint8List.sublistView(bytes, length));
    reply.complete(Uint8List.sublistView(bytes, 16, length));
  }

  Future<Map<String, Object?>> request(Map<String, Object> message, int tag) async {
    final reply = _reply = Completer<Uint8List>();
    _socket.add(usbmuxMessage(message, tag));
    _drain();
    final bytes = await reply.future.timeout(_timeout);
    return Plist.decode(utf8.decode(bytes, allowMalformed: true));
  }

  UsbmuxStream asStream() {
    _streaming = true;
    _drain();
    return UsbmuxStream._(_socket, _out.stream);
  }

  void close() {
    unawaited(_sub.cancel());
    _socket.destroy();
  }
}

/// The few XML plist shapes usbmuxd uses: dict, array, string, integer,
/// true/false and data (kept as base64 text).
class Plist {
  static String encode(Map<String, Object> dict) {
    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
      ..write('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
          '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n')
      ..write('<plist version="1.0">');
    _value(b, dict);
    b.write('</plist>\n');
    return b.toString();
  }

  static void _value(StringBuffer b, Object value) {
    switch (value) {
      case final Map m:
        b.write('<dict>');
        for (final MapEntry(:key, :value) in m.entries) {
          b.write('<key>${_esc('$key')}</key>');
          _value(b, value as Object);
        }
        b.write('</dict>');
      case final List l:
        b.write('<array>');
        for (final v in l) {
          _value(b, v as Object);
        }
        b.write('</array>');
      case final int i:
        b.write('<integer>$i</integer>');
      case final bool v:
        b.write(v ? '<true/>' : '<false/>');
      default:
        b.write('<string>${_esc('$value')}</string>');
    }
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _unesc(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// The top-level dict of [xml] (empty when there is none).
  static Map<String, Object?> decode(String xml) {
    final tokens = RegExp(r'<(/?)([a-zA-Z]+)(/?)>|([^<]+)')
        .allMatches(xml.substring(
            xml.contains('<plist') ? xml.indexOf('>', xml.indexOf('<plist')) + 1 : 0))
        .toList();
    var i = 0;
    Object? parse() {
      while (i < tokens.length) {
        final t = tokens[i++];
        final tag = t.group(2);
        if (tag == null) continue; // whitespace between elements
        if (t.group(1) == '/') return null; // a closing tag of our caller
        final selfClosing = t.group(3) == '/';
        switch (tag) {
          case 'true':
            return true;
          case 'false':
            return false;
          case 'dict':
            final map = <String, Object?>{};
            if (selfClosing) return map;
            while (i < tokens.length) {
              final k = tokens[i];
              if (k.group(2) == 'dict' && k.group(1) == '/') {
                i++;
                break;
              }
              if (k.group(2) == 'key' && k.group(1) != '/') {
                i++;
                final key = i < tokens.length && tokens[i].group(4) != null
                    ? _unesc(tokens[i++].group(4)!)
                    : '';
                i++; // </key>
                map[key] = parse();
              } else {
                i++;
              }
            }
            return map;
          case 'array':
            final list = <Object?>[];
            if (selfClosing) return list;
            while (i < tokens.length) {
              final k = tokens[i];
              if (k.group(2) == 'array' && k.group(1) == '/') {
                i++;
                break;
              }
              if (k.group(2) == null) {
                i++;
                continue;
              }
              list.add(parse());
            }
            return list;
          case 'string':
          case 'integer':
          case 'data':
          case 'real':
          case 'date':
            if (selfClosing) return tag == 'integer' ? 0 : '';
            final text = i < tokens.length && tokens[i].group(4) != null
                ? tokens[i++].group(4)!
                : '';
            i++; // closing tag
            if (tag == 'integer') return int.tryParse(text.trim()) ?? 0;
            if (tag == 'real') return double.tryParse(text.trim()) ?? 0.0;
            return _unesc(text);
          default:
            continue;
        }
      }
      return null;
    }

    final root = parse();
    return root is Map<String, Object?> ? root : <String, Object?>{};
  }
}
