import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
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

  /// The settings as they stand, for a session on [link]: the next session's
  /// choice ([SettingsService.nextChoice]) and the display mode, through
  /// [SessionSpec.from].
  ///
  /// A reading of the role a new device gets by default, nothing more: no session is built from
  /// it (a session's spec comes from its own choice, through
  /// [SessionSpec.from]), so a rule about what a session may run as belongs
  /// in [SessionChoice.effective], never here.
  factory SessionSpec.of(SettingsService settings, LinkType link) =>
      SessionSpec.from(settings.nextChoice, link,
          displayMode: settings.displayMode);

  /// What a session asked to be [choice] runs on [link]. Over Wi-Fi the
  /// tablet always drives the Mac ([SessionChoice.effective]):
  /// Mac-controls-tablet injects its input with adb, which needs the cable.
  /// A remote-control session mirrors the real desktop; any other captures in
  /// [displayMode].
  ///
  /// The link is all that is known when an attempt begins. A device that
  /// turns out not to be Android (an iPhone or iPad, known from its HELLO)
  /// can only drive the Mac too: the session takes its spec again after the
  /// HELLO with [android] false.
  factory SessionSpec.from(SessionChoice choice, LinkType link,
      {required DisplayMode displayMode, bool android = true}) {
    final effective = choice.effective(link: link, android: android);
    return SessionSpec(
      link: link,
      mode: effective.mode,
      direction: effective.direction,
      displayMode: effective.mode == SessionMode.remoteControl
          ? DisplayMode.mirror
          : displayMode,
    );
  }

  final LinkType link;
  final SessionMode mode;

  /// The effective direction (see [SessionSpec.from]).
  final RemoteDirection direction;

  /// What the Mac captures: remote-control sessions always mirror the real
  /// desktop.
  final DisplayMode displayMode;

  /// The tablet streams to the Mac (it captures, the Mac views and drives
  /// it). Every other session streams the Mac to the tablet.
  bool get isReverseRemote =>
      mode == SessionMode.remoteControl && direction.isReverse;
}
