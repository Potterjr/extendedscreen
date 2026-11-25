import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

/// A point normalized to the phone's screen in portrait (0..1), as the
/// runner takes it.
typedef PortraitPoint = ({double x, double y});

/// Sends one segment from [from] to [to] over [seconds], held still
/// [settle] seconds before the lift, put down [lead] points back along it;
/// answers once the runner has played it (true) or did not take it (false).
typedef SegmentSender = Future<bool> Function(PortraitPoint from,
    PortraitPoint to, double seconds, double settle, double lead);

/// How a streamed drag ended ([DragStreamer.release]).
enum DragRelease {
  /// Let go before the first segment was due: nothing went out, and the
  /// caller sends the whole drag as today's single `aswipe`.
  notStreamed,

  /// Every segment went out, the last one included.
  done,

  /// A segment was not taken (no link, `err`): nothing more went out, and
  /// the rest, from [DragStreamer.lastSent], is the caller's to send.
  failed,
}

/// A drag on the iPhone picture sent to the phone while the mouse button is
/// still held (plan unit L3), as segments: XCTest lifts the finger at the
/// end of every record, so each segment is a touch of its own (`seg`).
///
/// Pure Dart, fed by the controller's Listener from the moment the press
/// moved past its slop; the clock is injected, the pacing uses [Timer]s (a
/// widget test's fake clock moves both).
/// - Keeps the last point sent ([lastSent]) and the movement since; the
///   first segment is due [firstAfter] after the press became a drag, so a
///   drag let go sooner is exactly today's single `aswipe`.
/// - A segment is at least [minPoints] of the phone's points: shorter
///   movement is merged into the next one.
/// - One segment in flight at a time: the next is due once the runner has
///   answered the last one and its seconds + settle have passed, whichever
///   is later; movement meanwhile is merged.
/// - Each segment plays over the time its movement took, at most
///   [maxSeconds] (played faster than that, it never falls further behind),
///   is put down [lead] points back along its direction (a scroll view only
///   starts after about 10 pt, which a plain segment would lose), and holds
///   [settle] still before its lift, so the content does not fling.
/// - On release the last segment carries the release velocity and no
///   settle, so a flick still flings; a pointer that was still at release
///   (under [flingAbove]) keeps the settle, so a drag that stopped does not
///   glide.
class DragStreamer {
  DragStreamer({
    required PortraitPoint from,
    required this.points,
    required this.send,
    required DateTime Function() now,
    this.firstAfter = const Duration(milliseconds: 100),
    this.minPoints = 15,
    this.maxSeconds = 0.12,
    this.settle = 0.07,
    this.lead = 12,
    this.flingAbove = 150,
    this.velocityWindow = const Duration(milliseconds: 100),
  })  : _now = now,
        lastSent = from,
        _current = from {
    final t = now();
    _started = t;
    _lastTaken = t;
    _samples.add((t, from));
    _timer = Timer(firstAfter, _pump);
  }

  /// The phone's screen in points, portrait: distances and speeds are
  /// measured in these.
  final Size points;
  final SegmentSender send;
  final DateTime Function() _now;
  final Duration firstAfter;
  final double minPoints;
  final double maxSeconds;
  final double settle;
  final double lead;

  /// Points per second: a release faster than this flings.
  final double flingAbove;

  /// The movement the release velocity is measured over.
  final Duration velocityWindow;

  /// The end of the last segment sent (the drag's start before any).
  PortraitPoint lastSent;
  PortraitPoint _current;
  late final DateTime _started;
  late DateTime _lastTaken;
  final _samples = <(DateTime, PortraitPoint)>[];
  Timer? _timer;
  Future<void>? _inFlight;
  bool _ended = false;
  bool _failed = false;

  /// Segments sent so far (the last one included, once released).
  int segments = 0;

  /// Whether a segment has gone out.
  bool get streaming => segments > 0;

  double _distance(PortraitPoint a, PortraitPoint b) {
    final dx = (a.x - b.x) * points.width;
    final dy = (a.y - b.y) * points.height;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;

  /// The pointer is at [p] now.
  void move(PortraitPoint p) {
    if (_ended) return;
    _current = p;
    final t = _now();
    _samples.add((t, p));
    // A little more than the velocity window is kept.
    final keepFrom = t.subtract(velocityWindow * 3);
    while (_samples.length > 2 && _samples.first.$1.isBefore(keepFrom)) {
      _samples.removeAt(0);
    }
    _pump();
  }

  /// Sends the next segment if one is due.
  void _pump() {
    if (_ended || _failed || _inFlight != null) return;
    final t = _now();
    if (t.difference(_started) < firstAfter) return;
    if (_distance(lastSent, _current) < minPoints) return;
    final seconds =
        _seconds(t.difference(_lastTaken)).clamp(0.03, maxSeconds).toDouble();
    _lastTaken = t;
    _sendOne(_current, seconds, settle);
  }

  void _sendOne(PortraitPoint to, double seconds, double settleFor) {
    final from = lastSent;
    lastSent = to;
    segments++;
    final reply = send(from, to, seconds, settleFor, lead)
        .catchError((Object _) => false)
        .then((ok) {
      if (!ok) {
        _failed = true;
        lastSent = from;
      }
    });
    final paced = Future<void>.delayed(
        Duration(microseconds: ((seconds + settleFor) * 1e6).round()));
    _inFlight = Future.wait([reply, paced]).then((_) {
      _inFlight = null;
      _pump();
    });
  }

  /// Points per second over the last [velocityWindow] up to [t], and the
  /// movement it was measured over (from, to).
  (double, PortraitPoint, PortraitPoint) _velocity(DateTime t) {
    final since = t.subtract(velocityWindow);
    final (t0, p0) = _samples.firstWhere((s) => !s.$1.isBefore(since),
        orElse: () => _samples.last);
    final (t1, p1) = _samples.last;
    final dt = _seconds(t1.difference(t0));
    // No movement inside the window: the pointer was still.
    if (dt <= 0) return (0, p0, p1);
    return (_distance(p0, p1) / dt, p0, p1);
  }

  /// [minPoints] on from [at] in the direction from [a] to [b], kept on the
  /// screen; null when that leaves under 2 points (at an edge).
  PortraitPoint? _onward(PortraitPoint at, PortraitPoint a, PortraitPoint b) {
    final dx = (b.x - a.x) * points.width;
    final dy = (b.y - a.y) * points.height;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len <= 0) return null;
    final to = (
      x: (at.x + dx / len * minPoints / points.width).clamp(0.0, 1.0),
      y: (at.y + dy / len * minPoints / points.height).clamp(0.0, 1.0),
    );
    return _distance(at, to) < 2 ? null : to;
  }

  /// Let go at [p]: the last segment goes out once the one in flight is
  /// done. [DragRelease.notStreamed] when nothing had gone out yet.
  Future<DragRelease> release(PortraitPoint p) async {
    // Ended first: the release point goes out as the last segment, never
    // as a mid-drag one.
    _ended = true;
    _timer?.cancel();
    final t = _now();
    _current = p;
    _samples.add((t, p));
    if (!streaming) return DragRelease.notStreamed;
    final (v, va, vb) = _velocity(t);
    while (_inFlight != null) {
      await _inFlight;
    }
    if (_failed) return DragRelease.failed;
    final remainder = _distance(lastSent, p);
    final flings = v >= flingAbove;
    if (remainder < 2) {
      // Nothing left to move: a drag that stopped is done. A flick let go
      // just as a segment went out (that one kept its settle) still flings:
      // a short segment onward, in the direction it was moving.
      final onward = flings ? _onward(lastSent, va, vb) : null;
      if (onward == null) return DragRelease.done;
      _sendOne(onward,
          ((minPoints + lead) / v).clamp(0.02, maxSeconds).toDouble(), 0);
      while (_inFlight != null) {
        await _inFlight;
      }
      return _failed ? DragRelease.failed : DragRelease.done;
    }
    final seconds = flings
        // The finger moves lead + remainder: at the release velocity.
        ? ((remainder + lead) / v).clamp(0.02, maxSeconds).toDouble()
        : _seconds(_now().difference(_lastTaken))
            .clamp(0.03, maxSeconds)
            .toDouble();
    _sendOne(p, seconds, flings ? 0 : settle);
    while (_inFlight != null) {
      await _inFlight;
    }
    return _failed ? DragRelease.failed : DragRelease.done;
  }

  /// Completes once no segment is in flight (after [cancel], nothing more
  /// goes out, so then it is the end of the last one).
  Future<void> get idle async {
    while (_inFlight != null) {
      await _inFlight;
    }
  }

  /// Cancelled: nothing more goes out (what is in flight still plays).
  void cancel() {
    _ended = true;
    _timer?.cancel();
  }
}
