enum DeviceStatus { connected, disconnected, streaming, error }

class DeviceModel {
  final String serial;
  final String? model;
  final String? product;
  final DeviceStatus status;

  const DeviceModel({
    required this.serial,
    this.model,
    this.product,
    required this.status,
  });

  DeviceModel copyWith({
    String? serial,
    String? model,
    String? product,
    DeviceStatus? status,
  }) =>
      DeviceModel(
        serial: serial ?? this.serial,
        model: model ?? this.model,
        product: product ?? this.product,
        status: status ?? this.status,
      );
}
