// The stand-in for AdbManagerPlugin around its input shell section, which
// run.sh puts in at the marked line. See run.sh.
import Foundation

typealias FlutterResult = (Any?) -> Void

struct FlutterError {
    init(code: String, message: String?, details: Any?) {}
}

let work = CommandLine.arguments[1]
let started = ProcessInfo.processInfo.systemUptime

// Main thread only, like the plugin.
var logLines: [String] = []

func adbLogLine(_ message: String) {
    logLines.append(message)
    let at = String(format: "%5.2f", ProcessInfo.processInfo.systemUptime - started)
    print("    \(at)  \(message)")
}

final class Plugin: NSObject {
    private func adbPath() -> String? { work + "/adb" }

    private func adbRun(args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil,
                        completion: @escaping (String?, String?) -> Void) {
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: work + "/adb")
            proc.arguments = args
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
                return
            }
            if let limit = timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                    if proc.isRunning { proc.terminate() }
                }
            }
            proc.waitUntilExit()
            DispatchQueue.main.async { completion("", nil) }
        }
    }

    //%INPUT_SHELL%

    func tap(_ serial: String, _ x: Int) {
        sendInput(serial: serial, line: InputLine(command: "tap", values: [x, 0])!) { _ in }
    }

    func swipe(_ serial: String, _ x: Int, ms: Int) {
        sendInput(serial: serial,
                  line: InputLine(command: "swipe", values: [x, 0, x, 0, ms])!) { _ in }
    }

    func close(_ serial: String) { closeInputShell(serial: serial) }
    func muted(_ serial: String) -> Bool { inputShellsMute.contains(serial) }
    func quit() { closeAllInputShells() }
}

let plugin = Plugin()
var failures: [String] = []
var passed = 0

/// Runs [body] on the main thread, where the plugin lives.
func onMain<T>(_ body: () -> T) -> T { DispatchQueue.main.sync(execute: body) }

func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

func check(_ what: String, _ holds: Bool) {
    onMain {
        if holds { passed += 1 } else { failures.append(what) }
        print("\(holds ? "  ok  " : "  FAIL") \(what)")
    }
}

func setCost(_ serial: String, _ seconds: Double) {
    try! "\(seconds)\n".write(toFile: "\(work)/cost.\(serial)", atomically: true, encoding: .utf8)
}

func lines(_ file: String) -> [String] {
    ((try? String(contentsOfFile: "\(work)/\(file)", encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
}

/// What landed on [serial], in order: "shell tap 1 0", "oneoff tap 2 0".
func landed(_ serial: String) -> [String] {
    lines("landed.log").filter { $0.hasPrefix(serial + " ") }
        .map { String($0.dropFirst(serial.count + 1)) }
}

/// The taps that landed on [serial], as their x, in the order they landed.
func order(_ serial: String) -> [Int] {
    landed(serial).compactMap { line -> Int? in
        let parts = line.split(separator: " ")
        return parts.count == 4 && parts[1] == "tap" ? Int(parts[2]) : nil
    }
}

/// The taps that landed on [serial], as their x, sorted.
func taps(_ serial: String) -> [Int] { order(serial).sorted() }

func shellsOpened(_ serial: String) -> Int { lines("shells.log").filter { $0 == serial }.count }

func logged(_ serial: String, _ text: String) -> Bool {
    onMain { logLines.contains { $0.contains("input shell \(serial): ") && $0.contains(text) } }
}

// A tablet whose shells answered, then one line that hangs on a new shell:
// that shell is ended, and the tablet keeps its shell path.
func answeredThenHung() {
    let s = "C"
    onMain { plugin.tap(s, 1) }
    wait(0.6)
    check("C: the first tap lands through the shell", landed(s) == ["shell tap 1 0"])
    onMain { plugin.close(s) }
    wait(0.2)
    onMain { plugin.tap(s, 999) }
    wait(5.6)
    check("C: a hung line on a later shell ends that shell", logged(s, "no answer"))
    check("C: a tablet that has answered is not put on the per-process path",
          !onMain { plugin.muted(s) })
    wait(2.0)
    onMain { plugin.tap(s, 3) }
    wait(0.8)
    check("C: after the 2 s wait the next tap opens a shell again",
          landed(s).contains("shell tap 3 0") && shellsOpened(s) == 3)
}

// A tablet whose very first line never answers: per-process for the run.
func neverAnswered() {
    let s = "B"
    onMain { plugin.tap(s, 999) }
    wait(5.6)
    check("B: a tablet that never answered goes per-process", onMain { plugin.muted(s) })
    onMain { plugin.tap(s, 4) }
    wait(0.8)
    check("B: its next tap is one adb process", landed(s) == ["oneoff tap 4 0"])
}

// A tablet whose `input` is slow from the first line: nothing is dropped
// or swapped, and it ends up on the per-process path. While its taps go
// one adb process each, none is written to the shell (it could land before
// them), so the shell's second slow line is the first tap after a pause.
func slowFromTheStart() {
    let s = "A"
    setCost(s, 0.6)
    for x in 1...8 {
        onMain { plugin.tap(s, x) }
        wait(0.25)
    }
    wait(2.2)
    check("A: 8 taps 0.25 s apart on a 0.6 s `input` all land, in the order asked (\(order(s)))",
          order(s) == Array(1...8))
    check("A: none was dropped", !logged(s, "dropped"))
    onMain { plugin.tap(s, 9) }
    wait(1.2)
    check("A: a slow `input` puts the tablet on the per-process path", onMain { plugin.muted(s) })
    onMain { plugin.tap(s, 10) }
    wait(1.2)
    check("A: its next tap is one adb process (\(landed(s).suffix(2)))",
          landed(s).suffix(2) == ["shell tap 9 0", "oneoff tap 10 0"])
}

// A quick tablet: a burst stays on the one shell, in order.
func quickBurst() {
    let s = "D"
    setCost(s, 0.01)
    onMain { for x in 1...10 { plugin.tap(s, x) } }
    wait(2.0)
    check("D: a burst of 10 lands in order through one shell",
          landed(s) == (1...10).map { "shell tap \($0) 0" } && shellsOpened(s) == 1)
    check("D: a quick tablet keeps its shell", !onMain { plugin.muted(s) })
}

// A tablet that answered quickly and is slow for a while: nothing is
// dropped and it keeps its shell.
func quickThenSlow() {
    let s = "E"
    onMain { plugin.tap(s, 1) }
    wait(0.5)
    setCost(s, 0.6)
    for x in 11...18 {
        onMain { plugin.tap(s, x) }
        wait(0.25)
    }
    wait(2.2)
    check("E: 8 taps during a slow spell all land, in the order asked (\(order(s)))",
          order(s) == [1] + Array(11...18))
    check("E: none was dropped", !logged(s, "dropped"))
    check("E: a tablet that has been quick is not put on the per-process path",
          !onMain { plugin.muted(s) })
    setCost(s, 0.02)
    onMain { plugin.tap(s, 20) }
    wait(0.6)
    check("E: once quick again its taps go through the shell",
          landed(s).contains("shell tap 20 0") && shellsOpened(s) == 1)
}

// A close with an event still waiting: the event is not lost.
func closedWithOneWaiting() {
    let s = "F"
    setCost(s, 0.3)
    onMain {
        plugin.tap(s, 1)
        plugin.tap(s, 2)
        plugin.close(s)
    }
    wait(1.5)
    check("F: a tap still waiting when its shell is closed lands, after the one " +
          "under way (\(order(s)))",
          order(s) == [1, 2])
}

// A tablet that has been quick, one line that takes long: a tap that comes
// while that line is already late does not wait behind it.
func tapBehindALateLine() {
    let s = "P"
    onMain { plugin.tap(s, 1) }
    wait(0.5)
    setCost(s, 1.6)
    onMain { plugin.tap(s, 2) }
    wait(0.5)
    onMain { plugin.tap(s, 3) }
    wait(2.6)
    check("P: a tap 0.5 s into a 1.6 s line lands (\(order(s)))", order(s) == [1, 2, 3])
    check("P: it went one adb process, at once", landed(s).last == "oneoff tap 3 0")
    check("P: none was dropped", !logged(s, "dropped"))
}

// A tablet that has been quick turns slow as a burst arrives: what waited
// behind the first slow line does not wait behind the next one too, and a
// tap that comes while those are on their way goes after them, not ahead
// of them through the shell.
func burstIntoASlowSpell() {
    let s = "Q"
    onMain { plugin.tap(s, 1) }
    wait(0.5)
    setCost(s, 0.6)
    onMain { for x in 2...5 { plugin.tap(s, x) } }
    wait(0.75)
    onMain { plugin.tap(s, 6) }
    wait(2.2)
    check("Q: a burst of 4 at the start of a slow spell and a tap behind it all land, " +
          "in the order asked (\(order(s)))", order(s) == Array(1...6))
    check("Q: none was dropped", !logged(s, "dropped"))
    check("Q: what waited behind the slow line, and the tap behind that, went one adb " +
          "process each",
          landed(s).suffix(4) == (3...6).map { "oneoff tap \($0) 0" })
}

// One slow first line (adb's own start-up, say) and a quick second one:
// the tablet keeps its shell.
func slowFirstLineOnly() {
    let s = "R"
    setCost(s, 0.6)
    onMain { plugin.tap(s, 1) }
    wait(1.0)
    setCost(s, 0.02)
    onMain { plugin.tap(s, 2) }
    wait(0.6)
    check("R: one slow first line does not put the tablet on the per-process path",
          !onMain { plugin.muted(s) })
    onMain { plugin.tap(s, 3) }
    wait(0.6)
    check("R: its taps keep going through the one shell (\(landed(s)))",
          landed(s) == (1...3).map { "shell tap \($0) 0" } && shellsOpened(s) == 1)
}

// A tablet on the per-process path: a burst in one turn still lands in the
// order asked, though each event is an adb process of its own.
func burstOnePerProcess() {
    let s = "H"
    onMain { plugin.tap(s, 999) }
    wait(5.6)
    setCost(s, 0.3)
    onMain { for x in 1...4 { plugin.tap(s, x) } }
    wait(1.6)
    check("H: a burst on the per-process path lands in the order asked (\(landed(s)))",
          landed(s) == (1...4).map { "oneoff tap \($0) 0" })
}

// A long swipe is neither a hang nor a slow line.
func longSwipe() {
    let s = "G"
    onMain { plugin.swipe(s, 1, ms: 1500) }
    wait(2.2)
    onMain { plugin.tap(s, 2) }
    wait(0.6)
    check("G: a 1.5 s swipe and the tap after it go through the one shell",
          landed(s) == ["shell swipe 1 0 1 0 1500", "shell tap 2 0"] && shellsOpened(s) == 1)
    check("G: a swipe's own duration does not count as slow", !logged(s, "slow"))
}

let scenarios = [answeredThenHung, neverAnswered, slowFromTheStart, quickBurst, quickThenSlow,
                 closedWithOneWaiting, longSwipe, tapBehindALateLine, burstIntoASlowSpell,
                 slowFirstLineOnly, burstOnePerProcess]
let group = DispatchGroup()
for scenario in scenarios {
    group.enter()
    Thread.detachNewThread {
        scenario()
        group.leave()
    }
}
group.notify(queue: .main) {
    plugin.quit()
    print(failures.isEmpty
          ? "input shell: all \(passed) checks hold"
          : "input shell: \(failures.count) of \(passed + failures.count) checks FAILED")
    exit(failures.isEmpty ? 0 : 1)
}
dispatchMain()
