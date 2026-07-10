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
    private var isPaused = false
    private var currentURL: URL?

    // MARK: - Public

    /// Begin a new recording: show the selection overlay on every screen.
    /// No-op if a recording is already in progress.
    func begin() {
        guard session == nil else { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }
        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        // Promote to `.regular` so the overlay — and, later, the recording bar —
        // can hold keyboard focus (Esc/Space, Esc/Return to stop). A background
        // `.accessory` agent can't reliably become active, so key events would
        // never arrive. Stays `.regular` through recording; reverted on cancel
        // (below) and when recording stops. The Dock icon is hidden behind the
        // full-screen overlay.
        NSApp.setActivationPolicy(.regular)
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
                self?.revertActivationPolicyIfIdle()
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

    private func dismissOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        // Reset the pointer to the default arrow so the overlay's custom capture cursor
        // isn't left showing (and isn't baked into the first recorded frames).
        NSCursor.arrow.set()
    }

    /// Drop back to a background agent once nothing on screen needs the Dock
    /// presence / keyboard focus. Guarded so we don't demote the app while an
    /// editor is still open.
    private func revertActivationPolicyIfIdle() {
        if !EditorWindowController.hasOpenWindows { NSApp.setActivationPolicy(.accessory) }
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
                        let alert = NSAlert()
                        alert.messageText = "Microphone Access Denied"
                        alert.informativeText = "m_capture doesn't have permission to use the microphone. Recording will continue without mic audio."
                        alert.runModal()
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

        // Phase 2c — create session with the bar excluded from capture. (Window
        // targets ignore the exclusion list — a window filter never captures the bar.)
        let recordSession = VideoRecordSession(
            target: target,
            quality: Settings.shared.videoQuality,
            audioSource: audioSource,
            outputURL: url,
            excludedWindowIDs: [CGWindowID(recordBar.windowNumber)]
        )
        session = recordSession

        // Phase 2d — wire bar callbacks.
        recordBar.onStop = { [weak self] in self?.stopRecording() }
        recordBar.onPauseResume = { [weak self] in self?.togglePause() }

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
        }
        t.resume()
        updateTimer = t
    }

    private func stopRecording() {
        updateTimer?.cancel()
        updateTimer = nil
        bar?.close()
        revertActivationPolicyIfIdle()
        guard let session = session, let url = currentURL else { return }
        self.session = nil
        self.bar = nil
        self.isPaused = false
        self.currentURL = nil
        Task {
            await session.stop()
            await MainActor.run {
                if Settings.shared.playSound { NSSound(named: "Grab")?.play() }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
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
    }

    /// Called on the main thread when `start()` throws. Tears down the bar and
    /// session so the controller is back in the idle state, then tells the user why.
    private func handleStartError(_ error: Error) {
        updateTimer?.cancel(); updateTimer = nil
        bar?.close(); bar = nil
        session = nil; currentURL = nil; isPaused = false
        revertActivationPolicyIfIdle()

        let isPermission = !ScreenRecordingPermission.isGranted
        if isPermission {
            ScreenRecordingPermission.handleDenied()
        } else {
            let alert = BrandAlert(
                title: "Recording failed to start",
                message: "The recorder could not start: \(error.localizedDescription)\n\nIf Screen Recording was just reset by a rebuild, re-approve it under System Settings → Privacy & Security → Screen Recording and try again.",
                titles: ["OK"],
                primary: 0, cancel: 0
            )
            alert.runModal()
        }
    }

    /// Produces a timestamped `.mp4` URL in the configured save directory,
    /// independent of the image-format setting in `Settings`.
    private func videoURL() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH-mm-ss-dd-MM-yyyy"
        let name = "\(Settings.shared.filenamePrefix)\(fmt.string(from: Date())).mp4"
        return Settings.shared.saveDirectory.appendingPathComponent(name)
    }
}
