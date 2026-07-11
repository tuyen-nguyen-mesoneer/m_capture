// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Checks GitHub Releases for a newer build — no dependencies, just URLSession +
/// JSONDecoder — and drives the install. Two entry points:
///
/// - `checkInBackground()` — a silent check (on launch, and periodically thereafter via
///   `scheduleBackgroundChecks`) that downloads and swaps the new build in place with no
///   UI, then relaunches into it immediately.
/// - `checkManually()` — the "Check for Updates" item; always reports an outcome and,
///   on a newer build, installs it and offers an immediate relaunch.
///
/// Both paths require the repo's releases to be readable by the running user; for an
/// internal rollout the repo (or its releases) must be public or org-accessible.
///
/// Whether the user keeps their Screen Recording grant across an update is a *signing*
/// property, not an updater one: releases must share the `m_capture-dev` identity (see
/// `build.sh` / CONTRIBUTING). The updater installs regardless of identity, so a release
/// signed differently costs a one-time re-grant.
enum Updater {
    private static let repo = "tuyen-nguyen-mesoneer/m_capture"
    private static let releasesURL = URL(string: "https://api.github.com/repos/\(repo)/releases")!
    private static let releasesPage = "https://github.com/\(repo)/releases"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Keeps the repeating timer alive; retained for the process lifetime.
    private static var backgroundTimer: Timer?

    /// A build we've already swapped onto disk but haven't relaunched into yet. Kept so
    /// the launch check doesn't see the just-installed release as "newer" and reinstall it.
    private static let pendingVersionKey = "updater.pendingVersion"

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    /// The version baked into the running bundle (the *old* one even after a swap, since
    /// `Bundle.main` is fixed at launch).
    private static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// What releases are compared against: the running build, or a newer build already
    /// swapped onto disk and awaiting a relaunch. Prevents reinstalling the same release.
    static var effectiveCurrentVersion: String {
        let running = runningVersion
        guard let pending = UserDefaults.standard.string(forKey: pendingVersionKey) else { return running }
        return isNewer(pending, than: running) ? pending : running
    }

    /// Drop the pending marker once a relaunch has actually picked up that build (or newer).
    /// Call once at launch.
    static func reconcileAfterRelaunch() {
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: pendingVersionKey) else { return }
        if !isNewer(pending, than: runningVersion) { defaults.removeObject(forKey: pendingVersionKey) }
    }

    private static func markInstalled(_ version: String) {
        UserDefaults.standard.set(version, forKey: pendingVersionKey)
    }

    /// Manual check — always tells the user the outcome (up to date / available /
    /// couldn't check), and installs on demand.
    static func checkManually() {
        fetch { result in
            switch result {
            case .success(let release) where isNewer(release.tagName, than: effectiveCurrentVersion):
                promptAndInstall(release)
            case .success:
                presentUpToDateAlert()
            case .failure:
                presentErrorAlert()
            }
        }
    }

    /// Checks now, then re-checks silently once a day for as long as the process keeps
    /// running. m_capture is a menu-bar agent that's rarely quit — a launch-only check
    /// would only ever fire once per login/reboot, not "once a day" as intended, leaving
    /// long-running sessions to go weeks without ever picking up a newer release.
    static func scheduleBackgroundChecks() {
        checkInBackground()
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            checkInBackground()
        }
    }

    /// Silent check run on every launch (and periodically thereafter, see
    /// `scheduleBackgroundChecks`); on a newer build it downloads, swaps, and relaunches
    /// into it with no UI. Any failure stays silent — the running version is untouched.
    static func checkInBackground() {
        fetch { result in
            guard case .success(let release) = result,
                  isNewer(release.tagName, than: effectiveCurrentVersion),
                  let dmg = dmgURL(for: release)
            else { return }
            UpdateInstaller.install(dmgURL: dmg, expectedVersion: normalize(release.tagName)) { outcome in
                if case .success = outcome {
                    markInstalled(normalize(release.tagName))
                    // The swap is already safely on disk; only relaunch into it now if
                    // there's nothing to interrupt. Otherwise it's picked up next time
                    // the app naturally restarts (or the next background check).
                    var busy = EditorWindowController.hasOpenWindows
                    if #available(macOS 14, *) {
                        busy = busy || VideoRecordController.shared.isRecording
                    }
                    if !busy { relaunch() }
                }
            }
        }
    }

    private static func promptAndInstall(_ release: Release) {
        let version = normalize(release.tagName)
        let choice = BrandAlert(title: "Update available",
                                message: "m_capture \(version) is available.",
                                titles: ["Install", "Later"], primary: 0, cancel: 1).runModal()
        guard choice == 0 else { return }
        guard let dmg = dmgURL(for: release) else { presentErrorAlert(); return }
        UpdateInstaller.install(dmgURL: dmg, expectedVersion: version) { outcome in
            switch outcome {
            case .success:
                markInstalled(version)
                presentInstalledAlert(version)
            case .failure:
                presentErrorAlert()
            }
        }
    }

    private static func dmgURL(for release: Release) -> URL? {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }
        return URL(string: asset.browserDownloadURL)
    }

    /// Quit and reopen the freshly swapped bundle. A detached shell waits for this
    /// process to exit, then relaunches — it outlives our own termination.
    private static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"\(path)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        try? proc.run()
        NSApp.terminate(nil)
    }

    private static func fetch(_ completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("m_capture", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: Result<Release, Error>
            if let data, let release = try? JSONDecoder().decode([Release].self, from: data).first {
                result = .success(release)
            } else {
                result = .failure(error ?? URLError(.badServerResponse))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Drop a leading "v" and any pre-release suffix so tags compare numerically.
    private static func normalize(_ tag: String) -> String {
        var t = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
        return t
    }

    /// Whether `tag` is a newer version than `current`. Internal so `UpdateInstaller` can
    /// re-check the extracted bundle before swapping.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = normalize(tag).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func presentInstalledAlert(_ version: String) {
        let choice = BrandAlert(title: "Update installed",
                                message: "m_capture \(version) will run the next time you launch.",
                                titles: ["Relaunch now", "Later"], primary: 0, cancel: 1).runModal()
        if choice == 0 { relaunch() }
    }

    private static func presentUpToDateAlert() {
        BrandAlert(title: "You’re up to date",
                   message: "m_capture \(effectiveCurrentVersion) is the latest version.",
                   titles: ["OK"], primary: 0, cancel: 0).runModal()
    }

    private static func presentErrorAlert() {
        let choice = BrandAlert(title: "Couldn't update",
                                message: "Check your connection and try again.",
                                titles: ["Open Releases", "OK"], primary: 0, cancel: 1).runModal()
        if choice == 0, let url = URL(string: releasesPage) { NSWorkspace.shared.open(url) }
    }
}

