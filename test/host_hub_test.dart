import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// The hub and its per-tablet sessions, against tablets stood in for in
/// this process ([FakeTablet], with [SynthAdb] playing adb).

class _QuietLogger extends LoggerService {
  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) {}
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

/// ScreenCaptureKit, stood in for: the test pushes "frames" itself, and the
/// configs every start was given are kept.
class _Capture extends ScreenCaptureChannel {
  final frames = StreamController<Uint8List>.broadcast();
  final starts = <DisplayConfigModel>[];

  @override
  Stream<Uint8List> framesFor(int session) => frames.stream;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<bool> createVirtualDisplay(DisplayConfigModel config,
          {required int session,
          int serialNum = 1,
          String name = 'Extended Screen'}) async =>
      true;
  @override
  Future<void> startCapture(DisplayConfigModel config,
          {required int session}) async =>
      starts.add(config);
  @override
  Future<void> stopCapture({required int session}) async {}
  @override
  Future<void> removeVirtualDisplay({required int session}) async {}
  @override
  Future<void> disposeSession({required int session}) async {}
  @override
  Future<void> requestIdr({required int session}) async {}
  @override
  Future<Map<String, double>> getDisplayBounds({required int session}) async =>
      {'x': 0, 'y': 0, 'w': 1480, 'h': 924};
}

class _Input extends InputInjectChannel {
  @override
  Future<bool> requestAccessibility() async => true;
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  @override
  Future<void> releaseAll({required int session}) async {}
  @override
  Future<void> injectMouse(MouseEventModel e, Map<String, double> displayBounds,
      {required int session}) async {}
}

Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  late _Capture capture;

  const ultra = ClientPanel(2960, 1848, 120);
  const plain = ClientPanel(2560, 1600, 60);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    capture = Get.put<ScreenCaptureChannel>(_Capture()) as _Capture;
    Get.put<InputInjectChannel>(_Input());
  });

  tearDown(Get.reset);

  /// A hub whose adb is [adb], torn down after the test.
  HostConnectionManager hubWith(SynthAdb adb) {
    Get.put<AdbService>(adb);
    final hub = HostConnectionManager(adb: adb);
    addTearDown(hub.disconnect);
    return hub;
  }

  group('over USB', () {
    test("a tablet gets a port of its own on the Mac, adb joins the tablet's "
        '7001 to it, and Disconnect takes it all down', () async {
      final tablet = FakeTablet('SYN-1', panel: ultra);
      addTearDown(tablet.hangUp);
      final adb = SynthAdb([tablet]);
      final hub = hubWith(adb);

      await hub.connect(serial: 'SYN-1');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.activeDevice.value?.serial, 'SYN-1');
      expect(tablet.trusted, isTrue);
      final rule = adb.reverses['SYN-1']!;
      expect(rule.remote, 7001, reason: 'the tablet dials its own 7001');
      expect(rule.local, isNot(7001), reason: 'the Mac side is the session\'s own');

      capture.frames.add(Uint8List.fromList([0, 0, 0, 1, 0x65]));
      await _until(() => tablet.frames == 1);

      await hub.disconnect();
      expect(hub.phase.value, ConnectionPhase.disconnected);
      expect(hub.sessions, isEmpty);
      expect(adb.reverses, isEmpty, reason: 'its rule went with the session');
    });

    test("each tablet's capture is sized from its own panel, and the panel is "
        'remembered for it', () async {
      final big = FakeTablet('BIG', panel: ultra);
      final small = FakeTablet('SMALL', panel: plain);
      addTearDown(big.hangUp);
      addTearDown(small.hangUp);
      final hub = hubWith(SynthAdb([big, small]));

      await hub.connect(serial: 'BIG');
      await hub.disconnect();
      await hub.connect(serial: 'SMALL');
      expect(hub.phase.value, ConnectionPhase.streaming);

      // Max: logical size is half the panel, at the panel's top rate.
      expect(capture.starts.map((c) => (c.width, c.height, c.refreshRate)),
          [(1480, 924, 120), (1280, 800, 60)]);
      expect(settings.clientPanelFor('BIG'), ultra);
      expect(settings.clientPanelFor('SMALL'), plain);
      expect(settings.lastClientPanel, plain);
    });

    test("an unplugged tablet's session waits for that tablet, and picking "
        'another one ends it', () async {
      final first = FakeTablet('FIRST');
      final second = FakeTablet('SECOND');
      addTearDown(first.hangUp);
      addTearDown(second.hangUp);
      final adb = SynthAdb([first, second]);
      final hub = hubWith(adb);
      await hub.connect(serial: 'FIRST');
      final session = hub.focused!;

      // The cable comes out.
      adb.unplugged.add('FIRST');
      await first.hangUp();
      await _until(() => hub.errorMessage.value == 'error_device_gone'.tr);
      expect(hub.phase.value, ConnectionPhase.error);
      expect(adb.reverses.keys, isNot(contains('SECOND')),
          reason: 'its retries do not take whatever else is attached');

      await hub.connect(serial: 'SECOND');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions.keys, ['SECOND']);
      expect(hub.focused, isNot(same(session)));
      expect(session.phase.value, ConnectionPhase.disconnected,
          reason: 'its retry is over');
      expect(hub.activeDevice.value?.serial, 'SECOND');
    });

    test('Connect with nothing chosen takes the last-used tablet if it is '
        'attached, else the first one', () async {
      final a = FakeTablet('A');
      final b = FakeTablet('B');
      addTearDown(a.hangUp);
      addTearDown(b.hangUp);
      final hub = hubWith(SynthAdb([a, b]));

      await settings.setLastDevice('B');
      await hub.connect();
      expect(hub.activeDevice.value?.serial, 'B');
      await hub.disconnect();

      await settings.setLastDevice('GONE');
      await hub.connect();
      expect(hub.activeDevice.value?.serial, 'A');
    });

    test('a retry run early (Connect while one is pending) keeps the session',
        () async {
      final tablet = FakeTablet('SYN-1');
      addTearDown(tablet.hangUp);
      final adb = SynthAdb([tablet]);
      final hub = hubWith(adb);
      await hub.connect(serial: 'SYN-1');
      final session = hub.focused!;
      final nativeId = session.nativeId;

      adb.unplugged.add('SYN-1');
      await tablet.hangUp();
      await _until(() => hub.phase.value == ConnectionPhase.error);
      adb.unplugged.clear();
      await hub.connect();
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(session));
      expect(hub.focused!.nativeId, nativeId,
          reason: 'its native state stays under the same id');
    });

    test('two quick picks while a session is ending make one session, and '
        'nothing keeps running after Disconnect', () async {
      final first = FakeTablet('FIRST');
      final second = FakeTablet('SECOND');
      final third = FakeTablet('THIRD');
      for (final t in [first, second, third]) {
        addTearDown(t.hangUp);
      }
      final adb = SynthAdb([first, second, third]);
      final hub = hubWith(adb);
      await hub.connect(serial: 'FIRST');
      adb.unplugged.add('FIRST');
      await first.hangUp();
      await _until(() => hub.phase.value == ConnectionPhase.error);

      // Removing FIRST's rule takes a moment, and two picks land meanwhile.
      adb.removeDelay = const Duration(milliseconds: 300);
      final picks = [
        hub.connect(serial: 'SECOND'),
        hub.connect(serial: 'SECOND'),
        hub.connect(serial: 'THIRD'),
      ];
      await Future.wait(picks);
      expect(hub.sessions.keys, ['SECOND']);
      expect(adb.keysDelivered, {'FIRST': 1, 'SECOND': 1});
      expect(hub.phase.value, ConnectionPhase.streaming);

      await hub.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(second.trusted, isFalse, reason: 'no session left to dial it');
      expect(adb.keysDelivered, {'FIRST': 1, 'SECOND': 1});
      expect(adb.reverses, isEmpty);
    });

    test('picking the tablet again while Cancel is still ending its session '
        'does not bring that session back', () async {
      final tablet = FakeTablet('SYN-1');
      addTearDown(tablet.hangUp);
      final adb = SynthAdb([tablet]);
      final hub = hubWith(adb);
      await hub.connect(serial: 'SYN-1');
      adb.unplugged.add('SYN-1');
      await tablet.hangUp();
      await _until(() => hub.phase.value == ConnectionPhase.error);
      adb.unplugged.clear();

      adb.removeDelay = const Duration(milliseconds: 300);
      final cancel = hub.disconnect();
      await hub.connect(serial: 'SYN-1');
      await cancel;
      expect(hub.phase.value, ConnectionPhase.disconnected);
      expect(hub.sessions, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(tablet.trusted, isFalse);
      expect(adb.keysDelivered, {'SYN-1': 1}, reason: 'no retry dialled it');
    });

    test('with no tablet attached, Connect waits for one and takes the one '
        'that is plugged in', () async {
      final tablet = FakeTablet('NEW');
      addTearDown(tablet.hangUp);
      final adb = SynthAdb([tablet])..unplugged.add('NEW');
      final hub = hubWith(adb);
      await settings.setLastDevice('OLD');

      await hub.connect();
      expect(hub.phase.value, ConnectionPhase.error);
      expect(hub.errorMessage.value, contains('No ADB device'));
      expect(hub.sessions, isEmpty, reason: 'nothing to fix a session to');

      adb.unplugged.clear();
      await _until(() => hub.phase.value == ConnectionPhase.streaming,
          timeout: const Duration(seconds: 4));
      expect(hub.activeDevice.value?.serial, 'NEW');
    });

    test("an ended session's adb call that returns late does not undo the "
        "next session's tunnel to the same tablet", () async {
      final tablet = FakeTablet('SYN-1');
      addTearDown(tablet.hangUp);
      final adb = SynthAdb([tablet])
        ..reverseDelays.add(const Duration(milliseconds: 300));
      final hub = hubWith(adb);

      // The first attempt is cancelled while adb is still setting up its
      // rule, and the tablet is picked again at once.
      final first = hub.connect(serial: 'SYN-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await hub.disconnect();
      await hub.connect(serial: 'SYN-1');
      await first;
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(tablet.trusted, isTrue);
      expect(adb.reverses['SYN-1'], isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(adb.reverses['SYN-1'], isNotNull,
          reason: 'nothing late removed it');
      expect(hub.phase.value, ConnectionPhase.streaming);
    });

    test('a settings change reconnects the same session', () async {
      final tablet = FakeTablet('SYN-1');
      addTearDown(tablet.hangUp);
      final hub = hubWith(SynthAdb([tablet]));
      await hub.connect(serial: 'SYN-1');
      final session = hub.focused!;

      await hub.reconnect();
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(session));
      expect(capture.starts, hasLength(2));
    });
  });

  group('retries', () {
    // testWidgets for its fake clock: nothing here touches a real socket.
    testWidgets('over USB the first retry comes after a second, then after '
        'about 2, 5 and 10 s, and every 10 s after that', (tester) async {
      final adb = SynthAdb(const []);
      Get.put<AdbService>(adb);
      final hub = HostConnectionManager(adb: adb);
      unawaited(hub.connect(serial: 'GONE'));
      await tester.pump();
      expect(adb.listings, 1);
      expect(hub.phase.value, ConnectionPhase.error);

      // When each retry came, to 10 ms, over the next 45 s.
      final at = <int>[0];
      for (var t = 10; t <= 45000; t += 10) {
        await tester.pump(const Duration(milliseconds: 10));
        if (adb.listings > at.length) at.add(t);
      }
      final gaps = [for (var i = 1; i < at.length; i++) at[i] - at[i - 1]];
      // [no sooner than, no later than] each retry, ±20% after the first.
      const windows = [
        (1000, 1000),
        (1600, 2400),
        (4000, 6000),
        (8000, 12000),
        (8000, 12000),
      ];
      expect(gaps.length, greaterThanOrEqualTo(windows.length));
      for (final (i, (low, high)) in windows.indexed) {
        expect(gaps[i], inInclusiveRange(low, high + 10),
            reason: 'retry ${i + 1} after ${gaps[i]} ms');
      }
      await hub.disconnect();
      await tester.pump();
    });

    test('a session that was live starts again from a one-second retry, and '
        'over Wi-Fi it is always a second', () {
      Get.put<AdbService>(SynthAdb(const []));
      HostSession session(LinkType link) => HostSession(
            key: link == LinkType.usb ? 'T' : 'wifi',
            link: link,
            serial: link == LinkType.usb ? 'T' : null,
            pipeline: PipelineQueue(),
            socket: SocketService(),
          );
      final usb = session(LinkType.usb);
      // ignore: invalid_use_of_protected_member
      Duration next(HostSession s) => s.nextRetryDelay();
      expect(next(usb), const Duration(seconds: 1));
      expect(next(usb).inMilliseconds, inInclusiveRange(1600, 2400));
      usb.phase.value = ConnectionPhase.streaming;
      expect(next(usb), const Duration(seconds: 1));

      final wifi = session(LinkType.wifi);
      for (var i = 0; i < 4; i++) {
        expect(next(wifi), const Duration(seconds: 1));
      }
      usb.dispose();
      wifi.dispose();
    });
  });

  group('per-tablet settings', () {
    test('a panel reported before panels were kept per tablet becomes the '
        "last-used device's", () async {
      SharedPreferences.setMockInitialValues({
        'last_device': 'OLD',
        'client_panel_w': 2960,
        'client_panel_h': 1848,
        'client_panel_max_hz': 120,
      });
      final upgraded = SettingsService();
      await upgraded.init();
      expect(upgraded.clientPanelFor('OLD'), ultra);
      expect(upgraded.clientPanelFor('NEW'), isNull);

      await upgraded.setClientPanelFor('NEW', plain);
      expect(upgraded.clientPanelFor('NEW'), plain);
      expect(upgraded.clientPanelFor('OLD'), ultra);
      expect(upgraded.lastClientPanel, plain);
    });

    test('a panel survives the trip through preferences, and junk does not',
        () {
      expect(ClientPanel.decode(ultra.encode()), ultra);
      for (final junk in [null, '', '1,2', 'a,b,c', '0,10,60', '1,2,3,4']) {
        expect(ClientPanel.decode(junk), isNull, reason: '$junk');
      }
    });
  });
}
