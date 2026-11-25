# extendedscreen roadmap

State as of 2026-11-25: main has multi-tablet phases 0–5 core, the iOS client spike, Wi-Fi beside USB, the Wi-Fi listener, per-device settings, Mac controls iPhone over USB (first cut), the redesigned Home and the first two latency units (M0a, L1). Uncommitted in worktree `beside`: the rest of the iPhone latency work (S1a, L4, L2, L3, F1, review fixes) and the native remote window. Windows work goes on separately from `docs/windows-start.md`.

Legend: ✅ built and tested on real devices · 🟡 code exists, not tried on a real device · ❌ not built · ➖ out of scope (the OS does not allow it)

## Status at a glance (2026-11-25)

### Done
- **On main:** multi-tablet phases 0–5 core (several tablets over USB, a mode per device, encode budget), the iOS client over Wi-Fi, Wi-Fi beside USB, Mac controls iPhone over USB (first cut), the redesigned Home, latency units M0a (probe) and L1 (cached orientation).
- **Uncommitted in `beside`, checked on the iPhone 18 Pro Max:**
  - iPhone touch-link stability (S1a), pointer state machine with long press while held (L4), runner release 1 installed on the phone (L2), live drag in segments (L3), system buttons and ⌘1–⌘5 (F1), and the review fixes;
  - the native remote window for the iPhone: its own AppKit window, phone-shaped, buttons in the title bar, picture drawn without Flutter, closing it ends the session; the Flutter `/iphone-remote` route is removed;
  - measured: an instant click p50 185 ms / p90 202 ms, the owner's clicks p50 296 ms (press time included), opening Settings 75 ms;
  - E1 answered: XCTest cannot hold a finger across records or overlap them, so a press at mouse-down needs another input path (`docs/iphone-usb/latency-options.md`).

### In progress
- **Android remote in the native window** (`docs/iphone-usb/android-window-plan.md`): the Mac-views-tablet remote moved from the `/remote-host` grid to one native window per tablet (`TabletRemoteWindow`, opened by `TabletWindowOpener` when the session goes live, closing it disconnects that tablet with `userStopped`). Units 1–5 built and reviewed; the `/remote-host` route, the `RemoteHost` grid feature (`RemoteHostView`/`RemoteGridController`/`RemoteTile`) and its tests were removed on 2026-11-25 (unit 7). The hub's focused-session remote facade is kept, since `multi_remote_test.dart` and `tablet_screen_off_test.dart` still exercise it. Device check (unit 6) on the read-only AVD still to run.
- **Commit** of everything in `beside` once the Android window passes its device check (the owner is asked first).

### Next
1. A one-minute check of Xcode Device Hub's View Screen, then, if a click presses at mouse-down there, a spike of the CoreDevice HID (`dtuhidd`) input backend for live touches like iPhone Mirroring.
2. Pick the iPhone window's picture layer and remove the other; check landscape and rotation.
3. Scroll wheel and trackpad on the iPhone (F2), then the rest of the Mirroring parity units (C1, S1b, F6, F3, F5, F7, F8, F9, F4).
4. Roles apart from the OS and QR pairing (§5), then Windows (on its own branch).

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
| Mac | – | ❌ | ✅ USB, native window (tried 2026-11-25; landscape not yet) | 🟡 same code as iPhone, never tried | ✅ USB only (adb input); native window per tablet, `/remote-host` route removed 2026-11-25 |
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

## 4. Mac controls iPhone over USB (prototype on macOS, later Windows): the first cut on main; S1a, L4, L2, L3, F1, M0a and the native window uncommitted in worktree `beside`

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
  - `macos/Runner/IosScreenPlugin.swift` (channel `extended_screen/ios_screen`): the AVFoundation USB capture straight into a Flutter texture, no encode or decode (since 2026-11-25 into the native window only; the texture is gone with the route). `NSCameraUsageDescription` in `Info.plist` and the camera entitlement in both entitlements files.
  - `lib/shared/connection/usbmux.dart`: `UsbmuxClient` (ListDevices, Connect) with a small XML plist codec of its own. Tried against the real usbmuxd and the running runner: a ping in 2 ms.
  - `IosTouchService`: taps and swipes to the runner on port 8100 through usbmuxd, as `atap`/`aswipe` (answered at once), with the blocking `tap`/`swipe` for a runner without fast synthesis or built before `aswipe`; `orient` for landscape, cached (plan unit L1: asked on connect, on a landscape frame-size change and after each landscape gesture, never on a touch's way; checked by tests only, the device pass bar is landscape felt click p50 at least 10 ms under the M0a baseline).
  - The runner moved into the repo at `ios/TouchRunner/` (its own Xcode project, apart from Flutter's `ios/Runner`), with `atap` and `aswipe` added.
  - `/iphone-remote` (`IphoneRemoteController`, `IphoneRemoteView`; the route was removed on 2026-11-25 for the native window, below), opened from a phone icon in the Mac's Home bar: the picture, a click as a tap, a drag as a swipe, a long press sent while held (L4; Shift for hold-then-drag), and the reason when it cannot work (no phone, no Camera permission, no runner), in English and Thai.
  - Checked: `test/iphone_usb_test.dart`, `flutter analyze` at the standing 14 warnings, `flutter build macos --debug`.
  - Not yet: the whole thing in the app on a real iPhone (the installed release in /Applications has to be quit first, which needs the owner's go-ahead); the landscape mapping on a real phone; the full test suite and a review; one phone only (with two attached, touches are refused until the capture uniqueID to UDID mapping is known, plan unit S1a).
- **Touch-link stability (plan unit S1a, `docs/iphone-usb/plan.md`)**: built, checked by tests, `flutter analyze` and `flutter build macos --debug` only; the runner is unchanged. `UsbmuxClient.listen()` (usbmuxd's `Listen`: Attached/Detached on one long-lived connection, framed across chunks, reopened when usbmuxd restarts); the touch link connects when the phone is Attached and the first frame has come, whichever is later, and again at once on each Attached (the 2 s tick stays as a fallback, now only once a frame has come); the app bar chip shows the link state (connected, reconnecting, no runner, runner refused, several phones, no phone) and dropped commands are counted and logged; touches are refused while more than one iOS device is attached on either side; `IosScreenChannel.prepare()` as the iPhone view opens, with a quick relist after a fresh allow; the capture's uniqueID and the usbmux UDID logged side by side (`pairing … same=`). Device check still to do on the iPhone 18 Pro Max: touches-off time after the first picture ≤ 200 ms (today about 1-2 s), unplug and replug → touches back ≤ 1 s after the picture, and uniqueID vs UDID written down in `docs/iphone-usb/`.
- **Pointer state machine (plan unit L4, `docs/iphone-usb/plan.md`)**: built, checked by tests and `flutter analyze` only; the runner is unchanged. The picture is one `Listener` feeding a state machine in `IphoneRemoteController` (no gesture arena, no 500 ms long-press timeout): a click within the touch slop (18 of the phone's points, scaled to the picture) is an `atap` at release; a drag past it an `aswipe` at release (≤ 0.3 s replay, until L3); a still press sends a 0.7 s long press at 350 ms while the button is held, and nothing after it, with the next gesture waiting for it to play; Shift at pointer-down keeps the release-time hold-then-drag (moving an icon). An experimental E1 mode (`--dart-define=IPHONE_LIVE_FINGER=true`: `pdown`/`pmove`/`pup`) is off and falls back by itself on today's runner. Device check still to do: a Home Screen icon's menu opens while the Mac button is held, felt p50 ≤ 500 ms after pointer-down; felt click p50 not worse than the M0a baseline; Shift-hold-drag moves an icon; a jittery click on a small button taps it.
- **Runner release 1 (plan unit L2, `docs/iphone-usb/plan.md`)**: built in the repo, checked by `xcodebuild build` of the TouchRunner target for a generic iOS device (no install), tests and `flutter analyze`; installed on the phone from Xcode on 2026-11-25 and answering (`caps` lists every new verb). Runner: `TCP_NODELAY`; lines read and parsed on a serial `runner.net` queue, XCTest work on main one command at a time, answers in command order; `synth done <ms>` logged for async touches; records made with the display-ID initializer where XCTest has it; new verbs `caps`, `orient` with its source (the frontmost app's interface orientation, else SpringBoard's, else the physical one), `seg` (L3's drag segment, answered once played), `switcher`/`spotlight`/`control`/`notifications` (F1, in the interface orientation's frame), and experimental `pdown`/`pmove`/`pup`/`scroll`/`key`/`pastetest` (E1 to E3). Mac: `IosTouchService` asks `caps` once per connection and enables features from it (`supports`); a runner without `caps` keeps today's feature set and fallbacks; `orientSource` records what each `orient` answer was read from. Device check still to do: scripted `atap` → change p90 not worse than the baseline with `orient` interleaved (N=50); `home` then at once `atap` answers both, in order; `caps` lists every new verb; `orient` with rotation lock on in a landscape-only app answers the app's orientation (source `app`).
- **Live drag (plan unit L3, `docs/iphone-usb/plan.md`)**: built, checked by tests and `flutter analyze` only; no runner change (release 1's `seg` is what it uses, so it waits for that runner on the phone; today's runner has no `seg` in `caps` and keeps the release-time `aswipe`). A drag past the slop streams while the button is held as `seg` segments (`DragStreamer`): the first 100 ms after the slop, at least 15 pt each, one in flight, played in at most 0.12 s, 0.07 s still before each mid-drag lift, put down 12 pt back along the segment; the last at release carries the release velocity and no settle. A drag let go within 100 ms is one `aswipe` as before. Settings → Input → "Live drags on the iPhone" (on by default) turns it off. Device check still to do: felt drag pointer-down → first change p50 ≤ 250 ms; a slow 300 pt drag in Settings moves the list within 15% of the mouse's distance (screen recording); a slow 1 cm/s drag scrolls continuously with no cell selected; a fast flick still glides; the Control Center brightness slider and a sheet pulled down slowly (note any snap-back); tune lead (12 pt), settle (70 ms), minimum length (15 pt), first-segment delay (100 ms) and play cap (0.12 s) and write them here.
- **System shortcuts (plan unit F1, `docs/iphone-usb/plan.md`)**: built, checked by tests and `flutter analyze` only; no runner change (release 1 already has `switcher`, `spotlight`, `control` and `notifications`, with the edges picked in the interface orientation, so the gestures wait for that runner on the phone; today's runner has none of them in `caps` and their buttons stay greyed out, Home still works). The iPhone view's title bar has App Switcher, Spotlight, Control Center and Notification Center buttons beside Home, and ⌘1 Home, ⌘2 App Switcher, ⌘3 Spotlight, ⌘4 Control Center (iPhone Mirroring's, the last on macOS 27+) and ⌘5 Notification Center (ours) while the view has the keyboard focus; the Mac menus bind no ⌘-digit. Device check still to do on the iPhone 18 Pro Max, from the Home Screen and inside an app, portrait and a landscape app on both sides: App Switcher opens (not Home), Control Center, Notification Center and Spotlight open.
- **Review fixes to S1a, L4, L2, L3 and F1 (uncommitted in worktree `beside`)**: checked by tests, `flutter analyze` and `xcodebuild build` of the TouchRunner target only. One record on the phone at a time across gestures, not only within a drag (the controller's turns, `_Turn`: a gesture's first record, Home and a system gesture wait for the last one to have played; they replace `_holdUntil`); a press that begins while the last one's release still waits no longer has its gesture ended by it (`_openGestures`, a count), so no `orient` lands mid-drag (post-gesture `orient`s are not throttled: the refresh after each landscape gesture is what catches a flip, so the runner's new `orient` time is to be measured first); live drags only with fast synthesis; a flick let go just as a segment went out still flings; ⌘1 to ⌘5 ignore key repeats and every Home or system gesture is ignored while one runs (`systemBusy`); the Mac's wait for an answer runs at least until the answers ahead of it are due (the runner answers in order), so an `atap` behind a slow `seg` or `spotlight` no longer drops the link; a Detached of the phone a connect is opening a stream to gives that connect up, an Attached heard during a connect is posted again once it fails, and a connect failing within 10 s of a drop reads `reconnecting`, not "runner missing". Runner (backward compatible: new answer fields only): a `whenDone` verb's deadline counts from when it reaches main, with a log line when it waited over 50 ms; `orient` skips SpringBoard's pid among the active applications and answers `orient <raw> <source> pid=<n> <ms>` (the Mac logs one over 50 ms). L4's long-press bar is restated (the menu opens about 1 s after pointer-down, iOS needing ~0.5 s of contact; the probe's ~460 ms is the icon dimming) and L3's device check adds press-pause-drag cases; `segFirstAfter` is the first value to tune if L3's 250 ms first-change bar is missed. Not done: a press that pauses 350 ms before it moves is still a long press with no drag (documented; a follow-up drag as a new touch would land on whatever the hold opened).
- **Latency baseline (plan unit M0a, `docs/iphone-usb/plan.md`)**: the felt-latency probe is built (`--dart-define=IPHONE_PROBE=true`; CLAUDE.md, *iPhone over USB*, *Latency probe*): pointer-down → first changed capture frame on the Mac's one clock, plus scripted `atap`/`aswipe` trials, 50 per case, p50/p90. Checked by tests and `flutter build macos --debug` only; the numbers below are for the owner to fill in on the iPhone 18 Pro Max, Settings → General, today's gestures plus M0a, before any other unit. Every later latency or stability unit is judged against them.

  | Case | Portrait p50 / p90 (ms) | Landscape p50 / p90 (ms) |
  |---|---|---|
  | Scripted `atap` → change | – | – |
  | Scripted `aswipe` 0.15 → change | not valid (see below) | – |
  | Felt click → change, instant click (Back ↔ General) | 185 / 202 (n=11) | – |
  | Felt click → change, owner's own clicks, mixed screens | 296 / 583 (n=19) | – |
  | Felt 1 s still press → change | – | – |
  | Felt 300 ms drag → change | – | – |

  Measured 2026-11-25, runner release 1, release build with the probe. The instant clicks came from an automated click with almost no time between down and up. The owner's clicks include the time the button is held, because a tap is sent at mouse-up, so about 110 ms of the gap is press time. Opening Settings from the Home Screen measured 92 ms, so the app's own reaction is part of every number. The scripted `aswipe` run on the Home Screen read 0–36 ms: the screen was already changing when the probe armed (a widget, or the previous swipe still settling), so the probe needs a still screen or a settle check before it arms. A synchronous `tap` takes 240–248 ms to complete in XCTest, while the command reaches the runner in 1–2 ms.

  **E1 answered on the device (runner release 1).** A record without a lift is lifted at its end: `pdown` on a row opened it, like a tap. A second record sent while one plays is refused at once (`Unable to perform`), so it neither queues nor cancels nor adds a finger. A touch cannot be pressed at mouse-down and released at mouse-up through XCTest synthesis, so taps stay at mouse-up and drags stay segmented (L3). Matching iPhone Mirroring's press-on-mouse-down needs another input path.

- **Native remote window (`docs/iphone-usb/native-window-plan.md`, units 2 to 8)**: built, checked by tests, `flutter analyze` and `flutter build macos --debug`, and on the owner's iPhone 18 Pro Max on 2026-11-25 (picture, taps, drags, hold, title-bar buttons, shortcuts and close all work). The iPhone's screen opens in an AppKit window of its own (CLAUDE.md, *Remote windows (native)*): Swift owns the window, the picture layer the capture feeds directly, the titlebar accessory's controls, the mouse and ⌘W/⌘1–⌘5; Dart keeps the controller, the touch link and every string, pushed as full snapshots. Departures from the plan, decided by the owner and the lead: unit 1's spike was folded into unit 4 (the sample-buffer layer with DisplayImmediately and 420v by default, the capture's preview layer with `flutter.iphone_layer` = `preview`, for the lead to choose on the device); one iPhone window at a time, closing it ends the session, controls in a titlebar accessory; the window takes 420v (BGRA only where the output offers no 420v).
  - Unit 2, AppDelegate: Home is held by reference; the Dock and the status item bring it back whenever it is not visible.
  - Unit 3, per-device capture: `IosScreenPlugin` keeps one capture per device id, every call and callback names its device, `markProbe {device, id, t0Us?}`, the `sink` argument.
  - Unit 4, the shell: `RemoteWindowPlugin`, `RemoteWindowController`, `RemoteSurfaceView`; the window sink; `RemoteWindowChannel` (open is idempotent, `closed` with a token).
  - Unit 5, input and driver: pointer packets on `extended_screen/remote_window_input`, `RemoteDriver`, `IphoneRemoteWindow` (the controller put and deleted by device-id tag), Home opening the window (behind a debug `iphoneNativeWindow` switch, gone with the route).
  - Unit 6, view-model and chrome: `IphoneRemoteViewModel` (shared with the route until it was removed); one render per turn, deduplicated, again on a language switch.
  - Unit 7, probe: a down's event time is the probe's t0 (`t0Us`), scripted trials arm with none, both starts logged for one release.
  - Unit 8, docs: CLAUDE.md, README and this entry.
  - Device check (2026-11-25, the owner, iPhone 18 Pro Max): the picture, taps, drags, the long press, the title-bar buttons, the ⌘ shortcuts and closing the window (which ends the session) all work. Still to record: 10 minutes of gesture-heavy use without stalling, with the `didDrop` and renderer-failure counts from the log; the sample-buffer layer against the preview layer, and which one stays; resizing stays locked and rotation flips the lock; the Dock icon and the status item bring Home back with the window open; the toolbar in Thai; Retry after an unplug; whether two muxed iPhones can capture at once; and M0a's felt numbers in the window, recorded here.
- **The `/iphone-remote` route removed (2026-11-25, uncommitted in worktree `beside`)**, the owner's choice once the native window passed the device check above: the route and its `app_pages`/`app_routes` entries, `iphone_remote_view.dart`, Home's branch to it, the `iphoneNativeWindow` setting (key `iphone_native_window`, now unread) with its debug Settings row and its two translation keys, the controller's `nativeWindow` flag, and the texture sink (`IosScreenSink`, `IosScreenChannel.textureId`/`textureIds`, the `sink` argument, and in `IosScreenPlugin` the `FlutterTexture`, `copyPixelBuffer`, `textureFrameAvailable` and the BGRA-for-texture path). The route's widget tests went where the window's packet tests and the view-model tests already cover the behaviour; "live drags follow Settings" was ported to the controller, and the per-device capture tests now read `isRunning`/`current`. Still to remove: the losing picture layer with `flutter.iphone_layer`, once the device check picks one.
- **After that** (in this order): several iPhone windows at once (a per-UDID `IosTouchService` and a proven capture uniqueID↔UDID mapping); the scroll wheel and trackpad mapped to swipes or `DragStreamer`; event time feeding the controller's clocks if M0a shows the skew matters; a CoreDevice HID (`dtuhidd`) input backend behind the controller's touch sink, if the one-minute check in `docs/iphone-usb/latency-options.md` says it is worth a spike.

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
1. §4, Mac controls iPhone over USB (built and tried on the iPhone; the Android native window is built, `/remote-host` removed — its AVD device check, then commit).
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
- [ ] Mac controls iPhone over USB (§4) in landscape (the picture, taps, drags and the long press were checked in the native window on 2026-11-25).
- [x] The iPhone's native window (§4): picture, input, shortcuts, close = end (2026-11-25).
- [ ] The iPhone's native window (§4): which picture layer stays, Home back from the Dock, rotation.
- [ ] The Tab over Wi-Fi beside the iPhone (several Wi-Fi devices at once on real hardware).

### Upkeep
- [ ] Update the Tab's app to a current build (needs the owner's go-ahead) to get the identity tail.
- [ ] Reinstall the iPhone app every 7 days (free team); last install 2026-11-24, next by about 2026-12-01.
