import 'package:flutter/services.dart';

class PermissionInfo {
  final String key;
  final String label;
  final String description;
  bool granted;

  PermissionInfo({
    required this.key,
    required this.label,
    required this.description,
    this.granted = false,
  });
}

class PermissionsChannel {
  static const _channel = MethodChannel('extended_screen/permissions');

  Future<Map<String, bool>> checkPermissions() async {
    try {
      final result = await _channel.invokeMethod<Map>('checkPermissions');
      return result?.map((k, v) => MapEntry(k.toString(), v as bool)) ?? {};
    } catch (_) {
      return {};
    }
  }

  Future<void> openPermission(String permission) async {
    try {
      await _channel.invokeMethod('openPermission', {'permission': permission});
    } catch (_) {}
  }
}
