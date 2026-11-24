import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';

/// A Mac that answered a discovery probe.
class DiscoveredHost {
  final InternetAddress address;
  final int tcpPort;
  final Uint8List hostId;
  final String name;

  const DiscoveredHost({
    required this.address,
    required this.tcpPort,
    required this.hostId,
    required this.name,
  });
}

/// Finds the Mac on the local network without the user typing an address.
///
/// The tablet broadcasts a small UDP probe; a listening Mac answers the
/// sender directly with its id, name and TCP port. Asking this way round
/// keeps the reply unicast, which reaches a tablet whose Wi-Fi filters
/// incoming broadcasts.
///
/// Nothing here is trusted: a reply only says where to dial. Whether that
/// peer is the paired Mac is decided by the TLS certificate pin.
class WifiDiscoveryService extends GetxService {
  /// [udpPort] and [broadcast] exist for tests, which run a responder and a
  /// prober on a free loopback port without touching the real network.
  WifiDiscoveryService({this.udpPort = port, this.broadcast = true});

  /// UDP port, the same number as the TCP link.
  static const port = 7001;

  /// The port this instance answers on and probes.
  final int udpPort;

  /// Whether [probe] also asks the broadcast addresses.
  final bool broadcast;

  static const _version = 1;

  /// Datagrams one probe reads before it stops listening.
  static const _maxDatagrams = 64;

  /// Responder: datagrams read before yielding, and replies sent per second.
  static const _maxPerTurn = 32;
  static const _maxRepliesPerSecond = 20;
  static final _probe = Uint8List.fromList([...ascii.encode('EXTD?'), _version]);
  static final _replyMagic = ascii.encode('EXTD!');

  RawDatagramSocket? _responder;
  StreamSubscription<RawSocketEvent>? _responderSub;
  // Bumped by start and stop, so a restart scheduled after an error does
  // nothing once the responder was stopped or started again meanwhile.
  int _responderGen = 0;

  // ─── Host ─────────────────────────────────────────────────────────────────

  /// Answers probes until [stopResponder]. Throws if the port can't be bound;
  /// the link still works then, through a typed address.
  ///
  /// dart:io does not throw when a datagram can't be sent (the asker dropped
  /// off the network, no route): it reports an error on the socket's stream
  /// and closes the socket. So an error here means the responder is gone, and
  /// it is bound again a moment later rather than left silently dead while
  /// the Mac still shows itself as waiting.
  Future<void> startResponder({
    required Uint8List hostId,
    required String name,
    required int tcpPort,
  }) async {
    stopResponder();
    final gen = _responderGen;
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort,
        reuseAddress: true);
    if (gen != _responderGen) {
      sock.close(); // stopped or restarted while binding
      return;
    }
    final reply = encodeReply(hostId: hostId, name: name, tcpPort: tcpPort);
    _responder = sock;
    // Anyone on the network can send here, as fast as it likes. Two bounds
    // keep that from costing more than a little CPU:
    //  - at most [_maxPerTurn] datagrams are read before the rest of the app
    //    gets a turn. Returning is not enough for that: dart:io calls the
    //    handler again from a microtask while datagrams wait, and microtasks
    //    run before anything else. So reading is switched off and switched
    //    back on from a timer, which is a turn of the event loop.
    //  - at most [_maxRepliesPerSecond] replies go out, so this can't be used
    //    to aim traffic at someone else's (spoofed) address.
    var windowStart = DateTime.now();
    var repliesInWindow = 0;
    _responderSub = sock.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        var read = 0;
        for (var dg = sock.receive(); dg != null; dg = sock.receive()) {
          if (_isProbe(dg.data)) {
            final now = DateTime.now();
            if (now.difference(windowStart) >= const Duration(seconds: 1)) {
              windowStart = now;
              repliesInWindow = 0;
            }
            if (repliesInWindow++ < _maxRepliesPerSecond) {
              sock.send(reply, dg.address, dg.port);
            }
          }
          if (++read >= _maxPerTurn) {
            sock.readEventsEnabled = false;
            Timer.run(() {
              if (gen == _responderGen) sock.readEventsEnabled = true;
            });
            return;
          }
        }
      },
      onError: (Object _) {
        if (gen != _responderGen) return;
        _responderSub?.cancel();
        _responderSub = null;
        _responder = null;
        Timer(const Duration(seconds: 1), () {
          if (gen != _responderGen) return;
          startResponder(hostId: hostId, name: name, tcpPort: tcpPort)
              .catchError((Object _) {});
        });
      },
    );
  }

  /// The UDP port the responder is bound to, or null when it isn't running.
  int? get responderPort => _responder?.port;

  void stopResponder() {
    _responderGen++;
    _responderSub?.cancel();
    _responderSub = null;
    _responder?.close();
    _responder = null;
  }

  // ─── Client ───────────────────────────────────────────────────────────────

  /// Sends a probe and collects the answers for [timeout], or until one
  /// satisfies [until]. The probe goes to the broadcast addresses and to each
  /// of [directTargets]: addresses the Mac is believed to have, which is the
  /// only way to reach one on another subnet.
  ///
  /// Each target gets a socket of its own. A send that fails (no route, no
  /// Wi-Fi) closes the socket it was made on, and with one shared socket that
  /// would also throw away the answers to the probes that did go out.
  Future<List<DiscoveredHost>> probe({
    Duration timeout = const Duration(seconds: 1),
    bool Function(DiscoveredHost host)? until,
    List<InternetAddress> directTargets = const [],
  }) async {
    final found = <DiscoveredHost>[];
    final done = Completer<void>();
    final sockets = <RawDatagramSocket>[];
    final subs = <StreamSubscription<RawSocketEvent>>[];
    // Anyone on the network can answer, as often and as fast as it likes.
    // Reading stops for good after [_maxDatagrams], so a flood of replies
    // costs a bounded amount of work.
    var datagrams = 0;

    // dart:io calls a read handler again, from a microtask, for as long as a
    // datagram is waiting on an open socket. A handler that returns without
    // reading it (the probe is already decided) is therefore called for ever:
    // microtasks run before anything else, so the event loop never gets the
    // turn in which the socket would be closed, and the whole app freezes.
    // With one socket per target this is the normal case, not a corner: on
    // an ordinary network the Mac answers the broadcast, the subnet broadcast
    // and its own address, three sockets, at the same moment. So the instant
    // the probe is decided, every socket is closed, synchronously.
    void finish() {
      if (!done.isCompleted) done.complete();
      for (final sock in sockets) {
        sock.close();
      }
    }

    void read(RawDatagramSocket sock) {
      if (done.isCompleted) {
        sock.close();
        return;
      }
      for (var dg = sock.receive(); dg != null; dg = sock.receive()) {
        if (++datagrams > _maxDatagrams) {
          finish();
          return;
        }
        final host = decodeReply(dg.data, dg.address);
        if (host == null) continue;
        final known = found.any((h) =>
            h.address == host.address && _sameBytes(h.hostId, host.hostId));
        if (!known) found.add(host);
        if (until?.call(host) ?? false) {
          finish();
          return;
        }
      }
    }

    try {
      final targets = <InternetAddress>{
        if (broadcast) ...await _broadcastTargets(),
        ...directTargets,
      }.toList();
      // Every socket exists before the first probe leaves, so finish() always
      // has all of them to close.
      for (var i = 0; i < targets.length; i++) {
        sockets.add(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));
      }
      for (var i = 0; i < targets.length; i++) {
        final sock = sockets[i];
        // Off when this service sends no broadcast: iOS refuses SO_BROADCAST
        // without the multicast entitlement, which a free team cannot get.
        if (broadcast) sock.broadcastEnabled = true;
        subs.add(sock.listen(
          (event) {
            if (event == RawSocketEvent.read) read(sock);
          },
          // This target can't be reached; the others carry on.
          onError: (Object _) {},
        ));
        sock.send(_probe, targets[i], udpPort);
      }
      await done.future.timeout(timeout, onTimeout: () {});
    } finally {
      // Close them all first, then wait: waiting on one while another still
      // holds a datagram is the freeze described above.
      finish();
      await Future.wait([for (final sub in subs) sub.cancel()]);
    }
    return found;
  }

  /// The limited broadcast plus each interface's /24 broadcast. Dart exposes
  /// no netmask; /24 covers home and office networks, and anything else can
  /// use the typed address.
  static Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    for (final a in await lanAddresses()) {
      final b = a.rawAddress;
      targets.add('${b[0]}.${b[1]}.${b[2]}.255');
    }
    return [for (final t in targets) InternetAddress(t)];
  }

  /// This device's IPv4 addresses on real networks (no loopback, no
  /// link-local). Empty when there is no network or the list can't be read.
  static Future<List<InternetAddress>> lanAddresses() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a,
      ];
    } catch (_) {
      return const [];
    }
  }

  // ─── Wire format ──────────────────────────────────────────────────────────
  // Reply: "EXTD!" + version + host id (16) + TCP port (uint16 BE) + name
  // (length-prefixed UTF-8).

  static Uint8List encodeReply({
    required Uint8List hostId,
    required String name,
    required int tcpPort,
  }) {
    var nameBytes = utf8.encode(name);
    if (nameBytes.length > 64) nameBytes = nameBytes.sublist(0, 64);
    return (BytesBuilder()
          ..add(_replyMagic)
          ..addByte(_version)
          ..add(hostId)
          ..addByte(tcpPort >> 8)
          ..addByte(tcpPort & 0xFF)
          ..addByte(nameBytes.length)
          ..add(nameBytes))
        .toBytes();
  }

  static DiscoveredHost? decodeReply(Uint8List d, InternetAddress from) {
    const idLen = 16;
    final head = _replyMagic.length + 1;
    if (d.length < head + idLen + 3) return null;
    for (var i = 0; i < _replyMagic.length; i++) {
      if (d[i] != _replyMagic[i]) return null;
    }
    if (d[_replyMagic.length] != _version) return null;
    var o = head;
    final id = Uint8List.fromList(d.sublist(o, o += idLen));
    final tcpPort = (d[o] << 8) | d[o + 1];
    o += 2;
    final nameLen = d[o++];
    if (d.length < o + nameLen) return null;
    return DiscoveredHost(
      address: from,
      tcpPort: tcpPort,
      hostId: id,
      name: utf8.decode(d.sublist(o, o + nameLen), allowMalformed: true),
    );
  }

  static bool _isProbe(Uint8List d) => _sameBytes(d, _probe);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void onClose() {
    stopResponder();
    super.onClose();
  }
}
