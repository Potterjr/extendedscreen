import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/debug/loopback_preview_controller.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Several tablets' USB sessions side by side, built directly as the hub
/// holds them: one media queue, one set of adb rules and one encoder budget
/// between them; the last test goes through the hub itself. Real loopback
/// sockets and real time
/// (`testWidgets`' fake clock never completes real I/O), and the capture
/// channel's real frame demux behind a mocked `extended_screen/frames`.
/// Ids come from each session's `nativeId`; no test assumes one.

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

/// ScreenCaptureKit, stood in for, except for the frames: those come
/// through the real [ScreenCaptureChannel.framesFor] demux, tagged by the
/// test as the Swift plugin tags them. A start fails with [failCode] for
/// the sessions in [failing], and waits for its session's entry in
/// [startGates] (or for [holdNext], which the next start takes as its
/// gate). Each started capture's encoder keeps its rate as Swift's does
/// ([_Encoder]): a ceiling below it is reported at once, as Swift's
/// `onFrameRateChanged` would (to the session itself when it is in
/// [sessions], else through the hub's callback); a raised one only to a
/// fixed-rate encoder, while an adapting one (Max) climbs only once it has
/// been healthy for a while, which a test plays with [recover]. What was
/// done to each session is kept by id, and every call in [calls], in order;
/// a stop waits for its session's entry in [stopGates], a virtual display
/// for its entry in [displayGates].
class _Capture extends ScreenCaptureChannel {
  final failing = <int>{};
  String failCode = 'ENCODER_BUSY';
  final startGates = <int, Completer<void>>{};
  final stopGates = <int, Completer<void>>{};
  final displayGates = <int, Completer<void>>{};
  final calls = <(String, int)>[];
  Completer<void>? holdNext;
  final starts = <int, List<DisplayConfigModel>>{};
  final displaysMade = <int>[];
  final displaysRemoved = <int>[];
  final stops = <int>[];
  final ceilings = <(int, int)>[];
  final keyframeRequests = <int>[];

  /// Sessions whose virtual display is not made (id 0), and sessions whose
  /// start falls back to the main display (the plugin let the display go).
  final noDisplay = <int>{};
  final fallingBack = <int>{};

  /// The sessions whose encoders report rate changes, by id.
  final sessions = <int, HostSession>{};

  /// Each started capture's encoder, by id, from its start until its stop.
  final encoders = <int, _Encoder>{};

  void _report(int session, int fps) {
    final own = sessions[session];
    if (own != null) {
      own.frameRateChanged(fps);
    } else {
      onFrameRateChanged?.call(session, fps);
    }
  }

  /// [session]'s adapting encoder has been healthy long enough, and steps
  /// up one rung within its ceiling (Swift's adaptFrameRate), reporting
  /// it; [all] climbs every rung to the ceiling, one report each.
  void recover(int session, {bool all = true}) {
    final e = encoders[session];
    if (e == null) return;
    do {
      final up = e.ladder.where((r) => r > e.target);
      if (up.isEmpty) return;
      e.target = up.first;
      _report(session, e.target);
    } while (all);
  }

  /// What [getHostInfo] answers (null: the plugin can't say), once
  /// [hostInfoGate], if any, has completed.
  HostInfo? hostInfo;
  Completer<void>? hostInfoGate;

  @override
  Future<HostInfo?> getHostInfo() async {
    await hostInfoGate?.future;
    return hostInfo;
  }

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<VirtualDisplayResult> createVirtualDisplay(
    DisplayConfigModel config, {
    required int session,
    int serialNum = 1,
    String name = 'Extended Screen',
  }) async {
    displaysMade.add(session);
    calls.add(('createVirtualDisplay', session));
    await displayGates[session]?.future;
    if (noDisplay.contains(session)) {
      return const VirtualDisplayResult(displayId: 0, applied: false);
    }
    return const VirtualDisplayResult(displayId: 5, applied: true);
  }

  @override
  Future<CaptureStart> startCapture(
    DisplayConfigModel config, {
    required int session,
  }) async {
    (starts[session] ??= []).add(config);
    calls.add(('startCapture', session));
    // Set up before the start answers, as Swift's is: a ceiling sent while
    // the start is under way is applied once its timer runs.
    encoders[session] = _Encoder(config);
    final hold = holdNext;
    if (hold != null) {
      holdNext = null;
      startGates[session] = hold;
    }
    await startGates[session]?.future;
    if (failing.contains(session)) throw PlatformException(code: failCode);
    if (fallingBack.contains(session)) {
      return const CaptureStart(displayId: 1, fellBack: true);
    }
    return const CaptureStart(displayId: 5);
  }

  @override
  Future<void> setFrameRateCeiling(int fps, {required int session}) async {
    ceilings.add((session, fps));
    final e = encoders[session];
    if (e == null) return;
    // Swift's applyRequestedCeiling.
    final max = fps < e.start ? fps : e.start;
    if (max == e.max) return;
    e.max = max;
    if (e.target > max) {
      e.target = max;
      _report(session, max);
    } else if (!e.adaptive && e.target < max) {
      e.target = max;
      _report(session, max);
    }
  }

  @override
  Future<void> stopCapture({required int session}) async {
    calls.add(('stopCapture', session));
    encoders.remove(session);
    await stopGates[session]?.future;
    stops.add(session);
  }

  @override
  Future<void> removeVirtualDisplay({required int session}) async {
    calls.add(('removeVirtualDisplay', session));
    displaysRemoved.add(session);
  }

  @override
  Future<void> disposeSession({required int session}) async {}
  @override
  Future<void> requestIdr({required int session}) async {
    calls.add(('requestIdr', session));
    keyframeRequests.add(session);
  }

  @override
  Future<Map<String, double>> getDisplayBounds({required int session}) async =>
      {'x': 0, 'y': 0, 'w': 1280, 'h': 800};
}

/// One started capture's encoder rate, as Swift's CaptureSession keeps it:
/// [start] the rate it was started for, [max] that held to its ceiling,
/// [target] the rate it runs at.
class _Encoder {
  _Encoder(DisplayConfigModel config)
      : adaptive = config.adaptiveFps,
        start = config.refreshRate,
        max = config.fpsCeiling == null || config.fpsCeiling! > config.refreshRate
            ? config.refreshRate
            : config.fpsCeiling!,
        target = config.fpsCeiling == null ||
                config.fpsCeiling! > config.refreshRate
            ? config.refreshRate
            : config.fpsCeiling!;

  final bool adaptive;
  final int start;
  int max;
  int target;

  /// The rates it may run at now, lowest first: 30/45/60/90/120 and [max]
  /// itself, none above it.
  List<int> get ladder =>
      ({30, 45, 60, 90, 120, max}.where((r) => r <= max).toList()..sort());
}

/// The input plugin, recording which session every call names.
class _Input extends InputInjectChannel {
  final mice = <(int, MouseEventModel)>[];
  final releases = <int>[];

  @override
  Future<bool> requestAccessibility() async => true;
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  @override
  Future<void> releaseAll({required int session}) async =>
      releases.add(session);
  @override
  Future<void> injectMouse(
    MouseEventModel e,
    Map<String, double> displayBounds, {
    required int session,
  }) async => mice.add((session, e));

  int miceFor(int session) => mice.where((m) => m.$1 == session).length;
}

/// [SynthAdb] that counts every reverse rule asked for, by tablet.
class _CountingAdb extends SynthAdb {
  _CountingAdb(super.tablets);

  final reverseCalls = <String, int>{};

  /// Listings to give first, one per call (null: adb failed to list).
  final script = <List<DeviceModel>?>[];

  @override
  Future<List<DeviceModel>?> listDevicesOrNull() {
    if (script.isEmpty) return super.listDevicesOrNull();
    listings++;
    return Future.value(script.removeAt(0));
  }

  @override
  Future<bool> reverseForward({
    required String serial,
    required int localPort,
    required int remotePort,
  }) {
    reverseCalls[serial] = (reverseCalls[serial] ?? 0) + 1;
    return super.reverseForward(
      serial: serial,
      localPort: localPort,
      remotePort: remotePort,
    );
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A frame as the Swift plugin sends it: its session's id, then the bytes.
Uint8List _tagged(int session, List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out).setUint32(0, session);
  out.setRange(4, out.length, bytes);
  return out;
}

MouseEventModel _move(double x, double y) => MouseEventModel(
  normalizedX: x,
  normalizedY: y,
  button: MouseButton.left,
  action: MouseAction.move,
  timestampUs: DateTime.now().microsecondsSinceEpoch,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const framesChannel = EventChannel('extended_screen/frames');
  late _Capture capture;
  late _Input input;
  // The native frame stream's sink: set when the first capture listens.
  MockStreamHandlerEventSink? frameSink;

  /// Hands [bytes] to the capture channel as [session]'s encoder's frame.
  void encode(int session, List<int> bytes) =>
      frameSink!.success(_tagged(session, bytes));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    final settings = SettingsService();
    await settings.init();
    Get.put(settings);
    frameSink = null;
    messenger.setMockStreamHandler(
      framesChannel,
      MockStreamHandler.inline(onListen: (_, events) => frameSink = events),
    );
    capture = Get.put<ScreenCaptureChannel>(_Capture()) as _Capture;
    input = Get.put<InputInjectChannel>(_Input()) as _Input;
  });

  tearDown(() {
    messenger.setMockStreamHandler(framesChannel, null);
    Get.reset();
  });

  /// One queue, one set of tunnels and one budget for every session it
  /// makes, as the hub keeps them; [cap] tablets at once.
  ({
    _CountingAdb adb,
    EncodeBudget budget,
    HostSession Function(String serial) session,
  })
  rig(
    List<FakeTablet> tablets, {
    EncoderEstimate? estimate,
    int Function()? cap,
  }) {
    for (final t in tablets) {
      addTearDown(t.hangUp);
    }
    final adb = _CountingAdb(tablets);
    Get.put<AdbService>(adb);
    final pipeline = PipelineQueue();
    final tunnels = TabletTunnels();
    final budget = EncodeBudget(
      estimate ?? EncoderEstimate.forChip('Apple M3 Pro'),
    );
    HostSession session(String serial) {
      final s = HostSession(
        key: serial,
        link: LinkType.usb,
        serial: serial,
        pipeline: pipeline,
        tunnels: tunnels,
        adb: adb,
        budget: budget,
        cap: cap ?? () => 4,
        socket: SocketService(),
      );
      tunnels.claim(serial, s);
      capture.sessions[s.nativeId] = s;
      addTearDown(() async {
        await s.disconnect();
        s.dispose();
      });
      return s;
    }

    return (adb: adb, budget: budget, session: session);
  }

  test('a second tablet the encoder cannot take is refused for good: no '
      'retry, its display and tunnel gone, the first one untouched, until '
      'it is asked again', () async {
    final r = rig([FakeTablet('A'), FakeTablet('B')]);
    final adb = r.adb, budget = r.budget;
    final a = r.session('A');
    final b = r.session('B');

    await a.connect();
    expect(a.phase.value, ConnectionPhase.streaming);
    final ceilingA = budget.ceilings()[a.nativeId];
    expect(ceilingA, isNotNull);

    // B is admitted beside A, but its encoder can't be had: another
    // session's is in the way.
    capture.failing.add(b.nativeId);
    await b.connect();
    expect(b.phase.value, ConnectionPhase.error);
    expect(b.refused.value, isTrue);
    expect(b.retryPending.value, isFalse);
    expect(b.errorKey.value, 'error_encode_limit');
    expect(capture.displaysMade, contains(b.nativeId));
    expect(capture.displaysRemoved, contains(b.nativeId));
    expect(adb.reverses.keys, isNot(contains('B')));
    expect(budget.contains(b.nativeId), isFalse);
    expect(b.granted.value, isNull);

    // No retry comes (the first would have come after a second).
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(adb.reverseCalls['B'], 1);
    expect(b.phase.value, ConnectionPhase.error);

    // A runs on as it was.
    expect(a.phase.value, ConnectionPhase.streaming);
    expect(budget.ceilings(), {a.nativeId: ceilingA});
    final pushedToA = [
      for (final (id, fps) in capture.ceilings)
        if (id == a.nativeId) fps,
    ];
    expect(
      pushedToA.isEmpty || pushedToA.last == ceilingA,
      isTrue,
      reason: 'A ends at the ceiling it had: $pushedToA',
    );
    expect(capture.displaysRemoved, isNot(contains(a.nativeId)));
    expect(a.granted.value?.shared, isFalse, reason: 'B gave its share back');

    // Asked again, with room this time.
    capture.failing.clear();
    await b.connect();
    expect(b.phase.value, ConnectionPhase.streaming);
    expect(b.refused.value, isFalse);
    expect(b.errorKey.value, isNull);
    expect(budget.contains(b.nativeId), isTrue);
    expect(adb.reverseCalls['B'], 2);
    expect(a.granted.value?.shared, isTrue);
    expect(b.granted.value?.shared, isTrue);
  });

  test(
    'the cap refuses a tablet past it before anything is made for it',
    () async {
      // The default cap: one tablet.
      final r = rig([FakeTablet('A'), FakeTablet('B')], cap: () => 1);
      final a = r.session('A');
      final b = r.session('B');
      await a.connect();
      expect(a.phase.value, ConnectionPhase.streaming);

      await b.connect();
      expect(b.phase.value, ConnectionPhase.error);
      expect(b.refused.value, isTrue);
      expect(capture.displaysMade, isNot(contains(b.nativeId)));
      expect(capture.starts[b.nativeId], isNull);
      expect(r.adb.reverses.keys, ['A']);
    },
  );

  test(
    "a hello made with another tablet's key on B's port is turned away: "
    'B keeps waiting for its own key, and streams once adb delivers it',
    () async {
      final tabletA = FakeTablet('A');
      final tabletB = FakeTablet('B');
      final r = rig([tabletA, tabletB]);
      final adb = r.adb;
      final a = r.session('A');
      final b = r.session('B');
      await a.connect();
      expect(tabletA.trusted, isTrue);
      final keyA = tabletA.key;
      expect(keyA, isNotNull);
      final keysToA = adb.keysDelivered['A'];

      // adb is slow to hand B its key: B's session waits in handshaking.
      final gate = adb.deliveryGates['B'] = Completer<void>();
      final connecting = b.connect();
      await _until(
        () =>
            b.phase.value == ConnectionPhase.handshaking &&
            adb.reverses['B'] != null,
      );
      final portB = adb.reverses['B']!.local;

      // A key that opened A's session opens nothing on B's.
      expect(await tabletA.dialWith(portB, keyA), isFalse);
      expect(b.phase.value, ConnectionPhase.handshaking);
      expect(b.peerTrusted, isFalse);
      expect(adb.keysDelivered['B'], isNull, reason: 'still held by the gate');
      expect(
        adb.keysDelivered['A'],
        keysToA,
        reason: "A's session was not disturbed",
      );
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(tabletA.trusted, isTrue);

      gate.complete();
      await _until(() => b.phase.value == ConnectionPhase.streaming);
      await connecting;
      expect(tabletB.trusted, isTrue);
      expect(tabletB.key, adb.keys['B']);
      expect(adb.keysDelivered['A'], keysToA);
      expect(a.phase.value, ConnectionPhase.streaming);
    },
  );

  test("A failing in its handshake, or ending while its capture start is "
      "blocked, leaves B's link, frames and input as they were", () async {
    final tabletA = FakeTablet('A');
    final tabletB = FakeTablet('B');
    final r = rig([tabletA, tabletB]);
    final adb = r.adb;
    final a = r.session('A');
    final b = r.session('B');
    await b.connect();
    expect(b.phase.value, ConnectionPhase.streaming);
    tabletB.sendMouse(_move(0.5, 0.5));
    await _until(() => input.miceFor(b.nativeId) == 1);
    encode(b.nativeId, [0, 0, 0, 1, 0x65]);
    await _until(() => tabletB.frames == 1);
    final ratesB = [...tabletB.rates];

    void expectBUntouched(int frames, int mice) {
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(b.peerTrusted, isTrue);
      expect(tabletB.trusted, isTrue);
      expect(tabletB.frames, frames);
      expect(input.miceFor(b.nativeId), mice);
      expect(tabletB.rates, ratesB);
      expect(input.releases, isNot(contains(b.nativeId)));
      expect(capture.stops, isNot(contains(b.nativeId)));
      expect(capture.displaysRemoved, isNot(contains(b.nativeId)));
      expect(adb.reverses.keys, contains('B'));
    }

    // A's app is closed, so its key reaches nobody; something dials A's
    // port without one, and the key can't be delivered again either.
    adb.appOpen['A'] = false;
    final failing = a.connect();
    await _until(
      () =>
          a.phase.value == ConnectionPhase.handshaking &&
          adb.reverses['A'] != null,
    );
    expect(await tabletA.dialWith(adb.reverses['A']!.local, null), isFalse);
    await failing;
    expect(a.phase.value, ConnectionPhase.error);
    expect(a.errorKey.value, 'error_usb_key_not_delivered');
    expectBUntouched(1, 1);
    await a.disconnect();
    expect(adb.reverses.keys, ['B']);
    expectBUntouched(1, 1);

    // A again, its app open this time, but its capture start hangs: B's
    // frames still flow meanwhile (they don't wait for the media queue).
    adb.appOpen.remove('A');
    final startA = capture.startGates[a.nativeId] = Completer<void>();
    final connecting = a.connect();
    await _until(() => capture.starts[a.nativeId] != null);
    encode(b.nativeId, [0, 0, 0, 1, 0x41]);
    await _until(() => tabletB.frames == 2);

    // A is ended mid-start: its stop waits behind the start, then runs.
    final ending = a.disconnect();
    startA.complete();
    await ending;
    await connecting;
    expect(a.phase.value, ConnectionPhase.disconnected);
    expect(capture.stops, contains(a.nativeId));
    expect(r.budget.contains(a.nativeId), isFalse);
    expect(adb.reverses.keys, ['B']);
    expectBUntouched(2, 1);

    // And B carries on: its next frame and its next touch arrive.
    encode(b.nativeId, [0, 0, 0, 1, 0x41]);
    tabletB.sendMouse(_move(0.25, 0.75));
    await _until(() => tabletB.frames == 3 && input.miceFor(b.nativeId) == 2);
    expect(input.miceFor(a.nativeId), 0);
  });

  test("each session's frames reach its own tablet only, and a keyframe "
      "request reaches its own encoder only", () async {
    final tabletA = FakeTablet('A');
    final tabletB = FakeTablet('B');
    final r = rig([tabletA, tabletB]);
    final a = r.session('A');
    final b = r.session('B');
    await a.connect();
    await b.connect();
    expect(a.phase.value, ConnectionPhase.streaming);
    expect(b.phase.value, ConnectionPhase.streaming);

    final toA = tabletA.frameStream.first;
    encode(a.nativeId, [0, 0, 0, 1, 0x65, 0xAA]);
    expect(await toA, [0, 0, 0, 1, 0x65, 0xAA]);
    final toB = tabletB.frameStream.first;
    encode(b.nativeId, [0, 0, 0, 1, 0x41, 0xBB]);
    expect(await toB, [0, 0, 0, 1, 0x41, 0xBB]);
    // A session nobody has (a later one, or one already gone): dropped.
    encode(a.nativeId + b.nativeId + 100, [0, 0, 0, 1, 0x65]);
    for (var i = 0; i < 5; i++) {
      encode(a.nativeId, [0, 0, 0, 1, 0x41]);
    }
    await _until(() => tabletA.frames == 6);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(tabletB.frames, 1, reason: "A's frames never reach B");
    expect(tabletA.frames, 6);

    final before = capture.keyframeRequests.length;
    tabletB.requestKeyframe();
    await _until(() => capture.keyframeRequests.length > before);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(capture.keyframeRequests.sublist(before), [b.nativeId]);
  });

  test("each tablet's input names its own session, and A's end releases "
      "A's mouse state only", () async {
    final tabletA = FakeTablet('A');
    final tabletB = FakeTablet('B');
    final r = rig([tabletA, tabletB]);
    final a = r.session('A');
    final b = r.session('B');
    await a.connect();
    await b.connect();

    tabletA.sendMouse(_move(0.1, 0.1));
    tabletB.sendMouse(_move(0.9, 0.9));
    await _until(() => input.mice.length == 2);
    expect(input.miceFor(a.nativeId), 1);
    expect(input.miceFor(b.nativeId), 1);
    // The wire carries 32-bit floats.
    expect(
      input.mice.firstWhere((m) => m.$1 == a.nativeId).$2.normalizedX,
      closeTo(0.1, 1e-6),
    );
    expect(
      input.mice.firstWhere((m) => m.$1 == b.nativeId).$2.normalizedX,
      closeTo(0.9, 1e-6),
    );
    expect(input.releases, isEmpty);

    await a.disconnect();
    expect(input.releases, isNotEmpty);
    expect(input.releases.toSet(), {a.nativeId});

    tabletB.sendMouse(_move(0.5, 0.5));
    await _until(() => input.miceFor(b.nativeId) == 2);
    expect(b.phase.value, ConnectionPhase.streaming);
  });

  test(
    'tablets share the encoder live: a second one lowers the first '
    "one's ceiling without restarting it, and its leaving raises it",
    () async {
      const big = ClientPanel(2960, 1848, 120);
      const small = ClientPanel(2560, 1600, 60);
      final tabletA = FakeTablet('A', panel: big);
      final tabletB = FakeTablet('B', panel: small);
      // An encoder small enough that both tablets give up rate, though both
      // fit at their own resolution: 400 Mpx/s for either codec, on one
      // engine.
      final r = rig(
        [tabletA, tabletB],
        estimate: const EncoderEstimate(
          engines: 1,
          h264PerEngine: 400,
          h265PerEngine: 400,
        ),
      );
      final budget = r.budget;
      final a = r.session('A');
      final b = r.session('B');

      // Alone, A gets everything it asks for: Max at its panel's 120 Hz.
      await a.connect();
      expect(a.phase.value, ConnectionPhase.streaming);
      // The announcements cross the socket after the session is live; the
      // rate comes last.
      await _until(() => tabletA.rate != null);
      final startA = capture.starts[a.nativeId]!.single;
      expect(startA.refreshRate, 120);
      expect(startA.toMap().containsKey('fpsCeiling'), isFalse);
      expect(tabletA.codec, CodecType.h265);
      expect(tabletA.mode, SessionMode.extendedScreen);
      expect(tabletA.rates, [120]);
      expect(a.granted.value?.fps, 120);
      expect(a.granted.value?.shared, isFalse);
      final displaysForA = capture.displaysMade
          .where((id) => id == a.nativeId)
          .length;

      // B joins.
      await b.connect();
      expect(b.phase.value, ConnectionPhase.streaming);
      final ceilingA = budget.ceilings()[a.nativeId]!;
      final ceilingB = budget.ceilings()[b.nativeId]!;
      expect(ceilingA, lessThan(120));
      expect(capture.ceilings, contains((a.nativeId, ceilingA)));
      expect(
        capture.ceilings.where((c) => c.$1 == b.nativeId),
        isEmpty,
        reason: "B's ceiling travels in its start",
      );
      final startB = capture.starts[b.nativeId]!.single;
      final mapB = startB.toMap();
      expect(
        mapB['fpsCeiling'] != null || startB.scaleFactor < _scaleFor(small),
        isTrue,
        reason: 'B starts held down: $mapB',
      );
      expect(mapB['fpsCeiling'], ceilingB);
      expect(ceilingB, lessThan(60));
      await _until(() => tabletB.rate != null);
      expect(tabletB.rates, [ceilingB]);
      // A runs on with the same encoder and display: only its rate moved,
      // and its tablet was told.
      expect(capture.starts[a.nativeId], hasLength(1));
      expect(capture.stops, isNot(contains(a.nativeId)));
      expect(
        capture.displaysMade.where((id) => id == a.nativeId),
        hasLength(displaysForA),
      );
      await _until(() => tabletA.rates.length == 2);
      expect(tabletA.rates, [120, ceilingA]);
      expect(tabletA.rate, ceilingA);
      expect(a.granted.value?.fps, ceilingA);
      expect(a.granted.value?.shared, isTrue);
      expect(b.granted.value?.shared, isTrue);

      // B leaves: A may climb back to its own rate. Its Max encoder gets
      // the raised ceiling at once, but climbs (and reports) only once it
      // has been healthy for a while.
      await b.disconnect();
      expect(budget.ceilings(), {a.nativeId: 120});
      expect(capture.ceilings.last, (a.nativeId, 120));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.granted.value?.fps, ceilingA);
      expect(tabletA.rates, [120, ceilingA]);
      capture.recover(a.nativeId);
      await _until(() => tabletA.rate == 120);
      expect(a.granted.value?.fps, 120);
      expect(a.granted.value?.shared, isFalse);
      expect(capture.starts[a.nativeId], hasLength(1));
      expect(capture.stops, isNot(contains(a.nativeId)));
      expect(a.phase.value, ConnectionPhase.streaming);
    },
  );

  test(
    'a connect (the Retry its card offers, or a resume) while a reconnect '
    'tears down a session in error starts nothing beside it',
    () async {
      final tabletA = FakeTablet('A');
      final r = rig([tabletA]);
      final adb = r.adb;
      final a = r.session('A');
      await a.connect();
      expect(a.phase.value, ConnectionPhase.streaming);

      // The link is lost; a retry is armed, the device still known.
      await tabletA.hangUp();
      await _until(
        () => a.phase.value == ConnectionPhase.error && a.retryPending.value,
      );
      final reverses = adb.reverseCalls['A']!;

      // A settings change reconnects it; its teardown takes a while (adb
      // removing the rule), and meanwhile it still reads `error`, with no
      // retry pending.
      adb.removeDelay = const Duration(milliseconds: 600);
      final reconnecting = a.reconnect();
      expect(a.retryPending.value, isFalse);
      expect(a.phase.value, ConnectionPhase.error);
      unawaited(a.connect());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        adb.reverseCalls['A'],
        reverses,
        reason: 'no second attempt runs beside the reconnect',
      );

      adb.removeDelay = Duration.zero;
      await reconnecting;
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(adb.reverseCalls['A'], reverses + 1);
      expect(tabletA.trusted, isTrue);
    },
  );

  test(
    'a rebuild that fails gives its share back but keeps its place: the '
    'next one starts it as it was, never refused, even under a lowered cap',
    () async {
      var cap = 4;
      final r = rig([FakeTablet('A'), FakeTablet('B')], cap: () => cap);
      final budget = r.budget;
      final a = r.session('A');
      final b = r.session('B');
      await a.connect();
      await b.connect();
      expect(b.phase.value, ConnectionPhase.streaming);
      final firstA = capture.starts[a.nativeId]!.single;
      final firstB = capture.starts[b.nativeId]!.single;
      final grantedB = b.granted.value;

      // A wake while the displays are still dark: both rebuilds fail.
      capture
        ..failCode = 'NO_DISPLAY'
        ..failing.addAll({a.nativeId, b.nativeId});
      await a.rebuildCapture();
      await b.rebuildCapture();
      for (final s in [a, b]) {
        expect(budget.contains(s.nativeId), isFalse, reason: 'no encoder');
        expect(budget.holds(s.nativeId), isTrue, reason: 'its place kept');
        expect(s.granted.value, isNull, reason: 'nothing is captured');
      }

      // Maximum tablets lowered meanwhile (it stops nobody); the next wake
      // rebuilds them in the other order.
      cap = 1;
      capture.failing.clear();
      await b.rebuildCapture();
      await a.rebuildCapture();
      for (final (s, first) in [(a, firstA), (b, firstB)]) {
        final again = capture.starts[s.nativeId]!.last;
        expect(again.encodedWidth, first.encodedWidth);
        expect(again.encodedHeight, first.encodedHeight);
        expect(s.notice.value, isNull);
        expect(s.phase.value, ConnectionPhase.streaming);
      }
      expect(b.granted.value, grantedB);
    },
  );

  test(
    "a rebuild after B's stream stopped that fails gives B's share to A at "
    'once: A climbs back to its own rate, and B shows no grant',
    () async {
      const panel = ClientPanel(2960, 1848, 120);
      final r = rig(
        [FakeTablet('A', panel: panel), FakeTablet('B', panel: panel)],
        // Small enough that two tablets give up rate.
        estimate: const EncoderEstimate(
          engines: 1,
          h264PerEngine: 400,
          h265PerEngine: 400,
        ),
      );
      final budget = r.budget;
      final a = r.session('A');
      final b = r.session('B');
      await a.connect();
      await b.connect();
      expect(b.phase.value, ConnectionPhase.streaming);
      final shared = budget.ceilings()[a.nativeId]!;
      expect(shared, lessThan(120));
      await _until(() => a.granted.value?.fps == shared);

      // B's stream stops with an error while the displays are awake, and
      // its rebuild fails: nothing else will come to rebuild it.
      capture
        ..failCode = 'SCK_ERROR'
        ..failing.add(b.nativeId);
      await b.rebuildCapture();
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(b.granted.value, isNull);
      expect(budget.ceilings(), {a.nativeId: 120});
      expect(capture.ceilings.last, (a.nativeId, 120));
      expect(a.granted.value?.fps, shared,
          reason: 'its Max encoder climbs once healthy, not at once');
      capture.recover(a.nativeId);
      await _until(() => a.granted.value?.fps == 120);
      expect(a.granted.value?.shared, isFalse);
      expect(budget.count, 1, reason: "the load is A's alone");
      expect(budget.holds(b.nativeId), isTrue);

      // The next rebuild that works brings it back beside A.
      capture.failing.clear();
      await b.rebuildCapture();
      expect(budget.contains(b.nativeId), isTrue);
      expect(budget.ceilings()[a.nativeId], shared);
      expect(b.granted.value?.shared, isTrue);
    },
  );

  group('a ceiling raised while a capture starts', () {
    const big = ClientPanel(2960, 1848, 120);
    const small = ClientPanel(2560, 1600, 60);

    /// A alone, then B beside it, sharing an encoder small enough that B
    /// starts held down; [hold] keeps B's start at one of its native steps.
    Future<(HostSession, HostSession, FakeTablet, Future<void>, int)> joinB(
      Map<int, Completer<void>> Function() gates,
    ) async {
      final tabletB = FakeTablet('B', panel: small);
      final r = rig(
        [FakeTablet('A', panel: big), tabletB],
        estimate: const EncoderEstimate(
          engines: 1,
          h264PerEngine: 400,
          h265PerEngine: 400,
        ),
      );
      final a = r.session('A');
      final b = r.session('B');
      await a.connect();
      gates()[b.nativeId] = Completer<void>();
      final connecting = b.connect();
      await _until(() => r.budget.contains(b.nativeId));
      final held = r.budget.ceilings()[b.nativeId]!;
      expect(held, lessThan(60));
      return (a, b, tabletB, connecting, held);
    }

    test('while its display is made: the start carries the raised one', () async {
      final (a, b, tabletB, connecting, _) =
          await joinB(() => capture.displayGates);
      await _until(() => capture.displaysMade.contains(b.nativeId));

      // A leaves: B may run at its own rate.
      final ending = a.disconnect();
      capture.displayGates[b.nativeId]!.complete();
      await connecting;
      await ending;

      final start = capture.starts[b.nativeId]!.single;
      expect(start.toMap().containsKey('fpsCeiling'), isFalse);
      expect(b.granted.value?.fps, 60);
      await _until(() => tabletB.rate != null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tabletB.rate, 60);
    });

    test('after its start was sent: the tablet is told the rate the encoder '
        'reported, not the one it started at', () async {
      final (a, b, tabletB, connecting, held) =
          await joinB(() => capture.startGates);
      await _until(() => capture.calls.contains(('startCapture', b.nativeId)));
      expect(capture.starts[b.nativeId]!.single.fpsCeiling, held);

      // A leaves: the raise reaches B's encoder, which climbs to it (once
      // healthy) and reports it while the start is still under way.
      final ending = a.disconnect();
      await _until(() => capture.ceilings.contains((b.nativeId, 60)));
      capture.recover(b.nativeId);
      capture.startGates[b.nativeId]!.complete();
      await connecting;
      await ending;

      await _until(() => tabletB.rate != null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tabletB.rate, 60);
      expect(b.refreshRateHz.value, 60);
      expect(b.granted.value?.fps, 60);
    });
  });

  test("through the hub: ending A while B's capture start is blocked leaves "
      'B alone, and A goes once that start is through', () async {
    final tabletA = FakeTablet('A');
    final tabletB = FakeTablet('B');
    addTearDown(tabletA.hangUp);
    addTearDown(tabletB.hangUp);
    final adb = _CountingAdb([tabletA, tabletB]);
    Get.put<AdbService>(adb);
    final hub = HostConnectionManager(adb: adb);
    addTearDown(hub.disconnect);
    await hub.hostInfoReady;
    hub.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');

    await hub.connect(serial: 'A');
    final a = hub.sessions['A']!;
    expect(a.phase.value, ConnectionPhase.streaming);

    // B's capture start hangs, holding the media queue.
    final gate = capture.holdNext = Completer<void>();
    final connectingB = hub.connect(serial: 'B');
    await _until(() => capture.holdNext == null);
    final b = hub.sessions['B']!;
    expect(hub.focused, same(b));
    expect(b.phase.value, ConnectionPhase.configuring);

    // A ends: out of reach at once, its stop queued behind B's start.
    final endingA = hub.disconnectSession('A', userStopped: true);
    expect(hub.sessions.keys, ['B']);
    expect(hub.focused, same(b));
    expect(hub.stoppedDevices, {'A'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(capture.stops, isNot(contains(a.nativeId)));
    expect(
      b.phase.value,
      ConnectionPhase.configuring,
      reason: "A's end cancelled nothing of B's",
    );

    gate.complete();
    await connectingB;
    await endingA;
    expect(b.phase.value, ConnectionPhase.streaming);
    expect(hub.phase.value, ConnectionPhase.streaming);
    expect(hub.activeDevice.value?.serial, 'B');
    expect(a.phase.value, ConnectionPhase.disconnected);
    expect(capture.stops, contains(a.nativeId));
    // B's display was made while A's still existed (FB17797423): once the
    // start is through, B's capture is made again, in a round of its own
    // behind A's stop, so after A's display has gone. Once.
    await _until(
      () => capture.displaysMade.where((id) => id == b.nativeId).length == 2,
    );
    await hub.pipeline.run(() async {});
    await pumpEventQueue();
    expect(capture.stops.where((id) => id == b.nativeId).length, 1);
    expect(
      capture.calls.lastIndexOf(('createVirtualDisplay', b.nativeId)),
      greaterThan(
        capture.calls.indexOf(('removeVirtualDisplay', a.nativeId)),
      ),
    );
    expect(capture.displaysMade.where((id) => id == b.nativeId).length, 2);
    expect(b.phase.value, ConnectionPhase.streaming);
    expect(input.releases.toSet(), {a.nativeId});
    expect(adb.reverses.keys, ['B']);
    expect(hub.budget.contains(a.nativeId), isFalse);
    expect(hub.budget.contains(b.nativeId), isTrue);

    // B carries on: its frames and its touches arrive.
    encode(b.nativeId, [0, 0, 0, 1, 0x65]);
    tabletB.sendMouse(_move(0.5, 0.5));
    await _until(() => tabletB.frames == 1 && input.miceFor(b.nativeId) == 1);
    expect(input.miceFor(a.nativeId), 0);
  });

  group("learning the encoder's capacity through the hub", () {
    // What one Tab S10 Ultra ran with H.265 on the owner's M3 Pro: 656
    // Mpx/s, past the estimate's usable 467.5.
    const ultra = ClientPanel(2960, 1848, 120);
    const ultraPx = 2960 * 1848;
    const ultraAt120 = ultraPx * 120 / 1e6;

    /// A call from the capture plugin, as Swift makes it.
    Future<void> fromCapture(String method, Object? args) async {
      final done = Completer<void>();
      await messenger.handlePlatformMessage(
        'extended_screen/screen_capture',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) => done.complete(),
      );
      await done.future;
    }

    Future<HostConnectionManager> hubFor(
      List<FakeTablet> tablets, {
      Duration window = const Duration(milliseconds: 300),
      Duration probeTimeout = const Duration(seconds: 60),
      bool readChip = true,
    }) async {
      for (final t in tablets) {
        addTearDown(t.hangUp);
      }
      final adb = _CountingAdb(tablets);
      Get.put<AdbService>(adb);
      final hub = HostConnectionManager(
          adb: adb, capacityWindow: window, probeTimeout: probeTimeout);
      addTearDown(hub.disconnect);
      if (readChip) await hub.hostInfoReady;
      return hub;
    }

    /// Swift's once-a-second onEncoderStats for [s], every 50 ms until
    /// cancelled: its encoder handing back [encodedShare] of the rate it
    /// runs at, and the screen delivering [captured] frames a second.
    Timer feedStats(HostSession s,
        {double encodedShare = 1, double captured = 30}) {
      final t = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final fps = s.granted.value?.fps;
        if (fps == null) return;
        unawaited(fromCapture('onEncoderStats', {
          'session': s.nativeId,
          'encoded': fps * encodedShare,
          'captured': captured,
        }));
      });
      addTearDown(t.cancel);
      return t;
    }

    test('a tablet seen healthy at its ceiling for the whole window raises '
        "the capacity, saved for this chip, and a second tablet's grant "
        'is higher for it', () async {
      final settings = Get.find<SettingsService>();
      capture.hostInfo = const HostInfo(chip: 'Apple M3 Pro', os: '15.5');
      final hub = await hubFor(
          [FakeTablet('A', panel: ultra), FakeTablet('B', panel: ultra)]);
      expect(hub.budget.capacity(CodecType.h265), 550);
      final changesBefore = hub.capacityChanges.value;

      await hub.connect(serial: 'A');
      final a = hub.sessions['A']!;
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(a.granted.value?.fps, 120);
      expect(hub.budget.load, greaterThan(1.0), reason: 'encoder 119%');
      expect(hub.measuringCapacity, isTrue);
      final stats = feedStats(a);

      await _until(() => hub.budget.isLearned(CodecType.h265));
      stats.cancel();
      expect(hub.budget.capacity(CodecType.h265),
          closeTo(ultraAt120 / 0.85, 1e-6));
      expect(hub.budget.load, closeTo(0.85, 1e-9));
      expect(hub.capacityChanges.value, greaterThan(changesBefore));
      expect(settings.encoderCapacityFor('Apple M3 Pro', CodecType.h265),
          closeTo(ultraAt120 / 0.85, 1e-6));
      expect(settings.encoderCapacityFor('Apple M3 Pro', CodecType.h264),
          isNull);
      expect(a.granted.value?.fps, 120, reason: 'nothing restarted');
      expect(capture.starts[a.nativeId], hasLength(1));

      // The Tab dropped to 45 next to the AVD before; against the estimate
      // two such tablets get 45 and 30. Now both get 60.
      await hub.connect(serial: 'B');
      final b = hub.sessions['B']!;
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.budget.ceilings(), {a.nativeId: 60, b.nativeId: 60});
      expect(b.granted.value?.fps, 60);
      expect(capture.starts[b.nativeId]!.single.fpsCeiling, 60);
      expect(capture.ceilings, contains((a.nativeId, 60)));
      expect(a.granted.value?.fps, 60);
    });

    test('the window must be unbroken: a step-down inside it teaches '
        'nothing, and the window starts again once back at the ceiling',
        () async {
      final hub = await hubFor([FakeTablet('A', panel: ultra)],
          window: const Duration(milliseconds: 1000));
      hub.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');
      await hub.connect(serial: 'A');
      final a = hub.sessions['A']!;
      expect(a.granted.value?.fps, 120);
      feedStats(a);

      // Halfway through, the encoder steps down (alone: nothing to lower),
      // and later back up.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await fromCapture('onFrameRateChanged',
          {'session': a.nativeId, 'fps': 90, 'achieved': 84.0});
      expect(a.granted.value?.fps, 90);
      expect(hub.measuringCapacity, isFalse);
      await fromCapture(
          'onFrameRateChanged', {'session': a.nativeId, 'fps': 120});
      expect(hub.measuringCapacity, isTrue);

      // Past where the first window would have ended: nothing learned.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(hub.budget.isLearned(CodecType.h265), isFalse);
      // The new window, unbroken, does.
      await _until(() => hub.budget.isLearned(CodecType.h265));
      expect(hub.budget.capacity(CodecType.h265),
          closeTo(ultraAt120 / 0.85, 1e-6));
    });

    test('a capacity learned on an earlier run is loaded with the chip, and '
        "pushed to the running tablets' encoders live", () async {
      final settings = Get.find<SettingsService>();
      // Mirror: B joining beside A makes no virtual display, so no display
      // round restarts B and what reaches it is the live push alone.
      await settings.setDisplayMode(DisplayMode.mirror);
      // An unknown chip: the conservative 140 Mpx/s, and 200 learned.
      const chip = 'Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz';
      await settings.setEncoderCapacityFor(chip, CodecType.h265, 200);
      capture.hostInfo = const HostInfo(chip: chip, os: '14.6');
      final gate = capture.hostInfoGate = Completer<void>();
      const small = ClientPanel(1280, 800, 60);
      final hub = await hubFor(
        [FakeTablet('A', panel: small), FakeTablet('B', panel: small)],
        readChip: false,
      );
      expect(hub.budget.capacity(CodecType.h265), 140);

      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');
      final a = hub.sessions['A']!, b = hub.sessions['B']!;
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.budget.ceilings(), {a.nativeId: 60, b.nativeId: 45});
      final changesBefore = hub.capacityChanges.value;

      gate.complete();
      await hub.hostInfoReady;
      expect(hub.budget.capacity(CodecType.h265), 200);
      expect(hub.budget.isLearned(CodecType.h265), isTrue);
      expect(hub.budget.ceilings(), {a.nativeId: 60, b.nativeId: 60});
      expect(capture.ceilings.last, (b.nativeId, 60));
      // B's Max encoder has its ceiling raised, and climbs to it only once
      // it has been healthy for a while; until then B shows 45.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.granted.value?.fps, 45);
      capture.recover(b.nativeId);
      await _until(() => b.granted.value?.fps == 60);
      expect(capture.starts[b.nativeId], hasLength(1), reason: 'live');
      expect(hub.capacityChanges.value, greaterThan(changesBefore));
      expect(hub.hostInfo.value?.chip, chip);
    });

    test('an overload while two tablets share the encoder lowers what was '
        'learned to what they achieved, saved, and pushed; one alone lowers '
        'nothing', () async {
      final settings = Get.find<SettingsService>();
      await settings.setEncoderCapacityFor('Apple M3 Pro', CodecType.h265, 1000);
      capture.hostInfo = const HostInfo(chip: 'Apple M3 Pro', os: '15.5');
      final hub = await hubFor(
          [FakeTablet('A', panel: ultra), FakeTablet('B', panel: ultra)]);
      expect(hub.budget.capacity(CodecType.h265), 1000);

      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');
      final a = hub.sessions['A']!, b = hub.sessions['B']!;
      expect(hub.budget.ceilings(), {a.nativeId: 90, b.nativeId: 60});

      // A's encoder managed 70 fps beside B's 60, and steps down.
      await fromCapture('onFrameRateChanged',
          {'session': a.nativeId, 'fps': 60, 'achieved': 70.0});
      const achieved = ultraPx * (70 + 60) / 1e6;
      expect(hub.budget.capacity(CodecType.h265), closeTo(achieved, 1e-9));
      expect(settings.encoderCapacityFor('Apple M3 Pro', CodecType.h265),
          closeTo(achieved, 1e-9));
      final ceilings = hub.budget.ceilings();
      expect(ceilings, {a.nativeId: 60, b.nativeId: 45});
      expect(capture.ceilings, contains((b.nativeId, 45)));
      await _until(() => b.granted.value?.fps == 45);

      // Alone, A's own encoder looks after itself: nothing is lowered.
      await hub.disconnectSession('B');
      await fromCapture('onFrameRateChanged',
          {'session': a.nativeId, 'fps': 45, 'achieved': 10.0});
      expect(hub.budget.capacity(CodecType.h265), closeTo(achieved, 1e-9));
    });

    test('a rate granted is not proof: an encoder handing back too few '
        'frames, or a screen that never changes, teaches nothing; encoding '
        'at the rate with the screen changing does', () async {
      capture.hostInfo = const HostInfo(chip: 'Apple M3 Pro', os: '15.5');
      final hub = await hubFor([FakeTablet('A', panel: ultra)]);
      await hub.connect(serial: 'A');
      final a = hub.sessions['A']!;
      expect(a.granted.value?.fps, 120);

      // No reports at all, then an encoder refusing every frame (a sleep
      // invalidated it: its ticks still look healthy), then one short of
      // the rate, then a static screen: three windows each.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(hub.budget.isLearned(CodecType.h265), isFalse);
      for (final (share, captured) in [(0.0, 30.0), (0.9, 30.0), (1.0, 0.0)]) {
        final stats = feedStats(a, encodedShare: share, captured: captured);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        stats.cancel();
        expect(hub.budget.isLearned(CodecType.h265), isFalse,
            reason: 'encoded $share of the rate, screen at $captured fps');
      }

      feedStats(a);
      await _until(() => hub.budget.isLearned(CodecType.h265));
      expect(hub.budget.capacity(CodecType.h265),
          closeTo(ultraAt120 / 0.85, 1e-6));
    });

    group('with two tablets, where every ceiling fits what is known', () {
      // The owner's AVD and Tab S10 Ultra: the AVD first, the Tab held
      // down beside it by the M3 Pro's estimate.
      const avd = ClientPanel(2152, 2076, 60);
      late HostConnectionManager hub;
      late HostSession a, b;
      late Map<int, int> rule;

      Future<void> twoTablets({
        Duration probeTimeout = const Duration(seconds: 60),
      }) async {
        // Mirror: no display rounds restart anyone.
        await Get.find<SettingsService>().setDisplayMode(DisplayMode.mirror);
        capture.hostInfo = const HostInfo(chip: 'Apple M3 Pro', os: '15.5');
        hub = await hubFor(
          [FakeTablet('A', panel: avd), FakeTablet('B', panel: ultra)],
          probeTimeout: probeTimeout,
        );
        await hub.connect(serial: 'A');
        await hub.connect(serial: 'B');
        a = hub.sessions['A']!;
        b = hub.sessions['B']!;
        rule = hub.budget.ceilings();
        expect(rule[b.nativeId], lessThan(120));
        await _until(() => a.granted.value?.fps == rule[a.nativeId] &&
            b.granted.value?.fps == rule[b.nativeId]);
      }

      HostSession probed() => hub.probe!.id == a.nativeId ? a : b;

      test('a window that teaches nothing probes one rung higher; once that '
          "encoder has climbed there and held it, the higher load is "
          'learned and saved', () async {
        await twoTablets();
        final statsA = feedStats(a), statsB = feedStats(b);
        await _until(() => hub.probe != null);
        final probe = hub.probe!;
        final session = probed();
        expect(hub.budget.isLearned(CodecType.h265), isFalse,
            reason: 'two tablets at what the rule allows prove nothing new');
        expect(probe.fps, greaterThan(rule[probe.id]!));
        expect(hub.budget.ceilings()[probe.id], probe.fps);
        expect(capture.ceilings.last, (probe.id, probe.fps));
        // Its Max encoder climbs only once it has been healthy a while.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(session.granted.value?.fps, rule[probe.id]);
        expect(hub.budget.isLearned(CodecType.h265), isFalse);

        capture.recover(probe.id, all: false);
        await _until(() => hub.budget.isLearned(CodecType.h265));
        statsA.cancel();
        statsB.cancel();
        expect(hub.budget.capacity(CodecType.h265),
            greaterThanOrEqualTo(probe.load.mpx / 0.85 - 1e-6));
        expect(
            Get.find<SettingsService>()
                .encoderCapacityFor('Apple M3 Pro', CodecType.h265),
            hub.budget.capacity(CodecType.h265));
        expect(session.granted.value?.fps, probe.fps);
        expect(hub.probe, isNull, reason: 'learned: the probe is over');
        expect(capture.starts[a.nativeId], hasLength(1));
        expect(capture.starts[b.nativeId], hasLength(1));
      });

      test('an overload during a probe ends it: the ceilings go back, '
          'nothing is learned, and that load is not probed again', () async {
        await twoTablets();
        feedStats(a);
        feedStats(b);
        await _until(() => hub.probe != null);
        final probe = hub.probe!;
        capture.recover(probe.id, all: false);
        await _until(() => probed().granted.value?.fps == probe.fps);

        await fromCapture('onFrameRateChanged', {
          'session': probe.id,
          'fps': rule[probe.id],
          'achieved': rule[probe.id]! - 2.0,
        });
        expect(hub.probe, isNull);
        expect(hub.budget.ceilings(), rule);
        expect(capture.ceilings.last, (probe.id, rule[probe.id]));
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(hub.probe, isNull, reason: 'the same load failed already');
        expect(hub.budget.isLearned(CodecType.h265), isFalse);
        expect(hub.budget.ceilings(), rule);
      });

      test('a probe whose encoder never climbs fails at its deadline',
          () async {
        await twoTablets(probeTimeout: const Duration(milliseconds: 600));
        feedStats(a);
        feedStats(b);
        await _until(() => hub.probe != null);
        final probe = hub.probe!;
        await _until(() => hub.probe == null);
        expect(hub.budget.ceilings(), rule);
        expect(capture.ceilings.last, (probe.id, rule[probe.id]));
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(hub.probe, isNull);
        expect(hub.budget.isLearned(CodecType.h265), isFalse);
      });
    });

    test('a synthetic tablet teaches nothing, and nothing is saved',
        () async {
      final prefs = await SharedPreferences.getInstance();
      capture.hostInfo = const HostInfo(chip: 'Apple M3 Pro', os: '15.5');
      final hub = await hubFor([FakeTablet('synth-1', panel: ultra)]);
      final before = {for (final k in prefs.getKeys()) k: prefs.get(k)};
      await hub.connect(serial: 'synth-1');
      final s = hub.sessions['synth-1']!;
      expect(s.phase.value, ConnectionPhase.streaming);
      expect(s.granted.value?.fps, 120);
      expect(hub.measuringCapacity, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(hub.budget.isLearned(CodecType.h265), isFalse);
      expect({for (final k in prefs.getKeys()) k: prefs.get(k)}, before);
    });
  });

  group('a wake with several tablets capturing', () {
    late HostConnectionManager hub;
    late HostSession a, b;

    /// A live session the hub holds, on the hub's media queue.
    HostSession adopted(String serial) {
      final s = HostSession(
        key: serial,
        link: LinkType.usb,
        serial: serial,
        pipeline: hub.pipeline,
        socket: SocketService(),
      )..phase.value = ConnectionPhase.streaming;
      hub.adopt(s);
      return s;
    }

    /// Until the media queue has nothing left to run, a rebuild's further
    /// rounds included.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await pumpEventQueue();
        await hub.pipeline.run(() async {});
      }
    }

    List<(String, int)> stop(HostSession s) => [
      ('stopCapture', s.nativeId),
      ('removeVirtualDisplay', s.nativeId),
    ];
    List<(String, int)> start(HostSession s) => [
      ('createVirtualDisplay', s.nativeId),
      ('startCapture', s.nativeId),
      ('requestIdr', s.nativeId),
    ];
    void wake() => capture.onCaptureRestartNeeded!(null);
    void streamStopped(HostSession s, {bool asleep = false}) =>
        capture.onCaptureRestartNeeded!(s.nativeId, asleep: asleep);

    setUp(() async {
      final adb = _CountingAdb([]);
      Get.put<AdbService>(adb);
      hub = HostConnectionManager(adb: adb, devicePollInterval: null);
      addTearDown(hub.disconnect);
      // B first: the wake goes by key, not by arrival.
      b = adopted('B');
      a = adopted('A');
      // Each one's capture runs, as after its connect.
      await a.rebuildCapture();
      await b.rebuildCapture();
      capture.calls.clear();
    });

    test('every tablet stops before any starts again, in key order', () async {
      wake();
      await settle();
      expect(capture.calls, [...stop(a), ...stop(b), ...start(a), ...start(b)]);
    });

    test(
      "a stream-stop heard before a tablet's start is the wake's to cover",
      () async {
        final gate = capture.stopGates[b.nativeId] = Completer<void>();
        wake();
        await _until(() => capture.calls.contains(('stopCapture', b.nativeId)));
        streamStopped(a);
        gate.complete();
        await settle();
        expect(capture.calls, [
          ...stop(a),
          ...stop(b),
          ...start(a),
          ...start(b),
        ]);
      },
    );

    test(
      "a stream-stop after a tablet's start gets one round of its own",
      () async {
        final gate = capture.startGates[b.nativeId] = Completer<void>();
        wake();
        await _until(
          () => capture.calls.contains(('startCapture', b.nativeId)),
        );
        streamStopped(a);
        gate.complete();
        await settle();
        expect(capture.calls, [
          ...stop(a), ...stop(b), ...start(a), ...start(b), //
          ...stop(a), ...start(a),
        ]);
      },
    );

    test('a tablet that ends during the stops is not started', () async {
      final gate = capture.stopGates[a.nativeId] = Completer<void>();
      wake();
      await _until(() => capture.calls.contains(('stopCapture', a.nativeId)));
      final ending = hub.disconnectSession('B');
      gate.complete();
      await ending;
      await settle();
      expect(
        capture.calls.where((c) => c.$2 == b.nativeId).map((c) => c.$1),
        isNot(contains('startCapture')),
      );
      expect(capture.calls.where((c) => c.$2 == a.nativeId), [
        ...stop(a),
        ...start(a),
      ]);
      expect(a.phase.value, ConnectionPhase.streaming);
    });

    test(
      'a second wake during the rebuild gets a full round after it',
      () async {
        final gate = capture.stopGates[a.nativeId] = Completer<void>();
        wake();
        await _until(() => capture.calls.contains(('stopCapture', a.nativeId)));
        wake();
        wake();
        gate.complete();
        await settle();
        final round = [...stop(a), ...stop(b), ...start(a), ...start(b)];
        expect(capture.calls, [...round, ...round]);
      },
    );

    test('a stream that stopped as the displays slept waits for the wake; '
        'with one tablet left it is rebuilt as it always was', () async {
      streamStopped(a, asleep: true);
      await settle();
      expect(capture.calls, isEmpty);

      await hub.disconnectSession('B');
      capture.calls.clear();
      streamStopped(a, asleep: true);
      await settle();
      expect(capture.calls, [...stop(a), ...start(a)]);

      capture.calls.clear();
      wake();
      await settle();
      expect(capture.calls, [
        ...stop(a),
        ...start(a),
      ], reason: "alone, a wake goes through the session's own rebuild");
    });
  });

  group('several virtual displays (FB17797423)', () {
    late HostConnectionManager hub;

    /// A live session the hub holds, on the hub's media queue and in its
    /// display set.
    HostSession adopted(String serial) {
      final s = HostSession(
        key: serial,
        link: LinkType.usb,
        serial: serial,
        pipeline: hub.pipeline,
        displays: hub.displays,
        socket: SocketService(),
      )..phase.value = ConnectionPhase.streaming;
      hub.adopt(s);
      return s;
    }

    /// Until the media queue has nothing left to run, the rounds a display
    /// change asks for (from a timer) included.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        await pumpEventQueue();
        await hub.pipeline.run(() async {});
      }
    }

    List<(String, int)> stop(HostSession s) => [
      ('stopCapture', s.nativeId),
      ('removeVirtualDisplay', s.nativeId),
    ];
    List<(String, int)> start(HostSession s) => [
      ('createVirtualDisplay', s.nativeId),
      ('startCapture', s.nativeId),
      ('requestIdr', s.nativeId),
    ];
    void mismatch(HostSession s) => capture.onCaptureMismatch!(s.nativeId);
    void matched(HostSession s) => capture.onCaptureMatched!(s.nativeId);

    setUp(() {
      final adb = _CountingAdb([]);
      Get.put<AdbService>(adb);
      hub = HostConnectionManager(adb: adb, devicePollInterval: null);
      addTearDown(hub.disconnect);
    });

    test('a display made beside another has the whole set taken down and '
        'made again in key order, once; alone, nothing more', () async {
      final b = adopted('B');
      final a = adopted('A');
      await b.rebuildCapture();
      await settle();
      expect(capture.calls, [...stop(b), ...start(b)],
          reason: 'one display alone asks for nothing');

      capture.calls.clear();
      await a.rebuildCapture();
      await settle();
      expect(capture.calls, [
        ...stop(a), ...start(a), // A joins beside B's display
        ...stop(a), ...stop(b), ...start(a), ...start(b),
      ]);
      expect(hub.displays.holders.toSet(), {a, b});

      // A session's own rebuild (its stream stopped) makes its display
      // beside the other's: the set is made again too.
      capture.calls.clear();
      await b.rebuildCapture();
      await settle();
      expect(capture.calls, [
        ...stop(b), ...start(b),
        ...stop(a), ...stop(b), ...start(a), ...start(b),
      ]);
    });

    test('several displays made before the round starts make one round',
        () async {
      final a = adopted('A');
      final b = adopted('B');
      final c = adopted('C');
      await a.rebuildCapture();
      await settle();
      capture.calls.clear();
      final both = Future.wait([c.rebuildCapture(), b.rebuildCapture()]);
      await both;
      await settle();
      expect(capture.calls, [
        ...stop(c), ...start(c), ...stop(b), ...start(b),
        ...stop(a), ...stop(b), ...stop(c),
        ...start(a), ...start(b), ...start(c),
      ]);
    });

    test('a Mirror capture beside an Extend one makes no display, and asks '
        'for nothing', () async {
      final settings = Get.find<SettingsService>();
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await settings.setDisplayMode(DisplayMode.mirror);
      await b.rebuildCapture();
      await settle();
      expect(capture.calls, [
        ...stop(a), ...start(a),
        ...stop(b), ('startCapture', b.nativeId), ('requestIdr', b.nativeId),
      ]);
      expect(hub.displays.holders, [a]);
      // Nor does a mismatch: the Extend one has no other display to be
      // confused with.
      mismatch(a);
      await settle();
      expect(a.notice.value, 'error_extend_wrong_display');
    });

    test("a wake's own displays ask for no further round", () async {
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await b.rebuildCapture();
      await settle();
      capture.calls.clear();
      capture.onCaptureRestartNeeded!(null);
      await settle();
      expect(capture.calls, [...stop(a), ...stop(b), ...start(a), ...start(b)]);
    });

    test('the display of a session on its way out goes before any display '
        'is made again', () async {
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await b.rebuildCapture();
      await settle();
      capture.calls.clear();

      // The queue is busy; B's first frame shows another display, and its
      // round is queued. Then A ends: its own stop queues behind the round.
      final busy = Completer<void>();
      final holding = hub.pipeline.run(() => busy.future);
      mismatch(b);
      await Future<void>.delayed(Duration.zero);
      final endingA = hub.disconnectSession('A');
      busy.complete();
      await holding;
      await endingA;
      await settle();
      expect(capture.calls.take(7), [...stop(a), ...stop(b), ...start(b)]);
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.displays.holders, [b]);
    });

    test('a capture showing another display rebuilds the set at most twice '
        'in a row, then says so; a capture showing its own resets that',
        () async {
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await b.rebuildCapture();
      await settle();
      capture.calls.clear();
      final round = [...stop(a), ...stop(b), ...start(a), ...start(b)];

      mismatch(b);
      await settle();
      expect(capture.calls, round);
      expect(b.notice.value, isNull);
      mismatch(b);
      await settle();
      expect(capture.calls, [...round, ...round]);
      expect(b.notice.value, isNull);
      mismatch(b);
      await settle();
      expect(capture.calls, [...round, ...round],
          reason: 'a third one in a row is only said');
      expect(b.notice.value, 'error_extend_wrong_display');

      // A start whose first frame shows its own display: the next wrong
      // one is rebuilt again.
      capture.calls.clear();
      matched(b);
      mismatch(b);
      await settle();
      expect(capture.calls, round);
      expect(b.notice.value, isNull);
    });

    test("a joiner's own first frame showing another display, heard while "
        'the round its join asked for runs, asks for no second round and '
        'counts nothing', () async {
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await settle();
      capture.calls.clear();

      // B joins beside A's display. The round it asks for stops A first,
      // which takes a while (A's display leaving), while B's join capture
      // still runs and its first frame shows A's display.
      final gate = capture.stopGates[a.nativeId] = Completer<void>();
      await b.rebuildCapture();
      await _until(() => capture.calls.contains(('stopCapture', a.nativeId)));
      mismatch(b);
      gate.complete();
      await settle();
      expect(capture.calls, [
        ...stop(b), ...start(b), // B joins
        ...stop(a), ...stop(b), ...start(a), ...start(b), // one round
      ]);
      expect(b.wrongDisplayRebuilds, 0);
      expect(b.notice.value, isNull);

      // A frame of the round's own capture of B that shows another display
      // is what still asks, and counts.
      capture.calls.clear();
      mismatch(b);
      await settle();
      expect(capture.calls,
          [...stop(a), ...stop(b), ...start(a), ...start(b)]);
      expect(b.wrongDisplayRebuilds, 1);
    });

    test("a joiner's first frame heard before its start has even returned "
        'is covered by the round that start asks for', () async {
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await settle();
      capture.calls.clear();

      final gate = capture.startGates[b.nativeId] = Completer<void>();
      final joining = b.rebuildCapture();
      await _until(() => capture.calls.contains(('startCapture', b.nativeId)));
      mismatch(b);
      gate.complete();
      capture.startGates.remove(b.nativeId);
      await joining;
      await settle();
      expect(capture.calls, [
        ...stop(b), ...start(b),
        ...stop(a), ...stop(b), ...start(a), ...start(b),
      ]);
      expect(b.wrongDisplayRebuilds, 0);
      expect(b.notice.value, isNull);
    });

    test('a join that gets no capture going on a display of its own (the '
        'encoder refuses it, no display is made, or it falls back to the '
        'main display) asks for no round: the extending tablet runs on '
        'untouched', () async {
      final a = adopted('A');
      final b = adopted('B');
      await a.rebuildCapture();
      await settle();

      for (final variant in ['refused', 'no display', 'fell back']) {
        capture
          ..calls.clear()
          ..failing.clear()
          ..noDisplay.clear()
          ..fallingBack.clear();
        switch (variant) {
          case 'refused':
            capture.failing.add(b.nativeId);
          case 'no display':
            capture.noDisplay.add(b.nativeId);
          default:
            capture.fallingBack.add(b.nativeId);
        }
        await b.rebuildCapture();
        await settle();
        expect(capture.calls.where((c) => c.$2 == a.nativeId), isEmpty,
            reason: variant);
        expect(a.phase.value, ConnectionPhase.streaming, reason: variant);
        // The next try starts from no display of B's, as a refused join
        // ends: B's own teardown would take it down.
        await hub.pipeline.run(() async {
          await capture.removeVirtualDisplay(session: b.nativeId);
          hub.displays.removed(b);
        });
      }
    });

    test('alone, a capture showing another display is only said', () async {
      final a = adopted('A');
      await a.rebuildCapture();
      await settle();
      capture.calls.clear();
      mismatch(a);
      await settle();
      expect(capture.calls, isEmpty);
      expect(a.notice.value, 'error_extend_wrong_display');
    });
  });

  group('the auto-connect policy and the device poll', () {
    const tick = Duration(milliseconds: 50);

    /// The hub over [tablets] (room for four, permissions granted), its
    /// device poll every [tick] once [HostConnectionManager.autoConnect]
    /// has run; [known] have had a live session before.
    Future<(HostConnectionManager, _CountingAdb)> hubOver(
      List<FakeTablet> tablets, {
      List<String> known = const [],
    }) async {
      for (final t in tablets) {
        addTearDown(t.hangUp);
      }
      final settings = Get.find<SettingsService>();
      for (final (i, serial) in known.indexed) {
        await settings.rememberDevice(serial, vdSerial: 0x10000 + i);
      }
      final adb = _CountingAdb(tablets);
      Get.put<AdbService>(adb);
      final hub = HostConnectionManager(
        adb: adb,
        devicePollInterval: tick,
        hostGranted: () async => true,
      );
      addTearDown(hub.disconnect);
      addTearDown(hub.stopPolling);
      await hub.hostInfoReady;
      hub.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');
      return (hub, adb);
    }

    bool streaming(HostConnectionManager hub, String key) =>
        hub.sessions[key]?.phase.value == ConnectionPhase.streaming;

    /// Lets the poll run [n] more listings.
    Future<void> ticks(_CountingAdb adb, int n) {
      final from = adb.listings;
      return _until(() => adb.listings >= from + n);
    }

    test(
      'a tablet the user stopped does not hold up another one plugged in',
      () async {
        final (hub, adb) = await hubOver(
          [FakeTablet('A'), FakeTablet('B')],
          known: ['A', 'B'],
        );
        adb.unplugged.add('B');
        await hub.autoConnect();
        await _until(() => streaming(hub, 'A'));

        await hub.disconnectSession('A', userStopped: true);
        adb.unplugged.clear();
        await _until(() => streaming(hub, 'B'));
        await ticks(adb, 3);
        expect(hub.sessions.keys, ['B']);
        expect(hub.stoppedDevices, {'A'});
      },
    );

    test('a session waiting for its unplugged tablet retries within a tick '
        'of the tablet coming back', () async {
      final tabletB = FakeTablet('B');
      final (hub, adb) = await hubOver([FakeTablet('A'), tabletB]);
      await hub.autoConnect();
      await hub.connect(serial: 'A');
      await hub.connect(serial: 'B');
      final b = hub.sessions['B']!;
      expect(b.phase.value, ConnectionPhase.streaming);

      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => b.errorKey.value == 'error_device_gone');
      // Its own next retry is two seconds or so away.
      adb.unplugged.clear();
      await _until(
        () => b.phase.value == ConnectionPhase.streaming,
        timeout: const Duration(milliseconds: 1200),
      );
      expect(hub.sessions['B'], same(b));
      expect(streaming(hub, 'A'), isTrue);
    });

    test('a tablet unplugged when it was the only one attached says so, '
        'and is retried within a tick of coming back', () async {
      final tabletB = FakeTablet('B');
      final (hub, adb) = await hubOver([tabletB]);
      await hub.autoConnect();
      await _until(() => streaming(hub, 'B'));
      final b = hub.sessions['B']!;

      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => b.errorKey.value == 'error_device_gone');
      adb.unplugged.clear();
      await _until(
        () => b.phase.value == ConnectionPhase.streaming,
        timeout: const Duration(milliseconds: 1200),
      );
      expect(hub.sessions['B'], same(b));
    });

    test('a Disconnect on one of two attached tablets does not make the '
        'other the only one: a new tablet still waits for a pick', () async {
      final (hub, _) = await hubOver([FakeTablet('A'), FakeTablet('B')]);
      await hub.autoConnect();
      expect(hub.sessions, isEmpty, reason: 'two new tablets wait');

      await hub.connect(serial: 'A');
      expect(streaming(hub, 'A'), isTrue);
      await hub.disconnectSession('A', userStopped: true);
      expect(hub.phase.value, ConnectionPhase.disconnected);

      // The app comes back to the front.
      await hub.connectIfUnambiguous();
      expect(hub.sessions, isEmpty);
    });

    test("a user's pick waiting for its tablet's old session to end keeps "
        'its place: a tablet plugged in meanwhile does not take it', () async {
      await Get.find<SettingsService>().setMaxTablets(2);
      final (hub, adb) = await hubOver(
        [FakeTablet('A'), FakeTablet('B'), FakeTablet('C')],
        known: ['A', 'B', 'C'],
      );
      adb.unplugged.add('C');
      await hub.autoConnect();
      await _until(() => streaming(hub, 'A') && streaming(hub, 'B'));

      // B's card: Disconnect; its end takes a while.
      adb.removeDelay = const Duration(milliseconds: 500);
      final ending = hub.disconnectSession('B', userStopped: true);
      // The user picks B again from the add panel.
      hub.allowDevice('B');
      final picking = hub.connect(serial: 'B');
      // C is plugged in: the policy runs for it.
      adb.unplugged.remove('C');
      await hub.connectIfUnambiguous(only: {'C'});
      expect(hub.sessions.keys, isNot(contains('C')));

      await ending;
      adb.removeDelay = Duration.zero;
      await picking;
      expect(streaming(hub, 'B'), isTrue);
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
    });

    test("a user's pick waiting for its tablet's old session to end holds "
        'one place, not two: the policy still starts a known tablet in the '
        'room left', () async {
      final settings = Get.find<SettingsService>();
      await settings.setMaxTablets(2);
      final (hub, adb) = await hubOver(
        [FakeTablet('A'), FakeTablet('B'), FakeTablet('C')],
        known: ['A', 'B', 'C'],
      );
      await hub.autoConnect();
      await _until(() => streaming(hub, 'A') && streaming(hub, 'B'));
      expect(hub.sessions.keys, isNot(contains('C')), reason: 'no room');
      // Raising the cap runs no policy: C waits.
      await settings.setMaxTablets(3);

      // B's card: Disconnect, then the user picks B again while its end
      // still runs.
      adb.removeDelay = const Duration(milliseconds: 500);
      final ending = hub.disconnectSession('B', userStopped: true);
      hub.allowDevice('B');
      final picking = hub.connect(serial: 'B');
      // The app comes back to the front: the whole policy runs.
      await hub.connectIfUnambiguous();
      expect(hub.sessions.keys, contains('C'));

      await ending;
      adb.removeDelay = Duration.zero;
      await picking;
      await _until(() => streaming(hub, 'C'));
      expect(streaming(hub, 'B'), isTrue);
      expect(hub.sessions.keys.toSet(), {'A', 'B', 'C'});
    });

    test('a session waiting for its tablet to dial in starts again when adb '
        'lists that tablet under a new transport (the cable re-seated), or '
        'misses it', () async {
      final tabletA = FakeTablet('A');
      final (hub, adb) = await hubOver([tabletA]);
      // The app on the tablet is not open: the key reaches nobody, and the
      // session waits for a dial.
      adb.transports['A'] = '7';
      adb.appOpen['A'] = false;
      await hub.autoConnect();
      await _until(() => hub.sessions['A'] != null);
      final a = hub.sessions['A']!;
      await _until(() => a.phase.value == ConnectionPhase.handshaking);
      expect(a.activeDevice.value?.transportId, '7');
      final reverses = adb.reverseCalls['A']!;

      // Re-seated: same serial, a new transport, and no reverse rule.
      adb.transports['A'] = '8';
      await _until(() => adb.reverseCalls['A'] == reverses + 1);
      await _until(() => a.phase.value == ConnectionPhase.handshaking);
      expect(a.activeDevice.value?.transportId, '8');
      expect(hub.sessions['A'], same(a));

      // Listed under the same transport: nothing more happens.
      await ticks(adb, 3);
      expect(adb.reverseCalls['A'], reverses + 1);

      // Unplugged: it says so, and connects once it is back and open.
      adb.unplugged.add('A');
      await _until(() => a.errorKey.value == 'error_device_gone');
      adb.appOpen.remove('A');
      adb.unplugged.clear();
      await _until(() => a.phase.value == ConnectionPhase.streaming);
      expect(hub.sessions['A'], same(a));
    });

    test('a session waiting for its tablet to dial in starts again only once '
        'two successive listings have missed the tablet, as the baseline '
        'counts a tablet gone', () async {
      final tabletA = FakeTablet('A');
      final (hub, adb) = await hubOver([tabletA]);
      adb.transports['A'] = '7';
      adb.appOpen['A'] = false;
      await hub.autoConnect();
      await _until(() => hub.sessions['A'] != null);
      final a = hub.sessions['A']!;
      await _until(() => a.phase.value == ConnectionPhase.handshaking);
      // The listings are the test's from here (the attempt waits about
      // three seconds for a dial: all this takes a few milliseconds).
      hub.stopPolling();
      final reverses = adb.reverseCalls['A']!;

      // adb hiccups: one listing misses A.
      adb.script.add(const []);
      await hub.refreshDevices();
      expect(a.phase.value, ConnectionPhase.handshaking);
      expect(adb.reverseCalls['A'], reverses);

      // Listed again: the count starts over, so the next miss is a first.
      await hub.refreshDevices();
      adb.script.add(const []);
      await hub.refreshDevices();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a.phase.value, ConnectionPhase.handshaking);
      expect(adb.reverseCalls['A'], reverses);

      // A second miss in a row: its transport is taken as gone.
      adb.script.add(const []);
      await hub.refreshDevices();
      await _until(() => adb.reverseCalls['A'] == reverses + 1);
      await _until(() => a.phase.value == ConnectionPhase.handshaking);
      expect(hub.sessions['A'], same(a));
    });

    test("a launch whose listings all failed connects the attached tablet "
        "on the poll's first listing", () async {
      final (hub, adb) = await hubOver([FakeTablet('A')]);
      adb.listingFails = true;
      await hub.autoConnect();
      expect(hub.sessions, isEmpty);

      adb.listingFails = false;
      await _until(() => streaming(hub, 'A'));
    });

    test(
      'after a Disconnect of everything, the poll connects nothing back',
      () async {
        final (hub, adb) = await hubOver(
          [FakeTablet('A'), FakeTablet('B')],
          known: ['A', 'B'],
        );
        await hub.autoConnect();
        await _until(() => streaming(hub, 'A') && streaming(hub, 'B'));

        // The remote view's Disconnect: no pause, nothing stopped.
        await hub.disconnect();
        await ticks(adb, 4);
        expect(hub.sessions, isEmpty);
        expect(hub.phase.value, ConnectionPhase.disconnected);
      },
    );

    test(
      'an empty listing followed by the full one connects nothing',
      () async {
        final tablets = [FakeTablet('A'), FakeTablet('B')];
        final (hub, adb) = await hubOver(tablets, known: ['A', 'B']);
        await hub.autoConnect();
        await _until(() => streaming(hub, 'A') && streaming(hub, 'B'));
        await hub.disconnect();

        // adb restarting: nothing listed for a moment, then everything.
        adb.script.addAll([[], []]);
        await ticks(adb, 5);
        expect(adb.script, isEmpty);
        expect(hub.sessions, isEmpty);
        expect(hub.availableDevices.map((d) => d.serial), ['A', 'B']);
      },
    );

    test(
      'a failed listing changes neither the list nor the sessions',
      () async {
        final (hub, adb) = await hubOver(
          [FakeTablet('A'), FakeTablet('B')],
          known: ['A'],
        );
        await hub.autoConnect();
        await _until(() => streaming(hub, 'A'));

        adb.listingFails = true;
        await ticks(adb, 3);
        await hub.refreshDevices();
        expect(hub.availableDevices.map((d) => d.serial), ['A', 'B']);
        expect(hub.sessions.keys, ['A']);
        expect(streaming(hub, 'A'), isTrue);
      },
    );

    test(
      "a tablet's wireless-debugging listing is not another tablet",
      () async {
        const mdns = 'adb-A-x1y2z3._adb-tls-connect._tcp';
        final (hub, adb) = await hubOver(
          [FakeTablet('A'), FakeTablet(mdns)],
          known: [mdns],
        );
        await hub.refreshDevices();
        expect(hub.freeDevices.map((d) => d.serial), ['A']);

        await hub.autoConnect();
        await _until(() => streaming(hub, 'A'));
        await ticks(adb, 3);
        expect(
          hub.sessions.keys,
          ['A'],
          reason: 'one tablet, connected once, though its other name is known',
        );
        expect(hub.freeDevices, isEmpty);
      },
    );
  });

  group('synthetic tablets in a debug build', () {
    const adbChannel = MethodChannel('extended_screen/adb');
    const remoteChannel = MethodChannel('extended_screen/remote_video');
    const nalChannel = 'extended_screen/remote_nal';

    tearDown(() {
      messenger.setMockMethodCallHandler(adbChannel, null);
      messenger.setMockMethodCallHandler(remoteChannel, null);
      messenger.setMockMessageHandler(nalChannel, null);
    });

    /// A call from the remote-video plugin, as Swift makes it.
    Future<void> fromDecoder(String method, Object? args) async {
      final done = Completer<void>();
      await messenger.handlePlatformMessage(
        remoteChannel.name,
        remoteChannel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) => done.complete(),
      );
      await done.future;
    }

    test('none without the define', () {
      expect(synthTabletCount, 0);
      expect(synthTablets, isFalse);
    });

    test('the routing adb lists real devices and then the synthetic ones, '
        'and sends each call to the side its serial belongs to', () async {
      final calls = <MethodCall>[];
      var listingFails = false;
      messenger.setMockMethodCallHandler(adbChannel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'listDevices':
            if (listingFails) throw PlatformException(code: 'ADB_TIMEOUT');
            return [
              {'serial': 'R5CX', 'model': 'SM_X920'},
            ];
          case 'shellScript':
            return 'Broadcast completed: result=1';
        }
        return null;
      });
      final synth = SyntheticTablets(2);
      for (final t in synth.tablets) {
        addTearDown(t.hangUp);
      }
      final adb = synth.adb;
      expect(synth.tablets.map((t) => t.serial), ['synth-1', 'synth-2']);
      expect(
        synth.tablets.map((t) => t.panel),
        SyntheticTablets.panels.take(2),
      );

      final listed = await adb.listDevicesOrNull();
      expect(listed!.map((d) => d.serial), ['R5CX', 'synth-1', 'synth-2']);
      expect(listed.first.model, 'SM_X920');
      // adb failing to list says nothing new about the real tablet.
      listingFails = true;
      expect((await adb.listDevicesOrNull())!.map((d) => d.serial), [
        'R5CX',
        'synth-1',
        'synth-2',
      ]);
      expect(calls.where((c) => c.method == 'listDevices'), hasLength(2));

      calls.clear();
      expect(
        await adb.reverseForward(
          serial: 'R5CX',
          localPort: 50001,
          remotePort: 7001,
        ),
        isTrue,
      );
      expect(
        await adb.deliverUsbSessionKey(serial: 'R5CX', key: Uint8List(32)),
        AdbDelivery.stored,
      );
      await adb.removeForward(serial: 'R5CX', remotePort: 7001);
      expect(calls.map((c) => c.method), [
        'reverseForward',
        'shellScript',
        'removeForward',
      ]);
      expect(
        calls.map((c) => (c.arguments as Map)['serial']),
        everyElement('R5CX'),
      );
      expect(adb.reverses, isEmpty);
      expect(adb.keysDelivered, isEmpty);

      calls.clear();
      // The key first: with no tunnel yet, the fake does not dial.
      expect(
        await adb.deliverUsbSessionKey(serial: 'synth-1', key: Uint8List(32)),
        AdbDelivery.stored,
      );
      expect(
        await adb.reverseForward(
          serial: 'synth-1',
          localPort: 50002,
          remotePort: 7001,
        ),
        isTrue,
      );
      expect(await adb.holdTabletScreenOff(serial: 'synth-1'), isNotNull);
      await adb.removeForward(serial: 'synth-1', remotePort: 7001);
      expect(calls, isEmpty);
      expect(adb.keysDelivered, {'synth-1': 1});
    });

    test('a synthetic session persists nothing and is offered no Wi-Fi '
        'pairing, and its frames reach its tablet in order', () async {
      final identity = Get.put(
        WifiPairingService(
          generateCert: () async => (
            certPem:
                '-----BEGIN CERTIFICATE-----\nAAAA\n'
                '-----END CERTIFICATE-----\n',
            keyPem: 'key',
          ),
        ),
      );
      await identity.ready;
      final tablet = FakeTablet('synth-1');
      final r = rig([tablet, FakeTablet('A')]);
      final adb = r.adb;
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final k in prefs.getKeys()) k: prefs.get(k)};

      final synth = r.session('synth-1');
      await synth.connect();
      expect(synth.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.rate != null);

      final frames = tablet.frameStream.take(3).toList();
      for (final b in [0x65, 0x41, 0x41]) {
        encode(synth.nativeId, [0, 0, 0, 1, b, synth.nativeId]);
      }
      expect(await frames, [
        for (final b in [0x65, 0x41, 0x41]) [0, 0, 0, 1, b, synth.nativeId],
      ]);
      expect(synth.captured.value?.displayId, 5);

      // Time for an offer, had there been one (it reads the Computer Name
      // and the addresses first).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(adb.pairingsDelivered, isEmpty);
      expect({for (final k in prefs.getKeys()) k: prefs.get(k)}, before);

      // A real tablet's session beside it is offered one.
      final a = r.session('A');
      await a.connect();
      await _until(() => adb.pairingsDelivered['A'] == 1);
      expect(adb.pairingsDelivered.keys, ['A']);
      expect(prefs.getKeys(), isNot(equals(before.keys.toSet())));
    });

    test(
      "a decoder's keyframe request goes to its listener, not the hub's "
      'slot; the listener reaches its tablet\'s encoder over the link',
      () async {
        final tablet = FakeTablet('A');
        final r = rig([tablet]);
        final a = r.session('A');
        await a.connect();
        final remote = Get.put(RemoteVideoChannel());
        final hubSlot = <int>[];
        remote.onRequestIdr = hubSlot.add;
        const decoder = LoopbackPreviewController.decoderBase;
        remote.listenIdr(decoder, tablet.requestKeyframe);

        await fromDecoder('onRequestIdr', {'session': decoder});
        await _until(() => capture.keyframeRequests.contains(a.nativeId));
        expect(hubSlot, isEmpty);

        await fromDecoder('onRequestIdr', {'session': 7});
        expect(hubSlot, [7]);

        remote.unlistenIdr(decoder);
        final asked = capture.keyframeRequests.length;
        await fromDecoder('onRequestIdr', {'session': decoder});
        expect(hubSlot, [7, decoder]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(capture.keyframeRequests, hasLength(asked));
      },
    );

    test('the Loopback preview starts a tablet through the hub and decodes '
        'what reached its socket', () async {
      final made = <Map>[];
      final disposed = <int>[];
      final fed = <Uint8List>[];
      messenger.setMockMethodCallHandler(remoteChannel, (call) async {
        final args = call.arguments as Map;
        switch (call.method) {
          case 'initialize':
            made.add(args);
            return 77;
          case 'dispose':
            disposed.add(args['session'] as int);
        }
        return null;
      });
      messenger.setMockMessageHandler(nalChannel, (message) async {
        fed.add(Uint8List.sublistView(message!));
        return null;
      });
      Get.put(RemoteVideoChannel());
      final synth = Get.put(SyntheticTablets(1));
      final tablet = synth.tablets.single;
      addTearDown(tablet.hangUp);
      Get.put<AdbService>(synth.adb);
      final hub = HostConnectionManager(
        adb: synth.adb,
        devicePollInterval: null,
        hostGranted: () async => true,
      );
      addTearDown(hub.disconnect);
      Get.put<BaseConnectionManager>(hub);
      await hub.hostInfoReady;

      final preview = Get.put(LoopbackPreviewController());
      final tile = preview.tiles.single;
      expect(tile.decoderId, LoopbackPreviewController.decoderBase);
      preview.start(tile);
      await _until(
        () => preview.sessionOf(tile)?.phase.value == ConnectionPhase.streaming,
      );
      final session = preview.sessionOf(tile)!;
      await _until(() => tablet.codec != null);

      // The first frame makes the decoder, which then asks for a keyframe
      // through the tablet's link.
      encode(session.nativeId, [0, 0, 0, 1, 0x65]);
      await _until(() => tile.textureId.value == 77);
      expect(made.single['session'], LoopbackPreviewController.decoderBase);
      expect(
        made.single['codec'],
        tablet.codec == CodecType.h265 ? 'h265' : 'h264',
      );
      await _until(() => capture.keyframeRequests.contains(session.nativeId));

      encode(session.nativeId, [0, 0, 0, 1, 0x41, 0x42]);
      await _until(() => fed.isNotEmpty);
      expect(
        ByteData.sublistView(fed.single).getUint32(0),
        LoopbackPreviewController.decoderBase,
      );
      expect(fed.single.sublist(4), [0, 0, 0, 1, 0x41, 0x42]);

      await Get.delete<LoopbackPreviewController>();
      await _until(
        () => disposed.contains(LoopbackPreviewController.decoderBase),
      );

      // Stopped from the preview: that session alone ends.
      preview.stop(tile);
      await _until(() => hub.sessions.isEmpty);
    });
  });
}

/// The scale Max encodes [panel] at (native: twice its logical size).
double _scaleFor(ClientPanel panel) =>
    Get.find<SettingsService>().captureScaleFactorFor(panel);
