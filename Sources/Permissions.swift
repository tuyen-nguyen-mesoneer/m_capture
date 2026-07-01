// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics

/// Screen Recording permission helpers.
///
/// Capture runs in-process via ScreenCaptureKit, which yields nothing when the
/// grant is missing. We check `CGPreflightScreenCaptureAccess` up front and
/// guide the user when it's off.
enum ScreenRecordingPermission {
    /// Whether Screen Recording is currently granted. Shows no prompt.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static let didRequestKey = "permissions.didRequestScreenRecording"

    /// Call when a capture is attempted without permission. First time: fire the
    /// system grant prompt (which registers the app in the Screen Recording list).
    /// After that, macOS won't re-prompt, so show our own alert linking to Settings.
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
        alert.informativeText = "m_capture captures your screen with macOS's screen-recording API. "
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
