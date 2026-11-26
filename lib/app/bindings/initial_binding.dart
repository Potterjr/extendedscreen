import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_window_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/tablet_window_opener.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/client_connection_manager.dart';
import 'package:extendedscreen/modules/extended_screen/client/video_decoder_channel.dart';
import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';
import 'package:extendedscreen/shared/platform/battery_channel.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/platform/ios_device_service.dart';
import 'package:extendedscreen/shared/platform/wifi_pairing_channel.dart';
import 'package:extendedscreen/shared/platform/windows_app.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(LoggerService(), permanent: true);
    // SettingsService is registered in main() (loaded before runApp) so its
    // saved language is ready when GetMaterialApp reads the locale.
    if (!Get.isRegistered<SettingsService>()) {
      Get.put(SettingsService(), permanent: true);
    }

    // Transport — shared by both roles; permanent so it survives route changes.
    Get.put(SocketService(), permanent: true);
    // Wi-Fi link — both roles: the host owns an identity and answers probes,
    // the client stores the hosts it was paired with and sends the probes.
    Get.put(WifiPairingService(), permanent: true);
    // iOS asks only the addresses it knows: broadcasting needs a multicast
    // entitlement there.
    Get.put(WifiDiscoveryService(broadcast: !runsOnIos), permanent: true);

    // Role-specific wiring. The chosen manager is bound to BaseConnectionManager
    // so all shared UI depends on a single interface.
    if (GetPlatform.isMacOS) {
      // HOST (macOS): capture + input + adb, plus the reverse-remote decoder
      // (Mac-controls-tablet), then the host connection manager.
      Get.put(ScreenCaptureChannel(), permanent: true);
      Get.put(InputInjectChannel(), permanent: true);
      Get.put(RemoteVideoChannel(), permanent: true);
      if (synthTablets) {
        // Debug builds with --dart-define=SYNTH_TABLETS=N: N tablets stood
        // in for in this process, reached through an adb that hands every
        // other serial to the real one. A const condition, so no other
        // build contains any of it.
        final synth =
            Get.put(SyntheticTablets(synthTabletCount), permanent: true);
        Get.put<AdbService>(synth.adb, permanent: true);
      } else {
        Get.put(AdbService(), permanent: true);
      }
      // devicectl, the iPhone's stand-in for adb (Wi-Fi pairing through the
      // app's container). Inert until called; in the P0 spike only the
      // debug-only iPhones list in Settings calls it.
      Get.put(IosDeviceService(), permanent: true);
      // An iPhone or iPad over USB: its screen (AVFoundation) and touches
      // (the TouchRunner over usbmuxd). Inert until its view opens.
      Get.put(IosScreenChannel(), permanent: true);
      Get.put(IosTouchService(), permanent: true);
      // Native remote windows (one per device id): an iPhone's view, its
      // capture drawn straight into the window, and each tablet's the Mac
      // views and drives.
      Get.put(RemoteWindowChannel(), permanent: true);
      // The Mac has no link selector since several devices can join on
      // Wi-Fi: USB always runs and Wi-Fi is Home's Listen switch. A Mac left
      // on the Wi-Fi link listens instead (both values change at once in
      // memory; the writes follow).
      unawaited(Get.find<SettingsService>().migrateHostLinkToListen());
      Get.put<BaseConnectionManager>(HostConnectionManager(), permanent: true);
      // A tablet the Mac views and drives gets its native window when its
      // session goes live, once per session, with or without a Home screen
      // (a hidden launch builds none). After the hub, which it watches.
      Get.put(TabletWindowOpener(), permanent: true);
    } else if (defaultTargetPlatform == TargetPlatform.android ||
        wifiOnlyClient) {
      // CLIENT (Android, or the iOS and Windows clients over Wi-Fi): video
      // decoder, plus on Android the reverse-remote screen capturer, then
      // the client connection manager. Neither iOS nor (yet) Windows
      // captures its screen for the Mac.
      Get.put(VideoDecoderChannel(), permanent: true);
      if (defaultTargetPlatform == TargetPlatform.android) {
        Get.put(AndroidCaptureChannel(), permanent: true);
      }
      Get.put(BatteryChannel(), permanent: true);
      // What adb delivers from the Mac: the key of each USB session (kept
      // by UsbSessionService) and its Wi-Fi pairing. On iOS and Windows the
      // USB link never runs, so the service stays inert (registered so no
      // Get.find throws); the iPhone's pairing comes from the devicectl
      // inbox, the Windows client's from a pasted code (debug builds).
      Get.put(UsbSessionService(), permanent: true);
      Get.put(WifiPairingChannel(), permanent: true);
      Get.put<BaseConnectionManager>(ClientConnectionManager(), permanent: true);
    }
  }
}
