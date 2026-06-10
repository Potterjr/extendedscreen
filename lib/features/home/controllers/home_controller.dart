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

  bool get isHost => _connection.isHost;
  RxList<DeviceModel> get availableDevices => _connection.availableDevices;

  RxBool get isConnecting => _connection.phase.value.isConnecting.obs;

  @override
  void onInit() {
    super.onInit();
    // Populate the device picker as soon as the host screen opens.
    _connection.refreshDevices();
  }

  Future<void> refreshDevices() => _connection.refreshDevices();

  void onConnectTap() {
    if (_connection.phase.value.isActive) {
      _connection.disconnect();
    } else {
      _connection.connect();
    }
  }

  /// Host: connect to the chosen Android client and open the display once the
  /// link is live. Selecting a device is the only way to connect.
  Future<void> onSelectDevice(DeviceModel device) async {
    await _connection.connect(serial: device.serial);
    if (_connection.phase.value.isActive) {
      Get.toNamed(AppRoutes.display);
    }
  }

  void onGoToSettings() {
    Get.toNamed(AppRoutes.settings);
  }
}
