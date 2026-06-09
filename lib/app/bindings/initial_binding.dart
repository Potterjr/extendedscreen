import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import '../../core/connection/adb_service.dart';
import '../../core/connection/socket_service.dart';
import '../../core/connection/connection_manager.dart';
import '../../core/platform/screen_capture_channel.dart';
import '../../core/platform/input_inject_channel.dart';
import '../../core/platform/video_decoder_channel.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/logger_service.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(LoggerService(), permanent: true);
    Get.put(SettingsService(), permanent: true);

    // Connection layer — permanent so they survive route changes.
    Get.put(AdbService(), permanent: true);
    Get.put(SocketService(), permanent: true);

    // macOS-only capture / input channels.
    if (GetPlatform.isMacOS || GetPlatform.isDesktop) {
      Get.put(ScreenCaptureChannel(), permanent: true);
      Get.put(InputInjectChannel(), permanent: true);
    }

    // Android video decoder — permanent so the channel is always registered;
    // the native codec is initialized/released per-session by DisplayController.
    if (defaultTargetPlatform == TargetPlatform.android) {
      Get.put(VideoDecoderChannel(), permanent: true);
    }

    Get.put(ConnectionManager(), permanent: true);
  }
}
