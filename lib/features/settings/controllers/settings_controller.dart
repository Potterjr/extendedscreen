import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import '../../../core/connection/connection_manager.dart';
import '../../../core/connection/connection_state.dart';
import '../../../core/models/display_config_model.dart';
import '../../../core/platform/permissions_channel.dart';
import '../../../core/services/settings_service.dart';

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
  final _cm = Get.find<ConnectionManager>();
  final _perms = PermissionsChannel();

  late final mode = _settings.displayMode.obs;
  late final fps = _settings.fps.obs;
  late final bitrate = _settings.bitrate.obs;
  RxBool get showPerformanceOverlay => _settings.showPerformanceOverlay;
  RxBool get showHudOverlay => _settings.showHudOverlay;

  final bitrateOptions = [
    (label: '8 Mbps', value: 8000000),
    (label: '15 Mbps', value: 15000000),
    (label: '25 Mbps', value: 25000000),
    (label: '40 Mbps', value: 40000000),
  ];

  final fpsOptions = [30, 60, 120];
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

  void setFps(int f) {
    if (fps.value == f) return;
    fps.value = f;
    _settings.setFps(f);
    _reapply();
  }

  void setBitrate(int bps) {
    if (bitrate.value == bps) return;
    bitrate.value = bps;
    _settings.setBitrate(bps);
    _reapply();
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

  Future<void> _reapply() async {
    if (isApplying.value) return;
    isApplying.value = true;
    try {
      if (_cm.isHost) {
        await _cm.reapplyCapture();
      } else if (_cm.phase.value.isActive) {
        _cm.requestIdr();
      }
    } finally {
      isApplying.value = false;
    }
  }

  void togglePerformanceOverlay() =>
      _settings.setShowPerformanceOverlay(!showPerformanceOverlay.value);

  void toggleHudOverlay() =>
      _settings.setShowHudOverlay(!showHudOverlay.value);

  String get bitrateLabel =>
      bitrateOptions
          .firstWhereOrNull((o) => o.value == bitrate.value)
          ?.label ??
      '${(bitrate.value / 1000000).toStringAsFixed(0)} Mbps';
}
