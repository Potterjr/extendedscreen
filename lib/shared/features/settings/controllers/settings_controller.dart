import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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

  /// Resolution options offered for the custom preset, derived from the
  /// connected device's native panel (native, 80%, common sizes, half).
  List<({int w, int h})> get customResolutions {
    final pw = _settings.clientPanelWidth.value;
    final ph = _settings.clientPanelHeight.value;
    ({int w, int h}) even(double w, double h) =>
        (w: (w / 2).round() * 2, h: (h / 2).round() * 2);
    final options = [
      even(pw.toDouble(), ph.toDouble()),
      even(pw * 0.8, ph * 0.8),
      (w: 1920, h: 1200),
      even(pw / 2, ph / 2),
      (w: 1280, h: 800),
    ];
    // De-dupe while preserving order (common sizes may equal a derived one).
    final seen = <String>{};
    return options.where((r) => seen.add('${r.w}x${r.h}')).toList();
  }
  final customBitrateOptions = const [4, 6, 8, 12, 16, 20, 30, 40];
  final customRefreshOptions = const [30, 60, 90, 120];
  RxBool get showPerformanceOverlay => _settings.showPerformanceOverlay;
  RxBool get showHudOverlay => _settings.showHudOverlay;

  /// Active UI language code ('en' / 'th') and its setter for the picker.
  RxString get localeCode => _settings.localeCode;
  void setLocale(String code) => _settings.setLocale(code);

  /// Settings are adjustable only on the host (macOS); the client is read-only.
  bool get isHost => _cm.isHost;

  /// Name of the target (client) device: the connected device's model, else
  /// the last connected one, else a generic fallback.
  String get targetDeviceName {
    final connected = _cm.activeDevice.value?.model;
    if (connected != null && connected.isNotEmpty) return connected;
    final last = _settings.lastDeviceName;
    if (last != null && last.isNotEmpty) return last;
    return 'device_default_name'.tr;
  }

  final isApplying = false.obs;
  final permissions = <PermissionItem>[].obs;
  final isLoadingPerms = false.obs;

  // Scrolls the settings list and marks the Permissions section so the host can
  // jump straight there when a connect attempt is blocked by missing access.
  final scrollController = ScrollController();
  final permissionsKey = GlobalKey();

  @override
  void onReady() {
    super.onReady();
    refreshPermissions();
    // Arrived here from the permission gate — bring Permissions into view.
    final args = Get.arguments;
    if (args is Map && args['scrollTo'] == 'permissions') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPermissions());
    }
  }

  void _scrollToPermissions() {
    final ctx = permissionsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      alignment: 0.05, // near the top of the viewport
    );
  }

  @override
  void onClose() {
    scrollController.dispose();
    super.onClose();
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
          label: 'perm_screen_recording'.tr,
          description: 'perm_screen_recording_desc'.tr,
          isGranted: status['screen_recording'] ?? false,
        ),
        PermissionItem(
          key: 'accessibility',
          label: 'perm_accessibility'.tr,
          description: 'perm_accessibility_desc'.tr,
          isGranted: status['accessibility'] ?? false,
        ),
      ];
    } else {
      return [
        PermissionItem(
          key: 'battery_optimization',
          label: 'perm_battery_optimization'.tr,
          description: 'perm_battery_optimization_desc'.tr,
          isGranted: status['battery_optimization'] ?? false,
        ),
        PermissionItem(
          key: 'display_over_apps',
          label: 'perm_display_over_apps'.tr,
          description: 'perm_display_over_apps_desc'.tr,
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
