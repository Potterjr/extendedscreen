import 'package:get/get.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/controllers/display_controller.dart';

class DisplayBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(DisplayController());
  }
}
