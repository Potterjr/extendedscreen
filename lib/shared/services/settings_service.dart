import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';

class SettingsService extends GetxService {
  late SharedPreferences _prefs;

  static const _keyMode = 'display_mode';
  static const _keyBitrate = 'bitrate';
  static const _keyLastDevice = 'last_device';
  static const _keyPerfOverlay = 'perf_overlay';
  static const _keyHudOverlay = 'hud_overlay';
  static const _keyEncodePreset = 'encode_preset';
  static const _keyCodec = 'codec';

  final showPerformanceOverlay = false.obs;
  final showHudOverlay = true.obs;

  // Injected at build time via --dart-define=DEVICE_SERIAL=R52XC02C9RT
  static const _buildSerial =
      String.fromEnvironment('DEVICE_SERIAL', defaultValue: 'R52XC02C9RT');

  @override
  Future<void> onInit() async {
    super.onInit();
    _prefs = await SharedPreferences.getInstance();
    showPerformanceOverlay.value = _prefs.getBool(_keyPerfOverlay) ?? false;
    showHudOverlay.value = _prefs.getBool(_keyHudOverlay) ?? true;
  }

  DisplayMode get displayMode {
    final v = _prefs.getString(_keyMode);
    return v == 'mirror' ? DisplayMode.mirror : DisplayMode.extend;
  }

  Future<void> setDisplayMode(DisplayMode mode) =>
      _prefs.setString(_keyMode, mode.name);

  int get bitrate => _prefs.getInt(_keyBitrate) ?? 15000000; // 15 Mbps
  Future<void> setBitrate(int bps) => _prefs.setInt(_keyBitrate, bps);

  EncodePreset get encodePreset {
    final v = _prefs.getString(_keyEncodePreset);
    return EncodePreset.values.firstWhere(
      (e) => e.name == v,
      orElse: () => EncodePreset.balanced,
    );
  }

  Future<void> setEncodePreset(EncodePreset preset) =>
      _prefs.setString(_keyEncodePreset, preset.name);

  /// Refresh rate is derived from the active encode preset (no standalone setting).
  int get refreshRate => encodePreset.refreshRate;

  CodecType get codec {
    final v = _prefs.getString(_keyCodec);
    return v == 'h265' ? CodecType.h265 : CodecType.h264;
  }
  Future<void> setCodec(CodecType c) => _prefs.setString(_keyCodec, c == CodecType.h265 ? 'h265' : 'h264');

  // Returns saved serial, falls back to compile-time default (Tab S10 Ultra).
  String? get lastDeviceSerial =>
      _prefs.getString(_keyLastDevice) ?? (_buildSerial.isNotEmpty ? _buildSerial : null);

  Future<void> setLastDevice(String serial) =>
      _prefs.setString(_keyLastDevice, serial);

  Future<void> setShowPerformanceOverlay(bool v) {
    showPerformanceOverlay.value = v;
    return _prefs.setBool(_keyPerfOverlay, v);
  }

  Future<void> setShowHudOverlay(bool v) {
    showHudOverlay.value = v;
    return _prefs.setBool(_keyHudOverlay, v);
  }
}
