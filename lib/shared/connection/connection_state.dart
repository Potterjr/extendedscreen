import 'package:get/get.dart';

enum ConnectionPhase {
  disconnected,
  detectingDevice,
  adbConnecting,
  portForwarding,
  handshaking,
  configuring,
  streaming,
  paused,
  error,
}

extension ConnectionPhaseX on ConnectionPhase {
  bool get isActive =>
      this == ConnectionPhase.streaming || this == ConnectionPhase.paused;

  bool get isConnecting =>
      this != ConnectionPhase.disconnected &&
      this != ConnectionPhase.streaming &&
      this != ConnectionPhase.paused &&
      this != ConnectionPhase.error;

  String get label => switch (this) {
        ConnectionPhase.disconnected => 'phase_disconnected'.tr,
        ConnectionPhase.detectingDevice => 'phase_detecting_device'.tr,
        ConnectionPhase.adbConnecting => 'phase_adb_connecting'.tr,
        ConnectionPhase.portForwarding => 'phase_port_forwarding'.tr,
        ConnectionPhase.handshaking => 'phase_handshaking'.tr,
        ConnectionPhase.configuring => 'phase_configuring'.tr,
        ConnectionPhase.streaming => 'phase_streaming'.tr,
        ConnectionPhase.paused => 'phase_paused'.tr,
        ConnectionPhase.error => 'phase_error'.tr,
      };
}
