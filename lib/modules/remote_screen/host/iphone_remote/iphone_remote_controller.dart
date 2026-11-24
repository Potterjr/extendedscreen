import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// What the iPhone view shows about the picture.
enum IphoneScreenState { starting, noDevice, permissionDenied, failed, live }

/// The scripted latency trials (see [IphoneRemoteController.runProbe]).
enum ProbeScript {
  /// `atap` at the last point clicked on the picture (a blank row), else
  /// the middle of the screen.
  tap,

  /// `aswipe` of [IphoneRemoteController.probeSwipeDistance], up and down
  /// in turn, in the middle of the screen.
  swipe,
}

/// Mac: the view of an iPhone or iPad over USB (`/iphone-remote`). The
/// picture is the phone's own USB screen capture; clicks and drags on it go
/// to the TouchRunner over usbmuxd as taps and swipes. Both are retried
/// every [retryEvery] while missing (a phone plugged in, unlocked, or its
/// runner started later).
class IphoneRemoteController extends GetxController {
  IphoneRemoteController({
    this.retryEvery = const Duration(seconds: 2),
    this.deviceId,
    DateTime Function()? now,
    bool? probeEnabled,
    this.probeSettle = const Duration(milliseconds: 800),
  })  : _now = now ?? DateTime.now,
        probeEnabled = probeEnabled ?? probeDefine;

  /// `--dart-define=IPHONE_PROBE=true`: the felt-latency probe on by
  /// default. Only a default: tests pass [probeEnabled] (and the view's).
  static const probeDefine = bool.fromEnvironment('IPHONE_PROBE');

  /// Whether pointer-downs on the picture are probed (pointer-down to the
  /// first capture frame that changed) and the scripted trials can run.
  final bool probeEnabled;

  /// How long a scripted trial waits before it arms its probe, for the
  /// phone's screen to settle after the trial before it.
  final Duration probeSettle;

  /// A scripted swipe's length (normalized) and duration (seconds).
  static const probeSwipeDistance = 0.15;
  static const probeSwipeSeconds = 0.2;

  /// Trials in a scripted run.
  static const probeTrials = 50;

  final Duration retryEvery;

  /// The capture device to show (the one whose card on Home opened this
  /// page); the first one listed when it is null or not listed. Touches
  /// still go to the first device usbmuxd lists.
  final String? deviceId;
  final DateTime Function() _now;
  final screen = Get.find<IosScreenChannel>();
  final touch = Get.find<IosTouchService>();

  final screenState = IphoneScreenState.starting.obs;
  Timer? _retry;

  /// The start under way, if any: the retry tick and [retry] wait for it
  /// instead of starting another. While the Camera prompt is up a start
  /// can wait for the user for as long as they like, and each extra start
  /// built and tore down a capture of its own once they answered.
  Future<void>? _starting;

  /// A gesture of the phone's longest: the runner holds no longer.
  static const maxGesture = 3.0;

  /// The longest a plain drag is replayed over. The phone gets a drag only
  /// once it is let go on the Mac, and then it takes as long again, so a
  /// slow drag is played back faster (the same path, a little more fling).
  static const maxDragReplay = 0.3;

  /// Set when the phone did not take the Home button (an older runner).
  final homeFailed = false.obs;

  /// Presses the phone's Home button.
  Future<void> onHome() async {
    homeFailed.value = !await touch.home();
  }

  /// The felt probes' last [ProbeSummary.window] times.
  final felt = ProbeSummary();

  /// The felt probe's last time; null before one or when it gave up.
  final lastFeltMs = RxnDouble();

  /// Bumped on every probe answer and scripted trial, for the overlay.
  final probeRevision = 0.obs;

  /// The scripted run under way (or last finished): its kind, trials done
  /// and times.
  final scripting = false.obs;
  ProbeScript? scriptKind;
  int scriptDone = 0;
  ProbeSummary? script;

  int _probeId = 0;
  final _feltIds = <int>{};
  final _scriptWaits = <int, Completer<double?>>{};
  StreamSubscription<ProbeResult>? _probeSub;

  /// Where the last pointer went down on the picture, and the box it was in.
  (Offset, Size)? _lastDown;

  /// Follows the capture's frame size: a rotation changes it, so each
  /// change to a landscape frame asks which way the phone is turned.
  Worker? _frameWorker;

  /// A drag or long press under way, from its start until its command has
  /// gone out: no `orient` is sent meanwhile (it would share the runner's
  /// main queue with the touch). A refresh asked for then is [_turnDue].
  bool _gestureOpen = false;
  bool _turnDue = false;

  LoggerService? get _log =>
      Get.isRegistered<LoggerService>() ? Get.find<LoggerService>() : null;

  @override
  void onInit() {
    super.onInit();
    if (probeEnabled) _probeSub = screen.probes.listen(_onProbe);
    _frameWorker = ever<Size?>(screen.frameSize, (_) => _refreshTurn());
    unawaited(_tryStart());
    _retry = Timer.periodic(retryEvery, (_) => _tryStart());
  }

  Future<void> _tryStart() =>
      _starting ??= _startOnce().whenComplete(() => _starting = null);

  Future<void> _startOnce() async {
    if (screen.textureId.value == null &&
        screenState.value != IphoneScreenState.permissionDenied) {
      await _startScreen();
    }
    // The page may have closed while the screen started: a touch link
    // opened now would outlive it.
    if (isClosed) return;
    if (touch.state.value != IosTouchState.ready) {
      await touch.connect();
    }
  }

  Future<void> _startScreen() async {
    final devices = await screen.listDevices();
    if (isClosed) return;
    if (devices.isEmpty) {
      screenState.value = IphoneScreenState.noDevice;
      return;
    }
    try {
      final device =
          devices.firstWhereOrNull((d) => d.id == deviceId) ?? devices.first;
      await screen.start(device.id);
      if (isClosed) {
        await screen.stop();
        return;
      }
      screenState.value = IphoneScreenState.live;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') return; // a newer start took its place
      screenState.value = switch (e.code) {
        'PERMISSION_DENIED' => IphoneScreenState.permissionDenied,
        'NO_DEVICE' => IphoneScreenState.noDevice,
        _ => IphoneScreenState.failed,
      };
    }
  }

  /// Asks again after the user granted the Camera permission.
  Future<void> retry() async {
    await _starting;
    if (isClosed) return;
    // The start it waited for may have shown the picture already.
    if (screen.textureId.value == null) {
      screenState.value = IphoneScreenState.starting;
    }
    await _tryStart();
  }

  /// [p] (in a box of [box]) normalized to the phone's screen in portrait,
  /// as the runner takes it. A landscape frame is the phone turned: the
  /// picture is rotated a quarter turn from the portrait screen the runner
  /// addresses, one way or the other as [turned] says (the frame's size
  /// alone cannot tell which).
  static ({double x, double y}) toPortrait(Offset p, Size box, Size frame,
      {IosTurn turned = IosTurn.topLeft}) {
    final u = (p.dx / box.width).clamp(0.0, 1.0);
    final v = (p.dy / box.height).clamp(0.0, 1.0);
    if (frame.height >= frame.width) return (x: u, y: v);
    return switch (turned) {
      // The portrait screen's top is at the frame's left.
      IosTurn.topLeft => (x: 1 - v, y: u),
      // ...or at its right.
      IosTurn.topRight => (x: v, y: 1 - u),
    };
  }

  /// [p] mapped as the phone was last seen held ([IosTouchService.lastTurn],
  /// cached: no round trip on a touch's way); null with no picture. After
  /// a flip from one landscape side to the other (same frame size) the
  /// first gesture can still go to the old side; the refresh after it puts
  /// the next one right.
  ({double x, double y})? _map(Offset p, Size box) {
    final frame = screen.frameSize.value;
    if (frame == null) return null;
    return toPortrait(p, box, frame, turned: touch.lastTurn.value);
  }

  bool get _landscape {
    final frame = screen.frameSize.value;
    return frame != null && frame.width > frame.height;
  }

  /// Refreshes the cached side while the picture is landscape (a portrait
  /// one maps without it), unless a drag or long press is under way, in
  /// which case it is sent once that has gone out.
  void _refreshTurn() {
    if (!_landscape) return;
    if (_gestureOpen) {
      _turnDue = true;
      return;
    }
    _turnDue = false;
    unawaited(touch.refreshTurn());
  }

  /// A gesture has gone out (or was dropped): the refresh it held back, and
  /// the one after every landscape gesture (it catches a flip from one
  /// landscape side to the other, which keeps the frame's size).
  void _gestureDone() {
    _gestureOpen = false;
    if (_turnDue || _landscape) _refreshTurn();
  }

  /// A pointer went down on the picture: with the probe on, arms a felt
  /// probe before anything is sent to the phone (the channel message leaves
  /// in this call, so its time is taken before the gesture's command).
  void onPointerDown(Offset p, Size box) {
    _lastDown = (p, box);
    if (!probeEnabled || scripting.value) return;
    final id = ++_probeId;
    _feltIds.add(id);
    unawaited(screen.markProbe(id).then((armed) {
      if (!armed) _feltIds.remove(id);
    }));
  }

  void _onProbe(ProbeResult r) {
    if (_feltIds.remove(r.id)) {
      lastFeltMs.value = r.ms;
      if (r.ms != null) felt.add(r.ms!);
      _log?.i('iPhone probe felt id=${r.id} '
          'change=${r.ms?.toStringAsFixed(1) ?? 'none'} ms ($felt)');
      probeRevision.value++;
      return;
    }
    final wait = _scriptWaits.remove(r.id);
    if (wait != null && !wait.isCompleted) wait.complete(r.ms);
  }

  /// Runs [trials] scripted trials of [kind], each armed just before its
  /// command, one after the other, and logs their p50/p90. Null when the
  /// probe is off or a run is under way.
  Future<ProbeSummary?> runProbe(ProbeScript kind,
      {int trials = probeTrials}) async {
    if (!probeEnabled || scripting.value) return null;
    scripting.value = true;
    final summary = ProbeSummary(window: trials);
    script = summary;
    scriptKind = kind;
    scriptDone = 0;
    probeRevision.value++;
    try {
      final down = _lastDown;
      final at = kind == ProbeScript.tap && down != null
          ? _map(down.$1, down.$2)
          : null;
      final tapAt = at ?? (x: 0.5, y: 0.5);
      for (var i = 0; i < trials && !isClosed; i++) {
        await Future<void>.delayed(probeSettle);
        if (isClosed) break;
        final id = ++_probeId;
        final wait = _scriptWaits[id] = Completer<double?>();
        if (!await screen.markProbe(id)) {
          _scriptWaits.remove(id);
        } else {
          if (kind == ProbeScript.tap) {
            await touch.tap(tapAt.x, tapAt.y);
          } else {
            const h = probeSwipeDistance / 2;
            final up = i.isEven;
            await touch.swipe(0.5, up ? 0.5 + h : 0.5 - h, 0.5,
                up ? 0.5 - h : 0.5 + h, probeSwipeSeconds);
          }
          final ms = await wait.future
              .timeout(const Duration(seconds: 3), onTimeout: () => null);
          _scriptWaits.remove(id);
          if (ms != null) summary.add(ms);
        }
        scriptDone = i + 1;
        probeRevision.value++;
      }
      _log?.i('iPhone probe scripted ${kind.name} trials=$scriptDone $summary');
      return summary;
    } finally {
      scripting.value = false;
      probeRevision.value++;
    }
  }

  Future<void> onTap(Offset p, Size box) async {
    final n = _map(p, box);
    if (n == null) return;
    await touch.tap(n.x, n.y);
    if (!_gestureOpen) _gestureDone();
  }

  Offset? _pressAt;
  DateTime? _pressDown;
  DateTime? _pressMoved;

  /// A press held past the long-press delay ([held] is that delay: the
  /// finger has been down that long already). Nothing is sent until it
  /// ends, when its whole length and any drag after it are known.
  void onLongPressStart(Offset p, {Duration held = kLongPressTimeout}) {
    _pressAt = p;
    _pressDown = _now().subtract(held);
    _pressMoved = null;
    _gestureOpen = true;
  }

  /// The held finger moved: from here on the press is a drag.
  void onLongPressMove() {
    if (_pressAt == null) return;
    _pressMoved ??= _now();
  }

  /// The press as the phone gets it: held where it went down for as long as
  /// it was, then dragged to where it was let go (a held icon dragged).
  Future<void> onLongPressEnd(Offset p, Size box) async {
    final from = _pressAt;
    final down = _pressDown;
    final moved = _pressMoved;
    _pressAt = null;
    _pressDown = null;
    _pressMoved = null;
    if (from == null || down == null) return;
    try {
      final end = _now();
      final total = _seconds(end.difference(down));
      final a = _map(from, box);
      final b = _map(p, box);
      if (a == null || b == null) return;
      if (moved == null) {
        await touch.swipe(a.x, a.y, a.x, a.y, total.clamp(0.05, maxGesture));
        return;
      }
      final hold = _seconds(moved.difference(down)).clamp(0.05, maxGesture);
      final drag = _seconds(end.difference(moved))
          .clamp(0.05, (maxGesture - hold).clamp(0.05, maxGesture));
      await touch.swipe(a.x, a.y, b.x, b.y, drag, hold: hold);
    } finally {
      _gestureDone();
    }
  }

  /// The press was not a long press after all, or its pointer was
  /// cancelled: nothing is sent.
  void onLongPressCancel() {
    if (_pressAt == null) return;
    _pressAt = null;
    _pressDown = null;
    _pressMoved = null;
    if (_panStart == null) _gestureDone();
  }

  Offset? _panStart;
  DateTime? _panStartAt;

  void onPanStart(Offset p) {
    _panStart = p;
    _panStartAt = _now();
    _gestureOpen = true;
  }

  /// The drag's pointer was cancelled: nothing is sent.
  void onPanCancel() {
    if (_panStart == null) return;
    _panStart = null;
    _panStartAt = null;
    if (_pressAt == null) _gestureDone();
  }

  /// A drag, replayed over the time it took (up to [maxDragReplay]).
  Future<void> onPanEnd(Offset p, Size box) async {
    final start = _panStart;
    final at = _panStartAt;
    _panStart = null;
    _panStartAt = null;
    if (start == null || at == null) return;
    try {
      final a = _map(start, box);
      final b = _map(p, box);
      if (a == null || b == null) return;
      final seconds = _seconds(_now().difference(at));
      await touch.swipe(
          a.x, a.y, b.x, b.y, seconds.clamp(0.05, maxDragReplay));
    } finally {
      _gestureDone();
    }
  }

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;

  @override
  void onClose() {
    _retry?.cancel();
    _frameWorker?.dispose();
    unawaited(_probeSub?.cancel());
    for (final w in _scriptWaits.values) {
      if (!w.isCompleted) w.complete(null);
    }
    _scriptWaits.clear();
    unawaited(screen.stop());
    touch.disconnect();
    super.onClose();
  }
}
