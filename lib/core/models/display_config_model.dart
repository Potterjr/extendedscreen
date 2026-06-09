enum DisplayMode { extend, mirror }

enum CodecType { h264, h265 }

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
        'codec': codec.index,
        'bitrate': bitrate,
      };
}
