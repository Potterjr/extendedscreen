import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
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
  String get resolutionLabel => resolutionLabelFor(_lastPanel);

  String resolutionLabelFor(ClientPanel panel) =>
      '${(widthFor(panel) * scaleFactor).round()}×'
      '${(heightFor(panel) * scaleFactor).round()}';

  /// Bitrate in Mbps, e.g. "20 Mbps".
  String get bitrateLabel => bitrateLabelFor(_lastPanel);

  String bitrateLabelFor(ClientPanel panel) =>
      '${(bitrateFor(panel) / 1000000).round()} Mbps';

  // The last client panel a HELLO reported (persisted), for the getters
  // that take none. A session sizes its capture from its own tablet's panel,
  // and Settings labels the presets with the focused tablet's, both with the
  // `…For` variants.
  static ClientPanel get _lastPanel => Get.find<SettingsService>().lastClientPanel;

  // Quality's density (20 Mbps at native 60 Hz) in bits per pixel per frame,
  // so Max scales its bitrate with whatever resolution × rate it lands on.
  static const _qualityBitsPerPixel = 20000000 / (2960 * 1848 * 60);

  // Logical width/height passed to CGVirtualDisplay (panel ÷ 2 = HiDPI points).
  // For `custom` these are fallbacks — the live values come from SettingsService.
  int get width => widthFor(_lastPanel);
  int get height => heightFor(_lastPanel);

  int widthFor(ClientPanel panel) => switch (this) {
        EncodePreset.custom => 1920,
        _ => panel.width ~/ 2,
      };

  int heightFor(ClientPanel panel) => switch (this) {
        EncodePreset.custom => 1200,
        _ => panel.height ~/ 2,
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

  int get bitrate => bitrateFor(_lastPanel);

  int bitrateFor(ClientPanel panel) => switch (this) {
        EncodePreset.max =>
          (_qualityBitsPerPixel * panel.width * panel.height * panel.maxHz)
              .round()
              .clamp(8000000, 50000000),
        EncodePreset.quality => 20000000,
        EncodePreset.balanced => 8000000,
        EncodePreset.performance => 12000000,
        EncodePreset.custom => 12000000,
      };

  // Refresh rate is tied to the preset (no separate frame-rate setting).
  // Performance trades resolution for a high 120Hz capture; the rest run 60Hz.
  int get refreshRate => refreshRateFor(_lastPanel);

  int refreshRateFor(ClientPanel panel) => switch (this) {
        EncodePreset.max => panel.maxHz,
        EncodePreset.quality => 60,
        EncodePreset.balanced => 60,
        EncodePreset.performance => 120,
        EncodePreset.custom => 60,
      };

  /// What a session captures and encodes for a tablet with [panel] under this
  /// preset ([custom] holds the custom preset's values; the fixed presets
  /// ignore it). Reads no settings, so it can be worked out for any tablet.
  ///
  /// The desktop is always the panel's logical size (panel ÷ 2, HiDPI);
  /// custom's width is the *physical* encode width, so it only changes the
  /// scale, kept between half and double the logical size.
  DisplayConfigModel configFor(
    ClientPanel panel, {
    CustomPreset custom = const CustomPreset(),
    required DisplayMode mode,
    required CodecType codec,
  }) {
    final isCustom = this == EncodePreset.custom;
    final logicalWidth = panel.width ~/ 2;
    return DisplayConfigModel(
      width: logicalWidth,
      height: panel.height ~/ 2,
      scaleFactor: isCustom
          ? (custom.width / logicalWidth).clamp(0.5, 2.0).toDouble()
          : scaleFactor,
      refreshRate: isCustom ? custom.refreshRate : refreshRateFor(panel),
      bitrate: isCustom ? custom.bitrateMbps * 1000000 : bitrateFor(panel),
      mode: mode,
      codec: codec,
      adaptiveFps: this == EncodePreset.max,
    );
  }
}

/// The custom preset's values as Settings keeps them: the physical encode
/// width, the bitrate in Mbps and the refresh rate.
class CustomPreset {
  const CustomPreset({
    this.width = 1920,
    this.bitrateMbps = 12,
    this.refreshRate = 60,
  });

  final int width;
  final int bitrateMbps;
  final int refreshRate;
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
  // The highest rate this session may run at while other tablets share the
  // encoder (EncodeBudget), below [refreshRate]; null when nothing limits
  // it. Kept apart from [refreshRate] because the native side starts its
  // adaptive ladder from that, and a ceiling that is raised later must leave
  // room to climb back.
  final int? fpsCeiling;

  const DisplayConfigModel({
    required this.width,
    required this.height,
    required this.refreshRate,
    required this.scaleFactor,
    required this.mode,
    required this.codec,
    required this.bitrate,
    this.adaptiveFps = false,
    this.fpsCeiling,
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
    int? fpsCeiling,
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
        fpsCeiling: fpsCeiling ?? this.fpsCeiling,
      );

  /// This config held to [ceiling]: the ceiling when it is below
  /// [refreshRate], else none.
  DisplayConfigModel withFpsCeiling(int ceiling) => DisplayConfigModel(
        width: width,
        height: height,
        refreshRate: refreshRate,
        scaleFactor: scaleFactor,
        mode: mode,
        codec: codec,
        bitrate: bitrate,
        adaptiveFps: adaptiveFps,
        fpsCeiling: ceiling < refreshRate ? ceiling : null,
      );

  // What the encoder is handed: logical size × scale, rounded down to even
  // numbers, exactly as ScreenCapturePlugin.swift's startCapture does it.
  int get encodedWidth => (width * scaleFactor).toInt() & ~1;
  int get encodedHeight => (height * scaleFactor).toInt() & ~1;
  int get encodedPixels => encodedWidth * encodedHeight;

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'refreshRate': refreshRate,
        'scaleFactor': scaleFactor,
        'mode': mode.index,
        'codec': codec == CodecType.h265 ? 'h265' : 'h264',
        'bitrate': bitrate,
        'adaptiveFps': adaptiveFps,
        if (fpsCeiling != null) 'fpsCeiling': fpsCeiling,
      };
}
