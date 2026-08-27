// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

private enum CaptureMode { case region, window, screen }

/// Shared capture-mode state across the per-screen overlays. Without this, only the
/// overlay under the initial cursor holds keyboard focus, so **Space** (mode cycle) and
/// capture worked on just one display. All overlays created for one capture share a
/// single coordinator, so cycling the mode on any screen updates every screen and the
/// multi-monitor overlay behaves as one surface.
final class OverlayCoordinator {
    fileprivate var mode: CaptureMode = .region
    private let views = NSHashTable<SelectionView>.weakObjects()

    /// Safety net for multi-monitor setups: `mouseEntered` is normally what hands key
    /// status to the overlay under the pointer, but that only fires on a boundary
    /// crossing. If key status is ever lost some other way (observed with two screens
    /// connected — window server quirks around `.screenSaver`-level windows spanning
    /// displays) with the pointer never leaving its current overlay, no crossing event
    /// ever comes to re-key it, and the whole overlay silently stops accepting input —
    /// indefinitely, since even Esc no longer reaches it. A local monitor sees every
    /// mouseDown/keyDown *before* AppKit dispatches it, regardless of key status, so it
    /// can promote the event's own window to key right then — self-healing on the very
    /// interaction the user is already making, no crossing required.
    private var eventMonitor: Any?

    /// **`[weak self]` is load-bearing, and so is `stopMonitoring()`.** AppKit retains a
    /// monitor's handler until `removeMonitor`, so capturing `self` strongly here made the
    /// coordinator and its monitor retain each other: `deinit` never ran, the monitor was
    /// never removed, and every capture left one more behind — permanently intercepting
    /// each `keyDown`/`leftMouseDown` for the rest of the launch. The weak table of views
    /// kept the strays harmless (a dead coordinator finds no visible view and passes the
    /// event on), but they accumulated, and two live coordinators would cycle the mode
    /// twice on one Space press. `deinit` alone can't be trusted to clean this up — the
    /// dismissal paths call `stopMonitoring()` explicitly.
    init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let window = event.window as? OverlayWindow, !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            // Space cycles the mode even when the keystroke never reaches the selection
            // view's `keyDown` — an overlay that failed to take key status, or a window
            // whose first responder drifted, would otherwise swallow it silently.
            if event.type == .keyDown, event.keyCode == 49,
               let view = self.views.allObjects.first(where: { $0.window?.isVisible == true }) {
                view.cycleMode()
                return nil
            }
            return event
        }
    }

    /// Drop the monitor the moment this capture's overlays go away, rather than waiting on
    /// the last reference to the coordinator. Idempotent.
    func stopMonitoring() {
        guard let m = eventMonitor else { return }
        NSEvent.removeMonitor(m)
        eventMonitor = nil
    }

    deinit { stopMonitoring() }

    fileprivate func register(_ view: SelectionView) { views.add(view) }

    /// Advance to the next available mode and notify every registered overlay.
    fileprivate func cycle(using modes: [CaptureMode]) {
        guard modes.count > 1 else { return }
        let idx = modes.firstIndex(of: mode) ?? 0
        mode = modes[(idx + 1) % modes.count]
        for view in views.allObjects { view.modeDidChange() }
    }
}

final class OverlayWindow: NSWindow {
    var onComplete: ((CGRect) -> Void)?
    /// Called when the user picks whole-screen mode.
    var onCompleteScreen: (() -> Void)?
    /// Called when the user clicks a window in window-pick mode, with its `CGWindowID`.
    var onCompleteWindow: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    let captureScreen: NSScreen
    /// The mode state shared with every other overlay of this capture. Exposed so the
    /// controllers can `stopMonitoring()` it when they tear the overlays down — see
    /// `OverlayCoordinator.init`.
    let coordinator: OverlayCoordinator
    private let selectionView: SelectionView

    /// - Parameters:
    ///   - allowsWindowMode: When `true`, Space can cycle into window-pick mode
    ///     (hover to highlight a window, click to capture just that window).
    ///   - allowsFullScreenMode: When `false`, Space cannot cycle into whole-screen mode.
    ///   - recording: When `true`, window/screen modes show a video cursor instead of
    ///     the camera, distinguishing the record flow from screenshots.
    ///   - frozen: This display's still, grabbed before the overlay appeared, drawn as
    ///     the backdrop instead of dimming the live desktop (see `ScreenshotController.begin`).
    init(screen: NSScreen, coordinator: OverlayCoordinator,
         allowsWindowMode: Bool = true, allowsFullScreenMode: Bool = true, recording: Bool = false,
         previousRect: CGRect? = nil, frozen: NSImage? = nil) {
        captureScreen = screen
        self.coordinator = coordinator
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     coordinator: coordinator,
                                     allowsWindowMode: allowsWindowMode,
                                     allowsFullScreenMode: allowsFullScreenMode,
                                     recording: recording,
                                     frozen: frozen)
        selectionView.previousRect = previousRect
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // The controllers `close()` overlays they still hold references to (the hard
        // teardown that fixes the stranded-window bug); the AppKit default of `true`
        // would over-release and crash on the next autorelease-pool pop.
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        selectionView.autoresizingMask = [.width, .height]
        selectionView.onComplete = { [weak self] r in self?.onComplete?(r) }
        selectionView.onCompleteScreen = { [weak self] in self?.onCompleteScreen?() }
        selectionView.onCompleteWindow = { [weak self] id in self?.onCompleteWindow?(id) }
        selectionView.onCancel = { [weak self] in self?.onCancel?() }
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Take key status and point the first responder at the selection view — the only
    /// responder that handles Space / Esc / Return.
    ///
    /// `NSApp.activate` resolves asynchronously, so the synchronous
    /// `makeKeyAndOrderFront` right after it can land while the app is still inactive:
    /// the overlay ends up ordered front and drag-able (mouse events don't need key
    /// status) with the keyboard going to whatever app was frontmost — Space silently
    /// does nothing. Re-asserting on the next few run-loop turns catches activation
    /// whenever it actually lands.
    func claimKeyboard() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(selectionView)
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isVisible else { return }
                if !self.isKeyWindow {
                    self.makeKeyAndOrderFront(nil)
                    self.makeFirstResponder(self.selectionView)
                }
                // Re-assert the cursor on every retry, not just when key status is still
                // missing: cursor rects are honoured only while the app is *active*, and
                // `NSApp.activate` is asynchronous, so the overlay can already be key with
                // its rects not yet evaluated. That gap is why the plain arrow sometimes
                // survived until the pointer first moved.
                self.selectionView.applyModeCursor()
            }
        }
    }

    /// Show the capture cursor from the first frame: the view's initial cursor set (in
    /// `viewDidMoveToWindow`) runs before the window is key and can be overridden,
    /// leaving the default arrow until the pointer first moves.
    override func becomeKey() {
        super.becomeKey()
        selectionView.applyModeCursor()
    }

    /// Give up the cursor claim on the way out. `SelectionView.resetCursorRects` is what
    /// makes the capture cursor *stick* — and that cuts both ways: a rect the window server
    /// still remembers keeps re-asserting the camera after the overlay is gone, so the
    /// pointer stayed a camera until it next moved. A rect has to be released, not merely
    /// out-`set()`. Hooked on `orderOut` because that is the moment every teardown path
    /// shares (`close()` follows a tick later, too late to matter visually).
    override func orderOut(_ sender: Any?) {
        selectionView.relinquishCursor()
        super.orderOut(sender)
    }
}

/// Dims the screen with a transparent "hole" for the current selection, plus a
/// window-capture mode (Space to toggle).
final class SelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    /// Called when the user picks whole-screen mode (click). Distinct from `onComplete`
    /// so the controller can suppress the cursor for a full-screen grab.
    var onCompleteScreen: (() -> Void)?
    var onCompleteWindow: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    private let coordinator: OverlayCoordinator
    private var captureMode: CaptureMode { coordinator.mode }
    private let allowsWindowMode: Bool
    private let allowsFullScreenMode: Bool
    private let recording: Bool

    /// The previous capture's region on this display (view-local), re-offered as a
    /// dashed outline in region mode — Return re-captures it without re-dragging.
    var previousRect: CGRect?

    /// The window currently under the pointer in window-pick mode, or `nil` when the
    /// pointer is over empty desktop. Drives the highlight; the capture commits when
    /// the mouse is released over it (see `mouseUp`).
    private var hoveredWindow: PickableWindow?

    /// Where the guidance card was last drawn, padded for its drop shadow. `mouseDown`
    /// hides the card, but `invalidateSelection` only dirties the selection rect — without
    /// this the card would be left behind as a ghost until a drag happened to sweep over it.
    private var bannerFrame: CGRect = .null

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var trackingAreaRef: NSTrackingArea?

    /// This display's still (pixel-sized, scale 1), when the capture froze the screen
    /// before opening the overlay. `nil` falls back to dimming the live desktop.
    private let frozen: NSImage?

    init(frame: NSRect, coordinator: OverlayCoordinator,
         allowsWindowMode: Bool = true, allowsFullScreenMode: Bool = true, recording: Bool = false,
         frozen: NSImage? = nil) {
        self.coordinator = coordinator
        self.allowsWindowMode = allowsWindowMode
        self.allowsFullScreenMode = allowsFullScreenMode
        self.recording = recording
        self.frozen = frozen
        super.init(frame: frame)
        coordinator.register(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self); modeCursor.set() }

    /// Focus follows the pointer across displays: the overlay under the cursor becomes
    /// key so keyboard events (Esc) target the right screen and its cursor updates.
    override func mouseEntered(with event: NSEvent) {
        // Never re-key mid-drag: a region drag that crosses displays fires this on the
        // overlay it enters (button still held), and `makeKeyAndOrderFront` there would
        // hijack the in-progress event tracking — dropping the `mouseUp` and leaving the
        // overlay stuck with a half-drawn selection that Esc can no longer discard.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard window?.isKeyWindow == false else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    /// The shared coordinator cycled the mode: reset transient state, refresh the
    /// window highlight, re-assert the cursor (on the key screen), and redraw.
    func modeDidChange() {
        startPoint = nil; currentPoint = nil
        if captureMode == .window { refreshHoveredWindow() } else { hoveredWindow = nil }
        if window?.isKeyWindow == true { modeCursor.set() }
        window?.invalidateCursorRects(for: self)   // the rect names a mode-specific cursor
        needsDisplay = true
    }

    /// Advance the shared capture mode, from `keyDown` or the coordinator's monitor.
    fileprivate func cycleMode() {
        guard availableModes.count > 1 else { return }
        coordinator.cycle(using: availableModes)
    }

    /// The ordered set of modes Space cycles through, honouring the two capability
    /// flags. Region is always available; window and screen are opt-in.
    private var availableModes: [CaptureMode] {
        var modes: [CaptureMode] = [.region]
        if allowsWindowMode { modes.append(.window) }
        if allowsFullScreenMode { modes.append(.screen) }
        return modes
    }

    /// All three modes share one style — white body, brand-purple keyline, matched weight — so
    /// the pointer reads as this app's in every mode. Region gets a crosshair rather than a
    /// glyph: it is the shape that means "drag a region", and its arms leave a gap at the
    /// centre so the exact point being aimed at stays visible. Window and Screen get the camera — or the video
    /// glyph while recording, which is what tells the two flows apart. With no action line in
    /// the card any more, the cursor is what says what to do, so the record flow can't sit on
    /// a borrowed `.pointingHand` (it did, despite the docs on `recording:` promising a video
    /// cursor).
    private var modeCursor: NSCursor {
        if captureMode == .region { return Self.crosshairCursor }
        return recording ? Self.videoCursor : Self.cameraCursor
    }
    override func cursorUpdate(with event: NSEvent) {
        guard !cursorReleased else { return }
        modeCursor.set()
    }

    /// The overlay *owns* the pointer while it is up, so it declares a cursor rect over its
    /// whole bounds instead of only pushing `.set()` at a few moments. A one-shot `.set()`
    /// races window activation: the window server re-evaluates cursor state as the overlay
    /// becomes key, and with nothing *claiming* the region it falls back to the arrow — which
    /// is why the capture cursor intermittently never appeared until the pointer moved. The
    /// `.cursorUpdate` tracking area doesn't cover that either: it fires on enter/exit, and a
    /// pointer already inside the overlay when it appears never enters. A rect is declarative
    /// and gets re-applied on every activation, so it can't be raced.
    override func resetCursorRects() {
        guard !cursorReleased else { return }
        addCursorRect(bounds, cursor: modeCursor)
    }

    /// Set once the overlay is on its way out, so a late cursor-rect pass — AppKit re-runs
    /// them on activation changes, which the teardown itself triggers — can't re-claim the
    /// pointer after we handed it back.
    private var cursorReleased = false

    /// Drop the cursor claim and hand the pointer back to the plain arrow.
    func relinquishCursor() {
        guard !cursorReleased else { return }
        cursorReleased = true
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
    }

    /// Camera for the screenshot window/screen pick, video for the record flow — both as
    /// white glyphs with a brand keyline (`makeOutlined`), not the editor's halo style: this cursor is
    /// the only thing distinguishing the two flows at the pointer, so it has to be legible
    /// over a dimmed screenshot of anything.
    /// A crosshair, at the weight of the filled glyphs beside it. It has to be a crosshair:
    /// that is the one shape that says *drag out a region*. A `viewfinder` glyph matched the
    /// others' style but said "aim", losing the only instruction Region mode gives — and with
    /// no action line in the guidance card, this cursor is that instruction.
    private static let crosshairCursor = BrandCursor.makeOutlined(symbol: "plus") ?? .crosshair
    private static let cameraCursor = BrandCursor.makeOutlined(symbol: "camera.fill") ?? .pointingHand
    private static let videoCursor = BrandCursor.makeOutlined(symbol: "video.fill") ?? .pointingHand

    /// Re-assert the mode cursor. The `viewDidMoveToWindow` set can be discarded by the
    /// system before the window is key/active, so the owning window calls this on `becomeKey`
    /// to show the capture cursor from the first frame. Belt and braces alongside
    /// `resetCursorRects`: the rect is what makes it stick, this is what makes it immediate.
    func applyModeCursor() {
        guard !cursorReleased else { return }
        modeCursor.set()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingAreaRef = t
    }

    /// Snapped to `.integral`: raw mouse coordinates are sub-pixel, and a fractional
    /// rect forces both ScreenCaptureKit's crop and the editor canvas's on-screen
    /// position to sample/composite across a pixel boundary — softening the entire
    /// capture, not just its edges (see `ScreenshotController.finish`).
    private var selectionRect: CGRect? {
        guard let a = startPoint, let b = currentPoint else { return nil }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                       width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
        // Clamp to this display: a drag that crosses onto another screen can't produce a
        // valid single-display capture, so keep only the portion on the origin screen.
        let clipped = r.intersection(bounds)
        return clipped.isNull ? nil : clipped
    }

    /// Deliver clicks even when the overlay isn't the frontmost app's key window
    /// (the app is promoted from a background agent, so it can briefly be inactive).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        switch captureMode {
        case .screen:
            onCompleteScreen?()
        case .window:
            // Capture commits on release; a press just refreshes the highlight so the
            // target stays accurate if the pointer moved without a tracked `mouseMoved`.
            refreshHoveredWindow()
        case .region:
            let p = convert(event.locationInWindow, from: nil)
            let old = selectionRect
            startPoint = p; currentPoint = p
            invalidateSelection(old, selectionRect)
            clearPreDragChrome()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        switch captureMode {
        case .region:
            let old = selectionRect
            currentPoint = convert(event.locationInWindow, from: nil)
            invalidateSelection(old, selectionRect)
        case .window:
            refreshHoveredWindow()   // keep the highlight following the pointer while held
        case .screen:
            break
        }
    }
    override func mouseUp(with event: NSEvent) {
        switch captureMode {
        case .region:
            currentPoint = convert(event.locationInWindow, from: nil)
            if let r = selectionRect, r.width >= 3, r.height >= 3 { onComplete?(r) } else { onCancel?() }
        case .window:
            refreshHoveredWindow()
            if let win = hoveredWindow { onCompleteWindow?(win.id) } else { onCompleteScreen?() }
        case .screen:
            break
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard captureMode == .window else { return }
        refreshHoveredWindow()
    }

    /// Recompute the window under the pointer (window-pick mode) and redraw if it
    /// changed. Hit-tests in CG global space against `WindowList`, excluding our own
    /// process so the dim overlay is never a target.
    private func refreshHoveredWindow() {
        let cgPoint = WindowList.cgPoint(fromAppKitMouse: NSEvent.mouseLocation)
        let pid = ProcessInfo.processInfo.processIdentifier
        let found = WindowList.topmost(atCGPoint: cgPoint, excludingPID: pid)
        if found?.id != hoveredWindow?.id {
            let old = hoveredWindowViewRect
            hoveredWindow = found
            let new = hoveredWindowViewRect
            // A nil rect means the whole-screen fallback outline is (or was) showing,
            // so the change touches the entire view — otherwise repaint just the two
            // highlight areas.
            if old == nil || new == nil { needsDisplay = true }
            else { invalidateSelection(old, new) }
        }
    }

    /// Repaint only what a selection/highlight change touches. Marking the whole view
    /// dirty per mouse event software-redraws the entire (non-layer-backed) screen —
    /// on a large external display that alone can blow the frame budget, queue up
    /// pointer events, and read as a freeze while selecting. The outset covers the
    /// selection outline plus the size label drawn beside the region.
    /// Erase everything that only belongs *before* a drag: the guidance card and the dashed
    /// last-region ghost. Both stop drawing the moment `startPoint` is set, but
    /// `invalidateSelection` dirties only the selection rect, so neither area would be
    /// repainted — each would sit there as a stale image until a drag happened to sweep
    /// across it. Their own frames have to be invalidated explicitly.
    private func clearPreDragChrome() {
        if !bannerFrame.isNull { setNeedsDisplay(bannerFrame) }
        if let prev = previousRect { setNeedsDisplay(prev.insetBy(dx: -2, dy: -2)) }
    }

    private func invalidateSelection(_ old: CGRect?, _ new: CGRect?) {
        var dirty = CGRect.null
        if let o = old { dirty = dirty.union(o) }
        if let n = new { dirty = dirty.union(n) }
        guard !dirty.isNull else { return }
        setNeedsDisplay(dirty.insetBy(dx: -160, dy: -40))
    }

    /// The `hoveredWindow` frame in this view's local (bottom-left) coordinates,
    /// clipped to the overlay bounds so a window spanning displays draws only its
    /// on-screen portion.
    private var hoveredWindowViewRect: CGRect? {
        guard let win = hoveredWindow else { return nil }
        let appKit = WindowList.appKitRect(fromCG: win.frame)
        guard let originGlobal = window?.frame.origin else { return nil }
        let local = CGRect(x: appKit.minX - originGlobal.x,
                           y: appKit.minY - originGlobal.y,
                           width: appKit.width, height: appKit.height)
        let clipped = local.intersection(bounds)
        return clipped.isNull ? nil : clipped
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        // Return / keypad-Enter re-captures the previous region (region mode, no
        // drag in progress).
        if event.keyCode == 36 || event.keyCode == 76,
           captureMode == .region, startPoint == nil, let prev = previousRect {
            onComplete?(prev.integral)
            return
        }
        if event.keyCode == 49 {
            // Cycle the shared mode — the coordinator notifies every overlay (this one
            // included) via `modeDidChange`, so all displays switch together.
            cycleMode()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if frozen != nil {
            drawFrozen(dirtyRect)
            ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.55).cgColor)
            ctx.fill(dirtyRect)
        } else {
            ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.55).cgColor)
            ctx.fill(bounds)
        }

        switch captureMode {
        case .region: drawRegionMode(ctx)
        case .window: drawWindowMode(ctx)
        case .screen: drawScreenMode(ctx)
        }

        // Guidance is for *before* the gesture: once a drag is under way the size readout
        // has taken over and the card only covers what is being selected.
        if startPoint == nil { drawModeBanner() }
    }

    /// Show `r` bright against the dim. Over a frozen backdrop that's just the still
    /// redrawn at full opacity — the window stays opaque throughout, so none of the
    /// click-through care below applies.
    ///
    /// On the live-desktop fallback the region is cleared instead, but with a hair of
    /// opacity (0.02) left behind so the non-opaque overlay window still hit-tests
    /// clicks there. A fully transparent (alpha 0) region of a non-opaque window passes
    /// mouse clicks straight through to the app underneath — which would make
    /// window/screen picking uncapturable.
    private func punchHole(_ ctx: CGContext, _ r: CGRect) {
        if frozen != nil {
            drawFrozen(r)
            return
        }
        ctx.setBlendMode(.clear); ctx.fill(r); ctx.setBlendMode(.normal)
        ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.02).cgColor)
        ctx.fill(r)
    }

    /// Draw the frozen still behind `rect` only. `draw(_:)` runs on every mouse move
    /// during a drag, and recompositing the whole display each time — a 5K still is ~35
    /// MPx — would blow the frame budget on exactly the interaction that must stay
    /// smooth. The still is pixel-sized at scale 1 in the same bottom-left space as the
    /// view, so the source rect is just `rect` scaled by its pixels-per-point.
    private func drawFrozen(_ rect: CGRect) {
        guard let frozen else { return }
        let scale = frozen.size.width / max(bounds.width, 1)
        let from = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                          width: rect.width * scale, height: rect.height * scale)
        frozen.draw(in: rect, from: from, operation: .copy, fraction: 1)
    }

    /// A lavender wash over the hovered target, on top of the bright hole — so the
    /// exact capture area reads at a glance instead of only being implied by the
    /// outline. Drawn after `punchHole`.
    private func drawHoverTint(_ ctx: CGContext, _ r: CGRect) {
        ctx.setFillColor(Theme.lavender.withAlphaComponent(0.16).cgColor)
        ctx.fill(r)
    }

    /// One consistent chip background: raised surface, hairline border, radius 5.
    private func fillChip(_ box: CGRect) {
        let path = NSBezierPath(roundedRect: box, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall)
        Theme.surfaceRaised.withAlphaComponent(0.95).setFill(); path.fill()
        Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
    }

    private func drawRegionMode(_ ctx: CGContext) {
        // Offer the previous region as a dashed ghost until a fresh drag starts.
        if selectionRect == nil, startPoint == nil, let prev = previousRect {
            ctx.saveGState()
            ctx.setStrokeColor(Theme.lavender.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(prev.insetBy(dx: 0.75, dy: 0.75))
            ctx.restoreGState()
        }
        guard let r = selectionRect else { return }
        punchHole(ctx, r)
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor)
        ctx.setLineWidth(lw)
        ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))
        drawSizeLabel(for: r)
    }

    private func drawSizeLabel(for r: CGRect) {
        let text = "\(Int(r.width)) × \(Int(r.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11, .semibold), .foregroundColor: Theme.textPrimary,
        ]
        let ts = text.size(withAttributes: attrs)
        let pad: CGFloat = 6
        var boxY = r.maxY + 6
        if boxY + ts.height + pad > bounds.maxY { boxY = r.minY - ts.height - pad - 6 }
        let box = CGRect(x: r.minX, y: boxY, width: ts.width + pad * 2, height: ts.height + pad)
        fillChip(box)
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

    private func drawScreenMode(_ ctx: CGContext) {
        let r = bounds
        punchHole(ctx, r)
        drawHoverTint(ctx, r)
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(lw)
        ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))
    }

    /// Window-pick mode: highlight the window under the pointer with a bright cutout
    /// and outline — no label, so releasing anywhere over the highlighted window
    /// captures it (macOS-style). Falls back to the whole-screen outline when the
    /// pointer is over empty desktop, since a release there captures the screen.
    private func drawWindowMode(_ ctx: CGContext) {
        guard let r = hoveredWindowViewRect else {
            drawScreenMode(ctx)
            return
        }
        punchHole(ctx, r)
        drawHoverTint(ctx, r)
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(lw)
        ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))
    }


    /// The SF Symbol that best represents each capture mode, shown at the mode
    /// banner's leading edge.
    private func symbolName(for mode: CaptureMode) -> String {
        switch mode {
        case .region: return "viewfinder"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }

    /// One shortcut hint, split around its key name so the key can be drawn as a keycap
    /// wherever the localization puts it. Splitting the rendered sentence on whitespace
    /// would not survive translation — English wraps the key ("Press %@ to switch") while
    /// German leads with it ("%@ wechselt") — so the `%@` in the template is the seam.
    private struct KeyHint {
        let before: String
        let key: String
        let after: String
    }

    private func keyHint(_ template: String, key: String) -> KeyHint {
        let parts = L(template).components(separatedBy: "%@")
        return KeyHint(before: parts.first ?? "", key: L(key),
                       after: parts.count > 1 ? parts[1] : "")
    }

    private func name(for mode: CaptureMode) -> String {
        switch mode {
        case .region: return L("Region")
        case .window: return L("Window")
        case .screen: return L("Screen")
        }
    }

    /// The centred guidance card, stacked in three rows: the mode picker as a **segmented
    /// control**, the action beneath it in bright ink, the shortcuts muted below that. The
    /// one piece of chrome that's always on screen, so it gets the most polish of any overlay
    /// chip, and the only place that can answer "what do I do now?".
    ///
    /// Stacked, not a single line: as one horizontal strip it ran ~828 pt — over half a
    /// 1440 pt screen — and put the picker, the action and the hints at the same weight, so
    /// nothing led. A row each gives them an order to be read in and quarters the width.
    ///
    /// The modes are bordered segments carrying their own glyphs, rather than a run of words
    /// with one highlighted: as plain text they read like a caption *about* the card, not a
    /// control you operate. They come off `availableModes`, not a fixed three, so a flow that
    /// forbids window or screen picking shows one segment and drops the Space hint instead of
    /// advertising a mode that Space cannot reach.
    private func drawModeBanner() {
        var shortcuts: [KeyHint] = []
        if availableModes.count > 1 {
            shortcuts.append(keyHint("Press %@ to switch mode", key: "Space"))
        }
        if captureMode == .region, previousRect != nil {
            shortcuts.append(keyHint("Press %@ for last region", key: "Return"))
        }

        let modes = availableModes
        let modeFont = Theme.font(14, .semibold)
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: modeFont, .foregroundColor: Theme.textPrimary,
        ]
        let idleAttrs: [NSAttributedString.Key: Any] = [
            .font: modeFont, .foregroundColor: Theme.textSecondary.withAlphaComponent(0.6),
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(12, .medium), .foregroundColor: Theme.textSecondary,
        ]

        let segH: CGFloat = 26, segPadH: CGFloat = 10, segIcon: CGFloat = 13, segIconGap: CGFloat = 6
        func segWidth(_ mode: CaptureMode) -> CGFloat {
            let attrs = mode == captureMode ? activeAttrs : idleAttrs
            return segPadH * 2 + segIcon + segIconGap + name(for: mode).size(withAttributes: attrs).width
        }
        // +1 pt per seam for the hairline between segments.
        let modesW = modes.reduce(0) { $0 + segWidth($1) } + CGFloat(max(0, modes.count - 1))

        // The key names are drawn as keycaps — a faint fill inside a hairline border — so
        // they read as keys to press rather than as more of the sentence around them.
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(12, .semibold), .foregroundColor: Theme.ink,
        ]
        let capPadH: CGFloat = 5, capH: CGFloat = 17
        let separator = "  ·  "
        func capWidth(_ key: String) -> CGFloat {
            ceil(key.size(withAttributes: keyAttrs).width) + capPadH * 2
        }
        func hintWidth(_ h: KeyHint) -> CGFloat {
            h.before.size(withAttributes: hintAttrs).width + capWidth(h.key)
                + h.after.size(withAttributes: hintAttrs).width
        }
        let sepW = separator.size(withAttributes: hintAttrs).width
        let hintsW = shortcuts.reduce(0) { $0 + hintWidth($1) }
            + sepW * CGFloat(max(0, shortcuts.count - 1))

        let hintRowH = shortcuts.isEmpty ? 0 : capH

        let padH: CGFloat = 20, padV: CGFloat = 16
        let pickerGap: CGFloat = 14

        let bw = max(modesW, hintsW) + padH * 2
        var bh = padV * 2 + segH
        if !shortcuts.isEmpty { bh += pickerGap + hintRowH }
        // Stacked, the widest run — German, Region mode — is the picker itself at ~330 pt, so
        // the card fits any Mac display un-clamped; `max` only guards the left edge. Clamping
        // the *width* would crop the card while the text kept drawing past it.
        let box = CGRect(x: max(8, bounds.midX - bw / 2), y: bounds.midY - bh / 2,
                         width: bw, height: bh)

        drawBannerBackground(box)
        bannerFrame = box.insetBy(dx: -30, dy: -30)   // covers the shadow blur too

        // Row 1 — the mode picker, centred in the card.
        let track = NSRect(x: box.midX - modesW / 2, y: box.maxY - padV - segH,
                           width: modesW, height: segH)
        Theme.hoverFill.setFill()
        NSBezierPath(rect: track).fill()
        var sx = track.minX
        for (i, mode) in modes.enumerated() {
            let active = mode == captureMode
            let seg = NSRect(x: sx, y: track.minY, width: segWidth(mode), height: segH)
            if active {
                Theme.accentPurple.setFill()
                NSBezierPath(rect: seg).fill()
            }
            let tint = active ? Theme.textPrimary : Theme.textSecondary.withAlphaComponent(0.6)
            if let icon = tintedSymbol(symbolName(for: mode), pointSize: segIcon * 0.85, color: tint) {
                icon.draw(in: CGRect(x: seg.minX + segPadH, y: seg.midY - segIcon / 2,
                                     width: segIcon, height: segIcon))
            }
            let attrs = active ? activeAttrs : idleAttrs
            let label = name(for: mode)
            let ts = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: seg.minX + segPadH + segIcon + segIconGap,
                                   y: seg.midY - ts.height / 2), withAttributes: attrs)
            sx = seg.maxX
            if i < modes.count - 1 {
                Theme.divider.setFill()
                NSRect(x: sx, y: track.minY, width: 1, height: segH).fill()
                sx += 1
            }
        }
        Theme.cardStroke.setStroke()
        let outline = NSBezierPath(rect: track.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()

        // Row 2 — the keys that apply right now, each key in its own cap. There is no
        // action line: the cursor carries the gesture (crosshair = drag, camera/video over a
        // highlighted target = click), so spelling it out was a third way of saying it.
        guard !shortcuts.isEmpty else { return }
        let rowMidY = track.minY - pickerGap - hintRowH / 2
        func drawRun(_ text: String, _ x: inout CGFloat) {
            guard !text.isEmpty else { return }
            let size = text.size(withAttributes: hintAttrs)
            text.draw(at: NSPoint(x: x.rounded(), y: (rowMidY - size.height / 2).rounded()),
                      withAttributes: hintAttrs)
            x += size.width
        }
        var x = (box.midX - hintsW / 2).rounded()
        for (i, hint) in shortcuts.enumerated() {
            if i > 0 { drawRun(separator, &x) }
            drawRun(hint.before, &x)
            let cap = NSRect(x: x.rounded(), y: (rowMidY - capH / 2).rounded(),
                             width: capWidth(hint.key), height: capH)
            Theme.hoverFill.setFill()
            NSBezierPath(rect: cap).fill()
            Theme.cardStroke.setStroke()
            let edge = NSBezierPath(rect: cap.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
            let ks = hint.key.size(withAttributes: keyAttrs)
            hint.key.draw(at: NSPoint(x: (cap.midX - ks.width / 2).rounded(),
                                      y: (rowMidY - ks.height / 2).rounded()),
                          withAttributes: keyAttrs)
            x = cap.maxX
            drawRun(hint.after, &x)
        }
    }

    /// A solid-color copy of an SF Symbol, for drawing brand-tinted glyphs directly
    /// via CGContext (matches the tinting technique `BrandCursor` uses).
    private func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return nil }
        let glyph = symbol.size
        let tinted = NSImage(size: glyph)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: glyph))
        color.set()
        NSRect(origin: .zero, size: glyph).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    /// A larger-radius, more elevated version of `fillChip` reserved for the mode
    /// banner: brand gradient fill, soft drop shadow, and a lavender hairline glow.
    private func drawBannerBackground(_ box: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: box, xRadius: Theme.radiusMedium, yRadius: Theme.radiusMedium)

        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()
        Theme.surfaceBase.setFill(); path.fill()
        ctx.restoreGState()

        if let gradient = NSGradient(colors: [Theme.gradientTop, Theme.surfaceRaised]) {
            gradient.draw(in: path, angle: 90)
        }
        Theme.lavender.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

}
