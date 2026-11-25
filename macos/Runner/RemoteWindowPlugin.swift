import AVFoundation
import Cocoa
import FlutterMacOS

/// Native remote windows, one per device id (the iPhone's capture uniqueID,
/// or a reverse-remote tablet's adb serial, kind `tablet`):
/// Swift owns the window, the picture layer and (later) mouse and keyboard;
/// Dart owns every behaviour and string. A generic shell: `kind` says whose
/// window it is, so other remote views can reuse it.
///
/// Channel `extended_screen/remote_window` (method):
/// - `open {id, kind, title, token, frame?: [w, h]}` → `true`: makes the
///   window and brings it forward, or brings forward the one that exists
///   (which takes the new token).
/// - `focus {id}` → whether a window for `id` exists (brought forward).
/// - `close {id}` → whether one existed; it closes, and `closed` follows.
/// - to Dart: `closed {id, token}` (the red button, ⌘W, `close`, or the app
///   quitting) and `frameSize {id, token, w, h}` (the picture's size in pixels as
///   it changes; informational, the capture channel's `onFrameSize` stays
///   the source of truth). `token` is the window's, from the open that owns
///   it, so Dart ignores a late message from a window it already closed.
///
/// - `render {id, vm}` → whether a window for `id` exists: draws the chrome
///   around its picture from a full snapshot ([RemoteChrome]: the title, the
///   toolbar items in the titlebar accessory, a banner, a message with its
///   action, overlay lines). Every string in it was resolved in Dart.
/// - to Dart: `action {id, token, item}`: a shortcut (⌘ with a key of the
///   `shortcuts` map `open` carries, or of a toolbar item's `shortcut`), a
///   toolbar button, a menu entry or the message's action.
///
/// Channel `extended_screen/remote_window_input` (basic, binary): pointer
/// packets from the picture ([RemotePointerPacket]), sent on the main
/// thread as AppKit delivers the events.
///
/// Picture sources reach a window's layer through [sink(for:)], from any
/// thread (the iPhone capture enqueues on its capture queue, a tablet's
/// `RemoteVideoPlugin` decoder on VideoToolbox's output thread), and join a
/// capture session to a preview layer through [attach(session:id:)]. While
/// any window is open the app holds a latency-critical process activity, so
/// App Nap cannot slow a usually hidden Home's process.
final class RemoteWindowPlugin: NSObject {
    static let channelName = "extended_screen/remote_window"
    static let inputChannelName = "extended_screen/remote_window_input"

    /// The registered plugin (set once, before the engine runs). Main thread.
    private(set) static var shared: RemoteWindowPlugin?

    private let channel: FlutterMethodChannel
    /// Pointer packets to Dart.
    let input: FlutterBasicMessageChannel
    /// Open windows by device id (main thread).
    private var windows: [String: RemoteWindowController] = [:]
    /// Capture sessions a source offered for a device's preview layer.
    private var sessions: [String: AVCaptureSession] = [:]
    /// Each device's last picture size, so a window opened after the first
    /// frame starts locked.
    private var frameSizes: [String: CGSize] = [:]
    private var activity: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    /// The picture sinks of open windows, by device id, for any thread.
    private static let sinkLock = NSLock()
    private static var sinks: [String: RemotePictureSink] = [:]

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        input = FlutterBasicMessageChannel(
            name: Self.inputChannelName, binaryMessenger: messenger,
            codec: FlutterBinaryCodec.sharedInstance())
        super.init()
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = RemoteWindowPlugin(messenger: messenger)
        plugin.channel.setMethodCallHandler(plugin.handle)
        plugin.terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil,
            queue: .main) { [weak plugin] _ in plugin?.closeAll() }
        shared = plugin
    }

    /// The picture sink of [id]'s open window; nil with none. Any thread.
    static func sink(for id: String) -> RemotePictureSink? {
        sinkLock.lock(); defer { sinkLock.unlock() }
        return sinks[id]
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        guard let id = args?["id"] as? String, !id.isEmpty else {
            result(FlutterError(code: "BAD_ARGS", message: "No id", details: nil))
            return
        }
        switch call.method {
        case "open":
            var frame: CGSize?
            if let f = args?["frame"] as? [NSNumber], f.count == 2,
               f[0].doubleValue > 0, f[1].doubleValue > 0 {
                frame = CGSize(width: f[0].doubleValue, height: f[1].doubleValue)
            }
            open(id: id, kind: args?["kind"] as? String ?? "iphone",
                 token: (args?["token"] as? NSNumber)?.intValue ?? 0,
                 title: args?["title"] as? String ?? "", frame: frame,
                 shortcuts: args?["shortcuts"] as? [String: String])
            result(true)
        case "focus":
            guard let w = windows[id] else { result(false); return }
            w.bringForward()
            result(true)
        case "close":
            guard let w = windows[id] else { result(false); return }
            w.closeWindow()
            result(true)
        case "render":
            guard let w = windows[id] else { result(false); return }
            w.render(RemoteChrome(args?["vm"] as? [String: Any] ?? [:]))
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func open(id: String, kind: String, token: Int, title: String, frame: CGSize?,
                      shortcuts: [String: String]?) {
        if let w = windows[id] {
            w.token = token
            if let shortcuts { w.surface.shortcuts = shortcuts }
            if let size = frameSizes[id] ?? frame { w.apply(frameSize: size) }
            w.bringForward()
            return
        }
        let w = RemoteWindowController(id: id, kind: kind, token: token, title: title,
                                       frameSize: frameSizes[id] ?? frame)
        w.onClosed = { [weak self] w in self?.closed(w) }
        w.surface.shortcuts = shortcuts ?? [:]
        w.surface.onPointer = { [weak self] data in
            self?.input.sendMessage(data)
        }
        let send: (String) -> Void = { [weak self, weak w] item in
            guard let self, let w, self.windows[w.id] === w else { return }
            self.channel.invokeMethod(
                "action", arguments: ["id": w.id, "token": w.token, "item": item])
        }
        w.surface.onAction = send
        w.onAction = send
        windows[id] = w
        Self.sinkLock.lock(); Self.sinks[id] = w.surface.sink; Self.sinkLock.unlock()
        w.surface.sink.attach(session: sessions[id])
        holdActivity()
        w.bringForward()
    }

    private func closed(_ w: RemoteWindowController) {
        guard windows[w.id] === w else { return }
        windows.removeValue(forKey: w.id)
        // Forgotten with its window: a replugged tablet with another panel
        // must not open at the old shape (the next open's `frame` or the
        // next frame size says the new one).
        frameSizes.removeValue(forKey: w.id)
        Self.sinkLock.lock()
        if Self.sinks[w.id] === w.surface.sink { Self.sinks.removeValue(forKey: w.id) }
        Self.sinkLock.unlock()
        w.surface.sink.attach(session: nil)
        if windows.isEmpty { releaseActivity() }
        channel.invokeMethod("closed", arguments: ["id": w.id, "token": w.token])
    }

    private func closeAll() {
        for w in Array(windows.values) { w.closeWindow() }
    }

    // MARK: - Picture sources (main thread)

    /// [session] captures [id]: a preview-layer window shows it.
    func attach(session: AVCaptureSession, id: String) {
        sessions[id] = session
        windows[id]?.surface.sink.attach(session: session)
    }

    /// [session] stopped: nothing shows it any more (only if it is still
    /// [id]'s, so a replacement's attach is not undone).
    func detach(session: AVCaptureSession, id: String) {
        guard sessions[id] === session else { return }
        sessions.removeValue(forKey: id)
        if let sink = windows[id]?.surface.sink, sink.shows(session: session) {
            sink.attach(session: nil)
        }
    }

    /// [id]'s picture is now [size] pixels: its window follows the shape.
    func frameSizeChanged(id: String, size: CGSize) {
        guard size.width > 0, size.height > 0, frameSizes[id] != size else { return }
        frameSizes[id] = size
        guard let w = windows[id] else { return }
        w.apply(frameSize: size)
        channel.invokeMethod(
            "frameSize",
            arguments: ["id": id, "token": w.token, "w": Int(size.width), "h": Int(size.height)])
    }

    // MARK: - Process activity

    private func holdActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Remote window open")
    }

    private func releaseActivity() {
        guard let a = activity else { return }
        ProcessInfo.processInfo.endActivity(a)
        activity = nil
    }
}
