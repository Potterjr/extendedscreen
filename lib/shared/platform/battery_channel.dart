import 'dart:async';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class BatteryStatus {
  final bool isCharging;
  final int level; // 0-100, or -1 if unknown

  const BatteryStatus({required this.isCharging, required this.level});
}

/// Client (Android) only — the tablet's own battery/charging state. USB-C
/// carries both the ADB data link and (hardware permitting) charging, but only
/// the OS knows whether power is actually flowing, so this polls it for the
/// app's lifetime and both Home and the in-stream HUD read [status].
class BatteryChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/battery');
  static const _pollInterval = Duration(seconds: 10);

  final status = Rxn<BatteryStatus>();
  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    _refresh();
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  Future<void> _refresh() async {
    try {
      final result = await _channel.invokeMethod<Map>('getStatus');
      if (result == null) return;
      status.value = BatteryStatus(
        isCharging: result['isCharging'] as bool? ?? false,
        level: result['level'] as int? ?? -1,
      );
    } catch (_) {}
  }
}
