import 'package:get/get.dart';
import '../../../app/routes/app_routes.dart';
import '../../../core/connection/connection_manager.dart';
import '../../../core/connection/connection_state.dart';
import '../../../core/models/device_model.dart';

class HomeController extends GetxController {
  final _connection = Get.find<ConnectionManager>();

  ConnectionPhase get phase => _connection.phase.value;
  DeviceModel? get device => _connection.activeDevice.value;
  int get latencyMs => _connection.latencyMs.value;
  String get errorMessage => _connection.errorMessage.value;

  RxBool get isConnecting => _connection.phase.value.isConnecting.obs;

  void onConnectTap() {
    if (_connection.phase.value.isActive) {
      _connection.disconnect();
    } else {
      _connection.connect();
    }
  }

  void onGoToDisplay() {
    Get.toNamed(AppRoutes.display);
  }

  void onGoToSettings() {
    Get.toNamed(AppRoutes.settings);
  }
}
