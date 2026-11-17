import 'package:flutter_test/flutter_test.dart';

import 'package:extendedscreen/shared/connection/bitrate_adapter.dart';

const _mbps = 1000000;

/// Plays a link to [adapter] the way the host does: one sample every 50 ms.
class _Link {
  _Link(this.adapter);

  final BitrateAdapter adapter;
  int nowUs = 0;
  int delivered = 0;

  /// Every rate the adapter switched to, with when.
  final changes = <({int atMs, int bitrate})>[];

  /// [duration] of samples. [queued] says what is waiting to be acknowledged
  /// at sample i (counted from 0 for this call); [deliveredBps] how fast the
  /// link carries data meanwhile, by default exactly the stream's rate (an
  /// encoder using all of its budget on a link that keeps up).
  void run(
    Duration duration, {
    required int Function(int i) queued,
    int Function(int i)? deliveredBps,
    bool Function(int i)? refusedAt,
    Duration inFlight = Duration.zero,
  }) {
    final samples = duration.inMilliseconds ~/ 50;
    for (var i = 0; i < samples; i++) {
      nowUs += 50000;
      delivered += (deliveredBps?.call(i) ?? adapter.bitrate) ~/ 8 ~/ 20;
      if (refusedAt?.call(i) ?? false) adapter.frameRefused();
      final next = adapter.sample(
        nowUs: nowUs,
        queuedBytes: queued(i),
        deliveredBytes: delivered,
        inFlight: inFlight,
      );
      if (next != null) changes.add((atMs: nowUs ~/ 1000, bitrate: next));
    }
  }

  /// Bytes the adapter's current rate sends in [ms].
  int msOfStream(int ms) => adapter.bitrate ~/ 8 * ms ~/ 1000;

  // [simulate]'s link: what is queued, and whether frames are being dropped
  // until it has drained (the host's resync).
  int backlog = 0;
  bool resyncing = false;
  int refusals = 0;

  /// A link that carries [capacityBps], fed by an encoder at the adapter's
  /// rate, with the host's behaviour around it: the kernel holds 400 ms of
  /// stream (the host's send buffer), and once a frame has also waited
  /// 120 ms here it is refused, after which nothing is sent until the queue
  /// has drained. With [keyframe], a keyframe worth that much stream once a
  /// second, the rest of the second's budget spread over the other frames.
  /// [idle]: the encoder uses next to nothing of its budget beyond the
  /// keyframe, as on a still screen.
  void simulate(Duration duration,
      {required int capacityBps, Duration? keyframe, bool idle = false}) {
    final samples = duration.inMilliseconds ~/ 50;
    for (var i = 0; i < samples; i++) {
      nowUs += 50000;
      final perSecond = adapter.bitrate ~/ 8;
      final buffer = (perSecond * 4 ~/ 10).clamp(64 * 1024, 2 * 1024 * 1024);
      final key = _sinceKey++ % 20 == 0;
      final keyBytes = keyframe == null
          ? 0
          : perSecond * keyframe.inMicroseconds ~/ 1000000;
      final rest = idle ? perSecond ~/ 50 : perSecond - keyBytes;
      final output = (key ? keyBytes : 0) + rest ~/ 20;
      if (resyncing && backlog == 0) {
        resyncing = false;
        _sinceKey = 0; // resumes from a keyframe
      }
      if (!resyncing) {
        if (backlog > buffer + msOfStream(120)) {
          resyncing = true;
          refusals++;
          adapter.frameRefused();
        } else {
          backlog += output;
        }
      }
      final carried = capacityBps ~/ 8 ~/ 20;
      final taken = carried < backlog ? carried : backlog;
      backlog -= taken;
      delivered += taken;
      final next = adapter.sample(
          nowUs: nowUs, queuedBytes: backlog, deliveredBytes: delivered);
      if (next != null) changes.add((atMs: nowUs ~/ 1000, bitrate: next));
    }
  }

  int _sinceKey = 0;
}

void main() {
  test('starts at the preset and keeps it on a link that keeps up, however '
      'large a keyframe or a short stall', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    expect(link.adapter.bitrate, 40 * _mbps);
    link.run(
      const Duration(seconds: 20),
      // A frame or two in flight, a keyframe burst every second, and now
      // and then a quarter-second Wi-Fi stall with the queue piling up.
      queued: (i) => i % 100 >= 40 && i % 100 < 45
          ? link.msOfStream(250)
          : i % 20 == 0
              ? link.msOfStream(120)
              : link.msOfStream(5),
    );
    expect(link.changes, isEmpty);
    expect(link.adapter.bitrate, 40 * _mbps);
  });

  test('what any link holds in flight is not a queue: a long round trip '
      'cuts nothing', () {
    // 60 fps over a link with a 40 ms round trip: two or three frames are
    // always on their way, though the link carries everything sent.
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    int inFlight(int i) => link.msOfStream(i.isEven ? 40 : 50);
    link.run(const Duration(seconds: 20),
        queued: inFlight, inFlight: const Duration(milliseconds: 40));
    expect(link.changes, isEmpty);

    // Counted as a queue, the same link would be cut again and again.
    final naive = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    naive.run(const Duration(seconds: 5), queued: (i) => naive.msOfStream(45));
    expect(naive.changes, isNotEmpty);
  });

  test('a standing queue cuts the rate towards what the link delivers, at '
      'most halving it in one step', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    // The link carries 12 Mbps and never empties its queue.
    link.run(const Duration(seconds: 3),
        queued: (_) => 400 * 1024, deliveredBps: (_) => 12 * _mbps);

    expect(link.changes.first.bitrate, 20 * _mbps,
        reason: '85% of 12 Mbps is less than half of 40: one step halves');
    expect(link.changes.first.atMs, lessThanOrEqualTo(500),
        reason: 'judged as soon as one window is full');
    expect(link.changes[1].bitrate, (12 * _mbps * 0.85).round(),
        reason: 'the next step lands just under what the link carries');
    // One step per settle period, never faster.
    for (var i = 1; i < link.changes.length; i++) {
      expect(link.changes[i].atMs - link.changes[i - 1].atMs,
          greaterThanOrEqualTo(800));
    }
  });

  test('a refused frame cuts to 60% at once, and nothing more is cut while '
      'the backlog drains', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    link.run(const Duration(milliseconds: 100), queued: (_) => 0);
    link.run(const Duration(milliseconds: 700),
        queued: (_) => 600 * 1024, refusedAt: (_) => true);
    expect(link.changes, hasLength(1));
    expect(link.changes.single.bitrate, 24 * _mbps);
    expect(link.changes.single.atMs, 150);
  });

  test('an outage is not judged: one cut for the refused frame, and the rate '
      'is back within seconds of the link', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    link.run(const Duration(seconds: 1), queued: (_) => link.msOfStream(5));
    // Two seconds of nothing at all (a roam between mesh nodes): the queue
    // stands still, and a quarter second in, once the kernel's buffer is
    // full and the oldest frame has waited 120 ms, a frame is refused.
    link.run(const Duration(seconds: 2),
        queued: (_) => 1024 * 1024,
        deliveredBps: (_) => 0,
        refusedAt: (i) => i == 4);
    expect(link.changes.map((c) => c.bitrate), [24 * _mbps],
        reason: 'a window that carried nothing says nothing about the link');

    final backAtMs = link.nowUs ~/ 1000;
    link.run(const Duration(seconds: 15), queued: (_) => 0);
    final recovered = link.changes.firstWhere((c) => c.bitrate >= 38 * _mbps);
    expect(recovered.atMs - backAtMs, lessThan(6000),
        reason: 'the rate that gave out is still the one before the outage');
    expect(link.adapter.bitrate, 40 * _mbps);
  });

  for (final capacity in [8, 12, 25]) {
    test('a link that drops to $capacity Mbps is followed down to just under '
        'it, and the stream settles there without freezing', () {
      final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
      link.simulate(const Duration(seconds: 1), capacityBps: 100 * _mbps);
      expect(link.changes, isEmpty);

      link.simulate(const Duration(seconds: 10), capacityBps: capacity * _mbps);
      expect(link.adapter.bitrate,
          lessThanOrEqualTo((capacity * 1.1 * _mbps).round()),
          reason: 'at most a probe above the link');

      // Settled: around the link's rate, neither at the floor nor dropping
      // frames, for the next half minute.
      final refusals = link.refusals;
      link.changes.clear();
      link.simulate(const Duration(seconds: 30),
          capacityBps: capacity * _mbps);
      expect(link.refusals, refusals, reason: 'no more freezes');
      for (final c in link.changes) {
        expect(c.bitrate, greaterThanOrEqualTo((capacity * 0.6 * _mbps).round()));
        expect(c.bitrate, lessThanOrEqualTo((capacity * 1.15 * _mbps).round()));
      }
    });
  }

  test('an idle screen sending a keyframe a second does not climb over a '
      'link it was cut to fit', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    const key = Duration(milliseconds: 250);
    link.simulate(const Duration(seconds: 15),
        capacityBps: 8 * _mbps, keyframe: key);
    final settled = link.adapter.bitrate;
    expect(settled, lessThanOrEqualTo(9 * _mbps));
    link.changes.clear();

    // Reading a page for half a minute: each second a quarter second of
    // stream in one keyframe, next to nothing else.
    link.simulate(const Duration(seconds: 30),
        capacityBps: 8 * _mbps, keyframe: key, idle: true);
    expect(link.changes.where((c) => c.bitrate > settled), isEmpty,
        reason: 'a keyframe a second is not a stream using its budget');
  });

  for (final preset in [20, 40]) {
    test('keyframes on a link a little faster than the $preset Mbps preset '
        'are no reason to drop frames', () {
      final link = _Link(BitrateAdapter(ceiling: preset * _mbps));
      link.simulate(const Duration(seconds: 30),
          capacityBps: (preset * 1.1 * _mbps).round(),
          keyframe: const Duration(milliseconds: 250));
      expect(link.refusals, 0);
      expect(link.adapter.bitrate,
          greaterThanOrEqualTo((preset * 0.7 * _mbps).round()));
    });
  }

  test('never goes below the floor, however bad the link', () {
    final adapter = BitrateAdapter(ceiling: 40 * _mbps);
    expect(adapter.floor, 5 * _mbps, reason: 'an eighth of the preset');
    final link = _Link(adapter);
    link.run(const Duration(seconds: 20),
        queued: (_) => 2 * 1024 * 1024,
        deliveredBps: (_) => _mbps ~/ 2,
        refusedAt: (i) => i % 3 == 0);
    expect(adapter.bitrate, 5 * _mbps);
    expect(link.changes.map((c) => c.bitrate),
        everyElement(greaterThanOrEqualTo(5 * _mbps)));

    expect(BitrateAdapter(ceiling: 8 * _mbps).floor, 2 * _mbps,
        reason: 'and never below 2 Mbps');
    expect(BitrateAdapter(ceiling: _mbps).floor, _mbps,
        reason: 'nor above the preset');
  });

  test('after a cut it climbs fast to just below what the link delivered, '
      'probes past it slowly, and fast again once well past it', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    // A window in which the link delivered 30 Mbps and kept a queue: 40 → 25.5.
    link.run(const Duration(milliseconds: 500),
        queued: (_) => 600 * 1024, deliveredBps: (_) => 30 * _mbps);
    expect(link.adapter.bitrate, (30 * _mbps * 0.85).round());
    final cutAtMs = link.changes.single.atMs;
    link.changes.clear();

    // Then the link has room again: the dip is over.
    link.run(const Duration(seconds: 30), queued: (_) => 0);

    expect(link.changes.first.atMs - cutAtMs, greaterThanOrEqualTo(2000),
        reason: 'held for 2 s after a cut');
    // +15% a second up to 95% of the 30 Mbps the link delivered...
    final knee = (30 * _mbps * 0.95).round();
    final fast = link.changes.takeWhile((c) => c.bitrate <= knee).toList();
    expect(fast.last.bitrate, knee);
    for (var i = 1; i < fast.length; i++) {
      expect(fast[i].bitrate,
          lessThanOrEqualTo((fast[i - 1].bitrate * 1.15).round()));
      expect(fast[i].atMs - fast[i - 1].atMs, greaterThanOrEqualTo(1000));
    }
    // ...then 5% every 2 s until 15% past those 30 Mbps...
    final past = (30 * _mbps * 1.15).round();
    final rest = link.changes.skip(fast.length).toList();
    final slowCount = rest.indexWhere((c) => c.bitrate > past) + 1;
    expect(slowCount, greaterThan(1));
    final slow = rest.take(slowCount).toList();
    for (var i = 0; i < slow.length; i++) {
      final before = i == 0 ? fast.last : slow[i - 1];
      expect(slow[i].bitrate, lessThanOrEqualTo((before.bitrate * 1.05).round()));
      expect(slow[i].atMs - before.atMs, greaterThanOrEqualTo(2000));
    }
    // ...then fast again, to the preset and no higher.
    final again = rest.skip(slowCount).toList();
    expect(again, isNotEmpty);
    expect(again.first.atMs - slow.last.atMs, lessThan(2000));
    expect(link.adapter.bitrate, 40 * _mbps);
    expect(link.changes.last.atMs - cutAtMs, lessThan(20000));
    expect(link.changes.map((c) => c.bitrate),
        everyElement(lessThanOrEqualTo(40 * _mbps)));
  });

  test('an idle screen does not climb: an empty queue proves nothing while '
      'the stream uses a fraction of its budget', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    link.run(const Duration(milliseconds: 500),
        queued: (_) => 400 * 1024, deliveredBps: (_) => 12 * _mbps);
    expect(link.adapter.bitrate, 20 * _mbps);
    link.changes.clear();
    // Reading a page: tiny frames, a keyframe now and then.
    link.run(const Duration(seconds: 40),
        queued: (_) => 0, deliveredBps: (_) => 4 * _mbps);
    expect(link.changes, isEmpty);
    expect(link.adapter.bitrate, 20 * _mbps);

    // Busy again on a link with room: now it climbs.
    link.run(const Duration(seconds: 3), queued: (_) => 0);
    expect(link.changes, isNotEmpty);
    expect(link.adapter.bitrate, greaterThan(20 * _mbps));
  });

  test('a queue between healthy and congested neither cuts nor raises', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    link.run(const Duration(milliseconds: 500),
        queued: (_) => 400 * 1024, deliveredBps: (_) => 12 * _mbps);
    link.changes.clear();
    link.run(const Duration(seconds: 10), queued: (_) => link.msOfStream(20));
    expect(link.changes, isEmpty);
  });

  test('long after its last cut it climbs fast all the way to the preset', () {
    final link = _Link(BitrateAdapter(ceiling: 40 * _mbps));
    link.run(const Duration(milliseconds: 500),
        queued: (_) => 400 * 1024, deliveredBps: (_) => 12 * _mbps);
    // Neither healthy nor congested for half a minute: no change.
    link.run(const Duration(seconds: 31), queued: (_) => link.msOfStream(20));
    link.changes.clear();
    link.run(const Duration(seconds: 10), queued: (_) => 0);
    expect(link.adapter.bitrate, 40 * _mbps);
    expect(link.changes.last.atMs - link.changes.first.atMs, lessThan(6000),
        reason: '20 → 40 Mbps at 15% a second, the 12 Mbps measured then '
            'forgotten');
  });
}
