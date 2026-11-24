import XCTest
import Network

/// A UI test that never ends (the Mac's remote control of an iPhone over USB). It listens on TCP 8100 on the iPhone's
/// loopback only (the Mac reaches it through usbmuxd, whose connections
/// arrive there; nothing on the LAN can) and turns one-line commands into
/// touches anywhere on the screen:
///   tap <nx> <ny>               (waits for XCTest to report: ~250 ms)
///   atap <nx> <ny>              (returns at once; the touch lands ~100 ms later)
///   swipe <nx1> <ny1> <nx2> <ny2> <seconds> [<hold>]
///   aswipe <nx1> <ny1> <nx2> <ny2> <seconds> [<hold>]   (the same, at once;
///                               from a point to itself it is a press held
///                               that long; <hold> holds at the start first)
///   home                        (presses the Home button: the Home Screen)
///   orient                      (`orient <UIDeviceOrientation raw value>`)
///   ping                        (`pong <w>x<h> fast=<bool>`)
///   quit
/// Coordinates are normalized to the screen in portrait (0...1); seconds
/// are 0...5. Without fast synthesis atap/aswipe do what tap/swipe do (and
/// answer once the touch is done).
final class TouchRunner: XCTestCase {
    func testServe() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let size = springboard.frame.size
        var running = true

        let fast = FastTouch.available()
        NSLog("TouchRunner fast touches: %@", fast ? "yes" : "no")

        func pt(_ nx: Double, _ ny: Double) -> CGPoint {
            CGPoint(x: nx * size.width, y: ny * size.height)
        }

        func point(_ nx: Double, _ ny: Double) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: nx * size.width, dy: ny * size.height))
        }

        func ms(_ t0: Date) -> String {
            String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000)
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

        func slowSwipe(_ n: [Double], hold: Double) {
            point(n[0], n[1]).press(forDuration: max(hold, 0.05),
                thenDragTo: point(n[2], n[3]),
                withVelocity: .default, thenHoldForDuration: 0)
        }

        func handle(_ line: String) -> String {
            let p = line.split(separator: " ").map(String.init)
            let n = p.dropFirst().compactMap(Double.init)
            // Every number given must be one, and finite.
            guard n.count == p.count - 1, n.allSatisfy(\.isFinite) else {
                return "err \(line)"
            }
            let t0 = Date()
            switch p.first {
            case "ping":
                return "pong \(Int(size.width))x\(Int(size.height)) fast=\(fast)"
            case "orient":
                return "orient \(XCUIDevice.shared.orientation.rawValue)"
            case "home" where n.isEmpty:
                XCUIDevice.shared.press(.home)
            case "tap", "atap":
                guard n.count == 2, n.allSatisfy({ (0...1).contains($0) }) else {
                    return "err \(line)"
                }
                if fast && p[0] == "atap" {
                    FastTouch.tap(atAsync: pt(n[0], n[1]), hold: 0.01)
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
            case "swipe", "aswipe":
                guard n.count == 5 || n.count == 6,
                      n[0..<4].allSatisfy({ (0...1).contains($0) }),
                      (0...5).contains(n[4]),
                      n.count == 5 || (0...5).contains(n[5]) else {
                    return "err \(line)"
                }
                let hold = n.count == 6 ? n[5] : 0
                if fast && p[0] == "aswipe" {
                    FastTouch.swipeAsync(from: pt(n[0], n[1]), to: pt(n[2], n[3]),
                                         duration: n[4], hold: hold)
                    return "sent \(ms(t0))"
                }
                if fast {
                    do {
                        try FastTouch.swipe(from: pt(n[0], n[1]), to: pt(n[2], n[3]),
                                            duration: n[4], hold: hold)
                        return "ok fast \(ms(t0))"
                    } catch {
                        if !untouched(error) { return "err \(error.localizedDescription)" }
                    }
                }
                slowSwipe(n, hold: hold)
            case "quit":
                running = false
                return "bye"
            default:
                return "err \(line)"
            }
            return "ok \(ms(t0))"
        }

        // Loopback only: usbmuxd's forwarded connections arrive there, and
        // nothing else needs to reach this port (it takes anyone's touches).
        let params = NWParameters.tcp
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
                XCTFail("listener failed: \(error)")
                running = false
            default:
                break
            }
        }
        listener.newConnectionHandler = { conn in
            conn.stateUpdateHandler = { state in
                if case .failed = state { conn.cancel() }
            }
            conn.start(queue: .main)
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
                        // XCUI actions must run on the main thread: this
                        // queue is main.
                        let reply: String
                        if let text = String(data: bytes, encoding: .utf8) {
                            reply = handle(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            reply = "err undecodable"
                        }
                        conn.send(content: (reply + "\n").data(using: .utf8),
                                  completion: .contentProcessed { _ in })
                    }
                    // No command is this long: whatever sends it is not the Mac.
                    if pending.count > 4096 { conn.cancel(); return }
                    if done || error != nil { conn.cancel(); return }
                    readLine()
                }
            }
            readLine()
        }
        listener.start(queue: .main)
        while running {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        listener.cancel()
    }
}
