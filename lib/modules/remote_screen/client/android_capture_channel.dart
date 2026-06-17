import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// Android only — the reverse of [ScreenCaptureChannel]: when the Mac is the
/// remote controller, the tablet captures its OWN screen via `MediaProjection`,
/// encodes it with `MediaCodec`, and streams the encoded NAL units back to the
/// host (which decodes them in [RemoteVideoChannel]).
///
/// `MediaProjection` needs a one-time system consent dialog; [requestProjection]
/// triggers it and resolves true once the user approves.
class AndroidCaptureChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/android_capture');
  static const _frames = EventChannel('extended_screen/android_frames');
  final _log = Get.find<LoggerService>();

  /// Encoded NAL units streamed from the native MediaCodec encoder.
  Stream<Uint8List> get frameStream => _frames
      .receiveBroadcastStream()
      .map((e) => e is Uint8List ? e : Uint8List.fromList(List<int>.from(e)));

  /// Show the MediaProjection consent dialog. Resolves true once granted.
  Future<bool> requestProjection() async {
    try {
      return await _channel.invokeMethod<bool>('requestProjection') ?? false;
    } catch (e, st) {
      _log.e('requestProjection failed', e, st);
      return false;
    }
  }

  Future<void> startCapture(DisplayConfigModel config) async {
    await _channel.invokeMethod('startCapture', {
      'width': config.width,
      'height': config.height,
      'codec': config.codec == CodecType.h265 ? 'h265' : 'h264',
      'fps': config.refreshRate,
      'bitrate': config.bitrate,
    });
    _log.i('Android capture started ${config.width}x${config.height}'
        '@${config.refreshRate}fps');
  }

  Future<void> stopCapture() async {
    try {
      await _channel.invokeMethod('stopCapture');
    } catch (_) {}
  }

  /// Force the next encoded frame to be a keyframe (IDR) — the Mac asks for this
  /// when its decoder needs to (re)start cleanly.
  Future<void> requestIdr() async {
    try {
      await _channel.invokeMethod('requestIdr');
    } catch (_) {}
  }
}
