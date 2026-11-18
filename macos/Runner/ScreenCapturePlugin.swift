import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import os

// Capture/encode diagnostics. NSLog's interpolated text shows only as
// "<private>" in the unified log, so these go out as public os_log entries —
// readable without a debugger, e.g.
//   log stream --predicate 'subsystem == "com.example.extendedscreen"'
// — and are echoed to stderr for the `flutter run` console.
private let captureLog = OSLog(subsystem: "com.example.extendedscreen", category: "capture")

private func esLog(_ message: String) {
    os_log("%{public}@", log: captureLog, type: .default, message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Where a session's captured display sits inside its encoded frame,
/// normalised to the frame (0…1). The frame is always panel-shaped, so a
/// display of another shape (Mirror from a notched MacBook or a 16:9 monitor
/// onto a 16:10 tablet) is scaled to fit with bars along two edges. The tablet
/// reports touches over the whole frame, and InputInjectPlugin maps them
/// through this rect onto the display. One per capture session (the session
/// id Dart hands out): written on that session's capture queue from each
/// frame's SCStreamFrameInfo and read on the main thread, hence the lock.
/// Until the current capture's first frame arrives it is the whole frame.
final class CaptureContentRect {
    private static let registryLock = NSLock()
    private static var registry: [Int: CaptureContentRect] = [:]

    /// The rect of capture session [id], made on first use.
    static func forSession(_ id: Int) -> CaptureContentRect {
        registryLock.lock(); defer { registryLock.unlock() }
        if let rect = registry[id] { return rect }
        let rect = CaptureContentRect()
        registry[id] = rect
        return rect
    }

    /// Forgets session [id]'s rect (the session is gone).
    static func remove(_ id: Int) {
        registryLock.lock(); registry[id] = nil; registryLock.unlock()
    }

    private let lock = NSLock()
    private var rect: CGRect?  // nil: not measured yet, use the whole frame

    /// Back to the whole frame: a capture is starting or has stopped.
    func reset() {
        lock.lock(); rect = nil; lock.unlock()
    }

    /// Stores the rect measured from a frame. Returns true when it differs
    /// from the stored one, so the caller logs only changes.
    func update(_ newRect: CGRect) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rect == newRect { return false }
        rect = newRect
        return true
    }

    /// Maps a point normalised over the whole frame to one normalised over the
    /// display's picture. A point on a bar clamps to the picture's nearest edge.
    func map(x nx: Double, y ny: Double) -> (Double, Double) {
        lock.lock(); let current = rect; lock.unlock()
        var x = nx, y = ny
        if let r = current, r.width > 0, r.height > 0 {
            x = (nx - Double(r.minX)) / Double(r.width)
            y = (ny - Double(r.minY)) / Double(r.height)
        }
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }
}

// Registers a stub on older macOS and the real implementation on 12.3+
class ScreenCapturePlugin: NSObject {
    static func register(with messenger: FlutterBinaryMessenger) {
        if #available(macOS 12.3, *) {
            ScreenCapturePluginImpl.register(with: messenger)
        } else {
            let ch = FlutterMethodChannel(name: "extended_screen/screen_capture",
                                          binaryMessenger: messenger)
            ch.setMethodCallHandler { call, result in
                if call.method == "requestPermission" { result(false) }
                else { result(FlutterMethodNotImplemented) }
            }
        }
    }
}

/// The capture plugin: one method channel and one frame stream for every
/// capture session, each session (one per tablet) addressed by the id Dart
/// sends as `session` (a call without one means session 0). Every encoded
/// frame on the stream starts with its session's id, 4 bytes big-endian.
/// Main thread: the method calls, the session registry and every
/// display/stream start and stop.
@available(macOS 12.3, *)
private class ScreenCapturePluginImpl: NSObject, FlutterStreamHandler {

    private static let channelName = "extended_screen/screen_capture"
    private static let frameChannelName = "extended_screen/frames"
    private var channel: FlutterMethodChannel?
    private var frameSink: FlutterEventSink?
    private var sessions: [Int: CaptureSession] = [:]
    // Keeps macOS from App-Napping the (usually hidden) host while any
    // session streams: throttled timers/priority stalled encoding for
    // seconds at a time. Held while [streamingSessions] is not empty.
    private var captureActivity: NSObjectProtocol?
    private var streamingSessions = Set<Int>()

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = ScreenCapturePluginImpl()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        plugin.channel = ch
        ch.setMethodCallHandler(plugin.handle)

        let frameCh = FlutterEventChannel(name: frameChannelName, binaryMessenger: messenger)
        frameCh.setStreamHandler(plugin)

        plugin.observeSystemWake()
    }

    private var anyCapturing: Bool { sessions.values.contains { $0.isCapturing } }
    // Bumped by each wake notification: only the last one's rebuild request
    // goes out (the system-wake and display-wake notifications both fire on
    // resume).
    private var wakeGeneration = 0

    // MARK: - Sleep / Wake recovery

    // A sleep/wake cycle invalidates ScreenCaptureKit, the CGVirtualDisplays and
    // the VideoToolbox sessions, but the ADB-reverse socket (USB) survives — so
    // the Dart heartbeat/reconnect never fires and the pipeline stays dead. On
    // wake we ask Dart to rebuild every session (Dart owns the orchestration:
    // virtual display → SCK → encoder → control packets).
    private func observeSystemWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Rearranging displays (or changing resolution/scaling) in System
        // Settings → Displays doesn't invalidate the capture sessions, but it
        // does move the displays' screen-space origins — which Dart caches to
        // map tablet touch coordinates onto the real screen. Adding or removing
        // one session's virtual display moves the others too. Ask Dart to
        // refetch every session's bounds so touch keeps landing in the right
        // place.
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        guard anyCapturing else { return }
        channel?.invokeMethod("onDisplayBoundsChanged", arguments: nil)
    }

    @objc private func systemDidWake(_ note: Notification) {
        // Whether or not a stream is running: ScreenCaptureKit stops it as
        // the displays go to sleep, the rebuild that follows finds no display
        // and fails, and the wake is when one can work again. Dart decides
        // which sessions to rebuild (those still connected; it ignores this
        // with none).
        guard !sessions.isEmpty else { return }
        esLog("[ExtendedScreen] Wake (\(note.name.rawValue)) — scheduling capture restart")
        // Give the GPU/displays a moment to come back before rebuilding,
        // counted from the last of the wake notifications, which then get
        // one request. No session id: every session needs rebuilding.
        wakeGeneration += 1
        let generation = wakeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, generation == self.wakeGeneration else { return }
            self.channel?.invokeMethod("onCaptureNeedsRestart", arguments: nil)
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - FlutterStreamHandler (frame EventChannel)

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        frameSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        frameSink = nil
        return nil
    }

    // MARK: - Called by sessions (main thread)

    /// A session's encoded frame, already prefixed with its id.
    func emitFrame(_ data: Data) {
        frameSink?(FlutterStandardTypedData(bytes: data))
    }

    func invoke(_ method: String, _ arguments: Any?) {
        channel?.invokeMethod(method, arguments: arguments)
    }

    /// App Nap is held off while any session streams.
    func setStreaming(_ id: Int, _ streaming: Bool) {
        if streaming { streamingSessions.insert(id) } else { streamingSessions.remove(id) }
        if !streamingSessions.isEmpty, captureActivity == nil {
            captureActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Streaming the screen to the tablet")
        } else if streamingSessions.isEmpty, let activity = captureActivity {
            ProcessInfo.processInfo.endActivity(activity)
            captureActivity = nil
        }
    }

    /// Whether a session other than [id] has an encoder: every encoder after
    /// the first must be a hardware one (the second can otherwise land
    /// silently on a software encoder).
    func otherSessionEncodes(than id: Int) -> Bool {
        sessions.contains { $0.key != id && $0.value.hasEncoder }
    }

    // MARK: - Method calls

    private func session(_ id: Int) -> CaptureSession {
        if let s = sessions[id] { return s }
        let s = CaptureSession(id: id, plugin: self)
        sessions[id] = s
        return s
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let id = args["session"] as? Int ?? 0
        switch call.method {
        case "requestPermission":
            requestPermission(result: result)
        case "startCapture":
            session(id).startCapture(args: args, result: result)
        case "stopCapture":
            guard let s = sessions[id] else { result(nil); return }
            s.stopCapture { result(nil) }
        case "requestIdr":
            sessions[id]?.requestKeyframe()
            result(nil)
        case "setBitrate":
            // Applied by the session's timer thread before its next encode
            // (see onTick), the thread every other call into the encoder
            // comes from, so nothing here touches the encoder.
            if let bps = args["bitrate"] as? Int, bps > 0 {
                sessions[id]?.requestBitrate(bps)
            }
            result(nil)
        case "createVirtualDisplay":
            session(id).createVirtualDisplay(args: args, result: result)
        case "removeVirtualDisplay":
            guard let s = sessions[id] else { result(nil); return }
            s.removeVirtualDisplay { result(nil) }
        case "getVirtualDisplayBounds":
            let rect = CGDisplayBounds(sessions[id]?.boundsDisplayID ?? CGMainDisplayID())
            result([
                "x": rect.origin.x,
                "y": rect.origin.y,
                "w": rect.width,
                "h": rect.height,
            ])
        case "disposeSession":
            // Stops and forgets the session: its capture, encoder and
            // virtual display. Answered once all of that is gone.
            guard let s = sessions.removeValue(forKey: id) else { result(nil); return }
            s.dispose {
                CaptureContentRect.remove(id)
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Permission

    private func requestPermission(result: @escaping FlutterResult) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, error in
            DispatchQueue.main.async {
                result(error == nil)
            }
        }
    }
}

/// Counts frames handed to VideoToolbox and not yet returned. Retained by
/// every encode callback, so a callback that lands after its session is gone
/// still has a counter to decrement.
private final class EncodeCounter {
    private let value = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    init() { value.initialize(to: 0) }
    deinit { value.deallocate() }
    func increment() { OSAtomicIncrement32(value) }
    func decrement() { OSAtomicDecrement32(value) }
    var current: Int32 { OSAtomicAdd32(0, value) }
}

/// One run of a session's timer thread: stop() tells it to end, and [done]
/// is signalled once it has. Its frames in flight are counted per run, so a
/// frame an old encoder never returned can't hold back the next capture.
private final class TimerRun {
    private let lock = NSLock()
    private var running = true
    let done = DispatchSemaphore(value: 0)
    let inFlight = EncodeCounter()
    var reportedEncodeError = false  // timer thread only

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }
}

/// One tablet's capture pipeline: its virtual display (Extend), its
/// ScreenCaptureKit stream, its VideoToolbox encoder and the real-time timer
/// thread that feeds the encoder. Main thread: everything except the
/// capture queue's sample handling, the timer thread's encoding and the
/// encoder's callbacks, which share only what [lock], [bufferLock] and the
/// counters guard.
@available(macOS 12.3, *)
private final class CaptureSession: NSObject, SCStreamDelegate, SCStreamOutput {
    let id: Int
    private weak var plugin: ScreenCapturePluginImpl?
    private let contentRect: CaptureContentRect
    private let tag: String

    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    // CGVirtualDisplay is a private class (see CGVirtualDisplay.h); kept as
    // AnyObject, released by dropping the reference.
    private var virtualDisplay: AnyObject?
    private var virtualDisplayID: CGDirectDisplayID = 0
    // The display the running capture shows (0 when not capturing): the
    // virtual display in Extend, the main display in Mirror or when Extend
    // had to fall back. getVirtualDisplayBounds reports this display, so touch
    // input maps onto the picture the tablet actually shows.
    private var capturedDisplayID: CGDirectDisplayID = 0
    // Bumped on every start/stop so a start still waiting on ScreenCaptureKit
    // (up to ~1.5 s while it polls for a new virtual display) can't bring a
    // stream up after stopCapture.
    private var captureGeneration = 0
    // A just-created virtual display can take a moment to show up in
    // ScreenCaptureKit's list: re-poll this many times, this far apart.
    private static let virtualDisplayLookupRetries = 6
    private static let virtualDisplayLookupDelay = 0.25
    // True between a successful startCapture and stopCapture.
    private(set) var isCapturing = false
    private var timerRun: TimerRun?

    // Shared with the timer thread, under [lock].
    private let lock = NSLock()
    private var forceKeyframe = true  // first encoded frame is always an IDR
    // Over Wi-Fi the host's BitrateAdapter moves the encoder's average
    // bitrate to what the link carries. setBitrate (main thread) leaves the
    // new value here; the timer thread applies it before its next encode.
    // 0: nothing waiting. [encoderBitrate] is what the encoder runs at.
    private var requestedBitrate = 0
    private var encoderBitrate = 0

    // Timer-thread state: set on the main thread before the thread starts
    // (startCapture runs only once the previous thread has ended), then the
    // timer thread's alone.
    private var targetFps = 60
    // "Max" preset: the encode rate steps down from the tablet's top refresh
    // rate when this Mac's encoder can't keep up, and back up once it
    // recovers (see adaptFrameRate).
    private var adaptiveFps = false
    private var maxFps = 60
    private var overloadStreak = 0
    // Sum of the timer's ticks/s over the current overload streak — while the
    // encoder is saturated that's its real throughput (see adaptFrameRate).
    private var overloadTickSum = 0.0
    private var healthyStreak = 0
    // 45 sits between 30 and 60 because a 60 fps H.264 session at a tablet's
    // native resolution is right at the limit on some Macs (M3 Pro: ~50–60).
    private static let adaptiveRates = [30, 45, 60, 90, 120]
    // Seconds of health required before trying the next rate up; doubles each
    // time a step-up fails quickly so a rate that doesn't fit can't oscillate.
    private var stepUpDelay = 10
    private var lastStepUpAt: Date?
    private var diagLastLog = Date()

    // Frames handed to the encoder and not yet returned (TimerRun.inFlight):
    // past this many the tick skips the frame to bound latency.
    private static let maxPendingEncodeFrames: Int32 = 10

    // The newest captured frame (capture queue writes, timer thread reads).
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private var frameCount = 0  // capture queue only

    // Diagnostic counters.
    private var diagSckCount: Int32 = 0
    private var diagEncCount: Int32 = 0
    private var diagDropCount: Int32 = 0
    private var diagTickCount: Int32 = 0   // timer ticks per second

    private let captureQueue: DispatchQueue

    var hasEncoder: Bool { compressionSession != nil }

    /// The display touch input should land on: the captured one, else this
    /// session's virtual display, else the main display.
    var boundsDisplayID: CGDirectDisplayID {
        capturedDisplayID != 0 ? capturedDisplayID
            : (virtualDisplayID != 0 ? virtualDisplayID : CGMainDisplayID())
    }

    init(id: Int, plugin: ScreenCapturePluginImpl) {
        self.id = id
        self.plugin = plugin
        self.contentRect = CaptureContentRect.forSession(id)
        self.tag = "[ExtendedScreen] s\(id)"
        self.captureQueue = DispatchQueue(label: "capture.\(id)", qos: .userInteractive)
        super.init()
    }

    // MARK: - Keyframes and bitrate (main thread → timer thread)

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func requestBitrate(_ bps: Int) {
        lock.lock(); requestedBitrate = min(bps, Int(Int32.max)); lock.unlock()
    }

    // MARK: - Virtual Display (Extend Mode)

    /// Gives this session a virtual display, replacing its own previous one
    /// if it had one; other sessions' displays are left alone. Answers
    /// {applied, displayID}; displayID 0 means it failed.
    func createVirtualDisplay(args: [String: Any], result: @escaping FlutterResult) {
        let make = { [weak self] in
            guard let self = self else {
                result(["applied": false, "displayID": 0])
                return
            }
            // w/h are the LOGICAL desktop points (the client panel ÷ 2).
            // Physical pixel buffer = w*2 × h*2 — the client's native panel.
            let w = args["width"]  as? Int ?? 1280
            let h = args["height"] as? Int ?? 800
            let r = args["refreshRate"] as? Int ?? 60
            let serial = args["serialNum"] as? Int ?? 0x0001
            let name = args["name"] as? String ?? "Extended Screen"
            let pw = w * 2, ph = h * 2  // physical pixels

            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.queue = DispatchQueue.global(qos: .userInteractive)
            descriptor.name = name
            descriptor.maxPixelsWide = UInt32(pw)
            descriptor.maxPixelsHigh = UInt32(ph)
            // ~220 PPI → macOS treats this as a Retina display and applies 2x
            // HiDPI scaling: logical w×h points, physical pw×ph pixels.
            let mmW = CGFloat(w) / 220.0 * 25.4
            let mmH = CGFloat(h) / 220.0 * 25.4
            descriptor.sizeInMillimeters = CGSize(width: mmW, height: mmH)
            descriptor.productID = 0x1234
            descriptor.vendorID  = 0x3456
            // macOS remembers each display's arrangement by its serial; a
            // different one per tablet keeps two of them apart.
            descriptor.serialNum = UInt32(truncatingIfNeeded: max(serial, 1))
            let tag = self.tag
            descriptor.terminationHandler = { _, _ in
                esLog("\(tag) virtual display terminated")
            }

            let display = CGVirtualDisplay(descriptor: descriptor)

            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = 1  // 2x Retina: logical w×h → physical pw×ph
            let mode = CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h),
                                            refreshRate: Double(r))
            settings.modes = [mode]

            let ok = display.apply(settings)
            self.virtualDisplay = display
            self.virtualDisplayID = display.displayID
            esLog("\(tag) Virtual display created id=\(display.displayID) applied=\(ok) serial=\(serial)")
            result(["applied": ok, "displayID": Int(display.displayID)])
        }
        guard virtualDisplay != nil else {
            make()
            return
        }
        // Replacing this session's own display: release it first so the
        // system reclaims it before the new one is made (a double allocation
        // gave id 0 / applied false), and give the OS a moment to remove it.
        virtualDisplay = nil
        virtualDisplayID = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: make)
    }

    /// Releases this session's virtual display and calls back once the
    /// system no longer lists it (at most ~1 s), so whatever runs next sees
    /// a settled set of displays.
    func removeVirtualDisplay(completion: @escaping () -> Void) {
        let old = virtualDisplayID
        virtualDisplay = nil
        virtualDisplayID = 0
        guard old != 0 else {
            completion()
            return
        }
        Self.waitUntilGone(old, deadline: Date().addingTimeInterval(1), completion: completion)
    }

    private static func waitUntilGone(_ display: CGDirectDisplayID, deadline: Date,
                                      completion: @escaping () -> Void) {
        if !activeDisplays().contains(display) || Date() >= deadline {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilGone(display, deadline: deadline, completion: completion)
        }
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - Screen Capture

    /// Starts capturing. `mode` 0 is Extend (this session's virtual display)
    /// and 1 Mirror (the main display, whatever other displays exist).
    /// Answers {displayID, hardware, fellBack} or an error: ENCODER_BUSY,
    /// NO_ENCODER and ENCODER_FAILED when no encoder could be made.
    func startCapture(args: [String: Any], result: @escaping FlutterResult) {
        if stream != nil || timerRun != nil || compressionSession != nil {
            // Still running (or a start is under way): stop it first, then
            // start, so two pipelines never run for one session. A stop or
            // start that comes meanwhile wins over this one.
            let generation = captureGeneration + 1  // what stopCapture sets
            stopCapture { [weak self] in
                guard let self = self, self.captureGeneration == generation else {
                    result(FlutterError(code: "CANCELLED", message: "Capture stopped before it started", details: nil))
                    return
                }
                self.startCapture(args: args, result: result)
            }
            return
        }
        // Logical size × scaleFactor = the resolution we capture/encode at
        // (2.0 = native panel via HiDPI, 1.0 = half-res for performance/custom).
        let wLogical = args["width"]  as? Int ?? 1280
        let hLogical = args["height"] as? Int ?? 800
        let scale = args["scaleFactor"] as? Double ?? 2.0
        let w = (Int(Double(wLogical) * scale) >> 1) << 1  // encoder needs even dims
        let h = (Int(Double(hLogical) * scale) >> 1) << 1
        let fps   = args["refreshRate"] as? Int ?? 60
        let br    = args["bitrate"]     as? Int ?? 20_000_000
        let codec = args["codec"]       as? String ?? "h264"
        let extend = (args["mode"] as? Int ?? 0) == 0
        let requireHardware = (args["requireHardware"] as? Bool ?? false)
            || (plugin?.otherSessionEncodes(than: id) ?? false)
        targetFps = fps
        maxFps = fps
        adaptiveFps = args["adaptiveFps"] as? Bool ?? false
        overloadStreak = 0
        overloadTickSum = 0
        healthyStreak = 0
        stepUpDelay = 10
        lastStepUpAt = nil

        let (hardware, encoderError) = setupEncoder(width: w, height: h, fps: fps, bitrate: br,
                                                    codec: codec, requireHardware: requireHardware)
        if let error = encoderError {
            result(error)
            return
        }
        plugin?.setStreaming(id, true)

        captureGeneration += 1
        let generation = captureGeneration
        capturedDisplayID = 0
        contentRect.reset()
        // On the capture queue, so after any sample the old stream had
        // queued and before the new stream's first one: neither a stale frame
        // nor the first count carries over.
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.frameCount = 0
            self.bufferLock.lock(); self.latestPixelBuffer = nil; self.bufferLock.unlock()
        }

        // A start that fails from here on lets go of what it holds at once
        // (its encoder, App Nap's hold) rather than at the next stop. A wake
        // asks Dart to try again (see systemDidWake).
        let fail: (FlutterError) -> Void = { [weak self] error in
            guard let self = self else { result(error); return }
            esLog("\(self.tag) Capture not started: \(error.code) \(error.message ?? "")")
            self.stopCapture { result(error) }
        }

        // Called back on the main thread, where the stream is set up so the
        // generation check can't race stopCapture.
        findCaptureDisplay(virtualID: extend ? virtualDisplayID : 0, generation: generation,
                           attempt: 0) { [weak self] display, fellBack, error in
            guard let self = self, generation == self.captureGeneration else {
                result(FlutterError(code: "CANCELLED", message: "Capture stopped before it started", details: nil))
                return
            }
            guard let targetDisplay = display else {
                if let error = error {
                    fail(FlutterError(code: "SCK_ERROR", message: error.localizedDescription, details: nil))
                } else {
                    fail(FlutterError(code: "NO_DISPLAY", message: "No display to capture", details: nil))
                }
                return
            }

            // Panel-sized output even when the display has another shape:
            // ScreenCaptureKit keeps the display's aspect ratio and adds bars,
            // and the frames' content rect (see trackContentRect) tells input
            // mapping where the picture is.
            let config = SCStreamConfiguration()
            config.width  = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true
            if #available(macOS 13.0, *) {
                config.capturesAudio = false
            }

            let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = newStream

            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                newStream.startCapture { [weak self] err in
                    DispatchQueue.main.async {
                        // stopCapture ran meanwhile. Its stop reached this
                        // stream before the start finished, which ScreenCaptureKit
                        // may reject, so stop it again here if it did come up;
                        // either way don't mark it live or start the timer.
                        guard let self = self, generation == self.captureGeneration else {
                            if err == nil {
                                if let self = self {
                                    try? newStream.removeStreamOutput(self, type: .screen)
                                }
                                newStream.stopCapture { _ in }
                            }
                            result(FlutterError(code: "CANCELLED", message: "Capture stopped before it started", details: nil))
                            return
                        }
                        guard err == nil, let encoder = self.compressionSession else {
                            fail(FlutterError(code: "START_FAILED", message: err?.localizedDescription, details: nil))
                            return
                        }
                        self.isCapturing = true
                        self.capturedDisplayID = targetDisplay.displayID
                        self.startTimer(encoder: encoder)
                        result([
                            "displayID": Int(targetDisplay.displayID),
                            "hardware": hardware,
                            "fellBack": fellBack,
                        ])
                    }
                }
            } catch {
                fail(FlutterError(code: "ADD_OUTPUT_FAILED", message: error.localizedDescription, details: nil))
            }
        }
    }

    /// Picks the display to capture and calls back on the main thread, with a
    /// nil display if the lookup failed or capture was stopped meanwhile.
    /// Extend (`virtualID` ≠ 0): this session's virtual display. A just-created
    /// one can take a moment to appear in ScreenCaptureKit's list, so re-poll
    /// for ~1.5 s before falling back to the main display (`fellBack`, and
    /// the virtual display nothing would show is released). Mirror: the main
    /// display (CGMainDisplayID, the one with the menu bar), rather than
    /// whichever display ScreenCaptureKit happens to list first.
    private func findCaptureDisplay(virtualID: CGDirectDisplayID, generation: Int, attempt: Int,
                                    completion: @escaping (SCDisplay?, Bool, Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self = self, generation == self.captureGeneration else {
                    completion(nil, false, nil)
                    return
                }
                guard let content = content, error == nil else {
                    completion(nil, false, error)
                    return
                }
                if virtualID != 0 {
                    if let vd = content.displays.first(where: { $0.displayID == virtualID }) {
                        esLog("\(self.tag) Capturing virtual display \(virtualID)")
                        completion(vd, false, nil)
                        return
                    }
                    if attempt < Self.virtualDisplayLookupRetries {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.virtualDisplayLookupDelay) {
                            self.findCaptureDisplay(virtualID: virtualID, generation: generation,
                                                    attempt: attempt + 1, completion: completion)
                        }
                        return
                    }
                }
                let mainID = CGMainDisplayID()
                guard let main = content.displays.first(where: { $0.displayID == mainID })
                        ?? content.displays.first else {
                    completion(nil, false, nil)
                    return
                }
                if virtualID != 0 {
                    let waited = Double(Self.virtualDisplayLookupRetries) * Self.virtualDisplayLookupDelay
                    esLog("\(self.tag) WARNING: virtual display \(virtualID) still not in ScreenCaptureKit's display list after \(waited)s; falling back to display \(main.displayID). Extend is NOT active: the tablet mirrors that display, and the virtual display is released.")
                    // Nothing shows the virtual display now, so drop it: left
                    // attached, the cursor and windows could move onto a
                    // screen neither the Mac nor the tablet displays.
                    if self.virtualDisplayID == virtualID {
                        self.virtualDisplay = nil
                        self.virtualDisplayID = 0
                    }
                    completion(main, true, nil)
                    return
                }
                esLog("\(self.tag) Capturing main display \(main.displayID)")
                completion(main, false, nil)
            }
        }
    }

    /// Stops the capture and calls back once its timer thread has ended (at
    /// most ~1 s) and its encoder is gone, so a start that follows never
    /// overlaps it.
    func stopCapture(completion: @escaping () -> Void) {
        isCapturing = false
        captureGeneration += 1  // a start still in flight now gives up
        capturedDisplayID = 0
        contentRect.reset()
        plugin?.setStreaming(id, false)
        let run = timerRun
        timerRun = nil
        run?.stop()  // first, so no new encodes start during teardown
        if let s = stream {
            try? s.removeStreamOutput(self, type: .screen)
            s.stopCapture { _ in }
        }
        stream = nil
        bufferLock.lock(); latestPixelBuffer = nil; bufferLock.unlock()
        let encoder = compressionSession
        compressionSession = nil
        let tag = self.tag
        DispatchQueue.global(qos: .userInitiated).async {
            if let run = run, run.done.wait(timeout: .now() + 1) == .timedOut {
                esLog("\(tag) WARNING: the encode timer did not stop within 1 s")
            }
            if let encoder = encoder { VTCompressionSessionInvalidate(encoder) }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Stops everything this session holds: capture, encoder, virtual
    /// display. Holds the session (the registry no longer does) until its
    /// display is gone.
    func dispose(completion: @escaping () -> Void) {
        stopCapture {
            self.removeVirtualDisplay(completion: completion)
        }
    }

    // MARK: - Encode timer

    private func startTimer(encoder: VTCompressionSession) {
        diagLastLog = Date()
        OSAtomicAnd32(0, &diagSckCount); OSAtomicAnd32(0, &diagEncCount)
        OSAtomicAnd32(0, &diagDropCount); OSAtomicAnd32(0, &diagTickCount)
        // A dedicated real-time Mach thread — mach_wait_until gives
        // nanosecond-accurate wakeups independent of GCD's ~60fps scheduler cap.
        let run = TimerRun()
        timerRun = run
        let t = Thread { [weak self] in
            defer { run.done.signal() }
            self?.timerLoop(run: run, encoder: encoder)
        }
        t.qualityOfService = .userInteractive
        t.threadPriority = 1.0
        t.start()
    }

    private func timerLoop(run: TimerRun, encoder: VTCompressionSession) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // Apple Silicon ticks at 24 MHz (numer/denom = 125/3); Intel is 1/1.
        // Recomputed every tick so adaptFrameRate can change the rate live.
        func currentInterval() -> UInt64 {
            let intervalNs = UInt64(1_000_000_000) / UInt64(max(targetFps, 1))
            return intervalNs * UInt64(info.denom) / UInt64(info.numer)
        }
        esLog("\(tag) timer: targetFps=\(targetFps) adaptive=\(adaptiveFps) numer=\(info.numer) denom=\(info.denom)")

        var next = mach_absolute_time() + currentInterval()
        var loopCount: Int32 = 0
        var loopStart = mach_absolute_time()
        while run.isRunning {
            // mach_wait_until can return before the deadline when the wait is
            // interrupted; ticking on every return let the loop run at ~139/s
            // against a 120 target. Only tick once the deadline has passed.
            while run.isRunning && mach_absolute_time() < next {
                mach_wait_until(next)
            }
            guard run.isRunning else { break }
            let intervalMach = currentInterval()
            next += intervalMach
            // After a stall, resync instead of bursting to catch up.
            let now = mach_absolute_time()
            if next < now { next = now + intervalMach }
            loopCount += 1
            let elapsedNs = (mach_absolute_time() - loopStart) * UInt64(info.numer) / UInt64(info.denom)
            if elapsedNs >= 1_000_000_000 {
                esLog("\(tag) loopRate=\(loopCount)/s")
                loopCount = 0
                loopStart = mach_absolute_time()
            }
            onTick(encoder, run: run)
        }
    }

    private func onTick(_ encoder: VTCompressionSession, run: TimerRun) {
        OSAtomicIncrement32(&diagTickCount)
        // Diagnostic log every 1s (happens regardless of encode)
        let now = Date()
        let diagElapsed = now.timeIntervalSince(diagLastLog)
        if diagElapsed >= 1.0 {
            let sck  = OSAtomicAdd32(0, &diagSckCount);  OSAtomicAnd32(0, &diagSckCount)
            let enc  = OSAtomicAdd32(0, &diagEncCount);  OSAtomicAnd32(0, &diagEncCount)
            let drp  = OSAtomicAdd32(0, &diagDropCount); OSAtomicAnd32(0, &diagDropCount)
            let tick = OSAtomicAdd32(0, &diagTickCount); OSAtomicAnd32(0, &diagTickCount)
            let pendingNow = run.inFlight.current
            esLog("\(tag) diag: tick=\(tick)/s  SCK=\(sck)/s  encoded=\(enc)/s  skipped=\(drp)/s  pending=\(pendingNow)")
            diagLastLog = now
            if adaptiveFps {
                adaptFrameRate(encoder, ticksPerSec: Double(tick) / diagElapsed,
                               skipped: drp, pending: pendingNow)
            }
        }
        applyRequestedBitrate(encoder)

        bufferLock.lock()
        let pixelBuffer = latestPixelBuffer
        bufferLock.unlock()

        guard let pb = pixelBuffer else { return }

        // Stamp each encode with the host clock at submission, not the SCK
        // frame's PTS. On an idle screen SCK stops delivering, so that PTS
        // froze while this timer re-encoded the last frame, then leapt forward
        // by the whole idle time on the next change. VT paces/provisions the
        // hardware from these timestamps: an M3 Pro's HEVC session dropped
        // from ~120 fps to ~18–40 fps after one such leap and never recovered
        // — the "laggy after leaving it a while" bug.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())

        if run.inFlight.current >= Self.maxPendingEncodeFrames {
            OSAtomicIncrement32(&diagDropCount)
            return
        }

        lock.lock()
        let keyframe = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let frameProps: CFDictionary? = keyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        OSAtomicIncrement32(&diagEncCount)
        let counter = run.inFlight
        counter.increment()
        // Call VT directly on the timer thread — no serial queue bottleneck.
        // VTCompressionSessionEncodeFrame submits to the hardware and fires
        // its callback on a VT-internal thread.
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pb,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            counter.decrement()
            guard status == noErr, let encoded = encodedBuffer else { return }
            self?.handleEncodedFrame(encoded)
        }
        // Refused outright (an encoder a sleep invalidated, say): its handler
        // never runs, so it is not in flight.
        if status != noErr {
            counter.decrement()
            if !run.reportedEncodeError {
                run.reportedEncodeError = true
                esLog("\(tag) WARNING: the encoder refused a frame (status \(status))")
            }
        }
    }

    /// "Max" preset: capture starts at the tablet's top refresh rate, which can
    /// be well past what this Mac encodes at the tablet's native resolution
    /// (an M3 Pro's H.264 session saturates around 50 fps at 2960×1848; HEVC
    /// manages ~2× that). A saturated VT session doesn't drop frames: once ~8
    /// are in flight, EncodeFrame blocks the timer thread. So overload shows as
    /// the queue pinned near that cap (every queued frame is a frame of added
    /// latency) or the timer losing ticks to blocked encode calls — the skip
    /// counter alone never trips. After 3 such seconds, drop straight to the
    /// highest rate that fits in 95% of the throughput actually achieved, so
    /// the queue drains; stepping one notch at a time spent seconds at ~190 ms
    /// of latency per notch and fell from a marginal 60 all the way to 30.
    /// After [stepUpDelay] healthy seconds, step back up one notch. A step-up
    /// that fails within 30 s doubles the delay before the next try (capped
    /// at 5 min), so a rate that really doesn't fit isn't retried in a loop.
    private func adaptFrameRate(_ encoder: VTCompressionSession, ticksPerSec: Double,
                                skipped: Int32, pending: Int32) {
        let overloaded = skipped > 0
            || pending >= Self.maxPendingEncodeFrames - 3
            || ticksPerSec < Double(targetFps) * 0.9
        if overloaded {
            overloadStreak += 1
            overloadTickSum += ticksPerSec
        } else {
            overloadStreak = 0
            overloadTickSum = 0
        }
        healthyStreak = !overloaded && pending <= 4 ? healthyStreak + 1 : 0

        let rates = Set(Self.adaptiveRates + [maxFps]).filter { $0 <= maxFps }.sorted()
        let achieved = overloadStreak > 0 ? overloadTickSum / Double(overloadStreak) : 0
        let fits = rates.last(where: { $0 < targetFps && Double($0) <= achieved * 0.95 })
        if overloadStreak >= 3, let lower = fits ?? rates.first(where: { $0 < targetFps }) {
            if let up = lastStepUpAt, Date().timeIntervalSince(up) < 30 {
                stepUpDelay = min(stepUpDelay * 2, 300)
            }
            setAdaptiveRate(encoder, lower,
                            reason: String(format: "encoder can't keep up (%.0f fps achieved)", achieved))
        } else if healthyStreak >= stepUpDelay,
                  let higher = rates.first(where: { $0 > targetFps }) {
            lastStepUpAt = Date()
            setAdaptiveRate(encoder, higher, reason: "encoder recovered")
        }
    }

    /// Timer thread: hands the encoder a bitrate setBitrate left waiting. VT
    /// rate control takes it from the next frame on; nothing is rebuilt and
    /// no keyframe is forced.
    private func applyRequestedBitrate(_ encoder: VTCompressionSession) {
        lock.lock()
        let requested = requestedBitrate
        let current = encoderBitrate
        requestedBitrate = 0
        lock.unlock()
        guard requested > 0, requested != current else { return }
        let status = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate,
                                          value: NSNumber(value: requested))
        if status == noErr {
            esLog("\(tag) bitrate: \(current / 1000) → \(requested / 1000) kbps (fitting the Wi-Fi link)")
            lock.lock()
            encoderBitrate = requested
            lock.unlock()
        } else {
            esLog("\(tag) WARNING bitrate \(requested / 1000) kbps not applied (status \(status))")
        }
    }

    private func setAdaptiveRate(_ encoder: VTCompressionSession, _ fps: Int, reason: String) {
        overloadStreak = 0
        overloadTickSum = 0
        healthyStreak = 0
        targetFps = fps
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        esLog("\(tag) adaptive: \(reason) — now \(fps) fps (next step-up after \(stepUpDelay)s healthy)")
        let id = self.id
        DispatchQueue.main.async { [weak self] in
            self?.plugin?.invoke("onFrameRateChanged", ["session": id, "fps": fps])
        }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pw = CVPixelBufferGetWidth(pixelBuffer)
        let ph = CVPixelBufferGetHeight(pixelBuffer)
        if frameCount == 0 {
            esLog("\(tag) First frame pixel size: \(pw)x\(ph)")
        }
        trackContentRect(sampleBuffer, pixelWidth: pw, pixelHeight: ph)
        frameCount += 1
        OSAtomicIncrement32(&diagSckCount)

        // Store latest frame; the timer tick drives the actual encode (and
        // stamps it — see onTick).
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }

    /// Publishes where the display's picture sits in this frame (see
    /// CaptureContentRect). Per the SDK header, SCStreamFrameInfo.contentRect
    /// is in points of the output surface and scaleFactor is the pixel-to-
    /// point factor, so rect × scaleFactor is in the buffer's pixels. Should a
    /// macOS release report pixels instead, the scaled rect overflows the
    /// frame and the unscaled one is used. Runs on the capture queue.
    private func trackContentRect(_ sampleBuffer: CMSampleBuffer, pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              let info = (attachments as NSArray).firstObject as? NSDictionary,
              let rectDict = info[SCStreamFrameInfo.contentRect.rawValue] as? NSDictionary,
              let raw = CGRect(dictionaryRepresentation: rectDict as CFDictionary),
              raw.width > 0, raw.height > 0 else { return }
        var scale = (info[SCStreamFrameInfo.scaleFactor.rawValue] as? NSNumber)?.doubleValue ?? 1
        if !scale.isFinite || scale <= 0 { scale = 1 }
        let fw = CGFloat(pixelWidth), fh = CGFloat(pixelHeight)
        let tolerance: CGFloat = 0.01
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for factor in [CGFloat(scale), 1] {
            let r = CGRect(x: raw.minX * factor / fw, y: raw.minY * factor / fh,
                           width: raw.width * factor / fw, height: raw.height * factor / fh)
            guard r.minX >= -tolerance, r.minY >= -tolerance,
                  r.maxX <= 1 + tolerance, r.maxY <= 1 + tolerance else { continue }
            let normalized = r.intersection(unit)
            guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return }
            if contentRect.update(normalized) {
                esLog(String(format: "%@ Content rect in frame: x=%.4f y=%.4f w=%.4f h=%.4f (SCK %.1f,%.1f %.1fx%.1f pt, scaleFactor %.2f, frame %ldx%ld)",
                             tag,
                             Double(normalized.minX), Double(normalized.minY),
                             Double(normalized.width), Double(normalized.height),
                             Double(raw.minX), Double(raw.minY), Double(raw.width), Double(raw.height),
                             scale, pixelWidth, pixelHeight))
            }
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let id = self.id
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            self?.plugin?.invoke("onStreamStopped", ["session": id, "error": message])
        }
    }

    // MARK: - VideoToolbox Encoder

    /// Makes this session's encoder. Returns whether it runs on the
    /// hardware, or an error: ENCODER_BUSY (the hardware encoder is taken),
    /// NO_ENCODER (none fits) or ENCODER_FAILED.
    private func setupEncoder(width: Int, height: Int, fps: Int, bitrate: Int, codec: String,
                              requireHardware: Bool) -> (hardware: Bool, error: FlutterError?) {
        var session: VTCompressionSession?
        let isHEVC = codec == "h265"
        let codecType: CMVideoCodecType = isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let spec: [CFString: Any] = requireHardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            let code: String
            switch status {
            case kVTVideoEncoderNotAvailableNowErr: code = "ENCODER_BUSY"
            case kVTCouldNotFindVideoEncoderErr: code = "NO_ENCODER"
            default: code = "ENCODER_FAILED"
            }
            esLog("\(tag) WARNING: no \(isHEVC ? "HEVC" : "H264") encoder for \(width)x\(height) (status \(status), \(code), hardware \(requireHardware ? "required" : "preferred"))")
            return (false, FlutterError(code: code, message: "VTCompressionSessionCreate failed (\(status))",
                                        details: nil))
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if isHEVC {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,     value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            // Baseline+CAVLC: lowest decode complexity on Android MediaCodec.
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,     value: kVTProfileLevel_H264_Baseline_AutoLevel)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode,  value: kVTH264EntropyMode_CAVLC)
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(s)

        var usingHardware: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &usingHardware)
        let hardware = (usingHardware as? Bool) ?? false

        // A new encoder runs at the bitrate it was made with; a value set for
        // the previous one does not carry over. Its first frame is a keyframe.
        lock.lock()
        requestedBitrate = 0
        encoderBitrate = bitrate
        forceKeyframe = true
        lock.unlock()
        compressionSession = s
        esLog("\(tag) Encoder: \(isHEVC ? "HEVC" : "H264") \(width)x\(height) \(fps)fps \(bitrate/1000)kbps hardware=\(hardware)")
        return (hardware, nil)
    }

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// Runs on VideoToolbox's callback thread: the frame as Annex-B, behind
    /// this session's id (4 bytes, big-endian), handed to the main thread.
    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Detect keyframe (IDR) via sample attachments.
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let notSync = CFDictionaryContainsKey(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            isKeyframe = !notSync
        }

        var out = Data()
        var sessionID = UInt32(truncatingIfNeeded: id).bigEndian
        withUnsafeBytes(of: &sessionID) { out.append(contentsOf: $0) }

        // On keyframes, prepend parameter sets (SPS/PPS for H264; VPS/SPS/PPS for HEVC).
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let isHEVC = CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC
            var count = 0
            if isHEVC {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for i in 0..<count {
                    var psPtr: UnsafePointer<UInt8>?; var psSize = 0
                    if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psSize, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr, let p = psPtr {
                        out.append(contentsOf: Self.startCode)
                        out.append(p, count: psSize)
                    }
                }
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for i in 0..<count {
                    var psPtr: UnsafePointer<UInt8>?; var psSize = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psSize, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr, let p = psPtr {
                        out.append(contentsOf: Self.startCode)
                        out.append(p, count: psSize)
                    }
                }
            }
        }

        // Convert AVCC (4-byte length prefixes) → Annex-B (start codes).
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, length > 4 else { return }
        let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)

        var offset = 0
        while offset < length - 4 {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, bytes + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4
            if offset + Int(nalLength) > length { break }
            out.append(contentsOf: Self.startCode)
            out.append(bytes + offset, count: Int(nalLength))
            offset += Int(nalLength)
        }

        let payload = out
        // FlutterEventSink must be called on the platform (main) thread.
        DispatchQueue.main.async { [weak self] in
            self?.plugin?.emitFrame(payload)
        }
    }
}
