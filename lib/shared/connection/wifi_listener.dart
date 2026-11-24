import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/platform/host_name.dart';
import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// A device on Wi-Fi that has proved itself: it finished TLS with this Mac's
/// certificate, presented the pairing token (`0xF5`) and said HELLO. Its
/// connection is [socket]'s, already trusted; the session made for it takes
/// that socket over.
class WifiPeer {
  WifiPeer({
    required this.socket,
    required this.hello,
    required this.address,
  }) : tail = HelloTail.parse(hello);

  final SocketService socket;

  /// The whole HELLO payload, command byte first.
  final Uint8List hello;

  /// Its identity tail, if it sent one.
  final HelloTail? tail;

  /// The peer's address, for display.
  final String? address;

  /// HELLO's platform byte, or null for a HELLO too short to carry one.
  int? get platform => hello.length >= 2 ? hello[1] : null;
}

/// The hub's one Wi-Fi listener: a plain TCP server on every interface,
/// each connection taken through TLS and then made to prove itself before
/// anything else sees it, so any number of paired devices can join on one
/// port and nothing that cannot prove itself holds anything for long.
///
/// - TLS runs on each accepted socket under [handshakeTimeout]; past it the
///   connection gives its pending place back. It cannot be closed: dart:io's
///   upgrade takes the socket over, and offers no way to abort a handshake,
///   so a peer that connects and stays mute keeps its socket open until it
///   leaves, as with `SecureServerSocket` before. One remote address may
///   hold at most half the pending places, so one machine cannot keep the
///   paired devices out.
/// - At most [maxPending] connections wait to prove themselves at a time,
///   and live ones plus waiting ones stay within [maxLive] + [maxPending];
///   anything more is destroyed at once.
/// - A proven connection must open with the pairing token within
///   [proofTimeout], then say HELLO within [proofTimeout] again; until the
///   token passes it may not announce a payload over 1 KB.
/// - The discovery responder runs exactly as long as the listener.
class WifiListener {
  WifiListener({
    required this.port,
    required this.identity,
    required this.onPeer,
    required this.maxLive,
    this.liveCount,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.proofTimeout = const Duration(seconds: 3),
    this.maxPending = 4,
  });

  final int port;
  final WifiIdentity identity;

  /// A device proved itself; the callee owns [WifiPeer.socket] from now on.
  final void Function(WifiPeer peer) onPeer;

  /// The most devices that may be live at once (the hub's cap).
  final int Function() maxLive;

  /// How many Wi-Fi devices are live now, for the overall bound.
  final int Function()? liveCount;

  final Duration handshakeTimeout;
  final Duration proofTimeout;
  final int maxPending;

  final _log = Get.find<LoggerService>();
  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSub;
  bool _stopped = false;

  /// Connections taken but not yet proven (TLS, token or HELLO pending).
  int get pending => _pending;
  int _pending = 0;

  /// Connections turned away for want of room since the listener started.
  int turnedAway = 0;

  /// The bound port (tests bind 0).
  int? get boundPort => _server?.port;

  bool get isListening => _server != null;

  WifiDiscoveryService? get _discovery =>
      Get.isRegistered<WifiDiscoveryService>()
          ? Get.find<WifiDiscoveryService>()
          : null;

  /// Binds and starts answering discovery. Throws when the port cannot be
  /// bound.
  Future<void> start() async {
    _stopped = false;
    // Not shared: a second listener on the same port in this process would
    // quietly split the connections between the two.
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    if (_stopped) {
      await server.close();
      return;
    }
    _server = server;
    _serverSub = server.listen(_accept, onError: (Object e) {
      _log.w('Wi-Fi listener: accept failed ($e)');
    });
    _log.i('Wi-Fi listener on *:${server.port}');
    try {
      final name = await macDisplayName();
      if (!_stopped) {
        await _discovery?.startResponder(
          hostId: identity.hostId,
          name: name,
          tcpPort: server.port,
        );
      }
    } catch (e) {
      // Not fatal: a device can still dial an address it knows.
      _log.w('Wi-Fi listener: discovery responder not started ($e)');
    }
  }

  /// Stops listening and answering discovery. Connections still proving
  /// themselves are dropped; proven ones belong to their sessions.
  Future<void> stop() async {
    _stopped = true;
    _discovery?.stopResponder();
    await _serverSub?.cancel();
    _serverSub = null;
    final server = _server;
    _server = null;
    await server?.close();
  }

  void _accept(Socket raw) {
    final live = liveCount?.call() ?? 0;
    String address;
    try {
      address = raw.remoteAddress.address;
    } catch (_) {
      raw.destroy();
      return;
    }
    // One machine may hold at most half the pending places: a single host
    // on the LAN reopening mute connections cannot keep every paired device
    // out.
    final fromThere = _pendingFrom[address] ?? 0;
    if (_stopped ||
        _pending >= maxPending ||
        fromThere >= (maxPending ~/ 2).clamp(1, maxPending) ||
        live + _pending >= maxLive() + maxPending) {
      turnedAway++;
      raw.destroy();
      return;
    }
    _pending++;
    _pendingFrom[address] = fromThere + 1;
    unawaited(_prove(raw).whenComplete(() {
      _pending--;
      final left = (_pendingFrom[address] ?? 1) - 1;
      if (left <= 0) {
        _pendingFrom.remove(address);
      } else {
        _pendingFrom[address] = left;
      }
    }));
  }

  // Pending connections by remote address.
  final _pendingFrom = <String, int>{};

  Future<void> _prove(Socket raw) async {
    final SecureSocket secure;
    final handshake = SecureSocket.secureServer(raw, identity.serverContext());
    try {
      secure = await handshake.timeout(handshakeTimeout);
    } on TimeoutException {
      // raw is detached by now: destroying it closes nothing. A handshake
      // that finishes after all is closed then.
      unawaited(handshake.then((late) => late.destroy(), onError: (_) {}));
      _log.w('Wi-Fi listener: TLS handshake took too long — given up');
      return;
    } catch (e) {
      // Some other machine knocking (a port scan, a device paired with
      // another Mac): never part of anything.
      _log.w('Wi-Fi listener: TLS handshake rejected ($e)');
      raw.destroy();
      return;
    }
    if (_stopped) {
      secure.destroy();
      return;
    }
    String? address;
    try {
      address = secure.remoteAddress.address;
    } catch (_) {}
    final socket = SocketService();
    if (!socket.adoptClient(secure, paced: true, untrustedPayloadLimit: 1024)) {
      return;
    }
    final token = Completer<bool>();
    final hello = Completer<Uint8List?>();
    final sub = socket.packetStream.listen((packet) {
      final p = packet.payload;
      if (packet.type != PacketType.control || p.isEmpty) return;
      if (!token.isCompleted) {
        // The first control packet must be the token; anything else, or a
        // wrong token, ends it.
        token.complete(p[0] == WifiPairingService.authCommand &&
            identity.tokenMatches(p.sublist(1)));
      } else if (p[0] == ClientHello.command && !hello.isCompleted) {
        hello.complete(Uint8List.fromList(p));
      }
    }, onError: (Object _) {
      if (!token.isCompleted) token.complete(false);
      if (!hello.isCompleted) hello.complete(null);
    }, onDone: () {
      if (!token.isCompleted) token.complete(false);
      if (!hello.isCompleted) hello.complete(null);
    });
    try {
      final proved = await token.future
          .timeout(proofTimeout, onTimeout: () => false);
      if (!proved || _stopped) {
        _log.w('Wi-Fi listener: a client without the pairing token — dropped');
        await socket.disconnect();
        return;
      }
      socket.trustPeer();
      final said =
          await hello.future.timeout(proofTimeout, onTimeout: () => null);
      if (said == null || _stopped) {
        await socket.disconnect();
        return;
      }
      await sub.cancel();
      onPeer(WifiPeer(socket: socket, hello: said, address: address));
    } finally {
      await sub.cancel();
    }
  }
}
