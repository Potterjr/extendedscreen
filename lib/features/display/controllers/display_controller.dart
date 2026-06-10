import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/client/platform/video_decoder_channel.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

class DisplayController extends GetxController {
  final _cm = Get.find<BaseConnectionManager>();
  final _settings = Get.find<SettingsService>();
  final _log = Get.find<LoggerService>();

  final frameCount = 0.obs;
  final currentFps = 0.obs;
  final droppedPerSec = 0.obs;

  StreamSubscription? _packetSub;
  Timer? _fpsTimer;
  int _fpsCounter = 0;

  bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void onReady() {
    super.onReady();
    WakelockPlus.enable();
    // Show navigation bar while keeping fullscreen video content.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (isAndroid) {
      _initDecoderAndSubscribe();
    }
    _startFpsCounter();
  }

  Future<void> _initDecoderAndSubscribe() async {
    final decoder = Get.find<VideoDecoderChannel>();
    final config = DisplayConfigModel.defaultConfig.copyWith(
      refreshRate: _settings.refreshRate,
      bitrate: _settings.bitrate,
      codec: _settings.codec,
    );

    // Release any previous codec/surface before creating a new one so the old
    // SurfaceView is abandoned cleanly instead of flooding logcat.
    await decoder.dispose();

    decoder.onRequestIdr = _cm.requestIdr;

    await decoder.initialize(config);
    _log.i('Decoder ready, subscribing to frame stream');

    _packetSub = _cm.packetStream.listen(
      (packet) {
        if (packet.type == PacketType.frameData) {
          decoder.feedNal(packet.payload);
          _fpsCounter++;
          frameCount.value++;
        } else if (packet.type == PacketType.control &&
            packet.payload.length >= 2 &&
            packet.payload[0] == 0xFC) {
          // Host told us which codec it's using — reinitialize decoder.
          final newCodec = packet.payload[1] == 1 ? CodecType.h265 : CodecType.h264;
          if (newCodec != _settings.codec) {
            _settings.setCodec(newCodec);
            _packetSub?.cancel();
            _packetSub = null;
            _initDecoderAndSubscribe();
          }
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

  void onPointerDown(double nx, double ny, int id, double pressure) {
    _cm.sendTouch(TouchEventModel(
      pointers: [
        TouchPointerModel(
          pointerId: id,
          normalizedX: nx,
          normalizedY: ny,
          pressure: pressure,
          majorAxis: 1.0,
        )
      ],
      action: TouchAction.down,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      displayId: 0,
    ));
  }

  void onPointerMove(double nx, double ny, int id, double pressure) {
    _cm.sendTouch(TouchEventModel(
      pointers: [
        TouchPointerModel(
          pointerId: id,
          normalizedX: nx,
          normalizedY: ny,
          pressure: pressure,
          majorAxis: 1.0,
        )
      ],
      action: TouchAction.move,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      displayId: 0,
    ));
  }

  void onPointerUp(double nx, double ny, int id) {
    _cm.sendTouch(TouchEventModel(
      pointers: [
        TouchPointerModel(
          pointerId: id,
          normalizedX: nx,
          normalizedY: ny,
          pressure: 0,
          majorAxis: 1.0,
        )
      ],
      action: TouchAction.up,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      displayId: 0,
    ));
  }

  void onDisconnect() {
    _cm.disconnect();
    Get.back();
  }

  @override
  void onClose() {
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _packetSub?.cancel();
    _fpsTimer?.cancel();
    if (isAndroid) {
      Get.find<VideoDecoderChannel>().dispose();
    }
    super.onClose();
  }
}
