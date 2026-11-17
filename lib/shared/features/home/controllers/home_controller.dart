import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/platform/battery_channel.dart';
import 'package:extendedscreen/shared/platform/permissions_channel.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  final _connection = Get.find<BaseConnectionManager>();
  final _settings = Get.find<SettingsService>();
  final _perms = PermissionsChannel();

  /// Client only — [BatteryChannel] is registered just on Android, so this
  /// must only be read behind an `!isHost` guard.
  Rxn<BatteryStatus> get batteryStatus => Get.find<BatteryChannel>().status;

  /// Host: permission keys still missing, checked on load and on app resume
  /// (so returning from System Settings clears it automatically). Drives the
  /// inline banner on Home instead of a forced trip to the Settings screen.
  final missingPermissions = <String>[].obs;

  /// Host: which session to run this connection as. Exposed here (instead of a
  /// dedicated launcher screen) so switching modes is a single tap on Home.
  Rx<SessionMode> get sessionMode => _settings.sessionModeRx;
  void onSelectSessionMode(SessionMode mode) => _settings.setSessionMode(mode);

  ConnectionPhase get phase => _connection.phase.value;
  DeviceModel? get device => _connection.activeDevice.value;

  // Reverse remote (Mac controls this tablet): screen-share button state.
  RxBool get needsScreenShare => _connection.needsScreenShare;
  RxBool get isScreenSharing => _connection.isScreenSharing;
  void onStartScreenShare() => _connection.startScreenShare();
  int get latencyMs => _connection.latencyMs.value;
  String get errorMessage => _connection.errorMessage.value;

  bool get isHost => _connection.isHost;

  /// Host: a manual device-list refresh (the picker's refresh button) is
  /// running. Lets the picker show it is working: when the list comes back
  /// unchanged, nothing else on screen would move.
  final refreshingDevices = false.obs;

  /// Remote-control direction picker (host, while idle in remote-control mode).
  bool get isRemoteControl =>
      _settings.sessionModeRx.value == SessionMode.remoteControl;
  Rx<RemoteDirection> get remoteDirection => _settings.remoteDirectionRx;
  void onSelectDirection(RemoteDirection dir) =>
      _settings.setRemoteDirection(dir);

  /// Host, reverse remote (Mac controls tablet): true once the tablet stream is
  /// live. Reads the session-mode/direction observables so it is reactive.
  bool get isReverseRemote => _settings.isReverseRemote;

  // ─── Link type (USB / Wi-Fi) ──────────────────────────────────────────────

  /// Which link this device uses. Each side picks its own: the host how it
  /// listens, the client where it dials.
  Rx<LinkType> get linkType => _settings.linkTypeRx;
  bool get isWifi => _settings.linkTypeRx.value == LinkType.wifi;

  /// The direction a remote-control session will run in (Wi-Fi allows only
  /// tablet-controls-Mac). Reactive.
  RemoteDirection get effectiveDirection => _settings.effectiveRemoteDirection;

  Future<void> onSelectLinkType(LinkType type) async {
    if (_settings.linkType == type) return;
    await _settings.setLinkType(type);
    if (isHost) {
      // The host's selector only shows while idle: the next connect reads it.
      _loadLocalAddresses();
    } else {
      await _redialClient();
    }
  }

  /// Host, Wi-Fi: this Mac's LAN addresses, shown so the user can check the
  /// network or type one on the tablet if discovery finds nothing.
  final localAddresses = <String>[].obs;

  Future<void> _loadLocalAddresses() async {
    localAddresses.value = [
      for (final a in await WifiDiscoveryService.lanAddresses()) a.address,
    ];
  }

  /// Client, Wi-Fi: the Macs this tablet was paired with over USB. Empty when
  /// the pairing service isn't registered (widget tests).
  List<PairedHost> get pairedHosts => Get.isRegistered<WifiPairingService>()
      ? Get.find<WifiPairingService>().pairedHosts.toList()
      : const [];

  /// Client: unpair a Mac (the card asked for confirmation first). A dial in
  /// progress may be heading for that very Mac, so it starts over, unless the
  /// user had stopped it.
  Future<void> onForgetHost(String id) async {
    if (!Get.isRegistered<WifiPairingService>()) return;
    if (!await Get.find<WifiPairingService>().forget(id)) return;
    if (isWifi) await _redialClient();
  }

  /// Client, Wi-Fi: an address typed for the Mac ('' = find it).
  String get wifiHostAddress => _settings.wifiHostAddress;

  /// The field was submitted: save the address and dial it now.
  Future<void> onSetWifiHostAddress(String address) async {
    if (SettingsService.normalizeHostAddress(address) ==
        _settings.wifiHostAddress) {
      return;
    }
    await _settings.setWifiHostAddress(address);
    await _redialClient();
  }

  /// The field lost focus to a touch elsewhere: only save. That touch is
  /// still on its way to whatever it landed on (the pointer is down, not yet
  /// up), and a redial started now would flip the phase under it: a tap on
  /// Connect would arrive as Cancel. The next dial reads the new address.
  Future<void> onSaveWifiHostAddress(String address) =>
      _settings.setWifiHostAddress(address);

  /// The client is always dialling or waiting to: after a change to where it
  /// should dial, start over now rather than when the pending retry fires.
  /// Left alone when the user stopped it.
  Future<void> _redialClient() async {
    if (_connection.phase.value == ConnectionPhase.disconnected) return;
    await _connection.disconnect();
    await _connection.connect();
  }

  /// Host: (re)open the remote view — used to get back in after backing out of
  /// it while a reverse-remote session is still live.
  void onOpenRemoteView() => Get.toNamed(AppRoutes.remoteHost);

  /// Navigation workers registered in [onInit], disposed in [onClose].
  final _workers = <Worker>[];

  @override
  void onInit() {
    super.onInit();
    // Populate the device picker as soon as the host screen opens.
    _connection.refreshDevices();

    if (isHost) {
      // Recheck permissions on resume — covers returning from System Settings
      // after granting Screen Recording / Accessibility from the inline banner.
      WidgetsBinding.instance.addObserver(this);
      _checkHostPermissions();
      _loadLocalAddresses();
    }

    // Client (Android): auto-open the display once the link is live. The home
    // screen still shows the steps + Open View button (for when the user backs
    // out and wants to re-open). The host stays on this screen as the source.
    //
    // Exception: in reverse-remote (Mac controls the tablet) there is no
    // incoming video to show — the tablet is the capture source — so it stays
    // on home, and if the mode is learned (via 0xF9) after the view opened, we
    // pop back.
    if (!_connection.isHost) {
      _workers.add(ever<ConnectionPhase>(_connection.phase, (p) {
        if (p.isActive &&
            !_settings.isReverseRemote &&
            Get.currentRoute == AppRoutes.home) {
          Get.toNamed(AppRoutes.display);
        }
      }));
      _workers.add(
          everAll([_settings.sessionModeRx, _settings.remoteDirectionRx], (_) {
        if (_settings.isReverseRemote && Get.currentRoute == AppRoutes.display) {
          Get.back();
        }
      }));
      // Already streaming when home opens (resumed onto home while live) —
      // `ever` won't fire without a change, so jump after the first frame.
      if (_connection.phase.value.isActive && !_settings.isReverseRemote) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (Get.currentRoute == AppRoutes.home) {
            Get.toNamed(AppRoutes.display);
          }
        });
      }
    } else {
      // Host: in reverse remote (Mac controls tablet) the Mac is the viewer —
      // open the remote view once the tablet stream is live.
      void openRemote(ConnectionPhase p) {
        if (p.isActive &&
            _settings.isReverseRemote &&
            Get.currentRoute == AppRoutes.home) {
          Get.toNamed(AppRoutes.remoteHost);
        }
      }

      _workers.add(ever<ConnectionPhase>(_connection.phase, openRemote));
      // Already live when Home opens: the launch connected by itself
      // (HostConnectionManager.autoConnect), before the splash moved on or
      // while the window was hidden, and `ever` only sees changes.
      if (_connection.phase.value.isActive) {
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => openRemote(_connection.phase.value));
      }
    }
  }

  @override
  void onClose() {
    if (isHost) WidgetsBinding.instance.removeObserver(this);
    // The phase/mode observables belong to permanent services and outlive this
    // controller; dispose the workers so a closed Home stops reacting to them.
    for (final worker in _workers) {
      worker.dispose();
    }
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkHostPermissions();
      _loadLocalAddresses(); // the Mac may have changed network meanwhile
    }
  }

  Future<void> _checkHostPermissions() async {
    final status = await _perms.checkPermissions();
    missingPermissions.value = PermissionsChannel.hostRequired
        .where((key) => !(status[key] ?? false))
        .toList();
    if (missingPermissions.isEmpty) _maybeAutoConnect();
  }

  /// Host, permissions granted (Home opened, or the app came back to the
  /// front): connect without waiting for a tap when there's nothing to choose
  /// ([BaseConnectionManager.connectIfUnambiguous]), unless the user stopped
  /// the last attempt. The same check runs at launch from the host's
  /// `autoConnect()`, which doesn't need this screen to have been drawn.
  Future<void> _maybeAutoConnect() async {
    if (_userStopped) return;
    await _connection.connectIfUnambiguous();
  }

  void onGrantPermission(String key) => _perms.openPermission(key);

  /// Client: open the display view manually (via the Open View button). Only
  /// meaningful once the stream is live.
  void onOpenView() {
    if (_connection.phase.value.isActive) {
      Get.toNamed(AppRoutes.display);
    }
  }

  /// Host: the picker's refresh button. Repeated taps while one is running are
  /// ignored.
  Future<void> refreshDevices() async {
    if (refreshingDevices.value) return;
    refreshingDevices.value = true;
    try {
      // Keep the spinner up briefly: `adb devices` often answers within a
      // frame or two, too fast to read as feedback.
      await Future.wait([
        _connection.refreshDevices(),
        Future<void>.delayed(const Duration(milliseconds: 300)),
      ]);
    } finally {
      refreshingDevices.value = false;
    }
  }

  // Set when the user explicitly disconnects/cancels. Suppresses auto-connect
  // (which also re-runs whenever the app regains focus) until they connect
  // again themselves — otherwise a Cancel was undone by the next focus.
  bool _userStopped = false;

  /// The card's single action: Disconnect while live, Cancel while connecting
  /// (or, on the host, while a retry is pending), else Connect. Matches
  /// ConnectionCard's choice of label. On the host, Connect is only offered
  /// over Wi-Fi (start listening); over USB it connects by picking a device.
  void onConnectTap() {
    final p = _connection.phase.value;
    final stops = p.isActive ||
        p.isConnecting ||
        (isHost && p == ConnectionPhase.error);
    if (stops) {
      _userStopped = true;
      _connection.disconnect();
    } else {
      _connect();
    }
  }

  /// Host: connect to the chosen Android client. Selecting a device is the only
  /// way to connect. The display renders on the Android device (it auto-opens
  /// there); the Mac stays on this screen as the capture source.
  Future<void> onSelectDevice(DeviceModel device) =>
      _connect(serial: device.serial);

  /// Gate every connect attempt behind a permission check on the host: capture
  /// and input injection need Screen Recording + Accessibility. If anything is
  /// missing, bounce to Settings (scrolled to Permissions) instead of failing
  /// mid-handshake.
  Future<void> _connect({String? serial}) async {
    _userStopped = false;
    if (isHost && !await _ensureHostPermissions()) return;
    await _connection.connect(serial: serial);
  }

  Future<bool> _ensureHostPermissions() async {
    final granted = await _perms.hostGranted();
    if (!granted) {
      Get.snackbar(
        'perm_required_title'.tr,
        'perm_required_msg'.tr,
        snackPosition: SnackPosition.BOTTOM,
        margin: const EdgeInsets.all(16),
      );
      Get.toNamed(AppRoutes.settings, arguments: {'scrollTo': 'permissions'});
    }
    return granted;
  }

  void onGoToSettings() {
    Get.toNamed(AppRoutes.settings);
  }
}
