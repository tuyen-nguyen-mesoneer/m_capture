// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var menu: BrandMenu!
    private var countdownActive = false

    /// Apply the Dock-icon preference. `.accessory` drops the Dock icon (and the app's
    /// menu bar) leaving the status item as the only entry point; `.regular` restores it.
    ///
    /// Switching to `.accessory` at runtime also resigns the app active, so callers
    /// toggling this from an open panel must re-raise it (see `dockToggled`). Called at
    /// launch, before the app runs, and whenever the setting is toggled.
    static func applyDockVisibility() {
        let hide = Settings.shared.hideDockIcon
        guard NSApp.activationPolicy() != (hide ? .accessory : .regular) else { return }
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        if NSApp.isRunning { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }
        if Relocator.relocateToUserApplicationsIfNeeded() { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Logo.menuBarImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.setAccessibilityLabel("m_capture")

        buildMenu()
        reloadHotKeys()

        // The screenshot flow freezes the screen before showing its overlay, so the
        // shareable-content enumeration it needs sits on the hotkey's critical path —
        // pay it now, in the background, rather than on the user's first capture.
        ScreenshotController.warmUp()

        // Reflect recording state in the menu-bar icon so it's obvious the app is
        // recording even when the floating bar is minimized.
        VideoRecordController.shared.onRecordingUIUpdate = { [weak self] active, elapsed, paused in
            self?.updateRecordingIndicator(active: active, elapsed: elapsed, paused: paused)
        }
        // A long recording can take a while to re-encode as GIF; show it in the
        // menu-bar icon so the quiet gap between "Stop" and the Finder reveal
        // doesn't read as the app having dropped the recording.
        VideoRecordController.shared.onGIFExportUpdate = { [weak self] exporting in
            guard let button = self?.statusItem.button else { return }
            if exporting {
                button.image = nil
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                button.title = " GIF… "
            } else {
                button.image = Logo.menuBarImage(); button.title = ""; button.imagePosition = .imageOnly
            }
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
        // Opening the menu is a context switch — drop any open app panel so the
        // menu never floats over a stale Settings/History window.
        AppPanels.closeAll()
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
            AppPanels.closeAll()
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
        // While recording, the menu is recording controls only (Stop / Pause-Resume /
        // Show bar if minimized) plus Quit — every other action (Screenshot, a second
        // Record, History, Settings, ...) either doesn't make sense mid-recording or
        // would fight it for the screen, so they're dropped entirely rather than merely
        // disabled: a short, single-purpose menu beats a long one where most items are
        // greyed out. Quit stays reachable since it's an explicit, supported way to end
        // and finalize a recording (see `quit()`).
        if rec.isRecording {
            entries.append(.item(title: L("Stop Recording"), symbol: "stop.circle",
                                 shortcut: nil) { rec.stopFromMenu() })
            // The file-only stop variants are dropped in simulate mode: nothing is
            // captured, so there'd be no .mp4 to convert or trim.
            if !rec.isSimulatedRecording {
                entries.append(.item(title: L("Stop & Save as GIF"), symbol: "photo.stack",
                                     shortcut: nil) { rec.stopAsGIFFromMenu() })
                entries.append(.item(title: L("Stop & Trim…"), symbol: "scissors",
                                     shortcut: nil) { rec.stopAndTrimFromMenu() })
            }
            entries.append(.item(title: L("Discard Recording"), symbol: "trash",
                                 shortcut: nil) { rec.discardFromMenu() })
            // On-screen drawing, for the targets whose video can actually show it. Clear
            // only appears while there is something to clear.
            if rec.canDraw {
                entries.append(.item(title: rec.isDrawModeOn ? L("Stop Drawing") : L("Draw on Screen"),
                                     symbol: rec.isDrawModeOn ? "pencil.slash" : "pencil.tip",
                                     shortcut: s.shortcut(.draw).displayString) { rec.toggleDrawFromMenu() })
                if rec.hasDrawings {
                    entries.append(.item(title: L("Clear Drawings"), symbol: "eraser",
                                         shortcut: nil) { rec.clearDrawingsFromMenu() })
                }
            }
            entries.append(.item(title: rec.isRecordingPaused ? L("Resume Recording") : L("Pause Recording"),
                                 symbol: rec.isRecordingPaused ? "play.circle" : "pause.circle",
                                 shortcut: nil) { rec.togglePauseFromMenu() })
            if rec.isBarHidden {
                entries.append(.item(title: L("Show Recording Bar"), symbol: "menubar.dock.rectangle",
                                     shortcut: nil) { rec.setBarHidden(false) })
            }
            entries.append(.separator)
            entries.append(.item(title: L("Quit"), symbol: "power", shortcut: nil) { [weak self] in self?.quit() })
            menu = BrandMenu(entries: entries)
            return
        }
        entries.append(.item(title: L("Screenshot"), symbol: "camera.viewfinder",
                             shortcut: s.shortcut(.screenshot).displayString,
                             enabled: !editorOpen) { [weak self] in self?.takeScreenshot() })
        entries.append(contentsOf: [
            .item(title: L("Record Video"), symbol: "record.circle",
                  shortcut: s.shortcut(.record).displayString,
                  enabled: !editorOpen) { [weak self] in self?.record() },
            .item(title: L("History"), symbol: "clock", shortcut: nil) { HistoryWindowController.shared.show() },
            .item(title: L("Library"), symbol: "folder", shortcut: nil) { [weak self] in self?.openLibrary() },
            // Meta items (Usage Guide / About / Updates / Report a Bug) live in
            // Settings → About now — the menu stays a short list of actions.
            .item(title: L("Settings"), symbol: "gearshape", shortcut: nil) { [weak self] in self?.settings() },
            .separator,
            .item(title: L("Check for Updates"), symbol: "arrow.down.circle", shortcut: nil) { Updater.checkManually() },
            .item(title: L("Quit"), symbol: "power", shortcut: nil) { [weak self] in self?.quit() },
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
        // Draw on screen — only meaningful mid-recording on a display-backed target, so it
        // no-ops otherwise rather than registering conditionally (the binding has to stay
        // claimed for the whole session, or Settings → Shortcuts would report it free).
        hotKeys.append(HotKey(s.shortcut(.draw)) {
            let rec = VideoRecordController.shared
            guard rec.isRecording, rec.canDraw else { return }
            rec.toggleDrawFromMenu()
        })
        hotKeys.append(HotKey(s.shortcut(.forceQuit)) { [weak self] in self?.forceQuit() })
        // ⌥ + the record shortcut discards an in-flight recording (with confirm) —
        // the keyboard path when the floating bar (and its Esc handling) is hidden.
        // Skipped if the user's record shortcut already includes ⌥, which would
        // collide with the plain record binding.
        let record = s.shortcut(.record)
        if record.modifiers & UInt32(optionKey) == 0 {
            let discard = Shortcut(keyCode: record.keyCode,
                                   modifiers: record.modifiers | UInt32(optionKey))
            hotKeys.append(HotKey(discard) {
                if VideoRecordController.shared.isRecording {
                    VideoRecordController.shared.discardFromMenu()
                }
            })
        }
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

    /// The record hotkey toggles: pressing it while a recording runs stops and saves
    /// it — stopping otherwise needs a trip to the bar or the menu-bar icon, which is
    /// exactly what a keyboard-driven recording flow is trying to avoid.
    @objc func record() {
        let rec = VideoRecordController.shared
        if rec.isRecording { rec.stopFromMenu() } else { rec.begin() }
    }

    @objc func openLibrary() {
        NSWorkspace.shared.open(Settings.shared.saveDirectory)
    }

    @objc func settings() {
        SettingsWindowController.shared.show()
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
    /// OCR, Backgrounds, Before/After GIF — are discoverable from the menu.
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
        // The menu-bar indicator is the one part of the HUD that's always visible, so it
        // carries the simulate-mode signal too: an amber hollow dot and a SIM prefix,
        // unmistakable against the red filled dot of a real capture.
        let simulated = VideoRecordController.shared.isSimulatedRecording
        let tint: NSColor = paused ? .systemGray : (simulated ? Theme.warning : .systemRed)
        let conf = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(.init(paletteColors: [tint]))
        let dot = NSImage(systemSymbolName: simulated ? "record.circle" : "record.circle.fill",
                          accessibilityDescription: "Recording")?
            .withSymbolConfiguration(conf)
        dot?.isTemplate = false
        button.image = dot
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let clock = paused ? L("Paused") : Self.clockString(elapsed)
        button.title = simulated ? " SIM " + clock : " " + clock
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
