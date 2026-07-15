// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

enum MenuEntry {
    case header(String, url: String?, version: String? = nil)
    case item(title: String, symbol: String?, shortcut: String?, enabled: Bool = true, action: () -> Void)
    case separator
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class MenuWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A custom, mesoneer-styled drop-down shown under the status item (since NSMenu
/// can't be themed). Dark surface, rounded, purple hover rows.
final class BrandMenu: NSObject {
    private let entries: [MenuEntry]
    private var window: MenuWindow?
    private var lastClose = Date.distantPast
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private let width: CGFloat = 252
    private let pad: CGFloat = 8
    private let rowH: CGFloat = 32
    /// Ignore a reopen within this window of closing, so the same click that
    /// dismissed the menu doesn't immediately reopen it.
    private let reopenGuard: TimeInterval = 0.25

    init(entries: [MenuEntry]) { self.entries = entries }

    func toggle(from button: NSStatusBarButton) {
        if window != nil { close(); return }
        if Date().timeIntervalSince(lastClose) < reopenGuard { return }
        let win = makeWindow()
        if let bwin = button.window {
            let onScreen = bwin.convertToScreen(button.convert(button.bounds, to: nil))
            win.setFrameTopLeftPoint(NSPoint(x: onScreen.maxX - win.frame.width, y: onScreen.minY - 4))
        }
        present(win)
    }

    /// Show as a context menu with its top-left corner near a screen point
    /// (clamped to stay on-screen).
    func show(at screenPoint: NSPoint) {
        if window != nil { close(); return }
        if Date().timeIntervalSince(lastClose) < reopenGuard { return }
        let win = makeWindow()
        let w = win.frame.width, h = win.frame.height
        var x = screenPoint.x, top = screenPoint.y
        if let f = (NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? NSScreen.main)?.frame {
            x = min(max(f.minX + 8, x), f.maxX - w - 8)
            top = min(max(f.minY + h + 8, top), f.maxY - 8)
        }
        win.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        present(win)
    }

    private func present(_ win: MenuWindow) {
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: NSWindow.didResignKeyNotification, object: win)
        // `didResignKeyNotification` alone misses some outside clicks — e.g. onto
        // another status-bar item, or a spot that doesn't hand key status to another
        // window — leaving the menu stuck open. Global/local mouse-down monitors catch
        // every click outside this window, in other apps and in our own, as a backstop.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window { self?.close() }
            return event
        }
    }

    private func makeWindow() -> MenuWindow {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.surfaceBase.cgColor
        container.layer?.cornerRadius = 0
        container.layer?.masksToBounds = true

        var y = pad
        for entry in entries {
            switch entry {
            case .header(let title, let url, let version):
                let header = HeaderView(width: width, pad: pad, title: title, version: version,
                                        url: url.flatMap(URL.init(string:))) { [weak self] in self?.close() }
                header.frame = NSRect(x: 0, y: y, width: width, height: 34)
                container.addSubview(header)
                y += 34
            case .separator:
                let line = NSView(frame: NSRect(x: pad + 8, y: y + 4, width: width - 2 * pad - 16, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = Theme.border.cgColor
                container.addSubview(line)
                y += 9
            case .item(let title, let symbol, let shortcut, let enabled, let action):
                let row = MenuRowView(width: width - 2 * pad, height: rowH,
                                      icon: symbol, title: title, shortcut: shortcut, enabled: enabled) { [weak self] in
                    self?.close()
                    DispatchQueue.main.async(execute: action)
                }
                row.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: rowH)
                container.addSubview(row)
                y += rowH
            }
        }
        let total = y + pad
        container.frame = NSRect(x: 0, y: 0, width: width, height: total)

        Theme.applyPanelGradient(to: container)

        let win = MenuWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: total),
                             styleMask: .borderless, backing: .buffered, defer: false)
        Theme.styleOverlayWindow(win)
        win.level = .popUpMenu
        win.contentView = container
        return win
    }

    @objc private func resigned() { close() }

    private func close() {
        guard let win = window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: win)
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
        win.orderOut(nil)
        window = nil
        lastClose = Date()
    }

}

/// The brand lockup at the top of the menu: the "m." logo + product name.
/// When given a url it acts as a link (pointing-hand cursor, lavender on hover)
/// that opens the repo and dismisses the menu.
private final class HeaderView: NSView {
    override var isFlipped: Bool { true }
    private let url: URL?
    private let onOpen: () -> Void
    private let titleLabel: NSTextField

    init(width: CGFloat, pad: CGFloat, title: String, version: String?, url: URL?, onOpen: @escaping () -> Void) {
        self.url = url
        self.onOpen = onOpen
        let logoSize: CGFloat = 22
        let textX = pad + 8 + logoSize + 9
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))

        let logo = NSImageView(frame: NSRect(x: pad + 8, y: (34 - logoSize) / 2, width: logoSize, height: logoSize))
        logo.image = Logo.image(size: logoSize)
        logo.imageScaling = .scaleProportionallyUpOrDown
        addSubview(logo)

        titleLabel.font = Theme.font(14, .bold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: textX, y: (34 - 20) / 2, width: titleLabel.frame.width, height: 20)
        addSubview(titleLabel)

        // A lavender version pill, right-aligned in the header, so the build is
        // emphasized and always visible at a glance from the menu bar.
        if let version {
            let versionLabel = NSTextField(labelWithString: "v\(version)")
            versionLabel.font = Theme.font(11, .bold)
            versionLabel.textColor = Theme.lavender
            versionLabel.sizeToFit()
            let padX: CGFloat = 8, badgeH: CGFloat = 18
            let badgeW = versionLabel.frame.width + padX * 2
            let badge = NSView(frame: NSRect(x: width - pad - 8 - badgeW, y: (34 - badgeH) / 2,
                                             width: badgeW, height: badgeH))
            badge.wantsLayer = true
            badge.layer?.backgroundColor = Theme.accentPurple.cgColor
            badge.layer?.cornerRadius = badgeH / 2
            badge.layer?.borderWidth = 1
            badge.layer?.borderColor = Theme.border.cgColor
            versionLabel.frame = NSRect(x: padX, y: (badgeH - versionLabel.frame.height) / 2,
                                        width: versionLabel.frame.width, height: versionLabel.frame.height)
            badge.addSubview(versionLabel)
            addSubview(badge)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        if url != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard url != nil else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { titleLabel.textColor = Theme.lavender }
    override func mouseExited(with event: NSEvent) { titleLabel.textColor = Theme.textPrimary }
    override func mouseUp(with event: NSEvent) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
        onOpen()
    }
}

/// A single styled row: [icon] title …… shortcut, with purple hover.
/// A disabled row shows dimmed, ignores clicks, and never hover-highlights.
private final class MenuRowView: NSView {
    private let enabled: Bool
    private let onClick: () -> Void

    init(width: CGFloat, height: CGFloat, icon: String?, title: String,
         shortcut: String?, enabled: Bool = true, onClick: @escaping () -> Void) {
        self.enabled = enabled
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 7

        let textColor = enabled ? Theme.textPrimary : Theme.textMuted
        var textX: CGFloat = 12
        if let icon, let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iv = NSImageView(frame: NSRect(x: 12, y: (height - 18) / 2, width: 18, height: 18))
            iv.image = img
            iv.contentTintColor = textColor
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.alphaValue = enabled ? 1 : 0.5
            addSubview(iv)
            textX = 40
        }

        let name = NSTextField(labelWithString: title)
        name.font = Theme.font(13, .medium); name.textColor = textColor
        name.alphaValue = enabled ? 1 : 0.5
        name.frame = NSRect(x: textX, y: (height - 18) / 2, width: width - textX - 60, height: 18)
        addSubview(name)

        if let shortcut {
            let key = NSTextField(labelWithString: shortcut)
            key.font = Theme.font(12, .semibold); key.textColor = Theme.textMuted
            key.alignment = .right
            key.alphaValue = enabled ? 1 : 0.5
            key.frame = NSRect(x: width - 58, y: (height - 16) / 2, width: 46, height: 16)
            addSubview(key)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        guard enabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard enabled else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Theme.accentPurple.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        layer?.backgroundColor = NSColor.clear.cgColor
        onClick()
    }
}

