// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// The mesoneer brand icon, drawn from the **official vector**.
///
/// The "m." used to be typeset — `Theme.font` at bold, rendered to a bitmap and trimmed to
/// its ink bounds. That was always wrong and there is no way to make it right by choosing a
/// better substitute: the wordmark is set in **PolySans**, which the brand reserves
/// exclusively for the logo and which we cannot ship. Any UI face put in its place is a
/// different letterform, and "never modify the logo" is one of the guidelines' explicit
/// don'ts. So the shape below is the geometry from Frontify's own brand-icon SVG, kept as
/// its `d` string and parsed into a path — still drawn in code, no image asset, but no
/// longer an approximation of someone else's letterform.
enum Logo {
    /// Sentinel stamp value: an emoji-stamp whose `emoji` equals this renders the
    /// brand tile instead of a Unicode glyph (see `EmojiAnnotation` / `ToolButton`).
    static let stampToken = "::m_capture-logo::"

    /// The official mark's coordinate space — a 500×500 SVG viewBox, y-down.
    private static let viewBox: CGFloat = 500

    /// The "m." outline, verbatim from the brand-icon SVG. Two subpaths: the letterform
    /// and its dot. Already positioned inside the 500×500 circle, which is what carries
    /// the guidelines' fixed proportions (an 18x glyph in a 34x circle, offset 8x left /
    /// 12x right) — so scaling the whole mark is all that is ever needed, and there is no
    /// separate ratio here to get out of step with the spec.
    private static let markPathData = """
        M322.49 233.21V325h-35.82v-86.19c0-22.39-6.44-31.34-23.79-31.34-15.67 0-27.71 \
        16.79-27.71 43.1v74.44h-35.82v-82.84c0-22.39-3.08-34.7-21.27-34.7s-30.22 \
        20.71-30.22 49.25V325h-35.82V177.24h35.82v8.4c0 7.28-1.96 11.47-4.76 \
        17.63-1.12 2.52-1.96 5.32.84 6.16s3.92-1.68 4.48-3.08c7.56-19.31 \
        21.27-31.34 40.86-31.34s31.62 12.03 35.54 29.11c.56 1.96 1.96 2.8 4.2 2.8 \
        1.68 0 3.08-.56 3.92-2.52 8.39-18.75 23.23-29.38 40.86-29.38 25.75 0 \
        48.69 13.99 48.69 58.21Zm65.47 51.49V325h-40.3v-40.3z
        """

    /// The dark icon's circle fill, straight off the official asset — a 45° sweep from
    /// bottom-left to top-right that lifts from Deep Trust to Night Indigo across the
    /// middle and falls back to Deep Trust. Note this is **not** the brand's Gradient 1:
    /// the mark predates it and carries its own ramp, and the asset wins over inference.
    /// The intermediate stops are the asset's, not interpolations of ours.
    private static let circleStops: [(CGFloat, NSColor)] = [
        (0.21, Theme.rgb(0x19, 0x15, 0x27)),
        (0.34, Theme.rgb(0x1f, 0x19, 0x33)),
        (0.57, Theme.rgb(0x30, 0x25, 0x53)),
        (0.58, Theme.rgb(0x31, 0x26, 0x55)),
        (0.67, Theme.rgb(0x25, 0x1d, 0x3e)),
        (0.76, Theme.rgb(0x1c, 0x17, 0x2d)),
        (0.83, Theme.rgb(0x19, 0x15, 0x27)),
    ]

    /// The white icon's glyph colour, straight off the official asset.
    private static let glyphOnWhite = Theme.rgb(0x30, 0x26, 0x55)

    /// Parsed once — the path is immutable and every draw just copies and scales it.
    private static let markPath: NSBezierPath = parse(markPathData)

    /// The letterform's ink bounds in view-box units, for the menu-bar glyph, which is the
    /// one place the mark appears *without* its circle and so has to be trimmed itself.
    private static let markInk: NSRect = markPath.bounds

    // MARK: - Drawing

    /// The mesoneer **brand icon**: "m." centred in a circle. A circle and not the app's
    /// usual square chrome on purpose — the Brand Icon guidelines define the mark as
    /// circular, and it is the one documented exception to `Theme.radiusSmall`.
    ///
    /// - Parameter onDark: picks the approved variation. The *dark* icon (gradient circle,
    ///   white glyph) is for light or neutral backgrounds; the *white* icon (white circle,
    ///   dark indigo glyph) is for dark, coloured or image-based backgrounds. Only these
    ///   two variations exist — no outlines, shadows or recolouring.
    ///
    /// The app's chrome is dark throughout, so the menu header and the About card pass
    /// `onDark: true`. The two places that keep the dark icon are the stamp itself
    /// (`EmojiAnnotation`, which lands on a capture — an unknown background, where the
    /// filled circle is the safer of the two) and the tiles that *pick* that stamp, which
    /// have to preview what they place rather than match the card they sit on.
    static func image(size: CGFloat, onDark: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect)
            if onDark {
                NSColor.white.setFill()
                circle.fill()
            } else {
                NSGradient(colors: circleStops.map(\.1),
                           atLocations: circleStops.map(\.0), colorSpace: .sRGB)?
                    .draw(in: circle, angle: 45)
            }
            (onDark ? glyphOnWhite : NSColor.white).setFill()
            scaledMark(to: size).fill()
            return true
        }
    }

    /// The mark's letterform scaled from the view box to a `size`-square canvas. Uniform,
    /// because the guidelines forbid stretching it.
    private static func scaledMark(to size: CGFloat) -> NSBezierPath {
        let path = markPath.copy() as! NSBezierPath
        var t = AffineTransform.identity
        t.scale(size / viewBox)
        path.transform(using: t)
        return path
    }

    /// Monochrome template image sized to fill the menu bar like other icons. This is the
    /// letterform alone — no circle, since at 16 pt a filled disc would read as a blob and
    /// the menu bar supplies its own ground.
    /// - Parameter badged: draws a small download mark beside the glyph, for a build
    ///   already swapped onto disk and waiting on a relaunch. The composite stays a
    ///   template image, so the badge tints with the menu bar exactly like the logo —
    ///   a coloured badge would have to opt out of that and stop adapting.
    static func menuBarImage(badged: Bool = false) -> NSImage {
        let h: CGFloat = 16
        let scale = h / markInk.height
        let base = NSImage(size: NSSize(width: markInk.width * scale, height: h),
                           flipped: false) { _ in
            let path = markPath.copy() as! NSBezierPath
            // Bring the ink to the origin *before* scaling, so the glyph fills the image
            // rather than sitting wherever it sat inside the 500-unit circle.
            var t = AffineTransform(translationByX: -markInk.minX, byY: -markInk.minY)
            path.transform(using: t)
            t = AffineTransform.identity
            t.scale(scale)
            path.transform(using: t)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        guard badged,
              let badge = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                  accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        else {
            base.isTemplate = true
            return base
        }
        let gap: CGFloat = 2
        let composed = NSImage(size: NSSize(width: base.size.width + gap + badge.size.width,
                                            height: h), flipped: false) { _ in
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            badge.draw(at: NSPoint(x: base.size.width + gap, y: h - badge.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        composed.isTemplate = true
        return composed
    }

    // MARK: - SVG path parsing

    /// Parse an SVG `d` string into a y-up `NSBezierPath` in view-box units.
    ///
    /// Deliberately minimal — it handles exactly the commands the official mark uses
    /// (`M m L l H h V v C c S s Z z`) and nothing else. It is not a general SVG parser and
    /// should not become one: if a future brand asset needs arcs or quadratics, add that
    /// command rather than reaching for a dependency.
    ///
    /// SVG is y-down and AppKit here is y-up, so every emitted point is flipped through
    /// `viewBox`. The flip happens at emit time rather than as a trailing transform because
    /// relative deltas are accumulated in SVG space — converting once at the end would mean
    /// negating every `dy` on the way in, which is the same work with more places to slip.
    private static func parse(_ d: String) -> NSBezierPath {
        let path = NSBezierPath()
        let c = Array(d)
        var i = 0
        var cur = CGPoint.zero        // current point, SVG space
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?     // second control point of the previous C/S, for S
        var cmd: Character = " "

        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: viewBox - p.y) }

        func skipSeparators() {
            while i < c.count, c[i] == " " || c[i] == "," || c[i] == "\n" || c[i] == "\t" { i += 1 }
        }
        /// SVG numbers run together — "5.32.84" is two numbers, and "-" doubles as a
        /// separator — so scan one number at a time rather than splitting the string.
        func number() -> CGFloat {
            skipSeparators()
            var s = ""
            if i < c.count, c[i] == "-" || c[i] == "+" { s.append(c[i]); i += 1 }
            var seenDot = false
            while i < c.count {
                if c[i].isNumber { s.append(c[i]); i += 1 }
                else if c[i] == "." && !seenDot { seenDot = true; s.append(c[i]); i += 1 }
                else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }
        func point(relative: Bool) -> CGPoint {
            let p = CGPoint(x: number(), y: number())
            return relative ? CGPoint(x: cur.x + p.x, y: cur.y + p.y) : p
        }

        while i < c.count {
            skipSeparators()
            guard i < c.count else { break }
            // A letter starts a new command; a number means the previous one repeats.
            if c[i].isLetter {
                cmd = c[i]
                i += 1
            }
            let rel = cmd.isLowercase

            switch Character(cmd.lowercased()) {
            case "m":
                let p = point(relative: rel)
                path.move(to: flip(p))
                cur = p; subpathStart = p; lastControl = nil
                // An implicit continuation of a moveto is a lineto, per the spec.
                cmd = rel ? "l" : "L"
            case "l":
                let p = point(relative: rel)
                path.line(to: flip(p)); cur = p; lastControl = nil
            case "h":
                let x = number()
                let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                path.line(to: flip(p)); cur = p; lastControl = nil
            case "v":
                let y = number()
                let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                path.line(to: flip(p)); cur = p; lastControl = nil
            case "c":
                let c1 = point(relative: rel), c2 = point(relative: rel), p = point(relative: rel)
                path.curve(to: flip(p), controlPoint1: flip(c1), controlPoint2: flip(c2))
                cur = p; lastControl = c2
            case "s":
                // The first control point mirrors the previous curve's second one.
                let c2 = point(relative: rel), p = point(relative: rel)
                let c1 = lastControl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.curve(to: flip(p), controlPoint1: flip(c1), controlPoint2: flip(c2))
                cur = p; lastControl = c2
            case "z":
                path.close(); cur = subpathStart; lastControl = nil
            default:
                i += 1   // unknown command: skip the character rather than spin
            }
        }
        return path
    }
}
