enum DeviceStatus { connected, disconnected, streaming, error }

/// The serial prefix of the in-process stand-in tablets (debug builds and
/// tests, `debug/synthetic_tablet.dart`). Nothing about them is persisted.
const syntheticSerialPrefix = 'synth-';

class DeviceModel {
  final String serial;
  final String? model;
  final String? product;
  final DeviceStatus status;

  /// adb's `transport_id` for this connection of the device (`adb devices
  /// -l`): a replug gives it a new one, and takes the device's reverse rules
  /// away. Null when adb did not say (or for a stand-in tablet).
  final String? transportId;

  const DeviceModel({
    required this.serial,
    this.model,
    this.product,
    this.transportId,
    required this.status,
  });

  /// An Android emulator, as adb names one. The host's auto-connect skips
  /// emulators while a physical tablet is attached.
  bool get isEmulator => serial.startsWith('emulator-');

  /// One of the in-process stand-in tablets (see [syntheticSerialPrefix]).
  bool get isSynthetic => serial.startsWith(syntheticSerialPrefix);

  // adb's name for a device it reaches by wireless debugging, found by mDNS:
  // `adb-<serial>-<id>._adb-tls-connect._tcp` (a trailing dot on some
  // versions).
  static final _mdnsName =
      RegExp(r'^adb-(.+)-[^-]*\._adb-tls-connect\._tcp\.?$');

  /// [devices] without the mDNS entry of a tablet that is also listed by its
  /// own serial: one with wireless debugging on is listed twice while it is
  /// plugged in, and both entries are the same tablet.
  static List<DeviceModel> withoutMdnsDuplicates(List<DeviceModel> devices) {
    final serials = devices.map((d) => d.serial).toSet();
    return devices.where((d) {
      final mdns = _mdnsName.firstMatch(d.serial);
      return mdns == null || !serials.contains(mdns.group(1));
    }).toList();
  }

  DeviceModel copyWith({
    String? serial,
    String? model,
    String? product,
    String? transportId,
    DeviceStatus? status,
  }) =>
      DeviceModel(
        serial: serial ?? this.serial,
        model: model ?? this.model,
        product: product ?? this.product,
        transportId: transportId ?? this.transportId,
        status: status ?? this.status,
      );
}
