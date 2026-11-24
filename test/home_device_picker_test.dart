import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
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

/// The Mac's hub, whose `adb devices` result the test controls. Never
/// connects, so Home stays idle with the Add a device panel visible.
class _FakeHostManager extends HostConnectionManager {
  _FakeHostManager() : super(socket: SocketService(), adb: _Adb());

  List<DeviceModel> adbDevices = const [];
  int refreshCalls = 0;

  /// What the hub was asked to connect, with the role each was given;
  /// nothing is connected. Every connect of the hub's comes through here.
  final connects = <(String?, SessionChoice?)>[];

  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async =>
      connects.add((serial, choice));

  @override
  Future<void> autoConnect() async {}

  @override
  Future<void> refreshDevices() async {
    refreshCalls++;
    availableDevices.value = List.of(adbDevices);
  }
}

/// adb that is never really asked: the fake hub lists the devices itself.
class _Adb extends AdbService {
  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async => const [];
}

const _tablet = DeviceModel(
  serial: 'SERIAL-A',
  model: 'Tablet A',
  status: DeviceStatus.connected,
);
const _phone = DeviceModel(
  serial: 'SERIAL-B',
  model: 'Phone B',
  status: DeviceStatus.connected,
);

Finder _inAdd(Finder matching) =>
    find.descendant(of: find.byType(AddDevicePanel), matching: matching);

/// The Add a device panel's row for the device [serial].
Finder _row(String serial) => find.byKey(ValueKey('device/$serial'));

/// [serial]'s Connect: on a remembered device, or on a new one (which asks
/// for the role first).
Finder _connectBtn(String serial) =>
    find.byKey(ValueKey('device/$serial/connect'));
Finder _chooseBtn(String serial) =>
    find.byKey(ValueKey('device/$serial/choose'));

bool _pressable(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

/// A live session for [serial] that the hub holds, as far as Home can tell.
HostSession _live(HostConnectionManager hub, String serial) {
  final session = HostSession(
    key: serial,
    link: LinkType.usb,
    serial: serial,
    pipeline: hub.pipeline,
    adb: _Adb(),
    socket: SocketService(),
  )..phase.value = ConnectionPhase.streaming;
  hub.adopt(session);
  return session;
}

void main() {
  late _FakeHostManager cm;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    Get.put(SocketService());
    final settings = SettingsService();
    await settings.init();
    Get.put(settings);
    cm = Get.put<BaseConnectionManager>(_FakeHostManager()) as _FakeHostManager;
    // No native permissions plugin in tests: the check reports nothing granted,
    // so the auto-connect path never runs and the panel stays on screen.
    Get.put(HomeController(iosPollInterval: null));
  });

  tearDown(Get.reset);

  testWidgets('refresh button shows newly attached devices', (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    await tester.pump();
    // Nothing attached: Home says what to do, and the panel lists nothing.
    expect(find.byKey(const ValueKey('home/empty')), findsOneWidget);
    expect(_row('SERIAL-A'), findsNothing);
    expect(find.text('device_none_detected'), findsNothing);

    cm.adbDevices = const [_tablet];
    await tester.tap(find.byKey(const ValueKey('add/refresh')));
    await tester.pump();

    // Busy while the refresh is held; the button is disabled meanwhile.
    expect(_inAdd(find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(_inAdd(find.byIcon(Icons.refresh)), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('add/refresh')))
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 300));
    expect(_inAdd(find.byType(CircularProgressIndicator)), findsNothing);
    expect(_row('SERIAL-A'), findsOneWidget);
    expect(_inAdd(find.text('Tablet A')), findsOneWidget);
    expect(find.byKey(const ValueKey('home/empty')), findsNothing);
  });

  testWidgets('list assigned outside the panel still repaints it', (
    tester,
  ) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    await tester.pump();

    // The auto-connect and connect() paths assign the list directly.
    cm.availableDevices.value = const [_tablet, _phone];
    await tester.pump();
    expect(_inAdd(find.text('Tablet A')), findsOneWidget);
    expect(_inAdd(find.text('Phone B')), findsOneWidget);

    cm.availableDevices.value = const [_phone];
    await tester.pump();
    expect(_inAdd(find.text('Tablet A')), findsNothing);
    expect(_inAdd(find.text('Phone B')), findsOneWidget);
  });

  testWidgets('taps during a running refresh are ignored', (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    await tester.pump();
    final before = cm.refreshCalls;

    final controller = Get.find<HomeController>();
    final first = controller.refreshDevices();
    await controller.refreshDevices();
    await tester.pump(const Duration(milliseconds: 300));
    await first;

    expect(cm.refreshCalls, before + 1);
    expect(controller.refreshingDevices.value, isFalse);
  });

  testWidgets('a tablet with a session leaves the panel for a card of its '
      'own', (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    cm.availableDevices.value = const [_tablet, _phone];
    _live(cm, 'SERIAL-A').activeDevice.value = _tablet;
    await tester.pump();

    expect(find.byType(DeviceCard), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DeviceCard),
        matching: find.text('Tablet A'),
      ),
      findsOneWidget,
    );
    expect(_row('SERIAL-A'), findsNothing);
    expect(_inAdd(find.text('Tablet A')), findsNothing);
    expect(_inAdd(find.text('Phone B')), findsOneWidget);
    expect(_inAdd(find.text('home_add_device')), findsOneWidget);
    expect(
      _inAdd(find.text('home_row_full')),
      findsNothing,
      reason: 'room for a second tablet',
    );
    expect(_pressable(tester, _chooseBtn('SERIAL-B')), isTrue);
  });

  testWidgets('with Maximum tablets at 1 another tablet cannot be added',
      (tester) async {
    await Get.find<SettingsService>().setMaxTablets(1);
    await tester.pumpWidget(
      GetMaterialApp(
        translations: AppTranslations(),
        locale: const Locale('en'),
        home: const HomeView(),
      ),
    );
    cm.availableDevices.value = const [_tablet, _phone];
    _live(cm, 'SERIAL-A');
    await tester.pump();

    expect(_inAdd(find.text('Phone B')), findsOneWidget);
    expect(find.text('Every plugged-in device is connected'), findsNothing);
    expect(
      find.descendant(
        of: _row('SERIAL-B'),
        matching: find.text('All 1 places are in use (Settings → Tablets)'),
      ),
      findsOneWidget,
    );
    expect(_pressable(tester, _chooseBtn('SERIAL-B')), isFalse);
  });

  testWidgets("a tablet the encoder can't take in its remembered role asks "
      'for another: its chooser shows the remembered role, not offered, and '
      'the one the Mac encodes nothing for, which connects it; a new one is '
      'offered the same', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = Get.find<SettingsService>();
    await settings.rememberDevice(
      'SERIAL-A',
      model: 'Tablet A',
      vdSerial: 7,
      choice: const SessionChoice(SessionMode.extendedScreen),
    );
    final next = settings.nextChoice;
    // Room under the cap, none in the encoder: something already takes
    // all of a tiny one.
    cm.budget.estimate = const EncoderEstimate(
        engines: 1, h264PerEngine: 1, h265PerEngine: 1);
    cm.budget.admit(999, DisplayConfigModel.defaultConfig, cap: 8);
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    cm.availableDevices.value = const [_tablet, _phone];
    await tester.pump();

    expect(cm.canAdd, isTrue);
    expect(_inAdd(find.text('Tablet A')), findsOneWidget);
    // No dead end: the row says its role has no room, and its Connect,
    // which asks for the role, can be pressed.
    expect(
      find.descendant(
        of: _row('SERIAL-A'),
        matching: find.text('home_row_role_no_room'),
      ),
      findsOneWidget,
    );
    expect(_connectBtn('SERIAL-A'), findsNothing);
    expect(_pressable(tester, _chooseBtn('SERIAL-A')), isTrue);
    expect(
      find.descendant(
        of: _row('SERIAL-B'),
        matching: find.text('home_row_encoder_full'),
      ),
      findsNothing,
    );
    expect(_pressable(tester, _chooseBtn('SERIAL-B')), isTrue);

    bool pickable(String serial, String option) =>
        tester
            .widget<InkWell>(
              find.descendant(
                of: find.byKey(ValueKey('choose/$serial/$option')),
                matching: find.byType(InkWell),
              ),
            )
            .onTap !=
        null;

    await tester.tap(_chooseBtn('SERIAL-B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(pickable('SERIAL-B', 'extendedScreen.tabControlsMac'), isFalse);
    expect(pickable('SERIAL-B', 'remoteControl.tabControlsMac'), isFalse);
    expect(pickable('SERIAL-B', 'remoteControl.macControlsTab'), isTrue);
    await tester.tap(find.byKey(const ValueKey('choose/SERIAL-B/cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(cm.connects, isEmpty);

    // The remembered tablet: the chooser starts on its remembered role.
    // Granted, so the pick connects.
    const permissions = MethodChannel('extended_screen/permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      permissions,
      (_) async => {'screen_recording': true, 'accessibility': true},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));
    await tester.tap(_chooseBtn('SERIAL-A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final remembered = find.descendant(
      of: find.byKey(
        const ValueKey('choose/SERIAL-A/extendedScreen.tabControlsMac'),
      ),
      matching: find.byType(Material),
    );
    expect(
      tester.widget<Material>(remembered.first).color,
      isNot(Colors.white.withValues(alpha: 0.04)),
      reason: 'the remembered role is the one highlighted',
    );
    expect(pickable('SERIAL-A', 'extendedScreen.tabControlsMac'), isFalse);
    expect(pickable('SERIAL-A', 'remoteControl.macControlsTab'), isTrue);
    await tester.tap(
      find.byKey(
        const ValueKey('choose/SERIAL-A/remoteControl.macControlsTab'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(cm.connects, [
      (
        'SERIAL-A',
        const SessionChoice(
          SessionMode.remoteControl,
          RemoteDirection.macControlsTab,
        ),
      ),
    ]);
    expect(
      settings.nextChoice,
      next,
      reason: "a remembered device's pick is not the next new one's role",
    );
  });

  testWidgets('a press on a row whose place is taken by another tablet '
      'meanwhile connects nothing', (tester) async {
    const c = DeviceModel(
      serial: 'SERIAL-C',
      model: 'Tablet C',
      status: DeviceStatus.connected,
    );
    final picked = <String>[];
    Widget panel(List<DeviceModel> devices) => MaterialApp(
      home: Scaffold(
        body: AddDevicePanel(
          rows: [
            for (final d in devices)
              AddDeviceRow(device: d, subtitle: '', asksRole: false),
          ],
          onConnect: (d) => picked.add(d.serial),
          onChoose: (d) => picked.add(d.serial),
          onRefresh: () {},
          wifiRow: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(panel(const [_tablet, _phone, c]));

    // The user presses B's Connect; before the finger lifts, A leaves the
    // list (it connected by itself), so C now stands where B was.
    final touch = await tester.startGesture(
      tester.getCenter(_connectBtn('SERIAL-B')),
    );
    await tester.pumpWidget(panel(const [_phone, c]));
    await touch.up();
    await tester.pump();

    expect(picked, isNot(contains('SERIAL-C')));
  });

  group('the rows and their buttons', () {
    late SettingsService settings;

    /// Screen Recording and Accessibility granted, so a press connects.
    void grant() {
      const channel = MethodChannel('extended_screen/permissions');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'screen_recording': true, 'accessibility': true},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    Future<void> home(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      grant();
      settings = Get.find<SettingsService>();
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      cm.availableDevices.value = const [_tablet, _phone];
      await tester.pump();
      await tester.pump();
      cm.connects.clear();
    }

    /// A panel over [rows], recording what each button asked for.
    Widget panel(
      List<AddDeviceRow> rows,
      List<String> connected,
      List<String> chosen, {
      Widget? wifiRow,
    }) => MaterialApp(
      home: Scaffold(
        body: AddDevicePanel(
          rows: rows,
          onConnect: (d) => connected.add(d.serial),
          onChoose: (d) => chosen.add(d.serial),
          onRefresh: () {},
          wifiRow: wifiRow ?? const SizedBox(),
        ),
      ),
    );

    testWidgets('rows stay keyed by device and by meaning: a remembered '
        "device's Connect connects it as it was, a new one's asks; a device "
        'that turns remembered (or new) under the finger takes no press', (
      tester,
    ) async {
      final connected = <String>[];
      final chosen = <String>[];
      const known = SessionChoice(
        SessionMode.remoteControl,
        RemoteDirection.macControlsTab,
      );
      await Get.find<SettingsService>().rememberDevice(
        'SERIAL-A',
        model: 'Tablet A',
        vdSerial: 7,
        choice: known,
      );
      await home(tester);
      expect(_connectBtn('SERIAL-A'), findsOneWidget);
      expect(_chooseBtn('SERIAL-A'), findsNothing);
      expect(_chooseBtn('SERIAL-B'), findsOneWidget);
      expect(_connectBtn('SERIAL-B'), findsNothing);
      await tester.tap(_connectBtn('SERIAL-A'));
      await tester.pump();
      await tester.pump();
      expect(cm.connects, [('SERIAL-A', known)]);
      expect(
        settings.nextChoice,
        const SessionChoice(SessionMode.extendedScreen),
        reason: 'no role was chosen',
      );

      // A device turning remembered while the finger is on its button.
      AddDeviceRow row(DeviceModel d, {required bool remembered}) =>
          AddDeviceRow(device: d, subtitle: '', asksRole: !remembered);
      await tester.pumpWidget(
        panel([row(_phone, remembered: false)], connected, chosen),
      );
      var touch = await tester.startGesture(
        tester.getCenter(_chooseBtn('SERIAL-B')),
      );
      await tester.pumpWidget(
        panel([row(_phone, remembered: true)], connected, chosen),
      );
      await touch.up();
      await tester.pump();
      expect(connected, isEmpty);
      expect(chosen, isEmpty);
      // And the other way round.
      touch = await tester.startGesture(
        tester.getCenter(_connectBtn('SERIAL-B')),
      );
      await tester.pumpWidget(
        panel([row(_phone, remembered: false)], connected, chosen),
      );
      await touch.up();
      await tester.pump();
      expect(connected, isEmpty);
      expect(chosen, isEmpty);
      // With nothing moving, each takes its own press.
      await tester.tap(_chooseBtn('SERIAL-B'));
      expect(chosen, ['SERIAL-B']);
    });

    testWidgets('a press on a row that the panel moves away from under the '
        'finger (a tablet connecting by itself puts its card above) connects '
        'at most the pressed device, and saves no role', (tester) async {
      await home(tester);
      await settings.rememberDevice(
        'SERIAL-B',
        model: 'Phone B',
        vdSerial: 7,
        choice: const SessionChoice(SessionMode.remoteControl),
      );
      cm.availableDevices.refresh();
      await tester.pump();
      final before = settings.nextChoice;

      final touch = await tester.startGesture(
        tester.getCenter(_connectBtn('SERIAL-B')),
      );
      // Tablet A connects by itself: its card pushes the panel down, and A
      // leaves the rows.
      _live(cm, 'SERIAL-A').activeDevice.value = _tablet;
      await tester.pump();
      expect(find.byType(DeviceCard), findsOneWidget);
      expect(_row('SERIAL-A'), findsNothing);
      await touch.up();
      await tester.pump();
      await tester.pump();

      expect(settings.nextChoice, before);
      // At most the tablet that was pressed, never another.
      expect(cm.connects.map((c) => c.$1), everyElement('SERIAL-B'));
    });

    testWidgets('the Wi-Fi row stays last: a press on it never lands on a '
        'row that joins above it, and a row press never toggles it', (
      tester,
    ) async {
      final connected = <String>[];
      final chosen = <String>[];
      final toggles = <bool>[];
      final wifi = Material(
        key: const ValueKey('add/wifi-listen'),
        child: SwitchListTile(
          value: false,
          onChanged: toggles.add,
          title: const Text('wifi'),
        ),
      );
      AddDeviceRow row(DeviceModel d) =>
          AddDeviceRow(device: d, subtitle: '', asksRole: false);
      final wifiFinder = find.byKey(const ValueKey('add/wifi-listen'));
      await tester.pumpWidget(
        panel([row(_tablet)], connected, chosen, wifiRow: wifi),
      );
      expect(
        tester.getTopLeft(wifiFinder).dy,
        greaterThan(tester.getBottomLeft(_row('SERIAL-A')).dy),
      );

      // The finger is on the Wi-Fi row when a device joins the list, so the
      // new row now stands where the finger is.
      final at = tester.getCenter(wifiFinder);
      var touch = await tester.startGesture(at);
      await tester.pumpWidget(
        panel([row(_tablet), row(_phone)], connected, chosen, wifiRow: wifi),
      );
      expect(tester.getRect(_row('SERIAL-B')).contains(at), isTrue);
      expect(
        tester.getTopLeft(wifiFinder).dy,
        greaterThan(tester.getBottomLeft(_row('SERIAL-B')).dy),
      );
      await touch.up();
      await tester.pump();
      expect(connected, isEmpty);
      expect(chosen, isEmpty);
      expect(
        toggles.length,
        lessThanOrEqualTo(1),
        reason: 'at most the row that was pressed',
      );
      toggles.clear();

      // The finger is on B's Connect when B leaves, so the Wi-Fi row moves
      // up under it.
      final onB = tester.getCenter(_connectBtn('SERIAL-B'));
      touch = await tester.startGesture(onB);
      await tester.pumpWidget(
        panel([row(_tablet)], connected, chosen, wifiRow: wifi),
      );
      await touch.up();
      await tester.pump();
      expect(toggles, isEmpty);
      expect(connected, everyElement('SERIAL-B'));
      connected.clear();

      // And with nothing moving, each takes its own press.
      await tester.tap(wifiFinder);
      await tester.tap(_connectBtn('SERIAL-A'));
      expect(toggles, [true]);
      expect(connected, ['SERIAL-A']);
    });
  });
}
