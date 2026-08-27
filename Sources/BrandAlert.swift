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
    /// The widest a message line may be before the alert wraps it. Callers that compose
    /// a multi-line body — the updater's change log — truncate against this and pass it
    /// as `maxWidth`, so their lines are laid out whole rather than folded in half.
    static let wideMessageWidth: CGFloat = 520

    init(title: String, message: String, titles: [String], primary: Int, cancel: Int,
         icon: String? = nil, destructive: Set<Int> = [],
         maxWidth: CGFloat = 380, attributedMessage: NSAttributedString? = nil) {
        self.cancelIndex = cancel
        self.result = cancel

        // Native-alert composition: icon badge on the left, left-aligned title and
        // message beside it, buttons bottom-right — the shape people's eyes already
        // know from NSAlert, in brand colors. (The old centered stack read slower.)
        let side: CGFloat = 22
        let iconSize: CGFloat = 40, gIconText: CGFloat = 14
        let textX: CGFloat = icon != nil ? side + iconSize + gIconText : side
        let minTextWidth: CGFloat = 280, maxTextWidth = maxWidth
        let titleFont = Theme.font(14, .bold), msgFont = Theme.font(12)
        // Measure a multi-line body line by line. Measuring the whole string as one run
        // returns the width of every line laid end to end — a nonsense number that just
        // slams into the cap, so a two-line message and a twelve-line one both came out
        // at the maximum width regardless of how wide their longest line really was.
        let widestLine = message.components(separatedBy: "\n")
            .map { BrandAlert.singleLineWidth($0, font: msgFont) }
            .max() ?? 0
        let neededWidth = max(BrandAlert.singleLineWidth(title, font: titleFont), widestLine)
        // +8 pt slack: a wrapping label reserves a few points of internal padding, so it
        // flows onto a second line unless its width clears the single-line text width by
        // that margin (see `wrapping`).
        var textWidth = min(max(minTextWidth, ceil(neededWidth) + 8), maxTextWidth)
        // The button row must also fit: buttons are right-aligned under the text.
        let btnFont = Theme.font(13, .semibold)   // matches BrandButton's title font
        let btnWidths = titles.map { max(84, ceil(($0 as NSString).size(withAttributes: [.font: btnFont]).width) + 32) }
        let btnGap: CGFloat = 8
        let btnRowWidth = btnWidths.reduce(0, +) + btnGap * CGFloat(max(0, titles.count - 1))
        textWidth = max(textWidth, btnRowWidth)
        let panelWidth = textX + textWidth + side
        let topMargin: CGFloat = 20
        let gTitleMsg: CGFloat = 5, gMsgButtons: CGFloat = 18
        let buttonH: CGFloat = 30, bottom: CGFloat = 18

        let titleField = BrandAlert.wrapping(title, font: titleFont,
                                             color: Theme.textPrimary, width: textWidth)
        let msgField: NSView = attributedMessage.map { AlertBody($0, width: textWidth) }
            ?? BrandAlert.wrapping(message, font: msgFont, color: Theme.textMuted, width: textWidth)
        let titleH = titleField.frame.height, msgH = msgField.frame.height

        let textBlock = titleH + gTitleMsg + msgH
        // The icon column never dictates extra height unless the text is shorter
        // than the badge.
        let bodyH = max(textBlock, icon != nil ? iconSize : 0)
        let height = topMargin + bodyH + gMsgButtons + buttonH + bottom
        let size = NSSize(width: panelWidth, height: ceil(height))

        panel = AlertPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // Above the capture overlays (`.screenSaver`): an alert at the default `.normal`
        // level that fires while an overlay dims every display opens *underneath* it —
        // invisible and unclickable while `runModal` holds the app, which reads as a
        // total freeze. Alerts are rare and modal, so always-on-top is the safe default.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = Theme.surfaceBase
        panel.hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        Theme.applyPanelGradient(to: content)

        super.init()

        let top = size.height - topMargin

        // Icon badge tops-aligned with the title, in its own left column.
        if let icon {
            let badge = BrandAlert.iconBadge(icon, size: iconSize)
            badge.setFrameOrigin(NSPoint(x: side, y: top - iconSize))
            content.addSubview(badge)
        }

        titleField.setFrameOrigin(NSPoint(x: textX, y: top - titleH))
        content.addSubview(titleField)
        msgField.setFrameOrigin(NSPoint(x: textX, y: top - titleH - gTitleMsg - msgH))
        content.addSubview(msgField)

        // Buttons bottom-right in macOS order regardless of the order call sites
        // pass them: the primary (Return) action rightmost, cancel immediately to
        // its left, anything else further left. Enforced here so every dialog in
        // the app reads consistently; tags keep the caller's original indices.
        func rank(_ i: Int) -> Int { i == primary ? 2 : (i == cancel ? 1 : 0) }
        let layoutOrder = titles.indices.sorted { (rank($0), $0) < (rank($1), $1) }
        var x = size.width - side - btnRowWidth
        for i in layoutOrder {
            let kind: BrandButton.Kind = destructive.contains(i) ? .destructive : (i == primary ? .primary : .secondary)
            let b = BrandButton(title: titles[i], kind: kind)
            b.frame = NSRect(x: x, y: bottom, width: btnWidths[i], height: buttonH)
            b.tag = i
            b.target = self
            b.action = #selector(buttonClicked(_:))
            if i == primary { b.keyEquivalent = "\r" }
            content.addSubview(b)
            x += btnWidths[i] + btnGap
        }

        panel.contentView = content
        panel.onCancel = { [weak self] in self?.dismiss(with: cancel) }
    }

    /// A circular accent-red badge with a white glyph, for the alert's optional icon.
    private static func iconBadge(_ symbolName: String, size: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        guard let layer = v.layer else { return v }
        layer.cornerRadius = Theme.radiusSmall
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

    /// Put the panel on the display the user is looking at (`NSWindow.centerOnActiveScreen`,
    /// shared with the app's panels).
    ///
    /// This is what fixed the discard confirm that opened on the *built-in* display while the
    /// capture being discarded was on a second one: nothing appeared over the picture, and
    /// `runModal` held the app meanwhile, so the editor read as frozen rather than as waiting
    /// for an answer somewhere off-screen. The window level was never the problem —
    /// `.screenSaver + 2` was already above everything.
    ///
    /// Ordering is the one rule: it has to run *before* `makeKeyAndOrderFront`, while the
    /// window being answered for is still key.
    ///
    /// Dead centre, unlike the app's panels: an alert is raised over the capture or the
    /// recording it is asking about, and AppKit's traditional bias toward the upper third
    /// left the question sitting above the picture rather than on it.
    private func centerOnActiveScreen() { panel.centerOnActiveScreen(verticallyCentred: true) }

    /// Show the panel modally and return the index of the button the user chose.
    /// Reserve this for user-initiated flows that genuinely can't continue without
    /// an answer; anything fired from a background context (updater, async save
    /// failures) must use `present` — a nested `NSApp.runModal` from a callback
    /// freezes whatever run loop it lands on.
    @discardableResult
    func runModal() -> Int {
        centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    /// Non-modal presentation: shows the panel and returns immediately; `completion`
    /// gets the clicked button index (the cancel index on Esc/close). The alert
    /// retains itself while on screen.
    private var presentCompletion: ((Int) -> Void)?
    private static var presented: [BrandAlert] = []
    func present(completion: ((Int) -> Void)? = nil) {
        presentCompletion = completion
        Self.presented.append(self)
        centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func buttonClicked(_ sender: NSButton) { dismiss(with: sender.tag) }

    private func dismiss(with index: Int) {
        result = index
        if NSApp.modalWindow == panel {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: index))
        } else {
            panel.orderOut(nil)
            Self.presented.removeAll { $0 === self }
            let done = presentCompletion
            presentCompletion = nil
            done?(index)
        }
    }

    /// The width `text` needs to render on a single line in `font`.
    private static func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// A left-aligned wrapping label, sized to its wrapped height at `width`.
    private static func wrapping(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.alignment = .natural   // native-alert layout: text reads left-aligned
        f.preferredMaxLayoutWidth = width
        // Take the height from the field's own layout, not an independent `boundingRect`:
        // the two measurement paths disagree at the margin, so a `boundingRect` one-line
        // height could clip a label the field actually wraps onto a second line.
        let height = f.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        f.frame = NSRect(x: 0, y: 0, width: width, height: ceil(height) + 2)
        return f
    }
}

/// Draws a styled alert body itself.
///
/// `NSTextField` re-derives what it displays from `stringValue` plus the field's *own*
/// font and colour whenever it re-renders for a window state change — so the first click
/// on the alert (which makes the panel key) flattened every highlighted version heading
/// back to plain body text. A view that owns the attributed string has nothing to
/// re-derive from and cannot lose it.
private final class AlertBody: NSView {
    private let text: NSAttributedString
    private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    init(_ text: NSAttributedString, width: CGFloat) {
        self.text = text
        super.init(frame: .zero)
        let bounds = text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude), options: Self.options)
        frame = NSRect(x: 0, y: 0, width: width, height: ceil(bounds.height) + 2)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Top-down, so `draw(with:)` lays the first line out at the top of the view.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: bounds, options: Self.options)
    }
}

/// Borderless window that can take key focus (so Return/Esc work) and routes Esc
/// to the alert's cancel action.
private final class AlertPanel: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Floor the level at `.screenSaver + 2` — the alert's whole reason for being up there is
    /// to clear the editor and the capture overlays.
    ///
    /// **`NSApp.runModal(for:)` reassigns the window's level to `.modalPanel` (8) when the
    /// session begins**, so setting the level at init was silently undone on every modal
    /// alert: the panel dropped ~1000 levels, landed *behind* the `.screenSaver` editor, and
    /// stayed modal — an invisible window swallowing every click, which reads as the app
    /// freezing with a dialog stuck behind the picture. Clamping the setter fixes it for good
    /// rather than racing AppKit to re-assert the level afterwards, and it cannot be undone by
    /// a future caller either. The `present` path never hit this, which is why only the
    /// `runModal` confirms (discard capture, discard recording) misbehaved.
    static let minLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    override var level: NSWindow.Level {
        get { super.level }
        set { super.level = newValue.rawValue < Self.minLevel.rawValue ? Self.minLevel : newValue }
    }
}

/// A brand-styled pill button: `primary` is a solid `accentPurple` fill (white
/// text); `secondary` is a quiet hairline-bordered button that fills on hover;
/// `destructive` is a solid accent-red fill for actions like Discard/Delete.
/// Internal (not private) so other brand panels — e.g. the trim window — reuse it.
final class BrandButton: NSButton {
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

