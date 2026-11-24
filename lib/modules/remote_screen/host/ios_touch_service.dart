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

  /// Connected to the runner: touches go through.
  ready,
}

/// Which way a phone showing a landscape picture is turned: where the top
/// of its portrait screen is in the picture.
enum IosTurn { topLeft, topRight }

/// Mac: touches on an iPhone or iPad over USB. iOS lets no app take input
/// from outside, so they go to the TouchRunner, an XCUITest started on the
/// phone from Xcode, which listens on [runnerPort] and synthesizes them
/// through XCTest (private event synthesis, WebDriverAgent-style; a touch
/// lands about 100 ms after it is sent). Reached through usbmuxd, over the
/// cable. Coordinates are normalized to the screen in portrait.
class IosTouchService extends GetxService {
  IosTouchService({UsbmuxClient? usbmux}) : _usbmux = usbmux ?? UsbmuxClient();

  static const runnerPort = 8100;

  final UsbmuxClient _usbmux;
  final state = IosTouchState.idle.obs;

  /// The runner's screen size in points ("pong 440x956"), once connected.
  final screenPoints = RxnString();

  /// Whether the runner synthesizes touches itself (its pong's `fast=`).
  /// Without that its `atap`/`aswipe` are refused, so the blocking
  /// `tap`/`swipe` (XCUICoordinate, which answer once the touch is done) are
  /// sent instead.
  bool fast = true;

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
  /// Caveat: `orient` reads `XCUIDevice.shared.orientation`, the phone's
  /// physical orientation, not the frontmost app's interface orientation;
  /// with rotation lock on, or the phone flat, the two can differ.
  final lastTurn = IosTurn.topLeft.obs;

  /// The `orient` under way, if any: a second ask waits for it.
  Future<IosTurn>? _turning;

  LoggerService get _log => Get.find<LoggerService>();

  /// Connects to the runner on the first iOS device on USB (or [udid]), if
  /// not connected. True once connected.
  Future<bool> connect({String? udid}) {
    if (state.value == IosTouchState.ready && _stream != null) {
      return Future.value(true);
    }
    return _connecting ??= _connect(udid).whenComplete(() => _connecting = null);
  }

  Future<bool> _connect(String? udid) async {
    final gen = _gen;
    UsbmuxStream? opened;
    try {
      final devices = await _usbmux.listDevices();
      if (gen != _gen) return false;
      final device = devices.firstWhereOrNull(
          (d) => d.isUsb && (udid == null || d.serial == udid));
      if (device == null) {
        state.value = IosTouchState.noDevice;
        return false;
      }
      final stream = opened = await _usbmux.connect(device.deviceId, runnerPort);
      if (gen != _gen) {
        stream.close();
        return false;
      }
      _stream = stream;
      _lines = stream.data
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (_replies.isNotEmpty) _replies.removeAt(0).complete(line);
      }, onDone: _lost, onError: (Object _) => _lost());
      final pong = await _send('ping').timeout(const Duration(seconds: 2));
      if (gen != _gen) {
        stream.close();
        return false;
      }
      if (!pong.startsWith('pong')) {
        _lost();
        state.value = IosTouchState.noRunner;
        return false;
      }
      final fields = pong.split(' ');
      screenPoints.value = fields.elementAtOrNull(1);
      fast = !fields.contains('fast=false');
      _refusedFast.clear();
      if (!fast) {
        _log.w('iPhone touches: the runner has no fast synthesis; '
            'using its blocking tap and swipe');
      }
      state.value = IosTouchState.ready;
      // The side the phone is turned, ready before the first landscape
      // click. Sent now, before any touch, and not waited for.
      unawaited(_turning ??= _orient().whenComplete(() => _turning = null));
      return true;
    } on UsbmuxRefused {
      if (gen != _gen) return false;
      state.value = IosTouchState.noRunner;
      return false;
    } catch (e) {
      if (gen != _gen) {
        opened?.close();
        return false;
      }
      _log.w('iPhone touches: no runner ($e)');
      _lost();
      state.value = IosTouchState.noRunner;
      return false;
    }
  }

  void _lost() {
    unawaited(_lines?.cancel());
    _lines = null;
    _stream?.close();
    _stream = null;
    for (final r in _replies) {
      if (!r.isCompleted) r.completeError(StateError('runner gone'));
    }
    _replies.clear();
    if (state.value == IosTouchState.ready) state.value = IosTouchState.noRunner;
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

  /// Presses the phone's Home button (the Home Screen). False when it was
  /// not done: no runner, or a runner built before `home`.
  Future<bool> home() async {
    if (!await connect()) return false;
    final reply = await _fire('home', blocking: true, lasts: 1);
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
      final reply = await _send('orient').timeout(const Duration(seconds: 2));
      // UIDeviceOrientation: 3 landscapeLeft (the top on the left), 4
      // landscapeRight.
      switch (reply.split(' ').elementAtOrNull(1)) {
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
    if (!await connect()) return;
    if (fast && !_refusedFast.contains(fastVerb)) {
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
    final wait = Duration(
        milliseconds: 2000 + (blocking ? 5000 + (lasts * 1000).round() : 0));
    try {
      final reply = await _send(line).timeout(wait);
      if (reply.startsWith('err')) {
        _log.w('iPhone touches: the runner refused "$line" ($reply)');
      }
      return reply;
    } catch (_) {
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
    super.onClose();
  }
}
