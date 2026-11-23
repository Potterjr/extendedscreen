import 'dart:async';

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
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// The Mac's hub with Settings' reconnects counted instead of done; its
/// sessions are adopted, never connected.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
      : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  /// [reconnect] calls.
  int reconnects = 0;

  /// [reconnectExtendedOnly] calls.
  int extendedOnly = 0;

  /// Every restart asked for, in order: 'all' or 'extended'.
  final calls = <String>[];

  /// Set: a restart does not return until the test completes its entry in
  /// [running] (a tablet taking its time to come back).
  bool hold = false;
  final running = <Completer<void>>[];

  Future<void> _restart(String what) {
    calls.add(what);
    if (!hold) return Future<void>.value();
    final gate = Completer<void>();
    running.add(gate);
    return gate.future;
  }

  @override
  Future<void> reconnect() {
    reconnects++;
    return _restart('all');
  }

  @override
  Future<void> reconnectExtendedOnly() {
    extendedOnly++;
    return _restart('extended');
  }

  // Where every connect of the hub's ends: nothing connects here.
  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {}

  @override
  Future<void> autoConnect() async {}
}

/// The Mac's hub as it is, restarts included: which sessions a change
/// restarts is the hub's own rule. Nothing connects.
class _RealHub extends HostConnectionManager {
  _RealHub(AdbService adb)
      : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {}

  @override
  Future<void> autoConnect() async {}
}

/// A tablet's session whose restarts are counted instead of done.
class _Session extends HostSession {
  _Session({
    required String serial,
    required SessionChoice choice,
    required super.pipeline,
    required AdbService adb,
  }) : super(
          key: serial,
          link: LinkType.usb,
          serial: serial,
          choice: choice,
          adb: adb,
          socket: SocketService(),
        );

  int restarts = 0;

  @override
  Future<void> reconnect() async => restarts++;
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
      {bool translated = false,
      Locale locale = const Locale('en'),
      Size size = const Size(1000, 3000)}) async {
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
            locale: locale,
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
    expect(hub.calls, isEmpty, reason: 'no restart of any kind');
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

  testWidgets('Maximum tablets says it counts tablets in any mode, in English '
      'and in Thai', (tester) async {
    putHub();
    await open(tester, translated: true);
    expect(
        find.textContaining(
            'How many tablets can connect over USB at once, in any mode'),
        findsOneWidget);
    expect(find.textContaining('Extended Screen mode'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    Get.delete<SettingsController>();
    addTearDown(() => Get.locale = null);
    await open(tester, translated: true, locale: const Locale('th'));
    expect(
        find.textContaining(
            'จำนวนแท็บเล็ตที่เชื่อมต่อผ่าน USB ได้พร้อมกัน ในทุกโหมด'),
        findsOneWidget);
    expect(find.textContaining('ในโหมดจอเสริม'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('what a change restarts', () {
    const debounce = Duration(milliseconds: 350);
    const past = Duration(milliseconds: 400);

    /// The display mode that is not the saved one.
    DisplayMode otherMode() => settings.displayMode == DisplayMode.extend
        ? DisplayMode.mirror
        : DisplayMode.extend;

    CodecType otherCodec() =>
        settings.codec == CodecType.h265 ? CodecType.h264 : CodecType.h265;

    testWidgets(
        'Extend/Mirror alone restarts only the tablets the Mac extends onto, '
        'once', (tester) async {
      final hub = putHub();
      await open(tester);
      final controller = Get.find<SettingsController>();
      expect(settings.displayMode, DisplayMode.extend);

      // The row itself, as the user presses it.
      await tester.tap(find.text('settings_mode_mirror'));
      await tester.pump();
      expect(settings.displayMode, DisplayMode.mirror, reason: 'saved at once');
      expect(controller.isApplying.value, isTrue);
      expect(hub.calls, isEmpty, reason: 'still waiting out the debounce');

      await tester.pump(past);
      expect(hub.calls, ['extended']);
      expect(hub.reconnects, 0, reason: 'no tablet in remote control restarts');
      expect(controller.isApplying.value, isFalse);

      // Nothing follows by itself.
      await tester.pump(const Duration(seconds: 2));
      expect(hub.calls, ['extended']);

      // Back again: once more, the same way.
      await tester.tap(find.text('settings_mode_extend'));
      await tester.pump();
      await tester.pump(past);
      expect(hub.calls, ['extended', 'extended']);

      // The mode it already has: nothing.
      controller.setMode(settings.displayMode);
      await tester.pump(past);
      expect(hub.calls, ['extended', 'extended']);
      expect(controller.isApplying.value, isFalse);
    });

    testWidgets(
        'Extend/Mirror and the codec within one debounce restart every '
        'tablet, once', (tester) async {
      final hub = putHub();
      await open(tester);
      final controller = Get.find<SettingsController>();

      controller.setMode(otherMode());
      await tester.pump(const Duration(milliseconds: 200));
      expect(hub.calls, isEmpty);
      controller.setCodec(otherCodec());
      await tester.pump(const Duration(milliseconds: 200));
      expect(hub.calls, isEmpty, reason: 'the second change restarted the wait');
      await tester.pump(const Duration(milliseconds: 200));
      expect(hub.calls, ['all']);
      expect(hub.extendedOnly, 0);
      expect(controller.isApplying.value, isFalse);

      // The other way round: the codec's need is not forgotten when the
      // display mode comes after it.
      controller.setCodec(otherCodec());
      await tester.pump(const Duration(milliseconds: 200));
      controller.setMode(otherMode());
      await tester.pump(past);
      expect(hub.calls, ['all', 'all']);

      // And it is not kept past the restart it caused: the display mode
      // alone is again the smaller restart.
      controller.setMode(otherMode());
      await tester.pump(past);
      expect(hub.calls, ['all', 'all', 'extended']);
      await tester.pump(const Duration(seconds: 2));
      expect(hub.calls, hasLength(3));
    });

    testWidgets('a preset, the codec and each custom value always restart '
        'every tablet', (tester) async {
      final hub = putHub();
      await open(tester);
      final controller = Get.find<SettingsController>();
      expect(settings.encodePreset, EncodePreset.max);

      var expected = 0;
      Future<void> restartsAll(void Function() change, String what) async {
        change();
        expect(controller.isApplying.value, isTrue, reason: what);
        await tester.pump(past);
        expected++;
        expect(hub.reconnects, expected, reason: what);
        expect(hub.extendedOnly, 0, reason: what);
        expect(controller.isApplying.value, isFalse, reason: what);
      }

      for (final preset in [
        EncodePreset.quality,
        EncodePreset.balanced,
        EncodePreset.performance,
        EncodePreset.custom,
        EncodePreset.max,
      ]) {
        await restartsAll(
            () => controller.setEncodePreset(preset), 'preset ${preset.name}');
      }
      await restartsAll(() => controller.setCodec(otherCodec()), 'codec');
      await restartsAll(
          () => controller.setCustomResolution(1282, 802), 'custom resolution');
      await restartsAll(() => controller.setCustomBitrate(7), 'custom bitrate');
      await restartsAll(
          () => controller.setCustomRefreshRate(45), 'custom refresh rate');
      expect(hub.calls, everyElement('all'));

      // A value it already has restarts nothing.
      controller.setEncodePreset(settings.encodePreset);
      controller.setCodec(settings.codec);
      controller.setCustomBitrate(7);
      await tester.pump(past);
      expect(hub.reconnects, expected);
      expect(controller.isApplying.value, isFalse);
    });

    testWidgets(
        "a codec changed while Extend/Mirror's restart still runs reaches "
        'every tablet: exactly one full restart follows', (tester) async {
      final hub = putHub()..hold = true;
      await open(tester);
      final controller = Get.find<SettingsController>();

      controller.setMode(otherMode());
      await tester.pump(past);
      expect(hub.calls, ['extended']);
      expect(controller.isApplying.value, isTrue, reason: 'still restarting');

      // Past the display mode's debounce, its restart not back yet.
      controller.setCodec(otherCodec());
      await tester.pump(past);
      expect(hub.calls, ['extended'],
          reason: 'one restart at a time: the next waits for this one');
      await tester.pump(const Duration(seconds: 3));
      expect(hub.calls, ['extended']);
      expect(controller.isApplying.value, isTrue);

      hub.running[0].complete();
      await tester.pump();
      expect(hub.calls, ['extended', 'all'],
          reason: 'the codec change was not dropped');
      expect(controller.isApplying.value, isTrue,
          reason: 'the rows stay disabled through the second restart');

      hub.running[1].complete();
      await tester.pump();
      expect(controller.isApplying.value, isFalse);
      await tester.pump(const Duration(seconds: 3));
      expect(hub.calls, ['extended', 'all'], reason: 'exactly one');
      expect(hub.reconnects, 1);
    });

    testWidgets(
        'a codec changed just before the running restart returns still gets '
        'exactly one full restart, and the rows stay disabled until it has',
        (tester) async {
      final hub = putHub()..hold = true;
      await open(tester);
      final controller = Get.find<SettingsController>();

      controller.setMode(otherMode());
      await tester.pump(past);
      expect(hub.calls, ['extended']);

      controller.setCodec(otherCodec());
      await tester.pump(const Duration(milliseconds: 100));
      // The first restart is back before the codec's debounce has run out.
      hub.running[0].complete();
      await tester.pump();
      expect(hub.calls, ['extended']);
      expect(controller.isApplying.value, isTrue,
          reason: "the codec's restart is still to come");

      await tester.pump(debounce);
      expect(hub.calls, ['extended', 'all']);
      hub.running[1].complete();
      await tester.pump();
      expect(controller.isApplying.value, isFalse);
      await tester.pump(const Duration(seconds: 3));
      expect(hub.calls, ['extended', 'all']);
    });

    testWidgets(
        'several changes during one running restart make one more, as big as '
        'the biggest of them needs', (tester) async {
      final hub = putHub()..hold = true;
      await open(tester);
      final controller = Get.find<SettingsController>();

      // A full restart runs; only the display mode changes meanwhile.
      controller.setCodec(otherCodec());
      await tester.pump(past);
      expect(hub.calls, ['all']);
      controller.setMode(otherMode());
      await tester.pump(past);
      hub.running[0].complete();
      await tester.pump();
      expect(hub.calls, ['all', 'extended'],
          reason: 'the finished restart does not make the next one bigger');

      // During that one: the display mode, a preset and the display mode
      // again, each past the other's debounce.
      controller.setMode(otherMode());
      await tester.pump(past);
      controller.setEncodePreset(EncodePreset.balanced);
      await tester.pump(past);
      controller.setMode(otherMode());
      await tester.pump(past);
      expect(hub.calls, ['all', 'extended']);
      hub.running[1].complete();
      await tester.pump();
      expect(hub.calls, ['all', 'extended', 'all'],
          reason: 'one restart for all three, and a full one for the preset');

      // A change whose debounce has not run out when the follow-up restart
      // starts is applied by it: no restart of its own afterwards.
      controller.setCodec(otherCodec());
      await tester.pump(past);
      controller.setMode(otherMode());
      await tester.pump(const Duration(milliseconds: 100));
      hub.running[2].complete();
      await tester.pump();
      expect(hub.calls, ['all', 'extended', 'all', 'all']);
      expect(controller.isApplying.value, isTrue);
      hub.running[3].complete();
      await tester.pump();
      expect(controller.isApplying.value, isFalse);
      await tester.pump(const Duration(seconds: 3));
      expect(hub.calls, hasLength(4));
    });

    testWidgets('a restart that fails still lets the one a later change asked '
        'for run', (tester) async {
      final hub = putHub()..hold = true;
      await open(tester);
      final controller = Get.find<SettingsController>();

      // The debounce timer belongs to the zone the change was made in, and
      // so does what its restart throws.
      final thrown = <Object>[];
      runZonedGuarded(
          () => controller.setMode(otherMode()), (e, _) => thrown.add(e));
      await tester.pump(past);
      controller.setCodec(otherCodec());
      await tester.pump(past);
      hub.running[0].completeError(StateError('adb went away'));
      await tester.pump();
      expect(hub.calls, ['extended', 'all']);
      expect(controller.isApplying.value, isTrue);
      expect(thrown, isEmpty, reason: 'not before the second restart is back');

      hub.running[1].complete();
      await tester.pump();
      expect(controller.isApplying.value, isFalse);
      expect(thrown, [isStateError],
          reason: 'the failure is still reported, as before');

      // And the next change starts clean.
      controller.setMode(otherMode());
      await tester.pump(past);
      expect(hub.calls, ['extended', 'all', 'extended']);
      hub.running[2].complete();
      await tester.pump();
      expect(controller.isApplying.value, isFalse);
    });

    testWidgets('leaving Settings before the debounce has run out applies the '
        'change at once', (tester) async {
      final hub = putHub();
      await open(tester);
      final controller = Get.find<SettingsController>();

      controller.setCodec(otherCodec());
      await tester.pump(const Duration(milliseconds: 100));
      expect(hub.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      Get.delete<SettingsController>();
      await tester.pump();
      expect(hub.calls, ['all']);
      // No timer is left behind, and nothing runs twice.
      await tester.pump(const Duration(seconds: 2));
      expect(hub.calls, ['all']);

      // With nothing waiting, leaving restarts nothing.
      await open(tester);
      await tester.pumpWidget(const SizedBox());
      Get.delete<SettingsController>();
      await tester.pump(const Duration(seconds: 2));
      expect(hub.calls, ['all']);
    });

    testWidgets(
        "through the hub's own rule: Extend/Mirror leaves a tablet the Mac "
        'controls, and one that drives the Mac, running; the codec restarts '
        'all three', (tester) async {
      final hub = Get.put<BaseConnectionManager>(_RealHub(adb)) as _RealHub;
      _Session tablet(String serial, SessionChoice choice) {
        final session = _Session(
            serial: serial, choice: choice, pipeline: hub.pipeline, adb: adb)
          ..activeDevice.value = DeviceModel(
              serial: serial, model: serial, status: DeviceStatus.connected)
          ..phase.value = ConnectionPhase.streaming;
        hub.sessions[serial] = session;
        return session;
      }

      final extended =
          tablet('A-EXTENDED', const SessionChoice(SessionMode.extendedScreen));
      final drivesMac = tablet(
          'B-DRIVES-MAC',
          const SessionChoice(
              SessionMode.remoteControl, RemoteDirection.tabControlsMac));
      final controlled = tablet(
          'C-CONTROLLED',
          const SessionChoice(
              SessionMode.remoteControl, RemoteDirection.macControlsTab));
      await open(tester);
      final controller = Get.find<SettingsController>();

      controller.setMode(otherMode());
      await tester.pump(past);
      expect(extended.restarts, 1);
      expect(controlled.restarts, 0,
          reason: 'its user is not asked to approve capture again');
      expect(drivesMac.restarts, 0, reason: 'it mirrors whatever the mode');
      expect(controller.isApplying.value, isFalse);

      controller.setCodec(otherCodec());
      await tester.pump(past);
      expect([extended.restarts, drivesMac.restarts, controlled.restarts],
          [2, 1, 1]);

      // With no tablet the Mac extends onto, Extend/Mirror is only saved.
      extended.phase.value = ConnectionPhase.disconnected;
      hub.sessions.remove('A-EXTENDED');
      controller.setMode(otherMode());
      await tester.pump(past);
      expect([extended.restarts, drivesMac.restarts, controlled.restarts],
          [2, 1, 1]);
      expect(controller.isApplying.value, isFalse);
    });
  });
}
