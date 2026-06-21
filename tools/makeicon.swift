// Generates the m_capture app icon, drawn in code (no external assets).
//
// Usage:
//   swift makeicon.swift <out.icns>        — full multi-resolution .icns
//   swift makeicon.swift <out.png> [px]    — a single PNG at `px` (default 1024)
//
// The .icns is written directly via ImageIO, so the build needs neither `sips`
// nor `iconutil` — both of which spill into the system temp dir and fail under a
// sandbox. This keeps every byte inside the output path.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments[1]

func bitmap(_ w: Int, _ h: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return (rep, NSGraphicsContext(bitmapImageRep: rep)!)
}

// Render "m." white, trimmed to ink, so it can be centered precisely.
func glyph() -> (CGImage, CGFloat)? {
    let r = 200
    let (rep, ctx) = bitmap(r, r)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(r) * 0.6, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let g = "m."; let gs = g.size(withAttributes: attrs)
    g.draw(at: CGPoint(x: (CGFloat(r) - gs.width) / 2, y: (CGFloat(r) - gs.height) / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    var minX = r, minY = r, maxX = 0, maxY = 0
    for y in 0..<r { for x in 0..<r where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
        if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y } } }
    guard maxX >= minX, let full = rep.cgImage,
          let cg = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    else { return nil }
    return (cg, CGFloat(cg.width) / CGFloat(cg.height))
}

// The rounded gradient tile with the centered "m." glyph, at `px` square.
func render(_ px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)
    let (rep, ctx) = bitmap(px, px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let margin = size * 0.06
    let tile = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    let top = NSColor(srgbRed: 0x53 / 255, green: 0x3a / 255, blue: 0xa3 / 255, alpha: 1)
    let bottom = NSColor(srgbRed: 0x2a / 255, green: 0x1d / 255, blue: 0x4f / 255, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)

    if let (cg, aspect) = glyph() {
        let gw = tile.width * 0.6
        let gh = gw / aspect
        NSImage(cgImage: cg, size: NSSize(width: gw, height: gh))
            .draw(in: NSRect(x: (size - gw) / 2, y: (size - gh) / 2, width: gw, height: gh))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if outPath.hasSuffix(".icns") {
    // The icns element sizes macOS expects (1x + @2x pairs).
    let sizes = [16, 32, 64, 128, 256, 512, 1024]
    let url = URL(fileURLWithPath: outPath)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil)
    else { fatalError("could not create .icns destination at \(outPath)") }
    for s in sizes {
        guard let cg = render(s).cgImage else { fatalError("render failed at \(s)px") }
        CGImageDestinationAddImage(dest, cg, nil)
    }
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write .icns") }
} else {
    let px = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1024") ?? 1024
    try! render(px).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: outPath))
}
