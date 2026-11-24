import 'dart:convert';
import 'dart:typed_data';

/// The Wi-Fi pairing payload as text, for the debug-only paste path of a
/// client that has neither adb nor devicectl (the Windows client; see
/// `docs/windows-start.md`, Pairing). The same bytes adb delivers
/// (`WifiPairingService.buildPairingPayload`), in base64url after a prefix
/// that names the format. It holds the Mac's long-lived token: it is only
/// ever shown in a debug build, and is to be replaced by roadmap §5.2's
/// exchange.
class PairingCode {
  PairingCode._();

  static const prefix = 'esp1:';

  static String encode(Uint8List payload) =>
      prefix + base64Url.encode(payload).replaceAll('=', '');

  /// The payload in [text], or null when it is not a pairing code. Blanks
  /// and line breaks (a code wrapped by whatever carried it) are ignored.
  static Uint8List? decode(String text) {
    var s = text.replaceAll(RegExp(r'\s'), '');
    if (!s.startsWith(prefix)) return null;
    s = s.substring(prefix.length);
    if (s.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s)) return null;
    try {
      return Uint8List.fromList(base64Url.decode(base64Url.normalize(s)));
    } on FormatException {
      return null;
    }
  }
}
