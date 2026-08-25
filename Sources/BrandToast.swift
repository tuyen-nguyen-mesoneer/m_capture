// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A brief brand-styled toast pill centered near the top of the screen that
/// auto-fades — feedback for fire-and-forget actions (copied, trashed) that
/// don't warrant a dialog. Mirrors the Settings prefix-saved toast.
enum BrandToast {
    private static var current: NSWindow?

    static func show(_ message: String, on screen: NSScreen? = nil) {
        guard let screen = screen ?? NSScreen.main else { return }
        current?.orderOut(nil); current = nil

        let label = NSTextField(labelWithString: message)
        label.font = Theme.font(13, .semibold); label.textColor = .white
        // `intrinsicContentSize` comes back 3-4 pt narrower than the field needs to draw
        // its own text, so a frame cut to it clips the last glyph — which is how the
        // draw-mode tool toasts came out as "Rectangl" and "Arro". `sizeThatFits` is the
        // honest width.
        let ts = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                           height: CGFloat.greatestFiniteMagnitude))
        let pad: CGFloat = 12
        let size = NSSize(width: ceil(ts.width) + pad * 2, height: ceil(ts.height) + pad)

        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Theme.accentPurple.withAlphaComponent(0.95).cgColor
        pill.layer?.cornerRadius = Theme.radiusSmall
        label.frame = NSRect(x: pad, y: pad / 2, width: ceil(ts.width), height: ceil(ts.height))
        pill.addSubview(label)

        let vf = screen.visibleFrame
        let win = NSWindow(contentRect: NSRect(x: vf.midX - size.width / 2,
                                               y: vf.maxY - 30 - size.height,
                                               width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.contentView = pill
        win.orderFront(nil)

        current = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard current === win else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.orderOut(nil)
                if current === win { current = nil }
            })
        }
    }
}
