import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    ScreenCapturePlugin.register(with: messenger)
    InputInjectPlugin.register(with: messenger)
    AdbManagerPlugin.register(with: messenger)
    PermissionsPlugin.register(with: messenger)
    // Reverse-remote decoder needs a registrar for the texture registry.
    RemoteVideoPlugin.register(
      with: flutterViewController.registrar(forPlugin: "RemoteVideoPlugin"))

    // Start Dart now, with every plugin registered, instead of when the
    // window first appears (FlutterViewController launches the engine in
    // viewWillAppear). An app launched hidden (a login item set to hide,
    // `open -j`) has no window on screen, and then main() would not run at
    // all, so the host would not start listening until someone opened the
    // window. viewWillAppear skips an engine that is already running.
    if !flutterViewController.engine.run(withEntrypoint: nil) {
      NSLog("extendedscreen: the Flutter engine did not start")
    }

    super.awakeFromNib()
  }
}
