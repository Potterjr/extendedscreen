import 'dart:async';
import 'package:flutter/widgets.dart';

/// Turns raw single-finger pointer events coming from the tablet into
/// Android-phone-style host actions on the macOS extended display:
///
/// * **Tap** (down → up, no significant movement) → left click at that point.
/// * **Swipe / pan** (one finger dragged past [_tapSlop]) → scroll the window
///   under the finger. Natural direction: content follows the finger.
/// * **Long-press then drag** (hold [_longPress] without moving, then drag) →
///   a real mouse drag (press → move → release), for moving windows,
///   selecting text, dragging sliders, etc.
/// * **Fling** (release while still moving fast) → inertial scrolling that
///   decays over ~0.6 s, like flick-scrolling on a phone.
///
/// Pure Dart — the owner wires the callbacks to the connection manager. Only
/// the first active pointer is tracked; extra fingers are ignored.
class TouchGestureRecognizer {
  TouchGestureRecognizer({
    required this.onClick,
    required this.onMoveCursor,
    required this.onScroll,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
    required this.onLongPressEngaged,
  });

  /// Tap detected — emit a click at the normalized point.
  final void Function(double nx, double ny) onClick;

  /// Park the host cursor at a normalized point so the following scroll events
  /// land on the window the finger is over (macOS scrolls under the cursor).
  final void Function(double nx, double ny) onMoveCursor;

  /// Scroll by the given wheel deltas (already sign- and gain-adjusted).
  final void Function(double scrollDx, double scrollDy) onScroll;

  final void Function(double nx, double ny) onDragStart;
  final void Function(double nx, double ny) onDragMove;
  final void Function(double nx, double ny) onDragEnd;

  /// Fired once when a long-press upgrades to drag mode — used for haptics.
  final VoidCallback onLongPressEngaged;

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

  static const double _velEma = 0.4; // weight of the newest velocity sample
  static const double _velMax = 0.6; // clamp (wheel units / ms)
  static const double _flingStart = 0.06; // min release speed to fling
  static const double _flingStop = 0.02; // speed at which the fling ends
  static const double _flingFriction = 0.95; // per-tick decay (~60 Hz)
  static const Duration _flingTick = Duration(milliseconds: 16);

  // ─── State ────────────────────────────────────────────────────────────────
  int? _pointerId;
  Size _view = Size.zero;
  Offset _startPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  int _lastMoveUs = 0;
  _Mode _mode = _Mode.idle;
  Timer? _longPressTimer;

  Offset _vel = Offset.zero; // wheel units / ms
  Timer? _flingTimer;

  // ─── Pointer entry points ─────────────────────────────────────────────────
  void down(int id, Offset pos, Size view) {
    _cancelFling();
    if (_pointerId != null) return; // already tracking a finger
    _pointerId = id;
    _view = view;
    _startPos = pos;
    _lastPos = pos;
    _lastMoveUs = _nowUs();
    _vel = Offset.zero;
    _mode = _Mode.undecided;
    _longPressTimer = Timer(_longPress, () {
      if (_mode == _Mode.undecided && _pointerId == id) {
        _mode = _Mode.drag;
        onLongPressEngaged();
        onDragStart(_nx(_startPos), _ny(_startPos));
      }
    });
  }

  void move(int id, Offset pos, Size view) {
    if (id != _pointerId) return;
    _view = view;
    final now = _nowUs();
    switch (_mode) {
      case _Mode.undecided:
        if ((pos - _startPos).distance > _tapSlop) {
          _longPressTimer?.cancel();
          _mode = _Mode.scroll;
          // Park the cursor where the finger started so the scroll targets
          // the right window.
          onMoveCursor(_nx(_startPos), _ny(_startPos));
          _emitScroll(pos, now);
        }
      case _Mode.scroll:
        _emitScroll(pos, now);
      case _Mode.drag:
        onDragMove(_nx(pos), _ny(pos));
      case _Mode.idle:
        break;
    }
    _lastPos = pos;
    _lastMoveUs = now;
  }

  void up(int id, Offset pos, Size view) {
    if (id != _pointerId) return;
    _longPressTimer?.cancel();
    switch (_mode) {
      case _Mode.undecided:
        onClick(_nx(pos), _ny(pos)); // released without moving → tap
      case _Mode.scroll:
        _maybeFling();
      case _Mode.drag:
        onDragEnd(_nx(pos), _ny(pos));
      case _Mode.idle:
        break;
    }
    _reset();
  }

  void cancel(int id) {
    if (id != _pointerId) return;
    _longPressTimer?.cancel();
    if (_mode == _Mode.drag) onDragEnd(_nx(_lastPos), _ny(_lastPos));
    _reset();
  }

  void dispose() {
    _longPressTimer?.cancel();
    _cancelFling();
  }

  // ─── Internals ────────────────────────────────────────────────────────────
  void _emitScroll(Offset pos, int now) {
    final d = pos - _lastPos;
    final sdx = _directionSign * d.dx * _scrollGain;
    final sdy = _directionSign * d.dy * _scrollGain;
    onScroll(sdx, sdy);

    final dtMs = (now - _lastMoveUs) / 1000.0;
    if (dtMs > 0) {
      final sample = Offset(sdx / dtMs, sdy / dtMs);
      _vel = _vel * (1 - _velEma) + sample * _velEma;
      final speed = _vel.distance;
      if (speed > _velMax) _vel = _vel * (_velMax / speed);
    }
  }

  void _maybeFling() {
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

  void _reset() {
    _pointerId = null;
    _mode = _Mode.idle;
  }

  int _nowUs() => DateTime.now().microsecondsSinceEpoch;
  double _nx(Offset p) =>
      _view.width <= 0 ? 0 : (p.dx / _view.width).clamp(0.0, 1.0);
  double _ny(Offset p) =>
      _view.height <= 0 ? 0 : (p.dy / _view.height).clamp(0.0, 1.0);
}

enum _Mode { idle, undecided, scroll, drag }
