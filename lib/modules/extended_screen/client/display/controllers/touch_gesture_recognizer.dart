import 'dart:async';
import 'package:flutter/widgets.dart';

/// Turns raw multi-touch pointer events coming from the tablet into
/// Android-phone-style host actions on the macOS extended display:
///
/// * **Tap** (down → up, no significant movement) → left click at that point.
/// * **Swipe / pan** (one finger dragged past [_tapSlop]) → scroll the window
///   under the finger. Natural direction: content follows the finger.
/// * **Long-press then drag** (hold [_longPress] without moving, then drag) →
///   a real mouse drag (press → move → release), for moving windows,
///   selecting text, dragging sliders, etc. Extra fingers that touch down
///   during a drag are ignored: the drag keeps following the first finger and
///   releases when that finger lifts.
/// * **Fling** (release while still moving fast) → inertial scrolling that
///   decays over ~0.6 s, like flick-scrolling on a phone. A finger that rests
///   for [_flingMaxIdle] before lifting doesn't fling.
/// * **Pinch** (two fingers spread/close) → zoom in/out, emitted as ⌘+scroll
///   centred on the pinch point (browsers, Maps, Preview, editors, …).
///
/// Pure Dart — the owner wires the callbacks to the connection manager.
class TouchGestureRecognizer {
  TouchGestureRecognizer({
    required this.onClick,
    required this.onMoveCursor,
    required this.onScroll,
    required this.onZoom,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
    required this.onLongPressEngaged,
    int Function()? nowUs,
  }) : _nowUs = nowUs ?? _wallClockUs;

  /// Tap detected — emit a click at the normalized point.
  final void Function(double nx, double ny) onClick;

  /// Park the host cursor at a normalized point so the following scroll/zoom
  /// events land on the window under the finger (macOS scrolls/zooms there).
  final void Function(double nx, double ny) onMoveCursor;

  /// Scroll by the given wheel deltas (already sign- and gain-adjusted).
  final void Function(double scrollDx, double scrollDy) onScroll;

  /// Zoom by the given amount, emitted by the owner as a ⌘+scroll. Positive =
  /// zoom in (fingers spreading apart).
  final void Function(double zoomDelta) onZoom;

  final void Function(double nx, double ny) onDragStart;
  final void Function(double nx, double ny) onDragMove;

  /// Fired exactly once for each [onDragStart], including when the drag's
  /// finger is cancelled or the recognizer is disposed mid-drag.
  final void Function(double nx, double ny) onDragEnd;

  /// Fired once when a long-press upgrades to drag mode — used for haptics.
  final VoidCallback onLongPressEngaged;

  /// Current time in microseconds, used for scroll velocity. Defaults to the
  /// wall clock; tests inject a fake one.
  final int Function() _nowUs;

  // ─── Tunables ─────────────────────────────────────────────────────────────
  /// Finger travel (logical px) beyond which a press is treated as a swipe.
  static const double _tapSlop = 12.0;

  /// Hold-still time that upgrades a press into a drag.
  static const Duration _longPress = Duration(milliseconds: 400);

  /// Finger px → wheel units. Swift multiplies the wheel unit by 10 to reach
  /// device pixels, so ~0.12 keeps scrolling close to 1:1 with the finger.
  static const double _scrollGain = 0.12;

  /// Scroll direction. `1` = natural (content follows the finger). Flip to
  /// `-1` if scrolling feels inverted — the final feel also depends on the
  /// Mac's "Natural scrolling" system setting.
  static const double _directionSign = 1;

  /// Pinch-distance px → ⌘+scroll wheel units. Controls zoom sensitivity.
  static const double _zoomGain = 0.06;

  /// Zoom direction. `1` = fingers spreading apart zooms in. Flip to `-1` if
  /// pinch zoom feels inverted.
  static const double _zoomSign = 1;

  static const double _velEma = 0.4; // weight of the newest velocity sample
  static const double _velMax = 0.6; // clamp (wheel units / ms)
  static const double _flingStart = 0.06; // min release speed to fling
  static const double _flingStop = 0.02; // speed at which the fling ends
  static const double _flingFriction = 0.95; // per-tick decay (~60 Hz)
  static const Duration _flingTick = Duration(milliseconds: 16);

  /// A finger that hasn't moved for this long before lifting has stopped, so
  /// the velocity left over from its last move must not launch a fling. A
  /// move after a pause this long restarts the velocity estimate.
  static const Duration _flingMaxIdle = Duration(milliseconds: 100);

  // ─── State ────────────────────────────────────────────────────────────────
  // Insertion-ordered (Dart Map) so "the first two fingers" are stable.
  final Map<int, Offset> _pointers = {};
  int? _primaryId;
  Size _view = Size.zero;

  // Single-finger tracking.
  Offset _startPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  int _lastMoveUs = 0;
  _Mode _mode = _Mode.idle;
  Timer? _longPressTimer;

  // True between onDragStart and onDragEnd, i.e. while the host's mouse
  // button is held down.
  bool _dragOpen = false;

  // Pinch tracking.
  double _lastDist = 0;

  // Fling.
  Offset _vel = Offset.zero; // wheel units / ms
  Timer? _flingTimer;

  // ─── Pointer entry points ─────────────────────────────────────────────────
  void down(int id, Offset pos, Size view) {
    _cancelFling();
    _view = view;
    final wasEmpty = _pointers.isEmpty;
    _pointers[id] = pos;

    if (wasEmpty) {
      _primaryId = id;
      _startPos = pos;
      _lastPos = pos;
      _lastMoveUs = _nowUs();
      _vel = Offset.zero;
      _mode = _Mode.undecided;
      _longPressTimer = Timer(_longPress, () {
        if (_mode == _Mode.undecided && _primaryId == id) {
          _mode = _Mode.drag;
          onLongPressEngaged();
          _dragOpen = true;
          onDragStart(_nx(_startPos), _ny(_startPos));
        }
      });
      return;
    }

    // A second finger during an in-progress single-finger swipe/tap → pinch.
    // Drag / already-pinching / spent gestures ignore extra fingers.
    if (_mode == _Mode.undecided || _mode == _Mode.scroll) {
      if (_pointers.length >= 2) _beginPinch();
    }
  }

  void move(int id, Offset pos, Size view) {
    if (!_pointers.containsKey(id)) return;
    _view = view;
    _pointers[id] = pos;
    final now = _nowUs();

    switch (_mode) {
      case _Mode.pinch:
        _emitPinch();
      case _Mode.undecided:
        if (id == _primaryId && (pos - _startPos).distance > _tapSlop) {
          _longPressTimer?.cancel();
          _mode = _Mode.scroll;
          onMoveCursor(_nx(_startPos), _ny(_startPos));
          _emitScroll(pos, now);
        }
      case _Mode.scroll:
        if (id == _primaryId) _emitScroll(pos, now);
      case _Mode.drag:
        if (id == _primaryId) onDragMove(_nx(pos), _ny(pos));
      case _Mode.spent:
      case _Mode.idle:
        break;
    }
    if (id == _primaryId) {
      _lastPos = pos;
      _lastMoveUs = now;
    }
  }

  void up(int id, Offset pos, Size view) {
    if (!_pointers.containsKey(id)) return;
    final wasPrimary = id == _primaryId;
    _pointers.remove(id);
    _longPressTimer?.cancel();

    switch (_mode) {
      case _Mode.undecided:
        if (wasPrimary) onClick(_nx(pos), _ny(pos)); // released without moving
      case _Mode.scroll:
        if (wasPrimary) _maybeFling();
      case _Mode.drag:
        if (wasPrimary) _endDrag(pos);
      case _Mode.pinch:
      case _Mode.spent:
      case _Mode.idle:
        break;
    }

    _afterPointerLeft(wasPrimary);
  }

  void cancel(int id) {
    if (!_pointers.containsKey(id)) return;
    final wasPrimary = id == _primaryId;
    _pointers.remove(id);
    _longPressTimer?.cancel();
    if (_mode == _Mode.drag && wasPrimary) _endDrag(_lastPos);
    _afterPointerLeft(wasPrimary);
  }

  /// Releases a drag still held when the owner goes away mid-gesture.
  void dispose() {
    _longPressTimer?.cancel();
    _cancelFling();
    _reset();
  }

  // Any remaining fingers must lift before a new gesture can start, so
  // lifting one finger of a pinch doesn't snap back into single-finger scroll.
  // The exception is an extra finger leaving a drag: the drag belongs to the
  // primary finger, which is still down and still dragging.
  void _afterPointerLeft(bool wasPrimary) {
    if (_pointers.isEmpty) {
      _reset();
    } else if (wasPrimary || _mode != _Mode.drag) {
      _mode = _Mode.spent;
    }
  }

  // ─── Drag ─────────────────────────────────────────────────────────────────
  /// Sends the drag's mouse-up. Every path that ends a drag goes through
  /// here, so the host gets exactly one release per [onDragStart].
  void _endDrag(Offset pos) {
    if (!_dragOpen) return;
    _dragOpen = false;
    onDragEnd(_nx(pos), _ny(pos));
  }

  // ─── Scroll ───────────────────────────────────────────────────────────────
  void _emitScroll(Offset pos, int now) {
    final d = pos - _lastPos;
    final sdx = _directionSign * d.dx * _scrollGain;
    final sdy = _directionSign * d.dy * _scrollGain;
    onScroll(sdx, sdy);

    final dtMs = (now - _lastMoveUs) / 1000.0;
    if (dtMs > 0) {
      final sample = Offset(sdx / dtMs, sdy / dtMs);
      // After a pause the old velocity is stale, so the first move restarts
      // the estimate instead of blending into it. Otherwise one lift-off
      // micro-move after a rest would only shrink the stale speed a little
      // and still pass the idle check in _maybeFling.
      _vel = now - _lastMoveUs > _flingMaxIdle.inMicroseconds
          ? sample
          : _vel * (1 - _velEma) + sample * _velEma;
      final speed = _vel.distance;
      if (speed > _velMax) _vel = _vel * (_velMax / speed);
    }
  }

  void _maybeFling() {
    // _vel only changes on a move, so after a pause it is stale: the finger
    // stopped, then lifted.
    if (_nowUs() - _lastMoveUs > _flingMaxIdle.inMicroseconds) return;
    if (_vel.distance < _flingStart) return;
    _flingTimer = Timer.periodic(_flingTick, (_) {
      _vel = _vel * _flingFriction;
      if (_vel.distance < _flingStop) {
        _cancelFling();
        return;
      }
      final ms = _flingTick.inMilliseconds.toDouble();
      onScroll(_vel.dx * ms, _vel.dy * ms);
    });
  }

  void _cancelFling() {
    _flingTimer?.cancel();
    _flingTimer = null;
  }

  // ─── Pinch / zoom ─────────────────────────────────────────────────────────
  void _beginPinch() {
    _longPressTimer?.cancel();
    _cancelFling();
    _mode = _Mode.pinch;
    final (a, b) = _firstTwo();
    _lastDist = (a - b).distance;
    final c = (a + b) / 2;
    onMoveCursor(_nx(c), _ny(c));
  }

  void _emitPinch() {
    if (_pointers.length < 2) return;
    final (a, b) = _firstTwo();
    final dist = (a - b).distance;
    final delta = dist - _lastDist;
    _lastDist = dist;
    if (delta == 0) return;
    final c = (a + b) / 2;
    onMoveCursor(_nx(c), _ny(c)); // keep the zoom centred on the pinch point
    onZoom(_zoomSign * delta * _zoomGain);
  }

  (Offset, Offset) _firstTwo() {
    final it = _pointers.values.iterator;
    it.moveNext();
    final a = it.current;
    it.moveNext();
    final b = it.current;
    return (a, b);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  void _reset() {
    // Safety net: never leave the host's mouse button held down. A normal
    // release already cleared _dragOpen, so this sends no second mouse-up.
    _endDrag(_lastPos);
    _pointers.clear();
    _primaryId = null;
    _mode = _Mode.idle;
  }

  static int _wallClockUs() => DateTime.now().microsecondsSinceEpoch;

  double _nx(Offset p) =>
      _view.width <= 0 ? 0 : (p.dx / _view.width).clamp(0.0, 1.0);
  double _ny(Offset p) =>
      _view.height <= 0 ? 0 : (p.dy / _view.height).clamp(0.0, 1.0);
}

enum _Mode { idle, undecided, scroll, drag, pinch, spent }
