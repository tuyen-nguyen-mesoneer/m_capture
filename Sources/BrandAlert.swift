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

    /// - Parameters:
    ///   - icon: An optional SF Symbol shown in a circular accent badge above the
    ///     title, for alerts that benefit from an at-a-glance visual (e.g. a trash
    ///     glyph for a destructive confirmation). Omit for a plain text alert.
    ///   - destructive: Button indices rendered in the accent-red destructive style
    ///     instead of primary/secondary — for actions like "Discard" or "Delete".
    init(title: String, message: String, titles: [String], primary: Int, cancel: Int,
         icon: String? = nil, destructive: Set<Int> = []) {
        self.cancelIndex = cancel
        self.result = cancel

        let side: CGFloat = 26
        // Width the message needs to lay out on a single line (up to a cap), so short
        // confirmations like "Discard capture?" read as one tidy line instead of
        // wrapping under the fixed 260 pt column.
        let minContentWidth: CGFloat = 260, maxContentWidth: CGFloat = 420
        let titleFont = Theme.font(17, .bold), msgFont = Theme.font(13)
        let neededWidth = max(BrandAlert.singleLineWidth(title, font: titleFont),
                              BrandAlert.singleLineWidth(message, font: msgFont))
        // +8 pt slack: a wrapping label reserves a few points of internal padding, so it
        // flows onto a second line unless its width clears the single-line text width by
        // that margin (see `wrapping`). Pad past the measured width to keep short messages
        // like the relaunch prompt on one tidy line.
        let contentWidth = min(max(minContentWidth, ceil(neededWidth) + 8), maxContentWidth)
        let panelWidth = contentWidth + side * 2
        let topMargin: CGFloat = 26
        let iconSize: CGFloat = 52, gIconTitle: CGFloat = 16
        let gTitleMsg: CGFloat = 8, gMsgButtons: CGFloat = 20
        let buttonH: CGFloat = 36, bottom: CGFloat = 26

        let titleField = BrandAlert.wrapping(title, font: titleFont,
                                             color: Theme.textPrimary, width: contentWidth)
        let msgField = BrandAlert.wrapping(message, font: msgFont,
                                           color: Theme.textMuted, width: contentWidth)
        let titleH = titleField.frame.height, msgH = msgField.frame.height
        let iconH: CGFloat = icon != nil ? iconSize + gIconTitle : 0

        let height = topMargin + iconH + titleH + gTitleMsg + msgH + gMsgButtons + buttonH + bottom
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

        if let icon {
            let badge = BrandAlert.iconBadge(icon, size: iconSize)
            badge.setFrameOrigin(NSPoint(x: (size.width - iconSize) / 2, y: top - iconSize))
            content.addSubview(badge)
            top -= iconSize + gIconTitle
        }

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
            let kind: BrandButton.Kind = destructive.contains(i) ? .destructive : (i == primary ? .primary : .secondary)
            let b = BrandButton(title: t, kind: kind)
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

    /// A circular accent-red badge with a white glyph, for the alert's optional icon.
    private static func iconBadge(_ symbolName: String, size: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        guard let layer = v.layer else { return v }
        layer.cornerRadius = size / 2
        layer.backgroundColor = Theme.accent.withAlphaComponent(0.18).cgColor
        layer.borderWidth = 1
        layer.borderColor = Theme.accent.withAlphaComponent(0.4).cgColor

        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
            let iv = NSImageView(frame: v.bounds)
            iv.image = img
            iv.imageScaling = .scaleNone
            iv.imageAlignment = .alignCenter
            iv.contentTintColor = Theme.accent
            v.addSubview(iv)
        }
        return v
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

    /// The width `text` needs to render on a single line in `font`.
    private static func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// A center-aligned wrapping label, sized to its wrapped height at `width`.
    private static func wrapping(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.alignment = .center
        f.preferredMaxLayoutWidth = width
        // Take the height from the field's own layout, not an independent `boundingRect`:
        // the two measurement paths disagree at the margin, so a `boundingRect` one-line
        // height could clip a label the field actually wraps onto a second line.
        let height = f.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
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
/// text); `secondary` is a quiet hairline-bordered button that fills on hover;
/// `destructive` is a solid accent-red fill for actions like Discard/Delete.
private final class BrandButton: NSButton {
    enum Kind { case primary, secondary, destructive }
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
        let textColor: NSColor
        switch kind {
        case .primary:     textColor = Theme.surfaceBase   // dark text on the white fill
        case .secondary:   textColor = Theme.textPrimary
        case .destructive: textColor = .white              // on the accent-red fill
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.font(13, .semibold), .foregroundColor: textColor,
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
        case .destructive:
            (hovering ? Theme.accent.blended(withFraction: 0.15, of: .black) ?? Theme.accent : Theme.accent).setFill()
            NSBezierPath(rect: bounds).fill()
        }
        super.draw(dirtyRect)
    }
}

