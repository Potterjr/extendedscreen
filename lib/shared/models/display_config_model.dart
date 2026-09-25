import 'package:get/get.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

enum DisplayMode { extend, mirror }

enum CodecType { h264, h265 }

/// [max] is the default: native panel resolution at the tablet's top refresh
/// rate, with the host encoder stepping the rate down if it can't keep up.
enum EncodePreset { max, quality, balanced, performance, custom }

extension EncodePresetX on EncodePreset {
  // Localized strings resolve against the active GetX locale at read time.
  String get label => switch (this) {
        EncodePreset.max => 'preset_max_label'.tr,
        EncodePreset.quality => 'preset_quality_label'.tr,
        EncodePreset.balanced => 'preset_balanced_label'.tr,
        EncodePreset.performance => 'preset_performance_label'.tr,
        EncodePreset.custom => 'preset_custom_label'.tr,
      };

  /// One-line spec, e.g. "2960×1848 · 20 Mbps · 60 Hz".
  String get specLine => '$resolutionLabel · $bitrateLabel · $refreshRate Hz';

  /// Short tagline shown next to the preset name.
  String get tagline => switch (this) {
        EncodePreset.max => 'preset_max_tagline'.tr,
        EncodePreset.quality => 'preset_quality_tagline'.tr,
        EncodePreset.balanced => 'preset_balanced_tagline'.tr,
        EncodePreset.performance => 'preset_performance_tagline'.tr,
        EncodePreset.custom => 'preset_custom_tagline'.tr,
      };

  /// Detailed, plain-language explanation of the trade-off.
  String get description => switch (this) {
        EncodePreset.max => 'preset_max_desc'.tr,
        EncodePreset.quality => 'preset_quality_desc'.tr,
        EncodePreset.balanced => 'preset_balanced_desc'.tr,
        EncodePreset.performance => 'preset_performance_desc'.tr,
        EncodePreset.custom => 'preset_custom_desc'.tr,
      };

  /// Physical pixels the host actually captures (logical size × scaleFactor).
  String get resolutionLabel =>
      '${(width * scaleFactor).round()}×${(height * scaleFactor).round()}';

  /// Bitrate in Mbps, e.g. "20 Mbps".
  String get bitrateLabel => '${(bitrate / 1000000).round()} Mbps';

  // Native panel of the connected client (physical px, learned from its HELLO
  // and persisted) — fixed presets are defined relative to this, so they adapt
  // to whatever device is plugged in.
  static int get _panelW => Get.find<SettingsService>().clientPanelWidth.value;
  static int get _panelH => Get.find<SettingsService>().clientPanelHeight.value;
  // Top refresh rate the connected client's panel supports (from its HELLO).
  static int get _panelMaxHz =>
      Get.find<SettingsService>().clientMaxRefreshHz.value;

  // Quality's density (20 Mbps at native 60 Hz) in bits per pixel per frame,
  // so Max scales its bitrate with whatever resolution × rate it lands on.
  static const _qualityBitsPerPixel = 20000000 / (2960 * 1848 * 60);

  // Logical width/height passed to CGVirtualDisplay (panel ÷ 2 = HiDPI points).
  // For `custom` these are fallbacks — the live values come from SettingsService.
  int get width => switch (this) {
        EncodePreset.custom => 1920,
        _ => _panelW ~/ 2,
      };

  int get height => switch (this) {
        EncodePreset.custom => 1200,
        _ => _panelH ~/ 2,
      };

  // Performance uses 1.0x (no HiDPI): encodes at half the panel resolution
  // — 25% of Quality pixel count so VT can sustain 120fps throughput.
  double get scaleFactor => switch (this) {
        EncodePreset.max => 2.0,
        EncodePreset.quality => 2.0,
        EncodePreset.balanced => 2.0,
        EncodePreset.performance => 1.0,
        EncodePreset.custom => 1.0,
      };

  int get bitrate => switch (this) {
        EncodePreset.max => (_qualityBitsPerPixel * _panelW * _panelH * _panelMaxHz)
            .round()
            .clamp(8000000, 50000000),
        EncodePreset.quality => 20000000,
        EncodePreset.balanced => 8000000,
        EncodePreset.performance => 12000000,
        EncodePreset.custom => 12000000,
      };

  // Refresh rate is tied to the preset (no separate frame-rate setting).
  // Performance trades resolution for a high 120Hz capture; the rest run 60Hz.
  int get refreshRate => switch (this) {
        EncodePreset.max => _panelMaxHz,
        EncodePreset.quality => 60,
        EncodePreset.balanced => 60,
        EncodePreset.performance => 120,
        EncodePreset.custom => 60,
      };
}

class DisplayConfigModel {
  final int width;
  final int height;
  final int refreshRate;
  final double scaleFactor;
  final DisplayMode mode;
  final CodecType codec;
  final int bitrate;
  // Let the native encoder step [refreshRate] down if it can't keep up (Max).
  final bool adaptiveFps;

  const DisplayConfigModel({
    required this.width,
    required this.height,
    required this.refreshRate,
    required this.scaleFactor,
    required this.mode,
    required this.codec,
    required this.bitrate,
    this.adaptiveFps = false,
  });

  // Logical desktop @ 2x HiDPI → captures at the client's native panel
  // resolution for pixel-perfect sharpness. Width/height here are only
  // fallbacks; the live values are derived from the connected device.
  static const defaultConfig = DisplayConfigModel(
    width: 1480,
    height: 924,
    refreshRate: 60,
    scaleFactor: 2.0,
    mode: DisplayMode.extend,
    codec: CodecType.h264,
    bitrate: 20000000,
  );

  DisplayConfigModel copyWith({
    int? width,
    int? height,
    int? refreshRate,
    double? scaleFactor,
    DisplayMode? mode,
    CodecType? codec,
    int? bitrate,
    bool? adaptiveFps,
  }) =>
      DisplayConfigModel(
        width: width ?? this.width,
        height: height ?? this.height,
        refreshRate: refreshRate ?? this.refreshRate,
        scaleFactor: scaleFactor ?? this.scaleFactor,
        mode: mode ?? this.mode,
        codec: codec ?? this.codec,
        bitrate: bitrate ?? this.bitrate,
        adaptiveFps: adaptiveFps ?? this.adaptiveFps,
      );

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'refreshRate': refreshRate,
        'scaleFactor': scaleFactor,
        'mode': mode.index,
        'codec': codec == CodecType.h265 ? 'h265' : 'h264',
        'bitrate': bitrate,
        'adaptiveFps': adaptiveFps,
      };
}
