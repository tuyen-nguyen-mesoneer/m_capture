// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// mesoneer brand palette + typography helpers.
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // — Surfaces (the dark mesoneer.io purple) —
    static let surfaceBase    = rgb(0x19, 0x15, 0x28) // #191528 hero/base surface
    static let surfaceRaised  = rgb(0x30, 0x23, 0x55) // #302355 raised container
    static let gradientTop    = rgb(0x2a, 0x1f, 0x50) // #2a1f50 top-left glow of the panel gradient
    static let gradientBottom = rgb(0x12, 0x0d, 0x20) // #120d20 deep bottom-right of the gradient

    // — Accents —
    static let accentPurple    = rgb(0x43, 0x2a, 0x84) // #432a84 solid purple fill/border
    static let lavender        = rgb(0xd5, 0xba, 0xff) // #d5baff brand lavender (eyebrows, strokes, glyphs)
    static let accent          = rgb(0xff, 0x67, 0x5c) // #ff675c coral accent (default annotation color)

    // — Text roles —
    static let textPrimary     = NSColor.white                  // headings + body
    static let ink             = NSColor(white: 1, alpha: 0.92) // softened-white glyph + content ink on dark
    static let textSecondary   = rgb(0xc6, 0xbe, 0xda)          // #c6beda quiet lilac (grouping/labels)
    static let textMuted       = NSColor(white: 1, alpha: 0.6)  // styleguide muted-white body-secondary
    static let eyebrow         = lavender                       // UPPERCASE tracked labels ONLY

    // — Lines / states —
    static let border          = rgb(0x3a, 0x2f, 0x5e)          // #3a2f5e hairline
    static let divider         = NSColor(white: 1, alpha: 0.18) // hairline separator over a dark panel
    static let cardStroke      = NSColor(white: 1, alpha: 0.22) // translucent edge on floating editor cards
    static let hoverFill        = NSColor(white: 1, alpha: 0.10) // pointer hover on custom rows/cells
    static let focusRing        = lavender                       // keyboard focus ring

    // — Geometry scale —
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 12

    // — Logo tile (sampled from mesoneer.io's official "m." webclip icon) —
    static let logoTileTop    = rgb(0x41, 0x28, 0x80) // #412880 bright top-right corner
    static let logoTileBottom = rgb(0x2a, 0x20, 0x48) // #2a2048 deep bottom-left corner

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

    /// Style `view` as a rounded brand popover: clipped corners, a hairline
    /// border, and the panel gradient behind its content. Call once `view` is sized.
    static func stylePanel(_ view: NSView, cornerRadius: CGFloat = radiusMedium) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = border.cgColor
        applyPanelGradient(to: view, cornerRadius: cornerRadius)
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
    static func styleEyebrow(_ field: NSTextField, _ text: String, size: CGFloat = 11) {
        field.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .foregroundColor: eyebrow,
            .font: font(size, .medium),
            .kern: 1.2,
        ])
        field.drawsBackground = false
        field.isBezeled = false
        field.isEditable = false
    }
}
