import 'dart:async';
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/host/platform/screen_capture_channel.dart';
import 'package:extendedscreen/host/platform/input_inject_channel.dart';
import 'package:extendedscreen/host/connection/adb_service.dart';

/// HOST role (macOS): runs `adb reverse`, a TCP server, captures + encodes the
/// screen via ScreenCaptureKit/VideoToolbox, and injects the touch/mouse/key
/// events received from the tablet. The Android client is the control surface,
/// so the host adopts the config carried in the client's HELLO before capture.
class HostConnectionManager extends BaseConnectionManager {
  final _adb = Get.find<AdbService>();
  ScreenCaptureChannel get _capture => Get.find<ScreenCaptureChannel>();
  InputInjectChannel get _input => Get.find<InputInjectChannel>();

  @override
  bool get isHost => true;

  // Actual display bounds (updated after capture starts in extend/mirror mode).
  Map<String, double> _displayBounds = {'x': 0, 'y': 0, 'w': 2960, 'h': 1848};

  StreamSubscription? _frameSub;
  Completer<void>? _helloCompleter; // completes when the client HELLO arrives

  /// The host never connects automatically — it only loads the device list; the
  /// user must pick a client from the picker to connect.
  @override
  Future<void> autoConnect() async {
    await refreshDevices();
  }

  @override
  Future<void> refreshDevices() async {
    availableDevices.value = await _adb.listDevices();
  }

  @override
  Future<void> connect({String? serial}) async {
    if (phase.value.isConnecting || phase.value.isActive) return;
    try {
      setPhase(ConnectionPhase.detectingDevice);
      final devices = await _adb.listDevices();
      availableDevices.value = devices;
      if (devices.isEmpty) throw Exception('No ADB device detected');

      // Pick the explicitly requested device, else the last-used one, else first.
      final preferred = serial ?? settings.lastDeviceSerial;
      final device = preferred != null
          ? (devices.firstWhereOrNull((d) => d.serial == preferred) ??
              devices.first)
          : devices.first;
      activeDevice.value = device;
      await settings.setLastDevice(device.serial);
      log.i('Host: using device ${device.serial}');

      setPhase(ConnectionPhase.portForwarding);
      // Reverse tunnel: device:7001 → host:7001, so the tablet can dial us.
      final forwarded = await _adb.reverseForward(
        serial: device.serial,
        localPort: BaseConnectionManager.port,
        remotePort: BaseConnectionManager.port,
      );
      if (!forwarded) throw Exception('Port forwarding failed');

      setPhase(ConnectionPhase.handshaking);
      await socket.startServer(
          BaseConnectionManager.host, BaseConnectionManager.port);
      log.i('Host: waiting for tablet to connect…');
      await socket.waitForClient();

      _helloCompleter = Completer<void>();
      startPacketLoop();

      // Android is the sole control surface: wait for the client's HELLO so its
      // chosen mode/preset/codec are applied before capture starts. Fall back
      // to the host's own settings if it doesn't arrive promptly.
      try {
        await _helloCompleter!.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        log.w('Host: no client HELLO; using local settings');
      }

      setPhase(ConnectionPhase.configuring);
      // Capture start is non-fatal: the connection still goes live so the link
      // is up; frames begin once Screen Recording permission is granted.
      try {
        await _startCapture();
      } catch (e, st) {
        log.e('Host: screen capture not started (permission?)', e, st);
      }

      setPhase(ConnectionPhase.streaming);
      startHeartbeat();
      log.i('Host: link live (streaming)');
    } catch (e, st) {
      log.e('Host connection failed', e, st);
      errorMessage.value = e.toString();
      setPhase(ConnectionPhase.error);
      scheduleReconnect();
    }
  }

  Future<void> _startCapture() async {
    final preset = settings.encodePreset;
    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: preset.width,
      height: preset.height,
      scaleFactor: preset.scaleFactor,
      refreshRate: preset.refreshRate,
      bitrate: preset.bitrate,
      mode: settings.displayMode,
      codec: settings.codec,
    );

    await _capture.requestPermission();
    await _input.requestAccessibility();

    if (config.mode == DisplayMode.extend) {
      await _capture.createVirtualDisplay(config);
    }
    await _capture.startCapture(config);

    // Fetch actual display bounds so touch injection lands on the right screen.
    _displayBounds = await _capture.getDisplayBounds();
    log.i('Display bounds: $_displayBounds');

    // Tell client which codec we're using so it can initialize the right decoder.
    // 0xFC + 0x00 = H264, 0xFC + 0x01 = H265/HEVC.
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFC, config.codec == CodecType.h265 ? 1 : 0]),
    ));

    // Forward each encoded NAL unit from native → socket as FRAME_DATA.
    _frameSub = _capture.frameStream.listen((nal) {
      socket.send(Packet(
        type: PacketType.frameData,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: nal,
      ));
    });
  }

  @override
  Future<void> changeMode(DisplayMode mode) async {
    settings.setDisplayMode(mode);
    await reapplyCapture();
  }

  /// Stop capture, destroy virtual display, restart with the new mode. Call this
  /// after a display-mode change while streaming.
  Future<void> reapplyCapture() async {
    if (!phase.value.isActive) return;
    log.i('Reapplying capture settings (mode=${settings.displayMode.name})');
    await _frameSub?.cancel();
    _frameSub = null;
    await _capture.stopCapture();
    await _capture.removeVirtualDisplay();
    forceKeyframe = true;
    try {
      await _startCapture();
      // Tell the tablet to request a fresh IDR so it sees the change instantly.
      socket.send(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: Uint8List.fromList([0xFE]), // 0xFE = "reload"
      ));
    } catch (e, st) {
      log.e('reapplyCapture failed', e, st);
    }
  }

  // Exposed so reapplyCapture can force a keyframe without going through the
  // Swift plugin call (the next encoded frame will naturally be an IDR once
  // ScreenCapturePlugin.forceKeyframe is set via requestIdr).
  bool get forceKeyframe => false; // read-only alias; actual flag lives in Swift
  set forceKeyframe(bool _) => _capture.requestIdr();

  @override
  Future<void> onTeardown() async {
    await _frameSub?.cancel();
    _frameSub = null;
    await _capture.stopCapture();
    await _capture.removeVirtualDisplay();
    if (activeDevice.value != null) {
      await _adb.removeForward(serial: activeDevice.value!.serial);
    }
  }

  @override
  void onRolePacket(Packet packet) {
    switch (packet.type) {
      // Host injects input received from the tablet.
      case PacketType.touchEvent:
        _injectTouch(packet);
        break;
      case PacketType.mouseEvent:
        _injectMouse(packet);
        break;
      case PacketType.keyEvent:
        _injectKey(packet);
        break;

      // 0x01 — Tablet → Host: HELLO with the client's desired config.
      case PacketType.control
          when packet.payload.length >= 5 && packet.payload[0] == 0x01:
        _applyClientConfig(packet.payload);
        if (_helloCompleter?.isCompleted == false) {
          _helloCompleter!.complete();
        }
        break;

      // 0xFF — Tablet → Host: request a fresh keyframe (IDR).
      case PacketType.control
          when packet.payload.isNotEmpty && packet.payload[0] == 0xFF:
        _capture.requestIdr();
        break;

      // 0xFD + mode_byte — Tablet → Host: change display mode (0=extend,1=mirror).
      case PacketType.control
          when packet.payload.length >= 2 && packet.payload[0] == 0xFD:
        final newMode =
            packet.payload[1] == 1 ? DisplayMode.mirror : DisplayMode.extend;
        settings.setDisplayMode(newMode);
        reapplyCapture();
        break;

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
      _displayBounds,
    );
  }

  void _injectMouse(Packet packet) {
    final m = PacketCodec.decodeMouse(packet.payload);
    if (m != null) _input.injectMouse(m, _displayBounds);
  }

  void _injectKey(Packet packet) {
    final k = PacketCodec.decodeKey(packet.payload);
    if (k != null) _input.injectKey(k);
  }

  /// Adopt the client's config from its HELLO payload. Android is the only
  /// place these are edited, so the host mirrors them before capturing.
  void _applyClientConfig(Uint8List p) {
    final mode = p[2] == 1 ? DisplayMode.mirror : DisplayMode.extend;
    final preset =
        EncodePreset.values[p[3].clamp(0, EncodePreset.values.length - 1)];
    final codec = p[4] == 1 ? CodecType.h265 : CodecType.h264;
    settings.setDisplayMode(mode);
    settings.setEncodePreset(preset);
    settings.setCodec(codec);
    log.i('Host adopted client config: '
        'mode=${mode.name} preset=${preset.name} codec=${codec.name}');
  }
}
