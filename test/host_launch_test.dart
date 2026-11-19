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
import 'package:extendedscreen/shared/connection/encode_budget.dart';
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
/// asked to connect to is recorded instead. No device poll unless [poll]
/// says how often; [granted] stands in for the permission check (by default
/// the mocked permissions channel answers).
class _LaunchHost extends HostConnectionManager {
  _LaunchHost({Duration? poll, Future<bool> Function()? granted})
      : super(
            socket: SocketService(),
            devicePollInterval: poll,
            hostGranted: granted);

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
    Future<void> know(List<String> serials) async {
      for (final (i, serial) in serials.indexed) {
        await settings.rememberDevice(serial, vdSerial: 0x10000 + i);
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

    test('in remote control, two known tablets wait for the pick', () async {
      permissions(granted: true);
      await settings.setSessionMode(SessionMode.remoteControl);
      await know(['TABLET-A', 'TABLET-B']);
      adb.devices = [_device('TABLET-A'), _device('TABLET-B')];
      final host = roomy();
      expect(host.cap, 1);

      await host.autoConnect();
      expect(host.connects, isEmpty);
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
