// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation

/// Singleton orchestrator for the video-recording flow.
/// Coordinates the region-selection overlay, `VideoRecordBar`, `VideoRecordSession`,
/// and the 1 Hz update tick.
///
/// Call `begin()` from AppDelegate (guarded with `#available(macOS 14, *)`).
@available(macOS 14, *)
final class VideoRecordController {
    static let shared = VideoRecordController()
    private init() {}

    private var session: VideoRecordSession?
    private var bar: VideoRecordBar?
    private var updateTimer: DispatchSourceTimer?
    private var overlays: [OverlayWindow] = []
    private var dimWindows: [RecordingDimWindow] = []
    private var isPaused = false
    private var currentURL: URL?

    /// Reports recording state to the menu-bar icon so it's obvious the app is recording
    /// even when the floating bar is minimized: `(active, elapsed, paused)`.
    var onRecordingUIUpdate: ((_ active: Bool, _ elapsed: TimeInterval, _ paused: Bool) -> Void)?
    private func clearRecordingUI() { onRecordingUIUpdate?(false, 0, false) }

    // MARK: - Public

    /// Whether a recording is in progress (or paused mid-recording). Callers that need
    /// to avoid interrupting an in-flight capture (e.g. the updater's auto-relaunch)
    /// check this first.
    var isRecording: Bool { session != nil }

    /// Whether an in-progress recording is currently paused (for the menu-bar controls).
    var isRecordingPaused: Bool { session != nil && isPaused }

    // Menu-bar controls, so the recording can be driven from the status item when the
    // floating bar is minimized.
    func stopFromMenu() { stopRecording() }
    func togglePauseFromMenu() { togglePause() }
    /// Hide/show the floating record bar without ending the recording.
    func setBarHidden(_ hidden: Bool) { bar?.setVisible(!hidden) }
    /// Whether the bar is currently hidden (minimized to the menu bar).
    var isBarHidden: Bool { bar?.isVisible == false }

    /// Begin a new recording: show the selection overlay on every screen.
    /// No-op if a recording is already in progress, or the annotation editor
    /// is open (its full-screen dim backdrop and the recording overlay would
    /// otherwise fight for the same screen).
    func begin() {
        guard session == nil else { return }
        guard !EditorWindowController.hasOpenWindows else { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }
        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        // Activate so the overlay — and, later, the recording bar — can hold
        // keyboard focus (Esc/Space, Esc/Return to stop). The app is already
        // `.regular` (Dock icon), which is what lets it reliably become active.
        NSApp.activate(ignoringOtherApps: true)
        let coordinator = OverlayCoordinator()
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen, coordinator: coordinator,
                                    allowsWindowMode: true, allowsFullScreenMode: true, recording: true)
            win.onComplete = { [weak self] rect in
                let global = CGRect(x: screen.frame.minX + rect.minX,
                                    y: screen.frame.minY + rect.minY,
                                    width: rect.width, height: rect.height)
                self?.dismissOverlays()
                self?.requestMicThenStart(target: .region(rect: global, screen: screen), barScreen: screen)
            }
            win.onCompleteScreen = { [weak self] in
                self?.dismissOverlays()
                self?.requestMicThenStart(target: .region(rect: screen.frame, screen: screen), barScreen: screen)
            }
            win.onCompleteWindow = { [weak self] windowID in
                self?.dismissOverlays()
                self?.requestMicThenStart(target: .window(windowID), barScreen: Self.screen(forWindow: windowID))
            }
            win.onCancel = { [weak self] in
                self?.dismissOverlays()
            }
            overlays.append(win)
            if screen == keyScreen {
                win.makeKeyAndOrderFront(nil)
                win.makeFirstResponder(win.contentView)
            } else {
                win.orderFront(nil)
            }
        }
    }

    // MARK: - Private

    /// Put up a click-through dark overlay on every screen, cutting out the recording
    /// region so the captured bounds are unmistakable. Returns the dim windows' numbers so
    /// the caller can exclude them from the SCStream. `global` is in AppKit screen coords.
    @discardableResult
    private func showDim(forRegion global: CGRect) -> [CGWindowID] {
        dismissDim()
        var ids: [CGWindowID] = []
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(global)
            let hole = inter.isNull ? nil
                : CGRect(x: inter.minX - screen.frame.minX, y: inter.minY - screen.frame.minY,
                         width: inter.width, height: inter.height)
            // Every screen gets an overlay: a hole where the recording lands (dim around it
            // + a frame), or a full dim where it doesn't. A screen the region fully covers
            // shows just the frame (no dim) so screen/window recordings are outlined too.
            let win = RecordingDimWindow(screen: screen, holeInScreen: hole)
            win.orderFront(nil)
            dimWindows.append(win)
            ids.append(CGWindowID(win.windowNumber))
        }
        return ids
    }

    private func dismissDim() {
        dimWindows.forEach { $0.orderOut(nil) }
        dimWindows.removeAll()
    }

    private func dismissOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        // Reset the pointer to the default arrow so the overlay's custom capture cursor
        // isn't left showing (and isn't baked into the first recorded frames).
        NSCursor.arrow.set()
    }

    /// Resolve the screen a picked window mostly lives on, for placing the record bar.
    /// Uses the synchronous window list (the capture itself re-resolves via SCK).
    private static func screen(forWindow windowID: CGWindowID) -> NSScreen {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let win = WindowList.onScreen(excludingPID: pid).first(where: { $0.id == windowID }) {
            let appKit = WindowList.appKitRect(fromCG: win.frame)
            if let s = NSScreen.screens.first(where: { $0.frame.intersects(appKit) }) { return s }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// The picked window's global AppKit frame (for the recording dim's cutout), or nil.
    private static func windowGlobalFrame(_ windowID: CGWindowID) -> CGRect? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let win = WindowList.onScreen(excludingPID: pid).first(where: { $0.id == windowID }) else { return nil }
        return WindowList.appKitRect(fromCG: win.frame)
    }

    /// If the configured audio source includes the mic, request permission first.
    /// Always bounces back to the main thread before starting the session.
    /// `barScreen` is where the floating record bar is placed.
    private func requestMicThenStart(target: VideoRecordSession.Target, barScreen: NSScreen) {
        let audioSource = Settings.shared.videoAudioSource
        if audioSource.capturesMic {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    let effective: VideoAudioSource
                    if granted {
                        effective = audioSource
                    } else {
                        // Downgrade: if both were requested, fall back to system only;
                        // if mic-only was requested, fall back to none.
                        effective = audioSource == .both ? .system : .none
                        _ = BrandAlert(title: "Microphone access denied",
                                       message: "Recording will continue without mic audio.",
                                       titles: ["OK"], primary: 0, cancel: 0,
                                       icon: "mic.slash").runModal()
                    }
                    self?.startRecording(target: target, barScreen: barScreen, audioSource: effective)
                }
            }
        } else {
            startRecording(target: target, barScreen: barScreen, audioSource: audioSource)
        }
    }

    private func startRecording(target: VideoRecordSession.Target, barScreen: NSScreen, audioSource: VideoAudioSource) {
        // Region captures below a usable size are almost always accidental clicks;
        // window captures have no such floor.
        if case let .region(rect, _) = target, rect.width < 20 || rect.height < 20 { return }

        let qualityLetter: String
        switch Settings.shared.videoQuality {
        case .high:   qualityLetter = "H"
        case .medium: qualityLetter = "M"
        case .low:    qualityLetter = "L"
        }

        // Phase 2a — show bar FIRST so its windowNumber is available before SCStream begins.
        let recordBar = VideoRecordBar(quality: qualityLetter)
        recordBar.show(near: barScreen)
        bar = recordBar

        // Phase 2b — compute output URL with a forced .mp4 extension.
        let url = videoURL()
        currentURL = url

        // Phase 2b′ — darken everything outside what's being recorded so the captured
        // bounds are unmistakable, for region, whole-screen and window targets alike. The
        // dim windows are excluded from the region/display capture below; a window filter
        // already captures only the target window, so they never reach that video.
        var excluded = [CGWindowID(recordBar.windowNumber)]
        switch target {
        case let .region(rect, _):
            excluded += showDim(forRegion: rect)
        case let .window(windowID):
            if let rect = Self.windowGlobalFrame(windowID) { showDim(forRegion: rect) }
        }

        // Phase 2c — create session with the bar (and dim) excluded from capture. (Window
        // targets ignore the exclusion list — a window filter never captures the bar.)
        let recordSession = VideoRecordSession(
            target: target,
            quality: Settings.shared.videoQuality,
            audioSource: audioSource,
            outputURL: url,
            excludedWindowIDs: excluded
        )
        session = recordSession
        recordSession.onUnexpectedStop = { [weak self] reason in self?.handleUnexpectedStop(reason) }

        // Phase 2d — wire bar callbacks.
        recordBar.onStop = { [weak self] in self?.stopRecording() }
        recordBar.onPauseResume = { [weak self] in self?.togglePause() }
        recordBar.onDiscard = { [weak self] in self?.discardRecording() }
        recordBar.onMinimize = { [weak self] in self?.setBarHidden(true) }

        // Phase 2e — start capture, then start the UI ticker.
        // Handle start() errors explicitly: a silent failure leaves the bar running
        // with a 0 KB file and no feedback to the user.
        Task {
            do {
                try await recordSession.start()
            } catch {
                await MainActor.run { self.handleStartError(error) }
            }
        }
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let session = self.session else { return }
            self.bar?.update(elapsed: session.elapsedSeconds,
                             fileSize: session.estimatedFileSize,
                             isPaused: self.isPaused)
            self.onRecordingUIUpdate?(true, session.elapsedSeconds, self.isPaused)
        }
        t.resume()
        updateTimer = t
        onRecordingUIUpdate?(true, 0, isPaused)   // show the indicator immediately, not after 1 s
    }

    private func stopRecording() {
        updateTimer?.cancel()
        updateTimer = nil
        bar?.close()
        dismissDim()
        clearRecordingUI()
        guard let session = session, let url = currentURL else { return }
        self.session = nil
        self.bar = nil
        self.isPaused = false
        self.currentURL = nil
        Task {
            await session.stop()
            await MainActor.run {
                // Only celebrate/reveal a file that actually made it to disk — a
                // failed writer leaves nothing to show.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    _ = BrandAlert(title: "Recording wasn't saved",
                                   message: "Check that your save folder has free space.",
                                   titles: ["OK"], primary: 0, cancel: 0,
                                   icon: "exclamationmark.triangle").runModal()
                    return
                }
                if Settings.shared.playSound { NSSound(named: "Grab")?.play() }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Finalize an in-flight recording before the process quits, so the `.mp4` gets its
    /// `moov` atom instead of ending up a corrupt, unplayable file. Called from the Quit
    /// / Force Quit menu actions before termination.
    ///
    /// We *pump* the main run loop while the async stop runs rather than blocking it:
    /// `SCStream.stopCapture` delivers its completion on the main queue, so a plain
    /// `semaphore.wait` on main would deadlock and leave the file unfinalized. Bounded
    /// so termination can't hang.
    func finalizeForTermination() {
        guard let session = session, let url = currentURL else { return }
        updateTimer?.cancel(); updateTimer = nil
        bar?.close(); bar = nil
        dismissDim()
        self.session = nil; self.currentURL = nil; self.isPaused = false
        let done = DispatchSemaphore(value: 0)
        Task.detached { await session.stop(); done.signal() }
        let deadline = Date().addingTimeInterval(8)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            // Let main-queue completions (stopCapture, finishWriting) run.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if Settings.shared.playSound, FileManager.default.fileExists(atPath: url.path) {
            NSSound(named: "Grab")?.play()
        }
    }

    /// Discard the recording (Esc): confirm, then stop the session and delete the
    /// partial file — the universal cancel gesture shouldn't leave a junk .mp4 behind.
    private func discardRecording() {
        guard let session = session, let url = currentURL else { return }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = BrandAlert(title: "Discard recording?",
                                 message: "This recording will be deleted.",
                                 titles: ["Discard", "Keep Recording"],
                                 primary: 1, cancel: 1, icon: "trash", destructive: [0]).runModal()
        guard confirm == 0 else { return }
        updateTimer?.cancel(); updateTimer = nil
        bar?.close(); bar = nil
        dismissDim()
        clearRecordingUI()
        self.session = nil; self.currentURL = nil; self.isPaused = false
        Task {
            await session.stop()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func togglePause() {
        guard let session else { return }
        if isPaused {
            session.resume()
            isPaused = false
        } else {
            session.pause()
            isPaused = true
        }
        onRecordingUIUpdate?(true, session.elapsedSeconds, isPaused)   // reflect pause in the menu-bar icon at once
    }

    /// Called on the main thread when the capture stream stops unexpectedly mid-record
    /// (permission revoked, display unplugged, disk trouble). Finalizes whatever was
    /// captured, tears down the HUD, and tells the user — rather than the bar ticking
    /// on against a dead stream.
    private func handleUnexpectedStop(_ reason: String) {
        guard let session = session else { return }
        updateTimer?.cancel(); updateTimer = nil
        bar?.close(); bar = nil
        dismissDim()
        clearRecordingUI()
        let url = currentURL
        self.session = nil; self.currentURL = nil; self.isPaused = false
        Task {
            await session.stop()   // flush whatever frames made it, so the file is playable
            await MainActor.run {
                let saved = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                let tail = saved ? " The partial recording was saved." : ""
                _ = BrandAlert(title: "Recording stopped",
                               message: "The recording ended unexpectedly.\(tail)",
                               titles: ["OK"], primary: 0, cancel: 0,
                               icon: "exclamationmark.triangle").runModal()
                if saved, let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    /// Called on the main thread when `start()` throws. Tears down the bar and
    /// session so the controller is back in the idle state, then tells the user why.
    private func handleStartError(_ error: Error) {
        updateTimer?.cancel(); updateTimer = nil
        bar?.close(); bar = nil
        dismissDim()
        clearRecordingUI()
        session = nil; currentURL = nil; isPaused = false

        let isPermission = !ScreenRecordingPermission.isGranted
        if isPermission {
            ScreenRecordingPermission.handleDenied()
        } else {
            _ = BrandAlert(
                title: "Recording failed to start",
                message: "If Screen Recording was just reset, re-approve it in System Settings and try again.",
                titles: ["OK"], primary: 0, cancel: 0,
                icon: "exclamationmark.triangle"
            ).runModal()
        }
    }

    /// Produces a timestamped `.mp4` URL in the (validated, uniquified) save
    /// directory, independent of the image-format setting in `Settings`.
    private func videoURL() -> URL { Settings.shared.fileURL(ext: "mp4") }
}

/// A click-through dark overlay covering one screen while recording, with the recording
/// region cut out so it reads as a bright "hole" framed by the brand accent. Never
/// intercepts events (the app under it stays fully interactive) and is excluded from the
/// SCStream so it never lands in the video.
@available(macOS 14, *)
final class RecordingDimWindow: NSWindow {
    /// `holeInScreen` is the recording rect in this screen's local coords, or nil to dim
    /// the whole screen (the region lives entirely on another display).
    init(screen: NSScreen, holeInScreen: CGRect?) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above regular app windows (so they dim) but below the floating record bar.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = RecordingDimView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.hole = holeInScreen
        contentView = v
    }
}

@available(macOS 14, *)
private final class RecordingDimView: NSView {
    var hole: CGRect?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Match the capture selection overlay exactly (see SelectionOverlay): the same
        // surfaceBase dim and lavender region outline, so the record backdrop reads as
        // the same surface the user just dragged their region on.
        ctx.setFillColor(Theme.surfaceBase.withAlphaComponent(0.55).cgColor)
        guard let h = hole else { ctx.fill(bounds); return }
        // Fill the four bands around the hole so the region itself stays clear.
        let b = bounds
        ctx.fill(CGRect(x: 0, y: h.maxY, width: b.width, height: b.maxY - h.maxY))
        ctx.fill(CGRect(x: 0, y: 0, width: b.width, height: h.minY))
        ctx.fill(CGRect(x: 0, y: h.minY, width: h.minX, height: h.height))
        ctx.fill(CGRect(x: h.maxX, y: h.minY, width: b.maxX - h.maxX, height: h.height))
        let lw: CGFloat = 2
        ctx.setStrokeColor(Theme.lavender.cgColor)
        ctx.setLineWidth(lw)
        ctx.stroke(h.insetBy(dx: lw / 2, dy: lw / 2))
    }
}
