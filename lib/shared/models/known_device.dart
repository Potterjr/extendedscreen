/// A tablet the host has had a live USB session with, as `known_devices`
/// keeps it (see [SettingsService.knownDevices]).
class KnownDevice {
  const KnownDevice({
    required this.serial,
    this.model,
    required this.vdSerial,
    this.installId,
  });

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

  KnownDevice copyWith({String? model, int? vdSerial, String? installId}) =>
      KnownDevice(
        serial: serial,
        model: model ?? this.model,
        vdSerial: vdSerial ?? this.vdSerial,
        installId: installId ?? this.installId,
      );

  Map<String, dynamic> toJson() => {
        'serial': serial,
        if (model != null) 'model': model,
        'vdSerial': vdSerial,
        if (installId != null) 'installId': installId,
      };

  /// [toJson]'s output back, or null for anything else.
  static KnownDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final serial = json['serial'];
    final model = json['model'];
    final vdSerial = json['vdSerial'];
    final installId = json['installId'];
    if (serial is! String || serial.isEmpty || vdSerial is! int) return null;
    if (model != null && model is! String) return null;
    if (installId != null && installId is! String) return null;
    return KnownDevice(
      serial: serial,
      model: model as String?,
      vdSerial: vdSerial,
      installId: installId as String?,
    );
  }
}
