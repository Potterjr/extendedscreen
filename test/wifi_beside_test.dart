import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
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

/// Listen on Wi-Fi beside USB: the hub keeps one Wi-Fi session (the beside
/// session) waiting for a paired device while USB tablets run, each device
/// in its own mode. [FakeTablet]s play the USB tablets, [_WifiDevice] a
/// paired iPhone (or a stranger on the LAN) over real TLS on loopback, so
/// plain `test()` and real time.

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

/// ScreenCaptureKit, stood in for: every virtual display made is kept with
/// the serial it was given.
class _Capture extends ScreenCaptureChannel {
  /// (session, serialNum) of every virtual display made.
  final displays = <(int, int)>[];
  final starts = <int>[];

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<VirtualDisplayResult> createVirtualDisplay(DisplayConfigModel config,
      {required int session,
      int serialNum = 1,
      String name = 'Extended Screen'}) async {
    displays.add((session, serialNum));
    return VirtualDisplayResult(displayId: 10 + session, applied: true);
  }

  @override
  Future<CaptureStart> startCapture(DisplayConfigModel config,
      {required int session}) async {
    starts.add(session);
    return CaptureStart(displayId: 10 + session);
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
  Future<void> setBitrate(int bitsPerSecond, {required int session}) async {}
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

/// No UDP. Counts the responder's starts and stops, which only the Wi-Fi
/// session may make.
class _Discovery extends WifiDiscoveryService {
  int starts = 0;
  int stops = 0;

  @override
  Future<void> startResponder({
    required Uint8List hostId,
    required String name,
    required int tcpPort,
  }) async =>
      starts++;

  @override
  void stopResponder() => stops++;
}

/// A device on Wi-Fi: dials the Mac's TLS port, presents the pairing token
/// (unless [stranger]), says HELLO as [platform] with [panel], answers
/// pings and keeps every mode the Mac announces (`0xF9`).
class _WifiDevice {
  _WifiDevice(this.identity, this.port,
      {this.platform = HostSession.helloPlatformIphone,
      this.panel = const ClientPanel(2496, 1320, 120),
      this.stranger = false});

  final WifiIdentity identity;
  final int port;
  final int platform;
  final ClientPanel panel;
  final bool stranger;
  final _socket = SocketService();
  StreamSubscription<Packet>? _sub;

  final modes = <(SessionMode, RemoteDirection)>[];

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
    if (stranger) return;
    _send([WifiPairingService.authCommand, ...identity.token]);
    final w = panel.width, h = panel.height;
    _send([0x01, platform, w >> 8, w & 0xFF, h >> 8, h & 0xFF, panel.maxHz]);
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

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
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

// The beside session makes a real certificate, with macOS's openssl.
final _opensslMissing =
    Platform.isMacOS && File('/usr/bin/openssl').existsSync()
        ? null
        : 'needs /usr/bin/openssl (macOS)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wifi = HostConnectionManager.wifiKey;
  const ultra = ClientPanel(2960, 1848, 120);
  late SettingsService settings;
  late _Capture capture;
  late _Discovery discovery;
  late WifiIdentity identity;
  late int port;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    capture = Get.put<ScreenCaptureChannel>(_Capture()) as _Capture;
    Get.put<InputInjectChannel>(_Input());
    Get.put<RemoteVideoChannel>(RecordingRemoteVideo());
    discovery = Get.put<WifiDiscoveryService>(_Discovery()) as _Discovery;
    if (_opensslMissing == null) {
      identity = await Get.put(WifiPairingService()).ensureIdentity();
    }
    port = await _freePort();
  });

  tearDown(Get.reset);

  /// A hub over [tablets], on the free [port] for Wi-Fi, with room on the
  /// encoder for several devices, torn down after the test.
  Future<HostConnectionManager> hubWith(List<FakeTablet> tablets) async {
    for (final t in tablets) {
      addTearDown(t.hangUp);
    }
    final adb = SynthAdb(tablets);
    Get.put<AdbService>(adb);
    final hub = HostConnectionManager(
        adb: adb,
        port: port,
        devicePollInterval: null,
        hostGranted: () async => true);
    addTearDown(hub.disconnect);
    await hub.hostInfoReady;
    hub.budget.estimate = const EncoderEstimate(
        engines: 4, h264PerEngine: 4000, h265PerEngine: 4000);
    return hub;
  }

  /// A device dialled in on the beside session, which is live with it.
  Future<_WifiDevice> phoneIn(HostConnectionManager hub,
      {int platform = HostSession.helloPlatformIphone}) async {
    final phone = _WifiDevice(identity, port, platform: platform);
    addTearDown(phone.hangUp);
    await phone.dial();
    await _until(() =>
        hub.besideSession?.phase.value == ConnectionPhase.streaming &&
        phone.modes.isNotEmpty);
    return phone;
  }

  test('off by default: a USB tablet connects as before and nothing '
      'listens on Wi-Fi', () async {
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    expect(settings.wifiListen, isFalse);
    await hub.autoConnect();
    await _until(() => hub.phase.value == ConnectionPhase.streaming);
    expect(hub.sessions.keys, ['TAB']);
    expect(hub.wifiBeside, isFalse);
    expect(discovery.starts, 0);
  });

  test('on: the Mac listens beside the Tab, which still connects by itself; '
      'the listener is not shown, takes no place and is not under way',
      () async {
    await settings.setWifiListen(true);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    expect(hub.wifiBeside, isTrue);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession?.phase.value == ConnectionPhase.handshaking);
    final beside = hub.besideSession!;
    expect(beside.beside, isTrue);
    expect(beside.link, LinkType.wifi);
    expect(hub.focused?.key, 'TAB', reason: 'the listener is never shown');
    expect(hub.heldPlaces, {'TAB'});
    expect(hub.anyConnecting, isFalse);
    expect(HostConnectionManager.isListening(beside), isTrue);
    await _until(() => discovery.starts == 1);
  }, skip: _opensslMissing);

  test('on with no tablet: the listener alone leaves the hub idle', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith(const []);
    await hub.autoConnect();
    await _until(() => hub.besideSession != null);
    expect(hub.phase.value, ConnectionPhase.disconnected);
    expect(hub.focused, isNull);
  }, skip: _opensslMissing);

  test('an iPhone joins beside the extending Tab in a mode of its own: the '
      'Tab keeps extending, the iPhone drives the Mac, on a display identity '
      'that is not the Tab\'s', () async {
    await settings.setWifiListen(true);
    settings.setWifiListenChoice(const SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab));
    final tab = FakeTablet('TAB', panel: ultra);
    final hub = await hubWith([tab]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession != null);
    // What the Mac announced reaches the tablet a moment after it is live.
    await _until(() => tab.mode == SessionMode.extendedScreen);

    final phone = await phoneIn(hub);
    final beside = hub.besideSession!;
    expect(phone.modes.last,
        (SessionMode.remoteControl, RemoteDirection.tabControlsMac));
    expect(beside.platform, HostSession.helloPlatformIphone);
    expect(beside.spec.displayMode, DisplayMode.mirror);
    expect(beside.activeDevice.value?.model, 'iPhone');
    expect(hub.heldPlaces, {'TAB', wifi});
    expect(hub.sessions['TAB']!.spec.mode, SessionMode.extendedScreen);
    expect(hub.focused?.key, 'TAB', reason: 'the Tab stays the one shown');
    // Neither display identity is the other's: the Tab keeps its own, the
    // Wi-Fi device has its own, never 1 when that may be a tablet's.
    expect(beside.vdSerial, isNot(1));
    expect(beside.vdSerial, isNot(hub.sessions['TAB']!.vdSerial));
    expect(settings.lastClientPanel, ultra,
        reason: "an iPhone's area is no guess for a new tablet");
  }, skip: _opensslMissing);

  test('the iPhone leaving gives its place up: the beside session listens '
      'again and a second USB tablet can be added under Maximum tablets 2',
      () async {
    await settings.setWifiListen(true);
    await settings.setMaxTablets(2);
    final second = FakeTablet('TAB2', panel: const ClientPanel(2560, 1600, 60));
    final hub = await hubWith([FakeTablet('TAB', panel: ultra), second]);
    await hub.autoConnect();
    await hub.connect(serial: 'TAB');
    await _until(() => hub.besideSession != null);
    final phone = await phoneIn(hub);
    final beside = hub.besideSession!;
    expect(hub.heldPlaces, {'TAB', wifi});
    expect(hub.canAdd, isFalse, reason: 'two places, both taken');

    final starts = discovery.starts;
    await phone.hangUp();
    await _until(() => !beside.trusted.value);
    expect(hub.heldPlaces, {'TAB'});
    expect(beside.granted.value, isNull);
    expect(hub.budget.count, 1, reason: 'no reservation is kept for it');
    expect(hub.canAdd, isTrue);
    expect(hub.focused?.key, 'TAB');

    await hub.connect(serial: 'TAB2');
    expect(hub.sessions['TAB2']!.phase.value, ConnectionPhase.streaming);
    // The same session listens again: its server up, its responder
    // answering.
    await _until(() =>
        identical(hub.besideSession, beside) && discovery.starts > starts);
  }, skip: _opensslMissing);

  test('shown when it is the only one live, and no longer once it only '
      'listens again', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith(const []);
    await hub.autoConnect();
    await _until(() => hub.besideSession != null);
    final phone = await phoneIn(hub);
    expect(hub.focused, same(hub.besideSession));
    expect(hub.phase.value, ConnectionPhase.streaming);

    final starts = discovery.starts;
    await phone.hangUp();
    await _until(() => hub.focused == null);
    expect(hub.phase.value, ConnectionPhase.disconnected);
    // Listening again: its server is up and its responder answers.
    await _until(() => discovery.starts > starts);
  }, skip: _opensslMissing);

  test('a stranger that finishes TLS and never shows the token takes no '
      'place and is not under way', () async {
    await settings.setWifiListen(true);
    await settings.setMaxTablets(2);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession?.phase.value == ConnectionPhase.handshaking);
    final stranger = _WifiDevice(identity, port, stranger: true);
    addTearDown(stranger.hangUp);
    await stranger.dial();
    await _until(() =>
        hub.besideSession?.phase.value == ConnectionPhase.configuring);
    expect(hub.heldPlaces, {'TAB'});
    expect(hub.anyConnecting, isFalse);
    expect(hub.canAdd, isTrue);
    expect(hub.focused?.key, 'TAB');
  }, skip: _opensslMissing);

  test("a USB tablet's teardown leaves the listener's discovery responder "
      'answering', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming && discovery.starts >= 1);
    final stops = discovery.stops;
    await hub.disconnectSession('TAB');
    expect(discovery.stops, stops);
    expect(hub.besideSession, isNotNull);
  }, skip: _opensslMissing);

  test('turning the toggle off, or Maximum tablets to 1, ends the beside '
      'session alone; turning it on again listens again', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession != null);

    await settings.setWifiListen(false);
    await _until(() => hub.sessions[wifi] == null);
    expect(hub.sessions['TAB']!.phase.value, ConnectionPhase.streaming);

    await settings.setWifiListen(true);
    await _until(() => hub.besideSession != null);

    await settings.setMaxTablets(1);
    await _until(() => hub.sessions[wifi] == null);
    expect(hub.wifiBeside, isFalse);
    expect(hub.sessions['TAB']!.phase.value, ConnectionPhase.streaming);
  }, skip: _opensslMissing);

  test('with the toggle off, a connect of the Wi-Fi key over USB makes '
      'nothing',
      () async {
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.connect(serial: wifi);
    expect(hub.sessions, isEmpty);
  });

  test('its mode changed while it listens is kept for the next device, and '
      'the new listener runs as it', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await hub.connect(serial: 'TAB');
    await _until(() => hub.besideSession != null);
    final listener = hub.besideSession!;
    expect(listener.choice.mode, SessionMode.extendedScreen);

    const remote = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac);
    unawaited(hub.changeMode(wifi, remote));
    await _until(() =>
        hub.besideSession != null &&
        !identical(hub.besideSession, listener));
    expect(hub.besideSession!.choice, remote);
    expect(settings.wifiListenChoice, remote);
    expect(settings.knownChoice(wifi), isNull);

    final phone = await phoneIn(hub);
    expect(phone.modes.last,
        (SessionMode.remoteControl, RemoteDirection.tabControlsMac));
  }, skip: _opensslMissing);

  test('a link change ends the beside session; over the Wi-Fi link the '
      "link's own session listens, with the display identity of old",
      () async {
    await settings.setWifiListen(true);
    final hub = await hubWith(const []);
    await hub.autoConnect();
    await _until(() => hub.besideSession != null);

    await settings.setLinkType(LinkType.wifi);
    await _until(() => hub.besideSession == null);
    expect(hub.wifiBeside, isFalse);
    // The user's Connect on the Wi-Fi card, once the change has ended the
    // listener (until then the hub takes no pick).
    await _until(() {
      if (hub.sessions[wifi] == null) unawaited(hub.connect());
      return hub.sessions[wifi] != null;
    });
    final own = hub.sessions[wifi]!;
    expect(own.beside, isFalse);
    expect(own.vdSerial, 1);

    final device = _WifiDevice(identity, port,
        platform: HostSession.helloPlatformAndroid,
        panel: const ClientPanel(2000, 1200, 60));
    addTearDown(device.hangUp);
    await device.dial();
    await _until(() => own.phase.value == ConnectionPhase.streaming);
    expect(hub.focused, same(own));
    expect(capture.displays.last.$2, 1);
  }, skip: _opensslMissing);
  test('while the listener waits, the policy still has room for a known '
      'tablet plugged in under Maximum tablets 2', () async {
    await settings.setWifiListen(true);
    await settings.setMaxTablets(2);
    await settings.rememberDevice('TAB2', model: 'Second', vdSerial: 7);
    final second = FakeTablet('TAB2', panel: const ClientPanel(2560, 1600, 60));
    final hub = await hubWith([FakeTablet('TAB', panel: ultra), second]);
    final adb = Get.find<AdbService>() as SynthAdb;
    adb.unplugged.add('TAB2');
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession?.phase.value == ConnectionPhase.handshaking);

    adb.unplugged.remove('TAB2');
    await hub.refreshDevices();
    await hub.connectIfUnambiguous(only: {'TAB2'});
    await _until(() =>
        hub.sessions['TAB2']?.phase.value == ConnectionPhase.streaming);
    expect(hub.heldPlaces, {'TAB', 'TAB2'});
    expect(hub.besideSession, isNotNull, reason: 'it still listens');
  }, skip: _opensslMissing);

  test("a Disconnect of everything, the facade's Cancel included, leaves the "
      'Mac listening while the switch is on', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession != null);
    final before = hub.besideSession;
    hub.pauseAutoConnect();
    await hub.disconnect();
    await _until(() =>
        hub.besideSession != null && !identical(hub.besideSession, before));
    expect(hub.sessions.keys, [wifi], reason: 'the Tab stays stopped');
  }, skip: _opensslMissing);

  test('Maximum tablets lowered to 1 leaves a live iPhone running, and ends '
      'its session once the iPhone has gone', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.besideSession != null);
    final phone = await phoneIn(hub);
    final beside = hub.besideSession!;

    await settings.setMaxTablets(1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(beside.phase.value, ConnectionPhase.streaming);

    await phone.hangUp();
    await _until(() => hub.sessions[wifi] == null);
    expect(hub.sessions['TAB']!.phase.value, ConnectionPhase.streaming);
  }, skip: _opensslMissing);

}
