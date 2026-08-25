// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Builds mesoneer-styled pointer cursors from SF Symbols.
///
/// **One style everywhere**: a white glyph ringed with a brand-purple keyline. The capture
/// overlay, the editor's tools and the live-drawing overlay all use it, so the pointer never
/// changes character as you move between picking a region and marking one up — and *drag out a
/// region* is one glyph, `plus`, from the capture overlay's Region mode through to the editor's
/// Crop and every shape drag.
///
/// It earned the job by being the one that survives both backdrops. The editor used to carry a
/// brand-purple glyph with a soft white halo, which is fine over a bright capture and all but
/// invisible over the dim around it — dark on dark, with 2.5 pt of blur to save it. Inverting it
/// covers both extremes without a slab of colour following the pointer: the white body reads on
/// the dim, the keyline reads on bright content the white body would disappear into.
///
/// Only the size differs by role, via `modeSize` / `toolSize`.
enum BrandCursor {
    /// For a cursor that names a *mode* — the capture overlay's camera / video, where with no
    /// action line in the guidance card the pointer is the only thing saying what a click does.
    static let modeSize: CGFloat = 19
    /// For a cursor that is a *tool tip* — the editor's and the drawing overlay's, where the
    /// glyph has to stay clear of the pixel it is about to touch.
    static let toolSize: CGFloat = 16

    /// A brand cursor: the glyph filled white and ringed with a brand-purple keyline.
    ///
    /// The keyline is drawn as a ring of offset copies because it has to follow the *glyph's*
    /// silhouette — a stroked rectangle would outline the box, not the camera.
    ///
    /// - Parameters:
    ///   - name: SF Symbol name; returns `nil` if the symbol is unavailable.
    ///   - tipHotspot: put the active point at the glyph's lower-left tip (pencil-like tools)
    ///     rather than its centre.
    static func makeOutlined(symbol name: String, tipHotspot: Bool = false,
                             pointSize: CGFloat = modeSize,
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

        // hotSpot origin is the image's top-left, so the tip variant sits at the lower-left of
        // the glyph box — where a pencil or crop tip actually points.
        let hot = tipHotspot ? NSPoint(x: pad + 1, y: size.height - pad - 1)
                             : NSPoint(x: size.width / 2, y: size.height / 2)
        return NSCursor(image: image, hotSpot: hot)
    }
}
