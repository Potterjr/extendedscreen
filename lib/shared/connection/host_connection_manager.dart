import 'dart:async';
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';

/// HOST role (macOS): runs `adb reverse`, a TCP server, captures + encodes the
/// screen via ScreenCaptureKit/VideoToolbox, and injects the touch/mouse/key
/// events received from the tablet. The Android client is the control surface,
/// so the host adopts the config carried in the client's HELLO before capture.
class HostConnectionManager extends BaseConnectionManager {
  final _adb = Get.find<AdbService>();
  ScreenCaptureChannel get _capture => Get.find<ScreenCaptureChannel>();
  InputInjectChannel get _input => Get.find<InputInjectChannel>();
  RemoteVideoChannel get _remote => Get.find<RemoteVideoChannel>();

  @override
  bool get isHost => true;

  /// Texture id of the decoded tablet stream (reverse remote: Mac controls the
  /// tablet). Null unless a reverse-remote session is live; the remote-view
  /// widget renders a `Texture` from it.
  final remoteTextureId = Rxn<int>();

  // Actual display bounds (updated after capture starts in extend/mirror mode).
  Map<String, double> _displayBounds = {'x': 0, 'y': 0, 'w': 0, 'h': 0};

  StreamSubscription? _frameSub;

  // Completed when the client's HELLO arrives (it carries the panel size the
  // capture resolution is derived from).
  Completer<void>? _helloReceived;

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
  void sendUiFlags() {
    if (!phase.value.isActive) return;
    // 0xFA + performanceOverlay(0/1) + showHud(0/1).
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xFA,
        settings.showPerformanceOverlay.value ? 1 : 0,
        settings.showHudOverlay.value ? 1 : 0,
      ]),
    ));
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
      if (device.model != null && device.model!.isNotEmpty) {
        await settings.setLastDeviceName(device.model!);
      }
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

      _helloReceived = Completer<void>();
      startPacketLoop();

      setPhase(ConnectionPhase.configuring);
      // Wait for the client's HELLO so the capture resolution matches its
      // panel; on timeout fall back to the last-known (persisted) panel.
      try {
        await _helloReceived!.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        log.w('Host: no HELLO from client — using last-known panel '
            '${settings.clientPanelWidth.value}×${settings.clientPanelHeight.value}');
      }

      // Start the media pipeline. Reverse-remote (Mac controls tablet) decodes
      // the tablet's stream; every other mode captures + encodes the Mac. Both
      // are non-fatal so the link stays up even if the pipeline can't start.
      try {
        if (settings.isReverseRemote) {
          await _startRemoteReceive();
        } else {
          await _startCapture();
        }
      } catch (e, st) {
        log.e('Host: media pipeline not started (permission?)', e, st);
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
    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: settings.captureWidth,
      height: settings.captureHeight,
      scaleFactor: settings.captureScaleFactor,
      refreshRate: settings.refreshRate,
      bitrate: settings.captureBitrate,
      // Remote-control sessions always mirror the real desktop; extended-screen
      // honours the user's Extend/Mirror choice.
      mode: settings.effectiveDisplayMode,
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
    if ((_displayBounds['w'] ?? 0) <= 0 || (_displayBounds['h'] ?? 0) <= 0) {
      // Bounds query failed — fall back to the logical size we configured.
      _displayBounds = {
        'x': 0,
        'y': 0,
        'w': config.width.toDouble(),
        'h': config.height.toDouble(),
      };
    }
    log.i('Display bounds: $_displayBounds');

    // Announce the active session mode + direction so the client knows its role.
    _sendSessionMode();

    // Tell client which codec we're using so it can initialize the right decoder.
    // 0xFC + 0x00 = H264, 0xFC + 0x01 = H265/HEVC.
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFC, config.codec == CodecType.h265 ? 1 : 0]),
    ));

    // Tell the client the capture refresh rate so its HUD shows the real value.
    // 0xFB + refreshRate (Hz, single byte).
    refreshRateHz.value = config.refreshRate;
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFB, config.refreshRate.clamp(0, 255)]),
    ));

    // Sync the overlay/HUD toggles so a fresh client matches the host.
    sendUiFlags();

    // Forward each encoded NAL unit from native → socket as FRAME_DATA.
    _frameSub = _capture.frameStream.listen((nal) {
      socket.send(Packet(
        type: PacketType.frameData,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: nal,
      ));
    });
  }

  /// Reverse remote (Mac controls tablet): the tablet captures + encodes its own
  /// screen, so the host decodes the incoming stream into a Flutter texture and
  /// injects input back via `adb shell input`. No ScreenCaptureKit here.
  Future<void> _startRemoteReceive() async {
    // Tell the client to switch into capture mode.
    _sendSessionMode();

    // Stand up the decoder + texture sized to the tablet's native panel.
    _remote.onRequestIdr = requestIdr; // base sends 0xFF → tablet re-IDRs
    final texId = await _remote.initialize(
      codec: settings.codec,
      width: settings.clientPanelWidth.value,
      height: settings.clientPanelHeight.value,
    );
    remoteTextureId.value = texId;
    refreshRateHz.value = settings.refreshRate;

    // Instruct the client to begin capturing + encoding.
    // 0xF8 + codec + fps + bitrate(Mbps).
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xF8,
        settings.codec == CodecType.h265 ? 1 : 0,
        settings.refreshRate.clamp(0, 255),
        (settings.captureBitrate ~/ 1000000).clamp(1, 255),
      ]),
    ));
    log.i('Host: reverse remote — decoding tablet stream (texture $texId)');
  }

  /// 0xF9 + sessionMode index + remoteDirection index.
  void _sendSessionMode() {
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xF9,
        settings.sessionMode.index,
        settings.remoteDirection.index,
      ]),
    ));
  }

  // ─── Reverse-remote input (Mac → tablet via adb) ──────────────────────────
  // The remote-view widget reports normalized coords; map them to the tablet's
  // device pixels and drive `adb shell input`.

  void sendRemoteTap(double nx, double ny) {
    final serial = activeDevice.value?.serial;
    if (serial == null) return;
    _adb.inputTap(
      serial: serial,
      x: (nx * settings.clientPanelWidth.value).round(),
      y: (ny * settings.clientPanelHeight.value).round(),
    );
  }

  void sendRemoteSwipe(double nx1, double ny1, double nx2, double ny2,
      {int durationMs = 50}) {
    final serial = activeDevice.value?.serial;
    if (serial == null) return;
    final w = settings.clientPanelWidth.value;
    final h = settings.clientPanelHeight.value;
    _adb.inputSwipe(
      serial: serial,
      x1: (nx1 * w).round(),
      y1: (ny1 * h).round(),
      x2: (nx2 * w).round(),
      y2: (ny2 * h).round(),
      durationMs: durationMs,
    );
  }

  @override
  Future<void> onTeardown() async {
    await _frameSub?.cancel();
    _frameSub = null;
    if (settings.isReverseRemote) {
      // Best-effort: tell the client to stop capturing before the socket drops.
      socket.send(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: Uint8List.fromList([0xF7]),
      ));
      await _remote.dispose();
      remoteTextureId.value = null;
    } else {
      await _capture.stopCapture();
      await _capture.removeVirtualDisplay();
    }
    if (activeDevice.value != null) {
      await _adb.removeForward(serial: activeDevice.value!.serial);
    }
  }

  @override
  void onRolePacket(Packet packet) {
    switch (packet.type) {
      // Reverse remote: encoded frames coming FROM the tablet → decode them.
      case PacketType.frameData when settings.isReverseRemote:
        _remote.feedNal(packet.payload);
        break;

      // HELLO from the client: version + platform + native panel size.
      case PacketType.control
          when packet.payload.isNotEmpty && packet.payload[0] == 0x01:
        _onHello(packet.payload);
        break;

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

      // 0xFF — Tablet → Host: request a fresh keyframe (IDR).
      case PacketType.control
          when packet.payload.isNotEmpty && packet.payload[0] == 0xFF:
        _capture.requestIdr();
        break;

      default:
        break;
    }
  }

  /// Parse the client HELLO: [version, platform, panelW hi, panelW lo,
  /// panelH hi, panelH lo]. Older clients send only the first two bytes —
  /// then the last-known panel is kept.
  void _onHello(Uint8List p) {
    if (p.length >= 6) {
      final w = (p[2] << 8) | p[3];
      final h = (p[4] << 8) | p[5];
      if (w >= 320 && h >= 240 && w <= 8192 && h <= 8192) {
        settings.setClientPanel(w, h);
        log.i('Host: client panel $w×$h');
      }
    }
    if (!(_helloReceived?.isCompleted ?? true)) _helloReceived!.complete();
  }

  // Without valid bounds, normalized coords can't be mapped to the screen.
  bool get _hasBounds => (_displayBounds['w'] ?? 0) > 0;

  void _injectTouch(Packet packet) {
    if (!_hasBounds) return;
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
    if (!_hasBounds) return;
    final m = PacketCodec.decodeMouse(packet.payload);
    if (m != null) _input.injectMouse(m, _displayBounds);
  }

  void _injectKey(Packet packet) {
    final k = PacketCodec.decodeKey(packet.payload);
    if (k != null) _input.injectKey(k);
  }
}
