import Cocoa
import FlutterMacOS
import CoreGraphics

class InputInjectPlugin: NSObject {

    private static let channelName = "extended_screen/input_inject"

    // A second press counts as a double (then triple…) click when it comes
    // within the system double-click interval and lands within this many
    // points of the previous press: a fingertip is far less precise than a
    // mouse, so the window server's own few-pixel tolerance would miss most
    // double-taps.
    private static let multiClickRadius: CGFloat = 24

    // Mouse state carried between injected events. Flutter runs the method
    // channel handler on the main thread, so only the main thread touches it.

    /// One tablet's mouse state, kept per capture session (the `session` id
    /// Dart sends with each call; none means session 0).
    private final class InputState {
        // The button an injected down is holding: moves post as drags while
        // it is held, and releaseAll lets go of it if the link drops before
        // the up.
        var heldButton: CGMouseButton?
        // Click count of the current press, sent as mouseEventClickState:
        // macOS takes an event's click count (double-click, …) from that
        // field, and nothing fills it in for posted events.
        var clickCount: Int64 = 0
        var lastDownTime: TimeInterval = 0
        var lastDownPoint = CGPoint.zero
        var lastDownButton = CGMouseButton.left
        // Fractional wheel pixels carried into the next scroll event, per
        // axis, so a slow finger adds up to a scroll instead of truncating to
        // zero. Plain scroll and ⌘+scroll (pinch zoom) don't share a
        // remainder: it resets when the modifier flags change.
        var scrollRemainderX = 0.0
        var scrollRemainderY = 0.0
        var scrollRemainderFlags = CGEventFlags()
        // Where this tablet's scrolls go. Scroll events carry no point: the
        // tablet sends a move to the gesture's start (or the pinch centre)
        // first, which sets this.
        var scrollAnchor: CGPoint?
        // A press of this tablet's was dropped (another tablet held the
        // pointer): the rest of that gesture is dropped too, up to its
        // release, rather than reach the Mac in pieces once the pointer is
        // free.
        var dropUntilUp = false
    }

    private var states: [Int: InputState] = [:]

    private func state(_ session: Int) -> InputState {
        if let st = states[session] { return st }
        let st = InputState()
        states[session] = st
        return st
    }

    // The Mac has one pointer. The tablet whose press is holding a button
    // owns it until that button is released: meanwhile another tablet's
    // presses, releases and scrolls are dropped (its plain moves only set its
    // own scroll anchor), so one tablet can never break another's drag.
    private var pointerOwner: Int?

    // "Keep the Mac cursor in place" (a host setting, pushed via
    // setKeepCursor). macOS has a single system cursor and a posted press,
    // release or drag moves it, so with this on those borrow it: the first
    // saves where the user's cursor is, and once cursorReturnDelay passes
    // with no further press, release or drag (and no button held) it goes
    // back, unless the user has taken it meanwhile (moved it, or is pressing
    // their own button). Scrolls and pinches don't borrow it: a plain move
    // only sets scrollAnchor, and macOS routes a scroll by the location in the
    // event, so they are posted there. The window server still moves the
    // cursor to each one, so a move posted right behind it puts it back.
    private var keepCursor = false
    // Where the user's cursor was when the tablet took it; nil when not borrowed.
    private var savedCursor: CGPoint?
    // Where the tablet last moved the cursor (a posted press, release, drag
    // or move); the cursor still being there means the user hasn't touched it.
    private var lastCursorPoint: CGPoint?
    // Where a scroll puts the cursor back to (see injectScroll); a return
    // from a tap or drag updates it too.
    private var scrollHome: CGPoint?
    // Points the cursor left within the last staleWindow: each scroll's
    // anchor, and the tablet's point when a return moves the cursor off it.
    // A cursor read near one of them in that window may predate a move back
    // the window server hasn't applied yet, or be the user's motion added
    // while the cursor sat there.
    private var recentTabletPoints: [(point: CGPoint, time: TimeInterval)] = []
    private static let staleWindow: TimeInterval = 0.1
    private static let staleRadius: CGFloat = 48
    private var scrollSettleWork: DispatchWorkItem?
    // Longer than the gap between a fling's scrolls, so it runs once at the end.
    private static let scrollSettleDelay: TimeInterval = 0.05
    private var returnWork: DispatchWorkItem?
    // The last return, for a press that comes before the window server has
    // moved the cursor back: reading it then would save the tablet's point.
    private var lastReturn: (point: CGPoint, time: TimeInterval)?
    // Covers the moment between a tap's down and up and the injection of the
    // next press of a double tap without leaving the cursor out visibly long.
    // (A wait of 0.25 s, plus a scroll keeping the cursor until its fling
    // ended, felt like seconds on device.)
    private static let cursorReturnDelay: TimeInterval = 0.1

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
        case "releaseAll":
            // With a session: that tablet's button and state. Without one
            // (the app is ending): every tablet's.
            releaseAll(session: (call.arguments as? [String: Any])?["session"] as? Int)
            result(nil)
        case "setKeepCursor":
            let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
            setKeepCursor(enabled)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Mouse

    private func injectMouse(args: [String: Any]) {
        guard let actionIdx = args["action"] as? Int,
              let buttonIdx = args["button"] as? Int,
              let rawNx = args["normalizedX"] as? Double,
              let rawNy = args["normalizedY"] as? Double,
              let dx = args["displayX"] as? Double,
              let dy = args["displayY"] as? Double,
              let dw = args["displayW"] as? Double,
              let dh = args["displayH"] as? Double,
              rawNx.isFinite, rawNy.isFinite else { return }
        let session = args["session"] as? Int ?? 0
        let st = state(session)

        // The tablet normalises over its whole screen, i.e. the whole encoded
        // frame, but the captured display fills only the part of the frame its
        // aspect ratio allows (Mirror onto a differently shaped panel adds
        // bars). Map through the content rect its capture measured so a touch
        // lands on what it shows; a touch on a bar clamps to the nearest edge.
        let (nx, ny) = CaptureContentRect.forSession(session).map(x: rawNx, y: rawNy)
        // Stay on the display: x == displayX + displayW is already the first
        // column of whatever display sits to its right.
        let x = dx + min(nx * dw, max(dw - 1, 0))
        let y = dy + min(ny * dh, max(dh - 1, 0))
        let pt = CGPoint(x: x, y: y)
        let cgButton: CGMouseButton = buttonIdx == 2 ? .right : .left

        // Modifier bitmask (0x01 ⌘, 0x02 ⇧, 0x04 ⌃, 0x08 ⌥) — used for
        // ⌘+scroll pinch-to-zoom. Matches injectKey's mapping.
        let mods = args["modifiers"] as? Int ?? 0
        var flags = CGEventFlags()
        if mods & 0x01 != 0 { flags.insert(.maskCommand)   }
        if mods & 0x02 != 0 { flags.insert(.maskShift)     }
        if mods & 0x04 != 0 { flags.insert(.maskControl)   }
        if mods & 0x08 != 0 { flags.insert(.maskAlternate) }

        // Another tablet is holding the pointer (mid-drag or mid-press): this
        // one may only note where its next scroll would go.
        if let owner = pointerOwner, owner != session {
            if actionIdx == 0 { st.scrollAnchor = pt }
            if actionIdx == 1 { st.dropUntilUp = true }
            if actionIdx == 2 { st.dropUntilUp = false }
            return
        }
        // The rest of a gesture whose press was dropped. A new press starts
        // afresh, so a lost release can't silence this tablet for good.
        if st.dropUntilUp {
            if actionIdx == 1 {
                st.dropUntilUp = false
            } else {
                if actionIdx == 0 { st.scrollAnchor = pt }
                if actionIdx == 2 { st.dropUntilUp = false }
                return
            }
        }

        // Only a press, a release or a drag has to move the cursor.
        let takesCursor = actionIdx == 1 || actionIdx == 2
            || (actionIdx == 0 && st.heldButton != nil)
        if keepCursor && takesCursor { borrowCursor() }

        switch actionIdx {
        case 1:
            // A down while a button is still held means its up got lost:
            // release it where the cursor is first, so the app never sees two
            // presses in a row.
            if let held = st.heldButton {
                postMouse(held == .left ? .leftMouseUp : .rightMouseUp,
                          at: CGEvent(source: nil)?.location ?? pt, button: held,
                          flags: flags, clickState: st.clickCount)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let isRepeat = st.clickCount > 0
                && cgButton == st.lastDownButton
                && now - st.lastDownTime <= NSEvent.doubleClickInterval
                && hypot(pt.x - st.lastDownPoint.x, pt.y - st.lastDownPoint.y) <= Self.multiClickRadius
            st.clickCount = isRepeat ? st.clickCount + 1 : 1
            st.lastDownTime = now
            st.lastDownPoint = pt
            st.lastDownButton = cgButton
            st.heldButton = cgButton
            pointerOwner = session
            postMouse(cgButton == .left ? .leftMouseDown : .rightMouseDown,
                      at: pt, button: cgButton, flags: flags, clickState: st.clickCount)
            lastCursorPoint = pt
            st.scrollAnchor = pt
        case 2:
            // Release the button actually held; an up with nothing held (its
            // down was lost) is still posted, as a single click's up.
            let button = st.heldButton ?? cgButton
            let clickState = st.heldButton != nil ? st.clickCount : 1
            st.heldButton = nil
            pointerOwner = nil
            postMouse(button == .left ? .leftMouseUp : .rightMouseUp,
                      at: pt, button: button, flags: flags, clickState: clickState)
            lastCursorPoint = pt
            st.scrollAnchor = pt
        case 3:
            injectScroll(st, dx: args["scrollDx"] as? Double ?? 0,
                         dy: args["scrollDy"] as? Double ?? 0,
                         flags: flags)
        default:
            // macOS only treats movement as a drag (window moves, text
            // selection, sliders) when it arrives as a dragged event. With no
            // button held this is a plain move: the start of a scroll or the
            // centre of a pinch. It parks the cursor there, except with
            // keepCursor on, where it only marks where the scrolls go.
            if let held = st.heldButton {
                postMouse(held == .left ? .leftMouseDragged : .rightMouseDragged,
                          at: pt, button: held, flags: flags, clickState: st.clickCount)
                lastCursorPoint = pt
            } else if !keepCursor {
                postMouse(.mouseMoved, at: pt, button: cgButton, flags: flags, clickState: nil)
                lastCursorPoint = pt
            }
            st.scrollAnchor = pt
        }

        // A held button is a drag still in progress: the cursor stays until
        // the up, which schedules the return.
        if keepCursor && takesCursor && st.heldButton == nil { scheduleCursorReturn() }
    }

    // MARK: - Cursor return

    private func setKeepCursor(_ enabled: Bool) {
        // Hand back a cursor borrowed under the old setting now, rather than
        // leave it with the tablet.
        if !enabled { returnCursor() }
        keepCursor = enabled
    }

    /// Starts or continues the tablet's use of the cursor: cancels a pending
    /// return and, if the cursor isn't borrowed yet, saves the user's cursor
    /// position.
    private func borrowCursor() {
        returnWork?.cancel()
        returnWork = nil
        guard savedCursor == nil else { return }
        if let last = lastReturn,
           ProcessInfo.processInfo.systemUptime - last.time < 0.1 {
            savedCursor = last.point
        } else {
            savedCursor = CGEvent(source: nil)?.location
        }
    }

    private func scheduleCursorReturn() {
        returnWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.returnCursor() }
        returnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cursorReturnDelay, execute: work)
    }

    /// Puts the cursor back where the user left it. Skipped when the user has
    /// moved the mouse since the tablet last placed the cursor or is pressing
    /// their own button (it is theirs again already), and mid-drag (moving it
    /// would break the drag).
    private func returnCursor() {
        returnWork?.cancel()
        returnWork = nil
        guard let saved = savedCursor else { return }
        savedCursor = nil
        guard pointerOwner == nil else { return }
        // The tablet's button is up here, so a pressed button is the user's:
        // a press-and-hold on the trackpad inside the return delay would
        // otherwise have its drag jump to the saved point.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if let last = lastCursorPoint, let now = CGEvent(source: nil)?.location,
           hypot(now.x - last.x, now.y - last.y) > 1 {
            return
        }
        postMouse(.mouseMoved, at: saved, button: .left, flags: [], clickState: nil)
        let now = ProcessInfo.processInfo.systemUptime
        lastReturn = (saved, now)
        // A scroll right after must not take the point being left for home.
        scrollHome = saved
        if let last = lastCursorPoint { recentTabletPoints.append((last, now)) }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton,
                           flags: CGEventFlags, clickState: Int64?) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: point, mouseButton: button) else { return }
        if let clickState = clickState {
            ev.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if !flags.isEmpty { ev.flags = flags }
        ev.post(tap: .cghidEventTap)
    }

    /// Scroll deltas arrive in wheel units; ×10 gives the pixels posted (see
    /// TouchGestureRecognizer._scrollGain). Whole pixels are posted and the
    /// fraction is kept for the next event on the same axis.
    ///
    /// [point] is the gesture's scroll anchor. macOS sends a scroll to the
    /// window at the event's location, which a new event takes from the
    /// cursor, so it is set: otherwise the event could pick up a position
    /// from before the window server applied the move that parked the cursor
    /// (on device that sent the first scroll of a gesture to the window under
    /// the user's own cursor).
    ///
    /// The window server also moves the cursor to a posted scroll's location,
    /// from either tap. With keepCursor on, a move posted right behind each
    /// scroll puts it back; the same tap keeps the two in order, so the
    /// scroll is routed at the anchor first.
    private func injectScroll(_ st: InputState, dx: Double, dy: Double, flags: CGEventFlags) {
        let point = st.scrollAnchor
        if flags != st.scrollRemainderFlags {
            st.scrollRemainderX = 0
            st.scrollRemainderY = 0
            st.scrollRemainderFlags = flags
        }
        st.scrollRemainderX += Self.wheelPixels(dx)
        st.scrollRemainderY += Self.wheelPixels(dy)
        let px = st.scrollRemainderX.rounded(.towardZero)
        let py = st.scrollRemainderY.rounded(.towardZero)
        st.scrollRemainderX -= px
        st.scrollRemainderY -= py
        guard px != 0 || py != 0,
              let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                  wheelCount: 2, wheel1: Int32(py), wheel2: Int32(px), wheel3: 0) else { return }
        if !flags.isEmpty { ev.flags = flags }
        guard let point = point else {
            ev.post(tap: .cghidEventTap)
            return
        }
        guard keepCursor else {
            ev.location = point
            ev.post(tap: .cghidEventTap)
            return
        }
        // A button pressed with none held by the tablet (a scroll never comes
        // mid-drag from it) is the user's: the scroll would pull their drag
        // onto the tablet's display, so it is dropped.
        guard st.heldButton != nil || NSEvent.pressedMouseButtons == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recentTabletPoints.removeAll { now - $0.time >= Self.staleWindow }
        let cursor = CGEvent(source: nil)?.location
        let nearRecent = cursor.map { c in
            recentTabletPoints.contains { Self.near(c, $0.point, within: Self.staleRadius) }
        } ?? true
        if let saved = savedCursor, st.heldButton == nil {
            // A tap or drag's return is still pending: this scroll's move back
            // does it now, unless the user has taken the cursor meanwhile.
            returnWork?.cancel()
            returnWork = nil
            savedCursor = nil
            let tabletHasIt = nearRecent || cursor.map { c in
                lastCursorPoint.map { Self.near(c, $0, within: Self.staleRadius) } ?? false
            } ?? true
            scrollHome = tabletHasIt ? saved : cursor
            if let last = lastCursorPoint { recentTabletPoints.append((last, now)) }
        } else if let c = cursor, !nearRecent {
            // Otherwise home is where the cursor is, unless it reads near a
            // point it just left: then the last home stands.
            scrollHome = c
        }
        recentTabletPoints.append((point, now))
        ev.location = point
        ev.post(tap: .cghidEventTap)
        if let home = scrollHome, !Self.near(home, point, within: 1) {
            postMouse(.mouseMoved, at: home, button: .left, flags: [], clickState: nil)
            // A press right after reads the cursor before this applies.
            lastReturn = (home, now)
            settleAfterScrolls(at: home)
        }
    }

    /// The pointer position a physical mouse moves from can keep the scroll's
    /// anchor even though the move back right behind it shows the cursor at
    /// home: on device, the next nudge of the Mac's mouse, seconds later,
    /// jumped the cursor to the tablet's display. Another posted move to home
    /// doesn't fix it (the cursor reads there already, so nothing moves), so
    /// once the scrolls stop the cursor is warped there, which sets that
    /// position directly. A warp holds back the user's own mouse for a moment
    /// unless the mouse is associated with the cursor again right after.
    private func settleAfterScrolls(at home: CGPoint) {
        scrollSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.scrollSettleWork = nil
            // Not if the tablet has the cursor again, a button is down, or
            // the user has moved it since.
            guard self.keepCursor, self.savedCursor == nil, self.pointerOwner == nil,
                  NSEvent.pressedMouseButtons == 0,
                  let now = CGEvent(source: nil)?.location,
                  Self.near(now, home, within: 1) else { return }
            CGWarpMouseCursorPosition(home)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        scrollSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollSettleDelay, execute: work)
    }

    private static func near(_ a: CGPoint, _ b: CGPoint, within r: CGFloat) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= r
    }

    /// Wheel units → pixels, clamped so a NaN, infinite or huge value read off
    /// the socket can't trap the Int32 conversion.
    private static func wheelPixels(_ units: Double) -> Double {
        guard units.isFinite else { return 0 }
        return min(max(units * 10, -10_000), 10_000)
    }

    /// Called when a tablet's session tears down ([session]), or for every
    /// tablet (nil). Lets go of a button the tablet pressed but never
    /// released (the link dropped mid-drag), which would otherwise turn every
    /// later move into a drag, and forgets its click and scroll state so its
    /// next session starts clean. Once no tablet holds the pointer, a
    /// borrowed cursor is handed back; once no tablet has any state left, the
    /// shared cursor-return state is cleared too.
    private func releaseAll(session: Int?) {
        let ending = session.map { [$0] } ?? Array(states.keys)
        for id in ending {
            guard let st = states.removeValue(forKey: id) else { continue }
            if let held = st.heldButton {
                let at = CGEvent(source: nil)?.location ?? st.lastDownPoint
                postMouse(held == .left ? .leftMouseUp : .rightMouseUp,
                          at: at, button: held, flags: [], clickState: st.clickCount)
            }
            if pointerOwner == id { pointerOwner = nil }
        }
        if session == nil { pointerOwner = nil }
        if pointerOwner == nil { returnCursor() }
        guard states.isEmpty else { return }
        lastCursorPoint = nil
        scrollHome = nil
        recentTabletPoints.removeAll()
        scrollSettleWork?.cancel()
        scrollSettleWork = nil
        lastReturn = nil
    }

    // MARK: - Keyboard

    private func injectKey(args: [String: Any]) {
        guard let keycode  = args["keycode"]   as? Int,
              let mods     = args["modifiers"] as? Int,
              let isDown   = args["isDown"]    as? Bool,
              // Read off the socket: an out-of-range code must not trap.
              let virtualKey = CGKeyCode(exactly: keycode) else { return }

        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: virtualKey,
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
