import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/display_config_model.dart';

class SettingsService extends GetxService {
  late SharedPreferences _prefs;

  static const _keyMode = 'display_mode';
  static const _keyBitrate = 'bitrate';
  static const _keyFps = 'fps';
  static const _keyLastDevice = 'last_device';
  static const _keyPerfOverlay = 'perf_overlay';
  static const _keyHudOverlay = 'hud_overlay';

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

  int get fps => _prefs.getInt(_keyFps) ?? 60;
  Future<void> setFps(int fps) => _prefs.setInt(_keyFps, fps);

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
