# extendedscreen

Use an Android tablet as a second monitor for a Mac over a USB cable. The Mac captures a display, encodes it as H.264 or H.265, and streams it to the tablet through an `adb reverse` TCP tunnel. Touches on the tablet come back as mouse input. The same link also offers a Remote Control mode, in either direction.

One Flutter codebase builds both sides: on macOS it is the **host**, on Android the **client**. Nothing is tied to a tablet model. The tablet reports its panel size and top refresh rate when it connects, and the Mac sizes the stream to match.

## Requirements

| | |
|---|---|
| Mac | macOS 12.3 or later (the app installs on 12.0, but screen capture is only enabled from 12.3). `adb` installed in one of the locations listed under Setup. Screen Recording and Accessibility permissions. |
| Tablet | Any Android device with USB debugging enabled. The minimum Android version is whatever your Flutter SDK defaults to (API 24 with Flutter 3.47). Exact refresh-rate switching and low-latency decoding need Android 11 or later. |
| Cable | A USB data cable between the two. |
| Toolchain | Flutter with Dart 3.11 or later, Xcode and CocoaPods for the Mac app, the Android SDK with Java 17 for the tablet app. |

## Setup

1. **Install `adb` where the app looks for it.** The Mac app does not search `$PATH`. It uses the first of these that exists:
   - `/usr/local/bin/adb`
   - `/opt/homebrew/bin/adb`
   - `~/Library/Android/sdk/platform-tools/adb`

   Homebrew and Android Studio's default SDK location both put it in one of these.
2. **Enable USB debugging** on the tablet (Developer options), plug it in and accept the "Allow USB debugging" prompt. Check from a terminal:
   ```bash
   adb devices
   ```
   The tablet must be listed as `device`. The app hides devices that are `unauthorized` or `offline`.
3. **Run the app on both devices** (see Running).
4. **Grant the two macOS permissions.** If Screen Recording or Accessibility is missing, the Mac app shows a "Permissions needed" banner on its Home screen and will not connect. Use the **Open** buttons, on the banner or per permission under Settings → Permissions, to jump to the right pane in System Settings. Until both are granted the app only checks them and never triggers macOS's own prompt, so if it is not listed in the pane, add it yourself. The app re-checks when you switch back to it.

## Running

```bash
flutter pub get

# Mac (host)
flutter run -d macos

# Tablet (client): use the id shown by `flutter devices`
flutter run -d <device-id>
```

`.vscode/launch.json` has launch configs for both, plus a compound that starts them together. The Android configs carry one specific tablet's serial as `deviceId`; change it to yours.

## Using it

1. Open the app on the tablet. It dials the Mac by itself and retries every 5 seconds. A red "Waiting for Mac host…" banner is the normal state until the Mac side is up.
2. On the Mac, the tablet appears under **Android client**. The list is not live: if you plugged the tablet in or authorised it after the Mac app started, click the refresh icon on that card first (it shows a spinner while the Mac looks). Click the tablet to connect. The Mac has no Connect button: you connect by picking a device. If both permissions are granted and exactly one physical device is attached, the Mac connects without a click.
3. The Mac steps through *Detecting device*, *Forwarding port*, *Handshaking* and *Configuring display*. It waits on *Handshaking* until the tablet app is running, with no timeout.
4. The tablet opens the full-screen display by itself (Session modes lists one exception). In the default Extend mode a new display appears on the Mac; arrange it in System Settings → Displays and drag windows onto it.

Press **Disconnect** on the Mac's Home screen to stop. The Mac then stays disconnected until you pick a device yourself. The tablet keeps its display open under a "Reconnecting…" overlay and goes on redialling. The overlay has two buttons: **Back** returns to the tablet's Home screen and keeps redialling (the display reopens by itself once the Mac is back), and **Disconnect** stops redialling.

Disconnect on the tablet only drops the link. The Mac returns to *Handshaking* and streams again as soon as the tablet dials in (tap **Connect** there, or switch back to the app), so press **Cancel** on the Mac as well.

### On the tablet

| Gesture | Result on the Mac |
|---|---|
| Tap | Left click |
| Two or three quick taps on the same spot | Double or triple click (within the Mac's double-click speed and about 24 points of each other) |
| Drag one finger | Scroll. Lifting while still moving fast keeps it scrolling for a moment; stopping before you lift does not. |
| Hold for 0.4 s, then drag | A mouse drag with the left button held: move windows, select text, drag sliders and icons. Other fingers that touch meanwhile are ignored. |
| Pinch with two fingers | ⌘ + scroll, which zooms in apps that support it |

There is no right-click and no keyboard input from the tablet yet.

The Mac has only one cursor, and a click or a drag has to move it. With **Keep the Mac cursor in place** on (the default, under Settings → Touch on the Mac), a tap or a drag borrows the cursor and puts it back where you left it about a tenth of a second after the finger lifts, and scrolling and pinching put it straight back after each step, so at most it flickers for a few milliseconds. If you move the Mac's own mouse or trackpad, or press its button, while a tap or drag has the cursor, the cursor stays with you. Turn the setting off to leave the cursor where you last touched. With it on, hover effects (tooltips, menus that open on hover) don't stay up after a tap, because the cursor leaves.

The bar at the top of the display (the HUD) has a Back button, the stream rate in Hz, received frames per second, round-trip latency, frames dropped per second, the tablet's battery and a Disconnect button. It shows for about 4 seconds when the display opens, then hides behind a small tab at the top centre. Tap the tab to bring it back; touching the bar keeps it up. While it is hidden you can tap the Mac's menu bar, except right under the tab. Settings → Show HUD on the Mac only hides the numbers: with it off, the tab opens a bar with just Back and Disconnect.

### On the Mac

- Closing the window does not end the session. The app keeps streaming and can be reopened from its menu-bar icon or the Dock. Quit the app to stop it.
- The app does not keep the Mac awake. After the Mac wakes, the capture pipeline is rebuilt automatically.

### Session modes

The mode is chosen on the Mac's Home screen, and only while disconnected: the selectors are hidden during a session. If the Mac has already auto-connected in the last-used mode, press Disconnect first.

| Mode | What it does |
|---|---|
| Extended Screen | The tablet is a second monitor, in Extend or Mirror as set in Settings. |
| Remote Control, Tablet → Mac | The tablet shows the Mac's main display and controls it with the gestures above. Always mirrors, whatever the Mode setting says. |
| Remote Control, Mac → Tablet | The Mac shows the tablet's screen and controls it. |

Mac → Tablet works differently from the other two:

- On the tablet, tap **Start screen sharing** and approve Android's screen-capture prompt. This is needed again after a Disconnect, and whenever the Mac reconnects to apply a changed Mode, preset, codec or custom value.
- The Mac opens a remote view with its own Reconnect and Disconnect buttons. Unlike Disconnect on Home, that Disconnect does not switch off auto-connect: with exactly one physical device attached, the Mac connects again the next time the app regains focus. To stop for good, use the back arrow and press Disconnect on Home.
- In the remote view, a click is sent as a tap and a drag as a straight 50 ms swipe, both through `adb shell input`. There is no keyboard or text entry, long-press, pinch, scroll wheel, or Back/Home/Recents control.
- The tablet always captures at its native resolution. Presets only set the frame rate and bitrate here, and Max means 60 fps at 20 Mbps.
- The Mac still requires Screen Recording and Accessibility before it will connect.
- After a Mac → Tablet session, the tablet does not open the display by itself the first time you connect in another mode. Tap **Open View** on the tablet's Home screen.

## Settings

All stream settings are on the Mac, behind the gear icon. The tablet's Settings screen has only the language, a permissions list and an info section.

| Setting | Options | Notes |
|---|---|---|
| Language | English, ไทย | Follows the system language until you choose. Available on both devices. |
| Mode | Extend (default), Mirror | Extend creates a virtual display with the tablet panel's pixel size. Mirror shows the Mac's main display (the one with the menu bar). Ignored in Remote Control. |
| Encode Preset | Max (default), Quality, Balanced, Performance, Custom | See the table below. |
| Codec | H.264, H.265 | A toggle at the top of the Encode Preset sheet (the Codec row under Info is read-only). Until you choose one or select Max, it is set when the Mac app starts: H.265 if the preset is Max, H.264 otherwise. Switching to another preset keeps the current codec. |
| Performance Overlay | Off by default | Flutter's performance graphs, drawn on both devices. |
| Show HUD | On by default | The numbers on the tablet's HUD bar. When off, the bar keeps only Back and Disconnect. |
| Keep the Mac cursor in place | On by default | Under Touch. Taps and drags on the tablet give the Mac's cursor back as the finger lifts; scrolls and pinches don't take it (see *On the tablet*). |

Changing the Mode, preset, codec or a custom value drops the link and reconnects to apply it. The two overlay switches and the cursor switch apply live.

Preset resolutions are relative to the connected tablet's panel:

| Preset | Resolution | Bitrate | Refresh rate |
|---|---|---|---|
| Max | Native | Scales with resolution and rate, between 8 and 50 Mbps (40 Mbps at 2960×1848 and 120 Hz) | The panel's top rate, adaptive |
| Quality | Native | 20 Mbps | 60 Hz |
| Balanced | Native | 8 Mbps | 60 Hz |
| Performance | Half the width and height | 12 Mbps | 120 Hz |
| Custom | Native, 80%, 1920×1200, half, or 1280×800 | 4 to 40 Mbps | 30, 60, 90 or 120 Hz |

- **Max adapts its frame rate.** If the Mac's encoder cannot keep up for 3 seconds, the rate drops to the highest step of 30/45/60/90/120 that fits what it actually achieved. After 10 healthy seconds it tries one step up again. Each time a step-up fails within 30 seconds, that wait doubles, up to 5 minutes.
- **Custom is driven by width.** The height follows the tablet panel's aspect ratio, so 1920×1200 is only exact on a 16:10 panel.
- Until a tablet has connected once, the picker assumes a 2560×1600 panel at 60 Hz.

## How it works

```
Mac (host)                                        Tablet (client)
──────────────────────────────────────────────────────────────────
ScreenCaptureKit → VideoToolbox (H.264 / H.265)
        │  FRAME_DATA
        ▼  TCP 127.0.0.1:7001 through `adb reverse`
                                             MediaCodec → SurfaceView
                                                     │
CGEvent injection  ◄──────── MOUSE_EVENT ──────── touch gestures
```

- **Connection.** The Mac runs `adb reverse tcp:7001 tcp:7001` and listens on `127.0.0.1:7001`; the tablet dials its own `127.0.0.1:7001`. The tablet's first packet (HELLO) carries its panel size and top refresh rate. The Mac waits up to 3 seconds for it, starts capture, and announces the session mode, codec and refresh rate.
- **Extend** uses the private `CGVirtualDisplay` API to create a HiDPI display whose pixel size equals the tablet's panel. If screen capture cannot find the new display within about 1.5 seconds, the Mac removes it and mirrors its main display instead. **Mirror** captures the Mac's main display (the one with the menu bar).
- **Picture shape.** The stream always has the tablet's shape: its full panel size, or a scaled copy with Performance (half size) and most Custom sizes. A Mac display of another shape (a notched MacBook, a 16:9 monitor) is shown whole with black bars, and the Mac maps touches onto the picture: a tap on a bar goes to the nearest edge of the screen.
- **Falling behind.** If the tablet decodes more slowly than the Mac sends, it keeps only a few frames waiting: about 100 ms at 60 fps and above, never fewer than 6 frames (so up to 200 ms at 30 fps). Beyond that it skips ahead to the next keyframe, asking the Mac for one at most every 0.75 seconds, so the picture freezes briefly instead of lagging. A new decoder also waits for a keyframe. Skipped frames count in the HUD's drops.
- **Liveness.** Both sides send a heartbeat every 2 seconds, which is also the latency measurement. Six seconds of silence counts as a dead link. The Mac then tears everything down and retries after 1 second, the tablet after 5.
- **Refresh rate.** The tablet switches its panel to the slowest mode that still shows every frame of the stream, never below 60 Hz.
- **Mac → Tablet** reverses the media path: Android MediaProjection and MediaCodec encode the tablet's screen, and the Mac decodes it with VideoToolbox into a Flutter texture.

## Packet protocol

Every packet has a 17-byte big-endian header followed by the payload:

```
[ 4 bytes magic "EXTD" | 1 byte type | 4 bytes payload length | 8 bytes timestamp µs | payload ]
```

| Type | Direction | Purpose |
|---|---|---|
| `FRAME_DATA` | Encoder → viewer | One encoded H.264/H.265 frame |
| `MOUSE_EVENT` | Tablet → Mac | Clicks, moves, drags and scrolls from touch gestures |
| `TOUCH_EVENT`, `KEY_EVENT` | Tablet → Mac | Understood by the Mac, but the tablet does not send them yet |
| `HEARTBEAT` | Both | Liveness and round-trip latency |
| `CONTROL` | Both | Sub-commands, selected by the first payload byte |

| Control byte | Direction | Meaning |
|---|---|---|
| `0x01` | Tablet → Mac | HELLO: platform, panel width and height, top refresh rate |
| `0xFF` | Viewer → encoder | Request a keyframe |
| `0xFC` | Mac → tablet | Codec in use |
| `0xFB` | Mac → tablet | Stream refresh rate |
| `0xFA` | Mac → tablet | Performance-overlay and HUD switches |
| `0xF9` | Mac → tablet | Session mode and direction |
| `0xF8` | Mac → tablet | Start screen sharing (codec, fps, bitrate) |
| `0xF7` | Mac → tablet | Stop screen sharing |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| The Mac shows "No device detected — plug in via USB-C" | `adb` is not in one of the three locations, the tablet has not authorised USB debugging, the cable carries no data, or the tablet was plugged in or authorised after the list was last read (click the refresh icon on the card). A missing `adb` is not reported separately. |
| The Mac stays on "Handshaking…" | The app is not running on the tablet, or Disconnect was pressed on the tablet: tap **Connect** there. |
| The Mac says "Connected" but the tablet is black | Capture failed to start. The error is printed only to the console of a debug build (`flutter run`); the unified log below shows no error, just no `diag:` lines. Check both permissions. |
| The tablet shows "Reconnecting…" | The link dropped: a settings change on the Mac, a pulled cable, the Mac sleeping or the Mac app quitting. The tablet keeps redialling. Use **Back** or **Disconnect** on the overlay to leave it. |
| Extend is selected, but the tablet shows the Mac's main display and no new display appears in System Settings → Displays | The virtual display did not show up for screen capture within about 1.5 seconds, so the Mac fell back to its main display. The unified log below has a `WARNING: virtual display` line. Disconnect and pick the tablet again to retry. |

Capture and encode diagnostics go to the unified log, two lines per second while capturing (`loopRate=` and `diag:`), plus every adaptive rate change, a `Content rect in frame:` line (where the picture sits in the stream) at each capture start and whenever it changes, and the Extend fallback warning:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.example.extendedscreen"' --style compact
```

Use the full path: in zsh, `log` is a shell builtin.

## Development

```bash
flutter analyze
flutter test           # unit and widget tests in test/
flutter build macos    # release .app
```

Before giving a build to someone else:

- The Mac app is not sandboxed and uses a private API, because it has to run `adb`, post input events and create a virtual display. That rules out the Mac App Store.
- The macOS Release configuration uses manual signing with a specific development team, so `flutter build macos` needs that team's certificate. Change the team to your own on the Runner target in Xcode before building a release. `flutter run -d macos` (Debug) signs ad hoc and is not affected.
- The Android release build is signed with the debug key, and both apps still use the id `com.example.extendedscreen`.
- The Android app targets API 36 on purpose. Android 16 and later ignore an app's landscape lock on tablets; the app opts back in with a manifest setting that stops working once an app targets API 37. Do not raise `targetSdk` in `android/app/build.gradle.kts` without dealing with that.

`CLAUDE.md` describes the architecture in more detail.

## Limitations

- No audio in either direction.
- No keyboard input and no right-click from the tablet.
- Mirror, which Remote Control (Tablet → Mac) always uses, keeps the Mac display's shape: on a tablet of another shape the picture has black bars.
- Split-screen and freeform windows on the tablet are not supported, though Android does not stop you from using them: the stream is always sized for the whole screen.
- One tablet at a time, over USB only.
- The Mac's menus, the Mac's connection error messages (such as "Exception: No ADB device detected") and the Android notifications are English only; the rest of the UI is in English and Thai.
