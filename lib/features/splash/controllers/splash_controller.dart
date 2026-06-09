import 'package:get/get.dart';
import '../../../app/routes/app_routes.dart';
import '../../../core/connection/connection_manager.dart';
import '../../../core/connection/connection_state.dart';

class SplashController extends GetxController {
  @override
  void onReady() {
    super.onReady();
    // Kick off connection immediately; navigate after brief splash.
    final cm = Get.find<ConnectionManager>();
    if (cm.phase.value == ConnectionPhase.disconnected) {
      cm.connect();
    }
    Future.delayed(const Duration(seconds: 2), () {
      Get.offAllNamed(AppRoutes.home);
    });
  }
}
