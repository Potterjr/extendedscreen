import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
import 'package:extendedscreen/shared/features/settings/controllers/settings_controller.dart';
import 'package:extendedscreen/shared/features/settings/views/settings_view.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/platform/battery_channel.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/add_device_panel.dart';

/// What Home asked of a connection manager, recorded instead of done: no
/// socket is ever opened.
mixin _Recording on BaseConnectionManager {
  int connects = 0;

  /// The role each connect was given (the hub's own `connect` adds
  /// nextChoice; the tablet's, and the policy's Wi-Fi start, give none).
  final choices = <SessionChoice?>[];
  int disconnects = 0;
  int identityResets = 0;

  @override
  Future<void> resetWifiIdentity() async => identityResets++;

  /// Move through the phases as the real managers do: a connect starts
  /// waiting (`handshaking`), a disconnect ends everything.
  bool movesPhase = false;

  // The one place every connect goes through: the hub's `connect` and its
  // auto-connect policy both end here, and the tablet's `connect` below.
  @override
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {
    connects++;
    choices.add(choice);
    if (movesPhase) phase.value = ConnectionPhase.handshaking;
  }

  @override
  Future<void> autoConnect() async {}

  @override
  Future<void> disconnect() async {
    disconnects++;
    if (movesPhase) phase.value = ConnectionPhase.disconnected;
  }
}

/// The tablet's manager.
class _FakeClient extends BaseConnectionManager with _Recording {
  @override
  bool get isHost => false;

  @override
  Future<void> connect({String? serial}) => connectWith(serial);
}

/// The Mac's hub, with its own auto-connect policy and pause; connecting
/// and disconnecting are recorded.
class _FakeHub extends HostConnectionManager with _Recording {
  _FakeHub() : super(adb: _NoDevices(), devicePollInterval: null);

  /// The mode changes asked for, recorded instead of done.
  final modeChanges = <(String, SessionChoice)>[];

  @override
  Future<bool> changeMode(String key, SessionChoice choice,
      {HostSession? expected}) async {
    modeChanges.add((key, choice));
    return true;
  }
}

/// adb with nothing attached.
class _NoDevices extends AdbService {
  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async => const [];
}

const _permissions = MethodChannel('extended_screen/permissions');

/// A pairing as a Mac hands it to adb during a USB session. The certificate
/// is three arbitrary bytes: nothing here opens a TLS connection. [mac] tells
/// one Mac from another.
Uint8List _pairingPacket(String name, {int mac = 0}) =>
    WifiPairingService.buildPairingPayload(
      WifiIdentity(
        hostId: _hostId(mac),
        token: Uint8List(WifiIdentity.tokenLength),
        certPem: '-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----',
        keyPem: '',
      ),
      name,
    );

Uint8List _hostId(int mac) =>
    Uint8List(WifiIdentity.hostIdLength)..fillRange(0, 16, mac);

/// The Forget button of one paired Mac on the tablet's card.
Finder _forgetButton(int mac) => find.byKey(ValueKey('forget-${hexOf(_hostId(mac))}'));

/// Lets a dialog finish opening or closing. Not `pumpAndSettle`: Home can
/// have a progress indicator that never settles.
Future<void> _pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late SettingsService settings;
  late _Recording cm;

  Future<void> start({required bool host, bool permissions = true}) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _permissions,
      (_) async => {'screen_recording': permissions, 'accessibility': permissions},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(_permissions, null));
    cm = Get.put<BaseConnectionManager>(host ? _FakeHub() : _FakeClient())
        as _Recording;
    Get.put(HomeController(iosPollInterval: null));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    Get.put(SocketService());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
  });

  tearDown(Get.reset);

  group('host', () {
    testWidgets('a Mac whose saved link is Wi-Fi still gets the USB Home: no '
        'listening card, no Connect, no selector, the Add a device panel '
        'with its Wi-Fi row', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await start(host: true, permissions: false);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();
      await tester.pump();

      for (final text in [
        'wifi_host_title',
        'wifi_host_hint',
        'common_connect',
        'link_usb_label',
        'link_wifi_label',
        'remote_dir_title',
        'session_extended_desc',
      ]) {
        expect(find.text(text), findsNothing, reason: text);
      }
      expect(find.byType(AddDevicePanel), findsOneWidget);
      expect(find.byKey(const ValueKey('add/wifi-listen')), findsOneWidget);
      expect(find.byKey(const ValueKey('home/empty')), findsOneWidget);
      expect(cm.connects, 0);
    });

    testWidgets('over USB the add panel stays, the empty state shows, and '
        'nothing connects without a device', (tester) async {
      await start(host: true);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(AddDevicePanel), findsOneWidget);
      expect(find.byKey(const ValueKey('home/empty')), findsOneWidget);
      expect(find.text('home_empty'), findsOneWidget);
      expect(find.text('wifi_host_title'), findsNothing);
      expect(find.text('common_connect'), findsNothing);
      expect(cm.connects, 0);
    });

    testWidgets('the Mac offers no link selector: USB always runs, and Wi-Fi '
        "is the Add a device panel's last row", (tester) async {
      await start(host: true, permissions: false);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();

      expect(find.text('link_wifi_label'), findsNothing);
      expect(find.text('link_usb_label'), findsNothing);
      expect(find.byType(AddDevicePanel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AddDevicePanel),
          matching: find.byKey(const ValueKey('add/wifi-listen')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('next/wifi-listen')), findsNothing);
      expect(settings.linkType, LinkType.usb);
      expect(cm.connects, 0);
    });
  });

  group('client', () {
    late WifiPairingService pairing;

    Future<void> startClient(WidgetTester tester) async {
      pairing = Get.put(WifiPairingService());
      Get.put(BatteryChannel());
      // Its poll timer would outlive the test body.
      addTearDown(() => Get.delete<BatteryChannel>(force: true));
      await start(host: false);
      // The tablet's normal state: no Mac yet, a retry pending.
      cm.phase.value = ConnectionPhase.error;
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();
    }

    testWidgets('switching to Wi-Fi redials at once and says the tablet '
        'still needs pairing', (tester) async {
      await startClient(tester);
      expect(find.text('wifi_client_title'), findsNothing);

      await tester.tap(find.text('link_wifi_label'));
      await tester.pump();
      await tester.pump();
      expect(settings.linkType, LinkType.wifi);
      expect(cm.disconnects, 1);
      expect(cm.connects, 1);
      expect(find.text('wifi_client_not_paired'), findsOneWidget);
      // Nowhere to dial yet, so no address to type either.
      expect(find.byType(TextField), findsNothing);

      await Get.delete<BatteryChannel>(force: true);
    });

    testWidgets('on iOS there is no link to choose: always Wi-Fi, with the '
        'iPhone\'s pairing guidance', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        // Saved USB, as a build from before could have left it.
        await settings.setLinkType(LinkType.usb);
        await settings.init();
        await startClient(tester);

        expect(settings.linkType, LinkType.wifi);
        expect(find.text('link_usb_label'), findsNothing);
        expect(find.text('link_wifi_label'), findsNothing);
        expect(find.text('wifi_client_title'), findsOneWidget);
        expect(find.text('wifi_client_not_paired_ios'), findsOneWidget);
        expect(find.text('wifi_client_not_paired'), findsNothing);

        await tester.runAsync(
            () => pairing.storePairing(_pairingPacket('Studio')));
        await tester.pump();
        expect(find.text('wifi_client_paired'), findsOneWidget);
        expect(find.text('wifi_client_not_paired_ios'), findsNothing);

        await Get.delete<BatteryChannel>(force: true);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a paired tablet names its Mac and can be given an address',
        (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await startClient(tester);
      await tester.runAsync(() => pairing.storePairing(_pairingPacket('Studio')));
      await tester.pump();

      expect(find.text('wifi_client_paired'), findsOneWidget);
      expect(find.text('wifi_client_not_paired'), findsNothing);

      await tester.enterText(find.byType(TextField), ' 192.168.1.20 ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(settings.wifiHostAddress, '192.168.1.20');
      expect(cm.connects, 1, reason: 'the pending dial restarts with it');

      await Get.delete<BatteryChannel>(force: true);
    });

    testWidgets('tapping Connect with an unsaved address in the field '
        'connects: the same touch must not also cancel', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await startClient(tester);
      cm.movesPhase = true;
      await tester.runAsync(() => pairing.storePairing(_pairingPacket('Studio')));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '192.168.1.20');
      await tester.pump(); // the field now has focus, as while typing
      // A real touch: down, a moment, up. Leaving the field happens on the
      // way down, the button acts on the way up.
      final touch =
          await tester.startGesture(tester.getCenter(find.text('common_connect')));
      await tester.pump(const Duration(milliseconds: 120));
      await touch.up();
      await tester.pump();
      await tester.pump();

      expect(settings.wifiHostAddress, '192.168.1.20');
      expect(cm.connects, 1);
      expect(cm.disconnects, 0, reason: 'Connect must not turn into Cancel');
      expect(cm.phase.value, ConnectionPhase.handshaking);

      await Get.delete<BatteryChannel>(force: true);
    });

    testWidgets('a paired Mac is forgotten only after a confirmation, the '
        'pending dial starts over, and it stays forgotten', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await startClient(tester);
      // One at a time, each followed by a frame: a second change to the
      // list inside the same runAsync never returns.
      await tester.runAsync(
          () => pairing.storePairing(_pairingPacket('Studio', mac: 1)));
      await tester.pump();
      await tester.runAsync(
          () => pairing.storePairing(_pairingPacket('Laptop', mac: 2)));
      await tester.pump();
      expect(find.text('wifi_client_paired'), findsNWidgets(2));

      // Asked first, and Cancel changes nothing.
      await tester.tap(_forgetButton(1));
      await _pumpDialog(tester);
      expect(find.text('wifi_forget_title'), findsOneWidget);
      expect(find.text('wifi_forget_message'), findsOneWidget);
      await tester.tap(find.text('common_cancel'));
      await _pumpDialog(tester);
      expect(find.text('wifi_forget_title'), findsNothing);
      expect(pairing.pairedHosts, hasLength(2));
      expect(cm.disconnects, 0);

      await tester.tap(_forgetButton(1));
      await _pumpDialog(tester);
      await tester.tap(find.text('wifi_forget_confirm'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await _pumpDialog(tester);
      expect(pairing.pairedHosts.map((h) => h.name), ['Laptop']);
      expect(find.text('wifi_client_paired'), findsOneWidget);
      expect(_forgetButton(1), findsNothing);
      expect(_forgetButton(2), findsOneWidget);
      // The dial in progress may have been to that Mac.
      expect(cm.disconnects, 1);
      expect(cm.connects, 1);

      // An app restart does not bring it back.
      final restarted = WifiPairingService();
      await tester.runAsync(() => restarted.ready);
      expect(restarted.pairedHosts.map((h) => h.name), ['Laptop']);

      // With the last one gone the card is back to "pair over USB first".
      await tester.tap(_forgetButton(2));
      await _pumpDialog(tester);
      await tester.tap(find.text('wifi_forget_confirm'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await _pumpDialog(tester);
      expect(pairing.pairedHosts, isEmpty);
      expect(find.text('wifi_client_not_paired'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await Get.delete<BatteryChannel>(force: true);
    });

    testWidgets('forgetting a Mac leaves a stopped tablet stopped',
        (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await startClient(tester);
      cm.phase.value = ConnectionPhase.disconnected;
      await tester.runAsync(
          () => pairing.storePairing(_pairingPacket('Studio', mac: 1)));
      await tester.pump();

      await tester.tap(_forgetButton(1));
      await _pumpDialog(tester);
      await tester.tap(find.text('wifi_forget_confirm'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await _pumpDialog(tester);
      expect(pairing.pairedHosts, isEmpty);
      expect(cm.connects, 0);
      expect(cm.disconnects, 0);

      await Get.delete<BatteryChannel>(force: true);
    });

    testWidgets('a stopped tablet stays stopped when the link is switched',
        (tester) async {
      await startClient(tester);
      cm.phase.value = ConnectionPhase.disconnected;
      await tester.pump();

      await tester.tap(find.text('link_wifi_label'));
      await tester.pump();
      expect(settings.linkType, LinkType.wifi);
      expect(cm.connects, 0);
      expect(cm.disconnects, 0);

      await Get.delete<BatteryChannel>(force: true);
    });
  });

  group('settings', () {
    Future<void> openSettings(WidgetTester tester, {required bool host}) async {
      await start(host: host, permissions: false);
      Get.put(SettingsController());
      await tester.pumpWidget(const GetMaterialApp(home: SettingsView()));
      await tester.pump();
      await tester.pump();
    }

    Finder list() => find.byType(Scrollable).first;

    testWidgets('the Mac resets its Wi-Fi pairing only after a confirmation',
        (tester) async {
      await openSettings(tester, host: true);
      await tester.scrollUntilVisible(find.text('settings_wifi_reset'), 200,
          scrollable: list());
      expect(find.text('settings_wifi_reset_desc'), findsOneWidget);

      await tester.tap(find.text('settings_wifi_reset'));
      await _pumpDialog(tester);
      expect(find.text('wifi_reset_title'), findsOneWidget);
      expect(find.text('wifi_reset_message'), findsOneWidget);
      await tester.tap(find.text('common_cancel'));
      await _pumpDialog(tester);
      expect(cm.identityResets, 0);
      expect(find.text('settings_wifi_reset_desc'), findsOneWidget);

      await tester.tap(find.text('settings_wifi_reset'));
      await _pumpDialog(tester);
      await tester.tap(find.text('wifi_reset_confirm'));
      await _pumpDialog(tester);
      expect(cm.identityResets, 1);
      // The row now says what to do next.
      expect(find.text('settings_wifi_reset_done'), findsOneWidget);
      expect(find.text('settings_wifi_reset_desc'), findsNothing);
    });

    testWidgets('the tablet has no identity to reset', (tester) async {
      await openSettings(tester, host: false);
      // To the end of the list, so every row has been built.
      await tester.scrollUntilVisible(find.text('settings_host'), 200,
          scrollable: list());
      expect(find.text('settings_wifi_reset'), findsNothing);
      expect(find.text('settings_section_wifi'), findsNothing);
    });
  });
}
