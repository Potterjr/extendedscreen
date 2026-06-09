import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../models/display_config_model.dart';
import '../services/logger_service.dart';

/// Android only — bridges to MediaCodec decoder via Kotlin plugin.
class VideoDecoderChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/video_decoder');
  final _log = Get.find<LoggerService>();

  /// Invoked when the native decoder needs a keyframe (post-configure / error).
  void Function()? onRequestIdr;

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRequestIdr':
          onRequestIdr?.call();
        case 'onCodecError':
          _log.w('Decoder codec error: ${call.arguments}');
      }
      return null;
    });
  }

  Future<void> initialize(DisplayConfigModel config) async {
    await _channel.invokeMethod('initialize', {
      'width': config.width * 2,   // physical pixels (HiDPI 2x)
      'height': config.height * 2,
      'codec': config.codec == CodecType.h265 ? 'h265' : 'h264',
      'fps': config.refreshRate,
    });
    _log.i('VideoDecoder initialized ${config.width * 2}x${config.height * 2} @${config.refreshRate}fps');
  }

  /// Feed a raw NAL unit to MediaCodec.
  Future<void> feedNal(List<int> nalBytes) async {
    final nal = nalBytes is Uint8List ? nalBytes : Uint8List.fromList(nalBytes);
    await _channel.invokeMethod('feedNal', {'nal': nal});
  }

  /// Request an IDR frame from macOS host (codec error recovery).
  Future<void> requestIdr() async {
    await _channel.invokeMethod('requestIdr');
  }

  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
  }
}
