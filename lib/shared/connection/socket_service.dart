import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// A single-connection TCP transport that can act as either:
///  - CLIENT (Android): [connect] to the host through the adb-reverse tunnel,
///    or [connectSecure] to the host's LAN address over TLS.
///  - SERVER (macOS):   [startServer] (loopback, for the adb tunnel) or
///    [startSecureServer] (all interfaces, TLS) and accept the first client.
///
/// All modes share the same length-prefixed packet framing.
///
/// The two TLS entry points also switch the socket to paced sending (see
/// [sendFrame]): a Wi-Fi link can be slower than the stream, and without it
/// frames would pile up in the socket and the picture would fall further and
/// further behind.
class SocketService extends GetxService {
  /// [tlsDialTimeout] is for tests; the app uses the default.
  SocketService({Duration tlsDialTimeout = const Duration(seconds: 8)})
      : _tlsDialTimeout = tlsDialTimeout;

  final _log = Get.find<LoggerService>();

  Socket? _socket;
  ServerSocket? _server;
  SecureServerSocket? _secureServer;
  StreamSubscription? _sub;
  StreamSubscription? _serverSub;
  Completer<void>? _clientReady;

  final _packetController = StreamController<Packet>.broadcast();

  // Flat receive buffer with a write-head; avoids repeated toBytes()/sublist copies.
  static const _initialBufSize = 131072; // 128 KB
  Uint8List _recv = Uint8List(_initialBufSize);
  int _recvLen = 0;

  /// The largest payload a peer may announce. Far above any real frame (a
  /// keyframe of the largest stream is a few MB); a header asking for more is
  /// either corrupt or an attempt to make this side buffer without end.
  static const maxPayloadBytes = 16 * 1024 * 1024;
  int _inboundLimit = maxPayloadBytes;
  // Server only: the limit each new client starts with, until the connection
  // manager has authenticated it and calls [trustPeer].
  int? _untrustedLimit;

  // Changes every time a socket becomes the current one. Lets the connection
  // manager tie what it knows about a peer (it presented the pairing token)
  // to that connection, not to whoever is connected at the moment.
  int _connectionId = 0;

  // Bumped by every dial and by disconnect(). A dial that finishes after
  // either happened finds it changed: it was cancelled or replaced meanwhile,
  // and must drop its socket instead of installing it over what is current.
  // (A TLS dial over Wi-Fi is in flight for a noticeable time; a loopback
  // dial through adb never was.)
  int _dialGen = 0;

  /// Longest a TLS dial may take, TCP connect and handshake together. The
  /// SDK's own `timeout` covers only the TCP part, so a peer that accepts and
  /// then goes silent would otherwise keep the dial pending for ever, with
  /// nothing to trigger a retry.
  final Duration _tlsDialTimeout;

  // ─── Paced sending (Wi-Fi) ────────────────────────────────────────────────
  // Writes go through [_out] and one flush at a time, so this side knows when
  // the kernel has stopped taking data. An IOSink rejects add() while a flush
  // is pending, which is why nothing writes to the socket directly here.
  bool _paced = false;
  final _out = ListQueue<({Uint8List bytes, int queuedUs})>();
  bool _pumping = false;
  // Bumped whenever the socket changes, so a pump still awaiting the old
  // socket's flush stops instead of writing the new session's data.
  int _outGen = 0;
  // When the oldest bytes of the batch being flushed were queued (0: none).
  int _flushingSinceUs = 0;
  // Bytes handed to [send] on this connection, and those of them the kernel
  // has not taken yet (queued in [_out] or in the flush under way).
  int _sentTotal = 0;
  int _userPending = 0;
  // SO_NWRITE could not be read on this connection: don't try again.
  bool _nwriteFailed = false;

  /// Data queued this long ago and still not accepted by the kernel means the
  /// link can't keep up. Well above the few ms a healthy flush takes, even
  /// for a keyframe.
  static const _congestedAfter = Duration(milliseconds: 120);

  Stream<Packet> get packetStream => _packetController.stream;
  bool get isConnected => _socket != null;

  /// Identifies the current connection: a different value means a different
  /// peer socket, even if the previous one is long gone.
  int get connectionId => _connectionId;

  /// The current peer has proved who it is: lift the small pre-authentication
  /// payload limit for the rest of this connection.
  void trustPeer() => _inboundLimit = maxPayloadBytes;

  /// Client side of [startServer]'s `untrustedPayloadLimit`: the peer just
  /// dialled has not proved who it is, and until [trustPeer] it may not
  /// announce a payload over [limit] bytes.
  void distrustPeer({int limit = 1024}) => _inboundLimit = limit;

  /// The port the server is bound to (tests bind port 0 and read it here).
  int? get serverPort => _secureServer?.port ?? _server?.port;

  /// The peer's address, for display. Null when not connected.
  String? get remoteAddress {
    try {
      return _socket?.remoteAddress.address;
    } catch (_) {
      return null;
    }
  }

  /// DER of the certificate the TLS peer presented (client side: the Mac's).
  Uint8List? get peerCertificateDer {
    final s = _socket;
    return s is SecureSocket ? s.peerCertificate?.der : null;
  }

  void _notifyError(Object err) {
    if (_packetController.hasListener) {
      _packetController.addError(err);
    }
  }

  // ─── CLIENT MODE (Android) ────────────────────────────────────────────────

  Future<void> connect(String host, int port) async {
    _log.i('Socket connecting to $host:$port');
    final dial = ++_dialGen;
    final socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    if (dial != _dialGen) {
      socket.destroy();
      throw const SocketException('Dial superseded');
    }
    _resetOut();
    _paced = false;
    _untrustedLimit = null;
    _inboundLimit = maxPayloadBytes;
    _socket = socket;
    _connectionId++;
    _noDelay(socket);
    _bind(socket);
    _log.i('Socket connected');
  }

  /// Dials the host over TLS. No certificate authority is trusted, so every
  /// certificate goes to [trustCertificate] (given its DER), which must accept
  /// only a pinned one.
  Future<void> connectSecure(
    String host,
    int port, {
    required bool Function(Uint8List der) trustCertificate,
  }) async {
    _log.i('Socket connecting to $host:$port (TLS)');
    final dial = ++_dialGen;
    final pending = SecureSocket.connect(
      host,
      port,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (cert) => trustCertificate(cert.der),
      timeout: const Duration(seconds: 5),
    );
    final SecureSocket socket;
    try {
      socket = await pending.timeout(_tlsDialTimeout);
    } on TimeoutException {
      // The handshake can't be cancelled; if it ever does finish, close it.
      pending.then((late) => late.destroy(), onError: (_) {});
      rethrow;
    }
    if (dial != _dialGen) {
      socket.destroy();
      throw const SocketException('Dial superseded');
    }
    _resetOut();
    _paced = true;
    _untrustedLimit = null;
    // The server proved itself with the pinned certificate during the
    // handshake, so its packets are bounded only by the general limit.
    _inboundLimit = maxPayloadBytes;
    _socket = socket;
    _connectionId++;
    _noDelay(socket);
    _bind(socket);
    _log.i('Socket connected (TLS)');
  }

  // ─── SERVER MODE (macOS) ──────────────────────────────────────────────────

  /// Binds the listening socket. Returns once bound; use [waitForClient] to
  /// await the first incoming connection. With [untrustedPayloadLimit], a
  /// client may not announce a larger payload until the connection manager
  /// calls [trustPeer].
  Future<void> startServer(String host, int port,
      {int? untrustedPayloadLimit}) async {
    _log.i('Socket server binding on $host:$port');
    _resetOut();
    _paced = false;
    _untrustedLimit = untrustedPayloadLimit;
    _inboundLimit = untrustedPayloadLimit ?? maxPayloadBytes;
    // Not shared: a second listener on the same port in this process would
    // quietly split the connections between the two.
    _server = await ServerSocket.bind(host, port);
    _clientReady = Completer<void>();
    _serverSub = _server!.listen(_accept, onError: _onError);
  }

  /// Like [startServer], but on every interface and over TLS with [context]'s
  /// certificate. TLS only hides the stream and proves the Mac to the tablet;
  /// the connection manager still has to authenticate the client, and until
  /// it calls [trustPeer] a client may not send a payload larger than
  /// [untrustedPayloadLimit] (the token, a HELLO and heartbeats are tiny).
  Future<void> startSecureServer(
    int port,
    SecurityContext context, {
    int untrustedPayloadLimit = 1024,
  }) async {
    _log.i('Socket server binding on *:$port (TLS)');
    _resetOut();
    _paced = true;
    _untrustedLimit = untrustedPayloadLimit;
    _secureServer = await SecureServerSocket.bind(
        InternetAddress.anyIPv4, port, context,
        shared: true);
    _clientReady = Completer<void>();
    _serverSub = _secureServer!.listen(
      _accept,
      // A handshake that fails here is some other machine knocking (a port
      // scan, a tablet paired with another Mac). It never became the client,
      // so it must not take the session down like a socket error would.
      onError: (Object e) => _log.w('TLS handshake rejected: $e'),
    );
  }

  /// Best effort: a socket whose peer is already gone refuses the option, and
  /// its error or close then arrives through [_bind] like any other loss.
  void _noDelay(Socket socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
  }

  void _accept(Socket client) {
    if (_socket != null) {
      // Only one client supported; reject extras.
      client.destroy();
      return;
    }
    // Everything that can throw comes before the client is made current: a
    // peer that resets right after connecting makes these calls fail, and a
    // socket that became current but was never bound would hold the single
    // client slot for good, with its close never seen.
    try {
      _log.i('Client connected from ${client.remoteAddress.address}');
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      client.destroy();
      return;
    }
    _resetOut();
    _resetRecv();
    _inboundLimit = _untrustedLimit ?? maxPayloadBytes;
    _socket = client;
    _connectionId++;
    _bind(client);
    if (!(_clientReady?.isCompleted ?? true)) _clientReady!.complete();
  }

  /// Completes when the first client connects (server mode).
  Future<void> waitForClient() => _clientReady?.future ?? Future.value();

  /// Server only: closes the current client without reporting a lost link,
  /// and goes back to accepting ([waitForClient] waits for the next one).
  /// For a peer the connection manager turns away before it was ever part of
  /// a session.
  void dropClient() {
    final socket = _socket;
    if (socket == null || (_server == null && _secureServer == null)) return;
    _log.i('Socket: turning the client away');
    _sub?.cancel();
    _socket = null;
    _resetRecv();
    _resetOut();
    socket.destroy();
    _clientReady = Completer<void>();
  }

  // ─── SHARED ───────────────────────────────────────────────────────────────

  void _bind(Socket socket) {
    // Events count only while this socket is the current one. One that was
    // replaced or dropped can still report data, an error or its close; acted
    // on, that would feed stale bytes into the receive buffer or tear down
    // the connection that took its place.
    bool current() => identical(socket, _socket);
    _sub = socket.listen(
      (chunk) {
        if (current()) _onData(chunk);
      },
      onError: (Object err) {
        if (current()) _onError(err);
      },
      onDone: () {
        if (current()) _onDone();
        // The peer closed its half; ours stays open (CLOSE_WAIT, holding a
        // file descriptor until the object is collected) unless it is closed
        // here. Whether or not this socket was still the current one.
        socket.destroy();
      },
      cancelOnError: false,
    );
    // A write to a peer that has gone away also fails the sink's `done`
    // future. The read side above already reports the loss; without a
    // listener here the same failure would surface a second time as an
    // uncaught error.
    socket.done.then((_) {}, onError: (_) {});
  }

  void send(Packet packet) {
    final socket = _socket;
    if (socket == null) return;
    if (_paced) {
      _enqueue(socket, packet.serialize());
      return;
    }
    try {
      socket.add(packet.serialize());
    } catch (_) {
      // Socket may be closed/reset; BaseConnectionManager will reconnect via
      // the onError/onDone callbacks already wired to the stream.
    }
  }

  /// Sends a video frame, unless the link is [isCongested]: then the frame is
  /// dropped and this returns false. The caller must not send another frame
  /// until a keyframe, since later frames reference the dropped one.
  ///
  /// Over USB nothing is paced or dropped and this is [send].
  bool sendFrame(Packet packet) {
    if (isCongested) return false;
    send(packet);
    return true;
  }

  /// Paced links only: data handed to [send] more than [_congestedAfter] ago
  /// has still not left for the kernel.
  bool get isCongested {
    if (!_paced) return false;
    final oldest = _flushingSinceUs != 0
        ? _flushingSinceUs
        : (_out.isEmpty ? 0 : _out.first.queuedUs);
    return oldest != 0 && _nowUs() - oldest > _congestedAfter.inMicroseconds;
  }

  /// Paced links only (0 otherwise): bytes sent on this connection that the
  /// peer has not acknowledged yet, as far as this side can see. Those still
  /// queued here, plus on macOS those in the kernel's send buffer (SO_NWRITE:
  /// TCP keeps data there until the peer acknowledges it). Elsewhere, or if
  /// the option can't be read, only the first part: it grows only once the
  /// kernel's buffer is full, so a slow link shows up later.
  int get unackedBytes => _paced ? _userPending + _kernelUnacked() : 0;

  /// Paced links only (0 otherwise): bytes handed to [send] on this
  /// connection so far. Less [unackedBytes], what the link has carried.
  int get bytesSent => _paced ? _sentTotal : 0;

  /// The part of [unackedBytes] still queued in this process.
  @visibleForTesting
  int get queuedHere => _paced ? _userPending : 0;

  int _kernelUnacked() {
    final socket = _socket;
    if (socket == null || _nwriteFailed || !Platform.isMacOS) return 0;
    const soNwrite = 0x1024; // SO_NWRITE on Darwin
    try {
      final value = socket.getRawOption(RawSocketOption(
          RawSocketOption.levelSocket, soNwrite, Uint8List(4)));
      return ByteData.sublistView(value).getInt32(0, Endian.host);
    } catch (e) {
      _nwriteFailed = true;
      _log.w('Cannot read the send queue (SO_NWRITE): $e');
      return 0;
    }
  }

  /// Caps the kernel's send buffer. Left to itself it grows to megabytes and
  /// hides a slow link for a second or more before [isCongested] can see it.
  /// macOS only (the host is the side that sends video over Wi-Fi). Can be
  /// called again on a live socket: a lower cap keeps what is already queued
  /// and takes nothing more until the queue is below it.
  void limitSendBuffer(int bytes) {
    final socket = _socket;
    if (socket == null || !Platform.isMacOS) return;
    const soSndbuf = 0x1001; // SO_SNDBUF on Darwin
    try {
      socket.setRawOption(RawSocketOption.fromInt(
          RawSocketOption.levelSocket, soSndbuf, bytes));
    } catch (e) {
      _log.w('Could not limit the send buffer: $e');
    }
  }

  void _enqueue(Socket socket, Uint8List bytes) {
    _out.add((bytes: bytes, queuedUs: _nowUs()));
    _sentTotal += bytes.length;
    _userPending += bytes.length;
    if (!_pumping) _pump(socket, _outGen);
  }

  // One packet per flush. [unackedBytes] counts a packet here until its flush
  // is done and in the kernel (SO_NWRITE) as soon as the kernel takes part of
  // it, so a flush still under way is counted twice in part. Flushing whole
  // batches made that up to a batch: 100 ms of stream that read as queue.
  Future<void> _pump(Socket socket, int gen) async {
    _pumping = true;
    try {
      while (gen == _outGen && _out.isNotEmpty) {
        final next = _out.removeFirst();
        _flushingSinceUs = next.queuedUs;
        socket.add(next.bytes);
        await socket.flush();
        if (gen == _outGen) {
          _flushingSinceUs = 0;
          _userPending -= next.bytes.length;
        }
      }
    } catch (_) {
      // Closed or reset mid-write: the read side reports it and the
      // connection manager tears the session down.
    } finally {
      if (gen == _outGen) {
        _pumping = false;
        _flushingSinceUs = 0;
      }
    }
  }

  void _resetOut() {
    _outGen++;
    _out.clear();
    _pumping = false;
    _flushingSinceUs = 0;
    _sentTotal = 0;
    _userPending = 0;
    _nwriteFailed = false;
  }

  static int _nowUs() => DateTime.now().microsecondsSinceEpoch;

  void _onData(Uint8List chunk) {
    final needed = _recvLen + chunk.length;
    if (needed > _recv.length) {
      final bigger = Uint8List(needed * 2);
      bigger.setAll(0, _recv.sublist(0, _recvLen));
      _recv = bigger;
    }
    _recv.setAll(_recvLen, chunk);
    _recvLen += chunk.length;
    _tryParsePackets();
  }

  void _tryParsePackets() {
    var offset = 0;
    while (_recvLen - offset >= Packet.headerSize) {
      final view = ByteData.view(_recv.buffer, _recv.offsetInBytes + offset);
      if (view.getUint32(0, Endian.big) != Packet.magic) {
        _log.w('Socket framing error — flushing receive buffer');
        _recvLen = 0;
        return;
      }
      final payloadLen = view.getUint32(5, Endian.big);
      if (payloadLen > _inboundLimit) {
        _dropPeer('announced a $payloadLen-byte payload, over the limit');
        return;
      }
      final totalLen = Packet.headerSize + payloadLen;
      if (_recvLen - offset < totalLen) break;

      final type = PacketType.fromByte(view.getUint8(4));
      final ts = view.getInt64(9, Endian.big);
      // Two copies (sublist, then fromList): extract payload so the flat
      // receive buffer can be compacted freely.
      final payload = Uint8List.fromList(
          _recv.sublist(_recv.offsetInBytes + offset + Packet.headerSize,
              _recv.offsetInBytes + offset + totalLen));
      _packetController.add(Packet(type: type, timestampUs: ts, payload: payload));
      offset += totalLen;
    }

    if (offset > 0) {
      _recvLen -= offset;
      if (_recvLen > 0) _recv.setAll(0, _recv.sublist(offset, offset + _recvLen));
    }
  }

  /// Closes the current connection from this side and reports it as lost,
  /// the same way a close by the peer is reported.
  void _dropPeer(String why) {
    _log.w('Socket: dropping the peer ($why)');
    final socket = _socket;
    _sub?.cancel();
    _socket = null;
    _resetRecv();
    _resetOut();
    socket?.destroy();
    _notifyError(SocketException('Peer dropped: $why'));
    if (_server != null || _secureServer != null) {
      _clientReady = Completer<void>();
    }
  }

  /// Empties the receive buffer, and gives back one that a large packet (or
  /// a peer trying to exhaust memory) made grow.
  void _resetRecv() {
    _recvLen = 0;
    if (_recv.length > _initialBufSize * 8) _recv = Uint8List(_initialBufSize);
  }

  void _onError(Object err) {
    _log.e('Socket error', err);
    _notifyError(err);
  }

  void _onDone() {
    _log.w('Socket closed by remote');
    _notifyError(const SocketException('Connection closed'));
    // Drop the peer. The connection manager reacts to the error above by
    // tearing the session down (server included) and re-binding cleanly.
    _sub?.cancel();
    _socket = null;
    _resetRecv();
    _resetOut();
    if (_server != null || _secureServer != null) {
      _clientReady = Completer<void>();
    }
  }

  Future<void> disconnect() async {
    _dialGen++; // a dial still in flight must not install its socket
    await _sub?.cancel();
    await _serverSub?.cancel();
    final socket = _socket;
    if (socket != null) {
      if (_paced) {
        // close() throws while a flush is pending, and there is nothing worth
        // waiting to deliver on this link.
        socket.destroy();
      } else {
        try {
          await socket.close();
        } catch (_) {
          // close() repeats an earlier write error (the peer reset the
          // connection). The socket is gone either way; teardown goes on.
        }
      }
    }
    await _server?.close();
    await _secureServer?.close();
    _socket = null;
    _server = null;
    _secureServer = null;
    _resetOut();
    _paced = false;
    // Wake a connect() still parked in waitForClient() so it can see it was
    // cancelled, instead of waiting forever on a server that's gone.
    if (!(_clientReady?.isCompleted ?? true)) _clientReady!.complete();
    _clientReady = null;
    _resetRecv();
    _log.i('Socket disconnected');
  }

  @override
  void onClose() {
    disconnect();
    _packetController.close();
    super.onClose();
  }
}
