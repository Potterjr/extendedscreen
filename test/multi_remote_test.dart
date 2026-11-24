import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

import 'support/recording_remote_video.dart';

/// Tablets the Mac views and drives (remote control, Mac controls tablet),
/// through the hub: a [FakeTablet] plays the tablet's half (it "captures"
/// when the Mac's `0xF8` asks and sends the frames a test gives it),
/// [SynthAdb] keeps the taps the Mac sends through adb, and
/// [RecordingRemoteVideo] stands in for the Mac's decoders. Real loopback
/// sockets and real time, so plain `test()`.

class _QuietLogger extends LoggerService {
  /// Every warning, for the tests that count them.
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

/// ScreenCaptureKit, stood in for. A tablet the Mac only views needs none of
/// it, so every call that would make a display or a capture is kept in
/// [made], with its session.
class _Capture extends ScreenCaptureChannel {
  final made = <(String, int)>[];
  final stops = <int>[];

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<VirtualDisplayResult> createVirtualDisplay(DisplayConfigModel config,
      {required int session,
      int serialNum = 1,
      String name = 'Extended Screen'}) async {
    made.add(('createVirtualDisplay', session));
    return const VirtualDisplayResult(displayId: 5, applied: true);
  }

  @override
  Future<CaptureStart> startCapture(DisplayConfigModel config,
      {required int session}) async {
    made.add(('startCapture', session));
    return const CaptureStart(displayId: 5);
  }

  @override
  Future<void> setFrameRateCeiling(int fps, {required int session}) async {}
  @override
  Future<void> stopCapture({required int session}) async => stops.add(session);
  @override
  Future<void> removeVirtualDisplay({required int session}) async {}
  @override
  Future<void> disposeSession({required int session}) async {}
  @override
  Future<void> requestIdr({required int session}) async {}
  @override
  Future<void> setBitrate(int bitsPerSecond, {required int session}) async {}
  @override
  Future<Map<String, double>> getDisplayBounds({required int session}) async =>
      {'x': 0, 'y': 0, 'w': 1480, 'h': 924};
}

/// No UDP: the Mac answers no discovery probe, and the test's tablet dials
/// the port it is told.
class _NoDiscovery extends WifiDiscoveryService {
  @override
  Future<void> startResponder({
    required Uint8List hostId,
    required String name,
    required int tcpPort,
  }) async {}

  @override
  void stopResponder() {}
}

/// A tablet over Wi-Fi, as far as a session's start goes: it dials the Mac's
/// TLS port, presents the pairing token, says HELLO, answers the Mac's
/// pings and keeps every mode the Mac announces (`0xF9`).
class _WifiTablet {
  _WifiTablet(this.identity, this.port);

  final WifiIdentity identity;
  final int port;
  final _socket = SocketService();
  StreamSubscription<Packet>? _sub;

  /// Every mode and direction the Mac announced, in order.
  final modes = <(SessionMode, RemoteDirection)>[];

  /// Dials until the Mac's server takes the connection (it may still be
  /// binding, or waiting out a retry).
  Future<void> dial({Duration timeout = const Duration(seconds: 8)}) async {
    _sub = _socket.packetStream.listen(_onPacket, onError: (_) {});
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        await _socket.connectSecure('127.0.0.1', port,
            trustCertificate: (_) => true);
        break;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    _send([WifiPairingService.authCommand, ...identity.token]);
    // HELLO: Android, a 2000x1200 panel at 60 Hz.
    _send([0x01, 0x02, 2000 >> 8, 2000 & 0xFF, 1200 >> 8, 1200 & 0xFF, 60]);
  }

  Future<void> hangUp() async {
    await _sub?.cancel();
    _sub = null;
    await _socket.disconnect();
  }

  void _send(List<int> payload) => _socket.send(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: Uint8List.fromList(payload),
      ));

  void _onPacket(Packet packet) {
    final p = packet.payload;
    if (packet.type == PacketType.heartbeat) {
      if (!PacketCodec.heartbeatIsPong(p)) {
        final pong = PacketCodec.heartbeatPong(p);
        if (pong != null) _socket.send(pong);
      }
    } else if (packet.type == PacketType.control &&
        p.length >= 3 &&
        p[0] == 0xF9) {
      modes.add((SessionMode.values[p[1]], RemoteDirection.values[p[2]]));
    }
  }
}

/// adb whose device listing can be held back: while [listingGate] is set,
/// a listing asked for waits for it, as `adb devices` can take a while.
class _SlowListing extends SynthAdb {
  _SlowListing(super.tablets);

  Completer<void>? listingGate;

  /// Listings asked for and not yet answered.
  int listingsWaiting = 0;

  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async {
    final gate = listingGate;
    if (gate != null) {
      listingsWaiting++;
      await gate.future;
      listingsWaiting--;
    }
    return super.listDevicesOrNull();
  }
}

const _permissions = MethodChannel('extended_screen/permissions');

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

// The Wi-Fi tests make a real certificate, with macOS's openssl.
final _opensslMissing =
    Platform.isMacOS && File('/usr/bin/openssl').existsSync()
        ? null
        : 'needs /usr/bin/openssl (macOS)';

class _Input extends InputInjectChannel {
  final releases = <int>[];
  final mice = <int>[];

  /// While set, [releaseAll] throws: a session's teardown that fails half
  /// way.
  bool releaseFails = false;

  /// The same, for these sessions (native ids) alone.
  final releaseFailsFor = <int>{};

  @override
  Future<bool> requestAccessibility() async => true;
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  @override
  Future<void> releaseAll({required int session}) async {
    if (releaseFails || releaseFailsFor.contains(session)) {
      throw StateError('release failed');
    }
    releases.add(session);
  }
  @override
  Future<void> injectMouse(MouseEventModel e, Map<String, double> displayBounds,
      {required int session}) async =>
      mice.add(session);
}

/// The Mac's decoders, with one more thing a test can do: make a decoder
/// take its time ([gate]), as VideoToolbox can.
class _Remote extends RecordingRemoteVideo {
  /// While set, [initialize] answers only once it completes.
  Completer<void>? gate;

  @override
  Future<int?> initialize({
    required int session,
    required CodecType codec,
    required int width,
    required int height,
  }) async {
    final texture = await super.initialize(
        session: session, codec: codec, width: width, height: height);
    await gate?.future;
    return texture;
  }
}

/// The real hub, counting what goes through the seam a fake hub overrides
/// to stand in for connecting ([connectWith]).
class _CountingHub extends HostConnectionManager {
  _CountingHub({required super.adb})
      : super(devicePollInterval: null, hostGranted: () async => true);

  /// The serial of every [connectWith].
  final seam = <String?>[];

  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) {
    seam.add(serial);
    return super.connectWith(serial, choice: choice);
  }
}

Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A keyframe and a picture that needs one, as a tablet's encoder sends
/// them.
final _keyframe = Uint8List.fromList([0, 0, 0, 1, 0x65, 1, 2, 3]);
final _picture = Uint8List.fromList([0, 0, 0, 1, 0x41, 4, 5]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  late _Capture capture;
  late _Input input;
  late _Remote remote;

  const ultra = ClientPanel(2960, 1848, 120);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    capture = Get.put<ScreenCaptureChannel>(_Capture()) as _Capture;
    input = Get.put<InputInjectChannel>(_Input()) as _Input;
    // Before any hub: the hub takes the decoders' keyframe slot when it is
    // made.
    remote = Get.put<RemoteVideoChannel>(_Remote()) as _Remote;
  });

  tearDown(Get.reset);

  /// A hub whose adb is [adb], torn down after the test.
  HostConnectionManager hubWith(SynthAdb adb) {
    Get.put<AdbService>(adb);
    final hub = _CountingHub(adb: adb);
    addTearDown(hub.disconnect);
    return hub;
  }

  group('one tablet the Mac controls, as the app-wide mode says', () {
    late FakeTablet tablet;
    late SynthAdb adb;
    late HostConnectionManager hub;

    setUp(() async {
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      tablet = FakeTablet('TAB', panel: ultra);
      addTearDown(tablet.hangUp);
      adb = SynthAdb([tablet]);
      hub = hubWith(adb);
    });

    /// The tablet's session, live, the tablet having heard everything the
    /// Mac sends as it starts.
    Future<HostSession> live() async {
      await hub.connect(serial: 'TAB');
      expect(hub.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.keyframeRequests == 1);
      return hub.focused!;
    }

    test('the Mac tells the tablet the mode, asks for its screen and for a '
        'keyframe, and makes a decoder of its own for it; nothing of the '
        "Mac's screen is captured", () async {
      final session = await live();

      expect(tablet.controls, [0xF9, 0xF8, 0xFF],
          reason: 'the mode, then start capturing, then a keyframe');
      expect(tablet.mode, SessionMode.remoteControl);
      expect(tablet.direction, RemoteDirection.macControlsTab);
      // Max, which the tablet's encoder cannot do: Quality's 60 Hz and
      // 20 Mbps instead, with the codec Max defaults to.
      expect(settings.encodePreset, EncodePreset.max);
      expect(tablet.captureCodec, CodecType.h265);
      expect(tablet.captureFps, 60);
      expect(tablet.captureMbps, 20);
      expect(tablet.captureRequests, 1);
      expect(tablet.sharing, isTrue);

      // One decoder, the session's own, the size of the tablet's panel.
      expect(remote.made, [
        (
          session: session.nativeId,
          codec: CodecType.h265,
          width: ultra.width,
          height: ultra.height,
        ),
      ]);
      final texture = RecordingRemoteVideo.textureFor(session.nativeId);
      expect(session.remoteTextureId.value, texture);
      expect(hub.remoteTextureId.value, texture,
          reason: 'the hub shows the focused session\'s');

      // The Mac encodes nothing for this tablet: no share of the encoder,
      // no virtual display, no capture, no frame sent.
      expect(hub.budget.count, 0);
      expect(hub.budget.contains(session.nativeId), isFalse);
      expect(session.granted.value, isNull);
      expect(hub.displays.holders, isEmpty);
      expect(capture.made, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tablet.frames, 0);
      expect(tablet.rate, isNull, reason: 'no 0xFB: no stream from the Mac');
      expect(tablet.codec, isNull, reason: 'no 0xFC either');
    });

    test("the tablet's frames go to its decoder, and the first one says its "
        'picture has started', () async {
      final session = await live();
      expect(session.tabletStreaming.value, isFalse);
      expect(remote.fed, isEmpty);

      tablet.sendFrame(_keyframe);
      await _until(() => remote.fed[session.nativeId] == 1);
      expect(session.tabletStreaming.value, isTrue);
      expect(hub.tabletStreaming.value, isTrue);

      tablet.sendFrame(_picture);
      await _until(() => remote.fed[session.nativeId] == 2);
      expect(remote.fed.keys, [session.nativeId]);
      expect(tablet.frames, 0, reason: 'frames only go one way');

      // The stand-in sends a frame only while it "captures", as the app
      // does: with its capture stopped nothing leaves it, over a link that
      // would carry a frame to the decoder.
      tablet.sharing = false;
      tablet.sendFrame(_picture);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(remote.fed[session.nativeId], 2);
      tablet.sharing = true;
      tablet.sendFrame(_picture);
      await _until(() => remote.fed[session.nativeId] == 3);
    });

    test("a keyframe the Mac's decoder asks for is asked of the tablet's "
        'encoder, over the link', () async {
      final session = await live();
      expect(tablet.keyframeRequests, 1, reason: 'the one sent at the start');

      await remote.idr(session.nativeId);
      await _until(() => tablet.keyframeRequests == 2);

      // Another decoder's request is not this tablet's.
      await remote.idr(session.nativeId + 1000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tablet.keyframeRequests, 2);
      expect(tablet.controls.last, 0xFF);
    });

    test("the Mac's taps and swipes go through adb, in the tablet's own "
        'pixels', () async {
      await live();

      hub.sendRemoteTap(0.5, 0.5);
      expect(adb.taps, [('TAB', ultra.width ~/ 2, ultra.height ~/ 2)]);

      hub.sendRemoteSwipe(0.25, 0.5, 0.75, 0.5, durationMs: 120);
      expect(adb.swipes, [('TAB', 740, 924, 2220, 924, 120)]);
      hub.sendRemoteSwipe(0, 0, 1, 1);
      expect(adb.swipes.last, ('TAB', 0, 0, 2960, 1848, 50),
          reason: '50 ms unless said otherwise');

      // Nothing of it travels over the link, and nothing is injected on
      // the Mac.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tablet.controls, [0xF9, 0xF8, 0xFF]);
      expect(input.mice, isEmpty);
    });

    test('Disconnect tells the tablet to stop capturing and lets its decoder '
        'go', () async {
      final session = await live();
      tablet.sendFrame(_keyframe);
      await _until(() => session.tabletStreaming.value);

      await hub.disconnect();
      expect(hub.phase.value, ConnectionPhase.disconnected);
      expect(hub.sessions, isEmpty);
      await _until(() => !tablet.sharing);
      expect(tablet.captureStops, 1);
      expect(tablet.controls, [0xF9, 0xF8, 0xFF, 0xF7]);

      expect(remote.disposed, [session.nativeId]);
      expect(session.remoteTextureId.value, isNull);
      expect(hub.remoteTextureId.value, isNull);
      expect(session.tabletStreaming.value, isFalse);
      expect(hub.tabletStreaming.value, isFalse);
      expect(input.releases, contains(session.nativeId));
      expect(adb.releases, ['TAB'],
          reason: 'its panel is lit again, held off or not');
      expect(adb.reverses, isEmpty);

      // There was never anything of the Mac's to stop or give back.
      expect(hub.budget.count, 0);
      expect(hub.displays.holders, isEmpty);
      expect(capture.made, isEmpty);
      expect(capture.stops, isEmpty);
      expect(tablet.frames, 0);

      // A capture the Mac stopped sends nothing, whatever the link.
      tablet.sendFrame(_picture);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(remote.fed[session.nativeId], 1);
    });

    test('a synthetic tablet has no panel to turn off, unless the test gives '
        'it one: then the toggle holds it, and a panel that came back on by '
        'itself shows as on', () async {
      final session = await live();
      tablet.sendFrame(_keyframe);
      await _until(() => session.tabletStreaming.value);

      expect(await hub.setTabletScreenOff(true), contains('no panel'));
      expect(adb.holds, isEmpty);
      expect(hub.tabletScreenOff.value, isFalse);

      adb.panels.add('TAB');
      adb.holdErrors['TAB'] = 'error: ClassNotFoundException';
      expect(await hub.setTabletScreenOff(true), contains('ClassNotFound'));
      expect(adb.holds, isEmpty);
      expect(hub.tabletScreenOff.value, isFalse);

      adb.holdErrors.clear();
      expect(await hub.setTabletScreenOff(true), isNull);
      expect(adb.holds, ['TAB']);
      expect(session.tabletScreenOff.value, isTrue);
      expect(hub.tabletScreenOff.value, isTrue);
      expect(settings.tabletScreenOffFor('TAB'), isTrue);

      adb.restore('SOMEONE-ELSE');
      expect(session.tabletScreenOff.value, isTrue);
      adb.restore('TAB');
      expect(session.tabletScreenOff.value, isFalse);
      expect(hub.tabletScreenOff.value, isFalse);

      expect(await hub.setTabletScreenOff(true), isNull);
      expect(await hub.setTabletScreenOff(false), isNull);
      expect(adb.holds, ['TAB', 'TAB']);
      expect(adb.releases, ['TAB']);
    });
  });

  group('a session made for one mode keeps it', () {
    // Not the panel the settings start with, so its HELLO shows.
    const panel = ClientPanel(2000, 1200, 60);
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const extended = SessionChoice(SessionMode.extendedScreen);

    late FakeTablet tablet;
    late SynthAdb adb;
    late HostConnectionManager hub;

    setUp(() {
      tablet = FakeTablet('TAB', panel: panel);
      addTearDown(tablet.hangUp);
      adb = SynthAdb([tablet]);
      hub = hubWith(adb);
    });

    /// The tablet's session, made as [choice] (null: with none, so as the
    /// selectors stand) and given to the hub, as a pick would have made it.
    /// Not connected.
    HostSession made(SessionChoice? choice) {
      final session = HostSession(
        key: 'TAB',
        link: LinkType.usb,
        serial: 'TAB',
        choice: choice,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      hub.adopt(session);
      return session;
    }

    int sent(int command) => tablet.controls.where((c) => c == command).length;

    Future<void> setMode(SessionMode mode, RemoteDirection direction) async {
      await settings.setSessionMode(mode);
      await settings.setRemoteDirection(direction);
    }

    /// The session's start, held at the pipeline's queue: connects until the
    /// tablet's HELLO is in and the start is asked for, behind an operation
    /// that ends with the returned completer.
    Future<Completer<void>> heldAtQueue(HostSession session) async {
      final held = Completer<void>();
      // Whatever the test does: a queue left held would hold the hub's
      // teardown too.
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      unawaited(hub.pipeline.run(() => held.future));
      unawaited(session.connect());
      await _until(() => settings.clientPanelFor('TAB') == panel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.phase.value, ConnectionPhase.configuring);
      return held;
    }

    test('made to be controlled by the Mac, it is that before its first '
        'connect and through a retry, a reconnect and a restarted link, '
        'whatever the settings say meanwhile', () async {
      final session = made(reverse);
      expect(session.choice, reverse);
      for (final mode in SessionMode.values) {
        for (final direction in RemoteDirection.values) {
          await setMode(mode, direction);
          expect(session.spec.isReverseRemote, isTrue,
              reason: 'with the settings on $mode, $direction');
          expect(session.effectiveChoice, reverse);
        }
      }

      await setMode(SessionMode.remoteControl, RemoteDirection.tabControlsMac);
      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.keyframeRequests == 1);
      expect(tablet.controls, [0xF9, 0xF8, 0xFF]);
      expect(tablet.mode, SessionMode.remoteControl);
      expect(tablet.direction, RemoteDirection.macControlsTab);
      expect(remote.made.single.session, session.nativeId);
      expect(capture.made, isEmpty);

      await setMode(SessionMode.extendedScreen, RemoteDirection.tabControlsMac);

      /// The tablet hears the mode again, and it is still this one.
      Future<void> hearsItAgain(int times, String after) async {
        await _until(() =>
            sent(0xF9) == times &&
            sent(0xF8) == times &&
            session.phase.value == ConnectionPhase.streaming);
        expect(tablet.mode, SessionMode.remoteControl, reason: after);
        expect(tablet.direction, RemoteDirection.macControlsTab,
            reason: after);
        expect(session.spec.isReverseRemote, isTrue, reason: after);
        expect(session.effectiveChoice, reverse, reason: after);
        expect(remote.made, hasLength(times), reason: after);
        expect(capture.made, isEmpty, reason: after);
      }

      // The link drops: the retry.
      tablet.mode = tablet.direction = null;
      await tablet.hangUp();
      await _until(() => session.phase.value == ConnectionPhase.error);
      expect(session.spec.isReverseRemote, isTrue);
      await hearsItAgain(2, 'after a retry');

      // A settings change: every session reconnects.
      tablet.mode = tablet.direction = null;
      await hub.reconnect();
      await hearsItAgain(3, 'after a reconnect');

      tablet.mode = tablet.direction = null;
      // ignore: invalid_use_of_protected_member
      await session.restartLink();
      await hearsItAgain(4, 'after a restarted link');
      expect(hub.sessions['TAB'], same(session));
    });

    test('made to extend, it goes on extending when the settings move to a '
        'tablet the Mac controls', () async {
      final session = made(extended);
      await setMode(SessionMode.remoteControl, RemoteDirection.macControlsTab);
      expect(session.spec.isReverseRemote, isFalse);
      expect(session.effectiveChoice, extended);

      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.rate != null);
      expect(tablet.mode, SessionMode.extendedScreen);
      expect(capture.made.map((m) => m.$1),
          ['createVirtualDisplay', 'startCapture']);

      tablet.mode = null;
      await hub.reconnect();
      await _until(() =>
          sent(0xF9) == 2 && session.phase.value == ConnectionPhase.streaming);
      expect(tablet.mode, SessionMode.extendedScreen);
      expect(tablet.direction, RemoteDirection.tabControlsMac);
      expect(capture.made.where((m) => m.$1 == 'startCapture'), hasLength(2));
      expect(tablet.captureRequests, 0);
      expect(remote.made, isEmpty);

      // And the Mac sends it no taps.
      session.sendRemoteTap(0.5, 0.5);
      session.sendRemoteSwipe(0, 0, 1, 1);
      expect(adb.taps, isEmpty);
      expect(adb.swipes, isEmpty);
    });

    test('made with no choice, it takes what the selectors say as it is '
        'made, and keeps that: no later attempt follows them', () async {
      final session = made(null);
      expect(session.choice, extended);
      expect(session.effectiveChoice, extended);

      await session.connect();
      await _until(() => tablet.rate != null);
      expect(tablet.mode, SessionMode.extendedScreen);
      expect(tablet.captureRequests, 0);

      await setMode(SessionMode.remoteControl, RemoteDirection.macControlsTab);
      expect(session.spec.isReverseRemote, isFalse);
      tablet.mode = null;
      await hub.reconnect();
      await _until(() =>
          sent(0xF9) == 2 && session.phase.value == ConnectionPhase.streaming);
      expect(tablet.mode, SessionMode.extendedScreen,
          reason: 'the next attempt is what the session was made to be');
      expect(tablet.captureRequests, 0);
      expect(session.choice, extended);
      expect(session.effectiveChoice, extended);
      expect(remote.made, isEmpty);

      // Another session made now, with none either, takes the new ones.
      final later = HostSession(
        key: 'LATER',
        link: LinkType.usb,
        serial: 'LATER',
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      addTearDown(later.dispose);
      expect(later.choice, reverse);
      expect(later.spec.isReverseRemote, isTrue);
    });

    test('over Wi-Fi the tablet drives the Mac, whatever it was made for, '
        'and the Mac sends it no taps', () {
      final session = HostSession(
        key: 'wifi',
        link: LinkType.wifi,
        choice: reverse,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      addTearDown(session.dispose);
      expect(session.choice, reverse);
      expect(session.spec.isReverseRemote, isFalse);
      expect(session.spec.displayMode, DisplayMode.mirror);
      expect(
          session.effectiveChoice,
          const SessionChoice(
              SessionMode.remoteControl, RemoteDirection.tabControlsMac));

      session.sendRemoteTap(0.5, 0.5);
      session.sendRemoteSwipe(0, 0, 1, 1);
      expect(adb.taps, isEmpty);
      expect(adb.swipes, isEmpty);
    });

    test('once live, the tablet is remembered with the mode it was made for',
        () async {
      expect(settings.knownChoice('TAB'), isNull);
      final session = made(reverse);
      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);
      expect(settings.knownChoice('TAB'), reverse);
      expect(settings.nextChoice, extended,
          reason: 'the next tablet\'s choice is another matter');
    });

    test('made with no choice, a tablet is remembered in the mode the '
        'selectors gave its session, each time it goes live', () async {
      final session = made(null);
      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);
      expect(settings.knownDevice('TAB'), isNotNull);
      expect(settings.knownChoice('TAB'), extended);

      // Whatever was stored for the tablet meanwhile, a session going live
      // says what the tablet runs as now.
      settings.setKnownChoice('TAB', reverse);
      await hub.reconnect();
      await _until(() => session.phase.value == ConnectionPhase.streaming);
      expect(settings.knownChoice('TAB'), extended);
    });

    test('an attempt that ends while its start waits at the queue starts '
        'nothing: no mode, no capture request, no decoder', () async {
      final session = made(reverse);
      final held = await heldAtQueue(session);
      expect(remote.made, isEmpty);

      final ending = session.disconnect();
      held.complete();
      await ending;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(session.phase.value, ConnectionPhase.disconnected);
      expect(remote.made, isEmpty, reason: 'no decoder for an ended attempt');
      expect(session.remoteTextureId.value, isNull);
      expect(tablet.controls, isNot(contains(0xF9)));
      expect(tablet.controls, isNot(contains(0xF8)));
      expect(tablet.captureRequests, 0);
      expect(tablet.sharing, isFalse);

      // The decoder's keyframe requests are not this session's either.
      await remote.idr(session.nativeId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(tablet.keyframeRequests, 0);

      // Nothing of it is in the way of the next attempt.
      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.keyframeRequests == 1);
      expect(tablet.controls.where((c) => c != 0xF7), [0xF9, 0xF8, 0xFF]);
      expect(remote.made, hasLength(1));
    });

    test('a link lost while the start waits at the queue: the start does '
        'nothing, and the retry makes the one decoder', () async {
      final session = made(reverse);
      final held = await heldAtQueue(session);
      // ignore: invalid_use_of_protected_member
      final attempt = session.currentAttempt;

      await tablet.hangUp();
      // The Mac has noticed: the attempt is over.
      // ignore: invalid_use_of_protected_member
      await _until(() => session.isCancelled(attempt));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      held.complete();

      await _until(() =>
          session.phase.value == ConnectionPhase.streaming &&
          tablet.keyframeRequests == 1);
      expect(remote.made, hasLength(1));
      expect(sent(0xF9), 1);
      expect(sent(0xF8), 1);
    });

    test('an attempt that ends while its decoder is being made asks the '
        'tablet for nothing and shows no texture; the decoder goes',
        () async {
      final session = made(reverse);
      final textures = <int?>[];
      final shown = session.remoteTextureId.listen(textures.add);
      addTearDown(shown.cancel);

      final gate = remote.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final connecting = session.connect();
      await _until(() => remote.made.length == 1 && tablet.mode != null);
      expect(tablet.controls, [0xF9], reason: 'the mode goes first');

      final ending = session.disconnect();
      gate.complete();
      remote.gate = null;
      await ending;
      await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(tablet.controls, isNot(contains(0xF8)));
      expect(tablet.controls, isNot(contains(0xFF)));
      expect(tablet.captureRequests, 0);
      expect(tablet.sharing, isFalse);
      expect(textures.nonNulls, isEmpty,
          reason: 'the texture of a decoder on its way out');
      expect(session.remoteTextureId.value, isNull);
      // By the teardown's stop, queued behind that start (and once more by
      // the attempt as it gives up, which repeats the teardown).
      expect(remote.disposed, isNotEmpty);
      expect(remote.disposed.toSet(), {session.nativeId});
      expect(session.phase.value, ConnectionPhase.disconnected);
    });

    test('a tablet whose link is down still takes the Mac\'s taps (they go '
        'through adb), until the hub ends its session', () async {
      final session = made(reverse);
      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);

      // Unplugged as far as the listing goes, so no retry brings it back.
      adb.unplugged.add('TAB');
      await tablet.hangUp();
      await _until(() =>
          session.phase.value == ConnectionPhase.error &&
          session.retryPending.value);

      session.sendRemoteTap(0.5, 0.5);
      expect(adb.taps, [('TAB', panel.width ~/ 2, panel.height ~/ 2)]);
      hub.sendRemoteSwipe(0, 0.5, 1, 0.5, durationMs: 80);
      expect(adb.swipes, [('TAB', 0, 600, 2000, 600, 80)]);

      await hub.disconnectSession('TAB');
      session.sendRemoteTap(0.25, 0.25);
      session.sendRemoteSwipe(0, 0, 1, 1);
      expect(adb.taps, hasLength(1));
      expect(adb.swipes, hasLength(1));
    });
  });

  group("two tablets the Mac controls: a decoder the Mac can't make", () {
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const noDecoder = 'error_remote_decoder';

    late FakeTablet tabletA;
    late FakeTablet tabletB;
    late SynthAdb adb;
    late HostConnectionManager hub;

    setUp(() {
      tabletA = FakeTablet('A', panel: ultra);
      tabletB = FakeTablet('B', panel: const ClientPanel(2000, 1200, 60));
      addTearDown(tabletA.hangUp);
      addTearDown(tabletB.hangUp);
      adb = SynthAdb([tabletA, tabletB]);
      hub = hubWith(adb);
    });

    /// [tablet]'s session, made as [choice] and given to the hub (which
    /// makes one remote-control session at a time, for now). Not connected.
    HostSession made(FakeTablet tablet, [SessionChoice choice = reverse]) {
      final session = HostSession(
        key: tablet.serial,
        link: LinkType.usb,
        serial: tablet.serial,
        choice: choice,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      hub.adopt(session);
      return session;
    }

    /// Both tablets' sessions, live, each with its decoder asked for.
    Future<(HostSession, HostSession)> bothLive() async {
      final a = made(tabletA);
      final b = made(tabletB);
      await a.connect();
      await b.connect();
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(b.phase.value, ConnectionPhase.streaming);
      await _until(() =>
          tabletA.keyframeRequests == 1 && tabletB.keyframeRequests == 1);
      return (a, b);
    }

    test('with every decoder made, no card says anything', () async {
      final (a, b) = await bothLive();
      expect(remote.made.map((d) => d.session), [a.nativeId, b.nativeId]);
      expect(a.notice.value, isNull);
      expect(b.notice.value, isNull);
      expect(a.remoteTextureId.value,
          RecordingRemoteVideo.textureFor(a.nativeId));
      expect(b.remoteTextureId.value,
          RecordingRemoteVideo.textureFor(b.nativeId));

      // A decoder that says it was made, with no failure before it.
      await remote.ready(a.nativeId);
      expect(a.notice.value, isNull);
      expect(b.notice.value, isNull);
    });

    test("a decoder that fails says so on its own tablet's card only, until "
        'it is made again', () async {
      final (a, b) = await bothLive();

      final log = Get.find<LoggerService>() as _QuietLogger;
      int said() => log.warnings.where((w) => w.contains('no decoder')).length;
      await remote.codecError(b.nativeId, 'DECODER_BUSY (-12913)');
      expect(b.notice.value, noDecoder);
      expect(a.notice.value, isNull);
      // The plugin reports it again on every keyframe it cannot start from
      // (about one a second): the session warns once per failure.
      expect(said(), 1);
      await remote.codecError(b.nativeId, 'DECODER_BUSY (-12913)');
      await remote.codecError(b.nativeId, 'DECODER_BUSY (-12913)');
      expect(b.notice.value, noDecoder);
      expect(said(), 1);
      // The link, and the other tablet, carry on.
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(tabletB.captureStops, 0);
      expect(remote.disposed, isEmpty);

      // The other tablet's decoder being made again is not this one's.
      await remote.ready(a.nativeId);
      expect(b.notice.value, noDecoder);

      await remote.ready(b.nativeId);
      expect(b.notice.value, isNull);
      expect(a.notice.value, isNull);

      // And again: each failure is said, each recovery clears it.
      await remote.codecError(a.nativeId, 'DECODER_FAILED (-12911)');
      expect(a.notice.value, noDecoder);
      expect(b.notice.value, isNull);
      await remote.ready(a.nativeId);
      expect(a.notice.value, isNull);
    });

    test('a failure or a recovery of a decoder that is nobody\'s changes '
        'nothing', () async {
      final (a, b) = await bothLive();
      await remote.codecError(a.nativeId + b.nativeId + 1000, 'DECODER_BUSY');
      await remote.ready(a.nativeId + b.nativeId + 1000);
      expect(a.notice.value, isNull);
      expect(b.notice.value, isNull);
    });

    test('a tablet whose decoder and texture cannot be made at all says so, '
        'and is still asked for its screen; the other tablet has its picture',
        () async {
      final a = made(tabletA);
      final b = made(tabletB);
      remote.failing.add(a.nativeId);
      await a.connect();
      await b.connect();
      await _until(() =>
          tabletA.keyframeRequests == 1 && tabletB.keyframeRequests == 1);

      expect(a.phase.value, ConnectionPhase.streaming);
      expect(a.notice.value, noDecoder);
      expect(a.remoteTextureId.value, isNull);
      expect(tabletA.controls, [0xF9, 0xF8, 0xFF]);
      expect(tabletA.captureRequests, 1);
      expect(tabletA.sharing, isTrue);

      expect(b.notice.value, isNull);
      expect(b.remoteTextureId.value,
          RecordingRemoteVideo.textureFor(b.nativeId));

      // The next attempt starts with nothing said, and with a decoder this
      // time.
      remote.failing.clear();
      await a.reconnect();
      await _until(() => tabletA.keyframeRequests == 2);
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(a.notice.value, isNull);
      expect(a.remoteTextureId.value,
          RecordingRemoteVideo.textureFor(a.nativeId));
      expect(b.notice.value, isNull);
    });

    test('a decoder made again clears only what the decoder said', () async {
      final (a, b) = await bothLive();

      // Whatever else a card says is not the decoder's to take back.
      a.notice.value = 'error_extend_unavailable';
      await remote.ready(a.nativeId);
      expect(a.notice.value, 'error_extend_unavailable');

      // A failure takes the card's line over; its recovery clears that.
      await remote.codecError(a.nativeId, 'DECODER_BUSY');
      expect(a.notice.value, noDecoder);
      await remote.ready(a.nativeId);
      expect(a.notice.value, isNull);
      expect(b.notice.value, isNull);
    });

    test('once a session is over its decoder says nothing more: not after a '
        'Disconnect, not while a lost link waits for its retry', () async {
      final (a, b) = await bothLive();

      // Still the hub's session (ended by itself, not by the hub), so the
      // event reaches it.
      await b.disconnect();
      expect(b.phase.value, ConnectionPhase.disconnected);
      expect(remote.disposed, [b.nativeId]);
      await remote.codecError(b.nativeId, 'DECODER_FAILED');
      expect(b.notice.value, isNull);

      // A lost link: the decoder went with the teardown.
      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() =>
          a.phase.value == ConnectionPhase.error && a.retryPending.value);
      await _until(() => remote.disposed.contains(a.nativeId));
      await remote.codecError(a.nativeId, 'DECODER_FAILED');
      expect(a.notice.value, isNull);

      // What it said while live is not taken back by a late recovery
      // either: the next attempt starts clean anyway.
      a.notice.value = noDecoder;
      await remote.ready(a.nativeId);
      expect(a.notice.value, noDecoder);
    });

    test("a tablet the Mac extends onto has no decoder: an event under its "
        'id says nothing on its card', () async {
      final a = made(tabletA, const SessionChoice(SessionMode.extendedScreen));
      await a.connect();
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(remote.made, isEmpty);

      await remote.codecError(a.nativeId, 'DECODER_BUSY');
      expect(a.notice.value, isNull);
      await remote.ready(a.nativeId);
      expect(a.notice.value, isNull);
    });
  });

  group("the shell the Mac's taps go through ends with the session", () {
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const panel = ClientPanel(2000, 1200, 60);

    late FakeTablet tablet;
    late SynthAdb adb;

    setUp(() {
      tablet = FakeTablet('TAB', panel: panel);
      addTearDown(tablet.hangUp);
      adb = SynthAdb([tablet]);
    });

    test('a Disconnect of a tablet the Mac controls ends its shell, once',
        () async {
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      final hub = hubWith(adb);
      await hub.connect(serial: 'TAB');
      expect(hub.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.keyframeRequests == 1);

      hub.sendRemoteTap(0.5, 0.5);
      expect(adb.taps, hasLength(1));
      expect(adb.inputShellsClosed, isEmpty,
          reason: 'it stays open while the session runs');

      await hub.disconnect();
      expect(hub.sessions, isEmpty);
      expect(adb.inputShellsClosed, ['TAB']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adb.inputShellsClosed, ['TAB'], reason: 'and not again later');
    });

    test('every end of its link ends the shell, so the next attempt\'s taps '
        'open one of their own: a lost link, a reconnect, the hub ending '
        'the session', () async {
      final hub = hubWith(adb);
      final session = HostSession(
        key: 'TAB',
        link: LinkType.usb,
        serial: 'TAB',
        choice: reverse,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      hub.adopt(session);
      await session.connect();
      expect(session.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.keyframeRequests == 1);
      expect(adb.inputShellsClosed, isEmpty);

      await tablet.hangUp();
      await _until(() =>
          session.phase.value == ConnectionPhase.streaming &&
          tablet.keyframeRequests == 2);
      expect(adb.inputShellsClosed, ['TAB'], reason: 'the lost link');

      await hub.reconnect();
      await _until(() =>
          session.phase.value == ConnectionPhase.streaming &&
          tablet.keyframeRequests == 3);
      expect(adb.inputShellsClosed, ['TAB', 'TAB'], reason: 'the reconnect');

      await hub.disconnectSession('TAB');
      expect(adb.inputShellsClosed, ['TAB', 'TAB', 'TAB']);
      expect(adb.inputShellsClosed.toSet(), {'TAB'});
    });

    test('a tablet the Mac extends onto has no such shell: its end closes '
        'none, not on a Disconnect, a lost link or a reconnect', () async {
      final hub = hubWith(adb);
      await hub.connect(serial: 'TAB');
      expect(hub.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.rate != null);
      final session = hub.focused!;
      expect(session.spec.isReverseRemote, isFalse);

      await tablet.hangUp();
      await _until(() => session.phase.value == ConnectionPhase.error);
      await _until(() => session.phase.value == ConnectionPhase.streaming);
      await hub.reconnect();
      await _until(() => session.phase.value == ConnectionPhase.streaming);
      await hub.disconnect();
      expect(hub.sessions, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adb.inputShellsClosed, isEmpty);
    });

    test('a tablet that drives the Mac has none either', () async {
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      final hub = hubWith(adb);
      await hub.connect(serial: 'TAB');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.focused!.spec.mode, SessionMode.remoteControl);

      await hub.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adb.inputShellsClosed, isEmpty);
    });

    test('an older session of a tablet that already has a newer one closes '
        'nothing as it ends: the shell is the newer one\'s by then', () async {
      // Two sessions for one tablet on one set of tunnels, as the hub keeps
      // them. (The hub itself claims a tablet for a new session only once
      // the old one has ended, so there this guard is a second line.)
      Get.put<AdbService>(adb);
      final pipeline = PipelineQueue();
      final tunnels = TabletTunnels();
      HostSession session() {
        final s = HostSession(
          key: 'TAB',
          link: LinkType.usb,
          serial: 'TAB',
          choice: reverse,
          pipeline: pipeline,
          tunnels: tunnels,
          adb: adb,
          socket: SocketService(),
        );
        tunnels.claim('TAB', s);
        addTearDown(() async {
          await s.disconnect();
          s.dispose();
        });
        return s;
      }

      final older = session();
      await older.connect();
      expect(older.phase.value, ConnectionPhase.streaming);
      await _until(() => tablet.keyframeRequests == 1);
      older.sendRemoteTap(0.5, 0.5);
      expect(adb.taps, [('TAB', 1000, 600)]);

      // The tablet's next session exists before the first one has ended.
      final newer = session();
      await older.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(older.phase.value, ConnectionPhase.disconnected);
      expect(adb.inputShellsClosed, isEmpty,
          reason: 'not the older one\'s to close any more');
      expect(adb.releases, isEmpty,
          reason: 'nor its screen hold to let go (the same rule)');

      // The newer one's own end does close it.
      await newer.connect();
      expect(newer.phase.value, ConnectionPhase.streaming);
      expect(adb.inputShellsClosed, isEmpty);
      await newer.disconnect();
      expect(adb.inputShellsClosed, ['TAB']);
    });
  });

  group('the hub counts and reaches each tablet the Mac controls', () {
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const driving = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac);
    const extended = SessionChoice(SessionMode.extendedScreen);

    late FakeTablet tabletA;
    late FakeTablet tabletB;
    late FakeTablet tabletC;
    late SynthAdb adb;
    late HostConnectionManager hub;

    setUp(() {
      tabletA = FakeTablet('A', panel: ultra);
      tabletB = FakeTablet('B', panel: const ClientPanel(2000, 1200, 60));
      tabletC = FakeTablet('C', panel: const ClientPanel(2400, 1080, 60));
      for (final tablet in [tabletA, tabletB, tabletC]) {
        addTearDown(tablet.hangUp);
      }
      adb = SynthAdb([tabletA, tabletB, tabletC]);
      hub = hubWith(adb);
    });

    /// A session for [tablet], made as [choice]. Neither connected nor the
    /// hub's yet.
    HostSession session(FakeTablet tablet, [SessionChoice choice = reverse]) =>
        HostSession(
          key: tablet.serial,
          link: LinkType.usb,
          serial: tablet.serial,
          choice: choice,
          pipeline: hub.pipeline,
          adb: adb,
          socket: SocketService(),
        );

    /// [session], given to the hub as a test's stand-in for a pick (the hub
    /// makes one remote-control session at a time, for now).
    HostSession made(FakeTablet tablet, [SessionChoice choice = reverse]) {
      final s = session(tablet, choice);
      hub.adopt(s);
      return s;
    }

    /// Every value the hub's count takes from now on, in order.
    List<int> counts() {
      final seen = <int>[];
      final sub = hub.reverseActive.listen(seen.add);
      addTearDown(sub.cancel);
      return seen;
    }

    int sent(FakeTablet tablet, int command) =>
        tablet.controls.where((c) => c == command).length;

    /// [s] is live and its tablet has heard the whole start, for the
    /// [starts]th time.
    Future<void> started(HostSession s, FakeTablet tablet, int starts) =>
        _until(() =>
            s.phase.value == ConnectionPhase.streaming &&
            (s.spec.isReverseRemote
                ? tablet.keyframeRequests == starts
                : tablet.rates.length >= starts) &&
            sent(tablet, 0xF9) == starts);

    test('a tablet the Mac controls counts from the moment it is live, not '
        'while its link is down, and no more once it is disconnected',
        () async {
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      final seen = counts();
      expect(hub.reverseActive.value, 0);

      // The hub's own session, as a pick makes it.
      final connecting = hub.connect(serial: 'A');
      expect(hub.sessions.keys, ['A']);
      expect(hub.reverseActive.value, 0, reason: 'connecting is not live');
      await connecting;
      final a = hub.focused!;
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(hub.reverseActive.value, 1);
      expect(seen, [1]);
      await started(a, tabletA, 1);

      // Its link drops: in `error` until the retry is live again.
      await tabletA.hangUp();
      await _until(() => seen.length == 2);
      expect(seen, [1, 0]);
      await started(a, tabletA, 2);
      expect(hub.reverseActive.value, 1);
      expect(seen, [1, 0, 1]);

      await hub.disconnect();
      expect(hub.reverseActive.value, 0);
      expect(seen, [1, 0, 1, 0]);
    });

    test('ending one tablet takes it out of the count at once, before its '
        'teardown has run', () async {
      final a = made(tabletA);
      final b = made(tabletB);
      await a.connect();
      await b.connect();
      expect(hub.reverseActive.value, 2);

      final ending = hub.disconnectSession('A');
      expect(hub.sessions.keys, ['B']);
      expect(hub.reverseActive.value, 1, reason: 'in the same step');
      await ending;
      expect(hub.reverseActive.value, 1);
      expect(b.phase.value, ConnectionPhase.streaming);
    });

    test('a tablet the Mac extends onto, or one that drives the Mac, never '
        'counts', () async {
      final seen = counts();
      final a = made(tabletA, extended);
      final b = made(tabletB, driving);
      await a.connect();
      await b.connect();
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(b.spec.mode, SessionMode.remoteControl);
      expect(hub.reverseActive.value, 0);

      await hub.reconnect();
      await hub.disconnect();
      expect(hub.reverseActive.value, 0);
      expect(seen, isEmpty, reason: 'it never moved');
      expect(hub.remoteSessions, isEmpty);
    });

    test('over the app-wide mode an Extended pick through the hub does not '
        'count either', () async {
      final seen = counts();
      await hub.connect(serial: 'A');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.focused!.spec.isReverseRemote, isFalse);
      expect(hub.reverseActive.value, 0);
      expect(seen, isEmpty);
    });

    test('a session the hub is handed counts like one it made: adopted '
        'already live, or adopted first and live later', () async {
      // Live before the hub knows it.
      final a = session(tabletA);
      await a.connect();
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(hub.reverseActive.value, 0);
      hub.adopt(a);
      expect(hub.reverseActive.value, 1);

      // The hub's first, then live.
      final b = made(tabletB);
      expect(hub.reverseActive.value, 1);
      await b.connect();
      expect(hub.reverseActive.value, 2);

      await b.disconnect();
      expect(hub.reverseActive.value, 1,
          reason: 'still the hub\'s session, but not live');
    });

    test('a session put into the map directly counts, and one taken out of '
        'it is not watched any more: nothing it does afterwards moves the '
        'count', () async {
      final b = session(tabletB);
      // The hub does not end what a test took out of its map.
      addTearDown(() async {
        await b.disconnect();
        b.dispose();
      });
      final listeners = b.phase.subject.length;

      hub.sessions['B'] = b;
      expect(b.phase.subject.length, listeners! + 1,
          reason: 'the hub watches its phase');
      expect(hub.reverseActive.value, 0);
      await b.connect();
      expect(hub.reverseActive.value, 1);
      await started(b, tabletB, 1);

      // Out of the map while still live.
      final seen = counts();
      hub.sessions.remove('B');
      expect(hub.reverseActive.value, 0);
      expect(seen, [0]);
      await Future<void>.delayed(Duration.zero);
      expect(b.phase.subject.length, listeners,
          reason: 'no worker of the hub\'s is left on it');

      // Everything a session's phase can do, with nobody watching.
      await b.disconnect();
      expect(b.phase.value, ConnectionPhase.disconnected);
      await b.connect();
      expect(b.phase.value, ConnectionPhase.streaming);
      await started(b, tabletB, 2);
      expect(hub.reverseActive.value, 0);
      expect(seen, [0]);
      expect(b.phase.subject.length, listeners);

      // Back in, already live: counted at once, and watched again.
      hub.sessions['B'] = b;
      expect(hub.reverseActive.value, 1);
      expect(b.phase.subject.length, listeners + 1);

      // Another session takes its key: the count is the new one's, and the
      // old one is let go of.
      final next = session(tabletB);
      hub.sessions['B'] = next;
      expect(hub.reverseActive.value, 0);
      await Future<void>.delayed(Duration.zero);
      expect(b.phase.subject.length, listeners);
      expect(seen, [0, 1, 0]);
    });

    test('remoteSessions lists the tablets the Mac controls, whatever their '
        'phase, in key order, and nothing else', () async {
      expect(hub.remoteSessions, isEmpty);
      final c = made(tabletC);
      final b = made(tabletB, extended);
      final a = made(tabletA);
      expect(hub.sessions.keys, ['C', 'B', 'A']);
      expect(hub.remoteSessions, [a, c], reason: 'none of them connected');

      await a.connect();
      await b.connect();
      expect(hub.remoteSessions, [a, c]);
      expect(hub.reverseActive.value, 1);

      // A tablet that drives the Mac is a remote-control session, but not
      // one the Mac views.
      await hub.disconnectSession('B');
      final driver = made(tabletB, driving);
      expect(hub.remoteSessions, [a, c]);
      expect(hub.sessions.values, contains(driver));

      await hub.disconnectSession('A');
      expect(hub.remoteSessions, [c]);
    });

    test('whatever builds from remoteSessions the way an Obx does is told '
        'when the map changes', () async {
      // An Obx's own mechanism: it reads inside notifyChildren, which
      // throws unless something observable was read, and rebuilds on every
      // event of its observer.
      final observer = RxNotifier<dynamic>();
      addTearDown(observer.close);
      var events = 0;
      observer.listen((_) => events++);
      expect(RxInterface.notifyChildren(observer, () => hub.remoteSessions),
          isEmpty);

      made(tabletA);
      expect(events, greaterThan(0));
      final after = events;
      await hub.disconnectSession('A');
      expect(events, greaterThan(after));
    });

    test('reconnectSession restarts that tablet alone: the other one hears '
        'nothing and keeps its decoder', () async {
      final a = made(tabletA);
      final b = made(tabletB);
      await a.connect();
      await b.connect();
      await started(a, tabletA, 1);
      await started(b, tabletB, 1);
      tabletB.sendFrame(_keyframe);
      await _until(() => b.tabletStreaming.value);
      final seen = counts();

      await hub.reconnectSession('A');
      await started(a, tabletA, 2);
      expect(hub.sessions['A'], same(a), reason: 'the same session');
      expect(sent(tabletA, 0xF9), 2);
      expect(tabletA.captureRequests, 2);
      expect(tabletA.captureStops, 1);
      expect(remote.disposed, [a.nativeId]);
      expect(adb.inputShellsClosed, ['A']);

      expect(sent(tabletB, 0xF9), 1, reason: 'no second start for B');
      expect(tabletB.controls, [0xF9, 0xF8, 0xFF]);
      expect(tabletB.captureStops, 0);
      expect(tabletB.sharing, isTrue);
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(b.tabletStreaming.value, isTrue);
      expect(remote.made.map((d) => d.session),
          [a.nativeId, b.nativeId, a.nativeId]);
      expect(seen, [1, 2], reason: 'A left the count and came back');
    });

    test('reconnectSession follows the rule for which sessions may restart: '
        'not a key with no session, not an idle one, not one the encoder '
        'refused; one waiting to retry restarts at once', () async {
      final a = made(tabletA);
      final b = made(tabletB);
      await a.connect();
      await started(a, tabletA, 1);

      await hub.reconnectSession('nobody');
      await hub.reconnectSession('B');
      expect(b.phase.value, ConnectionPhase.disconnected);
      expect(tabletB.controls, isEmpty);
      expect(sent(tabletA, 0xF9), 1);

      a.refused.value = true;
      await hub.reconnectSession('A');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sent(tabletA, 0xF9), 1);
      expect(a.phase.value, ConnectionPhase.streaming);
      a.refused.value = false;

      // Its tablet unplugged: in `error`, the retry seconds away.
      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() =>
          a.phase.value == ConnectionPhase.error && a.retryPending.value);
      adb.unplugged.remove('A');
      await hub.reconnectSession('A');
      await started(a, tabletA, 2);
      expect(hub.reverseActive.value, 1);
    });

    test('reconnectExtendedOnly restarts the tablets the Mac extends onto '
        'and no remote-control one, in either direction; reconnect still '
        'restarts them all', () async {
      final a = made(tabletA);
      final b = made(tabletB, extended);
      final c = made(tabletC, driving);
      await a.connect();
      await b.connect();
      await c.connect();
      await started(a, tabletA, 1);
      await started(b, tabletB, 1);
      await started(c, tabletC, 1);
      expect(capture.stops, isEmpty);
      final seen = counts();

      await hub.reconnectExtendedOnly();
      await started(b, tabletB, 2);
      expect(hub.sessions['B'], same(b));
      expect(capture.stops, [b.nativeId]);
      expect(sent(tabletB, 0xF9), 2);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sent(tabletA, 0xF9), 1, reason: 'the tablet the Mac controls');
      expect(tabletA.controls, [0xF9, 0xF8, 0xFF]);
      expect(tabletA.captureStops, 0,
          reason: 'its user is not asked for the screen again');
      expect(remote.disposed, isEmpty);
      expect(adb.inputShellsClosed, isEmpty);
      expect(a.phase.value, ConnectionPhase.streaming);
      expect(sent(tabletC, 0xF9), 1, reason: 'the tablet driving the Mac');
      expect(c.phase.value, ConnectionPhase.streaming);
      expect(capture.stops, isNot(contains(c.nativeId)));
      expect(seen, isEmpty, reason: 'the count never moved');

      await hub.reconnect();
      await started(a, tabletA, 2);
      await started(b, tabletB, 3);
      await started(c, tabletC, 2);
      expect(remote.disposed, [a.nativeId]);
      expect(hub.reverseActive.value, 1);
    });

    test('anything with one link restarts it for either call: a session by '
        'itself is not the hub', () async {
      final a = made(tabletA);
      await a.connect();
      await started(a, tabletA, 1);

      // The base class's defaults, which the client has too.
      await a.reconnectSession('A');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sent(tabletA, 0xF9), 1, reason: 'a no-op without a hub');
      await a.reconnectExtendedOnly();
      await started(a, tabletA, 2);
      expect(a.reverseActive.value, 0,
          reason: 'only the hub counts; a session never sets its own');
      expect(hub.reverseActive.value, 1);
    });
  });

  // From here every hub session has a mode of its own, fixed when it is
  // made, and the hub holds several over USB whatever their modes.
  group('three stand-in tablets the Mac controls at once', () {
    test('each is told its mode and asked for its screen and a keyframe, has '
        'a decoder of its own fed with its own frames, and takes nothing of '
        "the Mac's encoder or displays", () async {
      const panels = [
        ClientPanel(2560, 1600, 60),
        ClientPanel(2800, 2000, 120),
        ClientPanel(2400, 1080, 60),
      ];
      final tablets = [
        for (final (i, panel) in panels.indexed)
          FakeTablet('$syntheticSerialPrefix${i + 1}', panel: panel),
      ];
      for (final t in tablets) {
        addTearDown(t.hangUp);
      }
      final adb = SynthAdb(tablets);
      final hub = hubWith(adb);
      await hub.hostInfoReady;
      hub.budget.estimate = const EncoderEstimate(
          engines: 4, h264PerEngine: 4000, h265PerEngine: 4000);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      expect(hub.cap, 4, reason: 'remote control no longer means one tablet');
      final counts = <int>[];
      final sub = hub.reverseActive.listen(counts.add);
      addTearDown(sub.cancel);

      final sessions = <HostSession>[];
      for (final t in tablets) {
        await hub.connect(serial: t.serial);
        sessions.add(hub.focused!);
        expect(hub.focused!.key, t.serial);
        expect(hub.phase.value, ConnectionPhase.streaming);
      }
      expect(counts, [1, 2, 3]);
      expect(hub.sessions.length, 3);
      expect(sessions.map((s) => s.nativeId).toSet(), hasLength(3));
      expect(hub.remoteSessions, sessions);

      await _until(() => tablets.every((t) => t.keyframeRequests == 1));
      for (final t in tablets) {
        expect(t.controls, [0xF9, 0xF8, 0xFF], reason: t.serial);
        expect(t.mode, SessionMode.remoteControl);
        expect(t.direction, RemoteDirection.macControlsTab);
        expect(t.captureRequests, 1);
      }
      // A decoder each, the size of its own tablet's panel.
      expect(remote.made, [
        for (final (i, s) in sessions.indexed)
          (
            session: s.nativeId,
            codec: CodecType.h265,
            width: panels[i].width,
            height: panels[i].height,
          ),
      ]);
      for (final s in sessions) {
        expect(s.remoteTextureId.value,
            RecordingRemoteVideo.textureFor(s.nativeId));
      }

      // Each tablet's frames go to its own decoder.
      tablets[1].sendFrame(_keyframe);
      await _until(() => remote.fed[sessions[1].nativeId] == 1);
      expect(remote.fed.keys, [sessions[1].nativeId]);
      expect(sessions[1].tabletStreaming.value, isTrue);
      expect(sessions[0].tabletStreaming.value, isFalse);
      tablets[0].sendFrame(_keyframe);
      tablets[2].sendFrame(_keyframe);
      tablets[2].sendFrame(_picture);
      await _until(() =>
          remote.fed[sessions[0].nativeId] == 1 &&
          remote.fed[sessions[2].nativeId] == 2);
      expect(remote.fed[sessions[1].nativeId], 1);

      // A keyframe one decoder asks for is asked of its tablet alone.
      await remote.idr(sessions[1].nativeId);
      await _until(() => tablets[1].keyframeRequests == 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tablets[0].keyframeRequests, 1);
      expect(tablets[2].keyframeRequests, 1);

      // And a tap goes to the tablet it was made on, in its own pixels.
      sessions[2].sendRemoteTap(0.5, 0.5);
      expect(adb.taps, [(tablets[2].serial, 1200, 540)]);

      // None of them is the encoder's or has a display.
      expect(hub.budget.count, 0);
      for (final s in sessions) {
        expect(hub.budget.contains(s.nativeId), isFalse);
        expect(s.granted.value, isNull);
      }
      expect(hub.displays.holders, isEmpty);
      expect(capture.made, isEmpty);
      expect(settings.knownDevices, isEmpty,
          reason: 'stand-in tablets are never remembered');
    });
  });

  group('several tablets, each in its own mode', () {
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const driving = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac);
    const extended = SessionChoice(SessionMode.extendedScreen);

    late FakeTablet tabletA;
    late FakeTablet tabletB;
    late FakeTablet tabletC;
    late _SlowListing adb;
    late HostConnectionManager hub;

    setUp(() async {
      tabletA = FakeTablet('A', panel: ultra);
      tabletB = FakeTablet('B', panel: const ClientPanel(2000, 1200, 60));
      tabletC = FakeTablet('C', panel: const ClientPanel(2400, 1080, 60));
      for (final tablet in [tabletA, tabletB, tabletC]) {
        addTearDown(tablet.hangUp);
      }
      adb = _SlowListing([tabletA, tabletB, tabletC]);
      hub = hubWith(adb);
      await hub.hostInfoReady;
      // Room for four big tablets.
      hub.budget.estimate = const EncoderEstimate(
          engines: 4, h264PerEngine: 4000, h265PerEngine: 4000);
    });

    int sent(FakeTablet tablet, int command) =>
        tablet.controls.where((c) => c == command).length;

    /// Home's selectors, set to [choice].
    Future<void> choose(SessionChoice choice) async {
      await settings.setSessionMode(choice.mode);
      await settings.setRemoteDirection(choice.direction);
    }

    /// The tablet has heard a whole start in [choice]: its [starts]th.
    Future<void> heard(FakeTablet tablet, SessionChoice choice, int starts) =>
        _until(() =>
            sent(tablet, 0xF9) == starts &&
            tablet.mode == choice.mode &&
            (choice.isReverse
                ? tablet.sharing && tablet.direction == choice.direction
                : tablet.rate != null));

    /// The user's pick of [tablet] with the selectors on [choice]: its
    /// session, live, the tablet having heard its start (its first).
    Future<HostSession> pick(FakeTablet tablet, SessionChoice choice) async {
      await choose(choice);
      await hub.connect(serial: tablet.serial);
      final session = hub.sessions[tablet.serial]!;
      expect(session.phase.value, ConnectionPhase.streaming);
      expect(session.choice, choice);
      await heard(tablet, choice, 1);
      return session;
    }

    test('a pick keeps its mode through a retry, a reconnect and a retry run '
        'early, whatever the selectors move to afterwards', () async {
      final a = await pick(tabletA, reverse);
      expect(settings.knownChoice('A'), reverse);

      // The selectors move on, for the next tablet.
      await choose(extended);
      expect(a.spec.isReverseRemote, isTrue);

      // Its link drops: the retry.
      tabletA.mode = tabletA.direction = null;
      await tabletA.hangUp();
      await _until(() =>
          sent(tabletA, 0xF9) == 2 &&
          a.phase.value == ConnectionPhase.streaming);
      expect(tabletA.mode, SessionMode.remoteControl);
      expect(tabletA.direction, RemoteDirection.macControlsTab);

      // A settings change.
      tabletA.mode = tabletA.direction = null;
      await hub.reconnect();
      await _until(() =>
          sent(tabletA, 0xF9) == 3 &&
          a.phase.value == ConnectionPhase.streaming);
      expect(tabletA.direction, RemoteDirection.macControlsTab);

      // Unplugged, then picked again on its card while it waits to retry:
      // that retry, run early, on the same session.
      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() => a.phase.value == ConnectionPhase.error);
      adb.unplugged.remove('A');
      tabletA.mode = tabletA.direction = null;
      await hub.connect(serial: 'A');
      expect(hub.sessions['A'], same(a));
      expect(a.phase.value, ConnectionPhase.streaming);
      await _until(() => sent(tabletA, 0xF9) == 4);
      expect(tabletA.mode, SessionMode.remoteControl);
      expect(tabletA.direction, RemoteDirection.macControlsTab);
      expect(a.choice, reverse);
      expect(settings.knownChoice('A'), reverse);
      expect(capture.made, isEmpty, reason: 'never once an Extended start');

      // While a tablet picked now runs as the selectors say now.
      final b = await pick(tabletB, extended);
      expect(b.spec.isReverseRemote, isFalse);
      expect(hub.reverseActive.value, 1);
    });

    test("one tablet waiting to retry: Home's selector moved to Mac controls "
        'tablet leaves it what it is, so its retry extends again; the '
        "change its card's menu asks for (of that very session) makes it a "
        'new session, which tells the tablet that the Mac controls it',
        () async {
      final a = await pick(tabletA, extended);
      expect(tabletA.mode, SessionMode.extendedScreen);

      // Its link drops and it waits to retry. What used to change its mode
      // then, the selector, now only says what the next tablet runs as.
      tabletA.mode = tabletA.direction = null;
      await tabletA.hangUp();
      await _until(() =>
          a.phase.value == ConnectionPhase.error && a.retryPending.value);
      await choose(reverse);
      expect(settings.nextChoice, reverse);
      expect(a.choice, extended);
      expect(a.spec.mode, SessionMode.extendedScreen);
      expect(a.spec.isReverseRemote, isFalse);
      await _until(() =>
          sent(tabletA, 0xF9) == 2 &&
          a.phase.value == ConnectionPhase.streaming);
      expect(hub.sessions['A'], same(a));
      expect(tabletA.mode, SessionMode.extendedScreen,
          reason: 'the retry ran as the session was made');
      expect(tabletA.captureRequests, 0);
      expect(remote.made, isEmpty);
      expect(settings.knownChoice('A'), extended);
      final extendStarts = capture.made
          .where((call) => call.$1 == 'startCapture')
          .length;
      expect(extendStarts, 2);

      // Waiting to retry again: the card's menu, as Home calls it.
      tabletA.mode = tabletA.direction = null;
      await tabletA.hangUp();
      await _until(() =>
          a.phase.value == ConnectionPhase.error && a.retryPending.value);
      expect(await hub.changeMode('A', reverse, expected: a), isTrue);

      final renewed = hub.sessions['A']!;
      expect(renewed, isNot(same(a)));
      expect(renewed.nativeId, isNot(a.nativeId));
      expect(renewed.choice, reverse);
      expect(renewed.spec.isReverseRemote, isTrue);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      await heard(tabletA, reverse, 3);
      // 0xF9 [1, 1]: remote control, Mac controls tablet.
      expect(tabletA.mode, SessionMode.remoteControl);
      expect(tabletA.direction, RemoteDirection.macControlsTab);
      expect(tabletA.mode!.index, 1);
      expect(tabletA.direction!.index, 1);
      expect(tabletA.captureRequests, 1);
      expect(remote.made.map((d) => d.session), [renewed.nativeId]);
      expect(
          capture.made.where((call) => call.$1 == 'startCapture').length,
          extendStarts,
          reason: 'the Mac captures nothing for a tablet it only views');
      expect(a.isRetired, isTrue);
      expect(a.retryPending.value, isFalse);
      expect(hub.reverseActive.value, 1);
      expect(hub.usbSessionCount, 1);
      expect(settings.knownChoice('A'), reverse);

      // The old session's retry, which was armed, never runs.
      final keys = adb.keysDelivered['A'];
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(hub.sessions['A'], same(renewed));
      expect(adb.keysDelivered['A'], keys);
      expect(sent(tabletA, 0xF9), 3);
    });

    // What CLAUDE.md tells whoever writes a fake hub: overriding
    // connectWith stands in for every connect that picks a tablet, and for
    // nothing else.
    test("a mode change, a reconnect and a retry run early do not go "
        "through connectWith, the seam a pick goes through", () async {
      final seam = (hub as _CountingHub).seam;
      final a = await pick(tabletA, extended);
      expect(seam, ['A']);

      expect(await hub.changeMode('A', driving, expected: a), isTrue);
      final renewed = hub.sessions['A']!;
      expect(renewed, isNot(same(a)));
      expect(renewed.phase.value, ConnectionPhase.streaming);
      await heard(tabletA, driving, 2);
      expect(seam, ['A'], reason: '_replace connects its session itself');

      await hub.reconnectSession('A');
      await heard(tabletA, driving, 3);
      await hub.reconnect();
      await heard(tabletA, driving, 4);
      expect(seam, ['A']);

      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() =>
          renewed.phase.value == ConnectionPhase.error &&
          renewed.retryPending.value);
      adb.unplugged.remove('A');
      await hub.retryNow('A');
      await heard(tabletA, driving, 5);
      expect(hub.sessions['A'], same(renewed));
      expect(seam, ['A']);
    });

    test('a tablet whose Mac -> Tablet link dropped while it shared its '
        'screen never heard that session stop it: its next session, made '
        "Extended on its card's menu, tells it to stop before anything "
        'else, once per attempt and never for a capture rebuild', () async {
      final a = await pick(tabletA, reverse);
      tabletA.sendFrame(_keyframe);
      await _until(() => remote.fed[a.nativeId] == 1);

      // The cable comes out: the stop the session sends as it ends goes
      // nowhere, and the tablet stops nothing when a link drops.
      adb.unplugged.add('A');
      await tabletA.hangUp();
      await _until(() =>
          a.phase.value == ConnectionPhase.error && a.retryPending.value);
      expect(tabletA.sharing, isTrue);
      expect(tabletA.captureStops, 0);
      expect(tabletA.controls, [0xF9, 0xF8, 0xFF]);

      // Its card's menu while it waits, then the cable goes back in.
      expect(await hub.changeMode('A', extended, expected: a), isTrue);
      final renewed = hub.sessions['A']!;
      expect(renewed, isNot(same(a)));
      expect(renewed.spec.isReverseRemote, isFalse);
      adb.unplugged.remove('A');
      await _until(() => renewed.phase.value == ConnectionPhase.streaming);
      await heard(tabletA, extended, 2);

      // The tablet is one thing only: a second screen, sharing nothing.
      expect(tabletA.mode, SessionMode.extendedScreen);
      expect(tabletA.sharing, isFalse,
          reason: 'or it goes on encoding and sending its screen');
      expect(tabletA.captureStops, 1);
      expect(tabletA.controls.skip(3).take(2), [0xF7, 0xF9],
          reason: "the stop is the first thing the new session says");
      expect(tabletA.captureRequests, 1);
      tabletA.sendFrame(_keyframe);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(remote.fed, {a.nativeId: 1},
          reason: 'nothing of the tablet reaches a decoder any more');

      // A rebuild inside the session (the Mac woke) starts the capture
      // again and says the mode again, but the link never dropped, so the
      // tablet cannot have started anything: no stop.
      final starts = capture.made.length;
      capture.onCaptureRestartNeeded!(null);
      await _until(() =>
          capture.made.length > starts && sent(tabletA, 0xF9) == 3);
      expect(tabletA.captureStops, 1);

      // A retry is a new attempt: the Mac cannot know what happened on the
      // tablet meanwhile, so it says it again.
      await tabletA.hangUp();
      await _until(() =>
          sent(tabletA, 0xF9) == 4 &&
          renewed.phase.value == ConnectionPhase.streaming);
      expect(hub.sessions['A'], same(renewed));
      expect(tabletA.captureStops, 2);
    });

    test('the same after Cancel on its card and a press on its tile with '
        'the Add panel on another mode: a tablet that drives the Mac, or '
        'extends it, is told to stop the capture a dead link left running',
        () async {
      for (final (tablet, next) in [(tabletA, driving), (tabletB, extended)]) {
        final old = await pick(tablet, reverse);
        adb.unplugged.add(tablet.serial);
        await tablet.hangUp();
        await _until(() => old.phase.value == ConnectionPhase.error);

        // Cancel: the session is gone, and with it the only one that would
        // ever have told this tablet to stop.
        await hub.disconnectSession(tablet.serial, userStopped: true);
        expect(hub.sessions.containsKey(tablet.serial), isFalse);
        expect(tablet.sharing, isTrue, reason: tablet.serial);
        expect(tablet.captureStops, 0, reason: tablet.serial);

        // Plugged in again and picked as something else.
        adb.unplugged.remove(tablet.serial);
        await choose(next);
        hub.allowDevice(tablet.serial);
        await hub.connect(serial: tablet.serial);
        final session = hub.sessions[tablet.serial]!;
        expect(session.phase.value, ConnectionPhase.streaming);
        expect(session.choice, next);
        await heard(tablet, next, 2);
        expect(tablet.sharing, isFalse, reason: tablet.serial);
        expect(tablet.captureStops, 1, reason: tablet.serial);
        expect(tablet.controls.skip(3).take(2), [0xF7, 0xF9],
            reason: tablet.serial);
      }
      expect(hub.reverseActive.value, 0);
    });

    // Two paths to B's Connect: the role chooser's (a role picked for it,
    // here Extended, not the one it is remembered in), and the remembered
    // row's (no role: it connects as it is remembered, Mac → tablet), the
    // one a remembered device's row takes when that role fits.
    for (final picked in [extended, null]) {
    test('a Connect pressed while an automatic connect is still asking adb '
        'for the devices connects a stopped tablet once, '
        '${picked == null ? "in its remembered role (the row's path)" : "in the role picked, not as it is remembered (the chooser's path)"}'
        ': the stop is lifted only with the pick itself, after the '
        'permissions were asked about, and the policy does not start it '
        'too', () async {
      final role = picked ?? reverse;
      await pick(tabletA, extended);
      await pick(tabletB, reverse);
      expect(settings.knownChoice('B'), reverse);
      // Stopped on its card; what a new device gets is Extended.
      await hub.disconnectSession('B', userStopped: true);
      expect(hub.stoppedDevices, {'B'});
      await choose(extended);

      // Home over this hub. Both permissions are granted, and the answer to
      // a check waits while [answer] is set.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Completer<void>? answer;
      var checks = 0;
      messenger.setMockMethodCallHandler(_permissions, (_) async {
        checks++;
        await answer?.future;
        return {'screen_recording': true, 'accessibility': true};
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(_permissions, null));
      Get.put<BaseConnectionManager>(hub);
      final home = Get.put(HomeController());
      // Home's own first look (its policy run finds B stopped).
      await _until(() => checks == 1);
      await pumpEventQueue();
      expect(hub.sessions.keys, ['A']);

      // The app comes to the front: Home runs the policy, whose listing
      // adb takes its time over.
      adb.listingGate = Completer<void>();
      home.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _until(() => adb.listingsWaiting >= 1);

      // B's Connect is pressed; the press's own permission check is out.
      answer = Completer<void>();
      final pressed = home.onConnectDevice(
          const DeviceModel(
              serial: 'B', model: 'Tablet B', status: DeviceStatus.connected),
          choice: picked);
      await _until(() => checks == 3);

      // adb answers the policy first: B is still the tablet the user
      // stopped, so the policy starts nothing.
      adb.listingGate!.complete();
      adb.listingGate = null;
      await pumpEventQueue();
      expect(hub.sessions.keys, ['A'],
          reason: 'not connected as it is remembered, under the pick');
      expect(hub.stoppedDevices, {'B'});

      // The permissions are there: the pick goes ahead, in its role.
      answer.complete();
      await pressed;
      final b = hub.sessions['B']!;
      expect(b.choice, role);
      expect(b.phase.value, ConnectionPhase.streaming);
      if (picked != null) {
        // (Its display joins A's, so its capture is started twice: no
        // count of starts here.)
        await _until(() =>
            tabletB.mode == SessionMode.extendedScreen &&
            tabletB.rate != null);
        expect(tabletB.sharing, isFalse);
        expect(sent(tabletB, 0xF8), 1,
            reason: 'asked for its screen by the first pick alone');
      } else {
        // Asked for its screen again, by this pick alone.
        await _until(() => sent(tabletB, 0xF8) == 2);
        expect(tabletB.mode, SessionMode.remoteControl);
      }
      expect(hub.stoppedDevices, isEmpty);
      expect(adb.keysDelivered['B'], 2, reason: 'one session made for it');
      expect(settings.knownChoice('B'), role);
      // A remembered device's pick is not what a new one gets.
      expect(settings.nextChoice.sameEffect(extended), isTrue);
    });
    }

    test("changing one tablet's mode ends its session and makes it a new "
        'one in that mode: the tablet is told to stop sharing, its decoder '
        'and its shell go, the new session has an id of its own and the '
        "tablet's own display serial, and the other tablets hear nothing",
        () async {
      final a = await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      final c = await pick(tabletC, reverse);
      await _until(() => [tabletA, tabletB, tabletC]
          .every((t) => t.keyframeRequests == 1));
      b.sendRemoteTap(0.5, 0.5);
      expect(settings.knownChoice('B'), reverse);
      expect(hub.focused, same(c));
      final oldId = b.nativeId;
      // The hub has listed what is attached, as Home's Add panel has it
      // (a pick with a serial lists nothing).
      await hub.refreshDevices();
      expect(hub.availableDevices.map((d) => d.serial),
          containsAll(['A', 'B', 'C']));
      expect(hub.freeDevices, isEmpty);

      // The old session's end takes a while.
      adb.removeDelay = const Duration(milliseconds: 250);
      final changing = hub.changeMode('B', extended, expected: b);
      // In the same step: B is out of the sessions, its place is held, and
      // it is remembered in the new mode.
      expect(hub.sessions.keys.toSet(), {'A', 'C'});
      expect(hub.heldUsbPlaces, {'A', 'B', 'C'});
      expect(hub.availableDevices.map((d) => d.serial), contains('B'));
      expect(hub.freeDevices, isEmpty,
          reason: 'not offered as a tablet to add meanwhile');
      expect(settings.knownChoice('B'), extended);
      expect(hub.reverseActive.value, 2);

      // The auto-connect policy runs meanwhile (the app came to the front):
      // B is attached, known and has no session, and is left alone.
      await hub.connectIfUnambiguous();
      await hub.connect(serial: 'B');
      expect(hub.sessions.containsKey('B'), isFalse,
          reason: 'neither the policy nor a pick brings it back early');

      expect(await changing, isTrue);
      final renewed = hub.sessions['B']!;
      expect(renewed, isNot(same(b)));
      expect(renewed.nativeId, isNot(oldId));
      expect(renewed.vdSerial, b.vdSerial);
      expect(renewed.choice, extended);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      await heard(tabletB, extended, 2);
      expect(tabletB.mode, SessionMode.extendedScreen);
      expect(adb.keysDelivered['B'], 2, reason: 'one new session, no more');

      // The old one is over, as its own mode has it.
      expect(b.isRetired, isTrue);
      expect(b.phase.value, ConnectionPhase.disconnected);
      // Told to stop twice over this live link: by the old session as it
      // ended, and by the new one as it began (the one that counts when
      // the old link was already dead).
      expect(tabletB.captureStops, 2);
      expect(tabletB.controls.take(6), [0xF9, 0xF8, 0xFF, 0xF7, 0xF7, 0xF9]);
      expect(tabletB.sharing, isFalse);
      expect(remote.disposed, [oldId]);
      expect(adb.inputShellsClosed, ['B']);
      // And the new one captures the Mac's screen for the tablet.
      expect(capture.made, [
        ('createVirtualDisplay', renewed.nativeId),
        ('startCapture', renewed.nativeId),
      ]);
      expect(hub.budget.contains(renewed.nativeId), isTrue);
      expect(hub.budget.count, 1);
      expect(remote.made.map((d) => d.session),
          [a.nativeId, oldId, c.nativeId],
          reason: 'no decoder for a tablet the Mac extends onto');

      // The others ran on, untouched.
      for (final (tablet, session) in [(tabletA, a), (tabletC, c)]) {
        expect(tablet.controls, [0xF9, 0xF8, 0xFF], reason: tablet.serial);
        expect(tablet.captureRequests, 1);
        expect(tablet.captureStops, 0);
        expect(hub.sessions[tablet.serial], same(session));
        expect(session.phase.value, ConnectionPhase.streaming);
      }
      expect(adb.keysDelivered['A'], 1);
      expect(adb.keysDelivered['C'], 1);
      expect(hub.reverseActive.value, 2);
      expect(hub.remoteSessions, [a, c]);
      expect(hub.focused, same(c), reason: 'B was not the one shown');
      expect(hub.usbSessionCount, 3);
      expect(hub.freeDevices, isEmpty, reason: 'every tablet has a session');
    });

    test('a change of the tablet the hub shows, beside another live tablet, '
        'shows the other one only while its old session ends: its new '
        'session is the one shown again', () async {
      final a = await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      expect(hub.focused, same(b));
      adb.removeDelay = const Duration(milliseconds: 200);

      final changing = hub.changeMode('B', driving, expected: b);
      // At once: B has no session, so the hub shows the tablet shown
      // before it.
      expect(hub.focused, same(a));
      expect(hub.focusedKey.value, 'A');

      expect(await changing, isTrue);
      final renewed = hub.sessions['B']!;
      expect(renewed, isNot(same(b)));
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(renewed),
          reason: 'B was the one shown when its mode was changed');
      expect(hub.focusedKey.value, 'B');
      expect(hub.activeDevice.value?.serial, 'B');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions['A'], same(a));
      expect(a.phase.value, ConnectionPhase.streaming);
    });

    test('Connect with nothing chosen while a tablet is between two '
        'sessions settles on a tablet that is free, never on the one '
        'changing mode, though that is the last one used', () async {
      await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      expect(settings.lastDeviceSerial, 'B');
      adb.removeDelay = const Duration(milliseconds: 300);

      final changing = hub.changeMode('B', driving, expected: b);
      expect(hub.sessions.keys.toSet(), {'A'});
      // The Connect button, as a hub with a session to add beside has it:
      // adb is asked what is attached, and B is among it.
      await hub.connect();
      final c = hub.sessions['C'];
      expect(c, isNotNull, reason: 'the free tablet, not nothing at all');
      expect(c!.phase.value, ConnectionPhase.streaming);
      expect(c.choice, reverse);
      expect(hub.availableDevices.map((d) => d.serial),
          containsAll(['A', 'B', 'C']));

      expect(await changing, isTrue);
      final renewed = hub.sessions['B']!;
      expect(renewed, isNot(same(b)));
      expect(renewed.choice, driving);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(adb.keysDelivered, {'A': 1, 'B': 2, 'C': 1},
          reason: 'one new session for B, made by its change alone');
      expect(hub.sessions.keys.toSet(), {'A', 'B', 'C'});
    });

    test('a change of the tablet the hub shows keeps it shown, and never '
        'shows disconnected, with room for several tablets too', () async {
      final b = await pick(tabletB, reverse);
      expect(hub.cap, 4);
      expect(hub.focused, same(b));
      adb.removeDelay = const Duration(milliseconds: 200);
      final phases = <ConnectionPhase>[];
      final worker = ever<ConnectionPhase>(hub.phase, phases.add);
      addTearDown(worker.dispose);

      expect(await hub.changeMode('B', driving), isTrue);
      final renewed = hub.sessions['B']!;
      expect(hub.focused, same(renewed));
      expect(hub.focusedKey.value, 'B');
      expect(renewed.choice, driving);
      expect(phases.first, ConnectionPhase.detectingDevice);
      expect(phases.last, ConnectionPhase.streaming);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));
      await heard(tabletB, driving, 2);
      expect(tabletB.direction, RemoteDirection.tabControlsMac);
      expect(hub.reverseActive.value, 0);
    });

    test('with Maximum tablets 1 a change never shows disconnected either, '
        'holds off a pick of another tablet, and the tablet ends up live in '
        'its new mode', () async {
      await settings.setMaxTablets(1);
      final b = await pick(tabletB, reverse);
      expect(hub.cap, 1);
      adb.removeDelay = const Duration(milliseconds: 200);
      final phases = <ConnectionPhase>[];
      final worker = ever<ConnectionPhase>(hub.phase, phases.add);
      addTearDown(worker.dispose);

      final changing = hub.changeMode('B', extended);
      expect(hub.phase.value, ConnectionPhase.detectingDevice);
      // One tablet at a time: nothing else is picked while it changes.
      await hub.connect(serial: 'A');
      expect(hub.sessions, isEmpty);
      expect(await changing, isTrue);

      final renewed = hub.sessions['B']!;
      expect(hub.sessions.keys, ['B']);
      expect(renewed, isNot(same(b)));
      expect(renewed.choice, extended);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(renewed));
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));
      expect(phases.first, ConnectionPhase.detectingDevice);
      expect(phases.last, ConnectionPhase.streaming);
      await heard(tabletB, extended, 2);
      expect(adb.keysDelivered, {'B': 2});
    });

    test('with Maximum tablets 1, a change whose old session fails to end '
        'does not leave the hub showing a connect for a tablet that is not '
        'coming back: it reads disconnected, and a tablet can be picked',
        () async {
      await settings.setMaxTablets(1);
      final b = await pick(tabletB, reverse);
      expect(hub.cap, 1);

      // The old session's teardown throws half way.
      input.releaseFails = true;
      await expectLater(
          hub.changeMode('B', extended, expected: b), throwsStateError);
      input.releaseFails = false;
      expect(hub.sessions, isEmpty);
      expect(hub.heldUsbPlaces, isEmpty);
      expect(hub.replacing, isFalse);
      expect(hub.phase.value, ConnectionPhase.disconnected,
          reason: 'or, one tablet at a time, nothing could be picked again');

      // (This test's own tidying: the teardown that failed, run to its
      // end, so nothing of B's old link is left open.)
      await b.disconnect();

      final a = await pick(tabletA, extended);
      expect(hub.sessions.keys, ['A']);
      expect(hub.focused, same(a));
    });

    test('two tablets changing mode at once, the first one\'s old session '
        'failing to end: the hub goes on showing a connect while the other '
        'one is still on its way back, and never reads disconnected',
        () async {
      final a = await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      expect(hub.focused, same(b));
      // Both old sessions take a while to end; A's teardown throws half
      // way, long before B's is done.
      adb.removeDelay = const Duration(milliseconds: 300);
      input.releaseFailsFor.add(a.nativeId);
      final phases = <ConnectionPhase>[];
      final worker = ever<ConnectionPhase>(hub.phase, phases.add);
      addTearDown(worker.dispose);

      final changingA = hub.changeMode('A', driving, expected: a);
      final changingB = hub.changeMode('B', driving, expected: b);
      final failed = expectLater(changingA, throwsStateError);
      expect(hub.sessions, isEmpty);
      expect(hub.heldUsbPlaces, {'A', 'B'});
      expect(hub.phase.value, ConnectionPhase.detectingDevice);

      // A is not coming back. B still is: not idle, so Home offers no
      // link selector and the policy does not take the hub for idle.
      await failed;
      expect(hub.sessions, isEmpty);
      expect(hub.heldUsbPlaces, {'B'});
      expect(hub.replacing, isTrue);
      expect(hub.phase.value, ConnectionPhase.detectingDevice);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));

      expect(await changingB, isTrue);
      final renewed = hub.sessions['B']!;
      expect(hub.sessions.keys, ['B']);
      expect(renewed.choice, driving);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(renewed));
      expect(hub.replacing, isFalse);
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));

      // (This test's own tidying: the teardown that failed, run to its
      // end, so nothing of A's old link is left open.)
      input.releaseFailsFor.clear();
      await a.disconnect();
    });

    test('a change is refused while a change of link is ending the '
        'sessions: no tablet is given a new USB session as the link '
        'becomes Wi-Fi', () async {
      await pick(tabletA, reverse);
      await pick(tabletB, reverse);
      final c = await pick(tabletC, reverse);
      // All three wait to retry, so Home's link selector could be there
      // (it shows with at most one session; the hub does not rest on that).
      for (final tablet in [tabletA, tabletB, tabletC]) {
        adb.unplugged.add(tablet.serial);
        await tablet.hangUp();
      }
      await _until(() => hub.sessions.values.every((s) =>
          s.phase.value == ConnectionPhase.error && s.retryPending.value));

      // The sessions end one after the other, each taking a while.
      adb.removeDelay = const Duration(milliseconds: 300);
      unawaited(settings.setLinkType(LinkType.wifi));
      await _until(() => !hub.sessions.containsKey('A'));
      expect(hub.sessions.keys.toSet(), {'B', 'C'},
          reason: 'A is ending; B and C still wait their turn');

      expect(await hub.changeMode('C', extended, expected: c), isFalse);
      expect(hub.sessions['C'], same(c));
      expect(c.isRetired, isFalse);
      expect(settings.knownChoice('C'), reverse);
      expect(hub.replacing, isFalse);

      await hub.disconnect();
      expect(hub.sessions, isEmpty);
      expect(adb.keysDelivered['C'], 1, reason: 'no second session for C');
    });

    test('a change is refused, and nothing happens, for a session that is '
        'not the one the caller saw, no session at all, a tablet being '
        'picked or still ending, a session on its way to being live, and a '
        'mode that comes to the same thing', () async {
      final a = await pick(tabletA, extended);
      final b = await pick(tabletB, reverse);

      /// Nothing was ended or made.
      void untouched() {
        expect(hub.sessions['A'], same(a));
        expect(hub.sessions['B'], same(b));
        expect(adb.keysDelivered, {'A': 1, 'B': 1});
        expect(settings.knownChoice('A'), extended);
        expect(settings.knownChoice('B'), reverse);
      }

      // Not the session the caller was looking at.
      expect(await hub.changeMode('B', extended, expected: a), isFalse);
      // No such tablet.
      expect(await hub.changeMode('NOBODY', extended), isFalse);
      // What it already is; the direction means nothing to an Extended
      // screen.
      expect(await hub.changeMode('B', reverse), isFalse);
      expect(await hub.changeMode('A', extended), isFalse);
      expect(
          await hub.changeMode(
              'A',
              const SessionChoice(
                  SessionMode.extendedScreen, RemoteDirection.macControlsTab)),
          isFalse);
      untouched();
      expect(b.isRetired, isFalse);
      expect(tabletB.captureStops, 0);

      // B waits to retry, and is being picked (its card's Retry): the pick
      // has it.
      adb.unplugged.add('B');
      await tabletB.hangUp();
      await _until(() => b.phase.value == ConnectionPhase.error);
      adb.unplugged.remove('B');
      final retry = hub.connect(serial: 'B');
      expect(await hub.changeMode('B', extended), isFalse);
      await retry;
      expect(b.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions['B'], same(b));
      expect(b.choice, reverse);

      // C is on its way to being live: its attempt is left to finish.
      adb.deliveryGates['C'] = Completer<void>();
      await choose(reverse);
      final connecting = hub.connect(serial: 'C');
      await _until(() =>
          hub.sessions['C']?.phase.value == ConnectionPhase.handshaking);
      final c = hub.sessions['C']!;
      expect(await hub.changeMode('C', extended), isFalse);
      expect(hub.sessions['C'], same(c));
      adb.deliveryGates.remove('C')!.complete();
      await connecting;
      expect(c.phase.value, ConnectionPhase.streaming);
      expect(c.choice, reverse);

      // Still ending (its card's Disconnect): there is no session to
      // change.
      adb.removeDelay = const Duration(milliseconds: 200);
      final ending = hub.disconnectSession('C');
      expect(await hub.changeMode('C', extended), isFalse);
      await ending;
      expect(hub.sessions.containsKey('C'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.sessions.containsKey('C'), isFalse, reason: 'not remade');

      // And while everything is being disconnected: the hub ends them one
      // after the other, so B is still its session when this is asked.
      final all = hub.disconnect();
      expect(hub.sessions['B'], same(b));
      expect(await hub.changeMode('B', extended), isFalse);
      await all;
      expect(hub.sessions, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.sessions, isEmpty);
      expect(settings.knownChoice('A'), extended);
      expect(settings.knownChoice('B'), reverse);
    });

    test('a Disconnect of everything while a tablet changes mode leaves '
        'nothing connected', () async {
      await pick(tabletA, extended);
      await pick(tabletB, reverse);
      adb.removeDelay = const Duration(milliseconds: 300);

      final changing = hub.changeMode('B', extended);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await hub.disconnect();
      expect(await changing, isTrue, reason: 'it had begun');
      // Well past the old session's end.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(hub.sessions, isEmpty);
      expect(hub.phase.value, ConnectionPhase.disconnected);
      expect(hub.heldUsbPlaces, isEmpty);
      expect(adb.keysDelivered, {'A': 1, 'B': 1}, reason: 'no new session');
      expect(sent(tabletB, 0xF9), 1);
      expect(adb.reverses, isEmpty);
      // What the user asked for is remembered, for when it connects again.
      expect(settings.knownChoice('B'), extended);

      // And nothing is left held: the tablet can be picked again.
      await choose(extended);
      await hub.connect(serial: 'B');
      expect(hub.sessions['B']!.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions['B']!.choice, extended);
    });

    test("a changing tablet's place is held: with every place taken, a pick "
        'of another tablet while its old session ends is refused, and the '
        'tablet comes back', () async {
      await settings.setMaxTablets(2);
      final a = await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      expect(hub.cap, 2);
      expect(hub.canAdd, isFalse);
      adb.removeDelay = const Duration(milliseconds: 300);

      final changing = hub.changeMode('B', driving);
      expect(hub.usbSessionCount, 1, reason: 'B has no session right now');
      expect(hub.heldUsbPlaces, {'A', 'B'});
      expect(hub.canAdd, isFalse);
      await hub.connect(serial: 'C');
      expect(hub.sessions.containsKey('C'), isFalse);
      expect(adb.keysDelivered.containsKey('C'), isFalse);

      expect(await changing, isTrue);
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
      final renewed = hub.sessions['B']!;
      expect(renewed, isNot(same(b)));
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(renewed.choice, driving);
      expect(hub.sessions['A'], same(a));
      expect(hub.heldUsbPlaces, {'A', 'B'});
      expect(hub.canAdd, isFalse);
    });

    test('a tablet changing mode comes back even after Maximum tablets was '
        'lowered under the live count: a lowered cap stops nobody', () async {
      await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      await settings.setMaxTablets(1);
      expect(hub.cap, 1);
      expect(hub.usbSessionCount, 2);

      expect(await hub.changeMode('B', driving), isTrue);
      final renewed = hub.sessions['B']!;
      expect(renewed, isNot(same(b)));
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
      // While a new tablet is still refused.
      await hub.connect(serial: 'C');
      expect(hub.sessions.containsKey('C'), isFalse);
    });

    test('a tablet changing into a mode the Mac encodes comes back under a '
        'lowered Maximum tablets too, beside a tablet that is encoding: '
        'its place is its own, and only the encoder could refuse it',
        () async {
      final a = await pick(tabletA, extended);
      // Not `pick`: a second display makes the first one's capture start
      // again, so the tablets hear more than one start.
      await choose(extended);
      await hub.connect(serial: 'B');
      final b = hub.sessions['B']!;
      await _until(
          () => a.granted.value != null && b.granted.value != null);
      expect(hub.budget.count, 2);
      await settings.setMaxTablets(1);
      expect(hub.cap, 1);

      // Extended -> Tablet -> Mac: the Mac encodes for it in both.
      expect(await hub.changeMode('B', driving), isTrue);
      var renewed = hub.sessions['B']!;
      expect(renewed, isNot(same(b)));
      expect(renewed.choice, driving);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(renewed.refused.value, isFalse);
      expect(renewed.errorKey.value, isNull);
      expect(renewed.granted.value, isNotNull);
      expect(hub.budget.contains(renewed.nativeId), isTrue);
      expect(hub.budget.count, 2);

      // And back to the mode it ran a moment ago.
      expect(await hub.changeMode('B', extended), isTrue);
      renewed = hub.sessions['B']!;
      expect(renewed.choice, extended);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(renewed.refused.value, isFalse);
      expect(renewed.granted.value, isNotNull);

      expect(hub.sessions['A'], same(a));
      expect(a.phase.value, ConnectionPhase.streaming);
      // While a new tablet is still refused, by the hub, before any
      // session is made for it.
      await hub.connect(serial: 'C');
      expect(hub.sessions.keys.toSet(), {'A', 'B'});
      expect(adb.keysDelivered.containsKey('C'), isFalse);
    });

    test('a tablet whose mode is changed while another one is shown is the '
        'one the hub shows once that one ends: the hub never reads '
        'disconnected with a tablet live', () async {
      await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      expect(hub.focused, same(b));

      expect(await hub.changeMode('A', driving), isTrue);
      final renewed = hub.sessions['A']!;
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(b), reason: 'A was not the one shown');

      final ending = hub.disconnectSession('B', userStopped: true);
      // At once, before B has ended.
      expect(hub.focused, same(renewed));
      expect(hub.focusedKey.value, 'A');
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.activeDevice.value?.serial, 'A');
      await ending;
      expect(hub.focused, same(renewed));

      // With Maximum tablets lowered to 1 afterwards, the lone tablet's
      // Retry is its own session's, and Disconnect leaves nothing behind.
      await settings.setMaxTablets(1);
      adb.unplugged.add('A');
      tabletA.hangUp();
      await _until(() => renewed.phase.value == ConnectionPhase.error);
      adb.unplugged.remove('A');
      await hub.connect(serial: 'A');
      expect(hub.sessions['A'], same(renewed));
      expect(hub.sessions.length, 1);
      expect(renewed.phase.value, ConnectionPhase.streaming);

      await hub.disconnect();
      expect(renewed.isRetired, isTrue);
      expect(renewed.retryPending.value, isFalse);
      expect(renewed.phase.value, ConnectionPhase.disconnected);
      expect(adb.reverses, isEmpty);
    });

    test('a tablet whose mode is changed while another one is shown takes '
        'the last place in line: when the shown one ends, the hub shows the '
        'tablet that was shown before it, and the changed one after that',
        () async {
      await pick(tabletA, reverse);
      final b = await pick(tabletB, reverse);
      final c = await pick(tabletC, reverse);
      expect(hub.focused, same(c));

      expect(await hub.changeMode('A', driving), isTrue);
      final renewed = hub.sessions['A']!;
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(c));

      final endingC = hub.disconnectSession('C', userStopped: true);
      expect(hub.focused, same(b),
          reason: 'B was shown more recently than a tablet that only '
              'changed mode in the background');
      final endingB = hub.disconnectSession('B', userStopped: true);
      expect(hub.focused, same(renewed));
      expect(hub.phase.value, ConnectionPhase.streaming);
      await Future.wait([endingC, endingB]);
    });

    test('a session the hub was never told to show is the one it shows '
        'once the shown one ends, while there is no other: the hub never '
        'reads disconnected with a session there', () async {
      final b = await pick(tabletB, reverse);
      // In the hub's map, as a test puts one there: never focused, so in
      // no focus history.
      final other = HostSession(
        key: 'A',
        link: LinkType.usb,
        serial: 'A',
        choice: reverse,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      hub.sessions['A'] = other;
      await other.connect();
      expect(other.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(b));

      final ending = hub.disconnectSession('B', userStopped: true);
      // At once, before B has ended.
      expect(hub.focused, same(other));
      expect(hub.focusedKey.value, 'A');
      expect(hub.phase.value, ConnectionPhase.streaming);
      await ending;
      expect(hub.focused, same(other));
    });

    /// The one session of a hub with Maximum tablets 1, in its map as a
    /// test puts one there (never focused), live, as [reverse].
    Future<HostSession> unshown(FakeTablet tablet) async {
      await settings.setMaxTablets(1);
      await choose(reverse);
      final lone = HostSession(
        key: tablet.serial,
        link: LinkType.usb,
        serial: tablet.serial,
        choice: reverse,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      hub.sessions[tablet.serial] = lone;
      await lone.connect();
      expect(lone.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, isNull);
      expect(hub.phase.value, ConnectionPhase.disconnected);
      return lone;
    }

    test('with Maximum tablets 1, a session the hub does not show is still '
        'the one session there is: a pick of another tablet while it is '
        'live does nothing, and a pick of its own tablet connects that very '
        'session', () async {
      final lone = await unshown(tabletA);

      // Shown or not, a live session holds off every other pick.
      await hub.connect(serial: 'C');
      expect(hub.sessions.keys, ['A']);
      expect(hub.sessions['A'], same(lone));
      expect(lone.isRetired, isFalse);
      expect(lone.phase.value, ConnectionPhase.streaming);
      expect(adb.keysDelivered.containsKey('C'), isFalse);

      // Its link drops, and its tablet is picked (its card's Retry).
      adb.unplugged.add('A');
      tabletA.hangUp();
      await _until(() => lone.phase.value == ConnectionPhase.error);
      await hub.connect(serial: 'A');
      expect(hub.sessions['A'], same(lone), reason: 'no second session');
      expect(hub.sessions.length, 1);
      expect(lone.isRetired, isFalse);
      expect(hub.focused, same(lone));
      adb.unplugged.remove('A');
      await _until(() => lone.phase.value == ConnectionPhase.streaming);
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.sessions['A'], same(lone));
    });

    test('with Maximum tablets 1, a pick of another tablet while the one '
        'session, which the hub does not show, waits to retry ends that '
        'session first: never two sessions', () async {
      final lone = await unshown(tabletA);
      adb.unplugged.add('A');
      tabletA.hangUp();
      await _until(() => lone.phase.value == ConnectionPhase.error);
      expect(hub.focused, isNull);

      await hub.connect(serial: 'C');
      expect(hub.sessions.keys, ['C'],
          reason: 'not a session for C beside A\'s, which nothing shows');
      expect(lone.isRetired, isTrue);
      expect(lone.retryPending.value, isFalse);
      final c = hub.sessions['C']!;
      expect(c.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(c));
      expect(hub.heldUsbPlaces, {'C'});
    });

    test('with Maximum tablets 1, a session that is there for the picked '
        'tablet once the old one has ended is the one connected: none is '
        'made over it', () async {
      final lone = await unshown(tabletA);
      adb.unplugged.add('A');
      tabletA.hangUp();
      await _until(() => lone.phase.value == ConnectionPhase.error);

      // The pick of C ends A's session first; while it does, a session
      // for C turns up in the map (as a test puts one there).
      final picking = hub.connect(serial: 'C');
      expect(lone.isRetired, isTrue);
      expect(hub.sessions, isEmpty);
      final other = HostSession(
        key: 'C',
        link: LinkType.usb,
        serial: 'C',
        choice: reverse,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      );
      hub.sessions['C'] = other;
      await picking;
      expect(hub.sessions['C'], same(other),
          reason: 'a second one made over it would leave it out of reach');
      expect(hub.sessions.length, 1);
      expect(other.isRetired, isFalse);
      expect(other.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(other));
      expect(adb.keysDelivered['C'], 1);
    });

    test('while a tablet is between two sessions the hub says so, to '
        'whatever builds from it the way an Obx does, and does not read '
        'disconnected when the tablet it shows is ended meanwhile',
        () async {
      await pick(tabletB, reverse);
      final a = await pick(tabletA, reverse);
      expect(hub.focused, same(a));
      expect(hub.replacing, isFalse);
      final observer = RxNotifier<dynamic>();
      addTearDown(observer.close);
      var events = 0;
      observer.listen((_) => events++);
      expect(RxInterface.notifyChildren(observer, () => hub.replacing),
          isFalse);
      final phases = <ConnectionPhase>[];
      final worker = ever<ConnectionPhase>(hub.phase, phases.add);
      addTearDown(worker.dispose);

      // B's old session takes a while to end.
      adb.removeDelay = const Duration(milliseconds: 300);
      final changing = hub.changeMode('B', driving);
      expect(hub.replacing, isTrue);
      expect(events, greaterThan(0));
      // A's card's Disconnect, in that window: no session is left, but a
      // tablet is on its way back.
      final ending = hub.disconnectSession('A', userStopped: true);
      expect(hub.sessions, isEmpty);
      expect(hub.heldUsbPlaces, {'B'});
      expect(hub.replacing, isTrue);
      expect(hub.phase.value, ConnectionPhase.detectingDevice,
          reason: 'not idle: Home offers no link selector');

      await ending;
      expect(await changing, isTrue);
      final renewed = hub.sessions['B']!;
      expect(hub.replacing, isFalse);
      expect(hub.heldUsbPlaces, {'B'});
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(renewed));
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));
      expect(settings.linkType, LinkType.usb);
    });

    test('two picks at once with one place left: exactly one is admitted',
        () async {
      await settings.setMaxTablets(2);
      await pick(tabletA, reverse);
      expect(hub.canAdd, isTrue);

      await Future.wait(
          [hub.connect(serial: 'B'), hub.connect(serial: 'C')]);
      expect(hub.sessions.length, 2);
      final added = hub.sessions.keys.where((k) => k != 'A').single;
      expect(hub.sessions[added]!.phase.value, ConnectionPhase.streaming);
      expect(adb.keysDelivered.keys.toSet(), {'A', added});
      expect(hub.heldUsbPlaces, {'A', added});
    });

    test('a tablet whose mode is changed before it was ever live is '
        'remembered in the new one once its new session is', () async {
      // A session that failed before going live (its tablet was picked and
      // unplugged at once): the tablet is not known.
      adb.unplugged.add('B');
      await choose(reverse);
      unawaited(hub.connect(serial: 'B'));
      await _until(() =>
          hub.sessions['B']?.phase.value == ConnectionPhase.error);
      expect(settings.knownDevice('B'), isNull);
      adb.unplugged.remove('B');

      expect(await hub.changeMode('B', extended), isTrue);
      expect(settings.knownDevice('B'), isNotNull);
      expect(hub.sessions['B']!.phase.value, ConnectionPhase.streaming);
      expect(settings.knownChoice('B'), extended);
      await heard(tabletB, extended, 1);
    });
  });

  group('over Wi-Fi the one session keeps its mode too', () {
    const wifi = HostConnectionManager.wifiKey;
    late HostConnectionManager hub;
    late WifiIdentity identity;
    late int port;

    setUp(() async {
      if (_opensslMissing != null) return;
      final pairing = Get.put(WifiPairingService());
      Get.put<WifiDiscoveryService>(_NoDiscovery());
      identity = await pairing.ensureIdentity();
      await settings.setLinkType(LinkType.wifi);
      port = await _freePort();
      final adb = SynthAdb(const []);
      Get.put<AdbService>(adb);
      hub = HostConnectionManager(
          adb: adb,
          port: port,
          devicePollInterval: null,
          hostGranted: () async => true);
      addTearDown(hub.disconnect);
    });

    /// A tablet that has dialled in and heard the session's mode.
    Future<_WifiTablet> dialIn() async {
      final tablet = _WifiTablet(identity, port);
      addTearDown(tablet.hangUp);
      await tablet.dial();
      await _until(() => tablet.modes.isNotEmpty);
      return tablet;
    }

    /// The Wi-Fi session, live in Extended screen, then its tablet gone:
    /// waiting to listen again.
    Future<HostSession> waitingToRetry() async {
      expect(hub.cap, 1);
      unawaited(hub.connect());
      final session = hub.sessions[wifi]!;
      expect(session.choice.mode, SessionMode.extendedScreen);
      final tablet = await dialIn();
      expect(tablet.modes,
          [(SessionMode.extendedScreen, RemoteDirection.tabControlsMac)]);
      await _until(() => session.phase.value == ConnectionPhase.streaming);
      await tablet.hangUp();
      await _until(() =>
          session.phase.value == ConnectionPhase.error &&
          session.retryPending.value);
      return session;
    }

    test('while it waits to retry, the selectors moving changes nothing for '
        'it: its own retry tells the tablet the mode it was made for',
        () async {
      final session = await waitingToRetry();
      await settings.setSessionMode(SessionMode.remoteControl);
      expect(session.spec.mode, SessionMode.extendedScreen);

      final again = await dialIn();
      expect(again.modes,
          [(SessionMode.extendedScreen, RemoteDirection.tabControlsMac)]);
      expect(hub.sessions[wifi], same(session));
      expect(session.choice.mode, SessionMode.extendedScreen);
    }, skip: _opensslMissing);

    test('changed through the hub while it waits to retry, it is replaced by '
        'a session in the new mode, which listens at once and tells the '
        'tablet that mode; a change of direction alone is no change',
        () async {
      final session = await waitingToRetry();
      final phases = <ConnectionPhase>[];
      final worker = ever<ConnectionPhase>(hub.phase, phases.add);
      addTearDown(worker.dispose);

      // What Home's selector does: save, then ask the hub.
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      expect(await hub.changeMode(wifi, settings.nextChoice), isFalse,
          reason: 'still an Extended screen');
      expect(hub.sessions[wifi], same(session));

      await settings.setSessionMode(SessionMode.remoteControl);
      final changing = hub.changeMode(wifi, settings.nextChoice);
      final again = await dialIn();
      expect(await changing, isTrue);
      final renewed = hub.sessions[wifi]!;
      expect(renewed, isNot(same(session)));
      expect(renewed.nativeId, isNot(session.nativeId));
      expect(session.isRetired, isTrue);
      expect(renewed.phase.value, ConnectionPhase.streaming);
      expect(hub.focused, same(renewed));
      // Mac controls tablet does not exist over Wi-Fi: the tablet drives.
      expect(again.modes,
          [(SessionMode.remoteControl, RemoteDirection.tabControlsMac)]);
      expect(renewed.spec.isReverseRemote, isFalse);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));
      expect(phases.first, ConnectionPhase.handshaking);

      // The other direction again is the same thing there.
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      expect(await hub.changeMode(wifi, settings.nextChoice), isFalse);
      expect(hub.sessions[wifi], same(renewed));
    }, skip: _opensslMissing);
  });

  test('a tablet the Mac extends onto is never asked for its screen or for '
      'a keyframe, and no decoder is made or fed for it', () async {
    final tablet = FakeTablet('TAB', panel: ultra);
    addTearDown(tablet.hangUp);
    final hub = hubWith(SynthAdb([tablet]));

    await hub.connect(serial: 'TAB');
    expect(hub.phase.value, ConnectionPhase.streaming);
    await _until(() => tablet.rate != null);
    expect(tablet.mode, SessionMode.extendedScreen);
    expect(tablet.direction, RemoteDirection.tabControlsMac);
    expect(tablet.captureRequests, 0);
    expect(tablet.sharing, isFalse);
    expect(tablet.keyframeRequests, 0);

    tablet.sendFrame(_keyframe);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(remote.fed, isEmpty);
    expect(remote.made, isEmpty);
    expect(hub.focused!.tabletStreaming.value, isFalse);
  });
}
