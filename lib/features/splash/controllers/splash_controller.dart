import 'package:get/get.dart';
import '../../../app/routes/app_routes.dart';
import '../../../core/connection/connection_manager.dart';
import '../../../core/connection/connection_state.dart';

class SplashController extends GetxController {
  @override
  void onReady() {
    super.onReady();
    // Kick off connection immediately; navigate after brief splash.
    // On the host with multiple devices this stays disconnected so the user
    // picks a client on the home screen instead of auto-grabbing one.
    final cm = Get.find<ConnectionManager>();
    if (cm.phase.value == ConnectionPhase.disconnected) {
      cm.autoConnect();
    }
    Future.delayed(const Duration(seconds: 2), () {
      Get.offAllNamed(AppRoutes.home);
    });
  }
}
