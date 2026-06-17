import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/platform/permissions_channel.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class HomeController extends GetxController {
  final _connection = Get.find<BaseConnectionManager>();
  final _settings = Get.find<SettingsService>();
  final _perms = PermissionsChannel();

  /// macOS host permissions that must be granted before capture can start.
  static const _requiredHostPermissions = ['screen_recording', 'accessibility'];

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

  /// Client: open the display view manually (via the Open View button). Only
  /// meaningful once the stream is live.
  void onOpenView() {
    if (_connection.phase.value.isActive) {
      Get.toNamed(AppRoutes.display);
    }
  }

  Future<void> refreshDevices() => _connection.refreshDevices();

  void onConnectTap() {
    if (_connection.phase.value.isActive) {
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
