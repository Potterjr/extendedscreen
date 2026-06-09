import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:get/get.dart';
import '../models/packet_model.dart';
import '../services/logger_service.dart';

/// A single-connection TCP transport that can act as either:
///  - CLIENT (Android): [connect] to the host through the adb-reverse tunnel.
///  - SERVER (macOS):   [startServer] and accept the first incoming client.
///
/// Both modes share the same length-prefixed packet framing.
class SocketService extends GetxService {
  final _log = Get.find<LoggerService>();

  Socket? _socket;
  ServerSocket? _server;
  StreamSubscription? _sub;
  StreamSubscription? _serverSub;
  Completer<void>? _clientReady;

  final _packetController = StreamController<Packet>.broadcast();

  // Flat receive buffer with a write-head; avoids repeated toBytes()/sublist copies.
  static const _initialBufSize = 131072; // 128 KB
  Uint8List _recv = Uint8List(_initialBufSize);
  int _recvLen = 0;

  Stream<Packet> get packetStream => _packetController.stream;
  bool get isConnected => _socket != null;

  void _notifyError(Object err) {
    if (_packetController.hasListener) {
      _packetController.addError(err);
    }
  }

  // ─── CLIENT MODE (Android) ────────────────────────────────────────────────

  Future<void> connect(String host, int port) async {
    _log.i('Socket connecting to $host:$port');
    _socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _bind(_socket!);
    _log.i('Socket connected');
  }

  // ─── SERVER MODE (macOS) ──────────────────────────────────────────────────

  /// Binds the listening socket. Returns once bound; use [waitForClient] to
  /// await the first incoming connection.
  Future<void> startServer(String host, int port) async {
    _log.i('Socket server binding on $host:$port');
    _server = await ServerSocket.bind(host, port, shared: true);
    _clientReady = Completer<void>();
    _serverSub = _server!.listen((client) {
      if (_socket != null) {
        // Only one client supported; reject extras.
        client.destroy();
        return;
      }
      _log.i('Client connected from ${client.remoteAddress.address}');
      _socket = client;
      _socket!.setOption(SocketOption.tcpNoDelay, true);
      _bind(_socket!);
      if (!(_clientReady?.isCompleted ?? true)) _clientReady!.complete();
    }, onError: _onError);
  }

  /// Completes when the first client connects (server mode).
  Future<void> waitForClient() => _clientReady?.future ?? Future.value();

  // ─── SHARED ───────────────────────────────────────────────────────────────

  void _bind(Socket socket) {
    _sub = socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  void send(Packet packet) {
    try {
      _socket?.add(packet.serialize());
    } catch (_) {
      // Socket may be closed/reset; ConnectionManager will reconnect via the
      // onError/onDone callbacks already wired to the stream.
    }
  }

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
      final totalLen = Packet.headerSize + payloadLen;
      if (_recvLen - offset < totalLen) break;

      final type = PacketType.fromByte(view.getUint8(4));
      final ts = view.getInt64(9, Endian.big);
      // One copy: extract payload so the ring buffer can be compacted freely.
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

  void _onError(Object err) {
    _log.e('Socket error', err);
    _notifyError(err);
  }

  void _onDone() {
    _log.w('Socket closed by remote');
    _notifyError(const SocketException('Connection closed'));
    // Drop the peer but keep the server listening for reconnects.
    _sub?.cancel();
    _socket = null;
    _recvLen = 0;
    if (_server != null) {
      _clientReady = Completer<void>();
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await _serverSub?.cancel();
    await _socket?.close();
    await _server?.close();
    _socket = null;
    _server = null;
    _clientReady = null;
    _recvLen = 0;
    _log.i('Socket disconnected');
  }

  @override
  void onClose() {
    disconnect();
    _packetController.close();
    super.onClose();
  }
}
