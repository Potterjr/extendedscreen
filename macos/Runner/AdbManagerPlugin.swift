import Cocoa
import FlutterMacOS

class AdbManagerPlugin: NSObject {

    private static let channelName = "extended_screen/adb"

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = AdbManagerPlugin()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler(plugin.handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "listDevices":
            listDevices(result: result)
        case "reverseForward":
            guard let args = call.arguments as? [String: Any],
                  let serial     = args["serial"]     as? String,
                  let localPort  = args["localPort"]  as? Int,
                  let remotePort = args["remotePort"] as? Int else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            reverseForward(serial: serial, localPort: localPort,
                           remotePort: remotePort, result: result)
        case "removeForward":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String else {
                result(nil); return
            }
            removeForward(serial: serial)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - ADB helpers

    private func listDevices(result: @escaping FlutterResult) {
        adbRun(args: ["devices", "-l"]) { output, error in
            guard error == nil, let out = output else {
                result([])
                return
            }
            let devices = out.components(separatedBy: "\n")
                .dropFirst() // header line
                .compactMap { line -> [String: String]? in
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 2, parts[1] == "device" else { return nil }
                    let serial  = String(parts[0])
                    let model   = parts.first(where: { $0.hasPrefix("model:") })
                                       .map { String($0.dropFirst(6)) }
                    let product = parts.first(where: { $0.hasPrefix("product:") })
                                       .map { String($0.dropFirst(8)) }
                    return ["serial": serial, "model": model ?? "", "product": product ?? ""]
                }
            result(devices)
        }
    }

    private func reverseForward(serial: String, localPort: Int, remotePort: Int,
                                 result: @escaping FlutterResult) {
        adbRun(args: ["-s", serial, "reverse",
                      "tcp:\(remotePort)", "tcp:\(localPort)"]) { _, error in
            if let err = error {
                result(FlutterError(code: "ADB_FAILED", message: err, details: nil))
            } else {
                result(nil)
            }
        }
    }

    private func removeForward(serial: String) {
        adbRun(args: ["-s", serial, "reverse", "--remove-all"]) { _, _ in }
    }

    // MARK: - Process runner

    private func adbRun(args: [String], completion: @escaping (String?, String?) -> Void) {
        let adbPaths = ["/usr/local/bin/adb", "/opt/homebrew/bin/adb",
                        "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"]
        guard let adb = adbPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            completion(nil, "adb not found in PATH")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: adb)
            proc.arguments = args
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError  = err
            do {
                try proc.run()
                proc.waitUntilExit()
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                DispatchQueue.main.async {
                    completion(stdout, proc.terminationStatus == 0 ? nil : stderr)
                }
            } catch {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
            }
        }
    }
}
