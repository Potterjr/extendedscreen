import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
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

  /// The panel the preset labels and the custom resolutions are worked out
  /// for: the focused tablet's on the host, else the last one a HELLO
  /// reported. Presets stay app-wide, and each tablet gets them at its own
  /// panel; the labels show what the tablet Home has focused gets.
  ClientPanel get panelForLabels {
    // Read first so an Obx also follows the global panel, which every HELLO
    // updates: the focused tablet's own panel is not observable.
    final last = _settings.lastClientPanel;
    final cm = _cm;
    if (cm is! HostConnectionManager) return last;
    final key = cm.focusedKey.value;
    return (key == null ? null : cm.sessions[key])?.panel ?? last;
  }

  /// What [preset] encodes at, for [panelForLabels] (custom: its own values).
  String resolutionLabelFor(EncodePreset preset) =>
      preset == EncodePreset.custom
          ? customResolutionLabel
          : preset.resolutionLabelFor(panelForLabels);

  String bitrateLabelFor(EncodePreset preset) => preset == EncodePreset.custom
      ? customBitrateLabel
      : preset.bitrateLabelFor(panelForLabels);

  int refreshRateFor(EncodePreset preset) => preset == EncodePreset.custom
      ? customRefreshRate.value
      : preset.refreshRateFor(panelForLabels);

  /// Resolution options offered for the custom preset, derived from
  /// [panelForLabels] (native, 80%, common sizes, half).
  List<({int w, int h})> get customResolutions {
    final panel = panelForLabels;
    final pw = panel.width;
    final ph = panel.height;
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
  RxBool get keepMacCursor => _settings.keepMacCursor;

  /// Active UI language code ('en' / 'th') and its setter for the picker.
  RxString get localeCode => _settings.localeCode;
  void setLocale(String code) => _settings.setLocale(code);

  /// Settings are adjustable only on the host (macOS); the client is read-only.
  bool get isHost => _cm.isHost;

  /// The link this device is set to use (picked on Home), for the Info rows.
  bool get isWifi => _settings.linkTypeRx.value == LinkType.wifi;

  /// Host: how many tablets may be connected at once (USB, Extended
  /// screen; the encoder estimate can allow fewer).
  RxInt get maxTablets => _settings.maxTabletsRx;

  /// Saved only: the hub reads it at the next pick or admission, and a
  /// lower cap ends no tablet already connected, so nothing reconnects.
  void setMaxTablets(int n) {
    if (maxTablets.value == n) return;
    _settings.setMaxTablets(n);
  }

  /// Host: the Encoder line, the chip the budget estimates from, the codec
  /// and what the encoder is taken to manage with it (all engines), marked
  /// as an estimate, or as measured once this Mac's encoder was seen to
  /// manage more ([EncodeBudget.isLearned]). A dash without a hub.
  String get encoderSummary {
    final cm = _cm;
    if (cm is! HostConnectionManager) return '—';
    cm.capacityChanges.value;
    final chip = cm.hostInfo.value?.chip ?? '';
    final c = codec.value;
    return [
      if (chip.isNotEmpty) chip,
      c == CodecType.h265 ? 'H.265' : 'H.264',
      (cm.budget.isLearned(c)
              ? 'settings_encoder_measured'
              : 'settings_encoder_estimated')
          .trParams({'mpx': '${cm.budget.capacity(c).round()}'}),
    ].join(' · ');
  }

  /// Names of the target (client) devices: the models of the live tablets,
  /// else the connected device's model, else the last connected one, else a
  /// generic fallback.
  String get targetDeviceNames {
    final cm = _cm;
    if (cm is HostConnectionManager) {
      final models = [
        for (final s in cm.sessions.values)
          if (s.phase.value.isActive) s.activeDevice.value?.model ?? '',
      ].where((m) => m.isNotEmpty);
      if (models.isNotEmpty) return models.join(', ');
    }
    final connected = _cm.activeDevice.value?.model;
    if (connected != null && connected.isNotEmpty) return connected;
    final last = _settings.lastDeviceName;
    if (last != null && last.isNotEmpty) return last;
    return 'device_default_name'.tr;
  }

  /// Host: the Wi-Fi identity was reset while this screen was open, so the
  /// row can say what to do next instead of looking as if nothing happened.
  final wifiPairingReset = false.obs;

  /// Host: discard this Mac's Wi-Fi identity (the view asked first). Every
  /// paired tablet has to connect over USB once to pair again.
  Future<void> resetWifiPairing() async {
    await _cm.resetWifiIdentity();
    wifiPairingReset.value = true;
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
    _reconnectDebounce?.cancel();
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
    // The Android rows (battery, overlay) mean nothing on iOS, which has no
    // permissions plugin. TODO(P2): one Local Network row there.
    if (runsOnIos) return const [];
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
    // Choosing Max also switches to its default codec (H.265); the codec
    // toggle can still override it afterwards. One reconnect covers both.
    if (preset == EncodePreset.max) {
      final c = SettingsService.defaultCodecFor(preset);
      codec.value = c;
      _settings.setCodec(c);
    }
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

  Timer? _reconnectDebounce;
  bool _reconnecting = false;

  /// Every setting change persists the value, then restarts the connection so
  /// the host's capture + encode pipeline picks it up. Debounced so changing
  /// several fields in one sheet visit (e.g. preset + codec, or the three
  /// custom values) collapses into a single reconnect instead of one per
  /// field. No-op (just saves) when nothing is connected.
  Future<void> _reconnect() async {
    isApplying.value = true;
    _reconnectDebounce?.cancel();
    _reconnectDebounce =
        Timer(const Duration(milliseconds: 350), _doReconnect);
  }

  Future<void> _doReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      await _cm.reconnect();
    } finally {
      _reconnecting = false;
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

  /// Applies at once with no reconnect: InputInjectChannel watches the setting
  /// and pushes it to the native injector.
  void toggleKeepMacCursor() =>
      _settings.setKeepMacCursor(!keepMacCursor.value);
}
