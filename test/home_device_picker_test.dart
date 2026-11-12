import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/device_picker_card.dart';

/// Host-role manager whose `adb devices` result the test controls. Never
/// connects, so Home stays idle with the picker visible.
class _FakeHostManager extends BaseConnectionManager {
  List<DeviceModel> adbDevices = const [];
  int refreshCalls = 0;

  @override
  bool get isHost => true;

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
}
