// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var menu: BrandMenu!
    private var countdownActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }
        if Relocator.relocateToUserApplicationsIfNeeded() { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Logo.menuBarImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)

        buildMenu()
        reloadHotKeys()

        // Reflect recording state in the menu-bar icon so it's obvious the app is
        // recording even when the floating bar is minimized.
        VideoRecordController.shared.onRecordingUIUpdate = { [weak self] active, elapsed, paused in
            self?.updateRecordingIndicator(active: active, elapsed: elapsed, paused: paused)
        }

        Updater.reconcileAfterRelaunch()
        Updater.scheduleBackgroundChecks()

        if CommandLine.arguments.contains("--editor-demo") {
            DispatchQueue.main.async { [weak self] in self?.openEditorDemo() }
        }
        if CommandLine.arguments.contains("--settings-demo") {
            DispatchQueue.main.async { [weak self] in self?.settings() }
        }
        if CommandLine.arguments.contains("--alert-demo") {
            DispatchQueue.main.async {
                _ = BrandAlert(title: "Update available",
                               message: "m_capture 1.1.0 is available.",
                               titles: ["Download", "Later"],
                               primary: 0, cancel: 1).runModal()
            }
        }
    }

    @objc private func statusClicked() {
        // Rebuilt on every open (not just at launch/hotkey-rebind) so the
        // Screenshot/Record rows reflect whether the editor is open right now.
        buildMenu()
        if let button = statusItem.button { menu.toggle(from: button) }
    }

    /// The app has a Dock icon but no main window, so a Dock-icon click (or ⌘-Tab
    /// reopen) drops the status menu down from the menu-bar item — matching what a
    /// user expects when they click to "open" the app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A reopen event can reach an instance that bailed out of `applicationDidFinishLaunching`
        // early (a duplicate quitting itself, or a relocation relaunch) — before `statusItem`
        // exists. Force-unwrapping it then traps, so no-op until the status item is live.
        guard let statusItem else { return true }
        if !flag {
            buildMenu()
            if let button = statusItem.button { menu.toggle(from: button) }
        }
        return true
    }

    /// Build the menu-bar menu, showing each action's current hotkey glyphs.
    /// Screenshot/Record are disabled while the annotation editor is open — both
    /// already no-op in that state (see `ScreenshotController.isBusy` /
    /// `VideoRecordController.begin()`); this just makes that visible.
    private func buildMenu() {
        let s = Settings.shared
        let editorOpen = EditorWindowController.hasOpenWindows
        let rec = VideoRecordController.shared
        var entries: [MenuEntry] = [
            .header("m_capture", url: "https://github.com/tuyen-nguyen-mesoneer/m_capture",
                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            .separator,
        ]
        // While recording, surface Stop / Pause-Resume (and Show bar if minimized) so the
        // whole flow can be driven from the menu bar, not just the floating HUD.
        if rec.isRecording {
            entries.append(.item(title: "Stop Recording", symbol: "stop.circle",
                                 shortcut: nil) { rec.stopFromMenu() })
            entries.append(.item(title: rec.isRecordingPaused ? "Resume Recording" : "Pause Recording",
                                 symbol: rec.isRecordingPaused ? "play.circle" : "pause.circle",
                                 shortcut: nil) { rec.togglePauseFromMenu() })
            if rec.isBarHidden {
                entries.append(.item(title: "Show Recording Bar", symbol: "menubar.dock.rectangle",
                                     shortcut: nil) { rec.setBarHidden(false) })
            }
            entries.append(.separator)
        }
        entries.append(.item(title: "Screenshot", symbol: "camera.viewfinder",
                             shortcut: s.shortcut(.screenshot).displayString,
                             enabled: !editorOpen) { [weak self] in self?.takeScreenshot() })
        entries.append(contentsOf: [
            .item(title: "Record Video", symbol: "record.circle",
                  shortcut: s.shortcut(.record).displayString,
                  enabled: !editorOpen) { [weak self] in self?.record() },
            .item(title: "Quick Screen", symbol: "cursorarrow.rays",
                  shortcut: s.shortcut(.quickScreen).displayString,
                  enabled: !editorOpen) { ScreenshotController.shared.captureQuickScreen() },
            .item(title: "Library", symbol: "folder", shortcut: nil) { [weak self] in self?.openLibrary() },
            .item(title: "Settings", symbol: "gearshape", shortcut: nil) { [weak self] in self?.settings() },
            .separator,
            .item(title: "Usage Guide", symbol: "questionmark.circle", shortcut: nil) { [weak self] in self?.openUsageGuide() },
            .item(title: "About", symbol: "info.circle", shortcut: nil) { [weak self] in self?.about() },
            .item(title: "Check for Updates", symbol: "arrow.down.circle", shortcut: nil) { Updater.checkManually() },
            .item(title: "Report a Bug", symbol: "ladybug", shortcut: nil) { [weak self] in self?.reportBug() },
            .item(title: "Quit", symbol: "power", shortcut: nil) { [weak self] in self?.quit() },
        ])
        menu = BrandMenu(entries: entries)
    }

    /// (Re)register the global hotkeys from Settings. Dropping the old `HotKey`
    /// instances unregisters them (see `HotKey.deinit`); rebuilds the menu so its
    /// glyphs stay in sync. Called at launch and whenever a shortcut is rebound.
    func reloadHotKeys() {
        hotKeys.removeAll()
        let s = Settings.shared
        hotKeys.append(HotKey(s.shortcut(.screenshot)) { [weak self] in self?.takeScreenshot() })
        hotKeys.append(HotKey(s.shortcut(.record)) { [weak self] in self?.record() })
        hotKeys.append(HotKey(s.shortcut(.quickScreen)) { ScreenshotController.shared.captureQuickScreen() })
        hotKeys.append(HotKey(s.shortcut(.forceQuit)) { [weak self] in self?.forceQuit() })
        buildMenu()
    }

    /// Region-selection overlay, then grab + copy. Honors the configured
    /// capture delay, showing a 3→2→1 countdown in the menu-bar icon first.
    @objc func takeScreenshot() {
        let delay = Settings.shared.captureDelay.rawValue
        if delay <= 0 { ScreenshotController.shared.begin(); return }
        countdown(from: delay)
    }

    /// Counts down in the status-item button, then begins the capture. Guards
    /// against re-entry so a second hotkey press during the countdown is ignored.
    private func countdown(from seconds: Int) {
        if countdownActive { return }
        guard let button = statusItem.button else {
            ScreenshotController.shared.begin()
            return
        }
        countdownActive = true
        let savedImage = button.image
        func tick(_ remaining: Int) {
            guard remaining > 0 else {
                button.image = savedImage
                button.title = ""
                countdownActive = false
                ScreenshotController.shared.begin()
                return
            }
            button.image = nil
            button.title = " \(remaining) "
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(remaining - 1) }
        }
        tick(seconds)
    }

    @objc func record() {
        VideoRecordController.shared.begin()
    }

    @objc func openLibrary() {
        NSWorkspace.shared.open(Settings.shared.saveDirectory)
    }

    @objc func settings() {
        SettingsWindowController.shared.show()
    }

    @objc func about() {
        AboutWindowController.shared.show()
    }

    /// Open a pre-filled GitHub issue, with the app + macOS version already in the
    /// body so bug reports arrive with the basics attached.
    @objc func reportBug() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let body = "\n\n---\nm_capture \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        var url = URLComponents(string: "https://github.com/tuyen-nguyen-mesoneer/m_capture/issues/new")!
        url.queryItems = [URLQueryItem(name: "title", value: "Bug: "),
                          URLQueryItem(name: "body", value: body)]
        if let u = url.url { NSWorkspace.shared.open(u) }
    }

    /// Open the usage guide (the repo's USAGE.md) so the editor-only features — Pin,
    /// OCR, Backgrounds, Before/After GIF, Quick Screen — are discoverable from the menu.
    @objc func openUsageGuide() {
        if let u = URL(string: "https://github.com/tuyen-nguyen-mesoneer/m_capture/blob/trunk/USAGE.md") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func quit() {
        // Finalize any in-flight recording synchronously first (proven run-loop-pumping
        // path, same as Force Quit) so the mp4 is playable, then terminate. This is more
        // reliable than applicationShouldTerminate/.terminateLater, whose modal run loop
        // can leave the app half-alive.
        VideoRecordController.shared.finalizeForTermination()
        NSApp.terminate(nil)
    }

    /// Safety net for quit routes that bypass our menu item (system logout, etc.):
    /// finalize a still-running recording synchronously before the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        VideoRecordController.shared.finalizeForTermination()
    }

    /// Show recording state right in the menu-bar icon — a red dot plus a live timer
    /// (grey "Paused" when paused) — so it's unmistakable the app is recording even with
    /// the floating bar minimized. Reverts to the plain m. logo when idle.
    private func updateRecordingIndicator(active: Bool, elapsed: TimeInterval, paused: Bool) {
        guard let button = statusItem.button else { return }
        guard active else {
            button.image = Logo.menuBarImage(); button.title = ""; button.imagePosition = .imageOnly
            return
        }
        let conf = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(.init(paletteColors: [paused ? .systemGray : .systemRed]))
        let dot = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(conf)
        dot?.isTemplate = false
        button.image = dot
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.title = paused ? " Paused" : " " + Self.clockString(elapsed)
    }

    private static func clockString(_ t: TimeInterval) -> String {
        let s = Int(t), h = Int(t) / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Force Quit: also force-terminates any other m_capture process still
    /// running (covers the stray-duplicate scenario a stuck quit can leave
    /// behind), then exits this process directly rather than going through
    /// `NSApp.terminate` — a harder stop than the regular Quit menu item.
    @objc func forceQuit() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let myPID = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != myPID {
            other.forceTerminate()
        }
        // exit(0) skips applicationWillTerminate, so finalize a recording here too —
        // otherwise a hard Force Quit mid-record leaves a corrupt file.
        VideoRecordController.shared.finalizeForTermination()
        exit(0)
    }

    /// Refuses a second launch when another m_capture process already owns the bundle
    /// identifier. Without this, a stray double-launch (a Login Item plus a manual
    /// open, a Finder relaunch that races an in-flight Relocator/Updater relaunch,
    /// etc.) leaves two menu-bar icons and two sets of global hotkeys running — and
    /// quitting one via its menu never touches the other.
    private func terminateIfAlreadyRunning() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// Open the editor on a generated sample image (see `--editor-demo`).
    private func openEditorDemo() {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 1040, height: 660)
        let image = AppDelegate.demoImage(size: size)
        let f = screen.frame
        let sel = NSRect(x: f.minX + (f.width - size.width) / 2,
                         y: f.minY + (f.height - size.height) / 2,
                         width: size.width, height: size.height)
        _ = EditorWindowController(image: image, selectionRect: sel, screen: screen, captureScale: 1)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A plain placeholder capture to frame in the editor demo.
    private static func demoImage(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        Theme.rgb(0xF4, 0xF1, 0xFA).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        Theme.rgb(0xFF, 0xFF, 0xFF).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 80, width: size.width - 120, height: size.height - 160),
                     xRadius: 16, yRadius: 16).fill()
        ("m_capture — editor demo" as NSString).draw(
            at: NSPoint(x: 92, y: size.height - 150),
            withAttributes: [.font: Theme.font(30, .bold),
                             .foregroundColor: Theme.rgb(0x2A, 0x1A, 0x4A)])
        img.unlockFocus()
        return img
    }
}
