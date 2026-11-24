import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The iOS app's bundle id (ios/Runner.xcodeproj's PRODUCT_BUNDLE_IDENTIFIER).
/// The host names the iPhone app by it in devicectl calls. It is not the
/// Android applicationId (`com.example.extendedscreen`), which the adb
/// broadcasts target and which stays as it is.
const iosBundleId = 'com.porto.extendedscreen.ios';

/// This build is the iOS client (iPhone or iPad). Read through
/// [defaultTargetPlatform], so a test can play an iOS client with
/// `debugDefaultTargetPlatformOverride`; in a release build it is the real
/// platform. The Dart side of the iOS client branches on this alone.
bool get runsOnIos => defaultTargetPlatform == TargetPlatform.iOS;

/// How warm iOS says the device is (`ProcessInfo.thermalState`).
enum IosThermalState { nominal, fair, serious, critical, unknown }

/// `extended_screen/ios_system` (ios/Runner/ExtendedViewController.swift's
/// `IosSystemPlugin`). Every call is a no-op off iOS and never throws: a
/// failure answers false, or [IosThermalState.unknown].
class IosSystemChannel {
  static const _channel = MethodChannel('extended_screen/ios_system');

  /// Defers the system's edge gestures (and hides the home indicator) while
  /// [on], so a swipe at the Mac's Dock edge reaches the Mac. True when the
  /// root view controller took it.
  static Future<bool> setImmersive(bool on) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('setImmersive', on) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's page in the iOS Settings app (where Local Network
  /// access is switched on and off).
  static Future<bool> openAppSettings() async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// One public `os_log` line under the bundle id, category `measure` (the
  /// only way a release build's Dart side is heard: `LoggerService` prints
  /// in debug builds only). For the P0 link measurements (`ES_MEASURE`).
  static Future<void> log(String line) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('log', line);
    } catch (_) {}
  }

  static Future<IosThermalState> thermalState() async {
    if (!Platform.isIOS) return IosThermalState.unknown;
    try {
      final name = await _channel.invokeMethod<String>('thermalState');
      return IosThermalState.values.firstWhere(
        (s) => s.name == name,
        orElse: () => IosThermalState.unknown,
      );
    } catch (_) {
      return IosThermalState.unknown;
    }
  }
}
