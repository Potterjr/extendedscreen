import 'dart:collection';
import 'dart:math' as math;

/// Fits the encoder's bitrate to what a Wi-Fi link carries right now
/// (host only; USB has bandwidth to spare and is never adapted).
///
/// **What it looks at.** The queue: bytes this Mac has handed to the link
/// that the tablet has not acknowledged yet ([SocketService.unackedBytes]),
/// taken at its low point between samples (the host reads it before writing
/// each frame), less what any link holds in flight however fast it is: one
/// round trip of stream ([sample]'s `inFlight`, from the heartbeat's lowest
/// recent round trip). It is judged by the smallest value over the last
/// [window]. A link that keeps up empties its queue between frames, so that
/// minimum stays near zero however large a keyframe burst; a link slower than
/// the stream never empties it, and the minimum climbs: latency the tablet
/// sees (the idea of CoDel's minimum sojourn time).
///
/// **Down.**
/// - A standing queue over [target] cuts the rate to 85% of what the link
///   delivered over the window (at most 85% of the current rate, at least
///   half of it), one step per [_settle].
/// - A frame the socket refused ([SocketService.sendFrame] returned false:
///   the tablet freezes until a keyframe) cuts at once: to 60%, or to 85% of
///   what the link delivered if that is less (at least 40%) when the window
///   measured the link rather than a stall.
/// - A window in which the link carried next to nothing for 200 ms or more
///   ([_stalled]: a scan, a roam, a stall of a second or two) is not judged
///   at all. It says nothing about what the link carries once it is back,
///   and the frames are already being dropped until it is. Cutting on it
///   used to take the rate to the floor during an outage and keep it there
///   for half a minute.
///
/// **Up.** Only while the stream is using its budget ([_loaded], judged over
/// [_loadSpan], longer than the keyframe interval): an idle screen sends
/// little more than a keyframe a second, so an empty queue then proves
/// nothing, and
/// climbing on it put the preset back over a slow link just in time for the
/// next scroll to freeze. With the queue empty since [_holdAfterCut] after the
/// last cut, the rate climbs 15% a second up to just below where the link
/// last gave out (remembered for [_memory]), then 5% every 2 s, never past
/// [ceiling]. Where it gave out is what the link delivered over the window
/// that cut; for a cut that measured nothing (a refusal over what may be a
/// stall) it is the rate that was running, so a stall costs a few seconds
/// of climbing, not half a minute. Once the slow climb has passed that point
/// by 15% with the link still keeping up, it was a dip, and the climb is fast
/// again.
///
/// Never below [floor], never above [ceiling]. Pure arithmetic over the
/// samples it is given, so it can be tested without sockets or timers.
class BitrateAdapter {
  BitrateAdapter({required this.ceiling, int? floor})
      : floor = math.min(ceiling, floor ?? math.max(2000000, ceiling ~/ 8)),
        _bitrate = ceiling;

  /// The preset's bitrate: where the stream starts and the most it gets.
  final int ceiling;

  /// The least it gets. A link that can't carry this freezes now and then
  /// (the socket refuses frames until a keyframe), which beats a picture
  /// too coarse to read.
  final int floor;

  /// Over this long the smallest queue is the standing one.
  static const window = Duration(milliseconds: 400);

  /// A standing queue longer than this, at the current rate, is congestion.
  static const target = Duration(milliseconds: 30);

  /// A standing queue this short means the link has room.
  static const _healthy = Duration(milliseconds: 10);

  static const _settle = Duration(milliseconds: 800);
  static const _holdAfterCut = Duration(seconds: 2);
  static const _memory = Duration(seconds: 30);

  /// Delivered less than this share of the rate over a window: the link
  /// stalled, and the window is not judged.
  static const _stalled = 0.15;

  /// Delivered at least this share of the rate over [_loadSpan]: the rate is
  /// what limits the picture, and an empty queue is room to grow.
  static const _loaded = 0.6;

  /// Longer than the encoder's keyframe interval (one a second): an idle
  /// screen still sends a keyframe of a quarter second of stream or so each
  /// second, enough to fill most of a 400 ms window on its own.
  static const _loadSpan = Duration(milliseconds: 1200);

  int _bitrate;
  int get bitrate => _bitrate;

  final _samples = ListQueue<_Sample>();
  // Delivery over [_loadSpan], kept across cuts.
  final _load = ListQueue<_Sample>();
  bool _refused = false;
  int? _lastCutUs;
  int? _lastRaiseUs;
  int? _congestedBitrate;

  /// The socket refused a frame since the last sample.
  void frameRefused() => _refused = true;

  /// One look at the link, [nowUs] being a monotonic clock in microseconds.
  /// [queuedBytes] is what was waiting to be acknowledged at its lowest since
  /// the last sample; [deliveredBytes] a running total of what the link has
  /// carried (anything that only grows); [inFlight] what a link that keeps
  /// up holds anyway, its round trip. Returns the new bitrate when it
  /// changed, else null.
  int? sample({
    required int nowUs,
    required int queuedBytes,
    required int deliveredBytes,
    Duration inFlight = Duration.zero,
  }) {
    _samples.addLast(_Sample(nowUs, queuedBytes, deliveredBytes));
    while (_samples.length > 2 &&
        nowUs - _samples.elementAt(1).us >= window.inMicroseconds) {
      _samples.removeFirst();
    }
    _load.addLast(_Sample(nowUs, 0, deliveredBytes));
    while (_load.length > 2 &&
        nowUs - _load.elementAt(1).us >= _loadSpan.inMicroseconds) {
      _load.removeFirst();
    }

    final refused = _refused;
    _refused = false;
    final lastCut = _lastCutUs;
    if (lastCut != null && nowUs - lastCut < _settle.inMicroseconds) {
      return null;
    }

    final first = _samples.first;
    final spanUs = nowUs - first.us;
    final full = spanUs >= window.inMicroseconds;
    final delivered = full
        ? (deliveredBytes - first.delivered) * 8 * 1000000 ~/ spanUs
        : null;
    final stalled = _stalledWithin();

    // A refusal over a window that measured the link (the link is slower
    // than the stream) goes as deep as the link; one that may be a stall
    // only to 60%, and leaves the rate to climb back to as it was.
    if (refused) {
      return _cut(nowUs, stalled ? null : delivered,
          factor: 0.6, atLeast: stalled || delivered == null ? 0.6 : 0.4);
    }

    if (delivered == null || stalled) return null;

    // Bytes the current rate sends in [d].
    int bytesIn(Duration d) => _bitrate ~/ 8 * d.inMicroseconds ~/ 1000000;
    final standing =
        _samples.map((s) => s.queued).reduce(math.min) - bytesIn(inFlight);
    if (standing > bytesIn(target)) {
      return _cut(nowUs, delivered, factor: 0.85, atLeast: 0.5);
    }
    // Room to grow: the queue emptied in this window and is not building up
    // again right now (a minimum from early in the window says nothing about
    // a queue that has grown since), with the stream using its budget.
    if (standing < bytesIn(_healthy) &&
        queuedBytes - bytesIn(inFlight) < bytesIn(target) &&
        _isLoaded(nowUs, deliveredBytes)) {
      return _raise(nowUs);
    }
    return null;
  }

  /// The stream used at least [_loaded] of its rate over [_loadSpan].
  bool _isLoaded(int nowUs, int deliveredBytes) {
    final first = _load.first;
    final spanUs = nowUs - first.us;
    if (spanUs < _loadSpan.inMicroseconds) return false;
    final bits = (deliveredBytes - first.delivered) * 8;
    return bits * 1000000 >= _bitrate * _loaded * spanUs;
  }

  /// Whether the link carried next to nothing for [_stallSpan] anywhere in the
  /// window. Not just over the whole window: the first sample after an
  /// outage shows the backlog draining, which lifts the window's average
  /// over the bar while its queue is still the outage's.
  bool _stalledWithin() {
    final samples = _samples.toList();
    for (var i = 0; i < samples.length; i++) {
      for (var j = i + 1; j < samples.length; j++) {
        final spanUs = samples[j].us - samples[i].us;
        if (spanUs < _stallSpan.inMicroseconds) continue;
        final bits = (samples[j].delivered - samples[i].delivered) * 8;
        if (bits * 1000000 < _bitrate * _stalled * spanUs) return true;
        break;
      }
    }
    return false;
  }

  static const _stallSpan = Duration(milliseconds: 200);

  /// To [factor] of the current rate, or 85% of what the link [delivered] if
  /// that is less, but never below [atLeast] of the current rate in one step.
  /// A link that really is that slow gets there in a few steps, one per
  /// [_settle].
  int? _cut(int nowUs, int? delivered,
      {required double factor, required double atLeast}) {
    var next = (_bitrate * factor).round();
    if (delivered != null) next = math.min(next, (delivered * 0.85).round());
    next = math.max(next, (_bitrate * atLeast).round()).clamp(floor, ceiling);

    // Where the link gives out, to climb back to quickly and past slowly:
    // what it delivered, when the window measured it. Otherwise (a refusal
    // that may be a stall, after which the link is back as it was) the rate
    // that was running, and never lower than what was remembered.
    final previous = _congestedBitrate;
    final lastCut = _lastCutUs;
    final remembered = previous != null &&
        lastCut != null &&
        nowUs - lastCut < _memory.inMicroseconds;
    _congestedBitrate = delivered ??
        (remembered ? math.max(previous, _bitrate) : _bitrate);

    _lastCutUs = nowUs;
    _lastRaiseUs = null;
    _samples.clear();
    return _set(next);
  }

  int? _raise(int nowUs) {
    if (_bitrate >= ceiling) return null;
    final lastCut = _lastCutUs;
    if (lastCut != null && nowUs - lastCut < _holdAfterCut.inMicroseconds) {
      return null;
    }
    var congested = _congestedBitrate;
    // Probed well past where the link gave out without it giving out again:
    // that was a dip, and the link has more now. Climb fast again.
    if (congested != null && _bitrate > congested * 1.15) {
      _congestedBitrate = congested = null;
    }
    final remembered = congested != null &&
        lastCut != null &&
        nowUs - lastCut < _memory.inMicroseconds;
    // Fast back up to just below where the link last gave out, slowly past.
    final knee = remembered ? (congested * 0.95).round() : ceiling;
    final fast = _bitrate < knee;
    final every = fast ? const Duration(seconds: 1) : const Duration(seconds: 2);
    final lastRaise = _lastRaiseUs;
    if (lastRaise != null && nowUs - lastRaise < every.inMicroseconds) {
      return null;
    }
    final next = fast
        ? math.min((_bitrate * 1.15).round(), knee)
        : (_bitrate * 1.05).round();
    _lastRaiseUs = nowUs;
    return _set(next.clamp(floor, ceiling));
  }

  int? _set(int next) {
    if (next == _bitrate) return null;
    _bitrate = next;
    return next;
  }
}

class _Sample {
  const _Sample(this.us, this.queued, this.delivered);
  final int us;
  final int queued;
  final int delivered;
}
