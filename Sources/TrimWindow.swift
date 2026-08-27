// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation

/// Post-recording trim: a brand panel with a live preview and an in/out range
/// slider, exporting losslessly (passthrough — no re-encode) over the original
/// file. Opened by "Stop & Trim…" in the menu-bar recording controls.
///
/// Preview uses `AVPlayerLayer` directly (AVFoundation, already linked) rather
/// than AVKit's `AVPlayerView`, whose system-styled controls would break the
/// brand chrome anyway — playback is driven by our own play/pause button and
/// the slider's scrubbing.
final class TrimWindowController: NSObject {
    /// Self-retained while open, like `PinnedWindow` — no owner outlives the flow.
    private static var active: TrimWindowController?

    private let window: PanelWindow
    private let url: URL
    private let player: AVPlayer
    private let slider = TrimSlider()
    private let playButton = BrandButton(title: "▶", kind: .secondary)
    private let saveButton = BrandButton(title: L("Save"), kind: .primary)
    private let rangeLabel = NSTextField(labelWithString: "")
    private var timeObserver: Any?
    private var duration: Double = 0
    private var exporting = false

    static func show(url: URL) { active = TrimWindowController(url: url) }

    private init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)

        let size = NSSize(width: 680, height: 520)
        window = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.surfaceBase
        window.hasShadow = true
        super.init()

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        Theme.applyPanelGradient(to: content)

        let side: CGFloat = 24
        let title = NSTextField(labelWithString: "")
        Theme.styleEyebrow(title, L("TRIM RECORDING"))
        title.sizeToFit()
        title.frame.origin = CGPoint(x: side, y: size.height - 40)
        content.addSubview(title)

        // Preview area, aspect-fit inside a fixed frame.
        let video = NSView(frame: NSRect(x: side, y: 150, width: size.width - side * 2, height: size.height - 40 - 160))
        video.wantsLayer = true
        video.layer?.backgroundColor = NSColor.black.cgColor
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = video.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.videoGravity = .resizeAspect
        video.layer?.addSublayer(playerLayer)
        video.autoresizingMask = [.width, .height]
        content.addSubview(video)

        slider.frame = NSRect(x: side + 44, y: 96, width: size.width - side * 2 - 44, height: 36)
        content.addSubview(slider)

        playButton.frame = NSRect(x: side, y: 96, width: 36, height: 36)
        playButton.target = self; playButton.action = #selector(togglePlay)
        content.addSubview(playButton)

        rangeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        rangeLabel.textColor = Theme.textSecondary
        rangeLabel.frame = NSRect(x: side, y: 66, width: size.width - side * 2, height: 18)
        rangeLabel.alignment = .center
        content.addSubview(rangeLabel)

        let cancel = BrandButton(title: L("Keep Full Recording"), kind: .secondary)
        cancel.frame = NSRect(x: side, y: 20, width: 190, height: 36)
        cancel.target = self; cancel.action = #selector(cancelPressed)
        content.addSubview(cancel)

        saveButton.frame = NSRect(x: size.width - side - 150, y: 20, width: 150, height: 36)
        saveButton.target = self; saveButton.action = #selector(savePressed)
        content.addSubview(saveButton)

        window.contentView = content
        window.installChrome(on: content)
        window.onClose = { [weak self] in self?.close() }

        slider.onRangeChange = { [weak self] in self?.rangeChanged() }
        slider.onScrub = { [weak self] t in
            self?.player.pause(); self?.setPlaying(false)
            self?.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }

        loadDuration()

        AppPanels.closeAll(except: window)
        window.centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func loadDuration() {
        Task { [weak self] in
            guard let self else { return }
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            await MainActor.run {
                self.duration = max(0.1, d)
                self.slider.configure(duration: self.duration)
                self.rangeChanged()
                self.startPlayheadUpdates()
            }
        }
    }

    /// Keep the slider's playhead live, and loop playback inside the trimmed range
    /// so what previews is exactly what saves.
    private func startPlayheadUpdates() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            self.slider.playhead = s
            if self.player.rate > 0, s >= self.slider.outTime {
                self.player.seek(to: CMTime(seconds: self.slider.inTime, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func rangeChanged() {
        let len = slider.outTime - slider.inTime
        rangeLabel.stringValue =
            "\(Self.clock(slider.inTime))  →  \(Self.clock(slider.outTime))    "
            + String(format: L("(%@ kept)"), Self.clock(len))
    }

    private static func clock(_ t: Double) -> String {
        let s = Int(t), tenths = Int((t - Double(s)) * 10)
        return String(format: "%d:%02d.%d", s / 60, s % 60, tenths)
    }

    private func setPlaying(_ playing: Bool) {
        playButton.attributedTitle = NSAttributedString(
            string: playing ? "❚❚" : "▶",
            attributes: [.font: Theme.font(13, .semibold), .foregroundColor: Theme.textPrimary])
    }

    @objc private func togglePlay() {
        if player.rate > 0 { player.pause(); setPlaying(false); return }
        // Restart from the in-point when the playhead sits outside the kept range.
        let now = player.currentTime().seconds
        if now < slider.inTime || now >= slider.outTime {
            player.seek(to: CMTime(seconds: slider.inTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play(); setPlaying(true)
    }

    @objc private func cancelPressed() { close() }

    /// Passthrough export of the kept range to a scratch file, then swap it over the
    /// original — lossless and near-instant since nothing re-encodes.
    @objc private func savePressed() {
        guard !exporting else { return }
        // Full range selected → nothing to cut.
        guard slider.inTime > 0.05 || slider.outTime < duration - 0.05 else { close(); return }
        exporting = true
        player.pause(); setPlaying(false)
        saveButton.attributedTitle = NSAttributedString(string: L("Saving…"), attributes: [
            .font: Theme.font(13, .semibold), .foregroundColor: Theme.surfaceBase])

        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            exporting = false; return
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".trim-" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        export.outputURL = tmp
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: slider.inTime, preferredTimescale: 600),
            end: CMTime(seconds: slider.outTime, preferredTimescale: 600))
        export.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                if export.status == .completed,
                   (try? FileManager.default.replaceItemAt(
                        URL(fileURLWithPath: self.url.path), withItemAt: tmp)) != nil {
                    if Settings.shared.playSound { NSSound(named: "Grab")?.play() }
                    self.close()
                    HistoryWindowController.shared.show()
                } else {
                    try? FileManager.default.removeItem(at: tmp)
                    BrandAlert(title: L("Unable to trim the recording"),
                               message: L("The full recording was kept unchanged."),
                               titles: ["OK"], primary: 0, cancel: 0,
                               icon: "exclamationmark.triangle").present()
                }
            }
        }
    }

    private func close() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o) }
        timeObserver = nil
        window.orderOut(nil)
        Self.active = nil
    }
}

/// The in/out range slider under the preview: dark track, lavender kept-range,
/// two white edge handles, and a thin playhead line. Dragging a handle adjusts
/// the range; dragging elsewhere scrubs the playhead.
final class TrimSlider: NSView {
    private(set) var inTime: Double = 0
    private(set) var outTime: Double = 1
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var onRangeChange: (() -> Void)?
    var onScrub: ((Double) -> Void)?

    private var duration: Double = 1
    private enum Drag { case none, inHandle, outHandle, scrub }
    private var drag: Drag = .none

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { L("Trim range") }

    func configure(duration: Double) {
        self.duration = duration
        inTime = 0; outTime = duration; playhead = 0
        needsDisplay = true
    }

    private var track: CGRect { bounds.insetBy(dx: 6, dy: 10) }
    private func x(for t: Double) -> CGFloat { track.minX + track.width * CGFloat(t / duration) }
    private func t(for x: CGFloat) -> Double {
        Double(max(0, min(1, (x - track.minX) / track.width))) * duration
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - x(for: inTime)) < 9 { drag = .inHandle }
        else if abs(p.x - x(for: outTime)) < 9 { drag = .outHandle }
        else { drag = .scrub; onScrub?(t(for: p.x)); playhead = t(for: p.x) }
        apply(p)
    }
    override func mouseDragged(with event: NSEvent) { apply(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { drag = .none }

    private func apply(_ p: CGPoint) {
        let time = t(for: p.x)
        switch drag {
        case .inHandle:  inTime = min(time, outTime - 0.2); onRangeChange?()
        case .outHandle: outTime = max(time, inTime + 0.2); onRangeChange?()
        case .scrub:     playhead = time; onScrub?(time)
        case .none:      return
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = track
        ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor)
        NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()

        let kept = CGRect(x: x(for: inTime), y: r.minY,
                          width: x(for: outTime) - x(for: inTime), height: r.height)
        ctx.setFillColor(Theme.lavender.withAlphaComponent(0.35).cgColor)
        ctx.fill(kept)
        ctx.setStrokeColor(Theme.lavender.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(kept.insetBy(dx: 0.75, dy: 0.75))

        // Edge handles: white vertical grips at the in/out points.
        for hx in [x(for: inTime), x(for: outTime)] {
            let grip = CGRect(x: hx - 3, y: r.minY - 4, width: 6, height: r.height + 8)
            ctx.setFillColor(NSColor.white.cgColor)
            NSBezierPath(roundedRect: grip, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()
        }

        // Playhead: thin accent line, only inside the track.
        if playhead >= 0, playhead <= duration {
            ctx.setFillColor(Theme.accent.cgColor)
            ctx.fill(CGRect(x: x(for: playhead) - 0.75, y: r.minY - 2, width: 1.5, height: r.height + 4))
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
