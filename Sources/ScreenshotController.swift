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
            guard let self, !self.overlays.isEmpty else { return }
            self.dismiss()
        }
    }

    /// True from the moment a capture starts (overlay shown, or a quick-screen
    /// grab kicked off) until it's fully handed off to `deliver`, plus for as
    /// long as an editor window from a prior capture is still open. `overlays`
    /// alone isn't enough: it's cleared by `dismiss()` well before the async
    /// ScreenCaptureKit grab and `deliver` finish, which left a window where a
    /// second hotkey press/menu click could start an independent overlay set
    /// (or a second `EditorWindowController`) while the first was still in flight.
    private var capturePending = false
    private var isBusy: Bool { !overlays.isEmpty || capturePending || EditorWindowController.hasOpenWindows }

    func begin() {
        if isBusy { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }
        AppPanels.closeAll()   // no app panel should sit under (or in) the shot

        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        // Bring the app forward so the overlay gets keyboard focus (Esc to cancel,
        // Space to toggle mode).
        NSApp.activate(ignoringOtherApps: true)
        let coordinator = OverlayCoordinator()
        let last = Settings.shared.lastRegion
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen, coordinator: coordinator,
                                    previousRect: screen.displayID == last?.displayID ? last?.rect : nil)
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
            win.onCancel = { [weak self] in self?.dismiss() }
            overlays.append(win)
            if screen == keyScreen {
                win.makeKeyAndOrderFront(nil)
                win.makeFirstResponder(win.contentView)
            } else {
                win.orderFront(nil)
            }
        }
    }

    /// Grabs the screen under the mouse immediately, with no overlay and no
    /// capture delay — for a transient UI state (a tooltip, a hover menu) that
    /// would vanish the moment the user has to drag a selection.
    func captureQuickScreen() {
        if isBusy { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }
        AppPanels.closeAll()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        guard let displayID = screen.displayID else { return }

        capturePending = true
        let sourceRect = CGRect(origin: .zero, size: screen.frame.size)
        ScreenshotController.playCaptureSoundIfEnabled()
        nonisolated(unsafe) let deliverScreen = screen
        Task {
            let result = await ScreenshotController.captureRegion(
                displayID: displayID, sourceRect: sourceRect, showsCursor: Settings.shared.captureCursor)
            await MainActor.run {
                defer { self.capturePending = false }
                guard let result else { ScreenshotController.handleEmptyCapture(); return }
                ScreenshotController.deliver(ScreenshotController.image(from: result.cg),
                                            selectionRect: deliverScreen.frame, screen: deliverScreen,
                                            captureScale: result.scale)
            }
        }
    }

    /// The system screenshot shutter sound, played when the user enables it
    /// (the in-process capture is otherwise silent).
    private static func playCaptureSoundIfEnabled() {
        guard Settings.shared.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    private func dismiss() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        ScreenshotController.forcePointerReset()
    }

    /// Reset the pointer to the pointing hand — matching the Window/Screen pick modes'
    /// cursor — immediately: the overlay's crosshair otherwise lingers (nothing moves
    /// the mouse in the brief pre-capture delay) and gets baked into the shot when
    /// `showsCursor` is on.
    ///
    /// `.set()`, hide/unhide, and `CGWarpMouseCursorPosition` all failed to force a
    /// redraw here (confirmed: only an actual click cleared it) — those either need a
    /// real hardware input event or, for the warp, Accessibility permission this app
    /// doesn't request. Instead this briefly puts up another real window with a cursor
    /// rect over the whole screen — the exact mechanism that successfully drew the
    /// crosshair in the first place — so the window server has to re-evaluate and draw
    /// the new cursor, then removes it a beat later once that's taken effect.
    static func forcePointerReset() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let win = CursorResetWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // Hit-testable (not click-through) and briefly key — cursor-rect ownership is
        // tied to actually being the front, hit-testable window under the pointer, same
        // as the real capture overlay it's replacing. It's up for only ~50ms.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = CursorResetView(frame: NSRect(origin: .zero, size: screen.frame.size))
        win.contentView = v
        win.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            win.orderOut(nil)
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

    /// A nil capture almost always means Screen Recording was revoked after
    /// launch (the pre-check in `begin()` catches the common case up front).
    /// Guide the user rather than failing silently.
    private static func handleEmptyCapture() {
        if !ScreenRecordingPermission.isGranted { ScreenRecordingPermission.handleDenied() }
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
                                      showsCursor: Bool) async -> (cg: CGImage, scale: CGFloat)? {
        await withTimeout(seconds: 10) {
            await captureRegionUnbounded(displayID: displayID, sourceRect: sourceRect,
                                         showsCursor: showsCursor)
        }
    }

    private static func captureRegionUnbounded(displayID: CGDirectDisplayID, sourceRect: CGRect,
                                               showsCursor: Bool) async -> (cg: CGImage, scale: CGFloat)? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
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
    private static func captureWindow(windowID: CGWindowID, showsCursor: Bool)
        async -> (cg: CGImage, scale: CGFloat, globalRect: CGRect, screen: NSScreen)? {
        // Resolve the hosting NSScreen outside the timeout race: NSScreen is
        // explicitly non-Sendable, so it can't cross the task-group boundary.
        guard let r = await withTimeout(seconds: 10, {
            await captureWindowUnbounded(windowID: windowID, showsCursor: showsCursor)
        }) else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(r.globalRect) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return (r.cg, r.scale, r.globalRect, screen)
    }

    private static func captureWindowUnbounded(windowID: CGWindowID, showsCursor: Bool)
        async -> (cg: CGImage, scale: CGFloat, globalRect: CGRect)? {
        do {
            let content = try await SCShareableContent.current
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

    private func finishWindow(windowID: CGWindowID) {
        dismiss()
        capturePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            ScreenshotController.playCaptureSoundIfEnabled()
            Task {
                // Never draw the cursor for a window grab — it's only ever the tool's
                // capture badge, which would otherwise bake into the shot.
                let result = await ScreenshotController.captureWindow(windowID: windowID, showsCursor: false)
                await MainActor.run {
                    defer { self.capturePending = false }
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
        dismiss()
        guard global.width >= 3, global.height >= 3 else { return }
        guard let displayID = screen.displayID else { return }

        capturePending = true
        let sourceRect = CGRect(x: viewRect.minX,
                                y: screen.frame.height - viewRect.maxY,
                                width: viewRect.width, height: viewRect.height)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            ScreenshotController.playCaptureSoundIfEnabled()
            nonisolated(unsafe) let deliverScreen = screen
            Task {
                let result = await ScreenshotController.captureRegion(
                    displayID: displayID, sourceRect: sourceRect, showsCursor: showsCursor)
                await MainActor.run {
                    defer { self.capturePending = false }
                    guard let result else { ScreenshotController.handleEmptyCapture(); return }
                    ScreenshotController.deliver(ScreenshotController.image(from: result.cg),
                                                selectionRect: global, screen: deliverScreen,
                                                captureScale: result.scale)
                }
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen, for matching against
    /// ScreenCaptureKit's `SCDisplay`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension ScreenshotController {
    /// Re-capture a display region while excluding given windows (e.g. the annotation
    /// editor covering the screen), so the editor can re-grab a *larger* region and see
    /// the real content behind it. `sourceRect` is display-local, top-left origin (points).
    static func recaptureRegion(displayID: CGDirectDisplayID, sourceRect: CGRect,
                                excluding windowIDs: [CGWindowID]) async -> (cg: CGImage, scale: CGFloat)? {
        await withTimeout(seconds: 10) {
            await recaptureRegionUnbounded(displayID: displayID, sourceRect: sourceRect,
                                           excluding: windowIDs)
        }
    }

    private static func recaptureRegionUnbounded(displayID: CGDirectDisplayID, sourceRect: CGRect,
                                                 excluding windowIDs: [CGWindowID]) async -> (cg: CGImage, scale: CGFloat)? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let excluded = content.windows.filter { windowIDs.contains(CGWindowID($0.windowID)) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            config.width = max(1, Int((sourceRect.width * scale).rounded()))
            config.height = max(1, Int((sourceRect.height * scale).rounded()))
            config.showsCursor = false
            config.captureResolution = .best
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (cg, scale)
        } catch { return nil }
    }

    /// Wrap a captured CGImage as a pixel-sized NSImage (scale 1) — mirrors the private
    /// `image(from:)`, exposed for the editor's re-grab path.
    static func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
