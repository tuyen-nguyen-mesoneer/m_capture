// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// A floating, always-on-top window that "pins" a captured image to the screen
/// so it stays visible while you work. Drag anywhere to move, drag the
/// bottom-right corner to scale (aspect preserved), and right-click for a
/// brand-styled menu (Copy / Save / Reset size / Close; Esc or ⌘W also close it).
final class PinnedWindowController: NSObject, NSWindowDelegate {
    // Retain live pins so several can coexist; each drops itself on close.
    private static var pinned: [PinnedWindowController] = []

    private let window: PinWindow
    private let rep: NSBitmapImageRep   // full-resolution pixels for copy/save

    /// - Parameters:
    ///   - rep: the flattened, full-resolution capture.
    ///   - screenRect: where to place it, in global screen coordinates.
    init(rep: NSBitmapImageRep, screenRect: CGRect) {
        self.rep = rep
        window = PinWindow(contentRect: screenRect, styleMask: .borderless,
                           backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 60, height: 60)

        let view = PinView(rep: rep)
        view.initialSize = screenRect.size
        view.onCopy = { [weak self] in self?.copyToClipboard() }
        view.onSave = { [weak self] in self?.saveToDisk() }
        view.onClose = { [weak self] in self?.close() }
        window.contentView = view

        PinnedWindowController.pinned.append(self)
        window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func image() -> NSImage {
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        return img
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image()])
    }

    private func saveToDisk() {
        let url = Settings.shared.fileURL()
        let rep = self.rep
        // Encode + write off the main thread (matches the editor's Save).
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Settings.shared.encode(rep) else { return }
            try? data.write(to: url)
        }
    }

    private func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        PinnedWindowController.pinned.removeAll { $0 === self }
    }
}

/// Key-able borderless window so the pin can receive Esc / ⌘W.
private final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the pinned image (rounded corners + brand edge) and handles dragging,
/// corner-resize, the brand-styled context menu, and keyboard dismissal.
private final class PinView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private let image: NSImage
    private let aspect: CGFloat              // width / height, preserved on resize
    var initialSize: NSSize = .zero          // pin size at creation (for "Reset size")
    private var contextMenu: BrandMenu?      // retained while shown
    private let cornerRadius = Theme.radiusMedium   // matches the app's 12pt panels
    private let grab: CGFloat = 22           // bottom-right resize hot-zone

    private enum Mode { case move, resize }
    private var mode: Mode = .move
    private var startMouse: NSPoint = .zero  // global, at mouseDown
    private var startFrame: NSRect = .zero   // window frame, at mouseDown

    init(rep: NSBitmapImageRep) {
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        image = img
        aspect = rep.pixelsHigh > 0 ? CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh) : 1
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        Theme.lavender.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Resize grip: a double-chevron in the bottom-right, inset to clear the
        // rounded corner, with a dark underlay so it stays visible over light captures.
        func gripPath() -> NSBezierPath {
            let p = NSBezierPath()
            let x0 = bounds.maxX - cornerRadius - 14, y0 = cornerRadius + 2
            p.move(to: NSPoint(x: x0, y: y0));     p.line(to: NSPoint(x: x0 + 11, y: y0 + 11))
            p.move(to: NSPoint(x: x0 + 6, y: y0)); p.line(to: NSPoint(x: x0 + 11, y: y0 + 6))
            return p
        }
        let under = gripPath(); under.lineWidth = 3
        NSColor(white: 0, alpha: 0.45).setStroke(); under.stroke()
        let grip = gripPath(); grip.lineWidth = 1.5
        Theme.lavender.setStroke(); grip.stroke()
    }

    // MARK: Move & resize

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        let p = convert(event.locationInWindow, from: nil)
        mode = (p.x > bounds.width - grab && p.y < grab) ? .resize : .move
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        switch mode {
        case .move:
            win.setFrameOrigin(NSPoint(x: startFrame.origin.x + dx, y: startFrame.origin.y + dy))
        case .resize:
            let newW = max(win.minSize.width, startFrame.width + dx)
            let newH = max(win.minSize.height, newW / aspect)
            // Anchor the top-left corner so it grows toward the cursor.
            win.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - newH,
                                width: newW, height: newH), display: true)
            win.invalidateShadow()
        }
    }

    // MARK: Context menu (brand-styled)

    override func rightMouseDown(with event: NSEvent) {
        let menu = BrandMenu(entries: [
            .item(title: "Copy", symbol: "doc.on.doc", shortcut: nil) { [weak self] in self?.onCopy?() },
            .item(title: "Save", symbol: "square.and.arrow.down", shortcut: nil) { [weak self] in self?.onSave?() },
            .item(title: "Reset size", symbol: "arrow.up.left.and.arrow.down.right", shortcut: nil) { [weak self] in self?.resetSize() },
            .separator,
            .item(title: "Close", symbol: "xmark", shortcut: "⌘W") { [weak self] in self?.onClose?() },
        ])
        contextMenu = menu
        menu.show(at: NSEvent.mouseLocation)
    }

    private func resetSize() {
        guard let win = window, initialSize.width > 0 else { return }
        let f = win.frame
        // Keep the top-left corner fixed, like the corner-resize.
        win.setFrame(NSRect(x: f.minX, y: f.maxY - initialSize.height,
                            width: initialSize.width, height: initialSize.height), display: true)
        win.invalidateShadow()
    }

    // MARK: Keyboard dismissal

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }   // Esc
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onClose?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
