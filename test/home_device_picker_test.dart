import 'package:flutter/material.dart';
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

  @override
  Future<void> connect({String? serial}) async {}

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
}
