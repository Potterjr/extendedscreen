import AVFoundation
import Cocoa
import os

private let surfaceLog = OSLog(subsystem: "com.example.extendedscreen", category: "remote_window")

func remoteWindowLog(_ message: String) {
    os_log("%{public}@", log: surfaceLog, type: .default, message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Which layer shows a remote window's picture. The sample-buffer layer is
/// the default; `defaults write <prefs> flutter.iphone_layer preview` picks
/// the capture session's own preview layer instead (read when a window is
/// made), so the two can be compared on the device.
enum RemoteLayerKind: String {
    case sampleBuffer
    case preview

    static let defaultsKey = "flutter.iphone_layer"

    static func fromDefaults() -> RemoteLayerKind {
        UserDefaults.standard.string(forKey: defaultsKey) == "preview" ? .preview : .sampleBuffer
    }
}

/// A remote window's picture layer, apart from its view so a capture queue
/// can feed it without touching AppKit. With [RemoteLayerKind.sampleBuffer]
/// frames are enqueued from the capture queue ([enqueue], any thread); with
/// [RemoteLayerKind.preview] the layer is joined to the capture session
/// ([attach], main thread) and draws with no hop through the app at all.
final class RemotePictureSink {
    let id: String
    let kind: RemoteLayerKind
    /// The layer the window shows (main thread for layout).
    let layer: CALayer
    private let displayLayer: AVSampleBufferDisplayLayer?
    private let previewLayer: AVCaptureVideoPreviewLayer?

    private let lock = NSLock()
    private var enqueued = 0
    private var failures = 0

    init(id: String, kind: RemoteLayerKind) {
        self.id = id
        self.kind = kind
        switch kind {
        case .sampleBuffer:
            let l = AVSampleBufferDisplayLayer()
            l.videoGravity = .resizeAspect
            displayLayer = l
            previewLayer = nil
            layer = l
        case .preview:
            let l = AVCaptureVideoPreviewLayer()
            l.videoGravity = .resizeAspect
            displayLayer = nil
            previewLayer = l
            layer = l
        }
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Whether [enqueue] shows anything (the sample-buffer layer).
    var takesSampleBuffers: Bool { displayLayer != nil }

    /// Shows [sampleBuffer] at once (DisplayImmediately: no timebase, no
    /// queueing behind earlier frames). Any thread; called on the capture
    /// queue. A failed renderer is flushed and fed on: a screen capture has
    /// no GOP, so the next frame is whole.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                     to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        var failed = false
        var reason = ""
        if #available(macOS 14.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                reason = renderer.error?.localizedDescription ?? "needs a flush"
                renderer.flush()
                failed = true
            }
            renderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
                reason = displayLayer.error?.localizedDescription ?? "needs a flush"
                displayLayer.flush()
                failed = true
            }
            displayLayer.enqueue(sampleBuffer)
        }
        lock.lock()
        enqueued += 1
        if failed { failures += 1 }
        let failuresNow = failures
        lock.unlock()
        if failed {
            remoteWindowLog("[ExtendedScreen] remote window id=\(id) renderer flushed "
                            + "(\(reason)); failures=\(failuresNow)")
        }
    }

    /// Frames enqueued and renderer failures so far.
    var counts: (enqueued: Int, failures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (enqueued, failures)
    }

    /// The preview layer shows [session] (nil: nothing). Main thread.
    func attach(session: AVCaptureSession?) {
        guard let previewLayer, previewLayer.session !== session else { return }
        previewLayer.session = session
    }

    /// Whether the preview layer is showing [session]. Main thread.
    func shows(session: AVCaptureSession) -> Bool {
        previewLayer?.session === session
    }
}

/// One pointer packet for Dart (`extended_screen/remote_window_input`,
/// little-endian; `RemotePointer` in `remote_driver.dart` is its twin):
/// u8 kind (0 down, 1 move, 2 up, 3 cancel), u8 flags (bit0 Shift), u16
/// idLen, the UTF-8 id, f32 x, y (picture-box points, top-left origin), f32
/// boxW, boxH, u64 eventUs (`NSEvent.timestamp` in µs: system uptime).
enum RemotePointerPacket {
    static let down: UInt8 = 0
    static let move: UInt8 = 1
    static let up: UInt8 = 2
    static let cancel: UInt8 = 3

    static func encode(kind: UInt8, shift: Bool, id: String, point: CGPoint,
                       box: CGSize, eventUs: UInt64) -> Data {
        let idBytes = Array(id.utf8.prefix(Int(UInt16.max)))
        var data = Data(capacity: 4 + idBytes.count + 24)
        data.append(kind)
        data.append(shift ? 1 : 0)
        var idLen = UInt16(idBytes.count).littleEndian
        withUnsafeBytes(of: &idLen) { data.append(contentsOf: $0) }
        data.append(contentsOf: idBytes)
        for v in [point.x, point.y, box.width, box.height] {
            var bits = Float32(v).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        var us = eventUs.littleEndian
        withUnsafeBytes(of: &us) { data.append(contentsOf: $0) }
        return data
    }
}

/// The content of a remote window: a layer-backed view holding the picture
/// layer, aspect-fitted (`resizeAspect`), with rounded corners. It takes the
/// first click on an inactive window, and ⌘W closes the window (MainMenu has
/// no Close item).
///
/// Input: the left button only. A press on the picture sends a down packet,
/// each drag a move (AppKit keeps sending drags outside the view while the
/// button is held), the release an up ([onPointer], to Dart); the window
/// losing key mid-press sends a cancel, and the rest of that press is
/// dropped. Points are in the aspect-fitted picture's own box (top-left
/// origin), so bars around it map outside 0..box. The right and other
/// buttons and the scroll wheel are dropped. ⌘ with a key in [shortcuts]
/// sends that item ([onAction]), not for a held key's repeats.
final class RemoteSurfaceView: NSView {
    let sink: RemotePictureSink

    /// Pointer packets, ready to send (main thread).
    var onPointer: ((Data) -> Void)?
    /// A shortcut's action item (main thread).
    var onAction: ((String) -> Void)?
    /// A key (`1` for ⌘1) to the action item it sends; from Dart's `open`.
    var shortcuts: [String: String] = [:]
    /// The picture's size in pixels once known: what the picture box is
    /// fitted to (the whole view before).
    var frameSize: CGSize?

    /// The press under way: its picture box, kept for its moves and its up.
    private var pressBox: CGRect?

    init(sink: RemotePictureSink) {
        self.sink = sink
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.addSublayer(sink.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sink.layer.frame = bounds
        sink.layer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command, key == "w" {
            window?.performClose(nil)
            return true
        }
        if mods == .command, let item = shortcuts[key] {
            if !event.isARepeat { onAction?(item) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A down while one is open (it never ended): end it first.
        if pressBox != nil { send(RemotePointerPacket.cancel, event: event) }
        let box = pictureRect(for: frameSize ?? bounds.size)
        pressBox = box
        send(RemotePointerPacket.down, event: event,
             shift: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressBox != nil else { return }
        send(RemotePointerPacket.move, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressBox != nil else { return }
        send(RemotePointerPacket.up, event: event)
        pressBox = nil
    }

    /// Ends a press still open with a cancel (the window lost key, or is
    /// closing). Main thread.
    func cancelPress() {
        guard let box = pressBox else { return }
        onPointer?(RemotePointerPacket.encode(
            kind: RemotePointerPacket.cancel, shift: false, id: sink.id,
            point: .zero, box: box.size, eventUs: Self.nowUs()))
        pressBox = nil
    }

    private func send(_ kind: UInt8, event: NSEvent, shift: Bool = false) {
        guard let box = pressBox, box.width > 0, box.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x - box.minX, y: p.y - box.minY)
        let us = event.timestamp > 0 ? UInt64(event.timestamp * 1_000_000) : Self.nowUs()
        onPointer?(RemotePointerPacket.encode(
            kind: kind, shift: shift, id: sink.id, point: point, box: box.size,
            eventUs: us))
    }

    /// System uptime in µs (the clock `NSEvent.timestamp` uses).
    private static func nowUs() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
    }

    /// The part of the view the picture fills for a frame of [frame] pixels
    /// (aspect-fitted, top-left origin, view points).
    func pictureRect(for frame: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / frame.width, bounds.height / frame.height)
        let w = frame.width * scale
        let h = frame.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
