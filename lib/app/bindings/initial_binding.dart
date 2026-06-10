import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/host/connection/adb_service.dart';
import 'package:extendedscreen/host/connection/host_connection_manager.dart';
import 'package:extendedscreen/host/platform/screen_capture_channel.dart';
import 'package:extendedscreen/host/platform/input_inject_channel.dart';
import 'package:extendedscreen/client/connection/client_connection_manager.dart';
import 'package:extendedscreen/client/platform/video_decoder_channel.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(LoggerService(), permanent: true);
    Get.put(SettingsService(), permanent: true);

    // Transport — shared by both roles; permanent so it survives route changes.
    Get.put(SocketService(), permanent: true);

    // Role-specific wiring. The chosen manager is bound to BaseConnectionManager
    // so all shared UI depends on a single interface.
    if (GetPlatform.isMacOS || GetPlatform.isDesktop) {
      // HOST (macOS): capture + input + adb, then the host connection manager.
      Get.put(ScreenCaptureChannel(), permanent: true);
      Get.put(InputInjectChannel(), permanent: true);
      Get.put(AdbService(), permanent: true);
      Get.put<BaseConnectionManager>(HostConnectionManager(), permanent: true);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      // CLIENT (Android): video decoder, then the client connection manager.
      Get.put(VideoDecoderChannel(), permanent: true);
      Get.put<BaseConnectionManager>(ClientConnectionManager(), permanent: true);
    }
  }
}
