import Cocoa
import FlutterMacOS
import ApplicationServices

class PermissionsPlugin {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "extended_screen/permissions",
                                       binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "checkPermissions":
        let screen = CGPreflightScreenCaptureAccess()
        let access = AXIsProcessTrusted()
        result(["screen_recording": screen, "accessibility": access])

      case "openPermission":
        guard let args = call.arguments as? [String: Any],
              let perm = args["permission"] as? String else {
          result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
          return
        }
        let urlStr: String
        switch perm {
        case "screen_recording":
          urlStr = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case "accessibility":
          urlStr = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        default:
          result(FlutterMethodNotImplemented)
          return
        }
        if let url = URL(string: urlStr) {
          NSWorkspace.shared.open(url)
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
