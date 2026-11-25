import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/usbmux.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// Where the Mac's touches to an iPhone stand.
enum IosTouchState {
  /// Not tried yet, or stopped.
  idle,

  /// No iOS device on USB.
  noDevice,

  /// A device, but nothing answers on the runner's port: the TouchRunner
  /// (ios/TouchRunner) is not running on it.
  noRunner,

  /// Something answered on the runner's port, but not with the runner's
  /// `pong`: it refused us (or is not the runner).
  runnerRefused,

  /// The link was up and dropped (the phone went off usbmuxd, as it does
  /// for a moment whenever a capture starts, or the cable was pulled):
  /// waiting to connect again.
  reconnecting,

  /// More than one iOS device on USB (on usbmuxd, or among the capture
  /// devices): touches are refused, since nothing says which phone the
  /// picture is (a capture device's uniqueID is not the UDID) until that
  /// mapping is confirmed on a device.
  severalDevices,

  /// Connected to the runner: touches go through.
  ready,
}

/// Which way a phone showing a landscape picture is turned: where the top
/// of its portrait screen is in the picture.
enum IosTurn { topLeft, topRight }

/// What an `orient` answer was read from. A runner from before release 1
/// names nothing and reads the physical orientation ([device]).
enum IosOrientSource {
  /// The frontmost app's interface orientation.
  app,

  /// SpringBoard's interface orientation (no app could be read).
  springboard,

  /// `XCUIDevice.shared.orientation`, the physical orientation: with
  /// rotation lock on, or the phone flat, it can differ from the screen.
  device,
}

/// The system gestures the runner plays as one verb each (runner release 1,
/// plan unit F1), in the order of their Mac shortcuts (⌘2 to ⌘5; ⌘1 is
/// Home, `home`).
enum IphoneSystemGesture {
  /// Up from the bottom edge, held still before the lift.
  switcher('switcher', 0.7),

  /// Home, then down from the middle of the Home Screen.
  spotlight('spotlight', 1.5),

  /// Down from the top-right corner.
  controlCenter('control', 0.3),

  /// Down from the top-left half.
  notifications('notifications', 0.3);

  const IphoneSystemGesture(this.verb, this.lasts);

  /// The runner's verb.
  final String verb;

  /// About how long the runner takes to play it, in seconds (added to the
  /// wait for its answer).
  final double lasts;
}

/// What the runner says it supports, from its `caps` answer (runner release
/// 1 on): `caps <verb>… <option>=<value>… exp=<verb>,<verb>…`. Verbs listed
/// under `exp` are experimental (the plan's spikes E1 to E3).
class RunnerCaps {
  const RunnerCaps(
      {this.verbs = const {},
      this.experimental = const {},
      this.options = const {}});

  final Set<String> verbs;
  final Set<String> experimental;
  final Map<String, String> options;

  /// The verbs a runner from before `caps` has, at most (a build from
  /// before `aswipe` or `home` refuses those, which is still found out by
  /// its `err`).
  static const legacyVerbs = {
    'ping', 'tap', 'atap', 'swipe', 'aswipe', 'home', 'orient', 'quit',
  };

  /// Whether [verb] is listed, plainly or as experimental.
  bool has(String verb) => verbs.contains(verb) || experimental.contains(verb);

  /// [line] parsed, or null when it is not a `caps` answer (an older runner
  /// answers `err caps`).
  static RunnerCaps? parse(String line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.isEmpty || fields.first != 'caps') return null;
    final verbs = <String>{};
    final experimental = <String>{};
    final options = <String, String>{};
    for (final f in fields.skip(1)) {
      final eq = f.indexOf('=');
      if (eq < 0) {
        verbs.add(f);
      } else if (f.substring(0, eq) == 'exp') {
        experimental.addAll(
            f.substring(eq + 1).split(',').where((v) => v.isNotEmpty));
      } else if (eq > 0) {
        options[f.substring(0, eq)] = f.substring(eq + 1);
      }
    }
    return RunnerCaps(
        verbs: verbs, experimental: experimental, options: options);
  }
}

/// Mac: touches on an iPhone or iPad over USB. iOS lets no app take input
/// from outside, so they go to the TouchRunner, an XCUITest started on the
/// phone from Xcode, which listens on [runnerPort] and synthesizes them
/// through XCTest (private event synthesis, WebDriverAgent-style; a touch
/// lands about 100 ms after it is sent). Reached through usbmuxd, over the
/// cable. Coordinates are normalized to the screen in portrait.
class IosTouchService extends GetxService {
  IosTouchService(
      {UsbmuxClient? usbmux,
      this.reconnectGrace = const Duration(seconds: 10)})
      : _usbmux = usbmux ?? UsbmuxClient();

  /// How long after a link dropped a connect that fails still reads as
  /// [IosTouchState.reconnecting] rather than [IosTouchState.noRunner]: the
  /// phone re-enumerating its USB (a capture's start) refuses usbmuxd's
  /// Connect, or drops a handshake, for a moment, and the view's "runner
  /// missing" banner flashed on every capture start.
  final Duration reconnectGrace;

  /// When the link last went from ready to [IosTouchState.reconnecting].
  DateTime? _droppedAt;

  static const runnerPort = 8100;

  final UsbmuxClient _usbmux;
  final state = IosTouchState.idle.obs;

  /// The UDID of the device the link is up to (null while it is not).
  final udid = RxnString();

  /// Commands dropped: sent while the link was down (and connecting failed),
  /// or whose answer never came (which drops the link). Each is logged, so
  /// a command that never went out can be told from a slow one.
  final dropped = 0.obs;

  /// The USB devices usbmuxd reports attached, by `DeviceID`, while
  /// [watch]ing; empty otherwise.
  final attached = <int, UsbmuxDevice>{}.obs;

  /// Whether the [watch] connection is up (usbmuxd took its Listen).
  final listening = false.obs;

  /// How many capture devices the picture's side lists (the view sets it
  /// from its listing); more than one refuses touches as two on usbmuxd do.
  int _captureDevices = 0;

  StreamSubscription<UsbmuxEvent>? _watch;
  final _attachments = StreamController<UsbmuxDevice>.broadcast();

  /// An iOS device came on USB (usbmuxd's Attached, while [watch]ing), or the
  /// one-device rule stopped refusing: a chance to connect, without waiting
  /// for a retry tick.
  Stream<UsbmuxDevice> get attachments => _attachments.stream;

  /// The `DeviceID` of the device the link is up to.
  int? _deviceId;

  /// The runner's screen size in points ("pong 440x956"), once connected.
  final screenPoints = RxnString();

  /// Whether the runner synthesizes touches itself (its pong's `fast=`).
  /// Without that its `atap`/`aswipe` are refused, so the blocking
  /// `tap`/`swipe` (XCUICoordinate, which answer once the touch is done) are
  /// sent instead.
  bool fast = true;

  /// What the runner listed in its `caps` answer on this connection; null
  /// for a runner from before `caps` (it answers `err caps`), which keeps
  /// today's feature set: [RunnerCaps.legacyVerbs], and the per-verb `err`
  /// fallbacks below.
  final caps = Rxn<RunnerCaps>();

  /// Whether [verb] may be sent to this runner: listed in [caps], or with no
  /// `caps`, one of [RunnerCaps.legacyVerbs]. Newer features (`seg`, the
  /// system gestures) are enabled by this, never by trying.
  bool supports(String verb) =>
      caps.value?.has(verb) ?? RunnerCaps.legacyVerbs.contains(verb);

  /// A verb [caps] rules out: listed caps that do not name it. With no
  /// `caps` nothing is ruled out up front (the runner's `err` says so).
  bool _ruledOut(String verb) {
    final c = caps.value;
    return c != null && !c.has(verb);
  }

  /// Fast commands this runner refused (`err <command> …`): a runner built
  /// before `aswipe` existed answers it so and does nothing. Those are sent
  /// the blocking way from then on, until the next connection (the runner
  /// may have been started again, newer).
  final _refusedFast = <String>{};

  UsbmuxStream? _stream;
  StreamSubscription<String>? _lines;
  Future<bool>? _connecting;
  final _replies = <Completer<String>>[];

  /// Bumped by [disconnect]: a connect still under way then gives up what it
  /// opened instead of installing it.
  int _gen = 0;

  /// The side the runner last reported while the phone was landscape (a
  /// phone lying flat reports neither, and keeps the side before). Landscape
  /// clicks are mapped by this cached value, never by a question asked per
  /// touch: [refreshTurn] keeps it current (on connect here; on a frame-size
  /// change and after each landscape gesture in the view's controller).
  ///
  /// A runner from release 1 on answers the frontmost app's interface
  /// orientation where it can read it ([orientSource]); an older one reads
  /// `XCUIDevice.shared.orientation`, the physical orientation, which with
  /// rotation lock on, or the phone flat, can differ from the screen.
  final lastTurn = IosTurn.topLeft.obs;

  /// What the last `orient` answer was read from (null before any).
  final orientSource = Rxn<IosOrientSource>();

  /// An `orient` that took this long on the phone (its answer's `<n>ms`,
  /// runner release 1) is logged.
  static const slowOrientMs = 50.0;

  /// The `orient` under way, if any: a second ask waits for it.
  Future<IosTurn>? _turning;

  LoggerService get _log => Get.find<LoggerService>();

  /// The distinct UDIDs among [devices] on USB (usbmuxd can list a phone
  /// twice, by USB and by network).
  static Set<String> _usbSerials(Iterable<UsbmuxDevice> devices) =>
      {for (final d in devices) if (d.isUsb) d.serial};

  /// Follows usbmuxd's Attached and Detached events ([UsbmuxClient.listen])
  /// until [unwatch]: [attached] and [listening] are kept, every USB
  /// Attached goes to [attachments], the Detached of the device the link is
  /// up to drops it at once ([IosTouchState.reconnecting]), and a second
  /// phone drops it too ([IosTouchState.severalDevices]).
  void watch() {
    _watch ??= _usbmux.listen().listen(onUsbmuxEvent);
  }

  void unwatch() {
    unawaited(_watch?.cancel());
    _watch = null;
    attached.clear();
    listening.value = false;
  }

  /// One event of [watch] (tests feed them directly).
  void onUsbmuxEvent(UsbmuxEvent e) {
    switch (e.kind) {
      case UsbmuxEventKind.listening:
        listening.value = true;
      case UsbmuxEventKind.lost:
        listening.value = false;
      case UsbmuxEventKind.attached:
        final device = e.device;
        if (device == null || !device.isUsb) return;
        attached[device.deviceId] = device;
        if (_usbSerials(attached.values).length > 1) {
          _refuseSeveral();
          return;
        }
        // A connect under way answers whoever asks meanwhile with its own
        // result, which this Attached may come too late for (its listing
        // found nothing yet): posted again once that one has failed.
        final running = _connecting;
        if (running != null) {
          unawaited(running.then((ok) {
            if (!ok && !_attachments.isClosed) _attachments.add(device);
          }));
        } else if (!_attachments.isClosed) {
          _attachments.add(device);
        }
      case UsbmuxEventKind.detached:
        final id = e.deviceId;
        if (id == null || attached.remove(id) == null) return;
        if (id == _deviceId) {
          _log.w('iPhone touches: the phone left usbmuxd; reconnecting');
          _lost();
        } else if (id == _connectingId) {
          // The connect under way is to a DeviceID that is gone (a replug
          // gives a new one): given up now, so the Attached that follows
          // starts a fresh one instead of joining it.
          _log.w('iPhone touches: the phone left usbmuxd while connecting');
          _gen++;
          _connectingId = null;
          _connecting = null;
          _lost();
        }
        if (state.value == IosTouchState.severalDevices &&
            _usbSerials(attached.values).length <= 1 &&
            _captureDevices <= 1) {
          state.value = IosTouchState.idle;
          final left = attached.values.firstOrNull;
          if (left != null && !_attachments.isClosed) _attachments.add(left);
        }
    }
  }

  /// The picture's side lists [n] capture devices. With more than one,
  /// touches are refused (and a link up is dropped).
  void setCaptureDevices(int n) {
    _captureDevices = n;
    if (n > 1) {
      _refuseSeveral();
    } else if (state.value == IosTouchState.severalDevices &&
        _usbSerials(attached.values).length <= 1) {
      state.value = IosTouchState.idle;
    }
  }

  void _refuseSeveral() {
    if (state.value == IosTouchState.severalDevices) return;
    _log.w('iPhone touches: more than one iOS device attached; touches are '
        'off until only one is (which phone the picture is cannot be told)');
    _gen++;
    _lost();
    state.value = IosTouchState.severalDevices;
  }

  /// Counts and logs a command that did not go out, or got no answer.
  void _drop(String line, String why) {
    dropped.value++;
    _log.w('iPhone touches: dropped "$line" ($why; ${dropped.value} dropped '
        'so far)');
  }

  /// Connects to the runner on the first iOS device on USB (or [udid]), if
  /// not connected. True once connected.
  Future<bool> connect({String? udid}) {
    if (state.value == IosTouchState.ready && _stream != null) {
      return Future.value(true);
    }
    final running = _connecting;
    if (running != null) return running;
    late final Future<bool> attempt;
    attempt = _connect(udid).whenComplete(() {
      // A newer attempt may have taken the slot (see the Detached above).
      if (identical(_connecting, attempt)) {
        _connecting = null;
        _connectingId = null;
      }
    });
    return _connecting = attempt;
  }

  /// The `DeviceID` the connect under way is opening a stream to.
  int? _connectingId;

  /// The state a connect that failed shows: [IosTouchState.reconnecting]
  /// while a dropped link is within [reconnectGrace], else [fallback].
  IosTouchState _failedState(IosTouchState fallback) {
    final dropped = _droppedAt;
    if (state.value == IosTouchState.reconnecting &&
        dropped != null &&
        DateTime.now().difference(dropped) < reconnectGrace) {
      return IosTouchState.reconnecting;
    }
    return fallback;
  }

  Future<bool> _connect(String? udid) async {
    final gen = _gen;
    UsbmuxStream? opened;
    try {
      final devices = await _usbmux.listDevices();
      if (gen != _gen) return false;
      // Until a capture device's uniqueID is known to name its UDID, two
      // phones on either side leave no way to tell which one the picture
      // is: no touches rather than touches on the wrong phone.
      if (udid == null &&
          (_usbSerials(devices).length > 1 || _captureDevices > 1)) {
        if (state.value != IosTouchState.severalDevices) {
          _log.w('iPhone touches: more than one iOS device attached; '
              'touches are off until only one is');
        }
        state.value = IosTouchState.severalDevices;
        return false;
      }
      final device = devices.firstWhereOrNull(
          (d) => d.isUsb && (udid == null || d.serial == udid));
      if (device == null) {
        // A link that dropped is still waiting for its phone to come back.
        if (state.value != IosTouchState.reconnecting) {
          state.value = IosTouchState.noDevice;
        }
        return false;
      }
      _connectingId = device.deviceId;
      final stream = opened = await _usbmux.connect(device.deviceId, runnerPort);
      if (gen != _gen) {
        stream.close();
        return false;
      }
      _stream = stream;
      _deviceId = device.deviceId;
      _lines = stream.data
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (_replies.isNotEmpty) _replies.removeAt(0).complete(line);
      }, onDone: _lost, onError: (Object _) => _lost());
      final pong = await _send('ping').timeout(_waitFor(_shortWait));
      if (gen != _gen) {
        stream.close();
        return false;
      }
      if (!pong.startsWith('pong')) {
        _log.w('iPhone touches: port $runnerPort answered "$pong", not the '
            "runner's pong");
        _lost();
        state.value = IosTouchState.runnerRefused;
        return false;
      }
      final fields = pong.split(' ');
      screenPoints.value = fields.elementAtOrNull(1);
      fast = !fields.contains('fast=false');
      _refusedFast.clear();
      // What this runner supports, asked once per connection: a runner from
      // before `caps` answers `err caps` (today's feature set).
      final capsReply = await _send('caps').timeout(_waitFor(_shortWait));
      if (gen != _gen) {
        stream.close();
        return false;
      }
      caps.value = RunnerCaps.parse(capsReply);
      if (!fast) {
        _log.w('iPhone touches: the runner has no fast synthesis; '
            'using its blocking tap and swipe');
      }
      this.udid.value = device.serial;
      state.value = IosTouchState.ready;
      _log.i('iPhone touches: connected to the runner on ${device.serial} '
          '(usbmux DeviceID ${device.deviceId})');
      // The side the phone is turned, ready before the first landscape
      // click. Sent now, before any touch, and not waited for.
      unawaited(_turning ??= _orient().whenComplete(() => _turning = null));
      return true;
    } on UsbmuxRefused {
      if (gen != _gen) return false;
      state.value = _failedState(IosTouchState.noRunner);
      return false;
    } catch (e) {
      if (gen != _gen) {
        opened?.close();
        return false;
      }
      _log.w('iPhone touches: no runner ($e)');
      final next = _failedState(IosTouchState.noRunner);
      _lost();
      state.value = next;
      return false;
    }
  }

  void _lost() {
    caps.value = null;
    unawaited(_lines?.cancel());
    _lines = null;
    _stream?.close();
    _stream = null;
    _deviceId = null;
    udid.value = null;
    for (final r in _replies) {
      if (!r.isCompleted) r.completeError(StateError('runner gone'));
    }
    _replies.clear();
    _repliesDue = null;
    if (state.value == IosTouchState.ready) {
      state.value = IosTouchState.reconnecting;
      _droppedAt = DateTime.now();
    }
  }

  /// A command answered by the runner at once (`atap`, `orient`, …) is
  /// waited for this long.
  static const _shortWait = Duration(seconds: 2);

  /// By when the last command sent should have been answered. The runner
  /// answers in command order, so no answer can come before the ones ahead
  /// of it: a command's wait runs at least until theirs ends. An `atap`
  /// clicked behind a `spotlight` (Home, then a swipe) used to time out on
  /// its own 2 s and drop the link.
  DateTime? _repliesDue;

  /// How long to wait for the answer to a command sent now that would be
  /// answered within [own] on its own.
  Duration _waitFor(Duration own) {
    final now = DateTime.now();
    var due = now.add(own);
    final ahead = _repliesDue;
    if (ahead != null && ahead.isAfter(due)) due = ahead;
    _repliesDue = due;
    return due.difference(now);
  }

  Future<String> _send(String line) {
    final stream = _stream;
    if (stream == null) return Future.error(StateError('not connected'));
    final reply = Completer<String>();
    _replies.add(reply);
    stream.add(utf8.encode('$line\n'));
    return reply.future;
  }

  String _n(double v) => v.clamp(0.0, 1.0).toStringAsFixed(4);

  /// A tap at ([nx], [ny]), normalized in portrait.
  Future<void> tap(double nx, double ny) =>
      _touch('atap', 'tap', '${_n(nx)} ${_n(ny)}');

  /// A swipe from ([nx1], [ny1]) to ([nx2], [ny2]) over [seconds], after
  /// [hold] seconds held at the start (a press, then a drag); from a point to
  /// itself, a press held [seconds].
  Future<void> swipe(double nx1, double ny1, double nx2, double ny2,
      double seconds, {double hold = 0}) {
    final s = seconds.clamp(0.02, 3.0);
    final h = hold.clamp(0.0, 3.0);
    return _touch(
        'aswipe',
        'swipe',
        '${_n(nx1)} ${_n(ny1)} ${_n(nx2)} ${_n(ny2)} ${s.toStringAsFixed(3)}'
            '${h > 0 ? ' ${h.toStringAsFixed(3)}' : ''}',
        lasts: s + h);
  }

  /// One segment of a live drag (runner release 1's `seg`, plan unit L3): a
  /// new touch put down [lead] points back along the segment, moved to
  /// ([nx2], [ny2]) over [seconds], held still [settle] seconds (so a
  /// mid-drag segment does not fling; 0 on the last one lets it), lifted.
  /// Answered once XCTest has played it (`done <ms>`, or `late <ms>` when
  /// XCTest never said): true then. False when it did not go out: no link,
  /// a runner whose [caps] do not list `seg` (never asked: there is no
  /// slow twin, the caller replays the drag as an `aswipe` instead), or an
  /// `err` answer.
  Future<bool> segment(double nx1, double ny1, double nx2, double ny2,
      double seconds, {double settle = 0, double lead = 0}) async {
    final s = seconds.clamp(0.02, 5.0);
    final e = settle.clamp(0.0, 1.0);
    final l = lead.clamp(0.0, 50.0);
    final line = 'seg ${_n(nx1)} ${_n(ny1)} ${_n(nx2)} ${_n(ny2)} '
        '${s.toStringAsFixed(3)} ${e.toStringAsFixed(3)} '
        '${l.toStringAsFixed(1)}';
    if (!await connect()) {
      _drop(line, state.value.name);
      return false;
    }
    if (!supports('seg')) return false;
    final reply = await _fire(line, blocking: true, lasts: s + e);
    return reply != null &&
        (reply.startsWith('done') || reply.startsWith('late'));
  }

  /// Experimental (plan unit E1, off unless the controller is built with
  /// `liveFinger`): a finger put down at ([nx], [ny]) and left down, moved,
  /// and lifted, each its own record (`pdown`, `pmove`, `pup`). Runner
  /// release 1 has them as experimental verbs (listed under `exp=` in its
  /// `caps`); a runner whose caps leave one out is not asked (false), and one
  /// from before `caps` is asked and answers `err` (false). Either way the
  /// caller goes back to whole-gesture records. Nothing is retried the slow
  /// way (there is no slow twin).
  Future<bool> fingerDown(double nx, double ny) => _finger('pdown', nx, ny);
  Future<bool> fingerMove(double nx, double ny) => _finger('pmove', nx, ny);
  Future<bool> fingerUp(double nx, double ny) => _finger('pup', nx, ny);

  Future<bool> _finger(String verb, double nx, double ny) async {
    final line = '$verb ${_n(nx)} ${_n(ny)}';
    if (!await connect()) {
      _drop(line, state.value.name);
      return false;
    }
    // A runner that lists its caps without the verb is not asked.
    if (_ruledOut(verb)) return false;
    final reply = await _fire(line, blocking: false);
    return reply != null && !reply.startsWith('err');
  }

  /// Presses the phone's Home button (the Home Screen). False when it was
  /// not done: no runner, or a runner built before `home`.
  Future<bool> home() async {
    if (!await connect()) {
      _drop('home', state.value.name);
      return false;
    }
    if (_ruledOut('home')) return false;
    final reply = await _fire('home', blocking: true, lasts: 1);
    return reply != null && !reply.startsWith('err');
  }

  /// Plays one of the system edge gestures (runner release 1's `switcher`,
  /// `spotlight`, `control`, `notifications`; the runner picks the edges in
  /// the screen's current interface orientation). Answered once played
  /// (`ok <ms> o=<raw>`): true then. False when it did not go out: no link,
  /// a runner whose [caps] do not list the verb (a runner from before
  /// `caps` has none of them, so it is never asked), or an `err` answer.
  Future<bool> systemGesture(IphoneSystemGesture gesture) async {
    final verb = gesture.verb;
    if (!await connect()) {
      _drop(verb, state.value.name);
      return false;
    }
    if (!supports(verb)) return false;
    final reply = await _fire(verb, blocking: true, lasts: gesture.lasts);
    return reply != null && !reply.startsWith('err');
  }

  /// Asks the runner which way the phone is turned and stores the answer
  /// in [lastTurn]; when it cannot say (lying flat, no runner, a runner
  /// without `orient`), [lastTurn] keeps the side it last reported. One
  /// question at a time: a second call waits for the first. A failed one
  /// drops the link, but no touch waits on it.
  Future<IosTurn> turn() =>
      _turning ??= _askTurn().whenComplete(() => _turning = null);

  Future<IosTurn> _askTurn() async {
    if (!await connect()) return lastTurn.value;
    return _orient();
  }

  /// [turn], only while connected: refreshing the cache never opens a link
  /// (connecting asks by itself).
  Future<IosTurn> refreshTurn() {
    if (state.value != IosTouchState.ready || _stream == null) {
      return Future.value(lastTurn.value);
    }
    return turn();
  }

  Future<IosTurn> _orient() async {
    try {
      final reply = await _send('orient').timeout(_waitFor(_shortWait));
      final fields = reply.split(' ');
      // Release 1 also says how long the runner's accessibility read took
      // (`… <n>ms`): a slow one holds up the touches behind it.
      final took = fields
          .where((f) => f.endsWith('ms'))
          .map((f) => double.tryParse(f.substring(0, f.length - 2)))
          .whereType<double>()
          .firstOrNull;
      if (took != null && took >= slowOrientMs) {
        _log.w('iPhone touches: orient took ${took.round()} ms on the phone '
            '($reply)');
      }
      if (fields.first == 'orient') {
        // `orient <raw> [app|springboard|device]`; no source from a runner
        // before release 1, which reads the physical orientation.
        orientSource.value = switch (fields.elementAtOrNull(2)) {
          'app' => IosOrientSource.app,
          'springboard' => IosOrientSource.springboard,
          _ => IosOrientSource.device,
        };
      }
      // UIDeviceOrientation: 3 landscapeLeft (the top on the left), 4
      // landscapeRight. An interface orientation's raw value names the same
      // turn (UIInterfaceOrientationLandscapeRight is 3, the home indicator
      // on the right, as UIDeviceOrientationLandscapeLeft).
      switch (fields.elementAtOrNull(1)) {
        case '3':
          lastTurn.value = IosTurn.topLeft;
        case '4':
          lastTurn.value = IosTurn.topRight;
      }
    } catch (_) {
      _lost();
    }
    return lastTurn.value;
  }

  /// Sends a touch as [fastVerb] (answered at once, the touch lands later)
  /// or, from a runner without fast synthesis or one that refused
  /// [fastVerb] before, as [slowVerb] (answered once the touch, [lasts]
  /// seconds, is done). A [fastVerb] the runner refuses is sent again as
  /// [slowVerb] at once: a refused command touched nothing, so this is no
  /// second touch.
  Future<void> _touch(String fastVerb, String slowVerb, String args,
      {double lasts = 0}) async {
    if (!await connect()) {
      _drop('$fastVerb $args', state.value.name);
      return;
    }
    if (fast && !_refusedFast.contains(fastVerb) && !_ruledOut(fastVerb)) {
      final reply = await _fire('$fastVerb $args', blocking: false);
      if (reply == null || !reply.startsWith('err $fastVerb')) return;
      _refusedFast.add(fastVerb);
      _log.w('iPhone touches: the runner does not take "$fastVerb" '
          '(an older build?); sending "$slowVerb" instead');
    }
    await _fire('$slowVerb $args', blocking: true, lasts: lasts);
  }

  /// Sends one command and returns the runner's answer (null with no
  /// answer, which drops the link). An `err …` answer is logged.
  Future<String?> _fire(String line,
      {required bool blocking, double lasts = 0}) async {
    final wait = _waitFor(Duration(
        milliseconds: 2000 + (blocking ? 5000 + (lasts * 1000).round() : 0)));
    try {
      final reply = await _send(line).timeout(wait);
      if (reply.startsWith('err')) {
        _log.w('iPhone touches: the runner refused "$line" ($reply)');
      }
      return reply;
    } catch (e) {
      _drop(line, e is TimeoutException ? 'no answer' : 'link down');
      _lost();
      return null;
    }
  }

  void disconnect() {
    _gen++;
    _lost();
    state.value = IosTouchState.idle;
  }

  @override
  void onClose() {
    _gen++;
    _lost();
    unwatch();
    unawaited(_attachments.close());
    super.onClose();
  }
}
