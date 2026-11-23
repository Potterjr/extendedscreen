import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

import 'support/recording_remote_video.dart';

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
/// configs every start was given are kept, with the serial number and name
/// of every virtual display made. What a display or a start gives back, and
/// whether a start fails, is the test's to say; [startGate] holds starts.
class _Capture extends ScreenCaptureChannel {
  final frames = StreamController<Uint8List>.broadcast();
  final starts = <DisplayConfigModel>[];
  final displays = <({int serialNum, String name})>[];
  VirtualDisplayResult display =
      const VirtualDisplayResult(displayId: 5, applied: true);
  CaptureStart started = const CaptureStart(displayId: 5);
  PlatformException? startError;
  Completer<void>? startGate;

  @override
  Stream<Uint8List> framesFor(int session) => frames.stream;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<VirtualDisplayResult> createVirtualDisplay(DisplayConfigModel config,
      {required int session,
      int serialNum = 1,
      String name = 'Extended Screen'}) async {
    displays.add((serialNum: serialNum, name: name));
    return display;
  }

  @override
  Future<CaptureStart> startCapture(DisplayConfigModel config,
      {required int session}) async {
    await startGate?.future;
    starts.add(config);
    final error = startError;
    if (error != null) throw error;
    return started;
  }

  @override
  Future<void> setFrameRateCeiling(int fps, {required int session}) async {}
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

/// adb whose device listing can be held ([listing]), as a slow `adb devices`
/// holds a connect that has no serial yet.
class _SlowListing extends SynthAdb {
  _SlowListing(super.tablets);

  /// While set, a listing answers only once it completes.
  Completer<void>? listing;

  /// Listings asked for and held.
  int waiting = 0;

  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async {
    final held = listing;
    if (held != null) {
      waiting++;
      await held.future;
      waiting--;
    }
    return super.listDevicesOrNull();
  }
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
    final hub = HostConnectionManager(
        adb: adb, devicePollInterval: null, hostGranted: () async => true);
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
        'another one ends it (one tablet at a time)', () async {
      await settings.setMaxTablets(1);
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
        'nothing keeps running after Disconnect (one tablet at a time)',
        () async {
      await settings.setMaxTablets(1);
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
        'that is plugged in (one tablet at a time)', () async {
      await settings.setMaxTablets(1);
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

  group('several tablets over USB', () {
    /// A hub whose encoder takes four big tablets with room to spare.
    Future<HostConnectionManager> roomyHub(SynthAdb adb) async {
      final hub = hubWith(adb);
      await hub.hostInfoReady;
      hub.budget.estimate = const EncoderEstimate(
          engines: 4, h264PerEngine: 4000, h265PerEngine: 4000);
      return hub;
    }

    List<FakeTablet> tablets(List<String> serials) {
      final made = [for (final serial in serials) FakeTablet(serial)];
      for (final t in made) {
        addTearDown(t.hangUp);
      }
      return made;
    }

    /// [hub] with A streaming and C refused by the encoder (its start found
    /// another session's encoder in the way).
    Future<void> refuseC(HostConnectionManager hub) async {
      await hub.connect(serial: 'A');
      capture.startError = PlatformException(code: 'ENCODER_BUSY');
      await hub.connect(serial: 'C');
      capture.startError = null;
      expect(hub.sessions['C']!.refused.value, isTrue);
      expect(hub.sessions['C']!.phase.value, ConnectionPhase.error);
    }

    test('one tablet at a time: a pick of another while one streams is '
        'refused, as it always was', () async {
      await settings.setMaxTablets(1);
      final adb = SynthAdb(tablets(['A', 'B']));
      final hub = await roomyHub(adb);
      expect(hub.cap, 1);

      await hub.connect(serial: 'A');
      final a = hub.focused!;
      await hub.connect(serial: 'B');
      expect(hub.sessions.keys, ['A']);
      expect(hub.focused, same(a));
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(adb.keysDelivered, {'A': 1});
    });

    test('picking B while A streams adds B, and A keeps streaming', () async {
      final [tabletA, tabletB] = tablets(['A', 'B']);
      final adb = SynthAdb([tabletA, tabletB]);
      final hub = await roomyHub(adb);
      expect(hub.cap, 4);

      await hub.connect(serial: 'A');
      final a = hub.focused!;
      expect(hub.canAdd, isTrue);
      await hub.connect(serial: 'B');
      final b = hub.focused!;
      expect(b.key, 'B', reason: 'the new session is focused');
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
      expect(hub.sessions['A'], same(a));
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.activeDevice.value?.serial, 'B');
      expect(tabletA.trusted && tabletB.trusted, isTrue);
      expect(adb.reverses.keys.toSet(), {'A', 'B'});
      expect(hub.usbSessionCount, 2);
      expect(hub.anyActive, isTrue);
      expect(hub.freeDevices, isEmpty);
    });

    test('two quick picks of one tablet make one session', () async {
      final adb = SynthAdb(tablets(['A']));
      final hub = await roomyHub(adb);

      await Future.wait([hub.connect(serial: 'A'), hub.connect(serial: 'A')]);
      expect(hub.sessions.keys, ['A']);
      expect(adb.keysDelivered, {'A': 1});
      expect(hub.phase.value, ConnectionPhase.streaming);
    });

    test("ending A alone leaves B, remembers that A was stopped, and the hub "
        "shows B's session; ending the last one shows disconnected", () async {
      final [tabletA, tabletB] = tablets(['A', 'B']);
      final adb = SynthAdb([tabletA, tabletB]);
      final hub = await roomyHub(adb);
      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');
      final b = hub.sessions['B']!;
      hub.focus('A');
      expect(hub.activeDevice.value?.serial, 'A');

      await hub.disconnectSession('A', userStopped: true);
      expect(hub.sessions.keys, ['B']);
      expect(hub.stoppedDevices, {'A'});
      expect(hub.focused, same(b));
      expect(hub.activeDevice.value?.serial, 'B');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(tabletB.trusted, isTrue);
      expect(adb.reverses.keys, ['B']);

      // The hub follows B now: B's lost link is the hub's.
      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => hub.phase.value == ConnectionPhase.error);
      expect(b.phase.value, ConnectionPhase.error);

      await hub.disconnectSession('B');
      expect(hub.sessions, isEmpty);
      expect(hub.phase.value, ConnectionPhase.disconnected);
      expect(hub.errorMessage.value, isEmpty);
      expect(hub.activeDevice.value, isNull);
      expect(hub.stoppedDevices, {'A'}, reason: 'B was not stopped by the user');
      hub.allowDevice('A');
      expect(hub.stoppedDevices, isEmpty);
    });

    test('one tablet at a time, a replace shows a connecting phase '
        'throughout, never disconnected', () async {
      await settings.setMaxTablets(1);
      final all = tablets(['FIRST', 'SECOND']);
      final first = all.first;
      final adb = SynthAdb(all);
      final hub = await roomyHub(adb);
      await hub.connect(serial: 'FIRST');
      adb.unplugged.add('FIRST');
      await first.hangUp();
      await _until(() => hub.phase.value == ConnectionPhase.error);

      // Ending FIRST takes a while.
      adb.removeDelay = const Duration(milliseconds: 300);
      final phases = <ConnectionPhase>[];
      final worker = ever<ConnectionPhase>(hub.phase, phases.add);
      addTearDown(worker.dispose);
      await hub.connect(serial: 'SECOND');
      expect(hub.sessions.keys, ['SECOND']);
      expect(phases.first, ConnectionPhase.detectingDevice);
      expect(phases.last, ConnectionPhase.streaming);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));
    });

    test('in remote control a second pick adds a session beside the first, '
        'each tablet told its own mode', () async {
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      final [tabletA, tabletB] = tablets(['A', 'B']);
      final adb = SynthAdb([tabletA, tabletB]);
      final hub = await roomyHub(adb);
      expect(hub.cap, settings.maxTablets,
          reason: 'the mode no longer makes it one tablet at a time');
      expect(hub.cap, 4);

      await hub.connect(serial: 'A');
      final a = hub.focused!;
      final idA = a.nativeId;
      expect(hub.canAdd, isTrue);

      // The second one extends: the selectors moved on between the picks.
      await settings.setSessionMode(SessionMode.extendedScreen);
      await hub.connect(serial: 'B');
      final b = hub.focused!;
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
      expect(hub.sessions['A'], same(a), reason: 'A was not replaced');
      expect(a.nativeId, idA);
      expect(b.key, 'B');
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.usbSessionCount, 2);

      await _until(() => tabletA.mode != null && tabletB.mode != null);
      expect(tabletA.mode, SessionMode.remoteControl);
      expect(tabletA.direction, RemoteDirection.tabControlsMac);
      expect(tabletB.mode, SessionMode.extendedScreen);
      expect(tabletA.controls.where((c) => c == 0xF9), hasLength(1));
      expect(tabletB.controls.where((c) => c == 0xF9), hasLength(1));
      expect(
          a.choice,
          const SessionChoice(
              SessionMode.remoteControl, RemoteDirection.tabControlsMac));
      expect(b.choice.mode, SessionMode.extendedScreen);
      expect(adb.keysDelivered, {'A': 1, 'B': 1});
    });

    // With Maximum tablets 1 a pick still replaces, in remote control as in
    // any mode, in either direction.
    for (final direction in RemoteDirection.values) {
      test('with Maximum tablets 1, in remote control (${direction.name}), a '
          'second pick is refused while the first is live and replaces it '
          'once it is not, never showing disconnected', () async {
        Get.put<RemoteVideoChannel>(RecordingRemoteVideo());
        await settings.setMaxTablets(1);
        await settings.setSessionMode(SessionMode.remoteControl);
        await settings.setRemoteDirection(direction);
        final all = tablets(['A', 'B']);
        final a = all.first;
        final adb = SynthAdb(all);
        final hub = await roomyHub(adb);
        expect(hub.cap, 1);

        await hub.connect(serial: 'A');
        final first = hub.focused!;
        expect(first.spec.direction, direction);
        await hub.connect(serial: 'B');
        expect(hub.sessions.keys, ['A'], reason: 'A is live: refused');

        adb.unplugged.add('A');
        await a.hangUp();
        await _until(() => hub.phase.value == ConnectionPhase.error);
        // Ending A takes a while.
        adb.removeDelay = const Duration(milliseconds: 300);
        final phases = <ConnectionPhase>[];
        final worker = ever<ConnectionPhase>(hub.phase, phases.add);
        addTearDown(worker.dispose);
        await hub.connect(serial: 'B');
        expect(hub.sessions.keys, ['B']);
        expect(hub.phase.value, ConnectionPhase.streaming);
        expect(first.phase.value, ConnectionPhase.disconnected);
        expect(phases.first, ConnectionPhase.detectingDevice);
        expect(phases.last, ConnectionPhase.streaming);
        expect(phases, isNot(contains(ConnectionPhase.disconnected)));
        expect(hub.focused!.spec.direction, direction);
        await _until(() => all.last.mode != null);
        expect(all.last.mode, SessionMode.remoteControl);
        expect(all.last.direction, direction);
      });
    }

    test('a pick runs in the mode the selectors showed when it was made: a '
        'change while adb is still listing does not reach it', () async {
      final [tabletA] = tablets(['A']);
      final adb = _SlowListing([tabletA]);
      final hub = await roomyHub(adb);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);

      // Connect with nothing chosen: adb is asked what is attached first.
      adb.listing = Completer<void>();
      final connecting = hub.connect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(hub.sessions, isEmpty);
      expect(hub.phase.value, ConnectionPhase.detectingDevice);

      await settings.setSessionMode(SessionMode.extendedScreen);
      adb.listing!.complete();
      adb.listing = null;
      await connecting;

      final a = hub.sessions['A']!;
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(a.choice.mode, SessionMode.remoteControl);
      expect(a.spec.mode, SessionMode.remoteControl);
      await _until(() => tabletA.mode != null);
      expect(tabletA.mode, SessionMode.remoteControl);
      expect(settings.knownChoice('A')?.mode, SessionMode.remoteControl);
    });

    test('a tablet the hub connects by itself runs in the mode it is '
        'remembered in, one with none in the selectors\' as they stand then',
        () async {
      const reverse = SessionChoice(
          SessionMode.remoteControl, RemoteDirection.macControlsTab);
      Get.put<RemoteVideoChannel>(RecordingRemoteVideo());
      final [tabletA, tabletB] = tablets(['A', 'B']);
      final adb = SynthAdb([tabletA, tabletB]);
      final hub = await roomyHub(adb);
      await settings.rememberDevice('A', vdSerial: 0x10001, choice: reverse);
      await settings.rememberDevice('B', vdSerial: 0x10002);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);

      await hub.connectIfUnambiguous();
      await _until(() =>
          hub.sessions.length == 2 &&
          hub.sessions.values
              .every((s) => s.phase.value == ConnectionPhase.streaming));
      expect(hub.sessions['A']!.choice, reverse);
      expect(hub.sessions['A']!.spec.isReverseRemote, isTrue);
      expect(
          hub.sessions['B']!.choice,
          const SessionChoice(
              SessionMode.remoteControl, RemoteDirection.tabControlsMac));
      await _until(() => tabletA.mode != null && tabletB.mode != null);
      expect(tabletA.direction, RemoteDirection.macControlsTab);
      expect(tabletB.direction, RemoteDirection.tabControlsMac);
      // And B is remembered in it from now on.
      expect(settings.knownChoice('B'), hub.sessions['B']!.choice);
    });

    test('a link change back to USB brings a known tablet back in the mode '
        'it is remembered in, not in the one the selectors show', () async {
      const reverse = SessionChoice(
          SessionMode.remoteControl, RemoteDirection.macControlsTab);
      Get.put<RemoteVideoChannel>(RecordingRemoteVideo());
      final [tabletA] = tablets(['A']);
      final adb = SynthAdb([tabletA]);
      final hub = await roomyHub(adb);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      await hub.connect(serial: 'A');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(settings.knownChoice('A'), reverse);

      // The selectors move on, and the tablet's link drops.
      await settings.setSessionMode(SessionMode.extendedScreen);
      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() =>
          hub.sessions['A']!.phase.value == ConnectionPhase.error &&
          hub.sessions['A']!.retryPending.value);

      // Over to Wi-Fi while it waits to retry: the Mac listens instead, in
      // the selectors' mode (nothing is remembered for the Wi-Fi session).
      // No Wi-Fi identity in this test, so that session fails and retries.
      await settings.setLinkType(LinkType.wifi);
      await _until(() =>
          hub.sessions.keys.join() == HostConnectionManager.wifiKey);
      final wifi = hub.sessions[HostConnectionManager.wifiKey]!;
      expect(wifi.choice.mode, SessionMode.extendedScreen);
      await _until(() =>
          wifi.phase.value == ConnectionPhase.error && wifi.retryPending.value);

      // And back, the tablet plugged in again.
      adb.unplugged.remove('A');
      tabletA.mode = tabletA.direction = null;
      await settings.setLinkType(LinkType.usb);
      await _until(() =>
          hub.sessions['A']?.phase.value == ConnectionPhase.streaming);
      expect(hub.sessions.keys, ['A']);
      expect(hub.sessions['A']!.choice, reverse);
      await _until(() => tabletA.mode != null);
      expect(tabletA.mode, SessionMode.remoteControl);
      expect(tabletA.direction, RemoteDirection.macControlsTab);
      expect(settings.nextChoice.mode, SessionMode.extendedScreen);
    });

    test("the hub's own connect after a link change takes a tablet with no "
        'mode remembered in the mode the selectors showed as that connect '
        'began: a change while adb is still listing does not reach it',
        () async {
      const driving = SessionChoice(
          SessionMode.remoteControl, RemoteDirection.tabControlsMac);
      final [tabletA, tabletB] = tablets(['A', 'B']);
      final adb = _SlowListing([tabletA, tabletB])..unplugged.add('B');
      final hub = await roomyHub(adb);
      await hub.connect(serial: 'A');
      expect(hub.phase.value, ConnectionPhase.streaming);

      // A's link drops and it waits to retry; over to Wi-Fi meanwhile (no
      // Wi-Fi identity in this test, so that session fails and retries).
      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() =>
          hub.sessions['A']!.phase.value == ConnectionPhase.error &&
          hub.sessions['A']!.retryPending.value);
      await settings.setLinkType(LinkType.wifi);
      await _until(() =>
          hub.sessions.keys.join() == HostConnectionManager.wifiKey);
      final wifi = hub.sessions[HostConnectionManager.wifiKey]!;
      await _until(() =>
          wifi.phase.value == ConnectionPhase.error && wifi.retryPending.value);

      // Another tablet is plugged in, one the Mac has never had, and the
      // selectors say Tablet -> Mac. Back to USB: the hub connects by
      // itself, with no mode given, and adb takes its time listing.
      adb.unplugged.remove('B');
      await settings.setSessionMode(driving.mode);
      await settings.setRemoteDirection(driving.direction);
      expect(settings.knownChoice('B'), isNull);
      adb.listing = Completer<void>();
      await settings.setLinkType(LinkType.usb);
      await _until(() => adb.waiting == 1);
      expect(hub.sessions, isEmpty);

      // The selectors move on while it lists.
      await settings.setSessionMode(SessionMode.extendedScreen);
      adb.listing!.complete();
      adb.listing = null;
      await _until(() =>
          hub.sessions['B']?.phase.value == ConnectionPhase.streaming);
      expect(hub.sessions.keys, ['B']);
      expect(hub.sessions['B']!.choice, driving);
      await _until(() => tabletB.mode != null);
      expect(tabletB.mode, SessionMode.remoteControl);
      expect(tabletB.direction, RemoteDirection.tabControlsMac);
      expect(settings.knownChoice('B'), driving);
      expect(settings.nextChoice.mode, SessionMode.extendedScreen);
    });

    test('with no tablet attached, the tablet plugged in later runs in the '
        'mode the selectors showed at the Connect, not in one chosen while '
        'the hub was looking for it', () async {
      const driving = SessionChoice(
          SessionMode.remoteControl, RemoteDirection.tabControlsMac);
      final [tablet] = tablets(['NEW']);
      final adb = SynthAdb([tablet])..unplugged.add('NEW');
      final hub = await roomyHub(adb);
      await settings.setSessionMode(driving.mode);
      await settings.setRemoteDirection(driving.direction);

      await hub.connect();
      expect(hub.phase.value, ConnectionPhase.error);
      expect(hub.errorMessage.value, contains('No ADB device'));
      expect(hub.sessions, isEmpty);

      // The selectors move on, then the tablet is plugged in: the hub's
      // next look takes it.
      await settings.setSessionMode(SessionMode.extendedScreen);
      adb.unplugged.clear();
      await _until(
          () => hub.sessions['NEW']?.phase.value == ConnectionPhase.streaming,
          timeout: const Duration(seconds: 4));
      expect(hub.sessions['NEW']!.choice, driving);
      await _until(() => tablet.mode != null);
      expect(tablet.mode, SessionMode.remoteControl);
      expect(tablet.direction, RemoteDirection.tabControlsMac);
      expect(settings.knownChoice('NEW'), driving);
    });

    test('a pick past the cap is refused', () async {
      final adb = SynthAdb(tablets(['A', 'B', 'C', 'D', 'E']));
      final hub = await roomyHub(adb);
      for (final serial in ['A', 'B', 'C', 'D']) {
        await hub.connect(serial: serial);
        expect(hub.sessions[serial]?.phase.value, ConnectionPhase.streaming);
      }
      expect(hub.canAdd, isFalse);
      await hub.connect(serial: 'E');
      expect(hub.sessions.keys.toSet(), {'A', 'B', 'C', 'D'});
      expect(adb.keysDelivered['E'], isNull);
      expect(hub.activeDevice.value?.serial, 'D');
      expect(hub.phase.value, ConnectionPhase.streaming);
    });

    test('lowering Maximum tablets under the live count keeps them all and '
        'refuses another', () async {
      final adb = SynthAdb(tablets(['A', 'B', 'C']));
      final hub = await roomyHub(adb);
      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');

      await settings.setMaxTablets(1);
      await hub.connect(serial: 'C');
      await hub.connect(serial: 'A');
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
      expect(adb.keysDelivered, {'A': 1, 'B': 1});
      for (final s in hub.sessions.values) {
        expect(s.phase.value, ConnectionPhase.streaming);
      }
    });

    test('lowering Maximum tablets under the live count stops nobody at '
        'their next reconnect or retry either', () async {
      final all = tablets(['A', 'B', 'C']);
      final tabletB = all[1];
      final adb = SynthAdb(all);
      final hub = await roomyHub(adb);
      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');

      await settings.setMaxTablets(1);
      // A settings change: every tablet reconnects, each admitted again.
      await hub.reconnect();
      for (final key in ['A', 'B']) {
        final s = hub.sessions[key]!;
        expect(s.phase.value, ConnectionPhase.streaming, reason: key);
        expect(s.refused.value, isFalse, reason: key);
      }

      // B's link drops, and its retry comes back under the cap of one.
      final b = hub.sessions['B']!;
      await tabletB.hangUp();
      await _until(() => b.phase.value == ConnectionPhase.error);
      await _until(() => b.phase.value == ConnectionPhase.streaming);
      expect(b.refused.value, isFalse);
      expect(hub.budget.count, 2);

      // A tablet new to the hub is still refused.
      await hub.connect(serial: 'C');
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
    });

    test("a running tablet's return keeps its resolution beside the place "
        'of a tablet that is unplugged, which still comes back, past a '
        'lowered cap', () async {
      const panel = ClientPanel(2960, 1848, 60);
      final tabletA = FakeTablet('A', panel: panel);
      final tabletB = FakeTablet('B', panel: panel);
      addTearDown(tabletA.hangUp);
      addTearDown(tabletB.hangUp);
      final adb = SynthAdb([tabletA, tabletB]);
      final hub = hubWith(adb);
      await hub.hostInfoReady;
      hub.budget.estimate = EncoderEstimate.forChip('Apple M3');
      await settings.setMaxTablets(2);
      await settings.setEncodePreset(EncodePreset.balanced);
      await settings.setCodec(CodecType.h265);

      // Both native on H.265, sharing by rate.
      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');
      final a = hub.sessions['A']!;
      final b = hub.sessions['B']!;
      expect(a.granted.value?.width, 2960);
      expect(b.granted.value?.width, 2960);

      // B's cable comes out: its session waits for it, keeping its place.
      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => b.errorKey.value == 'error_device_gone');
      expect(hub.budget.holds(b.nativeId), isTrue);

      // H.264 (two native tablets no longer fit) and a cap of one: A, the
      // only tablet running, comes back as it was, not at a size that would
      // leave room for B.
      await settings.setMaxTablets(1);
      await settings.setCodec(CodecType.h264);
      await hub.reconnect();
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(a.granted.value?.width, 2960);
      expect(b.errorKey.value, 'error_device_gone');

      // B plugged back in: a return, so neither the cap nor the encoder
      // refuses it; it fits beside A at a lower resolution.
      adb.unplugged.clear();
      await hub.retryNow('B');
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(b.refused.value, isFalse);
      expect(b.granted.value!.width, lessThan(2960));
      expect(a.granted.value?.width, 2960);
      expect(hub.budget.count, 2);
    });

    test('a pick of a tablet whose session is still ending waits for the end, '
        'then connects it anew', () async {
      final [tablet] = tablets(['A']);
      final adb = SynthAdb([tablet]);
      final hub = await roomyHub(adb);
      await hub.connect(serial: 'A');
      final old = hub.focused!;

      adb.removeDelay = const Duration(milliseconds: 300);
      var ended = false;
      final ending = hub.disconnectSession('A').then((_) => ended = true);
      final picking = hub.connect(serial: 'A');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.sessions['A'], isNull, reason: 'A is still ending');
      expect(hub.phase.value, ConnectionPhase.disconnected);
      await picking;
      expect(ended, isTrue);
      await ending;
      final renewed = hub.sessions['A']!;
      expect(renewed, isNot(same(old)));
      expect(renewed.nativeId, isNot(old.nativeId));
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(adb.keysDelivered, {'A': 2});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(adb.reverses['A'], isNotNull, reason: 'the old end removed nothing');
    });

    test('a settings reconnect restarts the live sessions and one waiting to '
        'retry, each the same session, and leaves a refused one', () async {
      final all = tablets(['A', 'B', 'C']);
      final tabletB = all[1];
      final adb = SynthAdb(all);
      final hub = await roomyHub(adb);
      await refuseC(hub);
      await hub.connect(serial: 'B');
      final a = hub.sessions['A']!;
      final b = hub.sessions['B']!;
      final ids = (a.nativeId, b.nativeId);

      // B's cable comes out; its retries wait for it (seconds apart by now).
      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => b.errorKey.value == 'error_device_gone');
      adb.unplugged.clear();
      final starts = capture.starts.length;

      final started = DateTime.now();
      await hub.reconnect();
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 1)),
          reason: "B did not wait for its retry");
      expect(hub.sessions['A'], same(a));
      expect(hub.sessions['B'], same(b));
      expect((a.nativeId, b.nativeId), ids);
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(capture.starts.length, starts + 2);
      final c = hub.sessions['C']!;
      expect(c.refused.value, isTrue);
      expect(c.phase.value, ConnectionPhase.error);
      expect(adb.keysDelivered['C'], 1);
    });

    test('a retry run now skips a refused session and runs a pending one',
        () async {
      final all = tablets(['A', 'B', 'C']);
      final tabletB = all[1];
      final adb = SynthAdb(all);
      final hub = await roomyHub(adb);
      await refuseC(hub);

      await hub.retryNow('C');
      expect(hub.sessions['C']!.refused.value, isTrue);
      expect(hub.sessions['C']!.phase.value, ConnectionPhase.error);
      expect(adb.keysDelivered['C'], 1);

      await hub.connect(serial: 'B');
      final b = hub.sessions['B']!;
      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => b.errorKey.value == 'error_device_gone');
      adb.unplugged.clear();
      await hub.retryNow('B');
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions['B'], same(b));
    });

    test('a link change ends the idle sessions, not while one is live, and '
        'does not listen after a refused one', () async {
      final adb = SynthAdb(tablets(['A', 'C']));
      final hub = await roomyHub(adb);
      await refuseC(hub);

      // Live: nothing ends.
      await settings.setLinkType(LinkType.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(hub.sessions.keys.toSet(), {'A', 'C'});
      await settings.setLinkType(LinkType.usb);

      await hub.disconnectSession('A');
      await settings.setLinkType(LinkType.wifi);
      await _until(() => hub.sessions.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hub.sessions, isEmpty, reason: 'C retried nothing, so no listen');
      expect(hub.phase.value, ConnectionPhase.disconnected);
    });

    test('a paused auto-connect, or a stopped Wi-Fi session, connects '
        'nothing', () async {
      final adb = SynthAdb(tablets(['A']));
      final hub = await roomyHub(adb);

      hub.pauseAutoConnect();
      await hub.connectIfUnambiguous();
      expect(hub.sessions, isEmpty, reason: 'one tablet, but paused');

      await settings.setLinkType(LinkType.wifi);
      await hub.connectIfUnambiguous();
      expect(hub.sessions, isEmpty);
      hub.allowDevice(HostConnectionManager.wifiKey);
      hub.stoppedDevices.add(HostConnectionManager.wifiKey);
      await hub.connectIfUnambiguous();
      expect(hub.sessions, isEmpty);
      expect(hub.phase.value, ConnectionPhase.disconnected);

      // Back on USB, nothing paused: the one tablet connects (started, not
      // waited for).
      await settings.setLinkType(LinkType.usb);
      await hub.connectIfUnambiguous();
      expect(hub.sessions.keys, ['A']);
      await _until(() => hub.phase.value == ConnectionPhase.streaming);
    });
  });

  group('the encoder and the virtual display', () {
    test('a lone tablet gets what its preset asks for, unshared', () async {
      final tablet = FakeTablet('SYN-1', panel: ultra);
      addTearDown(tablet.hangUp);
      final hub = hubWith(SynthAdb([tablet]));

      await hub.connect(serial: 'SYN-1');
      final session = hub.focused!;
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(capture.starts.single.fpsCeiling, isNull);
      expect(hub.refreshRateHz.value, 120, reason: '0xFB as today');
      expect(session.granted.value,
          const GrantedCapture(width: 2960, height: 1848, fps: 120, shared: false));
      expect(hub.budget.contains(session.nativeId), isTrue);

      await hub.disconnect();
      expect(hub.budget.count, 0, reason: 'its share went with it');
      expect(session.granted.value, isNull);
    });

    test("the tablet that was last used before keeps the virtual display's "
        "serial 1 and today's name; a new one gets a serial of its own, saved "
        'once it is live', () async {
      SharedPreferences.setMockInitialValues(
          {'last_device': 'OLD', 'last_device_name': 'SM_X920'});
      final upgraded = SettingsService();
      await upgraded.init();
      Get.delete<SettingsService>(force: true);
      settings = Get.put(upgraded);

      final old = FakeTablet('OLD');
      final fresh = FakeTablet('NEW', model: 'SM_X710');
      addTearDown(old.hangUp);
      addTearDown(fresh.hangUp);
      final hub = hubWith(SynthAdb([old, fresh]));

      await hub.connect(serial: 'OLD');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(capture.displays.single,
          (serialNum: 1, name: 'Extended Screen'));
      await hub.disconnect();

      final expected = SettingsService.fnv1a32('NEW') | 0x10000;
      await hub.refreshDevices();
      capture.startGate = Completer<void>();
      final connecting = hub.connect(serial: 'NEW');
      await _until(() => capture.displays.length == 2);
      expect(capture.displays.last,
          (serialNum: expected, name: 'Extended Screen – SM X710'));
      expect(settings.knownDevice('NEW'), isNull,
          reason: 'nothing is saved before the session is live');
      capture.startGate!.complete();
      await connecting;
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(settings.knownDevice('NEW')?.vdSerial, expected);
      expect(settings.knownDevice('OLD')?.vdSerial, 1);
      expect(settings.lastDeviceSerial, 'NEW');
    });

    test('Extend that falls back to the main display, or whose display was '
        'never made, says so', () async {
      final tablet = FakeTablet('SYN-1');
      addTearDown(tablet.hangUp);
      final hub = hubWith(SynthAdb([tablet]));

      capture.started = const CaptureStart(displayId: 1, fellBack: true);
      await hub.connect(serial: 'SYN-1');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.focused!.notice.value, 'error_extend_unavailable');

      await hub.disconnect();
      capture
        ..started = const CaptureStart(displayId: 1)
        ..display = const VirtualDisplayResult(displayId: 0, applied: false);
      await hub.connect(serial: 'SYN-1');
      expect(hub.focused!.notice.value, 'error_extend_unavailable');

      await hub.disconnect();
      capture.display = const VirtualDisplayResult(displayId: 5, applied: true);
      await hub.connect(serial: 'SYN-1');
      expect(hub.focused!.notice.value, isNull);
    });

    test('a capture that may show another display says so on its session',
        () async {
      final tablet = FakeTablet('SYN-1');
      addTearDown(tablet.hangUp);
      final hub = hubWith(SynthAdb([tablet]));
      await hub.connect(serial: 'SYN-1');

      capture.onCaptureMismatch!(hub.focused!.nativeId + 1000);
      expect(hub.focused!.notice.value, isNull, reason: 'another session');
      capture.onCaptureMismatch!(hub.focused!.nativeId);
      expect(hub.focused!.notice.value, 'error_extend_wrong_display');
    });

    for (final code in ['ENCODER_BUSY', 'ENCODER_FAILED']) {
      test('a lone tablet whose encoder fails to start ($code) still goes '
          'live, as it always has, and holds no share of the encoder',
          () async {
        final tablet = FakeTablet('SYN-1');
        addTearDown(tablet.hangUp);
        final hub = hubWith(SynthAdb([tablet]));
        capture.startError = PlatformException(code: code);

        await hub.connect(serial: 'SYN-1');
        final session = hub.focused!;
        expect(hub.phase.value, ConnectionPhase.streaming);
        expect(session.refused.value, isFalse);
        expect(hub.errorKey.value, isNull);
        expect(hub.budget.contains(session.nativeId), isFalse);
        expect(session.granted.value, isNull);
      });
    }
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
