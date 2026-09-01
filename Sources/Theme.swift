// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// mesoneer brand palette + typography helpers.
///
/// Every value here is a named colour from the mesoneer brand guidelines
/// (Frontify → Guidelines → Colors); nothing is eyeballed. Deriving a new shade means
/// taking it from the published Primary/Secondary/Accent ramps, not mixing one by hand.
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // MARK: - Primary colours

    /// "Deep Trust" — the brand's darkest primary; every panel and overlay sits on it.
    static let surfaceBase    = rgb(0x19, 0x15, 0x28)
    /// "Night Indigo" — raised containers on top of `surfaceBase`.
    static let surfaceRaised  = rgb(0x30, 0x23, 0x55)
    /// "Signal Purple" — the brand's solid accent fill.
    static let accentPurple   = rgb(0x42, 0x29, 0x82)

    /// Primary tints 1.2 / 1.1 — the only two shades the brand defines *below* Signal
    /// Purple, and the first two stops of Gradient 1. They exist for that gradient; use
    /// `panelGradient` rather than reaching for them directly.
    static let primary12      = rgb(0x2b, 0x20, 0x49)
    static let primary11      = rgb(0x32, 0x24, 0x5b)

    // MARK: - Secondary / accent

    /// "Lavender Ease" — the brighter of the two secondary colours.
    static let lavenderEase   = rgb(0xc3, 0x9c, 0xff)
    /// "Light Lilac" — eyebrows, focus rings, quiet highlights.
    static let lavender       = rgb(0xd5, 0xba, 0xff)
    /// "Vibrant Coral" — the brand's single accent, used sparingly for emphasis and for
    /// the one state that has to shout: an active recording.
    static let accent         = rgb(0xff, 0x6d, 0x6a)
    /// Amber for states that deliberately aren't the real thing — currently the
    /// simulated-recording HUD, which must never be mistaken for a live capture.
    static let warning         = rgb(0xff, 0xb3, 0x4d)

    static let textPrimary     = NSColor.white
    static let ink             = NSColor(white: 1, alpha: 0.92)
    /// Primary 0.3 — the brand's own muted-on-dark step.
    static let textSecondary   = rgb(0xc6, 0xbf, 0xda)
    static let textMuted       = NSColor(white: 1, alpha: 0.6)
    static let eyebrow         = lavender

    /// Primary 1.1 — a hairline that is still a brand colour rather than a mixed grey.
    /// Primary 1.1 — a hairline that is still a brand colour rather than a mixed grey.
    /// Fine for a divider on a *known* backdrop; **not** for a form control's edge, which
    /// has to read wherever the panel gradient puts it — see `controlStroke`.
    static let border          = primary11

    // MARK: - Form controls

    /// A form control is a **translucent white veil over the panel**, not a coloured
    /// slab: a faint white fill with a slightly stronger white hairline. Because both
    /// scale with whatever is behind them, the control keeps the same *relative* contrast
    /// (fill ≈1.18:1, stroke ≈1.95:1) at every point of `panelGradient` — no part of the
    /// sweep can swallow it.
    ///
    /// This is also how the rest of `Theme` already does neutral surfaces (`hoverFill`
    /// 0.10, `divider` 0.18, `cardStroke` 0.22), so a form reads as the same material as
    /// everything around it.
    ///
    /// Two rejected approaches, both tried and rendered:
    /// * `surfaceRaised` fill + `border` edge — what this used to be. Once `panelGradient`
    ///   lifted to Primary 1.1 at the top-right, that was `#302355` on `#32245B`:
    ///   **1.03:1**, with the border at **1.00:1**. The controls vanished.
    /// * Deep Trust fill + a lavender hairline. Legible (~2.3:1) but ugly — near-black
    ///   boxes punched into a purple panel, ringed in accent colour on all six rows,
    ///   which reads as a debug wireframe and spends the brand's one accent on chrome.
    ///   Lavender is now reserved for **focus** (a recording shortcut field, an open
    ///   popup), which is where an accent belongs and where it now genuinely stands out.
    static let controlFill = NSColor(white: 1, alpha: 0.06)
    static let controlStroke = NSColor(white: 1, alpha: 0.16)
    /// Disabled: fainter, but the box is **never** absent — a control that loses its
    /// outline is indistinguishable from empty panel, which is the bug that started this.
    static let controlFillDisabled = NSColor(white: 1, alpha: 0.03)
    static let controlStrokeDisabled = NSColor(white: 1, alpha: 0.08)

    /// Muted content for a disabled control (~4:1 on `controlFill` — clearly inactive,
    /// still readable). Express "disabled" with these colours, **not** by dropping
    /// `alphaValue` on the control: a container that is already dimmed multiplies with
    /// it, and two 0.4s left the Padding/Corner-radius rows at 0.16 — ghosts.
    static let controlTextDisabled = NSColor(white: 1, alpha: 0.42)
    static let controlGlyphDisabled = lavender.withAlphaComponent(0.35)
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


    // MARK: - Typography

    /// Open Sans is the mesoneer corporate typeface; the brand approves exactly four
    /// styles (Regular, Regular Italic, SemiBold, Bold). We ship the variable roman face
    /// — `Resources/Fonts/OpenSans-Variable.ttf`, SIL OFL — and never use italic, so the
    /// italic file is deliberately not bundled.
    ///
    /// Registration is explicit rather than relying solely on the bundle's
    /// `ATSApplicationFontsPath`, because `tools/shots.swift` draws with `Theme` while
    /// running outside the app bundle. Resolved once; if the face is missing for any
    /// reason we fall back to the system font rather than refuse to draw.
    private static let brandFontRegistered: Bool = {
        let candidates = [
            Bundle.main.url(forResource: "OpenSans-Variable", withExtension: "ttf", subdirectory: "Fonts"),
            Bundle.main.url(forResource: "OpenSans-Variable", withExtension: "ttf"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Fonts/OpenSans-Variable.ttf"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { return true }
            // Already registered by ATSApplicationFontsPath — that is a success too.
            if NSFont(name: brandRegularFace, size: 12) != nil { return true }
        }
        return NSFont(name: brandRegularFace, size: 12) != nil
    }()

    private static let brandRegularFace  = "OpenSans-Regular"
    private static let brandSemiBoldFace = "OpenSansRoman-SemiBold"
    private static let brandBoldFace     = "OpenSansRoman-Bold"

    /// The brand's four styles collapse to three romans, so an arbitrary `NSFont.Weight`
    /// is *snapped* to one of them rather than matched loosely: descriptor matching would
    /// happily hand back Light or ExtraBold, both of which the guidelines exclude.
    private static func brandFace(for weight: NSFont.Weight) -> String {
        if weight.rawValue >= NSFont.Weight.bold.rawValue { return brandBoldFace }
        if weight.rawValue >= NSFont.Weight.medium.rawValue { return brandSemiBoldFace }
        return brandRegularFace
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        if brandFontRegistered, let f = NSFont(name: brandFace(for: weight), size: size) { return f }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Open Sans with tabular figures — for anything that counts up in place (the
    /// recording timer, the trim range) and would otherwise jitter as digits change width.
    static func monoDigitFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = font(size, weight)
        guard base.fontName != NSFont.systemFont(ofSize: size, weight: weight).fontName else {
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    // MARK: - Surfaces

    /// The brand's **Gradient 1**, verbatim: 45°, Primary 1.2 at 10% → Primary 1.1 at 40%
    /// → Signal Purple at 80%, running dark bottom-left to purple top-right. Text on it
    /// must be white.
    ///
    /// The guidelines scope it to *highlighting* — "larger areas such as sections, boxes
    /// or buttons" — so it is deliberately **not** the app's general chrome. Painting every
    /// panel with it makes Signal Purple the whole surface, which is the opposite of the
    /// restraint the colour system asks for; `panelGradient` is the calm surface, this is
    /// the emphasis you put *on* it (the brand icon, a highlighted box).
    static func highlightGradientColors() -> [NSColor] { [primary12, primary11, accentPurple] }
    static let highlightGradientLocations: [CGFloat] = [0.10, 0.40, 0.80]

    static func highlightGradient(cornerRadius: CGFloat = 0) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = highlightGradientColors().map(\.cgColor)
        g.locations = highlightGradientLocations.map(NSNumber.init)
        g.startPoint = CGPoint(x: 0, y: 0)   // bottom-left
        g.endPoint = CGPoint(x: 1, y: 1)     // top-right → 45°
        g.cornerRadius = cornerRadius
        g.masksToBounds = cornerRadius > 0
        return g
    }

    /// The shared brand panel surface, used by every panel/popover/card.
    ///
    /// Deep Trust deepening the bottom-left and lifting through the two Primary tints
    /// toward the top-right — Gradient 1's axis and hue family at a fraction of its
    /// strength. Every stop is a published brand value (the old ramp's `#2A1F50` and
    /// `#120D20` were neither), and the result stays a calm dark surface that white text
    /// and lavender eyebrows sit on cleanly. For an area the brand wants *highlighted*,
    /// reach for `highlightGradient` instead.
    ///
    /// Caller sets `.frame`; pass the panel's corner radius so the gradient clips to it.
    static func panelGradient(cornerRadius: CGFloat = 0) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = [surfaceBase.cgColor, primary12.cgColor, primary11.cgColor]
        g.locations = [0.10, 0.55, 1.0]
        g.startPoint = CGPoint(x: 0, y: 0)   // bottom-left
        g.endPoint = CGPoint(x: 1, y: 1)     // top-right → 45°
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

