import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/platform/host_name.dart';

/// What makes the Mac recognisable and trustworthy over Wi-Fi: a self-signed
/// TLS certificate (the tablet pins it) and a random token (the tablet proves
/// it was paired by sending it inside the TLS session).
class WifiIdentity {
  static const hostIdLength = 16;
  static const tokenLength = 32;

  /// Random id announced in discovery replies, so a tablet can tell its own
  /// Mac from another one on the network.
  final Uint8List hostId;
  final Uint8List token;
  final String certPem;
  final String keyPem;

  const WifiIdentity({
    required this.hostId,
    required this.token,
    required this.certPem,
    required this.keyPem,
  });

  Uint8List get certDer => pemToDer(certPem);

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Compares in constant time, so a wrong token leaks nothing through how
  /// long the check took.
  bool tokenMatches(List<int> candidate) {
    if (candidate.length != token.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= token[i] ^ candidate[i];
    }
    return diff == 0;
  }
}

/// A Mac this tablet was paired with over USB.
class PairedHost {
  /// [WifiIdentity.hostId] as hex.
  final String id;
  final String name;
  final Uint8List token;
  final Uint8List certDer;

  /// The Mac's own LAN addresses at the time of pairing. A broadcast can't
  /// find a Mac on another subnet (a mesh router that does its own NAT is
  /// enough), but asking these addresses directly can.
  final List<String> addresses;

  /// Where the Mac last answered over Wi-Fi.
  final String? lastAddress;

  const PairedHost({
    required this.id,
    required this.name,
    required this.token,
    required this.certDer,
    this.addresses = const [],
    this.lastAddress,
  });

  PairedHost withAddress(String address) => PairedHost(
        id: id,
        name: name,
        token: token,
        certDer: certDer,
        addresses: addresses,
        lastAddress: address,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'token': base64.encode(token),
        'cert': base64.encode(certDer),
        if (addresses.isNotEmpty) 'addresses': addresses,
        if (lastAddress != null) 'address': lastAddress,
      };

  static PairedHost fromJson(Map<String, dynamic> j) => PairedHost(
        id: j['id'] as String,
        name: j['name'] as String,
        token: base64.decode(j['token'] as String),
        certDer: base64.decode(j['cert'] as String),
        addresses: [for (final a in (j['addresses'] as List?) ?? const []) '$a'],
        lastAddress: j['address'] as String?,
      );
}

typedef CertGenerator = Future<({String certPem, String keyPem})> Function();

/// Body of a PEM block as DER bytes.
Uint8List pemToDer(String pem) => base64.decode(pem
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('-----'))
    .join());

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Wi-Fi pairing for both roles.
///
/// Host: owns the Mac's [WifiIdentity], created on first use and kept in
/// preferences. Client: keeps the [PairedHost]s it learned.
///
/// Pairing happens over USB with no user step: on every USB session the host
/// hands its identity ([buildPairingPayload]) to adb, which delivers it to
/// this app on the tablet as a broadcast only the shell may send (see
/// `AdbService.deliverWifiPairing` and `WifiPairingChannel`). It never
/// travels on the link itself, where "the other end" is only whatever
/// answered on the tablet's 127.0.0.1:7001 or dialled the Mac's tunnel.
class WifiPairingService extends GetxService {
  WifiPairingService({CertGenerator? generateCert})
      : _generateCert = generateCert ?? _opensslSelfSigned;

  /// First byte of a pairing payload. It was a control sub-command while the
  /// payload travelled on the USB link; a client now ignores a packet that
  /// starts with it, on any link, and the byte must not be reused.
  static const pairingCommand = 0xF6;

  /// Control sub-command: client → host, first packet of a Wi-Fi session.
  static const authCommand = 0xF5;

  static const _payloadVersion = 1;
  static const _maxAddresses = 8;
  static const _keyHostId = 'wifi_host_id';
  static const _keyToken = 'wifi_token';
  static const _keyCert = 'wifi_cert_pem';
  static const _keyKey = 'wifi_key_pem';
  static const _keyPaired = 'wifi_paired_hosts';

  final CertGenerator _generateCert;
  Future<WifiIdentity>? _identity;
  Future<void>? _identityReset;
  Future<void>? _loaded;

  /// Client: the Macs this tablet can reach over Wi-Fi. Reactive for Home.
  ///
  /// TODO(P2, iOS): the token and certificate of each go to the Keychain
  /// (`flutter_secure_storage`, first_unlock_this_device) on iOS, behind a
  /// secret-store seam; the P0 spike keeps them in SharedPreferences like
  /// Android.
  final pairedHosts = <PairedHost>[].obs;

  @override
  void onInit() {
    super.onInit();
    ready;
  }

  /// Completes once [pairedHosts] holds what was saved.
  Future<void> get ready => _loaded ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPaired);
    if (raw == null) return;
    try {
      pairedHosts.value = [
        for (final j in jsonDecode(raw) as List)
          PairedHost.fromJson(Map<String, dynamic>.from(j as Map)),
      ];
    } catch (_) {
      // Unreadable list: the next USB session pairs again.
    }
  }

  // ─── Host ─────────────────────────────────────────────────────────────────

  /// The Mac's identity, generated and saved the first time. A failed
  /// generation is not remembered, so the next call tries again.
  Future<WifiIdentity> ensureIdentity() {
    final pending = _identity;
    if (pending != null) return pending;
    final created = _loadOrCreateIdentity();
    _identity = created;
    created.then((_) {}, onError: (_) {
      if (identical(_identity, created)) _identity = null;
    });
    return created;
  }

  Future<WifiIdentity> _loadOrCreateIdentity() async {
    // Never read what a reset is still removing.
    await _identityReset;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_keyHostId);
    final token = prefs.getString(_keyToken);
    final cert = prefs.getString(_keyCert);
    final key = prefs.getString(_keyKey);
    if (id != null && token != null && cert != null && key != null) {
      return WifiIdentity(
        hostId: base64.decode(id),
        token: base64.decode(token),
        certPem: cert,
        keyPem: key,
      );
    }
    final pair = await _generateCert();
    final rnd = Random.secure();
    Uint8List randomBytes(int n) =>
        Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
    final identity = WifiIdentity(
      hostId: randomBytes(WifiIdentity.hostIdLength),
      token: randomBytes(WifiIdentity.tokenLength),
      certPem: pair.certPem,
      keyPem: pair.keyPem,
    );
    await prefs.setString(_keyHostId, base64.encode(identity.hostId));
    await prefs.setString(_keyToken, base64.encode(identity.token));
    await prefs.setString(_keyCert, identity.certPem);
    await prefs.setString(_keyKey, identity.keyPem);
    return identity;
  }

  /// Discards the Mac's identity: its id, token, certificate and key. The
  /// next [ensureIdentity] makes a new one, which no tablet knows, so every
  /// tablet has to pair again over USB. A server still running with the old
  /// certificate is the caller's to restart
  /// (`HostConnectionManager.resetWifiIdentity`).
  Future<void> resetIdentity() {
    final before = _identity;
    final earlier = _identityReset;
    _identity = null;
    final done = () async {
      await earlier;
      // A creation still in flight saves when it finishes: wait, so that what
      // it saved is removed too.
      try {
        await before;
      } catch (_) {}
      final prefs = await SharedPreferences.getInstance();
      for (final key in const [_keyHostId, _keyToken, _keyCert, _keyKey]) {
        await prefs.remove(key);
      }
    }();
    _identityReset = done;
    return done;
  }

  /// Host: the pairing this Mac hands a client right now, through adb
  /// (`HostSession`, after each USB session goes live) or through devicectl
  /// (`IosDeviceService.deliverPairing`): its identity, the Computer Name
  /// the client will show ([macDisplayName]), and where the Mac is at this
  /// moment ([WifiDiscoveryService.lanAddresses]), so the client can ask it
  /// directly later (a broadcast does not cross into another subnet).
  ///
  /// The bytes hold the token: hand them only to a channel that reaches
  /// the client app alone (adb's DUMP-guarded broadcast, the app's own
  /// container), never to the link, and never in a process's arguments.
  Future<Uint8List> offerPayload({
    Future<List<InternetAddress>> Function()? lanAddresses,
    Future<String> Function()? displayName,
  }) async {
    final identity = await ensureIdentity();
    final addresses =
        await (lanAddresses ?? WifiDiscoveryService.lanAddresses)();
    final name = await (displayName ?? macDisplayName)();
    return buildPairingPayload(identity, name, addresses: addresses);
  }

  /// Pairing payload: [pairingCommand], version, host id, token, name
  /// (length-prefixed UTF-8), certificate (uint16 BE length, DER), then the
  /// Mac's IPv4 [addresses] (count byte, 4 bytes each; at most
  /// [_maxAddresses]). The address list was added after the rest: a payload
  /// may end at the certificate.
  static Uint8List buildPairingPayload(
    WifiIdentity identity,
    String name, {
    List<InternetAddress> addresses = const [],
  }) {
    var nameBytes = utf8.encode(name);
    if (nameBytes.length > 64) nameBytes = nameBytes.sublist(0, 64);
    final cert = identity.certDer;
    final v4 = [
      for (final a in addresses)
        if (a.type == InternetAddressType.IPv4) a.rawAddress,
    ].take(_maxAddresses).toList();
    final out = BytesBuilder()
      ..addByte(pairingCommand)
      ..addByte(_payloadVersion)
      ..add(identity.hostId)
      ..add(identity.token)
      ..addByte(nameBytes.length)
      ..add(nameBytes)
      ..addByte(cert.length >> 8)
      ..addByte(cert.length & 0xFF)
      ..add(cert)
      ..addByte(v4.length);
    for (final raw in v4) {
      out.add(raw);
    }
    return out.toBytes();
  }

  /// `0xF5` payload: the token of the Mac being dialled.
  static Uint8List buildAuthPayload(PairedHost host) =>
      Uint8List.fromList([authCommand, ...host.token]);

  // ─── Client ───────────────────────────────────────────────────────────────

  /// Reads a pairing payload. Null when it is malformed or from a newer
  /// version this build does not understand.
  static PairedHost? parsePairingPayload(Uint8List p) {
    const fixed = 2 + WifiIdentity.hostIdLength + WifiIdentity.tokenLength;
    if (p.length < fixed + 1 ||
        p[0] != pairingCommand ||
        p[1] != _payloadVersion) {
      return null;
    }
    var o = 2;
    final id = p.sublist(o, o += WifiIdentity.hostIdLength);
    final token = p.sublist(o, o += WifiIdentity.tokenLength);
    final nameLen = p[o++];
    if (p.length < o + nameLen + 2) return null;
    final name = utf8.decode(p.sublist(o, o += nameLen), allowMalformed: true);
    final certLen = (p[o] << 8) | p[o + 1];
    o += 2;
    if (certLen == 0 || p.length < o + certLen) return null;
    final cert = Uint8List.fromList(p.sublist(o, o += certLen));
    // Optional tail: only whole addresses that are really there are read,
    // and only ones a Mac can have on a network (the tablet will send probes
    // to them: not to itself, to "any", or to a broadcast or multicast group).
    final addresses = <String>[];
    if (o < p.length) {
      final count = p[o++];
      for (var i = 0;
          i < count && i < _maxAddresses && o + 4 <= p.length;
          i++, o += 4) {
        final first = p[o];
        if (first == 0 || first == 127 || first >= 224) continue;
        addresses.add('${p[o]}.${p[o + 1]}.${p[o + 2]}.${p[o + 3]}');
      }
    }
    return PairedHost(
      id: hexOf(id),
      name: name,
      token: Uint8List.fromList(token),
      certDer: cert,
      addresses: addresses,
    );
  }

  /// Stores the Mac from a pairing payload, refreshing an earlier pairing
  /// with the same Mac (its name and addresses) but keeping the address it
  /// was last seen at. Call it only with a payload that adb or the devicectl
  /// inbox delivered (`WifiPairingChannel`), never with bytes from a packet:
  /// whoever can call this decides which Macs the tablet trusts.
  ///
  /// A payload that names a Mac already paired but carries a different
  /// certificate or token is refused. A Mac's id, certificate and token are
  /// created together, so a real Mac never sends that; something else posing
  /// as it would. (Host ids are public: every discovery reply carries one.)
  Future<bool> storePairing(Uint8List payload) async {
    final host = parsePairingPayload(payload);
    if (host == null) return false;
    await ready;
    final old = pairedHosts.firstWhereOrNull((h) => h.id == host.id);
    if (old != null &&
        !(_sameBytes(old.certDer, host.certDer) &&
            _sameBytes(old.token, host.token))) {
      return false;
    }
    final merged =
        old?.lastAddress != null ? host.withAddress(old!.lastAddress!) : host;
    pairedHosts.value = [
      merged,
      ...pairedHosts.where((h) => h.id != host.id),
    ];
    await _save();
    return true;
  }

  /// Unpairs the Mac with this [PairedHost.id]: the tablet stops looking for
  /// it and no longer accepts its certificate. False when there was none.
  /// Connecting to that Mac over USB pairs it again.
  Future<bool> forget(String id) async {
    await ready;
    if (!pairedHosts.any((h) => h.id == id)) return false;
    pairedHosts.value = [...pairedHosts.where((h) => h.id != id)];
    await _save();
    return true;
  }

  PairedHost? hostForId(List<int> hostId) {
    final id = hexOf(hostId);
    return pairedHosts.firstWhereOrNull((h) => h.id == id);
  }

  /// The paired Mac that owns exactly this certificate. This is the pin: a
  /// TLS peer is trusted only when this returns a host.
  PairedHost? hostForCert(Uint8List? der) {
    if (der == null) return null;
    return pairedHosts.firstWhereOrNull((h) => _sameBytes(h.certDer, der));
  }

  Future<void> rememberAddress(PairedHost host, String address) async {
    if (host.lastAddress == address) return;
    pairedHosts.value = [
      for (final h in pairedHosts) h.id == host.id ? h.withAddress(address) : h,
    ];
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keyPaired, jsonEncode([for (final h in pairedHosts) h.toJson()]));
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Self-signed certificate from the system's `openssl` (LibreSSL ships with
  /// macOS). Host only: the tablet never needs a certificate of its own.
  static Future<({String certPem, String keyPem})> _opensslSelfSigned() async {
    final dir = await Directory.systemTemp.createTemp('extendedscreen_tls');
    try {
      final key = '${dir.path}/key.pem';
      final cert = '${dir.path}/cert.pem';
      final r = await Process.run('/usr/bin/openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', //
        '-keyout', key, '-out', cert, '-days', '3650', //
        '-subj', '/CN=extendedscreen',
      ]);
      if (r.exitCode != 0) {
        throw ProcessException('/usr/bin/openssl', const ['req'],
            '${r.stderr}'.trim(), r.exitCode);
      }
      return (
        certPem: await File(cert).readAsString(),
        keyPem: await File(key).readAsString(),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }
}
