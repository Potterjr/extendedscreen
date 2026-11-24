import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show protected, visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/platform/permissions_channel.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';

/// HOST role (macOS): the hub that holds one [HostSession] per tablet. Each
/// session is a tablet's whole link (its adb tunnel and loopback port, or
/// the Wi-Fi listener; authentication, capture or decoding, input) with its
/// own copy of the link's state machine. The hub chooses what to connect,
/// owns what there is one of for the app (the device list, the
/// app-lifecycle observer, the media [pipeline], the native plugins'
/// single-slot callbacks, which it routes to the session they are about),
/// and runs no link of its own: no packet loop, heartbeat or retry.
///
/// Over USB it holds up to [cap] sessions side by side, each in the mode it
/// was made for (its [HostSession.choice], fixed for its life: a tablet's
/// mode changes by replacing its session, [changeMode]); over Wi-Fi, one,
/// which a pick replaces. It mirrors the focused one: its [phase],
/// [errorMessage], [activeDevice], [latencyMs], [refreshRateHz],
/// [streamBitrate], [availableDevices] and the reverse-remote observables
/// follow the focused session's, so Home and Settings see what they saw
/// when this class was the link itself.
class HostConnectionManager extends BaseConnectionManager {
  /// [socket] and [port] (tests) go to the sessions it makes: one session at
  /// a time uses an injected socket. Without one, each session gets a socket
  /// of its own. [adb] defaults to the registered [AdbService].
  /// [devicePollInterval] is how often [autoConnect]'s device poll lists
  /// the attached tablets (null: no poll), and [hostGranted] (tests) says
  /// whether Screen Recording and Accessibility are granted.
  /// [capacityWindow] (tests) is how long the encoder must be seen healthy
  /// before what it encodes counts as proven ([EncodeBudget.raiseCapacity]),
  /// and [probeTimeout] (tests) how long a probe waits for its session's
  /// encoder to climb to the rung it was given ([EncodeBudget.startProbe]).
  HostConnectionManager({
    SocketService? socket,
    super.port,
    AdbService? adb,
    Duration? devicePollInterval = const Duration(seconds: 3),
    Future<bool> Function()? hostGranted,
    Duration capacityWindow = const Duration(seconds: 10),
    Duration probeTimeout = const Duration(seconds: 60),
  })  : _injectedSocket = socket,
        _adb = adb ?? Get.find<AdbService>(),
        _pollInterval = devicePollInterval,
        _hostGranted = hostGranted ?? PermissionsChannel().hostGranted,
        _capacityWindow = capacityWindow,
        _probeTimeout = probeTimeout,
        super(socket: socket ?? SocketService()) {
    _adb.onTabletScreenRestored = (serial) {
      for (final s in sessions.values) {
        s.onTabletScreenRestored(serial);
      }
    };
    ever<LinkType>(settings.linkTypeRx, _onLinkTypeChanged);
    // Listen on Wi-Fi beside USB follows its toggle and the cap it needs.
    _besideWorkers = [
      ever<bool>(settings.wifiListenRx, (on) {
        // Turned on: listening is what the user asked for, so a stop of the
        // Wi-Fi session made before no longer holds.
        if (on) stoppedDevices.remove(wifiKey);
        _besideRuleChanged();
      }),
      ever<int>(settings.maxTabletsRx, (_) => _besideRuleChanged()),
    ];
    _sessionsWorker = ever<Map<String, HostSession>>(
        sessions, (_) => _sessionsChanged());
    displays.onRebuildNeeded = _displaySetNeedsRebuild;
    displays.onMirrorRepairNeeded = _mirrorNeedsRepair;
    displays.coveredByRound = _roundWillRestart;
    displays.downForRound = _roundHasDisplaysDown;
    budget.addListener(_encoderStateChanged);
    _routeNativeCallbacks();
    hostInfoReady = _loadHostInfo();
  }

  final AdbService _adb;
  final SocketService? _injectedSocket;
  final Duration? _pollInterval;
  final Future<bool> Function() _hostGranted;

  /// Every session's media pipeline goes through this one queue.
  final pipeline = PipelineQueue();

  /// Each tablet's adb rule, as successive sessions for it take turns.
  final _tunnels = TabletTunnels();

  /// Every session's virtual display: one made while another exists has
  /// the whole set rebuilt in order ([_rebuildDisplays]).
  final displays = VirtualDisplays();

  /// This Mac's encoder, shared by every session's capture. A conservative
  /// guess until [hostInfoReady] has read the chip; one tablet alone gets
  /// what it asks for whatever the estimate.
  final budget = EncodeBudget(EncoderEstimate.conservative);

  /// Done once the chip is known and [budget] estimates from it (at once
  /// without the capture plugin).
  late final Future<void> hostInfoReady;

  /// The chip and macOS version [budget] estimates from, once read. Set
  /// after the estimate, so whoever shows the estimate (Settings' Encoder
  /// line) can watch this alone.
  final hostInfo = Rxn<HostInfo>();

  Future<void> _loadHostInfo() async {
    if (!Get.isRegistered<ScreenCaptureChannel>()) return;
    final info = await Get.find<ScreenCaptureChannel>().getHostInfo();
    if (info == null) return;
    final before = budget.ceilings();
    budget.estimate = EncoderEstimate.forChip(info.chip);
    // What earlier runs learned on this chip: it only ever adds to what
    // this run may have learned already.
    for (final codec in CodecType.values) {
      final saved = settings.encoderCapacityFor(info.chip, codec);
      if (saved != null && saved > (budget.learned(codec) ?? 0)) {
        budget.setLearned(codec, saved);
      }
    }
    _pushCeilingChanges(before);
    capacityChanges.value++;
    hostInfo.value = info;
    log.i('Host: ${info.chip.isEmpty ? 'unknown chip' : info.chip}, '
        'macOS ${info.os}; encoder ${budget.capacity(CodecType.h264).round()} '
        'Mpx/s H.264${budget.isLearned(CodecType.h264) ? ' (learned)' : ''}, '
        '${budget.capacity(CodecType.h265).round()} Mpx/s H.265'
        '${budget.isLearned(CodecType.h265) ? ' (learned)' : ''}');
  }

  /// Bumped whenever what the encoder is taken to manage changes (the chip
  /// read, a capacity learned or lowered), so whoever shows [budget]'s load
  /// or capacity (Home's load line, Settings' Encoder line) rebuilds.
  final capacityChanges = 0.obs;

  // ─── Learning the encoder's capacity ───────────────────────────────────
  //
  // The estimate is a guess. While every capture that adapts its rate (the
  // Max preset) runs at the ceiling the budget gave it for [_capacityWindow]
  // with nothing changing (no overload step-down, no ceiling moved, nobody
  // admitted or gone), and their encoders show they really encoded at that
  // rate, with content changing, through it ([_encodedThrough]), what they
  // encode is a load this encoder sustains, and the budget's capacity is
  // raised to it. With several captures that load always fits what the
  // budget already allows, so a window that teaches nothing starts a probe
  // (one capture a rung higher, [EncodeBudget.startProbe]): the next window,
  // once its encoder has climbed there, teaches the higher load. An
  // overload step-down while several captures share the encoder lowers what
  // was learned, and fails a probe under way. Both are saved per chip and
  // codec. Synthetic tablets teach nothing.

  final Duration _capacityWindow;
  Timer? _capacityTimer;

  // What each adapting session's encoder reported in the window under way
  // ([ScreenCaptureChannel.onEncoderStats]), by native id.
  final _evidence = <int, _EncodeEvidence>{};

  // The probe under way, and its deadline for the probed encoder to climb.
  final Duration _probeTimeout;
  EncodeProbe? _probe;
  Timer? _probeTimer;
  // Per codec, the least load a probe failed at in this run: no probe
  // reaches it again.
  final _probeFailedAt = <CodecType, double>{};

  /// The probe under way (tests).
  @visibleForTesting
  EncodeProbe? get probe => _probe;

  // Each session's grant and capture start, heard by the window.
  final _encoderWorkers = <HostSession, Worker>{};

  /// A healthy window is under way (tests).
  @visibleForTesting
  bool get measuringCapacity => _capacityTimer != null;

  /// What each admitted session's encoder runs at, by native id, once its
  /// capture has started; null while a session that is not a live,
  /// non-synthetic one of [sessions] holds part of the encoder (one being
  /// ended, a synthetic tablet), which teaches nothing.
  Map<int, int>? _runningRates() {
    final byId = {for (final s in sessions.values) s.nativeId: s};
    final running = <int, int>{};
    for (final id in budget.admitted) {
      final s = byId[id];
      if (s == null || SettingsService.isSyntheticKey(s.key)) return null;
      final fps = s.granted.value?.fps;
      if (fps != null && s.captured.value != null) running[id] = fps;
    }
    return running;
  }

  /// Something about the encoder's captures changed: a window under way
  /// ends, and a new one starts if every adapting capture runs at its
  /// ceiling.
  void _encoderStateChanged() {
    _capacityTimer?.cancel();
    _capacityTimer = null;
    _evidence.clear();
    // A probe the budget ended itself (an admission, a release, a capacity
    // learned from it) is over, neither failed nor to be ended again.
    final probe = _probe;
    if (probe != null && budget.probing != probe.id) _clearProbe();
    final running = _runningRates();
    final proven = running == null ? null : budget.provenLoad(running);
    if (proven == null) return;
    _capacityTimer = Timer(_capacityWindow, () {
      _capacityTimer = null;
      final now = _runningRates();
      if (now == null || budget.provenLoad(now) != proven) return;
      if (!_encodedThrough(now)) {
        // Rates as granted, but no proof the encoder carried them (a
        // static screen, or an encoder refusing frames): another window.
        _encoderStateChanged();
        return;
      }
      final changed = budget.raiseCapacity(proven);
      if (changed == null) {
        _startProbe();
        return;
      }
      log.i('Host: encoder sustained $proven — capacity now '
          '${budget.capacity(proven.codec).round()} Mpx/s');
      _capacityLearned(proven.codec, changed);
    });
  }

  /// A second of session [id]'s encoder ([ScreenCaptureChannel
  /// .onEncoderStats]): frames that came back encoded, and frames the
  /// screen delivered, a second. Kept for the window under way.
  void _encoderStats(int id, double encoded, double captured) {
    if (_capacityTimer == null) return;
    final e = _evidence.putIfAbsent(id, _EncodeEvidence.new);
    e.seconds++;
    e.encoded += encoded.isFinite ? encoded : 0;
    if (captured > 0) e.changing++;
  }

  /// [_encoderStats], as the capture plugin's onEncoderStats reaches it
  /// (tests without a capture channel).
  @visibleForTesting
  void encoderStats(int id, double encoded, double captured) =>
      _encoderStats(id, encoded, captured);

  /// Whether every adapting session's encoder showed, over the window, that
  /// it carried the rate it was granted ([running], by id): it reported, its
  /// encoded rate came to at least 95% of that on average, and the screen
  /// it captures changed in at least half of the seconds. A rate granted is
  /// not a rate encoded: an encoder a sleep invalidated refuses every frame
  /// without looking overloaded, and an idle screen re-encodes one frame,
  /// the cheapest work there is.
  bool _encodedThrough(Map<int, int> running) {
    for (final id in budget.adapting) {
      final fps = running[id];
      final e = _evidence[id];
      if (fps == null || e == null || e.seconds == 0) return false;
      if (e.encoded / e.seconds < fps * 0.95) return false;
      if (e.changing * 2 < e.seconds) return false;
    }
    return true;
  }

  /// A proven load taught nothing: one adapting session is given a rung
  /// more than the rule allows, to see whether the encoder takes it.
  void _startProbe() {
    if (_probe != null) return;
    final probe = budget.startProbe(failedAt: (codec) => _probeFailedAt[codec]);
    if (probe == null) return;
    _probe = probe;
    log.i('Host: probing the encoder: $probe');
    _pushCeilings({probe.id: probe.fps});
    // Its encoder climbs there once it has been healthy for a while; one
    // that never gets there did not take it.
    _probeTimer = Timer(_probeTimeout, () {
      _probeTimer = null;
      final s = _byNativeId(probe.id);
      if (_probe == probe && s?.granted.value?.fps != probe.fps) {
        _probeFailed('its encoder did not climb to ${probe.fps} fps');
      }
    });
  }

  /// The probe under way did not hold: its load is remembered as one this
  /// encoder does not take, and the ceilings go back to the rule's.
  void _probeFailed(String why) {
    final probe = _probe;
    if (probe == null) return;
    _clearProbe();
    final codec = probe.load.codec;
    _probeFailedAt[codec] =
        math.min(_probeFailedAt[codec] ?? double.infinity, probe.load.mpx);
    log.w('Host: encoder probe failed ($why): $probe');
    if (budget.probing == probe.id) _pushCeilings(budget.endProbe());
  }

  void _clearProbe() {
    _probe = null;
    _probeTimer?.cancel();
    _probeTimer = null;
  }

  /// Session [id]'s encoder could not keep up and stepped down; [achieved]
  /// is the rate it managed. With other sessions beside it, what they all
  /// achieved is the most the encoder takes ([EncodeBudget.lowerCapacity]).
  /// A probe under way failed.
  void _encoderOverloaded(int id, double achieved) {
    _probeFailed('session $id could not keep up');
    final running = _runningRates();
    if (running == null) return;
    final load = budget.achievedLoad(id, achieved, running);
    if (load == null) return;
    final changed = budget.lowerCapacity(load);
    if (changed == null) return;
    log.w('Host: encoder overloaded at $load — capacity now '
        '${budget.capacity(load.codec).round()} Mpx/s');
    _capacityLearned(load.codec, changed);
  }

  /// What was learned for [codec] changed: saved for this chip, the
  /// [changed] ceilings pushed to their encoders, and the UI told.
  void _capacityLearned(CodecType codec, Map<int, int> changed) {
    final chip = hostInfo.value?.chip ?? '';
    if (chip.isNotEmpty) {
      unawaited(settings.setEncoderCapacityFor(
          chip, codec, budget.learned(codec)));
    }
    _pushCeilings(changed);
    capacityChanges.value++;
  }

  /// Pushes every ceiling that differs from [before] to its encoder.
  void _pushCeilingChanges(Map<int, int> before) {
    _pushCeilings({
      for (final MapEntry(:key, :value) in budget.ceilings().entries)
        if (before[key] != value) key: value,
    });
  }

  /// Hands each session's new ceiling (by native id) to its running
  /// encoder, live, as a session's own admission does.
  void _pushCeilings(Map<int, int> ceilings) {
    if (ceilings.isEmpty || !Get.isRegistered<ScreenCaptureChannel>()) return;
    final capture = Get.find<ScreenCaptureChannel>();
    for (final MapEntry(key: id, value: fps) in ceilings.entries) {
      unawaited(capture.setFrameRateCeiling(fps, session: id));
    }
  }

  /// How many tablets may be connected at once: over USB, the Maximum
  /// tablets setting within what this Mac's encoder is thought to take,
  /// whatever mode each tablet runs in (one the Mac only views counts too,
  /// though it takes nothing of the encoder); over Wi-Fi one, since there
  /// is one listener. This is where it is applied: a tablet with no place
  /// is refused before a session is made for it ([_sessionFor]). A
  /// session's budget admission is handed no less than the places held
  /// ([heldUsbPlaces]), so the budget never refuses, as one tablet too
  /// many, a session that has its place here: not one made before the
  /// setting was lowered, nor the new session of a tablet changing mode.
  int get cap => settings.linkType == LinkType.usb
      ? math.min(settings.maxTablets,
          budget.estimate.tabletCap ?? SettingsService.maxTabletsLimit)
      : 1;

  // What a connect is choosing for: the keys being picked, from the call
  // until the key's session has started connecting (and so shows a
  // connecting phase); [_anyDevice] while a pick without a serial looks for
  // one, [_linkChange] while a link change ends sessions (which holds off
  // every pick). A tablet whose mode is being changed is held here too, from
  // the step that ends its old session until its new one has started
  // ([_replace]), so neither a pick nor the auto-connect policy brings it
  // back meanwhile. With [cap] 1 any entry holds off every pick, as one
  // choice at a time always has.
  final _choosing = <String>{};
  static const _anyDevice = '\u0000any';
  static const _linkChange = '\u0000link';

  // USB tablets whose session is being replaced ([_replace]): out of
  // [sessions] while the old one ends, each still holds its place under
  // [cap], so no other pick takes it. Observable, since the tablets Home
  // offers ([freeDevices]) leave them out.
  final _reserved = <String>{}.obs;

  // disconnect() calls ending every session: nothing new starts meanwhile.
  int _endingAll = 0;

  /// A [disconnect] is ending every session. The hub's observables keep
  /// what they last mirrored until it is done (the facade still reads the
  /// ended session's phase), so Home says so instead of offering anything.
  final endingAll = false.obs;

  // Sessions still ending, by key: a pick of that key waits for the end
  // (TabletTunnels already orders the two sessions' adb calls).
  final _endingKeys = <String, Future<void>>{};

  // Over USB with nothing attached: the next look for a device to connect.
  Timer? _lookAgain;

  /// The sessions, by key: the adb serial over USB, [wifiKey] for the one
  /// Wi-Fi session.
  final sessions = <String, HostSession>{}.obs;

  /// The key of the one Wi-Fi session.
  static const wifiKey = 'wifi';

  /// The session whose values the hub's observables show.
  HostSession? get focused => _focused;
  HostSession? _focused;

  /// [focused]'s key, for the UI to follow (Home marks that tablet's card).
  final focusedKey = RxnString();
  final _mirrors = <Worker>[];

  // Keys in the order they were last focused: when the focused session
  // ends, the most recent one left takes its place.
  final _recent = <String>[];

  // The session using the injected test socket, until it has ended: one at
  // a time, and never two sessions on one socket.
  HostSession? _injectedHolder;

  /// Tablets the user stopped ([disconnectSession] with `userStopped`): the
  /// automatic connects leave them alone until [allowDevice]. In memory
  /// only.
  final stoppedDevices = <String>{}.obs;

  /// The user stopped connecting ([pauseAutoConnect]): nothing connects by
  /// itself until they connect again ([allowDevice]).
  final autoConnectPaused = false.obs;

  @override
  void pauseAutoConnect() => autoConnectPaused.value = true;

  /// The user connected [key] (null: whatever [connect] picks; over Wi-Fi
  /// that is the Wi-Fi session) again.
  @override
  void allowDevice([String? key]) {
    stoppedDevices
        .remove(key ?? (settings.linkType == LinkType.wifi ? wifiKey : null));
    autoConnectPaused.value = false;
    // The pause is over: the listener beside the tablets comes back too.
    unawaited(_listenBeside());
  }

  // Keys an automatic connect has started and whose connect() has not
  // returned yet: the policy neither starts them again nor gives their
  // room under [cap] to another tablet.
  final _starting = <String>{};

  // The device poll ([autoConnect] starts it, [stopPolling] ends it), and
  // whether a tick's listing is still out.
  Timer? _poll;
  bool _polling = false;

  // The baseline the listings keep, to tell a tablet plugged in from one
  // listed all along: each serial seen, and how many successive successful
  // listings it has been missing from since. The first listing only seeds
  // it. [_skippedEmpty]: the poll ignored an empty listing that came right
  // after a non-empty one (adb restarting lists nothing for a moment).
  final _seen = <String, int>{};
  // Successive listings that missed the tablet of a session waiting for it
  // to dial in over USB, by key, with the attempt they missed it during
  // ([_tunnelsGone]).
  final _tunnelMisses = <String, (int, int)>{};
  bool _listedOnce = false;
  bool _skippedEmpty = false;

  /// Attached devices with no session yet (a tablet listed twice, by serial
  /// and by its wireless-debugging name, counts once). A tablet between
  /// two sessions, its mode being changed, is not one of them.
  List<DeviceModel> get freeDevices => [
        for (final d in DeviceModel.withoutMdnsDuplicates(availableDevices))
          if (!sessions.containsKey(d.serial) && !_reserved.contains(d.serial))
            d,
      ];

  /// Some session is live.
  bool get anyActive => sessions.values.any((s) => s.phase.value.isActive);

  /// Some session is on its way to being live (the beside session only
  /// once a device is on it: until then it only listens).
  bool get anyConnecting =>
      sessions.values.any((s) => s.phase.value.isConnecting && !isListening(s));

  /// Sessions over USB, whatever their phase.
  int get usbSessionCount =>
      sessions.values.where((s) => s.link == LinkType.usb).length;

  /// The places taken under [cap]: every USB session, whatever its phase,
  /// and every tablet whose session is being replaced ([changeMode]), which
  /// has none for a moment.
  Set<String> get heldUsbPlaces => {
        for (final s in sessions.values)
          if (s.link == LinkType.usb) s.key,
        ..._reserved,
      };

  /// Some USB tablet is between two sessions, its mode being changed
  /// ([changeMode]): it is in no session for a moment, and comes back.
  /// Observable. Home offers no link selector meanwhile: a link switched
  /// then would be saved and never acted on ([_onLinkTypeChanged] does
  /// nothing during a choice), and the tablet would come back over USB
  /// with the app saying Wi-Fi.
  bool get replacing => _reserved.isNotEmpty;

  /// Every place taken under [cap]: [heldUsbPlaces], and the session
  /// beside them on Wi-Fi while a device is on it ([besideHolds]). What
  /// Home counts, what a new USB tablet is checked against, and what the
  /// policy leaves room by.
  Set<String> get heldPlaces => {...heldUsbPlaces, if (besideHolds) wifiKey};

  /// A pick of a USB tablet with no session would add one beside the
  /// others, rather than replace the one there is (cap 1) or be refused.
  bool get canAdd =>
      !endingAll.value &&
      settings.linkType == LinkType.usb &&
      heldPlaces.length < cap;

  // ─── Wi-Fi beside USB ─────────────────────────────────────────────────────

  /// The Mac listens on Wi-Fi beside its USB tablets: the toggle is on
  /// ([SettingsService.wifiListen]), the link is USB, and [cap] leaves room
  /// for a second device. Then one Wi-Fi session ([wifiKey], made with
  /// [HostSession.beside]) waits for a paired device (an iPhone) while the
  /// USB tablets run on, each device in its own mode.
  bool get wifiBeside => settings.wifiListen && canListenBeside;

  /// Listening on Wi-Fi beside the USB tablets is possible now (the link
  /// is USB and [cap] leaves two places), toggle or not.
  bool get canListenBeside => settings.linkType == LinkType.usb && cap >= 2;

  /// The Wi-Fi session beside the USB tablets, if there is one.
  HostSession? get besideSession {
    final s = sessions[wifiKey];
    return s != null && s.beside ? s : null;
  }

  /// The beside session has a device on it (its peer proved itself): only
  /// then does it count as a tablet under [cap].
  bool get besideHolds => besideSession?.trusted.value ?? false;

  /// [session] is the beside session with no device on it: it only
  /// listens, whatever its phase says (a stranger that finished TLS keeps
  /// it `configuring` for up to 3 s), so it is never focused, takes no
  /// place, and reads as neither connecting nor live to the rules that
  /// look at the others.
  static bool isListening(HostSession session) =>
      session.beside && !session.trusted.value;

  late final List<Worker> _besideWorkers;

  // One per beside session: its trust, to show it while a device is on it.
  final _trustWorkers = <HostSession, Worker>{};

  // Beside sessions made so far, so a start can tell whether it made one.
  int _besideMade = 0;

  /// A device got onto the beside session, or left it. With nothing else
  /// shown, the hub shows it from the moment its device has proved itself;
  /// once it only listens again it is shown no longer (the hub would read
  /// as connecting for nobody), and another session, or `disconnected`,
  /// takes its place.
  void _besideTrustChanged(HostSession session, bool trusted) {
    if (sessions[session.key] != session) return;
    if (trusted) {
      if (_focused == null) _focus(session);
      return;
    }
    if (identical(_focused, session)) {
      _unfocus();
      _refocus(null);
    }
    // Its device gone while the rule no longer wants a listener (Maximum
    // tablets lowered meanwhile): it ends rather than listening again.
    if (!wifiBeside) unawaited(disconnectSession(session.key));
  }

  /// The toggle or Maximum tablets changed: a beside session that the rule
  /// no longer allows ends (the toggle off, or [cap] under 2), and one the
  /// rule wants is started.
  void _besideRuleChanged() {
    final beside = besideSession;
    if (!wifiBeside) {
      // Turned off: it ends. Maximum tablets lowered under 2: only a
      // listener ends; a device on it runs on, as a lowered cap stops no
      // tablet, and the session ends once that device has gone
      // ([_besideTrustChanged]).
      if (beside != null &&
          (!settings.wifiListen ||
              settings.linkType != LinkType.usb ||
              isListening(beside))) {
        unawaited(disconnectSession(beside.key));
      }
      return;
    }
    unawaited(_listenBeside());
  }

  /// Starts the beside session when [wifiBeside] wants one and there is
  /// none, nor one starting, and the user has not stopped it. With the same
  /// permission check as every automatic connect.
  Future<void> _listenBeside() async {
    if (!wifiBeside || !_besideWanted()) return;
    if (!await _hostGranted()) return;
    if (!wifiBeside || !_besideWanted()) return;
    _start(wifiKey);
  }

  // Not held off by [autoConnectPaused]: the switch is what says whether
  // the Mac listens, and a Cancel of the facade's search for a tablet
  // (which pauses) must not leave it reading on with nothing listening.
  bool _besideWanted() =>
      _endingAll == 0 &&
      !sessions.containsKey(wifiKey) &&
      !_endingKeys.containsKey(wifiKey) &&
      !_starting.contains(wifiKey) &&
      !_choosing.contains(wifiKey) &&
      !_choosing.contains(_linkChange) &&
      !stoppedDevices.contains(wifiKey);

  /// Makes the session [key] the one the hub's observables show. Not a
  /// beside session that only listens ([isListening]): the hub would read
  /// as connecting for a device that is not there.
  void focus(String key) {
    final session = sessions[key];
    if (session != null && session != _focused && !isListening(session)) {
      _focus(session);
    }
  }

  static bool _busy(HostSession? s) =>
      s != null && (s.phase.value.isConnecting || s.phase.value.isActive);

  @override
  bool get isHost => true;

  // ─── Reverse remote, every session ────────────────────────────────────────

  /// The sessions of tablets the Mac views and drives, whatever their
  /// phase, sorted by key. Reads [sessions], so an `Obx` that calls it
  /// follows the map (not each session's phase).
  List<HostSession> get remoteSessions => [
        for (final s in sessions.values)
          if (s.spec.isReverseRemote) s,
      ]..sort((a, b) => a.key.compareTo(b.key));

  // What keeps [reverseActive] right: one worker on [sessions], which keeps
  // a phase worker for each session in the map and for no other.
  late final Worker _sessionsWorker;
  final _phaseWorkers = <HostSession, Worker>{};

  /// [sessions] changed, however (a pick, an end, [adopt], a test putting
  /// a session in directly): the sessions that left are no longer watched,
  /// the new ones are, and [reverseActive] is counted again.
  void _sessionsChanged() {
    final now = sessions.values.toSet();
    for (final session in _phaseWorkers.keys.toList()) {
      if (!now.contains(session)) _phaseWorkers.remove(session)!.dispose();
    }
    for (final session in now) {
      _phaseWorkers.putIfAbsent(session,
          () => ever<ConnectionPhase>(session.phase, (_) => _countReverse()));
    }
    _countReverse();
  }

  /// [reverseActive]: the live sessions of tablets the Mac views and
  /// drives. A session's spec is its attempt's, taken before its phase
  /// leaves `disconnected` or `error`, so it is settled by the time the
  /// phase says live.
  void _countReverse() {
    final live = sessions.values
        .where((s) => s.spec.isReverseRemote && s.phase.value.isActive)
        .length;
    if (reverseActive.value != live) reverseActive.value = live;
  }

  // ─── Reverse remote, mirrored from the focused session ────────────────────
  //
  // Focused-session compatibility: the four observables below, and
  // [setTabletScreenOff], [sendRemoteTap] and [sendRemoteSwipe], are the
  // focused session's and say nothing about any other tablet the Mac
  // controls. The remote view no longer uses them: it goes to the sessions
  // themselves ([remoteSessions], each one's own observables and calls,
  // [reconnectSession]), as anything that shows or drives several must.

  /// Texture id of the decoded tablet stream (reverse remote: Mac controls the
  /// tablet). Null unless a reverse-remote session is live; the remote-view
  /// widget renders a `Texture` from it. The focused session's.
  final remoteTextureId = Rxn<int>();

  /// Reverse remote: the tablet's picture has started to arrive this session
  /// (its user approved screen capture), so its panel may go dark now. The
  /// focused session's.
  final tabletStreaming = false.obs;

  /// Reverse remote: the tablet's panel is held off ([setTabletScreenOff]).
  /// The focused session's.
  final tabletScreenOff = false.obs;

  /// A [setTabletScreenOff] is under way, the user's or the remembered
  /// choice's: the toggle waits for it, and another call is refused. The
  /// focused session's.
  final changingTabletScreen = false.obs;

  /// Reverse remote (USB): turns the focused tablet's panel off, or back on
  /// ([HostSession.setTabletScreenOff]). Returns null when done, else why
  /// not.
  Future<String?> setTabletScreenOff(bool off) async {
    final session = _focused;
    if (session == null) return 'no live Mac-controls-tablet session';
    return session.setTabletScreenOff(off);
  }

  /// Reverse remote: a tap on the focused tablet
  /// ([HostSession.sendRemoteTap]).
  void sendRemoteTap(double nx, double ny) => _focused?.sendRemoteTap(nx, ny);

  /// Reverse remote: a swipe on the focused tablet
  /// ([HostSession.sendRemoteSwipe]).
  void sendRemoteSwipe(double nx1, double ny1, double nx2, double ny2,
          {int durationMs = 50}) =>
      _focused?.sendRemoteSwipe(nx1, ny1, nx2, ny2, durationMs: durationMs);

  /// Makes [session] the hub's (and its focused one) without connecting it.
  @visibleForTesting
  void adopt(HostSession session) {
    sessions[session.key] = session;
    _routeNativeCallbacks();
    _focus(session);
  }

  /// Whether the focused session's encoder bitrate is being fitted to the
  /// link right now.
  @visibleForTesting
  bool get adaptingBitrate => _focused?.adaptingBitrate ?? false;

  // ─── Choosing and connecting ──────────────────────────────────────────────

  /// Splash entry point: starts the device poll, loads the device list for
  /// the picker and runs the auto-connect policy ([connectIfUnambiguous]),
  /// as Home does when it opens. Not left to Home: an app launched behind
  /// other windows (or at login, or hidden) is `hidden` to Flutter, which
  /// draws no frames then, so the Home route is not built and its
  /// controller does not run until the window is shown. Without Screen
  /// Recording and Accessibility nothing starts (the policy checks them on
  /// every run); Home asks for them once it is on screen. The poll starts
  /// first all the same, so a Mac granted them later still connects a
  /// tablet plugged in after that.
  @override
  Future<void> autoConnect() async {
    _startPolling();
    // A Cancel or Disconnect (or a retry) after this point owns what
    // happens next: adb can take seconds to answer its first call.
    final attempt = currentAttempt;
    // Over Wi-Fi nothing waits on adb: the list is only for the picker.
    final listing = refreshDevices();
    if (settings.linkType != LinkType.wifi) await listing;
    if (isCancelled(attempt)) return;
    await connectIfUnambiguous(since: attempt);
  }

  /// Lists the attached devices for the picker. A listing that failed
  /// (adb missing, failed or timed out) changes nothing: it says nothing
  /// about which tablets are attached.
  @override
  Future<void> refreshDevices() async {
    final devices = await _adb.listDevicesOrNull();
    if (devices != null) _listed(devices);
  }

  /// Takes a successful listing: the picker shows it, and the baseline
  /// learns from it. A serial counts as gone only once two successive
  /// listings have missed it, so a tablet that drops out of one listing
  /// (adb restarting, a cable wiggle) does not come back as a new one.
  /// Tablets that appeared, listed now and not in the baseline, are handed
  /// to [_appeared]; the first listing only seeds the baseline, since what
  /// is attached at launch is the launch's to connect. When the launch's
  /// listings all failed (adb slow or failing at login), the first
  /// successful one is the poll's ([fromPoll]): the policy then runs on it
  /// once, for every tablet, since the launch's found nothing to connect.
  void _listed(List<DeviceModel> devices, {bool fromPoll = false}) {
    final first = !_listedOnce;
    availableDevices.value = devices;
    final present = {
      for (final d in DeviceModel.withoutMdnsDuplicates(devices)) d.serial,
    };
    final appeared = _listedOnce
        ? present.where((s) => !_seen.containsKey(s)).toSet()
        : <String>{};
    _listedOnce = true;
    for (final serial in _seen.keys.toList()) {
      if (present.contains(serial)) continue;
      final misses = _seen[serial]! + 1;
      if (misses >= 2) {
        _seen.remove(serial);
      } else {
        _seen[serial] = misses;
      }
    }
    for (final serial in present) {
      _seen[serial] = 0;
    }
    _tunnelsGone(devices);
    _appeared(appeared, present);
    if (fromPoll && first) unawaited(connectIfUnambiguous());
  }

  /// A listing's news: a session waiting for its unplugged tablet
  /// (`error_device_gone`) whose tablet is listed again retries now, rather
  /// than when its backoff runs out; tablets plugged in run the policy for
  /// them alone. Not every listing runs the whole policy, so the poll does
  /// not connect again a tablet that stays plugged in after a Disconnect
  /// (the next resume or Home focus may: the remote view's Disconnect
  /// pauses nothing).
  void _appeared(Set<String> appeared, Set<String> present) {
    for (final serial in present) {
      final session = sessions[serial];
      if (session != null &&
          session.phase.value == ConnectionPhase.error &&
          session.errorKey.value == 'error_device_gone') {
        unawaited(retryNow(serial));
      }
    }
    if (appeared.isNotEmpty) unawaited(connectIfUnambiguous(only: appeared));
  }

  /// A session waiting for its tablet to dial in over USB can't tell that
  /// adb has dropped the tablet's transport meanwhile (the cable re-seated,
  /// or unplugged): its reverse rule went with it, so the tablet can never
  /// reach that session's port, and nothing on the Mac fails. A listing
  /// that lists the tablet under another transport id tells it so
  /// ([HostSession.tunnelLost]); so do two successive listings that miss
  /// it, the same rule as the baseline's ([_listed]), since one miss alone
  /// can be adb hiccupping, or a listing taken before the session's own.
  void _tunnelsGone(List<DeviceModel> devices) {
    final listed = {for (final d in devices) d.serial: d};
    final waiting = <String>{};
    for (final session in sessions.values.toList()) {
      if (session.link != LinkType.usb ||
          session.phase.value != ConnectionPhase.handshaking) {
        continue;
      }
      final key = session.key;
      waiting.add(key);
      final now = listed[key];
      final then = session.activeDevice.value?.transportId;
      final bool lost;
      if (now == null) {
        // Counted for this attempt only: a later one listed its tablet
        // itself before it began to wait.
        final attempt = session.currentAttempt;
        final before = _tunnelMisses[key];
        final misses = before != null && before.$1 == attempt ? before.$2 : 0;
        _tunnelMisses[key] = (attempt, misses + 1);
        lost = misses + 1 >= 2;
      } else {
        _tunnelMisses.remove(key);
        lost = then != null &&
            now.transportId != null &&
            now.transportId != then;
      }
      if (lost) {
        _tunnelMisses.remove(key);
        session.tunnelLost();
      }
    }
    // A miss counts only towards a wait that goes on: once it has ended
    // (the tablet dialled in, or the attempt failed), it starts afresh.
    _tunnelMisses.removeWhere((key, _) => !waiting.contains(key));
  }

  void _startPolling() {
    final every = _pollInterval;
    if (every == null || _poll != null) return;
    _poll = Timer.periodic(every, (_) => _pollDevices());
  }

  /// Ends the device poll (when the app goes, or a test ends).
  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// One tick of the poll: lists the devices, which notices a tablet
  /// plugged in ([_listed]). One listing at a time, and none while a
  /// session is finding its tablet or setting up its tunnel (adb is busy
  /// with it, and its own listing is about to say the same) or over Wi-Fi.
  Future<void> _pollDevices() async {
    if (_polling ||
        settings.linkType == LinkType.wifi ||
        sessions.values.any((s) =>
            s.phase.value == ConnectionPhase.detectingDevice ||
            s.phase.value == ConnectionPhase.portForwarding)) {
      return;
    }
    _polling = true;
    final List<DeviceModel>? devices;
    try {
      devices = await _adb.listDevicesOrNull();
    } finally {
      _polling = false;
    }
    if (devices == null || _poll == null) return;
    // adb restarting lists nothing for a moment: one empty listing right
    // after a non-empty one is not taken as every tablet unplugged.
    if (devices.isEmpty && availableDevices.isNotEmpty && !_skippedEmpty) {
      _skippedEmpty = true;
      return;
    }
    _skippedEmpty = false;
    _listed(devices, fromPoll: true);
  }

  /// Connects a tablet over the link Home has chosen: over Wi-Fi the one
  /// Wi-Fi session (listening for the paired tablet); over USB the device
  /// [serial], else the focused session's own device when it waits to
  /// retry (a retry run early), else the last-used device if it is
  /// attached, else the first one attached; with none attached and no
  /// session, it says so and looks again every second.
  ///
  /// With [cap] 1 (over Wi-Fi, or Maximum tablets 1) and at most one
  /// session, as there always was: only while nothing is connecting or
  /// connected, one call at a time, and picking another device ends the
  /// focused session first. Otherwise per tablet, whatever the modes: a
  /// pick adds a session for a tablet that has none (up to [cap], counting
  /// every USB session), runs the pending retry of one in `error`, and does
  /// nothing for one connecting or live, or while that tablet is being
  /// picked already; a tablet whose session is still ending is connected
  /// once that has ended. A pick without a serial takes only devices with
  /// no session. The session picked is focused.
  ///
  /// This is the user's connect (a tile of the Add panel, the Connect
  /// button, the Loopback preview's Start): a session it makes runs in the
  /// mode Home's selectors show at this call
  /// ([SettingsService.nextChoice]). Every other connect that picks a
  /// tablet goes to [connectWith] with a mode of its own, or none.
  /// [changeMode] does not: it starts its new session itself ([_replace]).
  @override
  Future<void> connect({String? serial}) =>
      connectWith(serial, choice: settings.nextChoice);

  /// [connect], for whoever says the mode: a session made here runs as
  /// [choice]; without one, in the mode its tablet is remembered in
  /// ([SettingsService.knownChoice]: the auto-connect policy's connects,
  /// and the hub's own after a link change), else as the selectors stood
  /// when this was called (read before anything is awaited, so a slow adb
  /// listing does not pick up a later change). A session that exists
  /// already (a retry run early, a card's Retry, the same tablet with [cap]
  /// 1) keeps the mode it was made for, whatever is passed.
  @override
  @protected
  Future<void> connectWith(String? serial, {SessionChoice? choice}) async {
    final fallback = settings.nextChoice;
    if (_endingAll > 0 || _choosing.contains(_linkChange)) return;
    // The Wi-Fi session over USB is the one beside the tablets, only while
    // that is on; it runs in the mode it was last given, if any.
    if (serial == wifiKey && settings.linkType == LinkType.usb) {
      if (!wifiBeside) return;
      choice = settings.wifiListenChoice ?? choice;
    }
    final single = cap == 1 && sessions.length <= 1;
    if (single) {
      // The session's own phase too, not only the one shown: a session
      // the hub did not show would otherwise be taken for idle.
      if (_choosing.isNotEmpty ||
          phase.value.isConnecting ||
          phase.value.isActive ||
          sessions.values.any(_busy)) {
        return;
      }
    } else if (_choosing.contains(serial ?? _anyDevice) ||
        _busy(serial == null ? null : sessions[serial])) {
      return;
    }
    // What this call holds in [_choosing]; a pick without a serial adds the
    // device it settles on.
    final held = {serial ?? _anyDevice};
    _choosing.addAll(held);
    _lookAgain?.cancel();
    final HostSession? session;
    try {
      session = await _choose(serial,
          single: single, held: held, choice: choice, fallback: fallback);
    } finally {
      _choosing.removeAll(held);
    }
    // A disconnect() may have ended it while the choice returned.
    if (session == null || sessions[session.key] != session) return;
    // Synchronously after the choice, and in this order: the session's
    // phase is a connecting one before the hub shows it, so the hub's goes
    // straight there (never through a new session's `disconnected`), before
    // anything else can run.
    final connecting = session.connect();
    // The beside session is shown only once a device is on it (a tap on its
    // card, or [_refocus]); listening, it would make the hub read as
    // connecting for nobody.
    if (session != _focused && !session.beside) _focus(session);
    await connecting;
  }

  /// Which session [connectWith] goes on with; null when there is none to
  /// connect (nothing attached, the tablet is being picked or is busy
  /// already, no room under [cap], or a [disconnect] came meanwhile). A new
  /// one runs as [choice], else as its tablet is remembered, else as
  /// [fallback].
  Future<HostSession?> _choose(String? serial,
      {required bool single,
      required Set<String> held,
      required SessionChoice? choice,
      required SessionChoice fallback}) async {
    final attempt = currentAttempt;
    var link = settings.linkType;
    final focused = _focused;
    final String key;
    if (link == LinkType.wifi) {
      key = wifiKey;
    } else if (serial == wifiKey) {
      // [connectWith] let it through only with [wifiBeside].
      key = wifiKey;
      link = LinkType.wifi;
    } else if (serial != null) {
      key = serial;
    } else if (focused != null &&
        focused.link == LinkType.usb &&
        (single || focused.phase.value == ConnectionPhase.error)) {
      key = focused.key;
    } else {
      // The facade shows a session's phase whenever one is focused.
      if (single || focused == null) setPhase(ConnectionPhase.detectingDevice);
      final listing = await _adb.listDevicesOrNull();
      if (isCancelled(attempt)) return null;
      if (listing != null) _listed(listing);
      final devices = listing ?? const <DeviceModel>[];
      final candidates = single
          ? devices
          : [
              for (final d in DeviceModel.withoutMdnsDuplicates(devices))
                if (!sessions.containsKey(d.serial) &&
                    !_reserved.contains(d.serial))
                  d,
            ];
      final preferred = settings.lastDeviceSerial;
      final picked =
          candidates.firstWhereOrNull((d) => d.serial == preferred)?.serial ??
              candidates.firstOrNull?.serial;
      if (picked == null) {
        // Every attached tablet has its session: nothing to add.
        // (A beside session that only listens is no tablet: it leaves the
        // hub to say that no device is attached, and to look again.)
        if (!single && sessions.values.any((s) => !isListening(s))) {
          return null;
        }
        // Nothing to fix a session to yet: say so, and look again, taking
        // whichever tablet is plugged in first (the last-used one if it is
        // among them).
        errorMessage.value = 'Exception: No ADB device detected';
        errorKey.value = null;
        setPhase(ConnectionPhase.error);
        // With the mode this call was given, as it was given it.
        _lookAgain = Timer(const Duration(seconds: 1), () {
          if (!isCancelled(attempt) && _focused == null) {
            connectWith(null, choice: choice);
          }
        });
        return null;
      }
      key = picked;
    }
    if (!single && !held.contains(key)) {
      // Settled on without a serial (or over Wi-Fi): the key is held from
      // here on like a picked one.
      if (_choosing.contains(key) || _busy(sessions[key])) return null;
      _choosing.add(key);
      held.add(key);
    }
    return _sessionFor(key, link, attempt,
        single: single, choice: choice, fallback: fallback);
  }

  /// The session [key] on [link]. With [single], the focused one when it is
  /// that, else a new one, once the focused session (another tablet, or the
  /// other link) has ended. Otherwise the session [key] when it waits to
  /// retry, else a new one beside the others while there is room under
  /// [cap]. Null when there is nothing to connect, or a [disconnect] came
  /// meanwhile. The caller focuses it.
  ///
  /// A session that exists keeps the mode it was made for. A new one is
  /// made as [choice], else as the tablet is remembered
  /// ([SettingsService.knownChoice]), else as [fallback] (the selectors as
  /// they stood when the connect was asked for), and keeps that for its
  /// life, over Wi-Fi too.
  Future<HostSession?> _sessionFor(String key, LinkType link, int attempt,
      {required bool single,
      SessionChoice? choice,
      SessionChoice? fallback}) async {
    if (single) {
      // The one session there is ([single]: at most one), whether or not
      // it is the one shown. Going by the shown one alone took a session
      // that was not shown for no session: a second one was made for its
      // tablet, and the first ran on where nothing could end it.
      final current = sessions.values.firstOrNull ?? _focused;
      if (current != null && current.key == key && current.link == link) {
        return current;
      }
      if (current != null) {
        // What Home shows while the old session ends: never `disconnected`
        // mid-pick.
        await _endSession(current,
            showing: link == LinkType.wifi
                ? ConnectionPhase.handshaking
                : ConnectionPhase.detectingDevice);
        if (isCancelled(attempt)) return null;
      }
    } else {
      final existing = sessions[key];
      if (existing != null) {
        if (_busy(existing)) return null;
        // In `error`: its retry, run early (the user's Retry, if the
        // encoder refused it), on the same session and native id.
        return existing;
      }
    }
    final ending = _endingKeys[key];
    if (ending != null) {
      await ending;
      if (isCancelled(attempt)) return null;
    }
    // Never over a session that is there: that one would run on, out of
    // the map and out of reach.
    final there = sessions[key];
    if (there != null) return _busy(there) ? null : there;
    // Counted after every await: live sessions keep running when the cap
    // is lowered under their number; only new ones are refused. A tablet
    // whose session is being replaced is no new one: its place is held
    // ([_reserved]), and counts against every other pick.
    final beside = link == LinkType.wifi && settings.linkType == LinkType.usb;
    // Turned off (or the cap lowered) while this was being chosen, or while
    // its last session ended.
    if (beside && !wifiBeside) return null;
    final held = heldPlaces..remove(key);
    // The beside session is made whatever the count: listening, it holds
    // no place; the device that dials in is admitted to the encoder like a
    // new tablet, against [cap] ([HostSession.beside]).
    if (!single && !beside && !_reserved.contains(key) && held.length >= cap) {
      log.w(
        'Host: $key not connected: ${held.length} of $cap tablets '
        'already',
      );
      return null;
    }
    final usb = link == LinkType.usb;
    final injected = _injectedSocket != null && _injectedHolder == null;
    final session = HostSession(
      key: key,
      link: link,
      serial: usb ? key : null,
      choice: choice ?? settings.knownChoice(key) ?? fallback,
      pipeline: pipeline,
      tunnels: _tunnels,
      displays: displays,
      adb: _adb,
      budget: budget,
      // The hub's check above is the cap. The budget's own must not
      // refuse a session that holds a place here (see [cap]).
      // The beside session's place is a new tablet's every time: [cap]
      // as it is, so the encoder refuses it when the tablets fill it.
      // With every place taken by the USB tablets (one still dialling in
      // holds its place here, though not yet in the budget), the device is
      // turned away: a cap of 0 refuses it.
      cap: beside
          ? () => heldUsbPlaces.length >= cap ? 0 : cap
          : () => math.max(cap, heldPlaces.length),
      beside: beside,
      // Over the Wi-Fi link the one display every build has made; over USB
      // the tablet's own, and beside the USB tablets the Wi-Fi device's
      // own (serial 1 may be a tablet's), never one a live display has.
      vdSerial: usb || beside
          ? settings.vdSerialFor(
              key,
              taken: {for (final s in sessions.values) s.vdSerial},
            )
          : 1,
      vdName: settings.vdNameFor(
        key,
        model: beside
            ? LinkType.wifi.chipLabel
            : availableDevices.firstWhereOrNull((d) => d.serial == key)?.model,
      ),
      socket: injected ? _injectedSocket : SocketService(),
      port: linkPort,
    );
    if (injected) _injectedHolder = session;
    if (link == LinkType.usb) _tunnels.claim(key, session);
    sessions[key] = session;
    _encoderWorkers[session] = everAll([
      session.granted,
      session.captured,
    ], (_) => _encoderStateChanged());
    if (beside) {
      _besideMade++;
      _trustWorkers[session] = ever<bool>(
        session.trusted,
        (t) => _besideTrustChanged(session, t),
      );
    }
    _routeNativeCallbacks();
    return session;
  }

  /// Ends [session] for good. It is out of reach at once (out of
  /// [sessions], refusing to connect, and in [_endingKeys] until it has
  /// ended), so nothing can pick it again while it ends; then its link
  /// ends, then its native state. When it was the focused one, the hub
  /// shows the most recently focused session left, at once; with none
  /// left, [showing] (`disconnected` unless a pick is replacing it, or
  /// another tablet is between two sessions, [replacing]). Not
  /// while a [disconnect] ends them all: that sets `disconnected` at its
  /// end, as it always has.
  Future<void> _endSession(HostSession session,
      {ConnectionPhase? showing}) async {
    if (sessions[session.key] == session) {
      sessions.remove(session.key);
      _recent.remove(session.key);
    }
    // A repair it asked for is asked for nobody now.
    _repairs.remove(session);
    if (_focused == session) {
      _unfocus();
      // What its teardown would have shown, mirrored.
      activeDevice.value = null;
      streamBitrate.value = null;
      remoteTextureId.value = null;
      tabletStreaming.value = false;
      tabletScreenOff.value = false;
      changingTabletScreen.value = false;
      // Before anything is awaited: the facade never shows the ended
      // session's values, nor `disconnected` while a pick replaces it or
      // while another tablet, between two sessions, is on its way back
      // ([_replace] sets `disconnected` if that one does not come back).
      if (_endingAll == 0) {
        _refocus(showing ??
            (_reserved.isNotEmpty ? ConnectionPhase.detectingDevice : null));
      }
    }
    final ended = Completer<void>();
    _endingKeys[session.key] = ended.future;
    try {
      session.retire();
      _encoderWorkers.remove(session)?.dispose();
      _trustWorkers.remove(session)?.dispose();
      _encoderStateChanged();
      await session.disconnect();
      session.dispose();
      if (Get.isRegistered<ScreenCaptureChannel>()) {
        final capture = Get.find<ScreenCaptureChannel>();
        await pipeline
            .run(() => capture.disposeSession(session: session.nativeId));
      }
    } finally {
      if (_injectedHolder == session) _injectedHolder = null;
      if (_endingKeys[session.key] == ended.future) {
        _endingKeys.remove(session.key);
      }
      ended.complete();
      // The toggle may have been turned off and on again while it ended:
      // the listener it asked for could not start then.
      if (session.beside) unawaited(_listenBeside());
    }
  }

  /// The hub's observables follow the most recently focused session left
  /// (else any session left: the hub never reads idle while it has one);
  /// with none, they show [showing] (else `disconnected`) and no error.
  void _refocus(ConnectionPhase? showing) {
    for (final key in _recent.reversed) {
      final next = sessions[key];
      if (next != null && !isListening(next)) {
        _focus(next);
        return;
      }
    }
    final left = sessions.values.where((s) => !isListening(s)).lastOrNull;
    if (left != null) {
      _focus(left);
      return;
    }
    errorMessage.value = '';
    errorKey.value = null;
    setPhase(showing ?? ConnectionPhase.disconnected);
  }

  /// The tablet whose session is [key] is to run as [choice] from now on.
  /// A session never changes what it is ([HostSession.choice] is final, so
  /// its teardown undoes exactly what its attempts built): it is ended and
  /// a new one made for the same key, with a new native id and, over USB,
  /// the tablet's own virtual-display serial ([_replace]). The other
  /// tablets run on.
  ///
  /// Nothing, and false, when there is no such session, it is no longer
  /// [expected] (the one the caller was looking at: a menu opened before
  /// the session was replaced), it has been ended, the tablet is being
  /// picked or its last session still ends, a [disconnect] or a link change
  /// is under way, the session is on its way to being live (its attempt is
  /// left to finish or fail), or [choice] comes to what it already runs as
  /// on its link ([SessionChoice.sameEffect]; over Wi-Fi the direction
  /// means nothing). Otherwise true, once the new session's connect has
  /// returned (as [connect] does), or a [disconnect] has overtaken it.
  @override
  Future<bool> changeMode(String key, SessionChoice choice,
      {HostSession? expected}) async {
    final old = sessions[key];
    if (old == null ||
        (expected != null && !identical(expected, old)) ||
        old.isRetired ||
        _endingKeys.containsKey(key) ||
        _choosing.contains(key) ||
        _choosing.contains(_linkChange) ||
        // With one tablet at a time, a pick under way may be replacing
        // this very session.
        (cap == 1 && sessions.length <= 1 && _choosing.isNotEmpty) ||
        _endingAll > 0 ||
        // The beside session may change while it only listens: there is
        // no attempt of a device's to let finish.
        (old.phase.value.isConnecting && !isListening(old)) ||
        old.choice
            .effective(link: old.link)
            .sameEffect(choice.effective(link: old.link))) {
      return false;
    }
    await _replace(old, choice);
    return true;
  }

  /// Ends [old] and makes its tablet a new session as [choice], then
  /// connects it; focused if [old] was.
  ///
  /// Everything up to the first await is one synchronous step, and has to
  /// stay one: the key is in [_choosing] (no pick and no automatic connect
  /// brings the tablet back in its old mode while [old] ends) and, over
  /// USB, in [_reserved] (its place under [cap] is not given away while it
  /// has no session) before [old] leaves [sessions]. An await between them
  /// would open both races. The tablet's remembered mode is the new one
  /// from that step on too ([SettingsService.setKnownChoice]; a tablet not
  /// known yet is remembered when its new session goes live).
  ///
  /// When [old] was the only session, the hub shows a connecting phase
  /// while it ends, never `disconnected`: with one tablet at a time that is
  /// what holds off a pick, and with more it keeps Home from offering the
  /// link selector, and the policy from taking the hub for idle, in a
  /// moment when a tablet is on its way back.
  Future<void> _replace(HostSession old, SessionChoice choice) async {
    final key = old.key;
    final link = old.link;
    final usb = link == LinkType.usb;
    final wasFocused = identical(_focused, old);
    final attempt = currentAttempt;
    // A beside session listens again for a moment: the hub shows nothing
    // for it, so with nothing else it reads `disconnected`.
    final showing = usb
        ? ConnectionPhase.detectingDevice
        : old.beside
            ? null
            : ConnectionPhase.handshaking;
    _choosing.add(key);
    if (usb) _reserved.add(key);
    final ending = _endSession(old, showing: showing);
    if (old.beside) {
      settings.setWifiListenChoice(choice);
    } else {
      settings.setKnownChoice(key, choice);
    }
    HostSession? session;
    try {
      await ending;
      if (!isCancelled(attempt) && _endingAll == 0) {
        session = await _sessionFor(key, link, attempt,
            single: false, choice: choice);
      }
    } finally {
      _choosing.remove(key);
      _reserved.remove(key);
      // Nothing came back (a Disconnect of everything, which sets
      // `disconnected` itself when it is done, or no session made): the
      // connecting phase shown for it must not stay.
      // Unless another tablet is still on its way back: its own replace
      // settles this.
      if ((session == null || sessions[key] != session) &&
          _focused == null &&
          _reserved.isEmpty &&
          _endingAll == 0 &&
          phase.value == showing) {
        setPhase(ConnectionPhase.disconnected);
      }
    }
    if (session == null || sessions[key] != session) return;
    // As in [connectWith]: connecting before it is shown, so the hub's
    // phase never passes through a new session's `disconnected`.
    final connecting = session.connect();
    if (session.beside && wasFocused) {
      // Listening again for a moment: shown once its device is back.
      _recent
        ..remove(key)
        ..add(key);
    } else if (!session.beside && (wasFocused || _focused == null)) {
      _focus(session);
    } else {
      // Not the one shown, but in the focus history like every session,
      // as the least recent: when the shown one ends, [_refocus] takes
      // the tablets that were shown before this one. (It finds a session
      // that is in no history too, so the hub does not read
      // `disconnected` with this tablet live either way.)
      _recent
        ..remove(key)
        ..insert(0, key);
    }
    await connecting;
  }

  /// Ends the session [key] alone; the others run on, and the hub shows
  /// another one if it was focused. With [userStopped] the tablet joins
  /// [stoppedDevices]. Unlike [disconnect] it cancels no pick of another
  /// tablet. Done once the session has ended.
  @override
  Future<void> disconnectSession(String key, {bool userStopped = false}) {
    if (userStopped) stoppedDevices.add(key);
    final session = sessions[key];
    if (session != null) return _endSession(session);
    return _endingKeys[key] ?? Future<void>.value();
  }

  /// Runs the pending retry of the session [key] now: only one in `error`
  /// that the encoder did not refuse (that one waits for the user).
  @override
  Future<void> retryNow(String key) async {
    final session = sessions[key];
    if (_endingAll > 0 ||
        session == null ||
        session.refused.value ||
        session.phase.value != ConnectionPhase.error) {
      return;
    }
    await session.connect();
  }

  /// Ends every session; nothing new starts until it is done.
  @override
  Future<void> disconnect() async {
    _endingAll++;
    endingAll.value = true;
    try {
      await super.disconnect();
    } finally {
      _endingAll--;
      endingAll.value = _endingAll > 0;
    }
    // Listening on Wi-Fi beside the tablets follows its switch alone: it
    // comes back after every tablet is disconnected.
    unawaited(_listenBeside());
  }

  /// Every session ends ([disconnect] runs this).
  @override
  Future<void> onTeardown() async {
    _lookAgain?.cancel();
    for (final session in sessions.values.toList()) {
      await _endSession(session);
    }
  }

  /// Applies a settings change: every session connecting, live or waiting
  /// to retry reconnects (its next attempt takes the new settings), each on
  /// the same object and native id. One in `error` reconnects at once (its
  /// device survives the lost link), which the remote view's Reconnect
  /// relies on; one the encoder refused waits for the user.
  @override
  Future<void> reconnect() => _reconnectWhere((_) => true);

  /// [reconnect] for the tablets the Mac extends onto alone: what a change
  /// of the display mode needs, since a remote-control session mirrors the
  /// real desktop whatever that setting says (and a tablet the Mac controls
  /// would have to approve its capture again for nothing).
  @override
  Future<void> reconnectExtendedOnly() =>
      _reconnectWhere((s) => s.spec.mode == SessionMode.extendedScreen);

  /// [reconnect] for the session [key] alone, by the same rule; the others
  /// run on. Nothing for a key with no session.
  @override
  Future<void> reconnectSession(String key) {
    final session = sessions[key];
    if (session == null) return Future<void>.value();
    return _reconnectWhere((s) => identical(s, session));
  }

  /// Reconnects, side by side, every session [test] takes that may
  /// reconnect: one connecting, live or in `error`, and not one the encoder
  /// refused.
  Future<void> _reconnectWhere(bool Function(HostSession) test) async {
    await Future.wait([
      for (final s in sessions.values.toList())
        if (test(s) &&
            !s.refused.value &&
            (s.phase.value.isConnecting ||
                s.phase.value.isActive ||
                s.phase.value == ConnectionPhase.error))
          s.reconnect(),
    ]);
  }

  /// Host → tablet: the overlay/HUD toggles, to every tablet.
  @override
  void sendUiFlags() {
    for (final session in sessions.values) {
      session.sendUiFlags();
    }
  }

  /// Discards this Mac's Wi-Fi identity (Settings → Reset Wi-Fi pairing): no
  /// tablet paired so far can connect over Wi-Fi again until it has been
  /// connected over USB once more. Each session then does its part
  /// ([HostSession.identityWasReset]): the Wi-Fi one listens again with the
  /// new identity, a live USB one hands its tablet the new identity.
  @override
  Future<void> resetWifiIdentity() async {
    await Get.find<WifiPairingService>().resetIdentity();
    for (final session in sessions.values.toList()) {
      await session.identityWasReset();
    }
  }

  /// The app's lifecycle, for every session: a detached app ends them all
  /// (and the poll); on resume each one that lost its link and is not
  /// already retrying reconnects to its device (the base class's rule, per
  /// session), and the auto-connect policy runs, permissions checked: Home
  /// runs it on resume too, but an app launched hidden has no Home yet.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      stopPolling();
      disconnect();
      return;
    }
    for (final session in sessions.values.toList()) {
      session.didChangeAppLifecycleState(state);
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(connectIfUnambiguous());
    }
  }

  @override
  void onClose() {
    stopPolling();
    _lookAgain?.cancel();
    _capacityTimer?.cancel();
    _capacityTimer = null;
    _clearProbe();
    budget.removeListener(_encoderStateChanged);
    _sessionsWorker.dispose();
    for (final worker in [..._besideWorkers, ..._trustWorkers.values]) {
      worker.dispose();
    }
    _trustWorkers.clear();
    for (final worker in _phaseWorkers.values) {
      worker.dispose();
    }
    _phaseWorkers.clear();
    super.onClose();
  }

  /// The auto-connect policy: connects without a tap what needs no choice.
  /// The launch, Home (opening, or the app coming back to the front), a
  /// resume and the device poll run it, never the user, so nothing starts
  /// without Screen Recording and Accessibility, nor while the user has
  /// paused it ([pauseAutoConnect]) or a [disconnect] (the user's Cancel or
  /// Disconnect), a link failure or a restart came after [since] (a
  /// [currentAttempt] the caller took before its own awaits; by default,
  /// now).
  ///
  /// Over Wi-Fi: start listening, only while no session exists, the hub is
  /// `disconnected` and the user has not stopped the Wi-Fi session
  /// ([stoppedDevices]). Over USB the candidates are the attached tablets
  /// with no session that the user has not stopped, emulators only when no
  /// real tablet is attached (stand-in tablets never), and only those in
  /// [only] when given (the poll's tablets just plugged in). Whichever rule
  /// takes a tablet, it comes back in the mode it is remembered in
  /// ([_start]), not in the one the selectors show:
  /// - with no session, the hub `disconnected` and exactly one candidate,
  ///   that one (the first-run rule: one tablet connects whether or not it
  ///   was seen before; two wait for the user's pick). Deliberately not
  ///   keyed off the saved last-used serial: that's persisted on every
  ///   connect *attempt*, so a reconnect-timer fallback can leave it
  ///   pointing at the wrong device, and a wrong pick strands the host
  ///   mid-handshake with no picker visible;
  /// - with [cap] over 1, also every candidate that has had a live session
  ///   before (the known devices), in serial order, while there is room.
  /// Each is started without waiting for its connect to finish.
  @override
  Future<void> connectIfUnambiguous({int? since, Set<String>? only}) async {
    final attempt = since ?? currentAttempt;
    bool stood() =>
        isCancelled(attempt) || autoConnectPaused.value || _endingAll > 0;
    if (stood()) return;
    if (!await _hostGranted()) return;
    if (stood()) return;
    // The launch must not admit tablets against the conservative guess
    // while the chip is being read.
    try {
      await hostInfoReady.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Not read in time, or not at all: the estimate stays conservative.
    }
    if (stood()) return;
    if (settings.linkType == LinkType.wifi) {
      if (sessions.isEmpty &&
          phase.value == ConnectionPhase.disconnected &&
          !stoppedDevices.contains(wifiKey) &&
          !_starting.contains(wifiKey)) {
        _start(wifiKey);
      }
      return;
    }
    await refreshDevices();
    // Something else may have started a connection meanwhile, or the user
    // may have stopped one.
    if (stood() || settings.linkType != LinkType.usb) return;
    final attached = [
      for (final d in DeviceModel.withoutMdnsDuplicates(availableDevices))
        if (!d.isSynthetic) d,
    ];
    final realAttached = attached.any((d) => !d.isEmulator);
    // Free tablets, the ones the user stopped included: those still count
    // for the first-run rule, so stopping one of two attached tablets does
    // not make the other one the only one. A tablet being picked (the
    // user's pick waiting for its old session to end, say) is not free: it
    // holds its place in [room] below, once.
    final free = [
      for (final d in attached)
        if ((!d.isEmulator || !realAttached) &&
            !sessions.containsKey(d.serial) &&
            !_starting.contains(d.serial) &&
            !_choosing.contains(d.serial))
          d.serial,
    ];
    final candidates = [
      for (final serial in free)
        if (!stoppedDevices.contains(serial)) serial,
    ]..sort();
    // The beside session counts for nothing here: it only listens until a
    // device is on it, and a tablet plugged in still connects by itself.
    final firstRun =
        sessions.values.every((s) => s.beside) &&
        _starting.every((k) => k == wifiKey) &&
        _reserved.isEmpty &&
        (phase.value == ConnectionPhase.disconnected ||
            (_focused?.beside ?? false)) &&
        free.length == 1 &&
        candidates.length == 1;
    final known = cap > 1
        ? {for (final d in settings.knownDevices) d.serial}
        : const <String>{};
    // The user's picks still under way (waiting for their tablet's old
    // session to end, say) hold their place too, and so does a tablet
    // between two sessions, its mode being changed.
    var room = cap -
        {
          ...heldPlaces,
          // The listener's start lasts as long as it listens: it holds a
          // place only once a device is on it (in [heldPlaces] then).
          for (final key in _starting)
            if (key != wifiKey) key,
          for (final key in _choosing)
            if (key != _anyDevice && key != _linkChange && key != wifiKey) key,
        }.length;
    for (final serial in candidates) {
      if (room <= 0) break;
      if (only != null && !only.contains(serial)) continue;
      if (!firstRun && !known.contains(serial)) continue;
      room--;
      _start(serial);
    }
    if (_besideWanted() && wifiBeside) _start(wifiKey);
  }

  /// Starts connecting [key] (over Wi-Fi, the Wi-Fi session) for the
  /// policy, without waiting for it: a connect returns only once its
  /// session is live, or never while a tablet does not answer. In the mode
  /// the tablet is remembered in, whichever rule picked it; one with none
  /// remembered (and the Wi-Fi session) takes what the selectors say.
  void _start(String key) {
    _starting.add(key);
    // The Wi-Fi session is asked for by its key over USB (beside the
    // tablets: [connectWith] gives it its own mode), by none over Wi-Fi.
    final usb = settings.linkType == LinkType.usb;
    final made = _besideMade;
    unawaited(
      connectWith(
            key == wifiKey && !usb ? null : key,
            choice: settings.knownChoice(key),
          )
          .catchError((Object e) => log.w('Host: auto-connect of $key: $e'))
          .whenComplete(() {
            _starting.remove(key);
            // A listener asked for while this one was still starting (it
            // ended meanwhile) starts now. Only when this start made one:
            // a start refused before making any would ask again at once,
            // for ever.
            if (key == wifiKey && _besideMade != made) {
              unawaited(_listenBeside());
            }
          }),
    );
  }

  /// Home offers the link selector while nothing is connecting or live.
  /// Sessions on the other link (idle, or in `error`) end; if one of them
  /// was waiting to retry, that retry runs on the new link. One the
  /// encoder refused waits for the user, so it brings nothing back.
  Future<void> _onLinkTypeChanged(LinkType link) async {
    if (_choosing.isNotEmpty || _endingAll > 0) return;
    final all = sessions.values.toList();
    if (all.any(
      (s) =>
          (s.phase.value.isConnecting || s.phase.value.isActive) &&
          !isListening(s),
    )) {
      return;
    }
    // The beside session goes with any change: over Wi-Fi the link's own
    // session takes its place, and back on USB a new one is made.
    final stale = all.where((s) => s.link != link || s.beside).toList();
    if (stale.isEmpty) {
      unawaited(_listenBeside());
      return;
    }
    final retrying = stale.any(
      (s) => !s.beside && s.retryPending.value && !s.refused.value,
    );
    final attempt = currentAttempt;
    _choosing.add(_linkChange);
    try {
      // The last one's end shows `disconnected`, which lets the retry's
      // connect() through.
      for (final session in stale) {
        await _endSession(session);
      }
    } finally {
      _choosing.remove(_linkChange);
    }
    if (isCancelled(attempt)) return;
    unawaited(_listenBeside());
    if (retrying) {
      // The hub's own connect: the tablet it settles on comes back in the
      // mode it is remembered in.
      await connectWith(null);
    } else if (sessions.values.every(isListening)) {
      setPhase(ConnectionPhase.disconnected);
    }
  }

  // ─── Routing and mirroring ────────────────────────────────────────────────

  /// The native plugins have one callback each: the hub takes them and
  /// hands each event to the session it is about (a wake to all of them).
  void _routeNativeCallbacks() {
    if (Get.isRegistered<ScreenCaptureChannel>()) {
      final capture = Get.find<ScreenCaptureChannel>();
      capture.onCaptureRestartNeeded = (id, {bool asleep = false}) {
        // With several tablets capturing, a wake rebuilds them all as one
        // operation, and a stream that stopped as the displays went to
        // sleep waits for it: its own rebuild would fail, and would make
        // one display while the others' are gone. With one, both go to the
        // session as they always have (the asleep rebuild fails; the wake
        // recovers it).
        final several = sessions.values.where((s) => s.canRebuild).length > 1;
        if (id == null && several) {
          unawaited(_rebuildAll());
          return;
        }
        if (asleep && several) return;
        for (final s in sessions.values.toList()) {
          if (id == null || s.nativeId == id) s.captureNeedsRestart();
        }
      };
      capture.onDisplayBoundsChanged = () {
        for (final s in sessions.values.toList()) {
          s.displayBoundsChanged();
        }
      };
      capture.onFrameRateChanged =
          (id, fps) => _byNativeId(id)?.frameRateChanged(fps);
      capture.onEncoderOverload = _encoderOverloaded;
      capture.onEncoderStats = _encoderStats;
      capture.onCaptureMismatch = (id) => _byNativeId(id)?.captureMismatch();
      capture.onCaptureMatched = (id) => _byNativeId(id)?.captureMatched();
    }
    if (Get.isRegistered<RemoteVideoChannel>()) {
      final remote = Get.find<RemoteVideoChannel>();
      remote.onRequestIdr = (id) => _byNativeId(id)?.decoderWantsKeyframe();
      remote.onCodecError = (id, code) => _byNativeId(id)?.decoderFailed(code);
      remote.onDecoderReady = (id) => _byNativeId(id)?.decoderReady();
    }
  }

  // An ordered rebuild is under way (its rounds included). [_wantAll]: a
  // wake asked for a full round after the one under way (the first may have
  // run while the displays were still asleep). [_wantDisplays]: the display
  // set changed, or a capture showed another display, since the round under
  // way took its targets. [_displayRoundWaiting]: a display round is queued
  // and has not taken its targets yet, so it covers any change asked now.
  // [_wakeRoundWaiting]: the same for a wake's round, which covers every
  // capture (the media queue can be busy for a while before it runs).
  bool _rebuilding = false;
  bool _wantAll = false;
  bool _wantDisplays = false;
  bool _displayRoundWaiting = false;
  bool _wakeRoundWaiting = false;
  // A display round is asked for, its timer not run yet.
  bool _displayRoundAsked = false;
  // The display round asked for is wanted for the display set itself (a
  // display made beside another, an Extend capture showing another
  // display), not only for the repairs in [_repairs]: one asked for by
  // repairs alone does nothing once none of them is needed any more. Set
  // with the ask and never by a timer or a round's end, cleared as a
  // display round takes its targets.
  bool _displaySetAsked = false;
  // The round under way: its targets; those it has not started again yet;
  // and those whose virtual display it took down, until its start of each
  // has returned.
  final _roundTargets = <HostSession>{};
  final _roundStartsLeft = <HostSession>{};
  final _roundDisplaysDown = <HostSession>{};
  // Sessions whose capture of the main display showed another display: the
  // next display round makes them again too, before any display (a repair
  // round, [_mirrorNeedsRepair]). Only sessions the hub still holds
  // ([_endSession] takes an ended one out).
  final _repairs = <HostSession>{};

  /// The sessions waiting for a repair round (tests).
  @visibleForTesting
  List<HostSession> get repairsDue => List.of(_repairs);

  /// Whether a rebuild round makes [session]'s running capture again: one
  /// under way that has not got to its start yet, or one asked for that
  /// has not taken its targets yet and will take this one (a display round
  /// takes every Extend session with a display and every Mirror session
  /// waiting for a repair, a wake every session that captures).
  /// [VirtualDisplays.willRestart] asks, so a first frame of a capture
  /// about to be made again asks for no round of its own.
  ///
  /// An Extend session answered true for a display round still to come
  /// counts on that round from then on ([_displaySetAsked]): it may have
  /// been asked for by a Mirror repair alone, and would do nothing if that
  /// repair were no longer needed when it runs.
  bool _roundWillRestart(HostSession session) {
    if (_roundStartsLeft.contains(session)) return true;
    if ((_wantAll || _wakeRoundWaiting) && session.canRebuild) return true;
    if (!(_displayRoundAsked || _displayRoundWaiting || _wantDisplays)) {
      return false;
    }
    if (_repairs.contains(session)) return true;
    if (!session.rebuildsDisplay) return false;
    _displaySetAsked = true;
    return true;
  }

  /// Whether the round under way has taken down a virtual display it has
  /// not made again yet, and does not make [session]'s capture again
  /// itself: [session]'s stream was made beside that display, which is
  /// about to be back. Between a round's last stop and its first display
  /// the set is empty, and a capture of the main display whose first frame
  /// is heard just then is still one to repair
  /// ([VirtualDisplays.besideDisplays]). A target of the round is another
  /// matter: its capture is, or will be, one the round made with no
  /// display there.
  bool _roundHasDisplaysDown(HostSession session) =>
      !_roundTargets.contains(session) &&
      _roundDisplaysDown.any((s) => !identical(s, session));

  /// The Mac woke: every session that captures is rebuilt
  /// ([_RebuildRound.wake]).
  Future<void> _rebuildAll() => _rebuild(_RebuildRound.wake);

  /// A session is making its virtual display while another session's
  /// exists, or its Extend capture showed another display
  /// ([VirtualDisplays]): the next display round is wanted for the display
  /// set, whatever becomes of the repairs asked for beside it.
  void _displaySetNeedsRebuild() {
    _displaySetAsked = true;
    _displaysNeedRebuild();
  }

  /// Asks for a display round. Asked from inside the queued start that
  /// makes a display (or from a native callback): the round is queued from
  /// outside it, once that start is over (and its connect has gone live),
  /// and several asks before then make one round.
  void _displaysNeedRebuild() {
    if (_displayRoundAsked) return;
    _displayRoundAsked = true;
    Timer.run(() {
      _displayRoundAsked = false;
      unawaited(_rebuildDisplays());
    });
  }

  /// [session] captures the main display (Mirror) and its first frame
  /// showed another one: with virtual displays about, macOS can hand a new
  /// stream one of them instead (FB17797423), and making that stream again
  /// beside them would likely get the same. So the next display round
  /// takes [session] too and starts it before any display is made again (a
  /// repair round, see [_rebuildRound]). Queued from a timer like any
  /// display round; several asks before it runs make one round.
  void _mirrorNeedsRepair(HostSession session) {
    _repairs.add(session);
    _displaysNeedRebuild();
  }

  /// Every Extend session's capture is rebuilt with the display set emptied
  /// first ([_RebuildRound.displays]).
  Future<void> _rebuildDisplays() => _rebuild(_RebuildRound.displays);

  /// Runs [round] as one operation on the [pipeline], then whatever was
  /// asked for meanwhile: a wake's round first, then a display round.
  Future<void> _rebuild(_RebuildRound round) async {
    if (round == _RebuildRound.wake) {
      _wantAll = true;
    } else if (!_displayRoundWaiting) {
      _wantDisplays = true;
    }
    if (_rebuilding) return;
    _rebuilding = true;
    try {
      while (_wantAll || _wantDisplays) {
        final next = _wantAll ? _RebuildRound.wake : _RebuildRound.displays;
        if (next == _RebuildRound.wake) {
          _wantAll = false;
        } else {
          _wantDisplays = false;
        }
        _displayRoundWaiting = next == _RebuildRound.displays;
        _wakeRoundWaiting = next == _RebuildRound.wake;
        await pipeline.run(() {
          _displayRoundWaiting = false;
          _wakeRoundWaiting = false;
          return _rebuildRound(next);
        });
      }
    } finally {
      _rebuilding = false;
      _wantAll = false;
      _wantDisplays = false;
      _displayRoundWaiting = false;
      _wakeRoundWaiting = false;
    }
  }

  /// One rebuild, run on the [pipeline]. Every target stops (stream,
  /// encoder, virtual display) before any starts again, in key order, so
  /// the display set is made in the same order every time, and no other
  /// operation (a session's own rebuild, a teardown) slips in between. A
  /// session that ended or lost its link during the stops is not started.
  /// Each start bumps its session's generation, so a stream-stop it heard
  /// before its start is already covered, while one after it still gets a
  /// round. The displays made here ask for no further round
  /// ([VirtualDisplays.rebuilding]).
  ///
  /// A wake rebuilds every live session that captures, Mirror included. A
  /// display round rebuilds every Extend session with a display, one whose
  /// connect is just going live included, and first takes down the
  /// displays of sessions on their way out (their own teardown would only
  /// get to them after the starts): FB17797423 lasts until every virtual
  /// display is gone.
  ///
  /// The same bug can hand a stream of the main display a virtual display
  /// instead, so a capture of the main display has to be made while none
  /// exists. A wake therefore starts its Mirror targets first (by what
  /// each start will capture, [SessionSpec.displayMode]; a remote-control
  /// session whose tablet drives the Mac always mirrors), then the Extend
  /// ones, each group in key order; the stops stay in key order. A display
  /// round never takes a Mirror session, except the ones whose first frame
  /// showed another display ([_repairs], a repair round): those stop with
  /// the rest and start first. With only Extend targets every round runs
  /// in key order, as it always has. A display round asked for by repairs
  /// alone, none of which is still needed when it runs (a wake's round made
  /// that capture again meanwhile, or its session ended or lost its
  /// capture), does nothing: the Extend tablets have nothing to be stopped
  /// for.
  Future<void> _rebuildRound(_RebuildRound round) async {
    final wake = round == _RebuildRound.wake;
    // The Mirror captures waiting for a repair are this round's now. A
    // wake makes every live capture again, those included, so it only
    // takes their asks off the list (one not live yet keeps its ask for
    // the display round that follows).
    final repairs = <HostSession>{};
    if (wake) {
      _repairs.removeWhere(
          (s) => s.canRebuild || !identical(sessions[s.key], s));
    } else {
      repairs.addAll([
        for (final s in _repairs)
          if (identical(sessions[s.key], s) && s.repairsMirror) s,
      ]);
      _repairs.clear();
      final forDisplaySet = _displaySetAsked;
      _displaySetAsked = false;
      if (!forDisplaySet && repairs.isEmpty) return;
    }
    final targets = [
      for (final s in sessions.values)
        if (wake ? s.canRebuild : s.rebuildsDisplay || repairs.contains(s))
          (session: s, attempt: s.currentAttempt),
    ]..sort((a, b) => a.session.key.compareTo(b.session.key));
    if (targets.isEmpty) return;
    bool first(HostSession s) =>
        wake ? s.spec.displayMode == DisplayMode.mirror : repairs.contains(s);
    final leaving = wake
        ? const <HostSession>[]
        : [
            for (final h in displays.holders)
              if (!targets.any((t) => identical(t.session, h))) h,
          ];
    log.w(wake
        ? 'Host: rebuilding ${targets.length} capture pipelines after wake'
        : repairs.isEmpty
            ? 'Host: rebuilding ${targets.length} virtual displays in order '
                '(the display set changed)'
            : 'Host: rebuilding ${targets.length} captures, '
                '${repairs.length} of the main display first (it showed '
                'another display)');
    displays.rebuilding = true;
    _roundTargets
      ..clear()
      ..addAll([for (final t in targets) t.session]);
    _roundStartsLeft
      ..clear()
      ..addAll(_roundTargets);
    _roundDisplaysDown
      ..clear()
      ..addAll([
        for (final t in targets)
          if (displays.holds(t.session)) t.session,
      ]);
    try {
      for (final s in leaving) {
        try {
          await s.stopPipelineOp();
        } catch (e, st) {
          log.e('Host: display of an ending session not removed', e, st);
        }
      }
      final stopped = <({HostSession session, int attempt})>[];
      for (final t in targets) {
        try {
          await t.session.stopPipelineOp();
          stopped.add(t);
        } catch (e, st) {
          _roundStartsLeft.remove(t.session);
          _roundDisplaysDown.remove(t.session);
          t.session.rebuildFailed(e, st);
        }
      }
      // Captures of the main display first, while no virtual display
      // exists; each group as it was stopped, in key order.
      final starts = [
        for (final t in stopped)
          if (first(t.session)) t,
        for (final t in stopped)
          if (!first(t.session)) t,
      ];
      for (final t in starts) {
        // From here a capture of this session's is the round's own.
        _roundStartsLeft.remove(t.session);
        try {
          await t.session.startPipelineOp(t.attempt);
        } catch (e, st) {
          t.session.rebuildFailed(e, st);
        } finally {
          // Back in the display set by now, or not coming back.
          _roundDisplaysDown.remove(t.session);
        }
      }
    } finally {
      displays.rebuilding = false;
      _roundTargets.clear();
      _roundStartsLeft.clear();
      _roundDisplaysDown.clear();
    }
  }

  HostSession? _byNativeId(int id) {
    for (final s in sessions.values) {
      if (s.nativeId == id) return s;
    }
    return null;
  }

  /// The hub's observables follow [session]'s from now on. Each is the
  /// hub's own Rx for its whole life: Home's workers and the remote view's
  /// widgets hold on to them.
  void _focus(HostSession session) {
    _unfocus();
    _focused = session;
    focusedKey.value = session.key;
    _recent
      ..remove(session.key)
      ..add(session.key);
    void mirror<T>(Rx<T> from, Rx<T> to) {
      to.value = from.value;
      _mirrors.add(ever<T>(from, (v) => to.value = v));
    }

    mirror(session.phase, phase);
    mirror(session.errorMessage, errorMessage);
    mirror(session.errorKey, errorKey);
    mirror(session.activeDevice, activeDevice);
    mirror(session.latencyMs, latencyMs);
    mirror(session.refreshRateHz, refreshRateHz);
    mirror(session.streamBitrate, streamBitrate);
    mirror(session.remoteTextureId, remoteTextureId);
    mirror(session.tabletStreaming, tabletStreaming);
    mirror(session.tabletScreenOff, tabletScreenOff);
    mirror(session.changingTabletScreen, changingTabletScreen);
  }

  /// The hub's observables keep the last values they mirrored.
  void _unfocus() {
    for (final w in _mirrors) {
      w.dispose();
    }
    _mirrors.clear();
    _focused = null;
    focusedKey.value = null;
  }
}

/// What one session's encoder reported during a capacity window: how many
/// seconds, the encoded frames a second summed over them, and in how many
/// the screen delivered a frame.
class _EncodeEvidence {
  int seconds = 0;
  double encoded = 0;
  int changing = 0;
}

/// What an ordered rebuild of the sessions' captures is for.
enum _RebuildRound {
  /// The Mac woke: every live session that captures.
  wake,

  /// The virtual display set changed with several displays (FB17797423):
  /// every Extend session with a display. With a capture of the main
  /// display that showed another one, that capture too, started first (a
  /// repair round).
  displays,
}
