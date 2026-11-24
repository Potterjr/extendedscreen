# extendedscreen roadmap

State as of 2026-11-24: main has multi-tablet phases 0–5 core, the iOS client spike, Wi-Fi beside USB, the Wi-Fi listener, per-device settings, and (since the commit after `aa61bfb`) Mac controls iPhone over USB, the redesigned Home and the first two latency units. The release of `aa61bfb` is installed in /Applications. Windows work starts from `docs/windows-start.md`.

Legend: ✅ built and tested on real devices · 🟡 code exists, not tried on a real device · ❌ not built · ➖ out of scope (the OS does not allow it)

## 1. The goal

Every device can be the source or the target, for both features.

- **Extended Screen**: the source's desktop gains another display, shown on the target.
- **Remote Control**: the controller sees the target's screen and drives it.

Decided 2026-11-24: an iPhone or iPad is never the source of an Extended Screen. iOS has no API that lets an app add a display for the whole system, only mirroring, which is viewing, not extending. Those cells are out of scope.

## 2. Status matrix

### Extended Screen (source → target display)

| Source | → Mac | → Windows | → iPhone | → iPad | → Android |
|---|---|---|---|---|---|
| Mac | – | ❌ no Windows client | ✅ Wi-Fi | 🟡 platform `0x04` handled, never tried on an iPad | ✅ USB and Wi-Fi, several at once |
| Windows | ❌ | – | ❌ | ❌ | ❌ |
| iPhone / iPad | ➖ | ➖ | ➖ | ➖ | ➖ |
| Android | ❌ | ❌ | ❌ | ❌ | – |

### Remote Control (controller → controlled target)

| Controller | → Mac | → Windows | → iPhone | → iPad | → Android |
|---|---|---|---|---|---|
| Mac | – | ❌ | 🟡 USB, built (see §4); not yet tried in the app on a real device | 🟡 same code as iPhone, never tried | ✅ USB only (adb input) |
| Windows | ❌ | – | ❌ | ❌ | ❌ |
| iPhone | ✅ Wi-Fi | ❌ | – | ❌ | ❌ |
| iPad | 🟡 same code as iPhone | ❌ | ❌ | – | ❌ |
| Android | ✅ USB and Wi-Fi | ❌ | ❌ | ❌ | – |

Every working cell has the Mac at the centre. Nothing works between two non-Mac devices yet.

## 3. What each OS allows

| | Can be an Extended Screen source | Can be controlled (input from outside) | Screen capture for viewing |
|---|---|---|---|
| Mac | ✅ `CGVirtualDisplay` (private API, in use) | ✅ CGEvent (in use) | ✅ ScreenCaptureKit (in use) |
| Windows | ✅ with an Indirect Display Driver (IddCx; a signed driver) | ✅ `SendInput` | ✅ Desktop Duplication / Windows.Graphics.Capture |
| Android | ⚠️ only with shell privileges (adb), as scrcpy's new-display mode does | ✅ adb `input` (in use, USB); without adb an AccessibilityService (`dispatchGesture`, user enables it once) | ✅ MediaProjection (in use) |
| iPhone / iPad | ➖ no API | ⚠️ no API: XCUITest (WebDriverAgent-style runner: Developer Mode, signed on a Mac, free team expires in 7 days) or a BLE HID mouse board with AssistiveTouch | ✅ ReplayKit Broadcast Extension (user starts it each time), or Apple's USB screen capture (QuickTime mode: AVFoundation on a Mac; on Windows only a reverse-engineered protocol over libusb) |

Every OS can be a viewer and controller: it decodes and sends input.

## 4. Mac controls iPhone over USB (prototype on macOS, later Windows): built, on main

The owner's choice is USB first, with a Mac prototype before Windows.

- **Picture**: Apple's USB screen capture, through AVFoundation with `kCMIOHardwarePropertyAllowScreenCaptureDevices`. No app is needed on the iPhone. It is shown on the Mac through the remote view, which already decodes into a texture.
  - Windows later: either the reverse-engineered capture protocol, or our own ReplayKit Broadcast Extension over usbmuxd.
  - The second option needs App Groups, so the extension can read the pairing. Check that the free team can sign it.
- **Input**: an XCUITest runner on the iPhone (WebDriverAgent-style HTTP server) reached through usbmuxd (`iproxy` on a Mac; go-ios on Windows).
  - It sends taps and swipes at absolute points, with about 100 ms of latency.
  - It needs Developer Mode, and signing on a Mac every 7 days on the free team.
- **Risks**: the runner breaks with iOS updates; the AVFoundation device shows up only while the phone is unlocked and trusted.
- **Spike results (2026-11-24, iPhone 18 Pro Max, iOS 27.0.1, Xcode 27.0):**
  - Picture: ✅ AVFoundation USB capture gives 1320×2868 portrait at ~53 fps while the screen changes (nothing when it is still). It needs the Camera permission (an app with `NSCameraUsageDescription`; a bare command-line tool is denied without a prompt).
  - Taps: ✅ an XCUITest runner (`~/Developer/es-touchrunner`: UI-test target `TouchRunner` plus a blank host app `TouchHost`, free team) listens on TCP 8100 on the phone. It is reached through usbmuxd (`Connect` to port 8100; a ping round trip is 31 ms), and it taps with `XCUICoordinate.tap()`, at about 700 ms per tap (XCTest waits for the app to be idle). Faster needs XCTest's private event synthesis, as WebDriverAgent does (expected 50–100 ms).
  - Fast taps: ✅ synthesized straight through XCTest's event synthesizer (private `XCPointerEventPath`/`XCSynthesizedEventRecord`, `XCUIDevice.eventSynthesizer`, WebDriverAgent-style, in `FastTouch.m`). A tap that waits for XCTest's completion takes ~250 ms; sending without waiting returns in ~2 ms. **End to end (command sent on the Mac → change visible in the USB capture on the Mac): 109–129 ms for a swipe.** Capture and usbmuxd work at the same time (the phone drops off usbmuxd for a moment when capture starts). The screen must be on: a locked or dark phone sends no frames.
  - Launching the runner: ❌ `xcodebuild test-without-building` fails on this device with "Root install style is not supported" (six variations tried). ✅ Run from Xcode's window (the test's gutter button) it works. Windows will need go-ios or similar to start it (testmanagerd).
- **Integrated into the app (2026-11-24, on main)**, a path apart from the tablets' hub, sessions and protocol (CLAUDE.md, *iPhone over USB*):
  - `macos/Runner/IosScreenPlugin.swift` (channel `extended_screen/ios_screen`): the AVFoundation USB capture straight into a Flutter texture, no encode or decode. `NSCameraUsageDescription` in `Info.plist` and the camera entitlement in both entitlements files.
  - `lib/shared/connection/usbmux.dart`: `UsbmuxClient` (ListDevices, Connect) with a small XML plist codec of its own. Tried against the real usbmuxd and the running runner: a ping in 2 ms.
  - `IosTouchService`: taps and swipes to the runner on port 8100 through usbmuxd, as `atap`/`aswipe` (answered at once), with the blocking `tap`/`swipe` for a runner without fast synthesis or built before `aswipe`; `orient` for landscape, cached (plan unit L1: asked on connect, on a landscape frame-size change and after each landscape gesture, never on a touch's way; checked by tests only, the device pass bar is landscape felt click p50 at least 10 ms under the M0a baseline).
  - The runner moved into the repo at `ios/TouchRunner/` (its own Xcode project, apart from Flutter's `ios/Runner`), with `atap` and `aswipe` added.
  - `/iphone-remote` (`IphoneRemoteController`, `IphoneRemoteView`), opened from a phone icon in the Mac's Home bar: the picture, a click as a tap, a drag as a swipe, a long press held as long as it was (then dragged if moved), and the reason when it cannot work (no phone, no Camera permission, no runner), in English and Thai.
  - Checked: `test/iphone_usb_test.dart`, `flutter analyze` at the standing 14 warnings, `flutter build macos --debug`.
  - Not yet: the whole thing in the app on a real iPhone (the installed release in /Applications has to be quit first, which needs the owner's go-ahead); the landscape mapping on a real phone; the full test suite and a review; one phone only (the capture and the touches each take the first one they find).
- **Latency baseline (plan unit M0a, `docs/iphone-usb/plan.md`)**: the felt-latency probe is built (`--dart-define=IPHONE_PROBE=true`; CLAUDE.md, *iPhone over USB*, *Latency probe*): pointer-down → first changed capture frame on the Mac's one clock, plus scripted `atap`/`aswipe` trials, 50 per case, p50/p90. Checked by tests and `flutter build macos --debug` only; the numbers below are for the owner to fill in on the iPhone 18 Pro Max, Settings → General, today's gestures plus M0a, before any other unit. Every later latency or stability unit is judged against them.

  | Case | Portrait p50 / p90 (ms) | Landscape p50 / p90 (ms) |
  |---|---|---|
  | Scripted `atap` → change | – | – |
  | Scripted `aswipe` 0.15 → change | – | – |
  | Felt click → change | – | – |
  | Felt 1 s still press → change | – | – |
  | Felt 300 ms drag → change | – | – |

## 5. Structural work before the matrix can fill in

1. **Roles apart from the OS.** Today host = Mac and client = tablet/phone are fixed. Each device must be able to be a provider (capture, encode, accept input) and a viewer/controller (decode, display, send input). The wire already carries video both ways (reverse remote), so this is a refactor, not a new protocol.
2. **Pairing without adb or devicectl.** A QR code or numeric code exchange, so that iPhone↔Android or Windows↔iPad can pair with no Mac. Today pairing reaches a tablet through adb and an iPhone through devicectl, and both need a Mac.
3. **Windows app.** Flutter Windows with native parts:
   - capture + encode (Desktop Duplication + Media Foundation);
   - input injection (`SendInput`);
   - decode (Media Foundation into a texture);
   - later, an IddCx driver for the Extended Screen source.
4. **Android as provider without adb.** An AccessibilityService for input (MediaProjection capture exists already). An Extended Screen source on Android needs adb (scrcpy-style virtual display).
5. **iPhone/iPad as controlled target** (see §4 for the Mac path).

Suggested order:
1. §4, Mac controls iPhone over USB (built; try it in the app on the iPhone, then commit).
2. Roles + QR pairing.
3. Windows as viewer/controller, then as a provider, then the Extended Screen source with its driver.
4. Mobile devices as providers to each other.

## 6. Open work from earlier phases

### Multi-tablet phase 5, optional items
- [ ] `0xF1` tells a device why it was refused (needs a client build: iPhone yes; the Tab only once its app is updated).
- [ ] `0xF2` flashes a device's name.
- [ ] Fewer encodes for idle displays (Swift).
- [ ] `adb track-devices` in place of the 3 s poll.
- [ ] Menu-bar list of devices, with Disconnect each and all.
- [ ] A total Wi-Fi bitrate cap.

### Deferred from phase 4
- [ ] Standby: a USB session parked while the same tablet is on Wi-Fi. Needs the Tab's app updated so it sends the HELLO identity tail.
- [ ] Display grace period: an iPhone that switches apps keeps its virtual display for ~30 s, so windows don't jump to the MacBook.

### iOS client (docs/ios-client-design.md)
- [ ] P1: the app remembers the display arrangement per device combination (only if System Settings does not hold it).
- [ ] P2:
  - Keychain token store;
  - Local Network denied guidance;
  - thermal HUD warning;
  - compact layout;
  - wire-fixture tests;
  - dev-build isolation (own bundle id, port, vdSerial offset);
  - the real iPhones list in Settings in place of the debug card.
- [ ] P4:
  - gesture tuning for a 6.9-inch panel;
  - LayerSink vs TextureSink;
  - "Open on iPhone";
  - automatic re-pairing when the Mac's address changes.
- [ ] P5: iPhone over USB through usbmuxd. Overlaps §4.

### Known limitations (recorded in CLAUDE.md)
- [ ] An app-wide settings change restarts devices that override that setting with their own.
- [ ] Home's encoder load line and Settings' Encoder line name the app-wide codec.
- [ ] ÷2.5 and ÷3 look alike on small panels (macOS grows displays under 800×525 pt).
- [ ] A connection that never starts TLS cannot be closed by the Mac (dart:io); it holds a socket until the peer leaves.
- [ ] The old Wi-Fi-link host path (one `wifi` session with its own TLS server) is unreachable from the app but still in the code and its tests. Remove it.
- [ ] A Wi-Fi device with no install id (today's Tab build) is a new device on every connection: no remembered mode, no lasting stop.

### Not yet tried on real devices
- [ ] Mac controls Tab after phases 3–5 (needs the consent tap on the Tab).
- [ ] Any iPad, in every mode.
- [ ] Mac controls iPhone over USB (§4) in the app: picture, taps, swipes, long press, landscape.
- [ ] The Tab over Wi-Fi beside the iPhone (several Wi-Fi devices at once on real hardware).

### Upkeep
- [ ] Update the Tab's app to a current build (needs the owner's go-ahead) to get the identity tail.
- [ ] Reinstall the iPhone app every 7 days (free team); last install 2026-11-24, next by about 2026-12-01.
