import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {

  // The entry point: NSApplicationMain, as @main gives an app delegate by
  // default, unless this process is the short-lived child that switches a
  // virtual display to HiDPI (VirtualDisplayModeHelper), which exits before
  // anything of the app starts.
  static func main() {
    VirtualDisplayModeHelper.runIfAsked()
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  private var statusItem: NSStatusItem?

  // Home, the main Flutter window, held strongly: the `mainFlutterWindow`
  // outlet is weak, and other windows (remote windows, one per device) mean
  // `NSApp.windows.first` is no longer Home.
  private var homeWindow: NSWindow?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Ensure the app appears in the Dock and Cmd+Tab switcher.
    NSApp.setActivationPolicy(.regular)
    super.applicationDidFinishLaunching(notification)
    homeWindow = mainFlutterWindow
    setupMenuBarIcon()
  }

  // Keep app alive when window is closed — streaming continues in background.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Clicking the Dock icon brings Home back whenever Home is not visible,
  // whatever other windows (a remote window) are.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if let home = home(), !home.isVisible || home.isMiniaturized {
      showWindow()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // ── Menu bar icon ──────────────────────────────────────────────────────────

  private func setupMenuBarIcon() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem?.button else { return }

    if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "display", accessibilityDescription: "Extended Screen") {
      img.isTemplate = true
      button.image = img
    } else {
      button.title = "⊡"
    }

    let menu = NSMenu()
    menu.addItem(withTitle: "Open Extended Screen",
                 action: #selector(showWindow),
                 keyEquivalent: "")
    menu.addItem(NSMenuItem.separator())
    menu.addItem(withTitle: "Quit",
                 action: #selector(NSApplication.terminate(_:)),
                 keyEquivalent: "q")

    statusItem?.menu = menu
  }

  // The main window by reference; the class lookup is only a fallback should
  // the outlet ever be unset.
  private func home() -> NSWindow? {
    if let w = homeWindow ?? mainFlutterWindow { return w }
    let w = NSApp.windows.first { $0 is MainFlutterWindow }
    homeWindow = w
    return w
  }

  @objc private func showWindow() {
    guard let home = home() else { return }
    if home.isMiniaturized { home.deminiaturize(nil) }
    home.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
