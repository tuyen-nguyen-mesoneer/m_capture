// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Brand logo helpers. The "m." glyph is rendered once and trimmed to its real
/// ink bounds, so it can be centered precisely (lowercase text otherwise sits
/// low inside its line box).
enum Logo {
    /// Sentinel stamp value: an emoji-stamp whose `emoji` equals this renders the
    /// brand tile instead of a Unicode glyph (see `EmojiAnnotation` / `ToolButton`).
    static let stampToken = "::m_capture-logo::"

    /// The cropped glyph is reused across the app (About icon, menu bar, stamps),
    /// so compute it once — the ink-bounds pixel scan is the costly part.
    private static var glyphCache: (image: CGImage, aspect: CGFloat)?

    /// White "m." cropped to its ink, plus its width/height aspect ratio.
    private static func glyph() -> (image: CGImage, aspect: CGFloat)? {
        if let g = glyphCache { return g }
        let render = 160
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: render, pixelsHigh: render,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(CGFloat(render) * 0.6, .bold),
            .foregroundColor: NSColor.white,
        ]
        let g = "m."
        let gs = g.size(withAttributes: attrs)
        g.draw(at: CGPoint(x: (CGFloat(render) - gs.width) / 2,
                           y: (CGFloat(render) - gs.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        var minX = render, minY = render, maxX = 0, maxY = 0
        for y in 0..<render {
            for x in 0..<render where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY, let full = rep.cgImage,
              let cg = full.cropping(to: CGRect(x: minX, y: minY,
                                                width: maxX - minX + 1,
                                                height: maxY - minY + 1)) else { return nil }
        let result = (cg, CGFloat(cg.width) / CGFloat(cg.height))
        glyphCache = result
        return result
    }

    /// Gradient brand tile with a centered white "m." — for the About window.
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // mesoneer's "m." mark is a sharp square (no rounding); the diagonal glow
            // runs lighter top-right → deep bottom-left. Sampled from their webclip icon.
            let tile = NSBezierPath(rect: rect)
            NSGradient(starting: Theme.logoTileTop, ending: Theme.logoTileBottom)?.draw(in: tile, angle: 225)

            if let g = Logo.glyph() {
                let gw = size * 0.54
                let gh = gw / g.aspect
                NSImage(cgImage: g.image, size: NSSize(width: gw, height: gh))
                    .draw(in: NSRect(x: (size - gw) / 2, y: (size - gh) / 2, width: gw, height: gh))
            }
            return true
        }
    }

    /// Monochrome template image sized to fill the menu bar like other icons.
    static func menuBarImage() -> NSImage {
        let h: CGFloat = 16
        guard let g = Logo.glyph() else {
            let img = NSImage(size: NSSize(width: h, height: h), flipped: false) { rect in
                "m.".draw(in: rect, withAttributes: [
                    .font: Theme.font(h * 0.8, .bold),
                    .foregroundColor: NSColor.black])
                return true
            }
            img.isTemplate = true
            return img
        }
        let img = NSImage(cgImage: g.image, size: NSSize(width: h * g.aspect, height: h))
        img.isTemplate = true
        return img
    }
}
