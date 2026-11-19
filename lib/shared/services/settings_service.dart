import 'dart:ui';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';

class SettingsService extends GetxService {
  late SharedPreferences _prefs;

  static const _keyMode = 'display_mode';
  static const _keySessionMode = 'session_mode';
  static const _keyRemoteDirection = 'remote_direction';
  static const _keyLinkType = 'link_type';
  static const _keyWifiHostAddress = 'wifi_host_address';
  static const _keyBitrate = 'bitrate';
  static const _keyLastDevice = 'last_device';
  static const _keyLastDeviceName = 'last_device_name';
  // Native panel of the connected client (physical px, landscape), learned
  // from its HELLO and persisted so presets stay correct across launches.
  static const _keyPanelW = 'client_panel_w';
  static const _keyPanelH = 'client_panel_h';
  static const _keyPanelMaxHz = 'client_panel_max_hz';
  static const _keyPerfOverlay = 'perf_overlay';
  static const _keyHudOverlay = 'hud_overlay';
  static const _keyKeepMacCursor = 'keep_mac_cursor';
  // Where a single tablet's screen-off choice used to live, before it was
  // kept per tablet. Read once, by [_migrateToPerTablet], then removed.
  static const _keyTabletScreenOff = 'tablet_screen_off';
  // Per tablet: `tablet_screen_off.<serial>` and `client_panel.<key>` (the
  // session key: the adb serial over USB).
  static const _keyTabletScreenOffPrefix = 'tablet_screen_off.';
  static const _keyClientPanelPrefix = 'client_panel.';
  static const _keyEncodePreset = 'encode_preset';
  static const _keyCodec = 'codec';
  static const _keyLocale = 'locale';
  // Custom preset values (physical resolution px, bitrate Mbps, refresh Hz).
  static const _keyCustomW = 'custom_width';
  static const _keyCustomH = 'custom_height';
  static const _keyCustomMbps = 'custom_bitrate_mbps';
  static const _keyCustomFps = 'custom_refresh_rate';

  final showPerformanceOverlay = false.obs;
  final showHudOverlay = true.obs;
  // Host only: the tablet's touches borrow the Mac's single cursor and hand it
  // back to where the user left it after each gesture (InputInjectPlugin).
  final keepMacCursor = true.obs;
  // Reactive mirror of the active codec so UI (e.g. the home card) updates live.
  final codecRx = CodecType.h264.obs;
  // Reactive UI language code ('en' / 'th'); drives the language picker.
  final localeCode = 'en'.obs;
  // Active session mode (chosen via the selector on Home). Reactive so UI reflects it
  // live; the host forces Mirror capture while in remote-control mode.
  final sessionModeRx = SessionMode.extendedScreen.obs;
  // Which side drives a remote-control session. Only meaningful when
  // sessionMode == remoteControl.
  final remoteDirectionRx = RemoteDirection.tabControlsMac.obs;
  // USB (adb tunnel) or Wi-Fi (TLS on the LAN). Each device keeps its own:
  // the host how it listens, the client where it dials. Picked on Home.
  final linkTypeRx = LinkType.usb.obs;

  // Native panel of the connected client device (physical px, landscape).
  // Fixed presets derive their capture resolution from these. The fallback is
  // only used until the first client HELLO reports the real panel.
  final clientPanelWidth = 2560.obs;
  final clientPanelHeight = 1600.obs;
  // Top refresh rate the client's panel supports (Hz), also from its HELLO.
  // 60 until a client that reports it has connected.
  final clientMaxRefreshHz = 60.obs;

  // Injected at build time via --dart-define=DEVICE_SERIAL=R52XC02C9RT
  static const _buildSerial =
      String.fromEnvironment('DEVICE_SERIAL', defaultValue: 'R52XC02C9RT');

  /// Loads persisted settings. Called from `main()` before the app builds so
  /// the saved language is available when [GetMaterialApp] reads [locale].
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    showPerformanceOverlay.value = _prefs.getBool(_keyPerfOverlay) ?? false;
    showHudOverlay.value = _prefs.getBool(_keyHudOverlay) ?? true;
    keepMacCursor.value = _prefs.getBool(_keyKeepMacCursor) ?? true;
    codecRx.value = switch (_prefs.getString(_keyCodec)) {
      'h265' => CodecType.h265,
      'h264' => CodecType.h264,
      _ => defaultCodecFor(encodePreset),
    };
    localeCode.value = _resolveInitialLocale();
    clientPanelWidth.value = _prefs.getInt(_keyPanelW) ?? clientPanelWidth.value;
    clientPanelHeight.value =
        _prefs.getInt(_keyPanelH) ?? clientPanelHeight.value;
    clientMaxRefreshHz.value =
        _prefs.getInt(_keyPanelMaxHz) ?? clientMaxRefreshHz.value;
    sessionModeRx.value = _resolveSessionMode();
    remoteDirectionRx.value = _resolveRemoteDirection();
    linkTypeRx.value = _prefs.getString(_keyLinkType) == LinkType.wifi.name
        ? LinkType.wifi
        : LinkType.usb;
    await _migrateToPerTablet();
  }

  /// Once: what used to be kept for the one tablet (its panel, the
  /// screen-off choice) becomes the last-used device's own, and the old
  /// screen-off key goes, so no other tablet inherits it later by becoming
  /// the last-used one. The global panel stays: it is the last panel any
  /// tablet reported.
  Future<void> _migrateToPerTablet() async {
    final last = _prefs.getString(_keyLastDevice);
    final off = _prefs.getBool(_keyTabletScreenOff);
    if (off != null) {
      if (last != null &&
          _prefs.getBool('$_keyTabletScreenOffPrefix$last') == null) {
        await _prefs.setBool('$_keyTabletScreenOffPrefix$last', off);
      }
      await _prefs.remove(_keyTabletScreenOff);
    }
    if (last != null &&
        _prefs.containsKey(_keyPanelW) &&
        _prefs.getString('$_keyClientPanelPrefix$last') == null) {
      await _prefs.setString(
          '$_keyClientPanelPrefix$last', lastClientPanel.encode());
    }
  }

  LinkType get linkType => linkTypeRx.value;

  Future<void> setLinkType(LinkType type) async {
    linkTypeRx.value = type;
    await _prefs.setString(_keyLinkType, type.name);
  }

  /// Client, Wi-Fi: an address typed by the user for the Mac. Empty means
  /// find it by discovery.
  String get wifiHostAddress => _prefs.getString(_keyWifiHostAddress) ?? '';

  Future<void> setWifiHostAddress(String address) =>
      _prefs.setString(_keyWifiHostAddress, normalizeHostAddress(address));

  /// What the user meant by what they typed for the Mac: the address or
  /// name, without spaces and without a `:port` copied along from the Mac's
  /// card (the port is fixed). Anything that can't be an IPv4 address or a
  /// host name becomes '' ("find it"), so a slip does not turn into an
  /// address that is dialled, and fails, for ever.
  static String normalizeHostAddress(String typed) {
    var s = typed.trim();
    final port = RegExp(r'^([^:]+):\d{1,5}$').firstMatch(s);
    if (port != null) s = port.group(1)!;
    return RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$').hasMatch(s)
        ? s
        : '';
  }

  SessionMode _resolveSessionMode() {
    final v = _prefs.getString(_keySessionMode);
    return SessionMode.values.firstWhere(
      (m) => m.name == v,
      orElse: () => SessionMode.extendedScreen,
    );
  }

  SessionMode get sessionMode => sessionModeRx.value;

  Future<void> setSessionMode(SessionMode mode) async {
    sessionModeRx.value = mode;
    await _prefs.setString(_keySessionMode, mode.name);
  }

  RemoteDirection _resolveRemoteDirection() {
    final v = _prefs.getString(_keyRemoteDirection);
    return RemoteDirection.values.firstWhere(
      (d) => d.name == v,
      orElse: () => RemoteDirection.tabControlsMac,
    );
  }

  RemoteDirection get remoteDirection => remoteDirectionRx.value;

  Future<void> setRemoteDirection(RemoteDirection dir) async {
    remoteDirectionRx.value = dir;
    await _prefs.setString(_keyRemoteDirection, dir.name);
  }

  /// The direction a remote-control session actually runs in. Mac-controls-
  /// tablet injects its input with `adb shell input`, which needs the cable,
  /// so over Wi-Fi the saved choice is ignored and the tablet drives the Mac.
  RemoteDirection get effectiveRemoteDirection => linkType == LinkType.wifi
      ? RemoteDirection.tabControlsMac
      : remoteDirection;

  /// True when the active session streams Android → macOS (tablet captures, Mac
  /// views): remote-control mode with the Mac-controls-tablet direction. Every
  /// other mode streams macOS → Android. Never true over Wi-Fi (see
  /// [effectiveRemoteDirection]).
  bool get isReverseRemote =>
      sessionMode == SessionMode.remoteControl &&
      effectiveRemoteDirection.isReverse;

  /// Display mode the host should actually capture in: remote-control always
  /// mirrors the real desktop; extended-screen honours the user's [displayMode].
  DisplayMode get effectiveDisplayMode =>
      sessionMode == SessionMode.remoteControl
          ? DisplayMode.mirror
          : displayMode;

  /// The panel the last HELLO reported, whichever tablet sent it: what the
  /// Settings labels show, and the fallback for a tablet never seen before.
  ClientPanel get lastClientPanel => ClientPanel(clientPanelWidth.value,
      clientPanelHeight.value, clientMaxRefreshHz.value);

  /// The panel the tablet behind session [key] reported last time, if it
  /// ever did (the last-used device from before panels were kept per tablet
  /// has the one it reported then).
  ClientPanel? clientPanelFor(String key) =>
      ClientPanel.decode(_prefs.getString('$_keyClientPanelPrefix$key'));

  /// Host: record [panel] as the one session [key]'s tablet reported (its
  /// HELLO), and as the last one reported.
  Future<void> setClientPanelFor(String key, ClientPanel panel) async {
    await _prefs.setString('$_keyClientPanelPrefix$key', panel.encode());
    await setClientPanel(panel.width, panel.height);
    await setClientMaxRefresh(panel.maxHz);
  }

  /// Host: record the client's native panel (from its HELLO). Landscape is
  /// enforced on the client, so width is always the long side.
  Future<void> setClientPanel(int w, int h) async {
    clientPanelWidth.value = w;
    clientPanelHeight.value = h;
    await _prefs.setInt(_keyPanelW, w);
    await _prefs.setInt(_keyPanelH, h);
  }

  /// Host: record the client panel's top refresh rate (from its HELLO) — the
  /// rate the Max preset starts at.
  Future<void> setClientMaxRefresh(int hz) async {
    clientMaxRefreshHz.value = hz;
    await _prefs.setInt(_keyPanelMaxHz, hz);
  }

  /// Saved language if present, otherwise follow the device language (Thai if
  /// the system is Thai, English for everything else).
  String _resolveInitialLocale() {
    final saved = _prefs.getString(_keyLocale);
    if (saved != null && AppTranslations.supportedLocales.contains(saved)) {
      return saved;
    }
    final device = PlatformDispatcher.instance.locale.languageCode;
    return device == 'th' ? 'th' : 'en';
  }

  /// Resolved [Locale] for [GetMaterialApp]/`Get.updateLocale`.
  Locale get locale => Locale(localeCode.value);

  Future<void> setLocale(String code) async {
    if (!AppTranslations.supportedLocales.contains(code)) return;
    localeCode.value = code;
    Get.updateLocale(Locale(code));
    await _prefs.setString(_keyLocale, code);
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
      orElse: () => EncodePreset.max,
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
  // Custom's width/height are the *physical* encode resolution — that's how the
  // picker labels them and what its help text describes. The desktop itself
  // stays at the panel's logical size (panel ÷ 2, HiDPI) like every fixed
  // preset; only the encode scale changes, so "half" really halves the pixels
  // (it used to be doubled as logical points: 1480×924 encoded at 2960×1848).
  //
  // Each `…For` takes the panel of the tablet a session captures for; the
  // getters without one use the last panel a HELLO reported.
  int get captureWidth => captureWidthFor(lastClientPanel);
  int get captureHeight => captureHeightFor(lastClientPanel);
  double get captureScaleFactor => captureScaleFactorFor(lastClientPanel);
  int get captureBitrate => captureBitrateFor(lastClientPanel);

  /// Effective refresh rate of the active preset (custom-aware).
  int get refreshRate => refreshRateFor(lastClientPanel);

  int captureWidthFor(ClientPanel panel) =>
      isCustomPreset ? panel.width ~/ 2 : encodePreset.widthFor(panel);
  int captureHeightFor(ClientPanel panel) =>
      isCustomPreset ? panel.height ~/ 2 : encodePreset.heightFor(panel);
  double captureScaleFactorFor(ClientPanel panel) => isCustomPreset
      ? customWidth / (panel.width ~/ 2)
      : encodePreset.scaleFactor;
  int captureBitrateFor(ClientPanel panel) => isCustomPreset
      ? customBitrateMbps * 1000000
      : encodePreset.bitrateFor(panel);
  int refreshRateFor(ClientPanel panel) =>
      isCustomPreset ? customRefreshRate : encodePreset.refreshRateFor(panel);

  CodecType get codec => codecRx.value;

  /// Codec used until the user picks one. Max defaults to H.265: at a tablet's
  /// native resolution a Mac's H.264 session saturates far below the panel's
  /// top rate (M3 Pro: ~50 fps at 2960×1848), while HEVC sustains ~2× that.
  static CodecType defaultCodecFor(EncodePreset preset) =>
      preset == EncodePreset.max ? CodecType.h265 : CodecType.h264;

  Future<void> setCodec(CodecType c) {
    codecRx.value = c;
    return _prefs.setString(_keyCodec, c == CodecType.h265 ? 'h265' : 'h264');
  }

  // Returns saved serial, falls back to the compile-time default.
  String? get lastDeviceSerial =>
      _prefs.getString(_keyLastDevice) ?? (_buildSerial.isNotEmpty ? _buildSerial : null);

  Future<void> setLastDevice(String serial) =>
      _prefs.setString(_keyLastDevice, serial);

  /// Model name of the last connected client (from `adb devices -l`), shown in
  /// the settings "Target device" row when nothing is connected.
  String? get lastDeviceName => _prefs.getString(_keyLastDeviceName);

  Future<void> setLastDeviceName(String name) =>
      _prefs.setString(_keyLastDeviceName, name);

  Future<void> setShowPerformanceOverlay(bool v) {
    showPerformanceOverlay.value = v;
    return _prefs.setBool(_keyPerfOverlay, v);
  }

  Future<void> setShowHudOverlay(bool v) {
    showHudOverlay.value = v;
    return _prefs.setBool(_keyHudOverlay, v);
  }

  Future<void> setKeepMacCursor(bool v) {
    keepMacCursor.value = v;
    return _prefs.setBool(_keyKeepMacCursor, v);
  }

  /// Reverse remote: whether the tablet [serial]'s panel was last chosen to
  /// go dark while the Mac views and drives it (the remote view's toggle,
  /// applied again when its next session's picture arrives).
  bool tabletScreenOffFor(String serial) =>
      _prefs.getBool('$_keyTabletScreenOffPrefix$serial') ?? false;

  Future<void> setTabletScreenOffFor(String serial, bool v) =>
      _prefs.setBool('$_keyTabletScreenOffPrefix$serial', v);
}
