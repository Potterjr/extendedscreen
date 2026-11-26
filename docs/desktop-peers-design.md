# Desktop peers: Mac and Windows as equals

Status: design, 2026-11-26. Owner's decision: there is no fixed host between desktops. Base: main a3de44d (worktree `beside`) and branch `windows` (9f69d79). This document builds on the design the reviewers preferred (per-peer tokens in an unchanged `0xF5`, the proposal carried in the HELLO tail, a Mac-side-only first milestone). It adds the stronger safety and UX rules from the other two designs and fixes the flaws the reviewers found.

## Summary

A Mac and a Windows PC are both **desktop peers**. Each runs the hub, listens on the LAN, and can start a session with the other. Two things decide who does what in a session:

- **The link role.** The side where the user pressed Start dials. The other side answers.
- **The media role, set by the feature, not by the OS.**
  - In Extended Screen the provider is the device that gains a display.
  - In Remote Control the provider is the device being controlled.

The provider captures, encodes, owns the encoder settings and accepts input. The viewer decodes and sends input.

Between desktops, a short negotiation replaces today's one-way `0xF9`:

1. The dialler proposes a feature and a provider side in its HELLO.
2. The answerer accepts, or refuses with a reason. The first time, the answerer's user is asked.
3. After an accept, the provider sends today's `0xF9`/`0xFC`/`0xFB`/`0xFA` and frames, exactly as a Mac does to a tablet now.

All new bytes are CONTROL sub-commands in `0xE0`–`0xE9`. They are sent only to a peer that has authenticated with a per-peer token and declared a desktop platform (`0x05` Windows, `0x06` macOS). Android and iOS stay viewer-only diallers on today's wire, so the Android tablet app needs no update.

Mac↔Windows pairing uses no adb and no devicectl. It is a commit-and-reveal short authentication string (6 digits, compared and confirmed on both screens) bound to both TLS certificates. It needs only SHA-256 from the existing `crypto` dependency. Each side issues the other its own 32-byte token, so:

- a peer never holds the token the tablets share;
- the answerer knows which peer dialled from the token that matched;
- one peer can be revoked on its own.

The first milestone is still "Windows views the Mac over Wi-Fi", which branch `windows` started. The wire already allows the reverse direction: the dialler can be the provider, and ACCEPT can carry the viewer's panel.

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | No fixed host between desktops. Both desktops listen; the one the user starts from dials. | "Mac always host" would rule out the features Windows exists to offer: a Windows PC gaining a display (IddCx), and a Mac controlling a Windows PC. It would also force the user to walk to the Mac to start anything. A fixed host would also need a second, asymmetric code path to undo later. With symmetric peers there is one model, and the mobile case is a special case of it: the mobile is always dialler and viewer. |
| D2 | The feature decides the provider; the OS never does. | Extended Screen: the side that gains a display provides (Mac: `CGVirtualDisplay`; Windows: IddCx, later). Remote Control: the controlled side provides (Mac: ScreenCaptureKit + CGEvent; Windows: Desktop Duplication/WGC + SendInput). Branch `windows`'s OS-based `notAndroid` clamp becomes a capability rule. |
| D3 | Encoder settings (preset, codec, fps, display mode) belong to the provider and are stored there per peer. | The provider runs the encoder and knows its budget. This matches today's per-device settings (aa61bfb). |
| D4 | The negotiation is only between desktops. It is gated on a desktop HELLO byte, a new `0xA2` HELLO tail **and** a per-peer token. | Mobiles never meet a new byte, so no tablet or iPhone update is needed. A token check that only peers can pass is what stops a downgrade or upgrade between the tablet path and the desktop path. |
| D5 | The dialler is authenticated by a **per-peer token** in the unchanged 32-byte `0xF5`. There is no client certificate and no extra HMAC tail. | The listener already compares the first packet's token (`wifi_listener.dart:225-229`). Matching against a set instead of one token names the peer, with no new byte or round trip. The answerer is already authenticated by the pinned TLS certificate. A peer token is never sent outside a TLS connection whose certificate has been pinned, so it cannot be replayed from the wire. |
| D6 | The proposal rides in the HELLO tail (`0xA2`). PROPOSE (`0xE0`) exists for re-proposals. | No extra round trip inside the listener's 3 s HELLO limit. The approval prompt can show the real request at once. Old Macs ignore trailing HELLO bytes. |
| D7 | New bytes: `0xE0`–`0xE5` for negotiation, `0xE8`/`0xE9` for pairing. `0x06` is reserved for a Mac dialler. | Every other byte is spoken for. `0xF3`–`0xFF` are in use, and `0xF6` is dead. `0xF1`/`0xF2` are reserved by multi-tablet phase 5 (multi-tablet-design.md:143-144). `0xF0`/`0xEF` are reserved by the iOS QR contingency (ios-client-design.md:165). No new packet *type*: an old build parses an unknown type as CONTROL and would dispatch its first payload byte. |
| D8 | Pairing is a 6-digit comparison (SAS) with a commitment, bound to both certificates. Pairing payloads travel only after both users confirm. | Desktops rarely have cameras, so QR suits phones, not Mac↔Windows. A plain numeric code under HMAC can be brute-forced offline. A PAKE would need an unvetted Dart implementation. A commit-and-reveal SAS over the TLS certificates gives a man in the middle a 10⁻⁶ chance per attempt using only SHA-256. Sending payloads before confirmation (as one reviewed design did) would hand secrets to anyone who dialled during the window. |
| D9 | Simultaneous dials: the call dialled by the lower host id survives. | Both sides learn both 16-byte host ids at pairing, so both reach the same answer with no extra round trip. |
| D10 | When a legacy answerer (a Mac from before negotiation) sends `0xF9` before any ACCEPT, the dialler takes it as an implicit accept, but only if the dialler proposed to be the viewer. | That is exactly today's branch-`windows` behaviour against a Mac that has not been updated. Any other proposal ends with "update the other computer". |
| D11 | Viewer sessions never count against `EncodeBudget` or `cap`. A provider session for a desktop shares the budget with tablets. | Only encoding costs the Mac's encoder. |

## Roles per session

Each session carries two attributes, both fixed for its life:

| Attribute | Values | Fixed by |
|---|---|---|
| `link` side | `dialler`, `answerer` | Who pressed Start. Only the dialler redials. |
| `media` role | `provider`, `viewer` | The negotiated feature and provider side. |

| Peer pair | Dialler | Answerer | Provider | Path |
|---|---|---|---|---|
| Tablet/iPhone → desktop | mobile | desktop | desktop, except reverse remote over USB (Android) | Today's wire, unchanged |
| Windows → Mac, "use the Mac as a screen / control the Mac" | Windows | Mac | Mac | Negotiation, M1 |
| Mac → Windows, "extend onto Windows / let Windows control this Mac" | Mac | Windows | Mac | Negotiation, M2 |
| Windows → Mac, "let the Mac control this PC" / Mac → Windows, "control Windows" | either | either | Windows | Negotiation, M4 |
| Mac → Windows, "Windows gains a display" | either | either | Windows (IddCx) | Negotiation, M5 |

Between desktops, `0xF9` always says `RemoteDirection.tabControlsMac` for Remote Control, which on the wire means "the viewer controls the provider". `macControlsTab` (reverse remote) needs adb, so it stays a USB/Android-only path and is never negotiated. Code reasons in terms of "provider = dialler/answerer". The enum keeps its wire indexes.

`BaseConnectionManager.isHost` stops being an app-wide fact (M3). Shared UI asks the session for its role, and asks a `DeviceCaps` object whether this device can listen, provide or view.

## Wire

### Framing and the gate

Framing is unchanged: the 17-byte header, 16 MB trusted / 1024 B untrusted payload limits, `connectionId`-based trust. A desktop dialler:

1. Dials TLS and pins the answerer's certificate (today's `onBadCertificate` → certificate lookup, now also in the peer store).
2. Sends `0xF5` + **the token this answerer issued to it** (32 bytes, unchanged layout).
3. Sends HELLO:

```
0x01, platform (0x05 Windows | 0x06 macOS), w u16, h u16, maxHz u8      -- 7 bytes, as today
0xA1, installId(16), nameLen(1), name                                     -- existing tail
0xA2, ver(1)=1, caps u16, sessionId(8), feature(1), provider(1), flags(1) -- new peer tail
```

- `feature`: 0 Extended Screen, 1 Remote Control.
- `provider`: 0 answerer provides, 1 dialler provides.
- `flags`: bit0 `resume` (a redial of `sessionId`). Other bits are 0 and ignored.
- When the dialler is the viewer, the 7-byte HELLO carries its panel as today. When the dialler is the provider, w, h and maxHz are 0, and the panel comes back in ACCEPT.

The answerer's listener matches the token against the identity token (tablets, iPhones) **and** every peer's issued token, in constant time, and reports which one matched. The `0xA2` tail is read only if a peer token matched. The `installId` in `0xA1` is a claim. The peer id the session acts on is the one the token named.

**Admission matrix (no downgrade, no upgrade):**

| Token matched | HELLO | Release build | Debug build |
|---|---|---|---|
| identity | `0x02`–`0x04` (or unknown < `0x05`) | today's path | today's path |
| identity | `0x05`/`0x06`, no `0xA2` | close the connection | legacy viewer path (branch `windows` today, `esp1:` paste pairing) |
| identity | `0x05`/`0x06` with `0xA2` | REFUSE 10 `pairAgain`, close | negotiate, peer named by the `installId` claim, logged as unverified (M1a scaffolding) |
| peer | `0x05`/`0x06` with `0xA2` | negotiate | negotiate |
| peer | anything else | close (no reply) | close |

A peer token can therefore never buy today's unprompted tablet path. The identity token never unlocks the desktop path in a release build, and a release Windows build never holds the identity token, because the paste is debug-only.

### Messages

Every body starts with `ver` (1). Parsers ignore trailing bytes, and fields are only ever appended. All messages are CONTROL sub-commands sent after `peerTrusted`. The exception is `0xE8`/`0xE9`, which run only on a pairing connection (see *Pairing*).

| Byte | Name | Direction | Body after `ver` |
|---|---|---|---|
| `0xE0` | PROPOSE | dialler → answerer | sessionId(8), feature, provider, flags, caps u16, [panel block when the dialler is the viewer]. Used to re-propose on a live link (after END of a feature, or after a version refusal on redial). The first proposal is the `0xA2` tail. |
| `0xE1` | ACCEPT | answerer → dialler | sessionId(8), feature, provider, caps u16, [panel block when the answerer is the viewer] |
| `0xE2` | REFUSE | answerer → dialler | sessionId(8), reason(1), detail(1), maxVer(1). The answerer closes 1 s later. The dialler does not auto-redial a refusal, except reason 6/2 at `maxVer` and reason 8 (see below). |
| `0xE3` | PENDING | answerer → dialler | sessionId(8), secondsLeft(1): the answerer's user is being asked. |
| `0xE4` | END | either | sessionId(8), reason(1): 1 user stopped, 2 unpaired, 3 app quitting, 4 feature switched. The receiver ends the session and does not redial. On reason 1 it puts the pair in `stoppedDevices`. |
| `0xE5` | UNPAIR | either | (none). Best effort, sent just before a local forget; the receiver forgets the sender's record. |
| `0xE6`, `0xE7` | reserved | | |
| `0xE8` | PAIR | dialler → answerer, pairing connection only | step(1) + step body |
| `0xE9` | PAIR_REPLY | answerer → dialler, pairing connection only | step(1) + step body |

Panel block: `platform(1), w u16, h u16, maxHz u8`, the same shape and meaning as HELLO bytes 1–6.

After ACCEPT the provider sends `0xF9` (mode + direction indexes), `0xFC`, `0xFB`, `0xFA`, then `FRAME_DATA`. The viewer sends `MOUSE_EVENT` (and later `KEY_EVENT`) and `0xFF`. Which end of the socket the provider sits on makes no difference to the wire.

### Capability flags (`caps`, u16; unknown bits ignored)

| Bit | Meaning |
|---|---|
| 0 | can provide Extended Screen (`CGVirtualDisplay`, or an IddCx driver installed) |
| 1 | can provide Remote Control (capture + input injection available on this OS) |
| 2 | can view (has a decoder) |
| 3 | decodes H.265 |
| 4 | encodes H.265 |
| 5 | accepts `KEY_EVENT` |
| 6 | listens for incoming sessions |

Caps describe what is installed, not what is currently granted. Permissions change, and a missing one is reported as a refusal. Caps are self-declared: a lie can only deny service, because the provider still enforces its own permissions and approval.

### Refusal reasons

| Code | Reason | `detail` |
|---|---|---|
| 1 | permission missing | 1 Screen Recording, 2 Accessibility, 3 Windows secure desktop/UAC, 4 notifications (cannot ask the user) |
| 2 | busy | 1 already in a session with you, 2 another session controls this computer, 3 remote role taken |
| 3 | no virtual-display driver (IddCx) | |
| 4 | declined by the user | |
| 5 | approval timed out (60 s) | |
| 6 | unsupported | 1 feature, 2 version (see `maxVer`), 3 provider side, 4 codec |
| 7 | encoder at capacity (`CaptureLimit` / `wouldFit` false) | |
| 8 | crossed call (lost the tie-break) | |
| 9 | incoming sessions switched off | |
| 10 | pair again (desktop authenticated with the identity token, release build) | |

Each reason has a translation key `error_peer_<name>` in `en` and `th`, plus a hint (for example "Grant Screen Recording on <Name>").

### Versioning

An answerer that receives a `ver` higher than it speaks replies with REFUSE 6/2 and its own `maxVer`, then closes. The dialler redials once at `maxVer`. A lower `ver` is answered at that `ver`. Version 1 is everything in this document.

### Timeouts

- The listener's 3 s token and 3 s HELLO limits are unchanged; the proposal is in the HELLO.
- The answerer sends ACCEPT, REFUSE or PENDING within 2 s of the HELLO.
- **Dialler waits:**
  - It waits 5 s after HELLO for ACCEPT, REFUSE, PENDING or a legacy `0xF9`.
  - After PENDING, it waits `secondsLeft` + 5 s.
  - If nothing comes, it ends with `error_peer_no_answer`.
- **Approval:** `awaitingApproval` is a new phase on the answerer's session, after HELLO and before any capture. The packet loop and heartbeat run throughout, so the 6 s liveness rule holds. It lasts at most 60 s, then REFUSE 5.

### Legacy answerer

A Mac from before this design treats `0x05` as an Android tablet and opens with `0xF9`. A new dialler that receives `0xF9` before ACCEPT:

- if it proposed "dialler views, answerer provides", treats it as an implicit ACCEPT with the mode `0xF9` names (this is M1's behaviour against an old Mac);
- otherwise ends the session with `error_peer_update_other`.

Such a Mac also saves the Windows panel as its global last panel. That is harmless, and M0 fixes it on new Macs.

### Why the Android tablet is unaffected

- Tablets send HELLO `0x02` (iPhone/iPad `0x03`/`0x04`), never `0x05`/`0x06`, never `0xA2`, and they hold the identity token, not a peer token. By the admission matrix, no answerer ever sends them an `0xE*` byte.
- Tablets never send `0xE*`. Even if one arrived, the client's `onRolePacket` is a chain of `if`s with no default, so unknown sub-commands are ignored.
- No new packet type is introduced.
- The following are unchanged byte for byte: the framing, `0xF5`, `0xF4`/`0xF3`, the 7-byte HELLO and `0xA1` tail, `0xF9`/`0xF8`/`0xF7`/`0xFF`/`0xFC`/`0xFB`/`0xFA`, pairing payload v1 (still what adb and devicectl deliver), and the v1 discovery probe and reply.
- Discovery replies gain an appended tag (below), and the v1 decoder already ignores trailing bytes.

### Discovery tail

The reply (`EXTD!` + ver 1 + hostId + port + name) gains:

```
0xD1, platform(1), caps u16, flags(1)
```

`flags` bit0 means "pairing window open". Responders keep answering the exact v1 probe. The reply stays untrusted: it says where to dial and whether to list a desktop in "Pair a computer". Trust comes only from the pinned certificate and the token.

## Pairing Mac↔Windows

### Who opens what

- On the **answerer**, the user opens Settings → Computers → *Pair a computer*. This opens a **pairing window**:
  - 2 minutes, single use (it closes after one successful pairing);
  - one pairing connection at a time;
  - 3 failed or mismatched attempts in total close it;
  - the existing per-address pending-connection limits apply.
  - Discovery advertises `flags` bit0.
- On the **dialler**, the user opens the same screen. It lists desktops whose replies say "pairing open", and the user picks one.

### Exchange

This runs on a TLS connection on which the dialler accepts any certificate. That is allowed only on a pairing connection, never on a session dial. While the window is open, the listener accepts `0xE8` as the *first* packet in place of `0xF5`; otherwise it drops the connection as today. The 1024-byte pre-trust limit applies until both users have confirmed. A pairing connection never becomes a session: it closes after step 8.

| Step | Packet | Body |
|---|---|---|
| 1 | `0xE8` | ver, platform, certB DER (u16 len), C = SHA-256("esdp-commit" ‖ nonceB ‖ certB) |
| 2 | `0xE9` | ver, nonceA (32) |
| 3 | `0xE8` | nonceB (32). A checks C. |
| — | both | SAS = SHA-256("esdp-sas" ‖ certA_seen ‖ certB_seen ‖ nonceA ‖ nonceB), first 4 bytes as a big-endian integer mod 10⁶, shown as `123 456` on both screens |
| 4 | `0xE8` / `0xE9` | confirm (sent when that side's user presses *Codes match*). On *Don't match*, that side sends abort and the window counts a failure. |
| 5 | both | Once a side has sent its confirm and received the other's, it raises the pairing connection's payload limit to 4 KB. It does not call `trustPeer()`. |
| 6 | `0xE8` | B's pairing payload v2 |
| 7 | `0xE9` | A's pairing payload v2 |
| 8 | both | store, close |

- `certA_seen` is the certificate B's TLS stack saw. `certB_seen` is the one B sent in step 1.
- A man in the middle who terminates TLS shows B a different `certA`, so the two sides hash different inputs. B commits to `nonceB` before seeing `nonceA`, so the attacker cannot grind nonces: one attempt gives a 10⁻⁶ chance, and the window allows three.
- Each side checks that the payload's certificate equals the certificate bound into the SAS (certA_seen on B, certB_seen on A), and refuses otherwise.

**Pairing payload v2** has the v1 layout (`0xF6`, ver = **2**, id16, token32, name, cert, addresses) followed by `platform(1)` and `caps u16`. The `token` field is **the per-peer token the sender issues to the receiver**: the token the receiver will put in `0xF5` when it dials the sender. Each side makes a fresh 32-byte token per peer. Macs keep sending v1, with the identity token, to tablets and iPhones through adb and devicectl. `parsePairingPayload` for v1 is unchanged, and v2 has its own parser, used only on pairing connections.

### Certificates

- The Mac keeps its `/usr/bin/openssl` RSA certificate. Tablets have pinned it.
- Windows has no openssl. It makes a self-signed ECDSA P-256 certificate in Dart (pinned versions of `pointycastle` + `basic_utils`), created at first launch from M1b, so pairing is symmetric even while Windows only dials.
- Pinning is DER equality and does not depend on the algorithm. Nothing else changes.

### What each side stores

`desktop_peers` (SharedPreferences, JSON) is kept apart from `wifi_paired_hosts`, so `storePairing`'s adb/inbox rules are not loosened.

| Field | Meaning |
|---|---|
| `id` | the peer's 16-byte host id (hex) |
| `name`, `platform`, `caps` | from its payload; refreshed on each pairing |
| `certDer` | pinned when dialling the peer |
| `dialToken` | the token the peer issued us; sent in `0xF5` when we dial it |
| `acceptToken` | the token we issued the peer; matched by our listener when it dials us |
| `addresses`, `lastAddress` | as `PairedHost` |
| `grants` | per (feature, provider side): `ask` or `always` |
| `pairedAt` | for the UI |

`storeConfirmedPairing` writes a record. Because a user confirmed it, it **may replace** an existing record with the same id (new token, new certificate). `storePairing` stays v1, adb/inbox only, and is never fed packet bytes. The client's certificate lookup consults both stores.

### Forget and reset

- **Forget** (Settings → Computers): send `0xE5` over a live link, or on a short dial if the peer is online, then delete the record locally whatever happens.
  - Deleting `acceptToken` is the real revocation: the peer can no longer dial us.
  - A peer receiving `0xE5` from an authenticated peer deletes its own record.
- **Revoke "Always"** clears that peer's grants without unpairing.
- **Reset Wi-Fi pairing** (existing) makes a new certificate and identity token. Every peer has pinned the old certificate, so tablets *and* computers must pair again. Settings says so in the confirm dialog. Peer records are kept, so the next pairing replaces them.

## Connection behaviour

### Who listens

Every desktop runs the `WifiListener` and its discovery responder while the app runs. Today's Mac already accepts several Wi-Fi devices through one listener. Windows starts listening in M2; until then it only dials.

*Accept incoming sessions* (Settings, default on) refuses desktop proposals with reason 9. It does not change tablet admission.

### Who dials

The side whose user pressed Start, from Home's peer list or from the last session at launch:

- Auto-connect at launch applies only to the dialler, only to its last session with that peer, and only if no END reason 1 put the pair in `stoppedDevices`.
- The answerer never dials on its own.

### One session per desktop pair

At most one session links two given desktops, matching the one-mode-per-device rule. A proposal while one is live gets REFUSE 2/1. The user ends the session first (END reason 4 switches feature: the dialler re-proposes with `0xE0` on the same link). Sessions with tablets are independent of desktop sessions.

### Simultaneous dials

Suppose desktop X has an outgoing attempt to peer P that is not yet accepted, and an incoming connection from P authenticates with P's token. Then:

- The call **dialled by the lower host id** survives.
- If X's id is lower, X answers P's incoming call with REFUSE 8, and P's dialler drops it without showing an error.
- If X's id is higher, X drops its own outgoing attempt (its dialler shows nothing) and handles P's call normally, prompt included.

Both sides reach the same answer from the stored ids, with no extra round trip. A user whose proposal lost and differed from the winner's gets REFUSE 2/1 if they try again while the winner's session is live.

### Reconnects

- Only the dialler redials, with the base Wi-Fi retry (1 s), sending the same `sessionId` with `flags.resume = 1`.
- On link loss the answerer ends its provider session but keeps a **resume record** for 30 s:
  - It is keyed by (authenticated peer id, sessionId, feature, provider side) and holds the grant used and the provider's budget reservation, as a retry does today.
  - A matching resume proposal within 30 s is accepted without a prompt.
  - Anything else, including the same sessionId from another peer, is a new proposal.
  - After 30 s the record and its reservation are released.
- END from either user stops the redial, and reason 1 puts the pair in the other side's `stoppedDevices`, so nobody redials into a session the other user closed.

### Consent

The dialler's user consents by pressing Start. The answerer's user is asked unless the authenticated peer holds an `always` grant for this (feature, provider side):

- **Allow once**: this sessionId and its resumes.
- **Always allow from <Name>**: stored in `grants`.
- **Decline**: REFUSE 4.

Grants are keyed only on the peer id that the token proved, never on an id or sessionId the dialler chose.

**Prompt safety.** A controller must not be able to approve its own request.

- The prompt window is excluded from capture: on macOS, `NSWindow.sharingType = .none` plus an `SCContentFilter` that excepts the app's prompt windows; on Windows, `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`. Whether SCK honours `sharingType` must be checked on the device.
- The prompt is placed on a physical display, never a virtual one, so a tablet extending onto its own virtual display cannot reach it.
- The prompt's buttons ignore input the app itself injected: on macOS, an event whose `kCGEventSourceUnixProcessID` is the app's own pid; on Windows, input marked through `SendInput`'s `dwExtraInfo` tag. This also needs checking on the device.
- While any Remote Control session (tablet or desktop) controls this computer, new desktop proposals are refused at once with REFUSE 2/2 and not shown.

**Hidden app.** The Mac app often runs hidden at login, so a request also raises a user notification (macOS `UNUserNotificationCenter`; Windows toast) and a badge on the menu-bar/tray item. Clicking either brings up the prompt window. Without notification permission the request still waits the 60 s in the window, and Settings shows a hint.

**Visibility.**

- While this desktop provides to a peer, the menu-bar/tray item shows "Sharing with <Name>" with Stop (which sends END 1).
- Automatic refusals (permission, capacity, incoming off) raise a notice on the answerer ("Refused <Name>: Accessibility not granted") with *Open Settings*.

## Settings ownership

| Setting | Owner | Stored |
|---|---|---|
| preset, codec, fps, display mode | provider | provider's `SettingsService`, per peer key `peer:<idHex>` (as today's per-device settings) |
| last proposal (feature, provider side) | dialler | `SessionChoice` per peer; the default selection on Home |
| grants, *Accept incoming sessions* | answerer | peer record; settings |
| announced mode, codec, rate (`0xF9`/`0xFC`/`0xFB`) | viewer | **session state only** on a desktop. A desktop viewer must not write them into its global `SettingsService` (client :576, :621), where they would overwrite its own provider settings. Mobiles keep today's writes. |
| window placement, scaling, input mapping | viewer | per peer |

A viewer states what it can decode in `caps`. The provider picks a codec within those caps and, if none fits, refuses with 6/4.

## UI on each desktop

Every string is a translation key in both `en` and `th`.

**Mac Home**

- Today's tablet sections stay as they are. A new **Computers** section lists paired peers, online or offline from discovery.
- Each peer row has verb buttons, enabled from its `caps`. A disabled button shows the reason as a tooltip.
  - *Extend onto it*: Mac provides, needs M2.
  - *Let it control this Mac*: Mac provides, needs M2.
  - *View its screen* / *Control it*: Windows provides, needs M4.
- A live session's card shows a role chip ("Sharing with <Name>" / "Viewing <Name>") and Disconnect, which sends END 1.

**Mac, answering**: the prompt, notification, menu-bar badge and sharing indicator described under Consent.

**Mac Settings → Computers**:

- *Pair a computer*, which shows the SAS.
- The list of paired computers, each with Forget and *Revoke "Always"*.
- *Accept incoming sessions*.
- The per-peer provider settings.

**Windows Home (M1)**

- A **Macs** list of paired peers with *Use as extra screen* and *Control this Mac*.
- While a proposal is outstanding, its card shows "Waiting for <Name> to allow…" with the PENDING countdown and Cancel.
- A refusal shows its translated reason and hint.
- A *Pair a computer* button opens the SAS flow.
- The `esp1:` paste field exists in debug builds only.

**Windows, later (M2+)**: the same Computers section as the Mac, plus its own prompt, toast, tray indicator and *Accept incoming sessions*.

## Hub and code changes

### M0–M2: the Mac side, with no refactor

- **`WifiListener`** takes a credential set (the identity token plus every `acceptToken`) and reports which credential matched. In debug builds it also accepts `0xE8` as the first packet while a pairing window is open.
- **`HostConnectionManager._onPeer`** applies the admission matrix:
  - It keys a desktop session `wifi:<peerIdHex>` from the matched token, not from the `installId` claim.
  - It stores the panel only under that key.
  - It holds the grants, resume records and tie-break.
- **`HostSession`:**
  - It ports `helloPlatformWindows` and the `0x02..0x05` parse from branch `windows`, adds `0x06`, and keeps desktop panels out of `lastClientPanel`.
  - It gains phase `awaitingApproval`, appended to `ConnectionPhase` with a label and colour.
  - Before any capture it decides:
    - permission check (`hostGranted`) → reason 1;
    - `budget.wouldFit` → reason 7;
    - busy → reason 2;
    - incoming off → reason 9.
  - On accept it runs today's `_startCapture`, and `_sendSessionMode` follows the accepted feature.
  - `notAndroid` becomes `canProvideTo(peer, feature)`, a capability rule.
  - `effectiveRemoteDirection`'s "Wi-Fi forces tabControlsMac" stays for mobiles. Desktops never use `macControlsTab`.
- **`PeerProtocol`** (`lib/shared/protocol/peer_protocol.dart`) is a pure codec for `0xA2`, `0xE0`–`0xE9`, the discovery `0xD1` tail and payload v2.
- **`PeerPairingService`** (pure state machine + I/O) implements the SAS exchange, `storeConfirmedPairing`, forget/UNPAIR and the `desktop_peers` store.
- **`ClientConnectionManager` on Windows:**
  - sends `dialToken` in `0xF5` and the `0xA2` tail;
  - stays `configuring` until ACCEPT or a legacy `0xF9`;
  - handles `0xE2`/`0xE3`/`0xE4`;
  - keeps the announced mode and codec in session fields when `wifiOnlyClient && runsOnWindows`;
  - redials with `resume`.
- **M2:**
  - A Mac **outgoing provider session**: a `HostSession` that dials, built with its own `SocketService` as the hub already does per session. It uses the ACCEPT panel where it would use HELLO's.
  - On Windows, the listener and discovery responder, Windows' own identity (Dart certificate, `COMPUTERNAME` as the display name), and the crossed-call rule on both sides.

### M3: the refactor, after a shippable M1/M2, mechanical and test-led

1. Extract **`LinkSession`** from `HostSession`/`ClientConnectionManager`. It holds the per-session state machine: phase, attempts, `_recovering`, retry, heartbeat, `peerTrusted`, and its own `SocketService`. No behaviour change.
2. Move `HostSession`'s media half into **`ProviderPipeline`** over platform ports: `CaptureSource`, `VideoEncoder`, `DisplayMaker` (CGVirtualDisplay / IddCx), `InputSink`, `PermissionGate`, `EncoderEstimate` (`forChip`; Windows a conservative fallback), `HostNameSource` (scutil / `COMPUTERNAME`), and `SendBufferSignal` (`SO_NWRITE`; on Windows the Dart queue only). `MacProvider` wraps today's code unchanged. Admission, `spec` and `panel` move with the media half.
3. Make `ClientConnectionManager`'s dial-and-decode core a multi-instance **`ViewerSession`** with its own `SocketService` and decoder id (as `RemoteVideoChannel` already keys by session). The mobile `ClientConnectionManager` becomes a one-session facade with the USB key and keep-alive.
4. The hub holds sessions of both roles. `InitialBinding` becomes "desktop = hub with both native sets; mobile = `ClientConnectionManager`". `isHost` is removed, and shared UI reads `session.role` and `DeviceCaps`.
5. Make `SocketService` and `UsbSessionService` injectable per hub/session, so two hubs can run in one test process.

The order inside `HostSession` must survive the move: the pipeline queue, `_exclusive`, budget admission and release, and the display-rebuild rounds. Each step lands on its own with the full test suite unchanged.

## The `windows` branch

**Keep:**

- the Media Foundation decoder plugin and `annexb.h`;
- `_MouseOverlay` (right-click, move-while-held, wheel);
- HELLO `0x05` and `ClientPlatform.windows`;
- `windows_app.dart` / `wifiOnlyClient` and Wi-Fi-only;
- `test/windows_client_test.dart` and the Windows HELLO test in `host_hub_test`;
- the usbmux/devicectl test skips on Windows;
- the CLAUDE.md "Windows client" section, to be updated.

**Change:**

- **Rebase onto a3de44d first.** Ten files overlap: CLAUDE.md, `initial_binding.dart`, `host_session.dart` (platform parse, `isApple`, which main uses in three places), `home_controller.dart`, `home_view.dart`, `settings_controller.dart`, `settings_view.dart`, `app_translations.dart`, `settings_service.dart` and `test/iphone_usb_test.dart`.
- `notAndroid` → the capability rule `canProvideTo`.
- The client sends `0xA2` with its proposal, keeps the announced state per session, and handles REFUSE/PENDING/END and the legacy implicit accept.
- The `esp1:` paste stays debug-only and is removed once SAS pairing ships (M1b). It must never reach a release build, because it shows the Mac's identity token.
- `InitialBinding`: Windows keeps registering the client in M1. From M2 it also registers the listener side, and from M3 the unified desktop hub.

## Milestones

| # | Content | Done when |
|---|---|---|
| **M0** | Rebase `windows` onto a3de44d and merge it. The Mac parses `0x05`, and reserves `0x06`, `0xE0`–`0xE9` and `0xD1` as named constants. `PeerProtocol` codec with tests. | `flutter test` passes on main with the branch merged. A `0x05` HELLO no longer writes the global panel. The codec round-trip and truncation tests pass. |
| **M1a** | Negotiation on debug pairing. Mac: admission matrix (debug rows), `awaitingApproval`, ACCEPT/REFUSE/PENDING/END, grants, the capture-excluded prompt with notification, refusal notices, sharing indicator. Windows: the `0xA2` proposal, PENDING/refusal UI, legacy implicit accept, per-session viewer state. | A debug Windows build proposes *Use as extra screen* and *Control this Mac*. The Mac prompts once, then streams, and *Always* skips the prompt next time. Every refusal reason shows translated on Windows. A tablet run shows no `0xE*` byte on the wire. |
| **M1b** | SAS pairing (`0xE8`/`0xE9`), per-peer tokens, the `desktop_peers` store, Windows' Dart certificate, the discovery `0xD1` tail, release rows of the matrix, resume records, END → `stoppedDevices`, forget/UNPAIR. **Ship the Windows viewer.** | Release builds on both sides pair by matching digits and then connect with no paste. A MITM proxy test yields mismatched digits. Forgetting on either side stops the other from dialling. A release Mac closes a shared-token `0x05` dial. |
| **M2** | Windows listens (listener, responder, firewall guidance). The Mac dials Windows as provider (*Extend onto it*, *Let it control this Mac*), with the panel taken from ACCEPT. Crossed-call rule. | From the Mac's Home, the user extends onto a Windows PC that never pressed anything beyond its approval. Simultaneous Start on both sides leaves exactly one session in both id orders. |
| **M3** | The refactor (LinkSession, ProviderPipeline/MacProvider, ViewerSession, unified hub, `isHost` removed, injectable services). | The whole existing suite passes unchanged at each step. Two hubs run in one test process over loopback. |
| **M4** | Windows provides Remote Control: WGC/Desktop Duplication capture, MF encode, SendInput, permission and secure-desktop handling, a Windows encoder estimate. The Mac views it through a `ViewerSession` in its native remote windows. | From the Mac, *Control it* shows and drives a Windows desktop. A UAC prompt on Windows is reported as refusal 1/3 or paused, never as a frozen picture. |
| **M5** | IddCx driver: Windows gains a display (Extended Screen with Windows as provider). Signing and installer. Refusal 3 live until the driver is present. | With the driver, the Mac extends onto a Windows virtual monitor; without it, the user sees "Install the display driver on <Name>". |
| **M6** | Hardening: tokens and keys in `flutter_secure_storage` (Keychain/DPAPI) with migration. Mac↔Mac (`0x06`). | Secrets no longer appear in the preferences file. Two Macs pair and extend. |

## Tests

- **Codec:** round trips for `0xA2`, every `0xE*` body and step, the `0xD1` tail and payload v2; unknown `ver`, unknown caps bits and truncated bodies; v1 parsers ignore the appended data.
- **Tablets see nothing new:** a `FakeTablet` (`0x02`) and an iOS HELLO (`0x03`/`0x04`) against the new hub, with a `_Tunnel` byte capture asserting that no `0xE*` byte ever appears and that `0xF9` still comes first. The existing suites pass unchanged.
- **Admission matrix:** every row, in debug and release. A peer token with HELLO `0x02` is dropped. The identity token with `0x05`+`0xA2` gets REFUSE 10 in release.
- **`FakeDesktopPeer`** (beside `FakeTablet`):
  - accept;
  - each refusal reason;
  - PENDING, then accept;
  - approval timeout (REFUSE 5) with heartbeats alive through 60 s (`testWidgets` fake clock);
  - `always` grant skips the prompt;
  - a grant does not carry to another peer or another feature.
- **Legacy:** a new Windows client against a Mac that opens with `0xF9` (implicit accept for a viewer proposal; `error_peer_update_other` otherwise).
- **Resume and END:** a resume within 30 s skips the prompt only for the same authenticated peer and sessionId. After 30 s the reservation is released. END 1 puts the pair in `stoppedDevices` and stops the redial.
- **Crossed dials:** both orderings × both id orders leave one session and no error card on the losing side.
- **SAS pairing** (wifi_link_test style, real TLS):
  - matching digits;
  - a MITM proxy with its own certificate gives different digits;
  - a reveal that does not match the commitment is refused;
  - no payload byte is sent before both confirms;
  - the window's expiry, single use and 3-try limit;
  - `0xE8` is refused when no window is open;
  - re-pairing replaces the record;
  - `storePairing` still refuses v2 and packet bytes.
- **Tokens:** the per-peer token names the peer; after forget it is rejected; the tablets' identity token still works.
- **Viewer state:** a desktop viewer's `0xF9`/`0xFC` leave `SettingsService` alone.
- **Budget:** viewer sessions never touch `EncodeBudget`; a desktop provider and a tablet share it.
- **Prompt safety:** a proposal during a live Remote Control session gets REFUSE 2/2 without a prompt.
- **Windows:** Dart certificate generation and the pinning round trip on the Windows TLS stack; the `DesktopPlatform` fallbacks.
- **M2:** dialler-as-provider with the panel from ACCEPT.

## Risks

- **People confirm digits without comparing them.** Both sides must confirm, the copy explains why, and the window allows only 3 tries.
- **A missed prompt on a hidden Mac.** Mitigated by the notification, the badge and PENDING on the dialler. Without notification permission the request can still time out unseen.
- **Prompt safety rests on platform behaviour still to be verified:** that `sharingType`/SCK exclusion and the injected-event checks behave as described. If they don't, the "refuse while controlled" rule is the backstop.
- **Plaintext secrets until M6.** A stolen `dialToken` together with an `always` grant gives silent access from the LAN. Mitigations: per-peer revocation, the sharing indicator, and M6.
- **New dependency** (`pointycastle`/`basic_utils`) for the Windows certificate. Pin the versions and test against the Windows TLS stack.
- **Windows firewall prompt** on inbound TCP/UDP 7001 from M2. **Windows sleep** while "always listening". **UAC secure desktop** blocks capture and input (M4). **HEVC** needs the Store extension. No `SO_NWRITE`, so the bitrate adapter is weaker there.
- **The M3 refactor** touches about 2000 lines of `HostSession` ordering invariants. It is kept mechanical, one step per change, with the suite unchanged.
- **IddCx driver signing** (EV certificate, attestation) on the M5 path.
- **Reset Wi-Fi pairing** re-pairs every tablet and computer, because one certificate serves both.
- **Merge conflicts** between `windows` and main's ongoing hub work. Rebase early (M0).

## Open questions for the owner

1. **Should one desktop pair be able to run two sessions at once** (say, the Mac extends onto Windows while Windows controls the Mac)?
   *Recommended:* no. One session per desktop pair, matching "one mode per device at a time". Switching feature is END 4 plus a new proposal on the same link.
2. **Can "Always allow" be granted for Remote Control, or only for Extended Screen?**
   *Recommended:* allow it for both, revocable in Settings. The sharing indicator and the refusal notices make an always-grant visible.
3. **Should the Mac's Wi-Fi listener run all the time, also when Home's link selector says USB?**
   *Recommended:* yes for desktop peers (peer tokens are always admitted). Tablets' Wi-Fi admission keeps following the link selector as today.
4. **How should Windows make its certificate:** pure Dart (`pointycastle`/`basic_utils`) or PowerShell `New-SelfSignedCertificate`/CNG?
   *Recommended:* pure Dart ECDSA P-256. It is testable on any host, needs no shell-out, and pinning is algorithm-agnostic.
5. **Should secret storage move to `flutter_secure_storage` before shipping the Windows viewer (M1b) rather than in M6?**
   *Recommended:* keep M6 for both platforms together, with a migration. Moving only Windows early splits the storage code, and the Mac's Keychain prompts for ad-hoc-signed debug builds need their own handling.

## Owner's answers (2026-11-26)

1. One session per desktop pair (recommended). Switching feature is END then a new proposal on the same link.
2. "Always allow" may be granted for both Extended Screen and Remote Control (recommended), revocable in Settings, with the sharing indicator always shown.
3. **Not the recommendation:** the Mac's listener for desktop peers follows Home's link selector, like the tablets. A Windows peer can dial in only while the Mac listens on Wi-Fi. M1a/M1b must make that visible on Windows (a refusal or "the Mac is not listening" hint), and the Mac's Home should say that Wi-Fi listening is what lets a paired PC in.
4. Windows makes its certificate in pure Dart (ECDSA P-256), the recommended answer, not asked separately.
5. Secrets move to Keychain/DPAPI in M6 for both platforms together (recommended).
