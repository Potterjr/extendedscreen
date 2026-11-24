import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/painting.dart' show EdgeInsets;

/// What kind of client sent a HELLO: its platform byte (`p[1]`). Hosts read
/// only the size and the rate (`p[2..6]`), so a new value changes nothing on
/// a host that does not know it.
enum ClientPlatform {
  android(0x02),
  iphone(0x03),
  ipad(0x04);

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
    }
  }

  /// HELLO: command, platform byte, width and height (uint16 BE each,
  /// physical px, landscape), the panel's top refresh rate (1 byte, Hz).
  static Uint8List payload({
    required ClientPlatform platform,
    required int width,
    required int height,
    required int maxRefreshHz,
  }) =>
      Uint8List.fromList([
        command,
        platform.byte,
        (width >> 8) & 0xFF, width & 0xFF,
        (height >> 8) & 0xFF, height & 0xFF,
        maxRefreshHz.clamp(0, 255),
      ]);
}
