// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Singleton orchestrator for the video-recording flow.
/// Coordinates the region-selection overlay, `VideoRecordBar`, `VideoRecordSession`,
/// and the 1 Hz update tick.
///
/// Call `begin()` from AppDelegate (guarded with `#available(macOS 14, *)`).
@available(macOS 14, *)
final class VideoRecordController {
    static let shared = VideoRecordController()

    /// True while the record flow's drag-to-select overlay is on screen (before the
    /// recording itself starts). `Updater` checks this so a background-update alert
    /// never opens underneath the full-screen overlays.
    var isSelecting: Bool { !overlays.isEmpty }

    /// A display appearing or vanishing mid-selection leaves overlays sized for a
    /// screen layout that no longer exists — tear the selection down. An already
    /// running recording is left alone (the stream errors out on its own if its
    /// display goes away, via `onUnexpectedStop`).
    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if !self.overlays.isEmpty { self.dismissOverlays() }
            // The recorded display vanished (unplugged / sleep): the SCStream can
            // stall silently rather than erroring, leaving a timer counting over a
            // dead capture. Route it through the unexpected-stop path, which
            // finalizes and saves the partial file.
            if let id = self.session?.recordedDisplayID,
               !NSScreen.screens.compactMap(\.displayID).contains(id) {
                self.handleUnexpectedStop("display disconnected")
            }
        }
    }

    /// SCShareableContent warm-up kicked off when the selection overlay opens —
    /// consumed by the session so recording starts (and the timer moves) promptly.
    private var contentPrefetch: Task<SCShareableContent?, Never>?

    private var session: VideoRecordSession?
    /// Stands in for `session` while simulate mode is on — nothing is captured, but the
    /// HUD needs a clock to read (see `Settings.simulateRecording`). Non-nil exactly
    /// while a simulated recording is in flight, so it doubles as the mode's state flag.
    private var simClock: SimulatedRecordingClock?
    /// Snapshot of `Settings.simulateRecording` taken when `begin()` runs, so toggling
    /// the setting mid-selection can't start a recording in a half-switched mode.
    private var isSimulating = false
    private var bar: VideoRecordBar?
    /// On-screen drawing for this recording (⌃⇧D). Non-nil only for region and whole-screen
    /// targets — see `canDraw`.
    private var drawOverlay: RecordDrawOverlay?
    /// Shows which sub-rect is being recorded while zoomed. Created before the stream starts
    /// so its windowNumber can join the exclusion list — the list is fixed at stream start,
    /// so a window made later could not be kept out of the video.
    private var zoomIndicator: ZoomIndicatorWindow?
    /// Drives the indicator while zoom is active. Separate from the 4 Hz HUD tick because a
    /// 250 ms indicator would visibly stutter against a camera gliding at 30–60 fps.
    private var zoomTicker: DispatchSourceTimer?
    /// Simulate mode has no capture session to own an engine, so the controller owns one —
    /// which is what makes the shortcut, the easing and the follow testable without the
    /// Screen Recording grant. Its scale is the screen's, not SCK's authoritative value.
    private var simZoomEngine: RecordZoomEngine?
    private var zoomTargetIsRegion = false
    private var updateTimer: DispatchSourceTimer?
    private var overlays: [OverlayWindow] = []
    private var dimWindows: [RecordingDimWindow] = []
    /// Bundle ID of whichever app was frontmost before `begin()` force-activated us for
    /// the drag-to-select overlay — yielded back once actual recording starts, so the
    /// rest of the recording doesn't leave m_capture squatting on "active app" and
    /// forcing an extra activation click on whatever the user switches to (the floating
    /// bar's own controls stay usable regardless, via `acceptsFirstMouse`). Uses
    /// `NSApplication.yieldActivation`, not `NSRunningApplication.activate()` — modern
    /// macOS's focus-stealing protections silently ignore one app force-activating an
    /// unrelated one; yielding is the sanctioned way to hand back activation we grabbed.
    private var appToRestore: String?
    private var isPaused = false
    private var currentURL: URL?

    /// Reports recording state to the menu-bar icon so it's obvious the app is recording
    /// even when the floating bar is minimized: `(active, elapsed, paused)`.
    var onRecordingUIUpdate: ((_ active: Bool, _ elapsed: TimeInterval, _ paused: Bool) -> Void)?
    private func clearRecordingUI() {
        clickVisualizer.stop()
        onRecordingUIUpdate?(false, 0, false)
    }
    private let clickVisualizer = ClickVisualizer()

    // MARK: - Public

    /// Whether a recording is in progress (or paused mid-recording). Callers that need
    /// to avoid interrupting an in-flight capture (e.g. the updater's auto-relaunch)
    /// check this first. True for a simulated recording too — it owns the same HUD,
    /// hotkeys and menu, so everything that must not run "while recording" still applies.
    var isRecording: Bool { session != nil || simClock != nil }

    /// Whether the in-flight recording is simulated: the flow runs but nothing is
    /// captured and no file is written. Drives the amber SIM indicators and hides the
    /// stop variants that would need a file (GIF / Trim).
    var isSimulatedRecording: Bool { simClock != nil }

    /// Whether an in-progress recording is currently paused (for the menu-bar controls).
    var isRecordingPaused: Bool { isRecording && isPaused }

    /// Elapsed time from whichever clock drives this recording — the capture session's,
    /// or simulate mode's stand-in.
    private var elapsedSeconds: TimeInterval {
        session?.elapsedSeconds ?? simClock?.elapsedSeconds ?? 0
    }

    // Menu-bar controls, so the recording can be driven from the status item when the
    // floating bar is minimized.
    func stopFromMenu() { stopRecording() }
    /// Stop and deliver the recording as a looping animated GIF instead of an .mp4.
    func stopAsGIFFromMenu() { stopRecording(destination: .gif) }
    /// Stop, then open the trim panel on the finished file before it's final.
    func stopAndTrimFromMenu() { stopRecording(destination: .trim) }
    /// Discard (with the usual confirm) — reachable from the menu and the ⌥-record
    /// hotkey, since Esc only works while the floating bar is visible and key.
    func discardFromMenu() { discardRecording() }
    /// Fires with `true` while a stopped recording converts to GIF, `false` when the
    /// conversion ends — drives the menu-bar "GIF…" status so a long conversion
    /// doesn't look like the app went silent.
    var onGIFExportUpdate: ((Bool) -> Void)?
    func togglePauseFromMenu() { togglePause() }

    /// Whether this recording can draw on screen. Region and whole-screen targets can — the
    /// overlay is composited into the display capture — but a single-window target cannot:
    /// its content filter captures nothing but that window, so strokes would be invisible in
    /// the video. The hotkey, bar tile and menu items are all gated on this.
    var canDraw: Bool { drawOverlay != nil }
    /// Whether draw mode is on right now (drives the menu title and the bar's pencil tile).
    var isDrawModeOn: Bool { drawOverlay?.isActive == true }
    /// Whether any strokes are on screen — the menu's Clear item appears only then.
    var hasDrawings: Bool { drawOverlay?.hasStrokes == true }
    /// Turn drawing on/off. Reached from the draw hotkey, the bar's pencil, and the menu.
    func toggleDrawFromMenu() { drawOverlay?.toggle() }

    /// Whether this recording can zoom. Region and whole-screen targets can; a window target
    /// has no fixed display rect to map the cursor into, so it cannot.
    var canZoom: Bool { zoomTargetIsRegion }
    /// Whether zoom is engaged right now (drives the menu title and the bar's magnifier).
    var isZoomed: Bool { zoomEngineInUse?.isZoomed == true }

    /// The engine driving this recording — the session's in a real recording, the
    /// controller's own in simulate mode.
    private var zoomEngineInUse: RecordZoomEngine? { session?.zoomEngine ?? simZoomEngine }

    /// Toggle zoom, anchored on the cursor's position at this instant.
    func toggleZoomFromMenu() {
        guard let engine = zoomEngineInUse else { return }
        engine.toggle()
        // Simulate mode has no frames to advance the engine, so the ticker does it there.
        startZoomTicker(advance: session == nil)
        let zoomed = engine.isZoomed
        bar?.setZoomActive(zoomed)
        // The bar starts minimized by default, so without this a hotkey press would have no
        // acknowledgement until the viewport outline caught up.
        BrandToast.show(zoomed
            ? String(format: L("Zoom %@"), RecordZoomEngine.label(forFactor: Settings.shared.videoZoomFactor.factor))
            : L("Zoom off"))
    }

    /// The zoom factor in effect, for the menu-bar indicator. 1 when not zoomed.
    var zoomLevelInEffect: CGFloat { zoomEngineInUse?.currentZoomLevel ?? 1 }

    /// Show and move the viewport indicator while zoom is active, then stop once the camera
    /// has fully eased back out (so an idle recording pays nothing).
    private func startZoomTicker(advance: Bool) {
        guard zoomTicker == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in
            guard let self, let engine = self.zoomEngineInUse else { return }
            if advance { _ = engine.advanceAndViewport() }
            let level = engine.currentZoomLevel
            // Stop only once the ease has fully returned to 1x. Keying this off a nil
            // viewport instead would kill the indicator in the gap before the first frame
            // arrives (toggling during the countdown, say) while the engine stayed zoomed.
            if !engine.isZoomed && level <= 1.001 {
                self.zoomIndicator?.hide()
                self.zoomTicker?.cancel()
                self.zoomTicker = nil
                self.bar?.setZoomActive(false)
                return
            }
            if let rect = engine.latestIndicatorRect() {
                self.zoomIndicator?.show(rect: rect, factor: level)
            }
        }
        t.resume()
        zoomTicker = t
    }
    func clearDrawingsFromMenu() { drawOverlay?.clear() }
    /// Hide/show the floating record bar without ending the recording.
    func setBarHidden(_ hidden: Bool) { bar?.setVisible(!hidden) }
    /// Whether the bar is currently hidden (minimized to the menu bar).
    var isBarHidden: Bool { bar?.isVisible == false }

    /// Begin a new recording: show the selection overlay on every screen.
    /// No-op if a recording is already in progress, or the annotation editor
    /// is open (its full-screen dim backdrop and the recording overlay would
    /// otherwise fight for the same screen).
    func begin() {
        guard !isRecording else { return }
        guard overlays.isEmpty else { return }   // a second press must not stack a set
        // Covers an open editor, a screenshot selection already on screen, and a capture
        // still in flight: two overlay sets at the same `.screenSaver` level leave the
        // lower one stranded on screen once the upper one completes.
        guard !ScreenshotController.shared.isBusy else { return }
        // Simulate mode intentionally bypasses the permission wall rather than faking a
        // grant: being usable *while the grant is pending* is the whole reason it exists
        // (see `Settings.simulateRecording`). Snapshotted here so the rest of the flow
        // reads one consistent mode.
        isSimulating = Settings.shared.simulateRecording
        guard isSimulating || ScreenRecordingPermission.isGranted else {
            // Offer simulate mode right here rather than leaving a dead end: on a managed
            // Mac the grant may be pending for days. Re-entering `begin()` async (not from
            // inside this guard) keeps overlay creation out of the modal alert's frame.
            ScreenRecordingPermission.handleDenied(simulateFallback: { [weak self] in
                DispatchQueue.main.async { self?.begin() }
            })
            return
        }
        AppPanels.closeAll()   // no app panel should sit under (or in) the recording
        // Warm up ScreenCaptureKit's content enumeration while the user drags their
        // region: `SCShareableContent.current` costs 0.5–2 s (worse with more
        // displays/windows), and paying it at session start is why the recording
        // timer used to sit at 0:00 after Stop was armed. Skipped when simulating: the
        // enumeration needs the very grant simulate mode works without, and no session
        // is created to consume it.
        if !isSimulating {
            contentPrefetch = Task { try? await SCShareableContent.current }
        }
        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        // Bring the app forward so the overlay can hold keyboard focus (Esc/Space,
        // Esc/Return to stop) — handed back to whatever was frontmost once recording
        // actually starts, see `appToRestore`.
        let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        appToRestore = frontmostID == Bundle.main.bundleIdentifier ? nil : frontmostID
        NSApp.activate(ignoringOtherApps: true)
        let coordinator = OverlayCoordinator()
        let last = Settings.shared.lastRegion
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen, coordinator: coordinator,
                                    allowsWindowMode: true, allowsFullScreenMode: true, recording: true,
                                    previousRect: screen.displayID == last?.displayID ? last?.rect : nil)
            win.onComplete = { [weak self] rect in
                if let id = screen.displayID { Settings.shared.lastRegion = (rect, id) }
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
                win.claimKeyboard()
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
        // See `dismissOverlays` — `orderOut` alone can leave a `.screenSaver`-level
        // window fully on screen after this returns (window-server transaction race,
        // confirmed on a secondary display); `close()` a tick later unconditionally
        // tears down its surface instead of trusting the soft hide.
        let stale = dimWindows
        dimWindows.forEach { $0.orderOut(nil) }
        dimWindows.removeAll()
        DispatchQueue.main.async { stale.forEach { $0.close() } }
    }

    private func dismissOverlays() {
        // `orderOut` occasionally leaves a `.screenSaver`-level, `.canJoinAllSpaces`
        // overlay window fully on screen even after this method returns and Swift's
        // own reference is dropped — confirmed via `CGWindowListCopyWindowInfo` on a
        // secondary display: a stranded, invisible, click-eating window over
        // everything below it that reads as the whole app freezing. `close()` one
        // runloop tick later (never inline — this can run from that very window's
        // own mouseUp) unconditionally tears down its window-server surface.
        let stale = overlays
        // Drop the shared coordinator's event monitor here rather than leaving it to
        // `deinit` — see `OverlayCoordinator.init` for why waiting leaked one monitor
        // per capture.
        stale.first?.coordinator.stopMonitoring()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        DispatchQueue.main.async { stale.forEach { $0.close() } }
        // Put the pointer back to the plain arrow so the overlay's capture cursor isn't left
        // showing (and isn't baked into the first recorded frames). See
        // `ScreenshotController.forcePointerReset` for why this both `.set()`s and briefly
        // puts up a window with a cursor rect.
        ScreenshotController.forcePointerReset()
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
                        // Non-modal: this runs from the permission callback, and a
                        // nested runModal from there can wedge the main run loop.
                        BrandAlert(title: L("Microphone access denied"),
                                   message: L("Recording will continue without mic audio."),
                                   titles: ["OK"], primary: 0, cancel: 0,
                                   icon: "mic.slash").present { _ in
                            self?.startRecording(target: target, barScreen: barScreen, audioSource: effective)
                        }
                        return
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

        // Optional 3/5/10 s countdown over the picked region — time to set the scene
        // up before frames start landing in the file.
        let countdown = Settings.shared.videoCountdown.rawValue
        if countdown > 0 {
            let rect: CGRect
            if case let .region(r, _) = target { rect = r }
            else if case let .window(id) = target, let r = Self.windowGlobalFrame(id) { rect = r }
            else { rect = barScreen.frame }
            RecordCountdownWindow.run(seconds: countdown, over: rect) { [weak self] in
                self?.reallyStartRecording(target: target, barScreen: barScreen, audioSource: audioSource)
            }
            return
        }
        reallyStartRecording(target: target, barScreen: barScreen, audioSource: audioSource)
    }

    private func reallyStartRecording(target: VideoRecordSession.Target, barScreen: NSScreen, audioSource: VideoAudioSource) {
        // Selection is done — yield activation back to whatever the user was in before
        // the hotkey. Keeping m_capture "active" for the whole recording (bar minimized,
        // nothing else visible) forced an extra activation click on every app switch.
        if let bundleID = appToRestore { NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID) }
        appToRestore = nil

        let qualityLetter: String
        switch Settings.shared.videoQuality {
        case .high:   qualityLetter = "H"
        case .medium: qualityLetter = "M"
        case .low:    qualityLetter = "L"
        }

        // Only a display-backed target can show drawings in the video (see `canDraw`), so
        // the bar's pencil tile is present only for those.
        let targetCanDraw: Bool
        if case .region = target { targetCanDraw = true } else { targetCanDraw = false }
        // Zoom needs a fixed display rect to map the cursor into — same constraint as drawing.
        zoomTargetIsRegion = targetCanDraw

        // Phase 2a — create/position the bar FIRST so its windowNumber is available
        // before SCStream begins. By default it starts minimized to the menu bar (the
        // timer + stop/pause live in the status item); Settings → Video toggles that.
        let recordBar = VideoRecordBar(quality: qualityLetter, simulated: isSimulating,
                                       canDraw: targetCanDraw, canZoom: targetCanDraw)
        if Settings.shared.videoStartBarMinimized {
            recordBar.prepare(near: barScreen)
        } else {
            recordBar.show(near: barScreen)
        }
        bar = recordBar

        // Phase 2b′ — darken everything outside what's being recorded so the captured
        // bounds are unmistakable, for region, whole-screen and window targets alike. The
        // dim windows are excluded from the region/display capture below; a window filter
        // already captures only the target window, so they never reach that video.
        // The indicator must exist before the stream starts to be excludable at all (the
        // filter's exclusion list is resolved once, in `VideoRecordSession.start()`). Created
        // hidden; the ticker reveals it when zoom engages.
        if case .region = target {
            let indicator = ZoomIndicatorWindow()
            zoomIndicator = indicator
        }
        var excluded = [CGWindowID(recordBar.windowNumber)]
        if let indicator = zoomIndicator { excluded.append(CGWindowID(indicator.windowNumber)) }
        switch target {
        case let .region(rect, _):
            excluded += showDim(forRegion: rect)
        case let .window(windowID):
            if let rect = Self.windowGlobalFrame(windowID) { showDim(forRegion: rect) }
        }

        // Phase 2c — create the capture session with the bar (and dim) excluded from
        // capture. (Window targets ignore the exclusion list — a window filter never
        // captures the bar.) Simulate mode stops deliberately short of this: no session,
        // no output file, just a wall-clock stand-in driving the same HUD.
        if isSimulating {
            simClock = SimulatedRecordingClock()
            // No capture session exists to own an engine, so build one here purely to drive
            // the indicator: it makes the shortcut, the easing and the cursor follow testable
            // while the Screen Recording grant is pending. `backingScaleFactor` stands in for
            // SCK's authoritative pixels-per-point, which only a real stream can provide.
            if case let .region(rect, screen) = target {
                simZoomEngine = RecordZoomEngine(region: rect,
                                                 pixelScale: screen.backingScaleFactor,
                                                 factor: Settings.shared.videoZoomFactor.factor)
            }
        } else {
            let url = videoURL()
            currentURL = url
            let recordSession = VideoRecordSession(
                target: target,
                quality: Settings.shared.videoQuality,
                audioSource: audioSource,
                outputURL: url,
                excludedWindowIDs: excluded,
                contentPrefetch: contentPrefetch,
                zoomFactor: targetCanDraw ? Settings.shared.videoZoomFactor.factor : nil
            )
            session = recordSession
            recordSession.onUnexpectedStop = { [weak self] reason in self?.handleUnexpectedStop(reason) }
        }
        contentPrefetch = nil

        // Phase 2c′ — the on-screen drawing overlay (⌃⇧D), for display-backed targets only.
        // Created hidden and deliberately NOT added to `excluded`: being captured is the
        // whole point, exactly like `ClickVisualizer`'s ripples. Windows created after the
        // stream starts are captured by default, so nothing more is needed.
        if case let .region(rect, _) = target {
            let overlay = RecordDrawOverlay(region: rect)
            overlay.onModeChange = { [weak self] on in self?.bar?.setDrawActive(on) }
            drawOverlay = overlay
        }

        // Phase 2d — wire bar callbacks.
        recordBar.onStop = { [weak self] in self?.stopRecording() }
        recordBar.onPauseResume = { [weak self] in self?.togglePause() }
        recordBar.onDiscard = { [weak self] in self?.discardRecording() }
        recordBar.onMinimize = { [weak self] in self?.setBarHidden(true) }
        recordBar.onToggleDraw = { [weak self] in self?.toggleDrawFromMenu() }
        recordBar.onToggleZoom = { [weak self] in self?.toggleZoomFromMenu() }

        if Settings.shared.videoShowClicks { clickVisualizer.start() }

        // Phase 2e — start capture, then start the UI ticker. A short delay first lets
        // the compositor actually clear the just-dismissed selection overlay (its mode
        // banner included): `orderOut`/`close` return before the screen repaints, so
        // starting the stream immediately after can catch that banner fading out in the
        // first captured frame(s) — the same latency `ScreenshotController` already
        // works around with its own pre-grab delay.
        // Handle start() errors explicitly: a silent failure leaves the bar running
        // with a 0 KB file and no feedback to the user.
        if let recordSession = session {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task {
                    do {
                        try await recordSession.start()
                    } catch {
                        await MainActor.run { self.handleStartError(error) }
                    }
                }
            }
        }
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        // 4 Hz, not 1 Hz: the display truncates to whole seconds, so a 1 s tick that
        // isn't phase-aligned with the capture start leaves the counter stuck at
        // 0:00 for up to two full seconds — reading as "recording hasn't started".
        // Ticking at 250 ms flips each second within a quarter second of real time.
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            let elapsed = self.elapsedSeconds
            // A simulated recording writes no file, so the size stays at 0 — the bar
            // shows "~0 KB", which is the honest reading.
            self.bar?.update(elapsed: elapsed,
                             fileSize: self.session?.estimatedFileSize ?? 0,
                             isPaused: self.isPaused)
            self.onRecordingUIUpdate?(true, elapsed, self.isPaused)
        }
        t.resume()
        updateTimer = t
        onRecordingUIUpdate?(true, 0, isPaused)   // show the indicator immediately, not after 1 s
    }

    /// Where a stopped recording goes: saved as-is, converted to GIF, or into the
    /// trim panel first.
    private enum StopDestination { case movie, gif, trim }

    /// Tear down everything the recording put on screen: the update tick, the floating
    /// bar, the region dim, the click ripples and the menu-bar indicator. Every exit path
    /// (stop / discard / unexpected stop / start failure / termination) funnels through
    /// this, so none of them can forget a piece and strand a window on screen.
    ///
    /// - Parameter terminating: The process is about to exit, so skip teardown that is only
    ///   cosmetic and needs later run-loop turns to complete (see `RecordDrawOverlay.tearDown`).
    private func teardownRecordingUI(terminating: Bool = false) {
        updateTimer?.cancel()
        updateTimer = nil
        bar?.close()
        bar = nil
        drawOverlay?.tearDown(terminating: terminating)
        drawOverlay = nil
        zoomTicker?.cancel()
        zoomTicker = nil
        zoomIndicator?.tearDown()
        zoomIndicator = nil
        simZoomEngine = nil
        zoomTargetIsRegion = false
        dismissDim()
        clearRecordingUI()
    }

    /// Clear the simulated-recording state. Separate from `teardownRecordingUI` because
    /// the real path clears `session`/`currentURL` at its own points in the stop sequence.
    private func clearSimulatedState() {
        simClock = nil
        isSimulating = false
        isPaused = false
    }

    private func stopRecording(destination: StopDestination = .movie) {
        // Simulate mode captured nothing, so there is no file to finalize, convert or
        // trim — tear the HUD down and say so plainly, rather than opening History onto
        // an unchanged folder and letting it read as a lost recording.
        if isSimulatedRecording {
            teardownRecordingUI()
            clearSimulatedState()
            BrandToast.show(L("Simulated recording — nothing was saved"))
            return
        }
        teardownRecordingUI()
        guard let session = session, let url = currentURL else { return }
        self.session = nil
        self.isPaused = false
        self.currentURL = nil
        Task {
            await session.stop()
            // Only celebrate/reveal a file that actually made it to disk — a
            // failed writer leaves nothing to show.
            guard FileManager.default.fileExists(atPath: url.path) else {
                await MainActor.run {
                    BrandAlert(title: L("Recording not saved"),
                               message: L("Check that the save folder has free space."),
                               titles: ["OK"], primary: 0, cancel: 0,
                               icon: "exclamationmark.triangle").present()
                }
                return
            }
            if destination == .trim {
                await MainActor.run { TrimWindowController.show(url: url) }
                return   // the trim panel owns the reveal (or keeps the file as-is)
            }
            if destination == .gif {
                await MainActor.run { self.onGIFExportUpdate?(true) }
                let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
                let ok = await VideoToGIF.convert(mp4: url, to: gifURL)
                await MainActor.run { self.onGIFExportUpdate?(false) }
                if ok {
                    // The GIF is the deliverable the user asked for; the intermediate
                    // .mp4 would just be clutter next to it.
                    try? FileManager.default.removeItem(at: url)
                } else {
                    await MainActor.run {
                        BrandAlert(title: L("Unable to convert to GIF"),
                                   message: L("The recording was kept as an .mp4."),
                                   titles: ["OK"], primary: 0, cancel: 0,
                                   icon: "exclamationmark.triangle").present()
                    }
                }
            }
            await MainActor.run {
                if Settings.shared.playSound { NSSound(named: "Grab")?.play() }
                // The in-app History panel (newest first, with copy/trim actions)
                // beats dumping the user into a Finder window.
                HistoryWindowController.shared.show()
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
        // Nothing was captured in simulate mode, so there is no file to finalize — just
        // clear the HUD so the app doesn't exit leaving overlay windows behind.
        if isSimulatedRecording {
            teardownRecordingUI(terminating: true)
            clearSimulatedState()
            return
        }
        guard let session = session, let url = currentURL else { return }
        teardownRecordingUI(terminating: true)
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
        guard isRecording else { return }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = BrandAlert(title: L("Discard recording?"),
                                 message: L("This recording will be deleted."),
                                 titles: [L("Discard"), L("Keep Recording")],
                                 primary: 1, cancel: 1, icon: "trash", destructive: [0]).runModal()
        guard confirm == 0 else { return }
        // Simulate mode has no partial file to delete — the confirm is still shown so the
        // gesture behaves identically to a real discard while testing.
        if isSimulatedRecording {
            teardownRecordingUI()
            clearSimulatedState()
            return
        }
        guard let session = session, let url = currentURL else { return }
        teardownRecordingUI()
        self.session = nil; self.currentURL = nil; self.isPaused = false
        Task {
            await session.stop()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func togglePause() {
        guard isRecording else { return }
        if isPaused {
            session?.resume(); simClock?.resume()
            isPaused = false
        } else {
            session?.pause(); simClock?.pause()
            isPaused = true
        }
        onRecordingUIUpdate?(true, elapsedSeconds, isPaused)   // reflect pause in the menu-bar icon at once
    }

    /// Called on the main thread when the capture stream stops unexpectedly mid-record
    /// (permission revoked, display unplugged, disk trouble). Finalizes whatever was
    /// captured, tears down the HUD, and tells the user — rather than the bar ticking
    /// on against a dead stream.
    private func handleUnexpectedStop(_ reason: String) {
        guard let session = session else { return }
        teardownRecordingUI()
        let url = currentURL
        self.session = nil; self.currentURL = nil; self.isPaused = false
        Task {
            await session.stop()   // flush whatever frames made it, so the file is playable
            await MainActor.run {
                let saved = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                let tail = saved ? L(" The partial recording was saved.") : ""
                BrandAlert(title: L("Recording stopped"),
                           message: L("The recording ended unexpectedly.") + tail,
                           titles: ["OK"], primary: 0, cancel: 0,
                           icon: "exclamationmark.triangle").present()
                if saved, let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    /// Called on the main thread when `start()` throws. Tears down the bar and
    /// session so the controller is back in the idle state, then tells the user why.
    private func handleStartError(_ error: Error) {
        teardownRecordingUI()
        session = nil; currentURL = nil; isPaused = false

        let isPermission = !ScreenRecordingPermission.isGranted
        if isPermission {
            ScreenRecordingPermission.handleDenied()
        } else {
            BrandAlert(
                title: L("Recording failed to start"),
                message: L("If the Screen Recording permission was reset, re-approve it in System Settings and try again."),
                titles: ["OK"], primary: 0, cancel: 0,
                icon: "exclamationmark.triangle"
            ).present()
        }
    }

    /// Produces a timestamped `.mp4` URL in the (validated, uniquified) save
    /// directory, independent of the image-format setting in `Settings`.
    private func videoURL() -> URL { Settings.shared.fileURL(ext: "mp4") }
}

/// Wall-clock stand-in for `VideoRecordSession` while simulate mode is on
/// (Settings → Video → Simulate recording). It supplies only what the HUD reads — the
/// elapsed time, with the same "paused time doesn't count" semantics as the real session's
/// `elapsedSeconds` — so the timer, menu-bar indicator and pause controls behave exactly
/// as they do during a real recording even though nothing is being captured.
final class SimulatedRecordingClock {
    private let start = CACurrentMediaTime()
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: TimeInterval = 0
    private var isPaused = false

    var elapsedSeconds: TimeInterval {
        var paused = pausedTotal
        if isPaused { paused += CACurrentMediaTime() - pauseStart }
        return CACurrentMediaTime() - start - paused
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pauseStart = CACurrentMediaTime()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        pausedTotal += CACurrentMediaTime() - pauseStart
    }
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
        // `dismissDim()` calls `close()` while the controller still holds a
        // reference; AppKit's default of `true` would over-release and crash.
        isReleasedWhenClosed = false
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

/// A 3-2-1 countdown floated over the region about to be recorded (Settings →
/// Video → Countdown), giving the user a beat to set the scene up after picking
/// the region. Self-retained for its short life; always calls `completion`.
@available(macOS 14, *)
final class RecordCountdownWindow {
    private static var active: RecordCountdownWindow?
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")

    static func run(seconds: Int, over rect: CGRect, completion: @escaping () -> Void) {
        active = RecordCountdownWindow(rect: rect)
        active?.tick(seconds, completion: completion)
    }

    private init(rect: CGRect) {
        let side: CGFloat = 120
        let frame = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.surfaceBase.withAlphaComponent(0.85).cgColor
        content.layer?.cornerRadius = Theme.radiusSmall
        label.font = Theme.font(64, .bold)
        label.textColor = Theme.textPrimary
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (side - 80) / 2, width: side, height: 80)
        content.addSubview(label)
        window.contentView = content
        window.orderFrontRegardless()
    }

    private func tick(_ remaining: Int, completion: @escaping () -> Void) {
        guard remaining > 0 else {
            window.orderOut(nil)
            Self.active = nil
            completion()
            return
        }
        label.stringValue = "\(remaining)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.tick(remaining - 1, completion: completion)
        }
    }
}
