import 'dart:typed_data';

import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:extendedscreen/shared/protocol/peer_protocol.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList(List.generate(n, (i) => (seed + i * 7) & 0xFF));

const _sid = 0x0123456789ABCDEF;
const _panel = PeerPanel(0x05, 2560, 1440, 144);

/// Every message the codec knows, one of each shape.
List<PeerMessage> _all() => [
      PeerPropose(
        sessionId: _sid,
        feature: PeerFeature.remoteControl,
        provider: PeerProvider.answerer,
        flags: PeerFlags.resume,
        caps: PeerCaps.view | PeerCaps.decodeH265,
        panel: _panel,
      ),
      PeerPropose(
        sessionId: 7,
        feature: PeerFeature.extendedScreen,
        provider: PeerProvider.dialler,
        caps: PeerCaps.provideExtendedScreen,
      ),
      PeerAccept(
        sessionId: _sid,
        feature: PeerFeature.extendedScreen,
        provider: PeerProvider.answerer,
        caps: PeerCaps.listens,
      ),
      PeerAccept(
        sessionId: -1, // all 64 bits set
        feature: PeerFeature.extendedScreen,
        provider: PeerProvider.dialler,
        caps: 0xFFFF,
        panel: _panel,
      ),
      const PeerRefuse(
        sessionId: _sid,
        reason: PeerRefusal.permissionMissing,
        detail: PeerRefusal.detailScreenRecording,
      ),
      const PeerPending(sessionId: _sid, secondsLeft: 60),
      const PeerEnd(sessionId: _sid, reason: PeerEndReason.userStopped),
      const PeerUnpair(),
      PeerPairCommit(
        platform: PeerProtocol.platformWindows,
        certDer: _bytes(700, 3),
        commitment: _bytes(32, 9),
      ),
      PeerPairNonce(reply: true, reveal: false, nonce: _bytes(32, 1)),
      PeerPairNonce(reply: false, reveal: true, nonce: _bytes(32, 2)),
      const PeerPairConfirm(reply: false),
      const PeerPairConfirm(reply: true),
      const PeerPairAbort(reply: true),
      PeerPairPayload(reply: false, payload: _bytes(1200, 4)),
      PeerPairPayload(reply: true, payload: _bytes(900, 5)),
    ];

void main() {
  group('reserved bytes', () {
    test('the peer commands are 0xE0-0xE9 and touch no byte in use', () {
      expect(PeerProtocol.propose, 0xE0);
      expect(PeerProtocol.pairReply, 0xE9);
      for (var b = 0; b < 256; b++) {
        expect(PeerProtocol.isPeerCommand(b), b >= 0xE0 && b <= 0xE9);
      }
      // Today's sub-commands (0x01, 0xF3-0xFF) and the reservations of
      // other designs (0xEF-0xF2) stay outside the range.
      for (final b in [0x01, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF6, 0xFF]) {
        expect(PeerProtocol.isPeerCommand(b), isFalse);
      }
      expect(PeerProtocol.platformWindows, ClientPlatform.windows.byte);
      expect(PeerProtocol.platformWindows, HostSession.helloPlatformWindows);
      expect(PeerProtocol.platformMacos, 0x06);
      expect(PeerProtocol.helloTailTag, 0xA2);
      expect(PeerProtocol.discoveryTailTag, 0xD1);
    });

    test('nothing else decodes as a peer message', () {
      for (final b in [0x01, 0xE6, 0xE7, 0xF3, 0xF5, 0xF9, 0xFF]) {
        expect(PeerProtocol.decode(Uint8List.fromList([b, 1, 0, 0, 0, 0])),
            isNull);
      }
    });
  });

  group('messages', () {
    test('every message round-trips', () {
      for (final m in _all()) {
        final bytes = m.encode();
        expect(bytes[0], m.command);
        expect(bytes[1], PeerProtocol.version);
        final back = PeerProtocol.decode(bytes);
        expect(back, isNotNull, reason: '${m.runtimeType}');
        expect(back.runtimeType, m.runtimeType);
        expect(back!.encode(), bytes, reason: '${m.runtimeType}');
      }
    });

    test('fields come back as sent', () {
      final p = PeerProtocol.decode(_all()[0].encode()) as PeerPropose;
      expect(p.sessionId, _sid);
      expect(p.feature, PeerFeature.remoteControl);
      expect(p.provider, PeerProvider.answerer);
      expect(p.flags, PeerFlags.resume);
      expect(PeerCaps.has(p.caps, PeerCaps.decodeH265), isTrue);
      expect(PeerCaps.has(p.caps, PeerCaps.encodeH265), isFalse);
      expect(p.panel, _panel);

      final noPanel = PeerProtocol.decode(_all()[1].encode()) as PeerPropose;
      expect(noPanel.panel, isNull,
          reason: 'a dialler that provides sends no panel');

      final a = PeerProtocol.decode(_all()[3].encode()) as PeerAccept;
      expect(a.sessionId, -1);
      expect(a.caps, 0xFFFF);
      expect(a.panel, _panel, reason: "the viewing answerer's panel");

      final r = PeerProtocol.decode(_all()[4].encode()) as PeerRefuse;
      expect(r.reason, PeerRefusal.permissionMissing);
      expect(r.detail, PeerRefusal.detailScreenRecording);
      expect(r.maxVer, PeerProtocol.version);

      final c = PeerProtocol.decode(_all()[8].encode()) as PeerPairCommit;
      expect(c.command, PeerProtocol.pair);
      expect(c.certDer, _bytes(700, 3));
      expect(c.commitment, _bytes(32, 9));

      final n = PeerProtocol.decode(_all()[9].encode()) as PeerPairNonce;
      expect(n.command, PeerProtocol.pairReply);
      expect(n.reveal, isFalse);
      final rv = PeerProtocol.decode(_all()[10].encode()) as PeerPairNonce;
      expect(rv.reveal, isTrue);
      expect(rv.step, PeerPairStep.reveal);

      final pa = PeerProtocol.decode(_all()[15].encode()) as PeerPairPayload;
      expect(pa.reply, isTrue);
      expect(pa.step, PeerPairStep.answererPayload);
      expect(pa.payload, _bytes(900, 5));
    });

    test('every cut-short body decodes as null and never throws', () {
      for (final m in _all()) {
        final bytes = m.encode();
        for (var n = 0; n < bytes.length; n++) {
          final cut = Uint8List.sublistView(bytes, 0, n);
          expect(PeerProtocol.decode(cut), isNull,
              reason: '${m.runtimeType} cut to $n of ${bytes.length}');
        }
      }
    });

    test('bytes appended after the known fields are ignored', () {
      for (final m in _all()) {
        final bytes = m.encode();
        final longer = Uint8List.fromList([...bytes, 0xAA, 0xBB, 0x00, 0x7F]);
        final back = PeerProtocol.decode(longer);
        expect(back, isNotNull, reason: '${m.runtimeType}');
        expect(back!.encode(), bytes);
      }
    });

    test('a higher version decodes with its version kept; 0 is refused', () {
      final bytes = _all()[0].encode();
      final v2 = Uint8List.fromList([...bytes, 1, 2, 3])..[1] = 2;
      final p = PeerProtocol.decode(v2) as PeerPropose;
      expect(p.ver, 2, reason: 'the caller refuses it with 6/2 at its maxVer');
      expect(p.sessionId, _sid);
      final v0 = Uint8List.fromList(bytes)..[1] = 0;
      expect(PeerProtocol.decode(v0), isNull);
    });

    test('an unknown pairing step decodes as null', () {
      expect(
          PeerProtocol.decode(Uint8List.fromList([PeerProtocol.pair, 1, 0])),
          isNull);
      expect(
          PeerProtocol.decode(
              Uint8List.fromList([PeerProtocol.pairReply, 1, 0x42, 1, 2])),
          isNull);
    });

    test('unknown feature, provider, caps and flag values pass through', () {
      final m = PeerPropose(
        sessionId: 1,
        feature: 9,
        provider: PeerProvider.dialler,
        flags: 0xFE,
        caps: 0xFF80,
      );
      final p = PeerProtocol.decode(m.encode()) as PeerPropose;
      expect(p.feature, 9);
      expect(p.flags, 0xFE);
      expect(p.caps, 0xFF80);
      expect(PeerHelloTail(
              caps: 0, sessionId: 1, feature: 0, provider: 0, flags: 0xFE)
          .resume, isFalse);
    });
  });

  group('HELLO tail 0xA2', () {
    final id = _bytes(16, 11);
    const tail = PeerHelloTail(
      caps: PeerCaps.view | PeerCaps.keyEvents,
      sessionId: _sid,
      feature: PeerFeature.remoteControl,
      provider: PeerProvider.answerer,
      flags: PeerFlags.resume,
    );

    Uint8List hello({bool identity = true, List<int> extra = const []}) =>
        Uint8List.fromList([
          ...ClientHello.payload(
            platform: ClientPlatform.windows,
            width: 2560,
            height: 1440,
            maxRefreshHz: 144,
            installId: identity ? id : null,
            name: 'DESKTOP-ÄB',
          ),
          ...tail.encode(),
          ...extra,
        ]);

    test('round-trips after the 0xA1 tail, which still parses', () {
      final h = hello();
      expect(PeerHelloTail.parse(h), tail);
      expect(PeerHelloTail.parse(h)!.resume, isTrue);
      final a1 = HelloTail.parse(h)!;
      expect(a1.installId, id);
      expect(a1.name, 'DESKTOP-ÄB');
      expect(h.sublist(0, 7), [0x01, 0x05, 0x0A, 0x00, 0x05, 0xA0, 144],
          reason: 'the seven bytes a host reads today are unchanged');
    });

    test('round-trips with no 0xA1 tail, and ignores appended bytes', () {
      expect(PeerHelloTail.parse(hello(identity: false)), tail);
      expect(PeerHelloTail.parse(hello(extra: [1, 2, 3])), tail);
    });

    test('a cut-short tail, or none, is null', () {
      final h = hello();
      final tailStart = h.length - tail.encode().length;
      for (var n = 0; n < h.length; n++) {
        expect(PeerHelloTail.parse(Uint8List.sublistView(h, 0, n)), isNull,
            reason: 'cut to $n (tail starts at $tailStart)');
      }
      // A tablet's HELLO: seven bytes, or with the 0xA1 tail only.
      expect(
          PeerHelloTail.parse(ClientHello.payload(
              platform: ClientPlatform.android,
              width: 2960,
              height: 1848,
              maxRefreshHz: 120,
              installId: id)),
          isNull);
      final v0 = Uint8List.fromList(h)..[tailStart + 1] = 0;
      expect(PeerHelloTail.parse(v0), isNull);
    });
  });

  group('discovery tail 0xD1', () {
    test('round-trips at the end of a reply and ignores what follows', () {
      const t = PeerDiscoveryTail(
          platform: 0x06,
          caps: PeerCaps.listens,
          flags: PeerDiscoveryTail.pairingOpen);
      final reply = Uint8List.fromList([...'EXTD!'.codeUnits, 1, 9, 9]);
      final at = reply.length;
      final whole = Uint8List.fromList([...reply, ...t.encode(), 0x55]);
      final back = PeerDiscoveryTail.parse(whole, at)!;
      expect(back, t);
      expect(back.isPairingOpen, isTrue);
      expect(PeerDiscoveryTail.parse(reply, at), isNull);
      for (var n = at; n < at + 5; n++) {
        expect(
            PeerDiscoveryTail.parse(Uint8List.sublistView(whole, 0, n), at),
            isNull);
      }
    });
  });

  group('pairing arithmetic', () {
    final certA = _bytes(600, 1);
    final certB = _bytes(500, 2);
    final nonceA = _bytes(32, 3);
    final nonceB = _bytes(32, 4);

    test('the commitment binds the nonce and the certificate', () {
      final c = PeerPairing.commitment(nonceB, certB);
      expect(c.length, 32);
      expect(PeerPairing.commitmentMatches(c, nonceB, certB), isTrue);
      expect(PeerPairing.commitmentMatches(c, nonceA, certB), isFalse);
      expect(PeerPairing.commitmentMatches(c, nonceB, certA), isFalse);
      expect(PeerPairing.commitmentMatches(c.sublist(1), nonceB, certB),
          isFalse);
    });

    test('both sides get the same six digits; a swapped certificate does '
        'not', () {
      final sas = PeerPairing.sas(certA, certB, nonceA, nonceB);
      expect(sas, inInclusiveRange(0, 999999));
      expect(PeerPairing.sas(certA, certB, nonceA, nonceB), sas);
      final mitm = _bytes(600, 77);
      expect(PeerPairing.sas(mitm, certB, nonceA, nonceB), isNot(sas));
      expect(PeerPairing.formatSas(42), '000 042');
      expect(PeerPairing.formatSas(123456), '123 456');
    });
  });
}
