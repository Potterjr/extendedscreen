import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/platform/wifi_pairing_channel.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class _QuietLogger extends LoggerService {
  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) {}
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

/// A pairing as the Mac writes it into the inbox. The certificate is three
/// arbitrary bytes: nothing here opens a TLS connection.
Uint8List _pairing(String name, {int mac = 1, int token = 0}) =>
    WifiPairingService.buildPairingPayload(
      WifiIdentity(
        hostId: Uint8List(WifiIdentity.hostIdLength)..fillRange(0, 16, mac),
        token: Uint8List(WifiIdentity.tokenLength)..fillRange(0, 32, token),
        certPem: '-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----',
        keyPem: '',
      ),
      name,
    );

/// Stands in for PairingInboxPlugin.swift: `takeInbox` hands over what is
/// in [file] (and keeps handing it over until it is answered, as the
/// plugin's `pairing.processing` does), `inboxDone` records the answer and
/// empties it.
class _Inbox {
  Uint8List? file;
  final takes = <Uint8List?>[];
  final answers = <int>[];
  Completer<void>? holdTake;
  int inFlight = 0;
  int maxInFlight = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'takeInbox':
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await holdTake?.future;
        inFlight--;
        takes.add(file);
        return file;
      case 'inboxDone':
        answers.add((call.arguments as Map)['result'] as int);
        file = null;
        return true;
    }
    throw MissingPluginException();
  }
}

/// A pairing service whose store can be made to throw.
class _Pairing extends WifiPairingService {
  bool fail = false;

  @override
  Future<bool> storePairing(Uint8List payload) {
    if (fail) throw StateError('disk full');
    return super.storePairing(payload);
  }
}

const _channel = MethodChannel('extended_screen/wifi_pairing');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Inbox inbox;
  late _Pairing pairing;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    pairing = Get.put<WifiPairingService>(_Pairing()) as _Pairing;
    inbox = _Inbox();
    messenger.setMockMethodCallHandler(_channel, inbox.handle);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_channel, null);
    await Get.delete<WifiPairingChannel>(force: true);
    Get.reset();
  });

  /// What the Mac's Darwin notification does: native calls `inboxChanged`.
  Future<void> nudge() => messenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('inboxChanged')),
        (_) {},
      );

  /// Lets every pending channel reply and store run (all microtasks here).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    // SharedPreferences' test store answers outside the fake clock.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  /// Registers the channel as InitialBinding does on iOS: its onInit pulls.
  Future<WifiPairingChannel> launch(WidgetTester tester) async {
    final channel = Get.put(WifiPairingChannel(inbox: true));
    await settle(tester);
    return channel;
  }

  group('the iOS inbox', () {
    /// The channel's poll timer runs until the channel is deleted, which
    /// has to happen inside the test body.
    void inboxTest(String description, WidgetTesterCallback body) =>
        testWidgets(description, (tester) async {
          await body(tester);
          await Get.delete<WifiPairingChannel>(force: true);
        });

    inboxTest('a pairing that waited while the app was closed is taken at '
        'launch, stored, then answered', (tester) async {
      inbox.file = _pairing('Studio');
      await launch(tester);

      expect(inbox.takes, hasLength(1));
      expect(inbox.answers, [1]);
      expect(pairing.pairedHosts.single.name, 'Studio');
    });

    inboxTest('a refused pairing is answered 2', (tester) async {
      inbox.file = _pairing('Studio');
      final channel = await launch(tester);
      // The same Mac with another token: something posing as it.
      inbox.file = _pairing('Studio', token: 9);
      unawaited(channel.pullInbox());
      await settle(tester);

      expect(inbox.answers, [1, 2]);
      expect(pairing.pairedHosts.single.token.first, 0);
    });

    inboxTest('a store that throws answers nothing, and the next pull '
        'takes the same file again', (tester) async {
      inbox.file = _pairing('Studio');
      pairing.fail = true;
      final channel = await launch(tester);
      expect(inbox.takes, hasLength(1));
      expect(inbox.answers, isEmpty);
      expect(inbox.file, isNotNull, reason: 'still in the inbox');

      pairing.fail = false;
      unawaited(channel.pullInbox());
      await settle(tester);
      expect(inbox.takes, hasLength(2));
      expect(inbox.answers, [1]);
      expect(pairing.pairedHosts, hasLength(1));
    });

    inboxTest('pulls on the nudge and on resume, one at a time',
        (tester) async {
      final channel = await launch(tester);
      expect(inbox.takes, hasLength(1), reason: 'the launch pull');

      inbox.file = _pairing('Studio');
      inbox.holdTake = Completer();
      await nudge();
      channel.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await nudge();
      await settle(tester);
      expect(inbox.maxInFlight, 1);
      expect(inbox.takes, hasLength(1), reason: 'the one pull is held');

      inbox.holdTake!.complete();
      inbox.holdTake = null;
      await settle(tester);
      expect(inbox.takes, hasLength(2));
      expect(inbox.answers, [1]);
      expect(pairing.pairedHosts.single.name, 'Studio');

      // After it, a resume pulls again.
      channel.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle(tester);
      expect(inbox.takes, hasLength(3));
    });

    inboxTest('polls every 2 s while no Mac is paired, and stops once one '
        'is', (tester) async {
      await launch(tester);
      final atLaunch = inbox.takes.length;

      await tester.pump(WifiPairingChannel.inboxPollInterval);
      await settle(tester);
      await tester.pump(WifiPairingChannel.inboxPollInterval);
      await settle(tester);
      expect(inbox.takes.length, atLaunch + 2);

      inbox.file = _pairing('Studio');
      await tester.pump(WifiPairingChannel.inboxPollInterval);
      await settle(tester);
      expect(pairing.pairedHosts, hasLength(1));
      final paired = inbox.takes.length;
      await tester.pump(WifiPairingChannel.inboxPollInterval * 3);
      await settle(tester);
      expect(inbox.takes.length, paired);

    });

    inboxTest('off iOS nothing is pulled', (tester) async {
      inbox.file = _pairing('Studio');
      final channel = Get.put(WifiPairingChannel(inbox: false));
      await tester.pump(WifiPairingChannel.inboxPollInterval * 2);
      channel.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await nudge();
      await settle(tester);
      expect(inbox.takes, isEmpty);
    });
  });

  group('settings on iOS', () {
    test('the link is Wi-Fi whatever was saved, and cannot be changed', () async {
      SharedPreferences.setMockInitialValues({'link_type': 'usb'});
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final settings = SettingsService();
        await settings.init();
        expect(settings.linkTypeRx.value, LinkType.wifi);
        await settings.setLinkType(LinkType.usb);
        expect(settings.linkType, LinkType.wifi);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('elsewhere the saved link stands', () async {
      SharedPreferences.setMockInitialValues({'link_type': 'wifi'});
      final settings = SettingsService();
      await settings.init();
      expect(settings.linkType, LinkType.wifi);
      await settings.setLinkType(LinkType.usb);
      expect(settings.linkType, LinkType.usb);
    });
  });
}
