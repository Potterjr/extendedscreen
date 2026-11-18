import Cocoa
import FlutterMacOS
import os.log

// Public unified-log entries under the app's subsystem, like ScreenCapturePlugin's.
private let adbLog = OSLog(subsystem: "com.example.extendedscreen", category: "adb")

private func adbLogLine(_ message: String) {
    os_log("%{public}@", log: adbLog, type: .default, message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

class AdbManagerPlugin: NSObject {

    private static let channelName = "extended_screen/adb"

    // Calls back into Dart (onTabletScreenRestored).
    private var channel: FlutterMethodChannel?

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = AdbManagerPlugin()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        plugin.channel = ch
        ch.setMethodCallHandler(plugin.handle)
        // Quitting lets every held tablet screen go first (the device side
        // would light it anyway, once its lease runs out).
        NotificationCenter.default.addObserver(
            plugin, selector: #selector(releaseAllScreens),
            name: NSApplication.willTerminateNotification, object: nil)
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
        case "holdTabletScreenOff":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            holdScreenOff(serial: serial, result: result)
        case "releaseTabletScreenOff":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String else {
                result(nil); return
            }
            releaseScreenOff(serial: serial, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Tablet screen off (reverse remote)

    /// The tablet app's `ScreenPower` helper in `hold` mode, run from its own
    /// APK with the shell's privileges (see ScreenPower.kt). Nothing secret
    /// in it, so it can go in adb's arguments.
    private static let holdCommand =
        "CLASSPATH=$(pm path com.example.extendedscreen | head -n 1 | cut -d: -f2) " +
        "exec app_process / com.example.extendedscreen.tools.ScreenPower hold"

    /// How often the helper's lease is renewed. It lights the panel by itself
    /// 10 s after the last renewal: this Mac, or the cable, has gone away.
    private static let leaseRenewal: TimeInterval = 2

    /// One `adb shell … hold` per tablet whose panel is off. Main thread only.
    private final class ScreenHold {
        let process: Process
        let input: FileHandle
        var answer: FlutterResult?
        var renewal: DispatchSourceTimer?
        var released = false
        var output = ""

        init(process: Process, input: FileHandle, answer: @escaping FlutterResult) {
            self.process = process
            self.input = input
            self.answer = answer
        }

        func send(_ line: String) {
            try? input.write(contentsOf: Data((line + "\n").utf8))
        }

        /// The first answer only: true once the panel is off, an error otherwise.
        func reply(_ value: Any?) {
            answer?(value)
            answer = nil
        }
    }

    private var screenHolds: [String: ScreenHold] = [:]

    private static let releasedBeforeAnswer = FlutterError(
        code: "SCREEN_OFF_CANCELLED", message: "released before the tablet answered", details: nil)

    private func holdScreenOff(serial: String, result: @escaping FlutterResult) {
        if let hold = screenHolds[serial] {
            // Already held: off again. One still starting answers both calls
            // when it knows, not this one at once.
            hold.send("off")
            if let pending = hold.answer {
                hold.answer = { value in
                    pending(value)
                    result(value)
                }
            } else {
                result(true)
            }
            return
        }
        guard let adb = adbPath() else {
            result(FlutterError(code: "ADB_MISSING", message: "adb not found", details: nil))
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adb)
        proc.arguments = ["-s", serial, "shell", "-T", Self.holdCommand]
        let input = Pipe()
        let output = Pipe()
        // Renewals are written while adb runs, and adb can exit first: a write
        // to a pipe nobody reads must fail (EPIPE), not raise SIGPIPE and take
        // this app down with it.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = output
        let hold = ScreenHold(process: proc, input: input.fileHandleForWriting, answer: result)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.onHoldOutput(serial: serial, hold: hold, text: text) }
        }
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onHoldEnded(serial: serial, hold: hold) }
        }
        do {
            try proc.run()
        } catch {
            result(FlutterError(code: "SCREEN_OFF_FAILED", message: error.localizedDescription,
                                details: nil))
            return
        }
        screenHolds[serial] = hold
        // A helper that never answers (an old tablet build, a hung adb).
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard hold.answer != nil else { return }
            hold.reply(FlutterError(code: "SCREEN_OFF_FAILED", message: "no answer from the tablet",
                                    details: nil))
            if proc.isRunning { proc.terminate() }
        }
    }

    private func onHoldOutput(serial: String, hold: ScreenHold, text: String) {
        hold.output += text
        while let newline = hold.output.firstIndex(of: "\n") {
            let line = String(hold.output[..<newline]).trimmingCharacters(in: .whitespaces)
            hold.output = String(hold.output[hold.output.index(after: newline)...])
            adbLogLine("[ExtendedScreen] tablet screen: \(line)")
            if hold.answer != nil {
                if line.hasPrefix("ok off") {
                    hold.reply(true)
                    if !hold.released { startRenewing(hold) }
                } else if line.hasPrefix("error") {
                    hold.reply(FlutterError(code: "SCREEN_OFF_FAILED", message: line, details: nil))
                    if hold.process.isRunning { hold.process.terminate() }
                }
            }
        }
    }

    private func startRenewing(_ hold: ScreenHold) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.leaseRenewal, repeating: Self.leaseRenewal)
        timer.setEventHandler { [weak hold] in hold?.send("keep") }
        timer.resume()
        hold.renewal = timer
    }

    private func onHoldEnded(serial: String, hold: ScreenHold) {
        hold.renewal?.cancel()
        hold.renewal = nil
        if screenHolds[serial] === hold { screenHolds[serial] = nil }
        if hold.answer != nil {
            let said = hold.output.trimmingCharacters(in: .whitespacesAndNewlines)
            hold.reply(FlutterError(code: "SCREEN_OFF_FAILED",
                                    message: said.isEmpty ? "the tablet's helper ended" : said,
                                    details: nil))
        } else if !hold.released {
            // Lit again without being asked: the lease ran out, the cable came
            // out, the helper died. Dart's toggle must say so.
            channel?.invokeMethod("onTabletScreenRestored", arguments: serial)
        }
    }

    private func releaseScreenOff(serial: String, result: @escaping FlutterResult) {
        guard let hold = screenHolds[serial] else {
            result(nil)
            return
        }
        screenHolds[serial] = nil
        hold.released = true
        hold.renewal?.cancel()
        hold.renewal = nil
        // Still starting: it is over before it answered (the helper reads
        // `on` as soon as it is up, and lights the panel again).
        hold.reply(Self.releasedBeforeAnswer)
        hold.send("on")
        try? hold.input.close()
        let proc = hold.process
        // It answers "ok on" and ends; an adb that hangs is ended after 3 s
        // (the device's watchdog then lights the panel).
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline { usleep(50_000) }
            if proc.isRunning { proc.terminate() }
            DispatchQueue.main.async { result(nil) }
        }
    }

    @objc private func releaseAllScreens() {
        for (_, hold) in screenHolds {
            hold.released = true
            hold.renewal?.cancel()
            hold.reply(Self.releasedBeforeAnswer)
            hold.send("on")
            try? hold.input.close()
        }
        screenHolds.removeAll()
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
    private func adbPath() -> String? {
        let adbPaths = ["/usr/local/bin/adb", "/opt/homebrew/bin/adb",
                        "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"]
        return adbPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func adbRun(args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil,
                        completion: @escaping (String?, String?) -> Void) {
        guard let adb = adbPath() else {
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
