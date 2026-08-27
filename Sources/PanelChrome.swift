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

extension NSWindow {
    /// Centre on the display the user is actually looking at.
    ///
    /// `NSWindow.center()` always centres on `NSScreen.main` — the display carrying the menu
    /// bar — regardless of where the window is or what raised it. So every panel and alert
    /// opened on the built-in screen no matter which display the work was on: finish a
    /// recording on a second monitor and History appeared on the laptop, behind whatever was
    /// there.
    ///
    /// **Call this before `makeKeyAndOrderFront`**, while the window that raised this one is
    /// still key — that window is the right anchor, because this one is about it. The
    /// pointer's screen covers the case where nothing is key (a background save failure, an
    /// update offer, a panel opened from the status menu), and `main` is the last resort.
    ///
    /// The default placement arithmetic is `center()`'s own, measured rather than guessed:
    /// centred horizontally in the visible frame, with a *quarter* of the vertical slack above
    /// so the window sits a little high, where the eye already is. Reproducing it means only
    /// the screen changes and a panel doesn't move on a single-display Mac. (Moving the window
    /// onto the target display and then calling `center()` does not work — `center()` resolves
    /// to `NSScreen.main`, not to the window's own screen.)
    ///
    /// - Parameter verticallyCentred: Put the window in the true middle instead. Alerts take
    ///   this: they arrive over a full-screen capture the user is looking *at*, not over a
    ///   desktop they are looking near the top of, so AppKit's bias toward the upper third
    ///   just parks the question off to one side of the thing it is asking about.
    func centerOnActiveScreen(verticallyCentred: Bool = false) {
        // A window can be its own key window on a re-show; it can't anchor itself.
        let key = NSApp.keyWindow
        let anchor = (key === self ? nil : key?.screen)
            ?? (NSApp.mainWindow === self ? nil : NSApp.mainWindow?.screen)
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let f = anchor?.visibleFrame else { center(); return }
        let size = frame.size
        let slack = f.height - size.height
        setFrameOrigin(NSPoint(x: f.minX + ((f.width - size.width) / 2).rounded(.down),
                               y: f.minY + (verticallyCentred ? slack / 2 : slack * 3 / 4).rounded(.down)))
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

