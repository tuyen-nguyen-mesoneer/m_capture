import CoreGraphics

/// Where the annotation editor puts the capture and its five tool cards on the screen — the
/// whole placement computation, kept UI-free so `tests/run.sh` can sweep it for invariants.
///
/// `EditorWindowController` builds the cards, measures them, and hands their sizes in; this
/// returns the frames, and the controller applies them. Nothing here knows a card is a view,
/// which is what lets the checks describe any capture shape on any screen size without
/// building one. The invariants it must keep, and that the sweep in
/// `tests/EditorLayoutChecks.swift` asserts: **no card overlaps another**, **no card sits over
/// the capture unless it is a gathered leftover**, and **every card is on the screen**.
enum EditorLayout {
    // MARK: Card geometry — shared by the gap model and `insetScale`, which has to predict
    // what the gap model will decide before a single card exists.

    /// Gap between a cluster card and the capture.
    static let cardGap: CGFloat = 16
    /// Margin every card keeps from the screen edge.
    static let cardMargin: CGFloat = 8
    /// How far `cardFrames` shrinks the capture before measuring around it.
    static let capturePad: CGFloat = 8
    /// Slack so `insetScale`'s arithmetic lands clear of the gap model's own comparisons
    /// rather than exactly on them.
    static let cardSlack: CGFloat = 8
    /// Long edge a capture should reach to be comfortable to annotate. Below it the capture
    /// is magnified (see `magnification`).
    static let comfortableEdge: CGFloat = 320
    /// Long edge below which a capture is too small to work on at all — the point where
    /// replicating pixels to enlarge it beats leaving it sharp but untouchable. Between this
    /// and `comfortableEdge` a capture is only enlarged as far as its own pixel density
    /// allows for free (see `magnification`).
    static let workableEdge: CGFloat = 120
    /// Ceiling on that magnification — past this a capture is more pixel blocks than picture.
    /// The magnification set here is the only one there is: the resize handles change the
    /// captured *region*, so they never rescale what is already on the canvas.
    static let maxMagnification: CGFloat = 4

    /// Horizontal room a card column needs beside the capture: its own width, plus the gap
    /// and margin `measureGaps` adds, plus slack. `insetScale` reserves exactly this, so a
    /// capture can't open at a size that leaves the cards nowhere to go.
    static func gutterInset(card: CGSize) -> CGFloat { card.width + cardGap + cardMargin + cardSlack }

    // MARK: Scale

    /// The capture's on-screen scale: shrunk when the cards can't fit around it, magnified
    /// when it is too small to work on, and 1 — pixel-exact — for everything in between.
    /// Shrinking wins if both apply, since a capture that big is not also small.
    ///
    /// `card` is the footprint of one cluster card, which the caller has to predict before
    /// any card exists (`EditorWindowController.cardFootprint`).
    static func onScreenScale(selection: CGRect, screen: CGRect,
                              captureScale: CGFloat, card: CGSize) -> CGFloat {
        let shrunk = insetScale(selection: selection, screen: screen, card: card)
        return shrunk < 1 ? shrunk
            : magnification(selection: selection, screen: screen, captureScale: captureScale)
    }

    /// Whole-number magnification for a capture too small to annotate comfortably.
    ///
    /// A 40×30 region centred in a dimmed 1440×900 screen is a postage stamp — there is
    /// nothing to aim a mark at, and below roughly 36 pt of canvas the eight 18 pt resize
    /// knobs overlap each other, so it can't even be resized.
    ///
    /// **Enlarging is only affordable up to the capture's own pixel density.** The canvas
    /// shows `1 / displayScale` captured pixels per point of screen, and `displayScale` is
    /// `magnification / captureScale` — so holding the magnification at or under
    /// `captureScale` keeps that at one captured pixel per point or better, the same density
    /// as ordinary 1× screen content. Past it the picture is coarser than the screen's own
    /// point grid: each captured pixel is spread over a block of points, which adds no detail
    /// and reads as soft whether the block is smoothed or left hard-edged.
    ///
    /// That threshold is what made this display-dependent, and it is worth spelling out
    /// because the symptom looks like a capture bug and isn't. `captureScale` *is* the
    /// display's density, so a 1× external panel has no headroom at all while a Retina one
    /// has 2×. A 265 pt capture was enlarged 2× on both, but that left the Retina canvas at
    /// one captured pixel per point (~113 per inch) and the 1× external at half that (~46
    /// per inch) — the same nominal zoom, two and a half times the perceived blur. `fits`
    /// allowed it on the external precisely because that screen is *bigger* in points.
    ///
    /// So only a capture under `workableEdge` — genuinely too small to aim a mark at — pays
    /// for replication, up to `maxMagnification`; anything larger is enlarged only as far as
    /// its own density gives away for nothing. Both are further capped by half the display,
    /// which keeps every margin at a quarter of the screen or more, well past what a card
    /// needs, so a magnified capture can never push the cards back on top of itself.
    static func magnification(selection: CGRect, screen: CGRect,
                              captureScale: CGFloat) -> CGFloat {
        let f = screen
        let long = max(selection.width, selection.height)
        guard long > 0, long < comfortableEdge, selection.width > 0, selection.height > 0
        else { return 1 }
        let wanted = (comfortableEdge / long).rounded(.up)
        let fits = min(f.width / 2 / selection.width, f.height / 2 / selection.height).rounded(.down)
        let free = max(1, captureScale)
        let ceiling = long < workableEdge ? maxMagnification : free
        return max(1, min(wanted, fits, ceiling))
    }

    /// How much to shrink the capture on screen so the tool cards have somewhere outside it
    /// to sit — 1, meaning pixel-exact and left where it was shot, whenever they already do.
    ///
    /// A capture big enough to leave `measureGaps` nothing loses the scattered layout
    /// entirely: no strip outside the image can hold a card, so all five gather *on top of*
    /// the image — over the very pixels being annotated. That starts well before a
    /// whole-display capture (around 85% of the screen's width), and at the whole-display
    /// end the editor is on top of that pixel-identical to the desktop it froze, with only
    /// those cards to say anything happened. Shrinking until a card column clears both sides
    /// fixes both: the dim becomes a frame, and the cards scatter around it the way they do
    /// for a small capture. It applies to any capture mode, because it is measured from the
    /// rect rather than read off the mode that produced it.
    ///
    /// The test is the gap model's own, so nothing is scaled that didn't need it: if any one
    /// side can take a card, the layout works and the capture stays pixel-exact. That matters
    /// because an inexact scale costs a full-canvas resample on every redraw (see the editor
    /// `init`'s note) — a capture that would otherwise be annotated *under* its own toolbars
    /// pays it, nothing else does.
    static func insetScale(selection: CGRect, screen: CGRect, card: CGSize) -> CGFloat {
        let f = screen, need = cardGap + cardMargin
        // `measureGaps`' own tests, against the geometry the capture will actually have: it is
        // centred, so both gutters are one width and both strips one depth, and four tests
        // collapse to two. One side with room is enough — a lone strip seats 10 cards and a
        // lone gutter 5 — so the gather only happens when every side comes up short.
        let side = (f.width - selection.width) / 2, strip = (f.height - selection.height) / 2
        let hasRoom = strip + capturePad - need >= card.height
            || (selection.height - capturePad * 2 >= card.height * 0.7
                && side + capturePad - need >= card.width)
        guard !hasRoom else { return 1 }

        // Leave a card's gutter on each side. Width drives it: the two side gutters are the
        // pair that can seat all five cards between them, and any capture that got here is
        // too wide for them. The top and bottom strips fall out proportionally and the gap
        // model uses them when they're deep enough.
        let room = f.width - gutterInset(card: card) * 2
        let scale = room / selection.width
        // Past this the capture is being sacrificed rather than framed (a display this narrow
        // has no room for the scattered layout at any scale), so leave it pixel-exact and let
        // the cards gather as they did before.
        guard room > 0, scale >= 0.6 else { return 1 }
        return min(1, scale)
    }

    // MARK: Canvas frame

    /// The canvas centred on the screen, origin on whole points.
    ///
    /// Centred, the four margins are symmetric — two equal gutters and two equal strips —
    /// which is what lets the cards scatter around it from any capture shape, and for one
    /// large enough to need scaling the middle is the *only* place that leaves a gutter on
    /// both sides.
    static func centredCanvas(_ size: CGSize, in screen: CGSize) -> CGRect {
        CGRect(x: ((screen.width - size.width) / 2).rounded(),
               y: ((screen.height - size.height) / 2).rounded(),
               width: size.width, height: size.height)
    }

    /// A canvas frame clamped inside the screen with `8 + pad` of margin (`pad` being the
    /// background preview's padding), then snapped to whole points.
    ///
    /// A frame bigger than the screen can't be clamped inside it — the overflow is centred
    /// rather than pinned into one corner, which is what the old `max(8 + pad, …)` floor did.
    /// Reachable once a resize grows the region out to the whole display. The origin stays
    /// on the device-pixel grid because a fractional one resamples the whole canvas and
    /// softens it on 1× external displays (the padding clamp can otherwise reintroduce a
    /// sub-pixel offset).
    static func clampCanvas(_ frame: CGRect, pad: CGFloat, in bounds: CGSize) -> CGRect {
        var fr = frame
        let m = 8 + pad
        let fitsX = bounds.width - fr.width - m >= m
        let fitsY = bounds.height - fr.height - m >= m
        fr.origin.x = fitsX ? min(max(m, fr.origin.x), bounds.width - fr.width - m)
                            : (bounds.width - fr.width) / 2
        fr.origin.y = fitsY ? min(max(m, fr.origin.y), bounds.height - fr.height - m)
                            : (bounds.height - fr.height) / 2
        fr.origin.x.round()
        fr.origin.y.round()
        return fr
    }

    // MARK: Card placement — the gap model

    /// One of the four strips of screen outside the selection, measured in whole tool
    /// cards. A gutter beside the capture runs its cards vertically, a strip above or below
    /// runs them in a horizontal row — so a run is always shaped like the space it lives in.
    enum Side { case left, right, top, bottom }
    struct Gap {
        let capacity: Int
        var taken = 0
        var hasRoom: Bool { taken < capacity }
    }

    /// Where each cluster would rather live, best first, in cluster order (Markup, Shape,
    /// Style, Background, Action). Markup hugs the left and Shape the right — that is the
    /// scattered look — while the three wide tile rows prefer the horizontal strips, which is
    /// the shape they lay out in. Adding a cluster means adding a row here.
    static let preference: [[Side]] = [
        [.left,   .right,  .bottom, .top],   // Markup
        [.right,  .left,   .bottom, .top],   // Shape
        [.top,    .bottom, .right,  .left],  // Style
        [.top,    .bottom, .left,   .right], // Background
        [.bottom, .top,    .right,  .left],  // Action
    ]

    /// The cards' frames, by cluster index, plus the order the controller adds them in (left
    /// run, right run, top row, bottom row, then the gathered block — which is also their
    /// z-order) and which of them had to be gathered over the capture.
    struct Placement {
        var frames: [CGRect]
        var order: [Int]
        var gathered: Set<Int>
    }

    /// Places the cards around `canvas` (the capture's frame on screen) on a screen of `cs`.
    ///
    /// The capture is first shrunk by `capturePad` — grown instead by the background
    /// preview's padding `bgPad` — and the four strips around it are measured in whole cards,
    /// against the largest card. Each cluster then takes the best gap in `preference` that
    /// still has room, and only what nothing can hold gets gathered. The old test was
    /// all-or-nothing — one short gutter and *all five* clusters went into a single block
    /// dumped over the image — so a capture anywhere near a screen edge lost the scattered
    /// layout entirely.
    static func cardFrames(cards: [CGSize], around canvas: CGRect, bgPad: CGFloat,
                           in cs: CGSize) -> Placement {
        let sel = canvas.insetBy(dx: capturePad - bgPad, dy: capturePad - bgPad)
        let g = cardGap, m = cardMargin
        let cardSize = CGSize(width: cards.map { $0.width }.max() ?? 0,
                              height: cards.map { $0.height }.max() ?? 0)

        var gaps = measureGaps(sel: sel, cs: cs, card: cardSize, g: g, m: m)
        let band = gutterBand(sel: sel, cs: cs, card: cardSize, g: g, m: m,
                              top: gaps[.top] != nil, bottom: gaps[.bottom] != nil)
        var runs: [Side: [Int]] = [:]
        var leftover: [Int] = []
        for (i, prefs) in zip(cards.indices, preference) {
            if let side = prefs.first(where: { gaps[$0]?.hasRoom == true }) {
                gaps[side]?.taken += 1
                runs[side, default: []].append(i)
            } else {
                leftover.append(i)
            }
        }

        var p = Placement(frames: cards.map { CGRect(origin: .zero, size: $0) }, order: [], gathered: [])
        func put(_ run: [Int], _ origins: [CGPoint]) {
            for (i, o) in zip(run, origins) { p.frames[i].origin = o; p.order.append(i) }
        }
        let sizes = { (run: [Int]) in run.map { cards[$0] } }
        if let v = runs[.left]   { put(v, stackVertically(sizes(v), onLeft: true,  sel: sel, gap: g, cs: cs, band: band)) }
        if let v = runs[.right]  { put(v, stackVertically(sizes(v), onLeft: false, sel: sel, gap: g, cs: cs, band: band)) }
        if let v = runs[.top]    { put(v, rowOutside(sizes(v), above: true,  sel: sel, gap: g, cs: cs)) }
        if let v = runs[.bottom] { put(v, rowOutside(sizes(v), above: false, sel: sel, gap: g, cs: cs)) }
        if !leftover.isEmpty {
            let (offsets, size) = gatherOffsets(sizes(leftover), rows: rowSplit(leftover.count))
            let origin = overCaptureOrigin(size, sel: sel, cs: cs)
            put(leftover, offsets.map { CGPoint(x: origin.x + $0.x, y: origin.y + $0.y) })
            p.gathered = Set(leftover)
        }
        return p
    }

    /// Measure the four strips of screen around the selection, in whole tool cards.
    static func measureGaps(sel: CGRect, cs: CGSize, card: CGSize,
                            g: CGFloat, m: CGFloat) -> [Side: Gap] {
        /// Cards of `extent` that fit in `span`: n·extent + (n−1)·g ≤ span.
        func fit(_ span: CGFloat, _ extent: CGFloat) -> Int {
            Int(max(0, (span + g) / (extent + g)))
        }
        var out: [Side: Gap] = [:]
        let row = fit(cs.width - 2 * m, card.width)
        if cs.height - sel.maxY - g - m >= card.height { out[.top] = Gap(capacity: row) }
        if sel.minY - g - m >= card.height { out[.bottom] = Gap(capacity: row) }

        // A gutter only reads as *flanking* the capture if the capture is tall enough to
        // flank; below that, a tower of cards beside a sliver of image looks wrong.
        guard sel.height >= card.height * 0.7 else { return out }
        // Whatever the horizontal strips will take is not the gutters' to use. Capping the
        // run to the capture's own height instead — and only when *both* strips were in play
        // — left the one-strip case free to reach into that strip's band: a small capture in
        // a screen corner got a run that `stackVertically` then had to push inside the screen
        // edge, straight through the row above it. A band too shallow for a single card now
        // yields no gutter at all, rather than the forced one (`max(1, …)`) that could put a
        // card taller than the capture beside it.
        let band = gutterBand(sel: sel, cs: cs, card: card, g: g, m: m,
                              top: out[.top] != nil, bottom: out[.bottom] != nil)
        let run = fit(band.hi - band.lo, card.height)
        guard run > 0 else { return out }
        if sel.minX - g - m >= card.width { out[.left] = Gap(capacity: run) }
        if cs.width - sel.maxX - g - m >= card.width { out[.right] = Gap(capacity: run) }
        return out
    }

    /// The vertical band a gutter run may occupy: the screen, less whatever the horizontal
    /// strips will take. `rowOutside` puts a strip hard against the capture, clamped to the
    /// screen edge — so these bounds are exactly that row's own edges, which is what keeps a
    /// column and a row from ever sharing a band. Both `measureGaps` (for capacity) and
    /// `stackVertically` (for placement) read it, so the two cannot disagree.
    static func gutterBand(sel: CGRect, cs: CGSize, card: CGSize, g: CGFloat, m: CGFloat,
                           top: Bool, bottom: Bool) -> (lo: CGFloat, hi: CGFloat) {
        (lo: bottom ? max(m, sel.minY - g - card.height) + card.height : m,
         hi: top ? min(cs.height - m - card.height, sel.maxY + g) : cs.height - m)
    }

    /// Rows for a gathered block of `n` cards: one flat row up to three, then the squarest
    /// split. A block only gathers when it has to sit over the capture, so it should cover
    /// as little of the image as its card count allows.
    static func rowSplit(_ n: Int) -> [Int] { n <= 3 ? [n] : [n / 2, n - n / 2] }

    /// Each card's offset inside a gathered block, plus the block's size. The block is an
    /// arrangement, not a container — the caller positions the cards themselves, so every
    /// one stays a free-standing, independently draggable view.
    static func gatherOffsets(_ cards: [CGSize], rows: [Int]) -> (offsets: [CGPoint], size: CGSize) {
        let pad: CGFloat = 7, hgap: CGFloat = 6, vgap: CGFloat = 6
        var grid: [[CGSize]] = [], i = 0
        for n in rows where i < cards.count {
            grid.append(Array(cards[i..<min(i + n, cards.count)])); i += n
        }
        let rowW = grid.map { row in
            row.reduce(0) { $0 + $1.width } + hgap * CGFloat(row.count - 1)
        }
        let rowH = grid.map { row in row.map { $0.height }.max() ?? 0 }
        let w = (rowW.max() ?? 0) + pad * 2
        let h = rowH.reduce(0, +) + vgap * CGFloat(grid.count - 1) + pad * 2

        var offsets: [CGPoint] = []
        var yTop = pad
        for (r, row) in grid.enumerated() {
            var x = (w - rowW[r]) / 2
            for v in row {
                offsets.append(CGPoint(x: x, y: h - yTop - rowH[r] + (rowH[r] - v.height) / 2))
                x += v.width + hgap
            }
            yTop += rowH[r] + vgap
        }
        return (offsets, CGSize(width: w, height: h))
    }

    /// Where a gathered block goes when no gap outside the selection can take it: bottom-
    /// centre *of the capture*, hugging the image's lower edge. Dead centre — the old
    /// behaviour for a whole-screen selection — covered exactly the part of the image you
    /// want to see, and the bottom edge is where every annotation tool puts its toolbar.
    /// Sitting inside the selection also means it cannot collide with cards already placed
    /// in the gaps outside it.
    static func overCaptureOrigin(_ size: CGSize, sel: CGRect, cs: CGSize) -> CGPoint {
        let m: CGFloat = 8, inset: CGFloat = 16
        return CGPoint(x: min(max(m, sel.midX - size.width / 2), max(m, cs.width - size.width - m)),
                       y: min(max(m, sel.minY + inset), max(m, cs.height - size.height - m)))
    }

    /// Origins for a column of cards beside the selection, centred vertically on it and
    /// clamped into `band`, each card centred horizontally in the column.
    static func stackVertically(_ views: [CGSize], onLeft: Bool, sel: CGRect,
                                gap: CGFloat, cs: CGSize, band: (lo: CGFloat, hi: CGFloat)) -> [CGPoint] {
        let m = cardMargin
        let maxW = views.map { $0.width }.max() ?? 0
        let totalH = views.reduce(0) { $0 + $1.height } + gap * CGFloat(views.count - 1)
        var topY = sel.midY + totalH / 2
        // Clamped into `band`, not the whole screen: pushing a run inside the screen edge is
        // exactly what used to walk it into a row's band. `measureGaps` sized the run against
        // this same band, so it always fits.
        topY = min(topY, band.hi)
        if topY - totalH < band.lo { topY = band.lo + totalH }
        let x = onLeft ? max(m, sel.minX - gap - maxW)
                       : min(cs.width - m - maxW, sel.maxX + gap)
        var y = topY
        var out: [CGPoint] = []
        for v in views {
            y -= v.height
            out.append(CGPoint(x: x + (maxW - v.width) / 2, y: y))
            y -= gap
        }
        return out
    }

    /// Origins for a single row of cards just outside the selection — `above` or below it,
    /// centred on it and clamped to the screen. Cards top-align across the row.
    static func rowOutside(_ views: [CGSize], above: Bool, sel: CGRect, gap: CGFloat,
                           cs: CGSize) -> [CGPoint] {
        let m = cardMargin
        let totalW = views.reduce(0) { $0 + $1.width } + gap * CGFloat(views.count - 1)
        let maxH = views.map { $0.height }.max() ?? 0
        var x = min(max(m, sel.midX - totalW / 2), cs.width - totalW - m)
        // `gutterBand` mirrors these two edges exactly — change one, change the other.
        let y = above ? min(cs.height - m - maxH, sel.maxY + gap)
                      : max(m, sel.minY - gap - maxH)
        var out: [CGPoint] = []
        for v in views {
            out.append(CGPoint(x: x, y: y + (maxH - v.height)))
            x += v.width + gap
        }
        return out
    }
}
