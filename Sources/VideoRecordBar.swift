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
        pauseBtn = RecordBarButton(title: "Pause", primary: false)
        stopBtn = RecordBarButton(title: "Stop", primary: true)
        super.init()

        // ── Window ─────────────────────────────────────────────────────────
        let barSize = NSSize(width: 340, height: 84)
        let win = RecordBarWindow(
            contentRect: NSRect(origin: .zero, size: barSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true   // borderless: the drop shadow defines the edge (brand chrome)
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.onKeyStop = { [weak self] in self?.onStop?() }
        window = win

        // ── Card ───────────────────────────────────────────────────────────
        let card = RecordCardView(frame: NSRect(origin: .zero, size: barSize))

        // One shared grid: both rows honour the same 16 pt side margins and a
        // symmetric 13 / 12 / 13 vertical rhythm, so the HUD reads as one block.
        let sidePad: CGFloat = 16
        let contentRight = barSize.width - sidePad          // 324
        let statusRowY: CGFloat = 53, statusRowH: CGFloat = 18
        let buttonRowY: CGFloat = 13, buttonRowH: CGFloat = 28
        // Every status-row item (dot, labels, badge) centres on this line so the
        // differently-sized fonts share one vertical midline instead of drifting.
        let rowCenter = statusRowY + statusRowH / 2

        // ── Row 1: status line ─────────────────────────────────────────────

        // Pulsing recording dot (the app accent), centred in the status row.
        let dotSize: CGFloat = 8
        dotView.frame = NSRect(x: sidePad, y: statusRowY + (statusRowH - dotSize) / 2,
                               width: dotSize, height: dotSize)
        dotView.wantsLayer = true
        dotView.layer!.cornerRadius = dotSize / 2
        dotView.layer!.backgroundColor = Theme.accent.cgColor
        card.addSubview(dotView)
        startPulse()

        // "REC" eyebrow — the mesoneer accent-label move.
        let recLabel = NSTextField(labelWithString: "")
        Theme.styleEyebrow(recLabel, "REC", size: 11)
        let recH = recLabel.intrinsicContentSize.height
        recLabel.frame = NSRect(x: 30, y: rowCenter - recH / 2, width: 34, height: recH)
        card.addSubview(recLabel)

        // Timer — monospaced digits so the width doesn't jitter each tick.
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timerLabel.textColor = Theme.textPrimary
        let timerH = timerLabel.intrinsicContentSize.height
        timerLabel.frame = NSRect(x: 72, y: rowCenter - timerH / 2, width: 72, height: timerH)
        card.addSubview(timerLabel)

        // File-size estimate — quiet secondary text.
        sizeLabel.font = Theme.font(11, .medium)
        sizeLabel.textColor = Theme.textSecondary
        let sizeH = sizeLabel.intrinsicContentSize.height
        sizeLabel.frame = NSRect(x: 152, y: rowCenter - sizeH / 2, width: 80, height: sizeH)
        card.addSubview(sizeLabel)

        // Quality chip — right-aligned to the content margin.
        let badgeW: CGFloat = 24, badgeH: CGFloat = 16
        let badge = QualityBadge(frame: NSRect(x: contentRight - badgeW,
                                               y: statusRowY + (statusRowH - badgeH) / 2,
                                               width: badgeW, height: badgeH), letter: quality)
        card.addSubview(badge)

        // ── Row 2: actions — two equal halves spanning the content width ────
        let gap: CGFloat = 12
        let buttonW = (contentRight - sidePad - gap) / 2      // 148

        stopBtn.frame = NSRect(x: sidePad, y: buttonRowY, width: buttonW, height: buttonRowH)
        stopBtn.onClick = { [weak self] in self?.onStop?() }
        card.addSubview(stopBtn)

        pauseBtn.frame = NSRect(x: sidePad + buttonW + gap, y: buttonRowY, width: buttonW, height: buttonRowH)
        pauseBtn.onClick = { [weak self] in self?.onPauseResume?() }
        card.addSubview(pauseBtn)

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
            self.pauseBtn.setTitle(isPaused ? "Resume" : "Pause")

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

/// Square brand card: the shared panel gradient behind the HUD content, no border —
/// the same chrome as the About / Settings panels and the editor's floating cards.
/// The window's drop shadow (not an edge stroke) lifts it off the backdrop.
private final class RecordCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.applyPanelGradient(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Quality badge

/// Small square chip drawn with `Theme.lavender` fill and a single quality letter.
private final class QualityBadge: NSView {
    private let letter: String

    init(frame: NSRect, letter: String) {
        self.letter = letter
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
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

/// Brand action button matching `BrandAlert`: square, flat, no radius. `primary` is a
/// solid white fill (dark text); the secondary is a quiet hairline ghost that brightens
/// on hover. White/ghost/square is the mesoneer button system (see styleguide).
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
        let path = NSBezierPath(rect: bounds)
        if primary {
            (hovering ? NSColor(white: 0.90, alpha: 1) : .white).setFill()
            path.fill()
        } else {
            (hovering ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.07)).setFill()
            path.fill()
            Theme.cardStroke.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1; border.stroke()
        }

        let color: NSColor = primary ? Theme.surfaceBase : Theme.textPrimary
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(13, .semibold), .foregroundColor: color,
        ]
        let ts = currentTitle.size(withAttributes: attrs)
        currentTitle.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2),
                          withAttributes: attrs)
    }
}
