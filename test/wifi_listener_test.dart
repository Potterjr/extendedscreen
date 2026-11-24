import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/wifi_listener.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// The hub's Wi-Fi listener on its own, with short deadlines: real loopback
/// sockets and real TLS, so plain `test()`.

class _QuietLogger extends LoggerService {
  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) {}
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

final _opensslMissing =
    Platform.isMacOS && File('/usr/bin/openssl').existsSync()
        ? null
        : 'needs /usr/bin/openssl (macOS)';

Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Whether [socket]'s peer closed it within [within].
Future<bool> _closedWithin(Socket socket, Duration within) {
  final closed = Completer<bool>();
  socket.listen((_) {}, onDone: () {
    if (!closed.isCompleted) closed.complete(true);
  }, onError: (_) {
    if (!closed.isCompleted) closed.complete(true);
  });
  return closed.future.timeout(within, onTimeout: () => false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WifiIdentity identity;
  late WifiListener listener;
  final peers = <WifiPeer>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    final settings = SettingsService();
    await settings.init();
    Get.put(settings);
    peers.clear();
    if (_opensslMissing != null) return;
    identity = await Get.put(WifiPairingService()).ensureIdentity();
    listener = WifiListener(
      port: 0,
      identity: identity,
      onPeer: peers.add,
      maxLive: () => 4,
      handshakeTimeout: const Duration(milliseconds: 400),
      proofTimeout: const Duration(milliseconds: 400),
      maxPending: 4,
    );
    await listener.start();
  });

  tearDown(() async {
    if (_opensslMissing == null) await listener.stop();
    for (final p in peers) {
      await p.socket.disconnect();
    }
    Get.reset();
  });

  /// A paired device: TLS, the token, then HELLO (with [installId], a tail).
  Future<SocketService> pairedDial({Uint8List? installId}) async {
    final s = SocketService();
    await s.connectSecure('127.0.0.1', listener.boundPort!,
        trustCertificate: (_) => true);
    void send(List<int> p) => s.send(Packet(
        type: PacketType.control,
        timestampUs: 0,
        payload: Uint8List.fromList(p)));
    send([WifiPairingService.authCommand, ...identity.token]);
    send(ClientHello.payload(
        platform: ClientPlatform.iphone,
        width: 2496,
        height: 1320,
        maxRefreshHz: 120,
        installId: installId));
    addTearDown(s.disconnect);
    return s;
  }

  test('a paired device that says HELLO is handed over, its identity read',
      () async {
    final id = Uint8List.fromList(List.filled(16, 7));
    await pairedDial(installId: id);
    await _until(() => peers.isNotEmpty);
    expect(peers.single.tail?.installId, id);
    expect(peers.single.platform, 0x03);
    expect(peers.single.socket.isConnected, isTrue);
    expect(listener.pending, 0);
  }, skip: _opensslMissing);

  test('two devices on one listener are each handed over', () async {
    await pairedDial(installId: Uint8List.fromList(List.filled(16, 1)));
    await pairedDial();
    await _until(() => peers.length == 2);
    expect(peers.where((p) => p.tail == null), hasLength(1));
  }, skip: _opensslMissing);

  test('a connection that never starts TLS gives its pending place back at '
      'the handshake deadline, so it locks nobody out', () async {
    // dart:io's TLS upgrade takes the socket over, so the listener cannot
    // close it: an idle peer keeps it open until it leaves. What the deadline
    // does guarantee is that it holds no place among the pending ones.
    final idle = [
      for (var i = 0; i < 2; i++)
        await Socket.connect('127.0.0.1', listener.boundPort!),
    ];
    for (final s in idle) {
      addTearDown(s.destroy);
    }
    await _until(() => listener.pending == 2);
    await _until(() => listener.pending == 0,
        timeout: const Duration(seconds: 3));
    await pairedDial();
    await _until(() => peers.length == 1);
  }, skip: _opensslMissing);

  test('one address may hold half the pending places: past that a '
      'connection from it is turned away at once, and a paired device gets '
      'in once its idle ones are gone', () async {
    final idle = [
      for (var i = 0; i < 2; i++)
        await Socket.connect('127.0.0.1', listener.boundPort!),
    ];
    for (final s in idle) {
      addTearDown(s.destroy);
    }
    await _until(() => listener.pending == 2);
    final third = await Socket.connect('127.0.0.1', listener.boundPort!);
    addTearDown(third.destroy);
    expect(await _closedWithin(third, const Duration(milliseconds: 300)),
        isTrue);
    expect(listener.turnedAway, 1);
    await _until(() => listener.pending == 0,
        timeout: const Duration(seconds: 3));
    await pairedDial();
    await _until(() => peers.length == 1);
  }, skip: _opensslMissing);

  test('a wrong token, or none, is dropped and handed nothing', () async {
    final s = SocketService();
    await s.connectSecure('127.0.0.1', listener.boundPort!,
        trustCertificate: (_) => true);
    addTearDown(s.disconnect);
    s.send(Packet(
        type: PacketType.control,
        timestampUs: 0,
        payload: Uint8List.fromList(
            [WifiPairingService.authCommand, ...List.filled(32, 0)])));
    await _until(() => listener.pending == 0);
    expect(peers, isEmpty);
  }, skip: _opensslMissing);

  test('the identity tail: encoded, parsed, cut to 64 bytes between '
      'characters, absent from a plain HELLO', () {
    final id = Uint8List.fromList(List.generate(16, (i) => i));
    final hello = ClientHello.payload(
        platform: ClientPlatform.android,
        width: 2000,
        height: 1200,
        maxRefreshHz: 60,
        installId: id,
        name: 'ก' * 40);
    final tail = HelloTail.parse(hello)!;
    expect(tail.installId, id);
    expect(tail.idHex, '000102030405060708090a0b0c0d0e0f');
    expect(tail.name, 'ก' * 21, reason: 'three bytes each, at most 64');
    expect(HelloTail.parse(ClientHello.payload(
            platform: ClientPlatform.android,
            width: 2000,
            height: 1200,
            maxRefreshHz: 60)),
        isNull);
  });
}
