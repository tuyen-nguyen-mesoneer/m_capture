// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Which activation policy the app runs under: the Dock-icon preference, overridden to
/// `.accessory` for as long as a capture surface is on screen.
///
/// **macOS will not layer a `.regular` app's windows over another app's full-screen
/// Space** — `.canJoinAllSpaces` + `.fullScreenAuxiliary` are not enough on their own
/// (Apple DTS, developer forums thread 826308). With the Dock icon showing, a screenshot
/// taken while display 2 held a full-screen app put the selection overlay up on display 1
/// only, so every capture came out of the first screen. Only `.accessory` apps may draw
/// there, so every capture surface — the selection overlay, the editor, a recording's HUD —
/// calls `holdForCapture()` *before* it activates the app or orders a window front.
///
/// Giving the Dock icon back is the delicate half. The hold has no matching release; each
/// surface's teardown calls `captureMayHaveEnded()` and the policy is re-derived from the
/// controllers' own state (`captureSurfaceUp`), so a missed or doubled call can't strand
/// the hold, and resigning active re-checks too. It is also put off while the app is still
/// **active**: an active `.regular` app is exactly what knocks the user out of their
/// full-screen Space, and the editor closing leaves us active with nothing on screen. The
/// Dock icon comes back the moment the user moves on to another app.
enum DockPolicy {
    /// True while the policy is `.accessory` because of a capture, not the preference.
    private static var heldForCapture = false
    private static var observer: NSObjectProtocol?

    private static var captureSurfaceUp: Bool {
        if ScreenshotController.shared.isBusy { return true }
        if #available(macOS 14, *), VideoRecordController.shared.isRecording { return true }
        return false
    }

    /// Apply the Dock-icon preference (launch, and Settings → General). `.accessory` drops
    /// the Dock icon and the app's menu bar, leaving the status item as the only entry
    /// point; `.regular` restores them.
    ///
    /// Switching to `.accessory` at runtime also resigns the app active, so callers toggling
    /// this from an open panel must re-raise it (see `SettingsWindowController.dockToggled`).
    static func applyPreference() {
        heldForCapture = false
        let target: NSApplication.ActivationPolicy = Settings.shared.hideDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if NSApp.isRunning { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Become `.accessory` so the next window can appear over a full-screen app. Call
    /// before `NSApp.activate` — activating as `.regular` is what pulls the user out of
    /// their full-screen Space. Idempotent; a no-op when the Dock icon is already hidden.
    static func holdForCapture() {
        observeResignActive()
        guard NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
        heldForCapture = true
    }

    /// Give the Dock icon back if nothing is holding the screen any more. Deferred a
    /// run-loop turn so the caller's teardown has finished updating the state it reads.
    static func captureMayHaveEnded() {
        DispatchQueue.main.async { restoreIfIdle() }
    }

    private static func restoreIfIdle() {
        guard heldForCapture, !captureSurfaceUp, !NSApp.isActive else { return }
        heldForCapture = false
        guard !Settings.shared.hideDockIcon else { return }
        NSApp.setActivationPolicy(.regular)
    }

    private static func observeResignActive() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { _ in captureMayHaveEnded() }
    }
}
