import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The desktop-peer wire (`docs/desktop-peers-design.md`, *Wire*): the bytes
/// a Mac and a Windows PC use to negotiate a session and to pair, as a pure
/// codec. Nothing sends these yet (M0): the constants reserve the bytes and
/// the codec is tested on its own.
///
/// Every message is a CONTROL payload: its sub-command byte, then a version
/// byte, then the fields of that version. Fields are only ever appended, so
/// a decoder reads the fields it knows, ignores whatever follows them, and
/// takes a higher version as the same layout with more after it (the caller
/// answers a version it does not speak with REFUSE 6/2). A body too short
/// for its fields decodes as null, never throws.
///
/// None of this reaches a tablet or an iPhone: they send HELLO `0x02`-`0x04`
/// with no `0xA2` tail and hold the identity token, and the answerer only
/// speaks this to a peer that matched a per-peer token (the design's
/// admission matrix).
class PeerProtocol {
  PeerProtocol._();

  /// The version this build speaks.
  static const version = 1;

  // HELLO platform bytes for desktops. 0x05 is what the Windows client
  // already sends (`ClientPlatform.windows`, `HostSession.helloPlatformWindows`).
  static const platformWindows = 0x05;

  /// Reserved for a Mac that dials another desktop (M6). Unused: a HELLO
  /// with it is still taken for Android by today's host.
  static const platformMacos = 0x06;

  // CONTROL sub-commands, 0xE0-0xE9 (0xE6/0xE7 reserved).
  static const propose = 0xE0;
  static const accept = 0xE1;
  static const refuse = 0xE2;
  static const pending = 0xE3;
  static const end = 0xE4;
  static const unpair = 0xE5;
  static const reservedE6 = 0xE6;
  static const reservedE7 = 0xE7;
  static const pair = 0xE8;
  static const pairReply = 0xE9;

  /// The first and last byte of the range the desktop peers own.
  static const firstCommand = 0xE0;
  static const lastCommand = 0xE9;

  /// Whether [command] (a CONTROL payload's first byte) is a desktop-peer
  /// message.
  static bool isPeerCommand(int command) =>
      command >= firstCommand && command <= lastCommand;

  /// The HELLO tail that carries the dialler's proposal ([PeerHelloTail]).
  static const helloTailTag = 0xA2;

  /// The tag appended to a discovery reply ([PeerDiscoveryTail]).
  static const discoveryTailTag = 0xD1;

  /// The length of a session id on the wire.
  static const sessionIdLength = 8;

  /// Decodes a CONTROL payload that starts with one of `0xE0`-`0xE5`,
  /// `0xE8` or `0xE9`; null for any other byte, a version 0, or a body too
  /// short for its fields.
  static PeerMessage? decode(Uint8List payload) {
    if (payload.length < 2 || payload[1] < 1) return null;
    final r = _Reader(payload, 2);
    final ver = payload[1];
    try {
      switch (payload[0]) {
        case propose:
          final id = r.u64();
          final feature = r.u8();
          final provider = r.u8();
          final flags = r.u8();
          final caps = r.u16();
          final panel = provider == PeerProvider.answerer ? r.panel() : null;
          return PeerPropose(
            ver: ver,
            sessionId: id,
            feature: feature,
            provider: provider,
            flags: flags,
            caps: caps,
            panel: panel,
          );
        case accept:
          final id = r.u64();
          final feature = r.u8();
          final provider = r.u8();
          final caps = r.u16();
          final panel = provider == PeerProvider.dialler ? r.panel() : null;
          return PeerAccept(
            ver: ver,
            sessionId: id,
            feature: feature,
            provider: provider,
            caps: caps,
            panel: panel,
          );
        case refuse:
          return PeerRefuse(
            ver: ver,
            sessionId: r.u64(),
            reason: r.u8(),
            detail: r.u8(),
            maxVer: r.u8(),
          );
        case pending:
          return PeerPending(
              ver: ver, sessionId: r.u64(), secondsLeft: r.u8());
        case end:
          return PeerEnd(ver: ver, sessionId: r.u64(), reason: r.u8());
        case unpair:
          return PeerUnpair(ver: ver);
        case pair:
        case pairReply:
          return PeerPair._decode(payload[0] == pairReply, ver, r);
      }
    } on _Short {
      return null;
    }
    return null;
  }
}

/// `feature` on the wire.
class PeerFeature {
  PeerFeature._();
  static const extendedScreen = 0;
  static const remoteControl = 1;
}

/// `provider` on the wire: which end of the link captures and encodes.
class PeerProvider {
  PeerProvider._();
  static const answerer = 0;
  static const dialler = 1;
}

/// Bits of the proposal's `flags`; unknown bits are ignored.
class PeerFlags {
  PeerFlags._();

  /// A redial of the same `sessionId`.
  static const resume = 0x01;
}

/// Capability bits (`caps`, u16; unknown bits ignored). They say what is
/// installed, not what is granted.
class PeerCaps {
  PeerCaps._();
  static const provideExtendedScreen = 1 << 0;
  static const provideRemoteControl = 1 << 1;
  static const view = 1 << 2;
  static const decodeH265 = 1 << 3;
  static const encodeH265 = 1 << 4;
  static const keyEvents = 1 << 5;
  static const listens = 1 << 6;

  static bool has(int caps, int bit) => caps & bit != 0;
}

/// REFUSE's `reason` (each with a translation key `error_peer_<name>` once
/// something shows it).
class PeerRefusal {
  PeerRefusal._();
  static const permissionMissing = 1;
  static const busy = 2;
  static const noDisplayDriver = 3;
  static const declined = 4;
  static const approvalTimedOut = 5;
  static const unsupported = 6;
  static const encoderAtCapacity = 7;
  static const crossedCall = 8;
  static const incomingOff = 9;
  static const pairAgain = 10;

  // `detail` for permissionMissing.
  static const detailScreenRecording = 1;
  static const detailAccessibility = 2;
  static const detailSecureDesktop = 3;
  static const detailNotifications = 4;

  // `detail` for busy.
  static const detailBusyWithYou = 1;
  static const detailControlledByOther = 2;
  static const detailRemoteRoleTaken = 3;

  // `detail` for unsupported.
  static const detailFeature = 1;
  static const detailVersion = 2;
  static const detailProviderSide = 3;
  static const detailCodec = 4;
}

/// END's `reason`.
class PeerEndReason {
  PeerEndReason._();
  static const userStopped = 1;
  static const unpaired = 2;
  static const appQuitting = 3;
  static const featureSwitched = 4;
}

/// The panel block: `platform(1), w u16, h u16, maxHz u8`, HELLO bytes 1-6.
class PeerPanel {
  const PeerPanel(this.platform, this.width, this.height, this.maxHz);

  final int platform;
  final int width;
  final int height;
  final int maxHz;

  static const length = 6;

  List<int> encode() => [
        platform & 0xFF,
        (width >> 8) & 0xFF, width & 0xFF,
        (height >> 8) & 0xFF, height & 0xFF,
        maxHz.clamp(0, 255),
      ];

  @override
  bool operator ==(Object other) =>
      other is PeerPanel &&
      other.platform == platform &&
      other.width == width &&
      other.height == height &&
      other.maxHz == maxHz;

  @override
  int get hashCode => Object.hash(platform, width, height, maxHz);

  @override
  String toString() => 'PeerPanel($platform, $width×$height@$maxHz)';
}

/// The dialler's first proposal, after HELLO's seven bytes and its `0xA1`
/// tail: `0xA2, ver, caps u16, sessionId(8), feature, provider, flags`.
/// Read only from a peer whose token was a per-peer one.
class PeerHelloTail {
  const PeerHelloTail({
    this.ver = PeerProtocol.version,
    required this.caps,
    required this.sessionId,
    required this.feature,
    required this.provider,
    this.flags = 0,
  });

  final int ver;
  final int caps;
  final int sessionId;
  final int feature;
  final int provider;
  final int flags;

  bool get resume => flags & PeerFlags.resume != 0;

  List<int> encode() => [
        PeerProtocol.helloTailTag,
        ver,
        ..._u16(caps),
        ..._u64(sessionId),
        feature,
        provider,
        flags,
      ];

  /// The tail of [hello] (a whole HELLO payload, command byte first): after
  /// the seven bytes, past an `0xA1` tail if there is one. Null when there
  /// is none, it is cut short or its version is 0.
  static PeerHelloTail? parse(Uint8List hello) {
    var at = 7;
    if (hello.length > at && hello[at] == 0xA1) {
      // 0xA1, installId(16), nameLen(1), name.
      const nameLengthAt = 1 + 16;
      if (hello.length <= at + nameLengthAt) return null;
      at += nameLengthAt + 1 + hello[at + nameLengthAt];
    }
    if (hello.length <= at || hello[at] != PeerProtocol.helloTailTag) {
      return null;
    }
    final r = _Reader(hello, at + 1);
    try {
      final ver = r.u8();
      if (ver < 1) return null;
      return PeerHelloTail(
        ver: ver,
        caps: r.u16(),
        sessionId: r.u64(),
        feature: r.u8(),
        provider: r.u8(),
        flags: r.u8(),
      );
    } on _Short {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PeerHelloTail &&
      other.ver == ver &&
      other.caps == caps &&
      other.sessionId == sessionId &&
      other.feature == feature &&
      other.provider == provider &&
      other.flags == flags;

  @override
  int get hashCode =>
      Object.hash(ver, caps, sessionId, feature, provider, flags);
}

/// What a discovery reply gains after its v1 fields:
/// `0xD1, platform, caps u16, flags`.
class PeerDiscoveryTail {
  const PeerDiscoveryTail({
    required this.platform,
    required this.caps,
    this.flags = 0,
  });

  final int platform;
  final int caps;
  final int flags;

  /// `flags` bit 0: the desktop has a pairing window open.
  static const pairingOpen = 0x01;

  bool get isPairingOpen => flags & pairingOpen != 0;

  List<int> encode() =>
      [PeerProtocol.discoveryTailTag, platform, ..._u16(caps), flags];

  /// The tail at [at] in [reply] (where the v1 reply ends), or null when
  /// there is none or it is cut short. Bytes after it are ignored.
  static PeerDiscoveryTail? parse(Uint8List reply, int at) {
    if (reply.length <= at || reply[at] != PeerProtocol.discoveryTailTag) {
      return null;
    }
    final r = _Reader(reply, at + 1);
    try {
      return PeerDiscoveryTail(platform: r.u8(), caps: r.u16(), flags: r.u8());
    } on _Short {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PeerDiscoveryTail &&
      other.platform == platform &&
      other.caps == caps &&
      other.flags == flags;

  @override
  int get hashCode => Object.hash(platform, caps, flags);
}

/// A decoded `0xE*` message. [encode] gives the whole CONTROL payload,
/// sub-command byte first.
sealed class PeerMessage {
  const PeerMessage(this.ver);

  final int ver;

  int get command;
  List<int> body();

  Uint8List encode() => Uint8List.fromList([command, ver, ...body()]);
}

/// `0xE0`: a re-proposal on a live link. [panel] is the dialler's when it
/// is the viewer ([provider] answerer), and required then.
class PeerPropose extends PeerMessage {
  PeerPropose({
    int ver = PeerProtocol.version,
    required this.sessionId,
    required this.feature,
    required this.provider,
    this.flags = 0,
    required this.caps,
    this.panel,
  })  : assert(provider != PeerProvider.answerer || panel != null),
        super(ver);

  final int sessionId;
  final int feature;
  final int provider;
  final int flags;
  final int caps;
  final PeerPanel? panel;

  @override
  int get command => PeerProtocol.propose;

  @override
  List<int> body() => [
        ..._u64(sessionId),
        feature,
        provider,
        flags,
        ..._u16(caps),
        if (provider == PeerProvider.answerer) ...panel!.encode(),
      ];
}

/// `0xE1`. [panel] is the answerer's when it is the viewer ([provider]
/// dialler), and required then.
class PeerAccept extends PeerMessage {
  PeerAccept({
    int ver = PeerProtocol.version,
    required this.sessionId,
    required this.feature,
    required this.provider,
    required this.caps,
    this.panel,
  })  : assert(provider != PeerProvider.dialler || panel != null),
        super(ver);

  final int sessionId;
  final int feature;
  final int provider;
  final int caps;
  final PeerPanel? panel;

  @override
  int get command => PeerProtocol.accept;

  @override
  List<int> body() => [
        ..._u64(sessionId),
        feature,
        provider,
        ..._u16(caps),
        if (provider == PeerProvider.dialler) ...panel!.encode(),
      ];
}

/// `0xE2`: [reason] is a [PeerRefusal] code, [maxVer] the highest version
/// the answerer speaks.
class PeerRefuse extends PeerMessage {
  const PeerRefuse({
    int ver = PeerProtocol.version,
    required this.sessionId,
    required this.reason,
    this.detail = 0,
    this.maxVer = PeerProtocol.version,
  }) : super(ver);

  final int sessionId;
  final int reason;
  final int detail;
  final int maxVer;

  @override
  int get command => PeerProtocol.refuse;

  @override
  List<int> body() => [..._u64(sessionId), reason, detail, maxVer];
}

/// `0xE3`: the answerer's user is being asked.
class PeerPending extends PeerMessage {
  const PeerPending({
    int ver = PeerProtocol.version,
    required this.sessionId,
    required this.secondsLeft,
  }) : super(ver);

  final int sessionId;
  final int secondsLeft;

  @override
  int get command => PeerProtocol.pending;

  @override
  List<int> body() => [..._u64(sessionId), secondsLeft.clamp(0, 255)];
}

/// `0xE4`: [reason] is a [PeerEndReason] code.
class PeerEnd extends PeerMessage {
  const PeerEnd({
    int ver = PeerProtocol.version,
    required this.sessionId,
    required this.reason,
  }) : super(ver);

  final int sessionId;
  final int reason;

  @override
  int get command => PeerProtocol.end;

  @override
  List<int> body() => [..._u64(sessionId), reason];
}

/// `0xE5`: the sender is forgetting this peer.
class PeerUnpair extends PeerMessage {
  const PeerUnpair({int ver = PeerProtocol.version}) : super(ver);

  @override
  int get command => PeerProtocol.unpair;

  @override
  List<int> body() => const [];
}

/// The steps of a pairing exchange, the byte after `ver` in `0xE8`/`0xE9`.
/// The numbers follow the design's *Exchange* table where a step is a
/// packet; its step 5 sends nothing, so 5 is abort.
class PeerPairStep {
  PeerPairStep._();

  /// B (dialler) → A: platform, its certificate, the commitment.
  static const commit = 1;

  /// A → B: A's nonce.
  static const nonce = 2;

  /// B → A: B's nonce, which A checks against the commitment.
  static const reveal = 3;

  /// Either: this side's user pressed *Codes match*.
  static const confirm = 4;

  /// Either: *Don't match*, or anything else that ends the exchange.
  static const abort = 5;

  /// B → A (`0xE8`): B's pairing payload v2.
  static const diallerPayload = 6;

  /// A → B (`0xE9`): A's pairing payload v2.
  static const answererPayload = 7;
}

/// `0xE8` (from the dialler) or `0xE9` ([reply], from the answerer): one
/// step of the pairing exchange. Only on a pairing connection.
sealed class PeerPair extends PeerMessage {
  const PeerPair(super.ver, {required this.reply});

  /// Sent as `0xE9`, by the answerer.
  final bool reply;

  int get step;

  @override
  int get command => reply ? PeerProtocol.pairReply : PeerProtocol.pair;

  @override
  List<int> body() => [step, ...stepBody()];

  List<int> stepBody();

  static PeerPair? _decode(bool reply, int ver, _Reader r) {
    final step = r.u8();
    switch (step) {
      case PeerPairStep.commit:
        final platform = r.u8();
        final cert = r.bytes(r.u16());
        return PeerPairCommit(
          ver: ver,
          reply: reply,
          platform: platform,
          certDer: cert,
          commitment: r.bytes(PeerPairing.hashLength),
        );
      case PeerPairStep.nonce:
      case PeerPairStep.reveal:
        return PeerPairNonce(
          ver: ver,
          reply: reply,
          reveal: step == PeerPairStep.reveal,
          nonce: r.bytes(PeerPairing.nonceLength),
        );
      case PeerPairStep.confirm:
        return PeerPairConfirm(ver: ver, reply: reply);
      case PeerPairStep.abort:
        return PeerPairAbort(ver: ver, reply: reply);
      case PeerPairStep.diallerPayload:
      case PeerPairStep.answererPayload:
        return PeerPairPayload(
          ver: ver,
          reply: reply,
          payload: r.bytes(r.u16()),
        );
    }
    return null;
  }
}

/// Step 1: `platform, certLen u16, cert DER, C(32)`, where C is
/// [PeerPairing.commitment] of the dialler's nonce and certificate.
class PeerPairCommit extends PeerPair {
  PeerPairCommit({
    int ver = PeerProtocol.version,
    bool reply = false,
    required this.platform,
    required this.certDer,
    required this.commitment,
  })  : assert(certDer.length <= 0xFFFF),
        assert(commitment.length == PeerPairing.hashLength),
        super(ver, reply: reply);

  final int platform;
  final Uint8List certDer;
  final Uint8List commitment;

  @override
  int get step => PeerPairStep.commit;

  @override
  List<int> stepBody() =>
      [platform, ..._u16(certDer.length), ...certDer, ...commitment];
}

/// Step 2 (the answerer's nonce) or, with [reveal], step 3 (the dialler's
/// nonce, revealed): 32 bytes.
class PeerPairNonce extends PeerPair {
  PeerPairNonce({
    int ver = PeerProtocol.version,
    required bool reply,
    required this.reveal,
    required this.nonce,
  })  : assert(nonce.length == PeerPairing.nonceLength),
        super(ver, reply: reply);

  final bool reveal;
  final Uint8List nonce;

  @override
  int get step => reveal ? PeerPairStep.reveal : PeerPairStep.nonce;

  @override
  List<int> stepBody() => nonce;
}

/// Step 4: this side's user confirmed the digits match.
class PeerPairConfirm extends PeerPair {
  const PeerPairConfirm({int ver = PeerProtocol.version, required bool reply})
      : super(ver, reply: reply);

  @override
  int get step => PeerPairStep.confirm;

  @override
  List<int> stepBody() => const [];
}

/// The exchange is over without a pairing.
class PeerPairAbort extends PeerPair {
  const PeerPairAbort({int ver = PeerProtocol.version, required bool reply})
      : super(ver, reply: reply);

  @override
  int get step => PeerPairStep.abort;

  @override
  List<int> stepBody() => const [];
}

/// Steps 6 and 7: the sender's pairing payload v2, `len u16` then the
/// bytes (its own layout and parser, not this codec's). Sent only after both
/// confirms.
class PeerPairPayload extends PeerPair {
  PeerPairPayload({
    int ver = PeerProtocol.version,
    required bool reply,
    required this.payload,
  })  : assert(payload.length <= 0xFFFF),
        super(ver, reply: reply);

  final Uint8List payload;

  @override
  int get step =>
      reply ? PeerPairStep.answererPayload : PeerPairStep.diallerPayload;

  @override
  List<int> stepBody() => [..._u16(payload.length), ...payload];
}

/// The pairing exchange's arithmetic (design, *Exchange*): the dialler's
/// commitment and the six digits both screens show.
class PeerPairing {
  PeerPairing._();

  static const nonceLength = 32;
  static const hashLength = 32;

  static final _commitLabel = utf8.encode('esdp-commit');
  static final _sasLabel = utf8.encode('esdp-sas');

  /// C = SHA-256("esdp-commit" ‖ nonceB ‖ certB).
  static Uint8List commitment(List<int> nonceB, List<int> certB) =>
      Uint8List.fromList(
          sha256.convert([..._commitLabel, ...nonceB, ...certB]).bytes);

  /// Whether [commitment] is what [nonceB] and [certB] commit to, compared
  /// in constant time.
  static bool commitmentMatches(
      List<int> commitment, List<int> nonceB, List<int> certB) {
    final want = PeerPairing.commitment(nonceB, certB);
    if (commitment.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= commitment[i] ^ want[i];
    }
    return diff == 0;
  }

  /// SHA-256("esdp-sas" ‖ certA ‖ certB ‖ nonceA ‖ nonceB), its first four
  /// bytes as a big-endian integer, mod 10⁶.
  static int sas(List<int> certA, List<int> certB, List<int> nonceA,
      List<int> nonceB) {
    final h = sha256
        .convert([..._sasLabel, ...certA, ...certB, ...nonceA, ...nonceB])
        .bytes;
    final v = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
    return v % 1000000;
  }

  /// [sas] as both screens show it: `123 456`.
  static String formatSas(int sas) {
    final s = sas.toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }
}

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

List<int> _u64(int v) {
  final b = ByteData(8)..setUint64(0, v);
  return b.buffer.asUint8List();
}

class _Short implements Exception {
  const _Short();
}

class _Reader {
  _Reader(this.data, this.at);

  final Uint8List data;
  int at;

  void _need(int n) {
    if (at + n > data.length) throw const _Short();
  }

  int u8() {
    _need(1);
    return data[at++];
  }

  int u16() {
    _need(2);
    final v = (data[at] << 8) | data[at + 1];
    at += 2;
    return v;
  }

  int u64() {
    _need(8);
    final v = ByteData.sublistView(data, at, at + 8).getUint64(0);
    at += 8;
    return v;
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.fromList(data.sublist(at, at + n));
    at += n;
    return v;
  }

  PeerPanel panel() => PeerPanel(u8(), u16(), u16(), u8());
}
