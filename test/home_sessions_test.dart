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
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/session_card.dart';

/// The Mac's hub with what Home asks of it recorded instead of done: the
/// sessions are adopted, never connected.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
    : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  final stops = <(String, bool)>[];
  final connects = <String?>[];
  int disconnects = 0;

  @override
  Future<void> disconnectSession(
    String key, {
    bool userStopped = false,
  }) async => stops.add((key, userStopped));

  @override
  Future<void> connect({String? serial}) async => connects.add(serial);

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> autoConnect() async {}
}

/// adb listing the tablets the test attached.
class _Adb extends AdbService {
  List<DeviceModel> devices = const [];
  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async => devices;
}

const _permissions = MethodChannel('extended_screen/permissions');

DeviceModel _device(String serial, String model) =>
    DeviceModel(serial: serial, model: model, status: DeviceStatus.connected);

/// The action button of [key]'s card that reads [label].
Finder _action(String key, String label) => find.byKey(ValueKey('$key/$label'));

Finder _card(String key) => find.byKey(ValueKey('session/$key'));

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

  /// Home over [count] live tablets, `SERIAL-A`, `SERIAL-B`, … (the first
  /// one focused), all attached.
  Future<List<HostSession>> start(
    WidgetTester tester,
    int count, {
    bool permissions = false,
    bool translated = false,
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
      final letter = String.fromCharCode(0x41 + i);
      final device = _device(
        'SERIAL-$letter',
        'A rather long tablet model '
            'name $letter',
      );
      devices.add(device);
      final session =
          HostSession(
              key: device.serial,
              link: LinkType.usb,
              serial: device.serial,
              pipeline: hub.pipeline,
              adb: adb,
              socket: SocketService(),
            )
            ..activeDevice.value = device
            ..phase.value = ConnectionPhase.streaming;
      hub.sessions[device.serial] = session;
      sessions.add(session);
    }
    if (sessions.isNotEmpty) hub.adopt(sessions.first);
    adb.devices = devices;
    hub.availableDevices.value = devices;
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
      find.text('session_extended_label'),
      findsNWidgets(2),
      reason: "each card's mode chip; the title no longer shows it",
    );
    expect(find.text('home_all_attached_connected'), findsOneWidget);
    // Several tablets: the selectors would change what each one runs.
    expect(find.text('session_extended_desc'), findsNothing);
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
    expect(
      find.text('session_extended_label'),
      findsNWidgets(2),
      reason: 'the title shows the mode, as before, and so does the card',
    );
    expect(find.text('home_appbar_tablets'), findsNothing);
    expect(find.text('link_usb_desc'), findsNothing, reason: 'live');

    // Waiting to retry is idle: the selectors are back.
    sessions[0]
      ..retryPending.value = true
      ..phase.value = ConnectionPhase.error;
    await tester.pump();
    expect(find.text('link_usb_desc'), findsOneWidget);
    expect(_action('SERIAL-A', 'common_cancel'), findsOneWidget);
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

  testWidgets('while a Disconnect of every tablet still runs, the freed '
      'tablet is not short of room, and there is nothing to disconnect', (
    tester,
  ) async {
    await settings.setSessionMode(SessionMode.remoteControl);
    await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester, 1);
    expect(hub.cap, 1);

    // The remote view's Disconnect: the session is out of the hub at once,
    // while the facade still reads its phase until the end.
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
}
