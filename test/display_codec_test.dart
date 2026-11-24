import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/client/display/controllers/display_controller.dart';
import 'package:extendedscreen/modules/extended_screen/client/video_decoder_channel.dart';
import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/client_connection_manager.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Keeps test output free of the pretty-printed connection log.
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

/// A host link that is always up: [receive] plays a packet from the host on
/// the same broadcast stream the real socket uses, and [sent] records what
/// the client sent. Like a Mac that holds [sessionKey], it answers the hello
/// a USB session opens with.
class _LoopbackSocket extends SocketService {
  _LoopbackSocket(this.sessionKey);

  final Uint8List sessionKey;
  final _packets = StreamController<Packet>.broadcast();
  final sent = <Packet>[];

  @override
  Stream<Packet> get packetStream => _packets.stream;

  @override
  Future<void> connect(String host, int port) async {}

  @override
  void send(Packet packet) {
    sent.add(packet);
    final p = packet.payload;
    if (packet.type == PacketType.control &&
        p.isNotEmpty &&
        p[0] == UsbSessionService.helloCommand) {
      final nonce = UsbSessionService.verifyHello(sessionKey, p);
      if (nonce != null) {
        receive(UsbSessionService.buildAnswer(sessionKey, nonce));
      }
    }
  }

  @override
  Future<void> disconnect() async {}

  void receive(List<int> payload, {PacketType type = PacketType.control}) =>
      _packets.add(Packet(
        type: type,
        timestampUs: 0,
        payload: Uint8List.fromList(payload),
      ));
}

/// Only [ClientConnectionManager.onTeardown] (via disconnect) touches it.
class _IdleCapture extends AndroidCaptureChannel {
  @override
  Future<void> stopCapture() async {}
}

/// Stands in for VideoDecoderPlugin.kt on `extended_screen/video_decoder`,
/// with its surface already attached. Like the plugin it acts on each call as
/// it arrives, in order: `initialize` configures only when nothing is
/// configured (a second one changes nothing), `dispose` releases. Replies can
/// be held back with [gates] to stretch the Dart side's awaits.
class _NativeDecoder {
  /// Codec of the running decoder ('h264' / 'h265'), null when released.
  String? running;

  /// What `initialize` answers: the iOS plugin's texture id, null on
  /// Android.
  int? textureId;

  /// Codec requested by every `initialize`, in order.
  final initialized = <String>[];
  int disposes = 0;
  final gates = <String, Completer<void>>{};

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'initialize':
        final codec = (call.arguments as Map)['codec'] as String;
        initialized.add(codec);
        running ??= codec;
        await gates[call.method]?.future;
        return textureId;
      case 'dispose':
        disposes++;
        running = null;
      case 'getMaxRefreshRate':
        return 120;
      case 'getDropCount':
        return 0;
    }
    await gates[call.method]?.future;
    return null;
  }
}

const _decoderChannel = MethodChannel('extended_screen/video_decoder');
const _nalChannel = 'extended_screen/nal_feed';
// wakelock_plus: its macOS Dart implementation (registered by `flutter test`
// on a Mac) and the default pigeon one.
const _wakelockMacChannel = MethodChannel('wakelock_plus_macos');
const _wakelockPigeonChannel =
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _LoopbackSocket socket;
  late _NativeDecoder native;
  late SettingsService settings;
  late ClientConnectionManager cm;
  late int nalsFed;

  setUp(() async {
    // The tablet last streamed H.265, so that is what it has persisted.
    SharedPreferences.setMockInitialValues({'codec': 'h265'});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put<SettingsService>(settings);
    // The key adb delivered for this session, held by both ends.
    final sessionKey = UsbSessionService.newKey();
    Get.put(UsbSessionService())
        .accept(UsbSessionService.buildDelivery(sessionKey));
    socket = _LoopbackSocket(sessionKey);
    Get.put<SocketService>(socket);
    Get.put<AndroidCaptureChannel>(_IdleCapture());

    native = _NativeDecoder();
    nalsFed = 0;
    messenger.setMockMethodCallHandler(_decoderChannel, native.handle);
    messenger.setMockMessageHandler(_nalChannel, (_) async {
      nalsFed++;
      return null;
    });
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(_wakelockMacChannel, (_) async => null);
    messenger.setMockMessageHandler(_wakelockPigeonChannel,
        (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]));
    Get.put<VideoDecoderChannel>(VideoDecoderChannel());

    cm = ClientConnectionManager();
    Get.put<BaseConnectionManager>(cm);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_decoderChannel, null);
    messenger.setMockMessageHandler(_nalChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_wakelockMacChannel, null);
    messenger.setMockMessageHandler(_wakelockPigeonChannel, null);
    Get.reset();
  });

  /// Lets every pending channel reply and packet delivery run.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// Connects (the manager subscribes to packets first, as on a real
  /// connect), then opens the display view, whose onReady runs a frame later
  /// (here nothing else schedules that frame, so ask for it).
  Future<void> connectAndOpenDisplay(WidgetTester tester) async {
    await cm.connect();
    Get.put(DisplayController());
    tester.binding.scheduleFrame();
    await settle(tester);
  }

  /// Stops every timer before flutter_test checks for pending ones.
  Future<void> closeAll(WidgetTester tester) async {
    if (Get.isRegistered<DisplayController>()) {
      await Get.delete<DisplayController>();
    }
    await cm.disconnect();
    await Get.delete<BaseConnectionManager>(force: true);
    await settle(tester);
  }

  void announceCodec(CodecType codec) =>
      socket.receive([0xFC, codec == CodecType.h265 ? 1 : 0]);

  void sendFrame() =>
      socket.receive([0, 0, 0, 1, 0x65], type: PacketType.frameData);

  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets(
      'fresh connect: a host codec that differs from the persisted one '
      'rebuilds the decoder', (tester) async {
    await connectAndOpenDisplay(tester);
    expect(native.initialized, ['h265'],
        reason: 'the view opens before 0xFC, so it builds from the setting');

    announceCodec(CodecType.h264);
    await settle(tester);

    expect(settings.codec, CodecType.h264);
    expect(native.initialized, ['h265', 'h264']);
    expect(native.running, 'h264');

    // One frame listener after the rebuild, not one per build.
    sendFrame();
    await settle(tester);
    expect(nalsFed, 1);

    await closeAll(tester);
  }, variant: android);

  testWidgets('announcing the codec the decoder runs does not rebuild it',
      (tester) async {
    await connectAndOpenDisplay(tester);
    final disposes = native.disposes;

    announceCodec(CodecType.h265);
    await settle(tester);

    expect(native.initialized, ['h265']);
    expect(native.disposes, disposes);
    expect(native.running, 'h265');

    await closeAll(tester);
  }, variant: android);

  testWidgets(
      'codec changes during a rebuild end on the latest codec with one '
      'frame listener', (tester) async {
    await connectAndOpenDisplay(tester);

    native.gates['initialize'] = Completer<void>();
    announceCodec(CodecType.h264);
    await settle(tester);
    announceCodec(CodecType.h265);
    await settle(tester);
    native.gates.remove('initialize')!.complete();
    await settle(tester);

    expect(native.initialized, ['h265', 'h264', 'h265']);
    expect(native.running, 'h265');
    sendFrame();
    await settle(tester);
    expect(nalsFed, 1);

    await closeAll(tester);
  }, variant: android);

  testWidgets(
      'closing the view while a rebuild releases the old decoder does not '
      'bring a decoder back', (tester) async {
    await connectAndOpenDisplay(tester);

    native.gates['dispose'] = Completer<void>();
    announceCodec(CodecType.h264);
    await settle(tester);
    await Get.delete<DisplayController>();
    native.gates.remove('dispose')!.complete();
    await settle(tester);

    expect(native.initialized, ['h265'],
        reason: 'no initialize may follow the view\'s own dispose');
    expect(native.running, isNull);
    sendFrame();
    await settle(tester);
    expect(nalsFed, 0);

    await closeAll(tester);
  }, variant: android);

  testWidgets(
      'closing the view while a rebuild initializes leaves no frame '
      'listener behind', (tester) async {
    await connectAndOpenDisplay(tester);

    native.gates['initialize'] = Completer<void>();
    announceCodec(CodecType.h264);
    await settle(tester);
    await Get.delete<DisplayController>();
    native.gates.remove('initialize')!.complete();
    await settle(tester);

    expect(native.running, isNull);
    sendFrame();
    await settle(tester);
    expect(nalsFed, 0);

    await closeAll(tester);
  }, variant: android);

  testWidgets('HELLO reports the display, landscape, not the view',
      (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    // The view leaves out a 96 px navigation bar; the display is the whole
    // panel (reported portrait here to exercise the normalisation).
    tester.view.physicalSize = const Size(2960, 1752);
    tester.view.display.size = const Size(1848, 2960);

    await cm.connect();

    final hello = socket.sent.firstWhere(
        (p) => p.type == PacketType.control && p.payload[0] == 0x01);
    expect(hello.payload.sublist(0, 7), [0x01, 0x02, 2960 >> 8, 2960 & 0xFF,
        1848 >> 8, 1848 & 0xFF, 120]);
    // Then who it is: the identity tail, its install id made once.
    final tail = HelloTail.parse(hello.payload);
    expect(tail, isNotNull);
    expect(tail!.installId, Get.find<SettingsService>().installId);

    await closeAll(tester);
  });

  testWidgets('HELLO falls back to the view when the display size is empty',
      (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    tester.view.physicalSize = const Size(2960, 1752);
    tester.view.display.size = Size.zero;

    await cm.connect();

    final hello = socket.sent.firstWhere(
        (p) => p.type == PacketType.control && p.payload[0] == 0x01);
    expect(hello.payload.sublist(2, 6),
        [2960 >> 8, 2960 & 0xFF, 1752 >> 8, 1752 & 0xFF]);

    await closeAll(tester);
  });

  testWidgets('iOS: the display shows the texture each decoder build answers',
      (tester) async {
    native.textureId = 7;
    await connectAndOpenDisplay(tester);
    final display = Get.find<DisplayController>();
    expect(native.initialized, ['h265']);
    expect(display.textureId.value, 7);

    // A codec change rebuilds the decoder, and with it the texture.
    native.textureId = 8;
    announceCodec(CodecType.h264);
    await settle(tester);
    expect(native.initialized, ['h265', 'h264']);
    expect(display.textureId.value, 8);

    sendFrame();
    await settle(tester);
    expect(nalsFed, 1);

    await closeAll(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('iOS HELLO', () {
    void phoneView(WidgetTester tester) {
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      // iPhone 18 Pro Max in landscape; its display is reported portrait.
      tester.view.physicalSize = const Size(2868, 1320);
      tester.view.devicePixelRatio = 3;
      tester.view.display.size = const Size(1320, 2868);
      tester.view.display.devicePixelRatio = 3;
      tester.view.padding =
          const FakeViewPadding(left: 186, right: 186, bottom: 63);
    }

    testWidgets('an iPhone reports 0x03 and the display less its side insets',
        (tester) async {
      phoneView(tester);
      final phone = ClientConnectionManager(ios: true);

      await phone.connect();

      final hello = socket.sent.firstWhere(
          (p) => p.type == PacketType.control && p.payload[0] == 0x01);
      expect(hello.payload.sublist(0, 7), [0x01, 0x03, 2496 >> 8, 2496 & 0xFF,
          1320 >> 8, 1320 & 0xFF, 120]);
      expect(phone.helloSize.value, const Size(2496, 1320));

      await phone.disconnect();
      await closeAll(tester);
    });

    testWidgets('an iPad reports 0x04 and its window less the safe area',
        (tester) async {
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      tester.view.physicalSize = const Size(2752, 2064);
      tester.view.devicePixelRatio = 2;
      tester.view.display.size = const Size(2064, 2752);
      tester.view.display.devicePixelRatio = 2;
      tester.view.padding = const FakeViewPadding(bottom: 40);
      final pad = ClientConnectionManager(ios: true);

      await pad.connect();

      final hello = socket.sent.firstWhere(
          (p) => p.type == PacketType.control && p.payload[0] == 0x01);
      expect(hello.payload.sublist(0, 7), [0x01, 0x04, 2752 >> 8, 2752 & 0xFF,
          2024 >> 8, 2024 & 0xFF, 120]);

      await pad.disconnect();
      await closeAll(tester);
    });

    testWidgets('Android ignores the insets, as before', (tester) async {
      phoneView(tester);

      await cm.connect();

      final hello = socket.sent.firstWhere(
          (p) => p.type == PacketType.control && p.payload[0] == 0x01);
      expect(hello.payload.sublist(1, 6),
          [0x02, 2868 >> 8, 2868 & 0xFF, 1320 >> 8, 1320 & 0xFF]);

      await closeAll(tester);
    });
  });
}
