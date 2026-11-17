import 'dart:io';
import 'package:flutter/services.dart';

/// Keeps the Android client process at foreground priority while the extended-
/// screen link is up, via a `connectedDevice` foreground service. Without it the
/// OS freezes the cached process when the tablet is backgrounded and then kills
/// it under memory pressure ("Sync transaction while frozen"), dropping the
/// socket + decoder. No-op on non-Android platforms (the macOS host never needs
/// it). Calls are idempotent and never throw — failures are swallowed so a
/// rejected background start can't take down the connection.
class KeepAliveChannel {
  static const _channel = MethodChannel('extended_screen/keepalive');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// While [enabled], Android keeps Wi-Fi out of power saving (a low-latency
  /// Wi-Fi lock, honoured only while the app is in the foreground with the
  /// screen on). A dozing radio holds each arriving frame until it wakes, so
  /// a Wi-Fi stream's latency jumps by tens of milliseconds now and then.
  static Future<void> setLowLatencyWifi(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setLowLatencyWifi', {'enabled': enabled});
    } catch (_) {}
  }
}
