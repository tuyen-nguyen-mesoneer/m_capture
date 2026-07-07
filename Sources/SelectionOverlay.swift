// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

private enum CaptureMode { case region, screen }

final class OverlayWindow: NSWindow {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    let captureScreen: NSScreen
    private let selectionView: SelectionView

    /// - Parameters:
    ///   - allowsWindowMode: Unused in the current implementation (no window-pick mode).
    ///   - allowsFullScreenMode: When `false`, Space cannot toggle into whole-screen mode.
    init(screen: NSScreen, allowsWindowMode: Bool = true, allowsFullScreenMode: Bool = true) {
        captureScreen = screen
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     allowsFullScreenMode: allowsFullScreenMode)
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
        selectionView.onCancel = { [weak self] in self?.onCancel?() }
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Show the crosshair from the first frame: the view's initial cursor set (in
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
    var onCancel: (() -> Void)?

    private var captureMode: CaptureMode = .region
    private let allowsFullScreenMode: Bool

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var trackingAreaRef: NSTrackingArea?

    init(frame: NSRect, allowsFullScreenMode: Bool = true) {
        self.allowsFullScreenMode = allowsFullScreenMode
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self); modeCursor.set() }

    private var modeCursor: NSCursor { captureMode == .region ? .crosshair : .pointingHand }
    override func cursorUpdate(with event: NSEvent) { modeCursor.set() }

    /// Re-assert the mode cursor. The `viewDidMoveToWindow` set can be discarded
    /// by the system before the window is key/active, so the owning window calls
    /// this on `becomeKey` to guarantee the crosshair from the first frame.
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

    override func mouseDown(with event: NSEvent) {
        if captureMode == .screen {
            onComplete?(CGRect(origin: .zero, size: bounds.size))
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p; currentPoint = p; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard captureMode == .region else { return }
        currentPoint = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard captureMode == .region else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        if let r = selectionRect, r.width >= 3, r.height >= 3 { onComplete?(r) } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 49, allowsFullScreenMode {
            captureMode = (captureMode == .region) ? .screen : .region
            startPoint = nil; currentPoint = nil
            modeCursor.set(); needsDisplay = true; return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)

        if captureMode == .region { drawRegionMode(ctx) }
        else                      { drawScreenMode(ctx) }

        drawModePill()
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
        ctx.setBlendMode(.clear); ctx.fill(r); ctx.setBlendMode(.normal)
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor); ctx.setLineWidth(lw)
        ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))

        let text = "Click here to capture this screen"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(13, .semibold), .foregroundColor: Theme.textPrimary,
        ]
        let ts = text.size(withAttributes: attrs)
        let pad: CGFloat = 8
        let box = CGRect(x: r.midX - (ts.width + pad * 2) / 2, y: r.midY - (ts.height + pad) / 2,
                         width: ts.width + pad * 2, height: ts.height + pad)
        fillChip(box)
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

    private func drawModePill() {
        let label = captureMode == .region ? "Region  (Space for Screen)" : "Screen  (Space for Region)"
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
