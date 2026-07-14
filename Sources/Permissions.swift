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

    /// Proactively fire the system grant prompt once (used by first-run onboarding),
    /// so the very first capture doesn't hit a cold permission wall. No-op if already
    /// requested or already granted.
    static func prime() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRequestKey), !isGranted else { return }
        defaults.set(true, forKey: didRequestKey)
        _ = CGRequestScreenCaptureAccess()
    }

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
        NSApp.activate(ignoringOtherApps: true)
        let r = BrandAlert(
            title: "Screen Recording permission needed",
            message: "Turn it on in System Settings → Privacy & Security → Screen Recording, then try again.",
            titles: ["Open System Settings", "Cancel"],
            primary: 0, cancel: 1, icon: "lock.shield").runModal()
        if r == 0 { openSettings() }
    }

    private static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

