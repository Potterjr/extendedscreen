import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/splash/controllers/splash_controller.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// What `adb devices` would list, as soon as [answer] lets it (adb's first
/// call after login can take seconds; a wedged one never answers).
class _Adb extends AdbService {
  List<DeviceModel> devices = const [];
  Completer<void>? answer;

  @override
  Future<List<DeviceModel>> listDevices() async {
    await answer?.future;
    return devices;
  }
}

/// The real host, up to the point where it would open a server: what it was
/// asked to connect to is recorded instead.
class _LaunchHost extends HostConnectionManager {
  _LaunchHost() : super(socket: SocketService());

  final connects = <String?>[];

  @override
  Future<void> connect({String? serial}) async {
    connects.add(serial);
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

const _permissions = MethodChannel('extended_screen/permissions');

DeviceModel _device(String serial) =>
    DeviceModel(serial: serial, status: DeviceStatus.connected);

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

  testWidgets('a reverse-remote session the launch already started opens the '
      'remote view once Home is shown', (tester) async {
    permissions(granted: true);
    await settings.setSessionMode(SessionMode.remoteControl);
    await settings.setRemoteDirection(RemoteDirection.macControlsTab);
    expect(settings.isReverseRemote, isTrue);
    final cm = Get.put<BaseConnectionManager>(_CountingManager())
        as _CountingManager;
    cm.phase.value = ConnectionPhase.streaming;

    await tester.pumpWidget(GetMaterialApp(
      initialRoute: AppRoutes.home,
      getPages: [
        GetPage(
          name: AppRoutes.home,
          page: () => const Text('home'),
          binding: BindingsBuilder(() {
            Get.put(HomeController());
          }),
        ),
        GetPage(name: AppRoutes.remoteHost, page: () => const Text('remote')),
      ],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('remote'), findsOneWidget);
    expect(cm.connects, 0, reason: 'already live: nothing more to start');
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
