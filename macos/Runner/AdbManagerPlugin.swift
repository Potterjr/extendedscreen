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
        // would light it anyway, once its lease runs out), and ends every
        // input shell.
        NotificationCenter.default.addObserver(
            plugin, selector: #selector(releaseAllScreens),
            name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(
            plugin, selector: #selector(closeAllInputShells),
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
            // With the tablet-side port, only this app's rule goes; other
            // tools' rules on the tablet stay.
            let rule = (args["remotePort"] as? Int).map { ["--remove", "tcp:\($0)"] }
                ?? ["--remove-all"]
            adbRun(args: ["-s", serial, "reverse"] + rule,
                   timeout: 5) { _, _ in result(nil) }
        case "shellInput":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String,
                  let inputArgs = args["args"] as? [String] else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            // Reverse remote: inject input on the tablet via `adb shell input …`,
            // one adb process per event. Taps and swipes go through the
            // tablet's input shell instead (`inputShell`); this is what is
            // left for key events and text, and what a tap falls back to.
            // Fire-and-forget so a dropped tap never stalls the control loop.
            adbRun(args: ["-s", serial, "shell", "input"] + inputArgs, timeout: 10) { _, _ in }
            result(nil)
        case "inputShell":
            guard let args = call.arguments as? [String: Any],
                  let serial = args["serial"] as? String, !serial.isEmpty,
                  let command = args["command"] as? String,
                  let values = args["values"] as? [Int],
                  let line = InputLine(command: command, values: values) else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            sendInput(serial: serial, line: line, result: result)
        case "closeInputShell":
            if let args = call.arguments as? [String: Any],
               let serial = args["serial"] as? String {
                closeInputShell(serial: serial)
            }
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

    // MARK: - Input shell (reverse remote)

    /// One tap or swipe for a tablet, checked: nothing but these integers
    /// ever reaches a device's shell, whatever Dart sent.
    private struct InputLine {
        /// `input`'s arguments: `tap X Y` or `swipe X1 Y1 X2 Y2 MS`.
        let args: [String]
        /// How long the device takes over it by design (a swipe's duration).
        let duration: TimeInterval
        /// When it was asked for (system uptime).
        let asked: TimeInterval

        init?(command: String, values: [Int]) {
            let coordinate = 0...65535
            switch command {
            case "tap":
                guard values.count == 2, values.allSatisfy(coordinate.contains) else {
                    return nil
                }
                duration = 0
            case "swipe":
                guard values.count == 5, values.prefix(4).allSatisfy(coordinate.contains),
                      (1...2000).contains(values[4]) else {
                    return nil
                }
                duration = TimeInterval(values[4]) / 1000
            default:
                return nil
            }
            args = [command] + values.map(String.init)
            asked = ProcessInfo.processInfo.systemUptime
        }

        var text: String { args.joined(separator: " ") }
    }

    /// One `adb -s <serial> shell -T` with no command per tablet the Mac
    /// controls: the device's sh reads its lines from adb's stdin, so a tap
    /// costs one line, not a new adb process and a new shell each time.
    /// Every line ends in `; echo __es_<n>`, and the next one is written
    /// only once that marker has come back, so the lines run in order and
    /// one that hangs, or is slow, is seen. Main thread only.
    ///
    /// Events the shell does not take go one adb process each
    /// (`InputLane`), and while any of those is still on its way nothing
    /// is written to the shell: a line written then could land first.
    private final class InputShell {
        let serial: String
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let errors: FileHandle
        /// Asked for and not written yet, oldest first.
        var queue: [InputLine] = []
        /// Written, its marker not back yet; `written` is when (system
        /// uptime).
        var inFlight: (line: InputLine, marker: String, written: TimeInterval)?
        /// Lines written so far: the number in the next marker.
        var sent = 0
        /// Lines in a row whose marker came back late.
        var slowRun = 0
        /// Ended on purpose (`closeInputShell`, quitting).
        var closed = false
        /// Given up on: its entry is gone and its queue handed on.
        var over = false
        var buffer = ""

        init(serial: String, process: Process, input: FileHandle, output: FileHandle,
             errors: FileHandle) {
            self.serial = serial
            self.process = process
            self.input = input
            self.output = output
            self.errors = errors
        }
    }

    private var inputShells: [String: InputShell] = [:]

    /// One tablet's events that go one `adb shell input …` each: the
    /// fallback, and all there was before the shell. They are started in
    /// the order asked and never two at the same instant, since which of
    /// two adb processes started together reaches the tablet first is a
    /// race: the next one starts once every one before it has exited, or
    /// `inputOnceGap` after the last one was started, whichever is first
    /// (so behind a slow `input` they still run side by side, as they did
    /// when each was started as it was asked for). Main thread only.
    private final class InputLane {
        /// Not started yet, oldest first.
        var waiting: [InputLine] = []
        /// adb processes started for this tablet that have not exited.
        var running = 0
        /// When the newest of them was started (system uptime).
        var lastStart: TimeInterval = 0
        /// Nothing starts before this: a line the shell wrote just before
        /// handing on what waited behind it comes first.
        var notBefore: TimeInterval = 0
        /// A timer for the oldest waiting event is set.
        var timed = false

        var busy: Bool { running > 0 || !waiting.isEmpty }
    }

    private var inputLanes: [String: InputLane] = [:]

    /// Until when (system uptime) no new shell is opened for a serial whose
    /// last one ended without being asked, or could not be started.
    private var inputShellRetryAt: [String: TimeInterval] = [:]

    /// Tablets that get no shell for the rest of the run, their taps going
    /// one adb process each, as before: no shell of theirs ever sent a
    /// marker back, or their `input` is slow from the first line on.
    private var inputShellsMute: Set<String> = []

    /// Tablets a marker has come back from in this run: their sh does read
    /// its lines from adb's stdin and answer. Kept per tablet, not per
    /// shell, because every session's end closes the shell.
    private var inputShellsAnswered: Set<String> = []

    /// Tablets that have answered a line in good time in this run: a slow
    /// line of theirs is a slow moment, not a slow `input`.
    private var inputShellsQuick: Set<String> = []

    /// A line that has waited this long unsent is dropped: a tap that lands
    /// seconds late is worse than one that never lands.
    private static let inputMaxWait: TimeInterval = 1
    /// A marker not back this long after its line (plus the swipe's own
    /// duration) means the shell hangs.
    private static let inputAnswerLimit: TimeInterval = 5
    /// A marker not back this long after its line (plus the swipe's own
    /// duration) makes the line a slow one. A shell runs its lines one
    /// after the other, so behind a slow line events would wait where the
    /// one-process-per-event path ran them side by side: nothing waits
    /// behind a line once it is this late.
    private static let inputSlowAfter: TimeInterval = 0.4
    /// This many slow lines in a row, on a tablet that has never answered
    /// in good time, and its `input` is taken to be slow (one that starts a
    /// runtime for every call, as older Android versions do).
    private static let inputSlowLines = 2
    private static let inputReopenDelay: TimeInterval = 2
    private static let inputCloseGrace: TimeInterval = 1
    /// Two adb processes for one tablet's events are started at least this
    /// far apart while the first still runs (`InputLane`). Not measured on
    /// a tablet: as far apart as a quick double click.
    private static let inputOnceGap: TimeInterval = 0.1

    private func inputLane(_ serial: String) -> InputLane {
        if let lane = inputLanes[serial] { return lane }
        let lane = InputLane()
        inputLanes[serial] = lane
        return lane
    }

    /// The fallback, and the path before there was a shell: one
    /// `adb shell input …` per event, after the tablet's earlier ones
    /// (`InputLane`). Nothing waits for its result; a hung adb is ended
    /// after 10 s.
    private func inputOnce(serial: String, lines: [InputLine]) {
        guard !lines.isEmpty else { return }
        let lane = inputLane(serial)
        lane.waiting.append(contentsOf: lines)
        pumpInputLane(serial, lane)
    }

    /// Starts what waits in [lane], oldest first, as far as its rule lets
    /// it, and sets a timer for the rest.
    private func pumpInputLane(_ serial: String, _ lane: InputLane) {
        var stale = 0
        defer {
            if stale > 0 {
                adbLogLine("[ExtendedScreen] input shell \(serial): dropped \(stale) " +
                           "event(s) that waited over \(Int(Self.inputMaxWait)) s")
            }
        }
        while let line = lane.waiting.first {
            let now = ProcessInfo.processInfo.systemUptime
            if now - line.asked > Self.inputMaxWait {
                lane.waiting.removeFirst()
                stale += 1
                continue
            }
            var due = lane.notBefore
            if lane.running > 0 { due = max(due, lane.lastStart + Self.inputOnceGap) }
            if now < due {
                if !lane.timed {
                    lane.timed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + (due - now)) {
                        [weak self, weak lane] in
                        guard let lane = lane else { return }
                        lane.timed = false
                        self?.pumpInputLane(serial, lane)
                    }
                }
                return
            }
            lane.waiting.removeFirst()
            lane.running += 1
            lane.lastStart = now
            adbRun(args: ["-s", serial, "shell", "input"] + line.args, timeout: 10) {
                [weak self, weak lane] _, _ in
                guard let lane = lane else { return }
                lane.running -= 1
                self?.pumpInputLane(serial, lane)
            }
        }
    }

    private func sendInput(serial: String, line: InputLine, result: @escaping FlutterResult) {
        // Also while earlier events of this tablet are still going one adb
        // process each: a line written to the shell now could land before
        // them. The shell takes the next event that finds none on its way.
        if inputShellsMute.contains(serial) || inputLanes[serial]?.busy == true {
            if let shell = inputShells[serial] {
                // Nothing waits there while the lane is busy; said for the
                // order's sake.
                handOnQueue(shell, now: ProcessInfo.processInfo.systemUptime)
            }
            inputOnce(serial: serial, lines: [line])
            result(nil)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let shell = inputShells[serial] {
            if let flight = shell.inFlight,
               now - flight.written > Self.inputSlowAfter + flight.line.duration {
                // The line under way is late already. This event, and what
                // waits, would only get later behind it: they go one adb
                // process each, in the order asked.
                handOnQueue(shell, now: now)
                inputOnce(serial: serial, lines: [line])
            } else {
                shell.queue.append(line)
                pumpInput(shell)
            }
            result(nil)
            return
        }
        if let retryAt = inputShellRetryAt[serial], now < retryAt {
            inputOnce(serial: serial, lines: [line])
            result(nil)
            return
        }
        guard let adb = adbPath() else {
            result(FlutterError(code: "ADB_FAILED", message: "adb not found", details: nil))
            return
        }
        guard let shell = openInputShell(serial: serial, adb: adb) else {
            inputShellRetryAt[serial] = now + Self.inputReopenDelay
            inputOnce(serial: serial, lines: [line])
            result(nil)
            return
        }
        shell.queue.append(line)
        pumpInput(shell)
        result(nil)
    }

    private func openInputShell(serial: String, adb: String) -> InputShell? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adb)
        // No command: the device's sh reads its lines from stdin. -T: no
        // terminal, so nothing is echoed and no prompt is printed.
        proc.arguments = ["-s", serial, "shell", "-T"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        // adb can exit while a line is being written: that write must fail
        // (EPIPE), not raise SIGPIPE and take this app down with it.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = errors
        let shell = InputShell(serial: serial, process: proc,
                               input: input.fileHandleForWriting,
                               output: output.fileHandleForReading,
                               errors: errors.fileHandleForReading)
        shell.output.readabilityHandler = { [weak self, weak shell] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let shell = shell else { return }
                self?.onInputShellOutput(shell, text: text)
            }
        }
        shell.errors.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                adbLogLine("[ExtendedScreen] input shell \(serial): \(text)")
            }
        }
        proc.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                // The handler holds the shell, which holds the process.
                shell.process.terminationHandler = nil
                self?.onInputShellEnded(shell, status: status)
            }
        }
        do {
            try proc.run()
        } catch {
            shell.output.readabilityHandler = nil
            shell.errors.readabilityHandler = nil
            proc.terminationHandler = nil
            adbLogLine("[ExtendedScreen] input shell \(serial): not started: " +
                       error.localizedDescription)
            return nil
        }
        inputShells[serial] = shell
        adbLogLine("[ExtendedScreen] input shell \(serial): opened (pid \(proc.processIdentifier))")
        return shell
    }

    /// Writes the oldest line that is still worth sending, if none is under
    /// way.
    private func pumpInput(_ shell: InputShell) {
        guard !shell.over, !shell.closed else { return }
        // Also while a line is under way, so a shell that hangs keeps no
        // growing queue.
        let now = ProcessInfo.processInfo.systemUptime
        var stale = 0
        while let first = shell.queue.first, now - first.asked > Self.inputMaxWait {
            shell.queue.removeFirst()
            stale += 1
        }
        if stale > 0 {
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): dropped \(stale) " +
                       "event(s) that waited over \(Int(Self.inputMaxWait)) s")
        }
        guard shell.inFlight == nil, !shell.queue.isEmpty else { return }
        let line = shell.queue.removeFirst()
        let number = shell.sent + 1
        let marker = "__es_\(number)"
        do {
            try shell.input.write(contentsOf: Data("input \(line.text); echo \(marker)\n".utf8))
        } catch {
            // adb has gone, and its end has not been heard yet. This line
            // was never written, so it may still go another way.
            shell.queue.insert(line, at: 0)
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): write failed: " +
                       error.localizedDescription)
            giveUpInputShell(shell)
            return
        }
        shell.sent = number
        shell.inFlight = (line, marker, ProcessInfo.processInfo.systemUptime)
        let limit = Self.inputAnswerLimit + line.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self, weak shell] in
            guard let shell = shell, !shell.over, !shell.closed,
                  shell.sent == number, shell.inFlight != nil else { return }
            self?.onInputShellStuck(shell, line: line, waited: limit)
        }
    }

    private func onInputShellOutput(_ shell: InputShell, text: String) {
        shell.buffer += text
        while let newline = shell.buffer.firstIndex(of: "\n") {
            let line = String(shell.buffer[..<newline])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            shell.buffer = String(shell.buffer[shell.buffer.index(after: newline)...])
            if let flight = shell.inFlight, line == flight.marker {
                shell.inFlight = nil
                onInputLineAnswered(shell, line: flight.line, written: flight.written)
                // Nothing if the shell was just given up on.
                pumpInput(shell)
            } else if !line.isEmpty, !line.hasPrefix("__es_") {
                // What `input` itself said (an error, usually).
                adbLogLine("[ExtendedScreen] input \(shell.serial): \(line)")
            }
        }
    }

    /// A line's marker came back, `written` being when the line went out.
    /// Measures how long the tablet took over it, less a swipe's own
    /// duration: a slow line hands on what waited behind it, and a tablet
    /// that is slow from its first line on gets no shell any more.
    private func onInputLineAnswered(_ shell: InputShell, line: InputLine,
                                     written: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let took = max(0, now - written - line.duration)
        let ms = Int((took * 1000).rounded())
        inputShellsAnswered.insert(shell.serial)
        if shell.sent == 1 {
            // Every shell says how long its first line took, so the log
            // shows what a line costs on this tablet.
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): answers " +
                       "(\"\(line.text)\" took \(ms) ms)")
        }
        guard took > Self.inputSlowAfter else {
            shell.slowRun = 0
            inputShellsQuick.insert(shell.serial)
            return
        }
        shell.slowRun += 1
        adbLogLine("[ExtendedScreen] input shell \(shell.serial): slow, " +
                   "\"\(line.text)\" took \(ms) ms")
        if shell.slowRun >= Self.inputSlowLines, !inputShellsQuick.contains(shell.serial) {
            // Never a line in good time: on this tablet a shell only makes
            // quick events wait for each other. giveUpInputShell hands on
            // what waits.
            inputShellsMute.insert(shell.serial)
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): slow from its first " +
                       "line on: from now on this tablet's taps go one adb process each")
            giveUpInputShell(shell)
            return
        }
        // What waited behind a slow line does not wait behind the next one
        // too.
        handOnQueue(shell, now: now)
    }

    /// Sends what waits in [shell]'s queue one adb process each, in the
    /// order asked and after the line under way, and drops what has waited
    /// too long for that; the queue is empty afterwards.
    private func handOnQueue(_ shell: InputShell, now: TimeInterval) {
        guard !shell.queue.isEmpty else { return }
        let young = shell.queue.filter { now - $0.asked <= Self.inputMaxWait }
        if young.count < shell.queue.count {
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): dropped " +
                       "\(shell.queue.count - young.count) event(s) that waited over " +
                       "\(Int(Self.inputMaxWait)) s")
        }
        shell.queue.removeAll()
        if let flight = shell.inFlight {
            // A line written only just now (a close right behind a tap)
            // was asked for before these.
            let lane = inputLane(shell.serial)
            lane.notBefore = max(lane.notBefore, flight.written + Self.inputOnceGap)
        }
        inputOnce(serial: shell.serial, lines: young)
    }

    /// A line's marker never came back.
    private func onInputShellStuck(_ shell: InputShell, line: InputLine, waited: TimeInterval) {
        if inputShellsAnswered.contains(shell.serial) {
            // This tablet's shells do answer (this one, or one of an
            // earlier session): a hang, so this shell goes and the next
            // event after the wait opens another.
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): no answer to " +
                       "\"\(line.text)\" for \(waited) s, ending it")
        } else {
            // Not one marker from this tablet in this run: its shell does
            // not read stdin, or says nothing back. Opening another would
            // only lose the next tap the same way, so no shell for it again.
            inputShellsMute.insert(shell.serial)
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): never answered " +
                       "(\"\(line.text)\", \(waited) s): from now on this tablet's taps " +
                       "go one adb process each")
        }
        giveUpInputShell(shell)
    }

    /// The shell is no use any more without anybody having asked for its
    /// end: its entry goes, no new one is opened for a moment (an adb that
    /// is restarting, a cable that is out), and the events that are still
    /// young enough go one by one. The line under way is not sent again:
    /// it may have landed.
    private func giveUpInputShell(_ shell: InputShell) {
        guard !shell.over, !shell.closed else { return }
        shell.over = true
        if inputShells[shell.serial] === shell { inputShells[shell.serial] = nil }
        let now = ProcessInfo.processInfo.systemUptime
        inputShellRetryAt[shell.serial] = now + Self.inputReopenDelay
        if let flight = shell.inFlight {
            adbLogLine("[ExtendedScreen] input shell \(shell.serial): " +
                       "\"\(flight.line.text)\" may not have landed")
        }
        handOnQueue(shell, now: now)
        shell.inFlight = nil
        try? shell.input.close()
        if shell.process.isRunning { shell.process.terminate() }
    }

    private func onInputShellEnded(_ shell: InputShell, status: Int32) {
        shell.output.readabilityHandler = nil
        shell.errors.readabilityHandler = nil
        if shell.closed || shell.over { return }
        adbLogLine("[ExtendedScreen] input shell \(shell.serial): ended by itself " +
                   "(status \(status)); no new one for \(Int(Self.inputReopenDelay)) s")
        giveUpInputShell(shell)
    }

    /// The session that used [serial]'s shell is over. The entry goes at
    /// once, so the next session's first tap opens a fresh shell; the line
    /// under way still runs (the device's sh ends at the end of its input),
    /// and events still waiting go one adb process each, as at every other
    /// end of a shell: taps keep landing while a tablet reconnects.
    private func closeInputShell(serial: String) {
        guard let shell = inputShells.removeValue(forKey: serial) else { return }
        shell.closed = true
        if !shell.queue.isEmpty {
            adbLogLine("[ExtendedScreen] input shell \(serial): closed with " +
                       "\(shell.queue.count) event(s) waiting")
            handOnQueue(shell, now: ProcessInfo.processInfo.systemUptime)
        }
        try? shell.input.close()
        adbLogLine("[ExtendedScreen] input shell \(serial): closed")
        let proc = shell.process
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputCloseGrace) {
            if proc.isRunning { proc.terminate() }
        }
    }

    @objc private func closeAllInputShells() {
        for (_, shell) in inputShells {
            shell.closed = true
            shell.queue.removeAll()
            try? shell.input.close()
            if shell.process.isRunning { shell.process.terminate() }
        }
        inputShells.removeAll()
        for (_, lane) in inputLanes { lane.waiting.removeAll() }
    }

    // Well inside a pipe's buffer (16 KB at least), which is what lets
    // adbRun write the whole script before adb has started.
    private static let maxScriptBytes = 8 * 1024

    // MARK: - ADB helpers

    private func listDevices(result: @escaping FlutterResult) {
        // Bounded: a wedged adb must not hold up the picker, a USB attempt's
        // detectingDevice step or the launch's auto-connect for ever. A
        // terminated or failed adb answers an error, not an empty list: it
        // says nothing about which tablets are attached (Dart's
        // listDevicesOrNull gives null for it, listDevices no devices).
        adbRun(args: ["devices", "-l"], timeout: 10) { output, error in
            guard error == nil, let out = output else {
                result(FlutterError(code: "ADB_FAILED", message: error ?? "no output",
                                    details: nil))
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
                    // adb's id for this connection of the device: a new one
                    // after every replug, when the device's reverse rules
                    // are gone.
                    let transport = parts.first(where: { $0.hasPrefix("transport_id:") })
                                       .map { String($0.dropFirst(13)) }
                    return ["serial": serial, "model": model ?? "", "product": product ?? "",
                            "transport": transport ?? ""]
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
