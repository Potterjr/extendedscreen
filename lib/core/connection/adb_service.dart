import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../models/device_model.dart';
import '../services/logger_service.dart';

class AdbService extends GetxService {
  static const _channel = MethodChannel('extended_screen/adb');
  final _log = Get.find<LoggerService>();

  /// Returns list of connected ADB devices.
  Future<List<DeviceModel>> listDevices() async {
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('listDevices') ?? [];
      return result.map((d) {
        final map = Map<String, dynamic>.from(d as Map);
        return DeviceModel(
          serial: map['serial'] as String,
          model: map['model'] as String?,
          product: map['product'] as String?,
          status: DeviceStatus.connected,
        );
      }).toList();
    } catch (e, st) {
      _log.e('ADB listDevices failed', e, st);
      return [];
    }
  }

  /// Sets up reverse port forwarding: Android tcp:remotePort → Mac tcp:localPort.
  Future<bool> reverseForward({
    required String serial,
    required int localPort,
    required int remotePort,
  }) async {
    try {
      await _channel.invokeMethod('reverseForward', {
        'serial': serial,
        'localPort': localPort,
        'remotePort': remotePort,
      });
      _log.i('ADB reverse forward $remotePort → $localPort');
      return true;
    } catch (e, st) {
      _log.e('ADB reverseForward failed', e, st);
      return false;
    }
  }

  Future<void> removeForward({required String serial}) async {
    try {
      await _channel.invokeMethod('removeForward', {'serial': serial});
    } catch (_) {}
  }
}
