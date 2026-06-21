// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics

/// Screen Recording permission helpers.
///
/// Capture is out-of-process via `/usr/sbin/screencapture`, so a *denied* grant
/// produces a blank/missing file rather than an error — without this, a capture
/// would silently produce nothing and leave the user with no idea why. We gate
/// the capture on `CGPreflightScreenCaptureAccess` (a TCC check that grabs no
/// pixels, unlike the obsoleted `CGDisplayCreateImage`) and guide the user when
/// it's missing.
enum ScreenRecordingPermission {
    /// Whether Screen Recording is currently granted. Shows no prompt.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static let didRequestKey = "permissions.didRequestScreenRecording"

    /// Call when a capture is attempted without permission. The first time, it
    /// fires the system's own grant prompt (which registers the app in the
    /// Screen Recording list and links to System Settings); on later attempts —
    /// when macOS no longer re-prompts — it shows our own alert routing the user
    /// to the right settings pane.
    static func handleDenied() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: didRequestKey) {
            defaults.set(true, forKey: didRequestKey)
            _ = CGRequestScreenCaptureAccess()
            return
        }
        presentGuidanceAlert()
    }

    private static func presentGuidanceAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "m_capture captures your screen with macOS’s screen-recording API. "
            + "Turn it on under System Settings → Privacy & Security → Screen Recording, then try your capture again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    private static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
