import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// What one tablet's session is: its mode, the direction a remote-control
/// session runs in and the display mode it captures, as they stood when its
/// connect attempt began. A session reads these instead of the live
/// settings, so a later change (made for another tablet, or by Home while
/// this one waits to retry) never reaches it halfway through; its next
/// attempt takes a new snapshot.
class SessionSpec {
  const SessionSpec({
    required this.link,
    required this.mode,
    required this.direction,
    required this.displayMode,
  });

  /// The settings as they stand, for a session on [link]. Over Wi-Fi the
  /// tablet always drives the Mac: Mac-controls-tablet injects its input
  /// with adb, which needs the cable.
  factory SessionSpec.of(SettingsService settings, LinkType link) {
    final mode = settings.sessionMode;
    return SessionSpec(
      link: link,
      mode: mode,
      direction: link == LinkType.wifi
          ? RemoteDirection.tabControlsMac
          : settings.remoteDirection,
      displayMode: mode == SessionMode.remoteControl
          ? DisplayMode.mirror
          : settings.displayMode,
    );
  }

  final LinkType link;
  final SessionMode mode;

  /// The effective direction (see [SessionSpec.of]).
  final RemoteDirection direction;

  /// What the Mac captures: remote-control sessions always mirror the real
  /// desktop.
  final DisplayMode displayMode;

  /// The tablet streams to the Mac (it captures, the Mac views and drives
  /// it). Every other session streams the Mac to the tablet.
  bool get isReverseRemote =>
      mode == SessionMode.remoteControl && direction.isReverse;
}
