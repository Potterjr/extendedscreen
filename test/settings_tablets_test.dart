import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/features/settings/controllers/settings_controller.dart';
import 'package:extendedscreen/shared/features/settings/views/settings_view.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// The Mac's hub with Settings' reconnects counted instead of done; its
/// sessions are adopted, never connected.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
      : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  int reconnects = 0;

  @override
  Future<void> reconnect() async => reconnects++;

  @override
  Future<void> connect({String? serial}) async {}

  @override
  Future<void> autoConnect() async {}
}

/// The tablet's manager.
class _Client extends BaseConnectionManager {
  @override
  bool get isHost => false;

  @override
  Future<void> connect({String? serial}) async {}

  @override
  Future<void> autoConnect() async {}
}

class _Adb extends AdbService {
  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async => const [];
}

const _permissions = MethodChannel('extended_screen/permissions');

void main() {
  late SettingsService settings;
  late _Adb adb;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    Get.put(SocketService());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    adb = _Adb();
  });

  tearDown(Get.reset);

  _Hub putHub() => Get.put<BaseConnectionManager>(_Hub(adb)) as _Hub;

  /// A live USB session for [serial] in [hub], showing [model].
  HostSession live(_Hub hub, String serial, String model) {
    final session = HostSession(
      key: serial,
      link: LinkType.usb,
      serial: serial,
      pipeline: hub.pipeline,
      adb: adb,
      socket: SocketService(),
    )
      ..activeDevice.value = DeviceModel(
          serial: serial, model: model, status: DeviceStatus.connected)
      ..phase.value = ConnectionPhase.streaming;
    hub.sessions[serial] = session;
    return session;
  }

  /// Settings, tall enough that every row is built. [translated] uses the
  /// real English strings instead of the keys.
  Future<void> open(WidgetTester tester,
      {bool translated = false, Size size = const Size(1000, 3000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _permissions,
      (_) async => {'screen_recording': true, 'accessibility': true},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(_permissions, null));
    Get.put(SettingsController());
    await tester.pumpWidget(translated
        ? GetMaterialApp(
            translations: AppTranslations(),
            locale: const Locale('en'),
            fallbackLocale: const Locale('en'),
            home: const SettingsView(),
          )
        : const GetMaterialApp(home: SettingsView()));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the Mac shows Maximum tablets and the Encoder line',
      (tester) async {
    putHub();
    await open(tester);

    expect(find.text('SETTINGS_SECTION_TABLETS'), findsOneWidget);
    expect(find.text('settings_max_tablets'), findsOneWidget);
    expect(find.text('settings_max_tablets_desc'), findsOneWidget);
    expect(find.text('${SettingsService.defaultMaxTablets}'), findsOneWidget);
    expect(find.text('settings_encoder'), findsOneWidget);
  });

  testWidgets('the tablet shows neither', (tester) async {
    Get.put<BaseConnectionManager>(_Client());
    await open(tester);

    expect(find.text('settings_max_tablets'), findsNothing);
    expect(find.text('settings_encoder'), findsNothing);
    expect(find.text('SETTINGS_SECTION_TABLETS'), findsNothing);
  });

  testWidgets('the Encoder line names the chip, the codec and its estimate',
      (tester) async {
    final hub = putHub();
    hub.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');
    hub.hostInfo.value = const HostInfo(chip: 'Apple M3 Pro', os: '15.5');
    await settings.setCodec(CodecType.h265);
    await open(tester, translated: true);

    expect(find.text('Apple M3 Pro · H.265 · 550 Mpx/s (estimated)'),
        findsOneWidget);

    // This Mac's encoder was seen to manage more: measured, and the line
    // follows with nothing else changing.
    hub.budget.setLearned(CodecType.h265, 772.4);
    hub.capacityChanges.value++;
    await tester.pump();
    expect(find.text('Apple M3 Pro · H.265 · 772 Mpx/s (measured)'),
        findsOneWidget);
    hub.budget.setLearned(CodecType.h265, null);

    // Before the chip is read: the conservative guess, with no chip named.
    hub.hostInfo.value = null;
    hub.budget.estimate = EncoderEstimate.conservative;
    Get.find<SettingsController>().setCodec(CodecType.h264);
    await tester.pump();
    expect(find.text('H.264 · 140 Mpx/s (estimated)'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('picking 2 tablets saves it and reconnects nothing',
      (tester) async {
    final hub = putHub();
    await open(tester);

    await tester.tap(find.text('settings_max_tablets'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(ListTile, '2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('max_tablets'), 2);
    expect(settings.maxTablets, 2);
    expect(find.text('2'), findsOneWidget, reason: "the row's value");
    // Past the settings debounce: still nothing restarted.
    await tester.pump(const Duration(seconds: 1));
    expect(hub.reconnects, 0);
    expect(Get.find<SettingsController>().isApplying.value, isFalse);
  });

  testWidgets(
      "the preset labels use the focused tablet's panel, not the last one "
      'reported', (tester) async {
    final hub = putHub();
    await settings.setClientPanelFor('SERIAL-A', const ClientPanel(2560, 1600, 60));
    // Another tablet reported last.
    await settings.setClientPanelFor('SERIAL-B', const ClientPanel(2960, 1848, 120));
    expect(settings.lastClientPanel, const ClientPanel(2960, 1848, 120));
    hub.adopt(live(hub, 'SERIAL-A', 'Tab A'));
    // Translated: the presets' raw keys are too long for their rows.
    await open(tester, translated: true);

    await tester.tap(find.text('Encode Preset'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Max, Quality and Balanced at the panel's native size.
    expect(find.text('2560×1600'), findsNWidgets(3));
    expect(find.text('1280×800'), findsOneWidget, reason: 'Performance');
    expect(find.text('2960×1848'), findsNothing);
    final controller = Get.find<SettingsController>();
    expect(controller.refreshRateFor(EncodePreset.max), 60);
    expect(controller.customResolutions.first, (w: 2560, h: 1600));

    // Focusing the other tablet relabels them.
    hub.adopt(live(hub, 'SERIAL-B', 'Tab B'));
    await tester.pump();
    expect(find.text('2960×1848'), findsNWidgets(3));
    expect(controller.refreshRateFor(EncodePreset.max), 120);
  });

  testWidgets('with no tablet focused the labels use the last panel',
      (tester) async {
    putHub();
    await settings.setClientPanelFor('SERIAL-B', const ClientPanel(2960, 1848, 120));
    await open(tester);

    final controller = Get.find<SettingsController>();
    expect(controller.panelForLabels, const ClientPanel(2960, 1848, 120));
    expect(controller.resolutionLabelFor(EncodePreset.quality), '2960×1848');
    expect(controller.resolutionLabelFor(EncodePreset.quality),
        EncodePreset.quality.resolutionLabel,
        reason: 'one tablet sees what it saw before');
  });

  testWidgets('the target device row lists the live tablets', (tester) async {
    final hub = putHub();
    hub.adopt(live(hub, 'SERIAL-A', 'Galaxy Tab S10 Ultra'));
    live(hub, 'SERIAL-B', 'Galaxy Tab S9');
    // Not live yet: not listed.
    live(hub, 'SERIAL-C', 'Galaxy Tab A9')
        .phase
        .value = ConnectionPhase.handshaking;
    await open(tester);

    expect(find.text('Galaxy Tab S10 Ultra, Galaxy Tab S9'), findsOneWidget);

    // None live: the focused tablet's model, as with one tablet.
    hub.sessions['SERIAL-A']!.phase.value = ConnectionPhase.error;
    hub.sessions['SERIAL-B']!.phase.value = ConnectionPhase.error;
    await tester.pump();
    expect(find.text('Galaxy Tab S10 Ultra'), findsOneWidget);
  });

  testWidgets('a long Encoder value ellipsizes without overflowing',
      (tester) async {
    final hub = putHub();
    const chip = 'Apple M3 Ultra with an improbably long brand string that '
        'goes on and on well past the width of any settings card';
    hub.budget.estimate = EncoderEstimate.forChip(chip);
    hub.hostInfo.value = const HostInfo(chip: chip, os: '15.5');
    // Translated: the other rows' raw keys would not fit a narrow window.
    await open(tester, translated: true, size: const Size(420, 3000));

    expect(tester.takeException(), isNull);
    final value = tester.widget<Text>(
        find.textContaining('Apple M3 Ultra with an improbably long'));
    expect(value.overflow, TextOverflow.ellipsis);
    expect(value.maxLines, 1);
    final row = find.ancestor(of: find.text('Encoder'),
        matching: find.byType(Row));
    expect(tester.getSize(row.first).width, lessThanOrEqualTo(420));
  });
}
