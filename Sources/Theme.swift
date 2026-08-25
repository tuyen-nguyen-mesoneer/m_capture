// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// mesoneer brand palette + typography helpers.
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static let surfaceBase    = rgb(0x19, 0x15, 0x28)
    static let surfaceRaised  = rgb(0x30, 0x23, 0x55)
    static let gradientTop    = rgb(0x2a, 0x1f, 0x50)
    static let gradientBottom = rgb(0x12, 0x0d, 0x20)

    static let accentPurple    = rgb(0x43, 0x2a, 0x84)
    static let lavender        = rgb(0xd5, 0xba, 0xff)
    static let accent          = rgb(0xff, 0x67, 0x5c)
    /// Amber for states that deliberately aren't the real thing — currently the
    /// simulated-recording HUD, which must never be mistaken for a live capture.
    static let warning         = rgb(0xff, 0xb3, 0x4d)

    static let textPrimary     = NSColor.white
    static let ink             = NSColor(white: 1, alpha: 0.92)
    static let textSecondary   = rgb(0xc6, 0xbe, 0xda)
    static let textMuted       = NSColor(white: 1, alpha: 0.6)
    static let eyebrow         = lavender

    static let border          = rgb(0x3a, 0x2f, 0x5e)
    static let divider         = NSColor(white: 1, alpha: 0.18)
    /// Drop shadow behind text drawn over an unknown backdrop (the editor's tool
    /// cards sit on whatever the user captured).
    static let textShadow      = NSColor(white: 0, alpha: 0.6)
    static let cardStroke      = NSColor(white: 1, alpha: 0.22)
    static let hoverFill        = NSColor(white: 1, alpha: 0.10)
    static let focusRing        = lavender

    /// The brand is square-cornered: every panel, chip, badge, banner, hover highlight
    /// and tile draws at 0. Kept as named tokens rather than bare zeros so the shape is
    /// one decision in one place, and so it can't be confused with the radii that are
    /// *content* rather than chrome — `Background`'s user-configurable image corner and
    /// the editor's rounded-rectangle annotation tool both stay rounded.
    static let radiusSmall: CGFloat = 0
    static let radiusMedium: CGFloat = 0

    static let logoTileTop    = rgb(0x41, 0x28, 0x80)
    static let logoTileBottom = rgb(0x2a, 0x20, 0x48)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// The shared brand panel gradient (top-left lavender-purple glow → base → deep),
    /// used by every panel/popover/card. Caller sets `.frame`. Pass the panel's corner
    /// radius so the gradient clips to it.
    static func panelGradient(cornerRadius: CGFloat = 0) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = [gradientTop.cgColor, surfaceBase.cgColor, gradientBottom.cgColor]
        g.locations = [0, 0.55, 1]
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        g.cornerRadius = cornerRadius
        g.masksToBounds = cornerRadius > 0
        return g
    }

    /// Insert the shared `panelGradient` behind everything already in `view`
    /// (frozen to its current bounds — these panels don't resize). Layer-backs
    /// the view first if needed.
    @discardableResult
    static func applyPanelGradient(to view: NSView, cornerRadius: CGFloat = 0) -> CAGradientLayer {
        view.wantsLayer = true
        let g = panelGradient(cornerRadius: cornerRadius)
        g.frame = view.bounds
        view.layer?.insertSublayer(g, at: 0)
        return g
    }

    /// Style `view` as a brand popover: the panel gradient behind its content, square
    /// corners, no border — the single panel style across the app (menu, Settings/About,
    /// pickers). Its window supplies a drop shadow to define the edge. Call once `view` is sized.
    static func stylePanel(_ view: NSView, cornerRadius: CGFloat = 0) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        applyPanelGradient(to: view, cornerRadius: cornerRadius)
    }

    /// Style `view` as a small floating card: **the same surface the status-item menu uses** —
    /// flat `surfaceBase` under `panelGradient` — plus a hairline edge and square corners. For
    /// the editor's tool cards and its inline bars, so the chrome floating over a capture reads
    /// as the same material as the menu the app opens from.
    ///
    /// Layered exactly as `BrandMenu` does it, and the order matters twice over: the opaque
    /// `backgroundColor` is what a caller's drop shadow derives its shape from (crisper than
    /// compositing one out of sublayers), and a layer draws its border *above* its sublayers,
    /// so the hairline survives the gradient sitting on top of the fill.
    ///
    /// Known trade: `panelGradient` is a 45° three-stop sweep scaled to a whole panel, so on a
    /// 126 pt card it is compressed to a short diagonal wash rather than the full sweep the
    /// menu shows. Matching the menu is the point; if a card ever needs to read flatter, the
    /// answer is a gentler gradient in `panelGradient`, not a different surface here.
    static func styleFloatingCard(_ view: NSView, cornerRadius: CGFloat = radiusSmall,
                                  stroke: NSColor = cardStroke) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.backgroundColor = surfaceBase.cgColor
        applyPanelGradient(to: view, cornerRadius: cornerRadius)
        layer.borderColor = stroke.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = cornerRadius
    }

    /// Make a borderless `window` transparent with a drop shadow so a rounded
    /// panel content view shows through. The caller sets `.level`/`.contentView`.
    static func styleOverlayWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }

    /// Style a label as a brand eyebrow: UPPERCASE, lavender, lightly tracked.
    /// (The single most recognizable mesoneer.io move — used ONLY on short labels.)
    /// `color` overrides the lavender for eyebrows that carry a state, e.g. the
    /// amber "SIM" on a simulated recording.
    static func styleEyebrow(_ field: NSTextField, _ text: String, size: CGFloat = 11,
                             color: NSColor = eyebrow) {
        field.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .foregroundColor: color,
            .font: font(size, .medium),
            .kern: 1.2,
        ])
        field.drawsBackground = false
        field.isBezeled = false
        field.isEditable = false
    }
}

