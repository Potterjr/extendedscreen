import 'package:get/get.dart';

/// What the user is doing this session — chosen from the launcher.
///
/// - [extendedScreen]: the tablet is a second monitor (Extend or Mirror, set in
///   Settings). The Mac captures a display and the tablet renders it.
/// - [remoteControl]: the tablet remote-controls the Mac's main desktop
///   (TeamViewer-style). Capture is forced to Mirror so the real desktop is
///   shown; touch on the tablet drives the Mac cursor.
///
/// The host announces the active mode to the client via a `0xF9` control packet
/// so both sides configure the right pipeline.
enum SessionMode { extendedScreen, remoteControl }

extension SessionModeX on SessionMode {
  // Localized strings resolve against the active GetX locale at read time.
  String get label => switch (this) {
        SessionMode.extendedScreen => 'session_extended_label'.tr,
        SessionMode.remoteControl => 'session_remote_label'.tr,
      };

  String get description => switch (this) {
        SessionMode.extendedScreen => 'session_extended_desc'.tr,
        SessionMode.remoteControl => 'session_remote_desc'.tr,
      };
}

/// Which side drives a [SessionMode.remoteControl] session — the user picks
/// this on the Remote Control screen.
///
/// - [tabControlsMac]: the Mac mirrors its desktop to the tablet and the tablet
///   drives the Mac (Phase 1; reuses the normal host-capture / client-decode
///   pipeline).
/// - [macControlsTab]: the tablet captures + encodes its own screen, the Mac
///   decodes + renders it and injects input back via `adb shell input`
///   (Phase 2 — the data flow is reversed relative to every other mode).
enum RemoteDirection { tabControlsMac, macControlsTab }

extension RemoteDirectionX on RemoteDirection {
  String get label => switch (this) {
        RemoteDirection.tabControlsMac => 'remote_dir_tab_label'.tr,
        RemoteDirection.macControlsTab => 'remote_dir_mac_label'.tr,
      };

  String get description => switch (this) {
        RemoteDirection.tabControlsMac => 'remote_dir_tab_desc'.tr,
        RemoteDirection.macControlsTab => 'remote_dir_mac_desc'.tr,
      };

  /// True when the tablet is the capture source and the Mac is the viewer —
  /// the only mode where the media pipeline runs Android→macOS.
  bool get isReverse => this == RemoteDirection.macControlsTab;
}
