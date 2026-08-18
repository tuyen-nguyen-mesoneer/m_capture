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
    ///
    /// The recording flow passes `simulateFallback`, which adds a "Simulate Instead"
    /// button that switches simulate mode on and re-runs the caller. On a managed Mac the
    /// grant can be weeks away behind an admin request, and every recording tool is
    /// testable without it — so the dead-end alert becomes the place the fallback is
    /// discovered. Screenshots pass nil: there are no pixels to fake.
    static func handleDenied(simulateFallback: (() -> Void)? = nil) {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: didRequestKey) {
            defaults.set(true, forKey: didRequestKey)
            _ = CGRequestScreenCaptureAccess()
            return
        }
        presentGuidanceAlert(simulateFallback: simulateFallback)
    }

    private static func presentGuidanceAlert(simulateFallback: (() -> Void)?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let simulateFallback else {
            let r = BrandAlert(
                title: L("Screen Recording permission required"),
                message: L("Enable it in System Settings → Privacy & Security → Screen Recording, then try again."),
                titles: [L("Open System Settings"), L("Cancel")],
                primary: 0, cancel: 1, icon: "lock.shield").runModal()
            if r == 0 { openSettings() }
            return
        }
        let r = BrandAlert(
            title: L("Screen Recording permission required"),
            message: L("Enable it in System Settings → Privacy & Security → Screen Recording, then try again. If your administrator manages this permission, you can simulate a recording meanwhile: every recording tool works, but nothing is captured or saved."),
            titles: [L("Open System Settings"), L("Simulate Instead"), L("Cancel")],
            primary: 0, cancel: 2, icon: "lock.shield").runModal()
        switch r {
        case 0: openSettings()
        case 1:
            Settings.shared.simulateRecording = true
            simulateFallback()
        default: break
        }
    }

    private static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

