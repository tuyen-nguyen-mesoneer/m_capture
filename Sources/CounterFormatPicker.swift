// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A small brand-styled popover listing the counter numbering formats with a
/// sample and a label, so the choice is explicit (vs. a silent cycling button).
/// Opens above the screen-saver-level editor; reuses `KeyablePickerWindow`.
final class CounterFormatPicker: NSObject {
    private var window: KeyablePickerWindow?
    private let onPick: (CounterFormat) -> Void
    private let onClose: () -> Void
    private var current: CounterFormat
    private var rowViews: [NSView] = []
    private var focusIndex = 0
    private var hoverIndex = -1

    private static let rows: [(CounterFormat, String, String)] = [
        (.number, "1 2 3", "Numbers"),
        (.letter, "A B C", "Letters"),
        (.roman, "i ii iii", "Roman"),
    ]

    init(current: CounterFormat, onPick: @escaping (CounterFormat) -> Void, onClose: @escaping () -> Void) {
        self.current = current; self.onPick = onPick; self.onClose = onClose
    }

    /// `avoid` (screen coords) is the tool panel — the popover is placed above it
    /// (or below if there's no room) so it never overlaps the card.
    func show(near button: NSView, avoiding avoid: CGRect? = nil) {
        if window != nil { close(); return }
        let container = buildContent()
        let win = KeyablePickerWindow(contentRect: container.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
        Theme.styleOverlayWindow(win)
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.contentView = container
        let panelW = container.frame.width, panelH = container.frame.height
        let vf = (button.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        var x = (anchor?.midX ?? vf.midX) - panelW / 2
        x = min(max(vf.minX + 8, x), vf.maxX - panelW - 8)
        let block = avoid ?? anchor ?? .zero
        var y = block.maxY + 10
        if y + panelH > vf.maxY - 8 { y = block.minY - panelH - 10 }
        y = min(max(vf.minY + 8, y), vf.maxY - panelH - 8)
        win.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(container)
        window = win
        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: NSWindow.didResignKeyNotification, object: win)
    }

    private func handleKey(_ code: UInt16) {
        switch code {
        case 125: focusIndex = min(Self.rows.count - 1, focusIndex + 1); updateHighlight()
        case 126: focusIndex = max(0, focusIndex - 1); updateHighlight()
        case 36, 76: choose(focusIndex)
        case 53: close()
        default: break
        }
    }
    private func updateHighlight() {
        for (i, v) in rowViews.enumerated() {
            let active = (i == focusIndex || i == hoverIndex)
            v.layer?.backgroundColor = active ? Theme.hoverFill.cgColor : NSColor.clear.cgColor
        }
    }
    private func hover(_ i: Int, _ inside: Bool) {
        hoverIndex = inside ? i : (hoverIndex == i ? -1 : hoverIndex)
        updateHighlight()
    }
    private func choose(_ i: Int) {
        guard i >= 0, i < Self.rows.count else { return }
        onPick(Self.rows[i].0)
        close()
    }

    /// Builds the popover content view (extracted so it can be rendered in tests).
    /// Styled like a panel card: a quiet caption, a horizontal divider, then the
    /// rows with small text.
    func buildContent() -> NSView {
        let pad: CGFloat = 8, rowH: CGFloat = 28, rowGap: CGFloat = 2, w: CGFloat = 146
        let inset: CGFloat = 10
        let capH: CGFloat = 16, capGap: CGFloat = 13
        let panelW = w + pad * 2
        let rowsH = CGFloat(Self.rows.count) * rowH + CGFloat(Self.rows.count - 1) * rowGap
        let panelH = pad + capH + capGap + rowsH + pad

        focusIndex = Self.rows.firstIndex { $0.0 == current } ?? 0
        rowViews = []
        let container = KeyNavView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        container.onKey = { [weak self] in self?.handleKey($0) }
        Theme.stylePanel(container)

        let cap = NSTextField(labelWithString: "")
        Theme.styleEyebrow(cap, "Counter format")
        cap.alignment = .center
        cap.frame = NSRect(x: 0, y: panelH - pad - capH, width: panelW, height: capH)
        container.addSubview(cap)

        let divider = NSView(frame: NSRect(x: panelW * 0.14, y: panelH - pad - capH - 6,
                                           width: panelW * 0.72, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        container.addSubview(divider)

        func lbl(_ s: String, _ f: NSFont, _ c: NSColor) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = f; t.textColor = c
            t.sizeToFit()
            return t
        }
        let contentTop = panelH - pad - capH - capGap
        let sampleColW: CGFloat = 46
        for (i, row) in Self.rows.enumerated() {
            let (fmt, sample, name) = row
            let y = contentTop - CGFloat(i + 1) * rowH - CGFloat(i) * rowGap
            let rowView = NSView(frame: NSRect(x: pad, y: y, width: w, height: rowH))
            rowView.wantsLayer = true
            rowView.layer?.cornerRadius = 6
            rowView.layer?.backgroundColor = (i == focusIndex) ? Theme.hoverFill.cgColor : NSColor.clear.cgColor
            rowViews.append(rowView)

            let sampleLab = lbl(sample, Theme.font(12, .bold), .white)
            sampleLab.frame.origin = CGPoint(x: inset, y: (rowH - sampleLab.frame.height) / 2)
            rowView.addSubview(sampleLab)

            let nameLab = lbl(name, Theme.font(10, .regular), Theme.textMuted)
            nameLab.frame.origin = CGPoint(x: inset + sampleColW, y: (rowH - nameLab.frame.height) / 2)
            rowView.addSubview(nameLab)

            if fmt == current {
                let ck = lbl("✓", Theme.font(10, .bold), Theme.lavender)
                ck.frame.origin = CGPoint(x: w - ck.frame.width - inset, y: (rowH - ck.frame.height) / 2)
                rowView.addSubview(ck)
            }

            let btn = HoverButton(frame: rowView.bounds)
            btn.title = ""; btn.isBordered = false; btn.isTransparent = true
            btn.target = self; btn.action = #selector(pick(_:)); btn.tag = i
            btn.onHover = { [weak self] inside in self?.hover(i, inside) }
            rowView.addSubview(btn)
            container.addSubview(rowView)
        }
        return container
    }

    @objc private func pick(_ sender: NSButton) { choose(sender.tag) }
    @objc private func resigned() { close() }

    func close() {
        guard let win = window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: win)
        win.orderOut(nil); window = nil; onClose()
    }
}

/// Content view that forwards key presses (↑/↓/↵/esc) to the picker.
private final class KeyNavView: NSView {
    var onKey: ((UInt16) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode) }
}

/// A transparent click target that also reports pointer enter/exit, so rows get
/// a hover affordance for mouse users (keyboard users get arrow-key focus).
private final class HoverButton: NSButton {
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

