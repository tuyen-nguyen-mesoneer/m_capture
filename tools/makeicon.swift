// Generates the m_capture app icon, drawn in code (no external assets).
//
// Usage (compiled by build.sh alongside Sources/Logo.swift + Sources/Theme.swift):
//   makeicon <out.icns>        — full multi-resolution .icns
//   makeicon <out.png> [px]    — a single PNG at `px` (default 1024)
//
// It draws nothing itself: the mark comes from `Logo.image`, the same official vector
// the menu, About card and stamps use. That is the point of compiling this against the
// app's own sources instead of running it as a standalone script — the icon and the
// in-app mark are one definition, so the logo cannot silently drift between them. It
// used to duplicate a typeset "m." and its gradient here, and duplicating a logo is
// exactly the kind of copy that goes stale unnoticed.
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

/// The brand icon at `px` square. Circular because the Brand Icon guidelines define the
/// mark that way and name app icons as one of its uses; it is the one place the brand's
/// otherwise square-cornered chrome does not apply.
///
/// The circle is inset rather than full-bleed, which serves two purposes at once: it
/// gives the mark the clear space the guidelines require (≥1 x-unit, i.e. ~3% of the
/// diameter), and an inscribed circle sits entirely inside macOS's squircle no matter
/// whether the system masks the icon or takes it as drawn — so the shape is correct
/// either way, with no corners bleeding through.
func render(_ px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)
    let (rep, ctx) = bitmap(px, px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let inset = (size * 0.07).rounded()
    let edge = size - 2 * inset
    // The dark variation: the app icon lands on the Dock, Finder and Launchpad, i.e. on
    // light or unknown ground, which is what the filled gradient circle is for.
    Logo.image(size: edge).draw(in: NSRect(x: inset, y: inset, width: edge, height: edge))

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
