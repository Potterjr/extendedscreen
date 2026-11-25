import AVFoundation
import CoreMediaIO
import FlutterMacOS
import os

// The probe's lines, as public os_log entries like ScreenCapturePlugin's
// (NSLog's text shows only as "<private>" there), echoed to stderr:
//   log stream --predicate 'subsystem == "com.example.extendedscreen" AND category == "ios_screen"'
private let iosScreenLog = OSLog(subsystem: "com.example.extendedscreen", category: "ios_screen")

private func esLog(_ message: String) {
    os_log("%{public}@", log: iosScreenLog, type: .default, message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// The screen of an iPhone or iPad plugged in over USB, as macOS offers it to
/// QuickTime ("record the iPhone screen"): an AVFoundation capture device that
/// appears once CoreMediaIO is allowed to publish iOS screen-capture devices.
/// Nothing runs on the phone for this. Frames go straight to the device's
/// native remote window ([RemoteWindowPlugin]; no encode, no decode). The phone sends a frame only when its
/// screen changes, and none while it is locked or dark.
///
/// One capture per device ([IosCapture], keyed by the capture device's
/// uniqueID, the `id` of every call and callback): starting one device ends
/// no other's capture. Whether two muxed iOS devices can capture at once is
/// unproven; a second one that cannot run reports `onStopped` for its id.
///
/// Channel `extended_screen/ios_screen`:
/// - `listDevices` → `[{id, name}]` (the capture devices of plugged-in iOS
///   devices; `id` is the capture device's uniqueID, not the UDID).
/// - `start {id}` → `{id}` (`id` the device started: the first listed when
///   none was given). Its frames go to the device's native remote window
///   (420v where the output offers it, else BGRA), each enqueued on its
///   sample-buffer layer from the capture queue, or the session joined to
///   its preview layer. Asks for the
///   Camera permission first (`PERMISSION_DENIED` when refused), `NO_DEVICE`
///   when it is gone, `START_FAILED` when the session will not take it (that
///   device's running capture, if any, is left as it was), `CANCELLED` when
///   a newer start replaced it while the Camera prompt was up. A start for a
///   device already capturing replaces that capture.
/// - `stop {id}` → stops that device's capture; with no `id`, every capture.
/// - `prepare` → lets CoreMediaIO publish the devices now (the iPhone's
///   window calls it as it opens, before `listDevices`); true when this
///   call is what switched it on, so the devices may appear only a moment
///   later.
/// - `notePairing {udid, device?}` → logs the capture device's uniqueID
///   (`device`'s, else the only capture's) next to the touch link's usbmux
///   UDID (category `ios_screen`), so the two can be compared on a real
///   phone; nothing maps one to the other.
/// - `markProbe {device?, id, t0Us?}` → whether a felt-latency probe was armed
///   on `device`'s capture (with no `device`, the only capture's), `id` being
///   Dart's probe sequence number (false with no frame yet, no such capture,
///   or a pixel format the sampler cannot read). Its start is `t0Us` when
///   given (an input event's time, µs of system uptime, the clock of
///   `mach_absolute_time`), else the moment the call arrives, so both ends
///   are on one clock; see [ProbeGrid].
/// - to Dart: `onFrameSize {id, width, height}` (the first frame, and
///   whenever the size changes, which it does when the phone rotates),
///   `onStopped {id}` (the device went away or the session failed),
///   `onProbe {device, id, ms}` (the first frame that differed from the
///   probe's start, `ms` after it; `ms` null when the probe gave up: nothing
///   changed within 2 s, a newer probe on that capture replaced it, or the
///   capture stopped).
final class IosScreenPlugin: NSObject {
    static let channelName = "extended_screen/ios_screen"

    private let channel: FlutterMethodChannel
    /// The running captures by device uniqueID (main thread).
    private var captures: [String: IosCapture] = [:]
    /// A start waiting for the user's answer to the Camera prompt.
    private var pendingStart: (deviceId: String?, result: FlutterResult)?
    private static var allowed = false

    /// Main thread: numbers every probe armed, so a give-up timer can tell
    /// whether it is still its probe's.
    private var probeSeq = 0
    /// A probe gives up when nothing changed within this.
    private static let probeTimeout: TimeInterval = 2

    init(registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(
            name: Self.channelName, binaryMessenger: registrar.messenger)
        super.init()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = IosScreenPlugin(registrar: registrar)
        plugin.channel.setMethodCallHandler(plugin.handle)
    }

    /// Lets CoreMediaIO publish iOS screen-capture devices (off by default).
    /// The devices appear a moment later.
    /// True when this call switched it on.
    @discardableResult
    private static func allowScreenCaptureDevices() -> Bool {
        if allowed { return false }
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(
                kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allow)
        allowed = status == 0
        return allowed
    }

    private static func iosDevices() -> [AVCaptureDevice] {
        // `.external` from macOS 14; the deployment target is 12.
        let type: AVCaptureDevice.DeviceType
        if #available(macOS 14.0, *) {
            type = .external
        } else {
            type = .externalUnknown
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [type], mediaType: .muxed, position: .unspecified
        ).devices.filter { $0.modelID.contains("iOS") }
    }

    /// The pixel format the window is fed: 420v, which its layers show
    /// natively, when [output] offers it, else BGRA ([ProbeGrid] reads
    /// either).
    static func pixelFormat(output: AVCaptureVideoDataOutput? = nil) -> OSType {
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if output?.availableVideoPixelFormatTypes.contains(yuv) ?? true {
            return yuv
        }
        return kCVPixelFormatType_32BGRA
    }

    /// `device`'s capture, or with no `device` the only one running.
    private func capture(for device: String?) -> IosCapture? {
        if let device { return captures[device] }
        return captures.count == 1 ? captures.values.first : nil
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "listDevices":
            Self.allowScreenCaptureDevices()
            result(Self.iosDevices().map {
                ["id": $0.uniqueID, "name": $0.localizedName]
            })
        case "start":
            start(deviceId: args?["id"] as? String, result: result)
        case "stop":
            if let id = args?["id"] as? String {
                stop(id: id)
            } else {
                for id in Array(captures.keys) { stop(id: id) }
            }
            result(nil)
        case "prepare":
            result(Self.allowScreenCaptureDevices())
        case "notePairing":
            let udid = args?["udid"] as? String ?? "?"
            if let shown = capture(for: args?["device"] as? String) {
                esLog("[ExtendedScreen] pairing capture uniqueID=\(shown.id) "
                      + "name=\"\(shown.name)\" model=\(shown.model) usbmux UDID=\(udid) "
                      + "(same=\(shown.id == udid))")
            } else {
                esLog("[ExtendedScreen] pairing no capture running; usbmux UDID=\(udid)")
            }
            result(nil)
        case "markProbe":
            let arrived = mach_absolute_time()
            let id = (args?["id"] as? NSNumber)?.intValue ?? 0
            let t0Us = (args?["t0Us"] as? NSNumber)?.uint64Value
            result(markProbe(device: args?["device"] as? String, id: id,
                             arrived: arrived, t0Us: t0Us))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(deviceId: String?, result: @escaping FlutterResult) {
        Self.allowScreenCaptureDevices()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            go(deviceId: deviceId, result: result)
        case .notDetermined:
            // One Camera prompt at a time: a start made while it is up
            // replaces the one waiting (answered CANCELLED), so only the
            // newest one runs once the user answers.
            if let waiting = pendingStart {
                waiting.result(FlutterError(code: "CANCELLED",
                                            message: "Superseded by a newer start",
                                            details: nil))
                pendingStart = (deviceId, result)
                return
            }
            pendingStart = (deviceId, result)
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let pending = self.pendingStart else { return }
                    self.pendingStart = nil
                    if ok {
                        self.go(deviceId: pending.deviceId, result: pending.result)
                    } else {
                        pending.result(FlutterError(code: "PERMISSION_DENIED",
                                                    message: "Camera access denied",
                                                    details: nil))
                    }
                }
            }
        default:
            result(FlutterError(code: "PERMISSION_DENIED",
                                message: "Camera access denied", details: nil))
        }
    }

    /// Builds the new session in full before that device's running capture
    /// is touched, so a start that fails leaves it (and its window's
    /// picture) as it was. Other devices' captures are never touched. Main
    /// thread.
    private func go(deviceId: String?, result: @escaping FlutterResult) {
        let devices = Self.iosDevices()
        guard let device = devices.first(where: {
            deviceId == nil || $0.uniqueID == deviceId
        }) else {
            result(FlutterError(code: "NO_DEVICE",
                                message: "No iOS device on USB", details: nil))
            return
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            result(FlutterError(code: "START_FAILED",
                                message: error.localizedDescription, details: nil))
            return
        }
        // -addInput: raises an Objective-C exception (which Swift cannot
        // catch: the whole host would abort) for an input it refuses.
        guard session.canAddInput(input) else {
            result(FlutterError(code: "START_FAILED",
                                message: "Cannot add the device input", details: nil))
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Self.pixelFormat(output: output),
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            result(FlutterError(code: "START_FAILED",
                                message: "Cannot add the video output", details: nil))
            return
        }
        session.addOutput(output)
        let id = device.uniqueID
        stop(id: id)
        esLog("[ExtendedScreen] capture start uniqueID=\(id) "
              + "name=\"\(device.localizedName)\" model=\(device.modelID) "
              + "of \(devices.count) iOS capture device(s), "
              + "\(captures.count) other capture(s) running")
        let capture = IosCapture(owner: self, device: device, session: session,
                                 output: output)
        captures[id] = capture
        // A preview-layer window shows the session itself, joined before it
        // runs (the sample-buffer layer is fed from the capture queue).
        RemoteWindowPlugin.shared?.attach(session: session, id: id)
        capture.observers = [
            NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionRuntimeError, object: session,
                queue: .main) { [weak self, weak capture] _ in
                    if let capture { self?.stopped(capture) }
                },
            NotificationCenter.default.addObserver(
                forName: .AVCaptureDeviceWasDisconnected, object: device,
                queue: .main) { [weak self, weak capture] _ in
                    if let capture { self?.stopped(capture) }
                },
        ]
        capture.run()
        result(["id": id])
    }

    /// [capture] ended by itself: only if it is still its device's capture.
    private func stopped(_ capture: IosCapture) {
        guard captures[capture.id] === capture else { return }
        stop(id: capture.id)
        channel.invokeMethod("onStopped", arguments: ["id": capture.id])
    }

    /// Main thread. Frames still in flight from the stopped output are
    /// dropped (see [IosCapture.captureOutput]), so nothing of this capture
    /// is kept after it, nor reaches the next capture's window.
    private func stop(id: String) {
        guard let capture = captures.removeValue(forKey: id) else { return }
        RemoteWindowPlugin.shared?.detach(session: capture.captureSession, id: id)
        if let armed = capture.stop() { probeAnswer(device: id, id: armed, ms: nil) }
    }

    // MARK: - Called by a capture (main thread)

    /// A capture's frame of a new size (frames make no per-frame hop to the
    /// main thread).
    fileprivate func frameArrived(_ capture: IosCapture, size: CGSize) {
        guard captures[capture.id] === capture else { return }
        if size != capture.lastSize {
            capture.lastSize = size
            channel.invokeMethod(
                "onFrameSize",
                arguments: ["id": capture.id,
                            "width": Int(size.width), "height": Int(size.height)])
            RemoteWindowPlugin.shared?.frameSizeChanged(id: capture.id, size: size)
        }
    }

    fileprivate func probeAnswer(device: String, id: Int, ms: Double?) {
        let value: Any = ms.map { $0 as Any } ?? NSNull()
        let send: () -> Void = { [weak self] in
            self?.channel.invokeMethod(
                "onProbe", arguments: ["device": device, "id": id, "ms": value])
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    // MARK: - Felt-latency probe

    /// Arms a probe on [device]'s capture: the grid of the frame shown now,
    /// and its start ([t0Us] as mach ticks when given and not ahead of
    /// [arrived], else [arrived]). Main thread.
    private func markProbe(device: String?, id: Int, arrived: UInt64,
                           t0Us: UInt64?) -> Bool {
        guard let capture = capture(for: device) else { return false }
        probeSeq += 1
        let seq = probeSeq
        var t0 = arrived
        if let t0Us, t0Us > 0 {
            let ticks = IosCapture.ticks(fromMicros: t0Us)
            if ticks <= arrived { t0 = ticks }
        }
        let (armed, replaced) = capture.arm(seq: seq, id: id, t0: t0, arrived: arrived)
        if let replaced { probeAnswer(device: capture.id, id: replaced, ms: nil) }
        guard armed else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeTimeout) {
            [weak self, weak capture] in
            guard let self, let capture, let stale = capture.giveUp(seq: seq) else { return }
            esLog("[ExtendedScreen] probe device=\(capture.id) id=\(stale) change=none "
                  + "(gave up after \(Int(Self.probeTimeout)) s)")
            self.probeAnswer(device: capture.id, id: stale, ms: nil)
        }
        return true
    }
}

/// One device's capture: its session, output, capture queue, newest frame
/// (what a probe is armed from) and probe. [IosScreenPlugin] keeps one
/// per device uniqueID and owns its lifetime; everything but the frame path
/// runs on the main thread.
final class IosCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let id: String
    let name: String
    let model: String
    private weak var owner: IosScreenPlugin?
    private let session: AVCaptureSession
    /// Capture queue only: the size last announced.
    private var queueSize = CGSize.zero
    /// Frames delivered and dropped by the output (under [lock]).
    private var delivered = 0
    private var dropped = 0
    /// The output (main thread); nil once stopped.
    private var output: AVCaptureVideoDataOutput?
    /// The same, read by [captureOutput] on [queue] (under [lock]).
    private var currentOutput: AVCaptureOutput?
    private let queue: DispatchQueue
    /// Where [session] is started and stopped: its device's queue, the
    /// same one for every capture of that device in this run, so an old
    /// session's `stopRunning` always ends before its replacement's
    /// `startRunning` begins (the replacement in [IosScreenPlugin.go], or a
    /// stop and start from Dart back to back). Two running sessions on one
    /// muxed iOS screen device are not known to work. Kept apart from
    /// [queue], which only carries frames.
    private let sessionQueue: DispatchQueue
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    /// The probe armed, if any (under [lock]). Frames are sampled only
    /// while there is one. [arrived] is when the arming call reached Swift,
    /// logged beside [t0] when that was an input event's time.
    private var probe: (seq: Int, id: Int, t0: UInt64, arrived: UInt64, grid: [UInt8])?

    /// Main thread.
    var lastSize = CGSize.zero
    var observers: [NSObjectProtocol] = []

    init(owner: IosScreenPlugin, device: AVCaptureDevice,
         session: AVCaptureSession, output: AVCaptureVideoDataOutput) {
        id = device.uniqueID
        name = device.localizedName
        model = device.modelID
        self.owner = owner
        self.session = session
        self.output = output
        queue = DispatchQueue(label: "ios-screen.capture.\(device.uniqueID)")
        sessionQueue = Self.sessionQueue(for: device.uniqueID)
        super.init()
    }

    /// One serial queue per device uniqueID, made on first use and kept
    /// for the run (a capture's own queue is new each time, so it cannot
    /// order one capture after the last). Main thread.
    private static var sessionQueues: [String: DispatchQueue] = [:]

    static func sessionQueue(for deviceId: String) -> DispatchQueue {
        if let q = sessionQueues[deviceId] { return q }
        let q = DispatchQueue(label: "ios-screen.session.\(deviceId)")
        sessionQueues[deviceId] = q
        return q
    }

    /// The session (main thread): the window's preview layer shows it.
    var captureSession: AVCaptureSession { session }

    /// Starts delivering frames. Main thread.
    func run() {
        lock.lock(); currentOutput = output; lock.unlock()
        output?.setSampleBufferDelegate(self, queue: queue)
        let session = session
        sessionQueue.async { session.startRunning() }
    }

    /// Stops the session; answers the probe that was armed, if any, for the
    /// caller to give up. Main thread.
    func stop() -> Int? {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        let session = session
        sessionQueue.async { session.stopRunning() }
        lock.lock()
        let armed = probe
        currentOutput = nil; latest = nil; probe = nil
        let (got, lost) = (delivered, dropped)
        lock.unlock()
        esLog("[ExtendedScreen] capture stop uniqueID=\(id) "
              + "frames=\(got) dropped=\(lost)")
        return armed?.id
    }

    /// Arms a probe from the frame shown now. Answers whether it was armed,
    /// and the id of the probe it replaced (to be given up). Main thread.
    func arm(seq: Int, id probeId: Int, t0: UInt64, arrived: UInt64) -> (Bool, Int?) {
        lock.lock()
        let replaced = probe
        var armed = false
        probe = nil
        if currentOutput != nil, let latest, let grid = ProbeGrid.sample(latest) {
            probe = (seq, probeId, t0, arrived, grid)
            armed = true
        }
        lock.unlock()
        return (armed, replaced?.id)
    }

    /// Probe [seq], if it is still armed, given up: its id.
    func giveUp(seq: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let armed = probe, armed.seq == seq else { return nil }
        probe = nil
        return armed.id
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func millis(from t0: UInt64, to t1: UInt64) -> Double {
        guard t1 > t0 else { return 0 }
        let nanos = Double(t1 - t0) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1e6
    }

    /// Microseconds of system uptime (NSEvent.timestamp × 1e6) as
    /// `mach_absolute_time` ticks.
    static func ticks(fromMicros us: UInt64) -> UInt64 {
        UInt64(Double(us) * 1000 * Double(timebase.denom) / Double(timebase.numer))
    }

    // MARK: - Capture (on [queue])

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let arrived = mach_absolute_time()
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels),
                          height: CVPixelBufferGetHeight(pixels))
        // Only the current output's frames, checked under the same lock
        // stop() clears it with: a frame of a stopped output is dropped.
        lock.lock()
        guard output === currentOutput else { lock.unlock(); return }
        latest = pixels
        delivered += 1
        let armed = probe
        lock.unlock()
        // Straight onto the window's layer from this queue; the main
        // thread hears only of a new size (the aspect lock, Dart).
        if let sink = RemoteWindowPlugin.sink(for: id), sink.takesSampleBuffers {
            sink.enqueue(sampleBuffer)
        }
        if let armed { checkProbe(armed, pixels: pixels, arrived: arrived) }
        guard size != queueSize else { return }
        queueSize = size
        DispatchQueue.main.async { [weak self] in
            // The plugin checks this is still the device's running capture:
            // otherwise its size would be announced for the next capture.
            guard let self else { return }
            self.owner?.frameArrived(self, size: size)
        }
    }

    /// A frame the output dropped (late, or its pool ran dry): counted, and
    /// logged now and then. Capture queue.
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        guard output === currentOutput else { lock.unlock(); return }
        dropped += 1
        let (got, lost) = (delivered, dropped)
        lock.unlock()
        if lost == 1 || lost % 100 == 0 {
            esLog("[ExtendedScreen] capture uniqueID=\(id) dropped=\(lost) frames=\(got)")
        }
    }

    /// Capture queue, only while a probe is armed: the first frame that
    /// differs from the probe's grid ends it.
    private func checkProbe(_ armed: (seq: Int, id: Int, t0: UInt64, arrived: UInt64,
                                      grid: [UInt8]),
                            pixels: CVPixelBuffer, arrived: UInt64) {
        guard let grid = ProbeGrid.sample(pixels),
              ProbeGrid.changed(armed.grid, grid) else { return }
        lock.lock()
        let mine = probe?.seq == armed.seq
        if mine { probe = nil }
        lock.unlock()
        guard mine else { return }
        let ms = Self.millis(from: armed.t0, to: arrived)
        var line = "[ExtendedScreen] probe device=\(id) id=\(armed.id) "
            + "change=\(String(format: "%.1f", ms))"
        if armed.t0 != armed.arrived {
            // Started at an input event's time: also from the call's arrival,
            // the start the earlier numbers were measured from.
            let fromCall = Self.millis(from: armed.arrived, to: arrived)
            line += " (from call \(String(format: "%.1f", fromCall)))"
        }
        esLog(line)
        owner?.probeAnswer(device: id, id: armed.id, ms: ms)
    }
}

/// The felt-latency probe's picture of a frame: the brightness at the centre
/// of each cell of a [cols]×[rows] grid (each a 2×2 pixel average, so one
/// pixel of noise moves nothing), read from the luma plane of 420v/420f
/// frames (the window's format) or from BGRA ones (when the output offers
/// no 420v). Two grids differ when the
/// mean of the sample differences above [noiseFloor] reaches [threshold]
/// (in 0-255 levels): a tap's row highlight or a scroll passes it, the
/// status-bar clock (two or three samples) does not.
enum ProbeGrid {
    static let cols = 16
    static let rows = 32
    static let noiseFloor = 6
    static let threshold = 0.5

    static func sample(_ pixels: CVPixelBuffer) -> [UInt8]? {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let planar: Bool
        switch format {
        case kCVPixelFormatType_32BGRA:
            planar = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planar = true
        default:
            return nil
        }
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixels, 0)
                          : CVPixelBufferGetBaseAddress(pixels)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                            : CVPixelBufferGetBytesPerRow(pixels)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixels, 0)
                           : CVPixelBufferGetWidth(pixels)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixels, 0)
                            : CVPixelBufferGetHeight(pixels)
        guard let base, width >= 2, height >= 2 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        func level(_ x: Int, _ y: Int) -> Int {
            if planar { return Int(p[y * stride + x]) }
            let o = y * stride + x * 4 // B, G, R, A
            return (Int(p[o + 2]) * 77 + Int(p[o + 1]) * 150 + Int(p[o]) * 29) >> 8
        }
        var grid = [UInt8](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let y = min((2 * r + 1) * height / (2 * rows), height - 2)
            for c in 0..<cols {
                let x = min((2 * c + 1) * width / (2 * cols), width - 2)
                let sum = level(x, y) + level(x + 1, y) + level(x, y + 1) + level(x + 1, y + 1)
                grid[r * cols + c] = UInt8(sum / 4)
            }
        }
        return grid
    }

    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var sum = 0
        for i in a.indices {
            let d = abs(Int(a[i]) - Int(b[i]))
            if d >= noiseFloor { sum += d }
        }
        return Double(sum) / Double(a.count) >= threshold
    }
}
