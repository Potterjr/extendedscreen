import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

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

  // ─── Input injection (reverse remote: Mac controls the tablet) ────────────
  // Runs `adb shell input …` on the device. Coordinates are device pixels.
  // Fire-and-forget: a dropped tap shouldn't stall the control loop.

  Future<void> inputTap({
    required String serial,
    required int x,
    required int y,
  }) =>
      _shellInput(serial, ['tap', '$x', '$y']);

  Future<void> inputSwipe({
    required String serial,
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    int durationMs = 50,
  }) =>
      _shellInput(serial, ['swipe', '$x1', '$y1', '$x2', '$y2', '$durationMs']);

  Future<void> inputKeyevent({required String serial, required int keycode}) =>
      _shellInput(serial, ['keyevent', '$keycode']);

  /// Types literal text on the device (spaces must be escaped as %s for `input`).
  Future<void> inputText({required String serial, required String text}) =>
      _shellInput(serial, ['text', text.replaceAll(' ', '%s')]);

  Future<void> _shellInput(String serial, List<String> args) async {
    try {
      await _channel.invokeMethod('shellInput', {
        'serial': serial,
        'args': args,
      });
    } catch (e) {
      _log.w('ADB input failed: $e');
    }
  }
}
