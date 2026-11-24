import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/device_profile.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/known_device.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/session_spec.dart';
import 'package:extendedscreen/shared/platform/windows_app.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

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
  // Every tablet the host has had a live USB session with (a JSON list of
  // [KnownDevice]). Its presence also marks [_migrateToPerTablet]'s
  // known-devices step as done.
  static const _keyKnownDevices = 'known_devices';
  // The configured cap on tablets at once (host).
  static const _keyMaxTablets = 'max_tablets';
  static const _keyWifiListen = 'wifi_listen';
  static const _keyInstallId = 'install_id';
  static const _keyWifiListenMode = 'wifi_listen_mode';
  static const _keyWifiListenDirection = 'wifi_listen_direction';
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
  // Host: what this Mac's encoder was seen to manage, per chip and codec
  // (`encoder_capacity.apple-m3-pro.h265`), in Mpx/s.
  static const _keyEncoderCapacityPrefix = 'encoder_capacity.';
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
  // The role a new device gets by default (the last one picked in Home's
  // role chooser), with [remoteDirectionRx]. Reactive so UI reflects it
  // live; the host forces Mirror capture while in remote-control mode.
  final sessionModeRx = SessionMode.extendedScreen.obs;
  // Which side drives a remote-control session. Only meaningful when
  // sessionMode == remoteControl.
  final remoteDirectionRx = RemoteDirection.tabControlsMac.obs;
  // USB (adb tunnel) or Wi-Fi (TLS on the LAN). Each device keeps its own:
  // the host how it listens, the client where it dials. Picked on Home.
  final linkTypeRx = LinkType.usb.obs;
  // Host: how many tablets may be connected at once, on top of what the
  // encoder allows (EncodeBudget). 1 to 8.
  final maxTabletsRx = defaultMaxTablets.obs;

  // Host: while the link is USB, the Mac also listens on Wi-Fi for one
  // paired device (an iPhone, say) beside the USB tablets. Saved with no
  // reconnect; the hub starts or ends that one session itself.
  final wifiListenRx = false.obs;

  static const defaultMaxTablets = 4;
  static const maxTabletsLimit = 8;

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
    // The iOS and Windows clients have no adb, so no USB link: Wi-Fi always,
    // whatever was saved, and every reader (the Rx included) sees it.
    linkTypeRx.value =
        wifiOnlyClient || _prefs.getString(_keyLinkType) == LinkType.wifi.name
        ? LinkType.wifi
        : LinkType.usb;
    maxTabletsRx.value = (_prefs.getInt(_keyMaxTablets) ?? defaultMaxTablets)
        .clamp(1, maxTabletsLimit);
    wifiListenRx.value = _prefs.getBool(_keyWifiListen) ?? false;
    await _migrateToPerTablet();
  }

  /// Once: what used to be kept for the one tablet (its panel, the
  /// screen-off choice) becomes the last-used device's own, and the old
  /// screen-off key goes, so no other tablet inherits it later by becoming
  /// the last-used one. The global panel stays: it is the last panel any
  /// tablet reported. The last-used device also becomes the first known
  /// device, with virtual-display serial 1, the one every virtual display had
  /// before, so macOS keeps its place on the desktop. That reads the saved
  /// serial itself, never [lastDeviceSerial], which falls back to the
  /// build's DEVICE_SERIAL: a tablet that was never used must not take 1.
  Future<void> _migrateToPerTablet() async {
    final last = _prefs.getString(_keyLastDevice);
    if (last != null && !_prefs.containsKey(_keyKnownDevices)) {
      await _saveKnownDevices([
        KnownDevice(serial: last, model: lastDeviceName, vdSerial: 1),
      ]);
    }
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

  /// Does nothing on iOS and Windows, where the link is always Wi-Fi.
  Future<void> setLinkType(LinkType type) async {
    if (wifiOnlyClient) return;
    linkTypeRx.value = type;
    await _prefs.setString(_keyLinkType, type.name);
  }

  /// Host, once per launch: a Mac saved on the Wi-Fi link from before the
  /// Listen switch moves to USB with the switch on, which is what that
  /// setting means now. Both observables change before the first await.
  Future<void> migrateHostLinkToListen() async {
    if (linkType != LinkType.wifi) return;
    wifiListenRx.value = true;
    linkTypeRx.value = LinkType.usb;
    await _prefs.setBool(_keyWifiListen, true);
    await _prefs.setString(_keyLinkType, LinkType.usb.name);
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

  /// Host: the role a new device gets when nothing else says: the last one
  /// picked in Home's role chooser (the saved session mode and remote
  /// direction; the direction is kept for Extended screen too). Also the
  /// auto-connect's fallback for a tablet the Mac has not had before, and
  /// the Wi-Fi listener's after [wifiListenChoice]. A session's link still
  /// has its say ([SessionChoice.effective]).
  SessionChoice get nextChoice => SessionChoice(sessionMode, remoteDirection);

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
  /// HELLO), and, when [global], as the last one reported
  /// ([lastClientPanel], the guess for a tablet that has reported none).
  /// Only an Android HELLO is [global]: an iPhone's (or an iPad's) area
  /// would be a poor guess for a new tablet. Nothing for a synthetic tablet.
  Future<void> setClientPanelFor(String key, ClientPanel panel,
      {bool global = true}) async {
    if (isSyntheticKey(key)) return;
    // A Wi-Fi device that did not say who it is has a new key on every
    // connection: nothing kept under it would be found again.
    if (!key.startsWith('wifi:conn')) {
      await _prefs.setString('$_keyClientPanelPrefix$key', panel.encode());
    }
    if (!global) return;
    await setClientPanel(panel.width, panel.height);
    await setClientMaxRefresh(panel.maxHz);
  }

  /// The preference key of what was learned of the encoder's capacity on
  /// [chip] (its brand string, "Apple M3 Pro") with [codec]: lower case,
  /// every run of anything but a letter or digit one dash
  /// (`encoder_capacity.apple-m3-pro.h265`). Null for an unknown chip.
  static String? encoderCapacityKey(String chip, CodecType codec) {
    final slug = chip
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) return null;
    return '$_keyEncoderCapacityPrefix$slug.${codec.name}';
  }

  /// Host: what an earlier run learned this Mac's encoder manages with
  /// [codec] on [chip], in Mpx/s (EncodeBudget's learned capacity); null for
  /// nothing, or for a value that can't be one.
  double? encoderCapacityFor(String chip, CodecType codec) {
    final key = encoderCapacityKey(chip, codec);
    if (key == null) return null;
    final v = _prefs.getDouble(key);
    if (v == null || !v.isFinite || v <= 0 || v > maxEncoderCapacity) {
      return null;
    }
    return v;
  }

  /// Host: saves what was learned of the encoder's capacity on [chip] with
  /// [codec] ([mpx], Mpx/s), or forgets it (null). Nothing for an unknown
  /// chip.
  Future<void> setEncoderCapacityFor(
      String chip, CodecType codec, double? mpx) async {
    final key = encoderCapacityKey(chip, codec);
    if (key == null) return;
    if (mpx == null || !mpx.isFinite || mpx <= 0) {
      await _prefs.remove(key);
    } else {
      await _prefs.setDouble(key, math.min(mpx, maxEncoderCapacity));
    }
  }

  /// More than any media engine manages, in Mpx/s: a saved value past it is
  /// not taken.
  static const maxEncoderCapacity = 100000.0;

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

  /// What a session capturing for a tablet with [panel] encodes under the
  /// current preset and codec, in [spec]'s display mode.
  DisplayConfigModel captureConfigFor(ClientPanel panel, SessionSpec spec,
          {DeviceProfile profile = const DeviceProfile()}) =>
      (profile.preset ?? encodePreset).configFor(
        panel,
        custom: CustomPreset(
          width: customWidth,
          bitrateMbps: customBitrateMbps,
          refreshRate: customRefreshRate,
        ),
        mode: spec.displayMode,
        codec: profile.codec ?? codec,
        divisor: profile.divisor ?? 2,
        fpsCap: profile.maxFps,
      );

  // ─── Per-device profiles ─────────────────────────────────────────────────

  static const _keyDeviceProfilePrefix = 'device_profile.';

  /// What device [key] runs with where it differs from the app-wide
  /// settings (empty when nothing was set for it, or for a key that is no
  /// device of its own: a synthetic tablet, an anonymous Wi-Fi one).
  DeviceProfile deviceProfile(String key) {
    if (!hasOwnProfile(key)) return const DeviceProfile();
    final raw = _prefs.getString('$_keyDeviceProfilePrefix$key');
    if (raw == null) return const DeviceProfile();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return DeviceProfile.fromJson(json);
    } catch (_) {
      // Anything unreadable is no profile: it must never stop a capture or
      // Home from drawing.
    }
    return const DeviceProfile();
  }

  /// Saves device [key]'s profile (an empty one removes it). The cache is
  /// updated inside the call, so [deviceProfile] reads it at once.
  Future<void> setDeviceProfile(String key, DeviceProfile profile) async {
    if (!hasOwnProfile(key)) return;
    final write = profile.isEmpty
        ? _prefs.remove('$_keyDeviceProfilePrefix$key')
        : _prefs.setString(
            '$_keyDeviceProfilePrefix$key', jsonEncode(profile.toJson()));
    deviceProfiles.value++;
    await write;
  }

  /// Bumped by every [setDeviceProfile], for the UI to follow.
  final deviceProfiles = 0.obs;

  /// Whether [key] can keep a profile: a real device that is the same one
  /// next time (not a synthetic tablet, not a Wi-Fi device without an
  /// install id, which is a new key on every connection).
  static bool hasOwnProfile(String key) =>
      !isSyntheticKey(key) && !key.startsWith('wifi:conn');

  /// The codec device [key] runs: its own, else the app-wide one.
  CodecType codecFor(String key) => deviceProfile(key).codec ?? codec;

  /// The preset device [key] runs: its own, else the app-wide one.
  EncodePreset presetFor(String key) =>
      deviceProfile(key).preset ?? encodePreset;

  /// The display mode device [key] runs (Extend or Mirror; remote control
  /// mirrors whatever this says): its own, else the app-wide one.
  DisplayMode displayModeFor(String key) =>
      deviceProfile(key).displayMode ?? displayMode;

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

  Future<void> setLastDevice(String serial) async {
    if (isSyntheticKey(serial)) return;
    await _prefs.setString(_keyLastDevice, serial);
  }

  /// Model name of the last connected client (from `adb devices -l`), shown in
  /// the settings "Target device" row when nothing is connected.
  String? get lastDeviceName => _prefs.getString(_keyLastDeviceName);

  /// It takes a model name, not a serial, so it can't tell a synthetic
  /// tablet's: [rememberDevice] checks the serial before writing either.
  Future<void> setLastDeviceName(String name) =>
      _prefs.setString(_keyLastDeviceName, name);

  /// A session key (or serial) of an in-process stand-in tablet (debug builds
  /// and tests). Nothing is ever saved for one: its panel, its screen-off
  /// choice, the last-used device and the known devices stay as they were.
  static bool isSyntheticKey(String key) =>
      key.startsWith(syntheticSerialPrefix);

  // ─── Known devices (host) ─────────────────────────────────────────────────

  /// Every tablet the host has had a live USB session with. A list that
  /// can't be read is no list.
  List<KnownDevice> get knownDevices {
    final text = _prefs.getString(_keyKnownDevices);
    if (text == null) return const [];
    try {
      final list = jsonDecode(text);
      if (list is! List) return const [];
      return list.map(KnownDevice.fromJson).whereType<KnownDevice>().toList();
    } on FormatException {
      return const [];
    }
  }

  KnownDevice? knownDevice(String serial) {
    for (final d in knownDevices) {
      if (d.serial == serial) return d;
    }
    return null;
  }

  /// [SharedPreferences] puts a value in its cache before the call returns
  /// and writes it out in the background, so [knownDevices] reads the new
  /// list at once, whether or not the write is awaited.
  Future<void> _saveKnownDevices(List<KnownDevice> devices) =>
      _prefs.setString(_keyKnownDevices,
          jsonEncode(devices.map((d) => d.toJson()).toList()));

  /// The mode known tablet [serial] is remembered in, if any (see
  /// [KnownDevice.choice]).
  SessionChoice? knownChoice(String serial) => knownDevice(serial)?.choice;

  /// Host: known tablet [serial] is now to run as [choice]. [knownChoice]
  /// reads it as soon as this returns; the write to disk follows by itself,
  /// and a failure there is only logged. Nothing for a tablet that is not
  /// known yet ([rememberDevice] adds it once its session is live) or for a
  /// synthetic one.
  void setKnownChoice(String serial, SessionChoice choice) {
    if (isSyntheticKey(serial)) return;
    final devices = knownDevices.toList();
    final i = devices.indexWhere((d) => d.serial == serial);
    if (i < 0) return;
    devices[i] = devices[i].copyWith(choice: choice);
    // then's onError, not catchError: the future underneath completes with
    // a bool, which a catchError handler would have to return.
    unawaited(_saveKnownDevices(devices).then<void>((_) {},
        onError: (Object e, StackTrace st) {
      const message = 'known_devices: could not save a tablet\'s mode';
      if (Get.isRegistered<LoggerService>()) {
        Get.find<LoggerService>().e(message, e, st);
      } else {
        debugPrint('$message: $e');
      }
    }));
  }

  /// FNV-1a, 32 bits, over [text]'s UTF-8 bytes: a stable number per serial.
  static int fnv1a32(String text) {
    var hash = 0x811C9DC5;
    for (final byte in utf8.encode(text)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// The serial number tablet [key]'s virtual display is created with: the
  /// one it was given before (see [rememberDevice]), else one worked out from
  /// its serial, at least 0x10000 so it never meets the 1 the migrated
  /// tablet keeps, and stepped past any in [taken] (displays live right now)
  /// and any another known tablet has. Saves nothing.
  int vdSerialFor(String key, {Set<int> taken = const {}}) {
    final known = knownDevices;
    for (final d in known) {
      if (d.serial == key) return d.vdSerial;
    }
    final stored = {for (final d in known) d.vdSerial};
    var v = fnv1a32(key) | 0x10000;
    while (v == 1 || taken.contains(v) || stored.contains(v)) {
      v = ((v + 1) & 0xFFFFFFFF) | 0x10000;
    }
    return v;
  }

  /// The name tablet [key]'s virtual display shows in System Settings. The
  /// migrated tablet (serial 1) keeps the one every display had before;
  /// another names its model ([model] when none is saved yet), as adb
  /// reports it with spaces for underscores.
  String vdNameFor(String key, {String? model}) {
    const base = 'Extended Screen';
    final known = knownDevice(key);
    if (known?.vdSerial == 1) return base;
    final name = (known?.model ?? model)?.replaceAll('_', ' ').trim();
    return name == null || name.isEmpty ? base : '$base – $name';
  }

  /// Host: tablet [serial] has a live session. Adds it to [knownDevices] with
  /// [vdSerial] (one it already has, and its install id, are kept), and makes
  /// it the last-used device, which Settings' "Target device" row and the
  /// first-run auto-connect read. [choice], when given, becomes the mode it
  /// is remembered in; without one a stored mode stays. Nothing for a
  /// synthetic tablet.
  Future<void> rememberDevice(String serial,
      {String? model,
      required int vdSerial,
      SessionChoice? choice,
      bool lastDevice = true}) async {
    if (isSyntheticKey(serial)) return;
    final hasModel = model != null && model.isNotEmpty;
    final devices = knownDevices.toList();
    final i = devices.indexWhere((d) => d.serial == serial);
    if (i < 0) {
      devices.add(KnownDevice(
          serial: serial,
          model: hasModel ? model : null,
          vdSerial: vdSerial,
          choice: choice));
    } else {
      devices[i] = devices[i]
          .copyWith(model: hasModel ? model : null, choice: choice);
    }
    await _saveKnownDevices(devices);
    if (!lastDevice) return;
    await setLastDevice(serial);
    if (hasModel) await setLastDeviceName(model);
  }

  /// Host: the configured cap on tablets at once.
  int get maxTablets => maxTabletsRx.value;

  Future<void> setMaxTablets(int n) async {
    final v = n.clamp(1, maxTabletsLimit);
    maxTabletsRx.value = v;
    await _prefs.setInt(_keyMaxTablets, v);
  }

  /// Client: this install's id, 16 random bytes made the first time it is
  /// asked for and kept from then on, sent in HELLO's identity tail
  /// (`HelloTail`) so a Mac knows this device again on Wi-Fi. Not a secret:
  /// it identifies, the pairing token is what proves.
  Uint8List get installId {
    final saved = _prefs.getString(_keyInstallId);
    if (saved != null) {
      try {
        final bytes = base64Decode(saved);
        if (bytes.length == 16) return bytes;
      } on FormatException {
        // Made again below.
      }
    }
    final random = math.Random.secure();
    final made = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)));
    unawaited(_prefs.setString(_keyInstallId, base64Encode(made)));
    return made;
  }

  /// Host: whether the Mac listens on Wi-Fi beside the USB tablets
  /// ([wifiListenRx]).
  bool get wifiListen => wifiListenRx.value;

  Future<void> setWifiListen(bool v) async {
    wifiListenRx.value = v;
    await _prefs.setBool(_keyWifiListen, v);
  }

  /// Host: the mode the device that joins over Wi-Fi beside the USB tablets
  /// was last asked to run in (its card's role chips); null until then,
  /// when it takes [nextChoice]. Kept apart from
  /// [knownChoice], which is for tablets known by their adb serial.
  SessionChoice? get wifiListenChoice => SessionChoice.fromNames(
    _prefs.getString(_keyWifiListenMode),
    _prefs.getString(_keyWifiListenDirection),
  );

  /// Saves [wifiListenChoice]. Not async, like [setKnownChoice]: the cache
  /// is updated inside the call, so a session made right after reads it.
  void setWifiListenChoice(SessionChoice choice) {
    // Both calls before any await: each puts its value in the cache at once.
    final writes = [
      _prefs.setString(_keyWifiListenMode, choice.mode.name),
      _prefs.setString(_keyWifiListenDirection, choice.direction.name),
    ];
    unawaited(
      Future.wait(writes).then<void>(
        (_) {},
        onError: (Object e) {
          if (Get.isRegistered<LoggerService>()) {
            Get.find<LoggerService>().w(
              'Settings: the Wi-Fi device\'s mode not saved: $e',
            );
          }
        },
      ),
    );
  }

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

  Future<void> setTabletScreenOffFor(String serial, bool v) async {
    if (isSyntheticKey(serial)) return;
    await _prefs.setBool('$_keyTabletScreenOffPrefix$serial', v);
  }
}
