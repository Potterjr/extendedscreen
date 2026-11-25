import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/drag_streamer.dart';
import 'package:extendedscreen/shared/connection/usbmux.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

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

/// Mac: the view of an iPhone or iPad over USB, in its native window
/// (`IphoneRemoteWindow`). The
/// picture is the phone's own USB screen capture; clicks and drags on it go
/// to the TouchRunner over usbmuxd as taps and swipes. Both are retried
/// every [retryEvery] while missing (a phone plugged in, unlocked, or its
/// runner started later).
///
/// The touch link is opened once the phone is on usbmuxd (its Attached,
/// [IosTouchService.watch]) and the capture has delivered its first frame,
/// whichever comes later: starting a capture takes the phone off usbmuxd
/// for a moment (its USB is re-enumerated), and a link opened before that
/// died with it. Which of the two comes first is not assumed. The tick
/// stays as the fallback (a usbmuxd whose Listen does not work), and it too
/// connects only once a frame has come.
class IphoneRemoteController extends GetxController {
  IphoneRemoteController({
    this.retryEvery = const Duration(seconds: 2),
    this.deviceId,
    DateTime Function()? now,
    bool? probeEnabled,
    this.probeSettle = const Duration(milliseconds: 800),
    bool? liveFinger,
    bool? liveDrag,
  })  : _now = now ?? DateTime.now,
        probeEnabled = probeEnabled ?? probeDefine,
        liveFinger = liveFinger ?? liveFingerDefine,
        _liveDrag = liveDrag;

  /// `--dart-define=IPHONE_PROBE=true`: the felt-latency probe on by
  /// default. Only a default: tests pass [probeEnabled].
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

  /// Whether this window's capture is running (or its start is under way).
  bool get _screenRunning {
    final shown = _shownId;
    return shown != null && screen.isRunning(shown);
  }

  /// The capture device to show (the one whose card on Home opened this
  /// window); the first one listed when it is null or not listed. Touches
  /// still go to the first device usbmuxd lists.
  final String? deviceId;
  final DateTime Function() _now;
  final screen = Get.find<IosScreenChannel>();
  final touch = Get.find<IosTouchService>();

  final screenState = IphoneScreenState.starting.obs;
  Timer? _retry;

  /// The capture device the running capture shows (its uniqueID).
  String? _shownId;

  StreamSubscription<UsbmuxDevice>? _attachSub;

  /// Answered by [IosScreenChannel.prepare]: whether this window's open is
  /// what let CoreMediaIO publish the phones (they appear a moment later,
  /// so an empty first listing is tried again soon, [quickRelist]).
  Future<bool>? _prepared;

  /// The listings tried again soon after a fresh [IosScreenChannel.prepare]
  /// found nothing: every [quickRelist], up to [quickRelists] times.
  static const quickRelist = Duration(milliseconds: 250);
  static const quickRelists = 8;
  int _relists = 0;
  Timer? _relist;

  /// The start under way, if any: the retry tick and [retry] wait for it
  /// instead of starting another. While the Camera prompt is up a start
  /// can wait for the user for as long as they like, and each extra start
  /// built and tore down a capture of its own once they answered.
  Future<void>? _starting;

  /// A gesture of the phone's longest: the runner holds no longer.
  static const maxGesture = 3.0;

  /// The longest a plain drag is replayed over, on the release-time path
  /// (a runner without `seg`, or live drags off in Settings). The phone gets
  /// such a drag only once it is let go on the Mac, and then it takes as
  /// long again, so a slow drag is played back faster (the same path, a
  /// little more fling).
  static const maxDragReplay = 0.3;

  /// Live drags (L3, [DragStreamer]): how soon after a press becomes a drag
  /// its first segment is due (a drag let go sooner is one `aswipe`), the
  /// shortest segment and the longest one's play time, the still time
  /// before each mid-drag lift, and how far back along it each is put down
  /// (the scroll view's own slop). First guesses, to be tuned on the device.
  static const segFirstAfter = Duration(milliseconds: 100);
  static const segMinPoints = 15.0;
  static const segMaxSeconds = 0.12;
  static const segSettle = 0.07;
  static const segLead = 12.0;

  /// Whether drags stream as segments while held: the constructor's
  /// `liveDrag` (tests), else Settings' "Live drags on the iPhone" (on by
  /// default), read at each pointer-down. Only with a runner whose `caps`
  /// list `seg`; any other runner gets the release-time drag.
  final bool? _liveDrag;
  bool get liveDragOn =>
      _liveDrag ??
      (Get.isRegistered<SettingsService>()
          ? Get.find<SettingsService>().iphoneLiveDrag.value
          : true);

  /// Set when the phone did not take the Home button (an older runner).
  final homeFailed = false.obs;

  /// Presses the phone's Home button. Nothing while Home or a system
  /// gesture is still under way ([systemBusy]): a held ⌘1, or clicks in a
  /// row, queued blocking commands on the phone that outlived the Mac's wait
  /// for their answers and dropped the link.
  Future<void> onHome() async {
    if (!canHome || systemBusy) return;
    await _systemCommand(() async {
      homeFailed.value = !await touch.home();
    });
  }

  /// Whether Home or a system gesture is under way (from its call until the
  /// phone has answered it).
  bool systemBusy = false;

  /// [send] as one record in turn ([_newTurn]): after every record sent
  /// before it has played, and before any sent after it (its answer comes
  /// once it has played).
  Future<void> _systemCommand(Future<void> Function() send) async {
    systemBusy = true;
    final turn = _newTurn();
    try {
      await turn.start;
      if (isClosed) return;
      await send();
    } finally {
      turn.end();
      systemBusy = false;
    }
  }

  /// Whether Home can be pressed now: the link is up and the runner has
  /// `home` (with no `caps`, a runner from before them, it is tried). Read
  /// in an `Obx`, it follows the link's state and its caps.
  bool get canHome =>
      touch.state.value == IosTouchState.ready && touch.supports('home');

  /// Whether [gesture] can be sent now: the link is up and the runner's
  /// `caps` list its verb (a runner from before `caps` has none of them).
  bool canSystem(IphoneSystemGesture gesture) =>
      touch.state.value == IosTouchState.ready &&
      touch.supports(gesture.verb);

  /// The system gestures the phone did not take when last sent.
  final systemFailed = <IphoneSystemGesture>{}.obs;

  /// Sends one of the system gestures (the window's ⌘2 to ⌘5 and its
  /// toolbar buttons beside Home). Nothing while [canSystem] is false.
  /// Nothing while one (or Home) is still under way ([systemBusy]).
  Future<void> onSystem(IphoneSystemGesture gesture) async {
    if (!canSystem(gesture) || systemBusy) return;
    await _systemCommand(() async {
      final ok = await touch.systemGesture(gesture);
      if (ok) {
        systemFailed.remove(gesture);
      } else {
        systemFailed.add(gesture);
      }
    });
    // Spotlight goes Home first, and a panel can turn the screen: the cached
    // side is read again (only while the picture is landscape).
    _refreshTurn();
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

  /// Pointers on the picture, each from its down until its command has gone
  /// out (or it was cancelled): no `orient` is sent while any is (it would
  /// share the runner's main queue with the touch). A refresh asked for then
  /// is [_turnDue]. A count, not a flag: a press can begin while the last
  /// one's release still waits for its answer, and that release must not
  /// end the new press's gesture.
  int _openGestures = 0;
  bool _turnDue = false;

  // One record on the phone at a time across gestures, as [DragStreamer]
  // keeps within one drag: each gesture's first record (and Home, and a
  // system gesture) waits for the last turn to end and its record to have
  // played ([_newTurn]). Whether a second record waits for, overlaps or
  // cancels a playing one is the plan's open question E1; quick flicks in a
  // row sent a drag's first segment while the last one's was unanswered.

  /// The last turn taken (null before any).
  _Turn? _lastTurn;

  /// The next turn: it starts once the last one has ended and its last
  /// record has played (a wait only when that is still ahead: no timer
  /// otherwise).
  _Turn _newTurn() {
    final before = _lastTurn;
    final turn = _lastTurn = _Turn(() async {
      if (before == null) return;
      await before.done.future;
      final until = before.playsUntil;
      if (until == null) return;
      final left = until.difference(_now());
      if (left > Duration.zero) await Future<void>.delayed(left);
    }());
    return turn;
  }

  LoggerService? get _log =>
      Get.isRegistered<LoggerService>() ? Get.find<LoggerService>() : null;

  @override
  void onInit() {
    super.onInit();
    if (probeEnabled) _probeSub = screen.probes.listen(_onProbe);
    _frameWorker = ever<Size?>(screen.frameSize, _onFrameSize);
    _attachSub = touch.attachments.listen(_onAttached);
    touch.watch();
    // Before the first listing: the phones appear a moment after it.
    _prepared = screen.prepare();
    unawaited(_tryStart());
    _retry = Timer.periodic(retryEvery, (_) => _tryStart());
  }

  Future<void> _tryStart() =>
      _starting ??= _startOnce().whenComplete(() => _starting = null);

  Future<void> _startOnce() async {
    if (!_screenRunning &&
        screenState.value != IphoneScreenState.permissionDenied) {
      await _startScreen();
    }
    // The window may have closed while the screen started: a touch link
    // opened now would outlive it. Before the first frame the phone may be
    // off usbmuxd still (the capture's start), so the tick waits for one.
    if (isClosed || screen.frameSize.value == null) return;
    if (touch.state.value != IosTouchState.ready) {
      await _connectTouch('tick');
    }
  }

  /// The first frame (a size after none) is half of the connect rule; a
  /// size change is a rotation, which refreshes the cached side.
  void _onFrameSize(Size? size) {
    if (size != null && !_hadFrame) {
      _hadFrame = true;
      if (touch.attached.isNotEmpty) _connectSoon('first frame');
    }
    if (size == null) _hadFrame = false;
    _refreshTurn();
  }

  bool _hadFrame = false;

  /// usbmuxd's Attached, the other half: connects at once if the picture is
  /// already up, else when its first frame comes.
  void _onAttached(UsbmuxDevice d) {
    if (screen.frameSize.value == null) return;
    _connectSoon('usbmux Attached ${d.serial}');
  }

  void _connectSoon(String why) {
    if (isClosed || touch.state.value == IosTouchState.ready) return;
    unawaited(_connectTouch(why));
  }

  Future<void> _connectTouch(String why) async {
    if (!await touch.connect() || isClosed) return;
    // Which capture device is which UDID is not known (the plugin says a
    // uniqueID is not the UDID): written down side by side to find out.
    final udid = touch.udid.value;
    _log?.i('iPhone touches connected ($why): capture uniqueID=$_shownId '
        'usbmux UDID=$udid');
    if (udid != null) unawaited(screen.notePairing(udid, device: _shownId));
  }

  Future<void> _startScreen() async {
    final fresh = await (_prepared ?? Future.value(false));
    if (isClosed) return;
    final devices = await screen.listDevices();
    if (isClosed) return;
    touch.setCaptureDevices(devices.length);
    if (devices.isEmpty) {
      screenState.value = IphoneScreenState.noDevice;
      // Freshly allowed, the phones are published a moment from now:
      // listed again soon rather than at the next tick.
      if (fresh && _relists < quickRelists) {
        _relists++;
        _relist?.cancel();
        _relist = Timer(quickRelist, () => unawaited(_tryStart()));
      }
      return;
    }
    try {
      final device =
          devices.firstWhereOrNull((d) => d.id == deviceId) ?? devices.first;
      _shownId = device.id;
      await screen.start(device.id);
      if (isClosed) {
        await screen.stop(device.id);
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
    if (!_screenRunning) {
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
    if (_openGestures > 0) {
      _turnDue = true;
      return;
    }
    _turnDue = false;
    unawaited(touch.refreshTurn());
  }

  /// A gesture has gone out (or was dropped): the refresh it held back, and
  /// the one after every landscape gesture (it catches a flip from one
  /// landscape side to the other, which keeps the frame's size). Only once
  /// no other press is open: one that began meanwhile holds it back.
  void _gestureDone() {
    if (_openGestures > 0) _openGestures--;
    if (_openGestures > 0) {
      if (_landscape) _turnDue = true;
      return;
    }
    if (_turnDue || _landscape) _refreshTurn();
  }

  /// With the probe on, arms a felt probe before anything is sent to the
  /// phone (the channel message leaves in this call, so its time is taken
  /// before the gesture's command). [t0Us] is the input event's time (µs of
  /// the Mac's uptime) when the pointer came from the native window: the
  /// probe then starts there, before the trip to Dart.
  void _armProbe({int? t0Us}) {
    if (!probeEnabled || scripting.value) return;
    final id = ++_probeId;
    _feltIds.add(id);
    unawaited(screen
        .markProbe(id, device: _shownId, t0Us: t0Us)
        .then((armed) {
      if (!armed) _feltIds.remove(id);
    }));
  }

  void _onProbe(ProbeResult r) {
    // Another device's capture: its probe ids are not this window's.
    if (r.device != null && _shownId != null && r.device != _shownId) return;
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
        if (!await screen.markProbe(id, device: _shownId)) {
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

  // ---- The pointer on the picture --------------------------------------
  //
  // One state machine fed by the native window's pointer packets
  // (`IphoneRemoteWindow` calls onPointerDown, Move, Up, Cancel): no
  // gesture arena and no 500 ms kLongPressTimeout. XCTest lifts the finger
  // at the end of every record, so each gesture is one record:
  // - a press that stays within [slopFor] and is let go is a tap (`atap`,
  //   sent at pointer-up);
  // - one that moves past it is a drag: with a runner that has `seg` (and
  //   live drags on), streamed while held as segments ([DragStreamer], the
  //   first one [segFirstAfter] after it became a drag; let go sooner it is
  //   one `aswipe`); otherwise replayed once let go (`aswipe` over at most
  //   [maxDragReplay]);
  // - one held still for [earlyHoldAfter] is a long press sent at once,
  //   while the button is still held: a press of [earlyHoldSeconds] in
  //   place. Nothing more of that press is sent: moving it drags nothing,
  //   and letting go sends nothing;
  // - with Shift down at pointer-down, nothing goes out early: the press is
  //   replayed at release as today's long press, held as long as it was
  //   held, then dragged (moving a Home Screen icon), one record.
  // With [liveFinger] (plan unit E1, experimental) the finger is put down
  // at pointer-down instead (`pdown`), moved (`pmove`) and lifted (`pup`);
  // a runner that refuses `pdown` turns it off for the window's life.

  /// How long a still press waits before its long press goes out.
  static const earlyHoldAfter = Duration(milliseconds: 350);

  /// The early long press's length on the phone: one record, kept short so
  /// that nothing waits behind it for long (whether a second record waits
  /// for a playing one is E1's question). Too short for a few targets (the
  /// Home Screen's jiggle mode): those take the Shift path.
  static const earlyHoldSeconds = 0.7;

  /// The capture's pixels per point of the phone, taken as an iPhone's 3x
  /// (an iPad, 2x, gets a slop of about 27 of its points instead of 18).
  static const phoneScale = 3.0;

  /// How far (in [box] pixels) a press may move and still be a tap:
  /// [kTouchSlop] of the phone's points, scaled to the picture on the Mac.
  /// A mouse would otherwise get Flutter's precise-pointer slop (about
  /// 2 px), which turned a jittery click into a short swipe.
  static double slopFor(Size box, Size frame) {
    final points = frame.shortestSide / phoneScale;
    if (points <= 0) return kTouchSlop;
    return kTouchSlop * box.shortestSide / points;
  }

  /// `--dart-define=IPHONE_LIVE_FINGER=true`: [liveFinger] on by default.
  static const liveFingerDefine = bool.fromEnvironment('IPHONE_LIVE_FINGER');

  /// Whether pointers are sent as a finger left down across records
  /// (E1); off until the spike shows the runner can.
  final bool liveFinger;

  /// Set when the runner refused `pdown` (every runner released so far).
  bool _liveRefused = false;

  _Press? _press;

  /// How long an `atap` plays on the phone after its answer: its record is
  /// a 10 ms press, handed over before the answer, so a record after it
  /// waits for nothing more than that answer (taps in a row stay as quick
  /// as they were).
  static const tapPlays = 0.0;

  /// [press]'s turn ([_newTurn]), taken at its first record: what that
  /// record waits for.
  Future<void> _turnOf(_Press press) => (press.turn ??= _newTurn()).start;

  /// [press]'s records have gone out; the last one plays [plays] seconds
  /// more (its answer came as it was handed over). Then the next gesture's
  /// record may go.
  void _endTurn(_Press press, [double plays = 0]) {
    press.turn?.end(plays <= 0
        ? null
        : _now().add(Duration(microseconds: (plays * 1e6).round())));
  }

  /// A pointer went down on the picture ([box] is the picture's size).
  /// [shift]: Shift was held, which selects the release-time long press.
  /// [eventUs]: the input event's time (µs of the Mac's uptime), from the
  /// native window; used only as the probe's start (0 or null: none).
  void onPointerDown(Offset p, Size box, {bool shift = false, int? eventUs}) {
    if (_press != null) return; // a second pointer: the first one leads
    _lastDown = (p, box);
    _armProbe(t0Us: eventUs != null && eventUs > 0 ? eventUs : null);
    final frame = screen.frameSize.value;
    if (frame == null) return;
    final press = _press = _Press(
        at: p, last: p, box: box, down: _now(), shift: shift,
        slop: slopFor(box, frame),
        // A runner without fast synthesis plays each `seg` the blocking
        // XCUICoordinate way (about 700 ms): its drags go at release.
        streams: !shift && liveDragOn && touch.fast && touch.supports('seg'));
    _openGestures++;
    if (liveFinger && !_liveRefused) {
      press.live = true;
      final n = _map(p, box)!;
      press.liveDown = _turnOf(press)
          .then((_) => touch.fingerDown(n.x, n.y))
          .then((ok) {
        if (!ok && !_liveRefused) {
          _liveRefused = true;
          _log?.w('iPhone touches: the runner does not take "pdown"; '
              'whole-gesture records from now on');
        }
        return ok;
      });
      return;
    }
    if (!shift) {
      press.holdTimer = Timer(earlyHoldAfter, () => _earlyHold(press));
    }
  }

  /// The pointer moved: past the slop the press is a drag.
  void onPointerMove(Offset p) {
    final press = _press;
    if (press == null) return;
    press.last = p;
    if (press.movedAt == null && (p - press.at).distance > press.slop) {
      press.movedAt = _now();
      press.holdTimer?.cancel();
      if (press.streams && !press.live && !press.held) _startStream(press);
    }
    if (press.live && press.movedAt != null) _liveMove(press);
    final n = press.streamer == null ? null : _map(p, press.box);
    if (n != null) press.streamer!.move(n);
  }

  /// The phone's screen in points, portrait: the runner's pong, else the
  /// capture's frame at [phoneScale].
  Size _phonePoints(Size frame) {
    final reported = touch.screenPoints.value?.split('x');
    final w = double.tryParse(reported?.elementAtOrNull(0) ?? '');
    final h = double.tryParse(reported?.elementAtOrNull(1) ?? '');
    if (w != null && h != null && w > 0 && h > 0) return Size(w, h);
    return Size(frame.shortestSide / phoneScale, frame.longestSide / phoneScale);
  }

  void _startStream(_Press press) {
    final frame = screen.frameSize.value;
    final from = _map(press.at, press.box);
    if (frame == null || from == null) return;
    press.streamer = DragStreamer(
      from: from,
      points: _phonePoints(frame),
      now: _now,
      firstAfter: segFirstAfter,
      minPoints: segMinPoints,
      maxSeconds: segMaxSeconds,
      settle: segSettle,
      lead: segLead,
      send: (a, b, seconds, settle, lead) async {
        await _turnOf(press);
        return touch.segment(a.x, a.y, b.x, b.y, seconds,
            settle: settle, lead: lead);
      },
    );
  }

  /// The pointer was let go: the gesture's record goes out (none after an
  /// early long press).
  Future<void> onPointerUp(Offset p) async {
    final press = _press;
    if (press == null) return;
    _press = null;
    press.holdTimer?.cancel();
    press.last = p;
    final released = _now();
    // The early long press ends its own turn once it has played.
    if (press.held) {
      _gestureDone();
      return;
    }
    // Taken now, before any await: a press that begins meanwhile comes after.
    final turn = _turnOf(press);
    var plays = 0.0;
    try {
      if (press.live && await press.liveDown!) {
        await press.liveMoving;
        final n = _map(p, press.box);
        if (n != null) await touch.fingerUp(n.x, n.y);
        return;
      }
      final streamer = press.streamer;
      final end = _map(p, press.box);
      if (streamer != null && end != null) {
        switch (await streamer.release(end)) {
          case DragRelease.done:
            return;
          case DragRelease.failed:
            // The rest of the drag, from where the segments stopped, the
            // release-time way.
            final from = streamer.lastSent;
            plays = _seconds(released.difference(press.movedAt ?? press.down))
                .clamp(0.05, maxDragReplay);
            await touch.swipe(from.x, from.y, end.x, end.y, plays);
            return;
          case DragRelease.notStreamed:
            break; // let go before the first segment: today's aswipe
        }
      }
      await turn;
      plays = await _sendAtRelease(press, released);
    } finally {
      _endTurn(press, plays);
      _gestureDone();
    }
  }

  /// The pointer was cancelled: nothing is sent, but a finger left down
  /// (E1) is lifted.
  Future<void> onPointerCancel() async {
    final press = _press;
    if (press == null) return;
    _press = null;
    press.holdTimer?.cancel();
    press.streamer?.cancel();
    // The early long press ends its own turn once it has played.
    if (press.held) {
      _gestureDone();
      return;
    }
    try {
      if (press.live && await press.liveDown!) {
        await press.liveMoving;
        final n = _map(press.last, press.box);
        if (n != null) await touch.fingerUp(n.x, n.y);
      }
      // A segment still in flight plays out before the next gesture's.
      await press.streamer?.idle;
    } finally {
      _endTurn(press);
      _gestureDone();
    }
  }

  /// The still press's long press, while the button is still held.
  void _earlyHold(_Press press) {
    if (!identical(_press, press) || press.movedAt != null) return;
    final n = _map(press.at, press.box);
    if (n == null) return;
    press.held = true;
    unawaited(_turnOf(press)
        .then((_) => touch.swipe(n.x, n.y, n.x, n.y, earlyHoldSeconds))
        .whenComplete(() => _endTurn(press, earlyHoldSeconds)));
  }

  /// The newest point of a live finger, one `pmove` in flight at a time.
  void _liveMove(_Press press) {
    if (press.liveMoving != null) {
      press.moveDue = true;
      return;
    }
    press.liveMoving = () async {
      do {
        press.moveDue = false;
        if (!await press.liveDown!) return;
        final n = _map(press.last, press.box);
        if (n != null) await touch.fingerMove(n.x, n.y);
      } while (press.moveDue);
    }()
        .whenComplete(() => press.liveMoving = null);
  }

  /// The record of a press let go at [end] (a live one the runner refused
  /// too, as if it had never been live); answers how long it plays on the
  /// phone after its answer.
  Future<double> _sendAtRelease(_Press press, DateTime end) async {
    final a = _map(press.at, press.box);
    final b = _map(press.last, press.box);
    if (a == null || b == null) return 0;
    final total = _seconds(end.difference(press.down));
    final moved = press.movedAt;
    final longEnough = total >= _seconds(earlyHoldAfter);
    if (moved == null) {
      if (press.shift && longEnough) {
        final s = total.clamp(0.05, maxGesture);
        await touch.swipe(a.x, a.y, a.x, a.y, s);
        return s;
      }
      await touch.tap(a.x, a.y);
      return tapPlays;
    }
    final hold = _seconds(moved.difference(press.down));
    if (press.shift && hold >= _seconds(earlyHoldAfter)) {
      final h = hold.clamp(0.05, maxGesture);
      final drag = _seconds(end.difference(moved))
          .clamp(0.05, (maxGesture - h).clamp(0.05, maxGesture));
      await touch.swipe(a.x, a.y, b.x, b.y, drag, hold: h);
      return h + drag;
    }
    // A drag, replayed over the time it took (up to [maxDragReplay]).
    final s = total.clamp(0.05, maxDragReplay);
    await touch.swipe(a.x, a.y, b.x, b.y, s);
    return s;
  }

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;

  @override
  void onClose() {
    _press?.holdTimer?.cancel();
    _press?.streamer?.cancel();
    _press = null;
    _retry?.cancel();
    _relist?.cancel();
    _frameWorker?.dispose();
    unawaited(_attachSub?.cancel());
    touch.unwatch();
    unawaited(_probeSub?.cancel());
    for (final w in _scriptWaits.values) {
      if (!w.isCompleted) w.complete(null);
    }
    _scriptWaits.clear();
    // Only this window's device: another device's capture goes on.
    final shown = _shownId;
    if (shown != null) unawaited(screen.stop(shown));
    touch.disconnect();
    super.onClose();
  }
}

/// One pointer on the picture, from its down to its up or cancel.
class _Press {
  _Press({
    required this.at,
    required this.last,
    required this.box,
    required this.down,
    required this.shift,
    required this.slop,
    this.streams = false,
  });

  /// Where it went down, where it is now, and the picture's size then.
  final Offset at;
  Offset last;
  final Size box;
  final DateTime down;
  final bool shift;
  final double slop;

  /// Whether a drag of this press streams as segments while held (L3), and
  /// the streamer once it has become one.
  final bool streams;
  DragStreamer? streamer;

  /// When it first moved past [slop]; null while it is a tap or a hold.
  DateTime? movedAt;

  /// The early long press's timer, and whether that press went out.
  Timer? holdTimer;
  bool held = false;

  /// Its place in the one-record-at-a-time order, from its first record.
  _Turn? turn;

  /// E1: the finger was put down on the phone ([liveDown] answers whether
  /// the runner took it), and the `pmove` in flight, if any.
  bool live = false;
  Future<bool>? liveDown;
  Future<void>? liveMoving;
  bool moveDue = false;
}

/// One gesture's place in the order records go to the phone: it [start]s
/// once the turn before it has ended, and [end]s when its records have gone
/// out (at most once), the last one playing until [playsUntil].
class _Turn {
  _Turn(this.start);

  final Future<void> start;
  final done = Completer<void>();
  DateTime? playsUntil;

  void end([DateTime? until]) {
    if (done.isCompleted) return;
    playsUntil = until;
    done.complete();
  }
}
