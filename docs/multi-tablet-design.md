

######## architecture

VERDICT
Take the incremental design's skeleton and add the clean design's hardening. Today's per-tablet code moves, almost unchanged, into a HostSession object, one per tablet. The registered HostConnectionManager becomes a hub that holds those sessions. Each native plugin becomes a registry of per-session objects, addressed by an id that Dart hands out.

Leave out the clean design's transport rewrite (PeerLink, listener classes, a LinkLifecycle mixin, SocketService turned into a client-only dialler). Three reasons:
- It moves the code that carries every cancellation and trust rule in CLAUDE.md.
- It changes the tablet app's code path.
- The feature doesn't need it. Once each USB tablet has its own Mac port, today's one-connection SocketService already is a per-tablet transport. Wi-Fi is the only place where many tablets share a port, and it gets a small listener owned by the hub that hands each accepted socket to its own SocketService.

Checked against the code (read-only):
- SocketService already exposes `serverPort`.
- `adb reverse` without --no-rebind replaces an old rule.
- `_onHello` reads only bytes 2..6.
- The client's onRolePacket is an if-chain, so unknown control bytes are ignored.
- `_onSessionKey` does nothing when the tablet's link is Wi-Fi.
- parsePairingPayload ignores anything after the address list.
- Tests already build `HostConnectionManager(socket:, port:)` side by side.

HOW THE TWO DESIGNS WERE JUDGED
Incremental design:
- Least code, and nothing changes on the tablet.
- Weak spots: the global mode stays until late, and only the newcomer is ever degraded. A first tablet on the Max preset already fills the M3 Pro's single encoder, so every second tablet would be refused or floored.
Clean design:
- Right about isolation.
- Costs: an early extraction of the lifecycle into a mixin (high regression risk), two-level locking (a per-session queue plus a topology queue), and host-minted Wi-Fi tokens (more code than the feature needs now).

Taken from the clean design:
- native ids that are never reused;
- stop and remove calls that answer only once they are really done;
- a TLS accept with a handshake deadline and a cap on pending connections;
- a live frame-rate ceiling per session;
- one app-lifecycle observer in the hub;
- USB retry backoff;
- 'standby' for a tablet that is on Wi-Fi while plugged in;
- mapping one tablet across both links.

OBJECTS AND OWNERSHIP (Mac)
1. Hub: lib/shared/connection/host_connection_manager.dart, rewritten. It keeps its class name and its registration (`Get.put<BaseConnectionManager>(HostConnectionManager(), permanent: true)`), so every `Get.find` and the cast in the remote view's controller (RemoteHostController then; RemoteGridController since phase 3) still compile. It owns:
- `sessions`: RxMap<String, HostSession>. The key is the adb serial for USB. For Wi-Fi it is 'wifi' until phase 4, then 'wifi:<installId>' (or 'wifi:conn<n>' for a tablet that sends no id).
- `focused` (the session the old single-session widgets show).
- `availableDevices` and `freeDevices` (devices without a session), kept current by a 3 s `adb devices -l` poll.
- `stoppedDevices` (replaces HomeController._userStopped, per device).
- One PipelineQueue.
- The native id allocator: starts at 1 and never reuses a number in a process, so a late native callback for a dead session finds nothing.
- EncodeBudget.
- The only WidgetsBindingObserver.
- A hub `_generation` counter for its own multi-step operations.
- The only claim on the single-slot callbacks: AdbService.onTabletScreenRestored (routed by serial) and ScreenCaptureChannel's wake and bounds-changed events (fanned out to every session).
- From phase 4: the TLS listener, the discovery responder and the Wi-Fi identity.
Facade: workers copy the focused session's phase, errorMessage, activeDevice, latencyMs, refreshRateHz, streamBitrate, remoteTextureId and tablet screen-off flags into the hub's own observables. With one tablet, every existing widget and test sees exactly today's values. The hub never runs a packet loop, heartbeat or retry of its own.

2. HostSession: new file lib/shared/connection/host_session.dart.
- It is today's HostConnectionManager body, moved. It still `extends BaseConnectionManager`, so each tablet inherits its own copy of the per-link state machine: phase, the `_attempt`/`_connectSeq` counters, `_recovering`, `_stopping`, heartbeat, retry timer, packet loop, admitPacket, handleLinkFailure and restartLink. Every cancellation rule therefore keeps working unchanged, per tablet.
- It is never `Get.put`. Its onInit never runs, so it adds no lifecycle observer, which is intended. The hub must dispose its `ever(phase)` worker when the session is removed.
- It holds:
  - its own SocketService (USB: a loopback listener on an ephemeral port plus its single client);
  - the auth state (`_authedConnection`, `_proof`, `_helloReceived`, `_usbKey`, `_keyTakenAt`);
  - `panel` (ClientPanel from its own HELLO);
  - `spec` (SessionSpec: mode, effective direction and effective display mode, snapshotted at each connect);
  - its CaptureHandle or RemoteDecoderHandle, `_displayBounds`, `_frameSub`, `_restarting`, `_streamHevc`;
  - its bitrate and resync state and its screen-off state;
  - `nativeId`, and its AdbService (injectable, which is what the tests and the synthetic tablets below use).

3. PipelineQueue: today's `_exclusive`, made one object that every session shares.
- For each session the order is still first-in first-out, so 'the stop queued behind a start always wins' still holds per tablet.
- Host-wide it also puts every virtual-display creation and removal, and every SCStream start and stop, in one line. Adding a display moves the others, and the Swift side then never sees two sessions' native calls interleave.
- Cost: one tablet's stop can wait behind another tablet's start (up to about 2 s).
- Rule: never call `pipeline.run` from inside a queued operation (it would deadlock). A hub operation over several sessions enqueues all the stops, then all the starts.
- The clean design's per-session queue plus topology queue can replace this later, if the wait is ever measured as a problem.

4. Native registries, one registered plugin per kind as today:
- ScreenCapturePlugin: [Int: CaptureSession].
- InputInjectPlugin: [Int: InputState], plus the global cursor state and a pointer-owner lease.
- RemoteVideoPlugin: [Int: RemoteDecoder].
- AdbManagerPlugin is already per serial.
The Dart wrappers stay permanent GetxServices but act as factories: `ScreenCaptureChannel.open(id)` returns a CaptureHandle and `RemoteVideoChannel.open(id)` a RemoteDecoderHandle. InputInjectChannel takes `session:`.

WHAT N MEANS PER MODE
- Extend: N virtual displays, N SCStreams, N VideoToolbox encoders.
- Mirror and tablet-controls-Mac: N SCStreams of the main display and N encoders. One shared encode is not in v1.
- Mac-controls-tablet: N decoders and N textures. The Mac encodes nothing.

LIFECYCLE
- A session is created by picking a device, by auto-connect, or by a Wi-Fi accept (phase 4).
- It survives its own retries: same object, key and nativeId.
- It ends only through `hub.disconnectSession(key)`, `disconnectAll`, or a terminal refusal. The ending runs disconnect, then `capture.close()` or `decoder.close()` (native dispose), then removal from the map.
- If a session with the same key is still closing, the new one waits for it, so an old `removeForward` can never undo a new `reverse`.

THREADING
Dart: everything runs on the one UI isolate. Isolation comes from per-session counters, not threads. Timers: one heartbeat every 2 s per session, plus one 50 ms bitrate timer per Wi-Fi session.
Swift:
- Main thread: method calls, the registry dictionaries, virtual-display create and remove, SCStream start and stop, all input injection, decoder setup and feed, and the single frames EventSink.
- Each CaptureSession: its own serial sample queue 'capture.<id>', its own real-time Mach timer thread (the only caller of VTCompressionSessionEncodeFrame, and the one that applies bitrate, the fps ceiling and forced keyframes), and VT callback threads that hop to main.
- CaptureContentRect: a lock-guarded [id: rect] map, written by the sample queues and read on main by input.
- RemoteDecoder: its VT output under its own lock, read by Flutter's raster thread.

HOW CLAUDE.md'S RULES CARRY OVER, PER SESSION
- Check isCancelled after every await: unchanged inside HostSession, and cancelling tablet A never touches tablet B. Hub operations take `_generation` first and re-check it after each await.
- Capture queue: every start, restart and stop still goes through PipelineQueue.
- `peerTrusted` is per connection: unchanged. Each session compares against its own socket's connectionId, and `_sendToClient`/`_forwardFrame` write only to that session's socket. Frames are routed by native id, so one tablet's picture can never reach another tablet's socket.
- Nothing pairs from the socket: pairing is still offered through adb, per USB session, to that session's serial.
- `adb reverse` runs once per attempt: each retry is a new attempt on a new port.
- A key is only for dials made after it arrived: the key is still made after that tablet's own reverse.
- handleLinkFailure is per tablet: it closes only that session's listener, pipeline and tunnel, and retries only that serial.
- The launch path waits for no frame: the hub's autoConnect still runs from the splash's onInit.

######## protocol

PHASES 0 TO 3 (multi-USB extend, multi remote control): NO WIRE CHANGE AT ALL.
- The tablet side stays on port 7001. Each tablet still dials its own 127.0.0.1:7001.
- Only the Mac side of the adb tunnel moves. `adb -s X reverse tcp:7001 tcp:<P_X>`, where P_X is an ephemeral loopback port the session bound just before.
- Order per attempt: bind 127.0.0.1:0, then the reverse, then make the key, then deliver it.
- The port says which tablet dialled. The key still proves it: any Mac process can dial P_X, but none holds K_X.
- A keyless hello on P_X can only mean tablet X, so the key is re-delivered to X only. With a shared port this would be guesswork, which is why the clean and incremental designs both rejected one shared port.
- Removal becomes `adb -s X reverse --remove tcp:7001` instead of `--remove-all`, so other tools' rules on that tablet survive.
- Every packet keeps its meaning, on that session's link only: 0x01 HELLO, 0xF4/0xF3, 0xF5, 0xF7 to 0xFC, 0xFF.
- Session keys still travel through the USB_SESSION broadcast with `adb -s`.
- Already-installed tablet builds therefore keep working with the new Mac app, and the old Mac app keeps working with them. Nothing the tablet can see has changed.
- Side benefit: USB no longer needs the Mac's port 7001, so USB sessions and the Wi-Fi listener can run at the same time later.
- Docs to change in the same commit: CLAUDE.md's 'TCP 127.0.0.1:7001 on both ends' and the README. Also note that `adb reverse --list` now shows `tcp:7001 tcp:5xxxx`.

INTERNAL ONLY (Dart and Swift ship in one app, so there is no compatibility concern):
- Encoded frames on `extended_screen/frames` gain a 4-byte big-endian session-id prefix. The NALs on `extended_screen/remote_nal` gain the same prefix.
- Native callbacks carry {session: id}.
- Method arguments gain 'session'. A missing value means session 0, which is what keeps phase 0 working with the old call sites.

PHASE 4 (multi Wi-Fi): ONE OPTIONAL CLIENT ADDITION, NO LOCKSTEP.
HELLO gets a trailing identity after the existing 7 bytes:
- 0xA1 tag;
- installId: 16 random bytes, made once and kept in the tablet's prefs;
- nameLen, then the name in UTF-8, at most 64 bytes, Build.MANUFACTURER + MODEL.
Compatibility:
- Old Mac builds ignore the tail.
- The new Mac accepts a HELLO without it.
- The tail is sent only after trust (0xF5 or 0xF3), so the 1 KB untrusted limit is not an issue.
- Send it on both links. Over USB the Mac records serial ↔ installId, so it knows which adb serial a Wi-Fi tablet is. That links one tablet's profile, virtual-display identity and card across links, and lets the Mac park a USB session for a tablet that is currently on Wi-Fi.
- Never extend 0xF5 (old Macs check its exact length). Never reuse 0xF6.

PHASE 5, OPTIONAL: two host-to-tablet control bytes, sent only to a trusted peer and ignored by current tablet builds:
- 0xF1 'refused' plus a reason (1 = Mac at capacity), sent before closing, so the tablet can say why instead of redialling silently.
- 0xF2 'identify' (flash the tablet's name for a second).

DELIBERATELY NOT DONE NOW: per-tablet Wi-Fi tokens (the clean design's host-minted id and token in a pairing tail).
- It is wire-compatible: old tablets ignore bytes after the address list (checked).
- But it needs a new storePairing rule on the tablet and a Mac-side table, and it buys only the ability to revoke one tablet.
- It is listed as an owner decision.

COMPATIBILITY MATRIX
- New Mac with today's tablet builds: full multi over USB, and Wi-Fi tablets as anonymous sessions (no remembered profile).
- New Mac with tablet builds from before the USB handshake: refused, as today.
- Old Mac with new tablet builds: the HELLO tail is ignored; nothing changes.
- New Mac with new tablet builds: Wi-Fi tablets are recognised across IP changes and across links.

######## host_native

Keep the new classes inside the existing Swift files. The Runner target lists every source in project.pbxproj, so a new file also needs its four pbxproj entries.

macos/Runner/ScreenCapturePlugin.swift (the biggest change): split into a registry and CaptureSession.
- The registered ScreenCapturePluginImpl keeps:
  - the method channel and the single frames EventChannel and sink. Dart subscribes once and never cancels, so the sink never flips between sessions;
  - the wake and screen-parameter observers;
  - `sessions: [Int: CaptureSession]`;
  - the App Nap activity, now reference-counted: begun by the first capturing session, ended by the last. Today any stopCapture ends it for every session.
- Every method reads `args["session"] as? Int ?? 0` and dispatches to that session.
- New methods:
  - `disposeSession`;
  - `setFrameRateCeiling {session, fps}`: live and cheap. It sets maxFps, lowers targetFps if needed and sets ExpectedFrameRate, the same way setAdaptiveRate already changes the rate without a new encoder;
  - `getHostInfo` → {chip from sysctl machdep.cpu.brand_string, macOS version}.
- CaptureSession takes every per-capture field the plugin holds today: stream (each session is its own stream's delegate and output), compressionSession, virtualDisplay and its id, capturedDisplayID, captureGeneration, timerGeneration, isCapturing, targetFps, maxFps and the adaptive-ladder state, requestedBitrate and encoderBitrate under a lock, the Mach thread, latestPixelBuffer, the diag counters, and its own sample queue. A stop then cancels only its own start.
- forceKeyframe and the fps ceiling go under the session's lock. Today they are written on main and read on the timer thread with no synchronisation.
- Encoder callback counter: the VT output closure does `OSAtomicDecrement32(&self!.pendingEncodeFrames)` under [weak self]. That crashes once sessions are freed, so keep the counter in a small box the closure retains. Do not zero it in stop while callbacks are in flight.
- stopCapture answers only after the session's Mach thread has exited (a semaphore the loop signals; wait at most 1 s), and only then invalidates the VT session. Today it invalidates while a tick may still be encoding.
- createVirtualDisplay {session, width, height, refreshRate, serialNum, name} → {applied, displayID}:
  - add-only. The 'release any previous display and wait 0.3 s' step happens only when this session replaces its own display;
  - serialNum comes from Dart: stable per tablet and non-zero. vendorID 0x3456 and productID 0x1234 stay;
  - the name is 'Extended Screen – <model>';
  - displayID 0 counts as failure;
  - terminationHandler reports onVirtualDisplayTerminated {session}.
- removeVirtualDisplay {session} answers once the display has left CGGetActiveDisplayList (poll every 50 ms, at most 1 s). The next step in the queue then sees a settled display set.
- startCapture {session, mode, ..., requireHardware} → {displayID, hardware}:
  - honour 'mode'. Today Swift ignores it and treats 'a virtual display exists' as Extend, so with two tablets a Mirror session would capture the other tablet's display;
  - Extend uses only this session's virtual display. If that display is not in SCShareableContent after the existing ~1.5 s poll, the session falls back to the main display and returns `fellBack: true`. Dart then shows it; it is never silent;
  - Mirror uses CGMainDisplayID.
- setupEncoder:
  - check the OSStatus of VTCompressionSessionCreate. Today it is discarded, so a failed encoder means a silent black stream;
  - use kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder when requireHardware is set (every session after the first);
  - map -12915 to ENCODER_BUSY and -12908 to NO_ENCODER;
  - read UsingHardwareAcceleratedVideoEncoder and log it per session.
- getVirtualDisplayBounds {session} answers from that session's captured display, else its virtual display, else the main display.
- requestIdr and setBitrate act on that session only.
- Callbacks:
  - onFrameRateChanged {session, fps, achieved}. 'achieved' is the measured ticks/s when the change was an overload step-down; Dart learns the encoder's capacity from it;
  - onStreamStopped {session, error};
  - onCaptureNeedsRestart once per wake, with no id: the hub rebuilds every session in order;
  - onDisplayBoundsChanged with no id: every session refreshes, because adding or removing one display moves the others.
- Frames: handleEncodedFrame writes UInt32(id).bigEndian as the first 4 bytes of the Data it already builds. No extra copy.
- CaptureContentRect: keep the class. `.shared` becomes `forSession(id)`, a lock-guarded dictionary. A session resets and removes only its own entry.

macos/Runner/InputInjectPlugin.swift
- Per-session InputState, in [Int: InputState], selected by 'session': heldButton, clickCount, lastDown time/point/button, scroll remainders and flags, scrollAnchor.
- Still global, because the Mac has one cursor: keepCursor, savedCursor, lastCursorPoint, scrollHome, recentTabletPoints (entries now note their session), returnWork, scrollSettleWork and lastReturn.
- Pointer-owner lease `pointerOwner: Int?`:
  - a down claims it;
  - while another session owns it, a session's down, drag, up and scroll are dropped, and its plain move only updates its own scrollAnchor;
  - the 'down while a button is held means its up was lost' recovery applies only within one session, so tablet B can never break tablet A's drag.
- Mapping goes through CaptureContentRect.forSession(session).
- releaseAll {session} releases a button only if that session owns the pointer, clears its state, and returns the cursor only when nobody owns it.
- releaseAll with no session releases everything, for app termination.

macos/Runner/RemoteVideoPlugin.swift
- RemoteDecoder (FlutterTexture), one per session, owns the VT session, format description, isHEVC, parameter sets, latestPixelBuffer and its lock, plus an alive flag. textureFrameAvailable is never called after dispose.
- The plugin keeps [Int: RemoteDecoder] and the registrar.
- initialize {session, codec} registers the decoder once and returns its textureId. Today it re-registers `self` on every call without unregistering.
- dispose {session} unregisters only that decoder.
- remote_nal messages carry the 4-byte prefix, stripped before splitAnnexB.
- Use RequireHardwareAcceleratedVideoDecoder when another decoder is live; -12913 maps to DECODER_BUSY.
- Optional: ask VT for 420v output (Flutter's macOS texture wraps NV12 without a copy) instead of BGRA.
- Built in phase 0 even though multi-remote comes in phase 3, because the debug 'loopback preview' used to test virtual displays in phase 2 needs it.

macos/Runner/AdbManagerPlugin.swift
- removeForward {serial, remotePort} runs `-s serial reverse --remove tcp:<remotePort>`. It keeps the 5 s bound and answers only after adb exits, so teardown still orders the removal before the next reverse.
- Phase 3: InputShell per serial, modelled on ScreenHold. One long-lived `adb -s X shell -T` fed `input tap` / `input swipe` lines on stdin, with F_SETNOSIGPIPE, released on willTerminate. It replaces one adb process per tap. As built: opened lazily by the first tap (there is no open call), each line followed by a marker the next line waits for, a 1 s age bound on waiting lines, and the per-tap process kept as the fallback (see PHASE 3 under phases).
- Phase 5, optional: `adb track-devices` → onDevicesChanged.
- Already per serial, no change: reverseForward (separate local and remote ports), screenHolds, onTabletScreenRestored(serial).

macos/Runner/MainFlutterWindow.swift: unchanged. The same registrations before engine.run; per-session objects live inside the registries.

macos/Runner/CGVirtualDisplay.h: no change. serialNum, name and terminationHandler are already declared.

macos/Runner/AppDelegate.swift, optional (phase 5): a menu-bar submenu listing the live tablets, with Disconnect each and Disconnect all.

######## host_dart

lib/shared/connection/host_session.dart (NEW)
- Today's HostConnectionManager body, moved. Constructor: `HostSession({required key, required nativeId, required LinkType link, String? serial, required PipelineQueue pipeline, EncodeBudget? budget, AdbService? adb, SocketService? socket, int? port})`.
- Differences from today:
  - (a) The serial is fixed for life. There is no fallback to `devices.first`; a missing device throws `LinkError('error_device_gone')`.
  - (b) USB order: `socket.startServer('127.0.0.1', 0, untrustedPayloadLimit: 1024)`, then `reverseForward(serial, localPort: socket.serverPort!, remotePort: linkPort)`, then the key.
  - (c) Every read of settings.isReverseRemote, effectiveDisplayMode, sessionMode or effectiveRemoteDirection reads `spec`.
  - (d) Every read of settings.clientPanel* reads `panel`.
  - (e) `_exclusive` becomes `pipeline.run`.
  - (f) `releaseAll(session: nativeId)`.
  - (g) `removeForward(serial, remotePort: linkPort)`.
  - (h) It no longer claims AdbService's callback; `onTabletScreenRestored(serial)` is public, for the hub to route.
- `_onHello` sets `panel`, persists it with `settings.setClientPanelFor(key, panel)`, and reads the phase 4 identity tail. The 3 s HELLO-timeout fallback uses `clientPanelFor(key) ?? lastClientPanel`.
- `_startCapture`:
  - `cfg = settings.captureConfigFor(panel, spec)`;
  - `cfg = budget.admit(nativeId, cfg)`;
  - passes `requireHardware: hub.capturingCount > 0`;
  - maps ENCODER_BUSY, NO_ENCODER and a budget refusal to `CaptureLimit(key)`.
  `connect()` treats CaptureLimit as terminal: it sets errorMessage and calls `handleLinkFailure(retry: false)`. Retrying every second would create and destroy virtual displays rapidly, which others report corrupts CoreGraphics' display-id pool. Every other pipeline error stays non-fatal, as today.
- `_restartCapture` is split into `stopPipelineOp()` and `startPipelineOp(attempt)`, so the hub can enqueue every stop before every start on wake.
- Screen-off uses `settings.tabletScreenOffFor(serial)`.
- On streaming: `settings.rememberDevice(serial, model, vdSerial)`. It still writes last_device, for the first-run rule.

lib/shared/connection/base_connection_manager.dart (small change)
- `handleLinkFailure({bool retry = true})`.
- `@protected Duration get retryDelay` with backoff: the first retry after 1 s (today's host value, so a single blip behaves as now), then 2, 5 and 10 s with ±20% jitter, reset when the session reaches streaming. This stops an adb-server restart from setting off N simultaneous reverse storms.
- Nothing else moves.

lib/shared/connection/host_connection_manager.dart (REWRITTEN as the hub)
- `connect({serial})` resolves `serial ?? last device if attached and free ?? the single free physical candidate`, looks up or creates that session, focuses it and connects it. It refuses when there is no free slot. Over Wi-Fi (phases 1 to 3) it uses the single 'wifi' session, which is exactly today's path and owns the TLS listener.
- `disconnect()` = disconnectAll. `reconnect()` = reconnectAll, run over the active and connecting sessions; sessions in error pick the change up on their pending retry.
- `sendUiFlags()` goes to every session.
- `autoConnect()` and `connectIfUnambiguous()` take `_generation` and re-check it after each await. They start every attached physical serial in `known_devices` that is not in stoppedDevices and has no session, within the free slots. Today's first-run rule still applies: no sessions, and exactly one physical candidate. Emulators never auto-connect while a physical device is attached, but the picker can add them.
- The 3 s device poll runs the same policy on hot-plug. When a session's serial reappears it calls `retryNow`.
- `didChangeAppLifecycleState`: detached → disconnectAll; resumed → the auto-connect policy plus retryNow on sessions that are in error and not recovering.
- Wake: one hub operation that enqueues every capturing session's stop, then every start (sorted by key, so the display set is rebuilt in the same order each time), then an IDR each. Bounds-changed refreshes every session.
- `resetWifiIdentity()`: restart the Wi-Fi session or listener and offer pairing again on every live USB session (each checks its own isLatestConnect).
- Standby: a USB session whose tablet is known to be live on Wi-Fi (installId map, phase 4) parks with no retries. A USB session that has had 3 attempts in a row with no hello at all shows 'the tablet app is not on USB' and backs off to 30 s. That case is today's loop when the tablet's app is set to Wi-Fi while it is plugged in.

lib/shared/connection/pipeline_queue.dart (NEW): `run<T>(Future<T> Function())`, which is today's `_exclusive`. It must not be called from inside a queued operation.

lib/shared/connection/encode_budget.dart (NEW): pure arithmetic, unit-tested like BitrateAdapter.
- `admit(id, cfg)` returns a granted config or throws CaptureLimit.
- `release(id)`.
- `ceilings()` returns the fps ceiling per live session; the hub pushes them with setFrameRateCeiling.
- `learn(codec, achievedSum)`.
- The policy is under 'limits'.

lib/shared/connection/wifi_listener.dart (NEW, phase 4)
- A plain ServerSocket on anyIPv4:7001 (no `shared`). Each raw socket is upgraded with `SecureSocket.secureServer(raw, ctx)` under a 5 s deadline, destroying the raw socket on timeout. A test must prove this aborts the handshake; if it does not, the pending cap below still bounds the cost.
- At most 4 connections may be waiting to prove the token, and live plus pending ≤ max_tablets + 4. Anything beyond is destroyed at once.
- Each accepted socket becomes a fresh SocketService via a new `adopt(socket, paced: true, untrustedPayloadLimit: 1024)`. The session starts its packet loop before adopting, so the 0xF5 token cannot be dropped.
- Wi-Fi sessions never retry, because the tablet redials. A newly authenticated session whose installId matches a live one evicts the stale one at once.
- The discovery responder lives exactly as long as the listener. Remove the `stopResponder()` calls in admitPacket and onTeardown.

lib/shared/connection/socket_service.dart
- Phase 1: `startServer` drops `shared: true`. With several listeners in one process it silently spreads connections across them.
- Phase 4: `adopt()`, and `startSecureServer` loses `shared`.

lib/shared/connection/adb_service.dart: `removeForward({serial, int? remotePort})`; phase 3 adds `closeInputShell`, with inputTap and inputSwipe going through the shell (`inputShell`); the planned `openInputShell` was not built, the shell opens with the first event.

Channels
- screen_capture_channel.dart: one permanent frames subscription that demuxes by the 4-byte prefix (`ByteData.sublistView(b,0,4).getUint32(0)`, then `Uint8List.sublistView(b,4)`) to `_routes[id]`; an unknown id is dropped. `CaptureHandle open(id)` carries frames, the per-session callbacks and every method with {'session': id}. `close()` disposes it natively.
- input_inject_channel.dart: `session:` on injectMouse, injectKey and releaseAll. setKeepCursor stays global.
- remote_video_channel.dart: `RemoteDecoderHandle open(id)`.

Models and settings
- New lib/shared/models/client_panel.dart and session_spec.dart.
- EncodePresetX gains `configFor(ClientPanel, custom)`. The old getters stay only for Settings labels, which use the focused or last panel.
- settings_service.dart gains:
  - `captureConfigFor(panel, spec)`. Custom scale = customWidth ÷ (panel.width ÷ 2), clamped;
  - `client_panel.<key>`;
  - `known_devices` (JSON: serial, model, vdSerial, installId);
  - `tablet_screen_off.<serial>`;
  - `max_tablets`;
  - in phase 4, `wifi_listen`.
- Migration: today's last_device gets vdSerial 0x0001, so macOS keeps its saved display arrangement, and inherits the global panel and screen-off values. Other tablets get FNV-1a32(key) | 0x10000, stepping past collisions.

Debug only: lib/shared/connection/debug/synthetic_tablet.dart
- A FakeTablet that speaks the tablet's half of the protocol: the 0xF4 hello with the key, HELLO with a chosen panel, pong, and counting frames and bytes.
- A SynthAdb that hands the key to the FakeTablet in-process instead of through adb.
- Enabled only with `--dart-define=SYNTH_TABLETS=N` in debug builds, behind a const check so release builds tree-shake it. Synthetic serials ('synth-1' and so on) are never written to known_devices or other prefs.
- The same FakeTablet is used by the unit tests, because two real ClientConnectionManagers cannot share one process: they both Get.find the single UsbSessionService.

Tests
- wifi_link_test and tablet_screen_off_test: `HostConnectionManager(socket:, port:)` becomes `HostSession(..., pipeline: PipelineQueue(), socket:, port:)`. `_NoAdb` records reverse(local = P, remote = 7001), and `_Tunnel` forwards to P.
- host_launch_test's `_LaunchHost` subclasses the hub.
- New multi_usb_test (two HostSessions plus two FakeTablets on loopback):
  - a hello made with A's key on B's port is rejected and never re-delivered to A;
  - stopping or failing A mid-handshake or mid-capture-start leaves B's phase, frames and input alone;
  - frames from native id 1 never reach B's socket;
  - A's teardown never releases B's button;
  - a stop on one device does not block another device's auto-connect.
- New encode_budget_test.

######## client

NOTHING IS REQUIRED ON THE TABLET FOR PHASES 0 TO 3. Builds already installed on tablets keep working with the multi-tablet Mac.
- Each tablet still runs one ClientConnectionManager with one session and one Mac.
- It dials its own 127.0.0.1:7001, which adb now maps to that tablet's own Mac port.
- It receives only its own key (`adb -s X`).
- Its hello verifies only on its own session.
- DisplayController, DisplayView, the HUD, reverse-remote capture, WifiPairingReceiver and every Kotlin plugin are unchanged, as is the handling of 0xF9/F8/F7/FC/FB/FA/FF.

Phase 4, optional and recommended for multi Wi-Fi (no lockstep with the Mac):
- `ClientConnectionManager._sendHandshake` appends the identity tail: 0xA1, a 16-byte install id (made once and kept in SharedPreferences as `client_install_id`), the name length, then the name. Send it on both links.
- The name comes from one new method, `getDeviceName` on the existing `extended_screen/keepalive` channel (ClientKeepAlivePlugin.kt), returning Build.MANUFACTURER + ' ' + Build.MODEL. If that call fails, the tail carries only the id. No new plugin or package is needed.
- Old Macs ignore the tail.

Phase 5, optional:
- Handle 0xF1: show 'error_host_at_capacity' and redial every 30 s instead of 5 s until a new session key or pairing arrives.
- Handle 0xF2: DisplayView flashes the tablet's name for a second.

Not planned unless you choose per-tablet tokens: any change to WifiPairingService.parsePairingPayload or storePairing.

A fact the plan relies on, checked in client_connection_manager.dart:
- `_onSessionKey` returns at once when the tablet's link is Wi-Fi. A USB key delivered to a tablet that is on Wi-Fi changes nothing on the tablet.
- The Mac's USB session for it would just time out and retry, which is why the hub parks or backs off such sessions.

######## ui

HOME (Mac)
Phase 1: nothing visible changes. The hub shows the focused session's values, so today's single card, device info, latency chip, error banner and Open-remote button read exactly what they read now.

Phase 2: home_view.dart becomes a list:
- The permission banner, as today. Every user-started connect stays behind _ensureHostPermissions; auto-connect only checks permissions.
- One SessionCard per tablet (new widgets/session_card.dart), each an Obx over its own session.
  - It reuses ConnectionCard, DeviceInfoCard and LatencyChip.
  - It shows: the model (or address); a link chip and a mode chip; the connection steps for its phase; latency, fps and bitrate; the quality it was granted ('2960×1848 · 45 fps, encoder shared'); and its own error line ('Extend unavailable, mirroring', 'Not started: this Mac's encoder is full', 'Unplugged, waiting', 'The tablet app is set to Wi-Fi').
  - Actions: Disconnect or Cancel (stops only this tablet and adds it to stoppedDevices), Retry, Open remote, and tap to focus.
  - The ConnectionCard button is keyed by `'<key>/<label>'`, so 'one touch never means two things' holds per card.
- An always-visible 'Add a tablet' panel.
  - It holds the existing DevicePickerCard over freeDevices (adb devices minus those in a session). Emulators are listed and can be added by hand.
  - Header: 'Tablets 2 of 4 · Encoder about 70% (H.265)'.
  - A device that would not fit is disabled with the reason ('This Mac is at its limit').
  - Until phase 3, the mode, direction and link selectors keep today's rule: shown only while no tablet is connected, and every tablet shares the mode.
- AppBar: the app name, plus '· N tablets' when N > 1, instead of the global mode label.

Phase 3:
- The mode and direction selectors move into the Add panel and apply to the next tablet. Mac-controls-tablet is greyed out for a Wi-Fi tablet.
- A live tablet's mode changes only from its card, which restarts only that tablet.
- As built: the selectors set the mode of the next tablet the user adds; a known tablet that connects by itself comes back in the mode it last ran in (kept in `known_devices`), and its tile says so.

Phase 4:
- The host's link selector becomes a toggle, 'Listen on Wi-Fi', which can run alongside the USB tablets.
- The Wi-Fi address card stays visible whenever the toggle is on, with a count of connected Wi-Fi tablets.

SETTINGS
Phases 1 to 4:
- Preset, codec, display mode and custom values stay app-wide, applied to each tablet's own panel.
- A change restarts every tablet (`hub.reconnectAll`, still debounced 350 ms). Since phase 3 a display-mode change alone restarts only the Extended-screen tablets (`reconnectExtendedOnly`): remote-control sessions always mirror.
- The HUD and overlay toggles go to every tablet without a restart.
- The preset labels use the focused tablet's panel.
- New rows: 'Maximum tablets' (1 to 8, default 4) and a read-only 'Encoder' line (chip, codec, prior or measured capacity).
- The Info 'Target device' row lists the connected tablets.
Phase 5:
- A per-tablet sheet /device-settings {key} opened from a card. It saves that tablet's profile (preset, codec, display mode, mode, auto-connect, name) and restarts only that tablet, debounced per tablet.
- App-wide Settings keeps language, permissions, keep-Mac-cursor, Reset Wi-Fi pairing and 'defaults for new tablets'.

REMOTE VIEW (phase 3)
- /remote-host becomes a grid of the Mac-controls-tablet sessions: 1 tile fills the window, 2 sit side by side, 3 or 4 form 2×2, more scroll.
- An optional `{focus: key}` argument opens one tile full-size, with a strip to switch.
- Each tile has its own small controller bound to its session's texture, streaming flag, screen-off flag and latency. Its aspect ratio and tap mapping use that tablet's own panel.
- Each tile keeps its own pointer state, so a press in tile A released over tile B sends nothing to B.
- Tile bar: name, latency, screen-off (per serial), Reconnect and Disconnect (that tablet only), Expand.
- The first Mac-controls-tablet session going live opens the route; later ones join without navigating. The route pops, or shows an empty state, when the last one ends.
- Everything stays in one window. A second macOS window means a second Flutter engine, which sees neither these textures nor the Get services.

PER-TABLET STATE (Mac prefs)
- `known_devices`: serial, model, virtual-display serial number, installId, and since phase 3 the mode and direction it last ran in.
- `client_panel.<key>`.
- `tablet_screen_off.<serial>`.
- In phase 4, `wifi_listen`. In phase 5, `device_profile.<key>`.
- The old global keys stay as fallbacks and as the migration source.

DEBUG ONLY (`SYNTH_TABLETS`): a 'Loopback preview' page. It decodes each synthetic tablet's stream on the Mac into a tile, so the owner can see which display each stream really shows.

TRANSLATIONS: every new label and error key goes into both the en and th maps: error_device_gone, error_encode_limit, error_extend_unavailable, error_tablet_on_wifi, home_add_tablet, home_tablets_count, settings_max_tablets, settings_encoder, remote_grid_empty, and the others. Chip labels stay literal, as today.

TABLET UI: unchanged (an optional 0xF1 message and 0xF2 name flash in phase 5).

######## limits

WHAT ACTUALLY LIMITS THE MAC
Not the number of displays.
- CGVirtualDisplay has no published cap. Six at once is reported working, and virtual displays do not use the chip's external-display hardware.
- ScreenCaptureKit allows one stream per display, at roughly 25 to 66 MB of buffers per 2960×1848 stream.
- The binding limit is the video encoder. The M3 Pro has one encode engine, shared by every tablet. This repo measured roughly 274 Mpx/s for H.264 (one session saturates near 50 fps at 2960×1848) and roughly 550 Mpx/s for H.265.
- Past that, nothing fails. Every stream slows down, because VideoToolbox blocks the encode call. A new encoder created with only 'enable hardware' can also land silently on a software encoder.
- The maximum is therefore decided at run time, not fixed. A configured cap sits on top of it as a safety net.

HOW THE MAXIMUM IS FOUND (the lowest of four wins)
1. Configured cap: 'Maximum tablets', default 4 (range 1 to 8). It covers what has not been tested (Apple bug FB17797423, more than ~6 displays).
2. Encode budget, in Mpx/s (encoded width × height × fps).
   - Starting estimate: the chip from sysctl selects an engine count (1 for base and Pro, 2 for Max, 4 for Ultra), times this repo's M3 Pro figures. An Intel or unknown chip gets a conservative estimate, capped at 2 tablets.
   - Usable = 85% of that.
   - Learned: when two or more tablets run and any one's encoder reports overload for 3 s, the sum of the rates all of them achieved becomes the measured capacity. It is saved per chip and codec and replaces the estimate (a later, higher measurement raises it).
3. Virtual display, per creation. Checks: id ≠ 0, settings applied, listed by ScreenCaptureKit within ~1.5 s, first frame the expected size. If a check fails, that tablet mirrors instead and its card says so. The number of virtual displays at that moment is saved as the Extend ceiling for this chip and macOS version, and the picker marks Extend 'at limit'.
4. Hardware encoder, per creation. Every encoder after the first must be hardware. Busy (-12915) or none (-12908) refuses that tablet with a reason. For Mac-controls-tablet, decoders work the same way (-12913).

HOW IT IS SHARED AND ENFORCED (EncodeBudget, in Dart, unit-tested)
- Each tablet has a wanted rate (its preset at its own panel) and a floor (its resolution at 30 fps).
- When a tablet joins, after its HELLO gives the panel:
  - (a) If the floors of every tablet, the newcomer included, do not fit the usable budget even with the newcomer at half resolution, the newcomer is refused.
  - (b) Otherwise every tablet starts at its wanted fps. While the total is over budget, the tablet with the largest demand steps one notch down the existing ladder (120, 90, 60, 45, 30). Running tablets change only their frame rate, live, through setFrameRateCeiling. No restart, no resolution change, no keyframe; they re-announce 0xFB as they already do.
  - (c) Only the newcomer can be given a lower resolution, and only when its native 30 fps floor does not fit: native, then 1920 wide, then half.
- When a tablet leaves, the ceilings are recomputed upward, and each tablet's own Max ladder climbs back within its ceiling.
- The Max preset's per-tablet adaptive ladder stays as it is. The ceiling is all that stops two ladders from fighting.

ROUGH M3 PRO NUMBERS WITH H.265 (to be confirmed by test T3)
- 1 tablet at native 60 Hz.
- 2 at native, about 45 fps each.
- 3 at 1920 wide, 60 Hz.
- About 5 at half resolution, 60 Hz.
- H.264 gives about half of each.
- An idle tablet costs as much as a busy one today, because the encode timer re-encodes the last frame on every tick. Reducing that is the single biggest win for N > 1 (phase 5, after T3, keeping the host-clock timestamps).

WHAT THE UI SHOWS AT THE LIMIT
- The Add panel header shows tablets used of the cap, and the encoder load.
- A device that would not fit is disabled, with 'This Mac is at its limit'.
- A tablet that got less than its preset shows what it got ('1480×924 · 30 fps, encoder shared').
- A refused tablet keeps its card, showing 'Not started: this Mac's encoder is full' with a Retry button. Retry runs admission again.
- Extend that could not be made shows 'Extend unavailable, mirroring'.

PAST THE MAXIMUM
- The refusal is terminal: `handleLinkFailure(retry: false)`.
  - Its tunnel is removed, so the tablet's own 5 s redials fail at once against nothing and cost the Mac nothing.
  - Its virtual display is released.
  - It is not retried every second, because rapid create and destroy of virtual displays is reported to corrupt CoreGraphics' display-id pool.
- Tablets already running lose at most some frame rate. They are never restarted or resized for a newcomer.
- From phase 5 the tablet can be told why (0xF1).

OTHER CEILINGS, SHOWN BUT NOT ENFORCED
- USB: tablets behind one USB 2.0 hub share 480 Mbps. Put one tablet per Mac port.
- adb: one adb server carries every tunnel. A restart drops them all at once, and backoff with jitter keeps the reconnects from storming.
- Wi-Fi: shared airtime, roughly 2 to 4 tablets at 20 to 30 Mbps on good 5/6 GHz, more with the Mac on Ethernet. Each link keeps its own BitrateAdapter. A cap on the total comes in phase 5.
- The main thread and UI isolate: every frame hops through both. Measure with 3 or 4 tablets before raising the cap past 4.

######## phases

Each phase ships on its own and keeps one tablet working exactly as today. Each updates CLAUDE.md in the same commit. The owner runs every hardware check himself:
- Install nothing on the Tab S10 Ultra unasked.
- A test build means quitting the running Mac app first. It is the same bundle id and preferences file, and both copies would fight over the tablet's adb tunnel.

HOW TO TEST N > 1 WITHOUT A SECOND TABLET (used from phase 2 on)
(a) Android emulator(s) as real second and third clients. They go through real adb, reverse, key delivery and decoding.
  - Pick a tablet AVD with a different panel and 60 Hz (for example 2560×1600). That checks per-tablet panel sizing and refresh rate against the Tab S10 Ultra's 2960×1848 at 120 Hz.
  - Add the emulator from the picker. Auto-connect ignores emulators while a physical device is attached, on purpose.
  - Use H.264 if the emulator image shows no picture with H.265.
  - Over Wi-Fi the emulator is behind NAT. Type 10.0.2.2 as the Mac's address on it; the Mac then sees it as 127.0.0.1. Two emulators therefore share one IP, which is exactly why Wi-Fi sessions are keyed by the HELLO install id and not by IP.
  - MediaProjection and `adb shell input` work on an AVD, so Mac-controls-tablet can be tested. Do not rely on the screen-off helper there.
(b) Any Android phone with the app is a real second client too. Nothing is tied to a tablet model. It is the only cheap way to test Wi-Fi airtime and the feel of input with two real devices.
(c) Synthetic tablets (debug build, `--dart-define=SYNTH_TABLETS=N`): N in-process fake tablets, each with real virtual displays, real ScreenCaptureKit and real VideoToolbox encoding. The Mac's limits are the binding ones, so this measures them with no tablet at all (T1 display ceiling, T3 encoder concurrency, T5 sleep/wake). The Loopback preview decodes each stream on the Mac, so T2 (does each stream show its own display after the display set changes) can be checked by eye.
(d) Unit tests: two HostSessions plus two FakeTablets on loopback, in one process.

PHASE 0: native session ids, still one tablet (effort L, mostly Swift)
- Changes: the three native registries with a session argument (missing means 0); Swift honours 'mode'; App Nap reference-counted; the encoder callback counter box; stopCapture waiting for the timer thread; the VTCompressionSessionCreate status checked; add-only virtual displays with a serial number from Dart (0x0001 for now); remove answering once the display is gone; the frame prefix and Dart demux; per-session input state (the lease does nothing with one tablet); per-session RemoteDecoder; removeForward by port.
- Proves: the id plumbing between Dart and Swift, with no visible change. It also fixes latent bugs: a freed-object crash path, the ignored mode, other tools' adb reverse rules being wiped, a black stream when the encoder fails to create.
- Tests: `flutter test` stays green, and `flutter build macos --debug` compiles the Swift.
- Owner smoke test: one tablet in Extend, Mirror and Mac-controls-tablet, sleep/wake, unplug and replug.

PHASE 1: hub and session split, at most one tablet (effort M to L)
- Changes:
  - HostSession (moved body), PipelineQueue, and the hub with its facade and adb routing.
  - The per-tablet Mac port: bind 127.0.0.1:0, then reverse tcp:7001 to tcp:P, then the key.
  - `shared: true` dropped from the loopback bind.
  - SessionSpec and ClientPanel snapshots; per-tablet panel and screen-off prefs, with migration.
  - Injectable AdbService; retry backoff (first retry still 1 s).
  - The FakeTablet and SynthAdb helpers.
- Proves:
  - The split preserves behaviour: Home, Settings, remote view, splash auto-connect, hidden launch, Wi-Fi, and every existing test unchanged apart from the constructor rename.
  - The new tunnel shape works with tablet builds already installed.
- Owner check: `adb -s <serial> reverse --list` shows `tcp:7001 tcp:<P>`.

PHASE 2: several extended or mirrored tablets over USB, the first goal (effort L)
- Changes:
  - The cap rises to 'Maximum tablets' over USB. Every tablet shares the mode (Extend or Mirror). Wi-Fi stays single.
  - SessionCards, the Add panel, the device poll, auto-connect of remembered devices, per-device stop.
  - Per-tablet virtual-display serial and name.
  - Hardware-required encoders after the first; EncodeBudget with the chip estimate and live fps ceilings.
  - Wake rebuilding everything in order; every tablet refreshing its bounds.
  - The pointer lease active.
  - The virtual-display grace period, if test T2 shows the Apple bug.
  - Synthetic tablets and the Loopback preview.
- Unit tests: multi_usb_test (see host_dart), encode_budget_test, the Home tests rewritten for cards and a picker that excludes busy devices.
- Hardware tests:
  - Tab S10 Ultra plus an emulator, extending side by side, with taps on each landing on its own display;
  - synthetic N = 2 to 6 for T1, T3 and T5;
  - T2 with 2 to 3 displays coming and going while the preview is watched.
- Release gate: T1, T2, T3 and T5 done. 'Maximum tablets' set from their results.
- Proves: two or more tablets each extend the desktop with correct input, and the limit is enforced visibly.

PHASE 3: several remote-control tablets, the second goal, plus mixed modes (effort M)
- STATUS: done in code and unit tests (plan and unit list: docs/phase3/plan_final.md; what was built differently from that plan, unit by unit, and what its verifiers left open: docs/phase3/impl_results.md, which is right where the two disagree). The hardware checks at the end of this block are the owner's and are still open.
- Decisions taken, where the lines below left them open or were changed:
  - Mode per session. Every session the hub makes carries a final choice (mode and direction), Wi-Fi's one session included; retries, reconnects and restarts keep it. No session object ever holds two modes: a live tablet's mode is changed by ending its session and making a new one for the same key (`hub.changeMode`), which never shows `disconnected`, holds the tablet's place under the cap and keeps the auto-connect policy away meanwhile.
  - The cap no longer depends on the mode: over USB it is min(Maximum tablets, the encoder estimate's tablet cap) in every mode; Wi-Fi stays 1. The replace-on-pick path is left only for Wi-Fi and Maximum tablets 1.
  - A pick's mode. The user's own connect (an Add-panel tile, the Connect button, the Loopback preview's Start) takes the Add panel's selectors, read at the tap. The auto-connect policy and the hub's own connects take the tablet's remembered mode, else the selectors. The selectors are the existing `session_mode` / `remote_direction` prefs; no new pref and no migration.
  - Changing a card's mode: inline hints in the menu items, no confirm dialog. The tablet app does not change (no tablet build, no wire change), so after a change to Mac-controls-tablet its user taps Start screen sharing, and after a change away from it, Open View.
  - /remote-host is a grid of the Mac-controls-tablet sessions and opens when the count of live ones leaves 0, not from the facade's phase or the selectors. A tile's Disconnect ends its tablet without stopping it (it may connect again by itself, as the old view's did); the last tile's Disconnect closes the view.
  - InputShell: numbers only cross from Dart, Swift builds the line; FIFO with a 1 s age bound; a marker per line; a duration-aware watchdog; opened lazily, not by an `openInputShell` call; the per-tap process stays as the fallback.
  - Remote decoders are made again only for changed parameter sets or a failed session, choose hardware at each creation, report failure and recovery to their own session, and hold an App Nap activity.
  - Mirror captures beside virtual displays (FB17797423): a first-frame check against the main display's shape, a repair round that takes every display down and starts the Mirror capture first, and wakes that start Mirror captures before any display is made. A main display with the same aspect ratio as a virtual display stays undetectable.
  - Settings: a display-mode change restarts only Extended-screen tablets; a change made while a restart runs is applied by one more.
  - A tablet that is not Android can only drive the Mac: the pure rule exists (`SessionChoice.effective(android: false)`), the hook after HELLO waits for the iOS branch.
- Deferred from this phase:
  - The pointer lease for moves between several tablet-controls-Mac tablets (listed under Changes below). Presses are already arbitrated by the pointer owner, and with keep-Mac-cursor on a plain move only sets that tablet's scroll anchor; decide after hardware item 5.
  - An encode-only cap split from the tablet cap, so a Mac with an unknown chip (tablet cap 2) could take a third tablet that only runs Mac-controls-tablet.
  - The owner's example with an iPhone as the remote screen beside the extending Tab: it needs USB and Wi-Fi at once (phase 4) and the ios-p0-spike merge. docs/ios-client-design.md's P3 gate was updated for per-session modes.
  - Changing a live Wi-Fi tablet's mode from a card (phase 4, with per-session Wi-Fi cards); until then disconnect, pick the mode, connect.
  - One device seen under two adb serials (USB and `adb connect ip:5555`) getting two sessions: older than this phase, left for phase 4's link work (a per-transport `ro.serialno`).
  - Real drags through InputShell (`input motionevent`), a decoded-size callback so a tile follows a rotated tablet, the remote decoders off the main thread, a Mac-side decoder budget, a Loopback preview for a synthetic Mac-controls-tablet tablet, and 0xF9 before encoder admission.
- Hardware checklist (owner; none of it was run):
  1. The Tab S10 Ultra and an AVD, both Mac-controls-tablet: each tile drives its own tablet; screen-off works per serial.
  2. The Tab extending plus the AVD in Mac-controls-tablet.
  3. The Tab extending plus a second device in tablet-controls-Mac: the mirroring tablet keeps showing the main display after joins, replugs, a mode change and a sleep and wake (watch for `error_mirror_wrong_display` and the repair round in the log). The replug that matters is the extending Tab's (its virtual display is made again beside the Mirror capture); an AVD has no cable, so for its own leave and join close and reopen its app or restart the emulator.
  4. Two tablet-controls-Mac sessions mirroring at once.
  5. Two input-driving tablets (tablet-controls-Mac twice, and Extend plus tablet-controls-Mac): a tap on B during a drag on A is dropped, the keep-Mac-cursor return lands correctly, a scroll goes to the right window; with keep-Mac-cursor off, note how moves feel (input for the deferred lease). Needs touches that do not come from the Mac's own mouse, see the note on an AVD below; the feel of moves needs two real touch devices.
  6. A live mode change in both directions, checking that the menu's hints match what the tablet shows.
  7. A Mac app relaunch: each tablet comes back in its remembered mode by itself. With the Tab and an AVD only the Tab does: auto-connect skips emulators beside a real tablet, and the AVD picked by hand takes the Add panel's mode, not its remembered one (both on purpose). To see two remembered modes come back: relaunch with the Tab unplugged, so the AVD comes back alone in its mode, then plug the Tab in; or use two known AVDs with no real tablet attached and Maximum tablets 2 or more; or a second real device.
  8. The unified log shows no per-keyframe decoder rebuilds and no DECODER_BUSY; with the host window closed the Mac-controls-tablet streams stay smooth.
  9. Mac-controls-tablet taps through the input shell (the AVD first, then the Tab; whether `adb shell -T` with no command reads stdin on every tablet build has never been checked on hardware): `ps` on the Mac shows one `adb -s <serial> shell -T` per controlled tablet; taps land in order; a double tap and a quick burst arrive whole, and a long burst never lags more than about a second (the plan's open question: is the 1 s age bound right); a 2 s swipe is not cut; the first tap after a tile's Reconnect goes through a fresh shell (`input shell <serial>: closed`, then `opened` in the log); after a cable replug the next tap lands; quitting the app leaves no such `adb` process. The unified log (category `adb`) must not say `input shell <serial>: never answered` (from then on that tablet's taps go one adb process each for the rest of the run, which still works, so item 1 alone would not show it), nor keep repeating `ended by itself` or `no answer to`.
  10. A Mac-controls-tablet picture survives a cold start (it appears on a newly made decoder: the first session after the Mac app is launched, and after a tile's Reconnect), a tablet rotation and a Mac sleep and wake.
  11. Settings with one tablet extending and one in Mac-controls-tablet: changing Extend/Mirror restarts only the extending one, and the other keeps its picture with no new consent; changing the codec or the preset restarts both, and the Mac-controls-tablet one needs Start screen sharing again. (Unit-tested; this is a look at the real consent prompt.)
- With an AVD as the second device (items 1 to 7 are written for the Tab S10 Ultra plus one AVD; a spare Android phone with the app is a real second device, see HOW TO TEST N > 1 above):
  - Item 1: screen-off is checked on the Tab only; the helper is not to be relied on in an AVD.
  - Item 5: an AVD's touches made with the Mac's mouse in the emulator window prove nothing here. They hold a real Mac button down and steer the one Mac cursor, the very pointer the injected input borrows, so scrolls are dropped and the cursor return and the scroll settle stand down (`NSEvent.pressedMouseButtons`), and a click "on B" during A's drag is a real Mac click wherever A's drag has put the cursor. Make B's touches with `adb -s emulator-NNNN shell input tap <x> <y>` and `… input swipe …` from a terminal instead (start it behind a `sleep 5;` so the drag on the Tab is under way): that shows the dropped tap, the cursor return and the scroll's window. How moves feel with keep-Mac-cursor off needs two real touch devices.
  - Item 7: beside the Tab an AVD never comes back by itself; use one of the three ways the item gives.
- Owner requirement (2026-11-19): mixed modes across devices, one mode per device at a time. Example: Mac in the centre, the Tab S10 Ultra extending, an iPhone 18 Pro Max as a remote screen (tablet-controls-Mac, since Mac-controls-iPhone is impossible on iOS; see docs/ios-client-design.md). A device is never extended and remote at once.
- Changes:
  - The mode is chosen per tablet in the Add panel and kept across that tablet's retries.
  - The /remote-host grid; per-serial InputShell; per-serial screen-off; per-tile pointer state.
  - Several tablet-controls-Mac sessions mirroring the main display, each with its own stream and encoder, sharing the cursor through the lease. (Built without a lease for moves; see Deferred above.)
- Tests: grid and tile unit tests (taps routed to the right serial, scaled by that tablet's panel; a press released over another tile sends nothing).
- Hardware: Tab S10 Ultra plus an emulator, both viewed and driven from the Mac. Then one extending and one in tablet-controls-Mac at the same time.
- Proves: both remote directions work for several tablets at once, mixed with extended ones.

PHASE 4: several Wi-Fi tablets, and USB and Wi-Fi together (effort M)
- Changes:
  - The hub-owned TLS listener with handshake deadline and pending cap; SocketService.adopt.
  - The responder staying up while listening; the 'Listen on Wi-Fi' toggle.
  - Identity reset across all tablets.
  - The HELLO identity tail (tablet build) and standby for a tablet that is on Wi-Fi while plugged in.
- Tests: wifi_link_test gains two clients on one listener, a rogue client holding a pending slot while a paired one still gets in, and a stale session evicted by the same install id.
- Hardware: Tab S10 Ultra over Wi-Fi plus an emulator over USB, then the reverse arrangement. Real airtime needs a phone or a second tablet (T7).
- Proves: paired tablets over the LAN alongside USB ones; a port scan never touches a live session.

PHASE 5: capacity learning and polish (effort M)
- Changes:
  - Learned encoder capacity; fewer encodes for idle displays (after T3).
  - The per-tablet settings sheet and profiles.
  - Optional: 0xF1 and 0xF2; a total Wi-Fi bitrate cap after T7; `adb track-devices` hot-plug; the menu-bar tablet list; 420v decode output.
- Proves: the measured maximum is the one enforced, and different tablets can run different presets.

######## risks

1. Apple bug FB17797423 (highest).
- With several virtual displays, once the set changes, a new capture stream can show the most recently added display instead of its own, until all of them are gone.
- Reported unfixed since macOS 12.3. It is not yet known whether macOS 27 still has it.
- Tablets coming and going independently is exactly the trigger.
- Detection: with different panel sizes, a wrong-size first frame catches it. With same-size tablets nothing automatic can.
- Mitigations: rebuild in a fixed order on wake; keep a lost tablet's display alive for a grace period; run test T2 before phase 2 ships. If T2 reproduces it, rebuild every stream whenever the set changes (each running tablet blips for about a second).

2. One shared encoder.
- Tablets slow each other down instead of failing.
- Idle displays cost full encode time until phase 5.
- The capacity figures come from one machine. Max, Ultra and Intel Macs are untested.
- Two concurrent 4K60 HEVC encodes panicked an iPhone 16 Pro (Apple reproduced it). macOS is untested.
- Mitigations: hardware-required encoders after the first, OSStatus checks, the budget's ceilings, and synthetic N-tablet runs (T3) before raising the cap.

3. Virtual-display lifecycle.
- Removal is asynchronous (up to about 0.7 s).
- A display whose mode was changed can stay until the app exits, so never call CGDisplaySetDisplayMode on them.
- Rapid create and destroy can corrupt the display-id pool, which is why limit errors are terminal and USB retries back off.
- New serial numbers reset macOS's saved arrangement once. The tablet in use today keeps 0x0001.

4. One Mac cursor for every input-driving tablet. With the lease, a second tablet's tap during the first tablet's drag is dropped, which can feel like a lost tap. The keep-cursor return logic was tuned for one source. Covered by unit tests; the feel needs two real devices (an emulator's mouse-driven input is a weak stand-in).

5. The split itself.
- The hub facade must reproduce today's single-tablet behaviour exactly: the phase guard, retry semantics, hidden-launch auto-connect, the remote-view auto-open.
- A `settings.` read missed inside HostSession leaks one tablet's state into another. Before each release, grep host_session.dart for isReverseRemote, effectiveDisplayMode and clientPanel.
- A nested PipelineQueue call deadlocks.
- A session removed without disposing its `ever` worker leaks.

6. Load. Every encoded frame of every tablet hops to the main thread and through the UI isolate. Measure with 3 to 4 tablets at 60 to 120 Hz before allowing more. The fallback (sending from Swift per session) is a large change and is not planned.

7. adb is shared.
- One adb server carries every tunnel. Another tool starting a mismatched adb drops all of them at once.
- The USB backend keeps changing between platform-tools releases.
- Tablets on one USB 2.0 hub share 480 Mbps, and nothing detects USB congestion.
- One tablet with wireless debugging can be listed twice (serial and mDNS name). The picker hides the mDNS entry when the serial is present.

8. Same tablet on two links. Until phase 4's identity tail, a plugged-in tablet whose app is set to Wi-Fi makes its USB session retry. Backoff to 30 s and a card message keep that cheap, and the identity tail fixes it.

9. Wi-Fi.
- Shared airtime; one far tablet slows the rest.
- Per-link adapters may oscillate together.
- One shared token, so a single tablet cannot be revoked, and a paired tablet could claim another's install id (all paired tablets are the owner's).
- Whether destroying the raw socket aborts a server-side TLS handshake must be proven by a test.

10. Preference migration and test churn. The global keys move to per-tablet keys, and five test files assume one host manager.

11. Debug-only code. The synthetic adb stand-in hands keys over in-process. It must stay behind a const debug flag so release builds cannot contain it.

######## decisions

Each item has a recommended default; you only need to answer where you disagree.

1. How many tablets at most. Default: a 'Maximum tablets' setting, default 4, with the encoder and virtual-display limits applied below it. Revisit after T1 and T3.

2. Auto-connect with several tablets. Default:
- At launch and on plug-in, connect every attached tablet that has streamed before and that you did not stop.
- A never-seen tablet connects by itself only under today's rule (nothing connected and exactly one candidate).
- Emulators are never auto-connected while a real tablet is attached.

3. What happens when a new tablet does not fit. Default: share by frame rate.
- Running tablets may drop frame rate live, never resolution, never restarted.
- Only the newcomer may get a lower resolution.
- Below half resolution at 30 fps it is refused, with a Retry button.
- Alternative: never touch running tablets. Then a first tablet on the Max preset usually leaves no room for a second.

4. Extend when a virtual display cannot be created. Default: that tablet mirrors the main display instead, and its card says so. Alternative: refuse it.

5. Mode per tablet or one mode for all. Default: one mode for all in phase 2; per tablet, chosen when adding it, from phase 3. Done in phase 3: chosen when adding, changed from the tablet's card, remembered per tablet for automatic connects.

6. Encode settings (preset, codec) per tablet. Default: app-wide, applied to each tablet's own panel, until the phase 5 per-tablet sheet.

7. Several tablets driving the one Mac cursor. Default: allowed, the first tablet to press keeps the pointer until it releases. Alternative: only one input tablet at a time, the others view-only.

8. Keeping a disconnected tablet's virtual display for a moment. Default: 10 s after a lost link (not after your Disconnect), and only while another virtual display exists, so a single tablet behaves as today. The cost is that windows wait on an invisible display for up to 10 s. Settle it after T2.

9. Recognising Wi-Fi tablets. Default: a random install id that the tablet sends in its HELLO (no simultaneous update of Mac and tablet needed). Alternative: per-tablet tokens issued by the Mac through adb. It also needs no simultaneous update, but it is more code; its only gain is revoking a single tablet.

10. USB and Wi-Fi at the same time. Default: yes. A 'Listen on Wi-Fi' toggle runs alongside the USB tablets and replaces today's either-or selector (phase 4).

11. Synthetic tablets in the app, debug builds only, behind a build flag. Default: yes. They are the only way to measure this Mac's real limits without a second tablet.

12. Shipping before testing with two physical devices. Default: ship phase 2 after the emulator plus synthetic tests and T1, T2, T3 and T5. Use a spare Android phone as the second real device if you have one.

13. One shared encode for identical mirror tablets. Default: not in v1.

14. Remote view layout. Default: one window with a grid and a focus mode; a separate window is not workable.

15. Spotting plugged-in tablets. Default: poll adb every 3 s in phase 2; `adb track-devices` later.
