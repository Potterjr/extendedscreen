import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extendedscreen/shared/connection/link_measure.dart';
import 'package:extendedscreen/shared/protocol/client_hello.dart';

void main() {
  group('ClientHello.panelSize', () {
    test('Android: the whole display, landscape, rounded as before', () {
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.android,
          display: const Size(1848, 2960),
          window: const Size(2960, 1752),
          // Never taken off on Android.
          padding: const EdgeInsets.only(left: 80, right: 80),
        ),
        (w: 2960, h: 1848),
      );
      // No display reported: the window. Odd sizes stay odd.
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.android,
          display: null,
          window: const Size(2399.6, 1079.4),
        ),
        (w: 2400, h: 1079),
      );
    });

    test('iPhone: the display less the insets on its short edges, even', () {
      // iPhone 18 Pro Max in landscape: the display is reported portrait,
      // the Dynamic Island's side and the other one inset 186 px each, the
      // home indicator 63 px along the bottom (not taken off).
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.iphone,
          display: const Size(1320, 2868),
          window: const Size(2868, 1320),
          padding: const EdgeInsets.only(left: 186, right: 186, bottom: 63),
        ),
        (w: 2496, h: 1320),
      );
      // Uneven insets and odd results round down to even.
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.iphone,
          display: const Size(1179, 2556),
          window: const Size(2556, 1179),
          padding: const EdgeInsets.only(left: 177, right: 0.5),
        ),
        (w: 2378, h: 1178),
      );
    });

    test('iPhone: a padding read while the window is still portrait comes '
        'off the long side all the same', () {
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.iphone,
          display: const Size(1320, 2868),
          window: const Size(1320, 2868),
          padding: const EdgeInsets.only(top: 186, bottom: 186, left: 9),
        ),
        (w: 2496, h: 1320),
      );
    });

    test('iPad: the window less every inset, even, not the display', () {
      // Full screen on a 13-inch iPad Pro, home indicator 40 px.
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.ipad,
          display: const Size(2064, 2752),
          window: const Size(2752, 2064),
          padding: const EdgeInsets.only(bottom: 40),
        ),
        (w: 2752, h: 2024),
      );
      // A Stage Manager window: its own size, whatever the display.
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.ipad,
          display: const Size(2064, 2752),
          window: const Size(1801, 1203),
          padding: const EdgeInsets.only(top: 49, bottom: 40),
        ),
        (w: 1800, h: 1114),
      );
    });

    test('nothing to report gives zeros, never a negative size', () {
      expect(
        ClientHello.panelSize(
          platform: ClientPlatform.iphone,
          display: Size.zero,
          window: const Size(100, 50),
          padding: const EdgeInsets.only(left: 80, right: 80),
        ),
        (w: 0, h: 50),
      );
    });
  });

  test('iosPlatformFor tells an iPad from an iPhone by the display in points',
      () {
    expect(ClientHello.iosPlatformFor(const Size(440, 956)),
        ClientPlatform.iphone);
    expect(ClientHello.iosPlatformFor(const Size(956, 440)),
        ClientPlatform.iphone);
    expect(ClientHello.iosPlatformFor(const Size(744, 1133)),
        ClientPlatform.ipad, reason: 'iPad mini, the smallest iPad');
    expect(ClientHello.iosPlatformFor(const Size(1376, 1032)),
        ClientPlatform.ipad);
  });

  test('payload: command, platform byte, size BE, rate', () {
    expect(
      ClientHello.payload(
        platform: ClientPlatform.iphone,
        width: 2496,
        height: 1320,
        maxRefreshHz: 120,
      ),
      [0x01, 0x03, 2496 >> 8, 2496 & 0xFF, 1320 >> 8, 1320 & 0xFF, 120],
    );
    expect(
      ClientHello.payload(
        platform: ClientPlatform.ipad,
        width: 2752,
        height: 2024,
        maxRefreshHz: 300,
      ),
      [0x01, 0x04, 2752 >> 8, 2752 & 0xFF, 2024 >> 8, 2024 & 0xFF, 255],
    );
    expect(
      ClientHello.payload(
        platform: ClientPlatform.android,
        width: 2960,
        height: 1848,
        maxRefreshHz: 120,
      )[1],
      0x02,
    );
  });

  group('LinkMeasure', () {
    test('percentile is the nearest rank', () {
      final values = [for (var i = 1; i <= 100; i++) i];
      expect(LinkMeasure.percentile(values, 50), 50);
      expect(LinkMeasure.percentile(values, 95), 95);
      expect(LinkMeasure.percentile(values, 99), 99);
      expect(LinkMeasure.percentile([7], 99), 7);
      expect(LinkMeasure.percentile([], 50), isNull);
    });

    test('logs round trips and frame intervals, and sums up each window', () {
      final lines = <String>[];
      var now = 0;
      final m = LinkMeasure(sink: lines.add, clockUs: () => now);

      m.roundTrip(4000);
      expect(lines, ['rtt 4000']);

      // 60 fps sent; the third frame arrives 5 ms late, the fourth on time.
      m.frame(1000000);
      now += 16667;
      m.frame(1016667);
      now += 21667;
      m.frame(1033334);
      now += 11667;
      m.frame(1050001);
      // Batched until a second has passed, or a round trip comes.
      expect(lines, ['rtt 4000']);
      m.roundTrip(9000);
      expect(lines, [
        'rtt 4000',
        'fr 16667/16667 21667/16667 11667/16667',
        'rtt 9000',
      ]);

      // A reconnect: the gap to the next link's first frame is not jitter.
      m.linkStarted();
      now += 5000000;
      m.frame(9000000);
      now += 1000000;
      m.frame(9016667);
      expect(lines.last, 'fr 1000000/16667');

      // The window ends: a summary, and the next window starts empty.
      now += 30000000;
      m.roundTrip(2000);
      final summary = lines.lastWhere((l) => l.startsWith('summary'));
      expect(summary, contains('rtt n=3'));
      expect(summary, contains('p50=4.0'));
      expect(summary, contains('p99=9.0'));
      expect(summary, contains('frames n=6'));
      expect(summary, contains('jitter p95=983.3'));
      expect(m.summary(), contains('rtt n=0'));
    });

    test('a frame batch never grows past its byte limit', () {
      final lines = <String>[];
      var now = 0;
      final m = LinkMeasure(sink: lines.add, clockUs: () => now, batchBytes: 40);
      for (var i = 0; i < 10; i++) {
        now += 16000;
        m.frame(i * 16000);
      }
      expect(lines, isNotEmpty);
      for (final l in lines) {
        expect(l.length, lessThanOrEqualTo(40 + 'fr '.length));
      }
    });
  });
}
