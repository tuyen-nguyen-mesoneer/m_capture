// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A mesoneer-styled modal alert — the brand counterpart to `NSAlert`. Same
/// borderless, square-cornered panel chrome as About/Settings (gradient surface,
/// 1px brand border), shown modally so callers keep the simple
/// synchronous flow: `runModal()` returns the index of the clicked button.
///
/// Buttons are laid out left→right in the order given; mark one `primary` (filled,
/// triggered by Return) and one `cancel` (returned on Esc / when dismissed).
final class BrandAlert: NSObject {
    private let panel: AlertPanel
    private let cancelIndex: Int
    private var result: Int

    init(title: String, message: String, titles: [String], primary: Int, cancel: Int) {
        self.cancelIndex = cancel
        self.result = cancel

        let side: CGFloat = 24
        let contentWidth: CGFloat = 260
        let panelWidth = contentWidth + side * 2
        let topMargin: CGFloat = 24
        let gTitleMsg: CGFloat = 8, gMsgButtons: CGFloat = 16
        let buttonH: CGFloat = 36, bottom: CGFloat = 24

        let titleField = BrandAlert.wrapping(title, font: Theme.font(17, .bold),
                                             color: Theme.textPrimary, width: contentWidth)
        let msgField = BrandAlert.wrapping(message, font: Theme.font(13),
                                           color: Theme.textMuted, width: contentWidth)
        let titleH = titleField.frame.height, msgH = msgField.frame.height

        let height = topMargin + titleH + gTitleMsg + msgH + gMsgButtons + buttonH + bottom
        let size = NSSize(width: panelWidth, height: ceil(height))

        panel = AlertPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = Theme.surfaceBase
        panel.hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        Theme.applyPanelGradient(to: content)

        super.init()

        var top = size.height - topMargin

        titleField.setFrameOrigin(NSPoint(x: side, y: top - titleH))
        content.addSubview(titleField)
        top -= titleH + gTitleMsg

        msgField.setFrameOrigin(NSPoint(x: side, y: top - msgH))
        content.addSubview(msgField)
        top -= msgH + gMsgButtons

        let font = Theme.font(13, .semibold)
        let widths = titles.map { max(92, ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 36) }
        let gap: CGFloat = 10
        let rowWidth = widths.reduce(0, +) + gap * CGFloat(max(0, titles.count - 1))
        var x = (size.width - rowWidth) / 2
        let rowY = top - buttonH
        for (i, t) in titles.enumerated() {
            let b = BrandButton(title: t, kind: i == primary ? .primary : .secondary)
            b.frame = NSRect(x: x, y: rowY, width: widths[i], height: buttonH)
            b.tag = i
            b.target = self
            b.action = #selector(buttonClicked(_:))
            if i == primary { b.keyEquivalent = "\r" }
            content.addSubview(b)
            x += widths[i] + gap
        }

        panel.contentView = content
        panel.onCancel = { [weak self] in self?.dismiss(with: cancel) }
    }

    /// Show the panel modally and return the index of the button the user chose.
    @discardableResult
    func runModal() -> Int {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    @objc private func buttonClicked(_ sender: NSButton) { dismiss(with: sender.tag) }

    private func dismiss(with index: Int) {
        result = index
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: index))
    }

    /// A center-aligned wrapping label, sized to its wrapped height at `width`.
    private static func wrapping(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.alignment = .center
        f.preferredMaxLayoutWidth = width
        let height = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        f.frame = NSRect(x: 0, y: 0, width: width, height: ceil(height) + 2)
        return f
    }
}

/// Borderless window that can take key focus (so Return/Esc work) and routes Esc
/// to the alert's cancel action.
private final class AlertPanel: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A brand-styled pill button: `primary` is a solid `accentPurple` fill (white
/// text); `secondary` is a quiet hairline-bordered button that fills on hover.
private final class BrandButton: NSButton {
    enum Kind { case primary, secondary }
    private let kind: Kind
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(title: String, kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.font(13, .semibold),
            .foregroundColor: kind == .primary ? Theme.surfaceBase : Theme.textPrimary,
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .primary:
            (hovering ? NSColor(white: 0.90, alpha: 1) : .white).setFill()
            NSBezierPath(rect: bounds).fill()
        case .secondary:
            (hovering ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.07)).setFill()
            NSBezierPath(rect: bounds).fill()
            Theme.cardStroke.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
        }
        super.draw(dirtyRect)
    }
}

