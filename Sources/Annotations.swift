// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

struct DrawStyle {
    var color: NSColor
    var lineWidth: CGFloat
}

/// One drawable mark on the canvas. Coordinates are in image space.
protocol Annotation: AnyObject {
    func draw(in ctx: CGContext)
    func hit(_ p: CGPoint) -> Bool
    func remap(_ f: (CGPoint) -> CGPoint)
    /// Tight bounding box in image space — drives the Select tool's outline + handle.
    var bounds: CGRect { get }
    /// Whether the Select tool offers a corner resize handle. Path-like marks
    /// (lines, arrows, freehand, ruler) are move-only.
    var resizable: Bool { get }
    /// Uniformly scale the mark by `f` about `anchor` (Select-tool resize). The
    /// default scales geometry via `remap`; marks with a size scalar (text,
    /// counter, emoji) override to also scale that scalar.
    func scale(by f: CGFloat, around anchor: CGPoint)
    /// Restyle the mark's stroke/text color in place (Select-tool color change).
    /// No-op for marks without a color (emoji, image overlay).
    func recolor(_ c: NSColor)
}
extension Annotation {
    func hit(_ p: CGPoint) -> Bool { false }
    var resizable: Bool { true }
    func scale(by f: CGFloat, around a: CGPoint) {
        remap { CGPoint(x: a.x + ($0.x - a.x) * f, y: a.y + ($0.y - a.y) * f) }
    }
    func recolor(_ c: NSColor) {}
}

private func contrasting(_ c: NSColor) -> NSColor {
    let rgb = c.usingColorSpace(.deviceRGB) ?? c
    let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    return lum > 0.6 ? .black : .white
}

class FreehandAnnotation: Annotation {
    private(set) var points: [CGPoint] = []
    var style: DrawStyle
    init(style: DrawStyle) { self.style = style }
    func add(_ p: CGPoint) { points.append(p) }
    func remap(_ f: (CGPoint) -> CGPoint) { points = points.map(f) }
    func recolor(_ c: NSColor) { style.color = c }
    var strokeWidth: CGFloat { style.lineWidth }
    var resizable: Bool { false }
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var (minX, minY, maxX, maxY) = (first.x, first.y, first.x, first.y)
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
    }

    func draw(in ctx: CGContext) {
        guard points.count > 1 else { return }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.beginPath(); ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }
    func hit(_ p: CGPoint) -> Bool {
        points.contains { hypot($0.x - p.x, $0.y - p.y) < max(8, strokeWidth) }
    }
}

final class PencilAnnotation: FreehandAnnotation {}

final class MarkerAnnotation: FreehandAnnotation {
    override var strokeWidth: CGFloat { style.lineWidth * 5 }
    override func draw(in ctx: CGContext) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(style.color.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.beginPath(); ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

class TwoPointAnnotation: Annotation {
    var start: CGPoint
    var end: CGPoint
    var style: DrawStyle
    init(start: CGPoint, style: DrawStyle) { self.start = start; self.end = start; self.style = style }
    func recolor(_ c: NSColor) { style.color = c }
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    func draw(in ctx: CGContext) {}
    func hit(_ p: CGPoint) -> Bool { rect.insetBy(dx: -6, dy: -6).contains(p) }
    func remap(_ f: (CGPoint) -> CGPoint) { start = f(start); end = f(end) }
    var resizable: Bool { true }
    var bounds: CGRect { rect }
}

/// A bendable mark: a quadratic curve from `start` to `end` shaped by one
/// `control` point. Straight when the control sits on the start–end line; the
/// editor exposes a draggable handle at the curve's apex to bend it. Base for the
/// bendable line and arrow — subclasses only supply `draw`.
class CurvedAnnotation: Annotation {
    var start: CGPoint
    var end: CGPoint
    var control: CGPoint
    var style: DrawStyle
    init(start: CGPoint, style: DrawStyle) {
        self.start = start; self.end = start; self.control = start; self.style = style
    }
    func recolor(_ c: NSColor) { style.color = c }
    /// Midpoint of the straight start–end line.
    var lineMid: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
    /// Point the curve passes through at t=0.5 — where the drag handle sits.
    var apex: CGPoint { CGPoint(x: (lineMid.x + control.x) / 2, y: (lineMid.y + control.y) / 2) }
    /// Reshape so the apex passes through `p` (dragging the handle).
    func bend(through p: CGPoint) { control = CGPoint(x: 2 * p.x - lineMid.x, y: 2 * p.y - lineMid.y) }
    /// Reset to a straight mark (control on the line) — used while drawing it out.
    func straighten() { control = lineMid }

    /// Strokes the quad-curve shaft up to `tip`. The line draws all the way to
    /// `end`; the arrow stops at its head's base so the head reads cleanly.
    func strokeShaft(to tip: CGPoint, in ctx: CGContext) {
        ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.beginPath(); ctx.move(to: start); ctx.addQuadCurve(to: tip, control: control); ctx.strokePath()
    }
    func draw(in ctx: CGContext) {}

    func hit(_ p: CGPoint) -> Bool {
        let n = 24
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n), mt = 1 - t
            let x = mt * mt * start.x + 2 * mt * t * control.x + t * t * end.x
            let y = mt * mt * start.y + 2 * mt * t * control.y + t * t * end.y
            if hypot(x - p.x, y - p.y) < max(8, style.lineWidth) { return true }
        }
        return false
    }
    func remap(_ f: (CGPoint) -> CGPoint) { start = f(start); end = f(end); control = f(control) }
    var resizable: Bool { false }
    /// A quadratic curve stays within the hull of its three points, so their box
    /// (padded by `boundsPadding`) bounds the whole mark.
    var bounds: CGRect {
        let xs = [start.x, end.x, control.x], ys = [start.y, end.y, control.y]
        let pad = boundsPadding
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -pad, dy: -pad)
    }
    /// Padding around the point hull — enough to cover the stroke (overridden by
    /// the arrow to also cover its head).
    var boundsPadding: CGFloat { max(12, style.lineWidth * 2) }
}

/// A bendable line — the curved shaft, no arrowhead.
final class CurvedLineAnnotation: CurvedAnnotation {
    override func draw(in ctx: CGContext) { strokeShaft(to: end, in: ctx) }
}

/// A bendable arrow — the curved shaft plus a filled arrowhead at `end`.
final class CurvedArrowAnnotation: CurvedAnnotation {
    override func draw(in ctx: CGContext) {
        let head = CurvedArrowAnnotation.headLength(style.lineWidth)
        let w = CGFloat.pi / 6
        let a = atan2(end.y - control.y, end.x - control.x)
        let p1 = CGPoint(x: end.x - cos(a - w) * head, y: end.y - sin(a - w) * head)
        let p2 = CGPoint(x: end.x - cos(a + w) * head, y: end.y - sin(a + w) * head)
        let backoff = min(head * cos(w), hypot(end.x - start.x, end.y - start.y))
        let shaftEnd = CGPoint(x: end.x - cos(a) * backoff, y: end.y - sin(a) * backoff)
        strokeShaft(to: shaftEnd, in: ctx)
        ctx.setFillColor(style.color.cgColor)
        ctx.beginPath(); ctx.move(to: end); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath(); ctx.fillPath()
    }
    /// Arrowhead length, shared by `draw` and `boundsPadding` so the box covers the barbs.
    static func headLength(_ lineWidth: CGFloat) -> CGFloat { max(14, lineWidth * 4.5) }
    override var boundsPadding: CGFloat { CurvedArrowAnnotation.headLength(style.lineWidth) }
}

final class RectAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(style.lineWidth); ctx.setLineJoin(.round)
        ctx.stroke(rect)
    }
}

final class EllipseAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(style.lineWidth)
        ctx.strokeEllipse(in: rect)
    }
}

/// Strokes a closed polygon through the given image-space points.
private func strokePolygon(_ pts: [CGPoint], in ctx: CGContext, _ style: DrawStyle, closed: Bool = true) {
    guard let first = pts.first else { return }
    ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(style.lineWidth)
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    ctx.beginPath(); ctx.move(to: first)
    for p in pts.dropFirst() { ctx.addLine(to: p) }
    if closed { ctx.closePath() }
    ctx.strokePath()
}

final class TriangleAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        let r = rect
        strokePolygon([CGPoint(x: r.minX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.midX, y: r.maxY)], in: ctx, style)
    }
}

final class DiamondAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        let r = rect
        strokePolygon([CGPoint(x: r.midX, y: r.maxY),
                       CGPoint(x: r.maxX, y: r.midY),
                       CGPoint(x: r.midX, y: r.minY),
                       CGPoint(x: r.minX, y: r.midY)], in: ctx, style)
    }
}

final class StarAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        let r = rect
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let inner: CGFloat = 0.4
        var pts: [CGPoint] = []
        for i in 0..<10 {
            let a = .pi / 2 + CGFloat(i) * .pi / 5
            let f: CGFloat = i % 2 == 0 ? 1 : inner
            pts.append(CGPoint(x: cx + cos(a) * rx * f, y: cy + sin(a) * ry * f))
        }
        strokePolygon(pts, in: ctx, style)
    }
}

/// Vertices of a regular `sides`-gon inscribed in `rect`, first vertex at the
/// top; `rotation` (radians) turns it — e.g. a half-step for a flat-topped octagon.
private func regularPolygon(sides: Int, in rect: CGRect, rotation: CGFloat = 0) -> [CGPoint] {
    let cx = rect.midX, cy = rect.midY, rx = rect.width / 2, ry = rect.height / 2
    return (0..<sides).map { i in
        let a = .pi / 2 + rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
        return CGPoint(x: cx + cos(a) * rx, y: cy + sin(a) * ry)
    }
}

final class PentagonAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) { strokePolygon(regularPolygon(sides: 5, in: rect), in: ctx, style) }
}

final class HexagonAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) { strokePolygon(regularPolygon(sides: 6, in: rect), in: ctx, style) }
}

final class OctagonAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        strokePolygon(regularPolygon(sides: 8, in: rect, rotation: .pi / 8), in: ctx, style)
    }
}

final class RoundedRectAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(style.lineWidth); ctx.setLineJoin(.round)
        let radius = min(rect.width, rect.height) * 0.2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
    }
}

final class CheckmarkAnnotation: TwoPointAnnotation {
    override func draw(in ctx: CGContext) {
        let r = rect
        strokePolygon([CGPoint(x: r.minX, y: r.minY + r.height * 0.5),
                       CGPoint(x: r.minX + r.width * 0.33, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY)], in: ctx, style, closed: false)
    }
}

/// A region obscured by a smooth Gaussian blur.
final class BlurAnnotation: TwoPointAnnotation {
    var patch: CGImage?
    override func draw(in ctx: CGContext) {
        if let patch {
            ctx.saveGState(); ctx.interpolationQuality = .high
            ctx.draw(patch, in: rect); ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor(white: 0.5, alpha: 0.55).cgColor); ctx.fill(rect)
        }
    }
    override func hit(_ p: CGPoint) -> Bool { rect.contains(p) }
}

/// Dims everything outside the chosen rectangle.
final class SpotlightAnnotation: TwoPointAnnotation {
    var fullSize: CGSize = .zero
    override func draw(in ctx: CGContext) {
        let r = rect
        ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        let W = fullSize.width, H = fullSize.height
        ctx.fill(CGRect(x: 0, y: r.maxY, width: W, height: H - r.maxY))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: r.minY))
        ctx.fill(CGRect(x: 0, y: r.minY, width: r.minX, height: r.height))
        ctx.fill(CGRect(x: r.maxX, y: r.minY, width: W - r.maxX, height: r.height))
    }
    override func hit(_ p: CGPoint) -> Bool { !rect.contains(p) }
}

final class TextAnnotation: Annotation {
    /// Rich text carrying the typed characters and each range's foreground color,
    /// so one mark can mix colors. Font, weight and wrapping are applied uniformly
    /// at draw from `fontSize`, so per-range colors survive font changes and resize.
    var attributed: NSAttributedString
    var origin: CGPoint
    var fontSize: CGFloat
    /// Wrap width in image space: long text flows onto multiple lines instead of
    /// running off the canvas. Scales with the font so resizing stays proportional.
    var maxWidth: CGFloat
    /// Height of the text box; the text is centered vertically within it to match
    /// the live editor. Scales with the font on resize.
    var boxHeight: CGFloat
    init(attributed: NSAttributedString, origin: CGPoint, fontSize: CGFloat,
         maxWidth: CGFloat, boxHeight: CGFloat) {
        self.attributed = attributed; self.origin = origin; self.fontSize = fontSize
        self.maxWidth = max(1, maxWidth); self.boxHeight = max(1, boxHeight)
    }
    var text: String { attributed.string }
    /// The stored rich text with the current uniform font, weight and wrapping laid
    /// over it, leaving each range's foreground color intact.
    private func styled() -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: m.length)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        m.addAttributes([.font: Theme.font(fontSize, .semibold), .paragraphStyle: para], range: full)
        return m
    }
    private var textHeight: CGFloat {
        ceil(styled().boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
    var bounds: CGRect { CGRect(x: origin.x, y: origin.y, width: maxWidth, height: boxHeight) }
    func draw(in ctx: CGContext) {
        let dy = max(0, boxHeight - textHeight)
        styled().draw(
            with: CGRect(x: origin.x, y: origin.y + dy, width: maxWidth, height: textHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    func hit(_ p: CGPoint) -> Bool { bounds.insetBy(dx: -6, dy: -6).contains(p) }
    func remap(_ f: (CGPoint) -> CGPoint) { origin = f(origin) }
    /// Whole-mark recolor (Select tool) — paints every range one color. Per-range
    /// coloring happens live in the text field while editing.
    func recolor(_ c: NSColor) {
        let m = NSMutableAttributedString(attributedString: attributed)
        m.addAttribute(.foregroundColor, value: c, range: NSRange(location: 0, length: m.length))
        attributed = m
    }
    func scale(by f: CGFloat, around a: CGPoint) {
        origin = CGPoint(x: a.x + (origin.x - a.x) * f, y: a.y + (origin.y - a.y) * f)
        fontSize *= f
        maxWidth *= f
        boxHeight *= f
    }
}

/// How a counter badge labels its sequence position.
enum CounterFormat: CaseIterable {
    case number, letter, roman
    /// A short sample of the format for toggle buttons / menus.
    var sample: String { switch self { case .number: return "1"; case .letter: return "A"; case .roman: return "i" } }
    /// The label for the 1-based position `n`.
    func label(_ n: Int) -> String {
        switch self {
        case .number: return "\(n)"
        case .letter:
            var n = n, s = ""
            while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
            return s.isEmpty ? "A" : s
        case .roman:
            let table: [(Int, String)] = [(1000,"m"),(900,"cm"),(500,"d"),(400,"cd"),(100,"c"),
                (90,"xc"),(50,"l"),(40,"xl"),(10,"x"),(9,"ix"),(5,"v"),(4,"iv"),(1,"i")]
            var n = max(1, n), s = ""
            for (v, sym) in table { while n >= v { s += sym; n -= v } }
            return s
        }
    }
}

final class CounterAnnotation: Annotation {
    var center: CGPoint
    let label: String
    var color: NSColor
    var radius: CGFloat
    init(center: CGPoint, label: String, color: NSColor, radius: CGFloat) {
        self.center = center; self.label = label; self.color = color; self.radius = radius
    }
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: Theme.font(radius * 1.05, .bold),
         .foregroundColor: contrasting(color)]
    }
    /// Capsule badge that grows for multi-character labels (AA, viii…).
    private var box: CGRect {
        let tw = (label as NSString).size(withAttributes: attrs).width
        let w = max(radius * 2, tw + radius * 0.9), h = radius * 2
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
    func draw(in ctx: CGContext) {
        let b = box
        let cap = { (r: CGRect) in CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }
        ctx.addPath(cap(b.insetBy(dx: -1.5, dy: -1.5))); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.addPath(cap(b)); ctx.setFillColor(color.cgColor); ctx.fillPath()
        let s = NSAttributedString(string: label, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    }
    func hit(_ p: CGPoint) -> Bool { box.contains(p) }
    func remap(_ f: (CGPoint) -> CGPoint) { center = f(center) }
    func recolor(_ c: NSColor) { color = c }
    var bounds: CGRect { box }
    func scale(by f: CGFloat, around a: CGPoint) {
        center = CGPoint(x: a.x + (center.x - a.x) * f, y: a.y + (center.y - a.y) * f)
        radius *= f
    }
}

/// An emoji stamp placed on the capture. Drag while placing to size it.
final class EmojiAnnotation: Annotation {
    var center: CGPoint
    let emoji: String
    var size: CGFloat
    init(center: CGPoint, emoji: String, size: CGFloat) {
        self.center = center; self.emoji = emoji; self.size = size
    }
    private var isLogo: Bool { emoji == Logo.stampToken }
    private var attrs: [NSAttributedString.Key: Any] { [.font: Theme.font(size)] }
    private var box: CGRect {
        let sz = isLogo ? CGSize(width: size, height: size) : (emoji as NSString).size(withAttributes: attrs)
        return CGRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height)
    }
    func draw(in ctx: CGContext) {
        if isLogo {
            Logo.image(size: size).draw(in: box)
            return
        }
        let s = NSAttributedString(string: emoji, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    }
    func hit(_ p: CGPoint) -> Bool { box.contains(p) }
    func remap(_ f: (CGPoint) -> CGPoint) { center = f(center) }
    var bounds: CGRect { box }
    func scale(by f: CGFloat, around a: CGPoint) {
        center = CGPoint(x: a.x + (center.x - a.x) * f, y: a.y + (center.y - a.y) * f)
        size *= f
    }
}

/// An axis-aligned dimension line with end-ticks and a label showing the span in
/// **image pixels**. Imprinted by the Ruler tool. `pixelsPerPoint` is the capture's
/// Retina factor (crop/rotate preserve it, so the value stays correct after them).
final class MeasureAnnotation: Annotation {
    var start: CGPoint
    var end: CGPoint
    let style: DrawStyle
    init(start: CGPoint, end: CGPoint, style: DrawStyle) {
        self.start = start; self.end = end; self.style = style
    }
    /// Length in the image's logical points — i.e. on-screen pixels. The capture's
    /// point space is 1:1 with screen coordinates, so no Retina scaling is applied
    /// (a Retina grab's device pixels are 2× this).
    var pixels: Int { Int(hypot(end.x - start.x, end.y - start.y).rounded()) }
    private var labelAttrs: [NSAttributedString.Key: Any] {
        [.font: Theme.font(12, .semibold), .foregroundColor: NSColor.white]
    }
    func draw(in ctx: CGContext) {
        let lw = max(1.5, style.lineWidth * 0.6)
        ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(lw); ctx.setLineCap(.round)
        ctx.beginPath(); ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
        let dx = end.x - start.x, dy = end.y - start.y
        let len = max(0.0001, hypot(dx, dy))
        let nx = -dy / len, ny = dx / len
        let tick: CGFloat = max(5, lw * 3)
        for p in [start, end] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: p.x + nx * tick, y: p.y + ny * tick))
            ctx.addLine(to: CGPoint(x: p.x - nx * tick, y: p.y - ny * tick))
            ctx.strokePath()
        }
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let s = NSAttributedString(string: "\(pixels) px", attributes: labelAttrs)
        let sz = s.size()
        let padX: CGFloat = 6, padY: CGFloat = 3, off = tick + 8
        let c = CGPoint(x: mid.x + nx * off, y: mid.y + ny * off)
        let box = CGRect(x: c.x - sz.width / 2 - padX, y: c.y - sz.height / 2 - padY,
                         width: sz.width + padX * 2, height: sz.height + padY * 2)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
    }
    func hit(_ p: CGPoint) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        let len2 = dx * dx + dy * dy
        guard len2 >= 1 else { return hypot(p.x - start.x, p.y - start.y) < 8 }
        let t = max(0, min(1, ((p.x - start.x) * dx + (p.y - start.y) * dy) / len2))
        let proj = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y) < max(8, style.lineWidth)
    }
    func remap(_ f: (CGPoint) -> CGPoint) { start = f(start); end = f(end) }
    var resizable: Bool { false }
    var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -8, dy: -8)
    }
}

/// An image pasted/inserted on top of the capture. Movable + resizable in the
/// editor; `opacity` (0–1) lets it sit semi-transparent to highlight differences.
/// The before/after GIF export renders one frame skipping these and one with them.
final class ImageOverlayAnnotation: Annotation {
    let image: CGImage
    var rect: CGRect
    var opacity: CGFloat
    init(image: CGImage, rect: CGRect, opacity: CGFloat = 1) {
        self.image = image; self.rect = rect; self.opacity = opacity
    }
    /// Height-to-width ratio, used to keep corner-resize aspect-locked.
    var aspect: CGFloat { CGFloat(image.height) / max(1, CGFloat(image.width)) }
    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
    func hit(_ p: CGPoint) -> Bool { rect.contains(p) }
    func remap(_ f: (CGPoint) -> CGPoint) {
        let a = f(CGPoint(x: rect.minX, y: rect.minY)), b = f(CGPoint(x: rect.maxX, y: rect.maxY))
        rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    var bounds: CGRect { rect }
}

/// A magnifier callout: outlines a small `source` region and draws its pixels
/// enlarged inside a rounded `dest` bubble, connected by a thin leader line.
/// `patch` (the source pixels) is sampled on commit and re-sampled after a
/// transform, exactly like `BlurAnnotation`.
final class ZoomAnnotation: Annotation {
    var source: CGRect
    var dest: CGRect
    var patch: CGImage?
    let style: DrawStyle
    init(source: CGRect, dest: CGRect, patch: CGImage?, style: DrawStyle) {
        self.source = source; self.dest = dest; self.patch = patch; self.style = style
    }
    func draw(in ctx: CGContext) {
        let lw = max(1.5, style.lineWidth)
        ctx.setStrokeColor(style.color.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(max(1, lw * 0.6)); ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: source.midX, y: source.midY))
        ctx.addLine(to: CGPoint(x: dest.midX, y: dest.midY))
        ctx.strokePath()
        ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(lw * 0.8)
        ctx.stroke(source)
        let radius = min(dest.width, dest.height) * 0.08
        let path = CGPath(roundedRect: dest, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        if let patch {
            ctx.interpolationQuality = .none
            ctx.draw(patch, in: dest)
        } else {
            ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor); ctx.fill(dest)
        }
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor); ctx.setLineWidth(lw + 2); ctx.strokePath()
        ctx.addPath(path); ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(lw); ctx.strokePath()
    }
    func hit(_ p: CGPoint) -> Bool { dest.contains(p) || source.contains(p) }
    func remap(_ f: (CGPoint) -> CGPoint) {
        func mapRect(_ r: CGRect) -> CGRect {
            let a = f(CGPoint(x: r.minX, y: r.minY)), b = f(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
        source = mapRect(source); dest = mapRect(dest)
    }
    var bounds: CGRect { dest.union(source) }
}

