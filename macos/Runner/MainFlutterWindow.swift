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

    super.awakeFromNib()
  }
}
