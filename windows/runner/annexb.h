#ifndef RUNNER_ANNEXB_H_
#define RUNNER_ANNEXB_H_

#include <cstddef>
#include <cstdint>

// True when `au`, one encoded frame as an Annex-B buffer, can start a
// decoder: H.264 SPS or IDR, HEVC VPS/SPS/PPS or an IRAP slice. The same
// rule as `isKeyframeAccessUnit` in VideoDecoderPlugin.kt and
// lib/shared/protocol/annexb.dart. The scan stops at the first slice.
inline bool IsKeyframeAccessUnit(const uint8_t* au, size_t n, bool hevc) {
  size_t i = 0;
  while (i + 3 < n) {
    if (au[i] != 0 || au[i + 1] != 0 || au[i + 2] != 1) {
      i++;
      continue;
    }
    const uint8_t header = au[i + 3];
    if (hevc) {
      const int type = (header >> 1) & 0x3F;
      if (type >= 32 && type <= 34) return true;  // VPS, SPS, PPS
      if (type >= 16 && type <= 23) return true;  // IRAP slice
      if (type < 32) return false;                // any other slice
    } else {
      const int type = header & 0x1F;
      if (type == 7 || type == 5) return true;  // SPS, IDR slice
      if (type >= 1 && type <= 4) return false;  // non-IDR slice
    }
    i += 4;
  }
  return false;
}

#endif  // RUNNER_ANNEXB_H_
