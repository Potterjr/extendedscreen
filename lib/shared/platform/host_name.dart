import 'dart:convert';
import 'dart:io';

/// Reads the name the owner gave this Mac. Null when there is none to read.
typedef ComputerNameReader = Future<String?> Function();

/// The most a name may take in a pairing packet or a discovery reply, in
/// UTF-8 bytes (both carry it behind a one-byte length and cut it at 64).
const maxHostNameBytes = 64;

/// The name this Mac shows on the tablet ("Paired with …").
///
/// It is the Computer Name from System Settings → General → Sharing, the one
/// the owner chose and recognises. `Platform.localHostname` is not that: it is
/// whatever the network last called the machine. On a VPN, or any network with
/// reverse DNS, it turns into something like `host123.corp.example.com`,
/// different from one network to the next, and that is what the tablet then
/// shows as the Mac it is paired with.
///
/// Falls back to the first label of the host name when the Computer Name
/// can't be read (not macOS, `scutil` missing or failing, an empty name).
/// The result is never empty and never longer than [maxHostNameBytes], cut
/// between characters rather than in the middle of one.
Future<String> macDisplayName({
  ComputerNameReader? readComputerName,
  String Function()? readHostName,
}) async {
  String? name;
  try {
    name = await (readComputerName ?? _scutilComputerName)();
  } catch (_) {
    // Fall through to the host name.
  }
  name = name?.trim() ?? '';
  if (name.isEmpty) {
    name = firstHostLabel((readHostName ?? () => Platform.localHostname)());
  }
  if (name.isEmpty) name = 'Mac';
  return truncateUtf8(name, maxHostNameBytes);
}

/// `MacBook-Pro.local` → `MacBook-Pro`; `host123.corp.example.com` →
/// `host123`. A bare name comes back as it is.
String firstHostLabel(String hostName) {
  final trimmed = hostName.trim();
  final dot = trimmed.indexOf('.');
  return dot <= 0 ? trimmed : trimmed.substring(0, dot);
}

/// [text] cut to at most [maxBytes] of UTF-8 without splitting a character.
/// Cutting the bytes themselves would leave half of a multi-byte character
/// (every Thai letter is three bytes) for the other side to show as "�".
String truncateUtf8(String text, int maxBytes) {
  if (utf8.encode(text).length <= maxBytes) return text;
  final out = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final size = utf8.encode(char).length;
    if (used + size > maxBytes) break;
    out.write(char);
    used += size;
  }
  return out.toString().trimRight();
}

Future<String?> _scutilComputerName() async {
  if (!Platform.isMacOS) return null;
  final result =
      await Process.run('/usr/sbin/scutil', const ['--get', 'ComputerName']);
  if (result.exitCode != 0) return null;
  return '${result.stdout}';
}
