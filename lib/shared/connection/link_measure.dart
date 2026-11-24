import 'dart:math' as math;

/// P0's Wi-Fi measurement (docs/ios-client-design.md, verdict item 8), on
/// the client: `--dart-define=ES_MEASURE=true`. A const, so a build without
/// it contains no measuring at all.
const measureLink = bool.fromEnvironment('ES_MEASURE');

/// Records every heartbeat round trip and every FRAME_DATA arrival, and
/// writes them out through [sink]:
///
///  - `rtt <µs>` for each round trip;
///  - `fr <arrival interval µs> <send interval µs>` for each frame after the
///    first of a link: the gap since the previous frame on this device's
///    monotonic clock, and the gap between the two packets' timestamps (the
///    Mac's clock, set as it sends). Frames are written in batches of up to
///    [batchBytes] per line, once a second, so 120 frames a second are not
///    120 native calls;
///  - every [window], a `summary` line: round trips p50/p95/p99 and frame
///    jitter p95 (|arrival interval − send interval|), with the counts.
///
/// Pure: the clock and the sink are injected. Nothing here touches the
/// link; the client calls it from its packet handler.
class LinkMeasure {
  LinkMeasure({
    required this.sink,
    int Function()? clockUs,
    this.window = const Duration(seconds: 30),
    this.flushEvery = const Duration(seconds: 1),
    this.batchBytes = 900,
  }) : _clockUs = clockUs ?? _monotonic;

  static final _stopwatch = Stopwatch()..start();
  static int _monotonic() => _stopwatch.elapsedMicroseconds;

  final void Function(String line) sink;
  final int Function() _clockUs;
  final Duration window;
  final Duration flushEvery;

  /// Kept under os_log's limit for one message.
  final int batchBytes;

  final List<int> _rtts = [];
  final List<int> _jitters = [];
  int _frames = 0;
  int? _windowStart;
  int? _lastFlush;
  int? _prevArrival;
  int? _prevSent;
  final StringBuffer _batch = StringBuffer();

  /// A new link: the next frame starts a new pair of intervals (a gap
  /// across a reconnect is not jitter).
  void linkStarted() {
    _prevArrival = null;
    _prevSent = null;
  }

  void roundTrip(int rttUs) {
    final now = _clockUs();
    _rtts.add(rttUs);
    _flushFrames();
    sink('rtt $rttUs');
    _maybeSummarise(now);
  }

  /// A FRAME_DATA packet arrived; [sentUs] is its header timestamp.
  void frame(int sentUs) {
    final now = _clockUs();
    _frames++;
    final prevArrival = _prevArrival;
    final prevSent = _prevSent;
    _prevArrival = now;
    _prevSent = sentUs;
    if (prevArrival != null && prevSent != null) {
      final arrived = now - prevArrival;
      final sent = sentUs - prevSent;
      _jitters.add((arrived - sent).abs());
      final entry = '$arrived/$sent ';
      if (_batch.length + entry.length > batchBytes) _flushFrames();
      _batch.write(entry);
    }
    _lastFlush ??= now;
    if (now - _lastFlush! >= flushEvery.inMicroseconds) _flushFrames();
    _maybeSummarise(now);
  }

  void _flushFrames() {
    _lastFlush = _clockUs();
    if (_batch.isEmpty) return;
    sink('fr ${_batch.toString().trimRight()}');
    _batch.clear();
  }

  void _maybeSummarise(int now) {
    final start = _windowStart ??= now;
    if (now - start < window.inMicroseconds) return;
    _flushFrames();
    sink(summary());
    _rtts.clear();
    _jitters.clear();
    _frames = 0;
    _windowStart = now;
  }

  /// The current window's figures, in milliseconds.
  String summary() {
    String ms(int? us) => us == null ? '-' : (us / 1000).toStringAsFixed(1);
    return 'summary rtt n=${_rtts.length} '
        'p50=${ms(percentile(_rtts, 50))} '
        'p95=${ms(percentile(_rtts, 95))} '
        'p99=${ms(percentile(_rtts, 99))} ms; '
        'frames n=$_frames jitter p95=${ms(percentile(_jitters, 95))} '
        'max=${ms(_jitters.isEmpty ? null : _jitters.reduce(math.max))} ms';
  }

  /// The nearest-rank percentile [p] (0 to 100) of [values]; null for none.
  static int? percentile(List<int> values, num p) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}
