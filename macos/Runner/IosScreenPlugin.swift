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
/// Nothing runs on the phone for this. Frames go straight into a Flutter
/// texture (no encode, no decode). The phone sends a frame only when its
/// screen changes, and none while it is locked or dark.
///
/// Channel `extended_screen/ios_screen`:
/// - `listDevices` → `[{id, name}]` (the capture devices of plugged-in iOS
///   devices; `id` is the capture device's uniqueID, not the UDID).
/// - `start {id}` → `{textureId}`; asks for the Camera permission first
///   (`PERMISSION_DENIED` when refused), `NO_DEVICE` when it is gone,
///   `START_FAILED` when the session will not take it (the running capture,
///   if any, is left as it was), `CANCELLED` when a newer start replaced it
///   while the Camera prompt was up.
/// - `stop` → stops the capture and unregisters the texture.
/// - `markProbe {id}` → whether a felt-latency probe was armed (false with no
///   frame yet, or a pixel format the sampler cannot read). Its start is
///   taken here, when the call arrives (`mach_absolute_time`), so both ends
///   are on one clock; see [ProbeGrid].
/// - to Dart: `onFrameSize {width, height}` (the first frame, and whenever
///   the size changes, which it does when the phone rotates), `onStopped`
///   (the device went away or the session failed), `onProbe {id, ms}` (the
///   first frame that differed from the probe's start, `ms` after it; `ms`
///   null when the probe gave up: nothing changed within 2 s, a newer probe
///   replaced it, or the capture stopped).
final class IosScreenPlugin: NSObject, FlutterTexture,
                             AVCaptureVideoDataOutputSampleBufferDelegate {
    static let channelName = "extended_screen/ios_screen"

    private let registrar: FlutterPluginRegistrar
    private let channel: FlutterMethodChannel
    private let queue = DispatchQueue(label: "ios-screen.capture")
    private var session: AVCaptureSession?
    /// The running capture's output (main thread).
    private var output: AVCaptureVideoDataOutput?
    /// The same, read by [captureOutput] on [queue] (under [lock]).
    private var currentOutput: AVCaptureOutput?
    /// A start waiting for the user's answer to the Camera prompt.
    private var pendingStart: (deviceId: String?, result: FlutterResult)?
    private var textureId: Int64?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []
    private static var allowed = false

    /// The probe armed, if any (under [lock]). Frames are sampled only
    /// while there is one.
    private var probe: (seq: Int, id: Int, t0: UInt64, grid: [UInt8])?
    /// Main thread: tells a probe's give-up timer whether it is still that
    /// probe's.
    private var probeSeq = 0
    /// A probe gives up when nothing changed within this.
    private static let probeTimeout: TimeInterval = 2

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
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
    private static func allowScreenCaptureDevices() {
        if allowed { return }
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

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "listDevices":
            Self.allowScreenCaptureDevices()
            result(Self.iosDevices().map {
                ["id": $0.uniqueID, "name": $0.localizedName]
            })
        case "start":
            let id = (call.arguments as? [String: Any])?["id"] as? String
            start(deviceId: id, result: result)
        case "stop":
            stop()
            result(nil)
        case "markProbe":
            let t0 = mach_absolute_time()
            let id = ((call.arguments as? [String: Any])?["id"] as? NSNumber)?.intValue ?? 0
            result(markProbe(id: id, t0: t0))
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

    /// Builds the new session in full before the running one is touched, so
    /// a start that fails leaves the running capture (and the texture Dart
    /// shows) as it was. Main thread.
    private func go(deviceId: String?, result: @escaping FlutterResult) {
        guard let device = Self.iosDevices().first(where: {
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            result(FlutterError(code: "START_FAILED",
                                message: "Cannot add the video output", details: nil))
            return
        }
        session.addOutput(output)
        stop()
        lock.lock(); currentOutput = output; lock.unlock()
        output.setSampleBufferDelegate(self, queue: queue)
        self.session = session
        self.output = output
        let id = registrar.textures.register(self)
        textureId = id
        lastSize = .zero
        observers = [
            NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionRuntimeError, object: session,
                queue: .main) { [weak self] _ in self?.stopped() },
            NotificationCenter.default.addObserver(
                forName: .AVCaptureDeviceWasDisconnected, object: device,
                queue: .main) { [weak self] _ in self?.stopped() },
        ]
        queue.async { session.startRunning() }
        result(["textureId": id])
    }

    private func stopped() {
        stop()
        channel.invokeMethod("onStopped", arguments: nil)
    }

    /// Main thread. Frames still in flight from the stopped output are
    /// dropped (see [captureOutput]), so nothing of this capture is kept
    /// after it, nor reaches the next capture's texture.
    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        if let session {
            queue.async { session.stopRunning() }
        }
        session = nil
        if let id = textureId { registrar.textures.unregisterTexture(id) }
        textureId = nil
        lock.lock()
        let armed = probe
        currentOutput = nil; latest = nil; probe = nil
        lock.unlock()
        if let armed { probeAnswer(id: armed.id, ms: nil) }
    }

    // MARK: - Felt-latency probe

    /// Arms a probe: the grid of the frame shown now, and [t0]. Main thread.
    private func markProbe(id: Int, t0: UInt64) -> Bool {
        probeSeq += 1
        let seq = probeSeq
        lock.lock()
        let replaced = probe
        var armed = false
        probe = nil
        if currentOutput != nil, let latest, let grid = ProbeGrid.sample(latest) {
            probe = (seq, id, t0, grid)
            armed = true
        }
        lock.unlock()
        if let replaced { probeAnswer(id: replaced.id, ms: nil) }
        guard armed else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.probe?.seq == seq ? self.probe : nil
            if stale != nil { self.probe = nil }
            self.lock.unlock()
            if let stale {
                esLog("[ExtendedScreen] probe id=\(stale.id) change=none (gave up after \(Int(Self.probeTimeout)) s)")
                self.probeAnswer(id: stale.id, ms: nil)
            }
        }
        return true
    }

    private func probeAnswer(id: Int, ms: Double?) {
        let value: Any = ms.map { $0 as Any } ?? NSNull()
        let send: () -> Void = { [weak self] in
            self?.channel.invokeMethod("onProbe", arguments: ["id": id, "ms": value])
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func millis(from t0: UInt64, to t1: UInt64) -> Double {
        guard t1 > t0 else { return 0 }
        let nanos = Double(t1 - t0) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1e6
    }

    // MARK: - Capture (on [queue])

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let arrived = mach_absolute_time()
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels),
                          height: CVPixelBufferGetHeight(pixels))
        // Only the current capture's frames, checked under the same lock
        // stop() clears it with: a frame of a stopped output is dropped.
        lock.lock()
        guard output === currentOutput else { lock.unlock(); return }
        latest = pixels
        let armed = probe
        lock.unlock()
        if let armed { checkProbe(armed, pixels: pixels, arrived: arrived) }
        DispatchQueue.main.async { [weak self] in
            // The output this frame came from must still be the running one:
            // otherwise it belongs to a capture stopped meanwhile, and its
            // size would be announced for the next capture's texture.
            guard let self, self.output === output, let id = self.textureId else { return }
            self.registrar.textures.textureFrameAvailable(id)
            if size != self.lastSize {
                self.lastSize = size
                self.channel.invokeMethod(
                    "onFrameSize",
                    arguments: ["width": Int(size.width), "height": Int(size.height)])
            }
        }
    }

    /// Capture queue, only while a probe is armed: the first frame that
    /// differs from the probe's grid ends it.
    private func checkProbe(_ armed: (seq: Int, id: Int, t0: UInt64, grid: [UInt8]),
                            pixels: CVPixelBuffer, arrived: UInt64) {
        guard let grid = ProbeGrid.sample(pixels),
              ProbeGrid.changed(armed.grid, grid) else { return }
        lock.lock()
        let mine = probe?.seq == armed.seq
        if mine { probe = nil }
        lock.unlock()
        guard mine else { return }
        let ms = Self.millis(from: armed.t0, to: arrived)
        esLog("[ExtendedScreen] probe id=\(armed.id) change=\(String(format: "%.1f", ms))")
        probeAnswer(id: armed.id, ms: ms)
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        guard let latest else { return nil }
        return Unmanaged.passRetained(latest)
    }
}

/// The felt-latency probe's picture of a frame: the brightness at the centre
/// of each cell of a [cols]×[rows] grid (each a 2×2 pixel average, so one
/// pixel of noise moves nothing), read from BGRA frames (the format today)
/// or from the luma plane of 420v/420f ones, so a baseline taken now stays
/// comparable once the capture asks for NV12. Two grids differ when the
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
