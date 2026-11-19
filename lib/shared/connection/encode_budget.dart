import 'dart:math' as math;

import 'package:extendedscreen/shared/connection/base_connection_manager.dart'
    show LinkError;
import 'package:extendedscreen/shared/models/display_config_model.dart';

/// A tablet that can't be given a capture: the tablets already running leave
/// the encoder no room for it even at its lowest resolution and rate, or the
/// cap on tablets at once is reached. Terminal: retrying would only make and
/// remove virtual displays in a loop.
class CaptureLimit extends LinkError {
  const CaptureLimit() : super('error_encode_limit');
}

/// How much this Mac's video encoder is taken to manage, in megapixels a
/// second (encoded width × height × fps), until something better is known.
///
/// Apple silicon has one media engine on a base or Pro chip, two on a Max and
/// four on an Ultra, and one encode session runs on one engine. The figures
/// per engine are this repo's measurements on an M3 Pro: about 274 Mpx/s with
/// H.264 (one session saturates near 50 fps at 2960×1848) and about 550 Mpx/s
/// with H.265. Anything else (Intel, a brand string not understood, none) gets
/// a conservative guess and at most two tablets.
class EncoderEstimate {
  const EncoderEstimate({
    required this.engines,
    required this.h264PerEngine,
    required this.h265PerEngine,
    this.tabletCap,
  });

  /// From the chip's brand string (`sysctl machdep.cpu.brand_string`, e.g.
  /// "Apple M3 Pro").
  factory EncoderEstimate.forChip(String? brand) {
    final chip = _appleChip.firstMatch(brand?.trim() ?? '');
    if (chip == null) return conservative;
    return EncoderEstimate(
      engines: switch (chip.group(1)) {
        'Max' => 2,
        'Ultra' => 4,
        _ => 1,
      },
      h264PerEngine: 274,
      h265PerEngine: 550,
    );
  }

  static final _appleChip =
      RegExp(r'^(?:Apple\s+)?M\d+(?:\s+(Pro|Max|Ultra))?\b');

  static const conservative = EncoderEstimate(
    engines: 1,
    h264PerEngine: 140,
    h265PerEngine: 140,
    tabletCap: 2,
  );

  final int engines;
  final double h264PerEngine;
  final double h265PerEngine;

  /// At most this many tablets whatever the setting says; null for none.
  final int? tabletCap;

  /// What one session can get, in Mpx/s: one engine.
  double perEngine(CodecType codec) =>
      codec == CodecType.h265 ? h265PerEngine : h264PerEngine;

  /// What all sessions together can get, in Mpx/s.
  double capacity(CodecType codec) => engines * perEngine(codec);
}

/// What some captures make this Mac's encoder do: [mpx] megapixels a
/// second (encoded width × height × fps, summed over the captures) of one
/// [codec], [largest] of them in one capture.
class EncoderLoad {
  const EncoderLoad(this.codec, this.mpx, {double? largest})
      : largest = largest ?? mpx;

  final CodecType codec;
  final double mpx;
  final double largest;

  @override
  bool operator ==(Object other) =>
      other is EncoderLoad &&
      other.codec == codec &&
      other.mpx == mpx &&
      other.largest == largest;

  @override
  int get hashCode => Object.hash(codec, mpx, largest);

  @override
  String toString() =>
      '${mpx.toStringAsFixed(1)} Mpx/s ${codec.name} (largest '
      '${largest.toStringAsFixed(1)})';
}

/// A probe [EncodeBudget.startProbe] began: session [id]'s ceiling is
/// [fps], one rung above what the rule gives it, and with every adapting
/// session at its ceiling the encoder would carry [load].
class EncodeProbe {
  const EncodeProbe(this.id, this.fps, this.load);

  final int id;
  final int fps;
  final EncoderLoad load;

  @override
  String toString() => 'session $id at $fps fps ($load)';
}

/// What [EncodeBudget.admit] gives a session.
class EncodeGrant {
  const EncodeGrant({
    required this.config,
    required this.reducedResolution,
    required this.fpsCeiling,
    this.othersChanged = const {},
  });

  /// What to start the capture with: the wanted config, at a lower
  /// resolution if [reducedResolution], with [DisplayConfigModel.fpsCeiling]
  /// set when [fpsCeiling] is below its rate.
  final DisplayConfigModel config;

  /// The session got less than its preset's resolution.
  final bool reducedResolution;

  /// The highest rate it may run at for now.
  final int fpsCeiling;

  /// The running sessions whose ceiling this admission changed (lowered),
  /// by id, to push to their encoders.
  final Map<int, int> othersChanged;
}

/// What a session's capture got, as its tablet's card shows it: the encoded
/// size, the rate it runs at (its encoder reports changes), and whether
/// another tablet shares the encoder.
class GrantedCapture {
  const GrantedCapture({
    required this.width,
    required this.height,
    required this.fps,
    required this.shared,
  });

  final int width;
  final int height;
  final int fps;
  final bool shared;

  GrantedCapture copyWith({int? fps, bool? shared}) => GrantedCapture(
        width: width,
        height: height,
        fps: fps ?? this.fps,
        shared: shared ?? this.shared,
      );

  @override
  bool operator ==(Object other) =>
      other is GrantedCapture &&
      other.width == width &&
      other.height == height &&
      other.fps == fps &&
      other.shared == shared;

  @override
  int get hashCode => Object.hash(width, height, fps, shared);

  @override
  String toString() => '$width×$height@$fps${shared ? ' shared' : ''}';
}

/// Shares this Mac's encoder between the tablets streaming from it. Pure
/// arithmetic, like [BitrateAdapter]; the host asks it before each capture
/// starts and tells it when one stops.
///
/// **Demand.** A session's demand is its encoded pixels × fps over the
/// [EncoderEstimate.capacity] for its codec: the share of the encoder it
/// takes, so sessions with different codecs add up. The total may not pass
/// [usable] (85%, room for whatever else the media engine does), and with
/// several engines no one session may pass one engine's share either.
///
/// **Rates.** Each session has a ladder: 120, 90, 60, 45 and 30 fps, plus the
/// rate it wants, keeping those no higher than that. Its floor is the bottom
/// rung. Every session starts at the rate it wants; while the total is over
/// budget, the session with the largest demand steps one rung down (on a
/// tie, the one admitted last). A running session only ever changes its
/// ceiling, live: never its resolution, so no restart and no keyframe.
///
/// **Admission** ([admit]):
/// 0. A session already admitted (its capture restarting) is admitted again
///    as it is: same resolution, never refused.
/// 1. A session alone (no other admitted, and no other reservation but
///    [suspend]ed ones) gets exactly what it wants, ceiling included, as one
///    tablet always has.
/// 2. Past the cap (the setting, or [EncoderEstimate.tabletCap]) it is
///    refused, unless it is returning to a place it reserved.
/// 3. Only the newcomer can get a lower resolution, and only when its floor
///    does not fit beside everyone else's: it tries its own resolution, then
///    1920 wide, then the logical size (scale 1). The first whose floors all
///    fit is taken; if none does, it is refused and nothing changes.
/// 4. The ceilings are then worked out as above.
///
/// When a session leaves ([release]) the ceilings are worked out again, which
/// only lifts them; each session's own Max ladder climbs back within its new
/// ceiling.
///
/// **Reservations.** A session whose capture stops while the session itself
/// goes on (its link lost and retried, a settings reconnect, a rebuild that
/// failed) [reserve]s its entry instead: it no longer counts towards the
/// ceilings or [load], so the others climb into its room, but it keeps its
/// place. Its next [admit] is a return: past the cap it is still admitted
/// (a lowered cap only refuses new tablets), it keeps its admission order,
/// and while it is out every other admission, a newcomer's or another
/// return, is planned with the reserved entries counted at their floors, as
/// if they were running. So tablets that all restart at once (a settings
/// reconnect) come back as they were whatever order their handshakes finish
/// in, and a newcomer can't take the room a returning tablet needs. A return
/// that does not fit beside the reservations (its demand grew) is planned
/// against the running sessions alone, so the tablet back first goes on.
/// [release] drops a reservation too.
///
/// A reservation whose tablet is gone (unplugged: its session waits for it
/// to be listed again) is [suspend]ed: it keeps its place under the cap, but
/// no admission is planned around its room, so a running tablet's return
/// never comes back smaller for the sake of a tablet that is not there (a
/// session with nothing else beside it is alone, rule 1), nor is a
/// newcomer kept out of the room. Once the tablet is back ([resume]) the
/// reservation holds room again; its own return is planned beside whatever
/// runs by then, past the cap still, so it can come back at a lower
/// resolution than it had (or, if not even its floor fits, be refused).
///
/// **Learned capacity.** The estimate is a guess, and on the measuring M3
/// Pro itself it was low: one tablet ran 2960×1848 at 120 fps with H.265
/// (656 Mpx/s) with no overload, past the estimate's usable 467. So the
/// capacity of a codec is the larger of the estimate and what was learned
/// for it ([learned]), and two signals move what was learned:
/// - [raiseCapacity]: a load the encoder was seen to sustain (the hub's
///   healthy window, [provenLoad]) is a lower bound. The capacity is raised
///   until that load fits the rule above (the total within [usable], each
///   session within one engine's share), never lowered by it.
/// - [lowerCapacity]: an encoder that could not keep up while several
///   sessions shared it says the capacity is at most what they achieved
///   together ([achievedLoad]). What was learned comes down to that, never
///   below the estimate.
/// Both work out the ceilings again and return those that changed, like
/// [release].
///
/// **Probes.** With several tablets every ceiling the rule sets fits the
/// capacity, so a proven load never passes it and nothing would ever be
/// learned. So once a load is proven and teaches nothing, the hub may
/// [startProbe]: one adapting session below the rate it wants gets one rung
/// more than the rule gives it. If the encoder sustains that (the next
/// proven load is past the capacity), [raiseCapacity] learns it; an
/// overload means it does not ([endProbe]). Anything that works the
/// ceilings out again (an admission, a release, a reservation, a new
/// estimate, a capacity learned or lowered) ends a probe.
class EncodeBudget {
  EncodeBudget(EncoderEstimate estimate, {this.usable = 0.85})
      : _estimate = estimate;

  /// The share of the estimate the sessions may use together.
  final double usable;

  EncoderEstimate _estimate;
  EncoderEstimate get estimate => _estimate;

  /// A new estimate takes effect at once on the ceilings, but never ends a
  /// session that no longer fits: they stay at their floors.
  set estimate(EncoderEstimate value) {
    _estimate = value;
    _probe = null;
    _ceilings = _ceilingsFor(_entries.values.toList());
    _notify();
  }

  // Called after every change to who is admitted or to the ceilings, so a
  // session can tell its tablet the encoder became shared, or not, even when
  // its own ceiling did not move.
  final _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  final _entries = <int, _Entry>{};
  // Sessions whose capture stopped while they go on, by id ([reserve]).
  final _reserved = <int, _Entry>{};
  // Reservations whose tablet is gone ([suspend]).
  final _suspended = <int>{};
  var _ceilings = <int, int>{};
  int _admissions = 0;
  // What was learned of the capacity, per codec, in Mpx/s, all engines.
  final _learned = <CodecType, double>{};
  // The session whose ceiling a probe holds one rung above the rule's.
  int? _probe;

  /// Admits session [id] wanting [wanted], with at most [cap] sessions at
  /// once. Throws [CaptureLimit] when it can't (state unchanged).
  EncodeGrant admit(int id, DisplayConfigModel wanted, {required int cap}) {
    final plan = _plan(id, wanted, cap);
    final before = _ceilings;
    _admissions = math.max(_admissions, plan.entry.order);
    _reserved.remove(id);
    _suspended.remove(id);
    _entries[id] = plan.entry;
    _probe = null;
    _ceilings = plan.ceilings;
    final ceiling = _ceilings[id]!;
    final grant = EncodeGrant(
      config: _withCeiling(plan.entry.config, ceiling),
      reducedResolution: plan.entry.reduced,
      fpsCeiling: ceiling,
      othersChanged: _changed(before, except: id),
    );
    _notify();
    return grant;
  }

  /// Whether a new session wanting [wanted] would be admitted now, by the
  /// same rule as [admit], changing nothing.
  bool wouldFit(DisplayConfigModel wanted, {required int cap}) {
    try {
      _plan(null, wanted, cap);
      return true;
    } on CaptureLimit {
      return false;
    }
  }

  /// Session [id] ended for good (or was refused): its entry, or its
  /// reservation, goes. Returns the ceilings this raised, by id.
  Map<int, int> release(int id) {
    _suspended.remove(id);
    final reserved = _reserved.remove(id) != null;
    if (_entries.remove(id) == null) {
      if (reserved) _notify();
      return const {};
    }
    return _recompute();
  }

  /// Session [id]'s capture stopped, but the session goes on and will start
  /// one again: it keeps its place (see the class comment) while the others
  /// may climb into its room. Returns the ceilings this raised, by id.
  Map<int, int> reserve(int id) {
    final entry = _entries.remove(id);
    if (entry == null) return const {};
    _reserved[id] = entry;
    return _recompute();
  }

  /// Session [id]'s tablet is gone while its session waits for it: its
  /// reservation, if it has one, keeps its place under the cap but no longer
  /// holds room on the encoder for others' admissions (see the class
  /// comment). Changes no ceiling.
  void suspend(int id) {
    if (_reserved.containsKey(id) && _suspended.add(id)) _notify();
  }

  /// Session [id]'s tablet is back: its reservation holds room again.
  void resume(int id) {
    if (_suspended.remove(id)) _notify();
  }

  /// Whether session [id]'s reservation is [suspend]ed.
  bool isSuspended(int id) => _suspended.contains(id);

  Map<int, int> _recompute() {
    final before = _ceilings;
    _probe = null;
    _ceilings = _ceilingsFor(_entries.values.toList());
    final raised = _changed(before);
    _notify();
    return raised;
  }

  /// Session [id] is admitted (its capture runs, or is starting).
  bool contains(int id) => _entries.containsKey(id);

  /// Session [id] holds a place: admitted, or reserved.
  bool holds(int id) => _entries.containsKey(id) || _reserved.containsKey(id);

  /// Whether a session other than [id] holds part of the encoder.
  bool hasOthers(int id) => _entries.keys.any((k) => k != id);

  /// How many sessions are admitted (reservations not counted).
  int get count => _entries.length;

  /// The admitted sessions, by id.
  Iterable<int> get admitted => _entries.keys;

  /// Every admitted session's ceiling, by id.
  Map<int, int> ceilings() => Map.unmodifiable(_ceilings);

  /// The share of the encoder the sessions take at their ceilings, where 1
  /// is the whole estimate (and [usable] the most admission allows).
  double get load => _entries.values
      .fold(0.0, (sum, e) => sum + _demand(e, _ceilings[e.id] ?? e.wanted));

  /// What the encoder is taken to manage with [codec], in Mpx/s, all
  /// engines together: the estimate, or what was learned when that is more.
  double capacity(CodecType codec) =>
      math.max(_estimate.capacity(codec), _learned[codec] ?? 0);

  /// What was learned of the capacity for [codec] (see the class comment),
  /// in Mpx/s; null for nothing. It counts only above the estimate
  /// ([isLearned]).
  double? learned(CodecType codec) => _learned[codec];

  /// Whether [capacity] for [codec] is a learned value, not the estimate.
  bool isLearned(CodecType codec) =>
      (_learned[codec] ?? 0) > _estimate.capacity(codec);

  /// Sets what was learned for [codec] (saved from an earlier run), null to
  /// forget it. Returns the ceilings this changed, by id.
  Map<int, int> setLearned(CodecType codec, double? mpx) {
    if (mpx == null || !mpx.isFinite || mpx <= 0) {
      if (_learned.remove(codec) == null) return const {};
    } else {
      if (_learned[codec] == mpx) return const {};
      _learned[codec] = mpx;
    }
    return _recompute();
  }

  /// What the admitted sessions that adapt their rate (the Max preset, the
  /// only one whose encoder reports overload) encode while every one of
  /// them runs at its ceiling: the load the encoder sustains then, if that
  /// goes on. [running] is each session's rate as its encoder reported it,
  /// by id. Null when not every such session runs at its ceiling (or its
  /// rate is unknown), when none adapts, or when they don't share a codec.
  /// Sessions with a fixed rate count for nothing: their encoder says
  /// nothing of overload.
  EncoderLoad? provenLoad(Map<int, int> running) {
    CodecType? codec;
    var sum = 0.0, largest = 0.0;
    for (final e in _entries.values) {
      if (!e.config.adaptiveFps) continue;
      final fps = running[e.id];
      if (fps == null || fps != _ceilings[e.id]) return null;
      if (codec != null && e.codec != codec) return null;
      codec = e.codec;
      final mpx = e.config.encodedPixels * fps / 1e6;
      sum += mpx;
      largest = math.max(largest, mpx);
    }
    return codec == null ? null : EncoderLoad(codec, sum, largest: largest);
  }

  /// The admitted sessions whose encoder adapts its rate (the Max preset),
  /// by id: the only ones [provenLoad] counts.
  Iterable<int> get adapting => [
        for (final e in _entries.values)
          if (e.config.adaptiveFps) e.id,
      ];

  /// The session a probe is under way for ([startProbe]), if any.
  int? get probing => _probe;

  /// Starts a probe (see the class comment): of the admitted sessions that
  /// adapt their rate, all with one codec and at least two of them, the one
  /// below the rate it wants whose next rung up adds the least load (on a
  /// tie, the first admitted) and no longer fits the capacity (a rung up
  /// that still fits would teach nothing) gets that rung as its ceiling. Null when there
  /// is none, a probe is under way already, or the load it would make is
  /// at or past [failedAt] for its codec (the least load a probe failed at).
  EncodeProbe? startProbe({double? Function(CodecType codec)? failedAt}) {
    if (_probe != null) return null;
    final members = [
      for (final e in _entries.values)
        if (e.config.adaptiveFps) e,
    ];
    if (members.length < 2) return null;
    final codec = members.first.codec;
    if (members.any((e) => e.codec != codec)) return null;
    final everyone = _entries.values.toList(growable: false);
    final rates = {for (final e in everyone) e.id: _ceilings[e.id] ?? e.wanted};
    _Entry? pick;
    var pickFps = 0;
    var pickCost = double.infinity;
    var sum = 0.0, largest = 0.0;
    for (final e in members) {
      final ceiling = rates[e.id]!;
      final mpx = e.config.encodedPixels * ceiling / 1e6;
      sum += mpx;
      largest = math.max(largest, mpx);
      final rung = e.ladder.indexOf(ceiling);
      if (rung <= 0) continue;
      final next = e.ladder[rung - 1];
      // A rung up that still fits what is known (the rule steps the
      // largest demand down, so it can leave one) would prove nothing new.
      if (_fits({...rates, e.id: next}, everyone)) continue;
      final cost = e.config.encodedPixels * (next - ceiling) / 1e6;
      if (cost < pickCost ||
          (cost == pickCost && pick != null && e.order < pick.order)) {
        pick = e;
        pickFps = next;
        pickCost = cost;
      }
    }
    if (pick == null) return null;
    final probed = pick.config.encodedPixels * pickFps / 1e6;
    final load = EncoderLoad(codec, sum + pickCost,
        largest: math.max(largest, probed));
    final failed = failedAt?.call(codec);
    if (failed != null && load.mpx >= failed) return null;
    _probe = pick.id;
    _ceilings = {..._ceilings, pick.id: pickFps};
    _notify();
    return EncodeProbe(pick.id, pickFps, load);
  }

  /// Ends the probe under way: the ceilings go back to the rule's. Returns
  /// those that changed, by id.
  Map<int, int> endProbe() => _probe == null ? const {} : _recompute();

  /// What the admitted sessions achieved together when session [id]'s
  /// encoder could not keep up, at [achievedFps]: its pixels at that rate,
  /// and every other's at the rate it runs at ([running], by id; its
  /// ceiling where unknown). Null unless [id] is admitted with at least one
  /// other and they all share a codec.
  EncoderLoad? achievedLoad(
      int id, double achievedFps, Map<int, int> running) {
    if (_entries.length < 2 || !_entries.containsKey(id)) return null;
    if (!achievedFps.isFinite || achievedFps <= 0) return null;
    final codec = _entries[id]!.codec;
    var sum = 0.0, largest = 0.0;
    for (final e in _entries.values) {
      if (e.codec != codec) return null;
      final fps = e.id == id
          ? achievedFps
          : (running[e.id] ?? _ceilings[e.id] ?? e.wanted).toDouble();
      final mpx = e.config.encodedPixels * fps / 1e6;
      sum += mpx;
      largest = math.max(largest, mpx);
    }
    return EncoderLoad(codec, sum, largest: largest);
  }

  /// [load] was sustained: raises the capacity for its codec until the load
  /// fits (the total within [usable], its largest session within one
  /// engine's share). Never lowers it. Returns the ceilings this changed,
  /// by id, or null when the capacity did not change.
  Map<int, int>? raiseCapacity(EncoderLoad load) {
    final needed =
        math.max(load.mpx, _estimate.engines * load.largest) / usable;
    if (!needed.isFinite || needed <= capacity(load.codec)) return null;
    _learned[load.codec] = needed;
    return _recompute();
  }

  /// An encoder could not keep up while several sessions shared it, and
  /// [load] is what they achieved: what was learned for its codec comes
  /// down to that, never below the estimate (nothing learned: nothing to
  /// lower). Returns the ceilings this changed, by id, or null when the
  /// capacity did not change.
  Map<int, int>? lowerCapacity(EncoderLoad load) {
    final learned = _learned[load.codec];
    if (learned == null || !load.mpx.isFinite) return null;
    final estimate = _estimate.capacity(load.codec);
    final next = math.max(estimate, math.min(learned, load.mpx));
    if (next >= learned) return null;
    if (next <= estimate) {
      _learned.remove(load.codec);
    } else {
      _learned[load.codec] = next;
    }
    return _recompute();
  }

  // ─── The rule ────────────────────────────────────────────────────────────

  // What admitting [id] (null: a session not admitted, for [wouldFit])
  // would leave: its entry and everyone's ceilings. Throws when refused.
  _Plan _plan(int? id, DisplayConfigModel wanted, int cap) {
    final existing = id == null ? null : _entries[id];
    final others =
        _entries.values.where((e) => e.id != id).toList(growable: false);
    final newId = id ?? -1;
    if (existing != null) {
      // (0) Its capture is restarting: it keeps what it was given.
      final entry = existing.withWanted(wanted.copyWith(
        width: existing.config.width,
        height: existing.config.height,
        scaleFactor: existing.config.scaleFactor,
      ));
      return _Plan(entry, _ceilingsFor([...others, entry]));
    }
    // Coming back after its capture stopped: it keeps its order, and the
    // cap does not apply to it.
    final returning = id == null ? null : _reserved[id];
    final held =
        _reserved.values.where((e) => e.id != id).toList(growable: false);
    // The reservations whose tablet is there: only those hold room.
    final holding = held
        .where((e) => !_suspended.contains(e.id))
        .toList(growable: false);
    final order = returning?.order ?? _admissions + 1;
    // (2) The cap, counting every place reserved, a suspended one too. (A
    // cap is at least one, so this never refuses a session alone.)
    final limit = _estimate.tabletCap == null || _estimate.tabletCap! > cap
        ? cap
        : _estimate.tabletCap!;
    if (returning == null && others.length + held.length >= limit) {
      throw const CaptureLimit();
    }
    if (others.isEmpty && holding.isEmpty) {
      // (1) Alone: exactly what it wants.
      final entry = _Entry(newId, wanted, order, reduced: false);
      return _Plan(entry, {newId: entry.wanted});
    }
    // (3) The newcomer's resolution: the first whose floors all fit, beside
    // the reserved places that hold room too. A return that does not fit
    // beside them is tried against the running sessions alone.
    final candidates = _resolutionsFor(wanted);
    for (final beside in [
      [...others, ...holding],
      if (returning != null && holding.isNotEmpty) others,
    ]) {
      for (var i = 0; i < candidates.length; i++) {
        final entry = _Entry(newId, candidates[i], order, reduced: i > 0);
        final members = [...beside, entry];
        if (_fits({for (final m in members) m.id: m.floor}, members)) {
          // (4) The ceilings, of the running sessions.
          return _Plan(entry, _ceilingsFor([...others, entry]));
        }
      }
    }
    throw const CaptureLimit();
  }

  // The newcomer's resolutions, best first: its own, 1920 wide, and the
  // logical size (scale 1, half the panel), each only if it is smaller.
  static List<DisplayConfigModel> _resolutionsFor(DisplayConfigModel wanted) {
    final list = [wanted];
    void tryScale(double scale) {
      final c = wanted.copyWith(scaleFactor: scale);
      if (c.encodedPixels < list.last.encodedPixels) list.add(c);
    }

    // Half a pixel over, so the product doesn't land a hair under 1920 and
    // round down to 1918.
    tryScale(1920.5 / wanted.width);
    tryScale(1.0);
    return list;
  }

  // Everyone at their wanted rate, then the largest demand steps down one
  // rung at a time while the total (or one session, against one engine) is
  // over budget. A session alone keeps its wanted rate whatever it costs.

  Map<int, int> _ceilingsFor(List<_Entry> members) {
    if (members.length <= 1) return {for (final m in members) m.id: m.wanted};
    final rung = {for (final m in members) m.id: 0};
    Map<int, int> rates() =>
        {for (final m in members) m.id: m.ladder[rung[m.id]!]};
    while (!_fits(rates(), members)) {
      _Entry? step;
      var stepDemand = -1.0;
      for (final m in members) {
        if (rung[m.id]! >= m.ladder.length - 1) continue;
        final d = _demand(m, m.ladder[rung[m.id]!]);
        if (d > stepDemand ||
            (d == stepDemand && step != null && m.order > step.order)) {
          step = m;
          stepDemand = d;
        }
      }
      // Everyone at their floor already: a new estimate can leave sessions
      // that no longer fit, and nothing ends them.
      if (step == null) break;
      rung[step.id] = rung[step.id]! + 1;
    }
    return rates();
  }

  // Whether [members] at [rates] fit: the total within [usable], and with
  // several engines each one within one engine's share.
  bool _fits(Map<int, int> rates, List<_Entry> members) {
    const slack = 1e-9;
    final perSession = usable / _estimate.engines;
    var total = 0.0;
    for (final m in members) {
      final d = _demand(m, rates[m.id]!);
      if (d > perSession + slack) return false;
      total += d;
    }
    return total <= usable + slack;
  }

  double _demand(_Entry e, int fps) =>
      e.config.encodedPixels * fps / (capacity(e.codec) * 1e6);

  Map<int, int> _changed(Map<int, int> before, {int? except}) => {
        for (final MapEntry(:key, :value) in _ceilings.entries)
          if (key != except && before[key] != value) key: value,
      };

  // [config] with [ceiling] as its fpsCeiling when it is below the rate.
  static DisplayConfigModel _withCeiling(
          DisplayConfigModel config, int ceiling) =>
      config.withFpsCeiling(ceiling);
}

class _Plan {
  const _Plan(this.entry, this.ceilings);
  final _Entry entry;
  final Map<int, int> ceilings;
}

class _Entry {
  _Entry(this.id, this.config, this.order, {required this.reduced})
      : ladder = _ladderFor(config.refreshRate);

  final int id;

  /// What it was given (resolution included), at its wanted rate.
  final DisplayConfigModel config;

  /// When it was admitted: on a tie, the latest steps down first.
  final int order;
  final bool reduced;
  final List<int> ladder;

  int get wanted => config.refreshRate;
  int get floor => ladder.last;
  CodecType get codec => config.codec;

  _Entry withWanted(DisplayConfigModel config) =>
      _Entry(id, config, order, reduced: reduced);

  static List<int> _ladderFor(int wanted) =>
      ({120, 90, 60, 45, 30, wanted}.where((r) => r <= wanted).toList()
        ..sort((a, b) => b - a));
}
