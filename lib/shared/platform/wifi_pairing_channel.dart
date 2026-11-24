import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// Client only (Android and iOS): the one way a Mac's Wi-Fi pairing gets
/// into this app. The Mac hands it to adb, adb delivers it as a broadcast that only the
/// shell may send (`WifiPairingReceiver.kt`), and the receiver calls `pair`
/// here with the payload.
///
/// Nothing that arrives on the link is ever stored as a pairing, because the
/// link cannot say who is on its other end: "the USB link" is whatever
/// answered on this tablet's 127.0.0.1:7001, which is adb only while a Mac
/// has a tunnel up. A broadcast from the shell can only come from a computer
/// the user allowed to debug this tablet.
///
/// The same receiver, and so the same guarantee, carries the key of each USB
/// session (`usbSession`, see [UsbSessionService]): the secret both ends of
/// the USB link have to prove they hold.
///
/// The reply is whether the pairing was stored, or the key taken; the
/// receiver turns it into the broadcast's result code, which the Mac reads.
///
/// iOS has no adb. There the Mac writes the same pairing bytes into this
/// app's own container with `devicectl` (`ESInbox`, `PairingInboxPlugin.swift`
/// on this channel), and Dart pulls them ([pullInbox]); native code never
/// pushes, since a push at launch would reach no handler yet. It pulls in
/// [onInit] (a pairing that waited while the app was closed), on every
/// resume, on `inboxChanged` (the Mac's Darwin notification, a nudge with no
/// data), and every [inboxPollInterval] while no Mac is paired. The file is
/// answered (`inboxDone`, which deletes it) only once [WifiPairingService.
/// storePairing] has answered; if storing throws nothing is answered, and
/// the next pull takes the same file again.
class WifiPairingChannel extends GetxService with WidgetsBindingObserver {
  static const _channel = MethodChannel('extended_screen/wifi_pairing');

  static const inboxPollInterval = Duration(seconds: 2);

  /// [inbox] defaults to the platform ([runsOnIos]); tests pass it.
  WifiPairingChannel({bool? inbox}) : inbox = inbox ?? runsOnIos;

  /// Pull pairings from the devicectl inbox (iOS).
  final bool inbox;

  Timer? _poll;
  Future<void>? _pulling;

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler(_onCall);
    if (!inbox) return;
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(inboxPollInterval, (_) {
      if (_pairing.pairedHosts.isEmpty) pullInbox();
    });
    pullInbox();
  }

  @override
  void onClose() {
    _poll?.cancel();
    if (inbox) WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (inbox && state == AppLifecycleState.resumed) pullInbox();
  }

  WifiPairingService get _pairing => Get.find<WifiPairingService>();

  /// Takes the pairing waiting in the inbox, if any, stores it and answers
  /// it. One pull at a time: a call while one runs gets that one.
  Future<void> pullInbox() => _pulling ??= _pull().whenComplete(() {
        _pulling = null;
      });

  Future<void> _pull() async {
    final log = Get.find<LoggerService>();
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('takeInbox');
      if (bytes == null) return;
      final stored = await _pairing.storePairing(bytes);
      await _channel.invokeMethod<bool>('inboxDone', {'result': stored ? 1 : 2});
      if (stored) {
        log.i('Client: paired with the Mac for Wi-Fi (through the inbox)');
      } else {
        log.w('Client: a pairing from the inbox was refused');
      }
    } catch (e) {
      // Left in the inbox: the next pull takes it again.
      log.w('Client: pulling the pairing inbox failed ($e)');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final payload = call.arguments;
    final log = Get.find<LoggerService>();
    switch (call.method) {
      case 'inboxChanged':
        if (inbox) unawaited(pullInbox());
        return null;
      case 'pair':
        if (payload is! Uint8List) return false;
        final stored =
            await Get.find<WifiPairingService>().storePairing(payload);
        if (stored) {
          log.i('Client: paired with the Mac for Wi-Fi (through adb)');
        } else {
          log.w('Client: a pairing delivered through adb was refused');
        }
        return stored;
      case 'usbSession':
        if (payload is! Uint8List) return false;
        final taken = Get.find<UsbSessionService>().accept(payload);
        if (taken) {
          log.i('Client: took a USB session key (through adb)');
        } else {
          log.w('Client: a USB session key delivered through adb was refused');
        }
        return taken;
      default:
        throw MissingPluginException();
    }
  }
}
