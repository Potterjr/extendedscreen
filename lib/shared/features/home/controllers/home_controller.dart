import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_grid_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_spec.dart';
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

  ConnectionPhase get phase => _connection.phase.value;
  DeviceModel? get device => _connection.activeDevice.value;

  // Reverse remote (Mac controls this tablet): screen-share button state.
  RxBool get needsScreenShare => _connection.needsScreenShare;
  RxBool get isScreenSharing => _connection.isScreenSharing;
  void onStartScreenShare() => _connection.startScreenShare();
  int get latencyMs => _connection.latencyMs.value;
  String get errorMessage => _connection.errorMessage.value;

  bool get isHost => _connection.isHost;

  /// Host: the iPhones and iPads plugged in over USB, as
  /// [IosScreenChannel.listDevices] lists them, each with a card on Home
  /// that opens its page. Listed when Home opens, on each resume, and every
  /// [iosPollInterval] while Home is the route shown and the app is in
  /// front.
  final iosUsbDevices = <IosScreenDevice>[].obs;

  /// How often [iosUsbDevices] is listed again; null: only when Home opens
  /// and on resume (tests).
  final Duration? iosPollInterval;

  HomeController({this.iosPollInterval = const Duration(seconds: 2)});

  Timer? _iosPoll;
  Future<void>? _iosListing;

  /// The app is in front (the poll lists nothing while it is not).
  bool _resumed = true;

  /// Whether touches reach a phone over USB; null without the service.
  Rx<IosTouchState>? get iosTouchState => Get.isRegistered<IosTouchService>()
      ? Get.find<IosTouchService>().state
      : null;

  /// Host: lists the iPhones and iPads on USB again, one listing at a time.
  /// The list is replaced only when it changed, so a poll that finds the
  /// same phone rebuilds nothing.
  Future<void> refreshIosDevices() {
    if (!isHost || !Get.isRegistered<IosScreenChannel>()) {
      return Future.value();
    }
    return _iosListing ??= () async {
      try {
        final list = await Get.find<IosScreenChannel>().listDevices();
        if (isClosed) return;
        final same =
            list.length == iosUsbDevices.length &&
            [
              for (var i = 0; i < list.length; i++)
                list[i].id == iosUsbDevices[i].id &&
                    list[i].name == iosUsbDevices[i].name,
            ].every((same) => same);
        if (!same) iosUsbDevices.assignAll(list);
      } finally {
        _iosListing = null;
      }
    }();
  }

  /// Host, an iPhone's card: its page, showing that phone.
  void onOpenIphone(String id) =>
      Get.toNamed(AppRoutes.iphoneRemote, arguments: {'id': id});

  /// Host: a manual device-list refresh (the picker's refresh button) is
  /// running. Lets the picker show it is working: when the list comes back
  /// unchanged, nothing else on screen would move.
  final refreshingDevices = false.obs;

  // ─── Link type (USB / Wi-Fi) ──────────────────────────────────────────────

  /// Which link this device uses. Each side picks its own: the host how it
  /// listens, the client where it dials.
  Rx<LinkType> get linkType => _settings.linkTypeRx;
  bool get isWifi => _settings.linkTypeRx.value == LinkType.wifi;

  Future<void> onSelectLinkType(LinkType type) async {
    if (_settings.linkType == type) return;
    await _settings.setLinkType(type);
    // Only the tablet has a link selector on Home: the Mac's USB always
    // runs, and Wi-Fi is the Add a device panel's last row.
    if (!isHost) await _redialClient();
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

  /// Host: (re)open the remote view, to get back in after backing out of it
  /// while a tablet the Mac controls is still live. With [key] (a tablet's
  /// card) the view is asked to show that tablet's tile alone, which it
  /// does only beside other tiles. The hub's focus is left as it is: the
  /// view shows every such tablet, whichever one the hub shows.
  void onOpenRemoteView({String? key}) {
    if (Get.currentRoute == AppRoutes.remoteHost &&
        Get.isRegistered<RemoteGridController>()) {
      // Already open: nothing to push, only the tile to show.
      if (key != null) Get.find<RemoteGridController>().expand(key);
      return;
    }
    Get.toNamed(AppRoutes.remoteHost,
        arguments: key == null ? null : {'focus': key});
  }

  /// The remote view, by itself: only from Home, so it never opens over
  /// Settings or a second time over itself.
  void _openRemoteFromHome() {
    if (Get.currentRoute == AppRoutes.home) Get.toNamed(AppRoutes.remoteHost);
  }

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
      if (Get.isRegistered<IosScreenChannel>()) {
        unawaited(refreshIosDevices());
        if (iosPollInterval case final every?) {
          // "While Home is shown": not under Settings, the remote view or
          // the iPhone's own page, and not with the app in the background.
          _iosPoll = Timer.periodic(every, (_) {
            if (Get.currentRoute == AppRoutes.home && _resumed) {
              unawaited(refreshIosDevices());
            }
          });
        }
      }
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
      // Host: the Mac is the viewer of every tablet it controls (remote
      // control, Mac controls tablet). The remote view opens when the first
      // of them goes live: the count of live ones leaving 0, whichever
      // tablet the hub shows and whatever the selectors say now. A tablet
      // that joins later gets a tile in the view and opens nothing, and an
      // Extended or tablet-controls-Mac session never counts.
      var live = _connection.reverseActive.value;
      _workers.add(ever<int>(_connection.reverseActive, (now) {
        final before = live;
        live = now;
        if (before == 0 && now > 0) _openRemoteFromHome();
      }));
      // Already live when Home opens: the launch connected by itself
      // (HostConnectionManager.autoConnect), before the splash moved on or
      // while the window was hidden, and `ever` only sees changes.
      if (live > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_connection.reverseActive.value > 0) _openRemoteFromHome();
        });
      }
    }
  }

  @override
  void onClose() {
    if (isHost) WidgetsBinding.instance.removeObserver(this);
    _iosPoll?.cancel();
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
      _resumed = true;
      _checkHostPermissions();
      _loadLocalAddresses(); // the Mac may have changed network meanwhile
      unawaited(refreshIosDevices());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _resumed = false;
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
  /// front): run the hub's auto-connect policy
  /// ([BaseConnectionManager.connectIfUnambiguous]), which does nothing
  /// while the user's Cancel or Disconnect on this card has paused it. The
  /// same policy runs at launch from the host's `autoConnect()`, which
  /// doesn't need this screen to have been drawn, and from the hub's own
  /// resume and device poll.
  Future<void> _maybeAutoConnect() => _connection.connectIfUnambiguous();

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

  /// The card's single action: Disconnect while live, Cancel while connecting
  /// (or, on the host, while a retry is pending), else Connect. Matches
  /// ConnectionCard's choice of label. On the host, Connect is only offered
  /// over Wi-Fi (start listening); over USB it connects by picking a device.
  /// A stop also pauses the host's auto-connect until the user connects
  /// again, or the next focus (or the device poll) would undo the Cancel.
  void onConnectTap() {
    final p = _connection.phase.value;
    final stops = p.isActive ||
        p.isConnecting ||
        (isHost && p == ConnectionPhase.error);
    if (stops) {
      _connection.pauseAutoConnect();
      _connection.disconnect();
    } else {
      _connect();
    }
  }

  /// Host, the Add a device panel: Connect on [device]. With no [choice]
  /// (a device the Mac has had before, whose role fits) it connects in its
  /// remembered role ([SettingsService.knownChoice], which cannot change
  /// while the device has no session, so reading it before the permissions
  /// are asked about is safe). With one (picked in the role chooser) it
  /// connects as that.
  ///
  /// A pick from the chooser was made while the page could change under
  /// the dialog (another tablet taking the last place, the auto-connect
  /// taking this one), so it is checked again first: refused, a snackbar
  /// says why and nothing is connected or saved. For a new device the pick
  /// is kept as the role a new device gets by default
  /// ([SettingsService.nextChoice], which the chooser preselects next
  /// time), once the permissions have been granted: a press that ends in
  /// Settings changes nothing.
  Future<void> onConnectDevice(DeviceModel device, {SessionChoice? choice}) {
    final known = _settings.knownChoice(device.serial);
    if (choice != null) {
      final refused = isFree(device.serial)
          ? addBlockedReason(role: choice, serial: device.serial)
          : 'home_row_taken'.tr;
      if (refused != null) {
        Get.snackbar(
          'home_connect_refused'.tr,
          refused,
          snackPosition: SnackPosition.BOTTOM,
          margin: const EdgeInsets.all(16),
        );
        return Future.value();
      }
    }
    return _connect(
      serial: device.serial,
      choice: choice ?? known,
      saveAsNext: choice != null && known == null,
    );
  }

  /// Host: [serial] is attached with no session (a row of the Add a device
  /// panel).
  bool isFree(String serial) {
    final hub = _connection;
    return hub is! HostConnectionManager ||
        hub.freeDevices.any((d) => d.serial == serial);
  }

  /// Host: why a device with no session cannot be connected now, in plain
  /// words, or null when it can: every place is taken (by Maximum tablets,
  /// or by what this Mac can drive, which the user cannot raise), or every
  /// device is being disconnected. With [role] and [serial], also when the
  /// encoder has no room for that device as that role. Reads the hub's
  /// observables, so an `Obx` calling it follows them.
  String? addBlockedReason({SessionChoice? role, String? serial}) {
    final hub = _connection;
    if (hub is! HostConnectionManager) return null;
    final sessions = hub.sessions.values.toList();
    final busy =
        sessions.any(
          (s) => s.phase.value.isConnecting || s.phase.value.isActive,
        ) ||
        hub.phase.value.isConnecting ||
        hub.phase.value.isActive;
    final cap = hub.cap;
    // With one tablet at most (cap 1), connecting another one replaces the
    // session there is while it is not under way, as it always has.
    final canPick = hub.canAdd || (cap == 1 && sessions.length <= 1 && !busy);
    if (!canPick) {
      // A Disconnect of every device (the remote view's, say) is still
      // ending them: the devices it freed are not short of room.
      if (hub.endingAll.value) return 'home_disconnecting'.tr;
      return (capIsTheMacs ? 'home_row_full_mac' : 'home_row_full').trParams({
        'cap': '$cap',
      });
    }
    if (role != null && serial != null && !fitsEncoder(serial, role)) {
      return 'home_row_encoder_full'.tr;
    }
    return null;
  }

  /// Host: the cap on devices at once is lower than Maximum tablets (what
  /// the Mac's encoder is estimated to drive, or the link), so Settings
  /// cannot raise it.
  bool get capIsTheMacs {
    final hub = _connection;
    return hub is HostConnectionManager && hub.cap < _settings.maxTablets;
  }

  /// Host: whether the Mac's encoder has room for [serial] as [choice]
  /// now. A device the Mac only views takes nothing of it. True when the
  /// manager is not the hub (stand-ins in tests).
  bool fitsEncoder(String serial, SessionChoice choice) {
    final hub = _connection;
    if (choice.isReverse || hub is! HostConnectionManager) return true;
    return hub.budget.wouldFit(
      _settings.captureConfigFor(
        _settings.clientPanelFor(serial) ?? _settings.lastClientPanel,
        SessionSpec.from(
          choice,
          LinkType.usb,
          displayMode: _settings.displayModeFor(serial),
        ),
        profile: _settings.deviceProfile(serial),
      ),
      cap: hub.cap,
    );
  }

  /// Host, a tablet's card: its Disconnect, or its Cancel while it connects
  /// or waits to retry. Ends that tablet's session alone, and the automatic
  /// connects leave the tablet alone until the user connects it again.
  Future<void> onSessionStop(String key) async {
    // A device on Wi-Fi is stopped like a tablet: the listener turns it
    // away until listening is turned on again (a device without an install
    // id is a new one each time, and comes back when it redials).
    await _connection.disconnectSession(key, userStopped: true);
  }

  /// Host, the Add a device panel's last row: Accept devices over Wi-Fi,
  /// turned on or off. Saved; the hub
  /// starts or stops its listener (and the Wi-Fi devices' sessions) itself. Turning
  /// it on needs the two permissions, like a connect from Home.
  Future<void> onWifiListen(bool on) async {
    if (on && isHost && !await _ensureHostPermissions()) return;
    await _settings.setWifiListen(on);
  }

  /// Host, a tablet's card: Retry, offered in `error`: when its failure
  /// armed no retry (the encoder had no room for it), or to run the retry
  /// it waits for now instead of when its backoff runs out. Runs that
  /// session's connect again, on the same session.
  Future<void> onSessionRetry(String key) => _connect(serial: key);

  /// Host, a tablet's card: one of its role chips picked [choice] for
  /// [session], the session the chip was built for. The hub ends that session and
  /// makes the tablet a new one as [choice]; the other tablets run on.
  /// Nothing when the tablet's session is another one by now (a press
  /// that began before a replacement), and the hub refuses what it cannot do
  /// (a session on its way to being live, a change that changes nothing).
  /// A mode in which the Mac captures its screen and takes the tablet's
  /// input needs the two permissions, like a connect from Home.
  Future<void> onSessionMode(HostSession session, SessionChoice choice) async {
    final hub = _connection;
    if (hub is! HostConnectionManager ||
        !identical(hub.sessions[session.key], session)) {
      return;
    }
    if (choice.encodesOnMac && !await _ensureHostPermissions()) return;
    // Whatever happened while the permissions were asked about, the hub
    // changes this session or none.
    await hub.changeMode(session.key, choice, expected: session);
  }

  /// Host: a tablet's card was tapped; the values the hub shows as its own
  /// (the session it retries or replaces on the next pick, what Settings
  /// labels its presets with) follow that tablet from now on. The remote
  /// view does not: it has a tile for every tablet the Mac controls.
  /// Checked, not cast: Home also runs over stand-in managers in tests.
  void onFocus(String key) {
    final hub = _connection;
    if (hub is HostConnectionManager) hub.focus(key);
  }

  /// Gate every connect attempt behind a permission check on the host: capture
  /// and input injection need Screen Recording + Accessibility. If anything is
  /// missing, bounce to Settings (scrolled to Permissions) instead of failing
  /// mid-handshake.
  ///
  /// [choice]: the role a session made for [serial] runs as (none: the
  /// hub's own rule; a session that exists keeps its own).
  /// [saveAsNext]: [choice] becomes the role a new device gets by default,
  /// once the permissions are granted.
  Future<void> _connect({
    String? serial,
    SessionChoice? choice,
    bool saveAsNext = false,
  }) async {
    if (isHost && !await _ensureHostPermissions()) return;
    if (saveAsNext && choice != null) {
      // The observables change at once; the writes to disk follow.
      unawaited(_settings.setSessionMode(choice.mode));
      unawaited(_settings.setRemoteDirection(choice.direction));
    }
    // The user connects again: the auto-connect they paused, and the
    // tablet they stopped, are theirs to connect by itself again. Only
    // now, in one step with the connect and with no await between the
    // two: the hub holds the tablet as being picked before it awaits
    // anything, so no automatic connect ever finds it allowed and not yet
    // picked. Lifted before the permissions were asked about, a policy run
    // already under way connected a stopped tablet as it was remembered,
    // and this pick, in the mode the selectors show, was refused as a
    // second one. A press that ends in Settings lifts nothing.
    _connection.allowDevice(serial);
    await _connection.connectWith(serial, choice: choice);
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
