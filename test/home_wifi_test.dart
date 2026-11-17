import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
import 'package:extendedscreen/shared/features/settings/controllers/settings_controller.dart';
import 'package:extendedscreen/shared/features/settings/views/settings_view.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/platform/battery_channel.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/device_picker_card.dart';

/// A manager of either role that records what Home asked of it and never
/// opens a socket.
class _FakeManager extends BaseConnectionManager {
  _FakeManager({required this.isHost});

  @override
  final bool isHost;

  int connects = 0;
  int disconnects = 0;
  int identityResets = 0;

  @override
  Future<void> resetWifiIdentity() async => identityResets++;

  /// Move through the phases as the real managers do: a connect starts
  /// waiting (`handshaking`), a disconnect ends everything.
  bool movesPhase = false;

  @override
  Future<void> connect({String? serial}) async {
    connects++;
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
  late _FakeManager cm;

  Future<void> start({required bool host, bool permissions = true}) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _permissions,
      (_) async => {'screen_recording': permissions, 'accessibility': permissions},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(_permissions, null));
    cm = Get.put<BaseConnectionManager>(_FakeManager(isHost: host))
        as _FakeManager;
    Get.put(HomeController());
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
    testWidgets('over Wi-Fi there is no device to pick: Home shows where the '
        'Mac listens and starts listening by itself', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await start(host: true);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(DevicePickerCard), findsNothing);
      expect(find.text('wifi_host_title'), findsOneWidget);
      expect(find.text('wifi_host_hint'), findsOneWidget);
      expect(cm.connects, 1, reason: 'permissions granted, nothing to choose');
      // Idle, the card offers the Connect the picker would otherwise be.
      expect(find.text('common_connect'), findsOneWidget);
    });

    testWidgets('while the Mac waits for the tablet, its address stays on '
        'screen and the selectors go', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await start(host: true, permissions: false);
      cm.movesPhase = true;
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();
      expect(find.text('link_usb_label'), findsOneWidget);

      await cm.connect();
      await tester.pump();
      expect(cm.phase.value, ConnectionPhase.handshaking);
      expect(find.text('wifi_host_title'), findsOneWidget,
          reason: 'this is when the address has to be read off the Mac');
      expect(find.text('link_usb_label'), findsNothing);
      expect(find.text('common_cancel'), findsOneWidget);

      // Gone once a session is live.
      cm.phase.value = ConnectionPhase.streaming;
      await tester.pump();
      expect(find.text('wifi_host_title'), findsNothing);
    });

    testWidgets('over USB the picker stays and nothing connects without a '
        'device', (tester) async {
      await start(host: true);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(DevicePickerCard), findsOneWidget);
      expect(find.text('wifi_host_title'), findsNothing);
      expect(find.text('common_connect'), findsNothing);
      expect(cm.connects, 0);
    });

    testWidgets('the selector switches the link and is saved', (tester) async {
      await start(host: true, permissions: false);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();

      await tester.tap(find.text('link_wifi_label'));
      await tester.pump();
      expect(settings.linkType, LinkType.wifi);
      expect(find.byType(DevicePickerCard), findsNothing);
      expect(find.text('wifi_host_title'), findsOneWidget);

      await tester.tap(find.text('link_usb_label'));
      await tester.pump();
      expect(settings.linkType, LinkType.usb);
      expect(find.byType(DevicePickerCard), findsOneWidget);
      expect(cm.connects, 0, reason: 'choosing a link is not connecting');
    });

    testWidgets('while retrying after an error the card offers Cancel, not '
        'Connect', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await start(host: true, permissions: false);
      cm.phase.value = ConnectionPhase.error;
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();

      expect(find.text('common_connect'), findsNothing);
      await tester.tap(find.text('common_cancel'));
      await tester.pump();
      expect(cm.disconnects, 1);
    });

    testWidgets('a press on Connect that is overtaken by an automatic '
        'connect does not turn into Cancel', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await start(host: true, permissions: false);
      cm.movesPhase = true;
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();

      final touch = await tester
          .startGesture(tester.getCenter(find.text('common_connect')));
      // The app regained focus with that click and started listening by
      // itself before the finger came up: the button now reads Cancel.
      await cm.connect();
      await tester.pump();
      expect(find.text('common_cancel'), findsOneWidget);
      await touch.up();
      await tester.pump();

      expect(cm.disconnects, 0, reason: 'the user pressed Connect');
      expect(cm.phase.value, ConnectionPhase.handshaking);
    });

    testWidgets('Mac → Tablet cannot be chosen over Wi-Fi', (tester) async {
      await settings.setLinkType(LinkType.wifi);
      await settings.setSessionMode(SessionMode.remoteControl);
      await start(host: true, permissions: false);
      await tester.pumpWidget(const GetMaterialApp(home: HomeView()));
      await tester.pump();

      expect(find.text('remote_dir_usb_only'), findsOneWidget);
      await tester.tap(find.text('remote_dir_mac_label'));
      await tester.pump();
      expect(settings.remoteDirection, RemoteDirection.tabControlsMac);

      // With the cable it is a normal choice again.
      await tester.tap(find.text('link_usb_label'));
      await tester.pump();
      expect(find.text('remote_dir_usb_only'), findsNothing);
      await tester.tap(find.text('remote_dir_mac_label'));
      await tester.pump();
      expect(settings.remoteDirection, RemoteDirection.macControlsTab);
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
