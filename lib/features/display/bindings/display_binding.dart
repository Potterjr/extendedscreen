import 'package:get/get.dart';
import '../controllers/display_controller.dart';

class DisplayBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(DisplayController());
  }
}
