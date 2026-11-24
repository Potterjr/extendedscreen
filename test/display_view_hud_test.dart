import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/client/display/controllers/display_controller.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/views/display_view.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class _FakeConnection extends BaseConnectionManager {
  int disconnects = 0;

  @override
  bool get isHost => false;

  @override
  Future<void> connect({String? serial}) async {}

  @override
  Future<void> autoConnect() async {}

  @override
  Future<void> disconnect() async {
    disconnects++;
    phase.value = ConnectionPhase.disconnected;
  }
}

/// Skips the decoder, wake lock and system-UI work, and records the pointer
/// downs that reach the touch overlay (i.e. would be sent to the Mac).
class _FakeDisplayController extends DisplayController {
  final touches = <Offset>[];
  final touchedSizes = <Size>[];

  @override
  bool get isAndroid => false;

  @override
  void onReady() {}

  @override
  void onClose() {}

  @override
  void onPointerDown(int id, Offset pos, Size size) {
    touches.add(pos);
    touchedSizes.add(size);
  }
}

/// The iOS display: the decoder's texture, for a stream of [stream]'s shape.
class _TextureDisplayController extends _FakeDisplayController {
  _TextureDisplayController(this.stream);
  final Size stream;

  @override
  bool get usesTexture => true;

  @override
  Size? get streamSize => stream;
}

const _home = 'home page';

void main() {
  late _FakeConnection connection;
  late _FakeDisplayController display;
  late SettingsService settings;
  _FakeDisplayController Function() makeDisplay = _FakeDisplayController.new;

  setUp(() async {
    Get.testMode = true;
    SharedPreferences.setMockInitialValues({'locale': 'en'});
    Get.put(LoggerService());
    Get.put(SocketService());
    settings = Get.put(SettingsService());
    await settings.init();
    connection = Get.put<BaseConnectionManager>(_FakeConnection())
        as _FakeConnection;
    connection.phase.value = ConnectionPhase.streaming;
  });

  tearDown(() {
    makeDisplay = _FakeDisplayController.new;
    Get.reset();
  });

  Future<void> openDisplay(WidgetTester tester) async {
    // A landscape tablet panel (2960×1848 at 2×), not the 800×600 default.
    tester.view.physicalSize = const Size(2960, 1848);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(
      translations: AppTranslations(),
      locale: const Locale('en'),
      initialRoute: '/',
      getPages: [
        GetPage(name: '/', page: () => const Scaffold(body: Text(_home))),
        GetPage(
          name: '/display',
          page: () => const DisplayView(),
          // Registered per route like the app's DisplayBinding; a controller
          // put in setUp is deleted when the previous test's route goes away.
          binding: BindingsBuilder(() {
            display = Get.put<DisplayController>(makeDisplay())
                as _FakeDisplayController;
          }),
        ),
      ],
    ));
    Get.toNamed('/display');
    // Route transition only; the HUD's 4 s timer is still running after it.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder hittable(String text) => find.text(text).hitTestable();

  // An implicit animation starts on the frame after the state change, so one
  // bare pump first, then long enough for the 200 ms slide/fade.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> waitForHide(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  }

  testWidgets('HUD bar shows on open, then collapses to the handle',
      (tester) async {
    await openDisplay(tester);
    expect(hittable('Disconnect'), findsOneWidget);
    expect(find.text('0 fps'), findsOneWidget);
    expect(find.bySemanticsLabel('Show controls').hitTestable(), findsNothing);

    await waitForHide(tester);
    expect(hittable('Disconnect'), findsNothing);
    expect(find.bySemanticsLabel('Show controls').hitTestable(), findsOneWidget);

    // Tapping the handle brings the bar back for another 4 s.
    await tester.tap(find.bySemanticsLabel('Show controls'));
    await settle(tester);
    expect(hittable('Disconnect'), findsOneWidget);
    expect(display.touches, isEmpty, reason: 'the handle keeps its tap');

    await waitForHide(tester);
    expect(hittable('Disconnect'), findsNothing);
  });

  testWidgets('a touch on the bar restarts the hide timer', (tester) async {
    await openDisplay(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Extended Screen'));
    await tester.pump(const Duration(seconds: 3));
    expect(hittable('Disconnect'), findsOneWidget);
    expect(display.touches, isEmpty, reason: 'the visible bar keeps its tap');

    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(hittable('Disconnect'), findsNothing);
  });

  testWidgets('touches outside the bar and handle reach the touch overlay',
      (tester) async {
    await openDisplay(tester);
    final barSpot = tester.getCenter(find.text('Extended Screen'));

    // Bar visible: the middle of the screen still goes to the Mac.
    await tester.tapAt(const Offset(400, 300));
    expect(display.touches, hasLength(1));

    await waitForHide(tester);

    // Bar hidden: where it was now goes to the Mac (its menu bar), and so
    // does the top edge just beside the handle.
    await tester.tapAt(barSpot);
    final handle = tester.getRect(find.bySemanticsLabel('Show controls'));
    expect(handle.width, greaterThanOrEqualTo(48));
    expect(handle.height, greaterThanOrEqualTo(48));
    await tester.tapAt(Offset(handle.left - 4, 10));
    expect(display.touches, hasLength(3));
  });

  testWidgets('bar and handle stay below a top display cutout',
      (tester) async {
    // A top-centre notch reported as a 60 px safe inset (30 logical at 2×).
    // openDisplay's view reset clears it again.
    tester.view.padding = const FakeViewPadding(top: 60);
    tester.view.viewPadding = const FakeViewPadding(top: 60);
    await openDisplay(tester);
    expect(tester.getRect(find.byTooltip('Back')).top,
        greaterThanOrEqualTo(30));
    expect(tester.getRect(find.text('Disconnect')).top,
        greaterThanOrEqualTo(30));

    await waitForHide(tester);
    final handle = tester.getRect(find.bySemanticsLabel('Show controls'));
    expect(handle.top, greaterThanOrEqualTo(30));
    await tester.tap(find.bySemanticsLabel('Show controls'));
    await settle(tester);
    expect(hittable('Disconnect'), findsOneWidget);
    expect(display.touches, isEmpty, reason: 'the handle keeps its tap');
  });

  testWidgets('with Show HUD off the bar keeps only Back and Disconnect',
      (tester) async {
    settings.showHudOverlay.value = false;
    await openDisplay(tester);
    expect(hittable('Disconnect'), findsOneWidget);
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    expect(find.text('0 fps'), findsNothing);
    expect(find.text('Extended Screen'), findsNothing);

    await waitForHide(tester);
    await tester.tap(find.bySemanticsLabel('Show controls'));
    await settle(tester);
    await tester.tap(hittable('Disconnect'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(connection.disconnects, 1);
    expect(find.text(_home), findsOneWidget);
  });

  testWidgets('HUD Back leaves the view without disconnecting',
      (tester) async {
    await openDisplay(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(_home), findsOneWidget);
    expect(connection.disconnects, 0);
  });

  group('reconnect overlay', () {
    Future<void> showOverlay(WidgetTester tester) async {
      await openDisplay(tester);
      connection.phase.value = ConnectionPhase.error;
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('shows a neutral reason and absorbs other taps',
        (tester) async {
      // Below the HUD bar and clear of the overlay's text and buttons, so
      // only the overlay itself can keep this tap from the touch overlay.
      const spot = Offset(740, 820);
      await openDisplay(tester);
      await tester.tapAt(spot);
      expect(display.touches, hasLength(1));

      connection.phase.value = ConnectionPhase.error;
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('display_reconnect_hint'.tr), findsOneWidget);
      expect(find.textContaining('Applying new settings'), findsNothing);
      await tester.tapAt(spot);
      expect(display.touches, hasLength(1));
      // Only the overlay's own buttons are reachable, not the HUD's.
      expect(hittable('Disconnect'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(OutlinedButton), matching: find.text('Back')),
          findsOneWidget);
    });

    testWidgets('Disconnect stops the link and leaves the view',
        (tester) async {
      await showOverlay(tester);
      await tester.tap(hittable('Disconnect'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(connection.disconnects, 1);
      expect(find.text(_home), findsOneWidget);
    });

    testWidgets('Back leaves the view and keeps redialling', (tester) async {
      await showOverlay(tester);
      await tester.tap(hittable('Back'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(connection.disconnects, 0);
      expect(find.text(_home), findsOneWidget);
    });
  });

  testWidgets('iOS: the texture sits in a box of the stream\'s shape, and '
      'touches are measured over that box alone', (tester) async {
    makeDisplay = () => _TextureDisplayController(const Size(2496, 1320));
    await openDisplay(tester);
    // The iPhone's 956×440 pt, not the tablet panel openDisplay set.
    tester.view.physicalSize = const Size(2868, 1320);
    tester.view.devicePixelRatio = 3.0;
    await tester.pump();

    // No texture yet: black, no Texture widget.
    expect(find.byType(Texture), findsNothing);
    display.textureId.value = 5;
    await tester.pump();
    final texture = find.byType(Texture);
    expect(tester.widget<Texture>(texture).textureId, 5);
    // 2496×1320 fitted into 956×440: 832×440, centred.
    expect(tester.getSize(texture), const Size(832, 440));
    expect(tester.getTopLeft(texture), const Offset(62, 0));

    // Let the HUD collapse so the middle of the screen is the overlay's.
    await waitForHide(tester);
    await tester.tapAt(const Offset(478, 300));
    expect(display.touches.single, const Offset(416, 300));
    expect(display.touchedSizes.single, const Size(832, 440));

    // The black bar beside the picture is not the Mac's.
    await tester.tapAt(const Offset(30, 300));
    expect(display.touches, hasLength(1));
  });
}
