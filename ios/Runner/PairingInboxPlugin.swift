import CryptoKit
import Flutter
import Foundation
import os

private let inboxLog = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "com.porto.extendedscreen.ios", category: "inbox")

/// How a Mac's Wi-Fi pairing gets into the iPhone app: the iOS stand-in for
/// Android's DUMP-guarded broadcast (docs/ios-client-design.md, *auth*). The
/// Mac writes the unchanged pairing bytes into this app's own container with
/// `xcrun devicectl device copy to --domain-type appDataContainer`, at
/// `Library/Application Support/ESInbox/pairing.bin`, then posts the Darwin
/// notification `<bundle id>.inbox`. Only a Mac the phone trusts, with
/// Developer Mode on, can write there, and only into a development-signed
/// app; Info.plist must never let Finder, Files or AirDrop in (see
/// test/ios_info_plist_test.dart).
///
/// Dart pulls; native never pushes the bytes. A push at launch would reach
/// no handler, and the inbox exists for exactly the pairing that waited
/// while the app was closed.
///
///   extended_screen/wifi_pairing (the channel `WifiPairingChannel` owns)
///     takeInbox → Uint8List or null. If `pairing.processing` exists (an
///       earlier take whose answer never came, the app was killed between),
///       its bytes again. Otherwise `pairing.bin` renamed to
///       `pairing.processing` (atomic) and its bytes, or null when there is
///       none. A file over 4 KB is refused on the spot: result 2, deleted.
///     inboxDone {result: 1 stored | 2 refused} → bool. Writes `result`
///       (the result byte, then the first 8 bytes of the SHA-256 of the
///       bytes it answers, so the Mac can tell which delivery it answers),
///       then deletes `pairing.processing`. False when nothing was taken.
///   to Dart: inboxChanged, a nudge with no data, on the Darwin
///     notification. With no handler set yet it is lost, and nothing else is:
///     the file stays for the next pull.
///
/// `ESInbox` is made at launch and excluded from backups, since a pairing
/// waiting there holds the Mac's long-lived token. Main thread throughout
/// (a few kilobytes of file I/O).
final class PairingInboxPlugin: NSObject, FlutterPlugin {
  private static let channelName = "extended_screen/wifi_pairing"

  private let channel: FlutterMethodChannel
  private let inbox: PairingInbox?
  private var observing = false

  private init(channel: FlutterMethodChannel, inbox: PairingInbox?) {
    self.channel = channel
    self.inbox = inbox
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let inbox = PairingInbox.inApplicationSupport()
    do {
      try inbox?.prepare()
    } catch {
      inboxLog.error("ESInbox not prepared: \(error.localizedDescription, privacy: .public)")
    }
    let plugin = PairingInboxPlugin(channel: channel, inbox: inbox)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    plugin.startObserving()
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    stopObserving()
  }

  deinit {
    stopObserving()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let inbox = inbox else {
      result(FlutterError(code: "NO_INBOX", message: "no Application Support directory", details: nil))
      return
    }
    switch call.method {
    case "takeInbox":
      do {
        if let bytes = try inbox.take() {
          inboxLog.info("took a pairing of \(bytes.count) bytes")
          result(FlutterStandardTypedData(bytes: bytes))
        } else {
          result(nil)
        }
      } catch {
        inboxLog.error("takeInbox failed: \(error.localizedDescription, privacy: .public)")
        result(FlutterError(code: "INBOX_FAILED", message: error.localizedDescription, details: nil))
      }
    case "inboxDone":
      let args = call.arguments as? [String: Any]
      guard let code = args?["result"] as? Int,
        let answer = PairingInbox.Answer(rawValue: UInt8(clamping: code)), code == Int(answer.rawValue)
      else {
        result(FlutterError(code: "BAD_ARGS", message: "inboxDone takes {result: 1 | 2}", details: nil))
        return
      }
      do {
        let answered = try inbox.done(answer)
        inboxLog.info("inboxDone \(code): \(answered ? "answered" : "nothing taken", privacy: .public)")
        result(answered)
      } catch {
        inboxLog.error("inboxDone failed: \(error.localizedDescription, privacy: .public)")
        result(FlutterError(code: "INBOX_FAILED", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Darwin notification

  /// `<bundle id>.inbox`, posted by `devicectl device notification post`
  /// after a delivery. It carries no data, so a forged one only makes the
  /// app look.
  static var notificationName: String {
    (Bundle.main.bundleIdentifier ?? "com.porto.extendedscreen.ios") + ".inbox"
  }

  private func startObserving() {
    guard !observing else { return }
    observing = true
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer = observer else { return }
        let plugin = Unmanaged<PairingInboxPlugin>.fromOpaque(observer).takeUnretainedValue()
        plugin.nudge()
      },
      Self.notificationName as CFString, nil, .deliverImmediately)
  }

  private func stopObserving() {
    guard observing else { return }
    observing = false
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(Self.notificationName as CFString), nil)
  }

  private func nudge() {
    DispatchQueue.main.async { [weak self] in
      inboxLog.info("inbox notification")
      self?.channel.invokeMethod("inboxChanged", arguments: nil)
    }
  }
}

/// The inbox's files, under one directory. Pure Foundation, no Flutter.
final class PairingInbox {
  /// What Dart made of the bytes it took, written as the result file's
  /// first byte.
  enum Answer: UInt8 {
    case stored = 1
    case refused = 2
  }

  /// A pairing payload is a few hundred bytes plus a certificate; anything
  /// over this is not one.
  static let maxBytes = 4096

  let directory: URL
  private let files = FileManager.default

  init(directory: URL) {
    self.directory = directory
  }

  static func inApplicationSupport() -> PairingInbox? {
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    return PairingInbox(directory: support.appendingPathComponent("ESInbox", isDirectory: true))
  }

  private var pendingURL: URL { directory.appendingPathComponent("pairing.bin") }
  private var processingURL: URL { directory.appendingPathComponent("pairing.processing") }
  private var resultURL: URL { directory.appendingPathComponent("result") }

  /// Makes the directory (Application Support does not exist on a fresh
  /// install) and keeps it, and so what waits in it, out of backups.
  func prepare() throws {
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  /// The bytes to hand to Dart, or nil. See `PairingInboxPlugin`.
  func take() throws -> Data? {
    if files.fileExists(atPath: processingURL.path) {
      return try readOrRefuse(processingURL)
    }
    guard files.fileExists(atPath: pendingURL.path) else { return nil }
    // Created but not written yet: leave it for the next pull, which the
    // delivery's notification makes.
    if try size(of: pendingURL) == 0 { return nil }
    try files.moveItem(at: pendingURL, to: processingURL)
    return try readOrRefuse(processingURL)
  }

  /// Answers what was taken. False when nothing is being processed.
  func done(_ answer: Answer) throws -> Bool {
    guard files.fileExists(atPath: processingURL.path) else { return false }
    try answerFor(processingURL, answer)
    return true
  }

  /// The file's bytes, or nil once a file over `maxBytes` has been refused.
  private func readOrRefuse(_ url: URL) throws -> Data? {
    if try size(of: url) > Self.maxBytes {
      inboxLog.warning("refused an inbox file over \(Self.maxBytes) bytes")
      try answerFor(url, .refused)
      return nil
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
    // Grown since the size was read.
    if bytes.count > Self.maxBytes {
      try answerFor(url, .refused)
      return nil
    }
    return bytes
  }

  /// Writes the result file for `url`'s bytes, then deletes `url`.
  private func answerFor(_ url: URL, _ answer: Answer) throws {
    var record = Data([answer.rawValue])
    record.append(contentsOf: try Self.sha256(of: url).prefix(8))
    try record.write(to: resultURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try files.removeItem(at: url)
  }

  private func size(of url: URL) throws -> Int {
    let attributes = try files.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
  }

  /// Streams the file, so a refused oversized one is never read whole.
  private static func sha256(of url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize()
  }
}
