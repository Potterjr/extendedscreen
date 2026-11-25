import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/drag_streamer.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_controller.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_view_model.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/iphone_remote_window.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_window_channel.dart';
import 'package:extendedscreen/shared/connection/usbmux.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Mac's view and control of an iPhone over USB: the usbmuxd client and
/// its plists against a stand-in usbmuxd on a Unix socket, the touch service
/// against a stand-in runner behind it, the coordinate mapping, and the view
/// with no phone.

class _QuietLogger extends LoggerService {
  final warnings = <String>[];
  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) => warnings.add(msg);
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

/// usbmuxd, stood in for: lists [devices]; a Connect to [port] on a listed
/// device opens a line-based runner that answers `ping` with
/// `pong 440x956 fast=[fast]`, `caps` with [caps] (`err caps` by default, as a
/// runner from before release 1 does), `orient` with `orient [orient]` (and
/// [orientSource] after it, when set) and anything else with
/// [answer] (`sent 1ms` by default), keeping every line in [received]. Like
/// usbmuxd, it takes only version 1 plist messages (type 8), and answers with
/// the request's tag; anything else is kept in [badHeaders].
class _FakeUsbmuxd {
  _FakeUsbmuxd(this.path,
      {this.port = 8100,
      this.devices = const [(7, 'UDID-1', 'USB')],
      this.fast = true,
      this.answer = 'sent 1ms',
      this.pong,
      this.caps,
      this.unknown = const {}});

  /// The runner's `caps` answer; null for a runner from before `caps`.
  final String? caps;

  /// The source a release-1 runner names after its `orient` value.
  String? orientSource;

  /// What `ping` is answered with instead of the runner's pong.
  final String? pong;

  final String path;

  /// The runner's port; changed by a test, a later Connect is refused.
  int port;
  final List<(int, String, String)> devices;

  /// Verbs answered only this long after they came, every answer still in
  /// command order, as the runner's `Replies` keeps them.
  final delays = <String, Duration>{};
  final bool fast;
  final String answer;

  /// Commands this runner does not know (a build from before them): it
  /// answers `err <line>` and touches nothing, as the runner does.
  final Set<String> unknown;
  int orient = 1;
  final received = <String>[];
  final badHeaders = <String>[];
  ServerSocket? _server;

  /// The Listen connections open now, and how many were ever taken.
  final listeners = <Socket>[];
  int listens = 0;

  Future<void> start() async {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
    _server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix), 0);
    _server!.listen(_serve);
  }

  /// Closes the server and every Listen connection, as usbmuxd exiting does.
  Future<void> stop() async {
    await _server?.close();
    for (final l in [...listeners]) {
      l.destroy();
    }
    listeners.clear();
  }

  static Map<String, Object> attachedMessage(int id, String serial,
          [String type = 'USB']) =>
      {
        'MessageType': 'Attached',
        'DeviceID': id,
        'Properties': {
          'ConnectionType': type,
          'SerialNumber': serial,
          'DeviceID': id,
        },
      };

  static Map<String, Object> detachedMessage(int id) =>
      {'MessageType': 'Detached', 'DeviceID': id};

  /// [messages] framed and written to every Listen connection in one write.
  void push(List<Map<String, Object>> messages) => pushBytes([
        for (final m in messages) ...usbmuxMessage(m, 0),
      ]);

  void pushBytes(List<int> bytes) {
    for (final l in listeners) {
      _write(l, bytes);
    }
  }

  void _serve(Socket s) {
    final buf = BytesBuilder();
    var streaming = false;
    var lineBuf = '';
    var replies = Future<void>.value();
    s.listen((chunk) {
      if (listeners.contains(s)) return;
      if (streaming) {
        lineBuf += utf8.decode(chunk);
        while (lineBuf.contains('\n')) {
          final i = lineBuf.indexOf('\n');
          final line = lineBuf.substring(0, i);
          lineBuf = lineBuf.substring(i + 1);
          received.add(line);
          final out = switch (line) {
            'ping' => pong ?? 'pong 440x956 fast=$fast',
            'caps' => caps ?? 'err caps',
            'orient' =>
              'orient $orient${orientSource == null ? '' : ' $orientSource'}',
            _ when unknown.contains(line.split(' ').first) => 'err $line',
            _ => answer,
          };
          if (delays.isEmpty) {
            _write(s, utf8.encode('$out\n'));
          } else {
            final delay = delays[line.split(' ').first];
            final before = replies;
            replies = () async {
              await before;
              if (delay != null) await Future<void>.delayed(delay);
              _write(s, utf8.encode('$out\n'));
            }();
          }
        }
        return;
      }
      buf.add(chunk);
      final bytes = buf.toBytes();
      if (bytes.length < 16) return;
      final header = ByteData.sublistView(bytes, 0, 16);
      final length = header.getUint32(0, Endian.little);
      if (bytes.length < length) return;
      buf.clear();
      final version = header.getUint32(4, Endian.little);
      final type = header.getUint32(8, Endian.little);
      final tag = header.getUint32(12, Endian.little);
      if (version != 1 || type != 8) {
        badHeaders.add('version $version type $type');
        s.destroy();
        return;
      }
      final msg = Plist.decode(utf8.decode(bytes.sublist(16, length)));
      Map<String, Object> reply;
      if (msg['MessageType'] == 'Listen') {
        // usbmuxd answers the Listen, then reports each device already
        // there, then each one as it comes and goes, on the same socket.
        listens++;
        listeners.add(s);
        streaming = true; // nothing more is read from it
        lineBuf = '';
        _write(s, usbmuxMessage({'MessageType': 'Result', 'Number': 0}, tag));
        push([
          for (final (id, serial, type) in devices)
            attachedMessage(id, serial, type),
        ]);
        return;
      }
      if (msg['MessageType'] == 'ListDevices') {
        reply = {
          'DeviceList': [
            for (final (id, serial, type) in devices)
              {
                'DeviceID': id,
                'MessageType': 'Attached',
                'Properties': {
                  'ConnectionType': type,
                  'SerialNumber': serial,
                  'DeviceID': id,
                },
              },
          ],
        };
      } else {
        final wanted = msg['PortNumber'] as int;
        final hostOrder = ((wanted & 0xFF) << 8) | ((wanted >> 8) & 0xFF);
        final ok = devices.any((d) => d.$1 == msg['DeviceID']) && hostOrder == port;
        reply = {'MessageType': 'Result', 'Number': ok ? 0 : 3};
        streaming = ok;
      }
      final body = utf8.encode(Plist.encode(reply));
      final out = ByteData(16)
        ..setUint32(0, 16 + body.length, Endian.little)
        ..setUint32(4, 1, Endian.little)
        ..setUint32(8, 8, Endian.little)
        ..setUint32(12, tag, Endian.little);
      _write(s, [...out.buffer.asUint8List(), ...body]);
      if (!streaming) s.close();
    }, onError: (_) {}, onDone: () {
      // The client hung up (a Listen cancelled, a link closed).
      listeners.remove(s);
      s.destroy();
    });
    unawaited(s.done.then((_) {}, onError: (_) {}));
  }

  /// A write to a client that has hung up (the touch link dropped on
  /// purpose) is no test failure.
  static void _write(Socket s, List<int> bytes) {
    try {
      s.add(bytes);
    } catch (_) {}
  }
}

/// Touches with no phone on USB: answers at once, opens no socket.
class _NoPhoneTouch extends IosTouchService {
  @override
  void watch() {}

  @override
  Future<bool> connect({String? udid}) async {
    state.value = IosTouchState.noDevice;
    return false;
  }
}

/// Touches recorded instead of sent; [turned] is what the runner says.
class _RecordingTouch extends IosTouchService {
  int connects = 0;

  /// Never opens usbmuxd: a test feeds [onUsbmuxEvent] itself.
  bool watching = false;
  @override
  void watch() => watching = true;
  @override
  void unwatch() => watching = false;

  IosTurn turned = IosTurn.topLeft;
  final sent = <String>[];

  /// Shared with a channel mock, to see what went out first.
  List<String>? order;

  /// Every command in order, `orient` included ([sent] leaves it out).
  final trace = <String>[];

  int get orients => trace.where((l) => l == 'orient').length;

  /// Whether [connect] reaches a runner (on [udidOf]).
  bool connectWorks = false;
  String udidOf = 'UDID-1';

  @override
  Future<bool> connect({String? udid}) async {
    connects++;
    if (!connectWorks) return false;
    this.udid.value = udidOf;
    state.value = IosTouchState.ready;
    return true;
  }

  int disconnects = 0;
  @override
  void disconnect() {
    disconnects++;
    super.disconnect();
  }

  /// What the real one asks of the runner: `orient`, answered [turned].
  @override
  Future<IosTurn> turn() async {
    trace.add('orient');
    lastTurn.value = turned;
    return turned;
  }

  /// As the real one: only while connected ([state] ready, set by a test).
  @override
  Future<IosTurn> refreshTurn() async =>
      state.value == IosTouchState.ready ? turn() : lastTurn.value;

  bool homeWorks = true;

  @override
  Future<bool> home() async {
    sent.add('home');
    return homeWorks;
  }

  bool systemWorks = true;

  /// How long a system gesture takes to be answered (null: at once).
  Duration? systemDelay;

  @override
  Future<bool> systemGesture(IphoneSystemGesture gesture) async {
    sent.add(gesture.verb);
    final delay = systemDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return systemWorks;
  }

  /// The clock a press in place is timed by: with it set, a command sent
  /// while such a press still plays on the phone counts in [overlaps] (no
  /// second record behind a playing one).
  DateTime Function()? now;
  DateTime? _pressPlaysUntil;
  int overlaps = 0;

  void _record() {
    final until = _pressPlaysUntil;
    final t = now?.call();
    if (until != null && t != null && t.isBefore(until)) overlaps++;
  }

  @override
  Future<void> tap(double nx, double ny) async {
    _record();
    order?.add('tap');
    sent.add('tap ${nx.toStringAsFixed(2)} ${ny.toStringAsFixed(2)}');
    trace.add('tap');
  }

  @override
  Future<void> swipe(double nx1, double ny1, double nx2, double ny2,
      double seconds, {double hold = 0}) async {
    _record();
    order?.add('swipe');
    trace.add('swipe');
    sent.add('swipe ${nx1.toStringAsFixed(2)} ${ny1.toStringAsFixed(2)} '
          '${nx2.toStringAsFixed(2)} ${ny2.toStringAsFixed(2)} '
          '${seconds.toStringAsFixed(2)} hold ${hold.toStringAsFixed(2)}');
    final t = now?.call();
    if (t != null && nx1 == nx2 && ny1 == ny2) {
      _pressPlaysUntil = t.add(
          Duration(microseconds: ((seconds + hold) * 1e6).round()));
    }
  }

  /// Whether the runner takes `pdown`/`pmove`/`pup` (E1; none released does).
  bool fingerWorks = true;

  Future<bool> _finger(String verb, double nx, double ny) async {
    _record();
    sent.add('$verb ${nx.toStringAsFixed(2)} ${ny.toStringAsFixed(2)}');
    trace.add(verb);
    return fingerWorks;
  }

  @override
  Future<bool> fingerDown(double nx, double ny) => _finger('pdown', nx, ny);
  @override
  Future<bool> fingerMove(double nx, double ny) => _finger('pmove', nx, ny);
  @override
  Future<bool> fingerUp(double nx, double ny) => _finger('pup', nx, ny);

  /// `seg` (L3): answered [segReply] after it was sent (on the test's fake
  /// clock), as the runner answers once XCTest has played it; [segWorks]
  /// false answers `err`. Each is kept in [segs], with the time it went out
  /// and how many were outstanding then (itself included).
  Duration segReply = const Duration(milliseconds: 60);
  bool segWorks = true;
  final segs = <_Seg>[];
  int _segsOut = 0;

  @override
  Future<bool> segment(double nx1, double ny1, double nx2, double ny2,
      double seconds, {double settle = 0, double lead = 0}) async {
    _segsOut++;
    segs.add(_Seg(nx1, ny1, nx2, ny2, seconds, settle, lead, now?.call(),
        _segsOut));
    trace.add('seg');
    sent.add('seg ${nx1.toStringAsFixed(2)} ${ny1.toStringAsFixed(2)} '
        '${nx2.toStringAsFixed(2)} ${ny2.toStringAsFixed(2)}');
    await Future<void>.delayed(segReply);
    _segsOut--;
    return segWorks;
  }
}

/// One `seg` the recording touch was asked for.
class _Seg {
  _Seg(this.x1, this.y1, this.x2, this.y2, this.seconds, this.settle,
      this.lead, this.at, this.outstanding);
  final double x1, y1, x2, y2, seconds, settle, lead;
  final DateTime? at;
  final int outstanding;
}

/// A usbmuxd client whose listing waits for [gate].
class _GatedUsbmux extends UsbmuxClient {
  _GatedUsbmux(String path) : super(path: path);
  final gate = Completer<void>();

  @override
  Future<List<UsbmuxDevice>> listDevices() async {
    await gate.future;
    return super.listDevices();
  }
}

/// A usbmuxd client whose Connect waits for [gate] ([waiting] once one does).
class _GatedConnect extends UsbmuxClient {
  _GatedConnect(String path) : super(path: path);
  final gate = Completer<void>();
  bool waiting = false;

  @override
  Future<UsbmuxStream> connect(int deviceId, int port) async {
    waiting = true;
    await gate.future;
    return super.connect(deviceId, port);
  }
}

UsbmuxEvent _attached(int id, String serial, [String type = 'USB']) =>
    UsbmuxEvent(UsbmuxEventKind.attached,
        deviceId: id,
        device: UsbmuxDevice(deviceId: id, serial: serial, connectionType: type));

UsbmuxEvent _detached(int id) =>
    UsbmuxEvent(UsbmuxEventKind.detached, deviceId: id);

String _ev(UsbmuxEvent e) => '${e.kind.name}'
    '${e.deviceId == null ? '' : ' ${e.deviceId}'}'
    '${e.device == null ? '' : ' ${e.device!.serial}'}';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String path;
  late _QuietLogger log;

  setUp(() async {
    log = Get.put<LoggerService>(_QuietLogger()) as _QuietLogger;
    dir = await Directory.systemTemp.createTemp('usbmux');
    path = '${dir.path}/usbmuxd';
  });

  tearDown(() async {
    Get.reset();
    await dir.delete(recursive: true);
  });

  group('Plist', () {
    test('encodes and decodes dicts, arrays, strings, integers and booleans, '
        'escaping text', () {
      final xml = Plist.encode({
        'MessageType': 'Connect',
        'DeviceID': 42,
        'Name': 'a < b & c',
        'On': true,
        'List': [1, 'two', false],
      });
      expect(Plist.decode(xml), {
        'MessageType': 'Connect',
        'DeviceID': 42,
        'Name': 'a < b & c',
        'On': true,
        'List': [1, 'two', false],
      });
    });

    test('writes text escaped as a plist parser expects it', () {
      final xml = Plist.encode({'Name': 'a & b <c>'});
      expect(xml, contains('<key>Name</key><string>a &amp; b &lt;c&gt;</string>'));
    });

    test('reads escaped text as plutil writes it', () {
      const xml = '<?xml version="1.0"?><plist version="1.0"><dict>'
          '<key>Name</key><string>Tom &amp; Jerry&apos;s &lt;iPhone&gt;</string>'
          '</dict></plist>';
      expect(Plist.decode(xml)['Name'], "Tom & Jerry's <iPhone>");
    });

    test('reads a nested reply as usbmuxd writes it', () {
      const xml = '<?xml version="1.0"?><plist version="1.0"><dict>'
          '<key>DeviceList</key><array><dict><key>DeviceID</key>'
          '<integer>32</integer><key>Properties</key><dict>'
          '<key>ConnectionType</key><string>USB</string>'
          '<key>SerialNumber</key><string>00008160-X</string>'
          '<key>LocationID</key><integer>0</integer></dict></dict></array>'
          '</dict></plist>';
      final d = Plist.decode(xml);
      final first = (d['DeviceList']! as List).first as Map;
      expect(first['DeviceID'], 32);
      expect((first['Properties'] as Map)['SerialNumber'], '00008160-X');
    });
  });

  group('UsbmuxClient', () {
    test('lists devices and opens a stream to a port on one', () async {
      final mux = _FakeUsbmuxd(path,
          devices: const [(7, 'UDID-1', 'USB'), (9, 'UDID-2', 'Network')]);
      await mux.start();
      addTearDown(mux.stop);
      final client = UsbmuxClient(path: path);

      final devices = await client.listDevices();
      expect(devices.map((d) => (d.deviceId, d.serial, d.isUsb)),
          [(7, 'UDID-1', true), (9, 'UDID-2', false)]);

      expect(mux.badHeaders, isEmpty);
      final stream = await client.connect(7, 8100);
      addTearDown(stream.close);
      final lines = stream.data
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final first = lines.first;
      stream.add(utf8.encode('ping\n'));
      expect(await first, startsWith('pong'));
    });

    test('a reply header too short to be one fails the request at once, '
        'with nothing thrown in the socket listener', () async {
      final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix), 0);
      addTearDown(server.close);
      server.listen((s) {
        s.listen((_) {
          final bad = ByteData(16)
            ..setUint32(0, 8, Endian.little)
            ..setUint32(4, 1, Endian.little)
            ..setUint32(8, 8, Endian.little)
            ..setUint32(12, 1, Endian.little);
          s.add(bad.buffer.asUint8List());
        }, onError: (_) {});
      });
      final client =
          UsbmuxClient(path: path, timeout: const Duration(seconds: 4));
      final started = DateTime.now();
      await expectLater(client.listDevices(), throwsA(isA<FormatException>()));
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
    });

    test('a port nothing listens on is refused', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      expect(() => UsbmuxClient(path: path).connect(7, 9999),
          throwsA(isA<UsbmuxRefused>().having((e) => e.code, 'code', 3)));
    });
  });

  group('usbmux Listen', () {
    test('the framer reads two messages from one chunk and one split '
        'anywhere across chunks', () {
      final a = usbmuxMessage(_FakeUsbmuxd.attachedMessage(3, 'A'), 0);
      final b = usbmuxMessage(_FakeUsbmuxd.attachedMessage(4, 'B'), 0);
      final framer = UsbmuxFramer();
      final both = framer.add([...a, ...b]);
      expect(both.map((m) => Plist.decode(utf8.decode(m))['DeviceID']), [3, 4]);

      // Split inside the header, then inside the body, then the rest with
      // the start of the next one.
      expect(framer.add(a.sublist(0, 7)), isEmpty);
      expect(framer.add(a.sublist(7, 40)), isEmpty);
      final rest = framer.add([...a.sublist(40), ...b.sublist(0, 20)]);
      expect(rest.map((m) => Plist.decode(utf8.decode(m))['DeviceID']), [3]);
      final last = framer.add(b.sublist(20));
      expect(last.map((m) => Plist.decode(utf8.decode(m))['DeviceID']), [4]);

      expect(() => UsbmuxFramer().add(ByteData(16).buffer.asUint8List()),
          throwsFormatException);
    });

    test('reports the devices there, then each Attached and Detached, '
        'framed however the chunks fall', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final events = <String>[];
      final sub = UsbmuxClient(path: path).listen().listen((e) => events.add(_ev(e)));
      addTearDown(sub.cancel);

      await _until(() => events.length == 2);
      expect(events, ['listening', 'attached 7 UDID-1']);
      // Two in one write.
      mux.push([
        _FakeUsbmuxd.attachedMessage(8, 'UDID-2'),
        _FakeUsbmuxd.attachedMessage(9, 'UDID-2', 'Network'),
      ]);
      await _until(() => events.length == 4);
      // One split across two writes, apart in time.
      final bytes = usbmuxMessage(_FakeUsbmuxd.detachedMessage(8), 0);
      mux.pushBytes(bytes.sublist(0, 10));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, hasLength(4));
      mux.pushBytes(bytes.sublist(10));
      await _until(() => events.length == 5);
      expect(events.skip(2), [
        'attached 8 UDID-2',
        'attached 9 UDID-2',
        'detached 8 UDID-2',
      ]);
    });

    test('opens its Listen again when usbmuxd restarts, the devices it had '
        'reported detached meanwhile; a cancel closes it', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      final events = <String>[];
      final sub = UsbmuxClient(
              path: path, listenRetry: const Duration(milliseconds: 50))
          .listen()
          .listen((e) => events.add(_ev(e)));

      await _until(() => events.length == 2);
      await mux.stop();
      await _until(() => events.length == 4);
      expect(events.skip(2), ['detached 7 UDID-1', 'lost']);
      await mux.start();
      await _until(() => events.length == 6);
      expect(events.skip(4), ['listening', 'attached 7 UDID-1']);
      expect(mux.listens, 2);

      await sub.cancel();
      await _until(() => mux.listeners.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(mux.listens, 2, reason: 'nothing opened after the cancel');
      await mux.stop();
    });
  });

  group('IosTouchService', () {
    test('connects to the runner over usbmuxd and sends taps and swipes '
        'without waiting for them to land', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      expect(await touch.connect(), isTrue);
      expect(touch.state.value, IosTouchState.ready);
      expect(touch.screenPoints.value, '440x956');

      await touch.tap(0.25, 0.5);
      await touch.swipe(0.5, 0.9, 0.5, 0.2, 0.3);
      await _until(() => mux.received.length == 5);
      expect(mux.received, [
        'ping',
        'caps',
        // Asked once on connect, so the first landscape click is mapped
        // without a round trip of its own.
        'orient',
        'atap 0.2500 0.5000',
        'aswipe 0.5000 0.9000 0.5000 0.2000 0.300',
      ]);
    });

    test('says why touches are off: no device on USB, or no runner', () async {
      final none = _FakeUsbmuxd(path, devices: const [(9, 'UDID-2', 'Network')]);
      await none.start();
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      expect(await touch.connect(), isFalse);
      expect(touch.state.value, IosTouchState.noDevice);
      await none.stop();

      final other = '${dir.path}/usbmuxd2';
      final noRunner = _FakeUsbmuxd(other, port: 1234);
      await noRunner.start();
      addTearDown(noRunner.stop);
      final touch2 = IosTouchService(usbmux: UsbmuxClient(path: other));
      expect(await touch2.connect(), isFalse);
      expect(touch2.state.value, IosTouchState.noRunner);
      // A touch with no runner is dropped, not an error.
      await touch2.tap(0.5, 0.5);
    });

    test('a runner without fast synthesis gets its blocking tap and swipe, '
        'which it does without it', () async {
      final mux = _FakeUsbmuxd(path, fast: false, answer: 'ok 250ms');
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      expect(await touch.connect(), isTrue);
      expect(touch.fast, isFalse);
      await touch.tap(0.25, 0.5);
      await touch.swipe(0.5, 0.9, 0.5, 0.2, 0.3, hold: 0.8);
      expect(mux.received, [
        'ping',
        'caps',
        'orient',
        'tap 0.2500 0.5000',
        'swipe 0.5000 0.9000 0.5000 0.2000 0.300 0.800',
      ]);
    });

    test('a runner built before aswipe gets its swipes the blocking way: '
        'the refused one again at once, the next ones straight away, until '
        'it is connected again', () async {
      final mux = _FakeUsbmuxd(path, unknown: {'aswipe'});
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      await touch.swipe(0.5, 0.8, 0.5, 0.3, 0.3);
      await touch.swipe(0.5, 0.3, 0.5, 0.8, 0.3);
      await touch.tap(0.5, 0.5);
      expect(mux.received, [
        'ping',
        'caps',
        'orient',
        'aswipe 0.5000 0.8000 0.5000 0.3000 0.300',
        'swipe 0.5000 0.8000 0.5000 0.3000 0.300',
        'swipe 0.5000 0.3000 0.5000 0.8000 0.300',
        'atap 0.5000 0.5000',
      ]);
      expect(touch.state.value, IosTouchState.ready);
      expect(log.warnings.where((w) => w.contains('does not take')), hasLength(1));

      touch.disconnect();
      await touch.swipe(0.5, 0.8, 0.5, 0.3, 0.3);
      expect(mux.received.skip(7).take(4),
          ['ping', 'caps', 'orient', 'aswipe 0.5000 0.8000 0.5000 0.3000 0.300']);
    });

    test('presses Home; a runner built before home says no', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      expect(await touch.home(), isTrue);
      expect(mux.received, ['ping', 'caps', 'orient', 'home']);

      final old = '${dir.path}/old';
      final mux2 = _FakeUsbmuxd(old, unknown: {'home'});
      await mux2.start();
      addTearDown(mux2.stop);
      final touch2 = IosTouchService(usbmux: UsbmuxClient(path: old));
      addTearDown(touch2.disconnect);
      expect(await touch2.home(), isFalse);
      expect(touch2.state.value, IosTouchState.ready);
    });

    test('a touch the runner refuses is logged, and the link stays', () async {
      final mux = _FakeUsbmuxd(path, answer: 'err atap 0.5 0.5');
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      await touch.tap(0.5, 0.5);
      // Refused fast, then refused the blocking way too: both logged, the
      // tap is not sent a third time.
      expect(mux.received,
          ['ping', 'caps', 'orient', 'atap 0.5000 0.5000', 'tap 0.5000 0.5000']);
      expect(log.warnings.where((w) => w.contains('refused')), hasLength(2));
      expect(touch.state.value, IosTouchState.ready);
    });

    test('asks the runner which way the phone is turned, keeping the last '
        'side while it lies flat', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      mux.orient = 4; // landscapeRight: the top on the right
      expect(await touch.turn(), IosTurn.topRight);
      mux.orient = 5; // face up
      expect(await touch.turn(), IosTurn.topRight);
      mux.orient = 3;
      expect(await touch.turn(), IosTurn.topLeft);
      expect(touch.lastTurn.value, IosTurn.topLeft);

      // Two asks at once share one question.
      mux.received.clear();
      mux.orient = 4;
      final both = await Future.wait([touch.turn(), touch.refreshTurn()]);
      expect(both, [IosTurn.topRight, IosTurn.topRight]);
      expect(mux.received, ['orient']);
      expect(touch.lastTurn.value, IosTurn.topRight);
    });

    test('asks the side once on connect, and a refresh never opens a link',
        () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      expect(await touch.refreshTurn(), IosTurn.topLeft);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mux.received, isEmpty, reason: 'not connected: nothing asked');

      mux.orient = 4;
      expect(await touch.connect(), isTrue);
      await _until(() => touch.lastTurn.value == IosTurn.topRight);
      expect(mux.received, ['ping', 'caps', 'orient']);
    });

    test('RunnerCaps parses verbs, options and the experimental list',
        () {
      final caps = RunnerCaps.parse('caps ping tap seg switcher release=1 '
          'orient=iface exp=pdown,pmove,pup')!;
      expect(caps.verbs, {'ping', 'tap', 'seg', 'switcher'});
      expect(caps.experimental, {'pdown', 'pmove', 'pup'});
      expect(caps.options, {'release': '1', 'orient': 'iface'});
      expect(caps.has('seg'), isTrue);
      expect(caps.has('pdown'), isTrue, reason: 'experimental is listed');
      expect(caps.has('control'), isFalse);
      expect(RunnerCaps.parse('err caps'), isNull);
      expect(RunnerCaps.parse('ok 3ms'), isNull);
    });

    test('a caps answer enables exactly the verbs it lists: a fast verb it '
        'leaves out goes the blocking way at once, and an unlisted Home or '
        'finger verb is never sent', () async {
      final mux = _FakeUsbmuxd(path,
          caps: 'caps ping caps quit tap swipe orient seg switcher '
              'release=1 exp=pdown');
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      expect(await touch.connect(), isTrue);
      expect(touch.caps.value?.options['release'], '1');
      for (final v in ['seg', 'switcher', 'tap', 'pdown']) {
        expect(touch.supports(v), isTrue, reason: v);
      }
      for (final v in ['atap', 'aswipe', 'home', 'spotlight', 'control',
          'notifications', 'pmove', 'scroll', 'key']) {
        expect(touch.supports(v), isFalse, reason: v);
      }

      await touch.tap(0.5, 0.5);
      expect(await touch.home(), isFalse);
      expect(await touch.fingerMove(0.5, 0.5), isFalse);
      expect(await touch.fingerDown(0.5, 0.5), isTrue);
      expect(mux.received, [
        'ping',
        'caps',
        'orient',
        // No `atap` round trip first: caps already said it is missing.
        'tap 0.5000 0.5000',
        'pdown 0.5000 0.5000',
      ]);
      expect(log.warnings.where((w) => w.contains('does not take')), isEmpty);
    });

    test('a system gesture goes out as its verb and waits for the answer; a '
        'runner whose caps leave it out, or with no caps, is never asked',
        () async {
      final mux = _FakeUsbmuxd(path,
          caps: 'caps ping caps orient switcher spotlight control '
              'notifications release=1',
          answer: 'ok 420ms o=1');
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      for (final g in IphoneSystemGesture.values) {
        expect(await touch.systemGesture(g), isTrue, reason: g.name);
      }
      expect(mux.received.skip(3),
          ['switcher', 'spotlight', 'control', 'notifications']);

      for (final (name, caps) in [
        ('some', 'caps ping caps orient switcher'),
        ('old', null),
      ]) {
        final mux2 = _FakeUsbmuxd('${dir.path}/$name', caps: caps);
        await mux2.start();
        addTearDown(mux2.stop);
        final touch2 =
            IosTouchService(usbmux: UsbmuxClient(path: '${dir.path}/$name'));
        addTearDown(touch2.disconnect);
        expect(await touch2.systemGesture(IphoneSystemGesture.controlCenter),
            isFalse, reason: name);
        // (The connect's own orient may still be on its way.)
        expect(
            mux2.received.where((l) => !{'ping', 'caps', 'orient'}.contains(l)),
            isEmpty,
            reason: name);
        expect(touch2.dropped.value, 0, reason: name);
      }

      final mux3 = _FakeUsbmuxd('${dir.path}/err',
          caps: 'caps ping caps orient switcher', answer: 'err switcher');
      await mux3.start();
      addTearDown(mux3.stop);
      final touch3 =
          IosTouchService(usbmux: UsbmuxClient(path: '${dir.path}/err'));
      addTearDown(touch3.disconnect);
      expect(await touch3.systemGesture(IphoneSystemGesture.switcher), isFalse);
    });

    test('seg goes out as one line and is true once the runner says done; '
        'an err answer is false', () async {
      final mux = _FakeUsbmuxd(path,
          caps: 'caps ping caps orient seg release=1', answer: 'done 140ms');
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      expect(await touch.connect(), isTrue);
      expect(await touch.segment(0.5, 0.6, 0.5, 0.4, 0.12,
          settle: 0.07, lead: 12), isTrue);
      expect(mux.received.last,
          'seg 0.5000 0.6000 0.5000 0.4000 0.120 0.070 12.0');

      final refusing = _FakeUsbmuxd('${dir.path}/err',
          caps: 'caps ping seg', answer: 'err seg');
      await refusing.start();
      addTearDown(refusing.stop);
      final touch2 =
          IosTouchService(usbmux: UsbmuxClient(path: '${dir.path}/err'));
      addTearDown(touch2.disconnect);
      expect(await touch2.connect(), isTrue);
      expect(await touch2.segment(0.5, 0.6, 0.5, 0.4, 0.12), isFalse);
    });

    test('a runner without seg in its caps, or without caps, is never sent '
        'a seg', () async {
      for (final caps in [null, 'caps ping aswipe']) {
        final socket = '${dir.path}/${caps == null ? 'old' : 'noseg'}';
        final mux = _FakeUsbmuxd(socket, caps: caps, answer: 'done 1ms');
        await mux.start();
        addTearDown(mux.stop);
        final touch = IosTouchService(usbmux: UsbmuxClient(path: socket));
        addTearDown(touch.disconnect);
        expect(await touch.connect(), isTrue);
        expect(await touch.segment(0.5, 0.6, 0.5, 0.4, 0.12), isFalse,
            reason: '$caps');
        expect(mux.received.where((l) => l.startsWith('seg')), isEmpty,
            reason: '$caps');
      }
    });

    test('no caps (an older runner answers err) keeps today\'s feature set',
        () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      expect(await touch.connect(), isTrue);
      expect(touch.caps.value, isNull);
      for (final v in RunnerCaps.legacyVerbs) {
        expect(touch.supports(v), isTrue, reason: v);
      }
      for (final v in ['seg', 'switcher', 'spotlight', 'control',
          'notifications', 'pdown', 'scroll', 'key', 'pastetest']) {
        expect(touch.supports(v), isFalse, reason: v);
      }
      // Today's verbs go out as before; the finger verbs are tried and
      // their `err` says no, as before caps.
      await touch.tap(0.5, 0.5);
      expect(await touch.home(), isTrue);
      expect(mux.received, ['ping', 'caps', 'orient', 'atap 0.5000 0.5000',
          'home']);

      // Caps belong to the connection: gone with it.
      final mux2 = _FakeUsbmuxd('${dir.path}/new', caps: 'caps ping seg');
      await mux2.start();
      addTearDown(mux2.stop);
      final touch2 = IosTouchService(usbmux: UsbmuxClient(path: mux2.path));
      expect(await touch2.connect(), isTrue);
      expect(touch2.supports('seg'), isTrue);
      touch2.disconnect();
      expect(touch2.caps.value, isNull);
    });

    test('an orient answer naming its source is parsed; one without a '
        'source is the physical orientation', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      expect(touch.orientSource.value, isNull);
      mux.orient = 4;
      mux.orientSource = 'app';
      expect(await touch.turn(), IosTurn.topRight);
      expect(touch.orientSource.value, IosOrientSource.app);

      mux.orient = 3;
      mux.orientSource = 'springboard';
      expect(await touch.turn(), IosTurn.topLeft);
      expect(touch.orientSource.value, IosOrientSource.springboard);

      // An interface in portrait (rotation lock, a portrait-only app) keeps
      // the last landscape side; the frame is portrait then anyway.
      mux.orient = 1;
      mux.orientSource = 'app';
      expect(await touch.turn(), IosTurn.topLeft);
      expect(touch.orientSource.value, IosOrientSource.app);

      mux.orient = 4;
      mux.orientSource = null;
      expect(await touch.turn(), IosTurn.topRight);
      expect(touch.orientSource.value, IosOrientSource.device);
    });

    test('watching: the Detached of the phone the link is up to drops it at '
        'once, and its Attached again is a chance to connect', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.onClose);
      final chances = <String>[];
      final sub = touch.attachments.listen((d) => chances.add(d.serial));
      addTearDown(sub.cancel);

      touch.watch();
      await _until(() => touch.listening.value && touch.attached.isNotEmpty);
      expect(chances, ['UDID-1']);
      expect(await touch.connect(), isTrue);
      expect(touch.udid.value, 'UDID-1');

      mux.push([_FakeUsbmuxd.detachedMessage(7)]);
      await _until(() => touch.state.value == IosTouchState.reconnecting);
      expect(touch.udid.value, isNull);
      expect(touch.attached, isEmpty);
      mux.push([_FakeUsbmuxd.attachedMessage(7, 'UDID-1')]);
      await _until(() => chances.length == 2);
      expect(await touch.connect(), isTrue);

      touch.unwatch();
      expect(touch.listening.value, isFalse);
      expect(touch.attached, isEmpty);
    });

    test('two phones attached: no touch link, the refusal shown; one phone '
        'listed twice (USB and network) is one', () async {
      final mux = _FakeUsbmuxd(path,
          devices: const [(7, 'UDID-1', 'USB'), (8, 'UDID-2', 'USB')]);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      expect(await touch.connect(), isFalse);
      expect(touch.state.value, IosTouchState.severalDevices);
      await touch.tap(0.5, 0.5);
      expect(mux.received, isEmpty, reason: 'nothing reaches either runner');
      expect(touch.dropped.value, 1);

      final other = '${dir.path}/usbmuxd2';
      final twice = _FakeUsbmuxd(other,
          devices: const [(7, 'UDID-1', 'USB'), (9, 'UDID-1', 'Network')]);
      await twice.start();
      addTearDown(twice.stop);
      final touch2 = IosTouchService(usbmux: UsbmuxClient(path: other));
      addTearDown(touch2.disconnect);
      expect(await touch2.connect(), isTrue);

      // Two capture devices on the picture's side refuse it too, and drop
      // a link that is up.
      touch2.setCaptureDevices(2);
      expect(touch2.state.value, IosTouchState.severalDevices);
      expect(await touch2.connect(), isFalse);
      touch2.setCaptureDevices(1);
      expect(touch2.state.value, IosTouchState.idle);
      expect(await touch2.connect(), isTrue);
    });

    test('a second phone attached while connected drops the link; its '
        'Detached lifts the refusal and is a chance to connect', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      final chances = <String>[];
      final sub = touch.attachments.listen((d) => chances.add(d.serial));
      addTearDown(sub.cancel);

      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      expect(await touch.connect(), isTrue);
      touch.onUsbmuxEvent(_attached(8, 'UDID-2'));
      expect(touch.state.value, IosTouchState.severalDevices);
      expect(touch.udid.value, isNull);
      touch.onUsbmuxEvent(_attached(9, 'UDID-1', 'Network'));
      expect(touch.attached.keys, [7, 8], reason: 'USB ones only');
      touch.onUsbmuxEvent(_detached(8));
      expect(touch.state.value, IosTouchState.idle);
      await Future<void>.delayed(Duration.zero);
      expect(chances, ['UDID-1', 'UDID-1']);
    });

    test('a send while the link is down is counted and logged, not thrown',
        () async {
      final mux = _FakeUsbmuxd(path, port: 1234);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);

      await touch.tap(0.5, 0.5);
      await touch.swipe(0.1, 0.1, 0.2, 0.2, 0.3);
      expect(await touch.home(), isFalse);
      expect(touch.state.value, IosTouchState.noRunner);
      expect(touch.dropped.value, 3);
      expect(log.warnings.where((w) => w.startsWith('iPhone touches: dropped')),
          [
            contains('"atap 0.5000 0.5000" (noRunner; 1 dropped'),
            contains('"aswipe 0.1000'),
            contains('"home" (noRunner; 3 dropped'),
          ]);
    });

    test('a port that answers but not with pong reads as the runner '
        'refusing', () async {
      final mux = _FakeUsbmuxd(path, pong: 'denied');
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      expect(await touch.connect(), isFalse);
      expect(touch.state.value, IosTouchState.runnerRefused);
    });

    test('a disconnect while a connect is under way leaves nothing open', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final client = _GatedUsbmux(path);
      final touch = IosTouchService(usbmux: client);

      final connecting = touch.connect();
      await Future<void>.delayed(Duration.zero);
      touch.disconnect();
      client.gate.complete();
      expect(await connecting, isFalse);
      expect(touch.state.value, IosTouchState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(mux.received, isEmpty, reason: 'no ping on a link nobody wants');
    });

    test('an answer held up behind a slow one does not time out: a tap '
        'queued behind a seg the runner answers 2.5 s later keeps the link',
        () async {
      final mux = _FakeUsbmuxd(path,
          caps: 'caps ping caps tap atap swipe aswipe orient seg release=1',
          answer: 'sent 1ms');
      mux.delays['seg'] = const Duration(milliseconds: 2500);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      expect(await touch.connect(), isTrue);
      final seg = touch.segment(0.5, 0.8, 0.5, 0.6, 0.1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await touch.tap(0.5, 0.5);
      await seg;
      expect(mux.received.where((l) => l.startsWith('atap')), hasLength(1));
      expect(touch.state.value, IosTouchState.ready,
          reason: 'its 2 s ran out while the seg ahead of it was unanswered');
      expect(touch.dropped.value, 0);
    });

    test('a connect that fails right after the link dropped reads as '
        'reconnecting, not as no runner; past the grace it is no runner',
        () async {
      for (final grace in [const Duration(seconds: 10), Duration.zero]) {
        final socket = '${dir.path}/grace${grace.inSeconds}';
        final mux = _FakeUsbmuxd(socket);
        await mux.start();
        addTearDown(mux.stop);
        final touch = IosTouchService(
            usbmux: UsbmuxClient(path: socket), reconnectGrace: grace);
        addTearDown(touch.disconnect);
        touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
        expect(await touch.connect(), isTrue);
        // The phone re-enumerates: off usbmuxd, back, and its Connect
        // refused for a moment.
        touch.onUsbmuxEvent(_detached(7));
        expect(touch.state.value, IosTouchState.reconnecting);
        mux.port = 1;
        expect(await touch.connect(), isFalse);
        expect(
            touch.state.value,
            grace == Duration.zero
                ? IosTouchState.noRunner
                : IosTouchState.reconnecting,
            reason: 'grace $grace');
      }
    });

    test('the Detached of the phone a connect is opening a stream to gives '
        'that connect up: the next connect is a fresh one', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final client = _GatedConnect(path);
      final touch = IosTouchService(usbmux: client);
      addTearDown(touch.disconnect);
      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      final first = touch.connect();
      await _until(() => client.waiting);
      touch.onUsbmuxEvent(_detached(7));
      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      final second = touch.connect();
      expect(identical(first, second), isFalse,
          reason: 'not the attempt to the DeviceID that left');
      client.gate.complete();
      expect(await first, isFalse);
      expect(await second, isTrue);
      expect(touch.state.value, IosTouchState.ready);
    });

    test('an Attached heard while a connect is under way is posted again '
        'once that connect has failed', () async {
      final mux = _FakeUsbmuxd(path, devices: const []);
      await mux.start();
      addTearDown(mux.stop);
      final client = _GatedUsbmux(path);
      final touch = IosTouchService(usbmux: client);
      addTearDown(touch.disconnect);
      final posted = <String>[];
      final sub = touch.attachments.listen((d) => posted.add(d.serial));
      addTearDown(sub.cancel);
      final connecting = touch.connect();
      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      await Future<void>.delayed(Duration.zero);
      expect(posted, isEmpty, reason: 'a connect now would join that one');
      client.gate.complete();
      expect(await connecting, isFalse, reason: 'its listing found nothing');
      await _until(() => posted.isNotEmpty);
      expect(posted, ['UDID-1']);
    });
  });

  group('DragStreamer', () {
    testWidgets('a flick let go just as a segment went out still flings: a '
        'short segment onward with no settle', (tester) async {
      DateTime now() => tester.binding.clock.now();
      final sent = <(PortraitPoint, PortraitPoint, double)>[];
      final streamer = DragStreamer(
        from: (x: 0.5, y: 0.8),
        points: const Size(440, 956),
        now: now,
        send: (a, b, seconds, settle, lead) async {
          sent.add((a, b, settle));
          return true;
        },
      );
      await tester.pump(const Duration(milliseconds: 100));
      streamer.move((x: 0.5, y: 0.7)); // out at once: in flight until ~270
      await tester.pump(const Duration(milliseconds: 100));
      streamer.move((x: 0.5, y: 0.68));
      await tester.pump(const Duration(milliseconds: 60));
      streamer.move((x: 0.5, y: 0.66));
      await tester.pump(const Duration(milliseconds: 15));
      expect(sent, hasLength(2), reason: 'the second went out at ~270 ms');
      expect(sent.last.$2.y, closeTo(0.66, 1e-9));
      final released = streamer.release((x: 0.5, y: 0.66));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await released, DragRelease.done);
      expect(sent, hasLength(3));
      final (a, b, settle) = sent.last;
      expect(settle, 0, reason: 'it flings');
      expect(a.y, closeTo(0.66, 1e-9));
      expect((a.y - b.y) * 956, closeTo(15, 0.5),
          reason: 'minPoints on, the way it was going (up)');
    });

    testWidgets('a drag that stopped where its last segment ended sends '
        'nothing more', (tester) async {
      DateTime now() => tester.binding.clock.now();
      var sent = 0;
      final streamer = DragStreamer(
        from: (x: 0.5, y: 0.8),
        points: const Size(440, 956),
        now: now,
        send: (a, b, seconds, settle, lead) async {
          sent++;
          return true;
        },
      );
      await tester.pump(const Duration(milliseconds: 100));
      streamer.move((x: 0.5, y: 0.7));
      await tester.pump(const Duration(milliseconds: 400));
      final released = streamer.release((x: 0.5, y: 0.7));
      await tester.pump(const Duration(milliseconds: 300));
      expect(await released, DragRelease.done);
      expect(sent, 1);
    });
  });

  group('coordinates', () {
    test('a portrait frame maps straight; a landscape one is turned a quarter '
        'to the portrait screen the runner addresses', () {
      const box = Size(200, 400);
      expect(
          IphoneRemoteController.toPortrait(
              const Offset(50, 100), box, const Size(1320, 2868)),
          (x: 0.25, y: 0.25));
      const wide = Size(400, 200);
      expect(
          IphoneRemoteController.toPortrait(
              const Offset(100, 50), wide, const Size(2868, 1320)),
          (x: 0.75, y: 0.25));
      // Turned the other way, the same click is the opposite corner.
      expect(
          IphoneRemoteController.toPortrait(
              const Offset(100, 50), wide, const Size(2868, 1320),
              turned: IosTurn.topRight),
          (x: 0.25, y: 0.75));
    });
  });

  group('IphoneRemoteController', () {
    late List<String> calls;
    late Completer<Map<String, Object?>> starting;
    const channel = MethodChannel(IosScreenChannel.channelName);

    void mockScreen(WidgetTester tester, {bool phone = true}) {
      calls = [];
      starting = Completer();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'listDevices' => [
              if (phone) {'id': 'cam-1', 'name': 'iPhone'},
            ],
          'start' => starting.future,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
    }

    testWidgets('starts one capture at a time, however long the Camera '
        'prompt stays up', (tester) async {
      mockScreen(tester);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(seconds: 2)));

      await tester.pump(const Duration(seconds: 20));
      expect(calls.where((m) => m == 'start'), hasLength(1));
      final retried = c.retry();
      await tester.pump(const Duration(seconds: 1));
      expect(calls.where((m) => m == 'start'), hasLength(1));

      starting.complete({'id': 'cam-1'});
      await tester.pump();
      await retried;
      expect((c.screen.current, c.screen.isRunning('cam-1')), ('cam-1', true));
      expect(c.screenState.value, IphoneScreenState.live);
      expect(touch.connects, 0,
          reason: 'no frame yet: the phone may still be off usbmuxd');
      // No Attached heard (a usbmuxd whose Listen does not work): the tick
      // connects once a frame has come.
      c.screen.frameSize.value = const Size(1320, 2868);
      expect(touch.connects, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(touch.connects, greaterThan(0));
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('starts the device it was opened for when that one is '
        'listed, else the first one', (tester) async {
      final started = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        return switch (call.method) {
          'listDevices' => [
              {'id': 'cam-1', 'name': 'iPhone'},
              {'id': 'cam-2', 'name': 'iPad'},
            ],
          'start' => () {
              started.add((call.arguments as Map)['id']);
              return {'id': (call.arguments as Map)['id']};
            }(),
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      Get.put(IosScreenChannel());
      Get.put<IosTouchService>(_RecordingTouch());

      for (final (id, expected) in [
        ('cam-2', 'cam-2'),
        ('cam-9', 'cam-1'),
        (null, 'cam-1'),
      ]) {
        started.clear();
        final c = Get.put(IphoneRemoteController(
            retryEvery: const Duration(hours: 1), deviceId: id));
        await tester.pump();
        await tester.pump();
        expect(started, [expected], reason: '$id');
        expect(c.screenState.value, IphoneScreenState.live);
        await Get.delete<IphoneRemoteController>();
        await tester.pump();
      }
    });

    testWidgets('a start superseded on the native side leaves the view '
        'waiting, not failed', (tester) async {
      mockScreen(tester);
      Get.put(IosScreenChannel());
      Get.put<IosTouchService>(_RecordingTouch());
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      await tester.pump();
      starting.completeError(PlatformException(code: 'CANCELLED'));
      await tester.pump();
      expect(c.screenState.value, IphoneScreenState.starting);
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('a slow drag is replayed in at most maxDragReplay, and Home '
        'says when the phone did not take it', (tester) async {
      mockScreen(tester, phone: false);
      var now = DateTime(2026);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), now: () => now));
      c.screen.frameSize.value = const Size(1320, 2868);
      const box = Size(100, 200);
      c.onPointerDown(const Offset(50, 150), box);
      c.onPointerMove(const Offset(50, 100));
      now = now.add(const Duration(milliseconds: 1500));
      await c.onPointerUp(const Offset(50, 50));
      expect(touch.sent.single, endsWith(
          '${IphoneRemoteController.maxDragReplay.toStringAsFixed(2)} hold 0.00'));

      // Home is pressed only while the link is up (and after the drag has
      // played on the phone: one record at a time).
      now = now.add(const Duration(seconds: 1));
      await c.onHome();
      expect(touch.sent.where((l) => l == 'home'), isEmpty);
      touch.state.value = IosTouchState.ready;
      await c.onHome();
      expect(c.homeFailed.value, isFalse);
      touch.homeWorks = false;
      await c.onHome();
      expect(c.homeFailed.value, isTrue);
      expect(touch.sent.where((l) => l == 'home'), hasLength(2));
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('a page closed while its capture starts opens no touch link',
        (tester) async {
      mockScreen(tester);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      await tester.pump();
      Get.delete<IphoneRemoteController>();
      starting.complete({'id': 'cam-1'});
      await tester.pump();
      expect(touch.connects, 0);
      expect(calls, contains('stop'));
    });

    testWidgets('an Attached after the first frame connects within one '
        'event-loop turn, with no tick; one connect per Attached',
        (tester) async {
      mockScreen(tester, phone: false);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      expect(touch.watching, isTrue);
      await tester.pump(); // the first start, with no phone, is over
      c.screen.frameSize.value = const Size(1320, 2868);
      expect(touch.connects, 0, reason: 'no Attached heard yet');

      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      await tester.pump();
      expect(touch.connects, 1);
      // Replugged: gone, back.
      touch.onUsbmuxEvent(_detached(7));
      touch.onUsbmuxEvent(_attached(12, 'UDID-1'));
      await tester.pump();
      expect(touch.connects, 2);
      // A rotation is no first frame.
      c.screen.frameSize.value = const Size(2868, 1320);
      await tester.pump();
      expect(touch.connects, 2);
      Get.delete<IphoneRemoteController>();
      expect(touch.watching, isFalse);
    });

    testWidgets('an Attached before the first frame connects only when the '
        'frame comes, once', (tester) async {
      mockScreen(tester, phone: false);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      await tester.pump();
      expect(touch.connects, 0, reason: 'the capture may still take the '
          'phone off usbmuxd');
      c.screen.frameSize.value = const Size(1320, 2868);
      await tester.pump();
      expect(touch.connects, 1);
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('the capture is allowed before the first listing; a fresh '
        'allow lists again soon; the pairing is written down once touches '
        'connect', (tester) async {
      final calls = <MethodCall>[];
      var listed = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        calls.add(call);
        return switch (call.method) {
          'prepare' => true,
          'listDevices' => [
              if (++listed >= 3) {'id': 'cam-1', 'name': 'iPhone'},
            ],
          'start' => {'id': 'cam-1'},
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch
        ..connectWorks = true;
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      await tester.pump();
      List<String> names() => [for (final m in calls) m.method];
      expect(names().take(2), ['prepare', 'listDevices']);
      await tester.pump(IphoneRemoteController.quickRelist);
      await tester.pump(IphoneRemoteController.quickRelist);
      await tester.pump();
      expect(names().where((m) => m == 'listDevices'), hasLength(3));
      expect(names(), contains('start'));
      expect(c.screenState.value, IphoneScreenState.live);

      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      c.screen.frameSize.value = const Size(1320, 2868);
      await tester.pump();
      expect(touch.connects, 1);
      final note = calls.where((m) => m.method == 'notePairing').single;
      expect((note.arguments as Map)['udid'], 'UDID-1');
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('two capture devices refuse touches', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async => switch (call.method) {
                'listDevices' => [
                    {'id': 'cam-1', 'name': 'iPhone'},
                    {'id': 'cam-2', 'name': 'iPad'},
                  ],
                'start' => {'id': 'cam-1'},
                _ => null,
              });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      await tester.pump();
      expect(touch.state.value, IosTouchState.severalDevices);
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('with Shift a press is sent once let go: held as long as it '
        'was, then dragged; a plain drag is replayed in maxDragReplay',
        (tester) async {
      mockScreen(tester, phone: false);
      var now = DateTime(2026);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), now: () => now));
      c.screen.frameSize.value = const Size(1320, 2868);
      const box = Size(100, 200);

      c.onPointerDown(const Offset(50, 100), box, shift: true);
      now = now.add(const Duration(milliseconds: 1200));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(touch.sent, isEmpty, reason: 'nothing before it ends');
      c.onPointerMove(const Offset(50, 20));
      now = now.add(const Duration(milliseconds: 400));
      await c.onPointerUp(const Offset(50, 20));
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.10 0.40 hold 1.20']);

      touch.sent.clear();
      c.onPointerDown(const Offset(50, 100), box, shift: true);
      now = now.add(const Duration(milliseconds: 2500));
      await tester.pump(const Duration(milliseconds: 2500));
      await c.onPointerUp(const Offset(50, 100));
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.50 2.50 hold 0.00']);

      touch.sent.clear();
      c.onPointerDown(const Offset(10, 10), box);
      c.onPointerMove(const Offset(20, 20));
      now = now.add(const Duration(milliseconds: 2500));
      await tester.pump(const Duration(milliseconds: 2500));
      await c.onPointerUp(const Offset(90, 190));
      expect(touch.sent, ['swipe 0.10 0.05 0.90 0.95 0.30 hold 0.00'],
          reason: 'a slow drag is replayed in maxDragReplay, so it lands '
              'soon after it is let go; it never became a long press');
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('a landscape tap is mapped by the cached side: no orient '
        'before it, one after it, so a topRight answer flips the next tap',
        (tester) async {
      mockScreen(tester, phone: false);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      touch.state.value = IosTouchState.ready;
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
      c.screen.frameSize.value = const Size(2868, 1320);
      expect(touch.trace, ['orient'], reason: 'the rotation asked once');
      const box = Size(400, 200);

      Future<void> tap() async {
        c.onPointerDown(const Offset(100, 50), box);
        await c.onPointerUp(const Offset(100, 50));
      }

      await tap();
      expect(touch.trace, ['orient', 'tap', 'orient'],
          reason: 'nothing asked on the tap\'s way; refreshed after it');
      // The phone is flipped to the other landscape side: same frame size.
      touch.turned = IosTurn.topRight;
      await tap();
      await tap();
      expect(touch.sent, ['tap 0.75 0.25', 'tap 0.75 0.25', 'tap 0.25 0.75'],
          reason: 'the first tap after a flip may go to the old side; the '
              'refresh after it puts the next one right');
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('a frame-size change asks the side exactly once; a portrait '
        'frame and a link not up ask nothing', (tester) async {
      mockScreen(tester, phone: false);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));

      c.screen.frameSize.value = const Size(2868, 1320);
      expect(touch.orients, 0, reason: 'no runner: connecting asks by itself');
      touch.state.value = IosTouchState.ready;
      c.screen.frameSize.value = const Size(1320, 2868);
      c.onPointerDown(const Offset(10, 10), const Size(100, 200));
      await c.onPointerUp(const Offset(10, 10));
      expect(touch.orients, 0, reason: 'a portrait frame maps without it');
      c.screen.frameSize.value = const Size(2868, 1320);
      expect(touch.orients, 1);
      c.screen.frameSize.value = const Size(2868, 1320);
      expect(touch.orients, 1, reason: 'the same size is no change');
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('no orient goes out between a drag\'s start and its command; '
        'one held back meanwhile is sent after it', (tester) async {
      mockScreen(tester, phone: false);
      var now = DateTime(2026);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      touch.state.value = IosTouchState.ready;
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), now: () => now));
      c.screen.frameSize.value = const Size(1320, 2868);
      const box = Size(400, 200);

      c.onPointerDown(const Offset(10, 10), box);
      c.onPointerMove(const Offset(100, 50));
      // The phone turns mid-drag.
      c.screen.frameSize.value = const Size(2868, 1320);
      now = now.add(const Duration(milliseconds: 200));
      await c.onPointerUp(const Offset(300, 150));
      expect(touch.trace, ['swipe', 'orient']);

      touch.trace.clear();
      c.onPointerDown(const Offset(50, 50), box, shift: true);
      now = now.add(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      c.onPointerMove(const Offset(90, 90));
      now = now.add(const Duration(milliseconds: 300));
      await c.onPointerUp(const Offset(90, 90));
      expect(touch.trace, ['swipe', 'orient'],
          reason: 'a landscape hold-then-drag refreshes once it has gone out');

      touch.trace.clear();
      c.onPointerDown(const Offset(10, 10), box);
      c.onPointerMove(const Offset(100, 100));
      await c.onPointerCancel();
      expect(touch.trace, ['orient'],
          reason: 'a cancelled drag sends nothing and holds nothing back');
      Get.delete<IphoneRemoteController>();
    });
  });

  testWidgets('live drags follow Settings when the controller is not told',
      (tester) async {
    const channel = MethodChannel(IosScreenChannel.channelName);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async => call.method == 'listDevices' ? <Map>[] : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({'iphone_live_drag': false});
    final settings = SettingsService();
    await settings.init();
    Get.put(settings);
    Get.put(IosScreenChannel());
    Get.put<IosTouchService>(_RecordingTouch());
    final c = Get.put(
        IphoneRemoteController(retryEvery: const Duration(hours: 1)));
    await tester.pump();
    expect(c.liveDragOn, isFalse);
    await settings.setIphoneLiveDrag(true);
    expect(c.liveDragOn, isTrue);
    Get.delete<IphoneRemoteController>();
  });

  test('the slop is the touch slop of the phone\'s points, scaled to the '
      'picture', () {
    const frame = Size(1320, 2868); // 440 x 956 pt
    expect(IphoneRemoteController.slopFor(const Size(440, 956), frame),
        closeTo(kTouchSlop, 1e-9));
    expect(IphoneRemoteController.slopFor(const Size(220, 478), frame),
        closeTo(kTouchSlop / 2, 1e-9));
    expect(IphoneRemoteController.slopFor(const Size(478, 220),
            const Size(2868, 1320)),
        closeTo(kTouchSlop / 2, 1e-9), reason: 'landscape: the short sides');
  });

  group('latency probe', () {
    const channel = MethodChannel(IosScreenChannel.channelName);

    Future<void> answer(WidgetTester tester, int id, double? ms) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
                MethodCall('onProbe', {'id': id, 'ms': ms})),
            (_) {});

    test('reads onProbe, and sums up the last 50 as p50 and p90', () {
      final r = ProbeResult.parse({'id': 3, 'ms': 112.5})!;
      expect((r.id, r.ms, r.gaveUp), (3, 112.5, false));
      expect(ProbeResult.parse({'id': 4, 'ms': null})!.gaveUp, isTrue);
      expect(ProbeResult.parse({'id': 5})!.gaveUp, isTrue);
      expect(ProbeResult.parse({'id': 6, 'ms': -1})!.gaveUp, isTrue);
      expect(ProbeResult.parse({'ms': 10}), isNull);
      expect(ProbeResult.parse('nope'), isNull);

      final s = ProbeSummary();
      expect((s.p50, s.p90), (null, null));
      for (var i = 10; i >= 1; i--) {
        s.add(i * 10.0);
      }
      expect((s.count, s.p50, s.p90), (10, 50.0, 90.0));
      s.add(1000);
      expect(s.p90, 100.0, reason: 'nearest rank: the 10th of 11');
      // Only the last 50 count: 60 more of 7 ms push the rest out.
      for (var i = 0; i < 60; i++) {
        s.add(7);
      }
      expect((s.count, s.p50, s.p90), (50, 7.0, 7.0));
      expect(ProbeSummary.percentile([5], 0.9), 5);
    });

    testWidgets('the channel hands each answer on, a gave-up one as null',
        (tester) async {
      final screen = IosScreenChannel();
      final got = <(int, double?)>[];
      final sub = screen.probes.listen((r) => got.add((r.id, r.ms)));
      addTearDown(sub.cancel);
      await answer(tester, 1, 120.0);
      await answer(tester, 2, null);
      await tester.pump();
      expect(got, [(1, 120.0), (2, null)]);
    });

    testWidgets('a scripted run arms each trial just before its command, '
        'swipes up and down in turn and sums up the answers', (tester) async {
      final order = <String>[];
      var nextMs = 100.0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        order.add(call.method);
        if (call.method == 'markProbe') {
          final id = (call.arguments as Map)['id'] as int;
          final ms = nextMs;
          nextMs += 10;
          // The answer comes once the command has gone out.
          Timer(const Duration(milliseconds: 5), () => answer(tester, id, ms));
          return true;
        }
        return call.method == 'listDevices' ? <Map>[] : null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      Get.put(IosScreenChannel());
      final touch =
          Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      touch.order = order;
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1),
          probeEnabled: true,
          probeSettle: Duration.zero));

      final run = c.runProbe(ProbeScript.swipe, trials: 3);
      expect(await c.runProbe(ProbeScript.tap), isNull,
          reason: 'one run at a time');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final summary = (await run)!;
      expect(summary.values, [100.0, 110.0, 120.0]);
      expect(order.where((m) => m == 'markProbe' || m == 'swipe'),
          ['markProbe', 'swipe', 'markProbe', 'swipe', 'markProbe', 'swipe']);
      expect(touch.sent, [
        'swipe 0.50 0.57 0.50 0.42 0.20 hold 0.00',
        'swipe 0.50 0.42 0.50 0.57 0.20 hold 0.00',
        'swipe 0.50 0.57 0.50 0.42 0.20 hold 0.00',
      ]);
      expect(c.scripting.value, isFalse);
      expect(c.felt.count, 0, reason: 'scripted trials are not felt ones');
      Get.delete<IphoneRemoteController>();
    });

    testWidgets('with the probe off the controller arms nothing',
        (tester) async {
      final order = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        order.add(call.method);
        return call.method == 'listDevices' ? <Map>[] : null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      Get.put(IosScreenChannel());
      Get.put<IosTouchService>(_RecordingTouch());
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), probeEnabled: false));
      c.onPointerDown(const Offset(1, 1), const Size(10, 10));
      expect(await c.runProbe(ProbeScript.tap), isNull);
      await tester.pump();
      expect(order, isNot(contains('markProbe')));
      Get.delete<IphoneRemoteController>();
    });
  });

  group('per-device capture', () {
    const channel = MethodChannel(IosScreenChannel.channelName);

    Future<void> send(WidgetTester tester, String method, Object? args) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec()
                .encodeMethodCall(MethodCall(method, args)),
            (_) {});

    /// The plugin's side: each start answers the device it took (the first
    /// listed one when none was asked for).
    List<MethodCall> mockPlugin(WidgetTester tester,
        {List<String> devices = const ['cam-1', 'cam-2'],
        Completer<void>? holdStart}) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        calls.add(call);
        switch (call.method) {
          case 'listDevices':
            return [
              for (final d in devices) {'id': d, 'name': 'iPhone $d'},
            ];
          case 'start':
            await holdStart?.future;
            final id = (call.arguments as Map)['id'] ?? devices.first;
            return {'id': id};
          case 'markProbe':
            return true;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      return calls;
    }

    testWidgets('every call names its device; a start for another device '
        'stops nothing, and stop ends only the one named', (tester) async {
      final calls = mockPlugin(tester);
      final screen = IosScreenChannel();
      await screen.start('cam-1');
      await screen.start('cam-2');
      expect([for (final c in calls) c.method], ['start', 'start']);
      expect([for (final c in calls) c.arguments], [
        {'id': 'cam-1'},
        {'id': 'cam-2'},
      ]);
      expect((screen.isRunning('cam-1'), screen.isRunning('cam-2')),
          (true, true));
      expect(screen.current, 'cam-2');

      calls.clear();
      await screen.stop('cam-1');
      expect([for (final c in calls) c.method], ['stop']);
      expect(calls.single.arguments, {'id': 'cam-1'});
      expect((screen.isRunning('cam-1'), screen.isRunning('cam-2')),
          (false, true));
      expect(screen.current, 'cam-2',
          reason: 'the device shown is not the one stopped');
      await screen.stop();
      expect(calls.last.arguments, isEmpty, reason: 'no id: every capture');
      expect(screen.isRunning('cam-2'), isFalse);
      expect(screen.current, isNull);
    });

    testWidgets('a stop and a start of one device back to back reach the '
        'plugin in that order', (tester) async {
      final calls = mockPlugin(tester);
      final screen = IosScreenChannel();
      await screen.start('cam-1');
      calls.clear();
      // The window closed and reopened at once.
      await Future.wait([screen.stop('cam-1'), screen.start('cam-1')]);
      expect([for (final c in calls) c.method], ['stop', 'start']);
      expect([for (final c in calls) c.arguments], [
        {'id': 'cam-1'},
        {'id': 'cam-1'},
      ]);
    });

    test('Swift starts and stops every session of one device on that '
        "device's own queue, which outlives each capture", () {
      // The native half of the order above: a capture's sample-buffer
      // queue is new each time, so a session started there could overlap
      // the stop of the session it replaced (same device, other queue).
      final swift = File('macos/Runner/IosScreenPlugin.swift')
          .readAsStringSync();
      final running = RegExp(r'(\w+)\.async \{ session\.(start|stop)Running\(\) \}')
          .allMatches(swift)
          .map((m) => (m[1], m[2]))
          .toList();
      expect(running, [('sessionQueue', 'start'), ('sessionQueue', 'stop')]);
      expect(
          RegExp(r'sessionQueue = Self\.sessionQueue\(for: device\.uniqueID\)')
              .hasMatch(swift),
          isTrue);
      expect(
          RegExp(r'private static var sessionQueues: \[String: DispatchQueue\]')
              .hasMatch(swift),
          isTrue,
          reason: 'one queue per device, kept for the run');
      expect(swift, isNot(contains('sessionQueues.removeValue')));
      expect(RegExp(r'(start|stop)Running\(\)').allMatches(swift).length,
          running.length,
          reason: 'no session started or stopped anywhere else');
    });

    testWidgets('a callback for another device is ignored', (tester) async {
      mockPlugin(tester);
      final screen = IosScreenChannel();
      await screen.start('cam-1');
      expect(screen.current, 'cam-1');

      // A device this channel never started.
      await send(tester, 'onFrameSize', {'id': 'cam-9', 'width': 1, 'height': 2});
      await send(tester, 'onStopped', {'id': 'cam-9'});
      expect(screen.frameSize.value, isNull);
      expect(screen.frameSizes, isEmpty);
      expect((screen.current, screen.isRunning('cam-9')), ('cam-1', false));

      await send(tester, 'onFrameSize',
          {'id': 'cam-1', 'width': 1320, 'height': 2868});
      expect(screen.frameSize.value, const Size(1320, 2868));

      // Another device started since: its callbacks are its own, and the
      // first one's leave the shown device alone.
      await screen.start('cam-2');
      expect((screen.current, screen.frameSize.value), ('cam-2', null));
      await send(tester, 'onFrameSize',
          {'id': 'cam-1', 'width': 2868, 'height': 1320});
      await send(tester, 'onStopped', {'id': 'cam-1'});
      expect((screen.current, screen.frameSize.value), ('cam-2', null));
      expect((screen.isRunning('cam-1'), screen.isRunning('cam-2')),
          (false, true));
      await send(tester, 'onFrameSize',
          {'id': 'cam-2', 'width': 1206, 'height': 2622});
      expect(screen.frameSize.value, const Size(1206, 2622));
      await send(tester, 'onStopped', {'id': 'cam-2'});
      expect((screen.current, screen.frameSize.value), (null, null));
    });

    testWidgets('a start with no device takes the one the plugin answers; '
        'its first frame size is kept even when it comes before the answer',
        (tester) async {
      final hold = Completer<void>();
      mockPlugin(tester, holdStart: hold);
      final screen = IosScreenChannel();
      final started = screen.start(null);
      await tester.pump();
      await send(tester, 'onFrameSize',
          {'id': 'cam-1', 'width': 1320, 'height': 2868});
      hold.complete();
      await started;
      expect(
          (screen.current, screen.isRunning('cam-1'), screen.frameSize.value),
          ('cam-1', true, const Size(1320, 2868)));
    });

    testWidgets('a start that fails leaves the device shown as it was',
        (tester) async {
      mockPlugin(tester);
      final screen = IosScreenChannel();
      await screen.start('cam-1');
      await send(tester, 'onFrameSize',
          {'id': 'cam-1', 'width': 1320, 'height': 2868});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async => throw PlatformException(code: 'START_FAILED'));
      for (final id in ['cam-2', 'cam-1']) {
        await expectLater(screen.start(id), throwsA(isA<PlatformException>()));
        expect(
            (screen.current, screen.isRunning('cam-1'), screen.frameSize.value),
            ('cam-1', true, const Size(1320, 2868)),
            reason: id);
      }
      expect(screen.isRunning('cam-2'), isFalse);
    });

    testWidgets('markProbe sends the device, the probe id and t0Us when given',
        (tester) async {
      final calls = mockPlugin(tester);
      final screen = IosScreenChannel();
      expect(await screen.markProbe(4, device: 'cam-1', t0Us: 123456789),
          isTrue);
      await screen.markProbe(5, device: 'cam-2');
      await screen.markProbe(6);
      expect([for (final c in calls) c.arguments], [
        {'device': 'cam-1', 'id': 4, 't0Us': 123456789},
        {'device': 'cam-2', 'id': 5},
        {'id': 6},
      ]);

      final got = <(String?, int, double?)>[];
      final sub = screen.probes.listen((r) => got.add((r.device, r.id, r.ms)));
      addTearDown(sub.cancel);
      await send(tester, 'onProbe', {'device': 'cam-1', 'id': 4, 'ms': 90.5});
      await tester.pump();
      expect(got, [('cam-1', 4, 90.5)]);
    });

    testWidgets('the page probes, notes and stops only its own device, and '
        'takes no other device\'s probe answer', (tester) async {
      final calls = mockPlugin(tester, devices: ['cam-1']);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch
        ..connectWorks = true;
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1),
          deviceId: 'cam-1',
          probeEnabled: true));
      await tester.pump();
      await tester.pump();
      expect(c.screen.isRunning('cam-1'), isTrue);
      await send(tester, 'onFrameSize',
          {'id': 'cam-1', 'width': 1320, 'height': 2868});
      touch.onUsbmuxEvent(_attached(7, 'UDID-1'));
      await tester.pump();
      final note = calls.where((m) => m.method == 'notePairing').single;
      expect(note.arguments, {'udid': 'UDID-1', 'device': 'cam-1'});

      c.onPointerDown(const Offset(50, 50), const Size(100, 200));
      await tester.pump();
      final mark = calls.where((m) => m.method == 'markProbe').single;
      expect(mark.arguments, {'device': 'cam-1', 'id': 1});
      await c.onPointerUp(const Offset(50, 50));

      // The same probe number, from another device's capture.
      await send(tester, 'onProbe', {'device': 'cam-2', 'id': 1, 'ms': 5.0});
      await tester.pump();
      expect(c.felt.count, 0);
      await send(tester, 'onProbe', {'device': 'cam-1', 'id': 1, 'ms': 80.0});
      await tester.pump();
      expect((c.felt.count, c.lastFeltMs.value), (1, 80.0));

      await Get.delete<IphoneRemoteController>();
      await tester.pump();
      final stops = calls.where((m) => m.method == 'stop');
      expect([for (final s in stops) s.arguments], [
        {'id': 'cam-1'},
      ]);
    });
  });

  // ---- The native window (plan unit 5) ------------------------------------
  //
  // The "pointer on the picture" group again, with the pointer coming as
  // the native window's packets (`extended_screen/remote_window_input`)
  // into IphoneRemoteWindow, which drives the same controller: every result
  // must be the same as on the route.
  group('pointer in the native window', () {
    const screenChannel = MethodChannel(IosScreenChannel.channelName);
    const windowChannel = MethodChannel(RemoteWindowChannel.channelName);

    /// The picture box on the Mac, in points (a portrait phone's shape).
    const box = Size(440, 956);

    late List<MethodCall> screenCalls;
    late List<MethodCall> windowCalls;

    /// The phone's window opened through the channel, as Home opens it, its
    /// controller on the test's fake clock, touches recorded on that clock,
    /// the picture [frame] already up.
    Future<(IphoneRemoteWindow, _RecordingTouch, RemoteWindowChannel)> open(
        WidgetTester tester,
        {bool liveFinger = false,
        String? caps,
        bool? liveDrag,
        bool probe = false,
        Duration probeSettle = const Duration(milliseconds: 800),
        void Function(MethodCall call)? onMark,
        Size frame = const Size(1320, 2868)}) async {
      screenCalls = [];
      windowCalls = [];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        screenCalls.add(call);
        if (call.method == 'markProbe') onMark?.call(call);
        return switch (call.method) {
          'listDevices' => [
              {'id': 'cam-1', 'name': 'iPhone'},
            ],
          'start' => {'id': 'cam-1'},
          'markProbe' => true,
          _ => null,
        };
      });
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call);
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(screenChannel, null);
        messenger.setMockMethodCallHandler(windowChannel, null);
      });
      final screen = Get.put(IosScreenChannel());
      final touch =
          Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      DateTime now() => tester.binding.clock.now();
      touch.now = now;
      if (caps != null) touch.caps.value = RunnerCaps.parse(caps);
      final windows = RemoteWindowChannel();
      final driver = IphoneRemoteWindow('cam-1',
          title: 'iPhone',
          create: (id) => IphoneRemoteController(
              deviceId: id,
              retryEvery: const Duration(hours: 1),
              now: now,
              probeEnabled: probe,
              probeSettle: probeSettle,
              liveFinger: liveFinger,
              liveDrag: liveDrag));
      expect(await windows.openDriver(driver), isTrue);
      await tester.pump();
      screen.frameSize.value = frame;
      await tester.pump();
      return (driver, touch, windows);
    }

    /// A packet from the window, at ([nx], [ny]) of the picture box.
    Future<void> send(WidgetTester tester, RemotePointerKind kind,
        double nx, double ny,
        {bool shift = false, String id = 'cam-1', int eventUs = 0}) {
      final p = RemotePointer(
          id: id,
          kind: kind,
          x: box.width * nx,
          y: box.height * ny,
          boxW: box.width,
          boxH: box.height,
          shift: shift,
          eventUs: eventUs);
      return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          RemoteWindowChannel.inputChannelName, p.encode(), (_) {});
    }

    Future<void> down(WidgetTester t, double x, double y, {bool shift = false}) =>
        send(t, RemotePointerKind.down, x, y, shift: shift);
    Future<void> move(WidgetTester t, double x, double y) =>
        send(t, RemotePointerKind.move, x, y);
    Future<void> up(WidgetTester t, double x, double y) =>
        send(t, RemotePointerKind.up, x, y);

    /// A click: down and up at once.
    Future<void> click(WidgetTester t, double x, double y) async {
      await down(t, x, y);
      await up(t, x, y);
    }

    /// Swift → Dart on the window's method channel, with the open's token.
    Future<void> fromWindow(WidgetTester tester, String method,
        Map<String, Object?> args) {
      final token = windowCalls
          .lastWhere((c) => c.method == 'open')
          .arguments['token'];
      return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          windowChannel.name,
          const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, {'id': 'cam-1', 'token': token, ...args})),
          (_) {});
    }

    Future<void> done(WidgetTester tester, RemoteWindowChannel w) async {
      await w.close('cam-1');
      await tester.pump();
    }

    /// A drag from [a] to [b] (normalized) in 16 ms steps over [total], left
    /// down; with the fake-clock time it passed the slop, and the last point.
    Future<(Offset, DateTime?)> dragHeld(
        WidgetTester tester, Offset a, Offset b, Duration total) async {
      final slop = IphoneRemoteController.slopFor(
          box, Get.find<IosScreenChannel>().frameSize.value!);
      await down(tester, a.dx, a.dy);
      final steps = (total.inMilliseconds / 16).round();
      DateTime? crossed;
      var p = a;
      for (var i = 1; i <= steps; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        p = Offset.lerp(a, b, i / steps)!;
        await move(tester, p.dx, p.dy);
        final moved = Offset((p.dx - a.dx) * box.width,
            (p.dy - a.dy) * box.height);
        if (crossed == null && moved.distance > slop) {
          crossed = tester.binding.clock.now();
        }
      }
      return (p, crossed);
    }

    /// Lets go at [p] and lets every segment in flight play out.
    Future<void> letGo(WidgetTester tester, Offset p) async {
      await up(tester, p.dx, p.dy);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    const allCaps = 'caps ping tap atap swipe aswipe home orient switcher '
        'spotlight control notifications';

    test('a packet reads back as it was written; a short or bad one is '
        'none', () {
      const p = RemotePointer(
          id: 'cam-é',
          kind: RemotePointerKind.move,
          x: 12.5,
          y: 900.25,
          boxW: 440,
          boxH: 956,
          shift: true,
          eventUs: 123456789012);
      final q = RemotePointer.decode(p.encode())!;
      expect((q.id, q.kind, q.x, q.y, q.boxW, q.boxH, q.shift, q.eventUs),
          ('cam-é', RemotePointerKind.move, 12.5, 900.25, 440.0, 956.0, true,
              123456789012));
      final bytes = p.encode().buffer.asUint8List();
      expect(RemotePointer.decode(null), isNull);
      expect(
          RemotePointer.decode(
              ByteData.sublistView(bytes, 0, bytes.length - 1)),
          isNull);
      final badKind = Uint8List.fromList(bytes)..[0] = 9;
      expect(RemotePointer.decode(ByteData.sublistView(badKind)), isNull);
      const empty = RemotePointer(
          id: 'x', kind: RemotePointerKind.down, x: 1, y: 1, boxW: 0, boxH: 9);
      expect(RemotePointer.decode(empty.encode()), isNull);
    });

    testWidgets('the window opens with its shortcuts, the controller under '
        'the device id, and a window capture', (tester) async {
      final (driver, _, w) = await open(tester);
      final opened = windowCalls.singleWhere((c) => c.method == 'open');
      expect(opened.arguments['shortcuts'], {
        '1': 'home',
        '2': 'system:0',
        '3': 'system:1',
        '4': 'system:2',
        '5': 'system:3',
      });
      expect(Get.isRegistered<IphoneRemoteController>(tag: 'cam-1'), isTrue);
      expect(driver.controller, isNotNull);
      expect(
          screenCalls.where((c) => c.method == 'start').map((c) => c.arguments),
          [
            {'id': 'cam-1'}
          ]);
      // A capture that runs is not started again by the tick.
      await tester.pump(const Duration(hours: 2));
      expect(screenCalls.where((c) => c.method == 'start'), hasLength(1));
      // A second open of the same phone focuses its window.
      expect(await w.openDriver(IphoneRemoteWindow('cam-1')), isTrue);
      expect(
          windowCalls.map((c) => c.method).where((m) => m != 'render'),
          ['open', 'focus']);
      await done(tester, w);
    });

    testWidgets('Cmd-1 to Cmd-5 (action items) send home, switcher, '
        'spotlight, control and notifications', (tester) async {
      final (_, touch, w) = await open(tester, caps: allCaps);
      touch.state.value = IosTouchState.ready;
      for (final item in [
        'home', 'system:0', 'system:1', 'system:2', 'system:3',
      ]) {
        await fromWindow(tester, 'action', {'item': item});
        await tester.pump();
      }
      expect(touch.sent,
          ['home', 'switcher', 'spotlight', 'control', 'notifications']);
      // Items it does not know, or another window's, send nothing.
      await fromWindow(tester, 'action', {'item': 'system:9'});
      await fromWindow(tester, 'action', {'item': 'nope'});
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          windowChannel.name,
          const StandardMethodCodec().encodeMethodCall(const MethodCall(
              'action', {'id': 'cam-1', 'token': -1, 'item': 'home'})),
          (_) {});
      await tester.pump();
      expect(touch.sent, hasLength(5));
      await done(tester, w);
    });

    testWidgets('a verb missing from the caps sends nothing for its item; '
        'with the link down, nothing at all', (tester) async {
      final (_, touch, w) = await open(tester,
          caps: 'caps ping tap atap swipe aswipe orient switcher');
      touch.state.value = IosTouchState.ready;
      for (final item in ['home', 'system:0', 'system:1', 'system:2',
          'system:3']) {
        await fromWindow(tester, 'action', {'item': item});
        await tester.pump();
      }
      expect(touch.sent, ['switcher']);
      touch.state.value = IosTouchState.reconnecting;
      touch.sent.clear();
      await fromWindow(tester, 'action', {'item': 'system:0'});
      await tester.pump();
      expect(touch.sent, isEmpty);
      await done(tester, w);
    });

    testWidgets('a held shortcut sends its gesture once; a press while one '
        'still runs sends nothing', (tester) async {
      final (_, touch, w) = await open(tester, caps: allCaps);
      touch.state.value = IosTouchState.ready;
      touch.systemDelay = const Duration(milliseconds: 1500);
      for (final item in ['system:1', 'system:1', 'home', 'system:1']) {
        await fromWindow(tester, 'action', {'item': item});
      }
      await tester.pump();
      expect(touch.sent, ['spotlight']);
      await tester.pump(const Duration(seconds: 2));
      await fromWindow(tester, 'action', {'item': 'system:1'});
      await tester.pump();
      expect(touch.sent, ['spotlight', 'spotlight'],
          reason: 'once answered, the next one goes');
      await tester.pump(const Duration(seconds: 2));
      await done(tester, w);
    });

    testWidgets('a click that jitters 3 px is one tap where it went down',
        (tester) async {
      final (_, touch, w) = await open(tester);
      await down(tester, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 40));
      await move(tester, 0.5 + 3 / box.width, 0.5);
      await tester.pump(const Duration(milliseconds: 40));
      await move(tester, 0.5 + 3 / box.width, 0.5 - 2 / box.height);
      await tester.pump(const Duration(milliseconds: 40));
      expect(touch.sent, isEmpty, reason: 'a tap goes out at pointer-up');
      await up(tester, 0.5 + 3 / box.width, 0.5 - 2 / box.height);
      await tester.pump();
      expect(touch.sent, ['tap 0.50 0.50']);
      await done(tester, w);
    });

    testWidgets('a still press sends one 0.7 s hold at 350 ms, while held, '
        'and nothing for moving it or letting it go', (tester) async {
      final (_, touch, w) = await open(tester);
      await down(tester, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 340));
      expect(touch.sent, isEmpty);
      await tester.pump(const Duration(milliseconds: 20));
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.50 0.70 hold 0.00']);
      await move(tester, 0.5, 0.2);
      await tester.pump(const Duration(milliseconds: 240));
      await up(tester, 0.5, 0.2);
      await tester.pump();
      expect(touch.sent, hasLength(1));
      expect(touch.overlaps, 0);
      await done(tester, w);
    });

    testWidgets('a click while the hold still plays waits for it: no second '
        'record behind a playing one', (tester) async {
      final (_, touch, w) = await open(tester);
      await down(tester, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 600));
      await up(tester, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 50));
      await click(tester, 0.25, 0.25);
      await tester.pump(const Duration(milliseconds: 100));
      expect(touch.sent, hasLength(1), reason: 'the hold plays until 1050 ms');
      await tester.pump(const Duration(milliseconds: 400));
      expect(touch.sent.last, 'tap 0.25 0.25');
      expect(touch.overlaps, 0);
      await done(tester, w);
    });

    testWidgets('with Shift, a 1 s hold then a drag is one hold-then-drag '
        'record at release', (tester) async {
      final (_, touch, w) = await open(tester);
      await down(tester, 0.5, 0.5, shift: true);
      await tester.pump(const Duration(seconds: 1));
      expect(touch.sent, isEmpty, reason: 'nothing goes out early with Shift');
      await move(tester, 0.5, 0.3);
      await tester.pump(const Duration(milliseconds: 200));
      await move(tester, 0.5, 0.1);
      await tester.pump(const Duration(milliseconds: 200));
      await up(tester, 0.5, 0.1);
      await tester.pump();
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.10 0.40 hold 1.00']);
      await done(tester, w);
    });

    testWidgets('a drag past the slop is a drag, never a long press',
        (tester) async {
      final (_, touch, w) = await open(tester);
      await down(tester, 0.5, 0.8);
      await tester.pump(const Duration(milliseconds: 50));
      await move(tester, 0.5, 0.6);
      await tester.pump(const Duration(milliseconds: 500));
      await move(tester, 0.5, 0.2);
      await tester.pump(const Duration(milliseconds: 50));
      expect(touch.sent, isEmpty);
      await up(tester, 0.5, 0.2);
      await tester.pump();
      expect(touch.sent, ['swipe 0.50 0.80 0.50 0.20 0.30 hold 0.00']);
      await done(tester, w);
    });

    testWidgets('a pointer cancelled mid-gesture sends nothing',
        (tester) async {
      final (_, touch, w) = await open(tester);
      await down(tester, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 100));
      await move(tester, 0.5, 0.2);
      await send(tester, RemotePointerKind.cancel, 0, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(touch.sent, isEmpty);
      await done(tester, w);
    });

    testWidgets('E1 mode: the finger goes down at pointer-down, moves, and '
        'is lifted at pointer-up or cancel', (tester) async {
      final (_, touch, w) = await open(tester, liveFinger: true);
      await down(tester, 0.5, 0.5);
      await tester.pump();
      expect(touch.sent, ['pdown 0.50 0.50']);
      await tester.pump(const Duration(milliseconds: 500));
      expect(touch.sent, hasLength(1));
      await move(tester, 0.5, 0.2);
      await tester.pump();
      await up(tester, 0.5, 0.2);
      await tester.pump();
      expect(touch.sent,
          ['pdown 0.50 0.50', 'pmove 0.50 0.20', 'pup 0.50 0.20']);

      touch.sent.clear();
      await down(tester, 0.25, 0.25);
      await tester.pump();
      await send(tester, RemotePointerKind.cancel, 0, 0);
      await tester.pump();
      expect(touch.sent, ['pdown 0.25 0.25', 'pup 0.25 0.25']);
      await done(tester, w);
    });

    testWidgets('E1 mode with a runner that refuses pdown: that press is sent '
        'as a whole record, and the next ones never try again',
        (tester) async {
      final (_, touch, w) = await open(tester, liveFinger: true);
      touch.fingerWorks = false;
      await click(tester, 0.5, 0.5);
      await tester.pump();
      expect(touch.sent, ['pdown 0.50 0.50', 'tap 0.50 0.50']);
      touch.sent.clear();
      await down(tester, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 400));
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.50 0.70 hold 0.00']);
      await up(tester, 0.5, 0.5);
      await tester.pump(const Duration(seconds: 1));
      await done(tester, w);
    });

    const segCaps = 'caps ping caps tap atap swipe aswipe home orient seg';

    testWidgets('a 600 ms drag streams: the first segment within 120 ms of '
        'the slop, one at a time, the last one with no settle',
        (tester) async {
      final (_, touch, w) = await open(tester, caps: segCaps);
      final (end, crossed) = await dragHeld(tester, const Offset(0.5, 0.8),
          const Offset(0.5, 0.2), const Duration(milliseconds: 600));
      expect(touch.segs, isNotEmpty, reason: 'segments go out while held');
      expect(touch.segs.first.at!.difference(crossed!),
          lessThanOrEqualTo(const Duration(milliseconds: 120)));
      await letGo(tester, end);
      final segs = touch.segs;
      expect(segs.length, greaterThanOrEqualTo(3));
      expect(segs.map((s) => s.outstanding), everyElement(1));
      for (var i = 1; i < segs.length; i++) {
        final prev = segs[i - 1];
        expect(segs[i].at!.difference(prev.at!).inMicroseconds,
            greaterThanOrEqualTo(((prev.seconds + prev.settle) * 1e6).round()));
        expect(segs[i].x1, prev.x2);
        expect(segs[i].y1, prev.y2);
      }
      expect(segs.first.y1, closeTo(0.8, 0.01));
      expect(segs.last.y2, closeTo(0.2, 0.01));
      expect(segs.last.settle, 0);
      expect(segs.take(segs.length - 1).map((s) => s.settle),
          everyElement(IphoneRemoteController.segSettle));
      expect(segs.map((s) => s.lead),
          everyElement(IphoneRemoteController.segLead));
      expect(touch.sent.where((l) => l.startsWith('swipe')), isEmpty);
      await done(tester, w);
    });

    testWidgets('movement under 15 pt is merged into the next segment, not '
        'sent', (tester) async {
      final (_, touch, w) = await open(tester, caps: segCaps);
      const pt = 1 / 956;
      await dragHeld(tester, const Offset(0.5, 0.5),
          const Offset(0.5, 0.5 - 25 * pt), const Duration(milliseconds: 48));
      await tester.pump(const Duration(milliseconds: 300));
      expect(touch.segs, hasLength(1));
      await move(tester, 0.5, 0.5 - 35 * pt);
      await tester.pump(const Duration(milliseconds: 300));
      expect(touch.segs, hasLength(1), reason: '10 pt: merged');
      await move(tester, 0.5, 0.5 - 45 * pt);
      await tester.pump();
      expect(touch.segs, hasLength(2));
      expect((touch.segs[1].y1 - touch.segs[1].y2) / pt, closeTo(20, 1.5));
      await tester.pump(const Duration(milliseconds: 300));
      await letGo(tester, const Offset(0.5, 0.5 - 45 * pt));
      expect(touch.segs, hasLength(2));
      expect(touch.segs.last.settle, IphoneRemoteController.segSettle);
      await done(tester, w);
    });

    testWidgets('a 60 ms flick is one aswipe at release, as before',
        (tester) async {
      final (_, touch, w) = await open(tester, caps: segCaps);
      final (end, _) = await dragHeld(tester, const Offset(0.5, 0.8),
          const Offset(0.5, 0.4), const Duration(milliseconds: 64));
      await letGo(tester, end);
      expect(touch.segs, isEmpty);
      expect(touch.sent, ['swipe 0.50 0.80 0.50 0.40 0.06 hold 0.00']);
      await done(tester, w);
    });

    testWidgets('without seg in the caps, or with live drags off, a drag is '
        'one aswipe at release', (tester) async {
      for (final (caps, liveDrag) in [
        (null, null),
        ('caps ping tap atap swipe aswipe orient', null),
        (segCaps, false),
      ]) {
        final (_, touch, w) =
            await open(tester, caps: caps, liveDrag: liveDrag);
        final (end, _) = await dragHeld(tester, const Offset(0.5, 0.8),
            const Offset(0.5, 0.2), const Duration(milliseconds: 600));
        expect(touch.sent, isEmpty, reason: '$caps $liveDrag: nothing held');
        await letGo(tester, end);
        expect(touch.segs, isEmpty, reason: '$caps $liveDrag');
        expect(touch.sent, ['swipe 0.50 0.80 0.50 0.20 0.30 hold 0.00'],
            reason: '$caps $liveDrag');
        await done(tester, w);
        Get.reset();
        Get.put<LoggerService>(_QuietLogger());
      }
    });

    testWidgets('on a landscape picture every segment point is in 0..1 and '
        'in portrait', (tester) async {
      final (_, touch, w) =
          await open(tester, caps: segCaps, frame: const Size(2868, 1320));
      touch.lastTurn.value = IosTurn.topLeft;
      final (end, _) = await dragHeld(tester, const Offset(0.2, 0.5),
          const Offset(0.8, 0.5), const Duration(milliseconds: 600));
      await letGo(tester, end);
      expect(touch.segs.length, greaterThanOrEqualTo(2));
      for (final s in touch.segs) {
        for (final v in [s.x1, s.y1, s.x2, s.y2]) {
          expect(v, inInclusiveRange(0.0, 1.0));
        }
        expect(s.x1, closeTo(0.5, 0.01));
        expect(s.x2, closeTo(0.5, 0.01));
      }
      expect(touch.segs.first.y1, closeTo(0.2, 0.01));
      expect(touch.segs.last.y2, closeTo(0.8, 0.01));
      await done(tester, w);
    });

    testWidgets('no orient goes out between the first segment and the last; '
        'a rotation meanwhile is asked about after', (tester) async {
      final (_, touch, w) =
          await open(tester, caps: segCaps, frame: const Size(2868, 1320));
      touch.state.value = IosTouchState.ready;
      final screen = Get.find<IosScreenChannel>();
      await dragHeld(tester, const Offset(0.2, 0.5), const Offset(0.5, 0.5),
          const Duration(milliseconds: 300));
      expect(touch.segs, isNotEmpty);
      screen.frameSize.value = const Size(2796, 1290);
      await tester.pump();
      var last = const Offset(0.5, 0.5);
      for (var i = 1; i <= 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        last = Offset(0.5 + i * 0.03, 0.5);
        await move(tester, last.dx, last.dy);
      }
      await letGo(tester, last);
      final first = touch.trace.indexOf('seg');
      final lastSeg = touch.trace.lastIndexOf('seg');
      expect(lastSeg, greaterThan(first));
      expect(touch.trace.sublist(first, lastSeg + 1), everyElement('seg'));
      expect(touch.trace.sublist(lastSeg + 1), contains('orient'));
      await done(tester, w);
    });

    testWidgets('a segment the runner refuses ends the streaming: the rest '
        'goes as one aswipe from where it stopped', (tester) async {
      final (_, touch, w) = await open(tester, caps: segCaps);
      touch.segWorks = false;
      final (end, _) = await dragHeld(tester, const Offset(0.5, 0.8),
          const Offset(0.5, 0.2), const Duration(milliseconds: 600));
      await letGo(tester, end);
      expect(touch.segs, hasLength(1));
      expect(touch.sent.last, startsWith('swipe 0.50 0.80 0.50 0.20'));
      await done(tester, w);
    });

    testWidgets('a drag begun while the last one\'s release still waits for '
        'its last segment: never two segments out, and no orient during it',
        (tester) async {
      final (_, touch, w) =
          await open(tester, caps: segCaps, frame: const Size(2868, 1320));
      touch.state.value = IosTouchState.ready;
      touch.segReply = const Duration(milliseconds: 300);
      final (end1, _) = await dragHeld(tester, const Offset(0.2, 0.5),
          const Offset(0.5, 0.5), const Duration(milliseconds: 300));
      await up(tester, end1.dx, end1.dy);
      await tester.pump(const Duration(milliseconds: 16));
      final mark = touch.trace.length;
      final (end2, _) = await dragHeld(tester, const Offset(0.2, 0.6),
          const Offset(0.7, 0.6), const Duration(milliseconds: 600));
      await letGo(tester, end2);
      await tester.pump(const Duration(seconds: 1));
      expect(touch.segs.map((s) => s.outstanding), everyElement(1));
      final after = touch.trace.sublist(mark);
      final first = after.indexOf('seg');
      final last = after.lastIndexOf('seg');
      expect(last, greaterThan(first));
      expect(after.sublist(first, last + 1), everyElement('seg'));
      expect(after.sublist(last + 1), contains('orient'));
      await done(tester, w);
    });

    testWidgets('a tap right after a drag waits for the drag\'s last segment',
        (tester) async {
      final (_, touch, w) = await open(tester, caps: segCaps);
      touch.segReply = const Duration(milliseconds: 300);
      final (end, _) = await dragHeld(tester, const Offset(0.5, 0.8),
          const Offset(0.5, 0.4), const Duration(milliseconds: 300));
      await up(tester, end.dx, end.dy);
      await tester.pump(const Duration(milliseconds: 20));
      await click(tester, 0.25, 0.25);
      await tester.pump(const Duration(milliseconds: 20));
      expect(touch.sent.where((l) => l.startsWith('tap')), isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(touch.sent.last, 'tap 0.25 0.25');
      await done(tester, w);
    });

    testWidgets('a runner without fast synthesis gets its drags at release, '
        'even with seg in its caps', (tester) async {
      final (_, touch, w) = await open(tester, caps: segCaps);
      touch.fast = false;
      final (end, _) = await dragHeld(tester, const Offset(0.5, 0.8),
          const Offset(0.5, 0.2), const Duration(milliseconds: 600));
      await letGo(tester, end);
      expect(touch.segs, isEmpty);
      expect(touch.sent, ['swipe 0.50 0.80 0.50 0.20 0.30 hold 0.00']);
      await done(tester, w);
    });

    // ---- The window's life -------------------------------------------------

    testWidgets('closed (the red button, Cmd-W) stops the screen and the '
        'touch link, and a late packet after it is ignored', (tester) async {
      final (driver, touch, w) = await open(tester);
      touch.state.value = IosTouchState.ready;
      await fromWindow(tester, 'closed', {});
      await tester.pump();
      expect(w.isOpen('cam-1'), isFalse);
      expect(Get.isRegistered<IphoneRemoteController>(tag: 'cam-1'), isFalse);
      expect(driver.controller, isNull);
      expect(screenCalls.where((c) => c.method == 'stop').map((c) => c.arguments),
          [
            {'id': 'cam-1'}
          ]);
      expect(touch.disconnects, 1);
      expect(touch.watching, isFalse);

      await click(tester, 0.5, 0.5);
      await fromWindow(tester, 'action', {'item': 'home'});
      await tester.pump(const Duration(seconds: 1));
      expect(touch.sent, isEmpty);
    });

    testWidgets('a packet for an id with no window is ignored',
        (tester) async {
      final (_, touch, w) = await open(tester);
      await send(tester, RemotePointerKind.down, 0.5, 0.5, id: 'cam-2');
      await send(tester, RemotePointerKind.up, 0.5, 0.5, id: 'cam-2');
      // Not a packet at all.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          RemoteWindowChannel.inputChannelName,
          ByteData.sublistView(Uint8List.fromList([0, 0])),
          (_) {});
      await tester.pump(const Duration(seconds: 1));
      expect(touch.sent, isEmpty);
      await click(tester, 0.5, 0.5);
      await tester.pump();
      expect(touch.sent, ['tap 0.50 0.50'], reason: 'its own still work');
      await done(tester, w);
    });

    testWidgets('a down carries its event time to markProbe as t0Us',
        (tester) async {
      // Screen and touch calls in one list, to see what went out first.
      final order = <String>[];
      final (_, touch, w) = await open(tester,
          probe: true, onMark: (_) => order.add('markProbe'));
      touch.order = order;
      await send(tester, RemotePointerKind.down, 0.5, 0.5,
          eventUs: 987654321);
      await tester.pump();
      final mark = screenCalls.lastWhere((c) => c.method == 'markProbe');
      expect(mark.arguments, {'device': 'cam-1', 'id': 1, 't0Us': 987654321});
      expect(order, ['markProbe'],
          reason: 'the probe is armed at the down, before any touch command');
      expect(touch.sent, isEmpty);
      await up(tester, 0.5, 0.5);
      await tester.pump();
      expect(order, ['markProbe', 'tap']);
      // With no event time (0), the probe starts at the call, as before.
      await click(tester, 0.3, 0.3);
      await tester.pump();
      expect(screenCalls.lastWhere((c) => c.method == 'markProbe').arguments,
          {'device': 'cam-1', 'id': 2});
      await done(tester, w);
    });

    // ---- The probe in the window (unit 7) --------------------------------

    /// Swift's answer to probe [id] on cam-1's capture.
    Future<void> probeAnswer(WidgetTester tester, int id, double? ms) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            screenChannel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(
                'onProbe', {'device': 'cam-1', 'id': id, 'ms': ms})),
            (_) {});

    /// The last `render` payload's toolbar item [id], if any.
    Map? lastItem(String id) =>
        (((windowCalls.lastWhere((c) => c.method == 'render').arguments
                    as Map)['vm'] as Map)['toolbar'] as List)
            .cast<Map>()
            .firstWhereOrNull((i) => i['id'] == id);

    List<String>? lastOverlay() =>
        (((windowCalls.lastWhere((c) => c.method == 'render').arguments
                    as Map)['vm'] as Map)['overlay'] as List?)
            ?.cast<String>();

    testWidgets('with the probe off the window has no probe menu or overlay, '
        'and a click arms nothing', (tester) async {
      final (_, touch, w) = await open(tester);
      expect(lastItem('probe'), isNull);
      expect(lastOverlay(), isNull);
      await send(tester, RemotePointerKind.down, 0.5, 0.5, eventUs: 5000);
      await up(tester, 0.5, 0.5);
      await tester.pump();
      expect(touch.sent, hasLength(1));
      expect(screenCalls.map((c) => c.method), isNot(contains('markProbe')));
      // A menu action that names the probe does nothing either.
      await fromWindow(tester, 'action', {'item': 'probe:tap'});
      await tester.pump(const Duration(seconds: 1));
      expect(screenCalls.map((c) => c.method), isNot(contains('markProbe')));
      await done(tester, w);
    });

    testWidgets('with the probe on the window gets the probe menu first, and '
        'an answer to a click updates the overlay lines', (tester) async {
      final (driver, _, w) = await open(tester, probe: true);
      final menu = lastItem('probe')!;
      expect(
          ((((windowCalls.lastWhere((c) => c.method == 'render').arguments
                      as Map)['vm'] as Map)['toolbar'] as List)
                  .first as Map)['id'],
          'probe');
      expect((menu['kind'], menu['enabled']), ('menu', true));
      expect((menu['menu'] as List).cast<Map>().map((e) => e['id']),
          ['probe:tap', 'probe:swipe']);
      expect(lastOverlay(), hasLength(1));
      expect(lastOverlay()!.single, isNot(contains('iphone_probe_last 118')));

      await send(tester, RemotePointerKind.down, 0.5, 0.5, eventUs: 4242);
      await tester.pump();
      expect(screenCalls.lastWhere((c) => c.method == 'markProbe').arguments,
          {'device': 'cam-1', 'id': 1, 't0Us': 4242});
      await up(tester, 0.5, 0.5);
      await tester.pump();
      final before = windowCalls.where((c) => c.method == 'render').length;

      await probeAnswer(tester, 1, 118.0);
      await tester.pump();
      expect(windowCalls.where((c) => c.method == 'render').length,
          before + 1, reason: 'one render for the answer');
      expect(lastOverlay()!.first, contains('iphone_probe_last 118'));
      expect(driver.controller!.felt.count, 1);

      // An answer for another device's capture changes nothing.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          screenChannel.name,
          const StandardMethodCodec().encodeMethodCall(const MethodCall(
              'onProbe', {'device': 'cam-2', 'id': 1, 'ms': 50.0})),
          (_) {});
      await tester.pump();
      expect(driver.controller!.felt.count, 1);
      expect(lastOverlay()!.first, contains('iphone_probe_last 118'));
      await done(tester, w);
    });

    testWidgets('the probe menu\'s scripted run arms every trial with no t0, '
        'and its progress and sums reach the overlay', (tester) async {
      var nextMs = 100.0;
      late WidgetTester t;
      final (driver, touch, w) = await open(tester,
          probe: true,
          probeSettle: Duration.zero,
          onMark: (call) {
            final id = (call.arguments as Map)['id'] as int;
            final ms = nextMs;
            nextMs += 1;
            // The answer comes once the command has gone out.
            Timer(const Duration(milliseconds: 5),
                () => probeAnswer(t, id, ms));
          });
      t = tester;
      await fromWindow(tester, 'action', {'item': 'probe:tap'});
      await tester.pump(const Duration(milliseconds: 1));
      final c = driver.controller!;
      expect(c.scripting.value, isTrue);
      await tester.pump();
      expect(lastItem('probe')!['enabled'], isFalse,
          reason: 'one run at a time');
      expect(lastOverlay(), hasLength(2));
      expect(lastOverlay()!.last, startsWith('atap iphone_probe_running'));

      // A click meanwhile arms no felt probe: the run owns the capture.
      await send(tester, RemotePointerKind.down, 0.2, 0.2, eventUs: 99);
      await send(tester, RemotePointerKind.up, 0.2, 0.2);
      for (var i = 0; i < 400 && c.scripting.value; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(c.scripting.value, isFalse);
      final marks = screenCalls.where((m) => m.method == 'markProbe').toList();
      expect(marks, hasLength(IphoneRemoteController.probeTrials));
      for (final m in marks) {
        expect((m.arguments as Map).containsKey('t0Us'), isFalse);
        expect((m.arguments as Map)['device'], 'cam-1');
      }
      expect(c.script!.count, IphoneRemoteController.probeTrials);
      expect(c.felt.count, 0, reason: 'scripted trials are not felt ones');
      expect(touch.sent.where((s) => s.startsWith('tap')),
          hasLength(IphoneRemoteController.probeTrials + 1),
          reason: 'every trial, and the click');
      await tester.pump();
      expect(lastItem('probe')!['enabled'], isTrue);
      expect(lastOverlay()!.last, startsWith('atap '));
      expect(lastOverlay()!.last, isNot(contains('iphone_probe_running')));
      await done(tester, w);
    });

    // ---- The window's chrome (unit 6) -------------------------------------

    /// The `render` payloads sent so far.
    List<Map> renders() => [
          for (final c in windowCalls.where((c) => c.method == 'render'))
            (c.arguments as Map)['vm'] as Map,
        ];

    Map? itemOf(Map vm, String id) =>
        (vm['toolbar'] as List).cast<Map>().firstWhereOrNull((i) => i['id'] == id);

    testWidgets('the window gets its chrome as one render per turn, and an '
        'unchanged one is not sent again', (tester) async {
      final (driver, touch, w) = await open(tester, caps: allCaps);
      final before = renders().length;
      expect(before, greaterThan(0));
      expect(renders().last['message'], isNull, reason: 'the picture is up');
      expect((windowCalls.lastWhere((c) => c.method == 'render').arguments
          as Map)['id'], 'cam-1');

      // Several changes in one turn: one render, with all of them.
      final c = driver.controller!;
      touch.state.value = IosTouchState.ready;
      touch.dropped.value = 2;
      c.homeFailed.value = true;
      c.systemFailed.add(IphoneSystemGesture.spotlight);
      await tester.pump();
      expect(renders(), hasLength(before + 1));
      final vm = renders().last;
      expect(itemOf(vm, 'touch')!['text'], 'iphone_remote_touch_ready');
      expect(itemOf(vm, 'touch')!['color'], 'green');
      expect(itemOf(vm, 'touch')!['tooltip'], 'iphone_touch_dropped');
      expect(itemOf(vm, 'home')!['tint'], 'warn');
      expect(itemOf(vm, 'system:1')!['tint'], 'warn');

      // Nothing changed, or a change back and forth in one turn: no render.
      await tester.pump();
      touch.state.value = IosTouchState.reconnecting;
      touch.state.value = IosTouchState.ready;
      await tester.pump();
      expect(renders(), hasLength(before + 1));

      // A set read through contains() is followed too.
      c.systemFailed.add(IphoneSystemGesture.switcher);
      await tester.pump();
      expect(renders(), hasLength(before + 2));
      expect(itemOf(renders().last, 'system:0')!['tint'], 'warn');

      // Closed: nothing more is rendered.
      await done(tester, w);
      touch.state.value = IosTouchState.noRunner;
      await tester.pump();
      expect(renders(), hasLength(before + 2));
    });

    testWidgets('a switch to Thai renders the chrome again in Thai',
        (tester) async {
      Get.addTranslations(AppTranslations().keys);
      Get.locale = const Locale('en');
      addTearDown(() {
        Get.clearTranslations();
        Get.locale = null;
      });
      final settings = Get.put(SettingsService());
      final (_, touch, w) = await open(tester, caps: allCaps);
      touch.state.value = IosTouchState.ready;
      await tester.pump();
      final before = renders().length;
      expect(itemOf(renders().last, 'home')!['tooltip'], 'Home Screen  ⌘1');
      expect(itemOf(renders().last, 'touch')!['text'], 'Touch on');

      // What SettingsService.setLocale does, without Get.updateLocale's
      // reassemble.
      Get.locale = const Locale('th');
      settings.localeCode.value = 'th';
      await tester.pump();
      expect(renders(), hasLength(before + 1));
      expect(itemOf(renders().last, 'home')!['tooltip'], 'หน้าโฮม  ⌘1');
      expect(itemOf(renders().last, 'touch')!['text'], 'แตะได้');
      expect(itemOf(renders().last, 'system:2')!['tooltip'], 'ศูนย์ควบคุม  ⌘4');
      await done(tester, w);
    });
  });

  group('view model', () {
    const screenChannel = MethodChannel(IosScreenChannel.channelName);
    const allCaps = 'caps ping tap atap swipe aswipe home orient switcher '
        'spotlight control notifications';

    /// A controller with no phone listed (its screen state is noDevice
    /// after the first pump), touches recorded.
    Future<(IphoneRemoteController, _RecordingTouch, IosScreenChannel)> make(
        WidgetTester tester,
        {bool probe = false, String? caps}) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(screenChannel,
          (call) async => call.method == 'listDevices' ? <Map>[] : null);
      addTearDown(() => messenger.setMockMethodCallHandler(screenChannel, null));
      final screen = Get.put(IosScreenChannel());
      final touch =
          Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      if (caps != null) touch.caps.value = RunnerCaps.parse(caps);
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), probeEnabled: probe));
      await tester.pump();
      return (c, touch, screen);
    }

    RemoteViewModel model(IphoneRemoteController c, {bool? probe}) =>
        IphoneRemoteViewModel.from(c, c.touch, c.screen, probe: probe);

    /// Loads the app's strings in English; cleared after the test.
    void english() {
      Get.addTranslations(AppTranslations().keys);
      Get.locale = const Locale('en');
      addTearDown(() {
        Get.clearTranslations();
        Get.locale = null;
      });
    }

    testWidgets('the touch chip says where the link stands, every state; a '
        'banner only for what the user has to act on, and only over the '
        'picture', (tester) async {
      final (c, touch, screen) = await make(tester);
      screen.frameSize.value = const Size(1320, 2868);
      for (final (state, label, symbol, color, banner) in [
        (IosTouchState.idle, 'iphone_remote_touch_off',
            IphoneRemoteViewModel.touchOffSymbol, RemoteChipColor.orange, null),
        (IosTouchState.ready, 'iphone_remote_touch_ready',
            IphoneRemoteViewModel.touchReadySymbol, RemoteChipColor.green,
            null),
        (IosTouchState.reconnecting, 'iphone_touch_reconnecting',
            IphoneRemoteViewModel.touchWaitingSymbol, RemoteChipColor.orange,
            null),
        (IosTouchState.noRunner, 'iphone_touch_no_runner',
            IphoneRemoteViewModel.touchOffSymbol, RemoteChipColor.orange,
            'iphone_remote_runner_missing'),
        (IosTouchState.runnerRefused, 'iphone_touch_refused',
            IphoneRemoteViewModel.touchOffSymbol, RemoteChipColor.orange,
            'iphone_remote_runner_refused'),
        (IosTouchState.severalDevices, 'iphone_touch_several',
            IphoneRemoteViewModel.touchOffSymbol, RemoteChipColor.orange,
            'iphone_remote_several'),
        (IosTouchState.noDevice, 'iphone_touch_no_device',
            IphoneRemoteViewModel.touchOffSymbol, RemoteChipColor.orange,
            null),
      ]) {
        touch.state.value = state;
        final vm = model(c);
        final chip = vm.item('touch')!;
        expect(
            (chip.kind, chip.text, chip.symbol, chip.color, chip.tooltip),
            (RemoteItemKind.chip, label, symbol, color, ''),
            reason: '$state');
        expect(vm.banner, banner, reason: '$state');
        expect(vm.message, isNull, reason: '$state');
      }
      expect(IosTouchState.values, hasLength(7), reason: 'all of them above');

      // A drop count is the chip's tooltip.
      touch.dropped.value = 2;
      expect(model(c).item('touch')!.tooltip, 'iphone_touch_dropped');

      // No picture: the message, and no banner even for a missing runner.
      touch.state.value = IosTouchState.noRunner;
      screen.frameSize.value = null;
      expect(model(c).banner, isNull);
      expect(model(c).message, isNotNull);
      Get.delete<IphoneRemoteController>(force: true);
    });

    testWidgets('Home and the gestures: enabled by the link and the caps, '
        'orange with their own tooltip once refused, Cmd-N in their '
        'tooltips', (tester) async {
      final (c, touch, _) = await make(tester, caps: allCaps);
      touch.state.value = IosTouchState.ready;
      var vm = model(c);
      expect(vm.toolbar.map((i) => i.id), [
        'gestures', 'home', 'system:0', 'system:1', 'system:2', 'system:3',
        'touch',
      ]);
      expect(vm.item('gestures')!.tooltip, 'iphone_remote_gestures');
      expect(vm.item('gestures')!.kind, RemoteItemKind.chip);
      for (final (id, label, digit) in [
        ('home', 'iphone_remote_home', '1'),
        ('system:0', 'iphone_remote_switcher', '2'),
        ('system:1', 'iphone_remote_spotlight', '3'),
        ('system:2', 'iphone_remote_control_center', '4'),
        ('system:3', 'iphone_remote_notifications', '5'),
      ]) {
        final i = vm.item(id)!;
        expect((i.kind, i.enabled, i.tint, i.shortcut, i.tooltip),
            (RemoteItemKind.button, true, RemoteTint.normal, digit,
                '$label  ⌘$digit'),
            reason: id);
      }

      // Refused: orange, with a tooltip that says so.
      c.homeFailed.value = true;
      c.systemFailed.add(IphoneSystemGesture.controlCenter);
      vm = model(c);
      expect((vm.item('home')!.tint, vm.item('home')!.tooltip),
          (RemoteTint.warn, 'iphone_remote_home_failed'));
      expect((vm.item('system:2')!.tint, vm.item('system:2')!.tooltip),
          (RemoteTint.warn, 'iphone_remote_gesture_failed'));
      expect(vm.item('system:1')!.tint, RemoteTint.normal);

      // Link down: nothing is enabled, and a refused gesture is not orange.
      touch.state.value = IosTouchState.reconnecting;
      vm = model(c);
      for (final id in ['home', 'system:0', 'system:1', 'system:2', 'system:3']) {
        expect(vm.item(id)!.enabled, isFalse, reason: id);
      }
      expect((vm.item('system:2')!.tint, vm.item('system:2')!.tooltip),
          (RemoteTint.normal, 'iphone_remote_control_center  ⌘4'));

      // A runner without a verb: its item is off and says it needs a newer
      // runner; with no caps at all (an older runner) Home is still tried.
      touch.state.value = IosTouchState.ready;
      touch.caps.value = RunnerCaps.parse('caps ping tap swipe switcher');
      vm = model(c);
      expect(vm.item('system:0')!.enabled, isTrue);
      expect((vm.item('system:1')!.enabled, vm.item('system:1')!.tooltip),
          (false, 'iphone_remote_gesture_needs_runner'));
      expect(vm.item('home')!.enabled, isFalse);
      touch.caps.value = null;
      expect(model(c).item('home')!.enabled, isTrue);
      Get.delete<IphoneRemoteController>(force: true);
    });

    testWidgets('the @name and @n parameters are filled in', (tester) async {
      english();
      final (c, touch, _) = await make(tester, probe: true, caps: allCaps);
      touch.state.value = IosTouchState.ready;
      c.systemFailed.add(IphoneSystemGesture.controlCenter);
      touch.dropped.value = 3;
      var vm = model(c);
      expect(vm.item('system:2')!.tooltip,
          startsWith('The iPhone did not take Control Center:'));
      expect(vm.item('touch')!.tooltip,
          '3 touch commands dropped while the link was down');
      expect(vm.item('probe')!.menu!.map((e) => e.label), [
        '${IphoneRemoteController.probeTrials} taps at the last click',
        '${IphoneRemoteController.probeTrials} swipes up and down',
      ]);
      touch.caps.value = RunnerCaps.parse('caps ping tap swipe');
      vm = model(c);
      expect(vm.item('system:1')!.tooltip,
          startsWith('Spotlight needs a newer TouchRunner'));
      expect(vm.overlay!.first, 'Click → change n=0 p50 – ms p90 – ms · last –');
      Get.delete<IphoneRemoteController>(force: true);
    });

    testWidgets('the message follows the screen state, with Retry where it '
        'helps, and goes once the picture is up', (tester) async {
      final (c, _, screen) = await make(tester);
      expect(c.screenState.value, IphoneScreenState.noDevice);
      for (final (state, text, retry) in [
        (IphoneScreenState.starting, 'iphone_remote_waiting', false),
        (IphoneScreenState.noDevice, 'iphone_remote_no_device', true),
        (IphoneScreenState.permissionDenied, 'iphone_remote_permission', true),
        (IphoneScreenState.failed, 'iphone_remote_failed', true),
        (IphoneScreenState.live, 'iphone_remote_waiting', false),
      ]) {
        c.screenState.value = state;
        final m = model(c).message!;
        expect((m.text, m.action?.id, m.action?.label),
            (text, retry ? 'retry' : null, retry ? 'common_retry' : null),
            reason: '$state');
      }
      c.screenState.value = IphoneScreenState.live;
      screen.frameSize.value = const Size(1320, 2868);
      expect(model(c).message, isNull);
      Get.delete<IphoneRemoteController>(force: true);
    });

    testWidgets('the probe menu and overlay only with the probe on',
        (tester) async {
      final (c, _, _) = await make(tester, probe: true);
      expect(model(c, probe: false).item('probe'), isNull);
      expect(model(c, probe: false).overlay, isNull);
      final vm = model(c);
      final menu = vm.item('probe')!;
      expect(vm.toolbar.first.id, 'probe');
      expect((menu.kind, menu.enabled, menu.tooltip),
          (RemoteItemKind.menu, true, 'iphone_probe_menu'));
      expect(menu.menu!.map((e) => e.id), ['probe:tap', 'probe:swipe']);
      expect(vm.overlay, hasLength(1));
      c.scripting.value = true;
      expect(model(c).item('probe')!.enabled, isFalse);
      Get.delete<IphoneRemoteController>(force: true);
    });

    testWidgets('the payload carries every field Swift draws', (tester) async {
      final (c, touch, _) = await make(tester, probe: true, caps: allCaps);
      touch.state.value = IosTouchState.ready;
      final map = IphoneRemoteViewModel.from(c, c.touch, c.screen,
              title: 'iPhone 17')
          .toMap();
      expect(map['title'], 'iPhone 17');
      // The label of the menu Swift folds the buttons into when the
      // titlebar is too narrow for the whole toolbar.
      expect(map['more'], 'remote_window_more');
      expect(map['message'], {
        'text': 'iphone_remote_no_device',
        'action': {'id': 'retry', 'label': 'common_retry'},
      });
      expect(map.containsKey('banner'), isFalse);
      final toolbar = (map['toolbar'] as List).cast<Map>();
      expect(toolbar.firstWhere((i) => i['id'] == 'home'), {
        'id': 'home',
        'symbol': 'house',
        'tooltip': 'iphone_remote_home  ⌘1',
        'enabled': true,
        'tint': 'normal',
        'kind': 'button',
        'shortcut': '1',
      });
      expect(toolbar.firstWhere((i) => i['id'] == 'probe')['menu'], [
        {'id': 'probe:tap', 'label': 'iphone_probe_run_tap'},
        {'id': 'probe:swipe', 'label': 'iphone_probe_run_swipe'},
      ]);
      expect(toolbar.firstWhere((i) => i['id'] == 'touch'), {
        'id': 'touch',
        'symbol': 'hand.tap',
        'tooltip': '',
        'enabled': true,
        'tint': 'normal',
        'kind': 'chip',
        'text': 'iphone_remote_touch_ready',
        'color': 'green',
      });
      expect(map['overlay'], hasLength(1));
      Get.delete<IphoneRemoteController>(force: true);
    });

    testWidgets('with no phone on USB the window says to plug one in, opens '
        'no capture, and Retry lists the phones again', (tester) async {
      const windowChannel = MethodChannel(RemoteWindowChannel.channelName);
      final screenCalls = <String>[];
      final windowCalls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        screenCalls.add(call.method);
        return call.method == 'listDevices' ? <Map>[] : null;
      });
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call);
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(screenChannel, null);
        messenger.setMockMethodCallHandler(windowChannel, null);
      });
      Get.put(IosScreenChannel());
      Get.put<IosTouchService>(_NoPhoneTouch());
      final windows = RemoteWindowChannel();
      final driver = IphoneRemoteWindow('cam-1',
          create: (id) => IphoneRemoteController(
              deviceId: id,
              retryEvery: const Duration(hours: 1)));
      expect(await windows.openDriver(driver), isTrue);
      await tester.pump();
      await tester.pump();
      final vm = (windowCalls.lastWhere((c) => c.method == 'render').arguments
          as Map)['vm'] as Map;
      expect(vm['message'], {
        'text': 'iphone_remote_no_device',
        'action': {'id': 'retry', 'label': 'common_retry'},
      });
      expect(
          (vm['toolbar'] as List)
              .cast<Map>()
              .firstWhere((i) => i['id'] == 'touch')['text'],
          'iphone_remote_touch_off');
      expect(screenCalls, isNot(contains('start')));

      final listings = screenCalls.where((m) => m == 'listDevices').length;
      final token = windowCalls
          .lastWhere((c) => c.method == 'open')
          .arguments['token'];
      await messenger.handlePlatformMessage(
          windowChannel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('action',
              {'id': 'cam-1', 'token': token, 'item': 'retry'})),
          (_) {});
      await tester.pump();
      await tester.pump();
      expect(screenCalls.where((m) => m == 'listDevices').length,
          greaterThan(listings));
      await windows.close('cam-1');
      await tester.pump();
    });
  });
}
