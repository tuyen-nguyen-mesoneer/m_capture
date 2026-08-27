// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A decorative frame baked around an exported capture: padding + a solid or
/// gradient background + rounded image corners + a soft drop shadow. It's purely
/// a post-process over the flattened image, so the editor's image-space
/// coordinate model (annotations, crop, eyedropper, blur) is untouched.
///
/// `presets` are the swatches shown in the editor; `.solid(_)` carries a custom
/// color chosen from the picker. The same proportional geometry drives both the
/// live editor preview and the baked export.
enum Background {
    case none
    case white, light, dark, black
    case lavender, sunset, ocean, forest, candy, midnight
    case solid(NSColor)

    /// The fixed presets shown in the Background cluster (None + 10).
    static let presets: [Background] = [
        .none, .white, .light, .dark, .black,
        .lavender, .sunset, .ocean, .forest, .candy, .midnight,
    ]

    /// Look up a preset by its `name` (used to restore the persisted default).
    static func preset(named name: String) -> Background? {
        presets.first { $0.name == name }
    }

    var isNone: Bool { if case .none = self { return true }; return false }
    var isSolid: Bool { if case .solid = self { return true }; return false }
    var solidColor: NSColor? { if case let .solid(c) = self { return c }; return nil }

    var name: String {
        switch self {
        case .none:     return "None"
        case .white:    return "White"
        case .light:    return "Light"
        case .dark:     return "Dark"
        case .black:    return "Black"
        case .lavender: return "Lavender"
        case .sunset:   return "Sunset"
        case .ocean:    return "Ocean"
        case .forest:   return "Forest"
        case .candy:    return "Candy"
        case .midnight: return "Midnight"
        case .solid:    return "Custom"
        }
    }

    static func padding(maxDim d: CGFloat) -> CGFloat { d * Settings.shared.paddingSize.scale }
    static func cornerRadius(minDim d: CGFloat, pad: CGFloat) -> CGFloat {
        min(d * 0.03, pad * 0.8) * Settings.shared.radiusSize.scale
    }

    /// A single representative color for the tool-button swatch.
    var swatch: NSColor {
        switch self {
        case .none:     return .clear
        case .white:    return .white
        case .light:    return Theme.rgb(0xF5, 0xF5, 0xF7)
        case .dark:     return Theme.rgb(0x19, 0x15, 0x28)
        case .black:    return .black
        case .lavender: return Theme.rgb(0xC9, 0xA9, 0xFF)
        case .sunset:   return Theme.rgb(0xF9, 0x73, 0x16)
        case .ocean:    return Theme.rgb(0x3B, 0x82, 0xF6)
        case .forest:   return Theme.rgb(0x10, 0xB9, 0x81)
        case .candy:    return Theme.rgb(0xEC, 0x48, 0x99)
        case .midnight: return Theme.rgb(0x1E, 0x3A, 0x8A)
        case let .solid(c): return c
        }
    }

    /// Gradient stops (top-left → bottom-right); a single element means a solid fill.
    private var colors: [NSColor] {
        switch self {
        case .none:     return []
        case .white:    return [.white]
        case .light:    return [Theme.rgb(0xF5, 0xF5, 0xF7)]
        case .dark:     return [Theme.rgb(0x19, 0x15, 0x28)]
        case .black:    return [.black]
        case .lavender: return [Theme.rgb(0xD5, 0xBA, 0xFF), Theme.rgb(0x7C, 0x3A, 0xED)]
        case .sunset:   return [Theme.rgb(0xF9, 0x73, 0x16), Theme.rgb(0xEC, 0x48, 0x99)]
        case .ocean:    return [Theme.rgb(0x3B, 0x82, 0xF6), Theme.rgb(0x14, 0xB8, 0xA6)]
        case .forest:   return [Theme.rgb(0x34, 0xD3, 0x99), Theme.rgb(0x05, 0x96, 0x69)]
        case .candy:    return [Theme.rgb(0xF4, 0x72, 0xB6), Theme.rgb(0xA8, 0x55, 0xF7)]
        case .midnight: return [Theme.rgb(0x1E, 0x3A, 0x8A), Theme.rgb(0x0F, 0x17, 0x2A)]
        case let .solid(c): return [c]
        }
    }

    /// Paint the background across `rect` in the current context.
    func fill(_ rect: CGRect, in ctx: CGContext) {
        let cs = colors
        guard !cs.isEmpty else { return }
        if cs.count == 1 {
            ctx.setFillColor(cs[0].cgColor); ctx.fill(rect); return
        }
        guard let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: cs.map { ($0.usingColorSpace(.deviceRGB) ?? $0).cgColor } as CFArray,
            locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.addRect(rect); ctx.clip()
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    /// Bake the frame around `inner` at full resolution. Returns `inner`
    /// unchanged when `.none`.
    func compose(_ inner: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard !isNone else { return inner }
        let iw = CGFloat(inner.pixelsWide), ih = CGFloat(inner.pixelsHigh)
        let pad = Background.padding(maxDim: max(iw, ih))
        let radius = Background.cornerRadius(minDim: min(iw, ih), pad: pad)
        let W = Int((iw + pad * 2).rounded()), H = Int((ih + pad * 2).rounded())
        // Build the frame in whatever space `inner` is already in — `CanvasView.flatten`
        // preserves the capture's (see `exportColorSpace`), and a `.deviceRGB` destination
        // here would convert it straight back down to sRGB, so choosing a background would
        // silently cost the gamut that flattening had just kept.
        let space = inner.colorSpace.cgColorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard W > 0, H > 0,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)), in: ctx)

        let innerRect = CGRect(x: pad, y: pad, width: iw, height: ih)
        let rounded = CGPath(roundedRect: innerRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.12), blur: pad * 0.5,
                      color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.addPath(rounded); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rounded); ctx.clip()
        inner.draw(in: innerRect)
        ctx.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out)
    }
}

