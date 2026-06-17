import 'package:get/get.dart';
import 'package:extendedscreen/shared/features/launcher/controllers/launcher_controller.dart';

class LauncherBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(LauncherController());
  }
}
