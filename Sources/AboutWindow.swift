// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Small dark, mesoneer-styled About panel.
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Compact vertical rhythm, laid out top-down; the window height is derived
        // from it so the top (clears the close button) and bottom margins stay balanced.
        let side: CGFloat = 24
        let topClear: CGFloat = 40, logoSize: CGFloat = 80
        let titleH: CGFloat = 32, verH: CGFloat = 18, descH: CGFloat = 22, footerH: CGFloat = 16
        let gLogoTitle: CGFloat = 8, gTitleVer: CGFloat = 2, gVerDesc: CGFloat = 10
        let gDescDiv: CGFloat = 16, gDivFooter: CGFloat = 16, bottom: CGFloat = 24
        let height = topClear + logoSize + gLogoTitle + titleH + gTitleVer + verH
                   + gVerDesc + descH + gDescDiv + 1 + gDivFooter + footerH + bottom

        // The description is the widest element, so it sets the content width: the
        // panel is exactly as wide as the description + side margins, and the divider
        // spans the same width — both equal `descWidth`, inset by `side`. `sizeToFit`
        // measures the field's true width (incl. its internal padding) so it can't clip.
        let desc = label("Internal screen capture and recording tool",
                         font: Theme.font(12), color: Theme.textMuted)
        desc.sizeToFit()
        let descWidth = ceil(desc.frame.width)
        let size = NSSize(width: descWidth + side * 2, height: ceil(height))

        // Borderless so the corners are square (macOS rounds `.titled` windows); chrome
        // is supplied by PanelWindow (close button, Esc/⌘W, drag-to-move).
        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isMovableByWindowBackground = true
        w.backgroundColor = Theme.surfaceBase
        w.onClose = { [weak w] in w?.orderOut(nil) }

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        Theme.applyPanelGradient(to: content)

        // Lay out top-down: `top` tracks the y of the next element's top edge.
        var top = size.height - topClear

        let logo = NSImageView(frame: NSRect(x: (size.width - logoSize) / 2, y: top - logoSize,
                                             width: logoSize, height: logoSize))
        logo.image = Logo.image(size: logoSize)
        content.addSubview(logo)
        top -= logoSize + gLogoTitle

        let title = label("m_capture", font: Theme.font(26, .bold), color: Theme.textPrimary)
        title.frame = NSRect(x: 0, y: top - titleH, width: size.width, height: titleH)
        content.addSubview(title)
        top -= titleH + gTitleVer

        // Version — read from the bundle (set by build.sh) so it never drifts.
        // Quiet secondary identifier (lavender reserved for eyebrows only).
        let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let version = label(versionString, font: Theme.font(12, .bold), color: Theme.textSecondary)
        version.frame = NSRect(x: 0, y: top - verH, width: size.width, height: verH)
        content.addSubview(version)
        top -= verH + gVerDesc

        desc.frame = NSRect(x: side, y: top - descH, width: descWidth, height: descH)
        content.addSubview(desc)
        top -= descH + gDescDiv

        let divider = NSBox(frame: NSRect(x: side, y: top - 1, width: descWidth, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)
        top -= 1 + gDivFooter

        // Footer: a centered row of clickable links separated by a middot —
        // [MIT License] · [© 2026 mesoneer AG] — sitting `bottom` px off the edge.
        let footerFont = Theme.font(11)
        let licenseLink = LinkButton("MIT License", url: "https://github.com/tuyen-nguyen-mesoneer/m_capture/blob/main/LICENSE", font: footerFont)
        let dot = label("·", font: footerFont, color: Theme.textMuted)
        let mesoneerLink = LinkButton("© 2026 mesoneer AG", url: "https://www.mesoneer.io/?r=0", font: footerFont)

        let gap: CGFloat = 8
        licenseLink.sizeToFit()
        dot.sizeToFit()
        mesoneerLink.sizeToFit()
        let rowWidth = licenseLink.frame.width + dot.frame.width + mesoneerLink.frame.width + gap * 2
        var x = (size.width - rowWidth) / 2
        let rowY = top - footerH
        for v in [licenseLink, dot, mesoneerLink] as [NSView] {
            v.setFrameOrigin(NSPoint(x: x, y: rowY))
            content.addSubview(v)
            x += v.frame.width + gap
        }

        w.contentView = content
        w.installChrome(on: content)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.alignment = .center
        return l
    }
}

/// A borderless text link that opens a URL; lavender, underlined on hover.
private final class LinkButton: NSButton {
    private let url: URL?
    private let text: String
    private let linkFont: NSFont

    init(_ text: String, url urlString: String, font: NSFont) {
        self.url = URL(string: urlString)
        self.text = text
        self.linkFont = font
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        wantsLayer = true
        render(underline: false)
        target = self
        action = #selector(open)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func render(underline: Bool) {
        var attrs: [NSAttributedString.Key: Any] = [.font: linkFont, .foregroundColor: Theme.lavender]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    @objc private func open() {
        if let url { NSWorkspace.shared.open(url) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { render(underline: true) }
    override func mouseExited(with event: NSEvent) { render(underline: false) }
}
