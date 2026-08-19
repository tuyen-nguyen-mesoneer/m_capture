// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Freehand drawing over the screen while a recording runs — toggled by the draw hotkey
/// (⌃⇧D), the record bar's pencil, or the status menu.
///
/// Strokes end up in the video for the same reason `ClickVisualizer`'s ripples do: this
/// overlay window is deliberately *not* added to the SCStream's exclusion list, so whatever
/// it shows is composited into the captured frames. Each stroke then fades on its own a few
/// seconds after it's finished, so a long recording doesn't accumulate stale annotations and
/// the common case needs no clearing gesture at all.
///
/// Region and whole-screen recordings only. A window target uses
/// `SCContentFilter(desktopIndependentWindow:)`, which composites nothing but that one
/// window — no overlay of ours could ever reach the video — so the controller creates none.
final class RecordDrawOverlay {
    /// Fires when draw mode turns on or off, so the record bar's pencil tile reflects a
    /// toggle that came from the hotkey or the menu rather than from the tile itself.
    var onModeChange: ((Bool) -> Void)?

    private let window: DrawOverlayWindow
    private let view: DrawOverlayView

    /// Bundle ID of whatever was frontmost when draw mode was entered. Drawing needs
    /// keyboard focus (Esc / ⌫), which means activating us; this hands activation back on
    /// exit so the rest of the recording doesn't leave m_capture squatting on "active app".
    /// Same `yieldActivation` contract `VideoRecordController.appToRestore` documents.
    private var appToRestore: String?

    var isActive: Bool { view.isActive }
    var hasStrokes: Bool { view.hasStrokes }
    /// The tool currently armed (pencil / rectangle / circle / line / arrow).
    var tool: DrawTool { view.tool }

    /// Switch tool and remember it for the next recording. Toasts the name because the
    /// record bar is usually minimized, so a keystroke would otherwise have no feedback.
    func setTool(_ tool: DrawTool) {
        guard view.tool != tool else { return }
        view.tool = tool
        Settings.shared.drawTool = tool
        BrandToast.show(tool.label)
    }

    /// `region` is the recorded rect in global AppKit coordinates (bottom-left origin) —
    /// the overlay covers exactly what the video shows, so nothing can be drawn off-frame.
    init(region: CGRect) {
        view = DrawOverlayView(frame: NSRect(origin: .zero, size: region.size))
        window = DrawOverlayWindow(contentRect: region, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // `tearDown()` closes the window while this object still holds a reference;
        // AppKit's default of `true` would over-release and crash.
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true   // until draw mode is actually on
        // Above the recording dim (also floating − 1, ordered front earlier, and
        // mouse-ignoring) but below the record bar at `.floating`, so Stop and Pause stay
        // clickable while drawing.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        window.onExit = { [weak self] in self?.deactivate() }
        window.onClear = { [weak self] in self?.clear() }
        // Tool letters are resolved live from Settings, so a rebind in Settings → Drawing
        // applies to a recording already in progress.
        window.onToolKey = { [weak self] key in
            guard let self,
                  let picked = DrawTool.allCases.first(where: { Settings.shared.drawKey($0) == key })
            else { return false }
            self.setTool(picked)
            return true
        }
        // A stroke left fading when draw mode ended keeps the window up until it's gone;
        // this is what finally hides it.
        view.onStrokesEmpty = { [weak self] in
            guard let self, !self.isActive else { return }
            self.window.orderOut(nil)
        }
    }

    func toggle() { isActive ? deactivate() : activate() }

    func activate() {
        guard !isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        appToRestore = front == Bundle.main.bundleIdentifier ? nil : front
        // Pick up the tool last used, plus any colour/thickness/fade changed in Settings.
        view.tool = Settings.shared.drawTool
        view.isActive = true
        window.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.invalidateCursorRects(for: view)
        // The bar starts minimized by default, so a hotkey toggle would otherwise have no
        // acknowledgement beyond the cursor changing.
        BrandToast.show(L("Drawing on — Esc to stop, ⌫ to clear"))
        onModeChange?(true)
    }

    func deactivate() {
        guard isActive else { return }
        // Leaving mid-drag: hand the in-flight stroke its fade before mouse events stop
        // arriving, or it would sit on screen for the rest of the recording.
        view.finishCurrentStroke()
        view.isActive = false
        // Stop intercepting clicks at once, but leave the window up if strokes are still
        // fading — cutting them off mid-fade would show as a jump in the video.
        window.ignoresMouseEvents = true
        if let bundleID = appToRestore { NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID) }
        appToRestore = nil
        if !hasStrokes { window.orderOut(nil) }
        onModeChange?(false)
    }

    /// Wipe every stroke now (⌫, or the menu's Clear Drawings).
    func clear() { view.clearAll() }

    /// The recording is over: drop everything without fading (no more frames for a fade to
    /// appear in) and tear the window down. `close()` a runloop tick later — never inline,
    /// since this can run from the window's own event handling — because `orderOut` alone
    /// can leave a floating-level window's surface on screen, the same hazard
    /// `VideoRecordController.dismissOverlays` documents.
    func tearDown() {
        view.isActive = false
        view.dropAllStrokes()
        window.ignoresMouseEvents = true
        if let bundleID = appToRestore { NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID) }
        appToRestore = nil
        window.orderOut(nil)
        let stale = window
        DispatchQueue.main.async { stale.close() }
    }
}

// MARK: - Window

/// Intercepts Esc and ⌫ so drawing can be left or cleared from the keyboard.
///
/// **Esc leaves draw mode — it never discards the recording.** Discard stays on the record
/// bar's own Esc and the ⌥-record hotkey; while this overlay is key it owns Esc, and a
/// stray sketch must not be able to throw away the take.
private final class DrawOverlayWindow: NSWindow {
    var onExit: (() -> Void)?
    var onClear: (() -> Void)?
    /// Returns true if the character selected a tool, so it isn't passed on as an
    /// unhandled key (which would beep).
    var onToolKey: ((String) -> Bool)?

    /// A borderless window is not key-eligible by default, and without key status there is
    /// no Esc or ⌫.
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:      onExit?();  return   // Esc — leave draw mode
        case 51, 117: onClear?(); return   // ⌫ / ⌦ — clear everything
        default: break
        }
        // Tool letters (C is the circle tool, so it no longer clears — ⌫ does).
        if let key = event.charactersIgnoringModifiers?.uppercased(),
           key.count == 1, onToolKey?(key) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Canvas

private final class DrawOverlayView: NSView {
    /// Called once the last stroke has finished fading, so an overlay whose draw mode is
    /// already off can be hidden.
    var onStrokesEmpty: (() -> Void)?

    var isActive = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var hasStrokes: Bool { !strokes.isEmpty }

    /// The tool the next mark will be drawn with. Set from Settings on activate and by the
    /// tool letters while drawing.
    var tool: DrawTool = .pencil {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// One drawn mark. Freehand keeps its sampled `points`; the shapes are defined by the
    /// drag's `origin` and `end`, so they can be rubber-banded live and rebuilt on each move.
    private final class Mark {
        let layer = CAShapeLayer()
        let tool: DrawTool
        var points: [CGPoint] = []
        var origin: CGPoint = .zero
        var end: CGPoint = .zero
        var fade: DispatchWorkItem?
        init(tool: DrawTool) { self.tool = tool }
    }

    private var strokes: [Mark] = []
    private var current: Mark?

    private static let fadeDuration: TimeInterval = 0.8
    private static let clearFadeDuration: TimeInterval = 0.15

    private static var cursorCache: [DrawTool: NSCursor] = [:]

    /// The armed tool's cursor, following the editor's convention (`CanvasView`): the
    /// pencil carries its own glyph with the hotspot at its tip, while every
    /// drag-to-define tool takes the precise plus — a miniature rectangle or arrow reads
    /// as an indistinguishable purple blob at cursor size *and* sits on top of the exact
    /// point being aimed at. Cached: building one composites a tinted symbol and a halo.
    private static func cursor(for tool: DrawTool) -> NSCursor {
        if let cached = cursorCache[tool] { return cached }
        let made: NSCursor
        switch tool {
        case .pencil:
            made = BrandCursor.make(symbol: "pencil.tip", tipHotspot: true) ?? .crosshair
        case .rectangle, .circle, .line, .arrow:
            made = BrandCursor.make(symbol: "plus") ?? .crosshair
        }
        cursorCache[tool] = made
        return made
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    /// A non-opaque `NSWindow` passes clicks straight *through* fully transparent (alpha 0)
    /// pixels while still tracking hover — so an interactive overlay that is 99 % clear
    /// looks live but silently leaks every click to the app underneath. Painting the region
    /// with a hair of opacity while drawing is what makes the window hit-test at all; it is
    /// imperceptible on screen and in the video. Exactly the hazard (and fix)
    /// `SelectionOverlay.punchHole` documents — don't restore a fully clear fill.
    /// Nothing is painted while draw mode is off, so the rest of the recording is untinted.
    override func draw(_ dirtyRect: NSRect) {
        guard isActive, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.02).cgColor)
        ctx.fill(bounds)
    }

    override func resetCursorRects() {
        guard isActive else { return }
        addCursorRect(bounds, cursor: Self.cursor(for: tool))
    }

    /// Assert the tool cursor while the pointer is already inside the overlay — a tool
    /// letter pressed mid-hover changes the rect but nothing re-enters it to apply it.
    override func cursorUpdate(with event: NSEvent) {
        guard isActive else { return super.cursorUpdate(with: event) }
        Self.cursor(for: tool).set()
    }

    /// Drawable from the first click even if the app was inactive a moment ago (see
    /// `VideoRecordBar.RecordBarButton`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Stroke capture

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        // Colour, thickness and fade are read per mark, not cached, so a change in
        // Settings → Drawing takes effect on the very next stroke of a live recording.
        let m = Mark(tool: tool)
        m.layer.fillColor = nil
        m.layer.strokeColor = Settings.shared.drawColor.cgColor
        m.layer.lineWidth = Settings.shared.drawStroke.width
        m.layer.lineCap = .round
        m.layer.lineJoin = .round
        let p = convert(event.locationInWindow, from: nil)
        m.origin = p; m.end = p
        m.points = [p]
        m.layer.path = Self.path(for: m)
        layer?.addSublayer(m.layer)
        strokes.append(m)
        current = m
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive, let m = current else { return }
        let raw = convert(event.locationInWindow, from: nil)
        if m.tool == .pencil {
            // Drop sub-pixel jitter: fewer, better-spaced points make the quadratic
            // smoothing below read as a clean curve instead of a wobble.
            if let last = m.points.last, hypot(raw.x - last.x, raw.y - last.y) < 1.5 { return }
            m.points.append(raw)
        } else {
            // ⇧ constrains, the way the annotation editor does: a true square/circle for
            // the boxed shapes, and 45° increments for line and arrow.
            m.end = event.modifierFlags.contains(.shift)
                ? Self.constrained(from: m.origin, to: raw, tool: m.tool) : raw
        }
        m.layer.path = Self.path(for: m)
    }

    /// Deliberately not guarded on `isActive`: a stroke whose drag was interrupted by
    /// leaving draw mode still needs its fade scheduled.
    override func mouseUp(with event: NSEvent) {
        finishCurrentStroke()
    }

    /// Close off the stroke being drawn, if any, and start its fade timer.
    func finishCurrentStroke() {
        guard let s = current else { return }
        current = nil
        scheduleFade(s)
    }

    // MARK: Fading

    /// Each mark fades on its own timer, started when *that* mark was finished — so marks
    /// drawn in quick succession disappear oldest-first rather than all at once. A fade
    /// setting of "never" schedules nothing; those marks live until Clear or teardown.
    private func scheduleFade(_ s: Mark) {
        guard let delay = Settings.shared.drawFade.delay else { return }
        let work = DispatchWorkItem { [weak self, weak s] in
            guard let self, let s else { return }
            self.fadeOut(s, duration: Self.fadeDuration)
        }
        s.fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut(_ s: Mark, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = s.layer.opacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        s.layer.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self, weak s] in
            guard let self, let s else { return }
            s.layer.removeFromSuperlayer()
            self.strokes.removeAll { $0 === s }
            if self.strokes.isEmpty { self.onStrokesEmpty?() }
        }
    }

    /// Clear everything at once, on a quick fade rather than a pop — a hard cut from a
    /// screen full of marks to none reads as a glitch in the video.
    func clearAll() {
        current = nil
        for s in strokes {
            s.fade?.cancel()
            s.fade = nil
            fadeOut(s, duration: Self.clearFadeDuration)
        }
    }

    /// Remove every stroke immediately, cancelling pending fades — recording teardown.
    func dropAllStrokes() {
        for s in strokes {
            s.fade?.cancel()
            s.fade = nil
            s.layer.removeFromSuperlayer()
        }
        strokes.removeAll()
        current = nil
    }

    // MARK: Geometry

    /// Build the path for a mark from its current geometry. Rebuilt on every drag event so
    /// the shapes rubber-band live under the cursor.
    private static func path(for m: Mark) -> CGPath {
        switch m.tool {
        case .pencil:
            return smoothed(m.points)
        case .rectangle:
            return CGPath(rect: rect(m.origin, m.end), transform: nil)
        case .circle:
            return CGPath(ellipseIn: rect(m.origin, m.end), transform: nil)
        case .line:
            let path = CGMutablePath()
            path.move(to: m.origin)
            path.addLine(to: m.end)
            return path
        case .arrow:
            return arrow(from: m.origin, to: m.end, lineWidth: m.layer.lineWidth)
        }
    }

    /// The drag's bounding box, normalised so dragging up/left works like down/right.
    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// A shaft plus two head barbs. The head scales with the stroke so a heavy arrow does
    /// not end in a tiny tip, and is capped at a third of the shaft so a very short drag
    /// stays an arrow rather than becoming a blob.
    private static func arrow(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1 else { return path }
        let angle = atan2(dy, dx)
        let head = min(max(12, lineWidth * 3.5), length / 3)
        let spread = CGFloat.pi / 7
        for side in [angle - spread, angle + spread] {
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - head * cos(side), y: b.y - head * sin(side)))
        }
        return path
    }

    /// ⇧ behaviour: boxed shapes become square (the larger drag axis wins, sign preserved),
    /// and line/arrow snap to the nearest 45°.
    private static func constrained(from origin: CGPoint, to p: CGPoint, tool: DrawTool) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        switch tool {
        case .rectangle, .circle:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: origin.x + (dx < 0 ? -side : side),
                           y: origin.y + (dy < 0 ? -side : side))
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let snapped = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: origin.x + length * cos(snapped), y: origin.y + length * sin(snapped))
        case .pencil:
            return p
        }
    }

    /// Midpoint-quadratic smoothing: every sampled point becomes the control point between
    /// the midpoints of its neighbours, which turns a jagged mouse trail into one
    /// continuous curve — without the overshoot a Catmull-Rom spline produces on a fast
    /// flick, which on screen looks like the line lashing past the cursor.
    private static func smoothed(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        // A tap with no drag: a hair of length so the round cap renders it as a dot.
        if pts.count == 1 {
            path.move(to: first)
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        if pts.count == 2 {
            path.move(to: first)
            path.addLine(to: pts[1])
            return path
        }
        path.move(to: mid(pts[0], pts[1]))
        for i in 1..<(pts.count - 1) {
            path.addQuadCurve(to: mid(pts[i], pts[i + 1]), control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
