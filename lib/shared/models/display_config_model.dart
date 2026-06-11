enum DisplayMode { extend, mirror }

enum CodecType { h264, h265 }

enum EncodePreset { quality, balanced, performance, custom }

extension EncodePresetX on EncodePreset {
  String get label => switch (this) {
        EncodePreset.quality => 'Quality',
        EncodePreset.balanced => 'Balanced',
        EncodePreset.performance => 'Performance',
        EncodePreset.custom => 'Custom',
      };

  /// One-line spec, e.g. "2960×1848 · 20 Mbps · 60 Hz".
  String get specLine => '$resolutionLabel · $bitrateLabel · $refreshRate Hz';

  /// Short tagline shown next to the preset name.
  String get tagline => switch (this) {
        EncodePreset.quality => 'Sharpest image',
        EncodePreset.balanced => 'Best all-round',
        EncodePreset.performance => 'Smoothest motion',
        EncodePreset.custom => 'Your settings',
      };

  /// Detailed, plain-language explanation of the trade-off.
  String get description => switch (this) {
        EncodePreset.quality =>
          'Full native resolution at a high bitrate. Text and fine detail look '
              'their crispest — best for reading, writing and design work. '
              'Uses the most USB bandwidth.',
        EncodePreset.balanced =>
          'Full native resolution at a moderate bitrate. Keeps the picture '
              'sharp while using about half the data of Quality — the best '
              'choice for everyday use.',
        EncodePreset.performance =>
          'Half the resolution but double the frame rate (120 Hz). Motion looks '
              'much smoother at the cost of fine sharpness — best for video, '
              'fast scrolling and animation.',
        EncodePreset.custom =>
          'Set your own resolution, bitrate and refresh rate. For advanced '
              'tuning when the fixed presets do not fit.',
      };

  /// Physical pixels the host actually captures (logical size × scaleFactor).
  String get resolutionLabel =>
      '${(width * scaleFactor).round()}×${(height * scaleFactor).round()}';

  /// Bitrate in Mbps, e.g. "20 Mbps".
  String get bitrateLabel => '${(bitrate / 1000000).round()} Mbps';

  // Logical width/height passed to CGVirtualDisplay (Swift doubles if HiDPI).
  // For `custom` these are fallbacks — the live values come from SettingsService.
  int get width => switch (this) {
        EncodePreset.quality => 1480,
        EncodePreset.balanced => 1480,
        EncodePreset.performance => 1480,
        EncodePreset.custom => 1920,
      };

  int get height => switch (this) {
        EncodePreset.quality => 924,
        EncodePreset.balanced => 924,
        EncodePreset.performance => 924,
        EncodePreset.custom => 1200,
      };

  // Performance uses 1.0x (no HiDPI): encodes 1480×924 instead of 2960×1848
  // — 25% of Quality pixel count so VT can sustain 120fps throughput.
  double get scaleFactor => switch (this) {
        EncodePreset.quality => 2.0,
        EncodePreset.balanced => 2.0,
        EncodePreset.performance => 1.0,
        EncodePreset.custom => 1.0,
      };

  int get bitrate => switch (this) {
        EncodePreset.quality => 20000000,
        EncodePreset.balanced => 8000000,
        EncodePreset.performance => 12000000,
        EncodePreset.custom => 12000000,
      };

  // Refresh rate is tied to the preset (no separate frame-rate setting).
  // Performance trades resolution for a high 120Hz capture; the rest run 60Hz.
  int get refreshRate => switch (this) {
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

  const DisplayConfigModel({
    required this.width,
    required this.height,
    required this.refreshRate,
    required this.scaleFactor,
    required this.mode,
    required this.codec,
    required this.bitrate,
  });

  // Logical desktop 1480×924 @ 2x HiDPI → captures 2960×1848 physical pixels,
  // matching the Tab S10 Ultra's native panel for pixel-perfect sharpness.
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
  }) =>
      DisplayConfigModel(
        width: width ?? this.width,
        height: height ?? this.height,
        refreshRate: refreshRate ?? this.refreshRate,
        scaleFactor: scaleFactor ?? this.scaleFactor,
        mode: mode ?? this.mode,
        codec: codec ?? this.codec,
        bitrate: bitrate ?? this.bitrate,
      );

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'refreshRate': refreshRate,
        'scaleFactor': scaleFactor,
        'mode': mode.index,
        'codec': codec == CodecType.h265 ? 'h265' : 'h264',
        'bitrate': bitrate,
      };
}
