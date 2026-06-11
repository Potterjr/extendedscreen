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
  // Custom preset values (physical resolution px, bitrate Mbps, refresh Hz).
  static const _keyCustomW = 'custom_width';
  static const _keyCustomH = 'custom_height';
  static const _keyCustomMbps = 'custom_bitrate_mbps';
  static const _keyCustomFps = 'custom_refresh_rate';

  final showPerformanceOverlay = false.obs;
  final showHudOverlay = true.obs;
  // Reactive mirror of the active codec so UI (e.g. the home card) updates live.
  final codecRx = CodecType.h264.obs;

  // Injected at build time via --dart-define=DEVICE_SERIAL=R52XC02C9RT
  static const _buildSerial =
      String.fromEnvironment('DEVICE_SERIAL', defaultValue: 'R52XC02C9RT');

  @override
  Future<void> onInit() async {
    super.onInit();
    _prefs = await SharedPreferences.getInstance();
    showPerformanceOverlay.value = _prefs.getBool(_keyPerfOverlay) ?? false;
    showHudOverlay.value = _prefs.getBool(_keyHudOverlay) ?? true;
    codecRx.value =
        _prefs.getString(_keyCodec) == 'h265' ? CodecType.h265 : CodecType.h264;
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

  // ─── Custom preset values (physical resolution, Mbps, Hz) ─────────────────
  int get customWidth => _prefs.getInt(_keyCustomW) ?? 1920;
  int get customHeight => _prefs.getInt(_keyCustomH) ?? 1200;
  int get customBitrateMbps => _prefs.getInt(_keyCustomMbps) ?? 12;
  int get customRefreshRate => _prefs.getInt(_keyCustomFps) ?? 60;

  Future<void> setCustomResolution(int w, int h) async {
    await _prefs.setInt(_keyCustomW, w);
    await _prefs.setInt(_keyCustomH, h);
  }

  Future<void> setCustomBitrateMbps(int mbps) =>
      _prefs.setInt(_keyCustomMbps, mbps);
  Future<void> setCustomRefreshRate(int hz) =>
      _prefs.setInt(_keyCustomFps, hz);

  bool get isCustomPreset => encodePreset == EncodePreset.custom;

  // ─── Effective capture values (resolve custom vs fixed preset) ────────────
  // Custom encodes at the chosen physical resolution with no HiDPI scaling.
  int get captureWidth =>
      isCustomPreset ? customWidth : encodePreset.width;
  int get captureHeight =>
      isCustomPreset ? customHeight : encodePreset.height;
  double get captureScaleFactor =>
      isCustomPreset ? 1.0 : encodePreset.scaleFactor;
  int get captureBitrate =>
      isCustomPreset ? customBitrateMbps * 1000000 : encodePreset.bitrate;

  /// Effective refresh rate of the active preset (custom-aware).
  int get refreshRate =>
      isCustomPreset ? customRefreshRate : encodePreset.refreshRate;

  CodecType get codec => codecRx.value;

  Future<void> setCodec(CodecType c) {
    codecRx.value = c;
    return _prefs.setString(_keyCodec, c == CodecType.h265 ? 'h265' : 'h264');
  }

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
