import Cocoa
import FlutterMacOS
import VideoToolbox
import CoreVideo

/// Reverse remote (Mac controls tablet): decodes the H.264/H.265 Annex-B stream
/// coming FROM the tablet via VideoToolbox and exposes the decoded frames to
/// Flutter as a `FlutterTexture`. The mirror image of the Android
/// `VideoDecoderPlugin`.
///
/// NAL units arrive over a binary message channel (no codec overhead). The
/// encoder prepends SPS/PPS to every keyframe, so a format description can be
/// (re)built whenever parameter sets appear.
class RemoteVideoPlugin: NSObject, FlutterTexture {

    private static let channelName    = "extended_screen/remote_video"
    private static let nalChannelName = "extended_screen/remote_nal"

    private let registrar: FlutterPluginRegistrar
    private let channel: FlutterMethodChannel
    private var textureId: Int64 = 0

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var isHEVC = false

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

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
            if let data = message as? Data {
                plugin.feedNal([UInt8](data))
            }
            reply(nil)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            let args = call.arguments as? [String: Any]
            isHEVC = (args?["codec"] as? String) == "h265"
            // Register a texture; frames flow in as NALs arrive.
            textureId = registrar.textures.register(self)
            result(NSNumber(value: textureId))
        case "dispose":
            teardown()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        guard let buf = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buf)
    }

    // MARK: - Decode

    private func feedNal(_ data: [UInt8]) {
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
        guard session != nil, formatDesc != nil, !vclNals.isEmpty else { return }
        decode(vclNals)
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
        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFd,
            decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        session = newSession
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
            guard let self = self, status == noErr, let img = imageBuffer else { return }
            self.lock.lock(); self.latestPixelBuffer = img; self.lock.unlock()
            self.registrar.textures.textureFrameAvailable(self.textureId)
        }
    }

    private func teardown() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        formatDesc = nil
        vps = nil; sps = nil; pps = nil
        lock.lock(); latestPixelBuffer = nil; lock.unlock()
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
