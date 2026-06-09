import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics

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

    private let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
    private let encodeQueue  = DispatchQueue(label: "encode",  qos: .userInteractive)

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = ScreenCapturePluginImpl()
        let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        plugin.channel = ch
        ch.setMethodCallHandler(plugin.handle)

        let frameCh = FlutterEventChannel(name: frameChannelName, binaryMessenger: messenger)
        frameCh.setStreamHandler(plugin)
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

            // w/h are the LOGICAL desktop points (e.g. 1480×924).
            // Physical pixel buffer = w*2 × h*2 (2960×1848) — full Tab S10 Ultra panel.
            let w = args["width"]  as? Int ?? 1480
            let h = args["height"] as? Int ?? 924
            let r = args["refreshRate"] as? Int ?? 60
            let pw = w * 2, ph = h * 2  // physical pixels

            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.queue = DispatchQueue.global(qos: .userInteractive)
            descriptor.name = "Extended Screen"
            descriptor.maxPixelsWide = UInt32(pw)
            descriptor.maxPixelsHigh = UInt32(ph)
            // ~220 PPI → macOS treats this as a Retina display and applies 2x
            // HiDPI scaling: logical 1480×924 points, physical 2960×1848 pixels.
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
            NSLog("[ExtendedScreen] Virtual display created id=\(display.displayID) applied=\(ok)")
            result(ok)
        }
    }

    // MARK: - Screen Capture

    private func startCapture(args: [String: Any], result: @escaping FlutterResult) {
        // logical size from config; capture/encode at physical (2x HiDPI) resolution.
        let wLogical = args["width"]  as? Int ?? 1480
        let hLogical = args["height"] as? Int ?? 924
        let w   = wLogical * 2   // 2960 physical pixels
        let h   = hLogical * 2   // 1848 physical pixels
        let fps = args["refreshRate"] as? Int ?? 60
        let br  = args["bitrate"]     as? Int ?? 20_000_000

        setupEncoder(width: w, height: h, fps: fps, bitrate: br)

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
                NSLog("[ExtendedScreen] Capturing virtual display \(self.virtualDisplayID)")
            } else if let main = content.displays.first {
                targetDisplay = main
                NSLog("[ExtendedScreen] Capturing main display \(main.displayID)")
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
                self.stream?.startCapture { err in
                    DispatchQueue.main.async {
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

    private func stopCapture() {
        stream?.stopCapture { _ in }
        stream = nil
        frameCount = 0
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession else { return }

        if frameCount == 0 {
            let pw = CVPixelBufferGetWidth(pixelBuffer)
            let ph = CVPixelBufferGetHeight(pixelBuffer)
            NSLog("[ExtendedScreen] First frame pixel size: \(pw)x\(ph)")
        }
        frameCount += 1

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var frameProps: CFDictionary? = nil
        if forceKeyframe {
            forceKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        encodeQueue.async {
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: frameProps,
                infoFlagsOut: nil
            ) { [weak self] status, _, encodedBuffer in
                guard status == noErr, let encoded = encodedBuffer else { return }
                self?.handleEncodedFrame(encoded)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        channel?.invokeMethod("onStreamStopped", arguments: error.localizedDescription)
    }

    // MARK: - VideoToolbox Encoder

    private func setupEncoder(width: Int, height: Int, fps: Int, bitrate: Int) {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard let s = session else { return }

        // Baseline profile + CAVLC: lower decode complexity on Android MediaCodec,
        // directly reducing end-to-end latency vs High+CABAC.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,                value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering,    value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,            value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode,         value: kVTH264EntropyMode_CAVLC)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,     value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,          value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,       value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(s)
        compressionSession = s
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

        // On keyframes, prepend SPS/PPS (parameter sets) in Annex-B form.
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var psPtr: UnsafePointer<UInt8>?
                var psSize = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &psPtr,
                    parameterSetSizeOut: &psSize, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let p = psPtr {
                    out.append(contentsOf: Self.startCode)
                    out.append(p, count: psSize)
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

