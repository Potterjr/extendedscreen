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
  UsbmuxClient({this.path = '/var/run/usbmuxd', this.timeout = const Duration(seconds: 5)});

  final String path;
  final Duration timeout;

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
    final body = utf8.encode(Plist.encode(message));
    final header = ByteData(16)
      ..setUint32(0, 16 + body.length, Endian.little)
      ..setUint32(4, 1, Endian.little)
      ..setUint32(8, 8, Endian.little)
      ..setUint32(12, tag, Endian.little);
    final reply = _reply = Completer<Uint8List>();
    _socket.add([...header.buffer.asUint8List(), ...body]);
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
