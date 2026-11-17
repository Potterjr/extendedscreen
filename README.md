# extendedscreen

Use an Android tablet as a second monitor for a Mac, over a USB cable or over Wi-Fi. The Mac captures a display, encodes it as H.264 or H.265, and streams it to the tablet: through an `adb reverse` TCP tunnel on USB, or over TLS on the local network on Wi-Fi. Touches on the tablet come back as mouse input. The same link also offers a Remote Control mode, in either direction over USB and tablet-to-Mac over Wi-Fi.

One Flutter codebase builds both sides: on macOS it is the **host**, on Android the **client**. Nothing is tied to a tablet model. The tablet reports its panel size and top refresh rate when it connects, and the Mac sizes the stream to match.

## Requirements

| | |
|---|---|
| Mac | macOS 12.3 or later (the app installs on 12.0, but screen capture is only enabled from 12.3). `adb` installed in one of the locations listed under Setup. Screen Recording and Accessibility permissions. |
| Tablet | Any Android device with USB debugging enabled. The minimum Android version is whatever your Flutter SDK defaults to (API 24 with Flutter 3.47). Exact refresh-rate switching and low-latency decoding need Android 11 or later. |
| Cable | A USB data cable between the two. Wi-Fi needs it once, to pair the tablet with the Mac. |
| Wi-Fi (optional) | Both devices on the same network, ideally 5 GHz or 6 GHz, on a network that lets its clients reach each other (guest networks often do not). |
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

1. Open the app on the tablet. It dials the Mac by itself, retries every 5 seconds, and dials at once when the Mac starts a session. A red "Waiting for Mac host…" banner is the normal state until the Mac side is up.
2. On the Mac, the tablet appears under **Android client**. The list is not live: if you plugged the tablet in or authorised it after the Mac app started, click the refresh icon on that card first (it shows a spinner while the Mac looks). Click the tablet to connect. The Mac has no Connect button: you connect by picking a device. If both permissions are granted and exactly one physical device is attached, the Mac connects without a click.
3. The Mac steps through *Detecting device*, *Forwarding port*, *Handshaking* and *Configuring display*. It waits on *Handshaking* until the tablet app is running, with no timeout. Before anything is streamed the two apps check each other (see *USB sessions* under Over Wi-Fi), which needs the same generation of the app on both sides: an older build on either end is refused, with a message on the newer one.
4. The tablet opens the full-screen display by itself (Session modes lists one exception). In the default Extend mode a new display appears on the Mac; arrange it in System Settings → Displays and drag windows onto it.

Press **Disconnect** on the Mac's Home screen to stop. The Mac then stays disconnected until you pick a device yourself. The tablet keeps its display open under a "Reconnecting…" overlay and goes on redialling. The overlay has two buttons: **Back** returns to the tablet's Home screen and keeps redialling (the display reopens by itself once the Mac is back), and **Disconnect** stops redialling.

Disconnect on the tablet only drops the link. The Mac returns to *Handshaking* and streams again as soon as the tablet dials in (tap **Connect** there, or switch back to the app), so press **Cancel** on the Mac as well.

### Over Wi-Fi

1. **Pair once over USB.** Connect over USB as above. Every USB session quietly gives the tablet what it needs to find and trust this Mac later, including the Mac's current network addresses; there is no code to type. The Mac hands it to the app on the tablet through `adb`, not over the link, so both apps have to be builds that know this way of pairing. Pair again the same way if you move to another Mac.
2. **On the Mac**, disconnect, choose **Wi-Fi** under the session modes and press **Connect**. The card shows the Mac's address. The Mac now waits for the tablet, and from then on starts waiting by itself whenever the app has focus and nothing was stopped by hand.
3. **On the tablet**, choose **Wi-Fi** on the Home screen. It looks for the Mac and connects. The cable can be unplugged.

The first time, macOS may ask to let the app find devices on the local network, and the macOS firewall (if it is on) to let it accept incoming connections: allow both.

The tablet finds the Mac in two ways at once: a broadcast on its own network, and a question sent straight to every address it knows for the Mac (the ones the Mac reported at pairing, the one it last connected to, and anything typed into **Mac address (optional)**). The second way is what works when the two are on different subnets, for example a tablet behind a mesh router that does its own NAT. If the tablet keeps saying it is looking for the Mac, the Mac's address has probably changed since the last USB session: connect over USB once more, or type the address shown on the Mac.

What differs from USB:

- **Remote Control, Mac → Tablet is not available.** It sends its input through `adb`, which needs the cable. The option is greyed out, and a session runs Tablet → Mac instead.
- **The picture follows the network.** When the network cannot carry the stream, the Mac lowers the bitrate until it fits, so the picture gets softer for a while instead of lagging; once the network has room again it sharpens over a few seconds of activity (an idle screen tells the Mac nothing about the network, so it waits for the next scroll or video). The Mac's Home screen shows the current rate next to *Wi-Fi*. Only a sudden, large drop still makes the Mac drop frames, which shows as a short freeze. The rate never goes above the preset's, nor below an eighth of it (at least 2 Mbps).
- **For the steadiest link:** connect the Mac to the router with a cable if you can (the stream then crosses the air once instead of twice), keep the tablet on 5 GHz or 6 GHz near the router, and on the tablet turn off Wi-Fi power saving and the automatic switch to mobile data if its settings have them. While it streams over Wi-Fi the app asks Android to keep Wi-Fi out of power saving.
- **Security.** The stream is encrypted with TLS. The tablet only talks to a Mac whose certificate it received over USB, and the Mac ignores everything from, and sends nothing to, a device that has not presented the token it handed out over USB. Another machine on the same network can still get in the way (occupy the connection for a few seconds at a time), but it cannot see the screen or send input. Both are kept in each app's preferences, unencrypted.
- **Pairing goes through `adb` and nowhere else.** The Mac gives its certificate and token to the tablet with an `adb shell` command addressed to this app, and the app accepts a pairing only from the shell (Android's `DUMP` permission, which an installed app does not have). Nothing sent over the link, USB or Wi-Fi, can pair the tablet, so another app on the tablet cannot pair it with a "Mac" of its own by answering on `127.0.0.1:7001`, and cannot collect the Mac's token by dialling the tunnel. What remains is what USB debugging itself means: a computer you authorised for debugging can pair the tablet, and so can an app you gave `DUMP` to with `adb shell pm grant`.
- **USB sessions prove both ends the same way.** The USB link is a TCP port on each device, and a port does not say who is on it: any app on the tablet can dial the tunnel, or answer on `127.0.0.1:7001` while no tunnel is up, and any program on the Mac can connect to the Mac's end. So for every USB connection attempt the Mac makes a random key once its tunnel is up, and gives it to the app on the tablet through the same `adb` channel as a pairing. The key itself never goes over the link. The tablet's first packet proves it holds the key, and the Mac's reply proves the same; until then the Mac sends no picture and takes no input, and the tablet acts on nothing it is sent and shows none of it. A key is good for one session, and the tablet uses it only on a connection it opened after the key arrived, so an app that got hold of the tablet's connection earlier cannot sit in the middle. A session that cannot be proved fails with a message instead of falling back to trusting the port; that includes a session between a build with this check and one without. Another app on the tablet can still get in the way (dial first and hold the connection for a few seconds at a time), and whatever can run `adb` on the Mac is trusted, as it always was: it can already see and control the tablet.
- **Unpairing.** On the tablet, the **Mac over Wi-Fi** card on Home lists each paired Mac with a button to forget it. On the Mac, **Settings → Wi-Fi → Reset Wi-Fi pairing** gives the Mac a new identity: every tablet stops connecting over Wi-Fi until it has been connected over USB once more, and a Wi-Fi session in progress ends. Use it when a tablet is lost or handed on. Afterwards a tablet you pair again lists this Mac twice; the older entry no longer works and can be forgotten.

### On the tablet

| Gesture | Result on the Mac |
|---|---|
| Tap | Left click |
| Two or three quick taps on the same spot | Double or triple click (within the Mac's double-click speed and about 24 points of each other) |
| Drag one finger | Scroll. Lifting while still moving fast keeps it scrolling for a moment; stopping before you lift does not. |
| Hold for 0.4 s, then drag | A mouse drag with the left button held: move windows, select text, drag sliders and icons. Other fingers that touch meanwhile are ignored. |
| Pinch with two fingers | ⌘ + scroll, which zooms in apps that support it |

There is no right-click and no keyboard input from the tablet yet.

The Mac has only one cursor, and a click or a drag has to move it. With **Keep the Mac cursor in place** on (the default, under Settings → Touch on the Mac), a tap or a drag borrows the cursor and puts it back where you left it about a tenth of a second after the finger lifts, and scrolling and pinching put it straight back after each step, so at most it flickers for a few milliseconds. While you hold the Mac's own mouse or trackpad button, scrolling on the tablet is ignored so it can't pull your drag away. If you move the Mac's own mouse or trackpad, or press its button, while a tap or drag has the cursor, the cursor stays with you. Turn the setting off to leave the cursor where you last touched. With it on, hover effects (tooltips, menus that open on hover) don't stay up after a tap, because the cursor leaves.

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
| Remote Control, Mac → Tablet | The Mac shows the tablet's screen and controls it. USB only. |

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
| Keep the Mac cursor in place | On by default | Under Touch. Taps and drags on the tablet give the Mac's cursor back as the finger lifts; scrolls and pinches hand it straight back (see *On the tablet*). |
| Reset Wi-Fi pairing | (an action) | Under Wi-Fi. Asks first, then gives the Mac a new Wi-Fi identity: every paired tablet has to connect over USB once before it can use Wi-Fi again (see *Over Wi-Fi*). |

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

- **Connection.** The Mac runs `adb reverse tcp:7001 tcp:7001` and listens on `127.0.0.1:7001`; the tablet dials its own `127.0.0.1:7001`. With the tunnel up, the Mac makes a random 32-byte key for this attempt and hands it to the app on the tablet through `adb` (a broadcast that only the shell may send, to this app); the app dials as soon as it has it. The tablet's first packet is a hello: a fresh nonce and an HMAC-SHA256 of it under the key. The Mac checks it (it waits 3 seconds), answers with its own HMAC of that nonce, and from then on trusts that connection; the tablet trusts the connection once the answer checks out (it waits 2 seconds). A hello made without the key, which is what a tablet app opened after the Mac started waiting sends, is turned away, and the Mac hands the key over again. Then comes HELLO, with the tablet's panel size and top refresh rate. The Mac waits up to 3 seconds for it, starts capture, and announces the session mode, codec and refresh rate.
- **Wi-Fi.** The Mac listens on TCP 7001 on every interface with a self-signed TLS certificate, and answers a UDP probe on port 7001, which the tablet broadcasts and also sends directly to the addresses it knows for the Mac. The certificate and a random 32-byte token reach the tablet on every USB session, through `adb` (a broadcast that only the shell may send, to this app) and never over the link. Over Wi-Fi the tablet accepts only that certificate and sends the token first; until the Mac has checked it (it waits 3 seconds), it reads nothing else from that connection. The Mac also caps how much it queues for the network: a frame that would wait more than about 120 ms is dropped, and sending resumes from the next keyframe.
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
| `0xF6` | not sent | Was Wi-Fi pairing over the USB link. The pairing (the Mac's id, name, token, certificate and current IPv4 addresses) now travels through `adb`; the tablet ignores this packet on any link |
| `0xF5` | Tablet → Mac | The pairing token. First packet of a Wi-Fi session |
| `0xF4` | Tablet → Mac | Hello. First packet of a USB session: a 16-byte nonce, and its HMAC-SHA256 under the session key that `adb` delivered (left out when the tablet has no key yet) |
| `0xF3` | Mac → tablet | The answer to a hello that proved the key: the Mac's HMAC-SHA256 of the same nonce |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| The Mac shows "No device detected — plug in via USB-C" | `adb` is not in one of the three locations, the tablet has not authorised USB debugging, the cable carries no data, or the tablet was plugged in or authorised after the list was last read (click the refresh icon on the card). A missing `adb` is not reported separately. |
| The Mac stays on "Handshaking…" | The app is not running on the tablet, or Disconnect was pressed on the tablet: tap **Connect** there. |
| The Mac says the tablet "did not confirm this USB session" | Whatever connected from the tablet never proved it holds the session key. Usually the tablet runs a build from before USB sessions were checked: update it. Otherwise another app on the tablet is using port 7001. |
| The Mac says it "could not hand this session's key" to the tablet | Something dialled in without the key and `adb` could not deliver it to the app: the app is not open on the tablet, it is an older build, or `adb` lost the device. Open the app on the tablet and update it if the message stays. |
| The tablet says "The Mac has not confirmed this USB session" | Something answered on the tablet's port 7001 but did not prove it is the Mac. Usually the Mac runs a build from before USB sessions were checked: update it. For a moment after opening the app it can also mean the Mac's key is still on its way. |
| The Mac says "Connected" but the tablet is black | Capture failed to start. The error is printed only to the console of a debug build (`flutter run`); the unified log below shows no error, just no `diag:` lines. Check both permissions. |
| The tablet shows "Reconnecting…" | The link dropped: a settings change on the Mac, a pulled cable, the Mac sleeping or the Mac app quitting. The tablet keeps redialling. Use **Back** or **Disconnect** on the overlay to leave it. |
| On Wi-Fi the tablet says "Not paired with a Mac yet" | The tablet has not connected to this Mac over USB since Wi-Fi support was installed on both, the Mac was forgotten on the tablet, or one of the two apps is an older build that pairs differently (update both). Switch both to USB, connect once, then switch back. |
| On Wi-Fi the tablet keeps "Looking for the Mac" | The Mac has not pressed Connect in Wi-Fi mode, the Mac's address changed since the last USB session and the two are on different subnets, the network isolates its clients, or macOS's Local Network permission or firewall is blocking the app. Connect over USB once to refresh the address, or type the Mac's address on the tablet. |
| On Wi-Fi the tablet says it is not the Mac it was paired with | The Mac's Wi-Fi identity changed (**Reset Wi-Fi pairing**, or its preferences were reset), or the address belongs to another Mac. Connect once over USB to pair again. |
| The tablet lists the same Mac twice | The Mac's Wi-Fi pairing was reset and the tablet paired again. The older entry no longer works: forget it. |
| On Wi-Fi the picture freezes briefly now and then | The network's capacity drops suddenly (another device starts a large transfer, the tablet moves away, the Mac or tablet scans for networks) and the Mac drops frames until the bitrate has come down. If it keeps happening, see *For the steadiest link* under *Over Wi-Fi*. |
| On Wi-Fi the picture is soft | The Mac lowered the bitrate to what the network carries (the rate is shown next to *Wi-Fi* on the Mac's Home screen). It climbs back on its own once the network has room. |
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
- One tablet at a time.
- Over Wi-Fi: no Remote Control from Mac to tablet. The bitrate adapts, but the resolution and frame rate do not, so on a very slow network the picture can get coarse.
- The Mac cannot unpair one tablet and keep the others: **Reset Wi-Fi pairing** unpairs them all.
- The Mac's menus, the Mac's connection error messages (such as "Exception: No ADB device detected") and the Android notifications are English only; the rest of the UI is in English and Thai.
