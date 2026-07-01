// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import ScreenCaptureKit

/// Drives a *scrolling screenshot*: reuse the region overlay to pick an area, then
/// — while the user scrolls the real app underneath — repeatedly capture that
/// fixed rect with ScreenCaptureKit and feed the frames to a `ScrollStitcher`,
/// showing a live growing preview. On Done, the tall result opens in the editor.
///
/// Requires macOS 14 (`SCScreenshotManager`); the menu item/hotkey are absent on 13.
@available(macOS 14.0, *)
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()
    private var overlays: [OverlayWindow] = []
    private var session: ScrollSession?

    func begin() {
        if !overlays.isEmpty || session != nil { return }
        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen, allowsWindowMode: false)
            win.onComplete = { [weak self] r in self?.startSession(viewRect: r, screen: screen) }
            win.onCancel = { [weak self] in self?.dismissOverlays() }
            overlays.append(win)
            if screen == keyScreen { win.makeKeyAndOrderFront(nil) } else { win.orderFront(nil) }
        }
    }

    private func dismissOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    private func startSession(viewRect: CGRect, screen: NSScreen) {
        let global = CGRect(x: screen.frame.minX + viewRect.minX,
                            y: screen.frame.minY + viewRect.minY,
                            width: viewRect.width, height: viewRect.height)
        dismissOverlays()
        guard global.width >= 20, global.height >= 20 else { return }
        let s = ScrollSession(region: global, screen: screen)
        s.onFinish = { [weak self] image in self?.finish(image: image, screen: screen) }
        s.onCancel = { [weak self] in self?.session = nil }
        session = s
        s.start()
    }

    private func finish(image: NSImage?, screen: NSScreen) {
        session = nil
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return }
        // The stitch is usually far taller than the screen — fit it within the
        // visible frame so the editor can show the whole thing (it scales display
        // by selectionRect.width / image.size.width, exactly like other captures).
        let vis = screen.visibleFrame
        let fit = min(vis.width * 0.9 / image.size.width, vis.height * 0.9 / image.size.height, 1)
        let dw = image.size.width * fit, dh = image.size.height * fit
        let sel = CGRect(x: screen.frame.midX - dw / 2, y: screen.frame.midY - dh / 2, width: dw, height: dh)
        _ = EditorWindowController(image: image, selectionRect: sel, screen: screen)
    }
}

// MARK: - Session

/// One scroll-capture run: owns the frame-outline window, the controller bar, the
/// stitcher, and the capture loop. Its mutable state is touched only on the main
/// actor; the stitch-queue hops marshal the (serial-confined) stitcher and bounce
/// back to main — hence `@unchecked Sendable`.
@available(macOS 14.0, *)
private final class ScrollSession: @unchecked Sendable {
    var onFinish: ((NSImage?) -> Void)?
    var onCancel: (() -> Void)?

    private let region: CGRect
    private let screen: NSScreen
    private let stitcher = ScrollStitcher()
    private let stitchQueue = DispatchQueue(label: "io.mesoneer.mcapture.stitch")

    private let frameWindow: NSWindow
    private let bar: ScrollCaptureBar

    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var running = false
    private var ended = false
    private var totalRows = 0
    private var noOverlapStreak = 0
    private var lastPreview = Date.distantPast
    private var lastAppend = Date.distantPast
    private var hinted = false
    private var captureHeightPx = 0

    /// Idle (no new content) before we hint that the capture can be finished…
    private static let idleHintAfter: TimeInterval = 1.2
    /// …and before we finish it automatically (only once something was captured).
    private static let autoFinishAfter: TimeInterval = 4.0
    /// Capture cadence. Faster than the eye needs, but a higher rate means smaller
    /// per-frame jumps, so a quick scroll keeps enough overlap for the stitcher.
    private static let frameIntervalNs: UInt64 = 24_000_000   // ~42 Hz

    init(region: CGRect, screen: NSScreen) {
        self.region = region
        self.screen = screen

        frameWindow = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.hasShadow = false
        frameWindow.level = .floating
        frameWindow.ignoresMouseEvents = true   // scrolling/clicking passes to the app
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        frameWindow.contentView = FrameOutlineView(frame: NSRect(origin: .zero, size: region.size))

        bar = ScrollCaptureBar(origin: ScrollSession.barOrigin(for: region, on: screen))
        bar.onDone = { [weak self] in self?.finish() }
        bar.onCancel = { [weak self] in self?.cancel() }
    }

    private var displayID: CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func barOrigin(for region: CGRect, on screen: NSScreen) -> NSPoint {
        let size = ScrollCaptureBar.size
        var x = region.midX - size.width / 2
        var y = region.minY - size.height - 16            // prefer below the region
        if y < screen.frame.minY + 8 { y = region.maxY + 16 }                 // else above
        if y + size.height > screen.frame.maxY - 8 { y = screen.frame.midY - size.height / 2 }
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        return NSPoint(x: x, y: y)
    }

    func start() {
        frameWindow.orderFront(nil)
        bar.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            guard let content = try? await SCShareableContent.current,
                  let display = content.displays.first(where: { $0.displayID == self.displayID }) else {
                self.cancel(); return
            }
            // Exclude our own frame + bar so they're not baked into the capture.
            let ids: Set<CGWindowID> = [CGWindowID(self.frameWindow.windowNumber),
                                        CGWindowID(self.bar.windowNumber)]
            let excluded = content.windows.filter { ids.contains($0.windowID) }
            guard !self.ended else { return }   // Done/Cancel raced ahead of content load
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let cfg = SCStreamConfiguration()
            let scale = self.screen.backingScaleFactor
            // sourceRect is in points, display-local, top-left origin.
            cfg.sourceRect = CGRect(x: self.region.minX - self.screen.frame.minX,
                                    y: self.screen.frame.maxY - self.region.maxY,
                                    width: self.region.width, height: self.region.height)
            cfg.width = Int(self.region.width * scale)
            cfg.height = Int(self.region.height * scale)
            cfg.showsCursor = false
            self.captureHeightPx = Int(self.region.height * scale)

            self.filter = filter
            self.config = cfg
            self.running = true
            await self.loop()
        }
    }

    @MainActor
    private func loop() async {
        guard let filter = filter, let config = config else { return }
        let stitcher = self.stitcher          // serial-queue-confined; avoids capturing self
        let queue = self.stitchQueue
        while running {
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                let result: ScrollStitcher.Result = await withCheckedContinuation { cont in
                    queue.async { cont.resume(returning: stitcher.add(cg)) }
                }
                handle(result)
            }
            try? await Task.sleep(nanoseconds: ScrollSession.frameIntervalNs)
        }
    }

    @MainActor
    private func handle(_ r: ScrollStitcher.Result) {
        switch r {
        case .appended(let n):
            totalRows += n
            noOverlapStreak = 0
            lastAppend = Date()
            if hinted { hinted = false; bar.emphasizeDone(false) }
            // A single frame revealing a big slice means the scroll is near the
            // overlap limit — nudge before it actually drops a band.
            if captureHeightPx > 0, n > captureHeightPx * 55 / 100 {
                bar.setStatus("Scroll a little slower", warn: true)
            } else {
                bar.setStatus("Captured \(totalRows) px", warn: false)
            }
            refreshPreview()
        case .noMovement:
            checkIdle()
        case .noOverlap:
            noOverlapStreak += 1
            if noOverlapStreak >= 2 { bar.setStatus("Scrolled too fast — scroll back up a bit", warn: true) }
        case .capReached:
            running = false
            bar.setStatus("Maximum length reached", warn: true)
            refreshPreview(force: true)
        }
    }

    /// Once the view sits still after capturing something, first hint that the
    /// capture can be finished, then finish it automatically — so a completed scroll
    /// doesn't wait on a click. Never fires before anything was captured (a region
    /// the user picked but didn't scroll stays open until Done/Cancel).
    @MainActor
    private func checkIdle() {
        guard totalRows > 0, !ended else { return }
        let idle = Date().timeIntervalSince(lastAppend)
        if idle >= ScrollSession.autoFinishAfter {
            finish()
        } else if idle >= ScrollSession.idleHintAfter, !hinted {
            hinted = true
            bar.setStatus("Done capturing? Press ⏎", warn: false)
            bar.emphasizeDone(true)
        }
    }

    private func refreshPreview(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastPreview) < 0.12 { return }
        lastPreview = Date()
        let stitcher = self.stitcher
        stitchQueue.async {
            let img = stitcher.previewImage()
            DispatchQueue.main.async { self.bar.setPreview(img) }
        }
    }

    private func finish() {
        if ended { return }
        ended = true
        running = false
        teardown()
        let stitcher = self.stitcher
        stitchQueue.async {
            let img = stitcher.finalImage()
            DispatchQueue.main.async { self.onFinish?(img) }
        }
    }

    private func cancel() {
        if ended { return }
        ended = true
        running = false
        teardown()
        onCancel?()
    }

    private func teardown() {
        frameWindow.orderOut(nil)
        bar.orderOut(nil)
    }
}

// MARK: - Frame outline

/// A thin accent border drawn around the capture region; its window ignores mouse
/// events so the user can scroll the app underneath.
private final class FrameOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor)
        ctx.setLineWidth(lw)
        ctx.stroke(bounds.insetBy(dx: lw / 2, dy: lw / 2))
    }
}

// MARK: - Controller bar

/// The floating brand-styled controller: a live growing preview, a status line,
/// and Done / Cancel. Esc cancels.
private final class ScrollCaptureBar: NSWindow {
    static let size = NSSize(width: 200, height: 320)

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let preview = ScrollPreviewView()
    private let status = NSTextField(labelWithString: "Scroll to capture…")
    private let done = BarButton(title: "Done", primary: true)

    init(origin: NSPoint) {
        super.init(contentRect: NSRect(origin: origin, size: ScrollCaptureBar.size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let card = CardView(frame: NSRect(origin: .zero, size: ScrollCaptureBar.size))

        let title = NSTextField(labelWithString: "Scrolling capture")
        title.font = Theme.font(13, .semibold)
        title.textColor = Theme.textPrimary
        title.alignment = .center
        title.frame = NSRect(x: 12, y: 290, width: 176, height: 18)
        card.addSubview(title)

        preview.frame = NSRect(x: 12, y: 86, width: 176, height: 196)
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.masksToBounds = true
        card.addSubview(preview)

        status.font = Theme.font(11, .medium)
        status.textColor = Theme.textSecondary
        status.alignment = .center
        status.frame = NSRect(x: 8, y: 58, width: 184, height: 18)
        card.addSubview(status)

        let cancel = BarButton(title: "Cancel", primary: false)
        cancel.frame = NSRect(x: 16, y: 14, width: 78, height: 32)
        cancel.onClick = { [weak self] in self?.onCancel?() }
        card.addSubview(cancel)

        done.frame = NSRect(x: 106, y: 14, width: 78, height: 32)
        done.onClick = { [weak self] in self?.onDone?() }
        card.addSubview(done)

        contentView = card
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()         // Esc
        case 36, 76: onDone?()       // Return / keypad Enter
        default: super.keyDown(with: event)
        }
    }

    func setPreview(_ image: NSImage?) { preview.image = image }

    /// Highlight Done while we're hinting the user can finish the capture.
    func emphasizeDone(_ on: Bool) { done.emphasized = on }

    func setStatus(_ text: String, warn: Bool) {
        status.stringValue = text
        status.textColor = warn ? Theme.accent : Theme.textSecondary
    }
}

/// Live preview for the scrolling-capture bar. Draws the growing stitch scaled to
/// the panel **width**, with the newest content anchored to the bottom (older rows
/// scroll up out of view) — the way dedicated scroll-capture tools show progress.
/// Fitting to width keeps content at a readable scale and sharp; the previous
/// fit-the-whole-strip-in-the-box behaviour crushed a tall capture into an
/// illegible sliver.
private final class ScrollPreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surfaceBase.setFill()
        bounds.fill()
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return }
        let iw = image.size.width, ih = image.size.height
        let scale = bounds.width / iw                    // fit to width
        let visRows = min(ih, bounds.height / scale)     // image rows that fit the panel height
        let destH = visRows * scale
        // The stitched image is upright, so its coordinate y = 0 is the bottom =
        // the most-recently-captured rows. Show that slice; anchor it to the panel
        // bottom once the strip is taller than the panel, else sit it at the top.
        let srcRect = NSRect(x: 0, y: 0, width: iw, height: visRows)
        let destY = ih * scale <= bounds.height ? bounds.height - destH : 0
        let destRect = NSRect(x: 0, y: destY, width: bounds.width, height: destH)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: destRect, from: srcRect, operation: .sourceOver, fraction: 1)
    }
}

/// Rounded dark card background for the controller bar.
private final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Theme.surfaceRaised.setFill(); path.fill()
        Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// A small rounded text button styled with the brand palette.
private final class BarButton: NSView {
    var onClick: (() -> Void)?
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }
    private let title: String
    private let primary: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, primary: Bool) {
        self.title = title
        self.primary = primary
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        let fill: NSColor = primary
            ? (hovering ? (Theme.lavender.blended(withFraction: 0.16, of: .black) ?? Theme.lavender) : Theme.lavender)
            : (hovering ? Theme.accentPurple : Theme.surfaceBase)
        fill.setFill(); path.fill()
        if !primary { Theme.border.setStroke(); path.lineWidth = 1; path.stroke() }
        if emphasized {   // bright inset ring marking the suggested action (no motion)
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            (primary ? NSColor.white : Theme.lavender).withAlphaComponent(0.9).setStroke()
            ring.lineWidth = 1.5; ring.stroke()
        }
        let color: NSColor = primary ? Theme.surfaceBase : Theme.textPrimary
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(12, .semibold), .foregroundColor: color,
        ]
        let ts = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2), withAttributes: attrs)
    }
}
