import XCTest
import Network

/// A UI test that never ends (the Mac's remote control of an iPhone over USB). It listens on TCP 8100 on the iPhone's
/// loopback only (the Mac reaches it through usbmuxd, whose connections
/// arrive there; nothing on the LAN can) and turns one-line commands into
/// touches anywhere on the screen, one answer line per command line, in the
/// order the commands came:
///   tap <nx> <ny>               (waits for XCTest to report: ~250 ms)
///   atap <nx> <ny>              (returns at once; the touch lands ~100 ms later)
///   swipe <nx1> <ny1> <nx2> <ny2> <seconds> [<hold>]
///   aswipe <nx1> <ny1> <nx2> <ny2> <seconds> [<hold>]   (the same, at once;
///                               from a point to itself it is a press held
///                               that long; <hold> holds at the start first)
///   home                        (presses the Home button: the Home Screen)
///   orient                      (`orient <raw> <app|springboard|device>`;
///                               release 1 adds `pid=<n> <ms>`)
///   ping                        (`pong <w>x<h> fast=<bool>`)
///   quit
/// Release 1 adds:
///   caps                        (the verbs and options this runner has)
///   seg <nx1> <ny1> <nx2> <ny2> <seconds> <settle> <lead>
///                               (one segment of a live drag: down <lead>
///                               points back along the segment, through to
///                               the end over <seconds>, still for <settle>,
///                               lift; answered `done <ms>` once XCTest has
///                               played it, `late <ms>` if it never says)
///   switcher | spotlight | control | notifications
///                               (the system edge gestures, in the frame of
///                               the screen's current interface orientation;
///                               answered once played: `ok <ms> o=<raw>`)
///   pdown|pmove|pup <nx> <ny>, scroll <nx> <ny> <dx> <dy>, key <name> <mods>,
///   pastetest                   (experimental, the plan's spikes E1 to E3)
/// Coordinates are normalized to the screen in portrait (0...1); seconds
/// are 0...5. Without fast synthesis atap/aswipe do what tap/swipe do (and
/// answer once the touch is done). Anything else is `err <line>`.
///
/// Lines are read and parsed on the serial `runner.net` queue; only the
/// XCTest/XCUI work goes to the main thread, one command at a time in the
/// order received (`MainChain`), and the answers go back in that order
/// (`Replies`), so a blocking verb (`home`) does not hold up the parse of
/// the next line, and an answer never overtakes an earlier one.
final class TouchRunner: XCTestCase {
    func testServe() throws {
        // An experimental verb that trips an XCUI failure must not end the
        // test that serves every other touch.
        continueAfterFailure = true
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let size = springboard.frame.size
        var running = true

        let fast = FastTouch.available()
        NSLog("TouchRunner fast touches: %@, record with display ID: %@",
              fast ? "yes" : "no", FastTouch.recordTakesDisplayID() ? "yes" : "no")

        let net = DispatchQueue(label: "runner.net", qos: .userInteractive)
        let chain = MainChain(net: net)

        /// The verbs and options this runner answers `caps` with.
        let caps = ([
            "caps", "ping", "quit", "tap", "atap", "swipe", "aswipe", "home",
            "orient", "seg", "switcher", "spotlight", "control", "notifications",
            "release=1", "orient=iface", "seg=done", "fast=\(fast)",
            "exp=pdown,pmove,pup,scroll,key,pastetest",
        ]).joined(separator: " ")

        // Main thread only, as everything XCTest is.
        var lastFinger: CGPoint?

        func pt(_ nx: Double, _ ny: Double) -> CGPoint {
            CGPoint(x: nx * size.width, y: ny * size.height)
        }

        func point(_ nx: Double, _ ny: Double) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: nx * size.width, dy: ny * size.height))
        }

        func ms(_ t0: Date) -> String {
            String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000)
        }

        /// The completion of a touch handed over without waiting: logged as
        /// `synth done <ms since the command came>` (or why not).
        func logDone(_ verb: String, _ t0: Date) -> FastTouchDone {
            { ok, error in
                if ok {
                    NSLog("TouchRunner synth done %@ %@", ms(t0), verb)
                } else {
                    NSLog("TouchRunner synth failed %@ %@: %@", ms(t0), verb,
                          error?.localizedDescription ?? "?")
                }
            }
        }

        /// Whether a fast touch that failed may be done again the slow way:
        /// only when the synthesizer never got it (code 1). After a refusal
        /// or a late report it may have landed, and a second one would be a
        /// double tap or a second swipe.
        func untouched(_ error: Error) -> Bool {
            let e = error as NSError
            return e.domain == "FastTouch" && e.code == 1
        }

        func slowTap(_ nx: Double, _ ny: Double) {
            point(nx, ny).tap()
        }

        func slowSwipe(_ n: [Double], hold: Double, endHold: Double = 0) {
            point(n[0], n[1]).press(forDuration: max(hold, 0.05),
                thenDragTo: point(n[2], n[3]),
                withVelocity: .default, thenHoldForDuration: endHold)
        }

        /// The interface orientation the screen is in now (a raw value that
        /// names the same turn as UIDeviceOrientation's), where it was read
        /// and the process it was read from: the frontmost app other than
        /// SpringBoard (which is active beside it and reports portrait on an
        /// iPhone), else SpringBoard, or, when neither can be read, the
        /// phone's physical orientation (pid 0).
        func orientation() -> (raw: Int, source: String, pid: Int32) {
            let board = FastTouch.processID(of: springboard)
            var pid: Int32 = 0
            let app = FastTouch.activeInterfaceOrientation(&pid, excludingPID: board)
            if app != 0 { return (app, "app", pid) }
            let o = FastTouch.interfaceOrientation(of: springboard)
            if o != 0 { return (o, "springboard", board) }
            return (XCUIDevice.shared.orientation.rawValue, "device", 0)
        }

        /// (u, v), normalized in the frame the user sees in interface
        /// orientation [o], as normalized portrait (the runner's frame).
        func portrait(_ u: Double, _ v: Double, _ o: Int) -> (Double, Double) {
            switch o {
            case 2: return (1 - u, 1 - v)  // upside down
            case 3: return (1 - v, u)      // the portrait top on the left
            case 4: return (v, 1 - u)      // ...on the right
            default: return (u, v)
            }
        }

        /// A system edge gesture from (u1, v1) to (u2, v2), given in the
        /// current interface orientation's frame, played to its end.
        func edge(_ u1: Double, _ v1: Double, _ u2: Double, _ v2: Double,
                  seconds: Double, endHold: Double, t0: Date,
                  reply: @escaping (String) -> Void) {
            let o = orientation().raw
            let a = portrait(u1, v1, o), b = portrait(u2, v2, o)
            if fast {
                FastTouch.swipeAsync(from: pt(a.0, a.1), to: pt(b.0, b.1),
                                     duration: seconds, hold: 0, endHold: endHold) {
                    ok, error in
                    reply(ok ? "ok \(ms(t0)) o=\(o)"
                             : "err \(error?.localizedDescription ?? "refused")")
                }
                return
            }
            slowSwipe([a.0, a.1, b.0, b.1], hold: 0.05, endHold: endHold)
            reply("ok \(ms(t0)) o=\(o)")
        }

        /// The keys `key` takes by name.
        let keys: [String: String] = {
            var k: [String: String] = [
                "return": XCUIKeyboardKey.return.rawValue,
                "delete": XCUIKeyboardKey.delete.rawValue,
                "tab": XCUIKeyboardKey.tab.rawValue,
                "escape": XCUIKeyboardKey.escape.rawValue,
                "space": XCUIKeyboardKey.space.rawValue,
                "up": XCUIKeyboardKey.upArrow.rawValue,
                "down": XCUIKeyboardKey.downArrow.rawValue,
                "left": XCUIKeyboardKey.leftArrow.rawValue,
                "right": XCUIKeyboardKey.rightArrow.rawValue,
            ]
            for c in "abcdefghijklmnopqrstuvwxyz0123456789" { k[String(c)] = String(c) }
            return k
        }()

        /// Where a key goes: the frontmost app, else SpringBoard.
        func keyTarget() -> XCUIApplication {
            var pid: Int32 = 0
            if FastTouch.activeInterfaceOrientation(
                   &pid, excludingPID: FastTouch.processID(of: springboard)) != 0, pid > 0,
               let app = FastTouch.application(withPID: pid) as? XCUIApplication {
                return app
            }
            return springboard
        }

        /// One command line, parsed (on `runner.net`) into what to do.
        func parse(_ line: String, _ t0: Date) -> Work {
            let p = line.split(separator: " ").map(String.init)
            // `key <name> <mods>` is the one verb with a word argument.
            if p.first == "key" {
                guard p.count == 3, let key = keys[p[1]], let mods = UInt(p[2]),
                      mods < 64 else { return .now("err \(line)") }
                return .onMain {
                    keyTarget().typeKey(key, modifierFlags:
                        XCUIElement.KeyModifierFlags(rawValue: mods))
                    return "ok \(ms(t0))"
                }
            }
            let n = p.dropFirst().compactMap(Double.init)
            // Every number given must be one, and finite.
            guard n.count == p.count - 1, n.allSatisfy(\.isFinite) else {
                return .now("err \(line)")
            }
            func unit(_ range: Range<Int>) -> Bool {
                n[range].allSatisfy { (0...1).contains($0) }
            }
            switch p.first {
            case "ping":
                return .now("pong \(Int(size.width))x\(Int(size.height)) fast=\(fast)")
            case "caps" where n.isEmpty:
                return .now("caps \(caps)")
            case "orient" where n.isEmpty:
                return .onMain {
                    // How long the accessibility read itself took: a slow
                    // one holds up the touches queued behind it.
                    let t1 = Date()
                    let o = orientation()
                    return "orient \(o.raw) \(o.source) pid=\(o.pid) \(ms(t1))"
                }
            case "home" where n.isEmpty:
                return .onMain {
                    XCUIDevice.shared.press(.home)
                    return "ok \(ms(t0))"
                }
            case "tap", "atap":
                guard n.count == 2, unit(0..<2) else { return .now("err \(line)") }
                return .onMain {
                    if fast && p[0] == "atap" {
                        FastTouch.tap(atAsync: pt(n[0], n[1]), hold: 0.01,
                                      completion: logDone("atap", t0))
                        return "sent \(ms(t0))"
                    }
                    if fast {
                        do {
                            try FastTouch.tap(at: pt(n[0], n[1]))
                            return "ok fast \(ms(t0))"
                        } catch {
                            if !untouched(error) { return "err \(error.localizedDescription)" }
                        }
                    }
                    slowTap(n[0], n[1])
                    return "ok \(ms(t0))"
                }
            case "swipe", "aswipe":
                guard n.count == 5 || n.count == 6, unit(0..<4),
                      (0...5).contains(n[4]),
                      n.count == 5 || (0...5).contains(n[5]) else {
                    return .now("err \(line)")
                }
                let hold = n.count == 6 ? n[5] : 0
                return .onMain {
                    if fast && p[0] == "aswipe" {
                        FastTouch.swipeAsync(from: pt(n[0], n[1]), to: pt(n[2], n[3]),
                                             duration: n[4], hold: hold, endHold: 0,
                                             completion: logDone("aswipe", t0))
                        return "sent \(ms(t0))"
                    }
                    if fast {
                        do {
                            try FastTouch.swipe(from: pt(n[0], n[1]), to: pt(n[2], n[3]),
                                                duration: n[4], hold: hold, endHold: 0)
                            return "ok fast \(ms(t0))"
                        } catch {
                            if !untouched(error) { return "err \(error.localizedDescription)" }
                        }
                    }
                    slowSwipe(n, hold: hold)
                    return "ok \(ms(t0))"
                }
            case "seg":
                guard n.count == 7, unit(0..<4), (0.02...5).contains(n[4]),
                      (0...1).contains(n[5]), (0...50).contains(n[6]) else {
                    return .now("err \(line)")
                }
                let (dur, settle, lead) = (n[4], n[5], n[6])
                return .whenDone(deadline: dur + settle + 3) { reply in
                    let from = pt(n[0], n[1]), to = pt(n[2], n[3])
                    // Down [lead] points back along the segment, so the
                    // scroll view's own slop is used up before the segment
                    // proper: the content moves as far as the mouse did.
                    var start = from
                    let dx = to.x - from.x, dy = to.y - from.y
                    let len = (dx * dx + dy * dy).squareRoot()
                    if len > 0 && lead > 0 {
                        start = CGPoint(
                            x: min(max(from.x - dx / len * lead, 0), size.width),
                            y: min(max(from.y - dy / len * lead, 0), size.height))
                    }
                    if fast {
                        FastTouch.swipeAsync(from: start, to: to, duration: dur,
                                             hold: 0, endHold: settle) { ok, error in
                            NSLog("TouchRunner synth %@ %@ seg", ok ? "done" : "failed", ms(t0))
                            reply(ok ? "done \(ms(t0))"
                                     : "err \(error?.localizedDescription ?? "refused")")
                        }
                        return
                    }
                    slowSwipe([Double(start.x / size.width), Double(start.y / size.height),
                               n[2], n[3]], hold: 0.05, endHold: settle)
                    reply("done \(ms(t0))")
                }
            case "switcher" where n.isEmpty:
                // Up from the bottom edge, then still before the lift, so
                // the switcher opens instead of going Home.
                return .whenDone(deadline: 5) { reply in
                    edge(0.5, 0.999, 0.5, 0.6, seconds: 0.35, endHold: 0.3,
                         t0: t0, reply: reply)
                }
            case "spotlight" where n.isEmpty:
                return .whenDone(deadline: 6) { reply in
                    XCUIDevice.shared.press(.home)
                    edge(0.5, 0.35, 0.5, 0.6, seconds: 0.25, endHold: 0,
                         t0: t0, reply: reply)
                }
            case "control" where n.isEmpty:
                return .whenDone(deadline: 5) { reply in
                    edge(0.95, 0.001, 0.95, 0.5, seconds: 0.3, endHold: 0,
                         t0: t0, reply: reply)
                }
            case "notifications" where n.isEmpty:
                return .whenDone(deadline: 5) { reply in
                    edge(0.25, 0.001, 0.25, 0.6, seconds: 0.3, endHold: 0,
                         t0: t0, reply: reply)
                }
            case "pdown", "pmove", "pup":
                guard n.count == 2, unit(0..<2) else { return .now("err \(line)") }
                guard fast else { return .now("err no fast synthesis") }
                return .onMain {
                    let at = pt(n[0], n[1])
                    switch p[0] {
                    case "pdown":
                        FastTouch.fingerDown(at: at, completion: logDone("pdown", t0))
                        lastFinger = at
                    case "pmove":
                        FastTouch.finger(from: lastFinger ?? at, moveTo: at,
                                         completion: logDone("pmove", t0))
                        lastFinger = at
                    default:
                        // A record cannot lift a finger it did not put down:
                        // this is a new touch, lifted at once.
                        FastTouch.tap(atAsync: at, hold: 0, completion: logDone("pup", t0))
                        lastFinger = nil
                    }
                    return "sent \(ms(t0))"
                }
            case "scroll":
                guard n.count == 4, unit(0..<2),
                      n[2...3].allSatisfy({ abs($0) <= 2000 }) else {
                    return .now("err \(line)")
                }
                guard fast else { return .now("err no fast synthesis") }
                return .onMain {
                    do {
                        try FastTouch.scroll(at: pt(n[0], n[1]), dx: n[2], dy: n[3],
                                             completion: logDone("scroll", t0))
                        return "sent \(ms(t0))"
                    } catch {
                        return "err \(error.localizedDescription)"
                    }
                }
            case "pastetest" where n.isEmpty:
                return .onMain {
                    keyTarget().typeKey("v", modifierFlags: .command)
                    return "ok \(ms(t0))"
                }
            case "quit" where n.isEmpty:
                return .onMain {
                    running = false
                    return "bye"
                }
            default:
                return .now("err \(line)")
            }
        }

        // Loopback only: usbmuxd's forwarded connections arrive there, and
        // nothing else needs to reach this port (it takes anyone's touches).
        // No Nagle: every answer is one short line the Mac is waiting for.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: 8100)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("TouchRunner listening on 8100 (loopback), screen %@",
                      NSCoder.string(for: size))
            case .failed(let error):
                // Port taken (another runner, WebDriverAgent), say: end the
                // test instead of claiming to serve.
                NSLog("TouchRunner cannot listen on 8100: %@", "\(error)")
                DispatchQueue.main.async {
                    XCTFail("listener failed: \(error)")
                    running = false
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { conn in
            conn.stateUpdateHandler = { state in
                if case .failed = state { conn.cancel() }
            }
            conn.start(queue: net)
            let replies = Replies(conn)
            // TCP keeps no message boundaries: a command can come split over
            // two reads, so only whole lines are handled and the rest waits.
            var pending = Data()
            func readLine() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                    data, _, done, error in
                    if let data { pending.append(data) }
                    while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let bytes = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        let t0 = Date()
                        let slot = replies.slot()
                        guard let text = String(data: bytes, encoding: .utf8) else {
                            replies.fill(slot, "err undecodable")
                            continue
                        }
                        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        switch parse(line, t0) {
                        case .now(let reply):
                            replies.fill(slot, reply)
                        case .onMain(let work):
                            chain.run {
                                let reply = work()
                                net.async { replies.fill(slot, reply) }
                            }
                        case .whenDone(let deadline, let work):
                            let once = Once { reply in
                                net.async { replies.fill(slot, reply) }
                            }
                            chain.run {
                                // The deadline counts from when the work
                                // reaches main, not from the parse: a
                                // blocking `home` or a slow `orient` ahead
                                // of it would use it up, and a `late` for a
                                // record not yet handed over lets the Mac
                                // send the next one on top of it.
                                let waited = Date().timeIntervalSince(t0)
                                if waited > 0.05 {
                                    NSLog("TouchRunner %@ waited %.0fms in the chain",
                                          line, waited * 1000)
                                }
                                net.asyncAfter(deadline: .now() + deadline) {
                                    if once.fire("late \(ms(t0))") {
                                        NSLog("TouchRunner no completion in time: %@", line)
                                    }
                                }
                                work { _ = once.fire($0) }
                            }
                        }
                    }
                    // No command is this long: whatever sends it is not the Mac.
                    if pending.count > 4096 { conn.cancel(); return }
                    if done || error != nil { conn.cancel(); return }
                    readLine()
                }
            }
            readLine()
        }
        listener.start(queue: net)
        while running {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        listener.cancel()
    }
}

/// What a command line asks for.
enum Work {
    /// An answer known at once, from `runner.net` (nothing of XCTest).
    case now(String)
    /// Work on the main thread, whose result is the answer.
    case onMain(() -> String)
    /// Work on the main thread that answers later, through the closure it is
    /// given (from any thread, once); `late <ms>` after [deadline] seconds
    /// without one.
    case whenDone(deadline: Double, (@escaping (String) -> Void) -> Void)
}

/// The main thread's commands, one at a time in the order they came: the
/// next is handed to main only once the last has returned there, so a
/// command never runs inside another one's wait (XCTest's waits spin the
/// main run loop, which would run any block queued behind them).
final class MainChain {
    private let net: DispatchQueue
    private var queue: [() -> Void] = []
    private var busy = false

    init(net: DispatchQueue) { self.net = net }

    /// Called on `runner.net`.
    func run(_ work: @escaping () -> Void) {
        queue.append(work)
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let work = queue.removeFirst()
        DispatchQueue.main.async {
            work()
            self.net.async {
                self.busy = false
                self.next()
            }
        }
    }
}

/// One connection's answers, sent in the order their commands came (only
/// touched on `runner.net`).
final class Replies {
    private let conn: NWConnection
    private var issued = 0
    private var sent = 0
    private var ready: [Int: String] = [:]

    init(_ conn: NWConnection) { self.conn = conn }

    func slot() -> Int {
        defer { issued += 1 }
        return issued
    }

    func fill(_ slot: Int, _ reply: String) {
        ready[slot] = reply
        while let next = ready.removeValue(forKey: sent) {
            conn.send(content: (next + "\n").data(using: .utf8),
                      completion: .contentProcessed { _ in })
            sent += 1
        }
    }
}

/// An answer given at most once, from whichever thread comes first.
final class Once {
    private let lock = NSLock()
    private var done = false
    private let action: (String) -> Void

    init(_ action: @escaping (String) -> Void) { self.action = action }

    /// True when this call gave the answer.
    @discardableResult
    func fire(_ reply: String) -> Bool {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { action(reply) }
        return first
    }
}
