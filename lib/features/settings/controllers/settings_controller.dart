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

  // Custom preset values (physical resolution px, Mbps, Hz).
  late final customWidth = _settings.customWidth.obs;
  late final customHeight = _settings.customHeight.obs;
  late final customBitrateMbps = _settings.customBitrateMbps.obs;
  late final customRefreshRate = _settings.customRefreshRate.obs;

  String get customResolutionLabel => '${customWidth.value}×${customHeight.value}';
  String get customBitrateLabel => '${customBitrateMbps.value} Mbps';

  /// Resolution / bitrate / refresh-rate options offered for the custom preset.
  final customResolutions = const [
    (w: 2960, h: 1848),
    (w: 2368, h: 1480),
    (w: 1920, h: 1200),
    (w: 1480, h: 924),
    (w: 1280, h: 800),
  ];
  final customBitrateOptions = const [4, 6, 8, 12, 16, 20, 30, 40];
  final customRefreshOptions = const [30, 60, 90, 120];
  RxBool get showPerformanceOverlay => _settings.showPerformanceOverlay;
  RxBool get showHudOverlay => _settings.showHudOverlay;

  /// Settings are adjustable only on the host (macOS); the client is read-only.
  bool get isHost => _cm.isHost;

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
    _settings.setDisplayMode(m);
    _reconnect();
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

  void setCustomResolution(int w, int h) {
    if (customWidth.value == w && customHeight.value == h) return;
    customWidth.value = w;
    customHeight.value = h;
    _settings.setCustomResolution(w, h);
    _reconnect();
  }

  void setCustomBitrate(int mbps) {
    if (customBitrateMbps.value == mbps) return;
    customBitrateMbps.value = mbps;
    _settings.setCustomBitrateMbps(mbps);
    _reconnect();
  }

  void setCustomRefreshRate(int hz) {
    if (customRefreshRate.value == hz) return;
    customRefreshRate.value = hz;
    _settings.setCustomRefreshRate(hz);
    _reconnect();
  }

  /// Every setting change persists the value, then restarts the connection so
  /// the host's capture + encode pipeline picks it up. No-op (just saves) when
  /// nothing is connected.
  Future<void> _reconnect() async {
    if (isApplying.value) return;
    isApplying.value = true;
    try {
      await _cm.reconnect();
    } finally {
      isApplying.value = false;
    }
  }

  void togglePerformanceOverlay() {
    _settings.setShowPerformanceOverlay(!showPerformanceOverlay.value);
    _cm.sendUiFlags(); // push to the client (overlays render there)
  }

  void toggleHudOverlay() {
    _settings.setShowHudOverlay(!showHudOverlay.value);
    _cm.sendUiFlags();
  }
}
