import Foundation

/// Where the display *layout* enters the capture: the global rect, the per-display pixel
/// scale and its rounding, and the CoreGraphics↔AppKit global flips. Multi-monitor capture
/// broke four times (#22, #38, #53, #54) in exactly these places, so each layout a user can
/// actually arrange — mixed density, a screen left of and below the primary, a screen
/// stacked above it — is described here with explicit origins, scales and heights.
final class CaptureLayoutChecks: CheckSuite {
    /// A display as AppKit lays it out: its global frame in points and its still's density.
    private struct Display {
        let frame: CGRect
        let scale: CGFloat
        var imageSize: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }
    }

    private let primary = Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    private var primaryHeight: CGFloat { primary.frame.height }

    /// The whole overlay-to-pixels path `ScreenshotController.finish` + `crop` run, for one display.
    private func capture(_ viewRect: CGRect, on d: Display) -> (global: CGRect, pixel: CGRect?) {
        let global = CaptureGeometry.globalRect(viewRect: viewRect, screenOrigin: d.frame.origin)
        let source = CaptureGeometry.sourceRect(viewRect: viewRect, displayHeight: d.frame.height)
        let pixel = CaptureGeometry.pixelRect(sourceRect: source, scale: d.scale, imageSize: d.imageSize)
        return (global, pixel)
    }

    // MARK: - Matrix rows

    @objc func checkMixedDensityScalesEachDisplayByItsOwnStill() {
        let external = Display(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)
        let region = CGRect(x: 100, y: 200, width: 300, height: 150)

        let scaleP = CaptureGeometry.scale(pixelWidth: 2880, pointWidth: 1440)
        let scaleE = CaptureGeometry.scale(pixelWidth: 1920, pointWidth: 1920)
        expect(scaleP == 2, "primary still 2880 px over 1440 pt → scale 2, got \(scaleP)")
        expect(scaleE == 1, "external still 1920 px over 1920 pt → scale 1, got \(scaleE)")

        let p = capture(region, on: primary)
        expect(p.global == CGRect(x: 100, y: 200, width: 300, height: 150),
               "primary global rect = view rect at origin (0,0), got \(p.global)")
        expect(p.pixel == CGRect(x: 200, y: 1100, width: 600, height: 300),
               "primary @2x: source (100,550,300,150) × 2 → (200,1100,600,300), got \(String(describing: p.pixel))")

        let e = capture(region, on: external)
        expect(e.global == CGRect(x: 1540, y: 200, width: 300, height: 150),
               "external global rect offset by its origin x=1440, got \(e.global)")
        expect(e.pixel == CGRect(x: 100, y: 730, width: 300, height: 150),
               "external @1x: flipped in its own 1080 pt → (100,730,300,150), got \(String(describing: e.pixel))")
    }

    @objc func checkNegativeOriginKeepsNegativeGlobalAndLandsWindowOnThatScreen() {
        let external = Display(frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080), scale: 1)

        let e = capture(CGRect(x: 100, y: 50, width: 300, height: 100), on: external)
        expect(e.global == CGRect(x: -1820, y: -130, width: 300, height: 100),
               "global rect keeps the screen's negative x/y, got \(e.global)")
        expect(e.pixel == CGRect(x: 100, y: 930, width: 300, height: 100),
               "pixel rect is display-local, unaffected by the negative origin, got \(String(describing: e.pixel))")

        let window = CaptureGeometry.appKitRect(fromCG: CGRect(x: -1500, y: 600, width: 400, height: 300),
                                                primaryHeight: primaryHeight)
        expect(window == CGRect(x: -1500, y: 0, width: 400, height: 300),
               "CG window (-1500,600,400,300) → AppKit (-1500,0,400,300), got \(window)")
        expect(external.frame.contains(window), "window lands inside the external screen \(external.frame), got \(window)")
        expect(!primary.frame.intersects(window), "window must not land on the primary screen, got \(window)")
    }

    @objc func checkVerticallyStackedWindowLandsOnUpperScreen() {
        let external = Display(frame: CGRect(x: -240, y: 900, width: 1920, height: 1080), scale: 1)

        let topInCG = CaptureGeometry.appKitRect(fromCG: external.frame, primaryHeight: primaryHeight).minY
        expect(topInCG == -1080, "screen stacked above the primary has CG y = -1080, got \(topInCG)")

        let window = CaptureGeometry.appKitRect(fromCG: CGRect(x: 100, y: -1000, width: 400, height: 300),
                                                primaryHeight: primaryHeight)
        expect(window == CGRect(x: 100, y: 1600, width: 400, height: 300),
               "CG window (100,-1000,400,300) → AppKit y 1600, got \(window)")
        expect(external.frame.contains(window), "window lands inside the upper screen \(external.frame), got \(window)")

        let mouse = CGPoint(x: 500, y: 1500)
        let cg = CaptureGeometry.cgPoint(fromAppKit: mouse, primaryHeight: primaryHeight)
        expect(cg == CGPoint(x: 500, y: -600), "AppKit (500,1500) → CG (500,-600), got \(cg)")
        let back = CaptureGeometry.cgPoint(fromAppKit: cg, primaryHeight: primaryHeight)
        expect(back == mouse, "AppKit → CG → AppKit round-trips to \(mouse), got \(back)")
    }

    @objc func checkFractionalOriginAndSizeRoundToNearestHalfAwayFromZero() {
        let big = CGSize(width: 4000, height: 4000)

        let nearest = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 10.125, y: 10.375, width: 50.125, height: 50.375),
                                                scale: 2, imageSize: big)
        expect(nearest == CGRect(x: 20, y: 21, width: 100, height: 101),
               "2x: 20.25→20, 20.75→21, 100.25→100, 100.75→101 (nearest, not up/down/truncated), got \(String(describing: nearest))")

        let halfAt2 = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 10.5, y: 20.5, width: 100.5, height: 50.5),
                                                scale: 2, imageSize: big)
        expect(halfAt2 == CGRect(x: 21, y: 41, width: 201, height: 101),
               ".5 edges at 2x land on whole pixels, got \(String(describing: halfAt2))")

        let quarterAt2 = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 10.25, y: 20.75, width: 100.25, height: 50.25),
                                                   scale: 2, imageSize: big)
        expect(quarterAt2 == CGRect(x: 21, y: 42, width: 201, height: 101),
               "x.5 pixel edges round up (20.5→21, 41.5→42, 200.5→201, 100.5→101), got \(String(describing: quarterAt2))")

        let at1_5 = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 1, y: 3, width: 5, height: 7),
                                              scale: 1.5, imageSize: big)
        expect(at1_5 == CGRect(x: 2, y: 5, width: 8, height: 11),
               "1.5x: 1.5→2, 4.5→5, 7.5→8, 10.5→11 (width rounded on its own, not via maxX), got \(String(describing: at1_5))")
    }

    @objc func checkOverhangIsClampedToTheImage() {
        let r = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 1400, y: 850, width: 100, height: 100),
                                          scale: 2, imageSize: primary.imageSize)
        expect(r == CGRect(x: 2800, y: 1700, width: 80, height: 100),
               "rect overhanging right/bottom of 2880×1800 clamps to (2800,1700,80,100), got \(String(describing: r))")
    }

    @objc func checkOffImageAndSubPixelRectsGiveNoCrop() {
        let outside = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 1500, y: 0, width: 100, height: 100),
                                                scale: 2, imageSize: primary.imageSize)
        expect(outside == nil, "rect fully right of the image → nil, got \(String(describing: outside))")

        let touching = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 1440, y: 0, width: 100, height: 100),
                                                 scale: 2, imageSize: primary.imageSize)
        expect(touching == nil, "rect starting exactly at the image's right edge → nil, got \(String(describing: touching))")

        let tiny = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 10, y: 10, width: 0.2, height: 0.2),
                                             scale: 2, imageSize: primary.imageSize)
        expect(tiny == nil, "0.2 pt at 2x rounds to 0 px → nil, got \(String(describing: tiny))")

        let thin = CaptureGeometry.pixelRect(sourceRect: CGRect(x: 10, y: 10, width: 100, height: 0.3),
                                             scale: 1.5, imageSize: primary.imageSize)
        expect(thin == nil, "0.3 pt at 1.5x rounds to 0 px tall → nil, got \(String(describing: thin))")
    }

    // MARK: - Round trip

    /// The overlay hit-tests the AppKit mouse against CG window frames, so the point flip and
    /// the rect flip must agree: a point inside a window in one space is inside it in the other.
    @objc func checkAppKitAndCGFlipsAgreeAndRoundTrip() {
        let layouts: [(String, CGRect)] = [
            ("primary", primary.frame),
            ("mixed-density right", CGRect(x: 1440, y: 0, width: 1920, height: 1080)),
            ("negative origin", CGRect(x: -1920, y: -180, width: 1920, height: 1080)),
            ("stacked above", CGRect(x: -240, y: 900, width: 1920, height: 1080)),
        ]
        for (name, screen) in layouts {
            let cgScreen = CaptureGeometry.appKitRect(fromCG: screen, primaryHeight: primaryHeight)
            let back = CaptureGeometry.appKitRect(fromCG: cgScreen, primaryHeight: primaryHeight)
            expect(back == screen, "\(name): AppKit → CG → AppKit rect round-trips to \(screen), got \(back)")

            let mouse = CGPoint(x: screen.minX + 37, y: screen.minY + 41)
            let cgMouse = CaptureGeometry.cgPoint(fromAppKit: mouse, primaryHeight: primaryHeight)
            expect(cgScreen.contains(cgMouse),
                   "\(name): AppKit point \(mouse) inside \(screen) maps to CG \(cgMouse) inside \(cgScreen)")
            let mouseBack = CaptureGeometry.cgPoint(fromAppKit: cgMouse, primaryHeight: primaryHeight)
            expect(mouseBack == mouse, "\(name): point round-trips to \(mouse), got \(mouseBack)")
        }
    }
}
