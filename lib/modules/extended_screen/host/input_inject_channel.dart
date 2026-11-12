import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// macOS only — injects touch/mouse/key events via CGEvent (Quartz).
class InputInjectChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/input_inject');
  final _log = Get.find<LoggerService>();
  Worker? _keepCursorWorker;

  @override
  void onInit() {
    super.onInit();
    // The native side starts with the cursor return off and keeps its state
    // across a Dart hot restart; push the setting now and on every change, so
    // it applies at once, mid-session, without a reconnect.
    final keepMacCursor = Get.find<SettingsService>().keepMacCursor;
    setKeepCursor(keepMacCursor.value);
    _keepCursorWorker = ever<bool>(keepMacCursor, setKeepCursor);
  }

  @override
  void onClose() {
    _keepCursorWorker?.dispose();
    super.onClose();
  }

  Future<bool> requestAccessibility() async {
    try {
      return await _channel.invokeMethod<bool>('requestAccessibility') ?? false;
    } catch (e, st) {
      _log.e('Accessibility permission failed', e, st);
      return false;
    }
  }

  /// Native side keeps button state across calls: moves post as drags while a
  /// button is held, and repeated presses count as double clicks. It also maps
  /// the normalized point through the capture's content rect (bars in Mirror)
  /// before scaling it onto [displayBounds].
  Future<void> injectMouse(MouseEventModel e, Map<String, double> displayBounds) async {
    await _channel.invokeMethod('injectMouse', {
      'action': e.action.index,
      'button': e.button.index,
      'normalizedX': e.normalizedX,
      'normalizedY': e.normalizedY,
      'scrollDx': e.scrollDx,
      'scrollDy': e.scrollDy,
      'modifiers': e.modifiers,
      'displayX': displayBounds['x'],
      'displayY': displayBounds['y'],
      'displayW': displayBounds['w'],
      'displayH': displayBounds['h'],
    });
  }

  /// Turns the native cursor return on or off. On, each tablet gesture
  /// borrows the Mac's one cursor and puts it back where the user left it
  /// once the gesture goes quiet; off, the cursor stays where it was touched.
  Future<void> setKeepCursor(bool enabled) async {
    try {
      await _channel.invokeMethod('setKeepCursor', {'enabled': enabled});
    } catch (e, st) {
      _log.e('setKeepCursor failed', e, st);
    }
  }

  /// Releases a button the tablet pressed but never released (the link
  /// dropped mid-drag), which would otherwise turn every later move into a
  /// drag, hands back a borrowed cursor, and clears the native click and
  /// scroll state.
  Future<void> releaseAll() async {
    try {
      await _channel.invokeMethod('releaseAll');
    } catch (_) {}
  }

  Future<void> injectKey(KeyEventModel e) async {
    await _channel.invokeMethod('injectKey', {
      'keycode': e.keycode,
      'modifiers': e.modifiers,
      'isDown': e.isDown,
    });
  }
}
