// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A menu-style rounded tool button used in the editor's tool clusters.
final class ToolButton: NSButton {
    enum Style {
        case tool(String)
        case text(String)
        case swatch(NSColor)
        case mosaic
        case spotlightGlyph
        case counterGlyph
        case roundedSquare
        case noneGlyph
        case plusGlyph
    }

    var tip: String?
    var onEnter: ((ToolButton) -> Void)?
    var onExit: (() -> Void)?
    var selectedState = false { didSet { needsDisplay = true } }
    /// Replaces the glyph for `.text` buttons at runtime (e.g. the live emoji stamp).
    var overrideText: String? { didSet { needsDisplay = true } }

    private let style: Style
    let radius: CGFloat
    private var hovering = false { didSet { needsDisplay = true } }

    static func size(radius r: CGFloat) -> NSSize { let s = r * 1.85; return NSSize(width: s, height: s) }

    init(style: Style, radius: CGFloat = 14, target: AnyObject?, action: Selector) {
        self.style = style
        self.radius = radius
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        // Never take first responder: clicking a tool tile (e.g. a color swatch to
        // recolor selected text) must not end the canvas's text-field editing.
        refusesFirstResponder = true
        wantsLayer = true
        let s = ToolButton.size(radius: radius)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: s.width).isActive = true
        heightAnchor.constraint(equalToConstant: s.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; onEnter?(self) }
    override func mouseExited(with event: NSEvent) { hovering = false; onExit?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let corner: CGFloat = 6
        let tile = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

        if case .swatch(let c) = style {
            if hovering {
                ctx.addPath(path); ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.fillPath()
            }
            let s = radius * 1.3
            let chip = CGRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
            let cr = s * 0.3
            let chipPath = CGPath(roundedRect: chip, cornerWidth: cr, cornerHeight: cr, transform: nil)
            ctx.addPath(chipPath); ctx.setFillColor(c.cgColor); ctx.fillPath()
            ctx.addPath(chipPath); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor); ctx.setLineWidth(1); ctx.strokePath()
            if selectedState {
                let r2 = chip.insetBy(dx: -3, dy: -3)
                ctx.addPath(CGPath(roundedRect: r2, cornerWidth: cr + 3, cornerHeight: cr + 3, transform: nil))
                ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
            }
            return
        }

        if selectedState {
            ctx.addPath(path); ctx.setFillColor(Theme.accentPurple.cgColor); ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: corner + 1, cornerHeight: corner + 1, transform: nil))
            ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
        } else if hovering {
            ctx.addPath(path); ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.fillPath()
        }

        switch style {
        case .tool(let symbol):
            let heavy = (symbol == "xmark")
            var conf = NSImage.SymbolConfiguration(pointSize: radius * 1.2, weight: heavy ? .light : .regular)
            conf = conf.applying(.init(paletteColors: [Theme.textPrimary]))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(conf) {
                let target = heavy ? glyphInk * 0.82 : glyphInk
                if let r = computeInkRect(img, target: target) {
                    img.draw(in: r)
                } else {
                    let box = target, sz = img.size
                    let f = sz.width > 0 && sz.height > 0 ? min(box / sz.width, box / sz.height) : 1
                    let w = sz.width * f, h = sz.height * f
                    img.draw(in: NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h))
                }
            }
        case .text(let t):
            let label = overrideText ?? t
            if label == Logo.stampToken {
                let box = radius * 1.4
                Logo.image(size: box).draw(in: NSRect(x: bounds.midX - box / 2, y: bounds.midY - box / 2, width: box, height: box))
                return
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(radius * 1.1, .bold),
                .foregroundColor: inkColor,
            ]
            let astr = NSAttributedString(string: label, attributes: attrs)
            let sz = astr.size()
            if sz.width > 0, sz.height > 0 {
                let img = NSImage(size: sz)
                img.lockFocus(); astr.draw(at: .zero); img.unlockFocus()
                if let r = computeInkRect(img, target: radius * 0.8) { img.draw(in: r) }
                else { img.draw(in: NSRect(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2, width: sz.width, height: sz.height)) }
            }
        case .mosaic:
            drawMosaic(ctx)
        case .spotlightGlyph:
            drawSpotlight(ctx)
        case .counterGlyph:
            drawCounter()
        case .roundedSquare:
            drawRoundedSquare(ctx)
        case .noneGlyph:
            drawNoSign(ctx)
        case .plusGlyph:
            drawPlus(ctx)
        case .swatch:
            break
        }
    }

    /// Target size for a `.tool` glyph's visible ink (its larger dimension). Every
    /// SF symbol and hand-drawn glyph is fitted to this so a row reads as one size.
    private var glyphInk: CGFloat { radius * 1.12 }

    private var glyphBox: CGRect {
        let s = glyphInk * 0.92
        return CGRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
    }
    private var glyphStroke: CGFloat { max(1.3, radius * 0.085) }
    private var inkColor: NSColor { Theme.ink }

    /// Visible-ink metrics of `image`: the ink center as fractions of the image
    /// (`cx` from left, `cyBottom` from bottom — CGContext row 0 is the bottom)
    /// and the ink size in points. Lets callers center on the ink rather than the
    /// image box, which for SF Symbols includes asymmetric cap-height padding.
    private func inkMetrics(_ image: NSImage) -> (cx: CGFloat, cyBottom: CGFloat, w: CGFloat, h: CGFloat)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let W = cg.width, H = cg.height
        guard W > 0, H > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        var minX = W, minY = H, maxX = -1, maxY = -1
        for y in 0..<H {
            let row = y * W
            for x in 0..<W where buf[(row + x) * 4 + 3] > 12 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let Wf = CGFloat(W), Hf = CGFloat(H)
        let ppp = Wf / max(1, image.size.width)
        return (cx: (CGFloat(minX + maxX) / 2 + 0.5) / Wf,
                cyBottom: (CGFloat(minY + maxY) / 2 + 0.5) / Hf,
                w: CGFloat(maxX - minX + 1) / ppp,
                h: CGFloat(maxY - minY + 1) / ppp)
    }

    /// A draw rect that centers `image`'s visible ink on the tile center and sizes
    /// the ink's larger dimension to `target`. Fixes glyphs whose ink isn't
    /// centered in their image box (magnifier, pin, arrows, text line-boxes).
    private func computeInkRect(_ image: NSImage, target: CGFloat) -> NSRect? {
        guard let m = inkMetrics(image) else { return nil }
        let s = target / max(m.w, m.h)
        let drawW = image.size.width * s, drawH = image.size.height * s
        return NSRect(x: bounds.midX - m.cx * drawW,
                      y: bounds.midY - m.cyBottom * drawH,
                      width: drawW, height: drawH)
    }

    /// Blur: a dense checkerboard of pixels (clearly reads as pixelation).
    private func drawMosaic(_ ctx: CGContext) {
        let a = glyphBox.insetBy(dx: glyphBox.width * 0.06, dy: glyphBox.height * 0.06)
        let n = 4
        let cell = a.width / CGFloat(n)
        let gap: CGFloat = 1.0
        ctx.setFillColor(inkColor.cgColor)
        for r in 0..<n {
            for c in 0..<n where (r + c) % 2 == 0 {
                ctx.fill(CGRect(x: a.minX + CGFloat(c) * cell + gap / 2,
                                y: a.minY + CGFloat(r) * cell + gap / 2,
                                width: cell - gap, height: cell - gap))
            }
        }
    }

    /// Spotlight: a sun (centre disc + rays).
    private func drawSpotlight(_ ctx: CGContext) {
        let a = glyphBox
        let c = CGPoint(x: a.midX, y: a.midY)
        let rr = a.width * 0.17
        ctx.setFillColor(inkColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(glyphStroke); ctx.setLineCap(.round)
        for i in 0..<8 {
            let ang = CGFloat(i) * .pi / 4
            ctx.move(to: CGPoint(x: c.x + cos(ang) * a.width * 0.30, y: c.y + sin(ang) * a.width * 0.30))
            ctx.addLine(to: CGPoint(x: c.x + cos(ang) * a.width * 0.47, y: c.y + sin(ang) * a.width * 0.47))
        }
        ctx.strokePath()
    }

    /// Rounded-rectangle shape: a stroked rounded box matching the `rectangle`
    /// SF Symbol beside it (slightly wider than tall).
    private func drawRoundedSquare(_ ctx: CGContext) {
        let w = glyphBox.width, h = glyphBox.width * 0.8
        let a = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let r = h * 0.28
        ctx.addPath(CGPath(roundedRect: a, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(glyphStroke); ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// "No background": a circle with a diagonal slash, drawn centered on
    /// `glyphBox` (the SF `nosign` symbol renders off-center at this size).
    private func drawNoSign(_ ctx: CGContext) {
        let a = glyphBox
        let c = CGPoint(x: a.midX, y: a.midY)
        let r = a.width / 2
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(glyphStroke)
        ctx.setLineCap(.round)
        ctx.strokeEllipse(in: a)
        let d = r * cos(.pi / 4)
        ctx.move(to: CGPoint(x: c.x - d, y: c.y + d))
        ctx.addLine(to: CGPoint(x: c.x + d, y: c.y - d))
        ctx.strokePath()
    }

    /// "+" add-custom-color: two strokes crossing at the center of `glyphBox`
    /// (text "+" centers on the line box, which sits the glyph visibly high).
    private func drawPlus(_ ctx: CGContext) {
        let c = CGPoint(x: glyphBox.midX, y: glyphBox.midY)
        let arm = glyphBox.width * 0.4
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(glyphStroke)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - arm, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + arm, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - arm)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + arm))
        ctx.strokePath()
    }

    /// Counter: a ringed "1" badge.
    private func drawCounter() {
        let ring = NSBezierPath(ovalIn: glyphBox)
        ring.lineWidth = glyphStroke
        inkColor.setStroke()
        ring.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(glyphBox.width * 0.62, .bold),
            .foregroundColor: inkColor,
        ]
        let ts = "1".size(withAttributes: attrs)
        "1".draw(at: CGPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2),
                 withAttributes: attrs)
    }
}

