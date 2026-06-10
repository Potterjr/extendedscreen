enum DisplayMode { extend, mirror }

enum CodecType { h264, h265 }

enum EncodePreset { quality, balanced, performance }

extension EncodePresetX on EncodePreset {
  String get label => switch (this) {
        EncodePreset.quality => 'Quality',
        EncodePreset.balanced => 'Balanced',
        EncodePreset.performance => 'Performance',
      };

  String get description => switch (this) {
        EncodePreset.quality => '2960×1848 · 20 Mbps — sharpest',
        EncodePreset.balanced => '2960×1848 · 8 Mbps — native + smooth',
        EncodePreset.performance => '1480×924 · 12 Mbps — high fps (120Hz)',
      };

  // Logical width/height passed to CGVirtualDisplay (Swift doubles if HiDPI).
  int get width => switch (this) {
        EncodePreset.quality => 1480,
        EncodePreset.balanced => 1480,
        EncodePreset.performance => 1480,
      };

  int get height => switch (this) {
        EncodePreset.quality => 924,
        EncodePreset.balanced => 924,
        EncodePreset.performance => 924,
      };

  // Performance uses 1.0x (no HiDPI): encodes 1480×924 instead of 2960×1848
  // — 25% of Quality pixel count so VT can sustain 120fps throughput.
  double get scaleFactor => switch (this) {
        EncodePreset.quality => 2.0,
        EncodePreset.balanced => 2.0,
        EncodePreset.performance => 1.0,
      };

  int get bitrate => switch (this) {
        EncodePreset.quality => 20000000,
        EncodePreset.balanced => 8000000,
        EncodePreset.performance => 12000000,
      };

  // Refresh rate is tied to the preset (no separate frame-rate setting).
  // Performance trades resolution for a high 120Hz capture; the rest run 60Hz.
  int get refreshRate => switch (this) {
        EncodePreset.quality => 60,
        EncodePreset.balanced => 60,
        EncodePreset.performance => 120,
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
