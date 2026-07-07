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

    func begin() {
        if !overlays.isEmpty { return }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.handleDenied()
            return
        }

        let mouse = NSEvent.mouseLocation
        let keyScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        // The overlay needs keyboard focus (Esc to cancel, Space to toggle mode),
        // but as a background `.accessory` agent the app can't reliably become
        // active — key events would never reach the overlay. Promote to `.regular`
        // and activate, exactly as the editor does; `dismiss()` reverts. The Dock
        // icon this surfaces is hidden behind the full-screen overlay anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen)
            win.onComplete = { [weak self] viewRect in self?.finish(viewRect: viewRect, screen: screen) }
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
        // Drop back to a background agent unless an editor still needs the Dock
        // presence (the capture path opens one right after this, which re-promotes).
        if !EditorWindowController.hasOpenWindows { NSApp.setActivationPolicy(.accessory) }
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

    /// Encode in the configured format and write off the main thread.
    private static func saveToDisk(_ image: NSImage) {
        guard let rep = bitmap(from: image) else { return }
        let url = Settings.shared.fileURL()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Settings.shared.encode(rep) else { return }
            try? data.write(to: url)
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
    private static func captureRegion(displayID: CGDirectDisplayID, sourceRect: CGRect,
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

    private func finish(viewRect: CGRect, screen: NSScreen) {
        let global = CGRect(x: screen.frame.minX + viewRect.minX,
                            y: screen.frame.minY + viewRect.minY,
                            width: viewRect.width, height: viewRect.height)
        dismiss()
        guard global.width >= 3, global.height >= 3 else { return }
        guard let displayID = screen.displayID else { return }

        let sourceRect = CGRect(x: viewRect.minX,
                                y: screen.frame.height - viewRect.maxY,
                                width: viewRect.width, height: viewRect.height)
        let showsCursor = Settings.shared.captureCursor

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            ScreenshotController.playCaptureSoundIfEnabled()
            nonisolated(unsafe) let deliverScreen = screen
            Task {
                let result = await ScreenshotController.captureRegion(
                    displayID: displayID, sourceRect: sourceRect, showsCursor: showsCursor)
                await MainActor.run {
                    guard let result else { ScreenshotController.handleEmptyCapture(); return }
                    ScreenshotController.deliver(ScreenshotController.image(from: result.cg),
                                                selectionRect: global, screen: deliverScreen,
                                                captureScale: result.scale)
                }
            }
        }
    }
}

private extension NSScreen {
    /// The CoreGraphics display ID backing this screen, for matching against
    /// ScreenCaptureKit's `SCDisplay`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
