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
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/device_picker_card.dart';
import 'package:extendedscreen/shared/widgets/session_card.dart';

/// The Mac's hub, whose `adb devices` result the test controls. Never
/// connects, so Home stays idle with the picker visible.
class _FakeHostManager extends HostConnectionManager {
  _FakeHostManager() : super(socket: SocketService(), adb: _Adb());

  List<DeviceModel> adbDevices = const [];
  int refreshCalls = 0;

  /// What the hub was asked to connect, with the mode each was given;
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

Finder _inPicker(Finder matching) =>
    find.descendant(of: find.byType(DevicePickerCard), matching: matching);

/// The add panel's tile for the device [serial].
Finder _tile(String serial) => find.byKey(ValueKey('device/$serial'));

/// The add panel's selector option for what the next tablet runs as:
/// `mode/<name>` or `dir/<name>`.
Finder _next(String option) => find.byKey(ValueKey('next/$option'));

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
    // so the auto-connect path never runs and the picker stays on screen.
    Get.put(HomeController());
  });

  tearDown(Get.reset);

  testWidgets('refresh button shows newly attached devices', (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    await tester.pump();
    expect(_inPicker(find.text('device_none_detected')), findsOneWidget);

    cm.adbDevices = const [_tablet];
    await tester.tap(_inPicker(find.byIcon(Icons.refresh)));
    await tester.pump();

    // Busy while the refresh is held; the button is disabled meanwhile.
    expect(_inPicker(find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(_inPicker(find.byIcon(Icons.refresh)), findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
    expect(_inPicker(find.byType(CircularProgressIndicator)), findsNothing);
    expect(_inPicker(find.text('Tablet A')), findsOneWidget);
    expect(_inPicker(find.text('device_none_detected')), findsNothing);
  });

  testWidgets('list assigned outside the picker still repaints it',
      (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    await tester.pump();

    // The auto-connect and connect() paths assign the list directly.
    cm.availableDevices.value = const [_tablet, _phone];
    await tester.pump();
    expect(_inPicker(find.text('Tablet A')), findsOneWidget);
    expect(_inPicker(find.text('Phone B')), findsOneWidget);

    cm.availableDevices.value = const [_phone];
    await tester.pump();
    expect(_inPicker(find.text('Tablet A')), findsNothing);
    expect(_inPicker(find.text('Phone B')), findsOneWidget);
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

  testWidgets('a tablet with a session leaves the picker for a card of its '
      'own', (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    cm.availableDevices.value = const [_tablet, _phone];
    _live(cm, 'SERIAL-A').activeDevice.value = _tablet;
    await tester.pump();

    expect(find.byType(SessionCard), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SessionCard), matching: find.text('Tablet A')),
        findsOneWidget);
    expect(_inPicker(find.text('Tablet A')), findsNothing);
    expect(_inPicker(find.text('Phone B')), findsOneWidget);
    expect(_inPicker(find.text('home_add_tablet')), findsOneWidget);
    expect(_inPicker(find.text('home_at_limit')), findsNothing,
        reason: 'room for a second tablet');
  });

  testWidgets('with Maximum tablets at 1 another tablet cannot be added',
      (tester) async {
    await Get.find<SettingsService>().setMaxTablets(1);
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    cm.availableDevices.value = const [_tablet, _phone];
    _live(cm, 'SERIAL-A');
    await tester.pump();

    expect(_inPicker(find.text('Phone B')), findsOneWidget);
    expect(_inPicker(find.text('home_at_limit')), findsOneWidget);
    expect(_inPicker(find.byIcon(Icons.chevron_right)), findsNothing);
    final tile = tester.widget<InkWell>(find
        .ancestor(of: find.text('Phone B'), matching: find.byType(InkWell))
        .first);
    expect(tile.onTap, isNull);
  });

  testWidgets("a tablet the encoder can't take is offered disabled",
      (tester) async {
    // Room under the cap, none in the encoder: something already takes
    // all of a tiny one.
    cm.budget.estimate = const EncoderEstimate(
        engines: 1, h264PerEngine: 1, h265PerEngine: 1);
    cm.budget.admit(999, DisplayConfigModel.defaultConfig, cap: 8);
    await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
    cm.availableDevices.value = const [_tablet];
    await tester.pump();

    expect(cm.canAdd, isTrue);
    expect(_inPicker(find.text('Tablet A')), findsOneWidget);
    expect(_inPicker(find.text('home_at_limit')), findsOneWidget);
  });

  testWidgets('a press on a tile whose place is taken by another tablet '
      'meanwhile picks nothing', (tester) async {
    const c = DeviceModel(
      serial: 'SERIAL-C',
      model: 'Tablet C',
      status: DeviceStatus.connected,
    );
    final picked = <String>[];
    Widget picker(List<DeviceModel> devices) => MaterialApp(
          home: Scaffold(
            body: DevicePickerCard(
              devices: devices,
              onSelect: (d) => picked.add(d.serial),
              onRefresh: () {},
            ),
          ),
        );
    await tester.pumpWidget(picker(const [_tablet, _phone, c]));

    // The user presses B; before the finger lifts, A leaves the list (it
    // connected by itself), so C now stands where B was.
    final touch = await tester.startGesture(tester.getCenter(find.text('Phone B')));
    await tester.pumpWidget(picker(const [_phone, c]));
    await touch.up();
    await tester.pump();

    expect(picked, isNot(contains('SERIAL-C')));
  });

  group('the mode selectors above the tiles', () {
    late SettingsService settings;

    /// Screen Recording and Accessibility granted, so a tile press connects.
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

    testWidgets('the tiles stay keyed by their device, under the selectors, '
        'and each press is its own: an option only saves, a tile only '
        'connects', (tester) async {
      await home(tester);

      expect(_inPicker(_tile('SERIAL-A')), findsOneWidget);
      expect(_inPicker(_tile('SERIAL-B')), findsOneWidget);
      expect(_inPicker(_next('mode/extendedScreen')), findsOneWidget);
      expect(_inPicker(_next('mode/remoteControl')), findsOneWidget);
      expect(_next('dir/macControlsTab'), findsNothing);
      // Header, the mode for the next tablet, then the tablets.
      final header = tester.getBottomLeft(find.text('home_add_tablet')).dy;
      final caption = tester.getTopLeft(find.text('home_next_tablet_mode')).dy;
      final option = tester.getBottomLeft(_next('mode/remoteControl')).dy;
      expect(caption, greaterThan(header));
      expect(option, greaterThan(caption));
      expect(tester.getTopLeft(_tile('SERIAL-A')).dy, greaterThan(option));

      // An option: saved, nothing connected, the tiles as they were (the
      // direction now stands between them and the mode).
      await tester.tap(_next('mode/remoteControl'));
      await tester.pump();
      await tester.pump();
      expect(settings.sessionMode, SessionMode.remoteControl);
      expect(cm.connects, isEmpty);
      expect(_inPicker(_next('dir/macControlsTab')), findsOneWidget);
      expect(
        tester.getTopLeft(_tile('SERIAL-A')).dy,
        greaterThan(tester.getBottomLeft(_next('dir/macControlsTab')).dy),
      );
      await tester.tap(_next('dir/macControlsTab'));
      await tester.pump();
      await tester.pump();
      expect(settings.remoteDirection, RemoteDirection.macControlsTab);
      expect(cm.connects, isEmpty);

      // A tile: that tablet, in the mode the selectors show; they stay.
      await tester.tap(_tile('SERIAL-B'));
      await tester.pump();
      await tester.pump();
      expect(cm.connects, [
        (
          'SERIAL-B',
          const SessionChoice(
            SessionMode.remoteControl,
            RemoteDirection.macControlsTab,
          ),
        ),
      ]);
      expect(settings.sessionMode, SessionMode.remoteControl);
      expect(settings.remoteDirection, RemoteDirection.macControlsTab);
    });

    testWidgets('a press on a tile that the panel moves away from under the '
        'finger (a tablet connecting by itself puts its card above) changes '
        'no selector', (tester) async {
      await home(tester);
      await settings.setSessionMode(SessionMode.remoteControl);
      await tester.pump();
      final before = settings.nextChoice;

      final touch = await tester.startGesture(
        tester.getCenter(_tile('SERIAL-B')),
      );
      // Tablet A connects by itself: its card pushes the panel down, and A
      // leaves the tiles.
      _live(cm, 'SERIAL-A').activeDevice.value = _tablet;
      await tester.pump();
      expect(find.byType(SessionCard), findsOneWidget);
      expect(_tile('SERIAL-A'), findsNothing);
      await touch.up();
      await tester.pump();
      await tester.pump();

      expect(settings.nextChoice, before);
      // At most the tablet that was pressed, never another.
      expect(cm.connects.map((c) => c.$1), everyElement('SERIAL-B'));
    });

    testWidgets('a press on a tile is never an option\'s, and a press on an '
        "option never a tile's, whatever the list does meanwhile", (
      tester,
    ) async {
      final picked = <String>[];
      final options = <String>[];
      // As wide as the card and about as tall as a tile, as the real
      // selectors are.
      Widget option(String name) => SizedBox(
        key: ValueKey('next/$name'),
        width: double.infinity,
        height: 56,
        child: TextButton(
          onPressed: () => options.add(name),
          child: Text(name),
        ),
      );
      Widget picker(List<DeviceModel> devices, List<String> leading) =>
          MaterialApp(
            home: Scaffold(
              body: DevicePickerCard(
                devices: devices,
                leading: [for (final name in leading) option(name)],
                onSelect: (d) => picked.add(d.serial),
                onRefresh: () {},
              ),
            ),
          );
      await tester.pumpWidget(picker(const [_tablet, _phone], ['mode']));
      expect(
        tester.getTopLeft(_tile('SERIAL-A')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(_next('mode')).dy),
      );

      // The finger is on tile A when one more row comes in above the tiles,
      // so that row now stands where the finger is.
      final at = tester.getCenter(_tile('SERIAL-A'));
      var touch = await tester.startGesture(at);
      await tester.pumpWidget(picker(const [_tablet, _phone], ['mode', 'dir']));
      expect(tester.getRect(_next('dir')).contains(at), isTrue);
      await touch.up();
      await tester.pump();
      expect(options, isEmpty);
      expect(picked, everyElement('SERIAL-A'));
      picked.clear();

      // The finger is on that row when it goes again, so a tile now stands
      // there.
      final onOption = tester.getCenter(_next('dir'));
      touch = await tester.startGesture(onOption);
      await tester.pumpWidget(picker(const [_tablet, _phone], ['mode']));
      expect(tester.getRect(_tile('SERIAL-A')).contains(onOption), isTrue);
      await touch.up();
      await tester.pump();
      expect(picked, isEmpty);
      expect(options, isEmpty);

      // And with nothing moving, each takes its own press.
      await tester.tap(_next('mode'));
      await tester.tap(_tile('SERIAL-B'));
      expect(options, ['mode']);
      expect(picked, ['SERIAL-B']);
    });
  });
}
