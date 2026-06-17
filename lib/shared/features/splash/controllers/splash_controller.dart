import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

class SplashController extends GetxController {
  @override
  void onReady() {
    super.onReady();
    // Kick off connection immediately; navigate after brief splash.
    // On the host with multiple devices this stays disconnected so the user
    // picks a client on the home screen instead of auto-grabbing one.
    final cm = Get.find<BaseConnectionManager>();
    if (cm.phase.value == ConnectionPhase.disconnected) {
      cm.autoConnect();
    }
    Future.delayed(const Duration(seconds: 2), () {
      // Host picks a session mode on the launcher first; the client doesn't
      // choose (the host drives the mode) so it goes straight to the
      // connection screen and auto-opens the display once live.
      Get.offAllNamed(cm.isHost ? AppRoutes.launcher : AppRoutes.home);
    });
  }
}
