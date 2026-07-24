// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// One app panel at a time: opening any panel (Settings, History, Trim) closes the
/// others, and starting a capture or recording closes them all — the app's panels
/// never stack up over each other or linger under a capture overlay. Each panel's
/// own close path (`onClose`) runs so per-panel teardown (e.g. Trim's playback)
/// happens properly.
enum AppPanels {
    static func closeAll(except keep: NSWindow? = nil) {
        for w in NSApp.windows where w is PanelWindow && w !== keep && w.isVisible {
            if let panel = w as? PanelWindow, let close = panel.onClose {
                close()
            } else {
                w.orderOut(nil)
            }
        }
    }
}

/// A borderless, square-cornered panel window for Settings / Trim. macOS rounds the
/// corners of `.titled` windows and offers no API to square them, so these panels are
/// borderless and supply their own chrome: a `PanelCloseButton`, Esc / ⌘W to close, and
/// drag-anywhere-to-move (`isMovableByWindowBackground`). A soft drop shadow defines the
/// square edge (no border), matching the other panels and the brand menu.
final class PanelWindow: NSWindow {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc → close (AppKit routes the Escape key here when nothing else consumes it).
    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            onClose?(); return
        }
        super.keyDown(with: event)
    }

    /// Give `content` square corners + a top-right close button, and a drop shadow on the
    /// window to define the (borderless) edge; call once the window's size is final.
    func installChrome(on content: NSView, closeInset: CGFloat = 14) {
        content.wantsLayer = true
        content.layer?.cornerRadius = 0
        hasShadow = true

        let size = PanelCloseButton.size
        let close = PanelCloseButton()
        close.frame = NSRect(x: content.bounds.maxX - closeInset - size,
                             y: content.bounds.maxY - closeInset - size, width: size, height: size)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.onClick = { [weak self] in self?.onClose?() }
        content.addSubview(close)
    }
}

/// A small custom-drawn close button (an "×"), since a borderless window has no native
/// traffic lights. Quiet by default, brightening with a subtle disc on hover.
final class PanelCloseButton: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { L("Close") }

    static let size: CGFloat = 22
    var onClick: (() -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Consume the press so the window's drag-to-move background doesn't swallow the click.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accentPurple.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let inset: CGFloat = 7
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset, y: inset))
        path.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: NSPoint(x: bounds.width - inset, y: inset))
        path.line(to: NSPoint(x: inset, y: bounds.height - inset))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        (hovering ? Theme.textPrimary : Theme.textSecondary).setStroke()
        path.stroke()
    }
}

