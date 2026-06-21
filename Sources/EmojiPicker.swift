// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A compact, brand-styled grid of preset emoji, opened *above* the
/// screen-saver-level editor (like `ColorPickerPanel`). Picking one sets the
/// current stamp and closes; reuses `KeyablePickerWindow`. Supports pointer
/// hover, full arrow-key navigation + Esc, and marks the active stamp.
final class EmojiPickerPanel: NSObject {
    private var window: KeyablePickerWindow?
    private let onPick: (String) -> Void
    private let onClose: () -> Void

    private let cols = 5
    private var cells: [NSButton] = []
    private var focusIndex = 0
    private var hoverIndex = -1
    private var current: String?

    // A 5×5 grid grouped by purpose: verdict · attention · status/dev · reaction,
    // with the brand "m." tile as the final stamp.
    static let presets = ["👍","👎","✅","❌","⭐️",
                          "💯","👀","👉","❗","⚠️",
                          "❓","💡","🔴","🟡","🟢",
                          "🐛","🔍","🎯","❤️","🔥",
                          "🚀","🎉","👌","🤔", Logo.stampToken]

    init(onPick: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onPick = onPick
        self.onClose = onClose
    }

    func show(near button: NSView, current: String? = nil) {
        if window != nil { close(); return }
        self.current = current
        let pad: CGFloat = 12, cell: CGFloat = 34, gap: CGFloat = 4, capH: CGFloat = 22
        let rows = Int(ceil(Double(Self.presets.count) / Double(cols)))
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        let panelW = gridW + pad * 2, panelH = gridH + pad * 2 + capH

        let container = KeyGridView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        container.onKey = { [weak self] in self?.handleKey($0) }
        Theme.stylePanel(container, cornerRadius: 14)

        let cap = NSTextField(labelWithString: "")
        Theme.styleEyebrow(cap, "Emoji")
        cap.frame = NSRect(x: pad, y: panelH - 20, width: gridW, height: 14)
        container.addSubview(cap)

        focusIndex = Self.presets.firstIndex(of: current ?? "") ?? 0
        cells = []
        for (i, e) in Self.presets.enumerated() {
            let r = i / cols, c = i % cols
            let b = HoverCell(frame: NSRect(x: pad + CGFloat(c) * (cell + gap),
                                            y: panelH - capH - pad - CGFloat(r + 1) * cell - CGFloat(r) * gap,
                                            width: cell, height: cell))
            if e == Logo.stampToken {     // brand tile cell, not a Unicode glyph
                b.image = Logo.image(size: 24); b.imagePosition = .imageOnly
            } else {
                b.title = e
            }
            b.isBordered = false; b.bezelStyle = .regularSquare
            b.font = .systemFont(ofSize: 20)
            b.wantsLayer = true; b.layer?.cornerRadius = Theme.radiusSmall
            b.target = self; b.action = #selector(pick(_:)); b.tag = i
            b.onHover = { [weak self] inside in self?.hover(i, inside) }
            container.addSubview(b)
            cells.append(b)
        }
        updateHighlight()

        let win = KeyablePickerWindow(contentRect: container.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
        Theme.styleOverlayWindow(win)
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.contentView = container

        if let scr = button.window?.screen ?? NSScreen.main, let bw = button.window {
            let onScreen = bw.convertToScreen(button.convert(button.bounds, to: nil))
            var x = onScreen.midX - panelW / 2
            var y = onScreen.maxY + 10
            let vf = scr.visibleFrame
            x = min(max(vf.minX + 8, x), vf.maxX - panelW - 8)
            if y + panelH > vf.maxY - 8 { y = onScreen.minY - panelH - 10 }
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(container)   // so arrows / ↵ / esc work
        window = win
        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: NSWindow.didResignKeyNotification, object: win)
    }

    /// Fill marks the keyboard/pointer position; a lavender ring marks the active stamp.
    private func updateHighlight() {
        for (i, b) in cells.enumerated() {
            let active = (i == focusIndex || i == hoverIndex)
            b.layer?.backgroundColor = active ? Theme.hoverFill.cgColor
                                              : NSColor(white: 1, alpha: 0.06).cgColor
            let isCurrent = Self.presets[i] == current
            b.layer?.borderWidth = isCurrent ? 1.5 : 0
            b.layer?.borderColor = isCurrent ? Theme.focusRing.cgColor : NSColor.clear.cgColor
        }
    }

    private func hover(_ i: Int, _ inside: Bool) {
        hoverIndex = inside ? i : (hoverIndex == i ? -1 : hoverIndex)
        updateHighlight()
    }

    private func handleKey(_ code: UInt16) {
        let n = Self.presets.count
        switch code {
        case 123: focusIndex = max(0, focusIndex - 1)                 // ←
        case 124: focusIndex = min(n - 1, focusIndex + 1)             // →
        case 125: focusIndex = min(n - 1, focusIndex + cols)          // ↓
        case 126: focusIndex = max(0, focusIndex - cols)              // ↑
        case 36, 76: pickIndex(focusIndex); return                    // ↵ / ⌤
        case 53: close(); return                                      // esc
        default: return
        }
        updateHighlight()
    }

    @objc private func pick(_ sender: NSButton) { pickIndex(sender.tag) }
    private func pickIndex(_ i: Int) {
        guard i >= 0, i < Self.presets.count else { return }
        onPick(Self.presets[i])
        close()
    }
    @objc private func resigned() { close() }

    func close() {
        guard let win = window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: win)
        win.orderOut(nil); window = nil; onClose()
    }
}

/// Container that forwards arrow / ↵ / esc presses to the picker.
private final class KeyGridView: NSView {
    var onKey: ((UInt16) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode) }
}

/// An emoji cell that reports pointer enter/exit so it gets a hover affordance.
private final class HoverCell: NSButton {
    var onHover: ((Bool) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
