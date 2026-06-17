import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';

/// CLIENT role (Android): dials into the adb-reverse tunnel, sends its desired
/// config in the HELLO, then decodes + renders frames (in DisplayController)
/// and forwards touch/keyboard input back to the host. The Android side is the
/// control surface, so settings changes here drive the host via [reconnect].
class ClientConnectionManager extends BaseConnectionManager {
  @override
  bool get isHost => false;

  AndroidCaptureChannel get _capture => Get.find<AndroidCaptureChannel>();
  StreamSubscription? _captureFrameSub;

  // Capture params from the host's 0xF8, applied when the user taps "Start
  // screen sharing" (MediaProjection consent must be user-initiated from the
  // foreground, so we don't auto-prompt).
  CodecType? _pendingCodec;
  int _pendingFps = 60;
  int _pendingBitrateMbps = 12;

  /// The client always dials in (and retries until the host server is up).
  @override
  Future<void> autoConnect() async {
    await connect();
  }

  @override
  Future<void> connect({String? serial}) async {
    if (phase.value.isConnecting || phase.value.isActive) return;
    try {
      setPhase(ConnectionPhase.handshaking);
      // Connects through the adb-reverse tunnel set up by the host.
      await socket.connect(BaseConnectionManager.host, BaseConnectionManager.port);

      setPhase(ConnectionPhase.configuring);
      _sendHandshake();

      startPacketLoop();

      setPhase(ConnectionPhase.streaming);
      startHeartbeat();
      log.i('Client: connected to host, streaming');
    } catch (e) {
      // Expected to fail until the host is up; retry quietly.
      log.w('Client connect failed (${e.runtimeType}); retrying…');
      errorMessage.value = 'Waiting for Mac host…';
      setPhase(ConnectionPhase.error);
      scheduleReconnect();
    }
  }

  void _sendHandshake() {
    // HELLO: version byte + platform byte (0x02 = Android client) + native
    // panel size (uint16 BE width, uint16 BE height, physical px, landscape).
    // The host derives its capture/virtual-display resolution from this, so
    // any connected device gets a pixel-matched stream.
    final panel = _nativePanelSize();
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0x01,
        0x02,
        (panel.w >> 8) & 0xFF, panel.w & 0xFF,
        (panel.h >> 8) & 0xFF, panel.h & 0xFF,
      ]),
    ));
  }

  /// Physical screen size in landscape orientation (the client is landscape-
  /// locked, but normalize anyway in case this runs before rotation applies).
  ({int w, int h}) _nativePanelSize() {
    final size = PlatformDispatcher.instance.views.first.physicalSize;
    final long = size.longestSide.round();
    final short = size.shortestSide.round();
    return (w: long, h: short);
  }

  // ─── Reverse remote (Mac controls tablet): capture this device's screen ────

  /// User tapped "Start screen sharing" — apply the params the host sent.
  @override
  Future<void> startScreenShare() async {
    final codec = _pendingCodec;
    if (codec == null) return;
    await _startReverseCapture(
      codec: codec,
      fps: _pendingFps,
      bitrateMbps: _pendingBitrateMbps,
    );
  }

  Future<void> _startReverseCapture({
    required CodecType codec,
    required int fps,
    required int bitrateMbps,
  }) async {
    if (_captureFrameSub != null) return; // already capturing
    final granted = await _capture.requestProjection();
    if (!granted) {
      log.w('Client: screen-capture consent denied');
      return;
    }
    needsScreenShare.value = false;
    isScreenSharing.value = true;
    final panel = _nativePanelSize();
    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: panel.w,
      height: panel.h,
      refreshRate: fps,
      bitrate: bitrateMbps * 1000000,
      codec: codec,
    );
    await _capture.startCapture(config);
    _captureFrameSub = _capture.frameStream.listen((nal) {
      socket.send(Packet(
        type: PacketType.frameData,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: nal,
      ));
    });
    log.i('Client: reverse capture streaming to Mac');
  }

  Future<void> _stopReverseCapture() async {
    await _captureFrameSub?.cancel();
    _captureFrameSub = null;
    await _capture.stopCapture();
    isScreenSharing.value = false;
  }

  @override
  Future<void> onTeardown() async {
    await _stopReverseCapture();
    needsScreenShare.value = false;
    _pendingCodec = null;
  }

  @override
  void onRolePacket(Packet packet) {
    if (packet.type != PacketType.control || packet.payload.isEmpty) return;
    final p = packet.payload;

    // 0xFE — Host → Tablet: capture restarted, request IDR to resume decode.
    if (p[0] == 0xFE) {
      requestIdr();
      return;
    }

    // 0xF9 + mode + direction — Host → Tablet: active session mode. In the
    // Mac-controls-tablet direction the tablet becomes the capture source.
    if (p.length >= 2 && p[0] == 0xF9) {
      final mode = p[1] < SessionMode.values.length
          ? SessionMode.values[p[1]]
          : SessionMode.extendedScreen;
      settings.setSessionMode(mode);
      if (p.length >= 3 && p[2] < RemoteDirection.values.length) {
        settings.setRemoteDirection(RemoteDirection.values[p[2]]);
      }
      return;
    }

    // 0xF8 + codec + fps + bitrate(Mbps) — Host → Tablet: the Mac wants to view
    // this screen. Stash the params and surface the "Start screen sharing"
    // button; the user starts it so the consent prompt fires in the foreground.
    if (p.length >= 4 && p[0] == 0xF8) {
      _pendingCodec = p[1] == 1 ? CodecType.h265 : CodecType.h264;
      _pendingFps = p[2];
      _pendingBitrateMbps = p[3];
      if (!isScreenSharing.value) needsScreenShare.value = true;
      return;
    }

    // 0xF7 — Host → Tablet: stop capturing (remote session ending).
    if (p[0] == 0xF7) {
      _stopReverseCapture();
      needsScreenShare.value = false;
      _pendingCodec = null;
      return;
    }

    // 0xFF — Host → Tablet: request a fresh keyframe from our encoder.
    if (p[0] == 0xFF) {
      _capture.requestIdr();
      return;
    }

    // 0xFC + codec_byte — Host → Tablet: codec changed, reinitialize decoder.
    if (p.length >= 2 && p[0] == 0xFC) {
      settings.setCodec(p[1] == 1 ? CodecType.h265 : CodecType.h264);
      return;
    }

    // 0xFB + refreshRate — Host → Tablet: capture refresh rate (Hz) for the HUD.
    if (p.length >= 2 && p[0] == 0xFB) {
      refreshRateHz.value = p[1];
      return;
    }

    // 0xFA + perfOverlay + showHud — Host → Tablet: sync overlay toggles which
    // render on the client but are edited on the host.
    if (p.length >= 3 && p[0] == 0xFA) {
      settings.setShowPerformanceOverlay(p[1] == 1);
      settings.setShowHudOverlay(p[2] == 1);
    }
  }
}
