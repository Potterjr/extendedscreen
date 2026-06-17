import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_host_controller.dart';

class RemoteHostBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(RemoteHostController());
  }
}
