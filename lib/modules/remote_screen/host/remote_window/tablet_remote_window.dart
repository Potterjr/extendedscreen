import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// A tablet's native remote window (reverse remote: the Mac views and
/// drives the tablet over USB): the [RemoteDriver] that drives, shows and
/// toggles the screen for one tablet.
///
/// Its [id] is the hub's session key (the adb serial), its [kind] `tablet`,
/// which is not a single kind, so several tablets' windows and an iPhone's
/// stand side by side. It holds no session: it resolves `hub.sessions[id]`
/// on every use and keeps only the [HostSession.nativeId] of the session it
/// shows ([shownNativeId], the session under [id] when it was made, else
/// when it started). A newer session under the same key is not the one it
/// shows: it takes no input or action from this window, and closing the
/// window leaves it alone.
///
/// Pointer packets (the left button on the picture) become `adb shell
/// input` taps and swipes, as the grid's tile made them: normalised by the
/// picture box and clamped to it, a release within [dragThreshold] of its
/// press a tap where it came up, otherwise a swipe from the press (50 ms).
/// Moves are ignored; a cancel, or a release with no press, sends nothing.
/// Only a session that is reverse remote and not retired takes any.
///
/// Action items: `screen` (the tablet's panel off or back on, once its
/// picture has come; one change at a time, and a failure shows in the
/// banner for [failureFor]), `reconnect` (that tablet's session alone) and
/// `disconnect` (ends it as the user's stop, then closes the window).
///
/// Closing the window (the red button, ⌘W, the app quitting) ends the
/// session it showed as the user's stop (`disconnectSession(userStopped:
/// true)`), unless the window was closed by this driver (Disconnect, or
/// the session having gone) or the key's session is no longer the one it
/// showed. When the key leaves `hub.remoteSessions`, or a new session takes
/// it, the driver asks for its window to be closed ([closeRequests]); a
/// session in `error` keeps it, saying it is reconnecting.
///
/// Its chrome is pushed as [renders] while the window is open, worked out
/// again a microtask after any observable it read changed (the session's,
/// the hub's session map, the toggle's failure, and the app's language), so
/// several changes in one turn make one snapshot, and one equal to the last
/// is not sent again.
class TabletRemoteWindow extends RemoteDriver {
  TabletRemoteWindow(
    this.id, {
    HostConnectionManager? hub,
    RemoteVideoChannel? video,
    this.failureFor = const Duration(seconds: 4),
  }) : _hubOverride = hub,
       _videoOverride = video {
    _nativeId = _hub.sessions[id]?.nativeId;
  }

  /// The SF Symbol of the message over the picture.
  static const symbol = 'ipad.landscape';

  /// Tells a tap from a swipe by how far the pointer moved (normalised).
  static const dragThreshold = 0.012;

  /// How long a swipe takes on the tablet.
  static const swipeMs = 50;

  @override
  final String id;

  @override
  String get kind => 'tablet';

  /// How long the screen toggle's failure stays in the banner.
  final Duration failureFor;

  final HostConnectionManager? _hubOverride;
  final RemoteVideoChannel? _videoOverride;

  // Only reachable on the host, so the cast is safe.
  HostConnectionManager get _hub =>
      _hubOverride ??
      Get.find<BaseConnectionManager>() as HostConnectionManager;

  RemoteVideoChannel? get _video =>
      _videoOverride ??
      (Get.isRegistered<RemoteVideoChannel>()
          ? Get.find<RemoteVideoChannel>()
          : null);

  int? _nativeId;

  /// The native id of the session this window shows; null before there was
  /// one.
  int? get shownNativeId => _nativeId;

  bool _started = false;
  bool _disposed = false;

  /// This driver closed (or asked to close) its own window: its close ends
  /// nothing more.
  bool _closedByOwner = false;
  bool _closeAsked = false;

  /// Where the pointer went down, normalised; null with none down.
  Offset? _down;

  /// The screen toggle's last failure (the reason as the session gave it,
  /// with the tablet's name when several are controlled), until
  /// [failureFor] has passed.
  final _failure = RxnString();
  Timer? _failureTimer;

  final _renders = StreamController<RemoteViewModel>.broadcast(sync: true);
  // Not synchronous: the close it asks for disposes this driver, which
  // closes the controller, and must not do so while it is firing.
  final _closes = StreamController<void>.broadcast();

  /// Follows every observable the last model read (as an `Obx` does).
  RxNotifier<dynamic>? _observer;
  StreamSubscription<dynamic>? _observerSub;
  Worker? _sessionsWorker;
  bool _renderDue = false;
  RemoteViewModel? _last;

  @override
  Stream<RemoteViewModel> get renders => _renders.stream;

  @override
  Stream<void> get closeRequests => _closes.stream;

  /// The last snapshot sent; null before the first.
  RemoteViewModel? get lastRender => _last;

  /// The session this window shows, while the hub still has it under [id];
  /// null otherwise.
  HostSession? get session {
    final s = _hub.sessions[id];
    if (s == null || _nativeId == null || s.nativeId != _nativeId) return null;
    return s;
  }

  /// The tablet's model, else its key.
  String get name => session?.activeDevice.value?.model ?? id;

  @override
  String get title => name;

  @override
  Size? get frameSize {
    final p = (session ?? _hub.sessions[id])?.panel;
    if (p == null || p.width <= 0 || p.height <= 0) return null;
    return Size(p.width.toDouble(), p.height.toDouble());
  }

  @override
  Map<String, String> get shortcuts => const {};

  @override
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _nativeId ??= _hub.sessions[id]?.nativeId;
    final observer = _observer = RxNotifier<dynamic>();
    _observerSub = observer.listen((_) => _renderSoon());
    _sessionsWorker = ever<Map<String, HostSession>>(_hub.sessions, (_) {
      _checkGone();
      _renderSoon();
    });
    if (_checkGone()) return;
    _renderSoon();
    final s = session;
    if (s == null) return;
    // The last picture at once (a still tablet sends nothing, even after a
    // keyframe request), then a keyframe for what comes next.
    await _video?.replayLatest(s.nativeId);
    if (_disposed) return;
    session?.decoderWantsKeyframe();
  }

  /// Whether what this window shows has gone: the key has left the hub's
  /// remote sessions, or another session took it. Asks once for the window
  /// to be closed then.
  bool _checkGone() {
    if (_disposed) return true;
    final s = _hub.sessions[id];
    final gone =
        s == null ||
        (_nativeId != null && s.nativeId != _nativeId) ||
        !s.spec.isReverseRemote;
    if (gone) _requestClose();
    return gone;
  }

  /// Asks once for this window to be closed, as its owner: the close then
  /// ends nothing more.
  void _requestClose() {
    _closedByOwner = true;
    if (_closeAsked || _closes.isClosed) return;
    _closeAsked = true;
    _closes.add(null);
  }

  /// One render a microtask from now, however many changes come before it.
  void _renderSoon() {
    if (_renderDue || _disposed || !_started) return;
    _renderDue = true;
    scheduleMicrotask(_render);
  }

  void _render() {
    _renderDue = false;
    final observer = _observer;
    if (_disposed || observer == null) return;
    // A phase change may also come with the session gone.
    _checkGone();
    final vm = RxInterface.notifyChildren(observer, () {
      // `.tr` reads `Get.locale`, no observable: the language is followed
      // through the setting that changes it.
      if (Get.isRegistered<SettingsService>()) {
        Get.find<SettingsService>().localeCode.value;
      }
      return _model();
    });
    if (vm.sameAs(_last)) return;
    _last = vm;
    _renders.add(vm);
  }

  RemoteViewModel _model() {
    final s = session;
    final failure = _failure.value;
    if (s == null) {
      return RemoteViewModel(
        title: id,
        banner: failure == null ? null : _failureText(failure),
        message: RemoteMessage(
          text: 'remote_tile_reconnecting'.tr,
          passThrough: true,
        ),
        more: 'remote_window_more'.tr,
        symbol: symbol,
      );
    }
    final active = s.phase.value.isActive;
    final streaming = s.tabletStreaming.value;
    final off = s.tabletScreenOff.value;
    final changing = s.changingTabletScreen.value;
    final ms = s.latencyMs.value;
    final notice = s.notice.value;
    final screenLabel = off
        ? 'remote_tablet_screen_on'.tr
        : 'remote_tablet_screen_off'.tr;
    return RemoteViewModel(
      title: s.activeDevice.value?.model ?? id,
      toolbar: [
        if (streaming)
          RemoteToolbarItem(
            id: 'screen',
            symbol: off ? 'sun.max' : 'moon',
            tooltip: '$screenLabel\n${'remote_tablet_screen_hint'.tr}',
            enabled: !changing,
          ),
        RemoteToolbarItem(
          id: 'latency',
          kind: RemoteItemKind.chip,
          symbol: 'bolt',
          text: '$ms ms',
          tooltip: 'latency_value'.trParams({'ms': '$ms'}),
          color: RemoteChipColor.green,
        ),
        RemoteToolbarItem(
          id: 'reconnect',
          symbol: 'arrow.clockwise',
          tooltip: 'common_reconnect'.tr,
        ),
        RemoteToolbarItem(
          id: 'disconnect',
          symbol: 'xmark.circle',
          tooltip: 'common_disconnect'.tr,
        ),
      ],
      banner: failure != null ? _failureText(failure) : notice?.tr,
      message: !active
          ? RemoteMessage(
              text: 'remote_tile_reconnecting'.tr,
              passThrough: true,
            )
          // Waiting for the tablet's user until the first frame; not when
          // the session noticed a fault on the Mac (no decoder), which the
          // banner says instead: nothing to do on the tablet then.
          : !streaming && notice == null
          ? RemoteMessage(text: 'remote_host_waiting'.tr, passThrough: true)
          : null,
      more: 'remote_window_more'.tr,
      symbol: symbol,
    );
  }

  static String _failureText(String detail) =>
      '${'remote_tablet_screen_failed'.tr}: $detail';

  static Offset _inside(RemotePointer e) =>
      Offset((e.x / e.boxW).clamp(0.0, 1.0), (e.y / e.boxH).clamp(0.0, 1.0));

  /// The session input may go to: the one shown, a tablet the Mac
  /// controls, not ended by the hub.
  HostSession? get _inputSession {
    final s = session;
    if (s == null || s.isRetired || !s.spec.isReverseRemote) return null;
    return s;
  }

  @override
  void pointer(RemotePointer e) {
    if (_disposed) return;
    switch (e.kind) {
      case RemotePointerKind.down:
        _down = _inside(e);
      case RemotePointerKind.move:
        break;
      case RemotePointerKind.cancel:
        _down = null;
      case RemotePointerKind.up:
        final start = _down;
        _down = null;
        if (start == null) return;
        final s = _inputSession;
        if (s == null) return;
        final end = _inside(e);
        if ((end - start).distance < dragThreshold) {
          s.sendRemoteTap(end.dx, end.dy);
        } else {
          s.sendRemoteSwipe(
            start.dx,
            start.dy,
            end.dx,
            end.dy,
            durationMs: swipeMs,
          );
        }
    }
  }

  @override
  void action(String item) {
    if (_disposed) return;
    switch (item) {
      case 'screen':
        unawaited(_toggleScreen());
      case 'reconnect':
        if (session != null) unawaited(_hub.reconnectSession(id));
      case 'disconnect':
        final shown = session != null;
        _closedByOwner = true;
        if (shown) {
          unawaited(_hub.disconnectSession(id, userStopped: true));
        }
        _requestClose();
    }
  }

  /// Turns the tablet's panel off, or back on. One call at a time: a press
  /// while one is under way (this one's, or the remembered choice being
  /// applied as the picture arrived) does nothing.
  Future<void> _toggleScreen() async {
    final s = session;
    if (s == null || s.changingTabletScreen.value) return;
    final error = await s.setTabletScreenOff(!s.tabletScreenOff.value);
    if (error == null || _disposed) return;
    // Which tablet, once there is more than one to mean.
    _failure.value = _hub.remoteSessions.length > 1 ? '$name: $error' : error;
    _failureTimer?.cancel();
    _failureTimer = Timer(failureFor, () => _failure.value = null);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failureTimer?.cancel();
    _failureTimer = null;
    _sessionsWorker?.dispose();
    _sessionsWorker = null;
    unawaited(_observerSub?.cancel());
    _observerSub = null;
    _observer?.close();
    _observer = null;
    unawaited(_renders.close());
    unawaited(_closes.close());
    if (_closedByOwner) return;
    // Only the session this window showed, still the hub's under its key.
    final s = _hub.sessions[id];
    if (s != null && _nativeId != null && s.nativeId == _nativeId) {
      await _hub.disconnectSession(id, userStopped: true);
    }
  }
}
