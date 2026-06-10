import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'adb_service.dart';
import 'socket_service.dart';
import 'connection_state.dart';
import '../models/device_model.dart';
import '../models/display_config_model.dart';
import '../models/packet_model.dart';
import '../models/touch_event_model.dart';
import '../protocol/packet_codec.dart';
import '../platform/screen_capture_channel.dart';
import '../platform/input_inject_channel.dart';
import '../services/logger_service.dart';
import '../services/settings_service.dart';

/// Orchestrates the connection and takes a platform-specific role:
///  - macOS  = HOST:   runs `adb reverse`, TCP server, captures+encodes the
///                     screen, injects input received from the tablet.
///  - Android = CLIENT: connects through the adb-reverse tunnel, decodes+renders
///                     frames (in DisplayController), sends touch/mouse/keys.
class ConnectionManager extends GetxService with WidgetsBindingObserver {
  final _adb = Get.find<AdbService>();
  final _socket = Get.find<SocketService>();
  final _log = Get.find<LoggerService>();
  final _settings = Get.find<SettingsService>();

  // macOS-only channels (resolved lazily; registered only on the host).
  ScreenCaptureChannel get _capture => Get.find<ScreenCaptureChannel>();
  InputInjectChannel get _input => Get.find<InputInjectChannel>();

  static const _host = '127.0.0.1';
  static const _port = 7001;
  static const _heartbeatInterval = Duration(seconds: 2);

  bool get isHost => GetPlatform.isMacOS || GetPlatform.isDesktop;

  final phase = ConnectionPhase.disconnected.obs;
  final errorMessage = ''.obs;
  final activeDevice = Rxn<DeviceModel>();
  final latencyMs = 0.obs;

  /// Raw packet stream for consumers (DisplayController reads FRAME_DATA here).
  Stream<Packet> get packetStream => _socket.packetStream;

  // Actual display bounds (updated after capture starts in extend/mirror mode).
  Map<String, double> _displayBounds = {'x': 0, 'y': 0, 'w': 2960, 'h': 1848};

  StreamSubscription? _packetSub;
  StreamSubscription? _frameSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _lastPingTs = 0; // timestamp of the most-recently sent ping

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only disconnect on full process detach; hidden/paused keeps streaming.
    if (state == AppLifecycleState.detached) {
      disconnect();
    } else if (state == AppLifecycleState.resumed && !phase.value.isActive) {
      // Reconnect if the link was lost while backgrounded.
      connect();
    }
  }

  Future<void> connect() async {
    if (phase.value.isConnecting || phase.value.isActive) return;
    if (isHost) {
      await _connectAsHost();
    } else {
      await _connectAsClient();
    }
  }

  // ─── HOST (macOS) ───────────────────────────────────────────────────────

  Future<void> _connectAsHost() async {
    try {
      _setPhase(ConnectionPhase.detectingDevice);
      final devices = await _adb.listDevices();
      if (devices.isEmpty) throw Exception('No ADB device detected');

      final preferred = _settings.lastDeviceSerial;
      final device = preferred != null
          ? (devices.firstWhereOrNull((d) => d.serial == preferred) ??
              devices.first)
          : devices.first;
      activeDevice.value = device;
      await _settings.setLastDevice(device.serial);
      _log.i('Host: using device ${device.serial}');

      _setPhase(ConnectionPhase.portForwarding);
      // Reverse tunnel: device:7001 → host:7001, so the tablet can dial us.
      final forwarded = await _adb.reverseForward(
        serial: device.serial,
        localPort: _port,
        remotePort: _port,
      );
      if (!forwarded) throw Exception('Port forwarding failed');

      _setPhase(ConnectionPhase.handshaking);
      await _socket.startServer(_host, _port);
      _log.i('Host: waiting for tablet to connect…');
      await _socket.waitForClient();

      _startPacketLoop();

      _setPhase(ConnectionPhase.configuring);
      // Capture start is non-fatal: the connection still goes live so the link
      // is up; frames begin once Screen Recording permission is granted.
      try {
        await _startCapture();
      } catch (e, st) {
        _log.e('Host: screen capture not started (permission?)', e, st);
      }

      _setPhase(ConnectionPhase.streaming);
      _startHeartbeat();
      _log.i('Host: link live (streaming)');
    } catch (e, st) {
      _log.e('Host connection failed', e, st);
      errorMessage.value = e.toString();
      _setPhase(ConnectionPhase.error);
      _scheduleReconnect();
    }
  }

  Future<void> _startCapture() async {
    final preset = _settings.encodePreset;
    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: preset.width,
      height: preset.height,
      scaleFactor: preset.scaleFactor,
      refreshRate: _settings.fps,
      bitrate: preset.bitrate,
      mode: _settings.displayMode,
      codec: _settings.codec,
    );

    await _capture.requestPermission();
    await _input.requestAccessibility();

    if (config.mode == DisplayMode.extend) {
      await _capture.createVirtualDisplay(config);
    }
    await _capture.startCapture(config);

    // Fetch actual display bounds so touch injection lands on the right screen.
    _displayBounds = await _capture.getDisplayBounds();
    _log.i('Display bounds: $_displayBounds');

    // Tell client which codec we're using so it can initialize the right decoder.
    // 0xFC + 0x00 = H264, 0xFC + 0x01 = H265/HEVC.
    _socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFC, config.codec == CodecType.h265 ? 1 : 0]),
    ));

    // Forward each encoded NAL unit from native → socket as FRAME_DATA.
    _frameSub = _capture.frameStream.listen((nal) {
      _socket.send(Packet(
        type: PacketType.frameData,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: nal,
      ));
    });
  }

  /// Change display mode. If we are the client, send 0xFD packet so the host
  /// applies the change. If we are the host, apply directly.
  Future<void> changeMode(DisplayMode mode) async {
    _settings.setDisplayMode(mode);
    if (isHost) {
      await reapplyCapture();
    } else if (phase.value.isActive) {
      _socket.send(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: Uint8List.fromList([0xFD, mode == DisplayMode.mirror ? 1 : 0]),
      ));
    }
  }

  /// Host only: stop capture, destroy virtual display, restart with new mode.
  /// Call this after a settings change (mode / fps / bitrate) while streaming.
  Future<void> reapplyCapture() async {
    if (!isHost || !phase.value.isActive) return;
    _log.i('Reapplying capture settings (mode=${_settings.displayMode.name})');
    await _frameSub?.cancel();
    _frameSub = null;
    await _capture.stopCapture();
    await _capture.removeVirtualDisplay();
    forceKeyframe = true;
    try {
      await _startCapture();
      // Tell the tablet to request a fresh IDR so it sees the change instantly.
      _socket.send(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: Uint8List.fromList([0xFE]), // 0xFE = "reload"
      ));
    } catch (e, st) {
      _log.e('reapplyCapture failed', e, st);
    }
  }

  // Exposed so reapplyCapture can force a keyframe without going through the
  // Swift plugin call (the next encoded frame will naturally be an IDR once
  // ScreenCapturePlugin.forceKeyframe is set via requestIdr).
  bool get forceKeyframe => false; // read-only alias; actual flag lives in Swift
  set forceKeyframe(bool _) => _capture.requestIdr();

  // ─── CLIENT (Android) ───────────────────────────────────────────────────

  Future<void> _connectAsClient() async {
    try {
      _setPhase(ConnectionPhase.handshaking);
      // Connects through the adb-reverse tunnel set up by the host.
      await _socket.connect(_host, _port);

      _setPhase(ConnectionPhase.configuring);
      await _sendHandshake();

      _startPacketLoop();

      _setPhase(ConnectionPhase.streaming);
      _startHeartbeat();
      _log.i('Client: connected to host, streaming');
    } catch (e) {
      // Expected to fail until the host is up; retry quietly.
      _log.w('Client connect failed (${e.runtimeType}); retrying…');
      errorMessage.value = 'Waiting for Mac host…';
      _setPhase(ConnectionPhase.error);
      _scheduleReconnect();
    }
  }

  // ─── SHARED ─────────────────────────────────────────────────────────────

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _packetSub?.cancel();
    _frameSub?.cancel();
    if (isHost) {
      await _capture.stopCapture();
      await _capture.removeVirtualDisplay();
    }
    await _socket.disconnect();
    if (isHost && activeDevice.value != null) {
      await _adb.removeForward(serial: activeDevice.value!.serial);
    }
    activeDevice.value = null;
    _setPhase(ConnectionPhase.disconnected);
  }

  void sendTouch(TouchEventModel event) {
    if (!phase.value.isActive) return;
    _socket.send(PacketCodec.wrapTouch(event));
  }

  void sendMouse(MouseEventModel event) {
    if (!phase.value.isActive) return;
    _socket.send(PacketCodec.wrapMouse(event));
  }

  void sendKey(KeyEventModel event) {
    if (!phase.value.isActive) return;
    _socket.send(PacketCodec.wrapKey(event));
  }

  /// Client → host: ask for a fresh keyframe so the decoder can start cleanly.
  void requestIdr() {
    if (!phase.value.isActive) return;
    _socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFF]),
    ));
  }

  void _startPacketLoop() {
    _packetSub = _socket.packetStream.listen(
      _handlePacket,
      onError: (e) {
        _log.e('Packet stream error', e);
        _setPhase(ConnectionPhase.error);
        _scheduleReconnect();
      },
    );
  }

  void _handlePacket(Packet packet) {
    switch (packet.type) {
      case PacketType.heartbeat:
        if (PacketCodec.heartbeatIsPong(packet.payload)) {
          // Only accept the pong that echoes OUR own last ping timestamp.
          // Ignores pongs that echo the peer's own pings (different clock).
          final originTs = PacketCodec.heartbeatOriginTs(packet.payload);
          if (originTs == _lastPingTs && originTs > 0) {
            final rttUs = DateTime.now().microsecondsSinceEpoch - originTs;
            latencyMs.value = (rttUs / 1000).round();
          }
        } else {
          // Incoming ping from peer — echo it back immediately.
          final pong = PacketCodec.heartbeatPong(packet.payload);
          if (pong != null) _socket.send(pong);
        }
        break;

      // Host injects input received from the tablet.
      case PacketType.touchEvent when isHost:
        _injectTouch(packet);
        break;
      case PacketType.mouseEvent when isHost:
        _injectMouse(packet);
        break;
      case PacketType.keyEvent when isHost:
        _injectKey(packet);
        break;

      // 0xFF — Tablet → Host: request a fresh keyframe (IDR).
      case PacketType.control
          when isHost && packet.payload.isNotEmpty && packet.payload[0] == 0xFF:
        _capture.requestIdr();
        break;

      // 0xFE — Host → Tablet: capture restarted, request IDR to resume decode.
      case PacketType.control
          when !isHost && packet.payload.isNotEmpty && packet.payload[0] == 0xFE:
        requestIdr();
        break;

      // 0xFC + codec_byte — Host → Tablet: codec changed, reinitialize decoder.
      case PacketType.control
          when !isHost && packet.payload.length >= 2 && packet.payload[0] == 0xFC:
        final newCodec = packet.payload[1] == 1 ? CodecType.h265 : CodecType.h264;
        _settings.setCodec(newCodec);
        break;

      // 0xFD + mode_byte — Tablet → Host: change display mode (0=extend,1=mirror).
      case PacketType.control
          when isHost && packet.payload.length >= 2 && packet.payload[0] == 0xFD:
        final newMode = packet.payload[1] == 1
            ? DisplayMode.mirror
            : DisplayMode.extend;
        _settings.setDisplayMode(newMode);
        reapplyCapture();
        break;

      // FRAME_DATA on the client is consumed by DisplayController via
      // [packetStream]; nothing to do here.
      default:
        break;
    }
  }

  void _injectTouch(Packet packet) {
    // Map a single primary pointer to a mouse move/click on macOS.
    final t = PacketCodec.decodeTouch(packet.payload);
    if (t == null || t.pointers.isEmpty) return;
    final p = t.pointers.first;
    final action = switch (t.action) {
      TouchAction.down => MouseAction.down,
      TouchAction.up => MouseAction.up,
      TouchAction.move => MouseAction.move,
      TouchAction.cancel => MouseAction.up,
    };
    _input.injectMouse(
      MouseEventModel(
        normalizedX: p.normalizedX,
        normalizedY: p.normalizedY,
        button: MouseButton.left,
        action: action,
        timestampUs: t.timestampUs,
      ),
      _hostDisplayBounds,
    );
  }

  void _injectMouse(Packet packet) {
    final m = PacketCodec.decodeMouse(packet.payload);
    if (m != null) _input.injectMouse(m, _hostDisplayBounds);
  }

  void _injectKey(Packet packet) {
    final k = PacketCodec.decodeKey(packet.payload);
    if (k != null) _input.injectKey(k);
  }

  // Cached real bounds of the active display (virtual or main).
  Map<String, double> get _hostDisplayBounds => _displayBounds;

  Future<void> _sendHandshake() async {
    // HELLO: version byte + platform byte (0x02 = Android client).
    _socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0x01, 0x02]),
    ));
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      final hb = PacketCodec.heartbeat();
      _lastPingTs = PacketCodec.heartbeatOriginTs(hb.payload);
      _socket.send(hb);
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), connect);
  }

  void _setPhase(ConnectionPhase p) {
    _log.d('Connection phase → ${p.name}');
    phase.value = p;
  }
}
