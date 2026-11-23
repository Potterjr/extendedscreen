import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';

/// What a tablet's session is asked to be: its mode and, for remote control,
/// which side drives. It is the choice as picked, before the link has its
/// say: [effective] gives what a session on a given link really runs.
class SessionChoice {
  const SessionChoice(this.mode,
      [this.direction = RemoteDirection.tabControlsMac]);

  final SessionMode mode;

  /// Which side drives a remote-control session. An Extended-screen choice
  /// carries one too (the saved one), which changes nothing it does.
  final RemoteDirection direction;

  /// Every choice a picker offers, in its order.
  static const all = [
    SessionChoice(SessionMode.extendedScreen),
    SessionChoice(SessionMode.remoteControl, RemoteDirection.tabControlsMac),
    SessionChoice(SessionMode.remoteControl, RemoteDirection.macControlsTab),
  ];

  /// The tablet streams to the Mac, which views and drives it.
  bool get isReverse =>
      mode == SessionMode.remoteControl && direction.isReverse;

  /// The Mac captures and encodes for the tablet: every choice but
  /// [isReverse].
  bool get encodesOnMac => !isReverse;

  /// The choice a session on [link] runs. Mac-controls-tablet injects its
  /// input with adb, which needs the cable and an Android tablet, so over
  /// Wi-Fi, or for a device that is not Android ([android] false: an iPhone
  /// or iPad), the tablet drives the Mac, whatever the mode.
  SessionChoice effective({required LinkType link, bool android = true}) =>
      link == LinkType.wifi || !android
          ? SessionChoice(mode, RemoteDirection.tabControlsMac)
          : this;

  /// Whether a session made with [other] would do what one made with this
  /// does. The direction means nothing to an Extended screen.
  bool sameEffect(SessionChoice other) =>
      mode == other.mode &&
      (mode == SessionMode.extendedScreen || direction == other.direction);

  /// The mode's name, with the direction's for remote control. Resolved
  /// against the active locale at read time, like the labels it is made of.
  String get label => mode == SessionMode.remoteControl
      ? '${mode.label} · ${direction.label}'
      : mode.label;

  /// A choice from the enum names it is stored under. An unknown mode is no
  /// choice; an unknown or missing direction is the default one.
  static SessionChoice? fromNames(Object? mode, Object? direction) {
    for (final m in SessionMode.values) {
      if (m.name != mode) continue;
      for (final d in RemoteDirection.values) {
        if (d.name == direction) return SessionChoice(m, d);
      }
      return SessionChoice(m);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SessionChoice &&
      other.mode == mode &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(mode, direction);

  @override
  String toString() => 'SessionChoice(${mode.name}, ${direction.name})';
}
