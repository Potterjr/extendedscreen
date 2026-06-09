import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {

  private var statusItem: NSStatusItem?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Ensure the app appears in the Dock and Cmd+Tab switcher.
    NSApp.setActivationPolicy(.regular)
    super.applicationDidFinishLaunching(notification)
    setupMenuBarIcon()
  }

  // Keep app alive when window is closed — streaming continues in background.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Clicking the Dock icon reopens the window.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows {
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

  @objc private func showWindow() {
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
