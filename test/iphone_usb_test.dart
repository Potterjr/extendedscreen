import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_controller.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_view.dart';
import 'package:extendedscreen/shared/connection/usbmux.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

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
/// `pong 440x956 fast=[fast]`, `orient` with `orient [orient]` and anything else with
/// [answer] (`sent 1ms` by default), keeping every line in [received]. Like
/// usbmuxd, it takes only version 1 plist messages (type 8), and answers with
/// the request's tag; anything else is kept in [badHeaders].
class _FakeUsbmuxd {
  _FakeUsbmuxd(this.path,
      {this.port = 8100,
      this.devices = const [(7, 'UDID-1', 'USB')],
      this.fast = true,
      this.answer = 'sent 1ms',
      this.unknown = const {}});

  final String path;
  final int port;
  final List<(int, String, String)> devices;
  final bool fast;
  final String answer;

  /// Commands this runner does not know (a build from before them): it
  /// answers `err <line>` and touches nothing, as the runner does.
  final Set<String> unknown;
  int orient = 1;
  final received = <String>[];
  final badHeaders = <String>[];
  ServerSocket? _server;

  Future<void> start() async {
    _server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix), 0);
    _server!.listen(_serve);
  }

  Future<void> stop() async => _server?.close();

  void _serve(Socket s) {
    final buf = BytesBuilder();
    var streaming = false;
    var lineBuf = '';
    s.listen((chunk) {
      if (streaming) {
        lineBuf += utf8.decode(chunk);
        while (lineBuf.contains('\n')) {
          final i = lineBuf.indexOf('\n');
          final line = lineBuf.substring(0, i);
          lineBuf = lineBuf.substring(i + 1);
          received.add(line);
          final out = switch (line) {
            'ping' => 'pong 440x956 fast=$fast',
            'orient' => 'orient $orient',
            _ when unknown.contains(line.split(' ').first) => 'err $line',
            _ => answer,
          };
          s.add(utf8.encode('$out\n'));
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
      s.add([...out.buffer.asUint8List(), ...body]);
      if (!streaming) s.close();
    }, onError: (_) {});
  }
}

/// Touches with no phone on USB: answers at once, opens no socket.
class _NoPhoneTouch extends IosTouchService {
  @override
  Future<bool> connect({String? udid}) async {
    state.value = IosTouchState.noDevice;
    return false;
  }
}

/// Touches recorded instead of sent; [turned] is what the runner says.
class _RecordingTouch extends IosTouchService {
  int connects = 0;
  IosTurn turned = IosTurn.topLeft;
  final sent = <String>[];

  /// Shared with a channel mock, to see what went out first.
  List<String>? order;

  /// Every command in order, `orient` included ([sent] leaves it out).
  final trace = <String>[];

  int get orients => trace.where((l) => l == 'orient').length;

  @override
  Future<bool> connect({String? udid}) async {
    connects++;
    return false;
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

  @override
  Future<void> tap(double nx, double ny) async {
    order?.add('tap');
    sent.add('tap ${nx.toStringAsFixed(2)} ${ny.toStringAsFixed(2)}');
    trace.add('tap');
  }

  @override
  Future<void> swipe(double nx1, double ny1, double nx2, double ny2,
      double seconds, {double hold = 0}) async {
    order?.add('swipe');
    trace.add('swipe');
    sent.add('swipe ${nx1.toStringAsFixed(2)} ${ny1.toStringAsFixed(2)} '
          '${nx2.toStringAsFixed(2)} ${ny2.toStringAsFixed(2)} '
          '${seconds.toStringAsFixed(2)} hold ${hold.toStringAsFixed(2)}');
  }
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

  // The stand-in usbmuxd is a Unix-domain socket, as on the Mac. Windows'
  // AF_UNIX driver (afunix.sys) can blue-screen the machine when a process
  // holding such a socket exits (see CLAUDE.md, Windows client), and the
  // iPhone-over-USB path is the Mac's alone, so these are not run there.
  final unixSockets = Platform.isWindows
      ? 'Unix-domain sockets: the Mac host path, not run on Windows'
      : null;

  group('UsbmuxClient', skip: unixSockets, () {
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

  group('IosTouchService', skip: unixSockets, () {
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
      await _until(() => mux.received.length == 4);
      expect(mux.received, [
        'ping',
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
      expect(mux.received.skip(6).take(3),
          ['ping', 'orient', 'aswipe 0.5000 0.8000 0.5000 0.3000 0.300']);
    });

    test('presses Home; a runner built before home says no', () async {
      final mux = _FakeUsbmuxd(path);
      await mux.start();
      addTearDown(mux.stop);
      final touch = IosTouchService(usbmux: UsbmuxClient(path: path));
      addTearDown(touch.disconnect);
      expect(await touch.home(), isTrue);
      expect(mux.received, ['ping', 'orient', 'home']);

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
          ['ping', 'orient', 'atap 0.5000 0.5000', 'tap 0.5000 0.5000']);
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
      expect(mux.received, ['ping', 'orient']);
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

      starting.complete({'textureId': 5});
      await tester.pump();
      await retried;
      expect(c.screen.textureId.value, 5);
      expect(c.screenState.value, IphoneScreenState.live);
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
              return {'textureId': started.length};
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
      c.onPanStart(const Offset(50, 150));
      now = now.add(const Duration(milliseconds: 1500));
      await c.onPanEnd(const Offset(50, 50), box);
      expect(touch.sent.single, endsWith(
          '${IphoneRemoteController.maxDragReplay.toStringAsFixed(2)} hold 0.00'));

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
      starting.complete({'textureId': 5});
      await tester.pump();
      expect(touch.connects, 0);
      expect(calls, contains('stop'));
    });

    testWidgets('a long press is sent once let go: held as long as it was, '
        'then dragged', (tester) async {
      mockScreen(tester, phone: false);
      var now = DateTime(2026);
      Get.put(IosScreenChannel());
      final touch = Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      final c = Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), now: () => now));
      c.screen.frameSize.value = const Size(1320, 2868);
      const box = Size(100, 200);

      c.onLongPressStart(const Offset(50, 100));
      now = now.add(const Duration(milliseconds: 700));
      expect(touch.sent, isEmpty, reason: 'nothing before it ends');
      c.onLongPressMove();
      now = now.add(const Duration(milliseconds: 400));
      await c.onLongPressEnd(const Offset(50, 20), box);
      // 0.5 s to be recognised + 0.7 s more held, then 0.4 s of drag.
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.10 0.40 hold 1.20']);

      touch.sent.clear();
      c.onLongPressStart(const Offset(50, 100));
      now = now.add(const Duration(seconds: 2));
      await c.onLongPressEnd(const Offset(50, 100), box);
      expect(touch.sent, ['swipe 0.50 0.50 0.50 0.50 2.50 hold 0.00']);

      touch.sent.clear();
      c.onPanStart(const Offset(10, 10));
      now = now.add(const Duration(milliseconds: 2500));
      await c.onPanEnd(const Offset(90, 190), box);
      expect(touch.sent, ['swipe 0.10 0.05 0.90 0.95 0.30 hold 0.00'],
          reason: 'a slow drag is replayed in maxDragReplay, so it lands '
              'soon after it is let go');
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

      await c.onTap(const Offset(100, 50), box);
      expect(touch.trace, ['orient', 'tap', 'orient'],
          reason: 'nothing asked on the tap\'s way; refreshed after it');
      // The phone is flipped to the other landscape side: same frame size.
      touch.turned = IosTurn.topRight;
      await c.onTap(const Offset(100, 50), box);
      await c.onTap(const Offset(100, 50), box);
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
      await c.onTap(const Offset(10, 10), const Size(100, 200));
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

      c.onPanStart(const Offset(10, 10));
      // The phone turns mid-drag.
      c.screen.frameSize.value = const Size(2868, 1320);
      now = now.add(const Duration(milliseconds: 200));
      await c.onPanEnd(const Offset(300, 150), box);
      expect(touch.trace, ['swipe', 'orient']);

      touch.trace.clear();
      c.onLongPressStart(const Offset(50, 50));
      c.onLongPressMove();
      now = now.add(const Duration(milliseconds: 300));
      await c.onLongPressEnd(const Offset(60, 60), box);
      expect(touch.trace, ['swipe', 'orient'],
          reason: 'a landscape long press refreshes once it has gone out');

      touch.trace.clear();
      c.onPanStart(const Offset(10, 10));
      c.onPanCancel();
      expect(touch.trace, ['orient'],
          reason: 'a cancelled drag sends nothing and holds nothing back');
      Get.delete<IphoneRemoteController>();
    });
  });

  testWidgets('over the picture, only a runner that does not answer is '
      'blamed', (tester) async {
    const channel = MethodChannel(IosScreenChannel.channelName);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async => call.method == 'listDevices' ? <Map>[] : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final screen = Get.put(IosScreenChannel());
    final touch = Get.put<IosTouchService>(_RecordingTouch());
    Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));
    await tester.pumpWidget(const GetMaterialApp(home: IphoneRemoteView()));
    await tester.pump();
    screen.textureId.value = 3;
    screen.frameSize.value = const Size(1320, 2868);

    for (final state in [IosTouchState.idle, IosTouchState.noDevice]) {
      touch.state.value = state;
      await tester.pump();
      expect(find.text('iphone_remote_runner_missing'), findsNothing,
          reason: '$state');
    }
    touch.state.value = IosTouchState.noRunner;
    await tester.pump();
    expect(find.text('iphone_remote_runner_missing'), findsOneWidget);
    Get.delete<IphoneRemoteController>();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with no phone on USB the view says to plug one in, and opens '
      'no capture', (tester) async {
    const channel = MethodChannel(IosScreenChannel.channelName);
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      return call.method == 'listDevices' ? <Map>[] : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    Get.put(IosScreenChannel());
    Get.put<IosTouchService>(_NoPhoneTouch());
    Get.put(IphoneRemoteController(retryEvery: const Duration(hours: 1)));

    await tester.pumpWidget(const GetMaterialApp(home: IphoneRemoteView()));
    await tester.pump();
    await tester.pump();
    expect(find.text('iphone_remote_no_device'), findsOneWidget);
    expect(calls, isNot(contains('start')));
    expect(find.text('iphone_remote_touch_off'), findsOneWidget);
    Get.delete<IphoneRemoteController>();
    await tester.pumpWidget(const SizedBox());
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

    Future<(_RecordingTouch, List<String>)> showView(WidgetTester tester,
        {required bool probe}) async {
      final order = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        order.add(call.method);
        return switch (call.method) {
          'listDevices' => <Map>[],
          'markProbe' => true,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final screen = Get.put(IosScreenChannel());
      final touch =
          Get.put<IosTouchService>(_RecordingTouch()) as _RecordingTouch;
      touch.order = order;
      Get.put(IphoneRemoteController(
          retryEvery: const Duration(hours: 1), probeEnabled: probe));
      await tester.pumpWidget(
          GetMaterialApp(home: IphoneRemoteView(probeEnabled: probe)));
      await tester.pump();
      screen.textureId.value = 3;
      screen.frameSize.value = const Size(1320, 2868);
      await tester.pump();
      return (touch, order);
    }

    testWidgets('off: no probe menu or overlay, and a click arms nothing',
        (tester) async {
      final (touch, order) = await showView(tester, probe: false);
      expect(find.byKey(const ValueKey('iphone/probe')), findsNothing);
      expect(find.byKey(const ValueKey('iphone/probe-overlay')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('iphone/surface')));
      await tester.pump();
      expect(touch.sent, hasLength(1));
      expect(order, isNot(contains('markProbe')));
      Get.delete<IphoneRemoteController>();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on: a click arms a probe at pointer-down, before its tap '
        'goes out, and its answer shows in the overlay', (tester) async {
      final (touch, order) = await showView(tester, probe: true);
      expect(find.byKey(const ValueKey('iphone/probe')), findsOneWidget);
      expect(find.byKey(const ValueKey('iphone/probe-overlay')), findsOneWidget);

      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('iphone/surface'))));
      await tester.pump();
      expect(order.where((m) => m == 'markProbe'), hasLength(1),
          reason: 'armed on pointer-down, before the finger comes up');
      expect(touch.sent, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(order.where((m) => m == 'markProbe' || m == 'tap'),
          ['markProbe', 'tap']);

      await answer(tester, 1, 118.0);
      await tester.pump();
      final c = Get.find<IphoneRemoteController>();
      expect((c.felt.count, c.lastFeltMs.value), (1, 118.0));
      expect(find.textContaining('iphone_probe_last 118'), findsOneWidget);
      Get.delete<IphoneRemoteController>();
      await tester.pumpWidget(const SizedBox());
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
}
