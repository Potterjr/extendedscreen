import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

class SplashController extends GetxController {
  // onInit, not onReady: onReady waits for a frame after this controller is
  // made, and a macOS app launched behind other windows is `hidden` to
  // Flutter, which then draws none. Nothing here needs one.
  @override
  void onInit() {
    super.onInit();
    // Kick off connection immediately; navigate after brief splash.
    // The host connects by itself only when there is nothing to choose (see
    // HostConnectionManager.autoConnect); otherwise the user picks a client
    // on the home screen.
    final cm = Get.find<BaseConnectionManager>();
    if (cm.phase.value == ConnectionPhase.disconnected) {
      cm.autoConnect();
    }
    Future.delayed(const Duration(seconds: 2), () {
      // Both roles land straight on the connection screen — the host picks
      // its session mode there (a compact selector, not a separate forced
      // screen); the client doesn't choose (the host drives the mode) and
      // auto-opens the display once live.
      Get.offAllNamed(AppRoutes.home);
    });
  }
}
