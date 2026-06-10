# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

**extendedscreen** turns a Samsung Galaxy Tab S10 Ultra into a second monitor for macOS via USB-C. The macOS app (Flutter + Swift native plugins) captures the screen and streams H.264/H.265 over an ADB-reverse TCP tunnel; the Android app (same Flutter codebase, different platform role) decodes and renders frames while forwarding touch/keyboard input back.

## Commands

```bash
# Run on macOS (override target device serial at build time if needed)
flutter run -d macos --dart-define=DEVICE_SERIAL=<serial>

# Run on connected Android device
flutter run -d <device-id>

# Build macOS release
flutter build macos

# Analyze / lint
flutter analyze

# Run tests
flutter test

# Run a single test file (example)
flutter test test/core/connection/connection_manager_test.dart
```

## Architecture

### Dual-role Flutter app

The same Dart codebase runs on both sides of the link, but the role-specific code is split into separate folders (imports are `package:extendedscreen/...`):

- **`lib/shared/`** — used by both roles: `models/`, `protocol/`, `services/` (logger, settings), `connection/` (`socket_service`, `connection_state`, and the abstract `BaseConnectionManager`), `platform/` (`permissions_channel`), and shared `widgets/`.
- **`lib/host/`** — macOS only: `platform/` (`screen_capture_channel`, `input_inject_channel`), `connection/` (`adb_service`, `HostConnectionManager`).
- **`lib/client/`** — Android only: `platform/` (`video_decoder_channel`), `connection/` (`ClientConnectionManager`).
- **`lib/features/`** — shared UI shells (splash, home, display, settings) that depend on `BaseConnectionManager` and shared widgets.

Roles:

- **Host (macOS):** runs `adb reverse`, starts a TCP server, captures the screen via `ScreenCapturePlugin` (Swift/ScreenCaptureKit), encodes with VideoToolbox (H.264 or H.265/HEVC selectable), and streams `FRAME_DATA` packets. Injects touch/mouse/key events received from the tablet via `InputInjectPlugin`.
- **Client (Android):** dials into the ADB-reverse tunnel, decodes H.264/H.265 frames (via `VideoDecoderChannel`), renders them in `DisplayView`, and forwards user input back as packets.

### State management — GetX

Services are registered as `GetxService`/permanent singletons in `InitialBinding`, which inspects the platform and registers either `HostConnectionManager` or `ClientConnectionManager` **bound to the `BaseConnectionManager` type** (`Get.put<BaseConnectionManager>(...)`) — so shared UI depends on a single interface. Controllers are scoped to routes via per-feature `*Binding` classes (`HomeBinding`, `DisplayBinding`, etc.).

### Connection lifecycle (`lib/shared/connection/`, `lib/host/connection/`, `lib/client/connection/`)

`BaseConnectionManager` owns the shared phase/latency observables, the packet loop with heartbeat handling, the reconnect timer, and input-send helpers. It exposes abstract `connect()`/`autoConnect()`/`changeMode()` hooks and overridable `onRolePacket()`/`onTeardown()` callbacks. `HostConnectionManager` and `ClientConnectionManager` implement the role specifics. The phase observable runs through:
`disconnected → detectingDevice → portForwarding → handshaking → configuring → streaming`

On error it schedules a 5-second reconnect automatically. `SocketService` owns the raw TCP socket; `AdbService` wraps `adb` CLI calls. The Android client is the sole settings/control surface — it sends its desired mode/preset/codec in the HELLO handshake, and the host adopts that config before capturing.

### Packet protocol (`lib/shared/protocol/packet_codec.dart`)

Binary framing: 4-byte magic `EXTD` + 1-byte type + 4-byte payload length + 8-byte timestamp (µs) + payload. Packet types: `FRAME_DATA`, `TOUCH_EVENT`, `MOUSE_EVENT`, `KEY_EVENT`, `HEARTBEAT`, `CONTROL`. Control sub-commands: `0xFF` (request IDR), `0xFE` (reload/resume decode), `0xFD+mode` (change display mode).

### Native macOS plugins (`macos/Runner/`)

| File | Purpose |
|---|---|
| `ScreenCapturePlugin.swift` | ScreenCaptureKit capture → VideoToolbox H.264/H.265 encode → `FlutterEventChannel` frame stream. Also manages `CGVirtualDisplay` (Extend mode). Requires macOS 12.3+. |
| `InputInjectPlugin.swift` | Injects mouse/keyboard events via CGEvent APIs. Requires Accessibility permission. |
| `AdbManagerPlugin.swift` | Wraps `adb` binary calls (`devices`, `reverse`, `forward --remove`). |
| `PermissionsPlugin.swift` | Checks/requests macOS permissions (Screen Recording, Accessibility) and exposes them to Dart via `MethodChannel`. |
| `SocketSender.swift` | (legacy/alternative) NWConnection TCP sender; main path now goes through `SocketService` on the Dart side. |

### Display modes

- **Extend:** Creates a `CGVirtualDisplay` matching the tablet resolution; ScreenCaptureKit captures that virtual display exclusively.
- **Mirror:** Captures the main display directly; no virtual display created.

Mode changes while streaming call `reapplyCapture()` which tears down and restarts the capture pipeline, then sends `0xFE` to the client to request a fresh IDR frame.

### Key settings (`lib/shared/services/settings_service.dart`)

Persisted via `shared_preferences`: FPS, display mode, last paired device serial, encode preset, codec (`h264`/`h265`). The target device serial can also be injected at build time via `--dart-define=DEVICE_SERIAL=<serial>` (default is baked in). Secure storage (`flutter_secure_storage`) is available for pairing tokens/TLS certs.

### Encode presets (`lib/shared/models/display_config_model.dart`)

`EncodePreset` bundles resolution + scale factor + bitrate + refresh rate into three named presets (`quality`, `balanced`, `performance`); there is no separate frame-rate setting. `HostConnectionManager._startCapture()` reads the active preset and applies the values to `DisplayConfigModel` at once. The logical width/height passed to `CGVirtualDisplay` are half the physical pixels when `scaleFactor` is 2.0 (HiDPI path).
