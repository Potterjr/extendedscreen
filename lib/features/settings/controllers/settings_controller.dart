import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/platform/permissions_channel.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class PermissionItem {
  final String key;
  final String label;
  final String description;
  final bool isGranted;

  const PermissionItem({
    required this.key,
    required this.label,
    required this.description,
    required this.isGranted,
  });
}

class SettingsController extends GetxController {
  final _settings = Get.find<SettingsService>();
  final _cm = Get.find<BaseConnectionManager>();
  final _perms = PermissionsChannel();

  late final mode = _settings.displayMode.obs;
  late final encodePreset = _settings.encodePreset.obs;
  late final codec = _settings.codec.obs;
  RxBool get showPerformanceOverlay => _settings.showPerformanceOverlay;
  RxBool get showHudOverlay => _settings.showHudOverlay;

  final isApplying = false.obs;
  final permissions = <PermissionItem>[].obs;
  final isLoadingPerms = false.obs;

  @override
  void onReady() {
    super.onReady();
    refreshPermissions();
  }

  Future<void> refreshPermissions() async {
    isLoadingPerms.value = true;
    final status = await _perms.checkPermissions();
    permissions.value = _buildPermissionList(status);
    isLoadingPerms.value = false;
  }

  List<PermissionItem> _buildPermissionList(Map<String, bool> status) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return [
        PermissionItem(
          key: 'screen_recording',
          label: 'Screen Recording',
          description: 'Required to capture the display content',
          isGranted: status['screen_recording'] ?? false,
        ),
        PermissionItem(
          key: 'accessibility',
          label: 'Accessibility',
          description: 'Required to inject touch and keyboard input',
          isGranted: status['accessibility'] ?? false,
        ),
      ];
    } else {
      return [
        PermissionItem(
          key: 'battery_optimization',
          label: 'Battery Optimization',
          description: 'Exempt from battery optimization to keep streaming alive',
          isGranted: status['battery_optimization'] ?? false,
        ),
        PermissionItem(
          key: 'display_over_apps',
          label: 'Display Over Other Apps',
          description: 'Allows the display overlay to render on top',
          isGranted: status['display_over_apps'] ?? false,
        ),
      ];
    }
  }

  Future<void> openPermission(String key) async {
    await _perms.openPermission(key);
    // Re-check after a short delay to update the status.
    await Future.delayed(const Duration(seconds: 1));
    await refreshPermissions();
  }

  void setMode(DisplayMode m) {
    if (mode.value == m) return;
    mode.value = m;
    _applyMode(m);
  }

  void setEncodePreset(EncodePreset preset) {
    if (encodePreset.value == preset) return;
    encodePreset.value = preset;
    _settings.setEncodePreset(preset);
    _reconnect();
  }

  void setCodec(CodecType c) {
    if (codec.value == c) return;
    codec.value = c;
    _settings.setCodec(c);
    _reconnect();
  }

  Future<void> _applyMode(DisplayMode m) async {
    if (isApplying.value) return;
    isApplying.value = true;
    try {
      await _cm.changeMode(m);
    } finally {
      isApplying.value = false;
    }
  }

  /// Performance changes (encode preset) require a full reconnect to take
  /// effect — the capture + handshake pipeline restarts with the new settings.
  Future<void> _reconnect() async {
    if (isApplying.value) return;
    isApplying.value = true;
    try {
      await _cm.reconnect();
    } finally {
      isApplying.value = false;
    }
  }

  void togglePerformanceOverlay() =>
      _settings.setShowPerformanceOverlay(!showPerformanceOverlay.value);

  void toggleHudOverlay() =>
      _settings.setShowHudOverlay(!showHudOverlay.value);
}
