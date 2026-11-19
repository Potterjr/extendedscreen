import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';

/// How many synthetic tablets the Mac app stands in for itself:
/// `--dart-define=SYNTH_TABLETS=N`, in a debug build only.
const int synthTabletCount =
    kDebugMode ? int.fromEnvironment('SYNTH_TABLETS') : 0;

/// There are synthetic tablets ([synthTabletCount] > 0). The app tests this,
/// never the comparison itself: a const bool is what the compiler folds
/// before tree-shaking, so in a profile or release build every branch on it
/// is dropped, and [FakeTablet], [SynthAdb] and the Loopback preview with
/// it. An `if (synthTabletCount > 0)` is a comparison the tree-shaker does
/// not evaluate, and it kept [FakeTablet] in a profile build.
const bool synthTablets = synthTabletCount > 0;

/// A tablet running the app, stood in for in this process: it speaks the
/// tablet's half of a USB session to the Mac (the `0xF4` hello made with the
/// key adb delivered, then HELLO with its [panel], pongs to the heartbeat)
/// and keeps what it is sent: frames, the codec, rate and mode the Mac
/// announces. It can also send what the app sends while it shows the Mac
/// (a mouse event, a keyframe request), and dial any port with any key, as
/// something else on the tablet could. A real `ClientConnectionManager` cannot run
/// twice in one process (each would take the one `UsbSessionService`), so
/// the Mac's side of several tablets is tested against these. Paired with
/// [SynthAdb], which plays adb for them.
///
/// Tests use it directly; a debug build with [synthTabletCount] runs some in
/// the app ([SyntheticTablets]). Nothing in a release build refers to it.
class FakeTablet {
  FakeTablet(
    this.serial, {
    this.panel = const ClientPanel(2560, 1600, 60),
    this.model = 'Synthetic_tablet',
  });

  final String serial;
  final String model;
  final ClientPanel panel;

  final _socket = SocketService();
  StreamSubscription<Packet>? _sub;

  // Where adb's tunnel from this tablet's port 7001 leads on the Mac; null
  // while there is none.
  int? _macPort;
  Uint8List? _key;
  Uint8List? _nonce;
  // The key the dial in flight, or the live connection, was made with; null
  // with neither. A delivery of that same key changes nothing, as in the
  // app (see [takeKey]).
  Uint8List? _dialledWith;

  /// The USB session key adb handed this tablet last (null: none yet).
  Uint8List? get key => _key;

  /// The Mac proved it holds this session's key (its `0xF3` checked out),
  /// and was sent HELLO.
  bool get trusted => _trusted;
  bool _trusted = false;

  /// Frames and their bytes received while trusted.
  int frames = 0;
  int frameBytes = 0;

  /// The first byte of every control packet received while trusted.
  final controls = <int>[];

  /// Each frame's payload as it arrives (while trusted).
  Stream<Uint8List> get frameStream => _frames.stream;
  final _frames = StreamController<Uint8List>.broadcast();

  /// What the Mac announced last: the codec (`0xFC`), the stream's rate
  /// (`0xFB`) and the session mode (`0xF9`). Null until it has.
  CodecType? codec;
  int? rate;
  SessionMode? mode;

  /// Every rate the Mac announced (`0xFB`), in order.
  final rates = <int>[];

  /// adb pointed this tablet's port at [macPort] on the Mac (null: the rule
  /// is gone).
  void tunnel(int? macPort) => _macPort = macPort;

  /// adb delivered a USB session key: the app dials at once with it, unless
  /// the dial in flight or the live connection was made with that very key
  /// (the Mac delivers a key again when a hello without it came first, and
  /// both deliveries can land together).
  Future<void> takeKey(Uint8List key) async {
    final current = _dialledWith;
    if (current != null && _sameBytes(current, key)) return;
    _key = key;
    await dial();
  }

  /// Dials the Mac through the tunnel and says hello. Nothing happens
  /// without a tunnel, as the tablet's dial would be refused.
  Future<void> dial() async {
    // Synchronously, before the first await: a delivery landing meanwhile
    // sees which key this dial is for.
    final key = _dialledWith = _key;
    await _hangUp();
    final port = _macPort;
    if (port == null || !identical(key, _dialledWith)) return _dialFailed(key);
    try {
      await _socket.connect('127.0.0.1', port);
    } catch (_) {
      return _dialFailed(key);
    }
    // The Mac closing the connection (or the tunnel going) ends the session.
    _sub = _socket.packetStream.listen(_onPacket,
        onError: (_) => _lost(key), onDone: () => _lost(key));
    final nonce = _nonce = UsbSessionService.newNonce();
    _send(UsbSessionService.buildHello(key, nonce));
  }

  // A dial that came to nothing, or a connection that ended, holds no key:
  // the same key delivered again dials again.
  void _dialFailed(Uint8List? key) {
    if (identical(key, _dialledWith)) _dialledWith = null;
  }

  void _lost(Uint8List? key) {
    _trusted = false;
    _dialFailed(key);
  }

  Future<void> hangUp() async {
    _dialledWith = null;
    await _hangUp();
  }

  Future<void> _hangUp() async {
    _trusted = false;
    await _sub?.cancel();
    _sub = null;
    await _socket.disconnect();
  }

  /// Dials [port] on the Mac on a connection of its own, beside this
  /// tablet's session (which it leaves alone), and says hello with [key]
  /// (null: a hello without one), as anything else that can reach the port
  /// could. Returns whether the Mac answered as the holder of [key] would:
  /// false once it turns the connection away, or after [wait]. The
  /// connection is closed either way.
  Future<bool> dialWith(int port, Uint8List? key,
      {Duration wait = const Duration(seconds: 5)}) async {
    final socket = SocketService();
    try {
      await socket.connect('127.0.0.1', port);
    } catch (_) {
      return false;
    }
    final answered = Completer<bool>();
    void settle(bool value) {
      if (!answered.isCompleted) answered.complete(value);
    }

    final nonce = UsbSessionService.newNonce();
    final sub = socket.packetStream.listen(
      (packet) {
        if (key != null &&
            packet.type == PacketType.control &&
            UsbSessionService.verifyAnswer(key, nonce, packet.payload)) {
          settle(true);
        }
      },
      onError: (_) => settle(false),
      onDone: () => settle(false),
    );
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: UsbSessionService.buildHello(key, nonce),
    ));
    final result = await answered.future.timeout(wait, onTimeout: () => false);
    await sub.cancel();
    await socket.disconnect();
    return result;
  }

  /// A mouse event, as the app's display sends one.
  void sendMouse(MouseEventModel event) =>
      _socket.send(PacketCodec.wrapMouse(event));

  /// `0xFF`: asks the Mac's encoder for a keyframe, as the app's decoder
  /// does.
  void requestKeyframe() => _send(Uint8List.fromList([0xFF]));

  void _onPacket(Packet packet) {
    if (!_trusted) {
      final key = _key, nonce = _nonce;
      if (packet.type == PacketType.control &&
          key != null &&
          nonce != null &&
          UsbSessionService.verifyAnswer(key, nonce, packet.payload)) {
        _trusted = true;
        _socket.trustPeer();
        _sendHello();
      }
      return;
    }
    switch (packet.type) {
      case PacketType.heartbeat:
        if (!PacketCodec.heartbeatIsPong(packet.payload)) {
          final pong = PacketCodec.heartbeatPong(packet.payload);
          if (pong != null) _socket.send(pong);
        }
      case PacketType.frameData:
        frames++;
        frameBytes += packet.payload.length;
        _frames.add(packet.payload);
      case PacketType.control when packet.payload.isNotEmpty:
        final p = packet.payload;
        controls.add(p[0]);
        switch (p[0]) {
          case 0xFC when p.length >= 2:
            codec = p[1] == 1 ? CodecType.h265 : CodecType.h264;
          case 0xFB when p.length >= 2:
            rate = p[1];
            rates.add(p[1]);
          case 0xF9 when p.length >= 2 && p[1] < SessionMode.values.length:
            mode = SessionMode.values[p[1]];
          default:
            break;
        }
      default:
        break;
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// HELLO: platform Android, the panel's size and top rate.
  void _sendHello() => _send(Uint8List.fromList([
        0x01,
        0x02,
        panel.width >> 8,
        panel.width & 0xFF,
        panel.height >> 8,
        panel.height & 0xFF,
        panel.maxHz,
      ]));

  void _send(Uint8List payload) => _socket.send(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: payload,
      ));
}

/// adb for [FakeTablet]s, in this process: lists them, points each one's
/// tunnel at the Mac port a reverse rule names, and hands it its session
/// key (which it dials with at once, as the app does). Pairings are taken
/// and dropped; the screen-off helper and `adb shell input` are not there.
/// A test can close a tablet's app ([appOpen]) or hold its key deliveries
/// ([deliveryGates]).
class SynthAdb extends AdbService {
  SynthAdb(Iterable<FakeTablet> tablets)
      : _tablets = {for (final t in tablets) t.serial: t},
        _routing = false;

  /// adb for the app's synthetic tablets beside the real ones: a `synth-`
  /// serial goes to its [FakeTablet], every other serial to adb itself
  /// ([AdbService]), and a listing is adb's devices followed by the fakes.
  /// The fakes keep [syntheticSerialPrefix] serials, which nothing persists
  /// and the auto-connect policy never picks.
  SynthAdb.routing(Iterable<FakeTablet> tablets)
      : _tablets = {for (final t in tablets) t.serial: t},
        _routing = true;

  final Map<String, FakeTablet> _tablets;
  final bool _routing;

  // What adb listed last time it could (routing only): a failed `adb
  // devices` changes nothing about the real tablets, as with adb alone.
  List<DeviceModel> _lastReal = const [];

  /// [serial] is a real device, for adb itself ([SynthAdb.routing] only).
  bool _real(String serial) =>
      _routing && !serial.startsWith(syntheticSerialPrefix);

  /// The reverse rule each tablet has: its port, and the Mac port it leads
  /// to.
  final reverses = <String, ({int remote, int local})>{};

  /// Tablets `adb devices` does not list (unplugged).
  final unplugged = <String>{};

  /// The `transport_id` each tablet is listed with (none: not said). A new
  /// one is what adb lists after a replug.
  final transports = <String, String>{};

  /// How many times the devices were listed.
  int listings = 0;

  /// `adb devices` fails (no binary, a timeout): the listing says nothing.
  bool listingFails = false;

  /// How long the next reverse calls take, one entry each (then none).
  final reverseDelays = <Duration>[];

  /// How long removing a rule takes.
  Duration removeDelay = Duration.zero;

  /// How many session keys each tablet was handed.
  final keysDelivered = <String, int>{};

  /// The session key each tablet was handed last.
  final keys = <String, Uint8List>{};

  /// How many Wi-Fi pairings each tablet was handed.
  final pairingsDelivered = <String, int>{};

  /// Tablets whose app is not open (false): a session key reaches nobody
  /// there (`notDelivered`, as `am broadcast` reports it). Absent: open.
  final appOpen = <String, bool>{};

  /// While a tablet has an entry here, its key deliveries wait for it to
  /// complete (adb taking its time), and then go on as they would have.
  final deliveryGates = <String, Completer<void>>{};

  @override
  Future<List<DeviceModel>?> listDevicesOrNull() async {
    listings++;
    if (listingFails) return null;
    var real = const <DeviceModel>[];
    if (_routing) {
      real = _lastReal = await super.listDevicesOrNull() ?? _lastReal;
    }
    return [
      ...real,
      for (final t in _tablets.values)
        if (!unplugged.contains(t.serial))
          DeviceModel(
              serial: t.serial,
              model: t.model,
              transportId: transports[t.serial],
              status: DeviceStatus.connected),
    ];
  }

  @override
  Future<bool> reverseForward({
    required String serial,
    required int localPort,
    required int remotePort,
  }) async {
    if (_real(serial)) {
      return super.reverseForward(
          serial: serial, localPort: localPort, remotePort: remotePort);
    }
    if (reverseDelays.isNotEmpty) {
      await Future<void>.delayed(reverseDelays.removeAt(0));
    }
    final tablet = _tablets[serial];
    if (tablet == null || unplugged.contains(serial)) return false;
    reverses[serial] = (remote: remotePort, local: localPort);
    tablet.tunnel(localPort);
    return true;
  }

  @override
  Future<void> removeForward({required String serial, int? remotePort}) async {
    if (_real(serial)) {
      return super.removeForward(serial: serial, remotePort: remotePort);
    }
    if (removeDelay > Duration.zero) await Future<void>.delayed(removeDelay);
    reverses.remove(serial);
    _tablets[serial]?.tunnel(null);
  }

  @override
  Future<AdbDelivery> deliverUsbSessionKey({
    required String serial,
    required Uint8List key,
  }) async {
    if (_real(serial)) {
      return super.deliverUsbSessionKey(serial: serial, key: key);
    }
    final gate = deliveryGates[serial];
    if (gate != null) await gate.future;
    final tablet = _tablets[serial];
    if (tablet == null ||
        unplugged.contains(serial) ||
        appOpen[serial] == false) {
      return AdbDelivery.notDelivered;
    }
    keysDelivered[serial] = (keysDelivered[serial] ?? 0) + 1;
    keys[serial] = key;
    unawaited(tablet.takeKey(key));
    return AdbDelivery.stored;
  }

  @override
  Future<AdbDelivery> deliverWifiPairing({
    required String serial,
    required Uint8List payload,
  }) async {
    if (_real(serial)) {
      return super.deliverWifiPairing(serial: serial, payload: payload);
    }
    if (!_tablets.containsKey(serial)) return AdbDelivery.notDelivered;
    pairingsDelivered[serial] = (pairingsDelivered[serial] ?? 0) + 1;
    return AdbDelivery.stored;
  }

  @override
  Future<String?> holdTabletScreenOff({required String serial}) async =>
      _real(serial)
          ? super.holdTabletScreenOff(serial: serial)
          : 'a synthetic tablet has no panel to turn off';

  @override
  Future<void> releaseTabletScreenOff({required String serial}) async {
    if (_real(serial)) await super.releaseTabletScreenOff(serial: serial);
  }

  @override
  Future<void> inputTap(
      {required String serial, required int x, required int y}) async {
    if (_real(serial)) await super.inputTap(serial: serial, x: x, y: y);
  }

  @override
  Future<void> inputSwipe({
    required String serial,
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    int durationMs = 50,
  }) async {
    if (_real(serial)) {
      await super.inputSwipe(
          serial: serial,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          durationMs: durationMs);
    }
  }

  @override
  Future<void> inputKeyevent(
      {required String serial, required int keycode}) async {
    if (_real(serial)) {
      await super.inputKeyevent(serial: serial, keycode: keycode);
    }
  }

  @override
  Future<void> inputText({required String serial, required String text}) async {
    if (_real(serial)) await super.inputText(serial: serial, text: text);
  }
}

/// The Mac app's synthetic tablets in a debug build ([synthTabletCount] of
/// them, `synth-1` on), and the adb that reaches them beside the real ones
/// ([SynthAdb.routing]), which `InitialBinding` registers as the
/// [AdbService]. Each one is a [FakeTablet] dialling this Mac's sessions on
/// loopback, so the Mac's side runs for real: virtual displays,
/// ScreenCaptureKit, VideoToolbox, the encode budget. That measures what
/// this Mac can take with no tablet at all, and the Loopback preview shows
/// what each stream carries.
///
/// Their panels take turns over three shapes, so a stream showing another
/// tablet's display has the wrong shape: bars in its preview tile, and the
/// capture's first-frame check (`onCaptureMismatch`, 2% tolerance) flags it.
class SyntheticTablets extends GetxService {
  SyntheticTablets(int count)
      : tablets = [
          for (var i = 0; i < count; i++)
            FakeTablet(
              '$syntheticSerialPrefix${i + 1}',
              panel: panels[i % panels.length],
              model: 'Synthetic_${i + 1}',
            ),
        ];

  /// 16:10 at 60 Hz, 7:5 at 120 Hz and 20:9 at 60 Hz.
  static const panels = [
    ClientPanel(2560, 1600, 60),
    ClientPanel(2800, 2000, 120),
    ClientPanel(2400, 1080, 60),
  ];

  final List<FakeTablet> tablets;

  late final SynthAdb adb = SynthAdb.routing(tablets);

  @override
  void onClose() {
    for (final t in tablets) {
      unawaited(t.hangUp());
    }
    super.onClose();
  }
}
