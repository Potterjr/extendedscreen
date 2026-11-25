import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_window_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/tablet_remote_window.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/tablet_window_opener.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/splash/controllers/splash_controller.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// What `adb devices` would list, as soon as [answer] lets it (adb's first
/// call after login can take seconds; a wedged one never answers).
class _Adb extends AdbService {
  List<DeviceModel> devices = const [];
  Completer<void>? answer;

  /// How many times the devices were listed.
  int listings = 0;

  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async {
    await answer?.future;
    listings++;
    return devices;
  }
}

/// The real host, up to the point where it would open a server: what it was
/// asked to connect to is recorded instead, at the one place every connect
/// of the hub's goes through (the user's `connect`, the auto-connect
/// policy's starts, a link change), with the mode each was given. No device
/// poll unless [poll] says how often; [granted] stands in for the permission
/// check (by default the mocked permissions channel answers).
class _LaunchHost extends HostConnectionManager {
  _LaunchHost({Duration? poll, Future<bool> Function()? granted})
      : super(
            socket: SocketService(),
            devicePollInterval: poll,
            hostGranted: granted);

  final connects = <String?>[];

  /// The mode each of [connects] was given: the selectors' for the user's
  /// own connect, the tablet's remembered one for the policy's, and null
  /// where the policy had none to give (the hub then takes the selectors').
  final choices = <SessionChoice?>[];

  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {
    connects.add(serial);
    choices.add(choice);
    phase.value = ConnectionPhase.handshaking;
  }

  // Nothing was started, so nothing to stop; the base disconnect() still
  // counts as the user's Cancel.
  @override
  Future<void> onTeardown() async {}
}

/// Counts what the splash asked of the connection.
class _CountingManager extends BaseConnectionManager {
  _CountingManager() : super(socket: SocketService());

  int autoConnects = 0;
  int connects = 0;

  @override
  bool get isHost => true;
  @override
  Future<void> connect({String? serial}) async => connects++;
  @override
  Future<void> autoConnect() async => autoConnects++;
}

/// The routes pushed after Home, by name.
class _Pushes extends NavigatorObserver {
  final names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name != AppRoutes.home) names.add(route.settings.name);
  }
}

/// Native remote windows recorded instead of opened: a second open of an
/// id that has a window focuses it, as the real channel does.
class _Windows extends RemoteWindowChannel {
  final opened = <RemoteDriver>[];

  /// The ids of [opened], in order.
  List<String> get ids => [for (final d in opened) d.id];

  @override
  Future<bool> openDriver(RemoteDriver driver) async {
    if (openIds.contains(driver.id)) return true;
    opened.add(driver);
    openIds.add(driver.id);
    return true;
  }
}

/// A route's transition, and whatever a frame callback scheduled.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

const _permissions = MethodChannel('extended_screen/permissions');

DeviceModel _device(String serial) =>
    DeviceModel(serial: serial, status: DeviceStatus.connected);

Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  late _Adb adb;

  void permissions({required bool granted}) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_permissions,
        (_) async => {'screen_recording': granted, 'accessibility': granted});
    addTearDown(() => messenger.setMockMethodCallHandler(_permissions, null));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    adb = Get.put<AdbService>(_Adb()) as _Adb;
  });

  tearDown(Get.reset);

  // A Mac app launched behind other windows draws no frames, so the Home
  // screen (whose controller used to be the only one to auto-connect) is
  // never built. The launch itself has to connect.
  group('at launch, with no Home screen', () {
    test('over USB with exactly one tablet, the host connects to it',
        () async {
      permissions(granted: true);
      adb.devices = [_device('TABLET')];
      final host = _LaunchHost();

      await host.autoConnect();
      expect(host.connects, ['TABLET']);
      expect(host.availableDevices.single.serial, 'TABLET');
      expect(Get.isRegistered<HomeController>(), isFalse);
    });

    test('an emulator next to the tablet is not a second choice', () async {
      permissions(granted: true);
      adb.devices = [_device('emulator-5554'), _device('TABLET')];
      final host = _LaunchHost();

      await host.autoConnect();
      expect(host.connects, ['TABLET']);
    });

    test('with two tablets it waits for the user to pick one', () async {
      permissions(granted: true);
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      final host = _LaunchHost();

      await host.autoConnect();
      expect(host.connects, isEmpty);
      expect(host.availableDevices, hasLength(2), reason: 'listed for the picker');
    });

    test('over Wi-Fi it starts listening', () async {
      permissions(granted: true);
      await settings.setLinkType(LinkType.wifi);
      final host = _LaunchHost();

      await host.autoConnect();
      expect(host.connects, [null]);
    });

    test('without Screen Recording and Accessibility nothing starts',
        () async {
      permissions(granted: false);
      adb.devices = [_device('TABLET')];
      final host = _LaunchHost();

      await host.autoConnect();
      expect(host.connects, isEmpty);
    });

    test('two callers waiting on adb together connect once', () async {
      permissions(granted: true);
      adb.devices = [_device('TABLET')];
      final host = _LaunchHost();

      // Both get past the idle check before either has its device list.
      await Future.wait(
          [host.connectIfUnambiguous(), host.connectIfUnambiguous()]);
      expect(host.connects, ['TABLET']);
    });

    test('Home opening later finds the launch connection under way',
        () async {
      permissions(granted: true);
      adb.devices = [_device('TABLET')];
      final host = _LaunchHost();

      await host.autoConnect();
      await host.connectIfUnambiguous();
      expect(host.connects, ['TABLET']);
    });

    test('a Cancel while the launch still waits on adb is not undone',
        () async {
      permissions(granted: true);
      adb.devices = [_device('TABLET')];
      adb.answer = Completer<void>();
      final host = _LaunchHost();

      final launch = host.autoConnect();
      // Meanwhile Home connected and the user cancelled it.
      await host.connect(serial: 'TABLET');
      await host.disconnect();
      expect(host.phase.value, ConnectionPhase.disconnected);
      adb.answer!.complete();
      await launch;
      expect(host.connects, ['TABLET'], reason: 'only the one the user stopped');
    });

    test('over Wi-Fi the launch does not wait on adb, and a Cancel during '
        'its permission check is not undone', () async {
      permissions(granted: true);
      await settings.setLinkType(LinkType.wifi);
      adb.answer = Completer<void>(); // never answers
      final waiting = _LaunchHost();
      await waiting.autoConnect();
      expect(waiting.connects, [null], reason: 'listening without adb');

      final cancelled = _LaunchHost();
      final launch = cancelled.autoConnect();
      await cancelled.disconnect();
      await launch;
      expect(cancelled.connects, isEmpty);
    });
  });

  // Every tablet that had a live session before connects by itself, as far
  // as the encoder's room goes; one seen for the first time does only when
  // it is the one tablet there is.
  group('several tablets', () {
    const extended = SessionChoice(SessionMode.extendedScreen);
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const driving = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac);

    /// Tablets that have had a live session; with [as], each in that mode.
    Future<void> know(List<String> serials,
        {Map<String, SessionChoice> as = const {}}) async {
      for (final (i, serial) in serials.indexed) {
        await settings.rememberDevice(serial,
            vdSerial: 0x10000 + i, choice: as[serial]);
      }
    }

    /// A host with room for four tablets (an M3 Pro's encoder).
    _LaunchHost roomy({Duration? poll, Future<bool> Function()? granted}) {
      final host = _LaunchHost(poll: poll, granted: granted);
      host.budget.estimate = EncoderEstimate.forChip('Apple M3 Pro');
      addTearDown(host.stopPolling);
      return host;
    }

    test('two known tablets both connect at launch', () async {
      permissions(granted: true);
      await know(['TABLET-A', 'TABLET-B']);
      adb.devices = [_device('TABLET-B'), _device('TABLET-A')];
      final host = roomy();
      expect(host.cap, 4);

      await host.autoConnect();
      expect(host.connects, ['TABLET-A', 'TABLET-B']);
    });

    test('a known tablet the user stopped does not', () async {
      permissions(granted: true);
      await know(['TABLET-A', 'TABLET-B']);
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      final host = roomy();
      host.stoppedDevices.add('TABLET-A');

      await host.autoConnect();
      expect(host.connects, ['TABLET-B']);
    });

    test('a known emulator is skipped beside a real tablet, and connects '
        'when it is alone', () async {
      permissions(granted: true);
      await know(['emulator-5554']);
      adb.devices = [
        _device('emulator-5554'),
        _device('TABLET-A'),
        _device('TABLET-B'),
      ];
      final beside = roomy();
      await beside.autoConnect();
      expect(beside.connects, isEmpty,
          reason: 'two new tablets to choose from, and the emulator skipped');

      adb.devices = [_device('emulator-5554')];
      final alone = roomy();
      await alone.autoConnect();
      expect(alone.connects, ['emulator-5554']);
    });

    // What the hardware checklist says of a relaunch with the tablet and
    // one emulator (docs/multi-tablet-design.md, phase 3, item 7).
    test('beside a real tablet a known emulator does not come back in its '
        'remembered mode: skipped by the policy, and picked by hand it takes '
        'the selectors\' mode; alone it comes back in its own', () async {
      permissions(granted: true);
      await know(['TABLET-A', 'emulator-5554'],
          as: {'TABLET-A': extended, 'emulator-5554': reverse});
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      adb.devices = [_device('emulator-5554'), _device('TABLET-A')];
      final beside = roomy();
      await beside.autoConnect();
      expect(beside.connects, ['TABLET-A']);
      expect(beside.choices, [extended]);

      await beside.connect(serial: 'emulator-5554');
      expect(beside.connects.last, 'emulator-5554');
      expect(beside.choices.last, driving,
          reason: 'the user\'s pick runs as the selectors say');

      adb.devices = [_device('emulator-5554')];
      final alone = roomy();
      await alone.autoConnect();
      expect(alone.connects, ['emulator-5554']);
      expect(alone.choices, [reverse]);
    });

    test('known tablets come back each in its remembered mode, whatever the '
        'selectors say now', () async {
      permissions(granted: true);
      await know(['TABLET-A', 'TABLET-B'],
          as: {'TABLET-A': extended, 'TABLET-B': reverse});
      // What the next tablet added would run as: neither of theirs.
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      expect(settings.nextChoice, driving);
      adb.devices = [_device('TABLET-B'), _device('TABLET-A')];
      final host = roomy();
      expect(host.cap, 4, reason: 'the mode does not lower the cap');

      await host.autoConnect();
      expect(host.connects, ['TABLET-A', 'TABLET-B']);
      expect(host.choices, [extended, reverse]);
    });

    test('a known tablet with no mode remembered is given none: it takes '
        'what the selectors say', () async {
      permissions(granted: true);
      await know(['TABLET-A', 'TABLET-B'], as: {'TABLET-B': reverse});
      await settings.setSessionMode(SessionMode.remoteControl);
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      final host = roomy();

      await host.autoConnect();
      expect(host.connects, ['TABLET-A', 'TABLET-B']);
      expect(host.choices, [null, reverse],
          reason: 'null: the hub falls back to the selectors for it');
    });

    test('a lone known tablet comes back in its remembered mode, by the '
        'first-run rule and with Maximum tablets 1 alike', () async {
      permissions(granted: true);
      await know(['TABLET-A'], as: {'TABLET-A': reverse});
      expect(settings.nextChoice, extended);
      adb.devices = [_device('TABLET-A')];

      final several = roomy();
      await several.autoConnect();
      expect(several.connects, ['TABLET-A']);
      expect(several.choices, [reverse]);

      await settings.setMaxTablets(1);
      final one = roomy();
      expect(one.cap, 1);
      await one.autoConnect();
      expect(one.connects, ['TABLET-A']);
      expect(one.choices, [reverse]);
    });

    test('a tablet seen for the first time, alone, is given no mode either',
        () async {
      permissions(granted: true);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      adb.devices = [_device('TABLET-NEW')];
      final host = roomy();

      await host.autoConnect();
      expect(host.connects, ['TABLET-NEW']);
      expect(host.choices, [null]);
    });

    test('in remote control too, two tablets seen for the first time wait '
        'for the pick', () async {
      permissions(granted: true);
      await settings.setSessionMode(SessionMode.remoteControl);
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      final host = roomy();
      expect(host.cap, 4);

      await host.autoConnect();
      expect(host.connects, isEmpty);
      expect(host.availableDevices, hasLength(2));
    });

    test('with Maximum tablets 1, in remote control, two known tablets wait '
        'for the pick', () async {
      permissions(granted: true);
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setMaxTablets(1);
      await know(['TABLET-A', 'TABLET-B'],
          as: {'TABLET-A': reverse, 'TABLET-B': driving});
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      final host = roomy();
      expect(host.cap, 1);

      await host.autoConnect();
      expect(host.connects, isEmpty);
    });

    test("the user's own connect is given the selectors' mode, whatever the "
        'tablet is remembered in', () async {
      permissions(granted: true);
      await know(['TABLET-A'], as: {'TABLET-A': reverse});
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.tabControlsMac);
      final host = roomy();

      await host.connect(serial: 'TABLET-A');
      expect(host.connects, ['TABLET-A']);
      expect(host.choices, [driving]);
    });

    test('a stand-in tablet is never a candidate', () async {
      permissions(granted: true);
      adb.devices = [_device('${syntheticSerialPrefix}1')];
      final alone = roomy();
      await alone.autoConnect();
      expect(alone.connects, isEmpty);

      adb.devices = [_device('${syntheticSerialPrefix}1'), _device('TABLET')];
      final beside = roomy();
      await beside.autoConnect();
      expect(beside.connects, ['TABLET'],
          reason: 'it does not make the one real tablet a choice');
    });

    test('without permissions a known tablet plugged in does not connect; '
        'once they are granted, the next one plugged in does', () async {
      var granted = false;
      await know(['TABLET-A', 'TABLET-B']);
      final host = roomy(
          poll: const Duration(milliseconds: 20), granted: () async => granted);
      await host.autoConnect();
      expect(host.connects, isEmpty);

      adb.devices = [_device('TABLET-A')];
      final seen = adb.listings;
      await _until(() => adb.listings >= seen + 3);
      expect(host.availableDevices.single.serial, 'TABLET-A',
          reason: 'the poll lists it for the picker');
      expect(host.connects, isEmpty);

      granted = true;
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      await _until(() => host.connects.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.connects, ['TABLET-B'],
          reason: 'A was plugged in before; only a new one runs the policy');
    });
  });

  // A tablet the Mac views and drives gets its native window from the
  // host-side opener (TabletWindowOpener), the first time each of its
  // sessions goes live: with no Home screen (a hidden launch builds none),
  // whatever the selectors say, and once per session.
  group('the remote window, with or without Home', () {
    late _LaunchHost hub;
    late _Windows windows;

    const reverse = SessionChoice(
      SessionMode.remoteControl,
      RemoteDirection.macControlsTab,
    );

    /// A session for [serial], made as [choice], put in the hub's map.
    HostSession tablet(
      String serial, {
      SessionChoice choice = reverse,
      ConnectionPhase phase = ConnectionPhase.streaming,
    }) {
      final session = HostSession(
        key: serial,
        link: LinkType.usb,
        serial: serial,
        choice: choice,
        pipeline: hub.pipeline,
        adb: adb,
        socket: SocketService(),
      )
        ..activeDevice.value = _device(serial)
        ..phase.value = phase;
      hub.sessions[serial] = session;
      return session;
    }

    /// The opener as the app registers it, after the hub.
    void opener() {
      Get.put(TabletWindowOpener());
    }

    /// Workers and the opens they start.
    Future<void> turn() => Future<void>.delayed(Duration.zero);

    setUp(() {
      permissions(granted: true);
      hub = Get.put<BaseConnectionManager>(_LaunchHost()) as _LaunchHost;
      windows = Get.put<RemoteWindowChannel>(_Windows()) as _Windows;
    });

    test('a session the launch made live before the opener existed gets '
        'its window at once, with no Home screen', () async {
      // Live while the selectors read Extended screen (they are the next
      // tablet's, not this one's).
      expect(settings.isReverseRemote, isFalse);
      tablet('TABLET-A');

      opener();
      await turn();
      expect(windows.ids, ['TABLET-A']);
      final driver = windows.opened.single;
      expect(driver, isA<TabletRemoteWindow>());
      expect(driver.kind, 'tablet');
      expect(Get.isRegistered<HomeController>(), isFalse);
      expect(hub.connects, isEmpty, reason: 'nothing more to start');
    });

    test('each session opens its window the first time it goes live: a '
        'second tablet its own, a retried link nothing more, an Extended '
        'one nothing', () async {
      opener();
      final a = tablet('TABLET-A', phase: ConnectionPhase.handshaking);
      await turn();
      expect(windows.opened, isEmpty, reason: 'not live yet');

      a.phase.value = ConnectionPhase.streaming;
      await turn();
      expect(windows.ids, ['TABLET-A']);

      // A second one joins.
      final b = tablet('TABLET-B', phase: ConnectionPhase.configuring);
      await turn();
      b.phase.value = ConnectionPhase.streaming;
      await turn();
      expect(windows.ids, ['TABLET-A', 'TABLET-B']);

      // A's window closed by the user, then its link drops and comes back:
      // the same session, so nothing opens again.
      windows.openIds.remove('TABLET-A');
      a.phase.value = ConnectionPhase.error;
      await turn();
      a.phase.value = ConnectionPhase.streaming;
      await turn();
      expect(windows.ids, ['TABLET-A', 'TABLET-B']);

      // An Extended tablet going live opens nothing.
      tablet('TABLET-C',
          choice: const SessionChoice(SessionMode.extendedScreen));
      await turn();
      expect(windows.ids, ['TABLET-A', 'TABLET-B']);

      // A new session for A (the user brought it back): its own window.
      final again = tablet('TABLET-A', phase: ConnectionPhase.handshaking);
      await turn();
      expect(windows.ids, ['TABLET-A', 'TABLET-B']);
      again.phase.value = ConnectionPhase.streaming;
      await turn();
      expect(windows.ids, ['TABLET-A', 'TABLET-B', 'TABLET-A']);
      expect(Get.isRegistered<HomeController>(), isFalse);
    });

    test('a window already open under the key (opened from Home before the '
        'session was live) is left alone', () async {
      opener();
      windows.openIds.add('TABLET-A');
      final a = tablet('TABLET-A', phase: ConnectionPhase.handshaking);
      a.phase.value = ConnectionPhase.streaming;
      await turn();
      expect(windows.opened, isEmpty);

      // That window closed, the same session's link retried: still nothing.
      windows.openIds.remove('TABLET-A');
      a.phase.value = ConnectionPhase.error;
      a.phase.value = ConnectionPhase.streaming;
      await turn();
      expect(windows.opened, isEmpty);
    });

    testWidgets('Home shown over a live session pushes no page and opens no '
        'second window', (tester) async {
      tablet('TABLET-A');
      opener();
      await tester.runAsync(turn);
      expect(windows.ids, ['TABLET-A']);

      final pushes = _Pushes();
      await tester.pumpWidget(GetMaterialApp(
        initialRoute: AppRoutes.home,
        navigatorObservers: [pushes],
        getPages: [
          GetPage(
            name: AppRoutes.home,
            page: () => const Text('home'),
            binding: BindingsBuilder(() {
              Get.put(HomeController(iosPollInterval: null));
            }),
          ),
          GetPage(name: AppRoutes.settings, page: () => const Text('settings')),
        ],
      ));
      await settle(tester);
      expect(find.text('home'), findsOneWidget);
      expect(pushes.names, isEmpty);
      expect(windows.ids, ['TABLET-A']);
    });
  });

  testWidgets('the splash starts the connection when it is made, not after '
      'a frame', (tester) async {
    final cm = Get.put<BaseConnectionManager>(_CountingManager())
        as _CountingManager;
    Get.put(SplashController());
    expect(cm.autoConnects, 1, reason: 'no frame has been drawn yet');

    // It still moves on to Home after its two seconds.
    await tester.pumpWidget(GetMaterialApp(
      initialRoute: '/blank',
      getPages: [
        GetPage(name: '/blank', page: () => const SizedBox()),
        GetPage(name: AppRoutes.home, page: () => const Text('home')),
      ],
    ));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('home'), findsOneWidget);
    expect(cm.autoConnects, 1);
  });
}
