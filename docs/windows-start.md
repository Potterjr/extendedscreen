# Starting the Windows side

How to pick up Windows work on a Windows machine. The Mac side carries on separately (the iPhone-over-USB latency work, `docs/roadmap.md` §4), so the two lines of work meet only through `main`.

## Read first

1. `CLAUDE.md`: the whole architecture. The Windows app is the same Flutter codebase with a third platform role.
2. `docs/roadmap.md`: the goal (every device a source or target), the status matrix, §3 (what Windows allows: IddCx, `SendInput`, Desktop Duplication / Windows.Graphics.Capture) and §5 (the structural work and its order).
3. `docs/ios-client-design.md`: how the last new client platform was added (the iOS spike). It is the closest template: a Wi-Fi client of today's protocol, a native decoder into a Flutter texture, a new HELLO platform byte, and a pairing path with no adb.
4. `docs/multi-tablet-design.md`: the hub, the sessions and the packet protocol on the Mac side.

## Machine setup

- Flutter stable (`.metadata` was made with `44a626f`; a newer stable is fine).
- Visual Studio 2022 with "Desktop development with C++"; `flutter doctor` must be clean for Windows.
- `flutter config --enable-windows-desktop`.
- Android platform-tools only if Android devices will be tested from Windows.

## Adding `windows/`

There is no `windows/` folder yet. Never run `flutter create` in the repo (it rewrites `.metadata` and adds template files). Make it in a scratch project and copy the folder in, as was done for `ios/`:

```
flutter create --platforms=windows --org com.example --project-name extendedscreen C:\tmp\es-scratch
xcopy /E /I C:\tmp\es-scratch\windows windows
```

Then add `windows/**` to `analysis_options.yaml`'s `exclude` (like `macos/**`), so `flutter analyze` keeps its 14 standing warnings.

## Known traps in today's code

- `InitialBinding` takes the host branch on `GetPlatform.isMacOS || GetPlatform.isDesktop`, so a Windows build registers the macOS channels (`ScreenCaptureChannel`, `InputInjectChannel`, `RemoteVideoChannel`, `AdbService`, `IosDeviceService`, `IosScreenChannel`, `IosTouchService`) and the hub; their first calls fail with `MissingPluginException`. Give Windows its own branch first.
- macOS-only assumptions: the Wi-Fi identity's certificate comes from `/usr/bin/openssl`, the Mac's name from `/usr/sbin/scutil`, `adb` is found at three fixed macOS paths (in Swift), `SocketService.limitSendBuffer` is macOS only, the iPhone USB path uses `/var/run/usbmuxd` (on Windows usbmuxd is Apple Mobile Device Service on TCP 27015).
- Tests: `wifi_link_test.dart` skips where `/usr/bin/openssl` is missing, and `display_codec_test.dart` fakes wakelock_plus's macOS channel; on Windows wakelock_plus registers another implementation and may need another fake. Run `flutter test` once on a clean checkout and note which failures are only platform ones before changing anything.
- HELLO's platform byte: the host knows `0x02` Android, `0x03` iPhone, `0x04` iPad, and treats anything else as Android (it becomes the global last panel). A Windows client should get a byte of its own (`0x05`), handled on the host like the iPhone's: its panel kept under its key only.
- Pairing: a tablet is paired through adb, an iPhone through devicectl, both from a Mac. A Windows client has neither, so it cannot be paired today. Roadmap §5.2 (a QR or numeric code exchange) is what fixes it; a debug-only way in (for example pasting the pairing payload) is acceptable for a spike if it is compiled out of release builds.

## Suggested first milestone

Roadmap §5 order: Windows as a viewer/controller first, then as a provider, then the Extended Screen source with its IddCx driver.

1. Windows as a Wi-Fi client of the Mac (Mac → Windows, the "Extended Screen" cell): a Windows branch in `InitialBinding` with `ClientConnectionManager`; a native decoder plugin (Media Foundation H.264/H.265 into a Flutter texture) speaking `VideoDecoderPlugin.kt`'s channel contract (`extended_screen/video_decoder` + `extended_screen/nal_feed`), as the iOS one does; mouse input from the pointer (a real mouse, so click, right-click and the wheel map directly); HELLO platform `0x05`; a pairing path.
2. Windows as a remote-control viewer of the Mac (same pipeline, Mirror).
3. Windows as a provider (capture + Media Foundation encode + `SendInput`), which needs roadmap §5.1 (roles apart from the OS).

## Rules that still hold

- The Android tablet app must not need an update: no wire change the tablet has to follow, nothing installed on the tablet.
- One mode per device at a time; different devices may use different modes at once.
- Ask before every commit; push once committed. No Claude `Co-Authored-By` line.
- `docs/` is tracked only for the design documents (this file, `roadmap.md`, `ios-client-design.md`, `multi-tablet-design.md`); plans, review output and backups stay untracked. Never commit `.vscode/settings.json`.
- Work on a branch of its own (`windows`), merged into `main` when a milestone is done. Files the Mac work also touches, so expect conflicts: `lib/app/bindings/initial_binding.dart`, `lib/shared/services/app_translations.dart`, `lib/shared/connection/host_session.dart`, `CLAUDE.md`, `README.md`, `docs/roadmap.md`.
