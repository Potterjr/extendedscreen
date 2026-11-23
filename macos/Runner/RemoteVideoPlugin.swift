import Cocoa
import FlutterMacOS
import VideoToolbox
import CoreVideo
import os.log

// Public unified-log entries under the app's subsystem, like
// ScreenCapturePlugin's (NSLog's text shows only as "<private>" there), and
// echoed to stderr for the `flutter run` console.
private let remoteLog = OSLog(subsystem: "com.example.extendedscreen", category: "remote")

private func remoteLogLine(_ message: String) {
    os_log("%{public}@", log: remoteLog, type: .default, message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Reverse remote (Mac controls tablet): decodes the H.264/H.265 Annex-B streams
/// coming FROM the tablets via VideoToolbox and exposes each tablet's decoded
/// frames to Flutter as a `FlutterTexture`. The mirror image of the Android
/// `VideoDecoderPlugin`.
///
/// One decoder per session (the id Dart sends as `session`; none means 0).
/// NAL units arrive over a binary message channel (no codec overhead), each
/// message behind its session's id, 4 bytes big-endian. The encoder prepends
/// SPS/PPS to every keyframe, so a decoder can start from any of them; it
/// makes its decompression session from the first ones and again only when
/// a keyframe brings other parameter sets or the session has failed (see
/// `RemoteDecoder.checkSession`). A decoder fed pictures it cannot decode
/// (no session yet, or a decode error) asks for a keyframe with
/// `onRequestIdr {session}`, at most once a second. A decoder whose
/// decompression session cannot be made says so with
/// `onCodecError {session, error}`, and with `onDecoderReady {session}` the
/// first time one is made after that. While any decoder exists the plugin
/// holds an activity that keeps App Nap off the host, which is usually
/// hidden. Main thread: method calls, the registry and feeding; each
/// decoder's output lands on VideoToolbox's threads.
class RemoteVideoPlugin: NSObject {

    private static let channelName    = "extended_screen/remote_video"
    private static let nalChannelName = "extended_screen/remote_nal"

    private let registrar: FlutterPluginRegistrar
    private let channel: FlutterMethodChannel
    private var decoders: [Int: RemoteDecoder] = [:]
    // Held from the first decoder's initialize to the last one's dispose: a
    // Mac that only shows tablets' screens runs no capture, so nothing else
    // keeps App Nap from throttling the host once its window is hidden.
    private var decodeActivity: NSObjectProtocol?

    private init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        self.channel = FlutterMethodChannel(name: RemoteVideoPlugin.channelName,
                                            binaryMessenger: registrar.messenger)
        super.init()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = RemoteVideoPlugin(registrar: registrar)
        plugin.channel.setMethodCallHandler(plugin.handle)

        let nalChannel = FlutterBasicMessageChannel(
            name: nalChannelName,
            binaryMessenger: registrar.messenger,
            codec: FlutterBinaryCodec.sharedInstance())
        nalChannel.setMessageHandler { message, reply in
            if let data = message as? Data, data.count > 4 {
                let bytes = [UInt8](data)
                let id = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                             | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
                plugin.decoders[id]?.feedNal(Array(bytes[4...]))
            }
            reply(nil)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let id = args["session"] as? Int ?? 0
        switch call.method {
        case "initialize":
            // A session starting again gets a fresh decoder and texture.
            decoders.removeValue(forKey: id)?.teardown()
            let decoder = RemoteDecoder(
                id: id, isHEVC: (args["codec"] as? String) == "h265",
                registrar: registrar,
                anotherDecoderLive: { [weak self] in
                    self?.decoders.contains { $0.key != id } ?? false
                },
                onError: { [weak self] message in
                    self?.channel.invokeMethod("onCodecError", arguments: ["session": id, "error": message])
                },
                onReady: { [weak self] in
                    self?.channel.invokeMethod("onDecoderReady", arguments: ["session": id])
                },
                onRequestIdr: { [weak self] in
                    self?.channel.invokeMethod("onRequestIdr", arguments: ["session": id])
                })
            decoders[id] = decoder
            holdActivityWhileDecoding()
            result(NSNumber(value: decoder.register()))
        case "dispose":
            decoders.removeValue(forKey: id)?.teardown()
            holdActivityWhileDecoding()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Begins the activity with the first decoder and ends it with the last
    /// (the same options the capture plugin holds while it streams).
    private func holdActivityWhileDecoding() {
        if !decoders.isEmpty, decodeActivity == nil {
            decodeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Showing a tablet's screen")
        } else if decoders.isEmpty, let activity = decodeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            decodeActivity = nil
        }
    }
}

/// One tablet's decoder and the texture it renders into.
private final class RemoteDecoder: NSObject, FlutterTexture {
    private let id: Int
    private let registrar: FlutterPluginRegistrar
    // Whether another session's decoder exists right now (main thread).
    private let anotherDecoderLive: () -> Bool
    private let onError: (String) -> Void
    private let onReady: () -> Void
    private let onRequestIdr: () -> Void
    // An error was reported and no decompression session has been made
    // since: the next one made is reported too (main thread).
    private var reportedError = false
    private var textureId: Int64 = 0
    // When the tablet was last asked for a keyframe (main thread).
    private var lastKeyframeRequest: Date?
    private static let keyframeRequestInterval: TimeInterval = 1

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let isHEVC: Bool

    // The newest parameter sets the stream carried.
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    // The parameter sets `session` was made from; nil without a session.
    private var builtSets: [[UInt8]]?
    // Moves on with every session made or ended, so a decode callback of an
    // earlier session says nothing about the current one (main thread).
    private var sessionGen = 0
    // The current session's last decode error, noErr while it has had none.
    // A status that means the session itself is gone stays until the next
    // session is made. Main thread: the output callback's errors hop there.
    private var lastDecodeStatus: OSStatus = noErr
    // The status with which the current session refused a keyframe, noErr
    // while it has refused none. A session that cannot decode a picture that
    // needs nothing before it is not kept either (main thread).
    private var keyframeFailure: OSStatus = noErr

    // Guards latestPixelBuffer and alive: the decoder's output thread writes,
    // Flutter's raster thread reads, teardown (main) ends it.
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var alive = true

    init(id: Int, isHEVC: Bool, registrar: FlutterPluginRegistrar,
         anotherDecoderLive: @escaping () -> Bool,
         onError: @escaping (String) -> Void, onReady: @escaping () -> Void,
         onRequestIdr: @escaping () -> Void) {
        self.id = id
        self.isHEVC = isHEVC
        self.registrar = registrar
        self.anotherDecoderLive = anotherDecoderLive
        self.onError = onError
        self.onReady = onReady
        self.onRequestIdr = onRequestIdr
        super.init()
    }

    /// Registers the texture; returns its id. Frames flow in as NALs arrive.
    func register() -> Int64 {
        textureId = registrar.textures.register(self)
        return textureId
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        guard let buf = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buf)
    }

    // MARK: - Decode

    func feedNal(_ data: [UInt8]) {
        let nals = Self.splitAnnexB(data)
        if nals.isEmpty { return }

        var vclNals: [[UInt8]] = []
        var sawParameterSets = false
        for nal in nals {
            guard let type = nalType(nal) else { continue }
            if isHEVC {
                switch type {
                case 32: vps = nal; sawParameterSets = true
                case 33: sps = nal; sawParameterSets = true
                case 34: pps = nal; sawParameterSets = true
                default: if type <= 31 { vclNals.append(nal) }
                }
            } else {
                switch type {
                case 7: sps = nal; sawParameterSets = true
                case 8: pps = nal; sawParameterSets = true
                default: if type >= 1 && type <= 5 { vclNals.append(nal) }
                }
            }
        }

        if sawParameterSets { checkSession() }
        guard !vclNals.isEmpty else { return }
        guard session != nil, formatDesc != nil else {
            // Pictures with nothing to start from: this decoder joined a
            // stream already under way (the tablet's capture outlived the
            // last session), or its session could not be made.
            requestKeyframe()
            return
        }
        decode(vclNals, keyframe: sawParameterSets)
    }

    /// Asks the tablet for a keyframe, at most once a second: the decoder has
    /// pictures it cannot use. Main thread.
    private func requestKeyframe() {
        lock.lock(); let alive = self.alive; lock.unlock()
        guard alive else { return }
        let now = Date()
        if let last = lastKeyframeRequest,
           now.timeIntervalSince(last) < Self.keyframeRequestInterval { return }
        lastKeyframeRequest = now
        onRequestIdr()
    }

    /// First-byte NAL unit type (H.264: bits 0–4; H.265: bits 1–6).
    private func nalType(_ nal: [UInt8]) -> Int? {
        guard let first = nal.first else { return nil }
        return isHEVC ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
    }

    /// Whether [status] says the decompression session itself is gone, not
    /// just one picture.
    private static func sessionFailed(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr
    }

    /// A keyframe's parameter sets arrived. The session is kept only when
    /// they are byte for byte the ones it was made from and it has not
    /// failed; with no session, other sets (a rotation, another resolution
    /// or profile), a failed session or one that refused its last keyframe
    /// it is made again. Main thread.
    private func checkSession() {
        let sets: [[UInt8]]
        if isHEVC {
            guard let v = vps, let s = sps, let p = pps else { return }
            sets = [v, s, p]
        } else {
            guard let s = sps, let p = pps else { return }
            sets = [s, p]
        }

        let reason: String
        if session == nil {
            reason = reportedError ? "the last one could not be made" : "first parameter sets"
        } else if builtSets != sets {
            reason = "parameter sets changed"
        } else if Self.sessionFailed(lastDecodeStatus) {
            reason = "its session failed (status \(lastDecodeStatus))"
        } else if keyframeFailure != noErr {
            reason = "its last keyframe did not decode (status \(keyframeFailure))"
        } else {
            return
        }
        rebuildSession(from: sets, reason: reason)
    }

    private func rebuildSession(from sets: [[UInt8]], reason: String) {
        var fd: CMVideoFormatDescription?
        let status = sets.withUnsafeParameterSets { ptrs, sizes in
            isHEVC
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        }
        guard status == noErr, let newFd = fd else {
            // Whatever session there is stays as it was.
            remoteLogLine("[ExtendedScreen] s\(id) no remote decoder made (\(reason)): "
                + "no format description from the parameter sets (status \(status))")
            return
        }
        formatDesc = newFd

        // (Re)create the decompression session for the new format.
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        builtSets = nil
        sessionGen += 1
        lastDecodeStatus = noErr
        keyframeFailure = noErr
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // Decided at each creation, from the decoders there are now. Another
        // tablet's decoder is live: this one must be a hardware one, or it
        // can land silently on a software decoder.
        let requireHardware = anotherDecoderLive()
        var spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        if requireHardware {
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }
        var newSession: VTDecompressionSession?
        let status2 = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFd,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        session = newSession
        guard status2 == noErr, let made = newSession else {
            let code = status2 == kVTVideoDecoderNotAvailableNowErr ? "DECODER_BUSY" : "DECODER_FAILED"
            remoteLogLine("[ExtendedScreen] s\(id) remote decoder not created (\(reason); status \(status2), \(code)"
                + "\(requireHardware ? ", hardware required" : ""))")
            session = nil
            reportedError = true
            onError("\(code) (\(status2))")
            return
        }
        builtSets = sets
        let size = CMVideoFormatDescriptionGetDimensions(newFd)
        remoteLogLine("[ExtendedScreen] s\(id) remote decoder made (\(reason)): "
            + "\(isHEVC ? "H.265" : "H.264") \(size.width)x\(size.height), "
            + "\(Self.usesHardware(made) ? "hardware" : "software")"
            + "\(requireHardware ? " (required)" : "")")
        if reportedError {
            // The first session made since the error: the tablet's picture
            // can be decoded again.
            reportedError = false
            remoteLogLine("[ExtendedScreen] s\(id) remote decoder created again")
            onReady()
        }
    }

    /// Whether VideoToolbox gave [session] a hardware decoder.
    private static func usesHardware(_ session: VTDecompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(
                session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: nil, valueOut: $0)
        }
        return status == noErr && (value as? Bool) == true
    }

    /// A picture the session numbered [gen] would not decode ([keyframe]: one
    /// that came with parameter sets). Main thread.
    private func decodeFailed(_ status: OSStatus, session gen: Int, keyframe: Bool) {
        // An earlier session's callback, or a torn-down decoder's.
        guard gen == sessionGen else { return }
        if keyframe { keyframeFailure = status }
        if !Self.sessionFailed(lastDecodeStatus) {
            if Self.sessionFailed(status) {
                remoteLogLine("[ExtendedScreen] s\(id) remote decoder's session failed (status \(status)); "
                    + "the next keyframe makes it again")
            }
            lastDecodeStatus = status
        }
        // Start again from a keyframe (a picture whose reference never
        // arrived, say); its parameter sets are also where a failed session
        // is made again.
        requestKeyframe()
    }

    /// [again]: this keyframe was refused once already, by a session that
    /// has been made again since.
    private func decode(_ vclNals: [[UInt8]], keyframe: Bool, again: Bool = false) {
        guard let session = session, let fd = formatDesc else { return }

        // Annex-B → AVCC (4-byte length prefixes) in one contiguous block.
        var avcc = Data()
        for nal in vclNals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }

        var blockBuffer: CMBlockBuffer?
        let avccCount = avcc.count
        let mem = malloc(avccCount)!
        avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: avccCount)
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: avccCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avccCount, flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let bb = blockBuffer else { free(mem); return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizes = [avccCount]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sb = sampleBuffer else { return }

        let gen = sessionGen
        let submitted = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self = self else { return }
            guard status == noErr, let img = imageBuffer else {
                // A picture that would not decode: its status goes to the
                // main thread, where the session's state lives.
                if status != noErr {
                    DispatchQueue.main.async { [weak self] in
                        self?.decodeFailed(status, session: gen, keyframe: keyframe)
                    }
                }
                return
            }
            self.lock.lock()
            let alive = self.alive
            if alive { self.latestPixelBuffer = img }
            self.lock.unlock()
            // Never for a texture that has been unregistered.
            if alive { self.registrar.textures.textureFrameAvailable(self.textureId) }
        }
        // A session that is gone can refuse the frame outright, with no
        // callback: without this its status would never be seen, and with
        // unchanged parameter sets the session never made again.
        guard submitted != noErr else { return }
        if keyframe, !again, Self.sessionFailed(submitted), let sets = builtSets {
            // A keyframe needs nothing before it, and nothing of it went
            // in: the session is made again now and takes this same
            // picture, where waiting for the next keyframe would lose it
            // (on a still tablet screen that one can be a long way off).
            // Once only: a second refusal is an ordinary failure.
            rebuildSession(from: sets, reason: "its session failed (status \(submitted))")
            if sessionGen != gen {
                if self.session != nil {
                    decode(vclNals, keyframe: true, again: true)
                } else {
                    // None could be made (reported): the next keyframe
                    // tries again.
                    requestKeyframe()
                }
                return
            }
            // No format description from its own sets: the session is as
            // it was.
        }
        decodeFailed(submitted, session: gen, keyframe: keyframe)
    }

    func teardown() {
        lock.lock(); alive = false; latestPixelBuffer = nil; lock.unlock()
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        formatDesc = nil
        vps = nil; sps = nil; pps = nil
        builtSets = nil
        sessionGen += 1
        lastDecodeStatus = noErr
        keyframeFailure = noErr
        if textureId != 0 { registrar.textures.unregisterTexture(textureId); textureId = 0 }
    }

    // MARK: - Annex-B parsing

    /// Split an Annex-B buffer into raw NAL units (start codes stripped).
    private static func splitAnnexB(_ data: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        let n = data.count
        var i = 0
        var nalStart = -1
        while i + 2 < n {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                if nalStart >= 0 {
                    var end = i
                    // Trim a trailing 0 belonging to a 4-byte start code.
                    if end > nalStart && data[end - 1] == 0 { end -= 1 }
                    if end > nalStart { nals.append(Array(data[nalStart..<end])) }
                }
                nalStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if nalStart >= 0 && nalStart < n {
            nals.append(Array(data[nalStart..<n]))
        }
        return nals
    }
}

private extension Array where Element == [UInt8] {
    /// Run `body` with C-style parameter-set pointer/size arrays (used by the
    /// CMVideoFormatDescription parameter-set constructors).
    func withUnsafeParameterSets<R>(
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
    ) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var bufs: [UnsafeMutablePointer<UInt8>] = []
        for set in self {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buf.initialize(from: set, count: set.count)
            bufs.append(buf)
            pointers.append(UnsafePointer(buf))
            sizes.append(set.count)
        }
        defer { for b in bufs { b.deallocate() } }
        return pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in
                body(pp.baseAddress!, sp.baseAddress!)
            }
        }
    }
}
