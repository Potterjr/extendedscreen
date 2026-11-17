import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

/// What lets the two ends of a USB session recognise each other.
///
/// The socket alone says nothing about who is on it. The Mac's peer is
/// whatever dialled its loopback server, through the adb tunnel or from the
/// Mac itself; the tablet's peer is whatever answered on its own
/// 127.0.0.1:7001, which is adb only while a Mac has its tunnel up. So for
/// every USB attempt the Mac makes a random key, once its tunnel is up, and
/// hands it to this app on the tablet through adb
/// (`AdbService.deliverUsbSessionKey`, a broadcast only the shell may send,
/// as for a Wi-Fi pairing). The key itself never goes on the socket. Each end
/// proves it holds it:
///
///  - [helloCommand], tablet → Mac, the first packet: a fresh nonce and
///    HMAC-SHA256(key, "client" label + nonce).
///  - [answerCommand], Mac → tablet: HMAC-SHA256(key, "host" label + nonce).
///
/// Until the hello checks out the Mac neither reads nor sends anything else,
/// and until the answer checks out neither does the tablet. The Mac accepts
/// one hello per key, so a recorded one is worth nothing.
///
/// The tablet uses a key only on a connection it dialled after the key
/// arrived (it reads [key] before dialling). That is what keeps an app on the
/// tablet from sitting in the middle: to be dialled it must own port 7001,
/// which it can only while adb does not, so before the Mac's tunnel, and with
/// it the key, existed.
///
/// Client (Android): an instance holds the key adb delivered last. The host
/// keeps its key in `HostConnectionManager` and only uses the statics.
class UsbSessionService extends GetxService {
  static const keyLength = 32;
  static const nonceLength = 16;
  static const macLength = 32;

  /// Control sub-command: client → host, first packet of a USB session.
  static const helloCommand = 0xF4;

  /// Control sub-command: host → client, the reply to a hello that proved
  /// the key.
  static const answerCommand = 0xF3;

  static const _deliveryVersion = 1;
  static const _clientLabel = 'extendedscreen usb client';
  static const _hostLabel = 'extendedscreen usb host';

  static final _random = Random.secure();

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  // ─── Client ───────────────────────────────────────────────────────────────

  Uint8List? _key;
  final _arrivals = StreamController<void>.broadcast();

  /// The key adb delivered last, or null when none has arrived since the app
  /// started. Kept in memory only.
  Uint8List? get key => _key;

  /// Fires each time adb delivers a key (the same one again included).
  Stream<void> get arrivals => _arrivals.stream;

  /// Takes a key delivery ([buildDelivery]). Call it only with bytes that adb
  /// delivered (`WifiPairingChannel`): whoever can call this decides what the
  /// tablet accepts as the Mac on its USB link.
  bool accept(Uint8List delivery) {
    if (delivery.length != 1 + keyLength || delivery[0] != _deliveryVersion) {
      return false;
    }
    _key = Uint8List.fromList(delivery.sublist(1));
    _arrivals.add(null);
    return true;
  }

  @override
  void onClose() {
    _arrivals.close();
    super.onClose();
  }

  // ─── Wire format ──────────────────────────────────────────────────────────

  static Uint8List newKey() => _randomBytes(keyLength);
  static Uint8List newNonce() => _randomBytes(nonceLength);

  /// What adb carries to the tablet: a version byte and the key.
  static Uint8List buildDelivery(Uint8List key) =>
      Uint8List.fromList([_deliveryVersion, ...key]);

  /// `0xF4` payload. With no [key] it is the nonce alone: a tablet that was
  /// handed no key yet still dials, so that a Mac already waiting learns the
  /// app is there and delivers its key again.
  static Uint8List buildHello(Uint8List? key, Uint8List nonce) =>
      Uint8List.fromList([
        helloCommand,
        ...nonce,
        if (key != null) ..._mac(key, _clientLabel, nonce),
      ]);

  /// The nonce of a hello made with [key], or null when [payload] is not one.
  static Uint8List? verifyHello(Uint8List key, Uint8List payload) {
    if (payload.length != 1 + nonceLength + macLength ||
        payload[0] != helloCommand) {
      return null;
    }
    final nonce = payload.sublist(1, 1 + nonceLength);
    final mac = payload.sublist(1 + nonceLength);
    return _equal(mac, _mac(key, _clientLabel, nonce)) ? nonce : null;
  }

  /// `0xF3` payload: the proof that the Mac holds [key], for this [nonce].
  static Uint8List buildAnswer(Uint8List key, Uint8List nonce) =>
      Uint8List.fromList([answerCommand, ..._mac(key, _hostLabel, nonce)]);

  static bool verifyAnswer(Uint8List key, Uint8List nonce, Uint8List payload) =>
      payload.length == 1 + macLength &&
      payload[0] == answerCommand &&
      _equal(payload.sublist(1), _mac(key, _hostLabel, nonce));

  static bool sameKey(Uint8List? a, Uint8List? b) =>
      a != null && b != null && _equal(a, b);

  static List<int> _mac(Uint8List key, String label, Uint8List nonce) =>
      Hmac(sha256, key).convert([...label.codeUnits, ...nonce]).bytes;

  /// Compares in constant time, so a wrong proof leaks nothing through how
  /// long the check took.
  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
