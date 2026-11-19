import 'package:flutter_test/flutter_test.dart';

import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';

void main() {
  const ultra = ClientPanel(2960, 1848, 120);
  const small = ClientPanel(1280, 800, 60);

  DisplayConfigModel want(
    ClientPanel panel, {
    EncodePreset preset = EncodePreset.max,
    CodecType codec = CodecType.h265,
  }) =>
      preset.configFor(panel, mode: DisplayMode.extend, codec: codec);

  EncodeBudget m3Pro() => EncodeBudget(EncoderEstimate.forChip('Apple M3 Pro'));

  // Everything a caller can read back, to show a call changed nothing.
  Object snapshot(EncodeBudget b) =>
      (b.count, b.ceilings().toString(), b.load);

  group('EncoderEstimate.forChip', () {
    test('counts the engines of each Apple chip', () {
      for (final (brand, engines) in [
        ('Apple M3', 1),
        ('Apple M3 Pro', 1),
        ('Apple M2 Max', 2),
        ('Apple M1 Ultra', 4),
        ('M4 Pro', 1),
      ]) {
        final e = EncoderEstimate.forChip(brand);
        expect(e.engines, engines, reason: brand);
        expect(e.tabletCap, isNull, reason: brand);
        expect(e.capacity(CodecType.h264), 274.0 * engines);
        expect(e.capacity(CodecType.h265), 550.0 * engines);
      }
    });

    test('anything else is a conservative guess, two tablets at most', () {
      for (final brand in [
        'Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz',
        'Something new',
        '',
        null,
      ]) {
        final e = EncoderEstimate.forChip(brand);
        expect(e.engines, 1);
        expect(e.capacity(CodecType.h264), 140);
        expect(e.capacity(CodecType.h265), 140);
        expect(e.tabletCap, 2);
      }
    });
  });

  test('a tablet alone gets exactly what it wants', () {
    final b = m3Pro();
    final wanted = want(ultra);
    final g = b.admit(1, wanted, cap: 4);
    expect(g.config.toMap(), wanted.toMap());
    expect(g.fpsCeiling, 120);
    expect(g.reducedResolution, isFalse);
    expect(g.othersChanged, isEmpty);
    expect(b.ceilings(), {1: 120});
  });

  test('two native H.265 tablets share the encoder by rate only', () {
    final b = m3Pro();
    b.admit(1, want(ultra), cap: 4);
    final g = b.admit(2, want(ultra), cap: 4);
    expect(g.reducedResolution, isFalse);
    expect(g.config.encodedPixels, 2960 * 1848);
    // The first keeps its resolution; only its ceiling moves, and it is
    // handed back to be pushed to its encoder.
    expect(g.othersChanged, {1: b.ceilings()[1]});
    expect(b.ceilings()[1], lessThan(120));
    expect(g.config.fpsCeiling, g.fpsCeiling);
    expect(g.config.refreshRate, 120);
    final total = 2960 * 1848 * (b.ceilings()[1]! + b.ceilings()[2]!) / 1e6;
    expect(total, lessThanOrEqualTo(0.85 * 550));
    expect(b.load, lessThanOrEqualTo(0.85));
    // On a tie the newer one steps down first.
    expect(b.ceilings(), {1: 45, 2: 30});
  });

  test('a second native H.264 tablet gets a lower resolution', () {
    final b = m3Pro();
    b.admit(1, want(ultra, codec: CodecType.h264), cap: 4);
    final g = b.admit(2, want(ultra, codec: CodecType.h264), cap: 4);
    expect(g.reducedResolution, isTrue);
    expect(g.config.encodedPixels, lessThan(2960 * 1848));
    expect(b.ceilings().values.every((fps) => fps >= 30), isTrue);
  });

  test('with several engines each session must fit one engine', () {
    final b = EncodeBudget(EncoderEstimate.forChip('Apple M2 Max'));
    b.admit(1, want(ultra), cap: 4);
    b.admit(2, want(ultra), cap: 4);
    for (final fps in b.ceilings().values) {
      expect(2960 * 1848 * fps / 1e6, lessThanOrEqualTo(0.85 * 550));
    }
    expect(b.ceilings(), {1: 60, 2: 60});
  });

  test('floors that do not fit refuse the newcomer and change nothing', () {
    final b = EncodeBudget(EncoderEstimate.forChip(null));
    b.admit(1, want(ultra), cap: 4);
    final before = snapshot(b);
    expect(() => b.admit(2, want(ultra), cap: 4),
        throwsA(isA<CaptureLimit>()));
    expect(snapshot(b), before);
    expect(b.contains(2), isFalse);
    expect(const CaptureLimit().key, 'error_encode_limit');
  });

  test('the cap refuses a tablet past it', () {
    final b = m3Pro();
    b.admit(1, want(small), cap: 2);
    b.admit(2, want(small), cap: 2);
    final before = snapshot(b);
    expect(() => b.admit(3, want(small), cap: 2),
        throwsA(isA<CaptureLimit>()));
    expect(snapshot(b), before);
  });

  test('an unknown chip takes two tablets at most', () {
    final b = EncodeBudget(EncoderEstimate.forChip('Intel(R) Core(TM) i7'));
    b.admit(1, want(small), cap: 4);
    b.admit(2, want(small), cap: 4);
    expect(() => b.admit(3, want(small), cap: 4),
        throwsA(isA<CaptureLimit>()));
  });

  test('admitting a session again never refuses it and keeps its resolution',
      () {
    final b = m3Pro();
    b.admit(1, want(ultra, codec: CodecType.h264), cap: 4);
    final first = b.admit(2, want(ultra, codec: CodecType.h264), cap: 4);
    expect(first.reducedResolution, isTrue);
    // Its capture restarts (a wake), even with the cap since lowered.
    final again = b.admit(2, want(ultra, codec: CodecType.h264), cap: 1);
    expect(again.reducedResolution, isTrue);
    expect(again.config.encodedPixels, first.config.encodedPixels);
    expect(again.fpsCeiling, first.fpsCeiling);
    expect(again.othersChanged, isEmpty);
    expect(b.count, 2);
  });

  group('a reservation', () {
    test('keeps a place past a lowered cap while the others climb into its '
        'room; a newcomer counts it, and release drops it', () {
      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      final second = b.admit(2, want(ultra), cap: 4);
      final shared = b.ceilings()[1]!;
      expect(shared, lessThan(120));

      // 2's capture stops while its session goes on.
      expect(b.reserve(2), {1: 120});
      expect(b.contains(2), isFalse);
      expect(b.holds(2), isTrue);
      expect(b.count, 1);
      expect(b.ceilings(), {1: 120});

      // A newcomer counts the place: past a cap of two it is refused.
      expect(() => b.admit(3, want(small), cap: 2), throwsA(isA<CaptureLimit>()));
      expect(b.wouldFit(want(small), cap: 2), isFalse);

      // 2 comes back under a cap of one: a return, not a new tablet. Same
      // resolution, and the first one's ceiling goes down as before.
      final back = b.admit(2, want(ultra), cap: 1);
      expect(back.config.encodedPixels, second.config.encodedPixels);
      expect(back.othersChanged, {1: shared});
      expect(b.holds(2), isTrue);

      // A refused (or ended) session's place goes.
      b.reserve(2);
      b.release(2);
      expect(b.holds(2), isFalse);
      expect(b.wouldFit(want(small), cap: 2), isTrue);
    });

    test('tablets that all restart at once come back as they were, whatever '
        'order their handshakes finish in', () {
      const big = ClientPanel(2960, 1848, 60);
      const mid = ClientPanel(2000, 1200, 60);
      DisplayConfigModel h264(ClientPanel p) => want(p, codec: CodecType.h264);
      EncodeBudget m3() => EncodeBudget(EncoderEstimate.forChip('Apple M3'));

      // Joined as 2000, 2960, 2000: all three fit, the 2960 at 1920 wide.
      final b = m3();
      final joined = {
        for (final (id, p) in [(1, mid), (2, big), (3, mid)])
          id: b.admit(id, h264(p), cap: 4),
      };
      expect([for (final g in joined.values) g.reducedResolution],
          [false, true, false]);

      // Admitted afresh with the 2960 first, the third would not fit: the
      // order alone decides.
      final fresh = m3()
        ..admit(2, h264(big), cap: 4)
        ..admit(1, h264(mid), cap: 4);
      expect(() => fresh.admit(3, h264(mid), cap: 4),
          throwsA(isA<CaptureLimit>()));

      // A settings reconnect: every capture stops, and the 2960's handshake
      // finishes first.
      for (final id in [1, 2, 3]) {
        b.reserve(id);
      }
      for (final (id, p) in [(2, big), (1, mid), (3, mid)]) {
        final g = b.admit(id, h264(p), cap: 4);
        expect(g.config.encodedPixels, joined[id]!.config.encodedPixels,
            reason: '$id');
      }
      expect(b.count, 3);
    });

    test("a suspended one (its tablet unplugged) keeps its place under the "
        "cap but holds no room: a running tablet's return keeps its "
        'resolution, and the tablet back is planned beside what runs', () {
      const big = ClientPanel(2960, 1848, 60);
      DisplayConfigModel wanted(CodecType codec) =>
          want(big, preset: EncodePreset.balanced, codec: codec);
      EncodeBudget twoNative() {
        final b = EncodeBudget(EncoderEstimate.forChip('Apple M3'));
        for (final id in [1, 2]) {
          expect(b.admit(id, wanted(CodecType.h265), cap: 2).reducedResolution,
              isFalse);
        }
        // 2's tablet goes; then a settings reconnect (H.264, where two
        // native tablets no longer fit, and a cap of one) stops 1's capture.
        b.reserve(2);
        b.reserve(1);
        return b;
      }

      // 2's tablet is still attached (a lost link): its room is held, and 1
      // comes back smaller so that both fit, as designed.
      final attached = twoNative();
      expect(attached.admit(1, wanted(CodecType.h264), cap: 1).reducedResolution,
          isTrue);

      final b = twoNative();
      expect(b.isSuspended(2), isFalse);
      b.suspend(2);
      b.suspend(3); // holds nothing: no effect
      expect(b.isSuspended(2), isTrue);
      expect(b.isSuspended(3), isFalse);
      final back = b.admit(1, wanted(CodecType.h264), cap: 1);
      expect(back.reducedResolution, isFalse);
      expect(back.config.encodedPixels, wanted(CodecType.h264).encodedPixels);
      expect(back.fpsCeiling, 60, reason: 'alone beside a suspended place');

      // The place still counts under the cap, but not as room.
      expect(b.wouldFit(want(small), cap: 2), isFalse);
      expect(b.wouldFit(want(small), cap: 4), isTrue);
      expect(b.holds(2), isTrue);

      // 2 is back: a return past the cap of one, beside 1 as it runs now.
      b.resume(2);
      expect(b.isSuspended(2), isFalse);
      final two = b.admit(2, wanted(CodecType.h264), cap: 1);
      expect(two.reducedResolution, isTrue);
      expect(b.count, 2);
      expect(b.admit(1, wanted(CodecType.h264), cap: 1).config.encodedPixels,
          back.config.encodedPixels, reason: '1 keeps its resolution');

      // An admission or a release ends a suspension.
      b.reserve(2);
      b.suspend(2);
      b.release(2);
      expect(b.isSuspended(2), isFalse);
      expect(b.holds(2), isFalse);
    });
  });

  test('release raises the ceilings of those left', () {
    final b = m3Pro();
    b.admit(1, want(ultra), cap: 4);
    b.admit(2, want(ultra), cap: 4);
    expect(b.release(2), {1: 120});
    expect(b.ceilings(), {1: 120});
    expect(b.release(2), isEmpty);
    expect(b.count, 1);
  });

  test('wouldFit changes nothing and agrees with admit', () {
    final b = m3Pro();
    expect(b.wouldFit(want(ultra), cap: 4), isTrue);
    expect(b.count, 0);
    var id = 0;
    for (final (panel, codec) in [
      (ultra, CodecType.h264),
      (ultra, CodecType.h265),
      (ultra, CodecType.h264),
      (small, CodecType.h264),
      (ultra, CodecType.h265),
      (small, CodecType.h265),
    ]) {
      final wanted = want(panel, codec: codec);
      final before = snapshot(b);
      final fits = b.wouldFit(wanted, cap: 4);
      expect(snapshot(b), before);
      bool admitted;
      try {
        b.admit(++id, wanted, cap: 4);
        admitted = true;
      } on CaptureLimit {
        admitted = false;
      }
      expect(admitted, fits, reason: 'tablet $id');
    }
  });

  test('hasOthers', () {
    final b = m3Pro();
    expect(b.hasOthers(1), isFalse);
    b.admit(1, want(small), cap: 4);
    expect(b.hasOthers(1), isFalse);
    expect(b.hasOthers(2), isTrue);
    b.admit(2, want(small), cap: 4);
    expect(b.hasOthers(1), isTrue);
    b.release(2);
    expect(b.hasOthers(1), isFalse);
  });

  test('a new estimate moves the ceilings but ends no one', () {
    final b = m3Pro();
    b.admit(1, want(ultra), cap: 4);
    b.admit(2, want(ultra), cap: 4);
    b.estimate = EncoderEstimate.forChip(null);
    expect(b.count, 2);
    expect(b.ceilings(), {1: 30, 2: 30});
  });

  group('learned capacity', () {
    // 2960×1848 at 120 fps: what one Tab S10 Ultra was seen to run with
    // H.265 on an M3 Pro, past the estimate's usable 467.5 Mpx/s.
    const ultraPx = 2960 * 1848;
    const ultraAt120 = ultraPx * 120 / 1e6;

    test('a proven load is what the Max sessions encode, each at its '
        'ceiling', () {
      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      expect(b.provenLoad({}), isNull, reason: 'rate not reported yet');
      expect(b.provenLoad({1: 90}), isNull, reason: 'below its ceiling');
      expect(b.provenLoad({1: 120}),
          const EncoderLoad(CodecType.h265, ultraAt120));

      // A fixed-rate session beside it counts for nothing (its encoder
      // says nothing of overload), whatever it runs at.
      b.admit(2, want(small, preset: EncodePreset.quality), cap: 4);
      final c1 = b.ceilings()[1]!;
      final load = b.provenLoad({1: c1});
      expect(load?.codec, CodecType.h265);
      expect(load?.mpx, closeTo(ultraPx * c1 / 1e6, 1e-9));
      expect(load?.largest, closeTo(ultraPx * c1 / 1e6, 1e-9));
    });

    test('nothing is proven without a Max session, or across codecs', () {
      final b = m3Pro();
      b.admit(1, want(small, preset: EncodePreset.balanced), cap: 4);
      expect(b.provenLoad({1: 60}), isNull);

      final mixed = m3Pro();
      mixed.admit(1, want(small), cap: 4);
      mixed.admit(2, want(small, codec: CodecType.h264), cap: 4);
      expect(mixed.provenLoad(mixed.ceilings()), isNull);
    });

    test('one tablet sustaining more than the estimate raises the capacity '
        'to fit it, and a second tablet then gets more', () {
      // Without anything learned: the second tablet's arrival leaves 45
      // and 30 fps.
      final plain = m3Pro();
      plain.admit(1, want(ultra), cap: 4);
      plain.admit(2, want(ultra), cap: 4);
      expect(plain.ceilings(), {1: 45, 2: 30});

      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      expect(b.load, greaterThan(1.0), reason: "the Home line's 119%");
      expect(b.isLearned(CodecType.h265), isFalse);
      final changed = b.raiseCapacity(b.provenLoad({1: 120})!);
      expect(changed, isNotNull);
      expect(changed, isEmpty, reason: 'alone it had what it wanted');
      expect(b.isLearned(CodecType.h265), isTrue);
      expect(b.capacity(CodecType.h265), closeTo(ultraAt120 / 0.85, 1e-6));
      expect(b.learned(CodecType.h265), closeTo(ultraAt120 / 0.85, 1e-6));
      expect(b.load, closeTo(0.85, 1e-9));
      expect(b.capacity(CodecType.h264), 274, reason: 'per codec');

      final g = b.admit(2, want(ultra), cap: 4);
      expect(b.ceilings(), {1: 60, 2: 60});
      expect(g.fpsCeiling, 60);
      expect(g.othersChanged, {1: 60});
      expect(b.load, lessThanOrEqualTo(0.85 + 1e-9));
    });

    test('a proven load never lowers the capacity', () {
      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      b.raiseCapacity(const EncoderLoad(CodecType.h265, ultraAt120));
      final learned = b.capacity(CodecType.h265);
      expect(b.raiseCapacity(const EncoderLoad(CodecType.h265, 100)), isNull);
      expect(
          b.raiseCapacity(const EncoderLoad(CodecType.h265, ultraAt120)),
          isNull,
          reason: 'already fits');
      expect(b.capacity(CodecType.h265), learned);
      // Under the estimate's usable share: nothing to learn.
      final fresh = m3Pro();
      expect(fresh.raiseCapacity(const EncoderLoad(CodecType.h265, 400)),
          isNull);
      expect(fresh.learned(CodecType.h265), isNull);
    });

    test('a raised capacity lifts the running sessions\' ceilings, handed '
        'back to push live', () {
      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      b.admit(2, want(ultra), cap: 4);
      expect(b.ceilings(), {1: 45, 2: 30});
      var notified = 0;
      b.addListener(() => notified++);
      final changed =
          b.raiseCapacity(const EncoderLoad(CodecType.h265, ultraAt120));
      expect(changed, {1: 60, 2: 60});
      expect(b.ceilings(), {1: 60, 2: 60});
      expect(notified, 1);
      expect(b.count, 2);
    });

    test('with several engines the largest session must fit one engine', () {
      final b = EncodeBudget(EncoderEstimate.forChip('Apple M2 Max'));
      b.admit(1, want(ultra), cap: 4);
      b.raiseCapacity(b.provenLoad({1: 120})!);
      // One session runs on one engine: 656 Mpx/s on one of two.
      expect(b.capacity(CodecType.h265), closeTo(2 * ultraAt120 / 0.85, 1e-6));
      b.admit(2, want(ultra), cap: 4);
      expect(b.ceilings(), {1: 120, 2: 120});
    });

    test('an overload with several tablets lowers what was learned to what '
        'they achieved, never below the estimate', () {
      final b = m3Pro();
      b.setLearned(CodecType.h265, 1000);
      b.admit(1, want(ultra), cap: 4);
      expect(b.achievedLoad(1, 40, {1: 120}), isNull, reason: 'alone');
      b.admit(2, want(ultra), cap: 4);
      expect(b.ceilings(), {1: 90, 2: 60});

      // Session 1 managed 70 fps beside session 2 at its 60.
      final load = b.achievedLoad(1, 70, {1: 90, 2: 60})!;
      expect(load.mpx, closeTo(ultraPx * 130 / 1e6, 1e-9));
      final changed = b.lowerCapacity(load);
      expect(changed, isNotNull);
      expect(b.learned(CodecType.h265), closeTo(ultraPx * 130 / 1e6, 1e-9));
      expect(b.capacity(CodecType.h265), closeTo(ultraPx * 130 / 1e6, 1e-9));
      expect(changed, {
        for (final MapEntry(:key, :value) in b.ceilings().entries)
          if (value != {1: 90, 2: 60}[key]) key: value,
      });
      expect(b.load, lessThanOrEqualTo(0.85 + 1e-9));

      // A higher achieved load never raises it.
      expect(b.lowerCapacity(const EncoderLoad(CodecType.h265, 900)), isNull);

      // Far lower: the estimate, and nothing learned any more.
      b.lowerCapacity(b.achievedLoad(1, 20, {2: 30})!);
      expect(b.capacity(CodecType.h265), 550);
      expect(b.learned(CodecType.h265), isNull);
      expect(b.isLearned(CodecType.h265), isFalse);
    });

    test('with nothing learned an overload lowers nothing', () {
      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      b.admit(2, want(ultra), cap: 4);
      final before = snapshot(b);
      expect(b.lowerCapacity(b.achievedLoad(1, 20, {})!), isNull);
      expect(snapshot(b), before);
      expect(b.capacity(CodecType.h265), 550);
    });

    test('the achieved load: the stepping session at what it managed, the '
        'others at their rates, one codec only', () {
      final b = m3Pro();
      b.admit(1, want(small), cap: 4);
      b.admit(2, want(small), cap: 4);
      const px = 1280 * 800;
      expect(b.achievedLoad(1, 33.5, {2: 45})!.mpx,
          closeTo(px * (33.5 + 45) / 1e6, 1e-9));
      // The other's rate unknown: its ceiling.
      expect(b.achievedLoad(1, 30, {})!.mpx,
          closeTo(px * (30 + b.ceilings()[2]!) / 1e6, 1e-9));
      expect(b.achievedLoad(3, 30, {}), isNull, reason: 'not admitted');
      expect(b.achievedLoad(1, double.nan, {}), isNull);

      b.admit(3, want(small, codec: CodecType.h264), cap: 4);
      expect(b.achievedLoad(1, 30, {}), isNull, reason: 'mixed codecs');
    });

    test('with two tablets at what the rule allows a proven load teaches '
        'nothing; a probe gives the cheapest rung up to one of them, and its '
        'load, once proven, does', () {
      const avd = ClientPanel(2152, 2076, 60);
      final b = m3Pro();
      b.admit(1, want(avd), cap: 4);
      b.admit(2, want(ultra), cap: 4);
      final rule = b.ceilings();
      expect(rule[2], lessThan(120));
      expect(b.raiseCapacity(b.provenLoad(rule)!), isNull);

      var notified = 0;
      b.addListener(() => notified++);
      final probe = b.startProbe()!;
      expect(notified, 1);
      expect(b.probing, probe.id);
      // The AVD's next rung adds less than the Tab's.
      const avdPx = 2152 * 2076, tabPx = 2960 * 1848;
      expect(avdPx < tabPx, isTrue);
      expect(probe.id, 1);
      expect(probe.fps, greaterThan(rule[1]!));
      expect(b.ceilings(), {...rule, 1: probe.fps});
      expect(probe.load.mpx,
          closeTo((avdPx * probe.fps + tabPx * rule[2]!) / 1e6, 1e-9));
      expect(b.startProbe(), isNull, reason: 'one at a time');

      // Proven at the probe's rates, it is past what was known.
      final proven = b.provenLoad(b.ceilings())!;
      expect(proven, probe.load);
      final changed = b.raiseCapacity(proven);
      expect(changed, isNotNull);
      expect(b.probing, isNull, reason: 'the rule took over');
      expect(b.capacity(CodecType.h265),
          greaterThanOrEqualTo(probe.load.mpx / 0.85 - 1e-9));
    });

    test('a probe skips a rung up that still fits what is known: it would '
        'teach nothing, and the probe would sit there for good', () {
      // Stepping the largest demand down leaves the 1080p tablet at 120
      // where 144 still fits beside the other at 30: the cheapest rung up,
      // and one that proves nothing.
      const big = ClientPanel(2800, 2000, 120);
      const fast = ClientPanel(1920, 1080, 144);
      final b = m3Pro();
      b.admit(1, want(big), cap: 4);
      b.admit(2, want(fast), cap: 4);
      expect(b.ceilings(), {1: 30, 2: 120});

      final probe = b.startProbe()!;
      expect(probe.id, 1, reason: 'the rung up that does not fit');
      expect(probe.fps, 45);
      final changed = b.raiseCapacity(b.provenLoad(b.ceilings())!);
      expect(changed, isNotNull, reason: 'its load, once proven, teaches');
    });

    test('a probe ends when the ceilings are worked out again, is refused '
        'at a load that failed, and needs two Max tablets below their '
        'rate', () {
      final b = m3Pro();
      b.admit(1, want(ultra), cap: 4);
      expect(b.startProbe(), isNull, reason: 'alone it has what it wants');
      b.admit(2, want(ultra), cap: 4);
      final rule = b.ceilings();

      final probe = b.startProbe()!;
      expect(b.endProbe(), {probe.id: rule[probe.id]});
      expect(b.ceilings(), rule);
      expect(b.endProbe(), isEmpty);

      // At or past a load a probe failed at: refused; under it: allowed.
      expect(b.startProbe(failedAt: (_) => probe.load.mpx), isNull);
      expect(b.startProbe(failedAt: (c) =>
              c == CodecType.h264 ? 0 : probe.load.mpx + 1),
          isNotNull);
      // An admission, a reservation or a new estimate end it.
      b.admit(3, want(small), cap: 4);
      expect(b.probing, isNull);
      b.startProbe();
      b.reserve(3);
      expect(b.probing, isNull);
      b.startProbe();
      b.estimate = EncoderEstimate.forChip('Apple M3 Pro');
      expect(b.probing, isNull);

      // Fixed-rate sessions are never probed.
      final fixed = m3Pro();
      fixed.admit(1, want(ultra, preset: EncodePreset.quality), cap: 4);
      fixed.admit(2, want(ultra, preset: EncodePreset.quality), cap: 4);
      expect(fixed.startProbe(), isNull);
    });

    test('a saved value counts only above the estimate, and a new estimate '
        'keeps what was learned', () {
      final b = m3Pro();
      expect(b.setLearned(CodecType.h265, 300), isEmpty);
      expect(b.capacity(CodecType.h265), 550);
      expect(b.isLearned(CodecType.h265), isFalse);
      b.setLearned(CodecType.h265, 800);
      expect(b.capacity(CodecType.h265), 800);
      b.estimate = EncoderEstimate.forChip(null);
      expect(b.capacity(CodecType.h265), 800);
      expect(b.capacity(CodecType.h264), 140);
      for (final bad in [double.nan, double.infinity, -1.0, 0.0, null]) {
        b.setLearned(CodecType.h265, 800);
        b.setLearned(CodecType.h265, bad);
        expect(b.learned(CodecType.h265), isNull, reason: '$bad');
      }
    });
  });
}
