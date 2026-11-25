import 'dart:async';

import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_window_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/tablet_remote_window.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';

/// Mac: opens a tablet's native remote window ([TabletRemoteWindow]) by
/// itself, the first time each reverse-remote session (the Mac views and
/// drives the tablet) goes live.
///
/// A permanent host service, registered after the hub, so it works with no
/// Home screen: an app launched hidden builds no route, and nothing on the
/// host's connection path may wait for one. It watches the hub's [sessions]
/// (one worker) and each session's phase (one worker per session in the
/// map), and opens a window when a session whose spec is reverse remote
/// becomes active, and at once for any that already is when it is made.
///
/// Once per session object: it remembers every [HostSession.nativeId] it
/// has opened (or found open) a window for, so a session whose link drops
/// and comes back (same session, same id: its window, kept open meanwhile,
/// says it is reconnecting) opens nothing more, and neither does one whose
/// window the user closed (closing it ends that session anyway). A tablet
/// brought back from Home gets a new session, so a new id, and a window of
/// its own when it goes live. A window already open under the key (opened
/// from Home before the session was live) is left as it is.
class TabletWindowOpener extends GetxService {
  TabletWindowOpener({HostConnectionManager? hub, RemoteWindowChannel? windows})
    : _hubOverride = hub,
      _windowsOverride = windows;

  final HostConnectionManager? _hubOverride;
  final RemoteWindowChannel? _windowsOverride;

  HostConnectionManager? get _hub {
    if (_hubOverride case final hub?) return hub;
    if (!Get.isRegistered<BaseConnectionManager>()) return null;
    final cm = Get.find<BaseConnectionManager>();
    return cm is HostConnectionManager ? cm : null;
  }

  RemoteWindowChannel? get _windows =>
      _windowsOverride ??
      (Get.isRegistered<RemoteWindowChannel>()
          ? Get.find<RemoteWindowChannel>()
          : null);

  /// The native ids whose session has had its window opened (or found
  /// open): never opened again.
  final _opened = <int>{};

  Worker? _sessionsWorker;
  final _phaseWorkers = <HostSession, Worker>{};

  /// The native ids this opener has seen a window for (tests).
  Set<int> get opened => Set.unmodifiable(_opened);

  @override
  void onInit() {
    super.onInit();
    final hub = _hub;
    if (hub == null) return;
    _sessionsWorker = ever<Map<String, HostSession>>(
      hub.sessions,
      (_) => _sessionsChanged(hub),
    );
    _sessionsChanged(hub);
  }

  /// The sessions in the map are watched, and no other; any of them live
  /// already is looked at now (`ever` only hears changes).
  void _sessionsChanged(HostConnectionManager hub) {
    final now = hub.sessions.values.toSet();
    for (final session in _phaseWorkers.keys.toList()) {
      if (!now.contains(session)) _phaseWorkers.remove(session)!.dispose();
    }
    for (final session in now) {
      _phaseWorkers.putIfAbsent(
        session,
        () => ever<ConnectionPhase>(
          session.phase,
          (_) => _maybeOpen(hub, session),
        ),
      );
      _maybeOpen(hub, session);
    }
  }

  void _maybeOpen(HostConnectionManager hub, HostSession session) {
    if (!session.phase.value.isActive ||
        !session.spec.isReverseRemote ||
        session.isRetired ||
        _opened.contains(session.nativeId) ||
        !identical(hub.sessions[session.key], session)) {
      return;
    }
    final windows = _windows;
    if (windows == null) return;
    _opened.add(session.nativeId);
    // Opened from Home already, before the session went live: that window
    // shows it, and is not to be brought forward over the user's work.
    if (windows.isOpen(session.key)) return;
    unawaited(windows.openDriver(TabletRemoteWindow(session.key, hub: hub)));
  }

  @override
  void onClose() {
    _sessionsWorker?.dispose();
    _sessionsWorker = null;
    for (final worker in _phaseWorkers.values) {
      worker.dispose();
    }
    _phaseWorkers.clear();
    super.onClose();
  }
}
