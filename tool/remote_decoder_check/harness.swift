
// Appended by run.sh to a copy of RemoteVideoPlugin.swift (RemoteDecoder is
// private to that file): a registrar that only counts the pictures a
// decoder shows, a software encoder for a few H.264 keyframes, and the
// scenario. See run.sh.

final class FakeTextures: NSObject, FlutterTextureRegistry {
    var frames = 0
    private let lock = NSLock()
    func register(_ texture: FlutterTexture) -> Int64 { 7 }
    func textureFrameAvailable(_ textureId: Int64) { lock.lock(); frames += 1; lock.unlock() }
    func unregisterTexture(_ textureId: Int64) {}
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
}

final class FakeRegistrar: NSObject, FlutterPluginRegistrar {
    let fakeTextures = FakeTextures()
    var messenger: FlutterBinaryMessenger { fatalError("unused") }
    var textures: FlutterTextureRegistry { fakeTextures }
    var view: NSView? { nil }
    var viewController: NSViewController? { nil }
    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {}
    func addApplicationDelegate(_ delegate: FlutterAppLifecycleDelegate) {}
    func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {}
    func publish(_ value: NSObject) {}
    func lookupKey(forAsset asset: String) -> String { asset }
    func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
}

extension RemoteDecoder {
    /// What a wake does to the session, as far as this can be played.
    func breakSession() { if let s = session { VTDecompressionSessionInvalidate(s) } }
}

/// H.264 keyframes (Annex-B, parameter sets first) from a software encoder.
func makeKeyframes(_ count: Int) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var enc: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false] as CFDictionary
    let st = VTCompressionSessionCreate(allocator: nil, width: 320, height: 240,
        codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &enc)
    precondition(st == noErr, "no encoder \(st)")
    let session = enc!
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    let lock = NSLock()
    for i in 0..<count {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(40 * (i + 1)), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb!,
            presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample = sample,
                  let fd = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var frame: [UInt8] = []
            var n = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
            for index in 0..<n {
                var p: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: index,
                    parameterSetPointerOut: &p, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                frame += [0, 0, 0, 1] + Array(UnsafeBufferPointer(start: p, count: size))
            }
            var total = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &total, dataPointerOut: &ptr)
            let bytes = UnsafeRawPointer(ptr!).assumingMemoryBound(to: UInt8.self)
            var at = 0
            while at + 4 <= total {
                let len = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16
                    | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
                frame += [0, 0, 0, 1] + Array(UnsafeBufferPointer(start: bytes + at + 4, count: len))
                at += 4 + len
            }
            lock.lock(); out.append(frame); lock.unlock()
        }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
    return out
}

let keyframes = makeKeyframes(3)
precondition(keyframes.count == 3, "encoder gave \(keyframes.count) keyframes")
let registrar = FakeRegistrar()
var idrRequests = 0
var errors: [String] = []
private let decoder = RemoteDecoder(id: 1, isHEVC: false, registrar: registrar,
    anotherDecoderLive: { false }, onError: { errors.append($0) }, onReady: {},
    onRequestIdr: { idrRequests += 1 })
_ = decoder.register()
var failed = 0
func check(_ what: String, _ holds: Bool) {
    if !holds { failed += 1 }
    print("\(holds ? "  ok  " : "  FAIL") \(what)")
}
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }

decoder.feedNal(keyframes[0])
settle()
check("the first keyframe decodes (\(registrar.fakeTextures.count) picture(s))",
      registrar.fakeTextures.count == 1)
decoder.breakSession()
decoder.feedNal(keyframes[1])
settle()
check("a keyframe a dead session refuses is decoded by the session made for it "
      + "(\(registrar.fakeTextures.count) picture(s), \(idrRequests) keyframe request(s))",
      registrar.fakeTextures.count == 2 && idrRequests == 0)
decoder.feedNal(keyframes[2])
settle()
check("and the next one decodes too (\(registrar.fakeTextures.count) picture(s))",
      registrar.fakeTextures.count == 3 && errors.isEmpty)
decoder.teardown()
exit(failed == 0 ? 0 : 1)
