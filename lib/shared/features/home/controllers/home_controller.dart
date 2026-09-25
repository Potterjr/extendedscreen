import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
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

  /// macOS host permissions that must be granted before capture can start.
  static const _requiredHostPermissions = ['screen_recording', 'accessibility'];

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
  RxList<DeviceModel> get availableDevices => _connection.availableDevices;

  /// Remote-control direction picker (host, while idle in remote-control mode).
  bool get isRemoteControl =>
      _settings.sessionModeRx.value == SessionMode.remoteControl;
  Rx<RemoteDirection> get remoteDirection => _settings.remoteDirectionRx;
  void onSelectDirection(RemoteDirection dir) =>
      _settings.setRemoteDirection(dir);

  /// Host, reverse remote (Mac controls tablet): true once the tablet stream is
  /// live. Reads the session-mode/direction observables so it is reactive.
  bool get isReverseRemote => _settings.isReverseRemote;

  /// Host: (re)open the remote view — used to get back in after backing out of
  /// it while a reverse-remote session is still live.
  void onOpenRemoteView() => Get.toNamed(AppRoutes.remoteHost);

  RxBool get isConnecting => _connection.phase.value.isConnecting.obs;

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
      ever<ConnectionPhase>(_connection.phase, (p) {
        if (p.isActive &&
            !_settings.isReverseRemote &&
            Get.currentRoute == AppRoutes.home) {
          Get.toNamed(AppRoutes.display);
        }
      });
      everAll([_settings.sessionModeRx, _settings.remoteDirectionRx], (_) {
        if (_settings.isReverseRemote && Get.currentRoute == AppRoutes.display) {
          Get.back();
        }
      });
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
      ever<ConnectionPhase>(_connection.phase, (p) {
        if (p.isActive &&
            _settings.isReverseRemote &&
            Get.currentRoute == AppRoutes.home) {
          Get.toNamed(AppRoutes.remoteHost);
        }
      });
    }
  }

  @override
  void onClose() {
    if (isHost) WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkHostPermissions();
  }

  Future<void> _checkHostPermissions() async {
    final status = await _perms.checkPermissions();
    missingPermissions.value = _requiredHostPermissions
        .where((key) => !(status[key] ?? false))
        .toList();
    if (missingPermissions.isEmpty) _maybeAutoConnect();
  }

  /// Host: connect without waiting for a tap when there's nothing to choose —
  /// exactly one physical device (emulators are ignored whenever a real device
  /// is present, and only count when they're all there is). Anything more
  /// ambiguous falls through to the picker. Deliberately not keyed off the
  /// saved last-used serial: that's persisted on every connect *attempt*, so a
  /// reconnect-timer fallback can leave it pointing at the wrong device, and
  /// a wrong pick strands the host mid-handshake with no picker visible.
  Future<void> _maybeAutoConnect() async {
    if (_userStopped ||
        _connection.phase.value != ConnectionPhase.disconnected) {
      return;
    }
    await _connection.refreshDevices();
    final devices = _connection.availableDevices;
    final physical =
        devices.where((d) => !d.serial.startsWith('emulator-')).toList();
    final candidates = physical.isNotEmpty ? physical : devices;
    if (candidates.length == 1) await _connect(serial: candidates.first.serial);
  }

  void onGrantPermission(String key) => _perms.openPermission(key);

  /// Client: open the display view manually (via the Open View button). Only
  /// meaningful once the stream is live.
  void onOpenView() {
    if (_connection.phase.value.isActive) {
      Get.toNamed(AppRoutes.display);
    }
  }

  Future<void> refreshDevices() => _connection.refreshDevices();

  // Set when the user explicitly disconnects/cancels. Suppresses auto-connect
  // (which also re-runs whenever the app regains focus) until they connect
  // again themselves — otherwise a Cancel was undone by the next focus.
  bool _userStopped = false;

  /// The card's single action: Disconnect while live, Cancel while connecting
  /// (or, on the host, while a retry is pending), else Connect. Matches
  /// ConnectionCard's choice of label.
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
    final status = await _perms.checkPermissions();
    final granted = _requiredHostPermissions
        .every((key) => status[key] ?? false);
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
