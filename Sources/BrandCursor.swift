// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Builds mesoneer-styled pointer cursors from SF Symbols.
///
/// Two styles, because they answer to different constraints. `make` is the editor's tool
/// cursor: a brand-purple glyph with a soft white halo and **no chip**, so a pencil or crop
/// tip stays visible over the pixel it is about to touch. `makeOutlined` is the capture
/// overlay's: a white glyph with a brand keyline, because there the cursor is the only thing
/// telling you what a click will do, and it has to carry that across a dimmed screenshot of
/// *anything* — without a slab of colour following the pointer around.
enum BrandCursor {
    /// - Parameters:
    ///   - name: SF Symbol name; returns `nil` if the symbol is unavailable.
    ///   - tipHotspot: put the active point at the glyph's lower-left tip (pencil-like
    ///     tools) rather than its centre.
    static func make(symbol name: String, tipHotspot: Bool = false, pointSize: CGFloat = 16) -> NSCursor? {
        // Bold weight so filled symbols and the inherently line-based glyphs (pencil,
        // line, crop, magnifier) all read as heavy, solid icons in one consistent style.
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return nil }
        let glyph = symbol.size

        // Brand-purple tint of the template symbol.
        let tinted = NSImage(size: glyph)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: glyph))
        Theme.accentPurple.set()
        NSRect(origin: .zero, size: glyph).fill(using: .sourceAtop)
        tinted.unlockFocus()

        // Composite with a white halo so it reads on both light and dark content.
        let inset: CGFloat = 3
        let size = NSSize(width: glyph.width + inset * 2, height: glyph.height + inset * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.95)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = .zero
        shadow.set()
        tinted.draw(in: NSRect(x: inset, y: inset, width: glyph.width, height: glyph.height))
        image.unlockFocus()

        // hotSpot origin is the image's top-left.
        let hot = tipHotspot ? NSPoint(x: inset + 1, y: size.height - inset - 1)
                             : NSPoint(x: size.width / 2, y: size.height / 2)
        return NSCursor(image: image, hotSpot: hot)
    }

    /// A capture cursor: the glyph filled white and ringed with a brand-purple keyline.
    ///
    /// The editor's halo style (`make`) could not carry this job — a `Theme.accentPurple`
    /// glyph is dark, the capture overlay dims the screen behind it, and dark-on-dark with a
    /// 2.5 pt halo is barely visible. Yet with no action line in the guidance card, this
    /// cursor is what says whether a click takes a screenshot or starts a recording.
    ///
    /// Inverting it solves both backgrounds without a filled chip behind the glyph: the white
    /// body reads against the dimmed screenshot, and the purple keyline reads against bright
    /// content the white body would otherwise disappear into. The keyline is drawn as a ring
    /// of offset copies because it has to follow the *glyph's* silhouette — a stroked
    /// rectangle would outline the box, not the camera.
    static func makeOutlined(symbol name: String, pointSize: CGFloat = 19,
                             keyline: CGFloat = 1.5) -> NSCursor? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return nil }
        let glyph = symbol.size

        /// Tint in the glyph's *own* transparent image: `.sourceAtop` over anything already
        /// drawn composites against those pixels and floods the whole glyph box.
        func tinted(_ color: NSColor) -> NSImage {
            let img = NSImage(size: glyph)
            img.lockFocus()
            symbol.draw(in: NSRect(origin: .zero, size: glyph))
            color.set()
            NSRect(origin: .zero, size: glyph).fill(using: .sourceAtop)
            img.unlockFocus()
            return img
        }
        let body = tinted(.white)
        let edge = tinted(Theme.accentPurple)

        let pad = keyline + 1
        let size = NSSize(width: glyph.width + pad * 2, height: glyph.height + pad * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let steps = 16
        for i in 0..<steps {
            let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
            edge.draw(in: NSRect(x: pad + cos(angle) * keyline, y: pad + sin(angle) * keyline,
                                 width: glyph.width, height: glyph.height))
        }
        body.draw(in: NSRect(x: pad, y: pad, width: glyph.width, height: glyph.height))
        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }

    /// A crosshair in the same style as `makeOutlined`: white arms with a brand-purple
    /// keyline, and a **gap at the centre** so the exact point being aimed at stays visible.
    ///
    /// Drawn rather than tinted from an SF Symbol because region selection is the one mode
    /// where a single pixel matters: the hotspot has to sit on an exact point, and no symbol
    /// leaves a clean hole at its own centre to put it in. That precision is why this stayed
    /// the system crosshair for so long — this keeps it while matching the capture cursors.
    static func makeCrosshair(side: CGFloat = 26, gap: CGFloat = 3.5,
                              core: CGFloat = 1.5, keyline: CGFloat = 1.25) -> NSCursor {
        let pad: CGFloat = 1
        let size = NSSize(width: side + pad * 2, height: side + pad * 2)
        let centre = NSPoint(x: size.width / 2, y: size.height / 2)

        func arms() -> NSBezierPath {
            let path = NSBezierPath()
            let half = side / 2
            for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
                path.move(to: NSPoint(x: centre.x + dx * gap, y: centre.y + dy * gap))
                path.line(to: NSPoint(x: centre.x + dx * half, y: centre.y + dy * half))
            }
            return path
        }

        let image = NSImage(size: size)
        image.lockFocus()
        // Keyline first as a wider stroke of the same path, so the white arms sit inside it.
        let outline = arms()
        outline.lineWidth = core + keyline * 2
        outline.lineCapStyle = .square
        Theme.accentPurple.setStroke()
        outline.stroke()

        let body = arms()
        body.lineWidth = core
        body.lineCapStyle = .square
        NSColor.white.setStroke()
        body.stroke()
        image.unlockFocus()

        // hotSpot origin is the image's top-left; the image is symmetric, so the centre is
        // the same point either way — and it lands in the gap, on nothing drawn.
        return NSCursor(image: image, hotSpot: centre)
    }
}
