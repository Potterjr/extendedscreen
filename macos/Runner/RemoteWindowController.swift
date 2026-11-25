import Cocoa

/// One remote device's window (an iPhone's, for now): shaped like the
/// device's picture and locked to its aspect ratio, the picture filling the
/// content below a black titlebar strip, its controls in a titlebar
/// accessory (trailing, so the picture keeps its full height). The controls,
/// the banner, the message and the overlay lines are drawn from the
/// snapshots Dart pushes (`render`, [RemoteChrome]): Swift holds no strings.
/// Keyed by the device id; [RemoteWindowPlugin] owns it. Closing it, by the
/// red button, ⌘W or `close`, ends that device's session in Dart (`closed`).
final class RemoteWindowController: NSWindowController, NSWindowDelegate {
    let id: String
    let kind: String
    let surface: RemoteSurfaceView
    /// The token of the Dart open that owns this window, echoed in `closed`
    /// and `frameSize` so Dart can tell this window from an earlier one of
    /// the same id (a re-open of an existing window hands it the new token).
    var token: Int
    /// Called once, as the window closes (main thread).
    var onClosed: ((RemoteWindowController) -> Void)?
    /// A toolbar button, a menu entry or the message's action (main thread).
    var onAction: ((String) -> Void)?

    /// The titlebar accessory's controls and the overlays over the picture.
    private let toolbar = RemoteToolbarView()
    private let accessory = NSTitlebarAccessoryViewController()
    private let overlays = RemoteChromeOverlayView()

    /// The picture's size in pixels, once known: what the aspect lock follows.
    private(set) var frameSize: CGSize?
    private var closed = false
    /// The content width the smallest toolbar (`RemoteToolbarView.Fit.folded`)
    /// needs beside the traffic lights: the window never gets narrower.
    private var toolbarMinWidth: CGFloat = 0

    /// Room kept between the zoom button and the accessory.
    private static let trafficLightMargin: CGFloat = 8

    /// The window's content before any frame size is known: a portrait phone
    /// (its longer side is the one a first window keeps).
    private static let placeholder = CGSize(width: 360, height: 780)
    /// A tablet's placeholder: landscape, as the tablet app is locked.
    private static let tabletPlaceholder = CGSize(width: 780, height: 488)

    /// The placeholder for a window of [kind].
    static func placeholder(for kind: String) -> CGSize {
        kind == "tablet" ? tabletPlaceholder : placeholder
    }

    /// The picture layer for a window of [kind]: a tablet's pictures come
    /// from its decoder as sample buffers, so it always takes the
    /// sample-buffer layer (`flutter.iphone_layer` is the iPhone's choice).
    static func layerKind(for kind: String) -> RemoteLayerKind {
        kind == "tablet" ? .sampleBuffer : .fromDefaults()
    }
    /// The shorter content side never goes below this.
    private static let minShortSide: CGFloat = 160
    /// The window's style: titled with its titlebar outside the content
    /// (see `init`), so no press on the picture can land on the titlebar.
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    init(id: String, kind: String, token: Int, title: String, frameSize: CGSize?) {
        self.id = id
        self.kind = kind
        self.token = token
        surface = RemoteSurfaceView(sink: RemotePictureSink(id: id, kind: Self.layerKind(for: kind)))
        // No `.fullSizeContentView`: the picture must not run under the
        // titlebar. AppKit's titlebar view sits above the content and takes
        // every press in that strip as a window drag, so the top of a phone's
        // screen (its status bar: Notification and Control Centre pulls,
        // scroll to top) could not be touched. The strip, black like the
        // window, is what moves the window, as iPhone Mirroring's bar does;
        // the content below it is the picture alone, and the aspect lock
        // (`contentAspectRatio`) applies to it.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.placeholder(for: kind)),
            styleMask: Self.styleMask,
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.backgroundColor = .black
        window.title = title
        // The window is black: its controls are drawn light on it.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = surface
        super.init(window: window)
        window.delegate = self

        // The controls' place; filled once Dart pushes the chrome.
        accessory.view = toolbar
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        toolbar.onAction = { [weak self] item in self?.onAction?(item) }

        // The banner, the message and the overlay lines lie over the picture
        // (whose layer goes below every subview's).
        surface.sink.layer.zPosition = -1
        overlays.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(overlays)
        NSLayoutConstraint.activate([
            overlays.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            overlays.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            overlays.topAnchor.constraint(equalTo: surface.topAnchor),
            overlays.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        overlays.onAction = { [weak self] item in self?.onAction?(item) }

        let name = "remote.\(id)"
        let restored = window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
        if !restored { window.center() }
        if let frameSize { apply(frameSize: frameSize) }
        window.makeFirstResponder(surface)
        remoteWindowLog("[ExtendedScreen] remote window open id=\(id) kind=\(kind) "
                        + "layer=\(surface.sink.kind.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings the window forward and the app with it. Main thread.
    func bringForward() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Locks the window to a picture of [size] pixels (the phone's frame,
    /// portrait or landscape): the content keeps its longer side, takes the
    /// new shape, and stays on screen. Rotation flips the lock. Main thread.
    func apply(frameSize size: CGSize) {
        guard let window, size.width > 0, size.height > 0, size != frameSize else { return }
        frameSize = size
        surface.frameSize = size
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let current = window.contentRect(forFrameRect: window.frame).size
        // A new window is the placeholder, whose longer side is the default;
        // a restored or resized one keeps the size the user gave it.
        let longSide = max(current.width, current.height, Self.minShortSide)

        // The frame's height beyond the content (the titlebar strip), which
        // the screen must have room for too.
        let chrome = window.frameRect(forContentRect: .zero).size

        // Shaped like the picture, its longer side kept, fitted to the screen.
        var content = Self.fit(size, longSide: longSide)
        let room = CGSize(width: screen.width * 0.95 - chrome.width,
                          height: screen.height * 0.95 - chrome.height)
        content = Self.fit(content, into: room)

        window.contentAspectRatio = size
        updateMinSize()
        window.contentMaxSize = Self.fit(
            size, into: CGSize(width: screen.width - chrome.width,
                               height: screen.height - chrome.height))

        // Keep the window's centre, then pull it back on screen.
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = CGPoint(x: old.midX - frame.width / 2, y: old.midY - frame.height / 2)
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
        surface.needsLayout = true
        fitToolbar()
    }

    /// The smallest content the window may take: its shorter side at least
    /// `minShortSide` and its width room for the folded toolbar beside the
    /// traffic lights, in the picture's shape once it is known. A window
    /// already smaller grows to it.
    private func updateMinSize() {
        guard let window else { return }
        let least: CGSize
        if let size = frameSize {
            let scale = max(Self.minShortSide / min(size.width, size.height),
                            toolbarMinWidth / size.width)
            least = CGSize(width: (size.width * scale).rounded(.up),
                           height: (size.height * scale).rounded(.up))
        } else {
            least = CGSize(width: max(Self.minShortSide, toolbarMinWidth), height: Self.minShortSide)
        }
        window.contentMinSize = least
        let current = window.contentRect(forFrameRect: window.frame).size
        if current.width > 0, current.height > 0,
           current.width < least.width || current.height < least.height {
            // Grown evenly, so the picture's shape is kept.
            let grow = max(least.width / current.width, least.height / current.height)
            window.setContentSize(CGSize(width: (current.width * grow).rounded(.up),
                                         height: (current.height * grow).rounded(.up)))
        }
    }

    /// Where the traffic lights end, in the window's coordinates, plus a
    /// margin: the accessory may take the titlebar from there on.
    private func trafficLightsEnd() -> CGFloat {
        guard let window, let zoom = window.standardWindowButton(.zoomButton),
              let parent = zoom.superview
        else { return 78 + Self.trafficLightMargin }
        return parent.convert(zoom.frame, to: nil).maxX + Self.trafficLightMargin
    }

    /// Sizes the trailing accessory (it takes its view's width) to the
    /// titlebar's free width: the full toolbar when it fits, else its chips
    /// without their text, else the buttons folded into one menu. The
    /// window's minimum width keeps room for the folded one, so the
    /// accessory never runs into the close button. Main thread.
    private func fitToolbar() {
        guard let window else { return }
        let available = window.frame.width - trafficLightsEnd()
        let width = toolbar.fit(into: available)
        toolbar.setFrameSize(NSSize(width: width, height: 28))
        let needed = ceil(toolbar.minimumWidth + trafficLightsEnd())
        if needed != toolbarMinWidth {
            toolbarMinWidth = needed
            updateMinSize()
        }
    }

    /// [size]'s shape with its longer side [longSide].
    static func fit(_ size: CGSize, longSide: CGFloat) -> CGSize {
        let scale = longSide / max(size.width, size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// [size] scaled down (never up) to fit in [box], its shape kept.
    static func fit(_ size: CGSize, into box: CGSize) -> CGSize {
        let scale = min(1, box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Draws [chrome] (a full snapshot): the title, the toolbar, the banner,
    /// the message and the overlay lines. The toolbar items' shortcuts join
    /// the ones `open` gave. Main thread.
    func render(_ chrome: RemoteChrome) {
        window?.title = chrome.title
        toolbar.apply(chrome.toolbar, more: chrome.more)
        fitToolbar()
        for item in chrome.toolbar {
            if let key = item.shortcut, !key.isEmpty { surface.shortcuts[key] = item.id }
        }
        overlays.apply(chrome)
    }

    /// Closes the window (its delegate then reports it closed). Main thread.
    func closeWindow() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        surface.cancelPress()
        let counts = surface.sink.counts
        remoteWindowLog("[ExtendedScreen] remote window closed id=\(id) "
                        + "enqueued=\(counts.enqueued) failures=\(counts.failures)")
        onClosed?(self)
    }

    func windowDidResize(_ notification: Notification) {
        fitToolbar()
    }

    func windowDidResignKey(_ notification: Notification) {
        surface.cancelPress()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        surface.needsLayout = true
    }
}

// MARK: - Chrome

/// One `render` snapshot from Dart (`RemoteViewModel.toMap`): every string
/// already in the user's language. Unknown or missing fields read as empty.
struct RemoteChrome {
    struct MenuEntry {
        let id: String
        let label: String
        init?(_ map: Any?) {
            guard let m = map as? [String: Any], let id = m["id"] as? String else { return nil }
            self.id = id
            label = m["label"] as? String ?? ""
        }
    }

    struct Item {
        enum Kind: String { case button, chip, menu }
        let id: String
        let kind: Kind
        let symbol: String
        let tooltip: String
        let enabled: Bool
        let warn: Bool
        let shortcut: String?
        let text: String?
        /// The chip's colour (`green`, `orange`); nil for the default.
        let color: String?
        let menu: [MenuEntry]

        init?(_ map: Any?) {
            guard let m = map as? [String: Any], let id = m["id"] as? String else { return nil }
            self.id = id
            kind = Kind(rawValue: m["kind"] as? String ?? "") ?? .button
            symbol = m["symbol"] as? String ?? ""
            tooltip = m["tooltip"] as? String ?? ""
            enabled = m["enabled"] as? Bool ?? true
            warn = (m["tint"] as? String) == "warn"
            shortcut = m["shortcut"] as? String
            text = m["text"] as? String
            color = m["color"] as? String
            menu = (m["menu"] as? [Any] ?? []).compactMap(MenuEntry.init)
        }
    }

    let title: String
    let toolbar: [Item]
    /// The label of the menu the buttons fold into when the titlebar is too
    /// narrow for them.
    let more: String
    let banner: String?
    let message: String?
    let messageAction: MenuEntry?
    /// The message lies translucent over the last picture instead of hiding
    /// it (a "waiting" or "reconnecting" over a picture that stays).
    let messagePassThrough: Bool
    let overlay: [String]
    /// The SF Symbol the message shows above its text (`iphone` by default).
    let symbol: String

    init(_ vm: [String: Any]) {
        title = vm["title"] as? String ?? ""
        let symbol = vm["symbol"] as? String ?? ""
        self.symbol = symbol.isEmpty ? "iphone" : symbol
        toolbar = (vm["toolbar"] as? [Any] ?? []).compactMap(Item.init)
        more = vm["more"] as? String ?? ""
        banner = vm["banner"] as? String
        let message = vm["message"] as? [String: Any]
        self.message = message?["text"] as? String
        messageAction = MenuEntry(message?["action"])
        messagePassThrough = message?["passThrough"] as? Bool ?? false
        overlay = (vm["overlay"] as? [Any] ?? []).compactMap { $0 as? String }
    }
}

private func remoteSymbol(_ name: String, size: CGFloat = 14) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}

private func remoteChipColor(_ name: String?) -> NSColor? {
    switch name {
    case "green": return .systemGreen
    case "orange": return .systemOrange
    default: return nil
    }
}

/// The titlebar accessory: the toolbar items left to right, each kept by
/// its id and updated in place while the snapshot's items stay the same ones
/// (a click on a button is never pulled from under the mouse), made again
/// when they change. A titlebar too narrow for it all gets less (`fit`):
/// first the chips lose their text (kept in their tooltips), then the
/// buttons and menus fold into one menu.
final class RemoteToolbarView: NSView {
    var onAction: ((String) -> Void)?

    /// How much of the toolbar shows, widest first.
    enum Fit: Int, CaseIterable { case full, iconChips, folded }

    private let stack = NSStackView()
    private var views: [String: RemoteToolbarItemView] = [:]
    private var layoutKey: [String] = []
    private var items: [RemoteChrome.Item] = []
    private let more = RemoteFoldButton()
    private(set) var current: Fit = .full
    /// The folded toolbar's width, as last measured (`fit`).
    private(set) var minimumWidth: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 28))
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Should the view ever be narrower than the stack, the leading items
        // are clipped, never the constraints broken.
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        leading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leading,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        more.onAction = { [weak self] id in self?.onAction?(id) }
        more.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ items: [RemoteChrome.Item], more label: String = "") {
        self.items = items
        let key = items.map { "\($0.id)/\($0.kind.rawValue)" }
        if key != layoutKey {
            layoutKey = key
            for v in stack.arrangedSubviews {
                stack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            views = [:]
            for item in items {
                // The folded menu takes the first button's place.
                if item.kind != .chip, more.superview == nil { stack.addArrangedSubview(more) }
                let v = RemoteToolbarItemView(kind: item.kind)
                v.onAction = { [weak self] id in self?.onAction?(id) }
                views[item.id] = v
                stack.addArrangedSubview(v)
            }
        }
        for item in items { views[item.id]?.apply(item) }
        more.apply(items.filter { $0.kind != .chip }, label: label)
        show(current)
    }

    /// The widest fit whose width is at most [available] (the folded one
    /// when none is), shown; answers its width. Also measures the folded
    /// width (`minimumWidth`).
    @discardableResult
    func fit(into available: CGFloat) -> CGFloat {
        var widths: [CGFloat] = []
        for f in Fit.allCases { widths.append(width(of: f)) }
        minimumWidth = widths[Fit.folded.rawValue]
        let chosen = Self.choose(available: available, widths: widths)
        show(chosen)
        return widths[chosen.rawValue]
    }

    /// The first fit, widest first, whose width (`widths`, by `Fit.rawValue`)
    /// is at most [available]; the last one when none is.
    static func choose(available: CGFloat, widths: [CGFloat]) -> Fit {
        for f in Fit.allCases where f.rawValue < widths.count && widths[f.rawValue] <= available {
            return f
        }
        return .folded
    }

    private func width(of fit: Fit) -> CGFloat {
        show(fit)
        layoutSubtreeIfNeeded()
        return ceil(stack.fittingSize.width)
    }

    private func show(_ fit: Fit) {
        current = fit
        // With nothing to fold, folded is just the icon chips.
        let fold = fit == .folded && more.superview != nil
        for item in items {
            guard let v = views[item.id] else { continue }
            switch item.kind {
            case .chip: v.showsText = fit == .full
            case .button, .menu: v.isHidden = fold
            }
        }
        more.isHidden = !fold
    }
}

/// The one menu the toolbar's buttons and menus fold into: each button an
/// entry (its tooltip, its symbol, enabled as it is), each menu a submenu.
final class RemoteFoldButton: NSView {
    var onAction: ((String) -> Void)?

    private let button = NSButton()
    private var items: [RemoteChrome.Item] = []

    init() {
        super.init(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.image = remoteSymbol("ellipsis.circle")
        button.target = self
        button.action = #selector(pressed(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 24),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ items: [RemoteChrome.Item], label: String) {
        self.items = items
        button.toolTip = label.isEmpty ? nil : label
        button.setAccessibilityLabel(label)
        button.isEnabled = items.contains { $0.enabled }
    }

    @objc private func pressed(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let mi = NSMenuItem(title: item.tooltip, action: nil, keyEquivalent: "")
            mi.image = remoteSymbol(item.symbol)
            mi.isEnabled = item.enabled
            if item.kind == .menu {
                let sub = NSMenu()
                sub.autoenablesItems = false
                for entry in item.menu {
                    let e = NSMenuItem(title: entry.label, action: #selector(chose(_:)),
                                       keyEquivalent: "")
                    e.target = self
                    e.representedObject = entry.id
                    sub.addItem(e)
                }
                mi.submenu = sub
            } else {
                mi.action = #selector(chose(_:))
                mi.target = self
                mi.representedObject = item.id
            }
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onAction?(id) }
    }
}

/// One toolbar item: a symbol button, a button that opens a menu, or a chip
/// (a symbol and optional text, which sends nothing).
final class RemoteToolbarItemView: NSView {
    var onAction: ((String) -> Void)?

    private let kind: RemoteChrome.Item.Kind
    private var item: RemoteChrome.Item?
    private let button = NSButton()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    /// The longest a chip's text gets; past it, it is cut with an ellipsis
    /// (the whole of it is in the tooltip).
    static let chipTextMaxWidth: CGFloat = 100

    /// Whether a chip shows its text (a narrow titlebar shows its icon only).
    var showsText = true {
        didSet { if oldValue != showsText, let item { apply(item) } }
    }

    init(kind: RemoteChrome.Item.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        let content: NSView
        switch kind {
        case .button, .menu:
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryChange)
            button.target = self
            button.action = #selector(pressed(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 26),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            content = button
        case .chip:
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.chipTextMaxWidth)
                .isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.orientation = .horizontal
            stack.spacing = 3
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(label)
            content = stack
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ item: RemoteChrome.Item) {
        self.item = item
        toolTip = item.tooltip.isEmpty ? nil : item.tooltip
        switch kind {
        case .button, .menu:
            button.image = remoteSymbol(item.symbol)
            button.toolTip = toolTip
            button.setAccessibilityLabel(item.tooltip)
            button.isEnabled = item.enabled
            button.contentTintColor = item.warn ? .systemOrange : nil
        case .chip:
            icon.image = remoteSymbol(item.symbol, size: 12)
            icon.contentTintColor = remoteChipColor(item.color)
                ?? (item.warn ? .systemOrange : .secondaryLabelColor)
            let text = item.text ?? ""
            label.stringValue = text
            label.isHidden = text.isEmpty || !showsText
            // Cut or hidden, the text is still the tooltip.
            let tip = [text, item.tooltip].filter { !$0.isEmpty }.joined(separator: "\n")
            toolTip = tip.isEmpty ? nil : tip
            label.toolTip = toolTip
            icon.toolTip = toolTip
            setAccessibilityLabel(text.isEmpty ? item.tooltip : text)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let item, item.enabled else { return }
        switch kind {
        case .menu:
            let menu = NSMenu()
            for entry in item.menu {
                let mi = NSMenuItem(title: entry.label, action: #selector(chose(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = entry.id
                menu.addItem(mi)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
        default:
            onAction?(item.id)
        }
    }

    @objc private func chose(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onAction?(id) }
    }
}

/// What lies over the picture: the banner along its top, the message
/// instead of it (black, so a last frame does not show through, or with
/// `passThrough` translucent over it) with its action button, and the
/// overlay lines in the bottom-left corner. Only the action button takes the
/// mouse; every other press goes through to the picture below.
final class RemoteChromeOverlayView: NSView {
    var onAction: ((String) -> Void)?

    private let banner = NSView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let message = NSView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let messageButton = NSButton(title: "", target: nil, action: nil)
    private let messageSymbol = NSImageView()
    private var messageSymbolName = ""
    private let overlay = NSView()
    private let overlayLabel = NSTextField(labelWithString: "")
    private var actionId: String?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // The message pane, under the banner and the overlay.
        message.wantsLayer = true
        message.layer?.backgroundColor = NSColor.black.cgColor
        messageSymbol.contentTintColor = NSColor.white.withAlphaComponent(0.38)
        messageLabel.alignment = .center
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        messageLabel.font = .systemFont(ofSize: 13)
        messageButton.bezelStyle = .rounded
        messageButton.target = self
        messageButton.action = #selector(messageAction)
        let column = NSStackView(views: [messageSymbol, messageLabel, messageButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        message.addSubview(column)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)

        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(red: 0x3A / 255.0, green: 0x2A / 255.0,
                                                blue: 0, alpha: 1).cgColor
        bannerLabel.textColor = NSColor(red: 1, green: 0xCC / 255.0, blue: 0x66 / 255.0,
                                        alpha: 1)
        bannerLabel.font = .systemFont(ofSize: 12)
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerLabel)
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)

        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.54).cgColor
        overlay.layer?.cornerRadius = 4
        overlayLabel.textColor = .white
        overlayLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        overlayLabel.maximumNumberOfLines = 0
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(overlayLabel)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: leadingAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.topAnchor.constraint(equalTo: topAnchor),
            message.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.centerXAnchor.constraint(equalTo: message.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: message.leadingAnchor,
                                            constant: 24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: message.widthAnchor,
                                                constant: -48),

            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.topAnchor.constraint(equalTo: topAnchor),
            bannerLabel.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            bannerLabel.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            bannerLabel.topAnchor.constraint(equalTo: banner.topAnchor, constant: 6),
            bannerLabel.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -6),

            overlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            overlayLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 6),
            overlayLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -6),
            overlayLabel.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 3),
            overlayLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -3),
        ])
        apply(RemoteChrome([:]))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // The wrapping labels break at the width they are given.
        bannerLabel.preferredMaxLayoutWidth = max(0, bounds.width - 24)
        messageLabel.preferredMaxLayoutWidth = max(0, bounds.width - 48)
    }

    /// Only the message's button takes a press; the rest goes to the picture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === messageButton && !messageButton.isHidden ? hit : nil
    }

    func apply(_ chrome: RemoteChrome) {
        let bannerText = chrome.banner ?? ""
        bannerLabel.stringValue = bannerText
        banner.isHidden = bannerText.isEmpty

        message.isHidden = chrome.message == nil
        message.layer?.backgroundColor = chrome.messagePassThrough
            ? NSColor.black.withAlphaComponent(0.55).cgColor : NSColor.black.cgColor
        if chrome.symbol != messageSymbolName {
            messageSymbolName = chrome.symbol
            messageSymbol.image = remoteSymbol(chrome.symbol, size: 40)
        }
        messageLabel.stringValue = chrome.message ?? ""
        actionId = chrome.messageAction?.id
        messageButton.title = chrome.messageAction?.label ?? ""
        messageButton.isHidden = chrome.messageAction == nil

        overlayLabel.stringValue = chrome.overlay.joined(separator: "\n")
        overlay.isHidden = chrome.overlay.isEmpty
        needsLayout = true
    }

    @objc private func messageAction() {
        if let actionId { onAction?(actionId) }
    }
}
