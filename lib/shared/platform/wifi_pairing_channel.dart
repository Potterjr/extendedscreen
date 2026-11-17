import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// Client (Android) only: the one way a Mac's Wi-Fi pairing gets into this
/// app. The Mac hands it to adb, adb delivers it as a broadcast that only the
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
class WifiPairingChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/wifi_pairing');

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler(_onCall);
  }

  @override
  void onClose() {
    _channel.setMethodCallHandler(null);
    super.onClose();
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final payload = call.arguments;
    final log = Get.find<LoggerService>();
    switch (call.method) {
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
