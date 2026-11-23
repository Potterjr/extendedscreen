import 'package:extendedscreen/shared/models/session_choice.dart';

/// A tablet the host has had a live USB session with, as `known_devices`
/// keeps it (see [SettingsService.knownDevices]).
class KnownDevice {
  const KnownDevice({
    required this.serial,
    this.model,
    required this.vdSerial,
    this.installId,
    this.choice,
  }) : _unread = const {};

  const KnownDevice._(this.serial, this.model, this.vdSerial, this.installId,
      this.choice, this._unread);

  /// Its adb serial, which is also its session key over USB.
  final String serial;

  /// Its model as `adb devices -l` reports it (`SM_X920`), if it did.
  final String? model;

  /// The serial number its virtual display is created with. macOS keeps a
  /// display's arrangement by vendor, product and serial number, so a tablet
  /// that keeps this keeps its place on the desktop. The tablet that was the
  /// last-used one before tablets were kept per device has 1, the value every
  /// virtual display had then.
  final int vdSerial;

  /// The tablet app's own id, once it reports one (not yet).
  final String? installId;

  /// The mode it is remembered in, as it was picked (not what the link made
  /// of it): the one its last live session ran in, or the one it was last
  /// asked to change to. The host's automatic connects use it again; the
  /// user's own pick takes the selectors' instead. Null until one is saved.
  final SessionChoice? choice;

  /// What [fromJson] found in the stored entry and this build could not
  /// read: keys it does not know, and a `mode` or `direction` whose value is
  /// not a name it knows. [toJson] writes them back as they came. Every
  /// save rewrites the whole list, so without this a build would drop what
  /// a later build keeps here, for every tablet, each time one goes live
  /// (as builds from before modes were remembered drop the modes).
  final Map<String, Object?> _unread;

  static const _mode = 'mode';
  static const _direction = 'direction';

  /// A null argument keeps the value it has. A [choice] also replaces a
  /// stored mode and direction this build could not read.
  KnownDevice copyWith({
    String? model,
    int? vdSerial,
    String? installId,
    SessionChoice? choice,
  }) =>
      KnownDevice._(
        serial,
        model ?? this.model,
        vdSerial ?? this.vdSerial,
        installId ?? this.installId,
        choice ?? this.choice,
        choice == null
            ? _unread
            : {
                for (final e in _unread.entries)
                  if (e.key != _mode && e.key != _direction) e.key: e.value,
              },
      );

  Map<String, dynamic> toJson() => {
        'serial': serial,
        if (model != null) 'model': model,
        'vdSerial': vdSerial,
        if (installId != null) 'installId': installId,
        if (choice != null) ...{
          _mode: choice!.mode.name,
          _direction: choice!.direction.name,
        },
        ..._unread,
      };

  /// [toJson]'s output back, or null for anything else. A mode this build
  /// can't read is no choice and never costs the entry, whose [vdSerial]
  /// has to survive.
  static KnownDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final serial = json['serial'];
    final model = json['model'];
    final vdSerial = json['vdSerial'];
    final installId = json['installId'];
    if (serial is! String || serial.isEmpty || vdSerial is! int) return null;
    if (model != null && model is! String) return null;
    if (installId != null && installId is! String) return null;
    final choice = SessionChoice.fromNames(json[_mode], json[_direction]);
    // What toJson writes for this entry by itself. Anything else the entry
    // holds is kept as it came.
    final written = {
      'serial': serial,
      'model': model,
      'vdSerial': vdSerial,
      'installId': installId,
      _mode: choice?.mode.name,
      _direction: choice?.direction.name,
    };
    final unread = <String, Object?>{
      for (final e in json.entries)
        if (e.key is String &&
            (!written.containsKey(e.key) || written[e.key] != e.value))
          e.key as String: e.value,
    };
    return KnownDevice._(serial, model as String?, vdSerial,
        installId as String?, choice, unread);
  }
}
