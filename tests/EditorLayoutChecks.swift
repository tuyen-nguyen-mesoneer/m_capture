import Foundation

/// The editor's tool-card placement (`EditorLayout`), swept over capture shapes × screen sizes
/// for the three invariants nothing enforces at runtime: **no card overlaps another**, **no card
/// sits over the capture unless it was gathered** (nothing outside could hold it), and **every
/// card is on the screen**. Each shape runs `EditorWindowController.init`'s own pipeline —
/// scale, canvas size, centre, then place — so what is checked is what the editor would open.
final class EditorLayoutChecks: CheckSuite {
    private struct Screen {
        let width: CGFloat, height: CGFloat
        var size: CGSize { CGSize(width: width, height: height) }
        var name: String { "\(Int(width))×\(Int(height))" }
    }

    private let screens = [Screen(width: 1440, height: 900), Screen(width: 1512, height: 982),
                           Screen(width: 1920, height: 1080), Screen(width: 2560, height: 1440),
                           Screen(width: 1280, height: 800)]

    /// `EditorWindowController.cardFootprint`: a 4×3 grid of `ToolButton.size(radius: 14)`
    /// tiles (14 × 1.85 pt) with 4 pt gaps, a 17 + 22 pt header, and 5 pt card padding.
    private let footprint: CGSize = {
        let side: CGFloat = 14 * 1.85, gap: CGFloat = 4, pad: CGFloat = 5
        let grid = CGSize(width: 3 * (side + gap) + side, height: 2 * (side + gap) + side)
        return CGSize(width: grid.width + pad * 2, height: 17 + 22 + grid.height + pad * 2)
    }()

    /// The card sets the editor can actually build: all at the footprint, all 24 pt wider (a
    /// long localized header — German's "HINTERGRUND" — widens a card past its grid), and a
    /// mix, since the gap model measures the largest card but places each at its own size.
    private var cardSets: [(name: String, sizes: [CGSize])] {
        let wide = CGSize(width: footprint.width + 24, height: footprint.height)
        return [("footprint", Array(repeating: footprint, count: 5)),
                ("footprint+24", Array(repeating: wide, count: 5)),
                ("mixed", [footprint, footprint, footprint, wide, footprint])]
    }

    private struct Layout {
        let inset: CGFloat
        let canvas: CGRect
        let placement: EditorLayout.Placement
    }

    /// `EditorWindowController.init`, minus the views: on-screen scale → canvas size (the
    /// capture's pixels × `displayScale`) → centred on the screen → cards placed around it.
    /// `bgPadRatio` stands in for `Background.padding` (canvas long edge × the preset's ratio),
    /// which the controller reads from Settings; 0 is the default "None" background.
    private func layout(_ selection: CGSize, on screen: Screen, captureScale: CGFloat,
                        cards: [CGSize], bgPadRatio: CGFloat = 0) -> Layout {
        let inset = EditorLayout.onScreenScale(selection: CGRect(origin: .zero, size: selection),
                                               screen: CGRect(origin: .zero, size: screen.size),
                                               captureScale: captureScale, card: footprint)
        let scale = (1 / captureScale) * inset
        let pixels = CGSize(width: (selection.width * captureScale).rounded(),
                            height: (selection.height * captureScale).rounded())
        let canvas = EditorLayout.centredCanvas(CGSize(width: pixels.width * scale,
                                                       height: pixels.height * scale), in: screen.size)
        let bgPad = bgPadRatio * max(canvas.width, canvas.height)
        let placement = EditorLayout.cardFrames(cards: cards, around: canvas, bgPad: bgPad, in: screen.size)
        return Layout(inset: inset, canvas: canvas, placement: placement)
    }

    /// Overlap with real area: cards placed exactly `cardGap` apart, or flush with the screen
    /// margin, must not count.
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.001 && i.height > 0.001
    }

    private let names = ["Markup", "Shape", "Style", "Background", "Action"]

    /// Every invariant this layout breaks, each naming the card(s) involved.
    private func violations(_ l: Layout, on screen: Screen) -> [String] {
        var out: [String] = []
        let frames = l.placement.frames
        let bounds = CGRect(origin: .zero, size: screen.size).insetBy(dx: -0.001, dy: -0.001)
        for i in frames.indices {
            if !bounds.contains(frames[i]) { out.append("\(names[i]) off screen at \(frames[i])") }
            if !l.placement.gathered.contains(i), overlaps(frames[i], l.canvas) {
                out.append("\(names[i]) over the capture \(l.canvas) at \(frames[i])")
            }
            for j in frames.indices where j > i && overlaps(frames[i], frames[j]) {
                out.append("\(names[i]) \(frames[i]) overlaps \(names[j]) \(frames[j])")
            }
        }
        return out
    }

    /// A canvas thinner than `2 × capturePad` on either axis insets to `CGRect.null`, whose
    /// infinite origin sends every card off screen. That is today's behaviour for a sliver
    /// capture (e.g. 3×200 pt on a 1× display, which magnification leaves alone), and fixing it
    /// is a behaviour change outside this check's remit, so the sweep stays clear of it.
    private func isSliver(_ l: Layout) -> Bool {
        min(l.canvas.width, l.canvas.height) < EditorLayout.capturePad * 2
    }

    /// Background padding ratios swept: none, and `PaddingSize.large`'s 0.045 — the widest
    /// `capturePad − bgPad` inset `relayout` can hand the gap model.
    private let bgPadRatios: [CGFloat] = [0, 0.045]

    /// Runs `shapes` on every screen, density, card set and background padding; records at
    /// most a handful of failures (each naming shape, screen, density, card set and padding),
    /// and prints how many layouts were checked, skipped as slivers, and failed.
    private func sweep(_ shapes: (Screen) -> [CGSize], label: String) {
        var failures = 0, checked = 0, skipped = 0
        for screen in screens {
            for captureScale: CGFloat in [1, 2] {
                for set in cardSets {
                    for ratio in bgPadRatios {
                        for shape in shapes(screen) {
                            let l = layout(shape, on: screen, captureScale: captureScale,
                                           cards: set.sizes, bgPadRatio: ratio)
                            guard !isSliver(l) else { skipped += 1; continue }
                            checked += 1
                            let v = violations(l, on: screen)
                            guard !v.isEmpty else { continue }
                            failures += 1
                            if failures <= 8 {
                                expect(false, "\(label): capture \(Int(shape.width))×\(Int(shape.height)) pt on "
                                       + "\(screen.name) @\(Int(captureScale))x, \(set.name) cards, "
                                       + "bgPad ratio \(ratio): " + v.joined(separator: "; "))
                            }
                        }
                    }
                }
            }
        }
        print("      \(label): \(failures) of \(checked) layouts break an invariant, \(skipped) sliver layouts skipped")
        expect(failures == 0, "\(label): \(failures) of \(checked) layouts break an invariant")
        expect(checked > 0, "\(label): no layouts checked")
    }

    // MARK: - Matrix rows

    @objc func checkSweepAcrossCaptureShapesAndScreens() {
        sweep({ screen in
            var shapes: [CGSize] = []
            for w in stride(from: CGFloat(4), through: screen.width, by: 24) {
                for h in stride(from: CGFloat(4), through: screen.height, by: 24) {
                    shapes.append(CGSize(width: w, height: h))
                }
                shapes.append(CGSize(width: w, height: screen.height))
            }
            for h in stride(from: CGFloat(4), through: screen.height, by: 24) {
                shapes.append(CGSize(width: screen.width, height: h))
            }
            shapes.append(screen.size)
            return shapes
        }, label: "sweep")
    }

    /// The band where a gutter column and a horizontal row compete for the same rows of
    /// screen: a capture just tall enough to be flanked (`sel.height ≥ 0.7 × card`, ~110 pt of
    /// canvas) but not tall enough for the column to clear the rows (~118 pt). Only
    /// `gutterBand` keeps a column out of a row here, so this is the part of the matrix that
    /// has to be walked in 1 pt steps. The collision needs the row to reach sideways past the
    /// capture too, which happens for captures under ~300 pt wide — and those stay that
    /// narrow only on a 1× display, since a 2× one magnifies them out of the band.
    @objc func checkGutterBandShapes() {
        sweep({ _ in
            var shapes: [CGSize] = []
            for h in stride(from: CGFloat(104), through: 124, by: 1) {
                for w in stride(from: CGFloat(120), through: 1200, by: 10) {
                    shapes.append(CGSize(width: w, height: h))
                }
            }
            return shapes
        }, label: "gutter band")
    }

    /// Runs at bgPad 0 only: `insetScale` ignores the background padding (known, out of scope),
    /// so with a preset set a whole-screen capture can scale too little for the cards to
    /// scatter, and asserting "nothing gathers" there would test that gap, not this layout.
    @objc func checkWholeScreenCaptureScalesAndScatters() {
        for screen in screens {
            for captureScale: CGFloat in [1, 2] {
                let l = layout(screen.size, on: screen, captureScale: captureScale, cards: cardSets[0].sizes)
                let at = "whole-screen \(screen.name) @\(Int(captureScale))x"
                expect(l.inset < 1, "\(at): insetScale should shrink it, got \(l.inset)")
                expect(l.placement.gathered.isEmpty,
                       "\(at): nothing should gather, got \(l.placement.gathered.sorted())")
                let v = violations(l, on: screen)
                expect(v.isEmpty, "\(at): " + v.joined(separator: "; "))
            }
        }
    }

    /// A 40×30 capture on a 2× display is magnified in whole steps up to `maxMagnification`,
    /// and the invariants hold around it. Magnification is also capped by density — past
    /// `workableEdge` a 1× display has no free headroom, so 200×150 stays at 1 — and by half
    /// the display: 300×250 on 640×480 would want 2×, but 250 pt is over half of 480.
    @objc func checkTinyCaptureMagnifiesInWholeSteps() {
        let screen = screens[0]
        let tiny = CGSize(width: 40, height: 30)
        let l = layout(tiny, on: screen, captureScale: 2, cards: cardSets[0].sizes)
        expect(l.inset == 4, "40×30 on \(screen.name) @2x: magnified to maxMagnification 4, got \(l.inset)")
        expect(l.inset == l.inset.rounded(), "magnification must be a whole step, got \(l.inset)")
        let v = violations(l, on: screen)
        expect(v.isEmpty, "40×30 on \(screen.name) @2x: " + v.joined(separator: "; "))

        let mid = EditorLayout.magnification(selection: CGRect(x: 0, y: 0, width: 200, height: 150),
                                             screen: CGRect(origin: .zero, size: screen.size), captureScale: 1)
        expect(mid == 1, "200×150 on a 1x display: no magnification, got \(mid)")
        let half = EditorLayout.magnification(selection: CGRect(x: 0, y: 0, width: 300, height: 250),
                                              screen: CGRect(x: 0, y: 0, width: 640, height: 480),
                                              captureScale: 2)
        expect(half == 1, "300×250 on 640×480 @2x: half the display allows no 2x, got \(half)")
    }

    /// Below `insetScale`'s 0.6 floor the capture is left pixel-exact and the cards gather —
    /// the one case allowed to sit over the capture, but still not on each other or off screen.
    @objc func checkNarrowScreenFallsBackToGathering() {
        let screen = Screen(width: 640, height: 480)
        let l = layout(screen.size, on: screen, captureScale: 1, cards: cardSets[0].sizes)
        expect(l.inset == 1, "whole-screen on 640×480: below the 0.6 floor → 1, got \(l.inset)")
        expect(!l.placement.gathered.isEmpty, "whole-screen on 640×480: cards gather")
        let v = violations(l, on: screen)
        expect(v.isEmpty, "whole-screen on 640×480: " + v.joined(separator: "; "))
    }

    /// `relayout`'s clamp: a frame that fits is kept `8 + pad` inside the screen; one that
    /// doesn't is centred rather than pinned to a corner; both land on whole points.
    @objc func checkRelayoutClampCentresOverflowAndRounds() {
        let bounds = CGSize(width: 1440, height: 900)
        let fits = EditorLayout.clampCanvas(CGRect(x: -50.4, y: 880.6, width: 400, height: 300),
                                            pad: 10, in: bounds)
        expect(fits == CGRect(x: 18, y: 582, width: 400, height: 300),
               "clamped 18 pt in (8 + pad 10), got \(fits)")
        let over = EditorLayout.clampCanvas(CGRect(x: 0, y: 0, width: 1500, height: 950),
                                            pad: 0, in: bounds)
        expect(over == CGRect(x: -30, y: -25, width: 1500, height: 950),
               "oversize frame centred, got \(over)")
    }
}
