import 'package:get/get.dart';

/// How the host and the client reach each other.
///
/// - [usb]: TCP on `127.0.0.1:7001` through the `adb reverse` tunnel. The
///   tunnel itself is the trust boundary (the user authorised USB debugging).
/// - [wifi]: TLS on the Mac's LAN address. The tablet must have been paired
///   with that Mac over USB first (see `WifiPairingService`).
///
/// Each side persists its own choice: the host decides how it listens, the
/// client where it dials. Nothing on the wire carries it.
enum LinkType { usb, wifi }

extension LinkTypeX on LinkType {
  // Localized strings resolve against the active GetX locale at read time.
  String get label => switch (this) {
        LinkType.usb => 'link_usb_label'.tr,
        LinkType.wifi => 'link_wifi_label'.tr,
      };

  String get description => switch (this) {
        LinkType.usb => 'link_usb_desc'.tr,
        LinkType.wifi => 'link_wifi_desc'.tr,
      };

  /// Short transport name for chips and subtitles. Not translated, like the
  /// other unit and codec labels.
  String get chipLabel => switch (this) {
        LinkType.usb => 'USB-C',
        LinkType.wifi => 'Wi-Fi',
      };
}
