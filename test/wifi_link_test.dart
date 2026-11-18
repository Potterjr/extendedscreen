import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/client/video_decoder_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/client_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/platform/host_name.dart';
import 'package:extendedscreen/shared/platform/wifi_pairing_channel.dart';
import 'package:extendedscreen/shared/protocol/annexb.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Keeps test output free of the pretty-printed connection log.
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

/// Stands in for ScreenCaptureKit: the test pushes "encoded frames" itself.
class _FakeCapture extends ScreenCaptureChannel {
  final frames = StreamController<Uint8List>.broadcast();
  bool started = false;
  int idrRequests = 0;

  @override
  Stream<Uint8List> framesFor(int session) => frames.stream;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<bool> createVirtualDisplay(DisplayConfigModel config,
          {required int session,
          int serialNum = 1,
          String name = 'Extended Screen'}) async =>
      true;
  @override
  Future<void> startCapture(DisplayConfigModel config,
          {required int session}) async =>
      started = true;
  /// How long the native side takes to stop, when a test needs a teardown
  /// that is still running while something else happens.
  Duration stopDelay = Duration.zero;

  @override
  Future<void> stopCapture({required int session}) async {
    if (stopDelay > Duration.zero) await Future<void>.delayed(stopDelay);
    started = false;
  }

  @override
  Future<void> removeVirtualDisplay({required int session}) async {}
  @override
  Future<void> requestIdr({required int session}) async => idrRequests++;
  @override
  Future<Map<String, double>> getDisplayBounds({required int session}) async =>
      {'x': 0, 'y': 0, 'w': 1480, 'h': 924};

  /// Every rate the host asked the encoder for, in order.
  final bitrates = <int>[];
  @override
  Future<void> setBitrate(int bitsPerSecond, {required int session}) async =>
      bitrates.add(bitsPerSecond);
}

/// Counts what would have become CGEvents.
class _FakeInput extends InputInjectChannel {
  int injected = 0;

  @override
  Future<bool> requestAccessibility() async => true;
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  /// How long letting go of a held button takes: the first thing a teardown
  /// waits for, with the server still accepting and the encoder still
  /// running.
  Duration releaseDelay = Duration.zero;

  @override
  Future<void> releaseAll({required int session}) async {
    if (releaseDelay > Duration.zero) await Future<void>.delayed(releaseDelay);
  }

  @override
  Future<void> injectMouse(MouseEventModel e, Map<String, double> displayBounds,
      {required int session}) async {
    injected++;
  }
}

/// A Wi-Fi session must never reach for adb. [devices] is what a USB attempt
/// would find attached, and with [tunnel] its `adb reverse` succeeds.
class _NoAdb extends AdbService {
  int calls = 0;
  List<DeviceModel> devices = const [];
  final forwardedTo = <String>[];
  bool tunnel = false;

  /// The pairings handed to adb, with the device each was for.
  final delivered = <({String serial, Uint8List payload})>[];

  /// The USB session keys handed to adb, in order (one key can be handed
  /// over more than once).
  final sessionKeys = <({String serial, Uint8List key})>[];

  /// What `am broadcast` reaches on the tablet. Null: no receiver there.
  Future<Object?> Function(Object? payload, {String method})? tablet;

  /// False: the tablet's app is not open, or is a build from before USB
  /// session keys, so a key is taken by nobody.
  bool appOpen = true;

  /// False: pairings are taken by nobody (session keys still are).
  bool pairings = true;

  @override
  Future<AdbDelivery> deliverWifiPairing({
    required String serial,
    required Uint8List payload,
  }) async {
    calls++;
    delivered.add((serial: serial, payload: payload));
    final receiver = tablet;
    if (receiver == null || !pairings) return AdbDelivery.notDelivered;
    return await receiver(payload, method: 'pair') == true
        ? AdbDelivery.stored
        : AdbDelivery.refused;
  }

  @override
  Future<AdbDelivery> deliverUsbSessionKey({
    required String serial,
    required Uint8List key,
  }) async {
    calls++;
    sessionKeys.add((serial: serial, key: key));
    final receiver = tablet;
    if (receiver == null || !appOpen) return AdbDelivery.notDelivered;
    final taken = await receiver(UsbSessionService.buildDelivery(key),
        method: 'usbSession');
    return taken == true ? AdbDelivery.stored : AdbDelivery.refused;
  }

  @override
  Future<List<DeviceModel>> listDevices() async {
    calls++;
    return devices;
  }

  @override
  Future<bool> reverseForward({
    required String serial,
    required int localPort,
    required int remotePort,
  }) async {
    calls++;
    forwardedTo.add(serial);
    return tunnel;
  }

  @override
  Future<void> removeForward({required String serial, int? remotePort}) async =>
      calls++;
}

/// The Mac's decoder for the tablet's picture (reverse remote), with nothing
/// behind it.
class _FakeRemote extends RemoteVideoChannel {
  @override
  Future<int?> initialize({
    required int session,
    required CodecType codec,
    required int width,
    required int height,
  }) async =>
      7;
  @override
  Future<void> feedNal(int session, List<int> nalBytes) async {}
  @override
  Future<void> dispose({required int session}) async {}
}

/// The tablet's screen capture, slow to stop: a client teardown that takes
/// [delay], as its platform calls can on a device.
class _SlowStop extends AndroidCaptureChannel {
  _SlowStop(this.delay);
  final Duration delay;

  @override
  Future<void> stopCapture() => Future<void>.delayed(delay);
}

/// No UDP at all: the Mac does not answer and the tablet's probe comes back
/// empty at once, as on a network that drops it.
class _NoDiscovery extends WifiDiscoveryService {
  int probes = 0;

  /// How long starting the responder takes (it reads the Computer Name from
  /// a process first), with the TLS server already accepting.
  Duration responderDelay = Duration.zero;

  @override
  Future<void> startResponder({
    required Uint8List hostId,
    required String name,
    required int tcpPort,
  }) async {
    if (responderDelay > Duration.zero) {
      await Future<void>.delayed(responderDelay);
    }
  }

  @override
  void stopResponder() {}

  @override
  Future<List<DiscoveredHost>> probe({
    Duration timeout = const Duration(seconds: 1),
    bool Function(DiscoveredHost host)? until,
    List<InternetAddress> directTargets = const [],
  }) async {
    probes++;
    return const [];
  }
}

Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<int> _freeUdpPort() async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  s.close();
  return port;
}

/// Whether a datagram this machine sends to its own [address] comes back to
/// it. Not every listed address does that: a VPN tunnel's is listed like any
/// other, and what is sent to it goes into the tunnel and is not seen again.
Future<bool> _udpReachesItself(InternetAddress address) async {
  final listener = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final arrived = Completer<bool>();
  void settle(bool value) {
    if (!arrived.isCompleted) arrived.complete(value);
  }

  final heard = listener.listen((event) {
    if (event == RawSocketEvent.read && listener.receive() != null) {
      settle(true);
    }
  }, onError: (_) => settle(false));
  // A datagram that can't be sent is an error on the sender's stream.
  final sent = sender.listen((_) {}, onError: (_) => settle(false));
  try {
    sender.send(const [1], address, listener.port);
    return await arrived.future.timeout(const Duration(milliseconds: 300),
        onTimeout: () => false);
  } catch (_) {
    return false;
  } finally {
    await heard.cancel();
    await sent.cancel();
    listener.close();
    sender.close();
  }
}

Packet _control(List<int> payload) => Packet(
      type: PacketType.control,
      timestampUs: 0,
      payload: Uint8List.fromList(payload),
    );

/// Calls the tablet's pairing channel the way `WifiPairingReceiver.kt` does
/// when adb delivers a broadcast (`pair`: a Wi-Fi pairing, `usbSession`: a
/// USB session key), and returns Dart's reply.
Future<Object?> _fromAdb(Object? payload, {String method = 'pair'}) async {
  const codec = StandardMethodCodec();
  final reply = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'extended_screen/wifi_pairing',
    codec.encodeMethodCall(MethodCall(method, payload)),
    reply.complete,
  );
  final data = await reply.future;
  return data == null ? null : codec.decodeEnvelope(data);
}

/// An identity that is not the test Mac's: its own id, token and certificate.
WifiIdentity _otherIdentity(int seed) => WifiIdentity(
      hostId: Uint8List(WifiIdentity.hostIdLength)..fillRange(0, 16, seed),
      token: Uint8List(WifiIdentity.tokenLength)..fillRange(0, 32, seed),
      certPem: '-----BEGIN CERTIFICATE-----\n'
          '${['AAEC', 'AwQF', 'BgcI'][seed % 3]}\n'
          '-----END CERTIFICATE-----',
      keyPem: '',
    );

// The TLS tests need a real certificate, which the app gets from macOS's
// openssl; elsewhere they are skipped rather than faked.
final _opensslMissing =
    Platform.isMacOS && File('/usr/bin/openssl').existsSync()
        ? null
        : 'needs /usr/bin/openssl (macOS)';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  // An address of this machine other than loopback, standing in for "the
  // Mac's address on the network" (pairing never stores loopback). Looked up
  // here because `skip:` is decided when a test is declared.
  final lanAddresses = await WifiDiscoveryService.lanAddresses();
  final lan = lanAddresses.isEmpty ? null : lanAddresses.first;
  final noLan = lan == null ? 'needs a network address' : null;

  // One real key pair for the whole file: RSA generation is the slow part.
  ({String certPem, String keyPem})? pair;

  setUpAll(() async {
    if (_opensslMissing != null) return;
    SharedPreferences.setMockInitialValues({});
    pair = (await WifiPairingService().ensureIdentity()).let((id) =>
        (certPem: id.certPem, keyPem: id.keyPem));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
  });

  tearDown(Get.reset);

  WifiPairingService pairingService() =>
      WifiPairingService(generateCert: () async => pair!);

  group('keyframe detection', () {
    Uint8List au(List<int> nalHeaders) => Uint8List.fromList([
          for (final h in nalHeaders) ...[0, 0, 0, 1, h, 0xAA, 0xBB],
        ]);

    test('H.264: parameter sets or an IDR slice start a decoder', () {
      expect(isKeyframeAccessUnit(au([0x67, 0x68, 0x65]), hevc: false), isTrue);
      expect(isKeyframeAccessUnit(au([0x65]), hevc: false), isTrue);
      expect(isKeyframeAccessUnit(au([0x41]), hevc: false), isFalse);
      // SEI in front of a non-IDR slice is still not a keyframe.
      expect(isKeyframeAccessUnit(au([0x06, 0x41]), hevc: false), isFalse);
    });

    test('HEVC: VPS/SPS/PPS or an IRAP slice start a decoder', () {
      // NAL type sits in bits 1..6 of the first header byte.
      int h(int type) => type << 1;
      expect(isKeyframeAccessUnit(au([h(32), h(33), h(34), h(19)]), hevc: true),
          isTrue);
      expect(isKeyframeAccessUnit(au([h(19)]), hevc: true), isTrue);
      expect(isKeyframeAccessUnit(au([h(1)]), hevc: true), isFalse);
      expect(isKeyframeAccessUnit(au([h(39), h(1)]), hevc: true), isFalse);
    });

    test('garbage is not a keyframe', () {
      expect(isKeyframeAccessUnit(Uint8List(0), hevc: false), isFalse);
      expect(isKeyframeAccessUnit(Uint8List.fromList([1, 2, 3, 4, 5]), hevc: true),
          isFalse);
    });
  });

  group('discovery', () {
    test('a reply round-trips, and anything else is ignored', () {
      final id = Uint8List.fromList(List.generate(16, (i) => i));
      final reply = WifiDiscoveryService.encodeReply(
          hostId: id, name: 'Studio Mac', tcpPort: 7001);
      final host = WifiDiscoveryService.decodeReply(
          reply, InternetAddress.loopbackIPv4);
      expect(host, isNotNull);
      expect(host!.name, 'Studio Mac');
      expect(host.tcpPort, 7001);
      expect(host.hostId, id);

      expect(
          WifiDiscoveryService.decodeReply(
              reply.sublist(0, reply.length - 3), InternetAddress.loopbackIPv4),
          isNull);
      expect(
          WifiDiscoveryService.decodeReply(
              Uint8List.fromList('EXTD?x'.codeUnits),
              InternetAddress.loopbackIPv4),
          isNull);
    });

    test('a probe sent straight to the Mac\'s address finds it', () async {
      // Port 0: the system picks one, read back through responderPort.
      final mac = WifiDiscoveryService(udpPort: 0, broadcast: false);
      final id = Uint8List.fromList(List.filled(16, 7));
      await mac.startResponder(hostId: id, name: 'Mac', tcpPort: 4242);
      addTearDown(mac.stopResponder);

      final tablet =
          WifiDiscoveryService(udpPort: mac.responderPort!, broadcast: false);
      final found = await tablet.probe(
        directTargets: [InternetAddress.loopbackIPv4],
        until: (_) => true,
        timeout: const Duration(seconds: 5),
      );
      expect(found, hasLength(1));
      expect(found.single.name, 'Mac');
      expect(found.single.tcpPort, 4242);
      expect(found.single.hostId, id);
      expect(found.single.address, InternetAddress.loopbackIPv4);
    });

    test('a probe with nobody listening comes back empty', () async {
      final found = await WifiDiscoveryService(
              udpPort: await _freeUdpPort(), broadcast: false)
          .probe(
        directTargets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 200),
      );
      expect(found, isEmpty);
    });

    test('a Mac that answers on several of the probed addresses at once does '
        'not freeze the probe', () async {
      // On an ordinary network the Mac hears the broadcast, the subnet
      // broadcast and the probe sent to its own address, and answers each:
      // several of the tablet's sockets get a reply at the same moment.
      // Only the addresses a datagram from this machine comes back on: with
      // a VPN up, the tunnel's address is in the list and answers nothing.
      final lan = [
        for (final a in await WifiDiscoveryService.lanAddresses())
          if (await _udpReachesItself(a)) a,
      ];
      final targets = [InternetAddress.loopbackIPv4, ...lan];
      final mac = WifiDiscoveryService(udpPort: 0, broadcast: false);
      await mac.startResponder(
          hostId: Uint8List(16), name: 'Mac', tcpPort: 4242);
      addTearDown(mac.stopResponder);
      final tablet =
          WifiDiscoveryService(udpPort: mac.responderPort!, broadcast: false);

      // Decided by the first answer, with the others still arriving.
      for (var round = 0; round < 5; round++) {
        final found = await tablet.probe(
          directTargets: targets,
          until: (_) => true,
          timeout: const Duration(seconds: 5),
        );
        expect(found, isNotEmpty);
      }
      // And when it runs to its timeout with every answer in.
      final all = await tablet.probe(
        directTargets: targets,
        timeout: const Duration(milliseconds: 300),
      );
      expect(all.length, targets.length,
          reason: 'one answer per address the Mac was asked on');
      // The isolate is still alive: a timer fires.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }, skip: Platform.isMacOS || Platform.isLinux ? null : 'needs loopback UDP');

    test('a target that can\'t be reached does not cost the answer from one '
        'that can', () async {
      final mac = WifiDiscoveryService(udpPort: 0, broadcast: false);
      await mac.startResponder(
          hostId: Uint8List(16), name: 'Mac', tcpPort: 4242);
      addTearDown(mac.stopResponder);

      final found = await WifiDiscoveryService(
              udpPort: mac.responderPort!, broadcast: false)
          .probe(
        directTargets: [
          // Reserved space with no route on any normal machine: where the
          // send fails, the socket it was made on is closed by dart:io.
          InternetAddress('240.0.0.1'),
          InternetAddress.loopbackIPv4,
        ],
        until: (_) => true,
        timeout: const Duration(seconds: 5),
      );
      expect(found.map((h) => h.name), ['Mac']);
    });

    test('the Mac goes on answering after one of its replies could not be '
        'sent', () async {
      final mac = WifiDiscoveryService(udpPort: 0, broadcast: false);
      await mac.startResponder(
          hostId: Uint8List(16), name: 'Mac', tcpPort: 4242);
      addTearDown(mac.stopResponder);
      final port = mac.responderPort!;
      final tablet = WifiDiscoveryService(udpPort: port, broadcast: false);

      for (var round = 0; round < 3; round++) {
        final found = await tablet.probe(
          directTargets: [InternetAddress.loopbackIPv4],
          until: (_) => true,
          timeout: const Duration(seconds: 5),
        );
        expect(found, hasLength(1), reason: 'round $round');
      }
    });

    test('a flood of replies ends the probe instead of occupying it',
        () async {
      // Something on the network that answers one probe with thousands of
      // replies, each claiming to be a different Mac.
      final flooder =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(flooder.close);
      flooder.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = flooder.receive();
        if (dg == null) return;
        for (var i = 0; i < 4000; i++) {
          final id = Uint8List(16)
            ..buffer.asByteData().setUint32(0, i);
          flooder.send(
              WifiDiscoveryService.encodeReply(
                  hostId: id, name: 'x', tcpPort: 1),
              dg.address,
              dg.port);
        }
      });

      // Asked on every address this machine has, so every one of the
      // probe's sockets is flooded, not just the first.
      final lan = await WifiDiscoveryService.lanAddresses();
      final watch = Stopwatch()..start();
      final found = await WifiDiscoveryService(
              udpPort: flooder.port, broadcast: false)
          .probe(
        directTargets: [InternetAddress.loopbackIPv4, ...lan],
        timeout: const Duration(seconds: 10),
      );
      expect(found.length, lessThanOrEqualTo(64));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'it stops reading instead of waiting out the flood');
    });

    test('the Mac keeps its replies to a trickle however fast it is asked',
        () async {
      final mac = WifiDiscoveryService(udpPort: 0, broadcast: false);
      await mac.startResponder(
          hostId: Uint8List(16), name: 'Mac', tcpPort: 4242);
      addTearDown(mac.stopResponder);

      final asker =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(asker.close);
      var replies = 0;
      asker.listen((event) {
        if (event != RawSocketEvent.read) return;
        while (asker.receive() != null) {
          replies++;
        }
      });
      final probe = Uint8List.fromList([...'EXTD?'.codeUnits, 1]);
      for (var i = 0; i < 2000; i++) {
        asker.send(probe, InternetAddress.loopbackIPv4, mac.responderPort!);
        if (i % 200 == 0) await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(replies, greaterThan(0));
      expect(replies, lessThanOrEqualTo(40),
          reason: '20 a second, over less than two seconds');

      // It still answers an ordinary probe afterwards.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final found = await WifiDiscoveryService(
              udpPort: mac.responderPort!, broadcast: false)
          .probe(
        directTargets: [InternetAddress.loopbackIPv4],
        until: (_) => true,
        timeout: const Duration(seconds: 5),
      );
      expect(found, hasLength(1));
    });

    test('with broadcasting off and no address to ask, nothing is sent',
        () async {
      final found = await WifiDiscoveryService(udpPort: 9, broadcast: false)
          .probe(timeout: const Duration(milliseconds: 50));
      expect(found, isEmpty);
    });
  });

  test('a pong echoes the ping and nothing a peer appended to it', () {
    final ping = PacketCodec.heartbeat();
    final padded = Uint8List.fromList([...ping.payload, ...List.filled(500, 9)]);
    final pong = PacketCodec.heartbeatPong(padded)!;
    expect(pong.payload, hasLength(9));
    expect(PacketCodec.heartbeatIsPong(pong.payload), isTrue);
    expect(PacketCodec.heartbeatOriginTs(pong.payload),
        PacketCodec.heartbeatOriginTs(ping.payload));
  });

  group('pairing', () {
    test('a pairing payload carries the identity to the tablet', () async {
      final mac = pairingService();
      final identity = await mac.ensureIdentity();
      final payload = WifiPairingService.buildPairingPayload(identity, 'Mac');

      final tablet = pairingService();
      expect(await tablet.storePairing(payload), isTrue);
      final host = tablet.pairedHosts.single;
      expect(host.name, 'Mac');
      expect(host.id, hexOf(identity.hostId));
      expect(identity.tokenMatches(host.token), isTrue);
      expect(tablet.hostForCert(identity.certDer), isNotNull);
      expect(tablet.hostForId(identity.hostId), isNotNull);

      // Saved: a fresh service (an app restart) still knows the Mac.
      final restarted = pairingService();
      await restarted.ready;
      expect(restarted.pairedHosts.single.name, 'Mac');
    }, skip: _opensslMissing);

    test('the Mac\'s addresses travel with the pairing', () async {
      final identity = await pairingService().ensureIdentity();
      final payload = WifiPairingService.buildPairingPayload(
        identity,
        'Mac',
        addresses: [
          InternetAddress('192.168.1.157'),
          InternetAddress('10.210.202.5'),
          InternetAddress('fe80::1'), // not IPv4: left out
        ],
      );
      final tablet = pairingService();
      expect(await tablet.storePairing(payload), isTrue);
      expect(tablet.pairedHosts.single.addresses,
          ['192.168.1.157', '10.210.202.5']);

      // Kept across a restart, and next to where the Mac last answered.
      await tablet.rememberAddress(tablet.pairedHosts.single, '192.168.1.200');
      final restarted = pairingService();
      await restarted.ready;
      expect(restarted.pairedHosts.single.addresses,
          ['192.168.1.157', '10.210.202.5']);
      expect(restarted.pairedHosts.single.lastAddress, '192.168.1.200');

      // Pairing again brings the Mac's new addresses and keeps the last one.
      final moved = WifiPairingService.buildPairingPayload(identity, 'Mac',
          addresses: [InternetAddress('192.168.1.99')]);
      expect(await restarted.storePairing(moved), isTrue);
      expect(restarted.pairedHosts.single.addresses, ['192.168.1.99']);
      expect(restarted.pairedHosts.single.lastAddress, '192.168.1.200');
    }, skip: _opensslMissing);

    test('a packet naming a Mac already paired but carrying another '
        'certificate or token is refused; the same Mac may refresh itself',
        () async {
      final identity = await pairingService().ensureIdentity();
      final tablet = pairingService();
      expect(
          await tablet.storePairing(WifiPairingService.buildPairingPayload(
              identity, 'Mac',
              addresses: [InternetAddress('192.168.1.10')])),
          isTrue);

      // Same (public) host id, someone else's certificate.
      final forgedCert = WifiPairingService.buildPairingPayload(identity, 'Mac')
        ..[60] ^= 0xFF;
      // ...or the right certificate with another token.
      final forgedToken =
          WifiPairingService.buildPairingPayload(identity, 'Mac')
            ..[2 + WifiIdentity.hostIdLength] ^= 0xFF;
      expect(
          WifiPairingService.parsePairingPayload(forgedCert), isNotNull,
          reason: 'well-formed, so it is the comparison that refuses it');
      expect(await tablet.storePairing(forgedCert), isFalse);
      expect(await tablet.storePairing(forgedToken), isFalse);
      expect(tablet.hostForCert(identity.certDer), isNotNull);
      expect(identity.tokenMatches(tablet.pairedHosts.single.token), isTrue);

      // The real Mac, renamed and on another address: accepted.
      expect(
          await tablet.storePairing(WifiPairingService.buildPairingPayload(
              identity, 'Studio',
              addresses: [InternetAddress('192.168.1.11')])),
          isTrue);
      expect(tablet.pairedHosts.single.name, 'Studio');
      expect(tablet.pairedHosts.single.addresses, ['192.168.1.11']);
    }, skip: _opensslMissing);

    test('addresses a Mac can\'t have on a network are left out', () async {
      final identity = await pairingService().ensureIdentity();
      final payload = WifiPairingService.buildPairingPayload(
        identity,
        'Mac',
        addresses: [
          InternetAddress('127.0.0.1'),
          InternetAddress('0.0.0.0'),
          InternetAddress('224.0.0.251'),
          InternetAddress('255.255.255.255'),
          InternetAddress('192.168.1.157'),
        ],
      );
      expect(WifiPairingService.parsePairingPayload(payload)!.addresses,
          ['192.168.1.157']);
    }, skip: _opensslMissing);

    test('a pairing packet without the address list, or with a cut-off one, '
        'still pairs', () async {
      final identity = await pairingService().ensureIdentity();
      final full = WifiPairingService.buildPairingPayload(identity, 'Mac',
          addresses: [InternetAddress('192.168.1.157'), InternetAddress('10.0.0.2')]);
      // 1 count byte + 2 × 4 address bytes at the end.
      final noList = full.sublist(0, full.length - 9);
      final cutOff = full.sublist(0, full.length - 2);
      final lying = Uint8List.fromList(full)..[full.length - 9] = 200;

      expect(WifiPairingService.parsePairingPayload(noList)!.addresses, isEmpty);
      expect(WifiPairingService.parsePairingPayload(cutOff)!.addresses,
          ['192.168.1.157']);
      expect(WifiPairingService.parsePairingPayload(lying)!.addresses,
          ['192.168.1.157', '10.0.0.2']);
    }, skip: _opensslMissing);

    test('the identity is created once and reused', () async {
      var generated = 0;
      CertGenerator counting() => () async {
            generated++;
            return pair!;
          };
      final first = await WifiPairingService(generateCert: counting())
          .ensureIdentity();
      final second = await WifiPairingService(generateCert: counting())
          .ensureIdentity();
      expect(generated, 1);
      expect(second.token, first.token);
      expect(second.hostId, first.hostId);
    }, skip: _opensslMissing);

    test('a failed generation is retried on the next call', () async {
      var attempts = 0;
      final service = WifiPairingService(generateCert: () async {
        if (attempts++ == 0) throw const ProcessException('openssl', []);
        return pair!;
      });
      await expectLater(service.ensureIdentity(), throwsA(anything));
      expect((await service.ensureIdentity()).certPem, pair!.certPem);
    }, skip: _opensslMissing);

    test('a truncated or foreign pairing packet is rejected', () async {
      final identity = await pairingService().ensureIdentity();
      final payload = WifiPairingService.buildPairingPayload(identity, 'Mac');
      final tablet = pairingService();
      expect(await tablet.storePairing(payload.sublist(0, 40)), isFalse);
      expect(
          await tablet
              .storePairing(payload.sublist(0, payload.length - 10)),
          isFalse);
      final newer = Uint8List.fromList(payload)..[1] = 99;
      expect(await tablet.storePairing(newer), isFalse);
      expect(tablet.pairedHosts, isEmpty);
    }, skip: _opensslMissing);

    test('a forgotten Mac is gone, also after a restart, and the others '
        'stay', () async {
      final identity = await pairingService().ensureIdentity();
      final studio = WifiPairingService.buildPairingPayload(identity, 'Studio');
      final other = _otherIdentity(7);
      final tablet = pairingService();
      expect(await tablet.storePairing(studio), isTrue);
      expect(
          await tablet.storePairing(
              WifiPairingService.buildPairingPayload(other, 'Laptop')),
          isTrue);
      expect(tablet.pairedHosts.map((h) => h.name), ['Laptop', 'Studio']);

      expect(await tablet.forget(hexOf(identity.hostId)), isTrue);
      expect(tablet.pairedHosts.map((h) => h.name), ['Laptop']);
      // Neither found by a discovery reply nor accepted in a TLS handshake.
      expect(tablet.hostForId(identity.hostId), isNull);
      expect(tablet.hostForCert(identity.certDer), isNull);
      expect(tablet.hostForCert(other.certDer), isNotNull);
      expect(await tablet.forget(hexOf(identity.hostId)), isFalse,
          reason: 'nothing left to forget');

      final restarted = pairingService();
      await restarted.ready;
      expect(restarted.pairedHosts.map((h) => h.name), ['Laptop']);

      // Pairing again (a USB session) brings it back.
      expect(await restarted.storePairing(studio), isTrue);
      expect(restarted.hostForCert(identity.certDer), isNotNull);
    }, skip: _opensslMissing);

    test('resetting the identity makes a new one, which is the one a restart '
        'finds', () async {
      final mac = pairingService();
      final old = await mac.ensureIdentity();
      await mac.resetIdentity();

      final fresh = await mac.ensureIdentity();
      expect(fresh.hostId, isNot(old.hostId));
      expect(fresh.tokenMatches(old.token), isFalse,
          reason: 'a tablet paired before the reset no longer gets in');

      final restarted = await pairingService().ensureIdentity();
      expect(restarted.hostId, fresh.hostId);
      expect(restarted.token, fresh.token);
    }, skip: _opensslMissing);

    test('a reset while the identity is still being created does not let '
        'that one come back', () async {
      final gate = Completer<void>();
      final mac = WifiPairingService(generateCert: () async {
        await gate.future;
        return pair!;
      });
      final creating = mac.ensureIdentity();
      final reset = mac.resetIdentity();
      // Asked for before the reset has removed anything: must wait for it.
      final after = mac.ensureIdentity();
      gate.complete();

      final first = await creating;
      await reset;
      final second = await after;
      expect(second.hostId, isNot(first.hostId));
      expect((await pairingService().ensureIdentity()).hostId, second.hostId);
    }, skip: _opensslMissing);

    test('a reset with no identity yet is harmless', () async {
      final mac = pairingService();
      await mac.resetIdentity();
      final identity = await mac.ensureIdentity();
      expect((await pairingService().ensureIdentity()).hostId, identity.hostId);
    }, skip: _opensslMissing);

    test('a pairing that adb delivers is stored, and the reply says so',
        () async {
      final identity = await pairingService().ensureIdentity();
      final tablet = Get.put<WifiPairingService>(pairingService());
      Get.put(WifiPairingChannel());

      final payload = WifiPairingService.buildPairingPayload(identity, 'Mac');
      expect(await _fromAdb(payload), isTrue);
      expect(tablet.pairedHosts.single.name, 'Mac');
      expect(tablet.hostForCert(identity.certDer), isNotNull);

      // What the Mac is told when the tablet will not take it: the id of a
      // Mac it knows with another token, something cut short, or no bytes.
      final forged = Uint8List.fromList(payload)
        ..[2 + WifiIdentity.hostIdLength] ^= 0xFF;
      expect(await _fromAdb(forged), isFalse);
      expect(await _fromAdb(payload.sublist(0, 40)), isFalse);
      expect(await _fromAdb('not bytes'), isFalse);
      expect(tablet.pairedHosts.single.name, 'Mac');
      expect(identity.tokenMatches(tablet.pairedHosts.single.token), isTrue);
    }, skip: _opensslMissing);

    test('the result of the pairing broadcast is read from adb\'s output', () {
      // As printed by a tablet on Android 16 with no receiver installed.
      const none = 'Broadcasting: Intent { '
          'act=com.example.extendedscreen.WIFI_PAIR flg=0x400000 '
          'cmp=com.example.extendedscreen/.plugins.WifiPairingReceiver '
          '(has extras) }\nBroadcast completed: result=0\n';
      AdbDelivery of(String output) =>
          AdbDelivery.fromResultCode(AdbService.broadcastResultCode(output));
      expect(of(none), AdbDelivery.notDelivered);
      expect(of(none.replaceFirst('result=0', 'result=1')), AdbDelivery.stored);
      expect(
          of(none.replaceFirst('result=0', 'result=2')), AdbDelivery.refused);
      // adb said something else entirely (no device, a shell error).
      expect(of("adb: device 'TABLET' not found"), AdbDelivery.notDelivered);
      expect(of(''), AdbDelivery.notDelivered);
    });

    test('only the exact token matches', () async {
      final identity = await pairingService().ensureIdentity();
      final wrong = Uint8List.fromList(identity.token)..[5] ^= 1;
      expect(identity.tokenMatches(identity.token), isTrue);
      expect(identity.tokenMatches(wrong), isFalse);
      expect(identity.tokenMatches(identity.token.sublist(1)), isFalse);
      expect(identity.tokenMatches(const []), isFalse);
    }, skip: _opensslMissing);
  });

  group('TLS socket', () {
    late WifiIdentity identity;
    late SocketService server;

    setUp(() async {
      if (_opensslMissing != null) return;
      identity = await pairingService().ensureIdentity();
      server = SocketService();
      await server.startSecureServer(0, identity.serverContext());
      addTearDown(server.disconnect);
    });

    test('a client that pins the certificate exchanges packets', () async {
      final client = SocketService();
      addTearDown(client.disconnect);
      await client.connectSecure(
        '127.0.0.1',
        server.serverPort!,
        trustCertificate: (der) => _same(der, identity.certDer),
      );
      await server.waitForClient();
      expect(_same(client.peerCertificateDer!, identity.certDer), isTrue);

      final atServer = server.packetStream.first;
      client.send(_control([1, 2, 3]));
      expect((await atServer.timeout(const Duration(seconds: 5))).payload,
          [1, 2, 3]);

      final atClient = client.packetStream.first;
      server.send(_control([9, 8]));
      expect((await atClient.timeout(const Duration(seconds: 5))).payload,
          [9, 8]);
    }, skip: _opensslMissing);

    test('a client that does not trust the certificate never connects, '
        'and the server keeps listening', () async {
      final errors = <Object>[];
      final sub = server.packetStream.listen((_) {}, onError: errors.add);
      addTearDown(sub.cancel);

      final stranger = SocketService();
      await expectLater(
        stranger.connectSecure('127.0.0.1', server.serverPort!,
            trustCertificate: (_) => false),
        throwsA(isA<TlsException>()),
      );
      // Give the server's side of the failed handshake time to surface.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.isConnected, isFalse);
      expect(errors, isEmpty,
          reason: 'a failed handshake must not look like a lost link');

      final client = SocketService();
      addTearDown(client.disconnect);
      await client.connectSecure('127.0.0.1', server.serverPort!,
          trustCertificate: (_) => true);
      await server.waitForClient().timeout(const Duration(seconds: 5));
      expect(server.isConnected, isTrue);
    }, skip: _opensslMissing);

    test('a dial cancelled while it is still handshaking never becomes the '
        'connection', () async {
      final client = SocketService();
      addTearDown(client.disconnect);
      final dial = client.connectSecure('127.0.0.1', server.serverPort!,
          trustCertificate: (_) => true);
      // The user changed their mind (or the link was switched) meanwhile.
      await client.disconnect();
      await expectLater(dial, throwsA(isA<SocketException>()));
      expect(client.isConnected, isFalse);

      // And the service is not left broken: the next dial works.
      await client.connectSecure('127.0.0.1', server.serverPort!,
          trustCertificate: (_) => true);
      expect(client.isConnected, isTrue);
    }, skip: _opensslMissing);

    test('a peer that accepts the connection but never answers the TLS '
        'handshake makes the dial fail instead of hanging', () async {
      // Plain TCP: takes the connection, says nothing.
      final mute = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      mute.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await mute.close();
      });

      final client =
          SocketService(tlsDialTimeout: const Duration(milliseconds: 300));
      addTearDown(client.disconnect);
      final watch = Stopwatch()..start();
      await expectLater(
        client.connectSecure('127.0.0.1', mute.port,
            trustCertificate: (_) => true),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(client.isConnected, isFalse);
    });

    test('each accepted client is a new connection, and starts out limited '
        'to small packets until it is trusted', () async {
      final small = _control(List.filled(200, 7));
      final big = _control(List.filled(4096, 7));
      final errors = <Object>[];
      final got = <Packet>[];
      final sub = server.packetStream.listen(got.add, onError: errors.add);
      addTearDown(sub.cancel);

      // First client: never trusted. A small packet passes, a big one gets
      // it dropped before the payload is even buffered.
      final first = SocketService();
      await first.connectSecure('127.0.0.1', server.serverPort!,
          trustCertificate: (_) => true);
      await server.waitForClient();
      final firstId = server.connectionId;
      first.send(small);
      await _until(() => got.length == 1);
      first.send(big);
      await _until(() => !server.isConnected);
      expect(errors, hasLength(1));
      expect(got, hasLength(1));
      await first.disconnect();

      // Second client: a different connection, limited again until trusted.
      final second = SocketService();
      addTearDown(second.disconnect);
      await second.connectSecure('127.0.0.1', server.serverPort!,
          trustCertificate: (_) => true);
      await server.waitForClient();
      expect(server.connectionId, isNot(firstId));
      server.trustPeer();
      second.send(big);
      await _until(() => got.length == 2);
      expect(got.last.payload, hasLength(4096));
      expect(server.isConnected, isTrue);
    }, skip: _opensslMissing);

    test('when the peer closes, this side closes its half too', () async {
      final usb = SocketService();
      addTearDown(usb.disconnect);
      await usb.startServer('127.0.0.1', 0);
      final lost = <Object>[];
      final sub = usb.packetStream.listen((_) {}, onError: lost.add);
      addTearDown(sub.cancel);
      final raw = await Socket.connect('127.0.0.1', usb.serverPort!);
      addTearDown(raw.destroy);
      await usb.waitForClient();

      // The peer says goodbye (closes its sending half) and waits to see
      // whether this side hangs up as well.
      var hungUp = false;
      raw.listen((_) {}, onDone: () => hungUp = true);
      await raw.close();
      await _until(() => hungUp, timeout: const Duration(seconds: 5));
      expect(lost, hasLength(1), reason: 'reported once as a lost link');
      expect(usb.isConnected, isFalse);
    });

    test('a header announcing an absurd payload drops the peer on any link',
        () async {
      final usb = SocketService();
      addTearDown(usb.disconnect);
      await usb.startServer('127.0.0.1', 0);
      final errors = <Object>[];
      final sub = usb.packetStream.listen((_) {}, onError: errors.add);
      addTearDown(sub.cancel);
      final raw = await Socket.connect('127.0.0.1', usb.serverPort!);
      addTearDown(raw.destroy);
      await usb.waitForClient();

      final header = ByteData(Packet.headerSize)
        ..setUint32(0, Packet.magic)
        ..setUint8(4, PacketType.frameData.value)
        ..setUint32(5, SocketService.maxPayloadBytes + 1);
      raw.add(header.buffer.asUint8List());
      await raw.flush();
      await _until(() => !usb.isConnected);
      expect(errors, hasLength(1));
    });

    test('frames are refused while the peer is not reading, and accepted '
        'again once it has caught up', () async {
      final raw = await SecureSocket.connect('127.0.0.1', server.serverPort!,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true);
      addTearDown(raw.destroy);
      // A tablet whose link has stalled: connected, but taking nothing.
      final reading = raw.listen((_) {})..pause();
      await server.waitForClient();
      server.limitSendBuffer(64 * 1024);

      final frame = Packet(
        type: PacketType.frameData,
        timestampUs: 0,
        payload: Uint8List(256 * 1024),
      );
      expect(server.isCongested, isFalse);
      var refused = false;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!refused && DateTime.now().isBefore(deadline)) {
        refused = !server.sendFrame(frame);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(refused, isTrue, reason: 'a stalled link must start refusing');
      expect(server.isCongested, isTrue);

      reading.resume();
      await _until(() => !server.isCongested,
          timeout: const Duration(seconds: 20));
      expect(server.sendFrame(frame), isTrue);
    }, skip: _opensslMissing);

    test('what the peer has not taken is counted, and drains to nothing once '
        'it reads', () async {
      final raw = await SecureSocket.connect('127.0.0.1', server.serverPort!,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true);
      addTearDown(raw.destroy);
      final reading = raw.listen((_) {})..pause();
      await server.waitForClient();
      server.limitSendBuffer(64 * 1024);
      expect(server.unackedBytes, 0);
      expect(server.bytesSent, 0);

      // Smaller than the kernel's buffer, so a packet counted both here and
      // in the kernel would show as more than was ever sent.
      final frame = Packet(
        type: PacketType.frameData,
        timestampUs: 0,
        payload: Uint8List(16 * 1024),
      );
      for (var i = 0; i < 128; i++) {
        server.send(frame);
      }
      final total = 128 * (Packet.headerSize + 16 * 1024);
      expect(server.bytesSent, total);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // A stalled reader: most of it is still waiting, here or in the
      // kernel, whatever the loopback's own buffers took.
      expect(server.unackedBytes, greaterThan(total ~/ 4));
      expect(server.unackedBytes, lessThanOrEqualTo(total));
      if (Platform.isMacOS) {
        expect(server.unackedBytes, greaterThan(server.queuedHere),
            reason: 'what the kernel holds is counted too (SO_NWRITE)');
      }

      reading.resume();
      await _until(() => server.unackedBytes == 0,
          timeout: const Duration(seconds: 10));
      expect(server.bytesSent, total);
    }, skip: _opensslMissing);

    test('over USB nothing is paced: frames are never refused', () async {
      final usb = SocketService();
      addTearDown(usb.disconnect);
      await usb.startServer('127.0.0.1', 0);
      final raw = await Socket.connect('127.0.0.1', usb.serverPort!);
      addTearDown(raw.destroy);
      raw.listen((_) {}).pause();
      await usb.waitForClient();

      final frame = Packet(
        type: PacketType.frameData,
        timestampUs: 0,
        payload: Uint8List(64 * 1024),
      );
      for (var i = 0; i < 200; i++) {
        expect(usb.sendFrame(frame), isTrue);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(usb.isCongested, isFalse);
      expect(usb.sendFrame(frame), isTrue);
      expect(usb.unackedBytes, 0, reason: 'nothing is measured either');
      expect(usb.bytesSent, 0);
    });
  });

  group('host and client over Wi-Fi', () {
    late SettingsService settings;
    late WifiPairingService pairing;
    late _FakeCapture capture;
    late _FakeInput input;
    late _NoAdb adb;
    late SocketService hostSocket;
    late SocketService clientSocket;
    late HostConnectionManager host;
    late ClientConnectionManager client;
    late WifiIdentity identity;
    late _NoDiscovery discovery;
    late int port;
    Future<void>? hostConnect;

    setUp(() async {
      if (_opensslMissing != null) return;
      hostConnect = null;
      settings = SettingsService();
      await settings.init();
      Get.put<SettingsService>(settings);
      await settings.setLinkType(LinkType.wifi);
      // The tablet is told where the Mac is, so no UDP is involved.
      await settings.setWifiHostAddress('127.0.0.1');

      pairing = Get.put<WifiPairingService>(pairingService());
      identity = await pairing.ensureIdentity();
      discovery = Get.put<WifiDiscoveryService>(_NoDiscovery()) as _NoDiscovery;
      adb = Get.put<AdbService>(_NoAdb()) as _NoAdb;
      capture = Get.put<ScreenCaptureChannel>(_FakeCapture()) as _FakeCapture;
      input = Get.put<InputInjectChannel>(_FakeInput()) as _FakeInput;
      Get.put(VideoDecoderChannel());
      Get.put(AndroidCaptureChannel());

      port = await _freePort();
      hostSocket = SocketService();
      clientSocket = SocketService();
      host = HostConnectionManager(socket: hostSocket, port: port);
      client = ClientConnectionManager(socket: clientSocket, port: port);
      addTearDown(() async {
        await client.disconnect();
        await host.disconnect();
        // A connect() parked waiting for the tablet wakes up cancelled and
        // undoes its own setup; let that finish before Get is reset.
        await hostConnect;
      });
    });

    Future<void> hostListens() async {
      hostConnect = host.connect();
      await _until(() => hostSocket.serverPort != null);
    }

    test('a paired tablet is let in and the stream reaches it', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();
      expect(host.phase.value, ConnectionPhase.handshaking);

      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming);
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(capture.started, isTrue);
      expect(host.activeDevice.value?.serial, '127.0.0.1');
      expect(adb.calls, 0, reason: 'a Wi-Fi session has no adb tunnel');

      // A frame from the encoder arrives at the tablet.
      final frame = clientSocket.packetStream
          .firstWhere((p) => p.type == PacketType.frameData);
      capture.frames.add(Uint8List.fromList([0, 0, 0, 1, 0x65, 42]));
      expect((await frame.timeout(const Duration(seconds: 5))).payload.last, 42);

      // And a touch from the tablet is injected on the Mac.
      client.sendMouse(const MouseEventModel(
        normalizedX: 0.5,
        normalizedY: 0.5,
        button: MouseButton.left,
        action: MouseAction.down,
        timestampUs: 1,
      ));
      await _until(() => input.injected == 1);

      // The tablet remembers where it found the Mac.
      await _until(() => pairing.pairedHosts.single.lastAddress == '127.0.0.1');
    }, skip: _opensslMissing);

    test('over a link slower than the preset the encoder is brought down to '
        'what it carries, and the picture keeps coming', () async {
      await settings.setEncodePreset(EncodePreset.custom);
      await settings.setCustomBitrateMbps(40);
      await settings.setCustomRefreshRate(60);
      await settings.setCodec(CodecType.h264);
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      // This tablet reaches the Mac over a link that carries 12 Mbps.
      final slow = await _SlowLink.open(port, bytesPerSecond: 1500 * 1000);
      addTearDown(slow.close);
      final tabletSocket = SocketService();
      final tablet =
          ClientConnectionManager(socket: tabletSocket, port: slow.port);
      addTearDown(tablet.disconnect);
      await hostListens();
      await tablet.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(host.streamBitrate.value, 40 * 1000000,
          reason: 'it starts at the preset');

      var frames = 0;
      final sub = tabletSocket.packetStream.listen((p) {
        if (p.type == PacketType.frameData) frames++;
      });
      addTearDown(sub.cancel);
      // Keyframes of a quarter second of stream, as VideoToolbox makes them,
      // so the bursts are part of the test.
      final encoder = _Encoder(capture,
          startBitrate: 40 * 1000000,
          fps: 60,
          keyframe: const Duration(milliseconds: 250))
        ..start();
      addTearDown(encoder.stop);

      await _until(() => host.streamBitrate.value! <= 12 * 1000000,
          timeout: const Duration(seconds: 15));
      expect(capture.bitrates.last, host.streamBitrate.value,
          reason: 'the encoder was told');

      // Settled: the picture keeps coming, no frame is dropped any more, and
      // the rate stays near what the link carries instead of collapsing
      // towards the floor (5 Mbps). It moves within a band around the link:
      // mostly below it (a quarter-second keyframe drains only at what the
      // link has to spare, and the rate keeps that spare large enough for
      // the queue to empty), with now and then a probe a step above it.
      await Future<void>.delayed(const Duration(seconds: 3));
      final settled = <int>[host.streamBitrate.value!];
      final watch = ever(host.streamBitrate, (int? b) {
        if (b != null) settled.add(b);
      });
      addTearDown(watch.dispose);
      final before = frames;
      final idrs = capture.idrRequests;
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(frames - before, greaterThan(225),
          reason: 'at 62.5 fps, 4 s with no frame dropped is 250 frames');
      expect(capture.idrRequests, idrs, reason: 'no frame refused');
      expect(settled, everyElement(greaterThanOrEqualTo(7 * 1000000)));
      expect(settled, everyElement(lessThanOrEqualTo(15 * 1000000)));
    }, skip: _opensslMissing, timeout: const Timeout(Duration(seconds: 60)));

    test('on a link a little faster than the preset, keyframes do not make '
        'the Mac drop frames', () async {
      await settings.setEncodePreset(EncodePreset.custom);
      await settings.setCustomBitrateMbps(20);
      await settings.setCustomRefreshRate(60);
      await settings.setCodec(CodecType.h264);
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      // 22 Mbps for a 20 Mbps stream whose keyframes are a quarter second.
      final link = await _SlowLink.open(port, bytesPerSecond: 2750 * 1000);
      addTearDown(link.close);
      final tablet =
          ClientConnectionManager(socket: SocketService(), port: link.port);
      addTearDown(tablet.disconnect);
      await hostListens();
      await tablet.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);

      final encoder = _Encoder(capture,
          startBitrate: 20 * 1000000,
          fps: 60,
          keyframe: const Duration(milliseconds: 250))
        ..start();
      addTearDown(encoder.stop);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(capture.idrRequests, 0, reason: 'no frame refused');
      expect(host.streamBitrate.value, greaterThanOrEqualTo(14 * 1000000));
    }, skip: _opensslMissing, timeout: const Timeout(Duration(seconds: 60)));

    test('a tablet that connects while the Mac is still starting to listen '
        'is not turned away', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      discovery.responderDelay = const Duration(seconds: 1);
      hostConnect = host.connect();
      await _until(() => hostSocket.serverPort != null);
      // TLS and the token, all before the Mac has got round to waiting.
      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming);
      await _until(() => host.phase.value == ConnectionPhase.streaming,
          timeout: const Duration(seconds: 3));
      expect(host.errorMessage.value, isEmpty);
    }, skip: _opensslMissing);

    test('the bitrate is only adapted while its session lasts', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(host.streamBitrate.value, settings.captureBitrate);

      expect(host.adaptingBitrate, isTrue);

      // Stopped before the teardown's first await: nothing may change the
      // encoder's rate for a session that is ending.
      final stopping = host.disconnect();
      expect(host.adaptingBitrate, isFalse);
      expect(host.streamBitrate.value, isNull);
      await stopping;
      expect(host.adaptingBitrate, isFalse);
    }, skip: _opensslMissing);

    test('with nothing typed, the tablet asks the addresses the Mac reported '
        'when it was paired', () async {
      // Real UDP on loopback, on a port of its own and with no broadcast.
      await Get.delete<WifiDiscoveryService>(force: true);
      final udp = WifiDiscoveryService(
          udpPort: await _freeUdpPort(), broadcast: false);
      Get.put<WifiDiscoveryService>(udp);
      await settings.setWifiHostAddress('');
      await pairing.storePairing(WifiPairingService.buildPairingPayload(
        identity,
        'Mac',
        addresses: [lan!],
      ));
      await hostListens();
      await _until(() => udp.responderPort != null);

      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming);
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(pairing.pairedHosts.single.lastAddress, lan.address);
    }, skip: _opensslMissing ?? noLan);

    test('a typed address that leads nowhere does not hide a Mac that answers '
        'at the address it reported', () async {
      await Get.delete<WifiDiscoveryService>(force: true);
      final udp = WifiDiscoveryService(
          udpPort: await _freeUdpPort(), broadcast: false);
      Get.put<WifiDiscoveryService>(udp);
      // TEST-NET-1: reserved for documentation, never a real host.
      await settings.setWifiHostAddress('192.0.2.1');
      await pairing.storePairing(WifiPairingService.buildPairingPayload(
        identity,
        'Mac',
        addresses: [lan!],
      ));
      await hostListens();
      await _until(() => udp.responderPort != null);

      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming);
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(pairing.pairedHosts.single.lastAddress, lan.address);
    }, skip: _opensslMissing ?? noLan);

    test('when nothing answers the probe, the known addresses are dialled in '
        'turn, so a wrong one typed does not block the rest', () async {
      // No discovery at all (the default fake), a name that leads nowhere
      // typed in, and the Mac's real address known from pairing.
      await settings.setWifiHostAddress('no-such-mac.invalid');
      await pairing.storePairing(WifiPairingService.buildPairingPayload(
        identity,
        'Mac',
        addresses: [lan!],
      ));
      await hostListens();

      await client.connect();
      expect(client.phase.value, ConnectionPhase.error,
          reason: 'first the typed name, which fails');
      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming,
          reason: 'then the address from pairing');
      await _until(() => host.phase.value == ConnectionPhase.streaming);
    }, skip: _opensslMissing ?? noLan);

    test('when no probe is answered, the typed address is dialled anyway',
        () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();
      await client.connect();
      expect(discovery.probes, 1);
      expect(client.phase.value, ConnectionPhase.streaming);
      await _until(() => host.phase.value == ConnectionPhase.streaming);
    }, skip: _opensslMissing);

    test('a tablet with the wrong token is turned away before capture starts',
        () async {
      // Right certificate (so TLS succeeds), wrong token.
      final payload = WifiPairingService.buildPairingPayload(identity, 'Mac');
      payload[2 + WifiIdentity.hostIdLength] ^= 0xFF;
      await pairing.storePairing(payload);
      await hostListens();

      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.error);
      expect(host.errorMessage.value, 'error_wifi_unpaired_client');
      expect(capture.started, isFalse);
      expect(input.injected, 0);
    }, skip: _opensslMissing);

    test('a stranger that skips the token gets no input injected and no '
        'stream, however long it stays', () async {
      await hostListens();
      final raw = await SecureSocket.connect('127.0.0.1', port,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true);
      addTearDown(raw.destroy);
      final received = <int>[];
      raw.listen(received.addAll, onError: (_) {});

      // Straight to a HELLO claiming a panel, and a click.
      raw.add(_control([0x01, 0x02, 0x04, 0x00, 0x03, 0x00, 120]).serialize());
      raw.add(PacketCodec.wrapMouse(const MouseEventModel(
        normalizedX: 0.5,
        normalizedY: 0.5,
        button: MouseButton.left,
        action: MouseAction.down,
        timestampUs: 1,
      )).serialize());
      await raw.flush();

      // The host gives it 3 s to authenticate, then drops it.
      await _until(() => host.phase.value == ConnectionPhase.error);
      expect(host.errorMessage.value, 'error_wifi_unpaired_client');
      expect(input.injected, 0);
      expect(capture.started, isFalse);
      expect(settings.clientPanelWidth.value, 2560,
          reason: 'an unauthenticated HELLO must not resize the stream');
      // Heartbeats aside, it was sent nothing: no mode, codec or video.
      expect(
          _packetTypes(received).where((t) => t != PacketType.heartbeat),
          isEmpty);
    }, skip: _opensslMissing);

    test('a connection that closes without a token does not come back to '
        'tear down the session that follows it', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();

      // Any machine on the network: completes TLS, says nothing, leaves.
      final stranger = await SecureSocket.connect('127.0.0.1', port,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stranger.destroy();

      // The Mac notices, and is listening again a second later.
      await _until(() => host.phase.value == ConnectionPhase.error);
      await _until(() =>
          host.phase.value == ConnectionPhase.handshaking &&
          hostSocket.serverPort != null);

      // The paired tablet connects, well inside the 3 s the first attempt
      // would have waited for the stranger's token.
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(capture.started, isTrue);

      // And is still connected after that wait would have run out.
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      expect(host.phase.value, ConnectionPhase.streaming);
      expect(client.phase.value, ConnectionPhase.streaming);
      expect(capture.started, isTrue);
    }, skip: _opensslMissing);

    test('whoever connects after the tablet drops is sent nothing, while the '
        'encoder keeps producing frames', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);

      // A capture that never stops: a keyframe every few ms, whatever the
      // session is doing.
      final keyframe = Uint8List.fromList([0, 0, 0, 1, 0x65, 1, 2, 3]);
      final encoder = Timer.periodic(const Duration(milliseconds: 2),
          (_) => capture.frames.add(keyframe));
      addTearDown(encoder.cancel);

      // The tablet vanishes, and strangers take every chance to get in:
      // during the teardown, and at each listen that follows.
      await clientSocket.disconnect();
      final received = <int>[];
      final strangers = <SecureSocket>[];
      addTearDown(() {
        for (final s in strangers) {
          s.destroy();
        }
      });
      final until = DateTime.now().add(const Duration(milliseconds: 2500));
      while (DateTime.now().isBefore(until)) {
        try {
          final s = await SecureSocket.connect('127.0.0.1', port,
              context: SecurityContext(withTrustedRoots: false),
              onBadCertificate: (_) => true,
              timeout: const Duration(milliseconds: 300));
          strangers.add(s);
          s.listen(received.addAll, onError: (_) {});
        } catch (_) {
          // Between listens: nothing to connect to.
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(strangers, isNotEmpty, reason: 'at least one got a connection');
      expect(received, isEmpty,
          reason: 'no frame and no control packet for an unpaired peer');
      expect(input.injected, 0);
    }, skip: _opensslMissing);

    test('an unpaired client announcing a large packet is dropped at once, '
        'not after the token timeout', () async {
      await hostListens();
      final raw = await SecureSocket.connect('127.0.0.1', port,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true);
      addTearDown(raw.destroy);
      var closed = false;
      raw.listen((_) {}, onDone: () => closed = true, onError: (_) {});
      final header = ByteData(Packet.headerSize)
        ..setUint32(0, Packet.magic)
        ..setUint8(4, PacketType.frameData.value)
        ..setUint32(5, 8 * 1024 * 1024);
      raw.add(header.buffer.asUint8List());
      await raw.flush();
      await _until(() => closed, timeout: const Duration(milliseconds: 1500));
      await _until(() => host.phase.value == ConnectionPhase.error ||
          host.phase.value == ConnectionPhase.handshaking);
    }, skip: _opensslMissing);

    test('switching to USB after a Wi-Fi session failed picks the last-used '
        'device, not the first one attached', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await settings.setLastDevice('TABLET');
      adb.devices = const [
        DeviceModel(serial: 'PHONE', status: DeviceStatus.connected),
        DeviceModel(serial: 'TABLET', status: DeviceStatus.connected),
      ];
      await hostListens();
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(host.activeDevice.value?.serial, '127.0.0.1');

      // The Wi-Fi link is lost, and before the retry the user picks USB.
      await clientSocket.disconnect();
      await _until(() => host.phase.value == ConnectionPhase.error);
      await settings.setLinkType(LinkType.usb);

      // The retry is a USB attempt: the leftover "device" was an address.
      await _until(() => adb.forwardedTo.isNotEmpty);
      expect(adb.forwardedTo.first, 'TABLET');
    }, skip: _opensslMissing);

    test('Cancel pressed while a lost link is still being cleaned up stays '
        'cancelled: no retry reopens the listener', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);

      // The link drops, and stopping the capture takes a moment.
      capture.stopDelay = const Duration(milliseconds: 400);
      await clientSocket.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(capture.started, isTrue, reason: 'the teardown is in progress');

      // The user cancels meanwhile.
      await host.disconnect();
      expect(host.phase.value, ConnectionPhase.disconnected);

      // Well past the 1 s retry delay: still off, nothing listening.
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      expect(host.phase.value, ConnectionPhase.disconnected);
      expect(hostSocket.serverPort, isNull);
      expect(capture.started, isFalse);
    }, skip: _opensslMissing);

    test('a tablet that was never paired does not dial at all', () async {
      await hostListens();
      await client.connect();
      expect(client.phase.value, ConnectionPhase.error);
      expect(client.errorMessage.value, 'error_wifi_not_paired');
      expect(hostSocket.isConnected, isFalse);
    }, skip: _opensslMissing);

    test('a tablet paired with another Mac refuses this one', () async {
      // Paired, but with a different certificate than this Mac presents.
      final payload = WifiPairingService.buildPairingPayload(identity, 'Other');
      // The last byte is the (empty) address count; the one before it is the
      // end of the certificate.
      payload[payload.length - 2] ^= 0xFF;
      await pairing.storePairing(payload);
      await hostListens();

      await client.connect();
      expect(client.phase.value, ConnectionPhase.error);
      expect(client.errorMessage.value, 'error_wifi_untrusted');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.phase.value, ConnectionPhase.handshaking,
          reason: 'the Mac keeps waiting for its own tablet');
    }, skip: _opensslMissing);

    test('resetting the identity while the Mac waits over Wi-Fi turns away a '
        'tablet paired before, and lets it in once it has paired again',
        () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();

      await host.resetWifiIdentity();
      // Listening again, as a Mac no tablet knows yet.
      await _until(() =>
          host.phase.value == ConnectionPhase.handshaking &&
          hostSocket.serverPort != null);
      final fresh = await pairing.ensureIdentity();
      expect(fresh.tokenMatches(identity.token), isFalse);
      expect(adb.calls, 0);

      // The tablet still holds the old pairing. (Every identity in this file
      // shares one certificate, so TLS passes and it is the token that is
      // refused; a real reset changes the certificate too.)
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.error);
      expect(host.errorMessage.value, 'error_wifi_unpaired_client');
      expect(capture.started, isFalse);
      expect(input.injected, 0);

      // Paired again, as a USB session would: the next dial gets through.
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(fresh, 'Mac'));
      await _until(() =>
          host.phase.value == ConnectionPhase.handshaking &&
          hostSocket.serverPort != null);
      await client.disconnect();
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);
      expect(capture.started, isTrue);
    }, skip: _opensslMissing);

    test('a reset on an idle Mac starts nothing', () async {
      await host.resetWifiIdentity();
      expect(host.phase.value, ConnectionPhase.disconnected);
      expect(hostSocket.serverPort, isNull);
      expect((await pairing.ensureIdentity()).tokenMatches(identity.token),
          isFalse);
    }, skip: _opensslMissing);

    test('a pairing packet is ignored when it arrives over Wi-Fi', () async {
      await pairing.storePairing(
          WifiPairingService.buildPairingPayload(identity, 'Mac'));
      await hostListens();
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);

      // Whoever is on the other end of a Wi-Fi session may not re-pair the
      // tablet, not even the Mac it already trusts.
      final rogue = WifiPairingService.buildPairingPayload(identity, 'Rogue');
      rogue[2] ^= 0xFF; // a different host id
      hostSocket.send(_control(rogue));
      // Something the client does act on, to know the packet above was read.
      hostSocket.send(_control([0xFB, 90]));
      await _until(() => client.refreshRateHz.value == 90);
      expect(pairing.pairedHosts.map((h) => h.name), ['Mac']);
    }, skip: _opensslMissing);
  });

  group('pairing over USB', () {
    late SettingsService settings;
    late WifiPairingService pairing;
    late _FakeCapture capture;
    late _NoAdb adb;
    late SocketService hostSocket;
    late SocketService clientSocket;
    late HostConnectionManager host;
    late ClientConnectionManager client;
    late WifiIdentity identity;
    late int port;
    Future<void>? hostConnect;

    setUp(() async {
      if (_opensslMissing != null) return;
      hostConnect = null;
      settings = SettingsService();
      await settings.init();
      Get.put<SettingsService>(settings);
      expect(settings.linkType, LinkType.usb);

      // One service plays both roles, as in the Wi-Fi group: the Mac's
      // identity and the tablet's list of paired Macs.
      pairing = Get.put<WifiPairingService>(pairingService());
      identity = await pairing.ensureIdentity();
      Get.put<WifiDiscoveryService>(_NoDiscovery());
      // The tablet's end of adb: a broadcast lands on its pairing channel,
      // which keeps a session key here.
      Get.put(UsbSessionService());
      Get.put(WifiPairingChannel());
      adb = Get.put<AdbService>(_NoAdb()) as _NoAdb
        ..tunnel = true
        ..devices = const [
          DeviceModel(serial: 'TABLET', status: DeviceStatus.connected),
        ]
        ..tablet = _fromAdb;
      capture = Get.put<ScreenCaptureChannel>(_FakeCapture()) as _FakeCapture;
      Get.put<InputInjectChannel>(_FakeInput());
      Get.put(VideoDecoderChannel());
      Get.put(AndroidCaptureChannel());

      port = await _freePort();
      hostSocket = SocketService();
      clientSocket = SocketService();
      host = HostConnectionManager(socket: hostSocket, port: port);
      client = ClientConnectionManager(socket: clientSocket, port: port);
      addTearDown(() async {
        await client.disconnect();
        await host.disconnect();
        await hostConnect;
      });
    });

    /// The first byte of every control packet the tablet is sent.
    List<int> controlsSeenByTablet() {
      final seen = <int>[];
      final sub = clientSocket.packetStream.listen((p) {
        if (p.type == PacketType.control && p.payload.isNotEmpty) {
          seen.add(p.payload[0]);
        }
      });
      addTearDown(sub.cancel);
      return seen;
    }

    Future<void> usbSession() async {
      hostConnect = host.connect(serial: 'TABLET');
      await _until(() => hostSocket.serverPort != null);
      await client.connect();
      await _until(() => host.phase.value == ConnectionPhase.streaming);
    }

    test('reverse remote: as the Mac starts receiving it asks the tablet for '
        'a keyframe too, after the request to capture', () async {
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      Get.put<RemoteVideoChannel>(_FakeRemote());
      final controls = controlsSeenByTablet();
      await usbSession();
      await _until(() => controls.contains(0xFF));
      // A capture left running by the last session ignores 0xF8, and only
      // the 0xFF gets the new decoder a picture it can start from.
      expect(controls, containsAllInOrder([0xF8, 0xFF]));
    }, skip: _opensslMissing);

    test('a USB session keeps the preset\'s bitrate: nothing is adapted',
        () async {
      await usbSession();
      final encoder = _Encoder(capture, startBitrate: 40 * 1000000, fps: 60)
        ..start();
      addTearDown(encoder.stop);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.adaptingBitrate, isFalse);
      expect(host.streamBitrate.value, isNull);
      expect(capture.bitrates, isEmpty);
    }, skip: _opensslMissing);

    test('a USB session hands the pairing to adb for its tablet, and the '
        'link carries none of it', () async {
      final controls = controlsSeenByTablet();
      await usbSession();

      await _until(() => pairing.pairedHosts.isNotEmpty);
      expect(adb.delivered.single.serial, 'TABLET');
      final paired = pairing.pairedHosts.single;
      expect(paired.id, hexOf(identity.hostId));
      expect(identity.tokenMatches(paired.token), isTrue);
      expect(pairing.hostForCert(identity.certDer), isNotNull);
      // Shown on the tablet as "Paired with …": the name the owner gave the
      // Mac, not what the network calls it.
      expect(paired.name, await macDisplayName());

      // Everything sent up to and after the pairing has arrived by the time
      // this marker has, and no pairing was among it.
      hostSocket.send(_control([0xFB, 90]));
      await _until(() => client.refreshRateHz.value == 90);
      expect(controls, contains(0xF9), reason: 'the session was set up');
      expect(controls, isNot(contains(WifiPairingService.pairingCommand)));
      expect(capture.started, isTrue);
    }, skip: _opensslMissing);

    test('an app answering on the tablet\'s port while no tunnel is up '
        'cannot pair the tablet', () async {
      // Whatever listens on 127.0.0.1:<port> is "the Mac" as far as the dial
      // can tell. This one is not adb.
      final rogue = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(rogue.close);
      final accepted = Completer<Socket>();
      rogue.listen((s) {
        s.listen((_) {}, onError: (_) {});
        if (!accepted.isCompleted) accepted.complete(s);
      });

      final dial = client.connect();
      final peer = await accepted.future;
      addTearDown(peer.destroy);

      // A complete, well-formed pairing for a Mac of its own.
      peer.add(_control(WifiPairingService.buildPairingPayload(
              _otherIdentity(9), 'Rogue'))
          .serialize());
      await peer.flush();
      // The tablet gives it the time a Mac has to prove itself, reads what
      // it sent meanwhile, and hangs up.
      await dial;
      expect(client.phase.value, ConnectionPhase.error);

      expect(pairing.pairedHosts, isEmpty);
      final restarted = pairingService();
      await restarted.ready;
      expect(restarted.pairedHosts, isEmpty, reason: 'nothing was saved');
    }, skip: _opensslMissing);

    test('the Mac itself cannot pair the tablet over the link either',
        () async {
      adb.pairings = false; // adb's own delivery never reaches the tablet
      await usbSession();
      await _until(() => adb.delivered.isNotEmpty);

      hostSocket.send(_control(
          WifiPairingService.buildPairingPayload(identity, 'Mac')));
      hostSocket.send(_control([0xFB, 90]));
      await _until(() => client.refreshRateHz.value == 90);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pairing.pairedHosts, isEmpty);
    }, skip: _opensslMissing);

    test('a reset during a USB session gives the tablet the new identity at '
        'once, and the session carries on', () async {
      await usbSession();
      await _until(() => pairing.pairedHosts.isNotEmpty);

      await host.resetWifiIdentity();
      await _until(() => adb.delivered.length == 2);
      final fresh = await pairing.ensureIdentity();
      expect(fresh.hostId, isNot(identity.hostId));
      await _until(() => pairing.hostForId(fresh.hostId) != null);
      expect(fresh.tokenMatches(pairing.hostForId(fresh.hostId)!.token), isTrue);

      expect(host.phase.value, ConnectionPhase.streaming);
      expect(client.phase.value, ConnectionPhase.streaming);
      // The old pairing stays on the tablet until it is forgotten there.
      expect(pairing.pairedHosts, hasLength(2));
    }, skip: _opensslMissing);
  });

  group('USB session key', () {
    final key = UsbSessionService.newKey();
    final nonce = UsbSessionService.newNonce();

    test('a hello made with the key checks out, and gives back its nonce', () {
      final hello = UsbSessionService.buildHello(key, nonce);
      expect(hello[0], 0xF4);
      expect(UsbSessionService.verifyHello(key, hello), nonce);
      // The key is not in it.
      expect(_indexOf(hello, key), -1);
    });

    test('a hello made with another key, with none, altered or cut short '
        'does not', () {
      final hello = UsbSessionService.buildHello(key, nonce);
      expect(
          UsbSessionService.verifyHello(UsbSessionService.newKey(), hello),
          isNull);
      expect(
          UsbSessionService.verifyHello(
              key, UsbSessionService.buildHello(null, nonce)),
          isNull);
      expect(
          UsbSessionService.verifyHello(
              key, Uint8List.fromList(hello)..[3] ^= 1),
          isNull,
          reason: 'another nonce');
      expect(
          UsbSessionService.verifyHello(
              key, Uint8List.fromList(hello)..[hello.length - 1] ^= 1),
          isNull);
      expect(
          UsbSessionService.verifyHello(
              key, hello.sublist(0, hello.length - 1)),
          isNull);
      expect(UsbSessionService.verifyHello(key, Uint8List(0)), isNull);
    });

    test('only the Mac\'s answer to this very hello checks out', () {
      final answer = UsbSessionService.buildAnswer(key, nonce);
      expect(answer[0], 0xF3);
      expect(UsbSessionService.verifyAnswer(key, nonce, answer), isTrue);
      expect(_indexOf(answer, key), -1);

      expect(
          UsbSessionService.verifyAnswer(
              UsbSessionService.newKey(), nonce, answer),
          isFalse);
      expect(
          UsbSessionService.verifyAnswer(
              key, UsbSessionService.newNonce(), answer),
          isFalse,
          reason: 'an answer to an earlier dial');
      expect(
          UsbSessionService.verifyAnswer(
              key, nonce, answer.sublist(0, answer.length - 1)),
          isFalse);

      // The proof in the hello, sent back as the answer.
      final hello = UsbSessionService.buildHello(key, nonce);
      final echoed = Uint8List.fromList([
        UsbSessionService.answerCommand,
        ...hello.sublist(1 + UsbSessionService.nonceLength),
      ]);
      expect(UsbSessionService.verifyAnswer(key, nonce, echoed), isFalse);
    });

    test('a key that adb delivers is kept, and the reply says so', () async {
      final session = Get.put(UsbSessionService());
      Get.put<WifiPairingService>(pairingService());
      Get.put(WifiPairingChannel());
      var arrivals = 0;
      final sub = session.arrivals.listen((_) => arrivals++);
      addTearDown(sub.cancel);

      expect(session.key, isNull);
      expect(
          await _fromAdb(UsbSessionService.buildDelivery(key),
              method: 'usbSession'),
          isTrue);
      expect(session.key, key);
      await Future<void>.delayed(Duration.zero);
      expect(arrivals, 1);

      // Not a key delivery: refused, and the key in hand stays.
      expect(await _fromAdb(key, method: 'usbSession'), isFalse);
      expect(await _fromAdb(Uint8List(0), method: 'usbSession'), isFalse);
      expect(await _fromAdb('not bytes', method: 'usbSession'), isFalse);
      expect(
          await _fromAdb(
              Uint8List.fromList(UsbSessionService.buildDelivery(key))..[0] = 9,
              method: 'usbSession'),
          isFalse,
          reason: 'a version this build does not know');
      expect(session.key, key);
      expect(arrivals, 1);
    });
  });

  group('a USB session proves both ends', () {
    late SettingsService settings;
    late UsbSessionService session;
    late _FakeCapture capture;
    late _FakeInput input;
    late _NoAdb adb;
    late SocketService hostSocket;
    late SocketService clientSocket;
    late HostConnectionManager host;
    late ClientConnectionManager client;
    late int port;
    Future<void>? hostConnect;

    setUp(() async {
      if (_opensslMissing != null) return;
      hostConnect = null;
      settings = SettingsService();
      await settings.init();
      Get.put<SettingsService>(settings);
      expect(settings.linkType, LinkType.usb);

      Get.put<WifiPairingService>(pairingService());
      Get.put<WifiDiscoveryService>(_NoDiscovery());
      // The tablet's end of adb.
      session = Get.put(UsbSessionService());
      Get.put(WifiPairingChannel());
      adb = Get.put<AdbService>(_NoAdb()) as _NoAdb
        ..tunnel = true
        ..devices = const [
          DeviceModel(serial: 'TABLET', status: DeviceStatus.connected),
        ]
        ..tablet = _fromAdb;
      capture = Get.put<ScreenCaptureChannel>(_FakeCapture()) as _FakeCapture;
      input = Get.put<InputInjectChannel>(_FakeInput()) as _FakeInput;
      Get.put(VideoDecoderChannel());
      Get.put(AndroidCaptureChannel());

      port = await _freePort();
      hostSocket = SocketService();
      clientSocket = SocketService();
      host = HostConnectionManager(socket: hostSocket, port: port);
      client = ClientConnectionManager(socket: clientSocket, port: port);
      addTearDown(() async {
        await client.disconnect();
        await host.disconnect();
        await hostConnect;
      });
    });

    /// The Mac has its tunnel up and has handed this attempt's key to adb.
    Future<void> hostWaits({int keys = 1}) async {
      hostConnect ??= host.connect(serial: 'TABLET');
      await _until(() =>
          hostSocket.serverPort != null && adb.sessionKeys.length >= keys);
    }

    Future<void> bothStreaming([ClientConnectionManager? tablet]) => _until(() =>
        host.phase.value == ConnectionPhase.streaming &&
        (tablet ?? client).phase.value == ConnectionPhase.streaming);

    const click = MouseEventModel(
      normalizedX: 0.5,
      normalizedY: 0.5,
      button: MouseButton.left,
      action: MouseAction.down,
      timestampUs: 1,
    );

    /// What an older tablet build opens a session with.
    final oldHello = _control([0x01, 0x02, 0x04, 0x00, 0x03, 0x00, 120]);

    test('a key that arrives while the tablet is disconnecting does not undo '
        'the Disconnect', () async {
      await hostWaits();
      await client.connect();
      await bothStreaming();

      // The user taps Disconnect; while the tablet is still tearing down
      // (its platform calls take a moment), adb hands it the key of a new
      // attempt from the Mac.
      // A GetxService: replaced only with force.
      await Get.delete<AndroidCaptureChannel>(force: true);
      Get.put<AndroidCaptureChannel>(
          _SlowStop(const Duration(milliseconds: 300)));
      final stopping = client.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.phase.value, isNot(ConnectionPhase.disconnected),
          reason: 'still tearing down');
      await _fromAdb(
          UsbSessionService.buildDelivery(UsbSessionService.newKey()),
          method: 'usbSession');
      await stopping;
      expect(client.phase.value, ConnectionPhase.disconnected);
      final after = <ConnectionPhase>[];
      final watch = ever(client.phase, after.add);
      addTearDown(watch.dispose);

      // Longer than the tablet's 5 s retry, and the Mac's own retry (1 s)
      // hands over yet another key meanwhile, which a stopped tablet also
      // keeps for the user's Connect.
      await Future<void>.delayed(const Duration(milliseconds: 5600));
      expect(after, isEmpty,
          reason: 'stopped by the user, it waits for their Connect');
      expect(client.phase.value, ConnectionPhase.disconnected);

      // The Mac's retry is not this test's hostConnect: stop it here, while
      // everything it tears down is still registered.
      await host.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }, skip: _opensslMissing);

    test('the genuine pair connects as before, and the key itself never '
        'goes on the link', () async {
      // adb's tunnel, with a copy of every byte that crosses it.
      final tunnel = await _Tunnel.open(port);
      addTearDown(tunnel.close);
      final tablet =
          ClientConnectionManager(socket: clientSocket, port: tunnel.port);
      addTearDown(tablet.disconnect);

      await hostWaits();
      expect(adb.sessionKeys.single.serial, 'TABLET');
      final key = adb.sessionKeys.single.key;
      expect(session.key, key, reason: 'adb gave it to the tablet app');

      await tablet.connect();
      expect(tablet.phase.value, ConnectionPhase.streaming);
      await bothStreaming(tablet);
      expect(capture.started, isTrue);
      expect(host.activeDevice.value?.serial, 'TABLET');

      // A frame from the encoder arrives at the tablet.
      final frame =
          tablet.packetStream.firstWhere((p) => p.type == PacketType.frameData);
      capture.frames.add(Uint8List.fromList([0, 0, 0, 1, 0x65, 42]));
      expect((await frame.timeout(const Duration(seconds: 5))).payload.last, 42);

      // And a touch from the tablet is injected on the Mac.
      tablet.sendMouse(click);
      await _until(() => input.injected == 1);

      // What crossed the link: the hello first, answered before anything
      // else, and neither with the key in it.
      final toMac = _wholePackets(tunnel.toMac);
      final toTablet = _wholePackets(tunnel.toTablet);
      expect(toMac.first.payload.first, UsbSessionService.helloCommand);
      expect(toTablet.first.payload.first, UsbSessionService.answerCommand);
      expect(_indexOf(tunnel.toMac, key), -1);
      expect(_indexOf(tunnel.toTablet, key), -1);
      expect(adb.sessionKeys, hasLength(1));
    }, skip: _opensslMissing);

    test('a peer on the USB link without the key gets no frames and injects '
        'no input, like a tablet build from before the handshake', () async {
      adb.appOpen = false; // an older build takes no key
      await hostWaits();

      // Whatever dialled the tunnel first. It opens the way a client always
      // did: a HELLO claiming a panel, then a click.
      final peer = await _Stranger.dial(port);
      addTearDown(peer.close);
      peer.send(oldHello);
      peer.send(PacketCodec.wrapMouse(click));

      // The Mac gives it 3 s to prove itself, then drops it.
      await _until(() => host.phase.value == ConnectionPhase.error);
      expect(host.errorMessage.value, 'error_usb_unverified_client');
      expect(input.injected, 0);
      expect(capture.started, isFalse);
      expect(settings.clientPanelWidth.value, 2560,
          reason: 'an unproven HELLO must not resize the stream');
      expect(peer.received, isEmpty,
          reason: 'no mode, codec, video or even a heartbeat');
    }, skip: _opensslMissing);

    test('a hello made without the key is turned away with nothing, and the '
        'tablet still gets in', () async {
      await hostWaits();

      final peer = await _Stranger.dial(port);
      addTearDown(peer.close);
      peer.send(_control(UsbSessionService.buildHello(
          UsbSessionService.newKey(), UsbSessionService.newNonce())));
      peer.send(oldHello);
      peer.send(PacketCodec.wrapMouse(click));

      await _until(() => peer.closed);
      expect(peer.received, isEmpty, reason: 'not even an answer');
      expect(input.injected, 0);
      expect(capture.started, isFalse);
      // The attempt goes on: the Mac is waiting again, not failing.
      await _until(() => host.phase.value == ConnectionPhase.handshaking);
      expect(host.errorMessage.value, isEmpty);

      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming);
      await bothStreaming();
      expect(capture.started, isTrue);
    }, skip: _opensslMissing);

    test('a recorded hello opens nothing a second time', () async {
      final tunnel = await _Tunnel.open(port);
      addTearDown(tunnel.close);
      final tablet =
          ClientConnectionManager(socket: clientSocket, port: tunnel.port);
      addTearDown(tablet.disconnect);
      await hostWaits();
      await tablet.connect();
      await bothStreaming(tablet);
      final hello = _wholePackets(tunnel.toMac).first;
      expect(hello.payload.first, UsbSessionService.helloCommand);

      // The tablet stops; the Mac notices and waits again, with a new key.
      await tablet.disconnect();
      await _until(() => host.phase.value == ConnectionPhase.error);
      await hostWaits(keys: 2);
      expect(_same(adb.sessionKeys.first.key, adb.sessionKeys.last.key),
          isFalse);
      final injectedBefore = input.injected;

      // Byte for byte what let the tablet in a moment ago.
      final peer = await _Stranger.dial(port);
      addTearDown(peer.close);
      peer.socket.add(hello.raw);
      peer.send(PacketCodec.wrapMouse(click));
      await _until(() => peer.closed);
      expect(peer.received, isEmpty);
      expect(input.injected, injectedBefore);
      expect(capture.started, isFalse);
    }, skip: _opensslMissing);

    test('whoever connects after the tablet drops is sent nothing, while the '
        'encoder keeps producing frames, even replaying the hello that let '
        'the tablet in', () async {
      final tunnel = await _Tunnel.open(port);
      addTearDown(tunnel.close);
      final tablet =
          ClientConnectionManager(socket: clientSocket, port: tunnel.port);
      addTearDown(tablet.disconnect);
      await hostWaits();
      await tablet.connect();
      await bothStreaming(tablet);
      final hello = _wholePackets(tunnel.toMac).first.raw;

      // A capture that never stops: a keyframe every few ms, whatever the
      // session is doing.
      final keyframe = Uint8List.fromList([0, 0, 0, 1, 0x65, 1, 2, 3]);
      final encoder = Timer.periodic(const Duration(milliseconds: 2),
          (_) => capture.frames.add(keyframe));
      addTearDown(encoder.cancel);

      // The tablet vanishes, and other apps on it take every chance to get
      // in: during the teardown (which takes a moment, while the server
      // still accepts and frames still come), and at each listen that
      // follows.
      input.releaseDelay = const Duration(milliseconds: 300);
      await tablet.disconnect();
      final strangers = <_Stranger>[];
      addTearDown(() {
        for (final s in strangers) {
          s.close();
        }
      });
      final until = DateTime.now().add(const Duration(milliseconds: 2500));
      while (DateTime.now().isBefore(until)) {
        try {
          final s = await _Stranger.dial(port);
          strangers.add(s);
          s.socket.add(hello);
          s.send(oldHello);
          s.send(PacketCodec.wrapMouse(click));
        } catch (_) {
          // Between listens: nothing to connect to.
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(strangers, isNotEmpty, reason: 'at least one got a connection');
      expect(strangers.expand((s) => s.received), isEmpty,
          reason: 'no frame and no control packet for an unproven peer');
      expect(input.injected, 0);
    }, skip: _opensslMissing);

    /// Something other than adb listening on the tablet's port: [onHello]
    /// gets each connection and the hello the tablet opened it with.
    Future<List<Packet>> rogueListener(
        void Function(Socket peer, Packet hello) onHello) async {
      final seen = <Packet>[];
      final rogue = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(rogue.close);
      rogue.listen((peer) {
        addTearDown(peer.destroy);
        final bytes = <int>[];
        var greeted = false;
        peer.listen((chunk) {
          bytes.addAll(chunk);
          final packets = _wholePackets(bytes);
          seen
            ..clear()
            ..addAll(packets.map((p) => Packet(
                type: p.type, timestampUs: 0, payload: p.payload)));
          if (!greeted && packets.isNotEmpty) {
            greeted = true;
            onHello(peer, seen.first);
          }
        }, onError: (_) {});
      });
      return seen;
    }

    /// Everything a Mac sends to set a session up and take the tablet over:
    /// rate, reverse-remote mode, "share your screen", codec, a frame and,
    /// for good measure, a pairing.
    void driveTablet(Socket peer) {
      for (final packet in [
        _control([0xFB, 90]),
        _control([
          0xF9,
          SessionMode.remoteControl.index,
          RemoteDirection.macControlsTab.index,
        ]),
        _control([0xF8, 1, 60, 12]),
        _control([0xFC, 1]),
        Packet(
          type: PacketType.frameData,
          timestampUs: 0,
          payload: Uint8List.fromList([0, 0, 0, 1, 0x65, 7]),
        ),
        _control(
            WifiPairingService.buildPairingPayload(_otherIdentity(9), 'Rogue')),
        PacketCodec.heartbeat(),
      ]) {
        peer.add(packet.serialize());
      }
    }

    void expectNothingActedOn(List<Packet> shown) {
      expect(client.phase.value, ConnectionPhase.error);
      expect(client.errorMessage.value, 'error_usb_unverified_host');
      expect(client.refreshRateHz.value, 60);
      expect(settings.sessionMode, SessionMode.extendedScreen);
      expect(settings.codec, CodecType.h264);
      expect(client.needsScreenShare.value, isFalse);
      expect(shown, isEmpty, reason: 'nothing reaches the display');
      expect(Get.find<WifiPairingService>().pairedHosts, isEmpty);
    }

    test('a rogue listener cannot get the tablet to act on its packets, '
        'even while the tablet holds a key (an older Mac build is treated '
        'the same)', () async {
      // The key of a Mac's earlier attempt, as adb delivered it.
      expect(
          await _fromAdb(
              UsbSessionService.buildDelivery(UsbSessionService.newKey()),
              method: 'usbSession'),
          isTrue);
      await settings.setCodec(CodecType.h264);
      final shown = <Packet>[];
      final sub = client.packetStream.listen(shown.add, onError: (_) {});
      addTearDown(sub.cancel);

      // No tunnel: what answers on the port is an app, and it starts
      // driving at once, without ever answering the hello.
      final seen = await rogueListener((peer, _) => driveTablet(peer));

      await client.connect(); // waits for the answer, then gives up
      expectNothingActedOn(shown);
      // All it ever got from the tablet is the hello: no HELLO with the
      // panel, no heartbeat reply, no input.
      expect(seen.map((p) => p.payload.first),
          [UsbSessionService.helloCommand]);
    }, skip: _opensslMissing);

    test('a rogue listener that makes an answer up fares no better',
        () async {
      await settings.setCodec(CodecType.h264);
      final shown = <Packet>[];
      final sub = client.packetStream.listen(shown.add, onError: (_) {});
      addTearDown(sub.cancel);
      final key = UsbSessionService.newKey();
      expect(
          await _fromAdb(UsbSessionService.buildDelivery(key),
              method: 'usbSession'),
          isTrue);

      // Three tries, one per dial: the tablet's own proof sent back, an
      // answer made with a key of the listener's choosing, and a real
      // answer, but to another dial (as if recorded from an earlier one).
      var dials = 0;
      await rogueListener((peer, hello) {
        final nonce =
            hello.payload.sublist(1, 1 + UsbSessionService.nonceLength);
        final answer = switch (dials++) {
          0 => [
              UsbSessionService.answerCommand,
              ...hello.payload.sublist(1 + UsbSessionService.nonceLength),
            ],
          1 => UsbSessionService.buildAnswer(UsbSessionService.newKey(), nonce),
          _ => UsbSessionService.buildAnswer(key, UsbSessionService.newNonce()),
        };
        peer.add(_control(answer).serialize());
        driveTablet(peer);
      });

      for (var attempt = 1; attempt <= 3; attempt++) {
        await client.connect();
        expect(dials, attempt);
        expectNothingActedOn(shown);
        await client.disconnect();
      }
    }, skip: _opensslMissing);

    test('a tablet that holds no key believes no answer at all', () async {
      await settings.setCodec(CodecType.h264);
      final shown = <Packet>[];
      final sub = client.packetStream.listen(shown.add, onError: (_) {});
      addTearDown(sub.cancel);
      expect(session.key, isNull);

      // The hello carries a nonce and no proof; the listener answers it
      // correctly for a key of its own.
      final ownKey = UsbSessionService.newKey();
      final seen = await rogueListener((peer, hello) {
        peer.add(_control(UsbSessionService.buildAnswer(
                ownKey, hello.payload.sublist(1)))
            .serialize());
        driveTablet(peer);
      });

      await client.connect();
      expectNothingActedOn(shown);
      expect(seen.single.payload,
          hasLength(1 + UsbSessionService.nonceLength));
    }, skip: _opensslMissing);

    test('a connection made before the key arrived is never believed, not '
        'even on a correct answer: the tablet hangs up and dials again',
        () async {
      await settings.setCodec(CodecType.h264);
      final shown = <Packet>[];
      final sub = client.packetStream.listen(shown.add, onError: (_) {});
      addTearDown(sub.cancel);

      // An app holds the port before any Mac has a tunnel up, and keeps the
      // tablet's connection open.
      final held = <Socket>[];
      final hellos = <Packet>[];
      var closedOnIt = false;
      final rogue = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(rogue.close);
      rogue.listen((peer) {
        held.add(peer);
        addTearDown(peer.destroy);
        final bytes = <int>[];
        final first = held.length == 1;
        peer.listen((chunk) {
          bytes.addAll(chunk);
          final packets = _wholePackets(bytes);
          if (packets.isNotEmpty && hellos.length < held.length) {
            hellos.add(Packet(
                type: packets.first.type,
                timestampUs: 0,
                payload: packets.first.payload));
          }
        }, onDone: () {
          if (first) closedOnIt = true;
        }, onError: (_) {});
      });

      final dial = client.connect();
      await _until(() => hellos.length == 1);
      final nonce = hellos.first.payload.sublist(1);
      expect(nonce, hasLength(UsbSessionService.nonceLength),
          reason: 'no key yet, so no proof');

      // Now a Mac starts an attempt and adb delivers its key. Passing the
      // held connection on to that Mac would get this answer back: right
      // key, right nonce.
      final key = UsbSessionService.newKey();
      expect(
          await _fromAdb(UsbSessionService.buildDelivery(key),
              method: 'usbSession'),
          isTrue);
      held.first
          .add(_control(UsbSessionService.buildAnswer(key, nonce)).serialize());
      driveTablet(held.first);
      await dial;

      // The tablet let go of that connection and dialled a new one, which
      // is the first the key is used on. (Here the app still answers; on a
      // tablet the port is adb's by now.)
      await _until(() => hellos.length == 2 && closedOnIt);
      expect(UsbSessionService.verifyHello(key, hellos.last.payload), isNotNull);
      await _until(() => client.phase.value == ConnectionPhase.error);
      expectNothingActedOn(shown);
    }, skip: _opensslMissing);

    test('the tablet app opened after the Mac started waiting is handed the '
        'key when it dials, and the Mac never leaves its attempt', () async {
      adb.appOpen = false; // nobody there to take the key the attempt made
      await hostWaits();
      expect(session.key, isNull);

      // The app is opened. Its first dial can only say "I am here".
      adb.appOpen = true;
      await client.connect();
      await bothStreaming();

      expect(adb.sessionKeys, hasLength(2));
      expect(_same(adb.sessionKeys.first.key, adb.sessionKeys.last.key), isTrue,
          reason: 'the same attempt, the same key, handed over again');
      expect(host.errorMessage.value, isEmpty);
      expect(capture.started, isTrue);
    }, skip: _opensslMissing);

    test('when adb cannot hand the key to the app, a dial without it fails '
        'the attempt with an error to show', () async {
      adb.appOpen = false;
      await hostWaits();

      final peer = await _Stranger.dial(port);
      addTearDown(peer.close);
      peer.send(_control(
          UsbSessionService.buildHello(null, UsbSessionService.newNonce())));

      await _until(() => host.phase.value == ConnectionPhase.error);
      expect(host.errorMessage.value, 'error_usb_key_not_delivered');
      expect(peer.received, isEmpty);
      expect(capture.started, isFalse);
    }, skip: _opensslMissing);

    test('a key that arrives while the tablet waits makes it dial at once, '
        'not at its next retry', () async {
      // The Mac is not there yet: refused, and the retry is 5 s away.
      await client.connect();
      expect(client.phase.value, ConnectionPhase.error);
      expect(client.errorMessage.value, 'error_waiting_for_host');

      final started = DateTime.now();
      await hostWaits();
      await bothStreaming();
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 3)));
    }, skip: _opensslMissing);

    test('a new key ends the session the Mac has already given up: after a '
        'settings reconnect the tablet is back at once', () async {
      await hostWaits();
      await client.connect();
      await bothStreaming();
      final first = adb.sessionKeys.single.key;

      final started = DateTime.now();
      await host.reconnect(); // as after a settings change on the Mac
      expect(host.phase.value, ConnectionPhase.streaming);
      await _until(() =>
          client.phase.value == ConnectionPhase.streaming &&
          UsbSessionService.sameKey(session.key, adb.sessionKeys.last.key));
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 3)));
      expect(_same(first, adb.sessionKeys.last.key), isFalse);

      // The new session works in both directions.
      final frame =
          client.packetStream.firstWhere((p) => p.type == PacketType.frameData);
      capture.frames.add(Uint8List.fromList([0, 0, 0, 1, 0x65, 9]));
      expect((await frame.timeout(const Duration(seconds: 5))).payload.last, 9);
      client.sendMouse(click);
      await _until(() => input.injected == 1);
    }, skip: _opensslMissing);

    test('a key does not start a tablet the user stopped', () async {
      await client.connect(); // refused: nothing is listening yet
      await client.disconnect();
      expect(client.phase.value, ConnectionPhase.disconnected);

      await hostWaits();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.phase.value, ConnectionPhase.disconnected);
      expect(host.phase.value, ConnectionPhase.handshaking);

      // Their Connect uses the key that came meanwhile.
      await client.connect();
      expect(client.phase.value, ConnectionPhase.streaming);
      await bothStreaming();
    }, skip: _opensslMissing);
  });

  group('settings', () {
    test('Mac-controls-tablet is never the direction over Wi-Fi', () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setSessionMode(SessionMode.remoteControl);
      await settings.setRemoteDirection(RemoteDirection.macControlsTab);
      expect(settings.isReverseRemote, isTrue);

      await settings.setLinkType(LinkType.wifi);
      expect(settings.isReverseRemote, isFalse);
      expect(settings.effectiveRemoteDirection, RemoteDirection.tabControlsMac);
      // The saved choice is kept for when the cable is back.
      await settings.setLinkType(LinkType.usb);
      expect(settings.isReverseRemote, isTrue);
    });

    test('a typed address is stored as something that can be dialled', () {
      String n(String s) => SettingsService.normalizeHostAddress(s);
      expect(n('  192.168.1.20 '), '192.168.1.20');
      // Copied from the Mac's card, port and all.
      expect(n('192.168.1.20:7001'), '192.168.1.20');
      expect(n('studio-mac.local'), 'studio-mac.local');
      expect(n('studio-mac.local:7001'), 'studio-mac.local');
      // Not an IPv4 address or a host name: treated as "find it".
      expect(n('fe80::1'), '');
      expect(n('http://192.168.1.20'), '');
      expect(n('192.168.1.20 7001'), '');
      expect(n('-bad-'), '');
      expect(n(''), '');
    });

    test('the link type and the typed address are saved', () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.linkType, LinkType.usb);
      await settings.setLinkType(LinkType.wifi);
      await settings.setWifiHostAddress('  192.168.1.20 ');

      final restarted = SettingsService();
      await restarted.init();
      expect(restarted.linkType, LinkType.wifi);
      expect(restarted.wifiHostAddress, '192.168.1.20');
    });
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Types of the whole packets in a raw byte capture.
List<PacketType> _packetTypes(List<int> bytes) =>
    [for (final p in _wholePackets(bytes)) p.type];

/// The whole packets in a raw byte capture, each with its bytes as sent.
List<({PacketType type, Uint8List payload, Uint8List raw})> _wholePackets(
    List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  final packets = <({PacketType type, Uint8List payload, Uint8List raw})>[];
  var o = 0;
  while (data.length - o >= Packet.headerSize) {
    final view = ByteData.sublistView(data, o);
    final length = view.getUint32(5, Endian.big);
    final end = o + Packet.headerSize + length;
    if (data.length < end) break;
    packets.add((
      type: PacketType.fromByte(view.getUint8(4)),
      payload: data.sublist(o + Packet.headerSize, end),
      raw: data.sublist(o, end),
    ));
    o = end;
  }
  return packets;
}

/// Where [needle] starts in [haystack], or -1.
int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var j = 0;
    while (j < needle.length && haystack[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return i;
  }
  return -1;
}

/// Something that is not the tablet's app, connected to the Mac's USB port
/// the way anything on the tablet can be (through the tunnel) or anything on
/// the Mac (directly).
class _Stranger {
  _Stranger._(this.socket) {
    socket.listen(received.addAll,
        onDone: () => closed = true, onError: (_) => closed = true);
    socket.done.then((_) {}, onError: (_) {});
  }

  final Socket socket;
  final received = <int>[];
  bool closed = false;

  static Future<_Stranger> dial(int port) async => _Stranger._(
      await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 300)));

  void send(Packet packet) => socket.add(packet.serialize());

  void close() => socket.destroy();
}

/// Stands where adb's tunnel does: the tablet dials [port], every byte is
/// passed on to the Mac's port and back, and a copy is kept of both
/// directions.
class _Tunnel {
  _Tunnel._(this._server, int target) {
    _server.listen((tablet) async {
      _ends.add(tablet);
      final Socket mac;
      try {
        mac = await Socket.connect('127.0.0.1', target);
      } catch (_) {
        tablet.destroy();
        return;
      }
      _ends.add(mac);
      void join(Socket from, Socket to, List<int> copy) {
        from.listen((chunk) {
          copy.addAll(chunk);
          to.add(chunk);
        }, onDone: to.destroy, onError: (_) => to.destroy());
        from.done.then((_) {}, onError: (_) {});
      }

      join(tablet, mac, toMac);
      join(mac, tablet, toTablet);
    });
  }

  final ServerSocket _server;
  final _ends = <Socket>[];
  final toMac = <int>[];
  final toTablet = <int>[];

  static Future<_Tunnel> open(int target) async => _Tunnel._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), target);

  int get port => _server.port;

  Future<void> close() async {
    for (final s in _ends) {
      s.destroy();
    }
    await _server.close();
  }
}

/// A Wi-Fi link that carries [bytesPerSecond] from the Mac to the tablet (and
/// anything the other way), standing between them like an access point: the
/// tablet dials [port], and it dials the Mac. It takes the Mac's data off the
/// socket a few kilobytes every 5 ms, as a radio drains its queue, with a
/// small receive buffer, so what the link can't carry yet stays unacknowledged
/// in the Mac's send queue, where a backlog shows over the air too.
class _SlowLink {
  _SlowLink._(this._server, int target, int bytesPerSecond) {
    _server.listen((tablet) async {
      _tablets.add(tablet);
      final RawSocket mac;
      try {
        mac = await RawSocket.connect('127.0.0.1', target);
      } catch (_) {
        tablet.destroy();
        return;
      }
      _macs.add(mac);
      try {
        const soRcvbuf = 0x1002; // SO_RCVBUF on Darwin
        if (Platform.isMacOS) {
          mac.setRawOption(RawSocketOption.fromInt(
              RawSocketOption.levelSocket, soRcvbuf, 16 * 1024));
        }
      } catch (_) {}
      // Read only on the tick below, never on an event.
      mac.readEventsEnabled = false;
      mac.listen((event) {
        if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          tablet.destroy();
        }
      }, onError: (_) => tablet.destroy());
      // The tablet's few small packets go straight through.
      tablet.listen((data) {
        var offset = 0;
        while (offset < data.length) {
          offset += mac.write(data, offset);
        }
      }, onDone: mac.close, onError: (_) => mac.close());
      tablet.done.then((_) {}, onError: (_) {});

      // What it may have carried by now, from a clock, not from the ticks:
      // a tick the busy isolate ran late (or skipped) must not make the link
      // slower than it is. At most 16 KB at once, as a radio would.
      final clock = Stopwatch()..start();
      var carried = 0;
      _timers.add(Timer.periodic(const Duration(milliseconds: 5), (_) {
        if (_closed) return;
        final due = bytesPerSecond * clock.elapsedMicroseconds ~/ 1000000;
        if (due - carried > 16 * 1024) carried = due - 16 * 1024;
        var budget = due - carried;
        while (budget > 0) {
          final Uint8List? data;
          try {
            data = mac.read(budget);
          } catch (_) {
            return;
          }
          if (data == null || data.isEmpty) return;
          tablet.add(data);
          budget -= data.length;
          carried += data.length;
        }
      }));
    });
  }

  final ServerSocket _server;
  final _tablets = <Socket>[];
  final _macs = <RawSocket>[];
  final _timers = <Timer>[];
  bool _closed = false;

  static Future<_SlowLink> open(int target,
          {required int bytesPerSecond}) async =>
      _SlowLink._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          target, bytesPerSecond);

  int get port => _server.port;

  Future<void> close() async {
    _closed = true;
    for (final t in _timers) {
      t.cancel();
    }
    for (final s in _tablets) {
      s.destroy();
    }
    for (final s in _macs) {
      s.close();
    }
    await _server.close();
  }
}

/// Stands in for VideoToolbox behind [_FakeCapture]: H.264 frames at about
/// [fps], each the size the encoder's current bitrate allows for its tick,
/// a keyframe of [keyframe] of stream every second and whenever one is asked
/// for.
class _Encoder {
  _Encoder(this.capture,
      {required this.startBitrate, required this.fps, this.keyframe});

  final _FakeCapture capture;
  final int startBitrate;
  final int fps;

  /// How much stream a keyframe is worth; one frame's worth if null.
  final Duration? keyframe;
  Timer? _timer;

  void start() {
    var sinceKey = 0;
    var idrs = capture.idrRequests;
    // A whole number of milliseconds, as the timer really ticks.
    final period = Duration(milliseconds: 1000 ~/ fps);
    _timer = Timer.periodic(period, (_) {
      final bitrate =
          capture.bitrates.isEmpty ? startBitrate : capture.bitrates.last;
      // A keyframe asked for starts the interval to the next one again.
      final key = sinceKey % fps == 0 || capture.idrRequests != idrs;
      idrs = capture.idrRequests;
      sinceKey = key ? 1 : sinceKey + 1;
      // The rate is an average, keyframes included, as rate control keeps
      // it: what a keyframe takes beyond one frame comes out of the others.
      final perSecond = bitrate ~/ 8;
      final keyBytes = perSecond * (keyframe ?? period).inMicroseconds ~/ 1000000;
      final otherBytes = keyframe == null
          ? keyBytes
          : math.max(0, perSecond - keyBytes) ~/ math.max(1, fps - 1);
      final frame = Uint8List(math.max(16, key ? keyBytes : otherBytes))
        ..setAll(0, [0, 0, 0, 1, key ? 0x65 : 0x41]);
      capture.frames.add(frame);
    });
  }

  void stop() => _timer?.cancel();
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
