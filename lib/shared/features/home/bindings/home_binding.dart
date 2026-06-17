import 'package:get/get.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';

class HomeBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(HomeController());
  }
}
