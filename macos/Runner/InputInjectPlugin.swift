import Cocoa
import FlutterMacOS
import CoreGraphics

class InputInjectPlugin: NSObject {

    private static let channelName = "extended_screen/input_inject"

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = InputInjectPlugin()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler(plugin.handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestAccessibility":
            let trusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            )
            result(trusted)
        case "injectMouse":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            injectMouse(args: args)
            result(nil)
        case "injectKey":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            injectKey(args: args)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Mouse

    private func injectMouse(args: [String: Any]) {
        guard let actionIdx = args["action"] as? Int,
              let buttonIdx = args["button"] as? Int,
              let nx = args["normalizedX"] as? Double,
              let ny = args["normalizedY"] as? Double,
              let dx = args["displayX"] as? Double,
              let dy = args["displayY"] as? Double,
              let dw = args["displayW"] as? Double,
              let dh = args["displayH"] as? Double else { return }

        let x = dx + nx * dw
        let y = dy + ny * dh
        let pt = CGPoint(x: x, y: y)
        let cgButton: CGMouseButton = buttonIdx == 2 ? .right : .left

        let eventType: CGEventType = switch (actionIdx, buttonIdx) {
            case (1, _): cgButton == .left ? .leftMouseDown  : .rightMouseDown
            case (2, _): cgButton == .left ? .leftMouseUp    : .rightMouseUp
            case (3, _): .scrollWheel
            default:     .mouseMoved
        }

        if eventType == .scrollWheel {
            let sdx = Int32((args["scrollDx"] as? Double ?? 0) * 10)
            let sdy = Int32((args["scrollDy"] as? Double ?? 0) * 10)
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 2, wheel1: sdy, wheel2: sdx, wheel3: 0)?.post(tap: .cghidEventTap)
        } else {
            CGEvent(mouseEventSource: nil, mouseType: eventType,
                    mouseCursorPosition: pt, mouseButton: cgButton)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard

    private func injectKey(args: [String: Any]) {
        guard let keycode  = args["keycode"]   as? Int,
              let mods     = args["modifiers"] as? Int,
              let isDown   = args["isDown"]    as? Bool else { return }

        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(keycode),
                                  keyDown: isDown) else { return }

        var flags = CGEventFlags()
        if mods & 0x01 != 0 { flags.insert(.maskCommand)   }
        if mods & 0x02 != 0 { flags.insert(.maskShift)     }
        if mods & 0x04 != 0 { flags.insert(.maskControl)   }
        if mods & 0x08 != 0 { flags.insert(.maskAlternate) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
