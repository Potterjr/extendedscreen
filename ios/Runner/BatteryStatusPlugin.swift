import Flutter
import UIKit

/// `extended_screen/battery` on iOS, the counterpart of BatteryStatusPlugin.kt:
///   getStatus → {isCharging: Bool, level: Int (0-100, or -1 if unknown)}
/// `isCharging` is true while charging or full on power, as on Android.
/// Battery monitoring is switched on at registration: without it iOS reports
/// the state as unknown and the level as -1. `BatteryChannel` polls this
/// every 10 s, and `HomeController.batteryStatus` finds it unguarded, so the
/// channel has to answer on iOS too. Main thread.
final class BatteryStatusPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let channel = FlutterMethodChannel(
      name: "extended_screen/battery", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BatteryStatusPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      let device = UIDevice.current
      let level = device.batteryLevel
      result([
        "isCharging": device.batteryState == .charging || device.batteryState == .full,
        "level": level < 0 ? -1 : Int((level * 100).rounded()),
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
