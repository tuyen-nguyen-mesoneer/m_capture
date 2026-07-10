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
    private let selectionView: SelectionView

    /// - Parameters:
    ///   - allowsWindowMode: When `true`, Space can cycle into window-pick mode
    ///     (hover to highlight a window, click to capture just that window).
    ///   - allowsFullScreenMode: When `false`, Space cannot cycle into whole-screen mode.
    ///   - recording: When `true`, window/screen modes show a video cursor instead of
    ///     the camera, distinguishing the record flow from screenshots.
    init(screen: NSScreen, coordinator: OverlayCoordinator,
         allowsWindowMode: Bool = true, allowsFullScreenMode: Bool = true, recording: Bool = false) {
        captureScreen = screen
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     coordinator: coordinator,
                                     allowsWindowMode: allowsWindowMode,
                                     allowsFullScreenMode: allowsFullScreenMode,
                                     recording: recording)
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
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

    /// Show the capture cursor from the first frame: the view's initial cursor set (in
    /// `viewDidMoveToWindow`) runs before the window is key and can be overridden,
    /// leaving the default arrow until the pointer first moves.
    override func becomeKey() {
        super.becomeKey()
        selectionView.applyModeCursor()
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

    /// The window currently under the pointer in window-pick mode, or `nil` when the
    /// pointer is over empty desktop. Drives the highlight; the capture commits when
    /// the mouse is released over it (see `mouseUp`).
    private var hoveredWindow: PickableWindow?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var trackingAreaRef: NSTrackingArea?

    init(frame: NSRect, coordinator: OverlayCoordinator,
         allowsWindowMode: Bool = true, allowsFullScreenMode: Bool = true, recording: Bool = false) {
        self.coordinator = coordinator
        self.allowsWindowMode = allowsWindowMode
        self.allowsFullScreenMode = allowsFullScreenMode
        self.recording = recording
        super.init(frame: frame)
        coordinator.register(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self); modeCursor.set() }

    /// Focus follows the pointer across displays: the overlay under the cursor becomes
    /// key so keyboard events (Esc) target the right screen and its cursor updates.
    override func mouseEntered(with event: NSEvent) {
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
        needsDisplay = true
    }

    /// The ordered set of modes Space cycles through, honouring the two capability
    /// flags. Region is always available; window and screen are opt-in.
    private var availableModes: [CaptureMode] {
        var modes: [CaptureMode] = [.region]
        if allowsWindowMode { modes.append(.window) }
        if allowsFullScreenMode { modes.append(.screen) }
        return modes
    }

    /// Region drag uses the crosshair; window/screen picking uses a capture cursor —
    /// a video glyph for the record flow, a camera for screenshots.
    private var modeCursor: NSCursor {
        if captureMode == .region { return .crosshair }
        return recording ? Self.videoCursor : Self.cameraCursor
    }
    override func cursorUpdate(with event: NSEvent) { modeCursor.set() }

    /// Capture cursors for window/screen modes, mesoneer-styled (shared `BrandCursor`):
    /// a camera glyph for screenshots and a video glyph for recording.
    private static let cameraCursor = BrandCursor.make(symbol: "camera.fill") ?? .pointingHand
    private static let videoCursor  = BrandCursor.make(symbol: "video.fill") ?? .pointingHand

    /// Re-assert the mode cursor. The `viewDidMoveToWindow` set can be discarded
    /// by the system before the window is key/active, so the owning window calls
    /// this on `becomeKey` to guarantee the camera cursor from the first frame.
    func applyModeCursor() { modeCursor.set() }

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
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
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
            startPoint = p; currentPoint = p; needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) {
        switch captureMode {
        case .region:
            currentPoint = convert(event.locationInWindow, from: nil); needsDisplay = true
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
            if let win = hoveredWindow { onCompleteWindow?(win.id) }
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
            hoveredWindow = found
            needsDisplay = true
        }
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
        if event.keyCode == 49, availableModes.count > 1 {
            // Cycle the shared mode — the coordinator notifies every overlay (this one
            // included) via `modeDidChange`, so all displays switch together.
            coordinator.cycle(using: availableModes)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)

        switch captureMode {
        case .region: drawRegionMode(ctx)
        case .window: drawWindowMode(ctx)
        case .screen: drawScreenMode(ctx)
        }

        drawModePill()
    }

    /// Clear `r` to a bright "hole" in the dim, but leave a hair of opacity (0.02) so
    /// the non-opaque overlay window still hit-tests clicks there. A fully transparent
    /// (alpha 0) region of a non-opaque window passes mouse clicks straight through to
    /// the app underneath — which would make window/screen picking uncapturable.
    private func punchHole(_ ctx: CGContext, _ r: CGRect) {
        ctx.setBlendMode(.clear); ctx.fill(r); ctx.setBlendMode(.normal)
        ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.02).cgColor)
        ctx.fill(r)
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
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        Theme.surfaceRaised.withAlphaComponent(0.95).setFill(); path.fill()
        Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
    }

    private func drawRegionMode(_ ctx: CGContext) {
        guard let r = selectionRect else { return }
        ctx.setBlendMode(.clear)
        ctx.fill(r)
        ctx.setBlendMode(.normal)
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
    /// captures it (macOS-style). Falls back to a centred hint when the pointer is over
    /// empty desktop so the mode never looks inert.
    private func drawWindowMode(_ ctx: CGContext) {
        guard let r = hoveredWindowViewRect else {
            drawCenteredChip("Move over a window to capture it")
            return
        }
        punchHole(ctx, r)
        drawHoverTint(ctx, r)
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(lw)
        ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))
    }

    /// A single chip centred in the overlay — used for the "move over a window" hint.
    private func drawCenteredChip(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(13, .semibold), .foregroundColor: Theme.textPrimary,
        ]
        let ts = text.size(withAttributes: attrs)
        let pad: CGFloat = 8
        let box = CGRect(x: bounds.midX - (ts.width + pad * 2) / 2, y: bounds.midY - (ts.height + pad) / 2,
                         width: ts.width + pad * 2, height: ts.height + pad)
        fillChip(box)
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

    private func drawModePill() {
        let modeName: String
        switch captureMode {
        case .region: modeName = "Region"
        case .window: modeName = "Window"
        case .screen: modeName = "Screen"
        }
        // Only advertise the Space shortcut when there's more than one mode to cycle.
        let label = availableModes.count > 1 ? "\(modeName)  (Space to cycle)" : modeName
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11, .regular), .foregroundColor: Theme.textPrimary,
        ]
        let ts = label.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let bw = ts.width + pad * 2, bh = ts.height + pad
        let box = CGRect(x: (bounds.width - bw) / 2, y: bounds.height - bh - 12, width: bw, height: bh)
        fillChip(box)
        label.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

}
