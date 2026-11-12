import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class _QuietLogger extends LoggerService {
  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) {}
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('extended_screen/input_inject');
  late List<MethodCall> calls;

  setUp(() {
    Get.reset();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    Get.put<LoggerService>(_QuietLogger());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    Get.reset();
  });

  Future<SettingsService> loadSettings() async {
    final s = SettingsService();
    await s.init();
    return s;
  }

  List<Object?> keepCursorPushes() => calls
      .where((c) => c.method == 'setKeepCursor')
      .map((c) => (c.arguments as Map)['enabled'])
      .toList();

  group('SettingsService.keepMacCursor', () {
    test('is on when nothing is saved', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await loadSettings()).keepMacCursor.value, isTrue);
    });

    test('a saved choice survives a relaunch', () async {
      SharedPreferences.setMockInitialValues({});
      await (await loadSettings()).setKeepMacCursor(false);
      // A fresh service reads it back from the same store.
      expect((await loadSettings()).keepMacCursor.value, isFalse);
    });
  });

  group('InputInjectChannel', () {
    test('pushes the saved setting to the native side when created', () async {
      SharedPreferences.setMockInitialValues({'flutter.keep_mac_cursor': false});
      Get.put(await loadSettings());
      Get.put(InputInjectChannel());
      await pumpEventQueue();
      expect(keepCursorPushes(), [false]);
    });

    test('pushes every change at once, without a reconnect', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Get.put(await loadSettings());
      Get.put(InputInjectChannel());
      await pumpEventQueue();

      await settings.setKeepMacCursor(false);
      await pumpEventQueue();
      await settings.setKeepMacCursor(true);
      await pumpEventQueue();

      expect(keepCursorPushes(), [true, false, true]);
    });
  });
}
