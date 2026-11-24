import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The UIScene template's engine hook: Main.storyboard's
  /// ExtendedViewController makes the engine implicitly, and this runs once it
  /// exists. Register the app's own plugins here, beside the pub ones.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    let plugins: [(String, (FlutterPluginRegistrar) -> Void)] = [
      ("IosSystemPlugin", IosSystemPlugin.register),
      ("VideoDecoderPlugin", VideoDecoderPlugin.register),
      ("PairingInboxPlugin", PairingInboxPlugin.register),
      ("BatteryStatusPlugin", BatteryStatusPlugin.register),
    ]
    for (name, register) in plugins {
      if let registrar = registry.registrar(forPlugin: name) { register(registrar) }
    }
  }
}
