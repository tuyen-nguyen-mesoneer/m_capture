// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

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

        NSApp.activate(ignoringOtherApps: true)
        // Cover *every* screen so a region can be selected on any display
        // (one borderless overlay per screen, each in its own coordinate space).
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen)
            win.onComplete = { [weak self] viewRect in self?.finish(viewRect: viewRect, screen: screen) }
            win.onCancel = { [weak self] in self?.dismiss() }
            overlays.append(win)
            if screen == keyScreen { win.makeKeyAndOrderFront(nil) } else { win.orderFront(nil) }
        }
    }

    /// Common `screencapture` flags from Settings. Always `-x` (silent) — a
    /// non-interactive capture won't emit the shutter sound anyway, so we play it
    /// ourselves (see `playCaptureSoundIfEnabled`). Cursor only when opted in.
    private static var captureFlags: [String] {
        var f = ["-x"]
        if Settings.shared.captureCursor { f.append("-C") }
        return f
    }

    /// The system screenshot shutter sound, played when the user enables it
    /// (`screencapture -R/-l` is otherwise silent).
    private static func playCaptureSoundIfEnabled() {
        guard Settings.shared.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    private func dismiss() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    /// Hand a fresh capture to the configured destination: the annotation editor
    /// (default), a direct save to the output folder, or the clipboard only.
    static func deliver(_ image: NSImage, selectionRect: CGRect, screen: NSScreen) {
        switch Settings.shared.captureBehavior {
        case .editor:
            _ = EditorWindowController(image: image, selectionRect: selectionRect, screen: screen)
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

    /// A missing/empty capture almost always means Screen Recording was revoked
    /// after launch (the pre-check in `begin()` catches the common case up front).
    /// Clean up the temp file and guide the user rather than failing silently.
    private static func handleEmptyCapture(at tmp: String) {
        try? FileManager.default.removeItem(atPath: tmp)
        if !ScreenRecordingPermission.isGranted { ScreenRecordingPermission.handleDenied() }
    }

    private func finish(viewRect: CGRect, screen: NSScreen) {
        let global = CGRect(x: screen.frame.minX + viewRect.minX,
                            y: screen.frame.minY + viewRect.minY,
                            width: viewRect.width, height: viewRect.height)
        dismiss()
        guard global.width >= 3, global.height >= 3 else { return }

        let zero = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        let primaryHeight = zero.frame.height
        let capX = Int(global.minX.rounded()), capY = Int((primaryHeight - global.maxY).rounded())
        let capW = Int(global.width.rounded()), capH = Int(global.height.rounded())

        let tmp = NSTemporaryDirectory() + "mcap_\(UUID().uuidString).png"
        // Let the overlay clear before grabbing pixels (a couple of compositor
        // frames is enough; the dominant cost is the screencapture subprocess).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ScreenshotController.captureFlags + ["-R", "\(capX),\(capY),\(capW),\(capH)", tmp]
            ScreenshotController.playCaptureSoundIfEnabled()
            proc.terminationHandler = { _ in
                DispatchQueue.main.async {
                    guard FileManager.default.fileExists(atPath: tmp),
                          let img = NSImage(contentsOfFile: tmp),
                          img.size.width > 0, img.size.height > 0 else {
                        ScreenshotController.handleEmptyCapture(at: tmp)
                        return
                    }
                    try? FileManager.default.removeItem(atPath: tmp)
                    ScreenshotController.deliver(img, selectionRect: global, screen: screen)
                }
            }
            try? proc.run()
        }
    }
}
