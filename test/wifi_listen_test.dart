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
import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

import 'support/recording_remote_video.dart';

/// Listening on Wi-Fi: the hub's one listener takes every paired device that
/// dials in, each into a session of its own beside the USB tablets, each in
/// its own mode. [FakeTablet]s play the USB tablets, [_WifiDevice] a paired
/// iPhone or tablet (or a stranger on the LAN) over real TLS on loopback, so
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
      this.stranger = false,
      this.installId});

  final WifiIdentity identity;
  final int port;
  final int platform;
  final ClientPanel panel;
  final bool stranger;

  /// Sent in HELLO's identity tail when set (a tablet build from before
  /// phase 4 sends none).
  final Uint8List? installId;
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
    _send([
      0x01, platform, w >> 8, w & 0xFF, h >> 8, h & 0xFF, panel.maxHz,
      if (installId != null) ...HelloTail.encode(installId!, ''),
    ]);
  }

  bool get connected => _socket.isConnected;

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

/// An install id made of [b] sixteen times.
Uint8List _id(int b) => Uint8List.fromList(List.filled(16, b));

String _key(int b) => 'wifi:${List.filled(16, b.toRadixString(16).padLeft(2, '0')).join()}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ultra = ClientPanel(2960, 1848, 120);
  late SettingsService settings;
  late _Discovery discovery;
  late WifiIdentity identity;
  late int port;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    Get.put<ScreenCaptureChannel>(_Capture());
    Get.put<InputInjectChannel>(_Input());
    Get.put<RemoteVideoChannel>(RecordingRemoteVideo());
    discovery = Get.put<WifiDiscoveryService>(_Discovery()) as _Discovery;
    if (_opensslMissing == null) {
      identity = await Get.put(WifiPairingService()).ensureIdentity();
    }
    port = await _freePort();
  });

  tearDown(Get.reset);

  /// A hub over [tablets], listening on the free [port], with room on the
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
    addTearDown(() => settings.setWifiListen(false));
    await hub.hostInfoReady;
    hub.budget.estimate = const EncoderEstimate(
        engines: 4, h264PerEngine: 4000, h265PerEngine: 4000);
    return hub;
  }

  /// A device dialled in and live in its own session.
  Future<_WifiDevice> deviceIn(HostConnectionManager hub,
      {int platform = HostSession.helloPlatformIphone,
      Uint8List? installId,
      ClientPanel panel = const ClientPanel(2496, 1320, 120)}) async {
    final before = hub.wifiSessions.length;
    final device = _WifiDevice(identity, port,
        platform: platform, installId: installId, panel: panel);
    addTearDown(device.hangUp);
    await device.dial();
    await _until(() =>
        hub.wifiSessions.length > before &&
        hub.wifiSessions.every(
            (s) => s.phase.value == ConnectionPhase.streaming) &&
        device.modes.isNotEmpty);
    return device;
  }

  /// The hub with the Tab live over USB and the listener up.
  Future<HostConnectionManager> tabAndListener({int? maxTablets}) async {
    await settings.setWifiListen(true);
    if (maxTablets != null) await settings.setMaxTablets(maxTablets);
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    await hub.autoConnect();
    await _until(() =>
        hub.phase.value == ConnectionPhase.streaming &&
        hub.listening.value &&
        discovery.starts >= 1);
    return hub;
  }

  test('off by default: a USB tablet connects as before and nothing '
      'listens on Wi-Fi', () async {
    final hub = await hubWith([FakeTablet('TAB', panel: ultra)]);
    expect(settings.wifiListen, isFalse);
    await hub.autoConnect();
    await _until(() => hub.phase.value == ConnectionPhase.streaming);
    expect(hub.listening.value, isFalse);
    expect(hub.sessions.keys, ['TAB']);
    expect(discovery.starts, 0);
  });

  test('on: the Mac listens beside the Tab, which still connects by itself; '
      'listening is no session and takes no place', () async {
    final hub = await tabAndListener();
    expect(hub.sessions.keys, ['TAB']);
    expect(hub.heldPlaces, {'TAB'});
    expect(hub.anyConnecting, isFalse);
    expect(hub.focused?.key, 'TAB');
  }, skip: _opensslMissing);

  test('an iPhone that says who it is joins beside the extending Tab in a '
      'mode of its own, on a display identity that is not the Tab\'s, and '
      'is known from then on', () async {
    settings.setWifiListenChoice(const SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab));
    final hub = await tabAndListener();
    final tab = hub.sessions['TAB']!;
    final besideSerial = settings.vdSerialFor('wifi', taken: {tab.vdSerial});
    await deviceIn(hub, installId: _id(0xAB));
    final phone = hub.sessions[_key(0xAB)]!;
    expect(phone.link, LinkType.wifi);
    expect(phone.spec.direction, RemoteDirection.tabControlsMac,
        reason: 'over Wi-Fi, and as an iPhone, it can only drive the Mac');
    expect(phone.spec.displayMode, DisplayMode.mirror);
    expect(phone.activeDevice.value?.model, 'iPhone');
    expect(hub.heldPlaces, {'TAB', _key(0xAB)});
    expect(tab.spec.mode, SessionMode.extendedScreen);
    expect(hub.focused?.key, 'TAB', reason: 'the Tab stays the one shown');
    expect(phone.vdSerial, isNot(1));
    expect(phone.vdSerial, isNot(tab.vdSerial));
    expect(phone.vdSerial, besideSerial,
        reason: "the first known Wi-Fi device keeps the beside session's display");
    await _until(() => settings.knownDevice(_key(0xAB)) != null);
    expect(settings.knownDevice(_key(0xAB))!.vdSerial, phone.vdSerial);
    expect(settings.lastDeviceSerial, 'TAB',
        reason: 'a Wi-Fi device is never the last-used adb device');
  }, skip: _opensslMissing);

  test('two devices on one listener, each in its own session: the anonymous '
      'tablet (today\'s build) keeps display serial 1 with no USB tablet',
      () async {
    await settings.setWifiListen(true);
    final hub = await hubWith(const []);
    await hub.autoConnect();
    await _until(() => hub.listening.value);
    await deviceIn(hub, installId: _id(0x01));
    await deviceIn(hub,
        platform: HostSession.helloPlatformAndroid,
        panel: const ClientPanel(2000, 1200, 60));
    expect(hub.wifiSessions.length, 2);
    final anonymous =
        hub.wifiSessions.firstWhere((s) => s.key.contains('conn'));
    expect(anonymous.vdSerial, 1);
    expect(hub.heldPlaces.length, 2);
    expect(settings.lastClientPanel, isNot(const ClientPanel(2496, 1320, 120)));
  }, skip: _opensslMissing);

  test('a device leaving ends its session (the device redials, no retry), '
      'and gives its place up for a second USB tablet under Maximum tablets 2',
      () async {
    await settings.setWifiListen(true);
    await settings.setMaxTablets(2);
    final second = FakeTablet('TAB2', panel: const ClientPanel(2560, 1600, 60));
    final hub = await hubWith([FakeTablet('TAB', panel: ultra), second]);
    await hub.autoConnect();
    await hub.connect(serial: 'TAB');
    await _until(() => hub.listening.value);
    final phone = await deviceIn(hub, installId: _id(0x02));
    expect(hub.canAdd, isFalse, reason: 'two places, both taken');

    await phone.hangUp();
    await _until(() => hub.sessions[_key(0x02)] == null);
    expect(hub.heldPlaces, {'TAB'});
    expect(hub.budget.count, 1, reason: 'no reservation is kept for it');
    expect(hub.canAdd, isTrue);
    expect(hub.focused?.key, 'TAB');

    await hub.connect(serial: 'TAB2');
    expect(hub.sessions['TAB2']!.phase.value, ConnectionPhase.streaming);
    expect(hub.listening.value, isTrue);
  }, skip: _opensslMissing);

  test('the same device dialling in again replaces its stale session', () async {
    await settings.setWifiListen(true);
    final hub = await hubWith(const []);
    await hub.autoConnect();
    await _until(() => hub.listening.value);
    await deviceIn(hub, installId: _id(0x03));
    final first = hub.sessions[_key(0x03)]!;
    // A second connection before the Mac has seen the first one drop.
    final again = _WifiDevice(identity, port, installId: _id(0x03));
    addTearDown(again.hangUp);
    await again.dial();
    await _until(() =>
        hub.sessions[_key(0x03)] != null &&
        !identical(hub.sessions[_key(0x03)], first) &&
        hub.sessions[_key(0x03)]!.phase.value == ConnectionPhase.streaming);
    expect(first.isRetired, isTrue);
    expect(hub.wifiSessions.length, 1);
  }, skip: _opensslMissing);

  test('with every place taken a device is turned away, and Home is told',
      () async {
    final hub = await tabAndListener(maxTablets: 1);
    final phone = _WifiDevice(identity, port, installId: _id(0x04));
    addTearDown(phone.hangUp);
    await phone.dial();
    await _until(() => hub.wifiTurnedAway.value == 1);
    expect(hub.wifiSessions, isEmpty);
    expect(hub.sessions['TAB']!.phase.value, ConnectionPhase.streaming);
  }, skip: _opensslMissing);

  test('a stranger that finishes TLS and never shows the token gets no '
      'session, and a paired device still gets in', () async {
    final hub = await tabAndListener();
    final stranger = _WifiDevice(identity, port, stranger: true);
    addTearDown(stranger.hangUp);
    await stranger.dial();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.wifiSessions, isEmpty);
    expect(hub.heldPlaces, {'TAB'});
    await deviceIn(hub, installId: _id(0x05));
    expect(hub.wifiSessions.length, 1);
  }, skip: _opensslMissing);

  test("a USB tablet's teardown leaves the listener's discovery responder "
      'answering', () async {
    final hub = await tabAndListener();
    final stops = discovery.stops;
    await hub.disconnectSession('TAB');
    expect(discovery.stops, stops);
    expect(hub.listening.value, isTrue);
  }, skip: _opensslMissing);

  test('turning the switch off stops listening and ends the Wi-Fi devices '
      'alone; on again listens again', () async {
    final hub = await tabAndListener();
    await deviceIn(hub, installId: _id(0x06));

    await settings.setWifiListen(false);
    await _until(() => !hub.listening.value && hub.wifiSessions.isEmpty);
    expect(hub.sessions['TAB']!.phase.value, ConnectionPhase.streaming);
    expect(discovery.stops, greaterThan(0));

    await settings.setWifiListen(true);
    await _until(() => hub.listening.value);
    await deviceIn(hub, installId: _id(0x06));
  }, skip: _opensslMissing);

  test("a Wi-Fi device's mode changed from its card ends its session and is "
      'what it runs in when it dials in again', () async {
    final hub = await tabAndListener();
    final phone = await deviceIn(hub, installId: _id(0x07));
    final first = hub.sessions[_key(0x07)]!;
    expect(first.choice.mode, SessionMode.extendedScreen);
    await _until(() => settings.knownDevice(_key(0x07)) != null);

    const remote = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac);
    expect(await hub.changeMode(_key(0x07), remote), isTrue);
    expect(first.isRetired, isTrue);
    expect(settings.knownChoice(_key(0x07)), remote);
    await phone.hangUp();

    final again = await deviceIn(hub, installId: _id(0x07));
    expect(hub.sessions[_key(0x07)]!.choice, remote);
    expect(again.modes.last,
        (SessionMode.remoteControl, RemoteDirection.tabControlsMac));
  }, skip: _opensslMissing);

  test('a device the user stopped is turned away until listening is turned '
      'on again, then gets in', () async {
    final hub = await tabAndListener();
    final phone = await deviceIn(hub, installId: _id(0x08));
    await hub.disconnectSession(_key(0x08), userStopped: true);
    await phone.hangUp();
    final back = _WifiDevice(identity, port, installId: _id(0x08));
    addTearDown(back.hangUp);
    await back.dial();
    // The Mac sees it prove itself, then closes it.
    await _until(() => !back.connected);
    expect(hub.sessions[_key(0x08)], isNull);

    await settings.setWifiListen(false);
    await settings.setWifiListen(true);
    await _until(() => hub.listening.value);
    expect(hub.stoppedDevices, isEmpty);
    await deviceIn(hub, installId: _id(0x08));
  }, skip: _opensslMissing);

  test('Reset Wi-Fi pairing while listening ends the Wi-Fi devices and '
      'listens again with the new identity: the old token opens nothing',
      () async {
    final hub = await tabAndListener();
    final phone = await deviceIn(hub, installId: _id(0x09));
    await hub.resetWifiIdentity();
    await _until(() => hub.wifiSessions.isEmpty && hub.listening.value);
    await phone.hangUp();
    // The same device with the old pairing: no TLS it trusts, no token that
    // passes. (It dials trusting anything; the token is what is refused.)
    final stale = _WifiDevice(identity, port, installId: _id(0x09));
    addTearDown(stale.hangUp);
    await stale.dial();
    await _until(() => !stale.connected);
    expect(hub.wifiSessions, isEmpty);
    expect(hub.sessions['TAB']!.phase.value, ConnectionPhase.streaming);
  }, skip: _opensslMissing);

  test('a tablet without an install id never takes serial 1 from a known '
      'tablet, and its stop is not kept', () async {
    await settings.rememberDevice('TAB', model: 'Tab', vdSerial: 1);
    await settings.setWifiListen(true);
    final hub = await hubWith(const []);
    await hub.autoConnect();
    await _until(() => hub.listening.value);
    await deviceIn(hub,
        platform: HostSession.helloPlatformAndroid,
        panel: const ClientPanel(2000, 1200, 60));
    final anonymous = hub.wifiSessions.single;
    expect(anonymous.vdSerial, isNot(1));
    await hub.disconnectSession(anonymous.key, userStopped: true);
    expect(hub.stoppedDevices, isEmpty);
    expect(settings.clientPanelFor(anonymous.key), isNull,
        reason: 'nothing is kept under a key that never comes back');
  }, skip: _opensslMissing);

  test('a Mac saved on the Wi-Fi link moves to USB with the switch on',
      () async {
    await settings.setLinkType(LinkType.wifi);
    await settings.migrateHostLinkToListen();
    expect(settings.linkType, LinkType.usb);
    expect(settings.wifiListen, isTrue);
  });
}
