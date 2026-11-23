import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// What `AdbService` asks the adb plugin for when the Mac taps or swipes on
/// a tablet it controls: the tablet's input shell (`inputShell`, numbers
/// only), the old one-process-per-event call (`shellInput`) only when the
/// plugin cannot take it, and `closeInputShell` when the session is over.
/// The plugin itself (the shell, its queue, its watchdog) is Swift and is
/// not run here.

class _Logger extends LoggerService {
  final warnings = <String>[];

  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) => warnings.add(msg);
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('extended_screen/adb');

  late _Logger log;
  late AdbService adb;
  late List<MethodCall> calls;

  /// What the plugin does with a call (after it is kept in [calls]); null:
  /// it answers nil, as the plugin does for every call here.
  Future<Object?> Function(MethodCall call)? plugin;

  setUp(() {
    log = Get.put<LoggerService>(_Logger()) as _Logger;
    adb = AdbService();
    calls = [];
    plugin = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return plugin?.call(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    Get.reset();
  });

  List<String> methods() => [for (final c in calls) c.method];

  test("a tap goes to the tablet's input shell as numbers", () async {
    await adb.inputTap(serial: 'X', x: 10, y: 20);

    expect(methods(), ['inputShell']);
    expect(calls.single.arguments, {
      'serial': 'X',
      'command': 'tap',
      'values': [10, 20],
    });
    expect(log.warnings, isEmpty);
  });

  test('a swipe goes there with its two points and its duration, 50 ms '
      'unless said otherwise', () async {
    await adb.inputSwipe(serial: 'X', x1: 1, y1: 2, x2: 3, y2: 4);
    await adb.inputSwipe(
        serial: 'Y', x1: 5, y1: 6, x2: 7, y2: 8, durationMs: 300);

    expect(methods(), ['inputShell', 'inputShell']);
    expect(calls[0].arguments, {
      'serial': 'X',
      'command': 'swipe',
      'values': [1, 2, 3, 4, 50],
    });
    expect(calls[1].arguments, {
      'serial': 'Y',
      'command': 'swipe',
      'values': [5, 6, 7, 8, 300],
    });
  });

  test('a plugin with no input shell gets the event the old way, as one '
      '`adb shell input`', () async {
    plugin = (call) async {
      if (call.method == 'inputShell') throw MissingPluginException();
      return null;
    };

    await adb.inputTap(serial: 'X', x: 10, y: 20);
    expect(methods(), ['inputShell', 'shellInput']);
    expect(calls.last.arguments, {
      'serial': 'X',
      'args': ['tap', '10', '20'],
    });

    calls.clear();
    await adb.inputSwipe(
        serial: 'X', x1: 1, y1: 2, x2: 3, y2: 4, durationMs: 80);
    expect(methods(), ['inputShell', 'shellInput']);
    expect(calls.last.arguments, {
      'serial': 'X',
      'args': ['swipe', '1', '2', '3', '4', '80'],
    });
  });

  test('so does an event adb could not take', () async {
    plugin = (call) async {
      if (call.method == 'inputShell') {
        throw PlatformException(code: 'ADB_FAILED', message: 'adb not found');
      }
      return null;
    };

    await adb.inputTap(serial: 'X', x: 10, y: 20);

    expect(methods(), ['inputShell', 'shellInput']);
    expect(calls.last.arguments, {
      'serial': 'X',
      'args': ['tap', '10', '20'],
    });
  });

  test('values the plugin refuses are dropped, not sent the old way',
      () async {
    plugin = (call) async {
      if (call.method == 'inputShell') {
        throw PlatformException(code: 'BAD_ARGS');
      }
      return null;
    };

    await adb.inputTap(serial: 'X', x: -5, y: 70000);
    await adb.inputSwipe(
        serial: 'X', x1: 1, y1: 2, x2: 3, y2: 4, durationMs: 5000);

    expect(methods(), ['inputShell', 'inputShell']);
    expect(log.warnings, hasLength(2));
    expect(log.warnings, everyElement(contains('BAD_ARGS')));
  });

  test('no other error sends an event the old way either', () async {
    plugin = (call) async {
      if (call.method == 'inputShell') {
        throw PlatformException(code: 'SOMETHING_ELSE');
      }
      return null;
    };

    await adb.inputTap(serial: 'X', x: 10, y: 20);

    expect(methods(), ['inputShell']);
  });

  test('closing a shell names its tablet, and the next tap asks for the '
      'shell again', () async {
    await adb.inputTap(serial: 'X', x: 1, y: 2);
    await adb.closeInputShell(serial: 'X');
    await adb.inputTap(serial: 'X', x: 3, y: 4);

    expect(methods(), ['inputShell', 'closeInputShell', 'inputShell']);
    expect(calls[1].arguments, {'serial': 'X'});
    expect(calls[2].arguments, {
      'serial': 'X',
      'command': 'tap',
      'values': [3, 4],
    });
    expect(log.warnings, isEmpty);
  });

  test('ten taps 50 ms apart all reach the shell, in order', () async {
    // The plugin takes its time over the first ones: nothing here waits for
    // an answer before the next tap is handed over.
    plugin = (call) async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return null;
    };

    final sent = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      sent.add(adb.inputTap(serial: 'X', x: i, y: 100 + i));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future.wait(sent);

    expect(methods(), List.filled(10, 'inputShell'));
    expect([
      for (final c in calls) (c.arguments as Map)['values']
    ], [
      for (var i = 0; i < 10; i++) [i, 100 + i]
    ]);
  });

  test('a channel that fails throws nothing at the caller: not from a tap, '
      'not from the fallback, not from a close', () async {
    plugin = (call) async => throw StateError('the plugin is gone');
    await adb.inputTap(serial: 'X', x: 1, y: 2);
    await adb.inputSwipe(serial: 'X', x1: 1, y1: 2, x2: 3, y2: 4);
    await adb.closeInputShell(serial: 'X');
    expect(methods(), ['inputShell', 'inputShell', 'closeInputShell']);

    // The shell cannot take it, and the old way fails too.
    calls.clear();
    plugin = (call) async => throw PlatformException(code: 'ADB_FAILED');
    await adb.inputTap(serial: 'X', x: 1, y: 2);
    await adb.closeInputShell(serial: 'X');
    expect(methods(), ['inputShell', 'shellInput', 'closeInputShell']);

    // No plugin at all.
    calls.clear();
    messenger.setMockMethodCallHandler(channel, null);
    await adb.inputTap(serial: 'X', x: 1, y: 2);
    await adb.closeInputShell(serial: 'X');
    expect(calls, isEmpty);
  });

  test('key events and text still take one `adb shell input` each', () async {
    await adb.inputKeyevent(serial: 'X', keycode: 4);
    await adb.inputText(serial: 'X', text: 'a b');

    expect(methods(), ['shellInput', 'shellInput']);
    expect(calls[0].arguments, {
      'serial': 'X',
      'args': ['keyevent', '4'],
    });
    expect(calls[1].arguments, {
      'serial': 'X',
      'args': ['text', 'a%sb'],
    });
  });
}
