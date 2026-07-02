// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var menu: BrandMenu!
    private var countdownActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Relocator.relocateToUserApplicationsIfNeeded() { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Logo.menuBarImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)

        buildMenu()
        reloadHotKeys()

        // Enable launch-at-login by default on first run; the user's later toggle
        // in Settings wins (this only runs once, and SMAppService is the source of
        // truth after that).
        let loginDefaultKey = "didApplyLoginItemDefault"
        if !UserDefaults.standard.bool(forKey: loginDefaultKey) {
            UserDefaults.standard.set(true, forKey: loginDefaultKey)
            Settings.shared.launchAtLogin = true
        }

        Updater.reconcileAfterRelaunch()
        Updater.checkInBackgroundIfDue()

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
        if let button = statusItem.button { menu.toggle(from: button) }
    }

    /// Build the menu-bar menu, showing each action's current hotkey glyphs.
    private func buildMenu() {
        let s = Settings.shared
        var entries: [MenuEntry] = [
            .header("m_capture", url: "https://github.com/tuyen-nguyen-mesoneer/m_capture"),
            .separator,
            .item(title: "Screenshot", symbol: "camera.viewfinder",
                  shortcut: s.shortcut(.screenshot).displayString) { [weak self] in self?.takeScreenshot() },
        ]
        entries.append(contentsOf: [
            .item(title: "Record Video", symbol: "record.circle",
                  shortcut: s.shortcut(.record).displayString) { [weak self] in self?.record() },
            .item(title: "Library", symbol: "folder", shortcut: nil) { [weak self] in self?.openLibrary() },
            .item(title: "Settings", symbol: "gearshape", shortcut: nil) { [weak self] in self?.settings() },
            .separator,
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

    @objc func quit() {
        NSApp.terminate(nil)
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
        _ = EditorWindowController(image: image, selectionRect: sel, screen: screen)
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
