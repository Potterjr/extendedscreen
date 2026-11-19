import 'dart:async';
import 'dart:typed_data';

import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';

/// A tablet running the app, stood in for in this process: it speaks the
/// tablet's half of a USB session to the Mac (the `0xF4` hello made with the
/// key adb delivered, then HELLO with its [panel], pongs to the heartbeat)
/// and counts what it is sent. A real `ClientConnectionManager` cannot run
/// twice in one process (each would take the one `UsbSessionService`), so
/// the Mac's side of several tablets is tested against these. Paired with
/// [SynthAdb], which plays adb for them.
///
/// Test and debug use only: nothing in a release build refers to it.
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

  /// The Mac proved it holds this session's key (its `0xF3` checked out),
  /// and was sent HELLO.
  bool get trusted => _trusted;
  bool _trusted = false;

  /// Frames and their bytes received while trusted.
  int frames = 0;
  int frameBytes = 0;

  /// The first byte of every control packet received while trusted.
  final controls = <int>[];

  /// adb pointed this tablet's port at [macPort] on the Mac (null: the rule
  /// is gone).
  void tunnel(int? macPort) => _macPort = macPort;

  /// adb delivered a USB session key: the app dials at once with it.
  Future<void> takeKey(Uint8List key) async {
    _key = key;
    await dial();
  }

  /// Dials the Mac through the tunnel and says hello. Nothing happens
  /// without a tunnel, as the tablet's dial would be refused.
  Future<void> dial() async {
    await hangUp();
    final port = _macPort;
    if (port == null) return;
    try {
      await _socket.connect('127.0.0.1', port);
    } catch (_) {
      return;
    }
    // The Mac closing the connection (or the tunnel going) ends the session.
    _sub = _socket.packetStream.listen(_onPacket,
        onError: (_) => _trusted = false, onDone: () => _trusted = false);
    final nonce = _nonce = UsbSessionService.newNonce();
    _send(UsbSessionService.buildHello(_key, nonce));
  }

  Future<void> hangUp() async {
    _trusted = false;
    await _sub?.cancel();
    _sub = null;
    await _socket.disconnect();
  }

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
      case PacketType.control when packet.payload.isNotEmpty:
        controls.add(packet.payload[0]);
      default:
        break;
    }
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
class SynthAdb extends AdbService {
  SynthAdb(Iterable<FakeTablet> tablets)
      : _tablets = {for (final t in tablets) t.serial: t};

  final Map<String, FakeTablet> _tablets;

  /// The reverse rule each tablet has: its port, and the Mac port it leads
  /// to.
  final reverses = <String, ({int remote, int local})>{};

  /// Tablets `adb devices` does not list (unplugged).
  final unplugged = <String>{};

  /// How many times the devices were listed.
  int listings = 0;

  /// How long the next reverse calls take, one entry each (then none).
  final reverseDelays = <Duration>[];

  /// How long removing a rule takes.
  Duration removeDelay = Duration.zero;

  /// How many session keys each tablet was handed.
  final keysDelivered = <String, int>{};

  @override
  Future<List<DeviceModel>> listDevices() async {
    listings++;
    return [
      for (final t in _tablets.values)
        if (!unplugged.contains(t.serial))
          DeviceModel(
              serial: t.serial, model: t.model, status: DeviceStatus.connected),
    ];
  }

  @override
  Future<bool> reverseForward({
    required String serial,
    required int localPort,
    required int remotePort,
  }) async {
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
    if (removeDelay > Duration.zero) await Future<void>.delayed(removeDelay);
    reverses.remove(serial);
    _tablets[serial]?.tunnel(null);
  }

  @override
  Future<AdbDelivery> deliverUsbSessionKey({
    required String serial,
    required Uint8List key,
  }) async {
    final tablet = _tablets[serial];
    if (tablet == null || unplugged.contains(serial)) {
      return AdbDelivery.notDelivered;
    }
    keysDelivered[serial] = (keysDelivered[serial] ?? 0) + 1;
    unawaited(tablet.takeKey(key));
    return AdbDelivery.stored;
  }

  @override
  Future<AdbDelivery> deliverWifiPairing({
    required String serial,
    required Uint8List payload,
  }) async =>
      _tablets.containsKey(serial)
          ? AdbDelivery.stored
          : AdbDelivery.notDelivered;

  @override
  Future<String?> holdTabletScreenOff({required String serial}) async =>
      'a synthetic tablet has no panel to turn off';

  @override
  Future<void> releaseTabletScreenOff({required String serial}) async {}

  @override
  Future<void> inputTap(
      {required String serial, required int x, required int y}) async {}

  @override
  Future<void> inputSwipe({
    required String serial,
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    int durationMs = 50,
  }) async {}

  @override
  Future<void> inputKeyevent(
      {required String serial, required int keycode}) async {}

  @override
  Future<void> inputText({required String serial, required String text}) async {}
}
