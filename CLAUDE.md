# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

**extendedscreen** turns an Android tablet into a second monitor for macOS via USB-C. The macOS app (Flutter + Swift native plugins) captures the screen and streams H.264/H.265 over an ADB-reverse TCP tunnel; the Android app (same Flutter codebase, different platform role) decodes and renders frames while forwarding touch/keyboard input back. **Nothing is hardcoded to a specific tablet model**: the client reports its native panel size in the HELLO handshake and the host derives all capture/encode resolutions from the connected device. The Android client is landscape-locked (manifest + `SystemChrome` in `main()`).

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

# Run tests (no test/ directory exists yet; flutter test fails until one is added)
flutter test
```

## Architecture

### Dual-role Flutter app

The same Dart codebase runs on both sides of the link, but the role-specific code is split into separate folders (imports are `package:extendedscreen/...`):

- **`lib/shared/`** — used by both roles: `models/`, `protocol/`, `services/` (logger, settings, translations), `connection/` (`socket_service`, `connection_state`, and the abstract `BaseConnectionManager`), `platform/` (`permissions_channel`), and shared `widgets/`.
- **`lib/host/`** — macOS only: `platform/` (`screen_capture_channel`, `input_inject_channel`), `connection/` (`adb_service`, `HostConnectionManager`).
- **`lib/client/`** — Android only: `platform/` (`video_decoder_channel`), `connection/` (`ClientConnectionManager`).
- **`lib/features/`** — shared UI shells (splash, home, display, settings) that depend on `BaseConnectionManager` and shared widgets.

Roles:

- **Host (macOS):** runs `adb reverse`, starts a TCP server, captures the screen via `ScreenCapturePlugin` (Swift/ScreenCaptureKit), encodes with VideoToolbox (H.264 or H.265/HEVC selectable), and streams `FRAME_DATA` packets. Injects touch/mouse/key events received from the tablet via `InputInjectPlugin`.
- **Client (Android):** dials into the ADB-reverse tunnel, decodes H.264/H.265 frames (via `VideoDecoderChannel`), renders them in `DisplayView`, and forwards user input back as packets.

### State management — GetX

`SettingsService` is constructed and `await settings.init()`-ed in `main()` **before** `runApp` so the persisted UI language is available when `GetMaterialApp` reads `locale` at first build; `InitialBinding` only registers it if not already registered. All other services are registered as `GetxService`/permanent singletons in `InitialBinding`, which inspects the platform and registers either `HostConnectionManager` or `ClientConnectionManager` **bound to the `BaseConnectionManager` type** (`Get.put<BaseConnectionManager>(...)`) — so shared UI depends on a single interface. Controllers are scoped to routes via per-feature `*Binding` classes (`HomeBinding`, `DisplayBinding`, etc.).

### Localization (`lib/shared/services/app_translations.dart`)

All user-facing strings are GetX translation keys resolved with `.tr` (or `.trParams({'name': value})` for `@name` interpolation) against `AppTranslations`, which holds `en` and `th` maps. **Never hard-code UI strings** — add a key to both locale maps. This applies to enum label extensions too (`ConnectionPhaseX.label`, `EncodePresetX.label/tagline/description`, permission item labels), which resolve the active locale at read time. `fallbackLocale` is `en`. The saved language (or device language: Thai if the system is Thai, else English) is resolved in `SettingsService.init()`; `SettingsService.setLocale()` persists the code and calls `Get.updateLocale()`.

### Connection lifecycle (`lib/shared/connection/`, `lib/host/connection/`, `lib/client/connection/`)

`BaseConnectionManager` owns the shared phase/latency observables, the packet loop with heartbeat handling, the reconnect timer, and input-send helpers. It exposes abstract `connect()`/`autoConnect()`/`changeMode()` hooks and overridable `onRolePacket()`/`onTeardown()` callbacks. `HostConnectionManager` and `ClientConnectionManager` implement the role specifics. The happy-path phase sequence is:
`disconnected → detectingDevice → adbConnecting → portForwarding → handshaking → configuring → streaming`
(plus `paused` and `error`; `isActive` covers streaming *and* paused).

On error it schedules a 5-second reconnect automatically. `SocketService` owns the raw TCP socket; `AdbService` wraps `adb` CLI calls. The **macOS host is the sole settings/control surface**: display mode, encode preset and codec are editable only on the host (the client's Settings page is read-only). Every setting change persists the value and then calls `reconnect()` (full disconnect + reconnect to the same device) so the capture/encode pipeline restarts with the new value; the host announces the active codec to the client via a `0xFC` control packet so its decoder reinitializes.

On the host, every connect attempt is gated by `HomeController._ensureHostPermissions()`: if Screen Recording or Accessibility is missing, it snackbars and navigates to Settings with `arguments: {'scrollTo': 'permissions'}` (the settings view scrolls to its Permissions section via a `GlobalKey`) instead of failing mid-handshake.

### Packet protocol (`lib/shared/protocol/packet_codec.dart`)

Binary framing: 4-byte magic `EXTD` + 1-byte type + 4-byte payload length + 8-byte timestamp (µs) + payload. Packet types: `FRAME_DATA`, `TOUCH_EVENT`, `MOUSE_EVENT`, `KEY_EVENT`, `HEARTBEAT`, `CONTROL`. Control sub-commands: `0x01` (client HELLO: version + platform + native panel size as two uint16 BE, physical px landscape), `0xFF` (request IDR), `0xFE` (reload/resume decode), `0xFD+mode` (change display mode), `0xFC` (announce codec), `0xFB` (announce refresh rate), `0xFA` (sync overlay/HUD toggles). The host waits (3 s timeout) for the HELLO before starting capture and persists the reported panel via `SettingsService.setClientPanel()`.

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

Persisted via `shared_preferences`: display mode, last paired device serial, encode preset (plus custom width/height/bitrate/refresh for the `custom` preset), codec (`h264`/`h265`), UI locale (`en`/`th`), performance/HUD overlay toggles. The target device serial can also be injected at build time via `--dart-define=DEVICE_SERIAL=<serial>` (default is baked in). Secure storage (`flutter_secure_storage`) is available for pairing tokens/TLS certs.

### Encode presets (`lib/shared/models/display_config_model.dart`)

`EncodePreset` bundles resolution + scale factor + bitrate + refresh rate into four presets: `quality`, `balanced`, `performance`, and `custom` (user-adjustable values persisted in settings); there is no separate frame-rate setting. Fixed-preset resolutions are **relative to the connected client's panel** (read from `SettingsService.clientPanelWidth/Height`): logical size is always panel ÷ 2; `scaleFactor` 2.0 (quality/balanced) encodes at native panel resolution, 1.0 (performance) at half. The Swift `startCapture` multiplies logical × `scaleFactor` (clamped to even dims); `CGVirtualDisplay` is always created at logical × 2 (HiDPI). `HostConnectionManager._startCapture()` reads the active preset and applies the values to `DisplayConfigModel` at once.
