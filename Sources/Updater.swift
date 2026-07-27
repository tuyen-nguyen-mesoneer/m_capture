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

    /// Polls until the user is idle so a relaunch alert deferred by `isUserBusy()` still
    /// fires once they finish, instead of being dropped until the next daily check.
    private static var relaunchWaitTimer: Timer?

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
        // A background check may already have staged a newer build that's still waiting
        // out `isUserBusy()` (see `waitForIdleThenAlert`) — `effectiveCurrentVersion`
        // already counts it as current, so without this check the user would be told
        // "up to date" instead of "restart to finish updating".
        if let pending = UserDefaults.standard.string(forKey: pendingVersionKey),
           isNewer(pending, than: runningVersion) {
            presentUpdatedAlert(pending)
            return
        }
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
    /// `scheduleBackgroundChecks`); on a newer build it downloads and swaps it in with no
    /// UI, then tells the user it's ready and relaunches once they confirm. Any failure
    /// stays silent — the running version is untouched.
    static func checkInBackground() {
        fetch { result in
            guard case .success(let release) = result,
                  isNewer(release.tagName, than: effectiveCurrentVersion),
                  let dmg = dmgURL(for: release)
            else { return }
            UpdateInstaller.install(dmgURL: dmg, expectedVersion: normalize(release.tagName)) { outcome in
                if case .success = outcome {
                    let version = normalize(release.tagName)
                    markInstalled(version)
                    // The swap is already safely on disk; only interrupt with the
                    // relaunch prompt if there's nothing to interrupt. Once the swap has
                    // happened, `effectiveCurrentVersion` reports this release as current,
                    // so no later check will ever notice it's "newer" again — if we drop
                    // the alert here it's gone for good. Wait the user out instead.
                    if isUserBusy() {
                        waitForIdleThenAlert(version)
                    } else {
                        presentUpdatedAlert(version)
                    }
                }
            }
        }
    }

    /// Whether interrupting with the relaunch prompt right now would step on active work.
    private static func isUserBusy() -> Bool {
        var busy = EditorWindowController.hasOpenWindows
            || ScreenshotController.shared.isSelecting
        if #available(macOS 14, *) {
            busy = busy || VideoRecordController.shared.isRecording
                || VideoRecordController.shared.isSelecting
        }
        return busy
    }

    /// Polls every few seconds until `isUserBusy()` clears, then shows the relaunch alert.
    /// A later call (e.g. the next daily check finding yet another release) restarts the
    /// wait with the newer version rather than stacking timers.
    private static func waitForIdleThenAlert(_ version: String) {
        relaunchWaitTimer?.invalidate()
        relaunchWaitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            guard !isUserBusy() else { return }
            timer.invalidate()
            relaunchWaitTimer = nil
            presentUpdatedAlert(version)
        }
    }

    private static func promptAndInstall(_ release: Release) {
        let version = normalize(release.tagName)
        BrandAlert(title: L("Update available"),
                   message: String(format: L("m_capture %@ is available."), version),
                   titles: [L("Install"), L("Later")], primary: 0, cancel: 1).present { choice in
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
    }

    private static func dmgURL(for release: Release) -> URL? {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }
        return URL(string: asset.browserDownloadURL)
    }

    /// Quit and reopen the bundle. A detached shell waits for this process to
    /// exit, then relaunches — it outlives our own termination. Internal because
    /// Settings' language switch also restarts through it.
    static func relaunch() {
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

    /// The relaunch prompt shown after a build is swapped onto disk — same wording
    /// whether the update came from a manual "Check for Updates" or the silent once-a-day
    /// check, so the two paths read identically. The relaunch is forced: a single confirm,
    /// then straight into the new build (no "Later" — the swap already happened).
    private static func presentRelaunchAlert(_ version: String) {
        BrandAlert(title: L("Update installed"),
                   message: String(format: L("m_capture %@ is ready. Click OK to relaunch."), version),
                   titles: ["OK"], primary: 0, cancel: 0).present { _ in relaunch() }
    }

    private static func presentInstalledAlert(_ version: String) { presentRelaunchAlert(version) }

    /// Silent-install path: the build is already swapped onto disk; prompt to relaunch
    /// with the same message as the manual path.
    private static func presentUpdatedAlert(_ version: String) { presentRelaunchAlert(version) }

    private static func presentUpToDateAlert() {
        BrandAlert(title: L("Up to date"),
                   message: String(format: L("m_capture %@ is the latest version."), effectiveCurrentVersion),
                   titles: ["OK"], primary: 0, cancel: 0).present()
    }

    private static func presentErrorAlert() {
        BrandAlert(title: L("Unable to update"),
                   message: L("Check the network connection and try again."),
                   titles: [L("Open Releases"), "OK"], primary: 0, cancel: 1).present { choice in
            if choice == 0, let url = URL(string: releasesPage) { NSWorkspace.shared.open(url) }
        }
    }
}

