// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Dims the recorded region and cuts a soft circle around the cursor that follows it
/// live, for a polished "tutorial video" focus look (Settings → Video → "Cursor
/// spotlight"). One borderless window per screen the recording target touches, sized
/// to just that target's on-screen bounds.
///
/// Unlike `RecordingDimWindow`'s framing cue, these windows are deliberately NOT
/// excluded from the SCStream — being visible in the captured frames is the entire
/// point, the same on-screen-is-the-capture approach `ClickVisualizer` uses for click
/// ripples. That also means the effect dims the presenter's live screen while
/// recording, not just the saved video.
///
/// Cursor position is sampled on a 30 Hz timer rather than an `NSEvent` mouse-move
/// monitor: a global + local monitor pair firing (and redrawing every screen) on
/// every raw move event was heavy enough on a high-poll-rate mouse/trackpad to stall
/// the main thread right as a recording started, which read as an app freeze.
final class CursorSpotlight {
    private var windows: [SpotlightWindow] = []
    private var timer: Timer?

    /// `targetRect` is the recording target's bounds in AppKit global screen
    /// coordinates (a region rect, a window frame, or a whole screen's frame).
    func start(targetRect: CGRect) {
        stop()
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(targetRect)
            guard !inter.isNull, inter.width > 1, inter.height > 1 else { continue }
            let holeInScreen = CGRect(x: inter.minX - screen.frame.minX, y: inter.minY - screen.frame.minY,
                                      width: inter.width, height: inter.height)
            let win = SpotlightWindow(screen: screen, holeInScreen: holeInScreen)
            win.orderFront(nil)
            windows.append(win)
        }
        guard !windows.isEmpty else { return }
        updateCenter()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.updateCenter() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    deinit { stop() }

    private func updateCenter() {
        let global = NSEvent.mouseLocation
        for win in windows {
            guard let screen = win.screen else { continue }
            let local = CGPoint(x: global.x - screen.frame.minX, y: global.y - screen.frame.minY)
            // Skip the redraw entirely when the cursor hasn't moved relative to this
            // screen — cheap, and avoids repainting every screen's window on every tick.
            if win.spotlightCenter != local { win.spotlightCenter = local }
        }
    }
}

/// A click-through window covering one screen, dimming everything in `holeInScreen`
/// except a soft circle that tracks the cursor.
private final class SpotlightWindow: NSWindow {
    private let spotlightView: SpotlightView

    var spotlightCenter: CGPoint {
        get { spotlightView.center }
        set { spotlightView.center = newValue }
    }

    init(screen: NSScreen, holeInScreen: CGRect) {
        spotlightView = SpotlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
        spotlightView.clipRect = holeInScreen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = spotlightView
    }
}

private final class SpotlightView: NSView {
    /// The recorded region's bounds in this view's local coordinates — dimming (and
    /// the spotlight hole) never draws outside it.
    var clipRect: CGRect = .zero
    var center: CGPoint = .zero {
        didSet { invalidateSpot(old: oldValue, new: center) }
    }
    /// Fully-clear inner radius and the larger radius the soft falloff fades out by.
    private static let clearRadius: CGFloat = 55
    private static let falloffRadius: CGFloat = 85
    /// A light dim outside the spotlight — enough to draw the eye to the cursor
    /// without hiding the rest of the screen (a near-opaque dim reads as "everything
    /// but the cursor is invisible", which isn't what a highlight effect should do).
    private static let dimAlpha: CGFloat = 0.32

    private func invalidateSpot(old: CGPoint, new: CGPoint) {
        let pad = Self.falloffRadius + 4
        let o = CGRect(x: old.x - pad, y: old.y - pad, width: pad * 2, height: pad * 2)
        let n = CGRect(x: new.x - pad, y: new.y - pad, width: pad * 2, height: pad * 2)
        setNeedsDisplay(o.union(n))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !clipRect.isNull else { return }
        ctx.saveGState()
        ctx.clip(to: clipRect)
        ctx.setFillColor(NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor)
        ctx.fill(clipRect)

        // Only punch the spotlight hole while the cursor is actually over the
        // recorded area — otherwise the falloff can still bleed a sliver of clear
        // space in at whichever edge of `clipRect` is nearest the (off-region)
        // cursor. Outside the region, the dim just stays flat with no hole. Both the
        // gradient and the ring below stay inside the outer clip set above, so
        // neither can ever paint outside `clipRect`.
        if clipRect.insetBy(dx: -Self.falloffRadius, dy: -Self.falloffRadius).contains(center) {
            // Punch the cursor's circle back to fully clear, with a short soft
            // falloff so the edge reads as a gentle highlight, not a hard disc.
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                         colors: [NSColor.white.cgColor, NSColor.white.cgColor,
                                                  NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                         locations: [0.0, Self.clearRadius / Self.falloffRadius, 1.0]) {
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: Self.falloffRadius, options: [])
            }
            ctx.restoreGState()

            // A thin lavender ring at the clear/dim boundary so the spotlight edge
            // reads as an intentional highlight rather than just a blur seam.
            ctx.setStrokeColor(Theme.lavender.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: center.x - Self.clearRadius, y: center.y - Self.clearRadius,
                                         width: Self.clearRadius * 2, height: Self.clearRadius * 2))
        }
        ctx.restoreGState()
    }
}
