// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Builds mesoneer-styled pointer cursors from SF Symbols: the brand-purple glyph with
/// a soft white halo for contrast on any background — no chip. Shared by the capture
/// overlay (camera / video) and the editor tool cursors so they look identical.
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
}
