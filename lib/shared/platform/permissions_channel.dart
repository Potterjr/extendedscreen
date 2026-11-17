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

  /// What the macOS host needs before capture can start: Screen Recording
  /// and Accessibility (input injection).
  static const hostRequired = ['screen_recording', 'accessibility'];

  /// Whether every one of [hostRequired] is granted. False when they can't
  /// be read.
  Future<bool> hostGranted() async {
    final status = await checkPermissions();
    return hostRequired.every((key) => status[key] ?? false);
  }

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
