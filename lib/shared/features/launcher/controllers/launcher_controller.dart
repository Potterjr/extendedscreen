import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Host-side landing screen: pick what to do this session (use the tablet as a
/// second monitor, or remote-control the Mac), then continue to the connection
/// screen. The chosen [SessionMode] is persisted so it reconnects in the same
/// mode after a settings change.
class LauncherController extends GetxController {
  final _settings = Get.find<SettingsService>();

  Future<void> _select(SessionMode mode) async {
    await _settings.setSessionMode(mode);
    Get.toNamed(AppRoutes.home);
  }

  Future<void> onSelectExtendedScreen() =>
      _select(SessionMode.extendedScreen);

  Future<void> onSelectRemoteControl() =>
      _select(SessionMode.remoteControl);

  void onGoToSettings() => Get.toNamed(AppRoutes.settings);
}
