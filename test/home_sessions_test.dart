import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_grid_controller.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/device_picker_card.dart';
import 'package:extendedscreen/shared/widgets/session_card.dart';

/// The Mac's hub with what Home asks of it recorded instead of done: the
/// sessions are adopted, never connected.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
    : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  final stops = <(String, bool)>[];
  final connects = <String?>[];

  /// The mode each of [connects] was given.
  final choices = <SessionChoice?>[];
  int disconnects = 0;

  @override
  Future<void> disconnectSession(
    String key, {
    bool userStopped = false,
  }) async => stops.add((key, userStopped));

  // Where every connect of the hub's goes through: Home's (the hub's own
  // `connect`, which adds the selectors' mode) and the policy's.
  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {
    connects.add(serial);
    choices.add(choice);
  }

  @override
  Future<void> disconnect() async => disconnects++;

  /// The mode changes asked for (tablet, mode, the session it was asked
  /// of), recorded instead of done.
  final modeChanges = <(String, SessionChoice, HostSession?)>[];

  @override
  Future<bool> changeMode(
    String key,
    SessionChoice choice, {
    HostSession? expected,
  }) async {
    modeChanges.add((key, choice, expected));
    return true;
  }

  @override
  Future<void> autoConnect() async {}

  /// Tablets between two sessions, as the hub holds one while its mode is
  /// being changed (the change itself is only recorded here): in no
  /// session, its place kept, not offered as a tablet to add.
  final between = <String>{}.obs;

  @override
  bool get replacing => between.isNotEmpty;

  @override
  Set<String> get heldUsbPlaces => {...super.heldUsbPlaces, ...between};

  @override
  List<DeviceModel> get freeDevices => [
    for (final d in super.freeDevices)
      if (!between.contains(d.serial)) d,
  ];
}

/// adb listing the tablets the test attached.
class _Adb extends AdbService {
  List<DeviceModel> devices = const [];
  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async => devices;
}

/// The pushes of the remote view, with what each was given.
class _Pushes extends NavigatorObserver {
  final arguments = <Object?>[];

  int get remote => arguments.length;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == AppRoutes.remoteHost) {
      arguments.add(route.settings.arguments);
    }
  }
}

const _reverse = SessionChoice(
  SessionMode.remoteControl,
  RemoteDirection.macControlsTab,
);
const _driving = SessionChoice(
  SessionMode.remoteControl,
  RemoteDirection.tabControlsMac,
);
const _extended = SessionChoice(SessionMode.extendedScreen);

const _permissions = MethodChannel('extended_screen/permissions');

DeviceModel _device(String serial, String model) =>
    DeviceModel(serial: serial, model: model, status: DeviceStatus.connected);

/// The action button of [key]'s card that reads [label].
Finder _action(String key, String label) => find.byKey(ValueKey('$key/$label'));

Finder _card(String key) => find.byKey(ValueKey('session/$key'));

/// The button on [key]'s card that opens its mode menu.
Finder _modeMenu(String key) => find.byKey(ValueKey('$key/mode'));

/// The item for [choice] in [key]'s open mode menu.
Finder _modeItem(String key, SessionChoice choice) => find.byKey(
  ValueKey('$key/mode/${choice.mode.name}.${choice.direction.name}'),
);

/// The add panel's selector option for what the next tablet runs as:
/// `mode/<name>` or `dir/<name>`.
Finder _next(String option) => find.byKey(ValueKey('next/$option'));

Finder _inPicker(Finder matching) =>
    find.descendant(of: find.byType(DevicePickerCard), matching: matching);

Finder _inCards(Finder matching) =>
    find.descendant(of: find.byType(SessionCard), matching: matching);

Finder _inTitle(Finder matching) =>
    find.descendant(of: find.byType(AppBar), matching: matching);

void main() {
  late SettingsService settings;
  late _Adb adb;
  late _Hub hub;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    adb = _Adb();
    hub = Get.put<BaseConnectionManager>(_Hub(adb)) as _Hub;
  });

  tearDown(Get.reset);

  /// Home with the real translations, starting in English. A new HomeView
  /// each time (not a const one), so pumping it again rebuilds the tree.
  Widget app() => GetMaterialApp(
    translations: AppTranslations(),
    locale: const Locale('en'),
    fallbackLocale: const Locale('en'),
    // ignore: prefer_const_constructors
    home: HomeView(),
  );

  /// A session for the tablet `SERIAL-<letter>`, made as [choice] (none:
  /// it follows the settings) and not yet the hub's.
  HostSession tablet(
    String letter, {
    SessionChoice? choice,
    ConnectionPhase phase = ConnectionPhase.streaming,
  }) {
    final device = _device(
      'SERIAL-$letter',
      'A rather long tablet model '
          'name $letter',
    );
    return HostSession(
        key: device.serial,
        link: LinkType.usb,
        serial: device.serial,
        choice: choice,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      )
      ..activeDevice.value = device
      ..phase.value = phase;
  }

  /// A route's transition, and whatever a frame callback scheduled.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Home over [count] live tablets, `SERIAL-A`, `SERIAL-B`, … (the first
  /// one focused), all attached, each made as [choice]. With [routed], Home
  /// is the app's `/home` route, as in the app (the remote view opens by
  /// itself only from there), and `/remote-host` a stand-in page with the
  /// remote view's own controller; [routed] hears the pushes.
  Future<List<HostSession>> start(
    WidgetTester tester,
    int count, {
    bool permissions = false,
    bool translated = false,
    SessionChoice? choice,
    NavigatorObserver? routed,
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _permissions,
      (_) async => {
        'screen_recording': permissions,
        'accessibility': permissions,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(_permissions, null));
    final sessions = <HostSession>[];
    final devices = <DeviceModel>[];
    for (var i = 0; i < count; i++) {
      final session = tablet(String.fromCharCode(0x41 + i), choice: choice);
      devices.add(session.activeDevice.value!);
      hub.sessions[session.key] = session;
      sessions.add(session);
    }
    if (sessions.isNotEmpty) hub.adopt(sessions.first);
    adb.devices = devices;
    hub.availableDevices.value = devices;
    if (routed != null) {
      await tester.pumpWidget(
        GetMaterialApp(
          initialRoute: AppRoutes.home,
          navigatorObservers: [routed],
          getPages: [
            GetPage(
              name: AppRoutes.home,
              page: () => const HomeView(),
              binding: BindingsBuilder(() {
                Get.put(HomeController());
              }),
            ),
            GetPage(
              name: AppRoutes.remoteHost,
              page: () => const Scaffold(body: Text('remote view')),
              binding: BindingsBuilder(() {
                Get.put(RemoteGridController());
              }),
            ),
            GetPage(
              name: AppRoutes.settings,
              page: () => const Scaffold(body: Text('settings')),
            ),
          ],
        ),
      );
      await settle(tester);
      return sessions;
    }
    Get.put(HomeController());
    await tester.pumpWidget(
      translated ? app() : const GetMaterialApp(home: HomeView()),
    );
    await tester.pump();
    await tester.pump();
    return sessions;
  }

  testWidgets('two tablets: a card each, and the title says how many', (
    tester,
  ) async {
    // Tall enough for both cards and the add panel below them.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester, 2);

    expect(find.byType(SessionCard), findsNWidgets(2));
    expect(find.text('home_appbar_tablets'), findsOneWidget);
    expect(
      _inCards(find.text('session_extended_label')),
      findsNWidgets(2),
      reason: "each card's mode chip",
    );
    expect(
      _inTitle(find.text('session_extended_label')),
      findsNothing,
      reason: 'the title no longer shows a mode',
    );
    expect(find.text('home_all_attached_connected'), findsOneWidget);
    // The mode of the next tablet is offered once, in the add panel; the
    // cards' own modes are theirs. The link is every tablet's: not now.
    expect(find.text('session_extended_desc'), findsOneWidget);
    expect(_inPicker(find.text('session_extended_desc')), findsOneWidget);
    expect(_inPicker(find.text('home_next_tablet_mode')), findsOneWidget);
    expect(find.text('link_usb_desc'), findsNothing);
  });

  testWidgets("one tablet: today's Home, with its card in place of the "
      'connection card', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 1);

    expect(find.byType(SessionCard), findsOneWidget);
    expect(find.text('perm_required_title'), findsOneWidget);
    // The title shows the session's mode, as before, and so does the card.
    expect(_inTitle(find.text('session_extended_label')), findsOneWidget);
    expect(_inCards(find.text('session_extended_label')), findsOneWidget);
    expect(find.text('home_appbar_tablets'), findsNothing);
    expect(find.text('link_usb_desc'), findsNothing, reason: 'live');
    // What the next tablet would run as is in the add panel all along.
    expect(_inPicker(_next('mode/extendedScreen')), findsOneWidget);
    expect(_inPicker(_next('mode/remoteControl')), findsOneWidget);

    // Waiting to retry is idle: the link selector is back.
    sessions[0]
      ..retryPending.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();
    expect(find.text('link_usb_desc'), findsOneWidget);
    expect(_inPicker(find.text('link_usb_desc')), findsNothing);
    expect(_action('SERIAL-A', 'common_cancel'), findsOneWidget);
    expect(_inPicker(_next('mode/extendedScreen')), findsOneWidget);
  });

  testWidgets("a card's Disconnect ends that tablet alone", (tester) async {
    await start(tester, 2);

    await tester.tap(_action('SERIAL-A', 'common_disconnect'));
    await tester.pump();

    expect(hub.stops, [('SERIAL-A', true)]);
    expect(hub.disconnects, 0, reason: 'the other tablet runs on');
    expect(hub.autoConnectPaused.value, isFalse);
  });

  testWidgets('a refused tablet offers Retry, which connects it again', (
    tester,
  ) async {
    final sessions = await start(tester, 2, permissions: true);
    final b = sessions[1];
    b.errorMessage.value = const CaptureLimit().toString();
    b.errorKey.value = 'error_encode_limit';
    b.refused.value = true;
    b.phase.value = ConnectionPhase.error;
    await tester.pump();

    expect(find.text('common_retry'), findsOneWidget);
    expect(find.text('error_encode_limit'), findsOneWidget);
    await tester.tap(_action('SERIAL-B', 'common_retry'));
    await tester.pump();
    await tester.pump();
    expect(hub.connects, ['SERIAL-B']);

    // Or it is ended: its card, and its place under the cap, need not stay
    // until another tablet leaves.
    expect(_action('SERIAL-B', 'common_cancel'), findsOneWidget);
    await tester.tap(_action('SERIAL-B', 'common_cancel'));
    await tester.pump();
    expect(hub.stops, [('SERIAL-B', true)]);
    hub.stops.clear();

    // A retry already armed is stopped by Cancel.
    b.refused.value = false;
    b.retryPending.value = true;
    await tester.pump();
    await tester.tap(_action('SERIAL-B', 'common_cancel'));
    await tester.pump();
    expect(hub.stops, [('SERIAL-B', true)]);
  });

  testWidgets('a tablet waiting out its retry offers Retry, which runs the '
      'retry now, beside Cancel', (tester) async {
    final sessions = await start(tester, 2, permissions: true);
    final b = sessions[1];
    b.errorMessage.value = const LinkError('error_usb_unverified_client')
        .toString();
    b.errorKey.value = 'error_usb_unverified_client';
    b.retryPending.value = true;
    b.phase.value = ConnectionPhase.error;
    await tester.pump();

    expect(_action('SERIAL-B', 'common_cancel'), findsOneWidget);
    await tester.tap(_action('SERIAL-B', 'common_retry'));
    await tester.pump();
    await tester.pump();
    expect(hub.connects, ['SERIAL-B']);
    expect(hub.stops, isEmpty);
  });

  // With one tablet at a time (Maximum tablets 1; the mode no longer makes
  // it so), whatever the mode.
  for (final remote in [false, true]) {
    testWidgets('with Maximum tablets 1'
        '${remote ? ', in remote control' : ''}, while a Disconnect of every '
        'tablet still runs, the freed tablet is not short of room, and there '
        'is nothing to disconnect', (tester) async {
      await settings.setMaxTablets(1);
      if (remote) {
        await settings.setSessionMode(SessionMode.remoteControl);
        await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      }
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1);
      expect(hub.cap, 1);

      // The remote view's Disconnect: the session is out of the hub at
      // once, while the facade still reads its phase until the end.
      hub.endingAll.value = true;
      hub.sessions.remove('SERIAL-A');
      await tester.pump();
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(find.text('home_disconnecting'), findsOneWidget);
      expect(find.text('home_at_limit'), findsNothing);
      expect(find.text('common_disconnect'), findsNothing);

      hub.endingAll.value = false;
      hub.phase.value = ConnectionPhase.disconnected;
      await tester.pump();
      expect(find.text('home_disconnecting'), findsNothing);
      expect(find.text('home_at_limit'), findsNothing);
    });
  }

  group('the mode of the next tablet', () {
    const extra = DeviceModel(
      serial: 'SERIAL-X',
      model: 'Tablet X',
      status: DeviceStatus.connected,
    );

    Finder inPicker(Finder matching) => find.descendant(
      of: find.byType(DevicePickerCard),
      matching: matching,
    );

    /// Whether the add panel's tile for [extra] can be pressed.
    bool tileEnabled(WidgetTester tester) => tester
        .widget<InkWell>(
          find
              .ancestor(
                of: inPicker(find.text('Tablet X')),
                matching: find.byType(InkWell),
              )
              .first,
        )
        .onTap !=
        null;

    /// One more tablet attached, with no session.
    Future<void> attachExtra(WidgetTester tester) async {
      hub.availableDevices.value = [...hub.availableDevices, extra];
      await tester.pump();
    }

    /// Something already takes all of a tiny encoder.
    void fillEncoder() {
      hub.budget.estimate = const EncoderEstimate(
        engines: 1,
        h264PerEngine: 1,
        h265PerEngine: 1,
      );
      hub.budget.admit(999, DisplayConfigModel.defaultConfig, cap: 8);
    }

    testWidgets('a tablet the Mac would only view needs a place, not room on '
        'the encoder: with the encoder full its tile stays enabled, while '
        "one to extend onto can't be added", (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1);
      fillEncoder();
      await attachExtra(tester);
      expect(hub.canAdd, isTrue);

      // Extended screen: the Mac would have to encode for it.
      expect(settings.nextChoice.isReverse, isFalse);
      expect(inPicker(find.text('home_at_limit')), findsOneWidget);
      expect(tileEnabled(tester), isFalse);

      // Tablet drives the Mac: the Mac encodes for that one too.
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      await tester.pump();
      expect(inPicker(find.text('home_at_limit')), findsOneWidget);
      expect(tileEnabled(tester), isFalse);

      // Mac controls the tablet: the tablet encodes.
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      await tester.pump();
      expect(inPicker(find.text('home_at_limit')), findsNothing);
      expect(tileEnabled(tester), isTrue);
    });

    testWidgets('pressing a tile connects that tablet in the mode chosen '
        'for the next one', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      await start(
        tester,
        1,
        permissions: true,
        choice: const SessionChoice(SessionMode.extendedScreen),
      );
      await attachExtra(tester);

      await tester.tap(inPicker(find.text('Tablet X')));
      await tester.pump();
      await tester.pump();
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_reverse]);
    });

    testWidgets('a press on the tile of a tablet the user stopped lifts the '
        'stop, and the pause, only as it connects: not when it ends in '
        'Settings for the permissions, and not while they are asked about', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Screen Recording and Accessibility are missing.
      await start(tester, 1, routed: _Pushes());
      await attachExtra(tester);
      hub.stoppedDevices.add('SERIAL-X');
      hub.pauseAutoConnect();

      await tester.tap(inPicker(find.text('Tablet X')));
      await settle(tester);
      expect(Get.currentRoute, AppRoutes.settings);
      expect(hub.connects, isEmpty);
      expect(
        hub.stoppedDevices,
        {'SERIAL-X'},
        reason: 'nothing was connected: the tablet is still stopped',
      );
      expect(hub.autoConnectPaused.value, isTrue);
      // Back to Home, the message about the permissions going with it.
      Get.back<void>(closeOverlays: true);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(Get.currentRoute, AppRoutes.home);

      // Granted now, the answer to the next check held back.
      final answer = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_permissions, (_) async {
            await answer.future;
            return {'screen_recording': true, 'accessibility': true};
          });
      await tester.tap(inPicker(find.text('Tablet X')));
      await tester.pump();
      await tester.pump();
      // An automatic connect that looks now still finds a stopped tablet;
      // lifted here already, it connected the tablet as it was remembered
      // and the pick itself was refused.
      expect(hub.connects, isEmpty);
      expect(hub.stoppedDevices, {'SERIAL-X'});
      expect(hub.autoConnectPaused.value, isTrue);

      answer.complete();
      await tester.pump();
      await tester.pump();
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_extended]);
      expect(hub.stoppedDevices, isEmpty);
      expect(hub.autoConnectPaused.value, isFalse);
    });

    testWidgets('in remote control a second tablet can be added beside the '
        'first: no tile says one at a time', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      await start(tester, 1, translated: true);
      await attachExtra(tester);
      expect(hub.cap, greaterThan(1));

      expect(tileEnabled(tester), isTrue);
      expect(find.text('home_remote_single'), findsNothing);
      final texts = tester
          .widgetList<Text>(inPicker(find.byType(Text)))
          .map((t) => t.data)
          .toList();
      for (final locale in ['en', 'th']) {
        final map = AppTranslations().keys[locale]!;
        expect(map.containsKey('home_remote_single'), isFalse);
        expect(texts, isNot(contains(map['home_at_limit'])));
      }
    });

    testWidgets('the mode selectors sit in the add panel whatever the '
        "tablets are doing, never above the cards; they change nothing a "
        'tablet runs as, the link selector keeps its rule, and the title '
        "shows the tablet's own mode", (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 1, choice: _reverse);
      // The selectors say something else.
      expect(settings.nextChoice.mode, SessionMode.extendedScreen);
      final title = _inTitle(
        find.text('session_remote_label · remote_dir_mac_label'),
      );
      final chip = _inCards(
        find.text('session_remote_label · remote_dir_mac_label'),
      );

      /// Mode and direction are offered once, inside the add panel, below
      /// the card.
      void selectorsInPanel({required bool direction}) {
        expect(_inPicker(find.text('home_next_tablet_mode')), findsOneWidget);
        for (final text in ['session_extended_desc', 'session_remote_desc']) {
          expect(find.text(text), findsOneWidget);
          expect(_inPicker(find.text(text)), findsOneWidget);
        }
        expect(
          find.text('remote_dir_title'),
          direction ? findsOneWidget : findsNothing,
        );
        expect(
          _inPicker(find.text('remote_dir_title')),
          direction ? findsOneWidget : findsNothing,
        );
      }

      expect(title, findsOneWidget);
      expect(chip, findsOneWidget);
      selectorsInPanel(direction: false);
      expect(
        tester.getTopLeft(_next('mode/extendedScreen')).dy,
        greaterThan(tester.getBottomLeft(_card('SERIAL-A')).dy),
      );
      expect(find.text('link_usb_desc'), findsNothing, reason: 'live');

      // Moving them while the tablet is live asks nothing of the hub and
      // changes nothing the tablet runs as: its title and chip stay.
      await tester.tap(_next('mode/remoteControl'));
      await tester.pump();
      selectorsInPanel(direction: true);
      await tester.tap(_next('dir/tabControlsMac'));
      await tester.pump();
      expect(settings.nextChoice, _driving);
      expect(sessions[0].effectiveChoice, _reverse);
      expect(title, findsOneWidget);
      expect(chip, findsOneWidget);
      expect(hub.modeChanges, isEmpty);
      expect(hub.connects, isEmpty);
      expect(hub.stops, isEmpty);
      await tester.tap(_next('mode/extendedScreen'));
      await tester.pump();
      selectorsInPanel(direction: false);

      // Waiting to retry: the link may be changed too.
      sessions[0]
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();
      expect(find.text('link_usb_desc'), findsOneWidget);
      selectorsInPanel(direction: false);
      expect(title, findsOneWidget);

      // Connecting again: still there.
      sessions[0]
        ..retryPending.value = false
        ..phase.value = ConnectionPhase.handshaking;
      await tester.pump();
      expect(find.text('link_usb_desc'), findsNothing);
      selectorsInPanel(direction: false);

      // With no tablet the title follows them.
      hub.sessions.remove('SERIAL-A');
      hub.phase.value = ConnectionPhase.disconnected;
      await tester.pump();
      selectorsInPanel(direction: false);
      expect(find.text('link_usb_desc'), findsOneWidget);
      expect(title, findsNothing);
      expect(_inTitle(find.text('session_extended_label')), findsOneWidget);
      await tester.tap(_next('mode/remoteControl'));
      await tester.pump();
      expect(_inTitle(find.text('session_remote_label')), findsOneWidget);
    });

    testWidgets('a tile of a tablet the Mac has had before says what it ran '
        'as last time; pressing it still asks for the mode chosen above '
        'the tiles', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const fresh = DeviceModel(
        serial: 'SERIAL-Y',
        model: 'Tablet Y',
        status: DeviceStatus.connected,
      );
      await settings.rememberDevice(
        extra.serial,
        model: extra.model,
        vdSerial: 7,
        choice: _reverse,
      );
      await start(tester, 1, permissions: true, translated: true);
      hub.availableDevices.value = [...hub.availableDevices, extra, fresh];
      await tester.pump();

      String text(String locale, String key) =>
          AppTranslations().keys[locale]![key]!;
      String last(String locale) => text(locale, 'home_tile_last_mode')
          .replaceAll(
            '@mode',
            '${text(locale, 'session_remote_label')} · '
                '${text(locale, 'remote_dir_mac_label')}',
          );
      final known = find.byKey(const ValueKey('device/SERIAL-X'));
      final unknown = find.byKey(const ValueKey('device/SERIAL-Y'));
      expect(last('en'), 'Last time: Remote Control · Mac → Tablet');
      expect(
        find.descendant(of: known, matching: find.text(last('en'))),
        findsOneWidget,
      );
      // A tablet never connected has nothing to say, nor does a card.
      expect(find.text(last('en')), findsOneWidget);
      expect(
        find.descendant(
          of: unknown,
          matching: find.textContaining('Last time'),
        ),
        findsNothing,
      );

      // The press is the user's, with the selector in front of them.
      expect(settings.nextChoice, _extended);
      await tester.tap(known);
      await tester.pump();
      await tester.pump();
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_extended]);
      expect(settings.knownChoice('SERIAL-X'), _reverse, reason: 'not yet');

      Get.locale = const Locale('th');
      await tester.pumpWidget(app());
      await tester.pump();
      expect(
        find.descendant(of: known, matching: find.text(last('th'))),
        findsOneWidget,
      );
      expect(find.text(last('en')), findsNothing);
    });
  });

  testWidgets("the add panel's header counts places in use, not tablets "
      'connected: a refused tablet holds one too', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 2, translated: true);
    sessions[1]
      ..refused.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();

    final header = AppTranslations().keys['en']!['home_tablets_count']!
        .replaceAll('@n', '2')
        .replaceAll('@cap', '${hub.cap}');
    expect(header, isNot(contains('connected')));
    expect(find.textContaining(header), findsOneWidget);
  });

  testWidgets('while a tablet is between two sessions, its mode being '
      'changed, Home offers no link selector (the hub would act on no '
      'switch), counts its place, and does not say that no device is '
      'attached', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 2, translated: true);
    final en = AppTranslations().keys['en']!;
    String count(int n) => en['home_tablets_count']!
        .replaceAll('@n', '$n')
        .replaceAll('@cap', '${hub.cap}');
    final link = find.text(en['link_usb_desc']!);

    // A waits to retry, which is idle. B's old session has left the map.
    sessions[0]
      ..retryPending.value = true
      ..phase.value = ConnectionPhase.error;
    hub.sessions.remove('SERIAL-B');
    await tester.pump();
    expect(link, findsOneWidget, reason: 'one idle tablet, as ever');
    expect(find.textContaining(count(1)), findsOneWidget);

    // The same, but B is on its way back in another mode.
    hub.between.add('SERIAL-B');
    await tester.pump();
    expect(link, findsNothing);
    expect(find.textContaining(count(2)), findsOneWidget);
    expect(find.byKey(const ValueKey('device/SERIAL-B')), findsNothing);
    expect(_card('SERIAL-A'), findsOneWidget);

    // A is unplugged and its card let go of meanwhile: no session at all,
    // the hub idle as far as its phase goes, and B the one tablet listed.
    sessions[0].phase.value = ConnectionPhase.disconnected;
    hub.sessions.remove('SERIAL-A');
    hub.availableDevices.removeWhere((d) => d.serial == 'SERIAL-A');
    await tester.pump();
    expect(hub.phase.value, ConnectionPhase.disconnected);
    expect(find.byType(SessionCard), findsNothing);
    expect(link, findsNothing);
    expect(find.textContaining(count(1)), findsOneWidget);
    expect(find.text(en['home_all_attached_connected']!), findsOneWidget);
    expect(find.text(en['device_none_detected']!), findsNothing);

    // B is back: Home's usual rule again.
    hub.between.clear();
    await tester.pump();
    expect(link, findsOneWidget);
  });

  testWidgets("the encoder's load follows a capacity the hub learned, with "
      'nothing else changing', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 2, translated: true);
    final a = sessions.first;
    // One Tab S10 Ultra alone at 120 fps with H.265 on an M3 Pro: past the
    // estimate.
    hub.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');
    final config = EncodePreset.max.configFor(
      const ClientPanel(2960, 1848, 120),
      mode: DisplayMode.extend,
      codec: CodecType.h265,
    );
    a.granted.value = const GrantedCapture(
      width: 2960,
      height: 1848,
      fps: 120,
      shared: false,
    );
    a.captured.value = const CaptureStart(displayId: 5);
    hub.budget.admit(a.nativeId, config, cap: 4);
    await tester.pump();
    expect(find.textContaining('encoder 119% (H.265)'), findsOneWidget);

    // Ten seconds healthy at its ceiling, its encoder handing back every
    // frame of a changing screen: the hub learns, and Home says so.
    for (var second = 0; second < 11; second++) {
      hub.encoderStats(a.nativeId, 120, 60);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(hub.budget.isLearned(CodecType.h265), isTrue);
    expect(find.textContaining('encoder 85% (H.265)'), findsOneWidget);

    // Nothing left to measure: no window outlives the test.
    hub.budget.release(a.nativeId);
    expect(hub.measuringCapacity, isFalse);
  });

  testWidgets('a press overtaken by a phase change does nothing', (
    tester,
  ) async {
    final sessions = await start(tester, 2);

    final touch = await tester.startGesture(
      tester.getCenter(_action('SERIAL-A', 'common_disconnect')),
    );
    // The link failed before the finger came up: the button now reads
    // Cancel (a retry is pending).
    sessions[0]
      ..retryPending.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();
    expect(_action('SERIAL-A', 'common_cancel'), findsOneWidget);
    await touch.up();
    await tester.pump();

    expect(hub.stops, isEmpty);
    expect(hub.connects, isEmpty);
  });

  testWidgets('tapping a card focuses its tablet', (tester) async {
    await start(tester, 2);
    expect(hub.focused?.key, 'SERIAL-A');

    await tester.tap(
      find.descendant(of: _card('SERIAL-B'), matching: find.text('SERIAL-B')),
    );
    await tester.pump();

    expect(hub.focused?.key, 'SERIAL-B');
    expect(hub.focusedKey.value, 'SERIAL-B');
    expect(hub.stops, isEmpty);
  });

  group('the remote view', () {
    /// The card's Open remote button.
    Finder openRemote(String key) => find.descendant(
      of: _card(key),
      matching: find.text('home_open_remote'),
    );

    /// Back out of the remote view, to Home.
    Future<void> back(WidgetTester tester) async {
      Get.back<void>();
      await settle(tester);
      expect(Get.currentRoute, AppRoutes.home);
    }

    testWidgets("a card's Open remote opens the view on that tablet's tile, "
        'and leaves the focus where it was', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pushes = _Pushes();
      await start(tester, 2, choice: _reverse, routed: pushes);
      expect(hub.reverseActive.value, 2);

      // Both were live when Home opened: the view came up by itself, on
      // every tile.
      expect(Get.currentRoute, AppRoutes.remoteHost);
      expect(pushes.arguments, [null]);
      expect(Get.find<RemoteGridController>().expanded.value, isNull);
      await back(tester);
      expect(hub.focused?.key, 'SERIAL-A');

      await tester.tap(openRemote('SERIAL-B'));
      await settle(tester);

      expect(Get.currentRoute, AppRoutes.remoteHost);
      expect(pushes.arguments, [
        null,
        {'focus': 'SERIAL-B'},
      ]);
      // The view's own controller took it: B's tile alone.
      final grid = Get.find<RemoteGridController>();
      expect(grid.tiles.map((t) => t.key), ['SERIAL-A', 'SERIAL-B']);
      expect(grid.expanded.value, 'SERIAL-B');
      // The hub shows the tablet it showed, and nothing was started or
      // stopped for it.
      expect(hub.focused?.key, 'SERIAL-A');
      expect(hub.focusedKey.value, 'SERIAL-A');
      expect(hub.connects, isEmpty);
      expect(hub.stops, isEmpty);

      // Asked again with the view open: no second route, only the tile.
      Get.find<HomeController>().onOpenRemoteView(key: 'SERIAL-A');
      await settle(tester);
      expect(pushes.remote, 2);
      expect(grid.expanded.value, 'SERIAL-A');
      Get.find<HomeController>().onOpenRemoteView();
      await settle(tester);
      expect(pushes.remote, 2);
      expect(grid.expanded.value, 'SERIAL-A', reason: 'no tile named');
      expect(hub.focused?.key, 'SERIAL-A');
    });

    testWidgets('a second tablet the Mac controls going live while the view '
        'is open joins it, and opens nothing', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pushes = _Pushes();
      final a = (await start(tester, 1, choice: _reverse, routed: pushes)).single;
      expect(Get.currentRoute, AppRoutes.remoteHost);
      expect(pushes.remote, 1);

      // The second one connects, then goes live.
      final b = tablet(
        'B',
        choice: _reverse,
        phase: ConnectionPhase.handshaking,
      );
      hub.sessions[b.key] = b;
      await settle(tester);
      expect(hub.reverseActive.value, 1);
      b.phase.value = ConnectionPhase.streaming;
      await settle(tester);
      expect(hub.reverseActive.value, 2);
      expect(pushes.remote, 1);
      expect(Get.currentRoute, AppRoutes.remoteHost);
      expect(Get.find<RemoteGridController>().tiles.map((t) => t.key), [
        'SERIAL-A',
        'SERIAL-B',
      ]);

      // Back on Home, its link drops and comes back: still not the first.
      await back(tester);
      b.phase.value = ConnectionPhase.error;
      await settle(tester);
      b.phase.value = ConnectionPhase.streaming;
      await settle(tester);
      expect(hub.reverseActive.value, 2);
      expect(pushes.remote, 1);
      expect(Get.currentRoute, AppRoutes.home);

      // Every one of them down, then one back: the view opens again, as
      // it does for a lone tablet whose link was retried.
      a.phase.value = ConnectionPhase.error;
      b.phase.value = ConnectionPhase.error;
      await settle(tester);
      expect(hub.reverseActive.value, 0);
      expect(pushes.remote, 1);
      a.phase.value = ConnectionPhase.streaming;
      await settle(tester);
      expect(pushes.remote, 2);
      expect(pushes.arguments.last, isNull);
      expect(Get.currentRoute, AppRoutes.remoteHost);
    });

    testWidgets('an Extended tablet going live beside the selectors set to '
        'Mac controls tablet opens nothing, and its card has no button', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pushes = _Pushes();
      final sessions = await start(
        tester,
        1,
        choice: const SessionChoice(SessionMode.extendedScreen),
        routed: pushes,
      );
      // What the next tablet would run as, picked while this one waits to
      // retry.
      sessions[0]
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      expect(settings.isReverseRemote, isTrue);
      await settle(tester);

      // The hub shows this session, so its own phase goes live with it.
      sessions[0]
        ..retryPending.value = false
        ..phase.value = ConnectionPhase.streaming;
      await settle(tester);
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(hub.reverseActive.value, 0);
      expect(pushes.remote, 0);
      expect(Get.currentRoute, AppRoutes.home);
      expect(find.text('home_open_remote'), findsNothing);
    });
  });

  group("a card's mode menu", () {
    /// Opens [key]'s menu.
    Future<void> open(WidgetTester tester, String key) async {
      await tester.tap(_modeMenu(key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// Presses [choice] in [key]'s open menu, and lets the menu close and
    /// Home ask about the permissions.
    Future<void> choose(
      WidgetTester tester,
      String key,
      SessionChoice choice,
    ) async {
      await tester.tap(_modeItem(key, choice));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    /// Closes an open menu without picking.
    Future<void> dismiss(WidgetTester tester) async {
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// [choice]'s item in [key]'s open menu: the checked one, which says
    /// nothing more, or one that carries [hint].
    void expectItem(
      WidgetTester tester,
      String key,
      SessionChoice choice, {
      String? hint,
    }) {
      final found = _modeItem(key, choice);
      expect(found, findsOneWidget);
      expect(
        find.descendant(of: found, matching: find.byIcon(Icons.check)),
        hint == null ? findsOneWidget : findsNothing,
        reason: '$choice',
      );
      expect(
        tester
            .widgetList<Text>(
              find.descendant(of: found, matching: find.byType(Text)),
            )
            .map((text) => text.data),
        [choice.label, ?hint],
        reason: '$choice',
      );
      expect(
        tester.widget<PopupMenuItem<SessionChoice>>(found).enabled,
        hint != null,
        reason: '$choice',
      );
    }

    testWidgets('one tablet waiting to retry: moving the add panel\'s '
        'selector alone changes nothing it runs as, and its card\'s menu '
        'asks the hub to change that very session to Mac controls tablet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // No permissions: a tablet the Mac only views needs none.
      final s = (await start(tester, 1, choice: _extended)).single;
      s
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();

      // What used to change a waiting tablet's mode: the selector.
      await tester.tap(_next('mode/remoteControl'));
      await tester.pump();
      await tester.tap(_next('dir/macControlsTab'));
      await tester.pump();
      expect(settings.nextChoice, _reverse);
      expect(hub.modeChanges, isEmpty);
      expect(hub.connects, isEmpty);
      expect(s.choice, _extended);
      expect(s.spec.mode, SessionMode.extendedScreen);
      expect(s.spec.isReverseRemote, isFalse);
      expect(_inCards(find.text('session_extended_label')), findsOneWidget);
      expect(_inTitle(find.text('session_extended_label')), findsOneWidget);
      // Nor does its Retry take the selector's mode: it runs the session
      // there is (the hub's connect keeps an existing session's choice).
      expect(hub.sessions['SERIAL-A'], same(s));

      // What changes it now: its own card's menu.
      await open(tester, 'SERIAL-A');
      await choose(tester, 'SERIAL-A', _reverse);
      expect(hub.modeChanges, [('SERIAL-A', _reverse, s)]);
      expect(hub.connects, isEmpty, reason: 'the hub replaces it itself');
      expect(hub.stops, isEmpty);
      expect(hub.disconnects, 0);
    });

    testWidgets('the menu offers every mode: the one the tablet runs as is '
        'checked and cannot be pressed, the others say what the change '
        "asks of the tablet's user", (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 2, permissions: true);
      // A extends; B is one the Mac controls.
      final b = tablet('B', choice: _reverse);
      hub.sessions['SERIAL-B'] = b;
      await tester.pump();
      expect(sessions[0].effectiveChoice.sameEffect(_extended), isTrue);
      expect(find.byTooltip('session_change_mode'), findsNWidgets(2));

      await open(tester, 'SERIAL-A');
      expectItem(tester, 'SERIAL-A', _extended);
      expectItem(
        tester,
        'SERIAL-A',
        _driving,
        hint: 'session_mode_hint_restart',
      );
      expectItem(
        tester,
        'SERIAL-A',
        _reverse,
        hint: 'session_mode_hint_to_reverse',
      );
      // Only this tablet's items are up.
      expect(_modeItem('SERIAL-B', _extended), findsNothing);
      // The checked one does nothing.
      await tester.tap(_modeItem('SERIAL-A', _extended));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(hub.modeChanges, isEmpty);
      expect(_modeItem('SERIAL-A', _extended), findsOneWidget);
      await dismiss(tester);
      expect(_modeItem('SERIAL-A', _extended), findsNothing);
      expect(hub.modeChanges, isEmpty);

      await open(tester, 'SERIAL-B');
      expectItem(tester, 'SERIAL-B', _reverse);
      for (final other in [_extended, _driving]) {
        expectItem(
          tester,
          'SERIAL-B',
          other,
          hint: 'session_mode_hint_from_reverse',
        );
      }
      await choose(tester, 'SERIAL-B', _driving);
      expect(hub.modeChanges, [('SERIAL-B', _driving, b)]);
      expect(hub.stops, isEmpty, reason: 'the other tablet is not touched');
    });

    testWidgets('opening a menu, or picking from it, focuses nothing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 2);
      expect(hub.focused?.key, 'SERIAL-A');

      await open(tester, 'SERIAL-B');
      expect(hub.focused?.key, 'SERIAL-A');
      await choose(tester, 'SERIAL-B', _reverse);
      expect(hub.modeChanges, [('SERIAL-B', _reverse, sessions[1])]);
      expect(hub.focused?.key, 'SERIAL-A');
      expect(hub.focusedKey.value, 'SERIAL-A');
    });

    testWidgets('a menu opened before its tablet got another session under '
        'the same key changes nothing', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = (await start(tester, 1, choice: _extended)).single;

      await open(tester, 'SERIAL-A');
      expect(_modeItem('SERIAL-A', _reverse), findsOneWidget);
      // Meanwhile the hub replaces the session (a change asked elsewhere,
      // or a pick): the card now holds the new one, the menu is still up.
      final renewed = tablet('A', choice: _driving);
      hub.sessions['SERIAL-A'] = renewed;
      await tester.pump();
      expect(
        _inCards(find.text('session_remote_label · remote_dir_tab_label')),
        findsOneWidget,
      );
      expect(_modeItem('SERIAL-A', _reverse), findsOneWidget);

      await choose(tester, 'SERIAL-A', _reverse);
      expect(hub.modeChanges, isEmpty);
      expect(hub.sessions['SERIAL-A'], same(renewed));
      expect(old.choice, _extended);

      // And with the tablet's session gone altogether.
      await open(tester, 'SERIAL-A');
      hub.sessions.remove('SERIAL-A');
      await tester.pump();
      expect(find.byType(SessionCard), findsNothing);
      await choose(tester, 'SERIAL-A', _reverse);
      expect(hub.modeChanges, isEmpty);

      // The controller itself asks the hub nothing for a session that is
      // not its tablet's.
      await Get.find<HomeController>().onSessionMode(old, _reverse);
      expect(hub.modeChanges, isEmpty);
    });

    testWidgets('a card has its menu while its tablet is live or waits in '
        'error, not while it connects, nor while every tablet is being '
        'disconnected', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 2);
      final a = sessions[0];
      expect(_modeMenu('SERIAL-A'), findsOneWidget);
      expect(_modeMenu('SERIAL-B'), findsOneWidget);

      for (final phase in ConnectionPhase.values) {
        a.phase.value = phase;
        await tester.pump();
        expect(
          _modeMenu('SERIAL-A'),
          phase.isActive || phase == ConnectionPhase.error
              ? findsOneWidget
              : findsNothing,
          reason: phase.name,
        );
        expect(_modeMenu('SERIAL-B'), findsOneWidget, reason: phase.name);
      }
      // Refused by the encoder, or waiting out a retry: both `error`.
      a
        ..refused.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();
      expect(_modeMenu('SERIAL-A'), findsOneWidget);

      hub.endingAll.value = true;
      await tester.pump();
      expect(_modeMenu('SERIAL-A'), findsNothing);
      expect(_modeMenu('SERIAL-B'), findsNothing);
      hub.endingAll.value = false;
      await tester.pump();
      expect(_modeMenu('SERIAL-B'), findsOneWidget);
    });

    testWidgets('a press on the menu button overtaken by the tablet starting '
        'to connect opens nothing', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = (await start(tester, 1)).single;
      a
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();

      final touch = await tester.startGesture(
        tester.getCenter(_modeMenu('SERIAL-A')),
      );
      // Its retry fires before the finger comes up.
      a
        ..retryPending.value = false
        ..phase.value = ConnectionPhase.detectingDevice;
      await tester.pump();
      await touch.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(_modeItem('SERIAL-A', _reverse), findsNothing);
      expect(hub.modeChanges, isEmpty);
      expect(hub.stops, isEmpty, reason: 'nor was it the Cancel');
    });

    testWidgets('a change into a mode the Mac captures or takes input for '
        'asks for the permissions first; a tablet the Mac would only view '
        'needs none', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = (await start(
        tester,
        1,
        choice: _extended,
        routed: _Pushes(),
      )).single;
      expect(Get.currentRoute, AppRoutes.home);

      // Screen Recording and Accessibility are missing.
      await open(tester, 'SERIAL-A');
      await choose(tester, 'SERIAL-A', _driving);
      await settle(tester);
      expect(hub.modeChanges, isEmpty);
      expect(Get.currentRoute, AppRoutes.settings);
      // Back to Home, the message about the permissions going with it.
      Get.back<void>(closeOverlays: true);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(Get.currentRoute, AppRoutes.home);

      await open(tester, 'SERIAL-A');
      await choose(tester, 'SERIAL-A', _reverse);
      await settle(tester);
      expect(hub.modeChanges, [('SERIAL-A', _reverse, a)]);
      expect(Get.currentRoute, AppRoutes.home);
    });

    testWidgets('the new words, in English and in Thai', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1, choice: _driving, translated: true);

      for (final locale in ['en', 'th']) {
        final map = AppTranslations().keys[locale]!;
        if (locale == 'th') {
          Get.locale = const Locale('th');
          await tester.pumpWidget(app());
          await tester.pump();
        }
        final share = map['home_start_share']!;
        final toReverse = map['session_mode_hint_to_reverse']!
            .replaceAll('@share', share);
        final remote = map['session_remote_label']!;
        // The add panel's caption, the card's chip with its direction, the
        // menu's tooltip.
        expect(find.text(map['home_next_tablet_mode']!), findsOneWidget);
        expect(
          _inCards(find.text('$remote · ${map['remote_dir_tab_label']}')),
          findsOneWidget,
        );
        expect(find.byTooltip(map['session_change_mode']!), findsOneWidget);

        await open(tester, 'SERIAL-A');
        // The tablet's own button, by the name it has there.
        expect(toReverse, contains(share));
        expect(toReverse, isNot(contains('@')));
        expect(find.text(toReverse), findsOneWidget);
        expect(
          find.text(map['session_mode_hint_restart']!),
          findsOneWidget,
          reason: 'to Extended screen',
        );
        expect(
          find.text('$remote · ${map['remote_dir_mac_label']}'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await dismiss(tester);
      }
      final en = AppTranslations().keys['en']!;
      final th = AppTranslations().keys['th']!;
      for (final key in [
        'home_next_tablet_mode',
        'home_tile_last_mode',
        'session_change_mode',
        'session_mode_hint_restart',
        'session_mode_hint_to_reverse',
        'session_mode_hint_from_reverse',
      ]) {
        expect(en[key], isNotNull, reason: key);
        expect(th[key], isNotNull, reason: key);
        expect(th[key], isNot(en[key]), reason: key);
      }
      expect(
        en['session_mode_hint_from_reverse']!.replaceAll(
          '@open',
          en['home_open_view']!,
        ),
        'Restarts this tablet; then tap Open View on it',
      );
      expect(th['session_mode_hint_from_reverse'], contains('@open'));
      expect(th['home_tile_last_mode'], contains('@mode'));
    });
  });

  testWidgets('an unplugged tablet says so, in the language chosen', (
    tester,
  ) async {
    final sessions = await start(tester, 2, translated: true);
    final b = sessions[1];
    b.errorMessage.value = const LinkError('error_device_gone').toString();
    b.errorKey.value = 'error_device_gone';
    b.retryPending.value = true;
    b.phase.value = ConnectionPhase.error;
    await tester.pump();

    final en = AppTranslations().keys['en']!['session_unplugged']!;
    final th = AppTranslations().keys['th']!['session_unplugged']!;
    expect(find.text(en), findsOneWidget);

    // What the Settings language picker's Get.updateLocale does, but for
    // its rebuild of the whole app: that reassemble leaves a widget test's
    // scheduler mid-frame, so the tree is pumped again instead. Nothing the
    // card shows was stored in English.
    Get.locale = const Locale('th');
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text(th), findsOneWidget);
    expect(find.text(en), findsNothing);
  });

  testWidgets('three cards fit an 800 px window', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 3, translated: true);
    sessions[1]
      ..granted.value = const GrantedCapture(
        width: 2960,
        height: 1848,
        fps: 45,
        shared: true,
      )
      ..notice.value = 'error_extend_wrong_display';
    sessions[2]
      ..errorKey.value = 'error_usb_unverified_client'
      ..phase.value = ConnectionPhase.error;
    await tester.pump();

    expect(find.byType(SessionCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  // Narrower than that the card's top row used to run over its edge once
  // the chip named the direction too and a menu button followed it.
  for (final language in ['en', 'th']) {
    testWidgets("a card's top row fits a 560 px window with the longest "
        'mode on its chip, which is cut short there and whole in a wide '
        'window ($language)', (tester) async {
      tester.view.physicalSize = const Size(560, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Get.locale = Locale(language);
      final sessions = await start(
        tester,
        2,
        translated: true,
        choice: _reverse,
      );
      Get.locale = Locale(language);
      await tester.pumpWidget(app());
      sessions[1]
        ..errorKey.value = 'error_usb_unverified_client'
        ..phase.value = ConnectionPhase.error;
      await tester.pump();

      final words = AppTranslations().keys[language]!;
      final longest =
          '${words['session_remote_label']} · ${words['remote_dir_mac_label']}';
      bool cut(String key) => tester
          .renderObject<RenderParagraph>(
            find.descendant(of: _card(key), matching: find.text(longest)),
          )
          .didExceedMaxLines;
      expect(find.byType(SessionCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      for (final key in ['SERIAL-A', 'SERIAL-B']) {
        expect(cut(key), isTrue, reason: key);
        expect(_modeMenu(key), findsOneWidget, reason: key);
        // The tablet's name keeps some room beside the chips.
        expect(
          tester
              .getSize(
                find.descendant(
                  of: _card(key),
                  matching: find.textContaining('A rather long tablet'),
                ),
              )
              .width,
          greaterThanOrEqualTo(72),
          reason: key,
        );
      }

      // With room for it the chip says it all, as before.
      tester.view.physicalSize = const Size(1000, 1800);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(cut('SERIAL-A'), isFalse);
      expect(cut('SERIAL-B'), isFalse);
    });
  }

  testWidgets('three cards with the longest mode on their chips, the add '
      "panel's selectors and an open menu fit an 800 px window, in Thai", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await settings.setSessionMode(SessionMode.remoteControl);
    await settings.setRemoteDirection(RemoteDirection.macControlsTab);
    await settings.rememberDevice(
      'SERIAL-X',
      model: 'Tablet X',
      vdSerial: 7,
      choice: _reverse,
    );
    Get.locale = const Locale('th');
    final sessions = await start(tester, 3, translated: true, choice: _reverse);
    Get.locale = const Locale('th');
    await tester.pumpWidget(app());
    hub.availableDevices.value = [
      ...hub.availableDevices,
      _device('SERIAL-X', 'Tablet X'),
    ];
    sessions[2]
      ..errorKey.value = 'error_usb_unverified_client'
      ..phase.value = ConnectionPhase.error;
    await tester.pump();

    final th = AppTranslations().keys['th']!;
    final longest =
        '${th['session_remote_label']} · ${th['remote_dir_mac_label']}';
    expect(find.byType(SessionCard), findsNWidgets(3));
    expect(_inCards(find.text(longest)), findsNWidgets(3));
    expect(find.text(th['home_next_tablet_mode']!), findsOneWidget);
    expect(_inPicker(find.text(th['remote_dir_title']!)), findsOneWidget);
    expect(
      _inPicker(
        find.text(th['home_tile_last_mode']!.replaceAll('@mode', longest)),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(_modeMenu('SERIAL-C'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_modeItem('SERIAL-C', _extended), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Listen on Wi-Fi beside USB', () {
    /// The session beside the USB tablets, with no device on it.
    HostSession listener() => HostSession(
          key: HostConnectionManager.wifiKey,
          link: LinkType.wifi,
          beside: true,
          pipeline: hub.pipeline,
          adb: adb,
          socket: SocketService(),
        )..phase.value = ConnectionPhase.handshaking;

    testWidgets('a listener alone hides nothing: the link selector and the '
        'facade card stay, its own card says it waits, and it holds no place',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setWifiListen(true);
      await start(tester, 0, permissions: true);
      hub.sessions[HostConnectionManager.wifiKey] = listener();
      await tester.pump();

      expect(_card(HostConnectionManager.wifiKey), findsOneWidget);
      expect(_inCards(find.text('session_wifi_beside')), findsOneWidget);
      expect(_inCards(find.text('session_wifi_waiting')), findsOneWidget);
      expect(find.text('link_usb_desc'), findsOneWidget,
          reason: 'a listener is under way for nobody');
      expect(hub.heldPlaces, isEmpty);
      expect(_inPicker(_next('wifi-listen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets("the add panel's switch turns listening on and off, and is "
        'off with room for one tablet only', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1, permissions: true);
      final toggle = find.descendant(
          of: _next('wifi-listen'), matching: find.byType(Switch));
      expect(tester.widget<Switch>(toggle).value, isFalse);

      await tester.tap(toggle);
      // The permissions are asked about first; then the switch moves.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.wifiListen, isTrue);
      expect(tester.widget<Switch>(toggle).value, isTrue);

      await settings.setMaxTablets(1);
      await tester.pump();
      expect(tester.widget<Switch>(toggle).onChanged, isNull);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.text('home_wifi_listen_needs_two'), findsOneWidget);
    });

    testWidgets("a listener's Cancel turns listening off rather than stopping "
        'a tablet', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setWifiListen(true);
      await start(tester, 1, permissions: true);
      hub.sessions[HostConnectionManager.wifiKey] = listener();
      await tester.pump();

      await tester.tap(_action(HostConnectionManager.wifiKey, 'common_cancel'));
      await tester.pump();
      expect(settings.wifiListen, isFalse);
      // The hub ends it for the switch, and stops no tablet: it is not
      // put among the ones the user stopped.
      expect(hub.stops, [(HostConnectionManager.wifiKey, false)]);
    });
  });
}
