import 'package:extendedscreen/shared/models/display_config_model.dart';

/// What one device (a USB tablet by its adb serial, a Wi-Fi device by its
/// install id) runs with when it differs from the app-wide settings. Every
/// field left null takes the app-wide value, so an empty profile is
/// exactly today's behaviour. Kept as `device_profile.<key>` (JSON).
class DeviceProfile {
  const DeviceProfile({
    this.preset,
    this.codec,
    this.displayMode,
    this.divisor,
    this.maxFps,
  });

  final EncodePreset? preset;
  final CodecType? codec;
  final DisplayMode? displayMode;

  /// How many physical pixels make one point of the Mac's desktop on this
  /// device: 2 (the default, sharp HiDPI), 2.5 or 3 (larger text, a smaller
  /// desktop and less to encode).
  final double? divisor;

  /// The highest frame rate this device is streamed at, whatever its preset
  /// and panel allow (null: no cap of its own).
  final int? maxFps;

  static const divisors = [2.0, 2.5, 3.0];
  static const fpsCaps = [60, 90, 120];

  bool get isEmpty =>
      preset == null &&
      codec == null &&
      displayMode == null &&
      divisor == null &&
      maxFps == null;

  DeviceProfile copyWith({
    EncodePreset? Function()? preset,
    CodecType? Function()? codec,
    DisplayMode? Function()? displayMode,
    double? Function()? divisor,
    int? Function()? maxFps,
  }) =>
      DeviceProfile(
        preset: preset != null ? preset() : this.preset,
        codec: codec != null ? codec() : this.codec,
        displayMode: displayMode != null ? displayMode() : this.displayMode,
        divisor: divisor != null ? divisor() : this.divisor,
        maxFps: maxFps != null ? maxFps() : this.maxFps,
      );

  Map<String, Object> toJson() => {
        if (preset != null) 'preset': preset!.name,
        if (codec != null) 'codec': codec!.name,
        if (displayMode != null) 'displayMode': displayMode!.name,
        'divisor': ?divisor,
        'maxFps': ?maxFps,
      };

  /// Reads what it can: a value this build does not know is no value.
  factory DeviceProfile.fromJson(Map<String, dynamic> json) {
    T? named<T extends Enum>(List<T> values, Object? name) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return null;
    }

    final d = json['divisor'];
    final f = json['maxFps'];
    final divisor = d is num ? d.toDouble() : null;
    final maxFps = f is int ? f : (f is double && f == f.roundToDouble() ? f.toInt() : null);
    return DeviceProfile(
      preset: named(EncodePreset.values, json['preset']),
      codec: named(CodecType.values, json['codec']),
      displayMode: named(DisplayMode.values, json['displayMode']),
      divisor: divisors.contains(divisor) ? divisor : null,
      maxFps: fpsCaps.contains(maxFps) ? maxFps : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile &&
      other.preset == preset &&
      other.codec == codec &&
      other.displayMode == displayMode &&
      other.divisor == divisor &&
      other.maxFps == maxFps;

  @override
  int get hashCode => Object.hash(preset, codec, displayMode, divisor, maxFps);
}
