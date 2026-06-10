import 'package:get/get.dart';
import 'package:extendedscreen/features/splash/controllers/splash_controller.dart';

class SplashBinding extends Bindings {
  @override
  void dependencies() {
    // Core services are registered permanently in InitialBinding.
    Get.put(SplashController());
  }
}
