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
            // Answered once adb is done, so the caller's await orders the
            // removal before anything that follows it: a reconnect's own
            // `adb reverse` must not be undone by this one landing late, or
            // the new attempt waits for a tablet with no tunnel to dial
            // (and its session key would rest on a port adb no longer
            // holds). The timeout keeps a hung adb from stalling teardown.
            adbRun(args: ["-s", serial, "reverse", "--remove-all"],
                   timeout: 5) { _, _ in result(nil) }
        case "shellInput":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String,
                  let inputArgs = args["args"] as? [String] else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            // Reverse remote: inject input on the tablet via `adb shell input …`.
            // Fire-and-forget so a dropped tap never stalls the control loop.
            adbRun(args: ["-s", serial, "shell", "input"] + inputArgs) { _, _ in }
            result(nil)
        case "shellScript":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String,
                  let script = args["script"] as? String,
                  let input = script.data(using: .utf8),
                  input.count <= AdbManagerPlugin.maxScriptBytes else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            // The script goes to the device's shell on stdin, not in adb's
            // arguments: it can carry the Wi-Fi pairing token, and every
            // process on this Mac can read another's arguments (`ps`). -T
            // means no terminal: the shell runs the lines and exits at EOF.
            adbRun(args: ["-s", serial, "shell", "-T"], stdin: input,
                   timeout: 20) { output, error in
                if let err = error {
                    result(FlutterError(code: "ADB_FAILED", message: err, details: nil))
                } else {
                    result(output ?? "")
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // Well inside a pipe's buffer (16 KB at least), which is what lets
    // adbRun write the whole script before adb has started.
    private static let maxScriptBytes = 8 * 1024

    // MARK: - ADB helpers

    private func listDevices(result: @escaping FlutterResult) {
        // Bounded: a wedged adb must not hold up the picker, a USB attempt's
        // detectingDevice step or the launch's auto-connect for ever (a
        // terminated adb answers as no devices).
        adbRun(args: ["devices", "-l"], timeout: 10) { output, error in
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

    // MARK: - Process runner

    /// `stdin` is written to adb's standard input. `timeout` (seconds) ends an
    /// adb that has not exited by then, e.g. one waiting on a device that
    /// went away mid-command.
    private func adbRun(args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil,
                        completion: @escaping (String?, String?) -> Void) {
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
                if let input = stdin {
                    // Written and closed before adb exists: the pipe holds it
                    // (the caller keeps it small), and this process still
                    // owns the reading end, so an adb that exits without
                    // reading can't turn the write into a SIGPIPE.
                    let pipe = Pipe()
                    try pipe.fileHandleForWriting.write(contentsOf: input)
                    try pipe.fileHandleForWriting.close()
                    proc.standardInput = pipe
                }
                try proc.run()
                if let limit = timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                        if proc.isRunning { proc.terminate() }
                    }
                }
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
