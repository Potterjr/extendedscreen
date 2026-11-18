import Cocoa
import FlutterMacOS
import VideoToolbox
import CoreVideo

/// Reverse remote (Mac controls tablet): decodes the H.264/H.265 Annex-B streams
/// coming FROM the tablets via VideoToolbox and exposes each tablet's decoded
/// frames to Flutter as a `FlutterTexture`. The mirror image of the Android
/// `VideoDecoderPlugin`.
///
/// One decoder per session (the id Dart sends as `session`; none means 0).
/// NAL units arrive over a binary message channel (no codec overhead), each
/// message behind its session's id, 4 bytes big-endian. The encoder prepends
/// SPS/PPS to every keyframe, so a format description can be (re)built
/// whenever parameter sets appear. A decoder fed pictures it cannot decode
/// (none of those yet, or a decode error) asks for a keyframe with
/// `onRequestIdr {session}`, at most once a second. Main thread: method
/// calls, the registry and feeding; each decoder's output lands on
/// VideoToolbox's threads.
class RemoteVideoPlugin: NSObject {

    private static let channelName    = "extended_screen/remote_video"
    private static let nalChannelName = "extended_screen/remote_nal"

    private let registrar: FlutterPluginRegistrar
    private let channel: FlutterMethodChannel
    private var decoders: [Int: RemoteDecoder] = [:]

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
                requireHardware: !decoders.isEmpty,
                onError: { [weak self] message in
                    self?.channel.invokeMethod("onCodecError", arguments: ["session": id, "error": message])
                },
                onRequestIdr: { [weak self] in
                    self?.channel.invokeMethod("onRequestIdr", arguments: ["session": id])
                })
            decoders[id] = decoder
            result(NSNumber(value: decoder.register()))
        case "dispose":
            decoders.removeValue(forKey: id)?.teardown()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// One tablet's decoder and the texture it renders into.
private final class RemoteDecoder: NSObject, FlutterTexture {
    private let id: Int
    private let registrar: FlutterPluginRegistrar
    private let requireHardware: Bool
    private let onError: (String) -> Void
    private let onRequestIdr: () -> Void
    private var textureId: Int64 = 0
    // When the tablet was last asked for a keyframe (main thread).
    private var lastKeyframeRequest: Date?
    private static let keyframeRequestInterval: TimeInterval = 1

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let isHEVC: Bool

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    // Guards latestPixelBuffer and alive: the decoder's output thread writes,
    // Flutter's raster thread reads, teardown (main) ends it.
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var alive = true

    init(id: Int, isHEVC: Bool, registrar: FlutterPluginRegistrar, requireHardware: Bool,
         onError: @escaping (String) -> Void, onRequestIdr: @escaping () -> Void) {
        self.id = id
        self.isHEVC = isHEVC
        self.registrar = registrar
        self.requireHardware = requireHardware
        self.onError = onError
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
        var paramChanged = false
        for nal in nals {
            guard let type = nalType(nal) else { continue }
            if isHEVC {
                switch type {
                case 32: vps = nal; paramChanged = true
                case 33: sps = nal; paramChanged = true
                case 34: pps = nal; paramChanged = true
                default: if type <= 31 { vclNals.append(nal) }
                }
            } else {
                switch type {
                case 7: sps = nal; paramChanged = true
                case 8: pps = nal; paramChanged = true
                default: if type >= 1 && type <= 5 { vclNals.append(nal) }
                }
            }
        }

        if paramChanged { rebuildSession() }
        guard !vclNals.isEmpty else { return }
        guard session != nil, formatDesc != nil else {
            // Pictures with nothing to start from: this decoder joined a
            // stream already under way (the tablet's capture outlived the
            // last session), or its session could not be made.
            requestKeyframe()
            return
        }
        decode(vclNals)
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

    private func rebuildSession() {
        let sets: [[UInt8]]
        if isHEVC {
            guard let v = vps, let s = sps, let p = pps else { return }
            sets = [v, s, p]
        } else {
            guard let s = sps, let p = pps else { return }
            sets = [s, p]
        }

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
        guard status == noErr, let newFd = fd else { return }
        formatDesc = newFd

        // (Re)create the decompression session for the new format.
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // Another tablet's decoder is live: this one must be a hardware one
        // too, or it can land silently on a software decoder.
        let spec: [CFString: Any]? = requireHardware
            ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
            : nil
        var newSession: VTDecompressionSession?
        let status2 = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFd,
            decoderSpecification: spec as CFDictionary?, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        session = newSession
        if status2 != noErr || newSession == nil {
            let code = status2 == kVTVideoDecoderNotAvailableNowErr ? "DECODER_BUSY" : "DECODER_FAILED"
            NSLog("[ExtendedScreen] s\(id) remote decoder not created (status \(status2), \(code))")
            onError("\(code) (\(status2))")
        }
    }

    private func decode(_ vclNals: [[UInt8]]) {
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

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self = self else { return }
            guard status == noErr, let img = imageBuffer else {
                // A picture that would not decode (one whose reference never
                // arrived, say): start again from a keyframe.
                if status != noErr {
                    DispatchQueue.main.async { [weak self] in self?.requestKeyframe() }
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
    }

    func teardown() {
        lock.lock(); alive = false; latestPixelBuffer = nil; lock.unlock()
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        formatDesc = nil
        vps = nil; sps = nil; pps = nil
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
