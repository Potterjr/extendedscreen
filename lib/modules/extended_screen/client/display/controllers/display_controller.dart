import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/controllers/touch_gesture_recognizer.dart';
import 'package:extendedscreen/modules/extended_screen/client/video_decoder_channel.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

class DisplayController extends GetxController with WidgetsBindingObserver {
  final _cm = Get.find<BaseConnectionManager>();
  final _settings = Get.find<SettingsService>();
  final _log = Get.find<LoggerService>();

  final frameCount = 0.obs;
  final currentFps = 0.obs;
  final droppedPerSec = 0.obs;

  StreamSubscription? _packetSub;
  Timer? _fpsTimer;
  int _fpsCounter = 0;

  // Refresh rate the display mode was last set for, and the watcher that
  // follows the host when it announces a different one (0xFB).
  int? _decoderFps;
  Worker? _refreshWorker;

  // Codec the current decoder was built with, and the watcher that rebuilds
  // it when the setting moves away from that. The host's codec (0xFC) is
  // stored in settings by ClientConnectionManager, its only handler.
  CodecType? _decoderCodec;
  Worker? _codecWorker;

  // Bumped by every decoder build. A build that finds it changed (or the
  // controller closed) after one of its awaits has been superseded and stops,
  // so overlapping builds can't leave the older codec running or subscribe a
  // second frame listener, and a late one can't revive the decoder after
  // onClose released it.
  int _decoderGen = 0;

  bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void onReady() {
    super.onReady();
    WidgetsBinding.instance.addObserver(this);
    _keepScreenOn();
    if (isAndroid) {
      _initDecoderAndSubscribe();
      // On a fresh connect this view opens before the host announces its
      // codec (0xFC), so the first build uses the codec persisted last time;
      // rebuild once the announced one differs. The native decoder never
      // switches codec on its own.
      _codecWorker = ever<CodecType>(_settings.codecRx, (c) {
        if (c != _decoderCodec) _initDecoderAndSubscribe();
      });
      // The host's rate (0xFB) can land after the display opens, and the Max
      // preset changes it mid-stream; the display mode must follow, or a
      // 120 Hz stream is shown on a 60 Hz screen and half its frames are
      // discarded. Only the mode changes — the decoder is provisioned for the
      // panel's top rate, and rebuilding it on every step hitched the display.
      _refreshWorker = ever<int>(_cm.refreshRateHz, (hz) {
        if (hz != _decoderFps) {
          _decoderFps = hz;
          Get.find<VideoDecoderChannel>().setRefreshRate(hz);
        }
      });
    }
    _startFpsCounter();
  }

  /// Keep the display awake and fullscreen while streaming. Re-asserted on
  /// resume because Android can drop the wake lock / UI mode when the app is
  /// backgrounded, which would let the screen dim or go black mid-stream.
  void _keepScreenOn() {
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _keepScreenOn();
    }
  }

  Future<void> _initDecoderAndSubscribe() async {
    final gen = ++_decoderGen;
    bool superseded() => isClosed || gen != _decoderGen;
    final decoder = Get.find<VideoDecoderChannel>();
    // Stop feeding the decoder being replaced; this build subscribes again
    // once its own decoder is ready.
    _packetSub?.cancel();
    _packetSub = null;
    // Size the decoder hint to this device's own panel (landscape-locked, so
    // the long side is the width); the channel doubles logical → physical.
    final panel =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: (panel.longestSide / 2).round(),
      height: (panel.shortestSide / 2).round(),
      // The host's announced rate, not this device's own (unused, host-only)
      // preset — that defaulted to 60 Hz regardless of what was streamed.
      refreshRate: _cm.refreshRateHz.value,
      bitrate: _settings.bitrate,
      codec: _settings.codec,
    );
    _decoderFps = config.refreshRate;
    _decoderCodec = config.codec;

    // Release any previous codec/surface before creating a new one so the old
    // SurfaceView is abandoned cleanly instead of flooding logcat. This is
    // also what lets a rebuild switch codec: the native decoder keeps its
    // first configuration until it is disposed.
    await decoder.dispose();
    // Checked before initialize: after onClose's dispose, an initialize would
    // start a decoder that keeps running after the view is gone.
    if (superseded()) return;

    decoder.onRequestIdr = _cm.requestIdr;

    await decoder.initialize(config);
    if (superseded()) return;
    // The codec worker starts a newer build when the setting changes, but
    // re-check here too so a change it missed can't leave this decoder on the
    // wrong codec.
    if (_settings.codec != _decoderCodec) {
      _initDecoderAndSubscribe();
      return;
    }
    // A 0xFB that landed during the awaits above was applied first and then
    // overwritten by this init's older rate — reapply the latest.
    final hz = _cm.refreshRateHz.value;
    if (hz != config.refreshRate) {
      _decoderFps = hz;
      await decoder.setRefreshRate(hz);
      if (superseded()) return;
    }
    _log.i('Decoder ready, subscribing to frame stream');

    _packetSub = _cm.packetStream.listen(
      (packet) {
        if (packet.type == PacketType.frameData) {
          decoder.feedNal(packet.payload);
          _fpsCounter++;
          frameCount.value++;
        }
      },
      onError: (_) {}, // BaseConnectionManager handles reconnect; ignore here.
    );
  }

  void _startFpsCounter() {
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      currentFps.value = _fpsCounter;
      _fpsCounter = 0;
      if (isAndroid) {
        droppedPerSec.value =
            await Get.find<VideoDecoderChannel>().fetchDropCount();
      }
    });
  }

  // ─── Touch → Android-style gestures ────────────────────────────────────────
  // Tap → click, one-finger swipe → natural scroll, long-press → drag. The
  // recognizer converts raw pointer events into mouse actions on the host.
  late final TouchGestureRecognizer _gestures = TouchGestureRecognizer(
    onClick: (nx, ny) {
      _sendMouse(MouseAction.down, nx, ny);
      _sendMouse(MouseAction.up, nx, ny);
    },
    onMoveCursor: (nx, ny) => _sendMouse(MouseAction.move, nx, ny),
    onScroll: (sdx, sdy) => _sendScroll(sdx, sdy),
    // Pinch-to-zoom → ⌘+scroll (0x01 = Command).
    onZoom: (dz) => _sendScroll(0, dz, modifiers: 0x01),
    onDragStart: (nx, ny) => _sendMouse(MouseAction.down, nx, ny),
    onDragMove: (nx, ny) => _sendMouse(MouseAction.move, nx, ny),
    onDragEnd: (nx, ny) => _sendMouse(MouseAction.up, nx, ny),
    onLongPressEngaged: () => HapticFeedback.selectionClick(),
  );

  void _sendMouse(MouseAction action, double nx, double ny) {
    _cm.sendMouse(MouseEventModel(
      normalizedX: nx,
      normalizedY: ny,
      button: MouseButton.left,
      action: action,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }

  void _sendScroll(double sdx, double sdy, {int modifiers = 0}) {
    _cm.sendMouse(MouseEventModel(
      normalizedX: 0,
      normalizedY: 0,
      button: MouseButton.none,
      action: MouseAction.scroll,
      scrollDx: sdx,
      scrollDy: sdy,
      modifiers: modifiers,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }

  void onPointerDown(int id, Offset pos, Size size) =>
      _gestures.down(id, pos, size);

  void onPointerMove(int id, Offset pos, Size size) =>
      _gestures.move(id, pos, size);

  void onPointerUp(int id, Offset pos, Size size) =>
      _gestures.up(id, pos, size);

  void onPointerCancel(int id) => _gestures.cancel(id);

  void onDisconnect() {
    _cm.disconnect();
    Get.back();
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _gestures.dispose();
    _refreshWorker?.dispose();
    _codecWorker?.dispose();
    _packetSub?.cancel();
    _fpsTimer?.cancel();
    if (isAndroid) {
      Get.find<VideoDecoderChannel>().dispose();
    }
    super.onClose();
  }
}
