import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// macOS only — bridges to ScreenCaptureKit + VideoToolbox via Swift plugin.
class ScreenCaptureChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/screen_capture');
  static const _frames = EventChannel('extended_screen/frames');
  final _log = Get.find<LoggerService>();

  /// Encoded H.264 NAL units streamed from the native VideoToolbox encoder.
  Stream<Uint8List> get frameStream => _frames
      .receiveBroadcastStream()
      .map((e) => e is Uint8List ? e : Uint8List.fromList(List<int>.from(e)));

  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (e, st) {
      _log.e('requestPermission failed', e, st);
      return false;
    }
  }

  Future<void> startCapture(DisplayConfigModel config) async {
    await _channel.invokeMethod('startCapture', config.toMap());
    _log.i('Screen capture started ${config.width}x${config.height}@${config.refreshRate}fps');
  }

  Future<void> stopCapture() async {
    try {
      await _channel.invokeMethod('stopCapture');
    } catch (_) {}
  }

  /// Forces the next encoded frame to be a keyframe (IDR).
  Future<void> requestIdr() async {
    try {
      await _channel.invokeMethod('requestIdr');
    } catch (_) {}
  }

  Future<void> createVirtualDisplay(DisplayConfigModel config) async {
    await _channel.invokeMethod('createVirtualDisplay', {
      'width': config.width,
      'height': config.height,
      'refreshRate': config.refreshRate,
      'scaleFactor': config.scaleFactor,
    });
  }

  Future<void> removeVirtualDisplay() async {
    try {
      await _channel.invokeMethod('removeVirtualDisplay');
    } catch (_) {}
  }

  /// Returns the actual screen-space bounds of the virtual display (extend mode)
  /// or the main display (mirror mode). Used to map tablet touch coords correctly.
  Future<Map<String, double>> getDisplayBounds() async {
    try {
      final r = await _channel.invokeMethod<Map>('getVirtualDisplayBounds');
      if (r != null) {
        return {
          'x': (r['x'] as num).toDouble(),
          'y': (r['y'] as num).toDouble(),
          'w': (r['w'] as num).toDouble(),
          'h': (r['h'] as num).toDouble(),
        };
      }
    } catch (e, st) {
      _log.e('getDisplayBounds failed', e, st);
    }
    // Zero size signals failure; the caller falls back to the config size.
    return {'x': 0, 'y': 0, 'w': 0, 'h': 0};
  }
}
