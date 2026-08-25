// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Shows the dim selection overlay, grabs the chosen region, and opens the
/// in-place editor (with a dimmed live-desktop backdrop).
final class ScreenshotController {
    static let shared = ScreenshotController()
    private var overlays: [OverlayWindow] = []

    /// True while the drag-to-select overlay is on screen. `Updater` checks this so a
    /// background-update alert never opens underneath the full-screen overlays.
    var isSelecting: Bool { !overlays.isEmpty }

    /// A display appearing or vanishing mid-selection leaves overlays sized/positioned
    /// for a screen layout that no longer exists (or covering a gone display) — tear
    /// the selection down rather than leaving stale dim windows up.
    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            // The warm snapshot describes a display layout that no longer exists.
            ScreenshotController.warmUp()
            guard let self, !self.overlays.isEmpty else { return }
            self.contentPrefetch = nil   // enumerated for a layout that no longer exists
            self.dismiss()
        }
    }

    /// Keep a `SCShareableContent` snapshot ready ahead of the next capture.
    ///
    /// The freeze-frame grab in `begin()` runs *before* the overlay appears, so its cost
    /// is visible to the user as latency on the hotkey — and enumerating shareable
    /// content alone costs 0.5–2 s. Refreshing it in the background (at launch, after a
    /// display change, and after every capture) leaves only the ~tens of milliseconds of
    /// `SCScreenshotManager.captureImage` on the critical path.
    static func warmUp() {
        guard ScreenRecordingPermission.isGranted else { return }
        warmContent = Task { try? await SCShareableContent.current }
    }

    private static var warmContent: Task<SCShareableContent?, Never>?

    /// True from the moment a capture starts (overlay shown, or a quick-screen
    /// grab kicked off) until it's fully handed off to `deliver`, plus for as
    /// long as an editor window from a prior capture is still open. `overlays`
    /// alone isn't enough: it's cleared by `dismiss()` well before the async
    /// ScreenCaptureKit grab and `deliver` finish, which left a window where a
    /// second hotkey press/menu click could start an independent overlay set
    /// (or a second `EditorWindowController`) while the first was still in flight.
    private var capturePending = false
    /// Monotonic token for the failsafe below — a stale failsafe from an earlier
    /// capture must never clear a newer capture's pending flag.
    private var pendingGeneration = 0

    /// Arm `capturePending` with a hard failsafe: whatever happens to the capture
    /// task, the flag clears after 15 s (the SCK grab itself is bounded to 10 s), so
    /// `isBusy` can never permanently swallow the hotkeys — a wedged capture must
    /// degrade to one lost shot, never to a dead app.
    private func beginPendingCapture() {
        capturePending = true
        pendingGeneration += 1
        let generation = pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.pendingGeneration == generation, self.capturePending else { return }
            self.capturePending = false
        }
    }

    /// `SCShareableContent` warm-up kicked off when the selection overlay opens —
    /// enumerating shareable content costs 0.5–2 s (worse with more displays/windows,
    /// and it can stall outright after a display-configuration change). Paying that
    /// *after* mouse-up left a multi-second dead window between the overlay vanishing
    /// and the editor appearing that read as a freeze; consuming a prefetch makes the
    /// post-drag grab near-instant, same as the record flow.
    private var contentPrefetch: Task<SCShareableContent?, Never>?

    var isBusy: Bool {
        if !overlays.isEmpty || capturePending || EditorWindowController.hasOpenWindows { return true }
        // The record flow owns an independent overlay set. Two sets stacked at the same
        // `.screenSaver` level leave the lower one on screen after the upper one
        // completes — a dim, pristine overlay sitting over the editor that reads as a
        // freeze. Only one selection surface may exist at a time, either flow.
        if #available(macOS 14, *), VideoRecordController.shared.isSelecting { return true }
        return false
    }

    /// The still frame of each display, grabbed the instant the capture starts and used
    /// as the selection overlay's backdrop — see `begin()`. Keyed by display ID.
    private var frozen: [CGDirectDisplayID: (cg: CGImage, scale: CGFloat)] = [:]

    /// Freeze every display, *then* show the selection overlay over those stills.
    ///
    /// Selecting on a live desktop can only ever capture what survives the overlay:
    /// `NSApp.activate` below is what gives the overlay its keyboard, and activating
    /// tears down whatever transient UI the frontmost app was showing — a tooltip, a
    /// hover menu, a popover. Grabbing the pixels *before* activation means that state
    /// is already in hand and the user can take as long as they like framing it. It also
    /// removes the need to keep the selection chrome out of a later live grab: the frame
    /// predates every overlay window.
    func begin() {
        if isBusy { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }
        AppPanels.closeAll()   // no app panel should sit under (or in) the shot

        beginPendingCapture()
        // The pointer is part of the frozen state the user is trying to keep (it's what
        // is producing the tooltip), so the setting applies to every mode here — unlike
        // a live grab, nothing of ours can bake in.
        let showsCursor = Settings.shared.captureCursor
        let displays: [(id: CGDirectDisplayID, size: CGSize)] = NSScreen.screens.compactMap {
            guard let id = $0.displayID else { return nil }
            return (id, $0.frame.size)
        }
        Task {
            var stills: [CGDirectDisplayID: (cg: CGImage, scale: CGFloat)] = [:]
            for display in displays {
                if let r = await ScreenshotController.captureRegion(
                    displayID: display.id,
                    sourceRect: CGRect(origin: .zero, size: display.size),
                    showsCursor: showsCursor,
                    prefetched: ScreenshotController.warmContent) {
                    stills[display.id] = r
                }
            }
            let captured = stills   // immutable copy: the closure below outlives the loop
            await MainActor.run { self.presentOverlays(stills: captured) }
        }
    }

    /// Put up one overlay per display over the frozen stills. A display whose still is
    /// missing (the grab failed or timed out) falls back to the live dim overlay and a
    /// fresh grab on mouse-up, so a failed freeze costs the tooltip, never the capture.
    private func presentOverlays(stills: [CGDirectDisplayID: (cg: CGImage, scale: CGFloat)]) {
        capturePending = false
        // A second capture can only have started if this one was cancelled or superseded
        // while the stills were in flight; don't stack a second overlay set on it.
        if isBusy { return }
        frozen = stills

        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        // Bring the app forward so the overlay gets keyboard focus (Esc to cancel,
        // Space to toggle mode).
        NSApp.activate(ignoringOtherApps: true)
        let coordinator = OverlayCoordinator()
        let last = Settings.shared.lastRegion
        for screen in NSScreen.screens {
            let still = screen.displayID.flatMap { frozen[$0] }
            let win = OverlayWindow(screen: screen, coordinator: coordinator,
                                    previousRect: screen.displayID == last?.displayID ? last?.rect : nil,
                                    frozen: still.map { ScreenshotController.nsImage(from: $0.cg) })
            win.onComplete = { [weak self] viewRect in
                self?.finish(viewRect: viewRect, screen: screen, showsCursor: Settings.shared.captureCursor)
            }
            win.onCompleteScreen = { [weak self] in
                // Whole-screen grab: never draw the cursor — it's only ever the tool's
                // capture badge here, which would otherwise bake into the shot.
                self?.finish(viewRect: CGRect(origin: .zero, size: screen.frame.size),
                             screen: screen, showsCursor: false)
            }
            win.onCompleteWindow = { [weak self] windowID in self?.finishWindow(windowID: windowID) }
            win.onCancel = { [weak self] in
                self?.contentPrefetch = nil
                self?.frozen = [:]
                self?.dismiss()
            }
            overlays.append(win)
            if screen == keyScreen {
                win.claimKeyboard()
            } else {
                win.orderFront(nil)
            }
        }
        // The freeze grab a moment ago already paid for a snapshot; window-pick mode
        // reuses it and refreshes itself when it doesn't know the picked window.
        contentPrefetch = ScreenshotController.warmContent
    }

    /// The system screenshot shutter sound, played when the user enables it
    /// (the in-process capture is otherwise silent).
    private static func playCaptureSoundIfEnabled() {
        guard Settings.shared.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    private func dismiss() {
        // `orderOut` alone occasionally leaves a `.screenSaver`-level,
        // `.canJoinAllSpaces` overlay window fully on screen (confirmed via
        // `CGWindowListCopyWindowInfo` — window server transaction races with the
        // `NSApp.activate` a moment earlier in `begin()`, especially on a secondary
        // display) even after this method returns and Swift's own reference is
        // dropped: a stranded, invisible, click-eating window over everything below
        // it that reads as the whole app freezing. `orderOut` first for the
        // instant visual hide, then `close()` one runloop tick later (never inline —
        // this can run from that very window's own mouseUp) to unconditionally tear
        // down its window-server surface rather than trust the soft hide.
        let stale = overlays
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        DispatchQueue.main.async { stale.forEach { $0.close() } }
        ScreenshotController.forcePointerReset()
    }

    /// Put the pointer back to the plain arrow immediately: the overlay's capture cursor
    /// otherwise lingers (nothing moves the mouse in the brief pre-capture delay) and gets
    /// baked into the shot when `showsCursor` is on.
    ///
    /// This used to install `.pointingHand` "matching the Window/Screen pick modes' cursor",
    /// which stopped being true once those modes moved to the brand camera / video glyph — so
    /// after a window or screen capture the camera stayed on screen until the pointer next
    /// moved, sometimes for seconds. `.arrow` is also simply the right thing to bake into a
    /// screenshot. The explicit `.set()` matters as much as the window: the reset window only
    /// wins while it is up, and when it closes the *app's* current cursor is whatever was last
    /// `.set()` — the camera — so without clearing that the old pointer comes straight back.
    ///
    /// `.set()`, hide/unhide, and `CGWarpMouseCursorPosition` all failed to force a
    /// redraw here (confirmed: only an actual click cleared it) — those either need a
    /// real hardware input event or, for the warp, Accessibility permission this app
    /// doesn't request. Instead this briefly puts up another real window with a cursor
    /// rect over the whole screen — the exact mechanism that successfully drew the
    /// crosshair in the first place — so the window server has to re-evaluate and draw
    /// the new cursor, then removes it a beat later once that's taken effect.
    /// Wait until no mouse button is held, then do the reset on a later run-loop turn.
    ///
    /// This is why the reset kept failing for Window and Screen while Region was fine.
    /// **Screen mode commits on `mouseDown`** (`SelectionView.mouseDown`), so every reset ran
    /// with the button still held — and while a button is down the window server treats
    /// pointer motion as a drag and suppresses cursor re-evaluation outright, so the warp,
    /// the `.set()` and the reset window's rect were all discarded. By the time the user let
    /// go, every attempt had already been made. Window commits on `mouseUp` but reset
    /// *synchronously inside that event's dispatch*, before AppKit re-evaluates cursor rects.
    /// Region commits on `mouseUp` at the end of a real drag, with fresh motion already in
    /// the pipeline — which is exactly why it alone worked.
    static func forcePointerReset(attempt: Int = 0) {
        // ~1 s of retries; if a button is somehow held past that, stop rather than spin.
        guard attempt < 33 else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                forcePointerReset(attempt: attempt + 1)
            }
            return
        }
        // Never inline: let the event that triggered this finish dispatching first.
        DispatchQueue.main.async { performPointerReset() }
    }

    private static func performPointerReset() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        redrawPointer(on: screen)
        let win = CursorResetWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // The deferred block below `close()`s while still holding `win`; AppKit's
        // default of `true` would over-release and crash.
        win.isReleasedWhenClosed = false
        // Hit-testable (not click-through) and briefly key — cursor-rect ownership is
        // tied to actually being the front, hit-testable window under the pointer, same
        // as the real capture overlay it's replacing. It's up for only ~50ms.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = CursorResetView(frame: NSRect(origin: .zero, size: screen.frame.size))
        win.contentView = v
        win.makeKeyAndOrderFront(nil)
        // 0.05 s was not enough of a window for the server to re-evaluate; re-assert while
        // the reset window is still up, then once more as it goes away — closing it hands
        // cursor duty back to whatever is underneath, which may not ask for an update until
        // the pointer moves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            ScreenshotController.redrawPointer(on: screen)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ScreenshotController.redrawPointer(on: screen)
            // `close()`, not just `orderOut` — see `dismiss()`'s note on the same
            // window-server race; this window briefly holds key status too, which
            // makes an incomplete hide here the worst case (a full-screen, currently
            // key, click-eating ghost). It has no event handlers of its own, so
            // closing it directly from this later tick is safe.
            win.close()
        }
    }

    /// Hand a fresh capture to the configured destination: the annotation editor
    /// (default), a direct save to the output folder, or the clipboard only.
    /// `captureScale` is the exact pixels-per-point density `image` was captured at —
    /// only the editor needs it, to size its live canvas without introducing rounding
    /// error (see `EditorWindowController.init`).
    static func deliver(_ image: NSImage, selectionRect: CGRect, screen: NSScreen, captureScale: CGFloat = 1) {
        switch Settings.shared.captureBehavior {
        case .editor:
            _ = EditorWindowController(image: image, selectionRect: selectionRect, screen: screen,
                                      captureScale: captureScale)
        case .save:
            saveToDisk(image)
            if Settings.shared.autoCopyOnSave { copyToPasteboard(image) }
        case .copy:
            copyToPasteboard(image)
        }
    }

    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func copyToPasteboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Encode in the configured format and write off the main thread. On failure —
    /// with no editor open in this "save straight to file" mode — alert the user so
    /// the capture isn't lost silently.
    private static func saveToDisk(_ image: NSImage) {
        guard let rep = bitmap(from: image) else { return }
        let fellBack = !Settings.shared.saveDirectoryAvailable
        let url = Settings.shared.fileURL()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Settings.shared.encode(rep).map { (try? $0.write(to: url)) != nil } ?? false
            DispatchQueue.main.async {
                if !ok {
                    BrandAlert(title: L("Unable to save the capture"),
                               message: L("Saving failed. Check your save folder in Settings → Output."),
                               titles: ["OK"], primary: 0, cancel: 0,
                               icon: "exclamationmark.triangle").present()
                } else if fellBack {
                    BrandAlert(title: L("Saved to the Desktop"),
                               message: L("The save folder was unavailable; the file was saved to the Desktop. Update it in Settings → Output."),
                               titles: ["OK"], primary: 0, cancel: 0,
                               icon: "folder.badge.questionmark").present()
                }
            }
        }
    }

    /// A nil capture means Screen Recording was revoked after launch (the pre-check
    /// in `begin()` catches the common case up front) or ScreenCaptureKit stalled
    /// past the 10 s bound — either way, tell the user rather than failing silently:
    /// a dropped shot with zero feedback reads as the app freezing.
    private static func handleEmptyCapture() {
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        BrandToast.show(L("Capture failed. Please try again."), on: screen)
    }

    /// Grab an on-screen region in-process with ScreenCaptureKit, rather than
    /// shelling out to `/usr/sbin/screencapture`.
    ///
    /// The old subprocess spawned a process per capture. On managed Macs,
    /// endpoint-security software gated each spawn and could stall the capture for
    /// *minutes*. Staying in-process avoids that, drops the temp-file round-trip,
    /// and lets ScreenCaptureKit draw the pointer natively. (`CGWindowListCreateImage`
    /// was obsoleted in macOS 15, so SCK is the only in-process route.)
    ///
    /// `sourceRect` is the region within the display in points, top-left origin. The
    /// output pixel size is `sourceRect × SCContentFilter.pointPixelScale` — SCK's own
    /// pixels-per-point for this display — so the grab is 1:1 native with no up/down-
    /// scaling on any display (plain 2×, fractional-HiDPI, or a 1× external alike).
    /// Returns the exact scale alongside the image: the editor needs this same
    /// authoritative value rather than re-deriving it from the selection rect (see
    /// `EditorWindowController.init`).
    /// Race an async ScreenCaptureKit operation against a deadline. `SCShareableContent`
    /// / `SCScreenshotManager` can stall indefinitely right after a display-configuration
    /// change (a monitor plugged/unplugged, display sleep). Without a bound, the awaiting
    /// caller never resumes, `capturePending` stays `true`, and every later hotkey press
    /// is silently swallowed by `isBusy` until relaunch — a permanent perceived freeze.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval, _ op: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func captureRegion(displayID: CGDirectDisplayID, sourceRect: CGRect,
                                      showsCursor: Bool,
                                      excluding windowIDs: [CGWindowID] = [],
                                      prefetched: Task<SCShareableContent?, Never>? = nil)
        async -> (cg: CGImage, scale: CGFloat)? {
        await withTimeout(seconds: 10) {
            await captureRegionUnbounded(displayID: displayID, sourceRect: sourceRect,
                                         showsCursor: showsCursor, excluding: windowIDs,
                                         prefetched: prefetched)
        }
    }

    private static func captureRegionUnbounded(displayID: CGDirectDisplayID, sourceRect: CGRect,
                                               showsCursor: Bool,
                                               excluding windowIDs: [CGWindowID],
                                               prefetched: Task<SCShareableContent?, Never>?)
        async -> (cg: CGImage, scale: CGFloat)? {
        do {
            // Consume the overlay-time prefetch when it knows this display; a stale
            // snapshot (display changed since the overlay opened) falls back to a
            // fresh fetch — still inside the caller's timeout.
            var content: SCShareableContent
            if let pre = await prefetched?.value,
               pre.displays.contains(where: { $0.displayID == displayID }) {
                content = pre
            } else {
                content = try await SCShareableContent.current
            }
            // Exclude our own overlay windows from the shot by ID. This — not the
            // short pre-grab delay — is what guarantees the dim/banner never bakes
            // into the capture: the prefetch made the grab fast enough to otherwise
            // catch the overlay's fade-out. Refresh once if the snapshot is missing
            // any of them (it predates windows created after it was kicked off).
            var excluded = content.windows.filter { windowIDs.contains(CGWindowID($0.windowID)) }
            if excluded.count < windowIDs.count {
                content = try await SCShareableContent.current
                excluded = content.windows.filter { windowIDs.contains(CGWindowID($0.windowID)) }
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            config.width = max(1, Int((sourceRect.width * scale).rounded()))
            config.height = max(1, Int((sourceRect.height * scale).rounded()))
            config.showsCursor = showsCursor
            config.captureResolution = .best
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (cg, scale)
        } catch {
            return nil
        }
    }

    /// Crop a frozen full-display still to `sourceRect` — display-local points with a
    /// top-left origin, the same convention `SCStreamConfiguration.sourceRect` uses — so
    /// a cropped still and a live grab of the same region produce identical pixels.
    /// Rounding matches the live path's, and the rect is clamped to the image so a
    /// selection touching the display edge can't fail on an out-of-bounds crop.
    private static func crop(_ cg: CGImage, to sourceRect: CGRect, scale: CGFloat) -> CGImage? {
        let px = CGRect(x: (sourceRect.minX * scale).rounded(),
                        y: (sourceRect.minY * scale).rounded(),
                        width: (sourceRect.width * scale).rounded(),
                        height: (sourceRect.height * scale).rounded())
        let clamped = px.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return cg.cropping(to: clamped)
    }

    /// Wrap a captured CGImage as a pixel-sized NSImage (scale 1), so the editor's
    /// display-scale math stays correct.
    private static func image(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Grab a single on-screen window in-process, following the same in-process
    /// ScreenCaptureKit path as `captureRegion` but with a window filter
    /// (`desktopIndependentWindow`) so occluding windows are excluded and only the
    /// target window's pixels are captured. Returns the image plus the window's AppKit
    /// global frame and hosting screen, which the editor uses to place its live canvas.
    private static func captureWindow(windowID: CGWindowID, showsCursor: Bool,
                                      prefetched: Task<SCShareableContent?, Never>? = nil)
        async -> (cg: CGImage, scale: CGFloat, globalRect: CGRect, screen: NSScreen)? {
        // Resolve the hosting NSScreen outside the timeout race: NSScreen is
        // explicitly non-Sendable, so it can't cross the task-group boundary.
        guard let r = await withTimeout(seconds: 10, {
            await captureWindowUnbounded(windowID: windowID, showsCursor: showsCursor,
                                         prefetched: prefetched)
        }) else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(r.globalRect) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return (r.cg, r.scale, r.globalRect, screen)
    }

    private static func captureWindowUnbounded(windowID: CGWindowID, showsCursor: Bool,
                                               prefetched: Task<SCShareableContent?, Never>?)
        async -> (cg: CGImage, scale: CGFloat, globalRect: CGRect)? {
        do {
            // The prefetch predates the pick — when it doesn't know this window
            // (opened after the overlay came up), refresh once before giving up.
            let content: SCShareableContent
            if let pre = await prefetched?.value,
               pre.windows.contains(where: { $0.windowID == windowID }) {
                content = pre
            } else {
                content = try await SCShareableContent.current
            }
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((scWindow.frame.width * scale).rounded()))
            config.height = max(1, Int((scWindow.frame.height * scale).rounded()))
            config.showsCursor = showsCursor
            config.captureResolution = .best
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // SCWindow.frame is CG global (top-left). Flip into AppKit space; the caller
            // picks the hosting screen for the editor backdrop.
            let appKit = WindowList.appKitRect(fromCG: scWindow.frame)
            return (cg, scale, appKit)
        } catch {
            return nil
        }
    }

    /// Window mode keeps the live grab rather than cropping the frozen still: SCK's
    /// `desktopIndependentWindow` filter returns the window's own pixels *unoccluded*,
    /// which a crop out of the composited still can't do.
    private func finishWindow(windowID: CGWindowID) {
        let prefetch = contentPrefetch
        contentPrefetch = nil
        frozen = [:]
        dismiss()
        beginPendingCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            ScreenshotController.playCaptureSoundIfEnabled()
            Task {
                // Never draw the cursor for a window grab — it's only ever the tool's
                // capture badge, which would otherwise bake into the shot.
                let result = await ScreenshotController.captureWindow(windowID: windowID, showsCursor: false,
                                                                      prefetched: prefetch)
                await MainActor.run {
                    defer { self.capturePending = false; ScreenshotController.warmUp() }
                    guard let result else { ScreenshotController.handleEmptyCapture(); return }
                    ScreenshotController.deliver(ScreenshotController.image(from: result.cg),
                                                selectionRect: result.globalRect, screen: result.screen,
                                                captureScale: result.scale)
                }
            }
        }
    }

    private func finish(viewRect: CGRect, screen: NSScreen, showsCursor: Bool) {
        // A real region drag (not whole-screen) becomes the re-offerable "last region".
        if viewRect.size != screen.frame.size, let id = screen.displayID {
            Settings.shared.lastRegion = (viewRect, id)
        }
        let global = CGRect(x: screen.frame.minX + viewRect.minX,
                            y: screen.frame.minY + viewRect.minY,
                            width: viewRect.width, height: viewRect.height)
        let prefetch = contentPrefetch
        contentPrefetch = nil
        // Snapshot the overlay window IDs before dismiss() drops them — only the live
        // fallback path needs them, to keep the selection chrome out of the shot.
        let overlayIDs = overlays.map { CGWindowID($0.windowNumber) }
        let still = screen.displayID.flatMap { frozen[$0] }
        frozen = [:]
        dismiss()
        guard global.width >= 3, global.height >= 3 else { return }
        guard let displayID = screen.displayID else { return }

        let sourceRect = CGRect(x: viewRect.minX,
                                y: screen.frame.height - viewRect.maxY,
                                width: viewRect.width, height: viewRect.height)

        // The common path: the pixels are already in hand, so crop and hand off with no
        // grab, no delay and no chance of the overlay's fade-out being caught in the shot.
        if let still, let cropped = ScreenshotController.crop(still.cg, to: sourceRect, scale: still.scale) {
            ScreenshotController.playCaptureSoundIfEnabled()
            ScreenshotController.deliver(ScreenshotController.image(from: cropped),
                                        selectionRect: global, screen: screen, captureScale: still.scale)
            ScreenshotController.warmUp()
            return
        }

        beginPendingCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            ScreenshotController.playCaptureSoundIfEnabled()
            nonisolated(unsafe) let deliverScreen = screen
            Task {
                let result = await ScreenshotController.captureRegion(
                    displayID: displayID, sourceRect: sourceRect, showsCursor: showsCursor,
                    excluding: overlayIDs, prefetched: prefetch)
                await MainActor.run {
                    defer { self.capturePending = false; ScreenshotController.warmUp() }
                    guard let result else { ScreenshotController.handleEmptyCapture(); return }
                    ScreenshotController.deliver(ScreenshotController.image(from: result.cg),
                                                selectionRect: global, screen: deliverScreen,
                                                captureScale: result.scale)
                }
            }
        }
    }
}

extension ScreenshotController {
    /// Set the arrow *and* make the window server actually re-composite it.
    ///
    /// `NSCursor.set()` only updates the app's current-cursor state. The server keeps drawing
    /// the image it last composited until **pointer motion** makes it re-evaluate — which is
    /// exactly why the stale camera cleared the instant the mouse was nudged. Cursor rects,
    /// `.set()`, `hide`/`unhide` and a front window with its own rect all change *claims*;
    /// none of them supply the motion, so none of them fixed it.
    ///
    /// `CGWarpMouseCursorPosition` does, and needs no Accessibility grant (that is required
    /// for *synthesizing events* via `CGEvent.post`, not for repositioning the pointer). The
    /// warp is one point and back on the next tick: two distinct positions, so the move can't
    /// be coalesced away, and a 1 pt round trip is imperceptible. Net position is unchanged.
    /// Guards against a second reset hiding the pointer again before the first unhides it.
    /// `NSCursor.hide()`/`unhide()` are reference-counted: two hides need two unhides, and an
    /// unmatched hide leaves the Mac with no pointer at all.
    private static var pointerHidden = false

    static func redrawPointer(on screen: NSScreen) {
        // Take the pointer off screen for a single tick. Setting a cursor only changes the
        // *claim*; the server keeps compositing the old image until it re-evaluates. With
        // nothing drawn there is no stale image to leave behind, and `unhide` composites
        // whatever the claim is by then — the arrow.
        if !pointerHidden {
            pointerHidden = true
            NSCursor.hide()
        }
        NSCursor.arrow.set()

        // Belt and braces: a 1 pt round trip supplies real pointer motion, the one thing that
        // reliably makes the server re-evaluate. Direction keeps it inside the current
        // display, so it can never walk onto another screen.
        let here = WindowList.cgPoint(fromAppKitMouse: NSEvent.mouseLocation)
        let bounds = screen.displayID.map(CGDisplayBounds) ?? .zero
        let dx: CGFloat = here.x + 1 < bounds.maxX ? 1 : -1
        CGWarpMouseCursorPosition(CGPoint(x: here.x + dx, y: here.y))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            CGWarpMouseCursorPosition(here)
            NSCursor.arrow.set()
            if pointerHidden {
                pointerHidden = false
                NSCursor.unhide()
            }
        }
    }
}

/// Borderless window used only to briefly reclaim cursor ownership after a capture
/// overlay is dismissed — see `ScreenshotController.forcePointerReset`.
private final class CursorResetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Full-screen view whose only job is to claim the pointing-hand cursor via a
/// standard AppKit cursor rect.
private final class CursorResetView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen, for matching against
    /// ScreenCaptureKit's `SCDisplay`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension ScreenshotController {
    /// Wrap a captured CGImage as a pixel-sized NSImage (scale 1) — mirrors the private
    /// `image(from:)`, exposed for the selection overlay's frozen backdrop.
    static func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
