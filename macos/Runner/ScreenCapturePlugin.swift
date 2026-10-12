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

@available(macOS 12.3, *)
private class ScreenCapturePluginImpl: NSObject, SCStreamDelegate, SCStreamOutput, FlutterStreamHandler {

    private static let channelName = "extended_screen/screen_capture"
    private static let frameChannelName = "extended_screen/frames"
    private var channel: FlutterMethodChannel?
    private var frameSink: FlutterEventSink?
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    // CGVirtualDisplay / CGVirtualDisplayDescriptor available macOS 12.4+ only;
    // stored as AnyObject to compile at 10.15 deployment target.
    private var virtualDisplay: AnyObject?
    private var virtualDisplayID: CGDirectDisplayID = 0
    private var forceKeyframe = true  // first encoded frame is always an IDR
    private var frameCount = 0
    // True between a successful startCapture and stopCapture. Gates the wake
    // handler so we only rebuild the pipeline when a session is actually live.
    private var isCapturing = false
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
    // Keeps macOS from App-Napping the (usually hidden) host while it streams:
    // throttled timers/priority stalled encoding for seconds at a time.
    private var captureActivity: NSObjectProtocol?
    // Counts frames dispatched to encodeQueue but not yet returned.
    // If this grows beyond the threshold we skip the incoming frame to bound latency.
    private var pendingEncodeFrames: Int32 = 0
    private static let maxPendingEncodeFrames: Int32 = 10

    // High-resolution Mach thread drives encode at exactly targetFps.
    // GCD DispatchSourceTimer is capped by the OS at ~60fps; mach_wait_until bypasses this.
    private var encodeTimer: DispatchSourceTimer?
    private var machThread: Thread?
    private var machThreadRunning = false
    // Bumped on every start/stop so a timer thread still inside mach_wait_until
    // exits even if capture restarts before it wakes (a stop→start within one
    // interval used to leave two timer threads encoding in parallel).
    private var timerGeneration = 0
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    // Diagnostic counters.
    private var diagSckCount: Int32 = 0
    private var diagEncCount: Int32 = 0
    private var diagDropCount: Int32 = 0
    private var diagTickCount: Int32 = 0   // timer ticks per second
    private var diagLastLog = Date()

    private let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
    private let encodeQueue  = DispatchQueue(label: "encode",  qos: .userInteractive)
    private let timerQueue   = DispatchQueue(label: "timer",   qos: .userInteractive)

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = ScreenCapturePluginImpl()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        plugin.channel = ch
        ch.setMethodCallHandler(plugin.handle)

        let frameCh = FlutterEventChannel(name: frameChannelName, binaryMessenger: messenger)
        frameCh.setStreamHandler(plugin)

        plugin.observeSystemWake()
    }

    // MARK: - Sleep / Wake recovery

    // A sleep/wake cycle invalidates ScreenCaptureKit, the CGVirtualDisplay and
    // the VideoToolbox session, but the ADB-reverse socket (USB) survives — so
    // the Dart heartbeat/reconnect never fires and the pipeline stays dead. On
    // wake we ask Dart to rebuild the whole thing (Dart owns the orchestration:
    // virtual display → SCK → encoder → control packets).
    private func observeSystemWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Rearranging displays (or changing resolution/scaling) in System
        // Settings → Displays doesn't invalidate the capture session, but it
        // does move the virtual display's screen-space origin — which Dart
        // caches to map tablet touch coordinates onto the real screen. Ask it
        // to refetch the bounds so touch keeps landing in the right place.
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        guard isCapturing else { return }
        channel?.invokeMethod("onDisplayBoundsChanged", arguments: nil)
    }

    @objc private func systemDidWake(_ note: Notification) {
        guard isCapturing else { return }
        esLog("[ExtendedScreen] Wake (\(note.name.rawValue)) — scheduling capture restart")
        // Give the GPU/displays a moment to come back before rebuilding. The
        // display-wake and system-wake notifications both fire on resume; the
        // Dart side coalesces the two rebuild requests.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.isCapturing else { return }
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

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermission":
            requestPermission(result: result)
        case "startCapture":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            startCapture(args: args, result: result)
        case "stopCapture":
            stopCapture()
            result(nil)
        case "requestIdr":
            forceKeyframe = true
            result(nil)
        case "createVirtualDisplay":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: nil, details: nil))
                return
            }
            createVirtualDisplay(args: args, result: result)
        case "removeVirtualDisplay":
            virtualDisplay = nil
            virtualDisplayID = 0
            result(nil)
        case "getVirtualDisplayBounds":
            let displayID = virtualDisplayID != 0 ? virtualDisplayID : CGMainDisplayID()
            let rect = CGDisplayBounds(displayID)
            result([
                "x": rect.origin.x,
                "y": rect.origin.y,
                "w": rect.width,
                "h": rect.height,
            ])
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

    // MARK: - Virtual Display (Extend Mode)

    private func createVirtualDisplay(args: [String: Any], result: @escaping FlutterResult) {
        // Release any previous virtual display first so the system reclaims it
        // before we allocate a new one (double-alloc causes id=0 / applied=false).
        virtualDisplay = nil
        virtualDisplayID = 0

        // Small delay to let the OS fully remove the previous display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }

            // w/h are the LOGICAL desktop points (the client panel ÷ 2).
            // Physical pixel buffer = w*2 × h*2 — the client's native panel.
            let w = args["width"]  as? Int ?? 1280
            let h = args["height"] as? Int ?? 800
            let r = args["refreshRate"] as? Int ?? 60
            let pw = w * 2, ph = h * 2  // physical pixels

            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.queue = DispatchQueue.global(qos: .userInteractive)
            descriptor.name = "Extended Screen"
            descriptor.maxPixelsWide = UInt32(pw)
            descriptor.maxPixelsHigh = UInt32(ph)
            // ~220 PPI → macOS treats this as a Retina display and applies 2x
            // HiDPI scaling: logical w×h points, physical pw×ph pixels.
            let mmW = CGFloat(w) / 220.0 * 25.4
            let mmH = CGFloat(h) / 220.0 * 25.4
            descriptor.sizeInMillimeters = CGSize(width: mmW, height: mmH)
            descriptor.productID = 0x1234
            descriptor.vendorID  = 0x3456
            descriptor.serialNum = 0x0001
            descriptor.terminationHandler = { _, _ in }

            let display = CGVirtualDisplay(descriptor: descriptor)

            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = 1  // 2x Retina: logical w×h → physical pw×ph
            let mode = CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h),
                                            refreshRate: Double(r))
            settings.modes = [mode]

            let ok = display.apply(settings)
            self.virtualDisplay = display
            self.virtualDisplayID = display.displayID
            esLog("[ExtendedScreen] Virtual display created id=\(display.displayID) applied=\(ok)")
            result(ok)
        }
    }

    // MARK: - Screen Capture

    private func startCapture(args: [String: Any], result: @escaping FlutterResult) {
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
        targetFps = fps
        maxFps = fps
        adaptiveFps = args["adaptiveFps"] as? Bool ?? false
        overloadStreak = 0
        overloadTickSum = 0
        healthyStreak = 0
        stepUpDelay = 10
        lastStepUpAt = nil
        if captureActivity == nil {
            captureActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Streaming the screen to the tablet")
        }

        setupEncoder(width: w, height: h, fps: fps, bitrate: br, codec: codec)

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let content = content, error == nil else {
                DispatchQueue.main.async { result(FlutterError(code: "SCK_ERROR", message: error?.localizedDescription, details: nil)) }
                return
            }
            // Target the virtual display (Extend mode) if one was created;
            // otherwise fall back to the main display (Mirror mode).
            let targetDisplay: SCDisplay
            if self.virtualDisplayID != 0,
               let vd = content.displays.first(where: { $0.displayID == self.virtualDisplayID }) {
                targetDisplay = vd
                esLog("[ExtendedScreen] Capturing virtual display \(self.virtualDisplayID)")
            } else if let main = content.displays.first {
                targetDisplay = main
                esLog("[ExtendedScreen] Capturing main display \(main.displayID)")
            } else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_DISPLAY", message: "No display to capture", details: nil))
                }
                return
            }

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
            self.stream = SCStream(filter: filter, configuration: config, delegate: self)

            do {
                try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.stream?.startCapture { [weak self] err in
                    DispatchQueue.main.async {
                        if err == nil {
                            self?.isCapturing = true
                            self?.startDisplayLink(displayID: targetDisplay.displayID)
                        }
                        result(err == nil ? nil : FlutterError(code: "START_FAILED", message: err?.localizedDescription, details: nil))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ADD_OUTPUT_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func startDisplayLink(displayID: CGDirectDisplayID) {
        stopDisplayLink()
        // Fresh diag window: a stale one (from before this capture) reads as
        // ~0 ticks/s, which adaptFrameRate would average into the throughput.
        diagLastLog = Date()
        OSAtomicAnd32(0, &diagSckCount); OSAtomicAnd32(0, &diagEncCount)
        OSAtomicAnd32(0, &diagDropCount); OSAtomicAnd32(0, &diagTickCount)
        // Use a dedicated real-time Mach thread — mach_wait_until gives nanosecond-accurate
        // wakeups independent of GCD's ~60fps scheduler cap.
        machThreadRunning = true
        timerGeneration += 1
        let generation = timerGeneration
        let t = Thread { [weak self] in self?.machTimerLoop(generation: generation) }
        t.qualityOfService = .userInteractive
        t.threadPriority = 1.0
        t.start()
        machThread = t
    }

    private func stopDisplayLink() {
        machThreadRunning = false
        timerGeneration += 1
        machThread = nil
        encodeTimer?.cancel()
        encodeTimer = nil
        bufferLock.lock(); latestPixelBuffer = nil; bufferLock.unlock()
    }

    private func machTimerLoop(generation: Int) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // Apple Silicon ticks at 24 MHz (numer/denom = 125/3); Intel is 1/1.
        // Recomputed every tick so adaptFrameRate can change the rate live.
        func currentInterval() -> UInt64 {
            let intervalNs = UInt64(1_000_000_000) / UInt64(max(targetFps, 1))
            return intervalNs * UInt64(info.denom) / UInt64(info.numer)
        }
        esLog("[ExtendedScreen] machTimerLoop: targetFps=\(targetFps) adaptive=\(adaptiveFps) numer=\(info.numer) denom=\(info.denom)")

        var next = mach_absolute_time() + currentInterval()
        var loopCount: Int32 = 0
        var loopStart = mach_absolute_time()
        while machThreadRunning && generation == timerGeneration {
            // mach_wait_until can return before the deadline when the wait is
            // interrupted; ticking on every return let the loop run at ~139/s
            // against a 120 target. Only tick once the deadline has passed.
            while machThreadRunning && generation == timerGeneration
                    && mach_absolute_time() < next {
                mach_wait_until(next)
            }
            guard generation == timerGeneration else { break }
            let intervalMach = currentInterval()
            next += intervalMach
            // After a stall, resync instead of bursting to catch up.
            let now = mach_absolute_time()
            if next < now { next = now + intervalMach }
            OSAtomicIncrement32(&loopCount)
            // Log loop rate every ~1s independently of onDisplayLinkTick
            let elapsed = mach_absolute_time() - loopStart
            let elapsedNs = elapsed * UInt64(info.numer) / UInt64(info.denom)
            if elapsedNs >= 1_000_000_000 {
                esLog("[ExtendedScreen] loopRate=\(loopCount)/s")
                loopCount = 0
                loopStart = mach_absolute_time()
            }
            onDisplayLinkTick()
        }
    }

    private func onDisplayLinkTick() {
        OSAtomicIncrement32(&diagTickCount)
        // Diagnostic log every 1s (happens regardless of encode)
        let now = Date()
        let diagElapsed = now.timeIntervalSince(diagLastLog)
        if diagElapsed >= 1.0 {
            let sck  = OSAtomicAdd32(0, &diagSckCount);  OSAtomicAnd32(0, &diagSckCount)
            let enc  = OSAtomicAdd32(0, &diagEncCount);  OSAtomicAnd32(0, &diagEncCount)
            let drp  = OSAtomicAdd32(0, &diagDropCount); OSAtomicAnd32(0, &diagDropCount)
            let tick = OSAtomicAdd32(0, &diagTickCount); OSAtomicAnd32(0, &diagTickCount)
            let pendingNow = OSAtomicAdd32(0, &pendingEncodeFrames)
            esLog("[ExtendedScreen] diag: tick=\(tick)/s  SCK=\(sck)/s  encoded=\(enc)/s  skipped=\(drp)/s  pending=\(pendingNow)")
            diagLastLog = now
            if adaptiveFps {
                adaptFrameRate(ticksPerSec: Double(tick) / diagElapsed, skipped: drp, pending: pendingNow)
            }
        }
        guard let session = compressionSession else { return }

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

        let pending = OSAtomicAdd32(0, &pendingEncodeFrames)
        if pending >= Self.maxPendingEncodeFrames {
            OSAtomicIncrement32(&diagDropCount)
            return
        }

        var frameProps: CFDictionary? = nil
        if forceKeyframe {
            forceKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        OSAtomicIncrement32(&diagEncCount)
        OSAtomicIncrement32(&pendingEncodeFrames)
        // Call VT directly on the timer thread — no serial queue bottleneck.
        // VTCompressionSessionEncodeFrame is non-blocking (submits to hardware) and
        // fires its callback on a VT-internal thread, so this is safe.
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pb,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            OSAtomicDecrement32(&self!.pendingEncodeFrames)
            guard status == noErr, let encoded = encodedBuffer else { return }
            self?.handleEncodedFrame(encoded)
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
    private func adaptFrameRate(ticksPerSec: Double, skipped: Int32, pending: Int32) {
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
            setAdaptiveRate(lower, reason: String(format: "encoder can't keep up (%.0f fps achieved)", achieved))
        } else if healthyStreak >= stepUpDelay,
                  let higher = rates.first(where: { $0 > targetFps }) {
            lastStepUpAt = Date()
            setAdaptiveRate(higher, reason: "encoder recovered")
        }
    }

    private func setAdaptiveRate(_ fps: Int, reason: String) {
        overloadStreak = 0
        overloadTickSum = 0
        healthyStreak = 0
        targetFps = fps
        if let s = compressionSession {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                 value: NSNumber(value: fps))
        }
        esLog("[ExtendedScreen] adaptive: \(reason) — now \(fps) fps (next step-up after \(stepUpDelay)s healthy)")
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("onFrameRateChanged", arguments: fps)
        }
    }

    private func stopCapture() {
        isCapturing = false
        if let activity = captureActivity {
            ProcessInfo.processInfo.endActivity(activity)
            captureActivity = nil
        }
        stopDisplayLink()  // cancel timer first so no new encodes fire during teardown
        stream?.stopCapture { _ in }
        stream = nil
        frameCount = 0
        pendingEncodeFrames = 0
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if frameCount == 0 {
            let pw = CVPixelBufferGetWidth(pixelBuffer)
            let ph = CVPixelBufferGetHeight(pixelBuffer)
            esLog("[ExtendedScreen] First frame pixel size: \(pw)x\(ph)")
        }
        frameCount += 1
        OSAtomicIncrement32(&diagSckCount)

        // Store latest frame; the timer tick drives the actual encode (and
        // stamps it — see onDisplayLinkTick).
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        channel?.invokeMethod("onStreamStopped", arguments: error.localizedDescription)
    }

    // MARK: - VideoToolbox Encoder

    private func setupEncoder(width: Int, height: Int, fps: Int, bitrate: Int, codec: String) {
        var session: VTCompressionSession?
        let isHEVC = codec == "h265"
        let codecType: CMVideoCodecType = isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        VTCompressionSessionCreate(
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
        guard let s = session else { return }

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
        compressionSession = s
        esLog("[ExtendedScreen] Encoder: \(isHEVC ? "HEVC" : "H264") \(width)x\(height) \(fps)fps \(bitrate/1000)kbps")
    }

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

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
            self?.frameSink?(FlutterStandardTypedData(bytes: payload))
        }
    }
}

