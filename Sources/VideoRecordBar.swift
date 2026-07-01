// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Floating recording HUD shown while a video recording is in progress.
/// Displays a live timer, file-size estimate, quality badge, and Pause/Stop controls.
/// The bar's `windowNumber` must be passed to `SCContentFilter` so it is excluded
/// from the SCStream capture — call `show(near:)` before starting the recording session.
///
/// Updating the display is the caller's responsibility; call `update(elapsed:fileSize:isPaused:)`
/// on each tick (typically 1 Hz) from `VideoRecordController`.
final class VideoRecordBar: NSObject {
    var onStop: (() -> Void)?
    var onPauseResume: (() -> Void)?

    var windowNumber: Int { window.windowNumber }

    private var window: RecordBarWindow!

    // Subviews mutated by update()
    private let dotView = NSView()
    private let timerLabel = NSTextField(labelWithString: "00:00:00")
    private let sizeLabel = NSTextField(labelWithString: "~0 KB")
    private let pauseBtn: RecordBarButton
    private let stopBtn: RecordBarButton

    // Dot layer exposed so we can add/remove the pulse animation
    private var dotLayer: CALayer { dotView.layer! }

    init(quality: String) {
        pauseBtn = RecordBarButton(title: "⏸  Pause", primary: false)
        stopBtn = RecordBarButton(title: "⏹  Stop", primary: true)
        super.init()

        // ── Window ─────────────────────────────────────────────────────────
        let barSize = NSSize(width: 340, height: 72)
        let win = RecordBarWindow(
            contentRect: NSRect(origin: .zero, size: barSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.onKeyStop = { [weak self] in self?.onStop?() }
        window = win

        // ── Card ───────────────────────────────────────────────────────────
        let card = RecordCardView(frame: NSRect(origin: .zero, size: barSize))

        // ── Row 1: status line (y=42) ──────────────────────────────────────

        // Pulsing red dot (8×8 pt, centred on y=42 row mid: y = 42 + (18-8)/2 = 47)
        dotView.frame = NSRect(x: 16, y: 47, width: 8, height: 8)
        dotView.wantsLayer = true
        dotView.layer!.cornerRadius = 4
        dotView.layer!.backgroundColor = Theme.accent.cgColor  // coral-red
        card.addSubview(dotView)
        startPulse()

        // "REC" eyebrow label
        let recLabel = NSTextField(labelWithString: "")
        Theme.styleEyebrow(recLabel, "REC", size: 11)
        recLabel.frame = NSRect(x: 28, y: 42, width: 36, height: 18)
        card.addSubview(recLabel)

        // Timer label — mono so digits don't jump width
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timerLabel.textColor = Theme.textPrimary
        timerLabel.frame = NSRect(x: 70, y: 42, width: 100, height: 18)
        card.addSubview(timerLabel)

        // File size label
        sizeLabel.font = Theme.font(11, .medium)
        sizeLabel.textColor = Theme.textSecondary
        sizeLabel.frame = NSRect(x: 180, y: 42, width: 100, height: 18)
        card.addSubview(sizeLabel)

        // Quality badge (rounded pill)
        let badge = QualityBadge(frame: NSRect(x: 290, y: 44, width: 24, height: 16), letter: quality)
        card.addSubview(badge)

        // ── Row 2: buttons (y=12) ─────────────────────────────────────────

        pauseBtn.frame = NSRect(x: 16, y: 12, width: 120, height: 28)
        pauseBtn.onClick = { [weak self] in self?.onPauseResume?() }
        card.addSubview(pauseBtn)

        stopBtn.frame = NSRect(x: 144, y: 12, width: 100, height: 28)
        stopBtn.onClick = { [weak self] in self?.onStop?() }
        card.addSubview(stopBtn)

        window.contentView = card
    }

    // MARK: - Public API

    /// Position the bar 24 pt above the bottom of the screen's visible frame, centred horizontally.
    func show(near screen: NSScreen) {
        let vis = screen.visibleFrame
        let barWidth: CGFloat = 340
        let x = vis.midX - barWidth / 2
        let y = vis.minY + 24
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.makeKeyAndOrderFront(nil)
    }

    /// Hide the bar without releasing it (so `windowNumber` stays valid for SCContentFilter teardown).
    func close() {
        window.orderOut(nil)
    }

    /// Called externally (typically 1 Hz) to refresh the displayed values.
    func update(elapsed: TimeInterval, fileSize: Int64, isPaused: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Timer
            let total = Int(elapsed)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            self.timerLabel.stringValue = String(format: "%02d:%02d:%02d", h, m, s)

            // File size
            if fileSize < 1_000_000 {
                self.sizeLabel.stringValue = "~\(fileSize / 1024) KB"
            } else {
                self.sizeLabel.stringValue = "~\(String(format: "%.1f", Double(fileSize) / 1_000_000)) MB"
            }

            // Pause/resume state
            self.pauseBtn.setTitle(isPaused ? "▶  Resume" : "⏸  Pause")

            // Dot animation
            if isPaused {
                self.dotLayer.removeAnimation(forKey: "pulse")
                self.dotLayer.opacity = 1.0
            } else {
                if self.dotLayer.animation(forKey: "pulse") == nil {
                    self.startPulse()
                }
            }
        }
    }

    // MARK: - Internals

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1.0
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dotLayer.add(pulse, forKey: "pulse")
    }
}

// MARK: - Private NSWindow subclass

/// Intercepts Esc and Return so the bar can stop the recording without focus gymnastics.
private final class RecordBarWindow: NSWindow {
    var onKeyStop: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 36, 76: onKeyStop?()          // Esc / Return / keypad Enter
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Card background

/// Rounded dark card: `Theme.surfaceRaised` fill + `Theme.border` hairline stroke.
private final class RecordCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Theme.surfaceRaised.setFill(); path.fill()
        Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

// MARK: - Quality badge

/// Small rounded pill drawn with `Theme.lavender` fill and a single quality letter.
private final class QualityBadge: NSView {
    private let letter: String

    init(frame: NSRect, letter: String) {
        self.letter = letter
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.lavender.setFill(); path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10, .bold),
            .foregroundColor: Theme.surfaceBase,
        ]
        let ts = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2),
                    withAttributes: attrs)
    }
}

// MARK: - Button

/// Brand-styled rounded text button (mirrors the `BarButton` in ScrollCaptureController).
private final class RecordBarButton: NSView {
    var onClick: (() -> Void)?
    private var currentTitle: String
    private let primary: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, primary: Bool) {
        self.currentTitle = title
        self.primary = primary
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ newTitle: String) {
        currentTitle = newTitle
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
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

        let color: NSColor = primary ? Theme.surfaceBase : Theme.textPrimary
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(12, .semibold), .foregroundColor: color,
        ]
        let ts = currentTitle.size(withAttributes: attrs)
        currentTitle.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2),
                          withAttributes: attrs)
    }
}
