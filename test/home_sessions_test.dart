import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
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
import 'package:extendedscreen/shared/widgets/add_device_panel.dart';
import 'package:extendedscreen/shared/widgets/device_card.dart';
import 'package:extendedscreen/shared/widgets/device_settings_sheet.dart';

/// The Mac's hub with what Home asks of it recorded instead of done: the
/// sessions are adopted, never connected.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
    : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  final stops = <(String, bool)>[];
  final connects = <String?>[];

  /// The role each of [connects] was given.
  final choices = <SessionChoice?>[];
  int disconnects = 0;

  @override
  Future<void> disconnectSession(
    String key, {
    bool userStopped = false,
  }) async => stops.add((key, userStopped));

  // Where every connect of the hub's goes through: Home's (with the
  // device's role) and the policy's.
  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {
    connects.add(serial);
    choices.add(choice);
  }

  @override
  Future<void> disconnect() async => disconnects++;

  /// The role changes asked for (tablet, role, the session it was asked
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

  /// Tablets between two sessions, as the hub holds one while its role is
  /// being changed (the change itself is only recorded here): in no
  /// session, its place kept, not offered as a device to add.
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

/// The iPhones and iPads the Mac lists on USB, as the test sets them.
class _Phones extends IosScreenChannel {
  List<IosScreenDevice> list = const [];
  int listings = 0;

  @override
  Future<List<IosScreenDevice>> listDevices() async {
    listings++;
    return list;
  }
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

/// [key]'s role chip for [choice].
Finder _role(String key, SessionChoice choice) => find.byKey(
  ValueKey('$key/role/${choice.mode.name}.${choice.direction.name}'),
);

/// The Add a device panel's row for [serial], and its two buttons: Connect
/// on a remembered device, Connect on a new one (which asks for the role).
Finder _row(String serial) => find.byKey(ValueKey('device/$serial'));
Finder _connectBtn(String serial) =>
    find.byKey(ValueKey('device/$serial/connect'));
Finder _chooseBtn(String serial) =>
    find.byKey(ValueKey('device/$serial/choose'));

/// [choice] in the role chooser open for [serial].
Finder _option(String serial, SessionChoice choice) => find.byKey(
  ValueKey('choose/$serial/${choice.mode.name}.${choice.direction.name}'),
);

final _summary = find.byKey(const ValueKey('home/summary'));
final _wifiRow = find.byKey(const ValueKey('add/wifi-listen'));

/// What Home offered the Mac before: the selectors for the next tablet.
final _selectors = [
  find.byKey(const ValueKey('next/mode')),
  find.byKey(const ValueKey('next/mode/extendedScreen')),
  find.byKey(const ValueKey('next/mode/remoteControl')),
  find.byKey(const ValueKey('next/dir')),
  find.byKey(const ValueKey('next/caption')),
  find.byKey(const ValueKey('next/wifi-listen')),
];

Finder _inAdd(Finder matching) =>
    find.descendant(of: find.byType(AddDevicePanel), matching: matching);

Finder _inCards(Finder matching) =>
    find.descendant(of: find.byType(DeviceCard), matching: matching);

Finder _inTitle(Finder matching) =>
    find.descendant(of: find.byType(AppBar), matching: matching);

/// What the Text found by [finder] says.
String _said(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).data!;

RoleChip _chip(WidgetTester tester, String key, SessionChoice choice) =>
    tester.widget<RoleChip>(_role(key, choice));

/// Whether a button found by [finder] can be pressed.
bool _pressable(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

/// Whether the chooser's option [choice] for [serial] can be picked.
bool _pickable(WidgetTester tester, String serial, SessionChoice choice) =>
    tester
        .widget<InkWell>(
          find.descendant(
            of: _option(serial, choice),
            matching: find.byType(InkWell),
          ),
        )
        .onTap !=
    null;

/// No mode, direction or link selector anywhere on the page.
void _noSelectors() {
  for (final f in _selectors) {
    expect(f, findsNothing);
  }
  for (final text in [
    'home_next_tablet_mode',
    'remote_dir_title',
    'link_usb_desc',
    'link_wifi_desc',
    'session_extended_desc',
  ]) {
    expect(find.text(text), findsNothing, reason: text);
  }
}

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

  /// A dialog or sheet opening or closing.
  Future<void> dialog(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Home over [count] live tablets, `SERIAL-A`, `SERIAL-B`, … (the first
  /// one focused), all attached, each made as [choice]. With [routed], Home
  /// is the app's `/home` route, as in the app (the remote view opens by
  /// itself only from there), and `/remote-host` a stand-in page with the
  /// remote view's own controller; [routed] hears the pushes. [iosPoll] is
  /// how often Home lists the iPhones on USB (none: only as it opens).
  Future<List<HostSession>> start(
    WidgetTester tester,
    int count, {
    bool permissions = false,
    bool translated = false,
    SessionChoice? choice,
    NavigatorObserver? routed,
    Duration? iosPoll,
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
                Get.put(HomeController(iosPollInterval: iosPoll));
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
            GetPage(
              name: AppRoutes.iphoneRemote,
              page: () => const Scaffold(body: Text('iphone page')),
            ),
          ],
        ),
      );
      await settle(tester);
      return sessions;
    }
    Get.put(HomeController(iosPollInterval: iosPoll));
    await tester.pumpWidget(
      translated ? app() : const GetMaterialApp(home: HomeView()),
    );
    await tester.pump();
    await tester.pump();
    return sessions;
  }

  testWidgets('two tablets: a card each under Devices, the summary counts '
      'their places, each card highlights its own role, and Home has no '
      'selector of its own', (tester) async {
    // Tall enough for both cards and the add panel below them.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester, 2);

    expect(find.byType(DeviceCard), findsNWidgets(2));
    expect(find.text('home_devices'), findsOneWidget);
    // Not translated here: the keys themselves. Neither tablet is
    // capturing, and with 2 places at most (the conservative estimate)
    // both are taken.
    expect(
      _said(tester, _summary),
      hub.cap == 2
          ? 'home_devices_connected · home_devices_at_cap'
          : 'home_devices_connected',
    );
    // The title is the app's name alone: the roles are on the cards.
    expect(_inTitle(find.text('app_name')), findsOneWidget);
    expect(find.text('home_appbar_tablets'), findsNothing);
    expect(_inTitle(find.text('role_extended')), findsNothing);
    for (final key in ['SERIAL-A', 'SERIAL-B']) {
      expect(_chip(tester, key, _extended).selected, isTrue, reason: key);
      expect(_chip(tester, key, _driving).selected, isFalse, reason: key);
      expect(_chip(tester, key, _reverse).selected, isFalse, reason: key);
    }
    expect(_inCards(find.text('role_extended')), findsNWidgets(2));
    expect(
      _inAdd(find.text('home_all_attached_connected')),
      findsOneWidget,
    );
    // Nothing on the page says what the next tablet runs as, and the Mac
    // has no link selector; nor the old phone button in the bar.
    _noSelectors();
    expect(find.byKey(const ValueKey('home/iphone-remote')), findsNothing);
  });

  testWidgets('one tablet: its card in the list, the permission banner '
      'above, its role highlighted on the card; waiting to retry it offers '
      'Cancel and Retry', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 1);

    expect(find.byType(DeviceCard), findsOneWidget);
    expect(find.text('perm_required_title'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('perm_required_title')).dy,
      lessThan(tester.getTopLeft(_card('SERIAL-A')).dy),
    );
    expect(_chip(tester, 'SERIAL-A', _extended).selected, isTrue);
    expect(_inTitle(find.text('app_name')), findsOneWidget);
    expect(_action('SERIAL-A', 'common_disconnect'), findsOneWidget);
    _noSelectors();

    sessions[0]
      ..retryPending.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();
    expect(_action('SERIAL-A', 'common_cancel'), findsOneWidget);
    expect(_action('SERIAL-A', 'common_retry'), findsOneWidget);
    expect(_action('SERIAL-A', 'common_disconnect'), findsNothing);
    _noSelectors();
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
    expect(
      find.descendant(of: _card('SERIAL-B'), matching: find.text('error_encode_limit')),
      findsOneWidget,
    );
    // Its status line says it waits for the user, not that it retries.
    expect(
      find.descendant(
        of: _card('SERIAL-B'),
        matching: find.textContaining('home_status_waiting_you'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('home_status_retrying'), findsNothing);
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

    expect(
      find.descendant(
        of: _card('SERIAL-B'),
        matching: find.textContaining('home_status_retrying'),
      ),
      findsOneWidget,
    );
    expect(_action('SERIAL-B', 'common_cancel'), findsOneWidget);
    await tester.tap(_action('SERIAL-B', 'common_retry'));
    await tester.pump();
    await tester.pump();
    expect(hub.connects, ['SERIAL-B']);
    expect(hub.stops, isEmpty);
  });

  // With one tablet at a time (Maximum tablets 1; the role no longer makes
  // it so), whatever the role.
  for (final remote in [false, true]) {
    testWidgets('with Maximum tablets 1'
        '${remote ? ', in remote control' : ''}, while a Disconnect of every '
        'tablet still runs, the freed tablet is not short of room, and there '
        'is nothing to disconnect', (tester) async {
      await settings.setMaxTablets(1);
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1, choice: remote ? _driving : null);
      expect(hub.cap, 1);

      // The remote view's Disconnect: the session is out of the hub at
      // once, while the facade still reads its phase until the end.
      hub.endingAll.value = true;
      hub.sessions.remove('SERIAL-A');
      await tester.pump();
      expect(hub.phase.value, ConnectionPhase.streaming);
      expect(
        find.descendant(of: _row('SERIAL-A'), matching: find.text('home_disconnecting')),
        findsOneWidget,
      );
      expect(find.text('home_row_full'), findsNothing);
      expect(_pressable(tester, _chooseBtn('SERIAL-A')), isFalse);
      expect(find.text('common_disconnect'), findsNothing);

      hub.endingAll.value = false;
      hub.phase.value = ConnectionPhase.disconnected;
      await tester.pump();
      expect(find.text('home_disconnecting'), findsNothing);
      expect(find.text('home_row_full'), findsNothing);
      expect(_pressable(tester, _chooseBtn('SERIAL-A')), isTrue);
    });
  }

  group('the role of a device', () {
    const extra = DeviceModel(
      serial: 'SERIAL-X',
      model: 'Tablet X',
      status: DeviceStatus.connected,
    );

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

    testWidgets('a device the Mac would only view needs a place, not room '
        "on the encoder: with the encoder full a new device's row stays "
        'enabled and its chooser offers only that role; a remembered one '
        'that the Mac would encode for asks for its role instead of '
        'connecting as it was', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1, permissions: true);
      fillEncoder();
      await attachExtra(tester);
      expect(hub.canAdd, isTrue);

      // New: never short of the encoder.
      expect(_pressable(tester, _chooseBtn('SERIAL-X')), isTrue);
      expect(find.text('home_row_encoder_full'), findsNothing);
      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      for (final c in [_extended, _driving]) {
        expect(_pickable(tester, 'SERIAL-X', c), isFalse, reason: '$c');
        expect(
          find.descendant(
            of: _option('SERIAL-X', c),
            matching: find.text('home_row_encoder_full'),
          ),
          findsOneWidget,
          reason: '$c',
        );
      }
      expect(_pickable(tester, 'SERIAL-X', _reverse), isTrue);
      await tester.tap(_option('SERIAL-X', _reverse));
      await dialog(tester);
      await tester.pump();
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_reverse]);

      // Remembered: a role with no room is no dead end. Its Connect asks
      // for the role, the row saying why; one that fits connects as it
      // was.
      await settings.rememberDevice(
        'SERIAL-X',
        model: 'Tablet X',
        vdSerial: 7,
        choice: _extended,
      );
      for (final (choice, fits) in [
        (_extended, false),
        (_driving, false),
        (_reverse, true),
      ]) {
        settings.setKnownChoice('SERIAL-X', choice);
        hub.availableDevices.refresh();
        await tester.pump();
        expect(_connectBtn('SERIAL-X'), fits ? findsOneWidget : findsNothing,
            reason: '$choice');
        expect(_chooseBtn('SERIAL-X'), fits ? findsNothing : findsOneWidget,
            reason: '$choice');
        expect(
          _pressable(tester, fits ? _connectBtn('SERIAL-X') : _chooseBtn('SERIAL-X')),
          isTrue,
          reason: '$choice',
        );
        expect(
          find.descendant(
            of: _row('SERIAL-X'),
            matching: find.text('home_row_role_no_room'),
          ),
          fits ? findsNothing : findsOneWidget,
          reason: '$choice',
        );
        expect(find.text('home_row_encoder_full'), findsNothing);
      }
      // The chooser it opens starts on the remembered role, not offered,
      // and connects it in the one picked; the default for new devices is
      // left alone.
      settings.setKnownChoice('SERIAL-X', _driving);
      hub.availableDevices.refresh();
      await tester.pump();
      final next = settings.nextChoice;
      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      expect(_pickable(tester, 'SERIAL-X', _driving), isFalse);
      await tester.tap(_option('SERIAL-X', _reverse));
      await dialog(tester);
      await tester.pump();
      expect(hub.connects, ['SERIAL-X', 'SERIAL-X']);
      expect(hub.choices, [_reverse, _reverse]);
      expect(settings.nextChoice, next);
    });

    testWidgets('Connect on a remembered device connects it in its '
        'remembered role, with no question', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.rememberDevice(
        extra.serial,
        model: extra.model,
        vdSerial: 7,
        choice: _reverse,
      );
      await start(tester, 1, permissions: true, choice: _extended);
      await attachExtra(tester);

      await tester.tap(_connectBtn('SERIAL-X'));
      await dialog(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_reverse]);
      expect(settings.nextChoice, _extended, reason: 'nothing was chosen');
    });

    testWidgets('Connect on a new device opens the chooser, which '
        'preselects the last role picked; Cancel connects nothing, and a '
        'pick connects in that role and is kept for the next one', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      await start(tester, 1, permissions: true, choice: _extended);
      await attachExtra(tester);
      expect(_connectBtn('SERIAL-X'), findsNothing);

      Color? colour(SessionChoice c) => tester
          .widget<Material>(
            find
                .descendant(of: _option('SERIAL-X', c), matching: find.byType(Material))
                .first,
          )
          .color;

      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      expect(find.text('home_choose_role_title'), findsOneWidget);
      for (final c in SessionChoice.all) {
        expect(_option('SERIAL-X', c), findsOneWidget, reason: '$c');
        expect(_pickable(tester, 'SERIAL-X', c), isTrue, reason: '$c');
      }
      expect(colour(_reverse), isNot(colour(_extended)),
          reason: 'the last role picked is highlighted');
      expect(colour(_driving), colour(_extended));
      await tester.tap(find.byKey(const ValueKey('choose/SERIAL-X/cancel')));
      await dialog(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(hub.connects, isEmpty);

      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      await tester.tap(_option('SERIAL-X', _driving));
      await dialog(tester);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_driving]);
      expect(settings.nextChoice, _driving);
      // Both halves saved, the direction too (it was Mac → tablet).
      expect(settings.sessionMode, SessionMode.remoteControl);
      expect(settings.remoteDirection, RemoteDirection.tabControlsMac);

      // And the other way: the mode itself is what changes.
      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      await tester.tap(_option('SERIAL-X', _extended));
      await dialog(tester);
      await tester.pump();
      expect(hub.choices, [_driving, _extended]);
      expect(settings.sessionMode, SessionMode.extendedScreen);
      expect(settings.nextChoice.sameEffect(_extended), isTrue);
    });

    testWidgets('the chooser highlights the default role by what it does: '
        'Extended saved with the Mac → tablet direction is Second display',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // What the old Home's two selectors could leave saved.
      await settings.setSessionMode(SessionMode.extendedScreen);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      await start(tester, 1, permissions: true, choice: _extended);
      await attachExtra(tester);

      Color? colour(SessionChoice c) => tester
          .widget<Material>(
            find
                .descendant(
                    of: _option('SERIAL-X', c), matching: find.byType(Material))
                .first,
          )
          .color;
      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      expect(colour(_extended), isNot(colour(_driving)),
          reason: 'Second display is highlighted');
      expect(colour(_reverse), colour(_driving));
    });

    testWidgets('a pick from the chooser that ends in Settings for the '
        'permissions connects nothing and leaves the default role alone',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Screen Recording and Accessibility are missing.
      await start(tester, 1, routed: _Pushes());
      await attachExtra(tester);
      final before = settings.nextChoice;
      expect(before.sameEffect(_driving), isFalse);

      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      await tester.tap(_option('SERIAL-X', _driving));
      await settle(tester);
      expect(Get.currentRoute, AppRoutes.settings);
      expect(hub.connects, isEmpty);
      expect(settings.nextChoice, before);
      expect(settings.sessionMode, before.mode);
      Get.back<void>(closeOverlays: true);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a pick from the chooser is checked again when the dialog '
        'closes: a place taken meanwhile, or the device connected by '
        'itself, refuses it with a message, and saves no role', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setMaxTablets(2);
      await start(tester, 1, permissions: true, translated: true);
      await attachExtra(tester);
      final before = settings.nextChoice;
      final en = AppTranslations().keys['en']!;

      // The chooser is open when another tablet takes the last place.
      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      hub.between.add('SERIAL-Z');
      await tester.tap(_option('SERIAL-X', _driving));
      await dialog(tester);
      await tester.pump();
      expect(hub.connects, isEmpty);
      expect(settings.nextChoice, before);
      expect(find.text(en['home_connect_refused']!), findsOneWidget);
      expect(
        find.text(en['home_row_full']!.replaceAll('@cap', '2')),
        findsWidgets,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));

      // Room again; this time the device gets a session of its own (the
      // auto-connect took it) while the chooser is open.
      hub.between.clear();
      await tester.pump();
      await tester.tap(_chooseBtn('SERIAL-X'));
      await dialog(tester);
      hub.sessions['SERIAL-X'] = HostSession(
        key: 'SERIAL-X',
        link: LinkType.usb,
        serial: 'SERIAL-X',
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      )..phase.value = ConnectionPhase.handshaking;
      await tester.tap(_option('SERIAL-X', _driving));
      await dialog(tester);
      await tester.pump();
      expect(hub.connects, isEmpty);
      expect(settings.nextChoice, before);
      expect(find.text(en['home_row_taken']!), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a press on the Connect of a tablet the user stopped lifts '
        'the stop, and the pause, only as it connects: not when it ends in '
        'Settings for the permissions, and not while they are asked about', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.rememberDevice(
        extra.serial,
        model: extra.model,
        vdSerial: 7,
        choice: _extended,
      );
      // Screen Recording and Accessibility are missing.
      await start(tester, 1, routed: _Pushes());
      await attachExtra(tester);
      hub.stoppedDevices.add('SERIAL-X');
      hub.pauseAutoConnect();

      await tester.tap(_connectBtn('SERIAL-X'));
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
      await tester.tap(_connectBtn('SERIAL-X'));
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

    testWidgets('a second device can be added beside one that controls the '
        'Mac or that the Mac controls: no row says one at a time', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = (await start(tester, 1, translated: true, choice: _driving))
          .single;
      await attachExtra(tester);
      expect(hub.cap, greaterThan(1));

      for (final choice in [_driving, _reverse]) {
        hub.sessions['SERIAL-A'] = tablet('A', choice: choice);
        await tester.pump();
        expect(_pressable(tester, _chooseBtn('SERIAL-X')), isTrue);
        final texts = tester
            .widgetList<Text>(_inAdd(find.byType(Text)))
            .map((t) => t.data ?? '')
            .toList();
        for (final locale in ['en', 'th']) {
          final map = AppTranslations().keys[locale]!;
          expect(map.containsKey('home_remote_single'), isFalse);
          final full = map['home_row_full']!.split('@cap').first;
          expect(texts.where((t) => t.contains(full)), isEmpty);
        }
      }
      expect(a.choice, _driving);
    });

    testWidgets('Home has no mode, direction or link selector in any phase, '
        "and the card's highlighted role follows its session alone", (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 1, choice: _reverse);
      // What a new device would get says something else.
      expect(settings.nextChoice.mode, SessionMode.extendedScreen);

      void check() {
        _noSelectors();
        expect(_inTitle(find.text('app_name')), findsOneWidget);
        if (hub.sessions.isNotEmpty) {
          expect(_chip(tester, 'SERIAL-A', _reverse).selected, isTrue);
          expect(_chip(tester, 'SERIAL-A', _extended).selected, isFalse);
        }
      }

      check();
      // Waiting to retry.
      sessions[0]
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();
      check();
      // Connecting again.
      sessions[0]
        ..retryPending.value = false
        ..phase.value = ConnectionPhase.handshaking;
      await tester.pump();
      check();
      // What a new device gets changing changes nothing on the card.
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      await tester.pump();
      check();
      // With no tablet.
      hub.sessions.remove('SERIAL-A');
      hub.phase.value = ConnectionPhase.disconnected;
      await tester.pump();
      check();
      expect(find.byType(DeviceCard), findsNothing);
      expect(hub.modeChanges, isEmpty);
      expect(hub.connects, isEmpty);
      expect(hub.stops, isEmpty);
    });

    testWidgets("a remembered device's row says it is plugged in and what "
        'it was last time, a new one that it is new, in the language '
        'chosen; Connect uses the remembered role', (tester) async {
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
      String known(String locale) =>
          '${text(locale, 'home_row_plugged_in')} · '
          '${text(locale, 'home_row_last_role').replaceAll('@role', text(locale, 'role_mac_controls'))}';
      String unknown(String locale) =>
          '${text(locale, 'home_row_plugged_in')} · ${text(locale, 'home_row_new')}';
      expect(known('en'),
          'Plugged in · last time: The Mac controls this device');
      expect(
        find.descendant(of: _row('SERIAL-X'), matching: find.text(known('en'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row('SERIAL-Y'), matching: find.text(unknown('en'))),
        findsOneWidget,
      );
      expect(find.text(known('en')), findsOneWidget, reason: 'no card says it');

      // The press is the user's, in the role the device is used to.
      expect(settings.nextChoice, _extended);
      await tester.tap(_connectBtn('SERIAL-X'));
      await tester.pump();
      await tester.pump();
      expect(hub.connects, ['SERIAL-X']);
      expect(hub.choices, [_reverse]);
      expect(settings.knownChoice('SERIAL-X'), _reverse);

      Get.locale = const Locale('th');
      await tester.pumpWidget(app());
      await tester.pump();
      expect(
        find.descendant(of: _row('SERIAL-X'), matching: find.text(known('th'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row('SERIAL-Y'), matching: find.text(unknown('th'))),
        findsOneWidget,
      );
      expect(find.text(known('en')), findsNothing);
    });
  });

  testWidgets('the Devices summary counts the devices connected, and says '
      'when every place is taken: a refused tablet is not connected but '
      'holds one', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await settings.setMaxTablets(2);
    final sessions = await start(tester, 2, translated: true);
    expect(hub.cap, 2);
    sessions[1]
      ..refused.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();

    final en = AppTranslations().keys['en']!;
    final one = en['home_devices_connected']!.replaceAll('@n', '1');
    final full = en['home_devices_at_cap']!.replaceAll('@cap', '2');
    expect(_said(tester, _summary), '$one · $full');

    // The refused one let go of: a place is free again.
    hub.sessions.remove('SERIAL-B');
    await tester.pump();
    expect(_said(tester, _summary), one);
  });

  testWidgets('while a tablet is between two sessions, its role being '
      'changed, Home counts its place, does not offer it, and does not say '
      'that nothing is attached', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await settings.setMaxTablets(2);
    final sessions = await start(tester, 2, translated: true);
    expect(hub.cap, 2);
    final en = AppTranslations().keys['en']!;
    final none = en['home_devices_connected']!.replaceAll('@n', '0');
    final full = en['home_devices_at_cap']!.replaceAll('@cap', '2');
    final link = find.text(en['link_usb_desc']!);

    // A waits to retry, which is idle. B's old session has left the map.
    sessions[0]
      ..retryPending.value = true
      ..phase.value = ConnectionPhase.error;
    hub.sessions.remove('SERIAL-B');
    await tester.pump();
    expect(link, findsNothing, reason: 'the Mac has no link selector');
    expect(_said(tester, _summary), none);

    // The same, but B is on its way back in another role: its place is
    // counted, so every place is taken.
    hub.between.add('SERIAL-B');
    await tester.pump();
    expect(link, findsNothing);
    expect(_said(tester, _summary), '$none · $full');
    expect(_row('SERIAL-B'), findsNothing);
    expect(_card('SERIAL-A'), findsOneWidget);

    // A is unplugged and its card let go of meanwhile: no session at all,
    // the hub idle as far as its phase goes, and B the one tablet listed.
    sessions[0].phase.value = ConnectionPhase.disconnected;
    hub.sessions.remove('SERIAL-A');
    hub.availableDevices.removeWhere((d) => d.serial == 'SERIAL-A');
    await tester.pump();
    expect(hub.phase.value, ConnectionPhase.disconnected);
    expect(find.byType(DeviceCard), findsNothing);
    expect(link, findsNothing);
    expect(_said(tester, _summary), none, reason: "B's place, not connected");
    expect(find.byKey(const ValueKey('home/none-connected')), findsOneWidget);
    expect(find.byKey(const ValueKey('home/empty')), findsNothing);
    expect(
      _inAdd(find.text(en['home_all_attached_connected']!)),
      findsOneWidget,
    );

    // B is back.
    hub.between.clear();
    await tester.pump();
    expect(link, findsNothing, reason: 'the Mac has no link selector');
    expect(_row('SERIAL-B'), findsOneWidget);
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
    expect(_said(tester, _summary), endsWith(' · encoder 119% (H.265)'));

    // Ten seconds healthy at its ceiling, its encoder handing back every
    // frame of a changing screen: the hub learns, and Home says so.
    for (var second = 0; second < 11; second++) {
      hub.encoderStats(a.nativeId, 120, 60);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(hub.budget.isLearned(CodecType.h265), isTrue);
    expect(_said(tester, _summary), endsWith(' · encoder 85% (H.265)'));

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

  testWidgets('tapping a card focuses its tablet, whose card alone has the '
      'accent border', (tester) async {
    await start(tester, 2);
    expect(hub.focused?.key, 'SERIAL-A');
    expect(tester.widget<DeviceCard>(_card('SERIAL-A')).focused, isTrue);
    expect(tester.widget<DeviceCard>(_card('SERIAL-B')).focused, isFalse);

    await tester.tap(
      find.descendant(
        of: _card('SERIAL-B'),
        matching: find.text('A rather long tablet model name B'),
      ),
    );
    await tester.pump();

    expect(hub.focused?.key, 'SERIAL-B');
    expect(hub.focusedKey.value, 'SERIAL-B');
    expect(hub.stops, isEmpty);
    expect(tester.widget<DeviceCard>(_card('SERIAL-A')).focused, isFalse);
    expect(tester.widget<DeviceCard>(_card('SERIAL-B')).focused, isTrue);
    // As drawn: the accent border, two wide, on that card alone.
    Border border(String key) =>
        tester
                .widgetList<Container>(
                  find.descendant(
                    of: _card(key),
                    matching: find.byType(Container),
                  ),
                )
                .map((c) => c.decoration)
                .whereType<BoxDecoration>()
                .firstWhere(
                  (d) => d.borderRadius == BorderRadius.circular(18),
                )
                .border!
            as Border;
    expect(border('SERIAL-B').top.width, 2);
    expect(
      border('SERIAL-B').top.color,
      const Color(0xFF00C8FF).withValues(alpha: 0.6),
    );
    expect(border('SERIAL-A').top.width, 1);
    expect(border('SERIAL-A').top.color, isNot(border('SERIAL-B').top.color));

    // One card alone is never drawn as focused.
    hub.sessions.remove('SERIAL-A');
    await tester.pump();
    expect(tester.widget<DeviceCard>(_card('SERIAL-B')).focused, isFalse);
  });

  testWidgets('two devices of the same model are told apart by their '
      'serial, on their cards and on their rows; a model of its own shows '
      'none', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = await start(tester, 2);
    for (final s in sessions) {
      s.activeDevice.value = _device(s.key, 'SM-X920');
    }
    hub.availableDevices.value = [
      for (final s in sessions) s.activeDevice.value!,
      _device('SERIAL-X', 'SM-X820'),
      _device('SERIAL-Y', 'SM-X820'),
      _device('SERIAL-Z', 'Pixel Tablet'),
    ];
    await tester.pump();

    String status(String key) => _said(
      tester,
      find.descendant(of: _card(key), matching: find.textContaining('USB-C')),
    );
    for (final key in ['SERIAL-A', 'SERIAL-B']) {
      expect(status(key), startsWith('USB-C · $key · '), reason: key);
    }
    for (final serial in ['SERIAL-X', 'SERIAL-Y']) {
      expect(
        find.descendant(
          of: _row(serial),
          matching: find.textContaining(' · $serial · '),
        ),
        findsOneWidget,
        reason: serial,
      );
    }
    expect(
      find.descendant(
        of: _row('SERIAL-Z'),
        matching: find.textContaining('SERIAL-Z'),
      ),
      findsNothing,
    );

    // B is another model now: neither card needs its serial.
    sessions[1].activeDevice.value = _device('SERIAL-B', 'SM-X710');
    await tester.pump();
    expect(status('SERIAL-A'), isNot(contains('SERIAL-A')));
    expect(status('SERIAL-B'), isNot(contains('SERIAL-B')));
  });

  group('the remote view', () {
    /// The card's Open remote button.
    Finder openRemote(String key) => find.byKey(ValueKey('$key/open-remote'));

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

    testWidgets('an Extended tablet going live while what a new device gets '
        'is The Mac controls this device opens nothing, and its card has no '
        'button', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      final pushes = _Pushes();
      final sessions = await start(
        tester,
        1,
        choice: const SessionChoice(SessionMode.extendedScreen),
        routed: pushes,
      );
      sessions[0]
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
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
      expect(openRemote('SERIAL-A'), findsNothing);
      expect(find.text('home_open_remote'), findsNothing);
    });
  });

  group("a card's role chips", () {
    /// Presses [choice] on [key]'s card, and lets Home ask about the
    /// permissions.
    Future<void> press(
      WidgetTester tester,
      String key,
      SessionChoice choice,
    ) async {
      await tester.tap(_role(key, choice));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a tablet waiting to retry: pressing its The Mac controls '
        'this device chip asks the hub to change that very session', (
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
      expect(hub.sessions['SERIAL-A'], same(s));

      await press(tester, 'SERIAL-A', _reverse);
      expect(hub.modeChanges, [('SERIAL-A', _reverse, s)]);
      expect(hub.connects, isEmpty, reason: 'the hub replaces it itself');
      expect(hub.stops, isEmpty);
      expect(hub.disconnects, 0);
    });

    testWidgets('a USB tablet shows all three roles: the one it runs as '
        'highlighted and not to be pressed, the others with what the change '
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

      void expectChip(String key, SessionChoice c, {String? hint}) {
        final chip = _chip(tester, key, c);
        expect(chip.selected, hint == null, reason: '$key $c');
        expect(chip.enabled, hint != null, reason: '$key $c');
        expect(chip.hint, hint, reason: '$key $c');
        expect(
          find.descendant(of: _role(key, c), matching: find.text(c.roleLabel)),
          findsOneWidget,
        );
      }

      expectChip('SERIAL-A', _extended);
      expectChip('SERIAL-A', _driving, hint: 'session_mode_hint_restart');
      expectChip('SERIAL-A', _reverse, hint: 'session_mode_hint_to_reverse');
      expect(find.byTooltip('session_mode_hint_restart'), findsWidgets);
      expectChip('SERIAL-B', _reverse);
      for (final other in [_extended, _driving]) {
        expectChip('SERIAL-B', other, hint: 'session_mode_hint_from_reverse');
      }

      // The highlighted one does nothing.
      await press(tester, 'SERIAL-A', _extended);
      expect(hub.modeChanges, isEmpty);

      await press(tester, 'SERIAL-B', _driving);
      expect(hub.modeChanges, [('SERIAL-B', _driving, b)]);
      expect(hub.stops, isEmpty, reason: 'the other tablet is not touched');
    });

    testWidgets('an iPhone or iPad on USB, and any device on Wi-Fi, is '
        'offered no The Mac controls this device chip', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 3, permissions: true);
      sessions[0].platform = HostSession.helloPlatformIphone;
      sessions[1].platform = HostSession.helloPlatformIpad;
      hub.sessions['SERIAL-C'] = tablet('C');
      await tester.pump();
      for (final key in ['SERIAL-A', 'SERIAL-B']) {
        expect(_role(key, _reverse), findsNothing, reason: key);
        expect(_role(key, _extended), findsOneWidget, reason: key);
        expect(_role(key, _driving), findsOneWidget, reason: key);
      }
      expect(
        find.descendant(of: _card('SERIAL-A'), matching: find.byIcon(Icons.phone_iphone)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _card('SERIAL-B'), matching: find.byIcon(Icons.tablet_mac)),
        findsOneWidget,
      );
      expect(_role('SERIAL-C', _reverse), findsOneWidget, reason: 'Android');
    });

    testWidgets('pressing a chip focuses nothing', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 2);
      expect(hub.focused?.key, 'SERIAL-A');

      await press(tester, 'SERIAL-B', _reverse);
      expect(hub.modeChanges, [('SERIAL-B', _reverse, sessions[1])]);
      expect(hub.focused?.key, 'SERIAL-A');
      expect(hub.focusedKey.value, 'SERIAL-A');
    });

    testWidgets('a press that began before its tablet got another session '
        'under the same key changes nothing', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = (await start(tester, 1, choice: _extended)).single;

      var touch = await tester.startGesture(
        tester.getCenter(_role('SERIAL-A', _reverse)),
      );
      // Meanwhile the hub replaces the session (a change asked elsewhere,
      // or a pick): the card now holds the new one, the finger still down.
      final renewed = tablet('A', choice: _driving);
      hub.sessions['SERIAL-A'] = renewed;
      await tester.pump();
      expect(_chip(tester, 'SERIAL-A', _driving).selected, isTrue);
      expect(_chip(tester, 'SERIAL-A', _reverse).enabled, isTrue);
      await touch.up();
      await tester.pump();
      await tester.pump();
      expect(hub.modeChanges, isEmpty);
      expect(hub.sessions['SERIAL-A'], same(renewed));
      expect(old.choice, _extended);

      // And with the tablet's session gone altogether.
      touch = await tester.startGesture(
        tester.getCenter(_role('SERIAL-A', _reverse)),
      );
      hub.sessions.remove('SERIAL-A');
      await tester.pump();
      expect(find.byType(DeviceCard), findsNothing);
      await touch.up();
      await tester.pump();
      expect(hub.modeChanges, isEmpty);

      // The controller itself asks the hub nothing for a session that is
      // not its tablet's.
      await Get.find<HomeController>().onSessionMode(old, _reverse);
      expect(hub.modeChanges, isEmpty);
    });

    testWidgets('chips can be pressed while the tablet is live or waits in '
        'error, not while it connects, nor while every tablet is being '
        'disconnected', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = await start(tester, 2);
      final a = sessions[0];
      bool pressable(String key) => _chip(tester, key, _reverse).enabled;
      expect(pressable('SERIAL-A'), isTrue);
      expect(pressable('SERIAL-B'), isTrue);

      for (final phase in ConnectionPhase.values) {
        a.phase.value = phase;
        await tester.pump();
        expect(
          pressable('SERIAL-A'),
          phase.isActive || phase == ConnectionPhase.error,
          reason: phase.name,
        );
        expect(
          _chip(tester, 'SERIAL-A', _reverse).onPressed != null,
          pressable('SERIAL-A'),
          reason: phase.name,
        );
        // The highlighted chip is never one to press.
        expect(_chip(tester, 'SERIAL-A', _extended).enabled, isFalse);
        expect(pressable('SERIAL-B'), isTrue, reason: phase.name);
        // The card's one action for the phase: Cancel while it connects,
        // Disconnect while live, Retry beside Cancel in error.
        final connecting = phase.isConnecting;
        final error = phase == ConnectionPhase.error;
        expect(
          _action('SERIAL-A', 'common_cancel'),
          connecting || error ? findsOneWidget : findsNothing,
          reason: phase.name,
        );
        expect(
          _action('SERIAL-A', 'common_disconnect'),
          phase.isActive ? findsOneWidget : findsNothing,
          reason: phase.name,
        );
        expect(
          _action('SERIAL-A', 'common_retry'),
          error ? findsOneWidget : findsNothing,
          reason: phase.name,
        );
        // Plain words while it connects: no step of the protocol.
        if (connecting) {
          expect(
            _said(
              tester,
              find.descendant(
                of: _card('SERIAL-A'),
                matching: find.textContaining('USB-C · '),
              ),
            ),
            phase == ConnectionPhase.handshaking
                ? 'USB-C · home_status_waiting_app'
                : 'USB-C · home_status_connecting',
            reason: phase.name,
          );
        }
      }
      // Cancel while it connects stops that tablet alone, as the user's.
      a.phase.value = ConnectionPhase.handshaking;
      await tester.pump();
      await tester.tap(_action('SERIAL-A', 'common_cancel'));
      await tester.pump();
      expect(hub.stops, [('SERIAL-A', true)]);
      hub.stops.clear();
      // Refused by the encoder, or waiting out a retry: both `error`.
      a
        ..refused.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();
      expect(pressable('SERIAL-A'), isTrue);

      hub.endingAll.value = true;
      await tester.pump();
      expect(pressable('SERIAL-A'), isFalse);
      expect(pressable('SERIAL-B'), isFalse);
      hub.endingAll.value = false;
      await tester.pump();
      expect(pressable('SERIAL-B'), isTrue);
    });

    testWidgets('a press on a chip overtaken by the tablet starting to '
        'connect changes nothing', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = (await start(tester, 1)).single;
      a
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();

      final touch = await tester.startGesture(
        tester.getCenter(_role('SERIAL-A', _reverse)),
      );
      // Its retry fires before the finger comes up.
      a
        ..retryPending.value = false
        ..phase.value = ConnectionPhase.detectingDevice;
      await tester.pump();
      await touch.up();
      await tester.pump();
      await tester.pump();

      expect(hub.modeChanges, isEmpty);
      expect(hub.stops, isEmpty, reason: 'nor was it the Cancel');
    });

    testWidgets('a change into a role the Mac captures or takes input for '
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
      await tester.tap(_role('SERIAL-A', _driving));
      await settle(tester);
      expect(hub.modeChanges, isEmpty);
      expect(Get.currentRoute, AppRoutes.settings);
      // Back to Home, the message about the permissions going with it.
      Get.back<void>(closeOverlays: true);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(Get.currentRoute, AppRoutes.home);

      await tester.tap(_role('SERIAL-A', _reverse));
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
        for (final key in ['role_extended', 'role_controls_mac', 'role_mac_controls']) {
          expect(_inCards(find.text(map[key]!)), findsOneWidget, reason: key);
        }
        expect(find.text(map['home_devices']!), findsOneWidget);
        expect(find.text(map['home_add_device']!), findsOneWidget);
        expect(find.text(map['home_wifi_accept']!), findsOneWidget);
        // The tablet's own button, by the name it has there.
        expect(toReverse, contains(share));
        expect(toReverse, isNot(contains('@')));
        expect(_chip(tester, 'SERIAL-A', _reverse).hint, toReverse);
        expect(
          _chip(tester, 'SERIAL-A', _extended).hint,
          map['session_mode_hint_restart'],
          reason: 'to Extended screen',
        );
        expect(tester.takeException(), isNull);
      }
      final en = AppTranslations().keys['en']!;
      final th = AppTranslations().keys['th']!;
      for (final key in [
        'role_extended',
        'role_controls_mac',
        'role_mac_controls',
        'role_extended_desc',
        'role_controls_mac_desc',
        'role_mac_controls_desc',
        'home_devices',
        'home_devices_connected',
        'home_devices_at_cap',
        'home_picture_settings',
        'home_add_device',
        'home_row_plugged_in',
        'home_row_last_role',
        'home_row_new',
        'home_row_full',
        'home_row_full_mac',
        'home_row_role_no_room',
        'home_row_taken',
        'home_connect_refused',
        'home_row_encoder_full',
        'home_choose_role_title',
        'home_choose_role_hint',
        'home_empty',
        'home_empty_wifi_on',
        'home_none_connected',
        'home_wifi_accept',
        'home_wifi_accept_desc',
        'home_wifi_mac_at',
        'home_wifi_not_listening',
        'home_status_connecting',
        'home_status_waiting_app',
        'home_status_not_connected',
        'home_status_retrying',
        'home_status_waiting_you',
        'home_status_shared',
        'home_wifi_turned_away_mac',
        'iphone_usb_open',
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
      expect(th['home_row_last_role'], contains('@role'));
      expect(th['home_row_full'], contains('@cap'));
      expect(th['home_devices_connected'], contains('@n'));
      expect(th['home_devices_at_cap'], contains('@cap'));
      expect(th['home_row_full_mac'], contains('@cap'));
      expect(th['home_row_role_no_room'], contains('@role'));
      expect(th['home_wifi_turned_away_mac'],
          allOf(contains('@n'), contains('@cap')));
      // Plain words while a tablet connects: no protocol step names, and
      // English status words begin with a capital, like the rest.
      expect(en['home_status_waiting_you'], contains('Retry'));
      for (final key in [
        'home_status_connecting',
        'home_status_waiting_app',
        'home_status_not_connected',
        'home_status_retrying',
        'home_status_waiting_you',
        'home_status_shared',
      ]) {
        expect(en[key]![0], en[key]![0].toUpperCase(), reason: key);
        expect(en[key], isNot(contains('Handshak')), reason: key);
        expect(th[key], isNot(contains('จับมือ')), reason: key);
      }
      expect(th['role_mac_controls_desc'], contains('@share'));
      expect(th['home_choose_role_title'], contains('@name'));
      expect(th['home_wifi_mac_at'], contains('@addr'));
      // What the old Home said, gone from both languages.
      for (final key in [
        'home_next_tablet_mode',
        'home_tile_last_mode',
        'session_change_mode',
        'home_add_tablet',
        'home_tablets_count',
        'home_devices_count',
        'home_appbar_tablets',
        'home_at_limit',
        'home_wifi_listen',
        'home_wifi_listen_desc',
        'home_wifi_listening_at',
        'session_granted',
        'session_granted_shared',
        'session_settings',
        'iphone_remote_open',
        'wifi_host_title',
        'wifi_host_address',
        'wifi_host_hint',
        'remote_dir_title',
        'remote_dir_usb_only',
        'device_android_client',
        'device_none_detected',
      ]) {
        expect(en.containsKey(key), isFalse, reason: key);
        expect(th.containsKey(key), isFalse, reason: key);
      }
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

  testWidgets('Picture settings opens the device sheet for that device, and '
      'is not offered for a device that is a new one each time', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester, 1);
    const wifiKey = 'wifi:conn-1';
    hub.sessions[wifiKey] = HostSession(
      key: wifiKey,
      link: LinkType.wifi,
      beside: true,
      pipeline: hub.pipeline,
      adb: adb,
      socket: SocketService(),
    )..phase.value = ConnectionPhase.streaming;
    hub.sessions['synth-1'] = HostSession(
      key: 'synth-1',
      link: LinkType.usb,
      serial: 'synth-1',
      pipeline: hub.pipeline,
      adb: adb,
      socket: SocketService(),
    )..phase.value = ConnectionPhase.streaming;
    await tester.pump();

    expect(find.byKey(const ValueKey('$wifiKey/settings')), findsNothing);
    expect(find.byKey(const ValueKey('synth-1/settings')), findsNothing);
    final open = find.byKey(const ValueKey('SERIAL-A/settings'));
    expect(
      find.descendant(of: open, matching: find.text('home_picture_settings')),
      findsOneWidget,
    );
    await tester.tap(open);
    await dialog(tester);
    expect(find.byType(DeviceSettingsSheet), findsOneWidget);
    expect(
      tester.widget<DeviceSettingsSheet>(find.byType(DeviceSettingsSheet)).deviceKey,
      'SERIAL-A',
    );
    expect(hub.focused?.key, 'SERIAL-A');
    expect(hub.connects, isEmpty);
  });

  testWidgets('with nothing attached and no session, Home says what to do '
      'and connects nothing', (tester) async {
    await start(tester, 0, permissions: true);

    expect(find.byKey(const ValueKey('home/empty')), findsOneWidget);
    expect(find.text('home_empty'), findsOneWidget);
    expect(find.byKey(const ValueKey('home/none-connected')), findsNothing);
    expect(find.byType(DeviceCard), findsNothing);
    expect(find.byType(AddDevicePanel), findsOneWidget);
    expect(_inAdd(find.text('home_all_attached_connected')), findsNothing);
    expect(_summary, findsNothing, reason: 'no place in use');
    expect(hub.connects, isEmpty);

    // Wi-Fi already accepted: the empty state does not ask for it.
    await settings.setWifiListen(true);
    await tester.pump();
    expect(find.text('home_empty'), findsNothing);
    expect(find.text('home_empty_wifi_on'), findsOneWidget);
    await settings.setWifiListen(false);
    await tester.pump();
    expect(find.text('home_empty'), findsOneWidget);

    // A device plugged in: the empty state goes, the row is there.
    hub.availableDevices.value = [_device('SERIAL-X', 'Tablet X')];
    await tester.pump();
    expect(find.byKey(const ValueKey('home/empty')), findsNothing);
    expect(find.byKey(const ValueKey('home/none-connected')), findsOneWidget);
    expect(_row('SERIAL-X'), findsOneWidget);
    expect(hub.connects, isEmpty);
  });

  group('iPhones over USB', () {
    testWidgets('one plugged in gets a card whose Open screen opens its '
        'page with its id; none listed, no card', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final phones = Get.put<IosScreenChannel>(_Phones()) as _Phones;
      await start(tester, 0, permissions: true, routed: _Pushes());
      final home = Get.find<HomeController>();
      expect(phones.listings, 1, reason: 'listed as Home opens');
      expect(find.byKey(const ValueKey('iphone-usb/cam-1')), findsNothing);
      expect(find.byKey(const ValueKey('home/empty')), findsOneWidget);

      phones.list = const [
        IosScreenDevice('cam-2', 'iPad Pro'),
        IosScreenDevice('cam-1', 'iPhone 17 Pro'),
      ];
      await home.refreshIosDevices();
      await tester.pump();
      final card = find.byKey(const ValueKey('iphone-usb/cam-1'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text('iPhone 17 Pro')),
        findsOneWidget,
      );
      // One icon for both: the name is the user's, and says nothing sure
      // about the kind (an iPad renamed "Studio" is still an iPad).
      for (final id in ['cam-1', 'cam-2']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('iphone-usb/$id')),
            matching: find.byIcon(Icons.phonelink),
          ),
          findsOneWidget,
          reason: id,
        );
      }
      // Sorted by name, above the add panel; no place under the cap.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('iphone-usb/cam-2'))).dy,
        lessThan(tester.getTopLeft(card).dy),
      );
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(find.byType(AddDevicePanel)).dy),
      );
      expect(find.byKey(const ValueKey('home/empty')), findsNothing);
      expect(_inAdd(find.text('home_all_attached_connected')), findsOneWidget);
      expect(hub.heldPlaces, isEmpty);

      await tester.tap(find.byKey(const ValueKey('iphone-usb/cam-1/open')));
      await settle(tester);
      expect(Get.currentRoute, AppRoutes.iphoneRemote);
      expect(Get.arguments, {'id': 'cam-1'});
      Get.back<void>();
      await settle(tester);
      expect(Get.currentRoute, AppRoutes.home);

      // Unplugged: its card goes.
      phones.list = const [];
      await home.refreshIosDevices();
      await tester.pump();
      expect(find.byKey(const ValueKey('iphone-usb/cam-1')), findsNothing);
      expect(find.byKey(const ValueKey('home/empty')), findsOneWidget);
    });

    testWidgets("the card's status says whether touch works only once it "
        'was tried', (tester) async {
      final phones = Get.put<IosScreenChannel>(_Phones()) as _Phones;
      phones.list = const [IosScreenDevice('cam-1', 'iPhone')];
      final touch = Get.put(IosTouchService());
      await start(tester, 0);
      final status = find.descendant(
        of: find.byKey(const ValueKey('iphone-usb/cam-1')),
        matching: find.textContaining('USB-C · role_mac_controls'),
      );
      String line() => tester.widget<Text>(status).data!;

      expect(line(), 'USB-C · role_mac_controls');
      touch.state.value = IosTouchState.ready;
      await tester.pump();
      expect(line(), 'USB-C · role_mac_controls · iphone_remote_touch_ready');
      for (final off in [IosTouchState.noRunner, IosTouchState.noDevice]) {
        touch.state.value = off;
        await tester.pump();
        expect(line(), 'USB-C · role_mac_controls · iphone_remote_touch_off');
      }
      touch.state.value = IosTouchState.idle;
      await tester.pump();
      expect(line(), 'USB-C · role_mac_controls');

      // A second one plugged in: the touch service is bound to one of
      // them, which the capture devices do not name, so neither card says
      // touch works.
      touch.state.value = IosTouchState.ready;
      phones.list = const [
        IosScreenDevice('cam-1', 'iPhone'),
        IosScreenDevice('cam-2', 'iPad'),
      ];
      await Get.find<HomeController>().refreshIosDevices();
      await tester.pump();
      for (final id in ['cam-1', 'cam-2']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('iphone-usb/$id')),
            matching: find.text('USB-C · role_mac_controls'),
          ),
          findsOneWidget,
          reason: id,
        );
      }
      expect(find.textContaining('iphone_remote_touch'), findsNothing);
    });

    testWidgets('the list is polled only while Home is the route shown and '
        "the app is in front, and stops when Home's controller closes", (
      tester,
    ) async {
      final phones = Get.put<IosScreenChannel>(_Phones()) as _Phones;
      await start(
        tester,
        0,
        routed: _Pushes(),
        iosPoll: const Duration(seconds: 1),
      );
      final home = Get.find<HomeController>();
      final first = phones.listings;
      expect(first, greaterThanOrEqualTo(1));
      await tester.pump(const Duration(seconds: 1));
      expect(phones.listings, first + 1);

      // Under another page: no listing.
      Get.toNamed<void>(AppRoutes.settings);
      await settle(tester);
      var before = phones.listings;
      await tester.pump(const Duration(seconds: 3));
      expect(phones.listings, before);
      Get.back<void>();
      await settle(tester);
      before = phones.listings;
      await tester.pump(const Duration(seconds: 1));
      expect(phones.listings, before + 1);

      // In the background: none either; back in front lists at once.
      home.didChangeAppLifecycleState(AppLifecycleState.hidden);
      before = phones.listings;
      await tester.pump(const Duration(seconds: 3));
      expect(phones.listings, before);
      home.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(phones.listings, before + 1);

      // Home's controller closes: its timer goes with it (a test fails
      // with a timer still pending).
      await Get.delete<HomeController>(force: true);
      await tester.pumpWidget(const SizedBox());
      before = phones.listings;
      await tester.pump(const Duration(seconds: 3));
      expect(phones.listings, before);
    });
  });

  testWidgets('three cards fit an 800×600 window, and the Wi-Fi row is at '
      'the end of the list', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
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
      ..refused.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();

    final list = find.byType(Scrollable).first;
    for (final key in ['SERIAL-A', 'SERIAL-B', 'SERIAL-C']) {
      await tester.scrollUntilVisible(_card(key), 200, scrollable: list);
      expect(tester.takeException(), isNull, reason: key);
    }
    await tester.scrollUntilVisible(
      _wifiRow,
      200,
      scrollable: list,
    );
    await tester.pump();
    expect(_wifiRow, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The card's top row (name, status, action) and its chips at a narrow
  // window.
  for (final language in ['en', 'th']) {
    testWidgets('at 560 px a card keeps room for its name, its status ends '
        'short instead of running over, and its role chips wrap onto more '
        'lines than in a wide window ($language)', (tester) async {
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
      sessions[0]
        ..latencyMs.value = 8
        ..refreshRateHz.value = 120
        ..streamBitrate.value = 42000000
        ..granted.value = const GrantedCapture(
          width: 2960,
          height: 1848,
          fps: 120,
          shared: true,
        );
      sessions[1]
        ..errorKey.value = 'error_usb_unverified_client'
        ..retryPending.value = true
        ..phase.value = ConnectionPhase.error;
      await tester.pump();

      /// How many lines [key]'s chips take.
      int lines(String key) => {
        for (final c in SessionChoice.all)
          tester.getTopLeft(_role(key, c)).dy,
      }.length;

      expect(find.byType(DeviceCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      final narrow = {for (final k in ['SERIAL-A', 'SERIAL-B']) k: lines(k)};
      for (final key in ['SERIAL-A', 'SERIAL-B']) {
        // The tablet's name keeps some room beside its action.
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
      // The live one's status line is long: cut short, not overflowing.
      final status = find.descendant(
        of: _card('SERIAL-A'),
        matching: find.textContaining('2960×1848'),
      );
      expect(tester.widget<Text>(status).overflow, TextOverflow.ellipsis);
      expect(tester.widget<Text>(status).maxLines, 2);
      // All of it, in order: link, encoded size, rate, round trip, the
      // Wi-Fi-style bitrate, and that the encoder is shared.
      final words = AppTranslations().keys[language]!;
      expect(
        _said(tester, status),
        'USB-C · 2960×1848 · 120 fps · 8 ms · 42 Mbps · '
        '${words['home_status_shared']}',
      );
      expect(
        _said(
          tester,
          find.descendant(
            of: _card('SERIAL-B'),
            matching: find.textContaining('USB-C'),
          ),
        ),
        'USB-C · ${words['home_status_retrying']}',
      );
      // Picture settings beside Open remote keeps its whole label: no share
      // of the row goes to blank space.
      for (final (button, text) in [
        ('settings', words['home_picture_settings']!),
        ('open-remote', words['home_open_remote']!),
      ]) {
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.descendant(
              of: find.byKey(ValueKey('SERIAL-A/$button')),
              matching: find.text(text),
            ),
            matching: find.byType(RichText),
          ),
        );
        expect(label.didExceedMaxLines, isFalse, reason: button);
      }

      tester.view.physicalSize = const Size(1000, 1800);
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final key in ['SERIAL-A', 'SERIAL-B']) {
        expect(narrow[key], greaterThan(lines(key)), reason: key);
      }
    });
  }

  testWidgets('three cards in Thai, The Mac controls this device on each, a '
      'remembered row with its last role, rows held back by the cap, and the '
      'role chooser fit 800×600 and 560×1000', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
      _device('SERIAL-Y', 'Tablet Y'),
    ];
    sessions[2]
      ..errorKey.value = 'error_usb_unverified_client'
      ..phase.value = ConnectionPhase.error;
    Get.find<HomeController>().localAddresses.value = [
      '192.168.1.5',
      '10.0.0.7',
    ];
    await settings.setWifiListen(true);
    hub.wifiTurnedAway.value = 2;
    await tester.pump();

    final th = AppTranslations().keys['th']!;
    // Three tablets past the conservative estimate's two places: the Mac
    // sets the cap, not Maximum tablets (4), so the reason does not send
    // the user to Settings, where nothing could raise it.
    expect(hub.cap, 2);
    expect(settings.maxTablets, 4);
    final full = th['home_row_full_mac']!.replaceAll('@cap', '2');
    expect(full, isNot(contains(th['settings_title'] ?? 'การตั้งค่า')));
    final last =
        '${th['home_row_plugged_in']} · '
        '${th['home_row_last_role']!.replaceAll('@role', th['role_mac_controls']!)}';
    final list = find.byType(Scrollable).first;
    for (final s in sessions) {
      await tester.scrollUntilVisible(_card(s.key), 200, scrollable: list);
      expect(_chip(tester, s.key, _reverse).selected, isTrue);
      expect(tester.takeException(), isNull, reason: s.key);
    }
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(_wifiRow, 200, scrollable: list);
    await tester.pump();
    expect(
      find.descendant(
        of: _wifiRow,
        matching: find.textContaining(
          th['home_wifi_turned_away_mac']!
              .replaceAll('@n', '2')
              .replaceAll('@cap', '2'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('SERIAL-X'), matching: find.text(last)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('SERIAL-X'), matching: find.text(full)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('SERIAL-Y'), matching: find.text(full)),
      findsOneWidget,
    );
    expect(_pressable(tester, _chooseBtn('SERIAL-Y')), isFalse);
    expect(tester.takeException(), isNull);

    // A place frees up: the chooser of the new one, at both sizes.
    hub.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');
    await settings.setMaxTablets(4);
    expect(hub.cap, 4);
    hub.availableDevices.refresh();
    await tester.pump();
    expect(_pressable(tester, _chooseBtn('SERIAL-Y')), isTrue);
    await tester.tap(_chooseBtn('SERIAL-Y'));
    await dialog(tester);
    expect(_option('SERIAL-Y', _reverse), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(560, 1000);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('choose/SERIAL-Y/cancel')));
    await dialog(tester);
    expect(hub.connects, isEmpty);
    await tester.scrollUntilVisible(_card('SERIAL-A'), -200, scrollable: list);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('Accept devices over Wi-Fi', () {
    testWidgets("the Add a device panel's last row turns listening on and "
        'off, and says where the Mac is, whether it accepts yet, and how '
        'many devices it turned away', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester, 1, permissions: true);
      hub.availableDevices.value = [
        ...hub.availableDevices,
        _device('SERIAL-X', 'Tablet X'),
      ];
      final home = Get.find<HomeController>();
      home.localAddresses.value = [];
      await tester.pump();
      final toggle = find.descendant(
        of: _wifiRow,
        matching: find.byType(Switch),
      );
      Finder says(String text) =>
          find.descendant(of: _wifiRow, matching: find.textContaining(text));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(says('home_wifi_accept_desc · wifi_host_no_network'), findsOneWidget);
      expect(says('home_wifi_not_listening'), findsNothing);
      // Below every row of the panel.
      expect(
        tester.getTopLeft(_wifiRow).dy,
        greaterThan(tester.getBottomLeft(_row('SERIAL-X')).dy),
      );

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.wifiListen, isTrue);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(says('home_wifi_not_listening'), findsOneWidget);

      home.localAddresses.value = ['192.168.1.5'];
      hub.listening.value = true;
      hub.wifiTurnedAway.value = 2;
      await tester.pump();
      expect(says('home_wifi_accept_desc · home_wifi_mac_at'), findsOneWidget);
      expect(says('home_wifi_not_listening'), findsNothing);
      expect(says('home_wifi_turned_away'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.wifiListen, isFalse);
      expect(says('home_wifi_turned_away'), findsNothing);
    });

    testWidgets("a Wi-Fi device's card stops it like a tablet's, and offers "
        'no The Mac controls this device chip', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settings.setWifiListen(true);
      await start(tester, 1, permissions: true);
      const key = 'wifi:0101';
      hub.sessions[key] = HostSession(
        key: key,
        link: LinkType.wifi,
        beside: true,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      )
        ..activeDevice.value = const DeviceModel(
            serial: '192.168.1.20',
            model: 'iPhone',
            status: DeviceStatus.connected)
        ..phase.value = ConnectionPhase.streaming;
      await tester.pump();

      expect(_inCards(find.text('iPhone')), findsOneWidget);
      final status = find.descendant(
        of: _card(key),
        matching: find.textContaining('192.168.1.20'),
      );
      expect(status, findsOneWidget);
      expect(tester.widget<Text>(status).data, startsWith('Wi-Fi · 192.168.1.20'));
      expect(_role(key, _extended), findsOneWidget);
      expect(_role(key, _driving), findsOneWidget);
      expect(_role(key, _reverse), findsNothing);
      expect(_chip(tester, key, _extended).selected, isTrue);
      expect(_chip(tester, key, _driving).enabled, isTrue);

      await tester.tap(_action(key, 'common_disconnect'));
      await tester.pump();
      expect(hub.stops, [(key, true)]);
      expect(settings.wifiListen, isTrue, reason: 'listening goes on');
    });
  });
}
