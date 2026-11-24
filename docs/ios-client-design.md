# iPhone client design

Contents: [verdict](#verdict) · [owner runbook](#owner-runbook) · [transport](#transport) · [auth](#auth) · [client](#client) · [ipad](#ipad) · [host](#host) · [arrangement](#arrangement) · [phases](#phases) · [risks](#risks) · [decisions](#decisions)

Facts marked *(verified)* were checked on this Mac or phone during review. Facts marked *(P0)* are still to be checked on the device.

## verdict

VERDICT
Build the iPhone client as an iOS target of the same Flutter app, and put it on the existing Wi-Fi link first. The iPhone is one more paired Wi-Fi client of today's protocol: pinned TLS, the 0xF5 token, pacing and BitrateAdapter, all unchanged on the Mac. Pairing still never travels on the link. adb's DUMP-guarded broadcast is replaced by its CoreDevice counterpart: the Mac writes the unchanged pairing bytes into the iPhone app's own container with `xcrun devicectl device copy to --domain-type appDataContainer`, and the app pulls them from Dart once its handler exists. To run the iPhone beside the Tab S10 Ultra (which stays on USB), the hub gets a small, forward-compatible slice of multi-tablet phase 4: a "Listen on Wi-Fi" toggle that keeps the one `wifi` session listening next to the USB sessions. The iPhone has a display identity of its own on every link (profile key `iphone`), never the Tab's serial 1. Display placement is the owner's to choose (any layout, and any display as the main one, a tablet or the iPhone included): first by hand in System Settings, which already does both and which macOS remembers per combination of displays; the app keeps the layout itself (P1, an in-app layout with a main-display choice) if that does not survive replugs, wakes and rebuilds, or if the owner wants it in the app. USB to the iPhone through usbmuxd comes last and only if the Wi-Fi link misses the numeric gates in P0. It would run the same TLS and 0xF5 proof over the usbmux pipe, so no new handshake is needed.

The target device: the owner's iPhone 18 Pro Max (iPhone19,7), panel 1320×2868, point scale 3. devicectl reported iOS 27.0.1, `connectionProperties.transportType` wired, `pairingState` paired and `deviceProperties.developerModeStatus` enabled *(verified at review time)*; at other times it lists the phone as `available (paired)` rather than `connected`, so whether delivery needs it wired and unlocked is *(P0)*.

Signing goes through the team already in project.pbxproj, T4P27BU383, which matches the only codesigning identity on this Mac, an Apple Development certificate valid until September 2027 *(verified)*. Whether that team is a free Personal Team or a paid individual account is not known: the certificate looks the same for both. The owner confirms it before P0 (Xcode → Settings → Accounts shows "(Personal Team)" next to a free team; a paid one appears under Membership on developer.apple.com). The weekly reinstall, the 3-app limit and the missing multicast entitlement apply only to a free team. No iOS provisioning profile exists on this Mac yet, so the first build also registers the phone with the team (automatic signing does this when the Apple ID is signed in to Xcode).

What changes for the Tab and the Android app: nothing in any phase that the Tab can observe with default settings. No new packet goes to an Android build. The host-side toggles (`wifi_listen`, and display Position if P1 is built) default to off and auto.

DISTRIBUTION
Personal development signing only, no App Store or TestFlight. Two reasons: the pairing inbox depends on devicectl writing into a development-signed (get-task-allow) app's container, which a TestFlight or App Store build would not allow, so such a build would need the QR fallback; and a review would add nothing for a single owner. Free team: the app stops launching 7 days after each install, so it is reinstalled weekly from the Mac (about 5 minutes with the phone cabled and unlocked); at most 3 sideloaded apps per device; no multicast entitlement. Paid ($99 a year): one-year profiles (one reinstall a year), and the multicast entitlement can be requested. Nothing else in this design changes with the account type.

HOW THE DESIGNS WERE JUDGED
Three designs, three judges.
- Wi-Fi first, shared Dart, devicectl pairing (this skeleton). Two of three judges picked it, 110 points in total. It is the shortest path to the goal and adds the least new trust surface. Weak spots: Wi-Fi jitter, one extra frame through FlutterTexture, and hub edits in sensitive places.
- USB first through usbmuxd, shared Dart, a native video layer under a transparent FlutterView, and a per-iPhone key with a new 0xF0 challenge. One judge picked it, 101 points. It has the best end-state latency (0.4 to 0.7 ms usbmux round trips were measured on this pair). But it needs about 20 to 25 days, stacks several unproven pieces on the critical path, adds a third transport and a new device kind to the hub before anything works, and breaks the "host sends nothing before proof" rule.
- A native SwiftUI/UIKit client. Lowest score, 81 points. Its transport and auth are the same as the USB-first design, but it reimplements about 3k lines of client protocol, state machine, gestures and strings in Swift, on a protocol with no version negotiation.

Grafted from the others:
- the arrangement planner as pure Dart, with Swift only applying origins, kept as a fallback (P1);
- the text-size divisor and an fps cap as host-side per-device settings, so HELLO keeps meaning "physical pixels the client renders";
- `_capture` made nullable and AndroidCaptureChannel left unregistered on iOS, rather than relying on swallowed exceptions;
- a root view controller that defers system edge gestures;
- a switchable decoder sink (Texture now, an AVSampleBufferDisplayLayer underlay as a measured experiment);
- golden wire fixtures;
- the Keychain for the iPhone's copy of the token from the start;
- an optional display grace period for an iPhone that was only backgrounded;
- for P5, usbmuxd Listen events, CONNREFUSED handled inside the attempt, and a listener that judges up to two pending connections;
- a fix the judges found in the skeleton: an iPhone HELLO must not overwrite the global last panel.

WHAT MUST BE PROVEN ON THE DEVICE BEFORE ANY HOST WORK (P0)
1. `devicectl device copy to --domain-type appDataContainer` writes into a running, development-signed `--release` build from this team, and the app's Dart side pulls it. Time it, and try it with the app closed, with the phone locked, with the phone wired but listed as `available (paired)`.
2. A Darwin notification posted with `devicectl device notification post` reaches the app (it is only a nudge; the design does not depend on it).
3. The Local Network prompt appears, and what a denied app's dial fails with (expected `No route to host`). A unicast `EXTD?` probe to the Mac's address is answered, with `broadcastEnabled` left off; whether dart:io resolves `<LocalHostName>.local`; and a pinned TLS dial plus 0xF5 is admitted by a Mac dev build on the Wi-Fi link (see *Test isolation* under *phases*).
4. The ported VideoToolbox decoder shows a Flutter Texture at 120 Hz with 32BGRA output, recovers after background and resume (`kVTInvalidSessionErr`), and shows correct colours: a test pattern (pure red, green, blue, skin tones, a grey ramp) on the Mac's extended display matches the MacBook's panel side by side, with no hue shift.
5. `view.display.size` and `view.padding` on this model in both landscape orientations (expected: 2868×1320, about 186 px left and right, symmetric), and which side the Dynamic Island is on for each.
6. Edge-gesture deferral works with a FlutterViewController subclass in the 3.47 UIScene template.
7. macOS accepts an 832×440 pt HiDPI virtual display (Mac only, no iPhone needed).
8. Wi-Fi quality, the gate for P5. Ten minutes of streaming to the iPhone at the default ÷3 and 60 fps (with the Tab on USB if the beside slice is stubbed in the spike, else alone), logging every heartbeat round trip and every FRAME_DATA arrival on the phone. Reported: RTT p50, p95 and p99; frame-arrival jitter as the p95 of |arrival interval − send interval| from the packet timestamps; and glass-to-glass, measured by putting a millisecond clock on both the MacBook and the iPhone's extended display and filming both with a 240 fps camera (the difference between the two readings), against the same measured for the Tab over USB. Thresholds are under *Gates* in P0.
Optional: usbmux throughput at 30 to 50 Mbps into a listener in the spike app, so the P5 decision rests on a measurement.

## owner runbook

What the owner does by hand, in order, to end up with the Tab and the iPhone arranged as they like (for example Tab left, MacBook centre, iPhone right), with the main display of their choice. Each step says which phase makes it possible and what should be on screen.

0. **Today, no code.** System Settings → Displays → Arrange: put the Tab's display where you want it, and drag the white menu-bar strip onto the display you want as main (the MacBook, or the Tab). Then, one at a time: unplug and replug the Tab; sleep the Mac for 5 minutes and wake it; change a setting that reconnects (for example the codec, then back). Expected after each: the Tab's desktop is where you put it, and the menu bar is on the display you chose. Pass criterion: after every event, the current set in `defaults read /Library/Preferences/com.apple.windowserver.displays` has the Tab's display at the origin you arranged (at 0,0 if you made it main). If it passes, P1 is needed only if you want the layout kept in the app (decision 7).
1. **Before P0.** Answer decisions 2 (bundle id), 3 (signing), 14 (which roadmap first) and 15 (safe area), and confirm the team type as described in *verdict*.
2. **P0 install, once.** The developer quits the installed Mac app for the test window (see *Test isolation*) and, with the owner's go-ahead, runs `flutter run --release -d <udid>` with the iPhone cabled and unlocked. On a free team the first launch shows "Untrusted Developer": iPhone Settings → General → VPN & Device Management → the developer app → Trust. Open the app; when iOS asks to find devices on the local network, answer Allow. Expected: the iPhone's Home in landscape, saying it is not paired. Afterwards reopen the installed Mac app; the Tab reconnects by itself.
3. **Pair (after P2 ships).** Cable the iPhone to the Mac, unlock it and open the iPhone app. On the Mac: Settings → Wi-Fi → iPhones → Pair on the iPhone's row. Expected: the row says Paired within a few seconds, and the iPhone's Home lists the Mac by its Computer Name. The cable can then come out.
4. **Listen beside USB (after P3 ships).** On the Mac's Home, in the add panel, turn on "Listen on Wi-Fi (iPhone)". Expected: a Wi-Fi card saying it waits for the iPhone, with the Mac's addresses. On the iPhone, open the app. Expected: the card goes live, and a new display appears on the Mac.
5. **Arrange, once per combination.** System Settings → Displays → Arrange, with the Tab and the iPhone both live: drag each display where you want it and the menu bar onto the main display. macOS remembers it for this combination of displays; arrange {MacBook, iPhone} the first time the iPhone is used without the Tab too. (If P1 was built: arrange it the same way, then Settings → Tablets → Remember this layout, or use the app's Arrange editor.)
6. **Every day.** Plug the Tab in: it connects by itself. Open the iPhone app: it dials the Mac by itself. Nothing opens the iPhone app for you (P4's "Open on iPhone" works only while it is cabled). Locking the phone or switching apps takes its display away; reopening the app brings it back within about 3 s.
7. **Every week, free team only.** Within 7 days of the last install, with the phone cabled and unlocked, run `flutter run --release -d <udid>` from the repo on the Mac (needs the repo, Flutter and Xcode on the Mac). Reinstalling over the app keeps its data, so the pairing stays. On day 8 without it, the app no longer starts: tapping its icon opens and closes it at once (or iOS says it is no longer available). Reinstalling fixes it. If the app was deleted instead, pair again (step 3).

## transport

PHASES 2 TO 4: THE EXISTING WI-FI TLS LINK
- The iPhone dials the Mac's `SecureServerSocket` on TCP 7001 (`SocketService.startSecureServer`) and finds it with the UDP 7001 `EXTD?` probe. The Mac side is unchanged: pacing (`isCongested`, keyframe resync), `BitrateAdapter`, `_resumeBelow` and `limitSendBuffer` all run as for a Wi-Fi Tab. `SO_NWRITE` and `SO_SNDBUF` are already guarded by `Platform.isMacOS` (socket_service.dart), so they are no-ops on the phone.
- Discovery is unicast only on iOS. Sending broadcast from iOS needs `com.apple.developer.networking.multicast`, a managed entitlement only a paid team can request. DTS has also reported `EACCES` on 255.255.255.255 sends even with it, on 26.x. The iOS binding registers `WifiDiscoveryService(broadcast: false)`; the constructor argument already exists, but `probe()` sets `sock.broadcastEnabled = true` on every socket today (wifi_discovery_service.dart:222), so it changes to set it only when `broadcast` is true (SO_BROADCAST without the entitlement is untested on iOS). `probe()` then asks only `directTargets`: the addresses in the pairing (`PairedHost.addresses`, at most 8), `PairedHost.lastAddress` and the address typed on Home. The Mac answers unicast as today, and with no reply a known address is dialled anyway. A typed host name is already accepted (`normalizeHostAddress`), so `<LocalHostName>.local` is a fallback when the Mac's DHCP address moves, if P0 item 3 shows dart:io resolves it. Recommend reserving the Mac's address on the router.
- Local Network permission: `NSLocalNetworkUsageDescription` in Info.plist. The first probe or TLS dial raises the prompt. Per TN3179, an app in the background with the permission undetermined is denied silently, so the first dial must happen in the foreground (it always does: Home is open). A denied permission is a hard blocker that iOS gives no API to query, so P2 detects it (see *client*).
- Link selection on the phone: forced to Wi-Fi in `SettingsService` on iOS (see *client*), and Home hides the link selector there. `ClientConnectionManager`'s USB branch (127.0.0.1:7001 behind adb reverse, plus the `UsbSessionService` key) never runs on the phone.
- Bandwidth. The recommended iPhone stream is 1664×880 at 60 Hz (see *host*), which the Max preset clamps to 8 Mbps. The worst case, 2496×1320 at 120 Hz, is about 24 Mbps. Both fit in a modern WLAN, and BitrateAdapter handles a congested one.
- No low-latency Wi-Fi lock exists on iOS. `KeepAliveChannel.setLowLatencyWifi` is already a no-op off Android. Network.framework's `serviceClass = .interactiveVideo` would need native sockets, so it is out of scope.
- Foreground only. iOS suspends a backgrounded or locked app within seconds, and there is no foreground-service equivalent. Today's resume rule would not bring the link back promptly: `BaseConnectionManager.didChangeAppLifecycleState` reconnects on resume only when the phase is not active and `_recovering` is false, and after a suspension the client still reads `streaming`, so the dead socket (TN2277) fails later and arms the client's 5 s retry, while the Mac encodes into a frozen socket until its own 6 s heartbeat timeout. So the client gets an iOS lifecycle path (P2, `ClientConnectionManager`, iOS only; Android keeps streaming in the background as today):
  - on `hidden` or `paused`: end the link cleanly with `handleLinkFailure(retry: false)`, which closes the socket so the Mac tears down at once instead of after 6 s, and arms no timer (`_recovering` stays set, so nothing redials in the background). `inactive` (Control Centre, a notification) ends nothing.
  - on `resumed`: unless the user had stopped it (`disconnected`), `restartLink()` at once, whatever the phase reads (the pause handler may not have run before the suspension).
  - The Mac re-listens 1 s after the close, so a resume after that dials straight in. `wakelock_plus` keeps the screen on while streaming. P4 adds an optional grace period, so windows don't leave the iPhone display at every app switch.

PHASE 5 (OPTIONAL): USB THROUGH USBMUXD, ONLY IF WI-FI MISSES THE P0 GATES
Measured on this Mac and phone (read-only, no app on the phone) *(verified)*:
- `/var/run/usbmuxd` is `srw-rw-rw- root daemon`. ListDevices returns the phone with ConnectionType USB, a DeviceID (7 at the time) and ConnectionSpeed 480000000. system_profiler agrees: 480 Mb/s, so this is a USB 2 cable.
- A Connect to lockdownd (62078) answered Result 0 in 1.0 ms, and request/response round trips were 0.41/0.61/0.69 ms (min/median/max over 20 runs).
- A Connect to 7001, where nothing listened, answered Result 3 (refused) at once.
- Listen pushes Attached/Detached events.
- Not measured: bulk throughput at 30 to 50 Mbps (that needs a listening app; optional in P0).

Shape of the link:
- The roles invert relative to adb. The iPhone app listens on 127.0.0.1:7001, opening the listener on resume and closing it on background (TN2277: a suspended app's listener goes defunct). The Mac dials through usbmuxd: a plist `Connect{DeviceID, PortNumber=htons(7001)}`, after which the Unix socket is a raw pipe. Per TN3179, accepting TCP needs no Local Network permission and no entitlement.
- Mac client: `lib/shared/connection/usbmux_client.dart`, pure Dart. It uses `InternetAddress('/var/run/usbmuxd', type: InternetAddressType.unix)`, the 16-byte little-endian header (length, version 1, type 8 = plist, tag) and a minimal XML plist codec (`lib/shared/protocol/plist_xml.dart`: dict, key, string, integer, data, array). No libimobiledevice (LGPL/GPL). peertalk (MIT) serves only as a reference.
- Device source: usbmuxd Listen replaces polling for iPhones. Only ConnectionType USB counts. The DeviceID changes on every attach, so it plays `transportId`'s role in the existing "a new transport means the tunnel is gone" rule.
- Result 3 means the app is not open or not in the foreground. It is handled inside the attempt: wait 1 to 2 s, check `isCancelled`, dial again. It never goes through `handleLinkFailure`, so it never climbs the 1/2/5/10 s USB backoff. The card says `error_ios_app_not_open`.
- Over the pipe, the Mac upgrades with TLS as the server (`SecureSocket.secureServer(socket, identity.serverContext(), bufferedData: <bytes after the Connect reply>)`) and the iPhone upgrades the accepted socket as a client with the same certificate pin (`SecureSocket.secure(..., onBadCertificate: hostForCert)`), then sends 0xF5. See *auth* for why TLS rather than a new HMAC.
- `SocketService.adoptClient(socket, untrustedPayloadLimit: 1024)` installs the connected socket: it bumps `connectionId` and `_dialGen`, applies the pre-trust limit, puts the socket in paced mode (needed for a SecureSocket's IOSink), and tolerates `tcpNoDelay` failing on a Unix socket. It is the same primitive multi-tablet phase 4 calls `adopt`, so it is built once (in P3 if the handshake-deadline listener needs it first, see *host*). BitrateAdapter stays off on this link: it is USB.
- The iPhone listener judges at most 2 pending connections, each with a 3 s proof deadline; a new connection arriving with both slots full evicts the oldest unproven one. A pending one replaces the live connection only after it has proved itself. That covers the Mac redialling after its own 6 s timeout. What remains is a denial of service: `/var/run/usbmuxd` is world-writable *(verified)*, so any local user on the Mac can keep dialling the app's port and evict the Mac's own dial before it proves itself, which keeps the iPhone's USB link from being established. Such a dialer never gets in (it cannot pass the certificate pin), and the Wi-Fi link is unaffected.

REJECTED
- AWDL or Network.framework peer-to-peer: it needs Swift sockets on both ends, shows documented periodic spikes of about 90 ms, and disturbs the Mac's own Wi-Fi (awdl0 is active here).
- The CoreDevice/RemoteXPC tunnel as a data path: devicectl shows a tunnel address (fd7d:…), but there is no route to it on the Mac and no public API for app sockets through it.
- en8/anpi link-local interfaces: unconfirmed what they are, and not needed.

## auth

THREAT MODEL
CLAUDE.md's rules hold as written: a port says nothing about who is on it, trust belongs to a connection (`peerTrusted == _authedConnection == socket.connectionId`), the host sends and admits nothing before proof, and nothing that arrives on the link can pair. For the iPhone:
- Wi-Fi: anything on the LAN can complete a TLS handshake with the Mac. Anything on the LAN can answer discovery. Discovery replies are only hints, and the 0xF5 token decides. But the exposure changes in kind: today the owner runs USB only and nothing listens, while with `wifi_listen` on the MacBook keeps a TLS listener on TCP 7001 and the UDP responder open on every network it joins, public Wi-Fi included, all day. There, anyone can read the Mac's name and host id from discovery, hold the single client slot for 3 s at a time, and (with today's `SecureServerSocket`, which has no handshake timeout) keep handshakes open that never finish, which in effect keeps the iPhone out. P3 therefore adds a handshake deadline (see *host*), and decision 6 asks the owner to accept the remaining exposure or scope the listener.
- Pairing channel: whatever can write the iPhone app's container. With the hardening below, that is only a Mac the phone has paired with ("Trust this computer") while Developer Mode is on, running Xcode's devicectl, for a development-signed app. That is the adb boundary restated: whatever can run devicectl (or adb) as the user on the Mac is inside it. Same-user processes can also read the Mac's SharedPreferences, which hold the Wi-Fi identity today.
- usbmux (P5): `/var/run/usbmuxd` is world-writable, so any process of any user on the Mac can dial the app's port. The phone's loopback is shared, so another iOS app can squat 7001 while ours is closed.
- At rest on the phone: the token and certificate of each paired Mac, and a pairing waiting in the inbox.

PAIRING: DEVICECTL INSTEAD OF ADB
New host service `IosDeviceService` (`lib/shared/platform/ios_device_service.dart`, GetxService, registered in InitialBinding's host branch). It runs `/usr/bin/xcrun` at that fixed path, never resolved from `$PATH` (the same rule adb follows), always with `--json-output <tmp>` and a 20 s timeout, through an injectable process runner for tests.
- `list()`: `xcrun devicectl list devices`. Per device it reads the udid, `hardwareProperties.marketingName`, `connectionProperties.transportType`, `connectionProperties.pairingState` and `deviceProperties.developerModeStatus` (the paths devicectl uses today *(verified)*; the test fixtures use exactly these). Only devices with transportType `wired`, pairingState `paired` and developerModeStatus `enabled` are offered.
- `deliverPairing(udid)`:
  1. Bytes: `WifiPairingService.offerPayload()`. This is today's `HostSession._offerWifiPairing` body (identity, `macDisplayName()`, `WifiDiscoveryService.lanAddresses()` into `buildPairingPayload`), moved so both callers share it. The format is unchanged: 0xF6, version, host id, token, name, certificate, addresses.
  2. Write them to a 0600 file in a fresh 0700 `Directory.systemTemp.createTemp()`. Only the path appears in devicectl's argv, never the token, for the same reason adb's script goes through stdin.
  3. `xcrun devicectl device copy to --device <udid> --domain-type appDataContainer --domain-identifier <iosBundleId> --source <file> --destination 'Library/Application Support/ESInbox/pairing.bin'`.
  4. `xcrun devicectl device notification post --device <udid> --name <iosBundleId>.inbox`. A Darwin notification carries no data, so a forged one only makes the app look.
  5. Delete the temp directory in a `finally`.
  6. Optional: read `ESInbox/result` back with `devicectl device copy from`. The result names the delivery it answers (see below), so the Mac shows Paired or Refused for this Pair, never a stale answer, and otherwise Sent.
  It answers an `IosDelivery`: sent, stored, refused, noXcode, notPaired, devModeOff or failed.
- Trigger: a Pair button per iPhone in Settings → Wi-Fi (host only). Nothing is delivered automatically to a phone that is only charging. P4 may add a re-delivery when a paired iPhone is wired and the Mac's address list has changed.

iOS side: the inbox is pulled by Dart, never pushed by native code. A push at launch would reach no handler: `WifiPairingChannel` sets its method handler only in `onInit`, which runs from InitialBinding after `await settings.init()` and `runApp`, so an early `invokeMethod` answers not-implemented, and a file already deleted would be lost silently, in exactly the case the inbox exists for (a pairing waiting while the app was closed).
- Native, `PairingInboxPlugin.swift`, on `extended_screen/wifi_pairing` (the channel `WifiPairingChannel` already owns):
  - `takeInbox`: if `ESInbox/pairing.processing` exists (an earlier take that never got its answer, because the app was killed in between), return its bytes again. Otherwise rename `pairing.bin` to `pairing.processing` (atomic) and return its bytes, or null when there is none. A file over 4 KB is refused on the spot: deleted, result 2.
  - `inboxDone {result}`: write `ESInbox/result` (the result byte, 1 stored or 2 refused, then the first 8 bytes of the SHA-256 of the bytes it answers), then delete `pairing.processing`.
  - On the Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`) it invokes `inboxChanged`, a nudge with no data. If no handler is set yet, the nudge is lost and nothing else is: the file stays.
- Dart, `WifiPairingChannel` on iOS: pulls in `onInit` (the launch case), on each `AppLifecycleState.resumed`, on each `inboxChanged`, and every 2 s while Home shows "not paired". One pull at a time. It hands the bytes to `WifiPairingService.storePairing` (unchanged, with its existing checks: a known host id with a different certificate or token is refused, and loopback, zero, multicast and broadcast addresses are dropped), and only after that answers true or false calls `inboxDone`. If storing throws, it calls nothing, and the next pull takes the same file again.
- Native creates `ESInbox` at first launch and sets `NSURLIsExcludedFromBackupKey` on it, so a pairing waiting there (it holds the long-lived token) is never in an iCloud or Finder backup.
- `usbSession` is never called on iOS.
- The comment on `storePairing` changes from "only bytes adb delivered" to "only bytes adb or the devicectl inbox delivered, never from a packet".

Container hardening (load-bearing, because the container is the trust channel):
- ios/Runner/Info.plist never sets `UIFileSharingEnabled` or `LSSupportsOpeningDocumentsInPlace`, and declares no `CFBundleDocumentTypes`. Then Finder file sharing, the Files app and AirDrop cannot place a file in the container.
- The inbox lives under `Library/`, never `Documents/`.
- A test (or a CI grep over ios/Runner/Info.plist) fails if any of those keys appear.

At rest on the phone:
- From the first iOS phase, the iOS copy of each `PairedHost`'s token and certificate goes to the Keychain through the already-declared `flutter_secure_storage`, with `first_unlock_this_device` accessibility, so it is not carried by backups. Non-secret fields (name, addresses, lastAddress) stay in SharedPreferences. Android is unchanged.
- `WifiPairingService` gets a small secret-store seam with a SharedPreferences implementation (Android, tests) and a Keychain one (iOS).
- iOS Keychain items outlive the app's deletion, while SharedPreferences do not. So on a launch whose prefs hold no paired hosts and no `ios_keychain_owner` marker, the app clears its own Keychain entries first, then sets the marker. A token left behind by an uninstall is gone at the next install's first launch.

SESSION PROOF: UNCHANGED
The iPhone is a Wi-Fi client of the existing protocol. It pins the certificate (`connectSecure(trustCertificate: (der) => _pairing.hostForCert(der) != null)`, checked again after connecting), then sends `0xF5 + token`. The host's `admitPacket` admits nothing until `WifiIdentity.tokenMatches` passes in constant time, and every send goes through `_sendToClient`. No host auth code changes in P2 to P4.

P5 OVER USBMUX: TLS + 0XF5 OVER THE PIPE, NOT A NEW HMAC
- The Mac is the TLS server even though it opens the TCP connection. The iPhone pins the certificate, so a Mac process dialling through usbmuxd without the private key gets nothing. A squatting iOS app sees only the Mac's public certificate and cannot produce the token, so the Mac never sends it a frame.
- A relay gains nothing either: TLS runs end to end between the Mac and our app.
- No new packet, and no exception to "the host sends nothing before proof". In `admitPacket`, the `if (_wifiSession)` branch becomes `if (_tokenAuth)` (Wi-Fi or usbmux).
- Why not an HMAC keyed by the token: there is one token for all clients, so the Tab's app (or anything holding its prefs) would know the key and could pose as the Mac to the iPhone. Only the certificate's private key cannot be forged by a paired client.
- Why not the USB-first design's per-iPhone K with 0xF0/0xF4/0xF3: it only adds per-device revocation, at the cost of a pre-proof packet and a second key-delivery path. That stays an owner decision, folded into the per-device-token follow-up the multi-tablet doc already defers.

WHAT IS ON THE WIRE

| Byte | iPhone, P2 to P5 | Note |
|---|---|---|
| `0x01` HELLO | platform `0x03`, then width, height (uint16 BE, physical px, landscape) and top rate (1 byte) | The size is the area the client renders: by default the panel minus both safe-area insets (about 2496×1320; decision 15 can change it). The rate is the window scene's screen `maximumFramesPerSecond` (120; 60 under Low Power Mode). Old and new hosts read only p[2..6] (`_onHello`, host_session.dart), so p[1] = 0x03 is safe either way. Android keeps 0x02. |
| `0xF5` | first packet, the token | Over Wi-Fi in P2 to P4, and inside TLS over usbmux in P5. |
| `0xFC 0xFB 0xFA 0xFE 0xFF` | as on Android | 0xFB moves the decoder's queue cap and a CADisplayLink frame-rate hint. |
| `0xF9` | extendedScreen, or remoteControl + tabControlsMac | `SessionChoice.effective(link:)` already forces tabControlsMac over Wi-Fi; every session's spec comes from it through `SessionSpec.from` (session_choice.dart, session_spec.dart). |
| `0xF8 0xF7` | never sent to a Wi-Fi peer; the iPhone ignores them | — |
| `0xF6` | ignored, as on every link | Still the first byte of the pairing payload in the inbox file. |
| `0xF4 0xF3` | not used by the iPhone | They stay adb-USB only. |

Off the wire: the inbox file (the existing pairing bytes), the result file (1 byte plus 8 bytes of hash), and in P5 the usbmuxd plist exchange between the Mac app and its own usbmuxd.

Contingency only, if P0 shows devicectl delivery is unusable and the env fallback also fails: QR pairing with `0xF0` claim (client → host, pre-trust, one per connection, at most 1024 bytes, admitted only while the Mac's pairing window is open) and `0xEF` grant (host → client, after `_trustConnection`, through `_sendToClient`). These bytes avoid 0xF1/0xF2 (reserved by multi-tablet phase 5), 0xF3 to 0xFF (in use) and 0xF6 (retired). Android builds never send 0xF0, so they never see 0xEF. See *decisions*.

WHAT OLD BUILDS SEE
- Today's Tab build with the new Mac: nothing new reaches it. The Android HELLO is unchanged, and so is the host's parse of it. `wifi_listen` defaults to off; when the owner turns it on, a Wi-Fi Tab could also take the listener, as it would today on the Wi-Fi link. Arrangement (if P1 is built) defaults to auto, which moves nothing.
- The iPhone build with an old Mac: the old Mac never delivers a pairing through devicectl, so the iPhone stays unpaired and shows `wifi_client_not_paired_ios`. If it was paired by a new Mac that was later downgraded, the old host accepts its HELLO and renders it at panel ÷ 2 (no divisor, no fps cap) on display serial 1. That works, with smaller text and the Tab's display identity.
- New Mac with the iPhone: full.
- The tablet app never sees a byte from the iPhone path.

REVOCATION
As today. Mac: Settings → Wi-Fi → Reset Wi-Fi pairing. One shared token, so this also unpairs a Wi-Fi Tab. Afterwards press Pair on the iPhone row again. iPhone: Forget on the paired Mac's row in `_WifiClientCard`, which deletes the Keychain entry too.

DEVICECTL FALLBACKS, IN ORDER
1. Inbox with the app closed or the phone locked fails, but works with the app in front: the Pair button first runs `devicectl device process launch --activate <bundle id>`, then copies.
2. `copy to` fails outright: `devicectl device process launch --terminate-existing --activate <bundle id>` with the payload in a `DEVICECTL_CHILD_ES_PAIRING` environment variable, base64url-encoded. Never put it in argv: other users can read any process's arguments, while macOS restricts the environment (KERN_PROCARGS2) to the same user and root. Same-user is already inside the boundary. Native keeps it in memory, and Dart's first `takeInbox` returns it like an inbox file. This costs an app restart and no new packet.
3. Both fail: QR pairing with 0xF0/0xEF (about +2 to 3 days in P2). The Mac shows the QR only on request, in a window excluded from its own SCContentFilter, valid for 2 minutes and one use. The QR holds version, host id, the certificate's SHA-256, a 16-byte one-time secret and the addresses; the long-lived token is never on screen. The iPhone pins by that fingerprint and stores the grant only through a new `storeQrPairing(qr, grant)` that checks host id and `sha256(certDer)` against the QR. `storePairing` is never fed packet bytes. This is also the only path for a TestFlight or App Store build.

## client

FLUTTER iOS TARGET, SAME CODEBASE
The repo has no ios/ today. Toolchain here: Flutter 3.47.9, Xcode 27.0, CocoaPods 1.16.2. Do not run `flutter create --platforms=ios .` in the repo: it may recreate missing template files (`test/widget_test.dart`, which this repo does not have, references the template's `MyApp` and would break `flutter analyze` and `flutter test`) and rewrites `.metadata`. Instead run it in a scratch project with the same name and org, copy its `ios/` folder in, and add an `ios` entry to `.metadata`'s platforms by hand. Check `git status` afterwards: only `ios/` and `.metadata` may have changed.
- Bundle id: iOS-only, under the owner's reverse domain (`com.example.*` is likely refused by automatic signing). Keep it as `const iosBundleId` in `lib/shared/platform/ios_app.dart`, which the host passes to devicectl. The Android applicationId (`com.example.extendedscreen`, which the adb broadcasts target) is unchanged.
- Deployment target iOS 17: the phone runs 27, and 17 keeps the `sampleBufferRenderer` option for the layer sink.
- Signing: `DEVELOPMENT_TEAM = T4P27BU383`, development signing only (see *Distribution*). On a free team the profile expires after 7 days, so the owner reinstalls weekly with `flutter run --release -d <udid>`. Since iOS 14, a Flutter debug build only starts from `flutter run` or Xcode, so the installed app is a release build.
- Nothing is installed on the iPhone or the Tab without the owner's go-ahead.

Info.plist:
- `UISupportedInterfaceOrientations~iphone`: LandscapeLeft and LandscapeRight only.
- `CADisableMinimumFrameDurationOnPhone = true` (the template has it; without it Flutter caps the phone at 60 Hz).
- `UIStatusBarHidden`. (`UIRequiresFullScreen` only affects iPad multitasking; see *ipad* for how the iPad build handles windows that are not full screen.)
- `NSLocalNetworkUsageDescription`.
- Never `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` or `CFBundleDocumentTypes` (see *auth*).

NATIVE SWIFT (ios/Runner/)
- `AppDelegate.swift`: registers the plugins in the template's engine hook (in the 3.47 UIScene template, the implicit engine's `didInitializeImplicitFlutterEngine`; P0 confirms).
- `ExtendedViewController.swift`: a `FlutterViewController` subclass, set as the storyboard's class. It returns `preferredScreenEdgesDeferringSystemGestures = .all` while in /display (the Mac's Dock sits on the bottom edge; Flutter never sets this, so the first swipe would leave the app), `prefersHomeIndicatorAutoHidden = true` and `prefersStatusBarHidden = true`. A small channel `extended_screen/ios_system` has `setImmersive(bool)` (toggled by DisplayController), `openAppSettings` (for the Local Network guidance) and `thermalState` (read by the HUD, see below).
- `VideoDecoderPlugin.swift`: a port of `RemoteDecoder` (macos/Runner/RemoteVideoPlugin.swift, about 270 lines: Annex-B split, parameter sets, CMVideoFormatDescription, VTDecompressionSession, the latest CVPixelBuffer as a FlutterTexture, `textureFrameAvailable`, the `alive` guard).
  - Platform changes: `import Flutter`; `registrar.messenger()` and `registrar.textures()` are methods on iOS; no session prefix.
  - Output 32BGRA (`kCVPixelFormatType_32BGRA`, IOSurface, Metal-compatible), as `RemoteDecoder` does today (RemoteVideoPlugin.swift:218). VideoToolbox then applies the stream's own colour matrix. The Mac captures 420v (video range, ScreenCapturePlugin.swift:731) in BT.709, while Flutter's YUV texture path is believed to implement only BT.601, so NV12 output risks a hue shift in reds and greens; NV12 is only a P4 experiment, adopted if it measures cheaper and passes the same test pattern as P0 item 4.
  - `nal_feed` is registered with a background task queue (`registrar.messenger().makeBackgroundTaskQueue()`), so 60 to 120 frames a second are not handled on the main thread beside the UI. Decoder state is guarded for that thread, as `@Synchronized` does on Android.
  - It implements the Android channel contract, so `VideoDecoderChannel` barely changes: `extended_screen/video_decoder` `initialize {width, height, codec, fps}` (now returns the texture id; Android returns null), `setRefreshRate` (fps for the queue cap, plus a `CADisplayLink` `preferredFrameRateRange` hint), `requestIdr`, `getDropCount`, `dispose`, `getMaxRefreshRate` (the key window scene's `screen.maximumFramesPerSecond`; `UIScreen.main` is deprecated), and the BinaryCodec `extended_screen/nal_feed`.
  - Parity with VideoDecoderPlugin.kt: a queue cap of max(6, fps ÷ 10) with keyframe resume, then `awaitingKeyframe` (a Swift twin of `isKeyframeAccessUnit`); IDR requests throttled to 750 ms, backing off to 8 s; the drop counter; `onCodecError`; on `kVTInvalidSessionErr` after backgrounding, rebuild the session and request an IDR (RemoteDecoder today only asks for a keyframe).
  - The sink is switchable: `TextureSink` (default) and `LayerSink` (P4 experiment: an `AVSampleBufferDisplayLayer` under a transparent FlutterView, fed `DisplayImmediately` sample buffers). It is chosen by `--dart-define=IOS_VIDEO_SINK`, so the two can be compared on the device without redesign.
  - `os_log` under the bundle id, since release builds print no Dart logs.
- `BatteryStatusPlugin.swift`: `extended_screen/battery` `getStatus` → `{isCharging: .charging or .full, level: batteryLevel × 100}`. It sets `UIDevice.current.isBatteryMonitoringEnabled = true` at registration; without it iOS reports state unknown and level −1. Required: `HomeController.batteryStatus` does an unguarded `Get.find<BatteryChannel>()`.
- `PairingInboxPlugin.swift`: see *auth*.
About 650 lines of Swift in all.

DART CHANGES (no behaviour change on Android)
- `lib/app/bindings/initial_binding.dart:59`: the client branch runs for Android or iOS. On iOS it registers `ClientConnectionManager`, `VideoDecoderChannel`, `BatteryChannel`, `UsbSessionService` (inert; registered so no `Get.find` can throw) and `WifiPairingChannel`. It does not register `AndroidCaptureChannel`. The shared `WifiDiscoveryService` registration passes `broadcast: !Platform.isIOS`.
- `lib/main.dart:12`: the landscape lock also applies on iOS.
- `client_connection_manager.dart`:
  - `_capture` becomes nullable (`Get.isRegistered<AndroidCaptureChannel>()`), so `onTeardown → _stopReverseCapture` and the 0xF7/0xFF handlers do nothing on iOS instead of throwing on every Disconnect. 0xF8 never raises `needsScreenShare` on iOS.
  - HELLO: platform byte 0x03 on iOS. The size on iOS is `view.display.size` landscape minus the insets decision 15 picks (by default `view.padding.left + right`), rounded down to even. The rate byte stays the panel top rate. The builder is extracted as a pure function, so the fixtures test can call it.
  - The iOS lifecycle path (see *transport*): an override of `didChangeAppLifecycleState` that, on iOS only, ends the link on `hidden`/`paused` and `restartLink()`s on `resumed`, then defers to the base rule for everything else.
  - Local Network denied: iOS offers no query, so the client infers it. When a Wi-Fi attempt's probe gets no reply and every dial to a known address fails at once with the error a denied app gets (expected `No route to host`; P0 item 3 pins the exact one) on two attempts in a row, it sets `errorKey` to `error_ios_local_network`.
- `display_controller.dart:47`: `isAndroid` becomes `hasClientDecoder` (Android or iOS) for the decoder build, the codec and 0xFB workers, the drop counter and dispose. It keeps the texture id from `initialize` in an `RxnInt`, and calls `setImmersive` on open and close.
- `display_view.dart` `_VideoSurface`: on iOS, `Texture(textureId)` in a box with the stream's aspect ratio, centred (or on the side away from the Dynamic Island, per decision 15), black around it. `_TouchOverlay` is sized to that same box, because touches are normalized over the frame. The HUD shows a warning when `thermalState` is serious or critical.
- `settings_controller.dart` `_buildPermissionList`: on iOS, no battery or overlay rows. One informational Local Network row opens app settings.
- `SettingsService` on iOS: `init()` sets `linkTypeRx.value = LinkType.wifi`, and `setLinkType` does nothing. Every reader then sees Wi-Fi, including those that read the Rx directly (the `wifi` local at the top of `_ClientBody`'s and of `_HostBody`'s `Obx` in home_view.dart, `HomeController.isWifi` and `linkType`, `SettingsController.isWifi`), not only the `linkType` getter. Home's `_ClientBody` hides the link selector on iOS.
- Home on iOS: `_ClientBody` shows `error_ios_local_network` with an Open Settings button (`openAppSettings`) in place of the usual waiting text.
- Compact layout: the whole app is landscape-only, so Home, the pairing state, the Forget dialog and client Settings render at 956×440 pt less about 62 pt of inset on each side, while they were laid out for a tablet (the Home tests run at 800 px). `_ClientBody`, `_WifiClientCard` and client Settings get a compact variant below 480 pt of height: one column, smaller paddings, the paired-Mac rows scrolling, and the not-paired guidance in at most three lines.
- `WifiPairingService`: the Keychain secret store on iOS; `offerPayload()` (host).
- Translations (en and th): `wifi_client_not_paired_ios` ("Plug the iPhone into the Mac and press Pair in the Mac's Settings → Wi-Fi"), `link_wifi_desc_ios`, `settings_local_network`, `error_ios_local_network` ("Local Network access is off for this app. Turn it on in Settings → Apps → Extended Screen"), `display_thermal_warning`, `error_ios_app_not_open` (P5). `display_surface_android_only` stays for other platforms.

SHARED AND UNCHANGED
ClientConnectionManager's Wi-Fi path, admitPacket, control dispatch, heartbeat and retry; SocketService's TLS client (dart:io/BoringSSL); WifiPairingService parsing and storePairing; `TouchGestureRecognizer` (pure Dart; retune slop and gains in P4, since an iPhone is about 956×440 pt); the HUD, `_HudHandle` and `_ReconnectingOverlay`; `wakelock_plus` (`isIdleTimerDisabled`); immersiveSticky. The iPhone forwards no keyboard input, like the Tab.

HEAT, BATTERY, POWER
- Continuous HEVC decode on a 120 Hz OLED panel heats the phone and drains it, and on Wi-Fi it is often unplugged. P3's owner check measures it (an hour of streaming). The 60 fps default and BGRA decode at the encoded size (1664×880) keep the load moderate.
- iOS throttles decode and dims the screen at `thermalState` serious or critical. P2 shows a HUD warning then; the owner can lower `max_fps` for the iPhone on the Mac. A client → host thermal hint that lowers the cap by itself would be a new packet (iOS-only sender), decision 17, default no.
- Low Power Mode caps ProMotion at 60 Hz. The HELLO rate reads 60 then, so the host's 60 default already matches.
- If the phone ends up cabled to the Mac for charging anyway, that strengthens the case for usbmux (decision 1).
- OLED burn-in: the Mac's static menu bar (shown on every display when "Displays have separate Spaces" is on) and any always-on window sit on the same pixels for hours while the wakelock keeps the screen on. Mitigations: "Automatically hide and show the menu bar" on the Mac, keep the Dock on the MacBook, and an optional P4 idle dim (a 50% black overlay after 10 minutes with no touch and no new frame, lifted by a touch).

NEVER ON iOS OR iPadOS
Reverse remote (macControlsTab). iOS has no input injection, and capturing the screen would need a ReplayKit broadcast extension with App Groups, which a free team cannot sign. The host already never sends 0xF8 over Wi-Fi.

## ipad

VERDICT
The same Flutter iOS target ships as a universal app (`TARGETED_DEVICE_FAMILY = "1,2"`). Everything above applies unchanged: the Wi-Fi TLS link and 0xF5, devicectl pairing into the app container, the VideoToolbox decoder plugin, the iOS lifecycle path, the Keychain store, and P5's usbmux path. Five things differ for an iPad, and they are what this section covers: the window is not always the whole panel, the panel is 4:3 and roomy, the iPad needs a profile of its own, Pencil and keyboards could do more than touch, and Sidecar already exists. **The iPhone and an iPad at the same time need two Wi-Fi clients, which the P3 beside slice does not have (one `wifi` session).** The Tab plus one Apple device works after P3; the Tab plus an iPhone plus an iPad needs multi-tablet phase 4's multi-client listener (or P5's usbmux, where each device is its own USB session).

WINDOW SIZE, NOT PANEL SIZE
On iPadOS the app's window can be smaller than the display: Split View and Slide Over, Stage Manager windows, and the windowing introduced with iPadOS 26. `UIRequiresFullScreen = YES` opted out of multitasking until now, but Apple has announced it as deprecated in iPadOS 26, and a later release may ignore it *(P0: check what iPadOS 26/27 do with it on the owner's iPad, if there is one)*. The design therefore does not rest on it:
- Set `UIRequiresFullScreen` anyway while it is honoured, so the common case is full screen.
- HELLO on iPad reports the **window scene's size in physical pixels** (its `coordinateSpace.bounds` × `screen.nativeScale`, landscape, minus the safe area, rounded down to even), not `view.display.size`. On Android and iPhone the window is the panel, so nothing changes there.
- A window that changes size while streaming (the user resizes it in Stage Manager, enters Split View) is a new panel: after it has been stable for 1 s, the client runs `restartLink()`, so the host rebuilds the session at the new size (a brief blip; the encode budget re-admits it as a return). Rotation does not happen (landscape-only, `UISupportedInterfaceOrientations~ipad`: LandscapeLeft and LandscapeRight).
- Without this, a window smaller than the reported panel would show the picture squeezed, as the foldable emulator did on Android.

PANEL, TEXT SIZE AND RATE
- iPads are about 4:3 (iPad Pro 13-inch 2752×2064, iPad Air 13-inch 2732×2048; the 11-inch models about 2420×1668). The host already sizes everything from HELLO, so a 4:3 virtual display needs no new code.
- Text size: an iPad is held like the Tab, so the default divisor is **2** (as for Android), giving the iPad's own point size (1376×1032 pt on a 13-inch Pro). Choices 2, 2.5 and 3 as for the iPhone.
- Rate: ProMotion iPads (Pro) report 120 through `maximumFramesPerSecond`, others 60. Default `max_fps` for iPad: none (the budget decides), as for the Tab. Load: a 13-inch Pro at native and 120 Hz is about 682 Mpx/s, the same class as the Tab (656), so the Tab and an iPad Pro together share the encoder at 60 fps each, the way two tablets do today.
- Safe area: no Dynamic Island; the rounded corners are small. Default: the full window, no crop (decision 15 is about the iPhone).

PLATFORM BYTE AND PROFILE
- HELLO platform byte `0x04` for iPad (`UIDevice.current.userInterfaceIdiom == .pad`), `0x03` stays the iPhone. Hosts read only p[2..6], so old hosts are unaffected, as for 0x03.
- Profile key `ipad` (beside `iphone` and `wifi`): its own `client_panel.ipad`, `display_divisor.ipad` (default 2), `max_fps.ipad` (default none), `vd_serial.ipad` (FNV, never 1) and name "Extended Screen – iPad". Like `iphone`, it assumes one iPad until multi-tablet phase 4 keys Wi-Fi clients by install id (the migration under *host* covers `ipad` the same way).
- The global last panel is not written by an iPad HELLO either (`global: platform == 0x02`).
- The card's chip reads "iPad".

INPUT BEYOND TOUCH (LATER, OPTIONAL)
- Apple Pencil: UIKit delivers it as touches, and Flutter as `PointerDeviceKind.stylus`. P2 must check that `TouchGestureRecognizer` accepts stylus pointers as fingers (if it filters by kind, the Pencil does nothing). Hover, pressure and tilt would need new mouse/tablet fields on the wire and tablet events on the Mac: not planned.
- Hardware keyboard (Magic Keyboard, Smart Keyboard): the protocol already has `KEY_EVENT` and the host already injects it (`InputInjectPlugin.injectKey`), but no client sends one. An iPad keyboard forwarded to the Mac is the single biggest gain over touch for an iPad; it needs a key map (iPadOS key codes to macOS virtual key codes and modifiers) and a decision on which shortcuts stay with iPadOS (⌘Tab, ⌘Space, Globe). Proposed as an optional phase after P4 (decision 19).
- Trackpad and mouse on iPad: Flutter reports them as `PointerDeviceKind.trackpad`/`mouse` with hover. Mapping hover to `MouseAction.move` and the two-finger scroll to the existing scroll packet would make an iPad with a Magic Keyboard feel like a Mac display. Same optional phase.

SIDECAR
macOS's own Sidecar already extends a Mac onto an iPad, wired or wireless, with Pencil and keyboard support. What this app adds for an iPad: it runs beside the Android tablets under one app, one encoder budget and one arrangement, with more than one extra display; Sidecar drives one iPad at a time and nothing else. If the owner's only goal for an iPad were a single extra display, Sidecar is the better tool today; decision 18 asks whether the iPad is worth the extra work at all.

TESTING WITHOUT HARDWARE
- The iPad simulator runs the universal build on the Mac. It shares the Mac's network, so it can dial a Mac dev build on 127.0.0.1 over the Wi-Fi link (the dev port from *Test isolation*), and VideoToolbox decodes H.264 and HEVC there in software.
- Pairing for the simulator does not need devicectl: `xcrun simctl get_app_container <udid> <bundle id> data` gives the container path on the Mac, and the test copies the pairing bytes into `Library/Application Support/ESInbox/pairing.bin` directly. A debug-only host button or a script does it; nothing in release builds.
- Stage Manager and Split View resizes can be exercised in the simulator, which tests the window-size HELLO and the 1 s relink.
- Latency, heat and Pencil need a real iPad.

PHASES
The iPad joins the existing phases; it adds no phase of its own except the optional input one.
- P0: if an iPad is available, run items 1, 3, 4 and 7 on it too, and check `UIRequiresFullScreen` on its iPadOS version. Without one, the simulator covers the window-size path.
- P2 (+1 to 1.5 days): universal target, `~ipad` orientations, platform 0x04, the window-size HELLO and the stable-size relink, the `ipad` profile and defaults, the stylus check in TouchGestureRecognizer, the iPad simulator test path. Tests: HELLO builder fixtures for 0x04 (window size, safe area); a fake window resize relinks once after 1 s of stability, never during a resize; `configFor` at divisor 2 for a 4:3 panel; `vd_serial.ipad` is never 1 and never `iphone`'s.
- P3: one Apple device beside the Tab, iPhone or iPad. Both at once waits for multi-tablet phase 4 (decision 18).
- Optional P6, keyboard and trackpad from iPad (2 to 3 days): KEY_EVENT from a hardware keyboard with a key map and a reserved-shortcut list; trackpad hover and scroll as mouse packets. Host side needs no change beyond what `injectKey` does today, except verifying it with real key codes.

## host

SESSION KINDS AND IDENTITY
- P2 to P4 add no device kind. The iPhone is a Wi-Fi `HostSession` (key `wifi`). The session records each attempt's HELLO platform byte in `platform` (0x02 Android, 0x03 iOS, null before HELLO or for an unknown value). It is used for:
  - the card's chip ("iPhone");
  - the profile key, below;
  - not writing the global last panel. `SettingsService.setClientPanelFor` writes `client_panel.<key>` and the global `client_panel_w/h/max_hz`. That global value is the fallback for Home's `wouldFit` and for a new Tab's first config. An iOS or iPadOS HELLO writes only its per-key value, otherwise the iPhone's 2496×1320 (or an iPad's window) would become a new Tab's guess. Implemented as a `global: platform == 0x02` argument (a HELLO without the platform byte counts as Android, as today).
- Profile key. A Wi-Fi session's per-device identity follows the peer, not the link: `profileKey` is the USB serial for a USB session, `iphone` for a Wi-Fi session whose HELLO said 0x03, and `wifi` otherwise. Everything per device is keyed by it: `client_panel.<profileKey>`, `display_divisor`, `max_fps`, and its place in each `display_layout.<setKey>` if P1 is built.
- Virtual display identity. The display is made after HELLO (in `_startCapture`), so a Wi-Fi session's `vdSerial` and `vdName` are set from that attempt's HELLO, before the display is first made, and stay fixed while that peer is connected:
  - iOS, on every link (the Mac's link Wi-Fi in P2, beside USB in P3): `vd_serial.iphone` if saved, else `vdSerialFor('iphone', taken: <every live session's vdSerial>)`, saved to `vd_serial.iphone` on its first live session; name "Extended Screen – iPhone". Never 1. So the iPhone has one UUID, with its own saved placement, in P2 and P3 alike, and never lands where macOS last put the Tab.
  - Android over the Wi-Fi link: 1 and "Extended Screen", as today, so a Wi-Fi Tab keeps its USB display identity.
  - Android beside USB (P3): `vdSerialFor('wifi', taken: …)`, since 1 may belong to the USB Tab. Such a tablet does not share its USB display identity; that is the cost, and it is today's behaviour for nobody (beside does not exist yet).
  - CLAUDE.md's "A session is fixed for its life: … `vdSerial` and `vdName`" gains the Wi-Fi exception.
- `taken`: every live session's vdSerial, whatever its link, the beside one included. Today the `taken:` set in the hub's `_sessionFor` is built from USB sessions only, so a new USB tablet could be handed the beside session's serial.
- P5 adds `DeviceKind { android, ios }` on `DeviceModel` (plus `udid`), key `ios:<UDID>`, `serial: null`, and a third connect path in `HostSession` (`_connectUsbmux`: detectingDevice from the usbmux listing, the in-attempt dial loop, `adoptClient`, TLS server upgrade, 0xF5). Every adb-shaped path is guarded on kind: `TabletTunnels.claim`, `removeForward`, ScreenHold, `sendRemoteTap/Swipe`, the mDNS duplicate filter, `isEmulator`, and `tunnelLost`'s transport rule (fed by Detached events instead). The usbmux session's profile key is `iphone` too, so it keeps the same display identity, Position and encode settings as over Wi-Fi. The auto-connect policy takes an iPhone only once it is known (it has had a live session). An unknown iPhone never counts for the first-run rule, so a phone on charge never stops the Tab connecting by itself.

DISCOVERY
The responder is one shared `WifiDiscoveryService`. It runs while the `wifi` session listens and stops once a client authenticates (the stop is inside the Wi-Fi trust branch of `HostSession.admitPacket`). It answers the iPhone's unicast probes as it answers the Tab's directed ones. One fix: every `HostSession.onTeardown` stops it with no check on the link (the `stopResponder()` right after it gives up its budget share), so in P3 any teardown of the Tab's USB session (replug, settings reconnect, retry, a failed wake rebuild) would stop the responder the beside listener relies on, until that listener re-listens; the iPhone, unicast-only, would then fall back to blind dials. The stop is guarded with `link == LinkType.wifi`.

HUB: WI-FI BESIDE USB (P3), A SLICE OF MULTI-TABLET PHASE 4
Since multi-tablet phase 3, `cap` over USB is `min(maxTablets, tabletCap ?? 8)` in every session mode (it used to drop to 1 outside Extended screen) and 1 over Wi-Fi, and the Wi-Fi session still runs only when the Mac's link is Wi-Fi. So the goal (Tab on USB, iPhone on Wi-Fi) needs this slice. It is what docs/multi-tablet-design.md decision 10 describes, minus the multi-client listener and the HELLO identity tail.
- Setting: `SettingsService.wifiListenRx`, key `wifi_listen` (the name the multi-tablet doc uses), default false, host only, saved with no reconnect.
- Gate: `_wifiBeside = wifiListen && linkType == usb && cap >= 2`. No session mode is in it: since multi-tablet phase 3 the mode belongs to each session, not to the app, and `cap` no longer depends on it.
- Mode: the beside session reads its own `choice`, like every session the hub makes (`HostSession.choice`, final; `connectWith` gives it `knownChoice(wifiKey) ?? nextChoice`, and nothing is known for `wifi` yet). Its `spec` is `SessionSpec.from(choice, wifi, …)`, so `SessionChoice.effective` makes any remote-control choice Tablet → Mac. The Tab can extend while the iPhone is a remote screen, or both extend; what the USB tablets run as does not reach it, and Home's selectors (the mode of the next session made) reach it only when it is made. Changing it while it runs is `hub.changeMode(wifiKey, choice)`, which ends it and makes a new one.
- Choosing: with `_wifiBeside`, `_choose` handles `serial == wifiKey` as key `wifi` on link Wi-Fi, without reading `settings.linkType`. `_start(wifiKey)` passes the key (today it passes null).
- Focus: `connect({serial, focus = true})`. The listener starts with `focus: false`. `_refocus` never picks a beside session whose peer is not trusted, so the facade (and with it the hub's phase, which the first-run rule reads) never shows the listener. Once trusted, the beside session can be focused by a tap on its card, or by `_refocus` like any other.
- Listening means "peer not trusted". A beside session counts as listening, whatever its phase, until `peerTrusted`: anything on the LAN can complete a TLS handshake and keep the session waiting for its token for 3 s, again and again, so a phase-based test ("handshaking, no client accepted") would let a stranger take a cap place, read as connecting in `anyConnecting` and `_onLinkTypeChanged`, and hide Home's selectors.
- Budget place. A beside session holds a place in the `EncodeBudget` only while its peer is there. Its teardown releases its place (`_releaseBudget`) instead of reserving it: today a non-retired teardown reserves (the `_reserveBudget()` branch at the top of `onTeardown`), and a Wi-Fi session that falls back to listening re-listens indefinitely, so the reservation would count under the budget's cap and, at its floor, in every other admission's plan, for an iPhone that may be in a pocket. The hub sets this per session (`releaseOnPeerLoss`, true for the beside session). The iPhone's return is then an ordinary admission; if the cap was reached meanwhile, it is refused like a new tablet (`error_encode_limit` on its card, the listener stops, Retry on the card).
- Counting: one rule for both counts. `besideHolds` = the beside session's peer is trusted, or it holds a budget place (only during P4's grace period). `sessionCount = usbSessionCount + (besideHolds ? 1 : 0)` replaces `usbSessionCount` in `canAdd`, the cap check in `_choose`, the budget's cap callback and Home's `home_tablets_count`. Without the release rule, with Maximum tablets 2, the Tab live and the iPhone backgrounded, `canAdd` would let a second USB tablet through and `budget.admit(cap: 2)` would refuse it with a terminal `CaptureLimit`.
- Handshake deadline. `SecureServerSocket` has no handshake timeout, so an idle connection that never finishes TLS is held for good. The beside listener (and the Wi-Fi link's, since it is the same code) binds a plain `ServerSocket` and upgrades each connection with `SecureSocket.secureServer` under a 3 s deadline, then installs it with `SocketService.adoptClient`. This is the listener primitive multi-tablet phase 4 needs anyway, built once here.
- Auto-connect policy: in the USB branch, when `_wifiBeside` holds and no `wifi` session exists, and `wifi` is neither in `stoppedDevices` nor in `_starting`, call `_start(wifiKey)`. The first-run rule ("no session, nothing starting, hub disconnected, exactly one candidate") counts only USB sessions and USB starts. An `ever(wifiListenRx)` worker runs the policy when the toggle is turned on and calls `disconnectSession(wifiKey)` when it is turned off. Nothing about a mode ends the beside session: only the toggle, a link change, or `cap` falling under 2 (Maximum tablets set to 1).
- Guards that must ignore a listening session: `_onLinkTypeChanged`'s "any connecting or live" check; `anyConnecting`; Home's rule for showing the mode, direction and link selectors. On a link change, the beside session ends and the ordinary rules for the new link apply.
- Home `_HostBody`, USB layout: the `wifi` session gets a `SessionCard` among the others (sorted by key, so `R52…` and `emulator-…` come first). While listening it shows `home_wifi_waiting` plus the Mac's addresses (reusing the address card's widget). The add panel gets a "Listen on Wi-Fi (iPhone)" switch bound to `wifiListen`. The card's Cancel → `onSessionStop('wifi')` (into `stoppedDevices`); Retry → `allowDevice('wifi')` and connect.
- Otherwise a Wi-Fi `HostSession` already has what it needs: its own `nativeId`, `InputState`, `VirtualDisplays` membership, `EncodeBudget` admission and place in the ordered FB17797423 rebuild rounds; it follows `identityWasReset`, and its retry re-listens after 1 s.

PAIRING UI (P2)
Settings → Wi-Fi (host only) gets an "iPhones" list from `IosDeviceService.list()`, refreshed when the card opens. Each row shows marketingName and the last 6 characters of the UDID, with a Pair button (spinner, then the `IosDelivery` result). Without Xcode it shows `settings_iphone_no_xcode`, and with Developer Mode off `settings_iphone_dev_mode`. Keys: `settings_iphones`, `settings_iphone_pair`, `settings_iphone_sent`, `settings_iphone_paired`, `settings_iphone_refused`, `settings_iphone_no_xcode`, `settings_iphone_dev_mode`, `error_ios_pair_failed`.

MODES PER DEVICE
- Extend and Mirror: as for any session.
- Remote control: tabControlsMac only, already forced over Wi-Fi by `SessionChoice.effective(link:)`, which every session's spec goes through (`SessionSpec.from(choice, link, …)`). In P5 (usbmux, a link `effective(link:)` does not clamp) the session applies `effective(android: false)` after an iPhone's or iPad's HELLO has said what it is (`HostSession.platform`, which the ios-p0-spike branch adds; the pure rule and its test exist already), and Home's direction selector disables Mac-controls-tablet while an iPhone is picked or has a session. Not in `SessionSpec.of`: since multi-tablet phase 3 that factory only reads Home's selectors (`settings.nextChoice`) and no session is built from it.
- The session mode is per session since multi-tablet phase 3 (done before P3): the beside session has its own `choice` (see the hub slice above), and remote control on any tablet no longer means cap 1, so it stops no listener.
- OWNER REQUIREMENT (met for Android tablets over USB by multi-tablet phase 3, which was built before the iOS phases; the iPhone's part needs P3's beside slice): modes mix across devices, one mode per device. Example: Mac in the centre, the Tab S10 Ultra extending, the iPhone as a remote screen (the iPhone controls the Mac: tabControlsMac, a mirror of the main display with input). A device never runs two modes: an iPhone in remote screen is not also an extended display, and an extended iPhone is not also a remote screen. Nothing in P0 to P5 may assume the mode is global: it is each session's own `choice` already, and the beside gate, `SessionSpec`, the card's mode chip and the cap rule read that.

ENCODE SETTINGS PER DEVICE (P2), HOST-SIDE
HELLO keeps meaning "physical pixels the client renders". Readability and load are set on the Mac, per profile key:
- `display_divisor.<profileKey>`: 2, 2.5 or 3. The default comes from the platform: 3 for iOS, 2 for anything else (so nothing changes for the Tab).
- `max_fps.<profileKey>`: none, 60, 90 or 120. Default 60 for iOS, none otherwise.
- `EncodePresetX.configFor(panel, ..., divisor:, fpsCap:)`: logical size = panel ÷ divisor, scale 2 (Performance: 1), dimensions even. For divisor 2 the logical size is computed exactly as today (`panel ~/ 2`), and only other divisors go through `(panel / divisor).floor()`, so Android's numbers stay identical, odd panel sizes included. Custom: scale = customWidth ÷ (panel width ÷ divisor), clamped to 0.5..2.0 as today, which is today's formula at divisor 2. The refresh rate is min(preset rate, fpsCap). Max's bitrate is computed from the encoded pixels × the capped rate when a cap or a divisor other than 2 applies, and exactly as today otherwise. `captureConfigFor(panel, spec, divisor:, fpsCap:)` takes them from `settings.displayDivisorFor(profileKey, platform)` and `maxFpsFor(profileKey, platform)`, read through the session as CLAUDE.md's rule for HostSession requires. known_devices_test asserts that every Android preset, Custom included, gives today's config at divisor 2 with no cap, for an even and an odd-sized panel.
- Settings → Tablets: Text size and Max fps rows per known device, for the iPhone and for the Wi-Fi display. A change reconnects that session only (a new `hub.reconnectSession(key)`), not every tablet.
- The `iphone` key assumes one iPhone. A second iPhone would share its profile and display identity until multi-tablet phase 4 gives Wi-Fi clients their own keys.

For the owner's phone (default safe-area crop 2496×1320, about 460 ppi; MacBook about 127 pt per inch):

| Divisor | Mac desktop (pt) | Encoded | Text vs MacBook | Mpx/s at 60 / 120 |
|---|---|---|---|---|
| 3 (default) | 832×440 | 1664×880 | ~83% | 88 / 176 |
| 2.5 | 998×528 | 1996×1056 | ~69% | 126 / 253 |
| 2 | 1248×660 | 2496×1320 | ~55% | 198 / 395 |

At ÷3, 440 pt is short: windows with a larger minimum height don't fit. ÷2.5 is the fallback. Whether macOS accepts an 832×440 pt HiDPI virtual display is P0 item 7.

ENCODE BUDGET
The only `EncodeBudget`-related change is the beside session's release rule above; admission itself is unchanged. The iPhone is one more admission with its own panel. The numbers below use the learned M3 Pro H.265 capacity, 772.25 Mpx/s in the host's preferences (`encoder_capacity.apple-m3-pro.h265`) *(verified at review time)*, so about 656 usable. The Tab at 2960×1848 and 120 Hz is 656 Mpx/s on its own.
- iPhone ÷3 at 60 (88): the Tab steps to 90 (492). 492 + 88 = 580, which fits. Tab 90, iPhone 60.
- iPhone ÷3 at 120 (176): 492 + 176 = 668, over. The Tab steps to 60 (328). Tab 60, iPhone 120.
- iPhone ÷2.5 at 60 (126): 618, which fits. Tab 90.
- iPhone ÷2 at 60 (198): 690, over. Tab 60.
So the defaults (÷3, 60) cost the Tab 120 → 90. The Max fps row says so (`settings_max_fps_hint`). The capacity probes may learn more later.

RELATION TO THE MULTI-TABLET ROADMAP
UPDATE: multi-tablet phase 3 was built first, on main's line, before iOS P1 to P3 (see docs/multi-tablet-design.md, PHASE 3, and docs/phase3/impl_results.md). So the ios-p0-spike branch merges onto a per-session mode, and what this section says phase 3 would do later (`_wifiBeside` reading the beside session's own mode) is how P3 is written from the start, as the hub slice above already says. The rest of this section is the order as planned before that, kept for the phase 4 and phase 5 hand-overs.
Multi-tablet phase 3 (per-tablet mode, the remote grid, InputShell) is next on that roadmap; phase 4 owns the hub's Wi-Fi listener, `wifi_listen` and `adopt`; phase 5 owns `device_profile.<key>`. Decision 14 asks which goes first. The default is iOS P0 to P3 first, then multi-tablet phase 3:
- P0 is a spike in a branch and collides with nothing.
- P2 and P3 touch `_onHello`, `configFor`, `_choose`, `_refocus` and the counts; phase 3 touches the mode and the remote view. Phase 3 then makes `_wifiBeside` read the beside session's own mode instead of the global one.
- Built once, here, and kept by phase 4: `SocketService.adoptClient` (phase 4's `adopt`), the handshake-deadline listener, the `wifi_listen` key and its toggle, the responder ownership fix.
- Replaced by phase 4: the single `wifi` beside session becomes the hub-owned listener's sessions `wifi:<installId>`. The iOS build is the same Dart client, so it sends the HELLO identity tail too. Migration, once: the first iOS installId the hub sees takes over the `iphone` profile: `vd_serial.iphone`, `client_panel.iphone`, `display_divisor.iphone`, `max_fps.iphone` (and the `iphone` entries and set keys of `display_layout.*` if P1 exists) are copied to `wifi:<installId>` (the vdSerial into its `known_devices` row) and the old keys deleted, so the display UUID and its placement survive. A test covers it.
- Replaced by phase 5: the divisor, fps cap and Position become fields of `device_profile.<key>`, migrated once from the per-key prefs.

## arrangement

GOAL (revised by the owner)
No fixed layout. The owner arranges the displays however they like (any side, any offset; Tab left, MacBook centre, iPhone right is just one example) and chooses which display is the main one (the one with the menu bar and the Dock), which may be the MacBook, a tablet or the iPhone. Whatever they chose must come back by itself through replugs, wakes, settings reconnects and the FB17797423 rebuild rounds, for every combination of devices that is connected.

HOW MACOS REMEMBERS IT TODAY
- macOS stores display origins, and which display is main, per set of display UUIDs (`/Library/Preferences/com.apple.windowserver.displays.plist`, DisplayAnyUserSets; 24 sets on this Mac).
- A virtual display's UUID is mapped by WindowServer from the display's identity: `DisplayUUIDMappings_v3.UUIDEntryMap` maps a hashed identity key to a freshly minted random (v4) UUID (the Tab's is 9B8FC3FF-…-43AB-…) *(verified)*. Vendor 0x3456, product 0x1234 and `serialNum` (the session's `vdSerial`) are surely part of that key; whether `maxPixels` or `sizeInMillimeters` (computed from the logical size at 220 ppi) are too is unknown. If they are, changing the iPhone's divisor (832×440 vs 998×528) would mint a new UUID and lose its saved arrangement; a check (in P2, or P1) changes the divisor of one vdSerial and looks for a new UUID, and if one appears, `maxPixels` and the millimetre size are pinned per vdSerial (the largest mode it may need) rather than per mode.
- The Tab's display (vdSerial 1) is saved to the RIGHT of the MacBook (1728×1117 at 0,0), at OriginX 1728, OriginY 115 *(verified at review time)*.
- A new UUID set starts with macOS appending the new display, usually on the right.
- Nothing in macos/Runner positions displays or changes the main display.

STEP 1: SYSTEM SETTINGS, NO CODE
System Settings → Displays → Arrange already does both things the owner asked for: drag each display where you want it, and drag the white menu-bar strip onto the display that should be main. Every managed display has a stable vdSerial (the iPhone's `vd_serial.iphone` included), so macOS keeps one saved arrangement per combination ({MacBook, Tab}, {MacBook, Tab, iPhone}, {MacBook, iPhone}, …) and restores it when that combination comes back. Each combination is arranged once, the first time it appears. Whether a combination survives the app's own events is not asserted: an ordered rebuild removes every virtual display and makes them again in key order, so for a moment the set is the MacBook alone, then partial sets. Runbook step 0 tests the Tab alone (replug, sleep and wake, a settings reconnect), and P3's owner check repeats it with the Tab and the iPhone, with the main display on the MacBook and once with it on the Tab. If any layout or main display does not come back, P1 is built.

A main display on a tablet or the iPhone has a cost the owner should know before choosing it:
- When that device goes away (unplugged, the iPhone locked or switched away from, a link lost), macOS moves the menu bar, the Dock and the windows to another display at once, and moves them back only if the same combination returns. With the iPhone as main, every lock moves the menu bar to the MacBook.
- During an ordered rebuild (a tablet joining, a replug, a wake) every virtual display is removed for about a second, so a virtual main display hands the menu bar to the MacBook and gets it back with the next set. That is a visible blip on each change.
- Default: the MacBook stays main; a tablet as main is supported, the iPhone as main is allowed with the warning above.

P1 (IF SYSTEM SETTINGS DOES NOT HOLD, OR THE OWNER WANTS IT IN THE APP): IN-APP LAYOUT
The app keeps the owner's layout itself and puts it back after every event, using the same public CoreGraphics calls System Settings uses.
- Saved state, per combination: `display_layout.<setKey>`, where setKey is the sorted list of profile keys of the managed displays connected (e.g. `R52XC02C9RT+iphone`). Each entry holds, per profile key, the origin relative to the MacBook's built-in panel (the anchor; with the lid closed, the main physical display), and which display is main (`main: builtin | <profileKey>`). Relative origins keep a layout valid when the MacBook's own resolution changes.
- Capture, not invent: the owner arranges in System Settings (or in the app's editor, below), and the app records what it sees. `ScreenCaptureChannel.listDisplays()` (`[{id, x, y, w, h, builtin, main, mirrored}]`), mapped to profile keys through `hub.displays` holders, is saved when the owner presses "Remember this layout" in Settings → Tablets, and, if "Follow System Settings" is on (default), automatically 3 s after a display change that the app did not cause (onDisplayBoundsChanged while no rebuild or arrange op is running).
- Restore: when a combination with a saved layout appears, the app applies it, including the main display.
- Optional editor (Settings → Tablets → Arrange): a small canvas of the connected displays drawn to scale, dragged with snapping to edges, and a "Make main" action per display. It writes the same saved layout and applies it. Without the editor the feature still works through System Settings plus Remember.

Planner: `lib/shared/connection/display_arrangement.dart`, pure Dart, unit-tested without CoreGraphics.
- Input: the active displays, the managed placements (display id → profile key) and the saved layout for the current combination.
- Output: the origins to set and the display to make main, only where they differ from what is on screen (a second run returns nothing).
- Main display: CoreGraphics makes main whichever display ends at (0,0). To make display M main, every origin (the MacBook's included) is translated by −M.origin in the same configuration, so the relative layout is kept and M lands at (0,0). Making the MacBook main again is the same translation with the built-in panel.
- Displays in a mirror set are skipped. Displays the app does not manage (a physical monitor) keep their place relative to the anchor.
- With no saved layout for a combination, nothing is moved (macOS's own placement stands) until the owner arranges and remembers it.

Native: `arrangeDisplays {placements: [{displayID, x, y}]}` (a placement list that includes the MacBook's panel when the main display changes) on `ScreenCapturePluginImpl`, main thread, answering `{applied, moved, failed}`. It runs `CGBeginDisplayConfiguration`, `CGConfigureDisplayFadeEffect(cfg, 0, 0, 0, 0, 0)` (no fade; whether the screens still blink is checked in P1's Mac check), `CGConfigureDisplayOrigin` per entry, then `CGCompleteDisplayConfiguration(cfg, .permanently)`, as displayplacer does without privileges. Permanently, not ForSession or ForAppOnly: macOS itself then restores each UUID set next time, so after the first placement no rebuild shows a jump. With the session-only options, macOS would restore its own spot first and the app would move it back on every set change. The call can fail while an app is full screen. It then answers `failed: true` and is retried on the next trigger, never in a loop.

When it runs (Dart, always inside the queue, never a nested `pipeline.run`):
1. In `HostSession._startAdmitted()`, right after `createVirtualDisplay` answers a display id and before `startCapture`, placed before the budget ceiling is re-read (CLAUDE.md requires no await between that read and `startCapture`). It is followed by an `isCancelled(attempt)` check that bails out the same way the other awaits there do. The stream then starts on a display that is already placed, and the display being moved has no SCStream yet.
2. Once at the end of `_rebuildRound()` and `_rebuildAll()`, inside their `pipeline.run`, after every start. This is also what gives a virtual main display its menu bar back after a round.
3. On `onDisplayBoundsChanged` caused by something else (a monitor plugged in, the lid closed), debounced 0.5 s through a hub timer that queues an arrange op. Moving a display itself raises this event, and the planner then finds nothing to do. A change the owner makes in System Settings is instead recorded as the new layout ("Follow System Settings"), never undone.
Input needs no change: taps map through each session's `CaptureContentRect` and its `capturedDisplayID` bounds, which the bounds-changed event refreshes.

Examples: saved {Tab at (−1480, 115) relative to the MacBook, main builtin}: the Tab's display, appended by macOS at (1728, 115), is moved to (−1480, 115). Saved {Tab at (−1480, 115), iPhone at (1728, 339), main R52XC02C9RT}: every origin is translated by (+1480, −115), so the Tab lands at (0,0) and becomes main, the MacBook at (1480, −115) and the iPhone at (3208, 224).

Unknown until tested (P1's release gate): whether `CGConfigureDisplayOrigin` under other displays' live SCStreams stops a stream or causes the FB17797423 misrouting, and whether changing the main display to a virtual one does. If it does, arrange only displays whose capture has not started (trigger 1), drop triggers 2 and 3 for running ones, and change the main display only from the editor (a deliberate act, followed by an ordered rebuild).

## phases

Order: P0, then P2 and P3 (the goal). P1 only if the manual arrangement fails (runbook step 0, or P3's owner check), built in parallel or after P3. Then P4; P5 only if Wi-Fi misses the gates. Each phase ships alone and keeps the Tab working exactly as before with default settings. Every phase ends with `flutter analyze` (only the 14 known `unawaited_return_in_try_block` warnings), `flutter test`, `flutter build macos --debug`, and CLAUDE.md (and the README where users see it) updated in the same commit. Nothing is installed on the iPhone or the Tab, and the running Mac app is not touched, without the owner's go-ahead.

TEST ISOLATION
A `flutter run -d macos` build shares far more with the installed app the owner uses every day than it seems: the same bundle id (`com.example.extendedscreen`), so the same preferences (`link_type`, `known_devices` with the Tab at vdSerial 1, `encoder_capacity`, the Wi-Fi identity); the same TCC grants for Screen Recording and Accessibility, where an ad-hoc signed build with the same bundle id can re-prompt or replace the installed app's entry, so the installed app loses its grant; the same Wi-Fi port 7001; its auto-connect would take the real Tab and `adb reverse` it away from the running app (and `SynthAdb.routing` hands real serials to adb as well); and its Extend display would reuse vdSerial 1, the Tab's display identity and arrangement.
- P0 (once): the owner quits the installed app (menu-bar item → Quit) for the test window. Afterwards the owner opens it again; it reconnects the Tab by itself, and runbook step 0's check confirms the Tab is still where it was arranged. If macOS asks for Screen Recording or Accessibility again, the installed app's entry was replaced: re-grant it in System Settings → Privacy & Security.
- From P2 on, dev builds are isolated instead (about half a day, done in P2's first commit): the Debug configuration gets its own bundle id (`com.example.extendedscreen.dev`), hence its own preferences suite and its own TCC entries (granted once); a `--dart-define=WIFI_PORT` (dev default 7101 for TCP and UDP, and the iPhone dev build probes the same); the dev build lists no real adb devices unless `--dart-define=REAL_ADB=true` (synthetic tablets still work); and its vdSerials are offset (`| 0x20000`, never 1) so its displays never share an identity with the installed app's. The dev Mac has its own Wi-Fi identity, so an iPhone paired to it lists that Mac as a second row; Forget it after testing.

P0: SPIKE AND DE-RISK (1.5 to 2 days; ships nothing)
- In a branch: the ios/ folder created in a scratch project and copied in (see *client*), the iOS-only bundle id and team, the bootstrap gates, a minimal VideoDecoderPlugin and PairingInboxPlugin (pull model), and ExtendedViewController. A Mac dev build on the Wi-Fi link for items 3 and 8.
- With the owner's OK, `flutter run --release` to the iPhone.
- Verify the eight items under *verdict*, plus optionally usbmux throughput into a sink listener in the spike app.
- Gates (proposed thresholds; the owner may move them):
  - Inbox fails → the devicectl fallbacks in order (process launch with env, then QR, +2 to 3 days in P2).
  - Wi-Fi (item 8): the design stands if RTT p95 ≤ 15 ms, p99 ≤ 40 ms, frame-arrival jitter p95 ≤ 8 ms, and glass-to-glass median ≤ the Tab's over USB + 25 ms. Missing any → promote P5 (usbmux) before P3; the owner decides with the numbers in hand.
  - Unicast discovery or TLS fails in a way the typed address doesn't fix → promote P5 before P3.
  - Texture sink: more than 5% of refreshes repeating a frame while the Mac sends 120 fps (CADisplayLink timestamps against `textureFrameAvailable`), or glass-to-glass more than 8 ms behind a LayerSink prototype → make LayerSink the P2 default.
  - Colours off with BGRA (item 4) → investigate before P2; NV12 is not a fix.
  - 832×440 pt rejected → the default becomes ÷2.5.
- Owner check: allow the install and trust the developer (runbook step 2); allow the developer to quit and later restart the installed Mac app for the test window; confirm the Tab is back, where it was arranged, afterwards. Report what the colour test pattern looks like on the iPhone.

P1 (CONDITIONAL): DISPLAY ARRANGEMENT, HOST ONLY (2 to 3 days)
Built if runbook step 0 or P3's owner check fails, or if the owner wants the layout and main display kept by the app (decision 7). Needs no iPhone.
- Changes: `display_layout.<setKey>` prefs; Remember this layout and Follow System Settings in Settings → Tablets; `ScreenCaptureChannel.listDisplays` and `arrangeDisplays` plus the Swift; the pure-Dart planner, the main-display translation; the three triggers. The drag editor is optional (+1 to 2 days).
- Ships: whatever layout and main display the owner remembered come back for that combination of devices. With nothing remembered, nothing moves.
- Tests: `display_arrangement_test.dart` (a saved layout restored, idempotent, the main display changed by one translation that keeps the relative layout, the MacBook made main again, a combination with no saved layout untouched, mirror sets and lid-closed skipped, an unmanaged monitor kept relative to the anchor, Follow System Settings recording only changes the app did not cause); a hub test with a fake channel checking the calls run inside the queue and never nested, and that a teardown during trigger 1's await bails before `startCapture` with the ceiling read after it.
- Mac check (isolated dev build, `SYNTH_TABLETS=3` and the Loopback preview): arrange under running streams; no `onStreamStopped`, no `onCaptureMismatch`, no visible blink, and a second call reports `moved: 0`. Also: the same vdSerial at two divisors keeps its UUID (see *arrangement*).
- Owner check: remember two layouts (one with the MacBook main, one with the Tab main); after a replug, sleep and wake and a settings reconnect, each comes back as remembered, menu bar included, with no visible jump after the first placement.

P2: THE IPHONE AS A WI-FI DISPLAY, ONE LINK AT A TIME (4 to 5 days)
- Client: everything under *client* (Texture sink with BGRA by default), the inbox pull, the Keychain secret store and its uninstall cleanup, unicast discovery with `broadcastEnabled` off, HELLO 0x03 with the safe-area size, the iOS lifecycle path, the forced Wi-Fi link, the Local Network denied state, the compact layout, the thermal HUD warning, en/th strings.
- Host: `IosDeviceService`, `WifiPairingService.offerPayload()`, the Settings → Wi-Fi iPhones list, `HostSession.platform`, the profile key and the iPhone's own display identity, the global-panel rule, the per-device divisor and fps cap, `taken` over every session, dev-build isolation.
- Ships: switch the Mac's link to Wi-Fi to use the iPhone; switch back to USB and the Tab works as before. The iPhone's display has its own identity, so it appears where macOS appends a new display (usually the right) and never takes the Tab's spot. The Android binary is unchanged apart from the shared Dart, whose iOS branches do not run there.
- Tests:
  - `ios_device_service_test.dart`: devicectl JSON fixtures with the real paths, the 0600 temp file removed on failure, the timeout, every `IosDelivery` result;
  - `wifi_link_test.dart`: a client with platform 0x03 and a 2496×1320 HELLO is captured at 832×440 logical, 60 fps, 8 Mbps, does not change `lastClientPanel`, and gets `vd_serial.iphone`, never 1;
  - `known_devices_test.dart`: `configFor` with divisor and fps cap; every Android preset (Custom included) unchanged at divisor 2 with no cap, for an even and an odd panel; Custom's scale under a divisor;
  - `connection_retry_test.dart`: with a fake iOS lifecycle, `paused` closes the link with no retry armed, and `resumed` redials at once whatever the phase reads; on Android neither changes anything;
  - a Dart test of the inbox pull with a mocked channel: pulled in `onInit`, `inboxDone` only after `storePairing` answers, nothing sent when it throws;
  - Home's client body on iOS (linkTypeRx forced to Wi-Fi, no link selector, the paired-Mac rows and Forget, the Local Network state), and the compact layout at 956×440 logical in en and th with no overflow;
  - `test/wire_fixtures_test.dart` with `test/fixtures/wire/` (HELLO 0x02 and 0x03, 0xF5, ping/pong, mouse click/scroll/drag): the builder and the host's parse both match the files;
  - a check that ios/Runner/Info.plist has none of the file-sharing keys.
- Owner check, each with a pass criterion:
  - Pair from Settings (runbook step 3): the row reads Paired within 10 s.
  - The iPhone extends over Wi-Fi: picture within 5 s of opening the app; colours match the MacBook on the test pattern.
  - Taps: a window's close and minimise buttons and menu items hit on the first try 9 times out of 10.
  - App switch and back, 5 times: picture back within 3 s each time; the Mac's card goes from live to waiting at once (not after 6 s).
  - Lock the phone: the Mac's iPhone card leaves live within 1 s; unlock and open: back within 3 s.
  - Local Network: deny it in iPhone Settings, open the app: Home shows the Local Network guidance within two attempts; allow it again: the app connects.
  - The display's corners and the Dock edge: nothing the owner needs is under the rounded corners or the Dynamic Island (decision 15).
  - Screenshots of the iPhone's Home and Settings in en and th, nothing clipped.
  - Back to USB: the Tab connects as before.

P3: TAB ON USB AND IPHONE ON WI-FI AT ONCE, THE GOAL (3 to 4 days)
- Host only: everything under *Hub: Wi-Fi beside USB*, plus the discovery responder guard and the handshake-deadline listener.
- Ships with `wifi_listen` off, so USB-only and Wi-Fi-only setups behave exactly as today.
- Tests (`host_hub_test.dart`, `host_launch_test.dart`, `home_sessions_test.dart`, `wifi_link_test.dart`):
  - a beside listener next to FakeTablet USB sessions;
  - the Tab still auto-connects by the first-run rule with the listener up;
  - a listening session blocks no link change and takes no focus;
  - a `_Stranger`-style TLS client that completes the handshake and never sends 0xF5 takes no cap place, does not read as connecting, and does not hide the selectors;
  - a client that never finishes TLS is dropped after 3 s, and a paired one gets in after it;
  - a USB session's teardown leaves the beside listener's responder answering;
  - with Maximum tablets 2, the Tab live and the iPhone gone back to listening, a second USB tablet is admitted (the beside place was released);
  - the iPhone's vdSerial is the same as in P2 and not 1; a new USB tablet never gets the beside session's serial;
  - `sessionCount` under the cap, with a listener holding no place;
  - turning `wifi_listen` off ends only that session;
  - a USB tablet in remote control (either direction) beside it leaves it listening, and the beside session keeps its own mode whatever the USB tablets run as; Maximum tablets 1 ends it;
  - the listener's card and the add panel's switch.
  These run against a client from wifi_link_test's helpers and FakeTablets; no iPhone is needed.
- Acceptance question for the owner, before P3 is called done: every side-button press, call or app switch removes the iPhone's display, and macOS moves its windows to the MacBook. If that is not acceptable, the grace period moves from P4 into P3 (+1 day).
- Owner check, each with a pass criterion:
  - The Tab plus the iPhone, arranged once as the owner likes (runbook step 5), first with the MacBook main, then with the Tab main: after a settings reconnect (which rebuilds both displays) the layout and the main display are as arranged.
  - The Tab's HUD shows 90 ± 2 fps and 0 drop/s with the iPhone at 60 fps.
  - Background and resume the iPhone 5 times: the Tab's HUD fps and frame count keep running throughout, with no drop/s.
  - Unplug and replug the Tab: the iPhone's picture keeps updating and its card never leaves live.
  - Sleep the Mac 5 minutes and wake it: both pictures back within 10 s, in the arranged layout, with the chosen main display.
  - One hour of streaming with the phone unplugged: record battery % per hour, every `thermalState` change (os_log) and any fps drop. Pass: no `critical`, and the owner finds the drain acceptable.

P4: POLISH (2 to 3 days)
- iOS `os_log` diagnostics.
- TouchGestureRecognizer slop and gains retuned for a 6.9-inch panel (per-platform constants).
- Optional "Open on iPhone" on its card (`devicectl device process launch --activate`, cabled only).
- Optional automatic re-pairing when a paired iPhone is wired and the Mac's address list changed.
- LayerSink measured against TextureSink (glass-to-glass with the timestamp-overlay method of P0 item 8), and made the default only if it wins by 8 ms or more at the median with no worse p95. NV12 decode output likewise, only if it measures cheaper and passes the colour test pattern.
- Optional idle dim against burn-in (see *client*).
- Optional display grace period (unless moved into P3): an iOS session whose link is lost keeps its virtual display, with the capture stopped, and holds its budget place (counted in `sessionCount`) for 30 s, then releases both, so an app switch does not move windows off the iPhone display. Tests against EncodeBudget reservations, the release after 30 s, and the FB17797423 rounds (the display stays in the set, so no round is triggered).

P5 (OPTIONAL): IPHONE OVER USB THROUGH USBMUXD (4 to 6 days)
Only if Wi-Fi misses P0's gates, or P3's owner check finds the latency or jitter unacceptable.
- Host: `UsbmuxClient` and `plist_xml`; Listen events merged into `_listed`; `DeviceKind.ios` and `ios:<UDID>` keys with every adb-shaped path guarded; `_connectUsbmux` with the in-attempt Result 3 loop; the TLS server upgrade; `_tokenAuth`. `SocketService.adoptClient` already exists from P3.
- Client: the loopback listener (pending slots with oldest-unproven eviction, open on resume, close on background) and the TLS client upgrade.
- Tests: `usbmux_test.dart` against a fake usbmuxd on a temp Unix socket (plist codec, Listen, Connect results); `FakeIPhone` and `FakeUsbmuxd` in `debug/synthetic_tablet.dart`; hub tests mixing the Tab and an iPhone (the first-run rule ignores an unknown iPhone; Result 3 never grows the backoff; Detached restarts a waiting session; a squatter without the token and a Mac-side dialer without the certificate get nothing).
- The usbmux session uses profile key `iphone`, so the iPhone keeps its display identity and placement.

Effort to the goal (P0, P2, P3): about 9 to 11 days. P1, if needed, adds 2 to 3; P4 2 to 3; P5 4 to 6. New code to the goal: about 650 lines of Swift on iOS, 250 of client Dart, 450 of host Dart (devicectl, the hub slice, the listener, per-device settings and identity), and about 550 lines of tests; P1 adds about 150 of Swift and 200 of Dart.

## risks

1. devicectl delivery is unverified. `copy to appDataContainer` may not work for a running release build from this team, or with the app closed or the phone locked, and the Darwin notification may not arrive. Development-signed builds normally keep get-task-allow, so it is plausible. Mitigation: P0 tests it first; Dart pulls the inbox at launch, on activation and on the nudge, and a file is deleted only after Dart answered; two fallbacks are designed. It also depends on Xcode being installed and selected, and on devicectl's JSON (documented as versioned).
2. The container is the trust channel. If a file-sharing key or a document type is ever added, Finder, Files or AirDrop could plant a pairing. Mitigation: Library/ only, excluded from backups, a size cap, deleted once answered, and a test on Info.plist.
3. Signing. If the team is a free Personal Team: the app stops launching 7 days after each install (a weekly reinstall from the Mac); at most 3 apps per device and 10 App IDs a week; no multicast entitlement, hence unicast-only discovery. A paid account removes the weekly reinstall but is not required. A TestFlight or App Store build would lose the devicectl inbox (no get-task-allow) and need QR pairing.
4. Foreground only: an app switch, the lock button or a call ends the iPhone session (now at once, by the lifecycle path), and macOS moves the windows off its display. Reopening the app redials at once. P3's acceptance question decides whether the grace period comes in P3 or P4. StandBy (the phone locked on its side while charging) is a lock too: no picture.
5. Wi-Fi jitter: AWDL is active on the Mac, plus roaming and a busy WLAN. BitrateAdapter and pacing absorb throughput drops, not latency spikes. P0 item 8 measures it against numeric gates, and P5 exists for it.
6. The Mac's address changes: discovery is unicast only, and pairing carries the addresses known at pairing time. Mitigations: a typed address or `.local` name, re-pairing (P4 can automate it), and a DHCP reservation.
7. Hub edits in hot logic (P3): the first-run rule, `_onLinkTypeChanged`, `_refocus`, the cap count, the budget release rule, the shared responder and Home's selector rule. A listener counted as connecting would stop the Tab from auto-connecting or block link changes. Mitigation: a dedicated test per rule, "listening" defined by trust rather than phase, `wifi_listen` off by default, and synthetic tablets and an AVD before the real Tab.
8. Identity: a Wi-Fi Tab and the iPhone now have separate profiles (`wifi`, `iphone`), but a second iPhone would share the `iphone` profile and display. Acceptable for one iPhone; multi-tablet phase 4's `wifi:<installId>` keys fix it, with the migration under *host*.
9. One shared token: Reset unpairs the Tab's Wi-Fi pairing too, and an extracted iPhone token would admit Wi-Fi clients until reset. The Keychain (from P2) and per-device tokens (a deferred decision) reduce it.
10. Always-on listener: with `wifi_listen` on, the Mac listens on every network it joins. P3's handshake deadline limits idle connections; a LAN peer can still read the Mac's name from discovery and hold the client slot for 3 s at a time. Decision 6.
11. Arrangement (only if P1 is built) writes the window server's permanent display sets, the main display included. A planner bug would outlive the app, which is why nothing moves for a combination the owner has not remembered, and a second run moves nothing. A virtual display as main moves the menu bar and windows to the MacBook whenever that device goes away and during every ordered rebuild (see *arrangement*). Its interaction with live SCStreams and FB17797423 is unknown until P1's synthetic check. A divisor change might mint a new display UUID (see *arrangement*).
12. Encoder budget: with the iPhone streaming, the Tab drops from 120 to 90 fps (iPhone at 60) or to 60 (iPhone at 120 or ÷2). The owner may see it as a Tab regression; the Settings copy explains it.
13. Small desktop: 832×440 pt at ÷3 is short and the 1.5× upscale softens the picture. ÷2.5 and ÷2 trade text size for space. macOS may not accept the smallest mode (P0).
14. HELLO size on iOS is the safe-area area (or what decision 15 picks), not the whole display. The host treats it as the panel; CLAUDE.md's 0x01 row must say so.
15. Edge gestures: if ExtendedViewController's override does not take effect under the UIScene template, a swipe at the Dock edge leaves the app (P0 item 6).
16. Heat, battery and burn-in: continuous decode on a 120 Hz OLED panel heats and drains the phone, and static Mac chrome can burn in. The 60 fps default, the HUD thermal warning, the hour-long owner check and the mitigations under *client* address it; nothing reacts automatically unless decision 17 says so.
17. Colour: VideoToolbox's BGRA conversion is trusted to use the stream's matrix; NV12 through Flutter is not (P0 item 4).
18. Dev builds share the installed app's bundle id until P2's isolation lands; P0 relies on the owner quitting the installed app, and a TCC entry replaced by a dev build must be re-granted.
19. Bundle id: `com.example.*` may be refused by automatic signing. The host's devicectl calls must use `iosBundleId`, never the Android package name.
20. P5 rests on usbmuxd's private protocol (stable for over a decade, used by peertalk, iproxy and Xcode's tools). A change in macOS would break only the iPhone's USB link. Any local user can deny the USB link (not enter it).

## decisions

Each item has a recommended default; answer only where you disagree.

1. Link for the iPhone. Default: Wi-Fi first (P2 to P3), usbmux (P5) only if Wi-Fi misses P0's numeric gates. Alternative: USB first through usbmuxd (best latency, the cable charges the phone, no Local Network prompt), at about three times the effort to the goal. If the phone will sit on a cable to the Mac for charging anyway, that argues for P5 sooner.
2. iOS bundle id. ANSWERED (2026-11-19): `com.porto.extendedscreen.ios`.
3. Signing. ANSWERED (2026-11-19): T4P27BU383 is a free Personal Team, so a weekly reinstall, at most 3 sideloaded apps, no multicast entitlement. Was: Default: whatever the existing team T4P27BU383 is (confirm Personal or paid as described in *verdict*); development signing only, no TestFlight or App Store. If it is free: a weekly `flutter run --release`, about 5 minutes a week. Alternative: a paid account ($99 a year), one reinstall a year and the multicast entitlement can be requested.
4. Text size on the iPhone. Default ÷3 (832×440 pt, text about 83% of the MacBook's). Alternatives ÷2.5 (998×528 pt) or ÷2.
5. iPhone frame rate. Default 60 fps, so the Tab keeps 90. Alternative 120, with the Tab at 60.
6. Wi-Fi beside USB. Default: a "Listen on Wi-Fi (iPhone)" switch, off until you turn it on, in the add panel; while on, the Mac listens on every network it joins (see risk 10), which you accept. Alternative: listen only for 10 minutes after you press Listen on the iPhone's card, then stop (+0.5 day); the iPhone must then connect within that window each time.
7. Arrangement and main display. Any layout and any main display are the owner's choice. Default: by hand in System Settings (drag the displays, drag the menu bar to the main one; runbook steps 0 and 5), the MacBook main; build P1 (the app remembers each combination's layout and main display, optional drag editor) if that does not hold through replug, sleep and wake and a settings reconnect, or if you want it in the app. A tablet or the iPhone as main is allowed; the iPhone as main moves the menu bar to the MacBook at every lock.
8. Pairing fallback if devicectl's inbox fails. Default: devicectl process launch with an environment variable, then QR pairing.
9. Per-iPhone revocation. Default: no; one shared token, as for the Tab. Revisit with the multi-tablet doc's per-device tokens.
10. Grace period on an app switch. Default: build it in P4 at 30 s for iOS sessions only; move it into P3 if windows jumping to the MacBook on every lock is not acceptable (P3's acceptance question).
11. Video sink. Default: Flutter Texture with BGRA; the layer underlay only if P4 measures it 8 ms or more faster; NV12 only if cheaper and colour-correct.
12. Native SwiftUI client. Default: no. Reconsider only if both the Texture and the layer sink fail on latency.
13. Reverse remote on the iPhone (the Mac viewing and driving the phone). Not possible without input injection; not planned.
14. Which roadmap first. ANSWERED by what was built: multi-tablet phase 3 came first (the alternative below), with P0 as a spike beside it; iOS P1 to P3 follow. Was: Default: iOS P0 to P3, then multi-tablet phase 3; multi-tablet phase 4 later absorbs the beside slice, with the migration under *host*. Alternative: multi-tablet phase 3 first, then iOS P2 and P3 (P0 can run either way).
15. Safe area on the iPhone. Default: crop both sides symmetrically (2496×1320 rendered; at ÷3 832×440 pt). Alternatives: crop only the Dynamic Island's side, following the orientation (2682×1320; 894×440 pt; the rounded corners on the other side clip the Mac's menu-bar and Dock corners); or the full panel (2868×1320; 956×440 pt; the island covers a sliver of desktop and all four corners clip). The encoded load at ÷3 and 60 fps is 88, 94 and 101 Mpx/s.
16. Owner checks. Default: the pass criteria written in P2 and P3 (first-try hits 9 times out of 10, the Tab's 90 ± 2 fps, 3 s resume). Change any number you care about.
17. Thermal reaction. Default: a HUD warning only, and you lower the iPhone's Max fps on the Mac if needed. Alternative: an iOS-only client → host thermal hint that lowers the cap by itself (a new packet, +1 day).
18. iPad. Default: the same build is universal from P2 (about +1 to 1.5 days), with its own `ipad` profile, divisor 2 and no fps cap; one Apple device beside the Tab after P3. iPhone and iPad at the same time only after multi-tablet phase 4 (or P5's usbmux). Alternative: iPhone only, and keep using Sidecar for an iPad.
19. Keyboard and trackpad from an iPad. Default: an optional P6 after P4, only if an iPad is used. Alternative: never; touch and Pencil-as-finger only.
