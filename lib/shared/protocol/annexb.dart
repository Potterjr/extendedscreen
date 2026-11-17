import 'dart:typed_data';

/// True when [au], one encoded frame as an Annex-B buffer, can start a
/// decoder: H.264 SPS or IDR, HEVC VPS/SPS/PPS or an IRAP slice. Same rule as
/// `isKeyframeAccessUnit` in `VideoDecoderPlugin.kt`.
///
/// The scan stops at the first slice, so on an ordinary frame it reads only a
/// few bytes: keyframes carry their parameter sets in front, other frames
/// start with the slice itself.
bool isKeyframeAccessUnit(Uint8List au, {required bool hevc}) {
  final n = au.length;
  var i = 0;
  while (i + 3 < n) {
    // A NAL unit starts after 00 00 01 (a four-byte start code ends the same).
    if (au[i] != 0 || au[i + 1] != 0 || au[i + 2] != 1) {
      i++;
      continue;
    }
    final header = au[i + 3];
    if (hevc) {
      final type = (header >> 1) & 0x3F;
      if (type >= 32 && type <= 34) return true; // VPS, SPS, PPS
      if (type >= 16 && type <= 23) return true; // IRAP slice
      if (type < 32) return false; // any other slice
    } else {
      final type = header & 0x1F;
      if (type == 7 || type == 5) return true; // SPS, IDR slice
      if (type >= 1 && type <= 4) return false; // non-IDR slice
    }
    i += 4;
  }
  return false;
}
