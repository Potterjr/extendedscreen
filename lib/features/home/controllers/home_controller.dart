import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/device_model.dart';

class HomeController extends GetxController {
  final _connection = Get.find<BaseConnectionManager>();

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

    // Client (Android): auto-open the display once the link is live. The home
    // screen still shows the steps + Open View button (for when the user backs
    // out and wants to re-open). The host stays on this screen as the source.
    if (!_connection.isHost) {
      ever<ConnectionPhase>(_connection.phase, (p) {
        if (p.isActive && Get.currentRoute == AppRoutes.home) {
          Get.toNamed(AppRoutes.display);
        }
      });
      // Already streaming when home opens (resumed onto home while live) —
      // `ever` won't fire without a change, so jump after the first frame.
      if (_connection.phase.value.isActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (Get.currentRoute == AppRoutes.home) {
            Get.toNamed(AppRoutes.display);
          }
        });
      }
    }
  }

  /// Client: open the display view manually (via the Open View button). Only
  /// meaningful once the stream is live.
  void onOpenView() {
    if (_connection.phase.value.isActive) {
      Get.toNamed(AppRoutes.display);
    }
  }

  Future<void> refreshDevices() => _connection.refreshDevices();

  void onConnectTap() {
    if (_connection.phase.value.isActive) {
      _connection.disconnect();
    } else {
      _connection.connect();
    }
  }

  /// Host: connect to the chosen Android client. Selecting a device is the only
  /// way to connect. The display renders on the Android device (it auto-opens
  /// there); the Mac stays on this screen as the capture source.
  Future<void> onSelectDevice(DeviceModel device) async {
    await _connection.connect(serial: device.serial);
  }

  void onGoToSettings() {
    Get.toNamed(AppRoutes.settings);
  }
}
