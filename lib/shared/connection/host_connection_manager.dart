import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/platform/permissions_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';

/// HOST role (macOS): the hub that holds one [HostSession] per tablet. Each
/// session is a tablet's whole link (its adb tunnel and loopback port, or
/// the Wi-Fi listener; authentication, capture or decoding, input) with its
/// own copy of the link's state machine. The hub chooses what to connect,
/// owns what there is one of for the app (the device list, the
/// app-lifecycle observer, the media [pipeline], the native plugins'
/// single-slot callbacks, which it routes to the session they are about),
/// and runs no link of its own: no packet loop, heartbeat or retry.
///
/// For now it holds at most one session, and mirrors it: its [phase],
/// [errorMessage], [activeDevice], [latencyMs], [refreshRateHz],
/// [streamBitrate], [availableDevices] and the reverse-remote observables
/// follow the focused session's, so Home, Settings and the remote view see
/// what they saw when this class was the link itself.
class HostConnectionManager extends BaseConnectionManager {
  /// [socket] and [port] (tests) go to the sessions it makes: one session at
  /// a time uses an injected socket. Without one, each session gets a socket
  /// of its own. [adb] defaults to the registered [AdbService].
  HostConnectionManager({SocketService? socket, super.port, AdbService? adb})
      : _injectedSocket = socket,
        _adb = adb ?? Get.find<AdbService>(),
        super(socket: socket ?? SocketService()) {
    _adb.onTabletScreenRestored = (serial) {
      for (final s in sessions.values) {
        s.onTabletScreenRestored(serial);
      }
    };
    ever<LinkType>(settings.linkTypeRx, _onLinkTypeChanged);
    _routeNativeCallbacks();
  }

  final AdbService _adb;
  final SocketService? _injectedSocket;

  /// Every session's media pipeline goes through this one queue.
  final pipeline = PipelineQueue();

  /// Each tablet's adb rule, as successive sessions for it take turns.
  final _tunnels = TabletTunnels();

  // One choice at a time: from a connect() deciding which session to use
  // until that session has started connecting (and so shows a connecting
  // phase), or a link change ending one, nothing else may pick or end a
  // session. And nothing while a disconnect() is ending them all.
  bool _choosing = false;
  int _ending = 0;

  // Over USB with nothing attached: the next look for a device to connect.
  Timer? _lookAgain;

  /// The sessions, by key: the adb serial over USB, [wifiKey] for the one
  /// Wi-Fi session. At most one for now.
  final sessions = <String, HostSession>{}.obs;

  /// The key of the one Wi-Fi session.
  static const wifiKey = 'wifi';

  /// The session whose values the hub's observables show.
  HostSession? get focused => _focused;
  HostSession? _focused;
  final _mirrors = <Worker>[];

  @override
  bool get isHost => true;

  // ─── Reverse remote, mirrored from the focused session ────────────────────

  /// Texture id of the decoded tablet stream (reverse remote: Mac controls the
  /// tablet). Null unless a reverse-remote session is live; the remote-view
  /// widget renders a `Texture` from it.
  final remoteTextureId = Rxn<int>();

  /// Reverse remote: the tablet's picture has started to arrive this session
  /// (its user approved screen capture), so its panel may go dark now.
  final tabletStreaming = false.obs;

  /// Reverse remote: the tablet's panel is held off ([setTabletScreenOff]).
  final tabletScreenOff = false.obs;

  /// A [setTabletScreenOff] is under way, the user's or the remembered
  /// choice's: the toggle waits for it, and another call is refused.
  final changingTabletScreen = false.obs;

  /// Reverse remote (USB): turns the focused tablet's panel off, or back on
  /// ([HostSession.setTabletScreenOff]). Returns null when done, else why
  /// not.
  Future<String?> setTabletScreenOff(bool off) async {
    final session = _focused;
    if (session == null) return 'no live Mac-controls-tablet session';
    return session.setTabletScreenOff(off);
  }

  void sendRemoteTap(double nx, double ny) => _focused?.sendRemoteTap(nx, ny);

  void sendRemoteSwipe(double nx1, double ny1, double nx2, double ny2,
          {int durationMs = 50}) =>
      _focused?.sendRemoteSwipe(nx1, ny1, nx2, ny2, durationMs: durationMs);

  /// Makes [session] the hub's (and its focused one) without connecting it.
  @visibleForTesting
  void adopt(HostSession session) {
    sessions[session.key] = session;
    _routeNativeCallbacks();
    _focus(session);
  }

  /// Whether the focused session's encoder bitrate is being fitted to the
  /// link right now.
  @visibleForTesting
  bool get adaptingBitrate => _focused?.adaptingBitrate ?? false;

  // ─── Choosing and connecting ──────────────────────────────────────────────

  /// Splash entry point: loads the device list for the picker and, when
  /// Screen Recording and Accessibility are granted, connects if there is
  /// nothing to choose ([connectIfUnambiguous]), as Home does when it opens.
  /// Not left to Home: an app launched behind other windows (or at login, or
  /// hidden) is `hidden` to Flutter, which draws no frames then, so the Home
  /// route is not built and its controller does not run until the window is
  /// shown. Without permissions nothing starts; Home asks for them once it
  /// is on screen.
  @override
  Future<void> autoConnect() async {
    // A Cancel or Disconnect (or a retry) after this point owns what
    // happens next: adb can take seconds to answer its first call.
    final attempt = currentAttempt;
    // Over Wi-Fi nothing waits on adb: the list is only for the picker.
    final listing = refreshDevices();
    if (settings.linkType != LinkType.wifi) await listing;
    if (isCancelled(attempt)) return;
    if (!await PermissionsChannel().hostGranted()) return;
    await connectIfUnambiguous(since: attempt);
  }

  @override
  Future<void> refreshDevices() async {
    availableDevices.value = await _adb.listDevices();
  }

  /// Connects a tablet over the link Home has chosen: over Wi-Fi the one
  /// Wi-Fi session (listening for the paired tablet); over USB the device
  /// [serial], else the focused session's own device (a retry run early),
  /// else the last-used device if it is attached, else the first one
  /// attached; with none attached, it says so and looks again every second.
  /// Picking another device ends the focused session first. Only while
  /// nothing is connecting or connected, and one call at a time.
  @override
  Future<void> connect({String? serial}) async {
    if (_choosing ||
        _ending > 0 ||
        phase.value.isConnecting ||
        phase.value.isActive) {
      return;
    }
    _choosing = true;
    _lookAgain?.cancel();
    final HostSession? session;
    try {
      session = await _choose(serial);
    } finally {
      _choosing = false;
    }
    // Synchronously after the choice: the session's phase (and so the
    // hub's) is a connecting one before anything else can run.
    await session?.connect();
  }

  /// Which session [connect] goes on with; null when there is none to
  /// connect (nothing attached, or a [disconnect] came meanwhile).
  Future<HostSession?> _choose(String? serial) async {
    final attempt = currentAttempt;
    final link = settings.linkType;
    final focused = _focused;
    final String key;
    if (link == LinkType.wifi) {
      key = wifiKey;
    } else if (serial != null) {
      key = serial;
    } else if (focused != null && focused.link == LinkType.usb) {
      key = focused.key;
    } else {
      setPhase(ConnectionPhase.detectingDevice);
      final devices = await _adb.listDevices();
      if (isCancelled(attempt)) return null;
      availableDevices.value = devices;
      final preferred = settings.lastDeviceSerial;
      final picked =
          devices.firstWhereOrNull((d) => d.serial == preferred)?.serial ??
              devices.firstOrNull?.serial;
      if (picked == null) {
        // Nothing to fix a session to yet: say so, and look again, taking
        // whichever tablet is plugged in first (the last-used one if it is
        // among them).
        errorMessage.value = 'Exception: No ADB device detected';
        setPhase(ConnectionPhase.error);
        _lookAgain = Timer(const Duration(seconds: 1), () {
          if (!isCancelled(attempt) && _focused == null) connect();
        });
        return null;
      }
      key = picked;
    }
    return _sessionFor(key, link, attempt);
  }

  /// The session [key] on [link]: the focused one when it is that, else a
  /// new one, once the focused session (another tablet, or the other link)
  /// has ended. Null when a [disconnect] came meanwhile.
  Future<HostSession?> _sessionFor(String key, LinkType link, int attempt) async {
    final current = _focused;
    if (current != null && current.key == key && current.link == link) {
      return current;
    }
    if (current != null) {
      final ended = _endSession(current);
      // What Home shows while the old session ends.
      setPhase(link == LinkType.wifi
          ? ConnectionPhase.handshaking
          : ConnectionPhase.detectingDevice);
      await ended;
      if (isCancelled(attempt)) return null;
    }
    final session = HostSession(
      key: key,
      link: link,
      serial: link == LinkType.usb ? key : null,
      pipeline: pipeline,
      tunnels: _tunnels,
      adb: _adb,
      socket: _injectedSocket ?? SocketService(),
      port: linkPort,
    );
    if (link == LinkType.usb) _tunnels.claim(key, session);
    sessions[key] = session;
    _routeNativeCallbacks();
    _focus(session);
    return session;
  }

  /// Ends [session] for good. It is out of reach at once (out of
  /// [sessions], no longer focused or mirrored, refusing to connect), so
  /// nothing can pick it again while it ends; then its link ends, then its
  /// native state.
  Future<void> _endSession(HostSession session) async {
    if (sessions[session.key] == session) sessions.remove(session.key);
    if (_focused == session) {
      _unfocus();
      // What its teardown would have shown, mirrored.
      activeDevice.value = null;
      streamBitrate.value = null;
      remoteTextureId.value = null;
      tabletStreaming.value = false;
      tabletScreenOff.value = false;
      changingTabletScreen.value = false;
    }
    session.retire();
    await session.disconnect();
    session.dispose();
    if (Get.isRegistered<ScreenCaptureChannel>()) {
      final capture = Get.find<ScreenCaptureChannel>();
      await pipeline.run(() => capture.disposeSession(session: session.nativeId));
    }
  }

  /// Ends every session; nothing new starts until it is done.
  @override
  Future<void> disconnect() async {
    _ending++;
    try {
      await super.disconnect();
    } finally {
      _ending--;
    }
  }

  /// Every session ends ([disconnect] runs this).
  @override
  Future<void> onTeardown() async {
    _lookAgain?.cancel();
    for (final session in sessions.values.toList()) {
      await _endSession(session);
    }
  }

  /// Applies a settings change: the focused session reconnects (its next
  /// attempt takes the new settings), as the link itself used to.
  @override
  Future<void> reconnect() async {
    await _focused?.reconnect();
  }

  /// Host → tablet: the overlay/HUD toggles, to every tablet.
  @override
  void sendUiFlags() {
    for (final session in sessions.values) {
      session.sendUiFlags();
    }
  }

  /// Discards this Mac's Wi-Fi identity (Settings → Reset Wi-Fi pairing): no
  /// tablet paired so far can connect over Wi-Fi again until it has been
  /// connected over USB once more. Each session then does its part
  /// ([HostSession.identityWasReset]): the Wi-Fi one listens again with the
  /// new identity, a live USB one hands its tablet the new identity.
  @override
  Future<void> resetWifiIdentity() async {
    await Get.find<WifiPairingService>().resetIdentity();
    for (final session in sessions.values.toList()) {
      await session.identityWasReset();
    }
  }

  /// The app's lifecycle, for every session: a detached app ends them all;
  /// on resume each one that lost its link and is not already retrying
  /// reconnects to its device (the base class's rule, per session).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      disconnect();
      return;
    }
    for (final session in sessions.values.toList()) {
      session.didChangeAppLifecycleState(state);
    }
  }

  /// Home offers the link selector while nothing is connecting or live. A
  /// session waiting to retry on the other link ends, and the retry it was
  /// waiting for runs on the new link; an idle one just ends.
  Future<void> _onLinkTypeChanged(LinkType link) async {
    final session = _focused;
    if (session == null || session.link == link || _choosing || _ending > 0) {
      return;
    }
    final p = session.phase.value;
    if (p.isConnecting || p.isActive) return;
    final retrying = p == ConnectionPhase.error;
    final attempt = currentAttempt;
    _choosing = true;
    try {
      await _endSession(session);
    } finally {
      _choosing = false;
    }
    if (isCancelled(attempt)) return;
    if (retrying) {
      await connect();
    } else {
      setPhase(ConnectionPhase.disconnected);
    }
  }

  // ─── Routing and mirroring ────────────────────────────────────────────────

  /// The native plugins have one callback each: the hub takes them and
  /// hands each event to the session it is about (a wake to all of them).
  void _routeNativeCallbacks() {
    if (Get.isRegistered<ScreenCaptureChannel>()) {
      final capture = Get.find<ScreenCaptureChannel>();
      capture.onCaptureRestartNeeded = (id) {
        for (final s in sessions.values.toList()) {
          if (id == null || s.nativeId == id) s.captureNeedsRestart();
        }
      };
      capture.onDisplayBoundsChanged = () {
        for (final s in sessions.values.toList()) {
          s.displayBoundsChanged();
        }
      };
      capture.onFrameRateChanged =
          (id, fps) => _byNativeId(id)?.frameRateChanged(fps);
    }
    if (Get.isRegistered<RemoteVideoChannel>()) {
      Get.find<RemoteVideoChannel>().onRequestIdr =
          (id) => _byNativeId(id)?.decoderWantsKeyframe();
    }
  }

  HostSession? _byNativeId(int id) {
    for (final s in sessions.values) {
      if (s.nativeId == id) return s;
    }
    return null;
  }

  /// The hub's observables follow [session]'s from now on. Each is the
  /// hub's own Rx for its whole life: Home's workers and the remote view's
  /// widgets hold on to them.
  void _focus(HostSession session) {
    _unfocus();
    _focused = session;
    void mirror<T>(Rx<T> from, Rx<T> to) {
      to.value = from.value;
      _mirrors.add(ever<T>(from, (v) => to.value = v));
    }

    mirror(session.phase, phase);
    mirror(session.errorMessage, errorMessage);
    mirror(session.activeDevice, activeDevice);
    mirror(session.latencyMs, latencyMs);
    mirror(session.refreshRateHz, refreshRateHz);
    mirror(session.streamBitrate, streamBitrate);
    mirror(session.remoteTextureId, remoteTextureId);
    mirror(session.tabletStreaming, tabletStreaming);
    mirror(session.tabletScreenOff, tabletScreenOff);
    mirror(session.changingTabletScreen, changingTabletScreen);
    // The session lists the devices as it connects; the picker shows that.
    _mirrors.add(ever<List<DeviceModel>>(session.availableDevices,
        (_) => availableDevices.value = session.availableDevices.toList()));
  }

  /// The hub's observables keep the last values they mirrored.
  void _unfocus() {
    for (final w in _mirrors) {
      w.dispose();
    }
    _mirrors.clear();
    _focused = null;
  }
}
