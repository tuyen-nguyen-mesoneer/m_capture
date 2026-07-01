// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation

/// Singleton orchestrator for the video-recording flow.
/// Coordinates the region-selection overlay, `VideoRecordBar`, `VideoRecordSession`,
/// and the 1 Hz update tick. Mirrors the lifecycle of `ScrollCaptureController`.
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
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen, allowsWindowMode: false, allowsFullScreenMode: true)
            win.onComplete = { [weak self] rect in
                let global = CGRect(x: screen.frame.minX + rect.minX,
                                    y: screen.frame.minY + rect.minY,
                                    width: rect.width, height: rect.height)
                self?.dismissOverlays()
                self?.requestMicThenStart(region: global, screen: screen)
            }
            win.onCancel = { [weak self] in self?.dismissOverlays() }
            overlays.append(win)
            if screen == keyScreen { win.makeKeyAndOrderFront(nil) } else { win.orderFront(nil) }
        }
    }

    // MARK: - Private

    private func dismissOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    /// If the configured audio source includes the mic, request permission first.
    /// Always bounces back to the main thread before starting the session.
    private func requestMicThenStart(region: CGRect, screen: NSScreen) {
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
                    self?.startRecording(region: region, screen: screen, audioSource: effective)
                }
            }
        } else {
            startRecording(region: region, screen: screen, audioSource: audioSource)
        }
    }

    private func startRecording(region: CGRect, screen: NSScreen, audioSource: VideoAudioSource) {
        guard region.width >= 20, region.height >= 20 else { return }

        let qualityLetter: String
        switch Settings.shared.videoQuality {
        case .high:   qualityLetter = "H"
        case .medium: qualityLetter = "M"
        case .low:    qualityLetter = "L"
        }

        // Phase 2a — show bar FIRST so its windowNumber is available before SCStream begins.
        let recordBar = VideoRecordBar(quality: qualityLetter)
        recordBar.show(near: screen)
        bar = recordBar

        // Phase 2b — compute output URL with a forced .mp4 extension.
        let url = videoURL()
        currentURL = url

        // Phase 2c — create session with the bar excluded from capture.
        let recordSession = VideoRecordSession(
            region: region,
            screen: screen,
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
