import Flutter
import UIKit
import os

/// The root view controller (set as the class of Main.storyboard's Flutter
/// view controller). Flutter never defers the system's edge gestures, so
/// without this the first swipe at the bottom edge, where the Mac's Dock sits
/// on the extended display, would leave the app instead of reaching the Mac.
///
/// P0 spike: whether `preferredScreenEdgesDeferringSystemGestures` takes
/// effect for a FlutterViewController subclass under the UIScene template is
/// still to be proven on the device (design, verdict item 6).
class ExtendedViewController: FlutterViewController {
  /// True while /display shows the Mac's screen (DisplayController calls
  /// `setImmersive` on open and close). Only then are edge gestures deferred:
  /// on Home and Settings a swipe should leave the app as usual.
  var immersive = false {
    didSet {
      guard immersive != oldValue else { return }
      setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
      setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
  }

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
    immersive ? .all : []
  }

  override var prefersHomeIndicatorAutoHidden: Bool { true }

  override var prefersStatusBarHidden: Bool { true }
}

/// `extended_screen/ios_system`: the few things Dart needs from UIKit on iOS.
///   setImmersive(bool) → bool  defers edge gestures on the root view
///                              controller (false when it is not an
///                              ExtendedViewController)
///   openAppSettings    → bool  opens this app's page in Settings (the Local
///                              Network switch lives there)
///   thermalState       → String  nominal | fair | serious | critical
///   log(String)        → nil   one public os_log line, category `measure`
///                              (the P0 link measurements, `ES_MEASURE`;
///                              release builds print no Dart logs)
/// Dart wrapper: `IosSystemChannel` in lib/shared/platform/ios_app.dart.
class IosSystemPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  private static let measureLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.porto.extendedscreen.ios", category: "measure")

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "extended_screen/ios_system", binaryMessenger: registrar.messenger())
    let instance = IosSystemPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setImmersive":
      guard let on = call.arguments as? Bool else {
        result(FlutterError(code: "BAD_ARGS", message: "setImmersive takes a bool", details: nil))
        return
      }
      guard let controller = registrar?.viewController as? ExtendedViewController else {
        result(false)
        return
      }
      controller.immersive = on
      result(true)
    case "openAppSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    case "thermalState":
      result(Self.thermalStateName(ProcessInfo.processInfo.thermalState))
    case "log":
      if let line = call.arguments as? String {
        Self.measureLog.log("\(line, privacy: .public)")
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }
}
