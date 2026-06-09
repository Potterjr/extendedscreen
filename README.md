# extendedscreen

Turn a Samsung Galaxy Tab S10 Ultra into a wireless-free second monitor for macOS over USB-C. The Mac captures its screen, H.264-encodes it, and streams it to the tablet through an ADB-reverse TCP tunnel. Touch and keyboard input on the tablet is injected back into macOS in real time.

## Requirements

| Side | Requirement |
|---|---|
| macOS | macOS 12.3+, ADB in PATH, Screen Recording permission, Accessibility permission |
| Android | Samsung Galaxy Tab S10 Ultra (or any Android device with USB debugging enabled) |
| Cable | USB-C connecting Mac to tablet |

## Setup

1. Enable USB debugging on the tablet (Developer Options → USB debugging).
2. Connect via USB-C and confirm the ADB device is visible:
   ```bash
   adb devices
   ```
3. Run both sides (see below). The Mac starts a TCP server; the tablet dials in through the ADB-reverse tunnel automatically.

## Running

```bash
# Mac (host — captures screen, streams frames)
flutter run -d macos

# Tablet (client — decodes and renders)
flutter run -d <device-serial>

# Run both at once (VS Code compound launch)
# Select "macOS + Tab S10 Ultra (both)" in the Run panel
```

On first launch, macOS will prompt for **Screen Recording** and **Accessibility** permissions. Grant both; the stream starts automatically once permissions are accepted.

## Settings

| Setting | Default | Description |
|---|---|---|
| Display mode | Extend | `Extend` creates a virtual display; `Mirror` duplicates the main display |
| FPS | 60 | Encode frame rate |
| Bitrate | 15 Mbps | H.264 target bitrate |

Settings persist across launches via `shared_preferences`. The tablet serial defaults to `R52XC02C9RT` at compile time; override with `--dart-define=DEVICE_SERIAL=<serial>`.

## How it works

```
Mac                                     Tablet
────────────────────────────────────────────────────────
ScreenCaptureKit → VideoToolbox H.264
      │  FRAME_DATA packets
      ▼  (TCP over adb reverse :7001)
                                   H.264 decode (MediaCodec)
                                         │
                                   DisplayView (SurfaceTexture)

Touch/key events ◄──────────────────────┘
(CGEvent injection)
```

**Extend mode** — `ScreenCapturePlugin` creates a `CGVirtualDisplay` matching the tablet resolution. ScreenCaptureKit captures that virtual display exclusively, so moving a window to the second monitor streams only that content.

**Mirror mode** — captures the primary display directly; no virtual display is created.

Mode changes while streaming tear down and restart the capture pipeline, then send a `0xFE` control packet so the tablet requests a fresh IDR frame.

## Packet protocol

Binary framing over TCP:

```
[ 4 bytes magic "EXTD" | 1 byte type | 4 bytes payload length | 8 bytes timestamp µs | payload ]
```

| Type | Direction | Purpose |
|---|---|---|
| `FRAME_DATA` | Mac → Tablet | H.264 NAL unit |
| `TOUCH_EVENT` | Tablet → Mac | Pointer events |
| `MOUSE_EVENT` | Tablet → Mac | Mouse events |
| `KEY_EVENT` | Tablet → Mac | Key events |
| `HEARTBEAT` | Both | RTT latency measurement |
| `CONTROL` | Both | Mode changes, IDR requests |

## Build

```bash
flutter build macos          # release .app
flutter analyze              # lint
flutter test                 # unit tests
```
