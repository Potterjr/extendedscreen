import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/client/display/controllers/display_controller.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/views/display_view.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/platform/windows_app.dart';
import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:extendedscreen/shared/protocol/pairing_code.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Keeps what the display would send to the Mac.
class _Connection extends BaseConnectionManager {
  final mouse = <MouseEventModel>[];

  @override
  bool get isHost => false;

  @override
  Future<void> connect({String? serial}) async {}

  @override
  Future<void> autoConnect() async {}

  @override
  void sendMouse(MouseEventModel event) => mouse.add(event);
}

/// The Windows display without its decoder, wake lock or system UI.
class _WindowsDisplay extends DisplayController {
  _WindowsDisplay(this.stream);
  final Size stream;

  @override
  bool get usesTexture => true;

  @override
  bool get usesMouse => true;

  @override
  Size? get streamSize => stream;

  @override
  void onReady() {}

  @override
  void onClose() {}
}

String _describe(MouseEventModel e) {
  String n(double v) => v.toStringAsFixed(2);
  return switch (e.action) {
    MouseAction.scroll =>
      'scroll ${e.scrollDx.toStringAsFixed(1)},${e.scrollDy.toStringAsFixed(1)}',
    _ => '${e.action.name} ${e.button.name} ${n(e.normalizedX)},'
        '${n(e.normalizedY)}',
  };
}

void main() {
  group('HELLO from Windows', () {
    test('reports the monitor, rounded down to even, else the window', () {
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.windows,
          display: const Size(2560, 1440),
          window: const Size(1280, 720),
        ),
        (w: 2560, h: 1440),
      );
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.windows,
          display: null,
          window: const Size(1919.6, 1081),
        ),
        (w: 1918, h: 1080),
      );
    });

    test('carries platform 0x05 and its name in the identity tail', () {
      final id = Uint8List.fromList(List.generate(16, (i) => i));
      final p = ClientHello.payload(
        platform: ClientPlatform.windows,
        width: 2560,
        height: 1440,
        maxRefreshHz: 144,
        installId: id,
        name: 'Windows',
      );
      expect(p.sublist(0, 7), [0x01, 0x05, 0x0A, 0x00, 0x05, 0xA0, 144]);
      final tail = HelloTail.parse(p)!;
      expect(tail.installId, id);
      expect(tail.name, 'Windows');
    });
  });

  group('PairingCode', () {
    test('round-trips a pairing, line breaks and blanks ignored', () {
      final payload = Uint8List.fromList(List.generate(200, (i) => i * 7));
      final code = PairingCode.encode(payload);
      expect(code, startsWith(PairingCode.prefix));
      expect(code, isNot(contains('=')));
      final wrapped = '  ${code.substring(0, 40)}\n${code.substring(40)}\t';
      expect(PairingCode.decode(wrapped), payload);
    });

    test('anything else is no pairing code', () {
      expect(PairingCode.decode(''), isNull);
      expect(PairingCode.decode('esp1:'), isNull);
      expect(PairingCode.decode('esp2:AAAA'), isNull);
      expect(PairingCode.decode('esp1:AA+A/'), isNull);
      expect(PairingCode.decode('AAAA'), isNull);
    });

    test("a pasted code stores the Mac as adb's bytes would", () async {
      SharedPreferences.setMockInitialValues({});
      Get.put(LoggerService());
      addTearDown(Get.reset);
      final pairing = WifiPairingService();
      final payload = WifiPairingService.buildPairingPayload(
        WifiIdentity(
          hostId: Uint8List(WifiIdentity.hostIdLength)..fillRange(0, 16, 3),
          token: Uint8List(WifiIdentity.tokenLength),
          certPem:
              '-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----',
          keyPem: '',
        ),
        'Studio',
      );
      final pasted = PairingCode.decode(PairingCode.encode(payload))!;
      expect(await pairing.storePairing(pasted), isTrue);
      expect(pairing.pairedHosts.single.name, 'Studio');
    });
  });

  group('settings on Windows', () {
    test('the link is Wi-Fi whatever was saved, and cannot be changed',
        () async {
      SharedPreferences.setMockInitialValues({'link_type': 'usb'});
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(runsOnWindows, isTrue);
        expect(wifiOnlyClient, isTrue);
        final settings = SettingsService();
        await settings.init();
        expect(settings.linkTypeRx.value, LinkType.wifi);
        await settings.setLinkType(LinkType.usb);
        expect(settings.linkType, LinkType.wifi);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('the mouse on the picture', () {
    late _Connection connection;

    setUp(() async {
      Get.testMode = true;
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      Get.put(LoggerService());
      Get.put(SocketService());
      final settings = Get.put(SettingsService());
      await settings.init();
      connection = Get.put<BaseConnectionManager>(_Connection()) as _Connection;
      connection.phase.value = ConnectionPhase.streaming;
    });

    tearDown(Get.reset);

    /// A 1600×900 window showing a 2560×1600 stream: a 1440×900 picture
    /// centred, 80 px of black on each side.
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(GetMaterialApp(
        translations: AppTranslations(),
        locale: const Locale('en'),
        initialRoute: '/display',
        getPages: [
          GetPage(
            name: '/display',
            page: () => const DisplayView(),
            binding: BindingsBuilder(() {
              Get.put<DisplayController>(
                  _WindowsDisplay(const Size(2560, 1600)));
            }),
          ),
        ],
      ));
      // Let the HUD collapse so it covers nothing but its handle.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      connection.mouse.clear();
    }

    testWidgets('a hover moves, each button goes down and up as itself, '
        'normalized over the picture', (tester) async {
      await open(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(800, 450));
      await mouse.moveTo(const Offset(80 + 360, 675));
      await tester.pump();
      expect(connection.mouse.map(_describe), contains('move none 0.25,0.75'));

      connection.mouse.clear();
      await mouse.down(const Offset(80 + 720, 450));
      await mouse.moveTo(const Offset(80 + 1080, 450));
      await mouse.up();
      await tester.pump();
      expect(connection.mouse.map(_describe), [
        'down left 0.50,0.50',
        'move left 0.75,0.50',
        'up left 0.75,0.50',
      ]);

      connection.mouse.clear();
      final right = await tester.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await right.down(const Offset(80 + 144, 90));
      await right.up();
      await tester.pump();
      expect(connection.mouse.map(_describe),
          ['down right 0.10,0.10', 'up right 0.10,0.10']);
    });

    testWidgets('the wheel scrolls where the pointer is, the wheel towards '
        'you scrolling the page down', (tester) async {
      await open(tester);
      connection.mouse.clear();
      await tester.sendEventToBinding(const PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(80 + 720, 450),
        scrollDelta: Offset(0, 50),
      ));
      await tester.pump();
      expect(connection.mouse.map(_describe),
          ['move none 0.50,0.50', 'scroll -0.0,-6.0']);
    });

    testWidgets('a press outside the picture sends nothing', (tester) async {
      await open(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.down(const Offset(40, 450));
      await mouse.up();
      await tester.pump();
      expect(connection.mouse.where((e) => e.action != MouseAction.move),
          isEmpty);
    });
  });
}
