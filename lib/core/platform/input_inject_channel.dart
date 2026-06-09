import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../models/touch_event_model.dart';
import '../services/logger_service.dart';

/// macOS only — injects touch/mouse/key events via CGEvent (Quartz).
class InputInjectChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/input_inject');
  final _log = Get.find<LoggerService>();

  Future<bool> requestAccessibility() async {
    try {
      return await _channel.invokeMethod<bool>('requestAccessibility') ?? false;
    } catch (e, st) {
      _log.e('Accessibility permission failed', e, st);
      return false;
    }
  }

  Future<void> injectMouse(MouseEventModel e, Map<String, double> displayBounds) async {
    await _channel.invokeMethod('injectMouse', {
      'action': e.action.index,
      'button': e.button.index,
      'normalizedX': e.normalizedX,
      'normalizedY': e.normalizedY,
      'scrollDx': e.scrollDx,
      'scrollDy': e.scrollDy,
      'displayX': displayBounds['x'],
      'displayY': displayBounds['y'],
      'displayW': displayBounds['w'],
      'displayH': displayBounds['h'],
    });
  }

  Future<void> injectKey(KeyEventModel e) async {
    await _channel.invokeMethod('injectKey', {
      'keycode': e.keycode,
      'modifiers': e.modifiers,
      'isDown': e.isDown,
    });
  }
}
