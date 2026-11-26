import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/painting.dart' show EdgeInsets;

/// What kind of client sent a HELLO: its platform byte (`p[1]`). Hosts read
/// only the size and the rate (`p[2..6]`), so a new value changes nothing on
/// a host that does not know it.
enum ClientPlatform {
  android(0x02),
  iphone(0x03),
  ipad(0x04),
  windows(0x05);

  const ClientPlatform(this.byte);
  final int byte;
}

/// The client's HELLO (`0x01`): the area it renders, which the host treats
/// as the panel. Pure, so tests (and later the wire fixtures) can build it
/// without a device.
class ClientHello {
  ClientHello._();

  static const command = 0x01;

  /// An iPad's display is at least 744 pt on its short side (iPad mini), an
  /// iPhone's at most 440 pt (the Pro Max models). Anything from here up is
  /// taken for an iPad.
  static const ipadMinShortSidePt = 600.0;

  /// Which iOS device this is, from its display's size in points. A Dart
  /// heuristic rather than `UIDevice.userInterfaceIdiom`: synchronous, no
  /// native call before the first HELLO, and the two families are hundreds
  /// of points apart. It reads the display, never the window: an iPad window
  /// in Split View or Stage Manager can be narrower than any iPhone.
  static ClientPlatform iosPlatformFor(Size displayPoints) =>
      displayPoints.shortestSide >= ipadMinShortSidePt
          ? ClientPlatform.ipad
          : ClientPlatform.iphone;

  /// The size to report, in physical pixels, landscape (width ≥ height).
  ///
  /// - Android: the whole display ([display], else [window]), as before,
  ///   rounded to the nearest pixel. The window can leave out the
  ///   navigation bar, the display does not.
  /// - iPhone: the display, less the safe-area insets on its two short
  ///   edges (the Dynamic Island's side and the other one, cropped alike),
  ///   rounded down to even. The long edges' insets (the home indicator)
  ///   are not taken off: the picture runs under them.
  /// - iPad: the window (Split View, Stage Manager), less every safe-area
  ///   inset, rounded down to even.
  /// - Windows: the monitor the window is on ([display], else [window]),
  ///   rounded down to even, so the Mac's display matches it when the
  ///   window is made full screen; a smaller window shows it letterboxed.
  ///   Unlike a tablet it may be portrait: a PC monitor need not turn.
  ///
  /// [padding] is the view's safe area in physical pixels, as
  /// `FlutterView.padding` reports it for the window's orientation. Which of
  /// its edges are the short ones follows the window's shape, so a padding
  /// read while the window is still portrait is not taken from the width.
  static ({int w, int h}) panelSize({
    required ClientPlatform platform,
    required Size? display,
    required Size window,
    EdgeInsets padding = EdgeInsets.zero,
  }) {
    final shown = (display == null || display.isEmpty) ? window : display;
    final landscape = window.width >= window.height;
    final acrossLong = landscape ? padding.horizontal : padding.vertical;
    final acrossShort = landscape ? padding.vertical : padding.horizontal;
    int even(double v) => v <= 0 ? 0 : v.floor() & ~1;
    switch (platform) {
      case ClientPlatform.android:
        return (w: shown.longestSide.round(), h: shown.shortestSide.round());
      case ClientPlatform.iphone:
        return (
          w: even(shown.longestSide - acrossLong),
          h: even(shown.shortestSide),
        );
      case ClientPlatform.ipad:
        return (
          w: even(window.longestSide - acrossLong),
          h: even(window.shortestSide - acrossShort),
        );
      case ClientPlatform.windows:
        return (w: even(shown.width), h: even(shown.height));
    }
  }

  /// HELLO: command, platform byte, width and height (uint16 BE each,
  /// physical px, landscape), the panel's top refresh rate (1 byte, Hz),
  /// then, with [installId], the identity tail ([HelloTail]). Hosts read
  /// only the first seven bytes, or the tail too: a host that does not know
  /// the tail ignores it.
  static Uint8List payload({
    required ClientPlatform platform,
    required int width,
    required int height,
    required int maxRefreshHz,
    Uint8List? installId,
    String name = '',
  }) =>
      Uint8List.fromList([
        command,
        platform.byte,
        (width >> 8) & 0xFF, width & 0xFF,
        (height >> 8) & 0xFF, height & 0xFF,
        maxRefreshHz.clamp(0, 255),
        if (installId != null) ...HelloTail.encode(installId, name),
      ]);
}

/// The identity a client adds after HELLO's seven bytes: `0xA1`, its install
/// id (16 random bytes made once and kept by the app), the length of its
/// name (1 byte) and the name in UTF-8, at most [maxNameBytes]. Sent only
/// after the peer is trusted, so the 1 KB untrusted limit is no concern.
/// Lets the Mac recognise a Wi-Fi device across connections and addresses.
class HelloTail {
  const HelloTail(this.installId, this.name);

  final Uint8List installId;
  final String name;

  static const tag = 0xA1;
  static const idLength = 16;
  static const maxNameBytes = 64;

  /// The install id as lowercase hex, for keys.
  String get idHex =>
      installId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> encode(Uint8List installId, String name) {
    assert(installId.length == idLength);
    var bytes = utf8.encode(name);
    if (bytes.length > maxNameBytes) {
      // Cut between characters, never inside one.
      var end = maxNameBytes;
      while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      bytes = bytes.sublist(0, end);
    }
    return [tag, ...installId, bytes.length, ...bytes];
  }

  /// The tail of [hello] (a whole HELLO payload, command byte first), or
  /// null when it has none or it is malformed.
  static HelloTail? parse(Uint8List hello) {
    const at = 7;
    if (hello.length < at + 1 + idLength + 1 || hello[at] != tag) return null;
    final id = Uint8List.fromList(hello.sublist(at + 1, at + 1 + idLength));
    final nameLength = hello[at + 1 + idLength];
    final start = at + 2 + idLength;
    if (nameLength > maxNameBytes || hello.length < start + nameLength) {
      return null;
    }
    String name;
    try {
      name = utf8.decode(hello.sublist(start, start + nameLength));
    } on FormatException {
      name = '';
    }
    return HelloTail(id, name.trim());
  }
}
