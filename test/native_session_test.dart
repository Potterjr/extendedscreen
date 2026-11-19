import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// What the native capture, input and decode plugins are told, and what they
/// send back, now that every call names its session (one per tablet).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const capture = MethodChannel('extended_screen/screen_capture');
  const frames = EventChannel('extended_screen/frames');
  const input = MethodChannel('extended_screen/input_inject');
  const remote = MethodChannel('extended_screen/remote_video');
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;

  /// A frame as the Swift plugin sends it: its session's id, then the bytes.
  Uint8List tagged(int session, List<int> bytes) {
    final out = Uint8List(4 + bytes.length);
    ByteData.sublistView(out).setUint32(0, session);
    out.setRange(4, out.length, bytes);
    return out;
  }

  /// Delivers a native → Dart method call on [channel].
  Future<void> fromNative(String channel, String method, Object? args) async {
    await messenger.handlePlatformMessage(
        channel, codec.encodeMethodCall(MethodCall(method, args)), (_) {});
  }

  setUp(() async {
    calls = [];
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    final settings = SettingsService();
    await settings.init();
    Get.put(settings);
    for (final ch in [capture, input, remote]) {
      messenger.setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return switch (call.method) {
          'createVirtualDisplay' => {'applied': true, 'displayID': 0},
          'initialize' => 7,
          'startCapture' => {'displayID': 3, 'hardware': true, 'fellBack': false},
          _ => null,
        };
      });
    }
  });

  tearDown(() {
    for (final ch in [capture, input, remote]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    messenger.setMockStreamHandler(frames, null);
    Get.reset();
  });

  test('each session gets only its own frames, without the id in front',
      () async {
    late MockStreamHandlerEventSink sink;
    messenger.setMockStreamHandler(
        frames,
        MockStreamHandler.inline(
            onListen: (_, events) => sink = events));
    final channel = ScreenCaptureChannel();
    final one = <List<int>>[], two = <List<int>>[];
    final a = channel.framesFor(1).listen(one.add);
    final b = channel.framesFor(2).listen(two.add);
    await pumpEventQueue();

    sink.success(tagged(1, [0, 0, 0, 1, 0x65]));
    sink.success(tagged(2, [0, 0, 0, 1, 0x41]));
    sink.success(tagged(9, [0, 0, 0, 1, 0x67]));
    sink.success(Uint8List.fromList([0, 0, 1])); // too short to name anyone
    await pumpEventQueue();

    expect(one, [
      [0, 0, 0, 1, 0x65]
    ]);
    expect(two, [
      [0, 0, 0, 1, 0x41]
    ]);
    await a.cancel();
    await b.cancel();
  });

  test('the frame stream is listened to once, for good: listeners come and '
      'go, and a disposed session gets nothing more', () async {
    late MockStreamHandlerEventSink sink;
    var listens = 0, cancels = 0;
    messenger.setMockStreamHandler(
        frames,
        MockStreamHandler.inline(onListen: (_, events) {
          listens++;
          sink = events;
        }, onCancel: (_) => cancels++));
    final channel = ScreenCaptureChannel();
    final one = <List<int>>[], two = <List<int>>[];
    final first = channel.framesFor(1).listen(one.add);
    await pumpEventQueue();
    sink.success(tagged(1, [0x65]));
    await pumpEventQueue();
    // The session's encoder is rebuilt: its listener goes, and in between
    // another session starts listening.
    await first.cancel();
    final other = channel.framesFor(2).listen(two.add);
    await pumpEventQueue();
    sink.success(tagged(2, [0x41]));
    final again = channel.framesFor(1).listen(one.add);
    sink.success(tagged(1, [0x67, 0x65]));
    await pumpEventQueue();

    expect(listens, 1);
    expect(cancels, 0);
    expect(one, [
      [0x65],
      [0x67, 0x65]
    ]);
    expect(two, [
      [0x41]
    ]);

    var closed = false;
    channel.framesFor(2).listen(two.add, onDone: () => closed = true);
    await channel.disposeSession(session: 2);
    sink.success(tagged(2, [0x42]));
    await pumpEventQueue();
    expect(closed, isTrue);
    expect(two, hasLength(1), reason: 'a disposed session is dropped');
    await other.cancel();
    await again.cancel();
  });

  test('every capture call names its session, and the mode goes along',
      () async {
    final channel = ScreenCaptureChannel();
    final config =
        DisplayConfigModel.defaultConfig.copyWith(mode: DisplayMode.mirror);
    await channel.startCapture(config, session: 4);
    await channel.requestIdr(session: 4);
    await channel.setBitrate(8000000, session: 4);
    await channel.stopCapture(session: 4);
    await channel.removeVirtualDisplay(session: 4);
    await channel.getDisplayBounds(session: 4);

    expect(calls.map((c) => c.method), [
      'startCapture',
      'requestIdr',
      'setBitrate',
      'stopCapture',
      'removeVirtualDisplay',
      'getVirtualDisplayBounds',
    ]);
    for (final c in calls) {
      expect((c.arguments as Map)['session'], 4, reason: c.method);
    }
    expect((calls.first.arguments as Map)['mode'], DisplayMode.mirror.index);
  });

  test('a virtual display with no id counts as not made', () async {
    final channel = ScreenCaptureChannel();
    final made = await channel.createVirtualDisplay(
        DisplayConfigModel.defaultConfig,
        session: 2, serialNum: 0x10002, name: 'Extended Screen – Tab');
    expect(made.ok, isFalse);
    expect(made.applied, isTrue);
    expect(made.displayId, 0);
    final args = calls.single.arguments as Map;
    expect(args['session'], 2);
    expect(args['serialNum'], 0x10002);
    expect(args['name'], 'Extended Screen – Tab');
  });

  test('a made virtual display, and a start, say what they got', () async {
    messenger.setMockMethodCallHandler(capture, (call) async {
      calls.add(call);
      return switch (call.method) {
        'createVirtualDisplay' => {'applied': true, 'displayID': 9},
        'startCapture' => {'displayID': 1, 'hardware': false, 'fellBack': true},
        _ => null,
      };
    });
    final channel = ScreenCaptureChannel();
    final made = await channel
        .createVirtualDisplay(DisplayConfigModel.defaultConfig, session: 2);
    expect((made.ok, made.displayId), (true, 9));

    final started = await channel
        .startCapture(DisplayConfigModel.defaultConfig, session: 2);
    expect((started.displayId, started.hardware, started.fellBack),
        (1, false, true));
    expect((calls.last.arguments as Map).containsKey('fpsCeiling'), isFalse,
        reason: 'no ceiling: the encoder runs at the config rate, as before');

    await channel.startCapture(
        DisplayConfigModel.defaultConfig.copyWith(fpsCeiling: 45),
        session: 2);
    expect((calls.last.arguments as Map)['fpsCeiling'], 45);
  });

  test('a start that fails still throws its code', () async {
    messenger.setMockMethodCallHandler(
        capture, (call) async => throw PlatformException(code: 'ENCODER_BUSY'));
    final channel = ScreenCaptureChannel();
    await expectLater(
        channel.startCapture(DisplayConfigModel.defaultConfig, session: 2),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'ENCODER_BUSY')));
  });

  test('a frame-rate ceiling names its session and its rate', () async {
    final channel = ScreenCaptureChannel();
    await channel.setFrameRateCeiling(45, session: 3);
    expect(calls.single.method, 'setFrameRateCeiling');
    expect(calls.single.arguments, {'fps': 45, 'session': 3});
  });

  test("the Mac's chip and macOS version, or null when nobody answers",
      () async {
    messenger.setMockMethodCallHandler(
        capture,
        (call) async => call.method == 'getHostInfo'
            ? {'chip': 'Apple M3 Pro', 'os': '26.1.0'}
            : null);
    final channel = ScreenCaptureChannel();
    final info = await channel.getHostInfo();
    expect((info?.chip, info?.os), ('Apple M3 Pro', '26.1.0'));

    messenger.setMockMethodCallHandler(capture, null);
    expect(await channel.getHostInfo(), isNull);
    messenger.setMockMethodCallHandler(
        capture, (call) async => throw PlatformException(code: 'X'));
    expect(await channel.getHostInfo(), isNull);
  });

  test('native callbacks say which session they are about', () async {
    final channel = ScreenCaptureChannel();
    final restarts = <(int?, bool)>[];
    final rates = <(int, int)>[];
    final terminated = <(int, int)>[];
    final mismatched = <int>[];
    final matched = <int>[];
    channel.onCaptureRestartNeeded =
        (s, {bool asleep = false}) => restarts.add((s, asleep));
    channel.onFrameRateChanged = (s, fps) => rates.add((s, fps));
    final events = <String>[];
    channel.onEncoderOverload = (s, achieved) => events.add('$s over $achieved');
    channel.onVirtualDisplayTerminated = (s, d) => terminated.add((s, d));
    channel.onCaptureMismatch = mismatched.add;
    channel.onCaptureMatched = matched.add;

    await fromNative('extended_screen/screen_capture', 'onStreamStopped',
        {'session': 3, 'error': 'gone'});
    await fromNative('extended_screen/screen_capture', 'onStreamStopped',
        {'session': 4, 'error': 'gone', 'asleep': true});
    await fromNative(
        'extended_screen/screen_capture', 'onCaptureNeedsRestart', null);
    await fromNative('extended_screen/screen_capture', 'onFrameRateChanged',
        {'session': 3, 'fps': 45});
    // An overload step-down says what the encoder managed, before the rate.
    channel.onFrameRateChanged = (s, fps) {
      rates.add((s, fps));
      events.add('$s at $fps');
    };
    await fromNative('extended_screen/screen_capture', 'onFrameRateChanged',
        {'session': 4, 'fps': 60, 'achieved': 71.5});
    await fromNative('extended_screen/screen_capture',
        'onVirtualDisplayTerminated', {'session': 3, 'displayID': 12});
    await fromNative('extended_screen/screen_capture', 'onCaptureMismatch',
        {'session': 4, 'x': 0.0, 'y': 0.1, 'w': 1.0, 'h': 0.8});
    await fromNative('extended_screen/screen_capture', 'onCaptureMatched',
        {'session': 3});

    expect(restarts, [(3, false), (4, true), (null, false)],
        reason: 'a wake is about every session');
    expect(rates, [(3, 45), (4, 60)]);
    expect(events, ['4 over 71.5', '4 at 60'],
        reason: 'only the overload carries what was achieved');
    expect(terminated, [(3, 12)]);
    expect(mismatched, [4]);
    expect(matched, [3]);
  });

  test("a frame for the tablet's decoder goes behind its session's id, and "
      'only the frame', () async {
    final sent = <Uint8List>[];
    messenger.setMockMessageHandler('extended_screen/remote_nal',
        (message) async {
      sent.add(Uint8List.fromList(
          message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes)));
      return null;
    });
    addTearDown(
        () => messenger.setMockMessageHandler('extended_screen/remote_nal', null));
    final channel = RemoteVideoChannel()..onInit();
    // A view into a bigger buffer, as a packet's payload is.
    final packet = Uint8List.fromList([9, 9, 0, 0, 0, 1, 0x26, 9, 9]);
    await channel.feedNal(5, Uint8List.sublistView(packet, 2, 7));

    expect(sent.single, [0, 0, 0, 5, 0, 0, 0, 1, 0x26]);
    expect(
        await channel.initialize(
            session: 5, codec: CodecType.h265, width: 2960, height: 1848),
        7);
    await channel.dispose(session: 5);
    expect(calls.map((c) => (c.method, (c.arguments as Map)['session'])),
        [('initialize', 5), ('dispose', 5)]);
  });

  test('mouse, key and release calls name their session', () async {
    final channel = InputInjectChannel();
    await channel.injectMouse(
        MouseEventModel(
          normalizedX: 0.5,
          normalizedY: 0.5,
          button: MouseButton.left,
          action: MouseAction.down,
          timestampUs: 0,
        ),
        {'x': 0, 'y': 0, 'w': 100, 'h': 100},
        session: 6);
    await channel.injectKey(
        KeyEventModel(keycode: 0, modifiers: 0, isDown: true, timestampUs: 0),
        session: 6);
    await channel.releaseAll(session: 6);
    expect(calls.map((c) => (c.method, (c.arguments as Map)['session'])),
        [('injectMouse', 6), ('injectKey', 6), ('releaseAll', 6)]);
  });

  group('rebuilding the capture', () {
    late HostSession host;
    late int starts;

    /// The host's capture as native answers it; [startCapture] decides each
    /// start (by default it works).
    void native({Future<Object?> Function()? startCapture}) {
      messenger.setMockMethodCallHandler(capture, (call) async {
        calls.add(call);
        return switch (call.method) {
          'startCapture' => await (() async {
              starts++;
              return startCapture == null
                  ? {'displayID': 3, 'hardware': true, 'fellBack': false}
                  : await startCapture();
            })(),
          'createVirtualDisplay' => {'applied': true, 'displayID': 5},
          _ => null,
        };
      });
    }

    setUp(() {
      starts = 0;
      messenger.setMockStreamHandler(
          frames, MockStreamHandler.inline(onListen: (_, _) {}));
      Get.put<AdbService>(AdbService());
      Get.put(ScreenCaptureChannel());
      Get.put(InputInjectChannel());
      host = HostSession(
        key: 'TABLET',
        link: LinkType.usb,
        serial: 'TABLET',
        pipeline: PipelineQueue(),
        socket: SocketService(),
      )..phase.value = ConnectionPhase.streaming;
      // The plugin's callbacks reach a session through the hub.
      HostConnectionManager(socket: SocketService()).sessions['TABLET'] = host;
    });

    test('a wake that comes while a rebuild cannot work yet (the displays '
        'were still asleep) gets a rebuild of its own', () async {
      final asleep = Completer<void>();
      native(startCapture: () async {
        if (starts > 1) return {'displayID': 3, 'hardware': true};
        await asleep.future;
        throw PlatformException(code: 'NO_DISPLAY');
      });
      // The stream stopped as the displays went to sleep.
      final rebuilt = host.rebuildCapture();
      await pumpEventQueue();
      expect(starts, 1);

      // They wake while that rebuild is still looking for a display.
      await fromNative(
          'extended_screen/screen_capture', 'onCaptureNeedsRestart', null);
      asleep.complete();
      await rebuilt;

      expect(starts, 2);
      expect(calls.where((c) => c.method == 'stopCapture'), hasLength(2));
      expect(calls.last.method, 'requestIdr',
          reason: 'the second rebuild worked and asks for a keyframe');
    });

    test('a rebuild that failed is not retried by itself, and the next wake '
        'rebuilds', () async {
      native(startCapture: () async => throw PlatformException(code: 'NO_DISPLAY'));
      await host.rebuildCapture();
      expect(starts, 1);

      native();
      await fromNative(
          'extended_screen/screen_capture', 'onCaptureNeedsRestart', null);
      await pumpEventQueue();
      expect(starts, 2);
    });

    test('alone, a wake rebuilds through the session itself: stop, remove '
        'the display, make it again, start, keyframe', () async {
      native();
      await host.rebuildCapture();
      calls.clear();
      await fromNative(
          'extended_screen/screen_capture', 'onCaptureNeedsRestart', null);
      await pumpEventQueue();
      const steps = {
        'stopCapture',
        'removeVirtualDisplay',
        'createVirtualDisplay',
        'startCapture',
        'requestIdr',
      };
      expect(calls.map((c) => c.method).where(steps.contains), [
        'stopCapture',
        'removeVirtualDisplay',
        'createVirtualDisplay',
        'startCapture',
        'requestIdr',
      ]);
    });

    test('a wake after the session ended rebuilds nothing', () async {
      native();
      await host.rebuildCapture();
      expect(starts, 1);
      host.phase.value = ConnectionPhase.disconnected;
      await fromNative(
          'extended_screen/screen_capture', 'onCaptureNeedsRestart', null);
      await pumpEventQueue();
      expect(starts, 1);
    });
  });

  test('every host session gets an id of its own, never reused', () {
    Get.put<AdbService>(AdbService());
    HostSession session() => HostSession(
          key: 'TABLET',
          link: LinkType.usb,
          serial: 'TABLET',
          pipeline: PipelineQueue(),
          socket: SocketService(),
        );
    final a = session();
    final b = session();
    expect(a.nativeId, isNot(b.nativeId));
    expect(a.nativeId, greaterThan(0), reason: '0 is what a call without one means');
  });
}
