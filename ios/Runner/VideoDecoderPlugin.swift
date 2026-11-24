import CoreMedia
import CoreVideo
import Flutter
import QuartzCore
import UIKit
import VideoToolbox
import os

private let decoderLog = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "com.porto.extendedscreen.ios", category: "decoder")

/// The iPhone's decoder: the Mac's H.264/H.265 Annex-B stream through
/// VideoToolbox into a Flutter `Texture`. A port of macOS's `RemoteDecoder`
/// (macos/Runner/RemoteVideoPlugin.swift) speaking the Android channel
/// contract of `VideoDecoderPlugin.kt`, so `VideoDecoderChannel` barely
/// changes:
///
///   extended_screen/video_decoder
///     initialize {width, height, codec, fps, sink?} → texture id. A call
///       while configured keeps the running session and only stores the new
///       values (as on Android), except that a different codec drops the
///       session, since its parameter sets mean nothing to the new one.
///     setRefreshRate {fps}  queue cap, plus a display-link frame-rate hint
///     requestIdr            answered with `onRequestIdr`, as on Android
///     getDropCount          frames discarded since the last call (then 0)
///     getMaxRefreshRate     the window scene's screen's top rate
///     dispose               ends the session and unregisters the texture
///   to Dart: onRequestIdr, onCodecError(String)
///   extended_screen/nal_feed (BinaryCodec, on a background task queue): one
///     access unit per message.
///
/// Parity with Android: frames wait for a decode slot in `pending`, at most
/// `queueCap` (about 100 ms at the stream rate, never under 6); on overflow
/// input resumes from a keyframe (the incoming one, else the newest queued
/// one), else everything waits for the next keyframe (`awaitingKeyframe`).
/// A new session starts the same way. Keyframe requests made for dropped
/// frames are throttled to one per 750 ms, backing off to 8 s while the
/// decoder is stuck. A session iOS invalidated (`kVTInvalidSessionErr`,
/// after the app was in the background) is rebuilt from the last parameter
/// sets, and a keyframe is asked for at once.
///
/// Output is 32BGRA in IOSurface-backed, Metal-compatible buffers, so
/// VideoToolbox applies the stream's own colour matrix (BT.709 video range
/// from the Mac) and Flutter's texture path does no YUV conversion of its own.
///
/// Threads: method calls and texture (un)registration on main; every piece
/// of decoder state on `queue` (the nal_feed task queue waits for it, which
/// keeps frames in order); VideoToolbox's output on its own threads, which
/// only hands the picture to the sink and hops back onto `queue`.
///
/// TODO(P4): `IOS_VIDEO_SINK` (a Dart define, passed as `sink`) will pick an
/// `AVSampleBufferDisplayLayer` sink under a transparent FlutterView; only
/// the texture sink exists, and any other value logs and uses it.
final class VideoDecoderPlugin: NSObject, FlutterPlugin {
  private static let channelName = "extended_screen/video_decoder"
  private static let nalChannelName = "extended_screen/nal_feed"

  /// The queue holds about 100 ms of frames at the stream rate, but never
  /// fewer than this, so an ordinary delivery burst doesn't trip it.
  private static let minQueuedFrames = 6
  /// Access units handed to VideoToolbox whose output has not come back:
  /// the counterpart of a MediaCodec's input buffers.
  private static let maxInFlight = 3
  /// Gap between keyframe requests made because frames were dropped.
  private static let idrRequestInterval: TimeInterval = 0.75
  /// Ceiling for that gap while the decoder is stuck.
  private static let idrRequestMaxInterval: TimeInterval = 8

  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private weak var registrar: FlutterPluginRegistrar?
  private let queue = DispatchQueue(label: "extended_screen.video_decoder", qos: .userInteractive)

  // Main thread.
  private var textureId: Int64 = 0
  private let rateHint = FrameRateHint()

  // `queue` only, from here down.
  private var sink: TextureSink?
  private var configured = false
  private var isHEVC = false  // kept through dispose, like Android's isHevc
  private var fps = 60
  private var session: VTDecompressionSession?
  private var formatDesc: CMVideoFormatDescription?
  private var vps: [UInt8]?
  private var sps: [UInt8]?
  private var pps: [UInt8]?
  /// Bumped whenever the session is replaced or dropped: output of an older
  /// one frees no slot of the current one.
  private var generation = 0
  /// Bumped whenever input restarts from a keyframe: a decode error from a
  /// frame sent before that restart starts nothing again.
  private var inputEpoch = 0
  private var inFlight = 0
  private var pending: [[UInt8]] = []
  private var awaitingKeyframe = false
  private var dropCount = 0
  private var lastIdrRequest: TimeInterval = 0
  private var idrRetry = idrRequestInterval
  private var outputSinceIdrRequest = false
  /// The last session could not be made (or iOS invalidated it): decoding is
  /// stuck until a keyframe makes one, so keyframe requests back off.
  private var sessionBroken = false
  private var lastCreateFailure: OSStatus?

  private init(registrar: FlutterPluginRegistrar, channel: FlutterMethodChannel) {
    self.registrar = registrar
    self.channel = channel
    self.textures = registrar.textures()
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let plugin = VideoDecoderPlugin(registrar: registrar, channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)

    // 60 to 120 frames a second: off the main thread, beside the UI.
    let nalChannel = FlutterBasicMessageChannel(
      name: nalChannelName, binaryMessenger: messenger,
      codec: FlutterBinaryCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?())
    nalChannel.setMessageHandler { [weak plugin] message, reply in
      if let plugin = plugin, let data = message as? Data, !data.isEmpty {
        let au = [UInt8](data)
        plugin.queue.sync { plugin.feed(au) }
      }
      reply(nil)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialize":
      result(NSNumber(value: initialize(args)))
    case "setRefreshRate":
      let fps = (args["fps"] as? Int) ?? queue.sync { self.fps }
      queue.sync { self.fps = fps }
      rateHint.set(fps: fps, max: maxRefreshRate())
      result(nil)
    case "requestIdr":
      channel.invokeMethod("onRequestIdr", arguments: nil)
      result(nil)
    case "getDropCount":
      result(queue.sync { () -> Int in
        let n = dropCount
        dropCount = 0
        return n
      })
    case "getMaxRefreshRate":
      result(maxRefreshRate())
    case "dispose":
      dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle (main thread)

  private func initialize(_ args: [String: Any]) -> Int64 {
    let width = args["width"] as? Int ?? 0
    let height = args["height"] as? Int ?? 0
    let fps = args["fps"] as? Int ?? 60
    let hevc = (args["codec"] as? String ?? "h264") == "h265"
    if let sinkName = args["sink"] as? String, sinkName != "texture" {
      decoderLog.warning("sink \(sinkName, privacy: .public) is not built yet; using the texture")
    }

    var newSink: TextureSink?
    if textureId == 0 {
      let made = TextureSink(registry: textures)
      textureId = textures.register(made)
      made.textureId = textureId
      newSink = made
    }
    queue.sync {
      if let made = newSink { sink = made }
      self.fps = fps
      if configured && hevc != isHEVC {
        // Dart disposes before switching codec; should it not, the old
        // codec's parameter sets and queued frames are of no use.
        dropSession()
        vps = nil; sps = nil; pps = nil
        dropQueued(pending.count)
      }
      isHEVC = hevc
      if !configured {
        configured = true
        restartInputFromKeyframe()
        requestIdr()
        // Frames that arrived before the decoder was configured wait in
        // `pending`; nothing else would ever submit them, since drain()
        // otherwise runs only from a decode callback and feed() submits
        // directly only while the queue is empty.
        drain()
      }
    }
    rateHint.set(fps: fps, max: maxRefreshRate())
    decoderLog.info(
      "initialize \(width)x\(height) \(hevc ? "h265" : "h264", privacy: .public) @\(fps) → texture \(self.textureId)"
    )
    return textureId
  }

  private func dispose() {
    let old: TextureSink? = queue.sync {
      dropSession()
      vps = nil; sps = nil; pps = nil
      configured = false
      fps = 60
      pending.removeAll()
      awaitingKeyframe = false
      idrRetry = Self.idrRequestInterval
      dropCount = 0
      sessionBroken = false
      lastCreateFailure = nil
      let s = sink
      sink = nil
      return s
    }
    old?.retire()
    if textureId != 0 {
      textures.unregisterTexture(textureId)
      textureId = 0
    }
    rateHint.stop()
    decoderLog.info("disposed")
  }

  /// The top refresh rate of the screen this app is on (120 on ProMotion,
  /// 60 under Low Power Mode or without it), for the HELLO.
  private func maxRefreshRate() -> Int {
    let scene =
      registrar?.viewController?.view.window?.windowScene
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.screen.maximumFramesPerSecond ?? 60
  }

  // MARK: - Input (queue)

  /// One access unit from the Mac. It waits for a decode slot, at most
  /// `queueCap` of them, so a decoder slower than the stream drops frames
  /// instead of falling seconds behind.
  private func feed(_ au: [UInt8]) {
    if awaitingKeyframe {
      if !AnnexB.isKeyframeAccessUnit(au, hevc: isHEVC) {
        dropCount += 1
        requestIdrThrottled()
        return
      }
      awaitingKeyframe = false
    }
    if configured && inFlight < Self.maxInFlight && pending.isEmpty {
      submit(au)
      return
    }
    if pending.count < queueCap {
      pending.append(au)
    } else {
      dropForOverflow(au)
    }
    // A free slot with frames waiting (queued before configure, or after a
    // restart) must not wait for a decode callback that may never come.
    drain()
  }

  private var queueCap: Int { max(Self.minQueuedFrames, fps / 10) }

  private func drain() {
    while configured && inFlight < Self.maxInFlight && !pending.isEmpty {
      submit(pending.removeFirst())
    }
  }

  /// Queue full: the decoder is behind the stream. Dropping one frame from
  /// the middle of a GOP corrupts every frame after it until the next
  /// keyframe, so resume from a keyframe instead: the incoming one, else the
  /// newest queued one (unless it is at the head, which frees no room), else
  /// the next to arrive, which is asked for.
  private func dropForOverflow(_ au: [UInt8]) {
    if AnnexB.isKeyframeAccessUnit(au, hevc: isHEVC) {
      dropQueued(pending.count)
      pending.append(au)
      return
    }
    let newest = newestQueuedKeyframe()
    if newest > 0 {
      dropQueued(newest)
      pending.append(au)
    } else {
      dropQueued(pending.count)
      dropCount += 1  // the incoming frame
      awaitingKeyframe = true
      requestIdrThrottled()
    }
  }

  /// A new session, or one that lost a picture, can only go on from a
  /// keyframe. Keep the queue from its newest keyframe on; with none queued,
  /// drop it all and wait for the next keyframe.
  private func restartInputFromKeyframe() {
    inputEpoch += 1
    let newest = newestQueuedKeyframe()
    if newest >= 0 {
      dropQueued(newest)
    } else {
      dropQueued(pending.count)
      awaitingKeyframe = true
    }
  }

  private func newestQueuedKeyframe() -> Int {
    pending.lastIndex { AnnexB.isKeyframeAccessUnit($0, hevc: isHEVC) } ?? -1
  }

  /// Drops the `count` oldest queued frames, counting them for the HUD.
  private func dropQueued(_ count: Int) {
    guard count > 0 else { return }
    pending.removeFirst(count)
    dropCount += count
  }

  // MARK: - Keyframe requests (queue)

  private func requestIdr() {
    lastIdrRequest = ProcessInfo.processInfo.systemUptime
    outputSinceIdrRequest = false
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onRequestIdr", arguments: nil)
    }
  }

  /// A keyframe request for dropped frames, repeated while they keep being
  /// dropped (the last one may have gone unanswered), but at most once per
  /// `idrRetry`. None before `initialize`: it asks for one itself.
  ///
  /// A decoder that cannot decode at all (every slot taken with nothing
  /// back since the last request, or no session because iOS would not make
  /// one) is not helped by a keyframe, so the gap doubles up to 8 s; any
  /// output resets it. A healthy decoder waiting for a keyframe keeps the
  /// short gap.
  private func requestIdrThrottled() {
    guard configured else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastIdrRequest < idrRetry { return }
    if (sessionBroken || inFlight >= Self.maxInFlight) && !outputSinceIdrRequest {
      idrRetry = min(idrRetry * 2, Self.idrRequestMaxInterval)
    }
    requestIdr()
  }

  // MARK: - Decode (queue)

  private func submit(_ au: [UInt8]) {
    let units = AnnexB.split(au)
    var vcl: [Range<Int>] = []
    var newSets = false
    for range in units {
      let header = au[range.lowerBound]
      let set: (inout [UInt8]?) -> Void = { stored in
        let bytes = Array(au[range])
        if stored != bytes {
          stored = bytes
          newSets = true
        }
      }
      if isHEVC {
        let type = Int((header >> 1) & 0x3F)
        switch type {
        case 32: set(&vps)
        case 33: set(&sps)
        case 34: set(&pps)
        case 0...31: vcl.append(range)
        default: break
        }
      } else {
        let type = Int(header & 0x1F)
        switch type {
        case 7: set(&sps)
        case 8: set(&pps)
        case 1...5: vcl.append(range)
        default: break
        }
      }
    }
    // New parameter sets; or a keyframe while there is no session (iOS
    // would not make the last one): try again.
    if newSets || (session == nil && AnnexB.isKeyframeAccessUnit(au, hevc: isHEVC)) {
      makeSession()
    }
    guard !vcl.isEmpty else { return }
    guard let session = session, let fd = formatDesc else {
      dropCount += 1
      awaitingKeyframe = true
      requestIdrThrottled()
      return
    }
    guard let sample = Self.sampleBuffer(au, units: vcl, format: fd) else {
      dropCount += 1
      return
    }

    inFlight += 1
    let gen = generation
    let epoch = inputEpoch
    let sink = self.sink
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
      infoFlagsOut: nil
    ) { [weak self] status, _, image, _, _ in
      if status == noErr, let image = image { sink?.present(image) }
      guard let self = self else { return }
      self.queue.async { self.decoded(generation: gen, epoch: epoch, status: status) }
    }
    if status != noErr {
      // The handler is not called when the call itself fails.
      inFlight = max(0, inFlight - 1)
      decodeFailed(status, epoch: epoch)
    }
  }

  private func decoded(generation gen: Int, epoch: Int, status: OSStatus) {
    guard gen == generation else { return }
    inFlight = max(0, inFlight - 1)
    outputSinceIdrRequest = true
    idrRetry = Self.idrRequestInterval
    if status != noErr { decodeFailed(status, epoch: epoch) }
    drain()
  }

  private func decodeFailed(_ status: OSStatus, epoch: Int) {
    if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
      // iOS took the decoder away (the app was in the background). Make the
      // session again from the parameter sets we have and start over from
      // a keyframe, asked for now.
      decoderLog.warning("session invalidated (status \(status)); rebuilding")
      notifyError("INVALID_SESSION (\(status))")
      dropSession()
      makeSession()
      restartInputFromKeyframe()
      requestIdr()
      return
    }
    // A picture that would not decode (its reference never arrived, say):
    // every picture after it is damaged too, until a keyframe. A failure of
    // a frame sent before the last restart is already covered by it.
    guard epoch == inputEpoch else { return }
    decoderLog.debug("decode error \(status)")
    restartInputFromKeyframe()
    requestIdrThrottled()
  }

  /// Ends the current session; whatever it still has in flight frees no slot.
  private func dropSession() {
    if let s = session { VTDecompressionSessionInvalidate(s) }
    session = nil
    formatDesc = nil
    generation += 1
    inFlight = 0
  }

  /// (Re)makes the session for the stored parameter sets. A session that can
  /// take the new format keeps running.
  private func makeSession() {
    let sets: [[UInt8]]
    if isHEVC {
      guard let v = vps, let s = sps, let p = pps else { return }
      sets = [v, s, p]
    } else {
      guard let s = sps, let p = pps else { return }
      sets = [s, p]
    }
    guard let fd = Self.formatDescription(sets, hevc: isHEVC) else {
      decoderLog.error("parameter sets give no format description")
      return
    }
    if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fd) {
      formatDesc = fd
      return
    }
    dropSession()
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var made: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
      imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &made)
    guard status == noErr, let made = made else {
      sessionBroken = true
      if lastCreateFailure != status {
        lastCreateFailure = status
        decoderLog.error("session not created (status \(status))")
        notifyError("DECODER_FAILED (\(status))")
      }
      return
    }
    VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    session = made
    formatDesc = fd
    sessionBroken = false
    lastCreateFailure = nil
    let dims = CMVideoFormatDescriptionGetDimensions(fd)
    decoderLog.info(
      "session \(self.isHEVC ? "h265" : "h264", privacy: .public) \(dims.width)x\(dims.height)")
  }

  private func notifyError(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onCodecError", arguments: message)
    }
  }

  private static func formatDescription(_ sets: [[UInt8]], hevc: Bool) -> CMVideoFormatDescription? {
    var fd: CMVideoFormatDescription?
    let status = sets.withUnsafeParameterSets { pointers, sizes in
      hevc
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
          parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
          parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
    }
    return status == noErr ? fd : nil
  }

  /// The access unit's picture NAL units as one AVCC sample (4-byte
  /// big-endian lengths in place of start codes).
  private static func sampleBuffer(
    _ au: [UInt8], units: [Range<Int>], format: CMVideoFormatDescription
  ) -> CMSampleBuffer? {
    let length = units.reduce(0) { $0 + 4 + $1.count }
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        == kCMBlockBufferNoErr,
      let block = block
    else { return nil }
    var offset = 0
    for range in units {
      var size = UInt32(range.count).bigEndian
      let ok = withUnsafeBytes(of: &size) { header in
        CMBlockBufferReplaceDataBytes(
          with: header.baseAddress!, blockBuffer: block, offsetIntoDestination: offset,
          dataLength: 4) == kCMBlockBufferNoErr
      }
      guard ok else { return nil }
      offset += 4
      let copied = au.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
          with: bytes.baseAddress! + range.lowerBound, blockBuffer: block,
          offsetIntoDestination: offset, dataLength: range.count) == kCMBlockBufferNoErr
      }
      guard copied else { return nil }
      offset += range.count
    }
    var sample: CMSampleBuffer?
    var sizes = [length]
    let status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
      sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
    return status == noErr ? sample : nil
  }
}

/// The decoded picture as a Flutter texture: the newest pixel buffer, read
/// by Flutter's raster thread. `retire()` (dispose) makes it take no more
/// pictures, so a late decode never marks an unregistered texture.
private final class TextureSink: NSObject, FlutterTexture {
  private weak var registry: FlutterTextureRegistry?
  var textureId: Int64 = 0
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var alive = true

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  /// VideoToolbox's output thread.
  func present(_ buffer: CVPixelBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard alive else { return }
    latest = buffer
    registry?.textureFrameAvailable(textureId)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func retire() {
    lock.lock()
    alive = false
    latest = nil
    lock.unlock()
  }
}

/// Keeps the panel at the stream's rate while a stream is configured: the
/// slowest rate that shows every frame, never under 60 Hz (as Android picks
/// its display mode). A display link of our own, doing nothing per frame,
/// whose preferred range ProMotion honours. Main thread.
private final class FrameRateHint {
  private var link: CADisplayLink?

  func set(fps: Int, max top: Int) {
    let top = Float(Swift.max(top, 60))
    let want = Swift.min(Float(Swift.max(fps, 60)), top)
    if link == nil {
      let made = CADisplayLink(target: Tick(), selector: #selector(Tick.tick(_:)))
      made.add(to: .main, forMode: .common)
      link = made
    }
    link?.preferredFrameRateRange = CAFrameRateRange(minimum: want, maximum: top, preferred: want)
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  private final class Tick: NSObject {
    @objc func tick(_ link: CADisplayLink) {}
  }
}

/// Annex-B helpers, the Swift twins of the Kotlin and Dart ones.
enum AnnexB {
  /// True when `au`, one Annex-B access unit, can start decoding on its own:
  /// it carries parameter sets (the Mac prepends them to every keyframe) or
  /// an IDR/IRAP slice. Start codes may be 3 or 4 bytes. The scan stops at
  /// the first slice, so a non-keyframe costs a few bytes rather than the
  /// whole frame. Mirrors `isKeyframeAccessUnit` in VideoDecoderPlugin.kt and
  /// lib/shared/protocol/annexb.dart.
  static func isKeyframeAccessUnit(_ au: [UInt8], hevc: Bool) -> Bool {
    var i = 0
    while i + 3 < au.count {
      if au[i] != 0 || au[i + 1] != 0 || au[i + 2] != 1 {
        i += 1
        continue
      }
      let header = au[i + 3]
      if hevc {
        // nal_unit_type is bits 1-6: 32-34 VPS/SPS/PPS, 16-21 IRAP slices
        // (BLA/IDR/CRA); any other type below 32 is a non-IRAP slice.
        let type = (header >> 1) & 0x3F
        if (16...21).contains(type) || (32...34).contains(type) { return true }
        if type < 32 { return false }
      } else {
        // nal_unit_type is the low 5 bits: 7 SPS, 5 IDR slice; 1-4 are
        // non-IDR slices and slice data partitions.
        let type = header & 0x1F
        if type == 5 || type == 7 { return true }
        if (1...4).contains(type) { return false }
      }
      i += 4
    }
    return false
  }

  /// The NAL units of an Annex-B buffer, as ranges without their start
  /// codes (a 4-byte start code's leading zero is trimmed off the unit
  /// before it). Empty units are left out.
  static func split(_ data: [UInt8]) -> [Range<Int>] {
    var units: [Range<Int>] = []
    let n = data.count
    var i = 0
    var start = -1
    while i + 2 < n {
      if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
        if start >= 0 {
          var end = i
          if end > start && data[end - 1] == 0 { end -= 1 }
          if end > start { units.append(start..<end) }
        }
        start = i + 3
        i += 3
      } else {
        i += 1
      }
    }
    if start >= 0 && start < n { units.append(start..<n) }
    return units
  }
}

extension Array where Element == [UInt8] {
  /// Runs `body` with C-style parameter-set pointer and size arrays (for the
  /// CMVideoFormatDescription parameter-set constructors).
  fileprivate func withUnsafeParameterSets<R>(
    _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
  ) -> R {
    var pointers: [UnsafePointer<UInt8>] = []
    var sizes: [Int] = []
    var buffers: [UnsafeMutablePointer<UInt8>] = []
    for set in self {
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
      buffer.initialize(from: set, count: set.count)
      buffers.append(buffer)
      pointers.append(UnsafePointer(buffer))
      sizes.append(set.count)
    }
    defer { for b in buffers { b.deallocate() } }
    return pointers.withUnsafeBufferPointer { p in
      sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
    }
  }
}
