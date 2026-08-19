// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import CoreImage
import CoreVideo

/// Zooms a recording without touching the user's real screen: each captured frame is
/// cropped to a sub-rect and scaled back up to the output size before it reaches the
/// encoder, so the video shows a magnified view while the desktop carries on unchanged.
///
/// **Why the transform lives here and not in ScreenCaptureKit.** Animating
/// `SCStreamConfiguration.sourceRect` via `updateConfiguration` would be the obvious route,
/// but those updates are asynchronous with unpredictable latency — per-frame calls at 30/60
/// fps stutter, and there is no control over the easing. Cropping frames we already have is
/// deterministic and costs one GPU pass. (macOS's own accessibility zoom is out: it zooms
/// the user's actual screen.)
///
/// The frame path is the real-time part of the recorder, so this type is deliberately
/// allocation-light: one `CIContext`, one `CVPixelBufferPool`, and no work at all when the
/// factor is 1. It runs on `VideoRecordSession`'s `writeQueue`, never the main thread.
final class RecordZoomEngine {

    /// Interpolation used to scale the crop back up. Lanczos is sharper; the affine path is
    /// the cheap fallback if Lanczos can't hold the frame budget at high resolutions.
    enum Scaler: String, CaseIterable {
        case lanczos, affine
    }

    /// Output frame size in pixels — fixed for the life of a recording, matching the
    /// `AVAssetWriterInput` dimensions. The transform always renders exactly this size, so
    /// the encoder never sees a dimension change mid-stream.
    let outputSize: CGSize
    var scaler: Scaler

    private let ciContext: CIContext
    private let pool: CVPixelBufferPool?

    // Rolling cost stats, so a recording can report what the transform actually cost
    // instead of relying on a benchmark done under different conditions.
    private(set) var frameCount = 0
    private var totalSeconds = 0.0
    var averageMilliseconds: Double { frameCount == 0 ? 0 : totalSeconds / Double(frameCount) * 1000 }

    // MARK: - Zoom state

    /// Where the recorded region sits in global AppKit space, and how many pixels one point
    /// is — together these map a global cursor position into frame-pixel space. Snapshotted
    /// at init on the main thread so the frame path never touches `NSScreen`.
    private let region: CGRect
    private let pixelScale: CGFloat
    private let primaryHeight: CGFloat

    /// Factor to ease to when zoomed in (Settings → Video → Zoom level).
    private let zoomFactor: CGFloat

    private enum Phase { case out, easingIn, zoomed, easingOut }
    private var phase: Phase = .out
    private var phaseStart: TimeInterval = 0
    private var factorAtPhaseStart: CGFloat = 1
    private var currentFactor: CGFloat = 1
    /// Smoothed viewport centre in frame pixels — this lag is what makes the camera glide
    /// after the cursor instead of snapping to it.
    private var smoothedCenter: CGPoint = .zero
    private var lastSampleTime: TimeInterval = 0
    private var lastViewport: CGRect?

    /// State is advanced from the capture write queue (real recordings) and from the
    /// controller's indicator tick (and simulate mode, where no frames exist), so every
    /// mutation is serialised. Contention is trivial at ~60 + ~30 calls a second.
    private let lock = NSLock()

    private static let easeDuration: TimeInterval = 0.45
    /// Seconds for the camera to cover ~63% of the distance to the cursor. Larger = calmer.
    private static let followTimeConstant: TimeInterval = 0.28
    /// Points of cursor movement ignored before the camera responds, so it sits still during
    /// hand jitter rather than drifting continuously — the difference between calm and seasick.
    private static let deadZone: CGFloat = 8

    init(outputSize: CGSize, scaler: Scaler = .lanczos) {
        self.outputSize = outputSize
        self.scaler = scaler
        // Rec. 709 working space matches what `VideoRecordSession` tells the encoder, so the
        // transform can't shift colour. Intermediates are never reused frame to frame, so
        // caching them only grows memory.
        self.ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709) as Any,
            .cacheIntermediates: false,
        ])
        self.pool = Self.makePool(width: Int(outputSize.width), height: Int(outputSize.height))
        // Benchmark path: no region mapping, so the follow logic is inert.
        self.region = .zero
        self.pixelScale = 1
        self.primaryHeight = 0
        self.zoomFactor = 2
    }

    /// The initialiser a real recording uses.
    ///
    /// - Parameters:
    ///   - region: the recorded rect in global AppKit points (bottom-left origin).
    ///   - pixelScale: `SCContentFilter.pointPixelScale` — pixels per point for this display.
    ///   - factor: the zoom level to ease to.
    convenience init(region: CGRect, pixelScale: CGFloat, factor: CGFloat, scaler: Scaler = .lanczos) {
        self.init(outputSize: CGSize(width: region.width * pixelScale,
                                     height: region.height * pixelScale),
                  region: region, pixelScale: pixelScale, factor: factor, scaler: scaler)
    }

    private init(outputSize: CGSize, region: CGRect, pixelScale: CGFloat,
                 factor: CGFloat, scaler: Scaler) {
        self.outputSize = outputSize
        self.scaler = scaler
        self.ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709) as Any,
            .cacheIntermediates: false,
        ])
        self.pool = Self.makePool(width: Int(outputSize.width), height: Int(outputSize.height))
        self.region = region
        self.pixelScale = pixelScale
        self.primaryHeight = WindowList.primaryHeight
        self.zoomFactor = factor
    }

    // MARK: - Toggle

    /// Whether zoom is engaged (including while easing in).
    var isZoomed: Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .easingIn || phase == .zoomed
    }

    /// Toggle zoom, anchored on the cursor's position *at this moment* — the zoom lands on
    /// whatever the user is pointing at, not wherever the camera drifted to last time.
    /// Easing starts from the current factor, so a toggle mid-animation reverses smoothly
    /// instead of jumping.
    func toggle() {
        lock.lock(); defer { lock.unlock() }
        let zoomedNow = (phase == .easingIn || phase == .zoomed)
        if zoomedNow {
            phase = .easingOut
        } else {
            smoothedCenter = unlockedCursorInFrame()
                ?? CGPoint(x: outputSize.width / 2, y: outputSize.height / 2)
            lastSampleTime = 0
            phase = .easingIn
        }
        factorAtPhaseStart = currentFactor
        phaseStart = CACurrentMediaTime()
    }

    // MARK: - Per-frame geometry

    /// Advance the ease and the cursor follow, and return the viewport for the next frame —
    /// or nil when fully zoomed out, which is the common case and costs nothing.
    ///
    /// Time comes from the wall clock rather than frame PTS. A pause needs no special case:
    /// frames stop reaching the transform (`append` returns early while paused), so an ease
    /// in flight simply completes unseen and the camera is settled on resume. The follow's
    /// `dt` is clamped, so the first sample after a long pause takes one modest step rather
    /// than lurching.
    func advanceAndViewport() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()

        switch phase {
        case .out:
            currentFactor = 1
        case .zoomed:
            currentFactor = zoomFactor
        case .easingIn, .easingOut:
            let target: CGFloat = (phase == .easingIn) ? zoomFactor : 1
            let t = Self.smoothstep(CGFloat((now - phaseStart) / Self.easeDuration))
            currentFactor = factorAtPhaseStart + (target - factorAtPhaseStart) * t
            if t >= 1 {
                currentFactor = target
                phase = (phase == .easingIn) ? .zoomed : .out
            }
        }

        guard currentFactor > 1.001 else {
            lastViewport = nil
            lastSampleTime = 0
            return nil
        }

        if let target = unlockedCursorInFrame() {
            let dt = lastSampleTime == 0 ? 1.0 / 60 : min(now - lastSampleTime, 0.25)
            // Time-constant smoothing rather than a fixed per-frame step, so the glide feels
            // identical at 30 and 60 fps.
            let alpha = CGFloat(1 - exp(-dt / Self.followTimeConstant))
            let dx = target.x - smoothedCenter.x, dy = target.y - smoothedCenter.y
            if hypot(dx, dy) > Self.deadZone * pixelScale {
                smoothedCenter.x += dx * alpha
                smoothedCenter.y += dy * alpha
            }
        }
        lastSampleTime = now

        let vp = Self.viewport(outputSize: outputSize, factor: currentFactor, center: smoothedCenter)
        lastViewport = vp
        return vp
    }

    /// The zoom factor in effect right now — 1 when fully out, and the intermediate values
    /// while easing. The indicator reads this so its badge counts up and down with the
    /// animation instead of snapping between 1 and the target.
    var currentZoomLevel: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return currentFactor
    }

    /// "2×" / "1.5×" — trailing zeros dropped so the badge stays short.
    static func label(forFactor f: CGFloat) -> String {
        f == f.rounded() ? String(format: "%.0f×", f) : String(format: "%.1f×", f)
    }

    /// The viewport most recently computed, as a global AppKit rect — what the on-screen
    /// indicator draws, so the user can see what is actually in frame while their real screen
    /// stays un-zoomed. Nil when zoomed out.
    func latestIndicatorRect() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        guard let vp = lastViewport, pixelScale > 0 else { return nil }
        return CGRect(x: region.minX + vp.minX / pixelScale,
                      y: region.minY + vp.minY / pixelScale,
                      width: vp.width / pixelScale,
                      height: vp.height / pixelScale)
    }

    /// Cursor position in frame pixels, or nil when it is outside the recorded region — the
    /// camera then holds still instead of lurching to an edge. Caller must hold `lock`.
    private func unlockedCursorInFrame() -> CGPoint? {
        guard pixelScale > 0, let cg = CGEvent(source: nil)?.location else { return nil }
        // CoreGraphics is top-left origin; flipping within the primary display's height is an
        // involution, so this one expression converts either way (see `WindowList`).
        let global = CGPoint(x: cg.x, y: primaryHeight - cg.y)
        guard region.contains(global) else { return nil }
        return CGPoint(x: (global.x - region.minX) * pixelScale,
                       y: (global.y - region.minY) * pixelScale)
    }

    /// Ease-in-out, so the zoom neither starts nor stops abruptly on camera.
    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Crop `source` to `viewport` and scale it back to `outputSize`.
    ///
    /// `viewport` is in source *pixel* coordinates with a bottom-left origin — CoreImage's
    /// convention, not ScreenCaptureKit's. Returns nil if a buffer can't be vended, in which
    /// case the caller should append the untouched frame rather than drop it.
    ///
    /// The returned buffer belongs to this engine's pool; never hand back SCStream's own
    /// buffer, which the framework reuses.
    func transform(_ source: CVPixelBuffer, viewport: CGRect) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var vended: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &vended) == kCVReturnSuccess,
              let destination = vended else { return nil }

        let started = CACurrentMediaTime()
        let image = CIImage(cvPixelBuffer: source)
        // Crop, move the crop to the origin, then scale — in that order, so the scale
        // applies to the cropped extent rather than the whole frame.
        let cropped = image
            .cropped(to: viewport)
            .transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
        let scaleX = outputSize.width / viewport.width
        let scaleY = outputSize.height / viewport.height
        let scaled: CIImage
        switch scaler {
        case .lanczos:
            scaled = cropped.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleX,
                kCIInputAspectRatioKey: scaleY / scaleX,
            ])
        case .affine:
            scaled = cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        ciContext.render(scaled, to: destination)
        totalSeconds += CACurrentMediaTime() - started
        frameCount += 1
        return destination
    }

    /// A viewport of `outputSize / factor` centred on `center`, clamped inside the frame.
    ///
    /// Origins and sizes are forced even: 420v is 4:2:0 chroma-subsampled, so an odd crop
    /// splits a chroma sample pair and shifts colour against luma (and some renders simply
    /// fail). Even geometry costs at most one pixel of precision.
    static func viewport(outputSize: CGSize, factor: CGFloat, center: CGPoint) -> CGRect {
        let w = (outputSize.width / factor).rounded(.down)
        let h = (outputSize.height / factor).rounded(.down)
        let evenW = max(2, w - w.truncatingRemainder(dividingBy: 2))
        let evenH = max(2, h - h.truncatingRemainder(dividingBy: 2))
        var x = (center.x - evenW / 2).rounded(.down)
        var y = (center.y - evenH / 2).rounded(.down)
        x = min(max(0, x), outputSize.width - evenW)
        y = min(max(0, y), outputSize.height - evenH)
        return CGRect(x: x - x.truncatingRemainder(dividingBy: 2),
                      y: y - y.truncatingRemainder(dividingBy: 2),
                      width: evenW, height: evenH)
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // IOSurface-backed so the GPU render and the encoder can share the memory.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }
}

// MARK: - Benchmark (dev only)

extension RecordZoomEngine {
    /// Measure the per-frame cost of the zoom transform against the real frame budget, and
    /// print a table. Run with `./build.sh --run` then `open build/m_capture.app --args
    /// --zoom-benchmark`, or see CONTRIBUTING.
    ///
    /// Deliberately synthetic — it builds its own 420v frames instead of capturing, so it
    /// needs **no Screen Recording permission** and can be run before the pipeline is wired
    /// up at all. That makes it the cheap way to answer the one question that decides the
    /// design: does a Lanczos crop-and-upscale fit inside 33 ms (30 fps) / 16.7 ms (60 fps)?
    static func runBenchmark(iterations: Int = 120) {
        let sizes: [(String, CGSize)] = [
            ("1080p", CGSize(width: 1920, height: 1080)),
            ("1440p", CGSize(width: 2560, height: 1440)),
            ("4K",    CGSize(width: 3840, height: 2160)),
        ]
        let factors: [CGFloat] = [1.5, 2, 3]

        print("zoom transform benchmark — \(iterations) frames per case")
        print("budget: 33.3 ms at 30 fps, 16.7 ms at 60 fps\n")
        // Manual padding rather than String(format:) — %s there expects a C string, not a
        // Swift String, and silently prints garbage.
        func col(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        func rcol(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
        print(col("size", 8) + col("factor", 8) + col("scaler", 9)
              + rcol("avg ms", 9) + rcol("max fps", 9) + rcol("verdict", 10))

        for (label, size) in sizes {
            guard let source = makeSourceFrame(size: size) else {
                print("  \(label): could not build a source frame — skipped")
                continue
            }
            for factor in factors {
                for scaler in Scaler.allCases {
                    let engine = RecordZoomEngine(outputSize: size, scaler: scaler)
                    let viewport = RecordZoomEngine.viewport(
                        outputSize: size, factor: factor,
                        center: CGPoint(x: size.width / 2, y: size.height / 2))
                    // One untimed pass first: the first render pays shader compilation and
                    // pool warm-up, which would otherwise skew a short run.
                    _ = engine.transform(source, viewport: viewport)
                    let warmed = RecordZoomEngine(outputSize: size, scaler: scaler)
                    for _ in 0..<iterations {
                        _ = warmed.transform(source, viewport: viewport)
                    }
                    let ms = warmed.averageMilliseconds
                    let fps = ms > 0 ? 1000 / ms : 0
                    let verdict = ms < 16.7 ? "60 fps" : (ms < 33.3 ? "30 fps" : "TOO SLOW")
                    print(col(label, 8)
                          + col(String(format: "%.1f×", Double(factor)), 8)
                          + col(scaler.rawValue, 9)
                          + rcol(String(format: "%.2f", ms), 9)
                          + rcol(String(format: "%.0f", fps), 9)
                          + rcol(verdict, 10))
                }
            }
        }
        print("\ndone")
    }

    /// A checkerboard rendered into a 420v buffer — busy enough that the scaler can't take a
    /// flat-colour shortcut, so the numbers reflect real screen content.
    private static func makeSourceFrame(size: CGSize) -> CVPixelBuffer? {
        guard let pool = makePool(width: Int(size.width), height: Int(size.height)) else { return nil }
        var vended: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &vended) == kCVReturnSuccess,
              let buffer = vended else { return nil }
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0.11, green: 0.08, blue: 0.20),
            "inputColor1": CIColor(red: 0.84, green: 0.73, blue: 1.0),
            "inputWidth": 11,
        ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
        guard let image = checker else { return nil }
        CIContext(options: [.cacheIntermediates: false]).render(image, to: buffer)
        return buffer
    }
}

// MARK: - Viewport indicator

/// A thin lavender frame over the sub-rect currently being recorded.
///
/// This exists because live zoom magnifies only the *video* — the user's own screen is
/// untouched, so without it there is no way to tell what is actually in frame. It is
/// click-through and excluded from the capture (the controller adds its `windowNumber` to the
/// stream's exclusion list before the stream starts), so it guides the user without ever
/// appearing in the recording.
final class ZoomIndicatorWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // `tearDown()` closes while the controller still holds a reference; AppKit's default
        // of true would over-release and crash.
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // With the recording dim, below the record bar — it must never take a click or cover
        // Stop.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = ZoomIndicatorView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    /// Move the frame to `rect` (global AppKit points), update the badge, and show it.
    ///
    /// Position updates are wrapped so CoreAnimation's implicit animation can't add its own
    /// lag on top of the engine's smoothing — two eases fighting reads as rubber-banding.
    /// The frame itself is already animated: the viewport is `output / factor`, so as the
    /// factor eases the rect visibly shrinks from the full frame down to the zoomed area,
    /// which is what shows *which* region is being magnified.
    func show(rect: CGRect, factor: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(rect, display: false)
        if let view = contentView as? ZoomIndicatorView {
            view.frame = NSRect(origin: .zero, size: rect.size)
            view.factor = factor
        }
        CATransaction.commit()
        guard !isVisible else { return }
        // Fade in rather than pop: the rect appears mid-ease, and an abrupt outline reads as
        // a glitch next to a smooth zoom.
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    /// Fade out, then order out — so the outline doesn't vanish a frame before the zoom
    /// finishes easing back to 1×.
    func hide() {
        guard isVisible, alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }

    /// Recording is over: hide, then close a tick later — never inline, since this can run
    /// from a timer handler, and `orderOut` alone can strand a floating-level window's surface
    /// (see `VideoRecordController.dismissOverlays`).
    func tearDown() {
        orderOut(nil)
        DispatchQueue.main.async { [self] in close() }
    }
}

private final class ZoomIndicatorView: NSView {
    /// Live zoom factor, shown as a badge so the state is readable at a glance rather than
    /// inferred from the rectangle's size.
    var factor: CGFloat = 1 { didSet { if factor != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lw: CGFloat = 2
        let frame = bounds.insetBy(dx: lw / 2, dy: lw / 2)

        // A faint full outline delimits the area, and brighter corner brackets make it read
        // as a camera frame rather than a selection — the same lavender as the selection
        // overlay's region outline, so it stays in the family.
        ctx.setStrokeColor(Theme.lavender.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(lw)
        ctx.stroke(frame)

        let arm = min(30, min(frame.width, frame.height) / 4)
        ctx.setStrokeColor(Theme.lavender.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
                                 (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                                 (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0),
                                 (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: corner.x + arm * CGFloat(dx), y: corner.y))
            ctx.addLine(to: corner)
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * CGFloat(dy)))
            ctx.strokePath()
        }

        // Factor badge, inset from the top-left corner. This window is excluded from the
        // capture, so the badge guides the user without ever landing in the video.
        let text = RecordZoomEngine.label(forFactor: factor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(12, .bold),
            .foregroundColor: Theme.surfaceBase,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        let pill = NSRect(x: frame.minX + 8, y: frame.maxY - size.height - pad * 1.4 - 8,
                          width: size.width + pad * 2, height: size.height + pad)
        guard pill.maxX < frame.maxX, pill.minY > frame.minY else { return }
        ctx.setFillColor(Theme.lavender.cgColor)
        ctx.fill(pill)
        (text as NSString).draw(at: NSPoint(x: pill.minX + pad, y: pill.minY + pad / 2),
                                withAttributes: attrs)
    }
}
