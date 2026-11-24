import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/shared/features/settings/views/ios_devices_debug_card.dart';
import 'package:extendedscreen/shared/platform/ios_device_service.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';

/// Settings → Wi-Fi → "iPhones (debug)", the P0 spike's Pair trigger.

class _Service extends IosDeviceService {
  _Service(this.devices);
  List<IosDevice>? devices;
  final pairs = <String>[];
  final simulators = <String>[];
  Completer<IosDelivery>? answer;

  @override
  Future<List<IosDevice>?> list() async => devices;

  @override
  Future<IosDelivery> deliverPairing(
    String udid, {
    Uint8List? payload,
    bool simulator = false,
  }) {
    pairs.add(udid);
    if (simulator) simulators.add(udid);
    return (answer = Completer<IosDelivery>()).future;
  }
}

const _ready = IosDevice(
  udid: 'U-READY',
  name: "Owner's iPhone",
  model: 'iPhone 18 Pro Max',
  transportType: 'wired',
  pairingState: 'paired',
  developerModeStatus: 'enabled',
);
const _off = IosDevice(
  udid: 'U-OFF',
  name: 'iPhone 17',
  model: 'iPhone 17',
  transportType: 'wired',
  pairingState: 'paired',
  developerModeStatus: 'disabled',
);

const _sim = IosDevice(
  udid: 'S-BOOTED',
  name: 'ES iPhone 17 Pro Max',
  model: 'iPhone 17 Pro Max',
  isSimulator: true,
  simulatorState: 'Booted',
  runtime: 'iOS 26.5',
);

Widget _app(IosDeviceService service, {Locale locale = const Locale('en')}) =>
    GetMaterialApp(
      translations: AppTranslations(),
      locale: locale,
      home: Scaffold(body: IosDevicesDebugCard(service: service)),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('lists each iPhone; Pair only where a pairing can go, and shows '
      'its answer', (tester) async {
    final service = _Service([_ready, _off]);
    await tester.pumpWidget(_app(service));
    await tester.pump();

    expect(find.text("Owner's iPhone · iPhone 18 Pro Max"), findsOneWidget);
    expect(find.text('Ready to pair'), findsOneWidget);
    expect(find.text('Developer Mode is off on the iPhone'), findsOneWidget);
    final off = tester.widget<TextButton>(
        find.byKey(const ValueKey('ios-debug/pair/U-OFF')));
    expect(off.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('ios-debug/pair/U-READY')));
    await tester.pump();
    expect(service.pairs, ['U-READY']);
    expect(find.text('Pairing…'), findsOneWidget);
    service.answer!.complete(IosDelivery.stored);
    await tester.pump();
    expect(find.text('Paired'), findsOneWidget);
  });

  testWidgets('labels a simulator and pairs it through the simulator path',
      (tester) async {
    final service = _Service([_ready, _sim]);
    await tester.pumpWidget(_app(service));
    await tester.pump();

    expect(find.text('ES iPhone 17 Pro Max · Simulator iOS 26.5'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ios-debug/pair/S-BOOTED')));
    await tester.pump();
    expect(service.simulators, ['S-BOOTED']);
    service.answer!.complete(IosDelivery.notInstalled);
    await tester.pump();
    expect(find.text('The app is not installed on the simulator'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ios-debug/pair/U-READY')));
    await tester.pump();
    expect(service.pairs, ['S-BOOTED', 'U-READY']);
    expect(service.simulators, ['S-BOOTED'], reason: 'a device is no sim');
  });

  testWidgets('says when devicectl lists nothing, in Thai too', (tester) async {
    await tester.pumpWidget(_app(_Service(const []), locale: const Locale('th')));
    await tester.pump();
    expect(find.text('devicectl ไม่พบ iPhone'), findsOneWidget);
    expect(find.text('iPhone (ดีบัก)'), findsOneWidget);
  });

  testWidgets('says when devicectl cannot be asked', (tester) async {
    await tester.pumpWidget(_app(_Service(null)));
    await tester.pump();
    expect(find.text('devicectl could not be asked'), findsOneWidget);
  });
}
