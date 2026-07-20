// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Shared geometry so the brand pop-up button, text field, and shortcut field
/// align their text (the control column width is owned by the form layout).
enum BrandControl {
    static let textInset: CGFloat = 11
}

/// A brand-styled pop-up button. The default `NSPopUpButton` bezel reads as a
/// black system pill against the dark purple panel and its drop-down is an
/// unthemed NSMenu, so this draws a rounded `surfaceRaised` button (white title,
/// lavender chevron) and, on click, shows its own brand-styled list window
/// (`BrandPopUpList`) instead of the system menu — same approach as `BrandMenu`,
/// which exists because NSMenu can't be themed.
final class BrandPopUpButton: NSPopUpButton {
    private var list: BrandPopUpList?
    /// Own title label, drawn left-aligned. The cell's built-in title is
    /// suppressed (it centers and resists styling), so this is the visible title.
    private let titleLabel = NSTextField(labelWithString: "")
    /// Set false to drop the selected-row checkmark in the dropdown list — useful
    /// where the button's own title already makes the current value obvious.
    var showsCheckmark = true

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        let c = BrandPopUpCell(textCell: "", pullsDown: pullsDown)
        c.menu = menu
        cell = c
        isBordered = true

        titleLabel.font = Theme.font(12)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BrandControl.textInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `NSControl.isEnabled` has no built-in effect here since `mouseDown` is fully
    /// overridden below — dim the whole control (title, bezel, chevron together) and
    /// block interaction explicitly.
    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Match the height of the brand text fields/checkboxes around it.
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.height = 24
        return s
    }

    /// Route all clicks inside the control to the button itself (so the title
    /// label doesn't swallow them) and open the themed list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private func refreshTitle() { titleLabel.stringValue = titleOfSelectedItem ?? "" }

    override func selectItem(at index: Int) { super.selectItem(at: index); refreshTitle() }
    override func selectItem(withTitle title: String) { super.selectItem(withTitle: title); refreshTitle() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, list == nil else { return }
        let l = BrandPopUpList(button: self, showsCheckmark: showsCheckmark,
                               onSelect: { [weak self] idx in
                                   guard let self else { return }
                                   self.list = nil
                                   self.selectItem(at: idx)
                                   if let action = self.action { NSApp.sendAction(action, to: self.target, from: self) }
                               },
                               onClose: { [weak self] in self?.list = nil })
        list = l
        l.present()
    }
}

private final class BrandPopUpCell: NSPopUpButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let r = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall)
        Theme.surfaceRaised.setFill()
        path.fill()
        Theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        drawChevron(in: r)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
}

/// A downward lavender chevron on the closed button (the cell draws in a flipped
/// context, so the apex sits below the shoulders here).
private func drawChevron(in r: NSRect) {
    let cx = r.maxX - 13, cy = r.midY
    let chev = NSBezierPath()
    chev.move(to: NSPoint(x: cx - 4, y: cy - 2.5))
    chev.line(to: NSPoint(x: cx, y: cy + 2.5))
    chev.line(to: NSPoint(x: cx + 4, y: cy - 2.5))
    chev.lineWidth = 1.5
    chev.lineCapStyle = .round
    chev.lineJoinStyle = .round
    Theme.lavender.setStroke()
    chev.stroke()
}

private final class PopUpListWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A compact brand-styled list shown under a `BrandPopUpButton` — the themed
/// replacement for the system pop-up menu. Lavender check on the selected row,
/// purple hover, closes on outside click.
final class BrandPopUpList {
    private let button: NSPopUpButton
    private let showsCheckmark: Bool
    private let onSelect: (Int) -> Void
    private let onClose: () -> Void
    private var window: PopUpListWindow?

    private let rowH: CGFloat = 32
    private let pad: CGFloat = 6

    init(button: NSPopUpButton, showsCheckmark: Bool = true,
         onSelect: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        self.button = button
        self.showsCheckmark = showsCheckmark
        self.onSelect = onSelect
        self.onClose = onClose
    }

    func present() {
        let titles = button.itemTitles
        guard !titles.isEmpty, let bwin = button.window else { return }
        let selected = button.indexOfSelectedItem
        let width = button.bounds.width
        let total = CGFloat(titles.count) * rowH + 2 * pad

        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        Theme.stylePanel(container)

        for (i, title) in titles.enumerated() {
            let row = PopUpRow(width: width, height: rowH, title: title,
                               checked: i == selected, showsCheckmark: showsCheckmark) { [weak self] in
                self?.close()
                self?.onSelect(i)
            }
            row.frame = NSRect(x: 0, y: pad + CGFloat(i) * rowH, width: width, height: rowH)
            container.addSubview(row)
        }

        let win = PopUpListWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: total),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        Theme.styleOverlayWindow(win)
        win.level = .popUpMenu
        win.contentView = container

        let onScreen = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (NSScreen.screens.first { $0.frame.intersects(onScreen) } ?? NSScreen.main)?.frame
        var topY = onScreen.minY - 3
        if let f = screen {
            let fitsBelow = (onScreen.minY - 3 - total) >= f.minY + 8
            if !fitsBelow { topY = onScreen.maxY + 3 + total }
            topY = min(max(topY, f.minY + 8 + total), f.maxY - 8)
        }
        win.setFrameTopLeftPoint(NSPoint(x: onScreen.minX, y: topY))

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: NSWindow.didResignKeyNotification, object: win)
    }

    @objc private func resigned() { close(); onClose() }

    private func close() {
        guard let win = window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: win)
        win.orderOut(nil)
        window = nil
    }
}

/// One row in the list: optional lavender check, title, and an inset rounded
/// purple highlight on hover (margins on all sides so it reads as a pill, not a
/// full-bleed block).
private final class PopUpRow: NSView {
    private let onClick: () -> Void
    private let highlight = NSView()

    /// Left/right and top/bottom margins around the hover pill.
    private static let hInset: CGFloat = 6
    private static let vInset: CGFloat = 3

    init(width: CGFloat, height: CGFloat, title: String, checked: Bool, showsCheckmark: Bool = true,
         onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true

        highlight.frame = bounds.insetBy(dx: Self.hInset, dy: Self.vInset)
        highlight.autoresizingMask = [.width, .height]
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(highlight)

        let checkX = Self.hInset + 8
        // Without a checkmark, the text starts where the checkmark would have —
        // no dead indent reserved for an icon that isn't there.
        let textX = showsCheckmark ? checkX + 20 : checkX
        if checked, showsCheckmark, let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let iv = NSImageView(frame: NSRect(x: checkX, y: (height - 12) / 2, width: 13, height: 12))
            iv.image = img.withSymbolConfiguration(cfg)
            iv.contentTintColor = Theme.lavender
            iv.imageScaling = .scaleProportionallyUpOrDown
            addSubview(iv)
        }

        let name = NSTextField(labelWithString: title)
        name.font = Theme.font(12, checked ? .semibold : .regular)
        name.textColor = Theme.textPrimary
        name.alignment = .left
        name.lineBreakMode = .byClipping
        name.frame = NSRect(x: textX, y: (height - 16) / 2, width: width - textX - Self.hInset, height: 16)
        addSubview(name)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { highlight.layer?.backgroundColor = Theme.accentPurple.cgColor }
    override func mouseExited(with event: NSEvent) { highlight.layer?.backgroundColor = NSColor.clear.cgColor }
    override func mouseUp(with event: NSEvent) {
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        onClick()
    }
}

