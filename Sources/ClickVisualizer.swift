// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Shows an expanding, fading ring at every mouse click while a recording runs, so
/// clicks are visible in the captured video (Settings → Video → "Show mouse clicks").
///
/// The ripple windows are deliberately NOT excluded from the recording stream —
/// being captured is their entire purpose. Global `NSEvent` mouse monitors don't
/// need the Accessibility permission (only keyboard monitors do), so this works
/// with the Screen Recording grant the app already has. The local monitor covers
/// clicks on our own windows (the record bar), which the global one doesn't see.
final class ClickVisualizer {
    private var monitors: [Any] = []

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { _ in Self.ripple(at: NSEvent.mouseLocation) }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: handler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in
            handler(e); return e
        } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    deinit { stop() }

    /// One self-contained ripple: a small click-through window that animates a ring
    /// from the click point and closes itself when the animation ends.
    private static func ripple(at point: CGPoint) {
        let size: CGFloat = 64
        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        view.wantsLayer = true
        let ring = CAShapeLayer()
        let startR: CGFloat = 8, endR: CGFloat = 26
        ring.path = CGPath(ellipseIn: CGRect(x: size / 2 - startR, y: size / 2 - startR,
                                             width: startR * 2, height: startR * 2), transform: nil)
        ring.fillColor = Theme.lavender.withAlphaComponent(0.25).cgColor
        ring.strokeColor = Theme.lavender.cgColor
        ring.lineWidth = 2
        view.layer?.addSublayer(ring)
        win.contentView = view
        win.orderFrontRegardless()

        let duration = 0.35
        let grow = CABasicAnimation(keyPath: "path")
        grow.toValue = CGPath(ellipseIn: CGRect(x: size / 2 - endR, y: size / 2 - endR,
                                                width: endR * 2, height: endR * 2), transform: nil)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        for a in [grow, fade] {
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.isRemovedOnCompletion = false
            a.fillMode = .forwards
            ring.add(a, forKey: a.keyPath)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            win.orderOut(nil)
        }
    }
}
