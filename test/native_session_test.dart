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
    expect(
        await channel.createVirtualDisplay(DisplayConfigModel.defaultConfig,
            session: 2, serialNum: 0x10002, name: 'Extended Screen – Tab'),
        isFalse);
    final args = calls.single.arguments as Map;
    expect(args['session'], 2);
    expect(args['serialNum'], 0x10002);
    expect(args['name'], 'Extended Screen – Tab');
  });

  test('native callbacks say which session they are about', () async {
    final channel = ScreenCaptureChannel();
    final restarts = <int?>[];
    final rates = <(int, int)>[];
    channel.onCaptureRestartNeeded = restarts.add;
    channel.onFrameRateChanged = (s, fps) => rates.add((s, fps));

    await fromNative('extended_screen/screen_capture', 'onStreamStopped',
        {'session': 3, 'error': 'gone'});
    await fromNative(
        'extended_screen/screen_capture', 'onCaptureNeedsRestart', null);
    await fromNative('extended_screen/screen_capture', 'onFrameRateChanged',
        {'session': 3, 'fps': 45});

    expect(restarts, [3, null], reason: 'a wake is about every session');
    expect(rates, [(3, 45)]);
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
