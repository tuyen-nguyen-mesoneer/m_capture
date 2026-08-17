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
/// property, not an updater one: releases must share the `m_capture-release` identity (see
/// `build.sh` / CONTRIBUTING). The updater installs regardless of identity, so a release
/// signed differently costs a one-time re-grant.
enum Updater {
    private static let repo = "tuyen-nguyen-mesoneer/m_capture"
    /// The releases **Atom feed**, not `api.github.com`. The API caps unauthenticated
    /// callers at 60 requests/hour *per egress IP*, so a whole office behind one NAT
    /// exhausts it collectively and every "Check for Updates" then answers 403 — which
    /// is what shipped as "Unable to update". The feed is plain github.com HTML-side
    /// infrastructure with no such quota, and lists tags newest-first just the same.
    private static let releasesURL = URL(string: "https://github.com/\(repo)/releases.atom")!
    private static let releasesPage = "https://github.com/\(repo)/releases"
    /// `release.yml` always uploads exactly this name, so the download URL is derivable
    /// from the tag alone — the feed carries no asset list.
    private static let dmgAssetName = "m_capture.dmg"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Keeps the repeating timer alive; retained for the process lifetime.
    private static var backgroundTimer: Timer?

    /// Polls until the user is idle so a relaunch alert deferred by `isUserBusy()` still
    /// fires once they finish, instead of being dropped until the next daily check.
    private static var relaunchWaitTimer: Timer?

    /// One-shot retry after a failed silent check. The launch check fires the moment a
    /// login item starts — routinely *before* Wi-Fi/VPN is up — and long-running sessions
    /// hit transient failures too (network flaps, GitHub's 60-requests/hour per-IP API
    /// limit, which a whole office behind one NAT egress exhausts constantly). Waiting
    /// for the next daily tick turned every such hiccup into a full day without updates —
    /// for users whose check *always* races the network at login, into "auto-update
    /// never works at all".
    private static var retryTimer: Timer?
    private static let retryInterval: TimeInterval = 15 * 60

    /// A build we've already swapped onto disk but haven't relaunched into yet. Kept so
    /// the launch check doesn't see the just-installed release as "newer" and reinstall it.
    private static let pendingVersionKey = "updater.pendingVersion"

    /// Consecutive silent-check fetch failures, persisted so Settings → About can
    /// surface a chronically blocked updater (proxy, rate limit, private repo).
    private static let failedChecksKey = "updater.failedChecks"

    /// True while the relaunch alert is on screen, so a daily re-prompt doesn't stack
    /// a second copy behind the first. Cleared in the alert's completion just before
    /// the relaunch: if termination is ever refused or interrupted (an in-flight
    /// recording's finalize, a hung terminate), a stuck `true` here would otherwise
    /// suppress every future re-offer for the rest of the process lifetime — the
    /// swapped build would sit on disk forever with the user never prompted again.
    private static var relaunchAlertShowing = false

    /// Whether the silent check has failed enough times in a row that the user should
    /// be told (in Settings → About) that auto-update isn't working for them.
    static var isCheckFailing: Bool {
        UserDefaults.standard.integer(forKey: failedChecksKey) >= 3
    }

    private struct Release {
        let tagName: String
    }

    /// Why a check couldn't answer. Separated so the alert can say "rate limited, try
    /// later" instead of blaming the user's network for GitHub's throttle.
    private enum CheckError: Error {
        case rateLimited
        case network
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
            case .failure(let error):
                presentErrorAlert(error as? CheckError ?? .network)
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
        // A prior check already swapped a newer build onto disk; the user just hasn't
        // relaunched into it. Nothing to download — re-offer the relaunch (once a day,
        // via the daily timer) so a missed or ignored prompt isn't gone for good.
        if let pending = UserDefaults.standard.string(forKey: pendingVersionKey),
           isNewer(pending, than: runningVersion) {
            if !relaunchAlertShowing, relaunchWaitTimer == nil {
                if isUserBusy() { waitForIdleThenAlert(pending) } else { presentUpdatedAlert(pending) }
            }
            return
        }
        fetch { result in
            guard case .success(let release) = result else {
                recordCheckFailure()
                scheduleRetry()
                return
            }
            guard isNewer(release.tagName, than: effectiveCurrentVersion),
                  let dmg = dmgURL(for: release) else {
                // A healthy check with nothing to install — the updater works here.
                UserDefaults.standard.removeObject(forKey: failedChecksKey)
                return
            }
            UpdateInstaller.install(dmgURL: dmg, expectedVersion: normalize(release.tagName)) { outcome in
                switch outcome {
                case .success:
                    UserDefaults.standard.removeObject(forKey: failedChecksKey)
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
                case .failure:
                    // A machine where the swap itself can't succeed (the bundle on a
                    // read-only volume — e.g. running straight from the mounted DMG —
                    // or an /Applications copy this user can't write) fails silently
                    // *every* day; count it toward the About warning exactly like a
                    // failing fetch, so those users learn why they're stuck. No 15-min
                    // retry here: re-downloading the DMG on a loop is heavy, and a
                    // permission failure won't heal on its own — the daily tick covers
                    // the transient cases (hdiutil busy, disk full since freed).
                    recordCheckFailure()
                }
            }
        }
    }

    private static func recordCheckFailure() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: failedChecksKey) + 1, forKey: failedChecksKey)
    }

    /// Try again in 15 minutes after a failed fetch, instead of silently sitting out
    /// the remainder of the 24 h interval. One timer, no stacking; a success clears
    /// the failure count on its own.
    private static func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { _ in
            retryTimer = nil
            checkInBackground()
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
        guard let tag = release.tagName
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(dmgAssetName)")
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
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("m_capture", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data, let feed = String(data: data, encoding: .utf8) else {
                // 403/429 is a throttle, not an outage — the status code is the only
                // thing that tells the two apart, so it must not be discarded.
                let reason: CheckError = (status == 403 || status == 429) ? .rateLimited : .network
                DispatchQueue.main.async { completion(.failure(reason)) }
                return
            }
            // Newest first. Drafts never reach the public feed; a tag carrying a
            // pre-release suffix ("1.7.0-beta1") is skipped here since the feed, unlike
            // the API, has no flag for it.
            let tags = releaseTags(in: feed).filter { !$0.contains("-") }
            guard !tags.isEmpty else {
                DispatchQueue.main.async { completion(.failure(CheckError.network)) }
                return
            }
            DispatchQueue.main.async { resolveInstallable(tags, from: 0, completion) }
        }.resume()
    }

    /// Tags in feed order, read off each entry's `…/releases/tag/<tag>` link.
    private static func releaseTags(in feed: String) -> [String] {
        let pattern = "/releases/tag/([^\"]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(feed.startIndex..., in: feed)
        return re.matches(in: feed, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: feed) else { return nil }
            return String(feed[r]).removingPercentEncoding ?? String(feed[r])
        }
    }

    /// Walks the tags newest-first and returns the first one we could actually install.
    /// Only a candidate that's *newer* than what we're running gets its `.dmg` probed:
    /// a release whose asset upload failed must not block updates for everyone, but
    /// there's no reason to spend a request confirming an asset we won't download.
    private static func resolveInstallable(_ tags: [String], from index: Int,
                                           _ completion: @escaping (Result<Release, Error>) -> Void) {
        guard index < tags.count else { completion(.failure(CheckError.network)); return }
        let release = Release(tagName: tags[index])
        guard isNewer(release.tagName, than: effectiveCurrentVersion), let dmg = dmgURL(for: release) else {
            completion(.success(release))
            return
        }
        assetExists(dmg) { exists in
            if exists { completion(.success(release)) }
            else { resolveInstallable(tags, from: index + 1, completion) }
        }
    }

    /// HEAD-probe a derived download URL — the feed can't tell us whether the asset
    /// is really there.
    private static func assetExists(_ url: URL, _ completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("m_capture", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
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
        guard !relaunchAlertShowing else { return }
        relaunchAlertShowing = true
        // The alert is non-modal and the app is usually in the background when the
        // silent check fires — the panel can sit unnoticed behind other windows or on
        // another Space. Badge the Dock tile (and bounce it once) so the user knows
        // something is waiting; cleared on confirm, and a relaunch starts clean anyway.
        NSApp.dockTile.badgeLabel = "1"
        NSApp.requestUserAttention(.informationalRequest)
        BrandAlert(title: L("Update installed"),
                   message: String(format: L("m_capture %@ is ready. Click OK to relaunch."), version),
                   titles: ["OK"], primary: 0, cancel: 0).present { _ in
            relaunchAlertShowing = false
            NSApp.dockTile.badgeLabel = nil
            relaunch()
        }
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

    private static func presentErrorAlert(_ reason: CheckError = .network) {
        let message = reason == .rateLimited
            ? L("GitHub is rate-limiting update checks right now. Try again later.")
            : L("Check the network connection and try again.")
        BrandAlert(title: L("Unable to update"),
                   message: message,
                   titles: [L("Open Releases"), "OK"], primary: 0, cancel: 1).present { choice in
            if choice == 0, let url = URL(string: releasesPage) { NSWorkspace.shared.open(url) }
        }
    }
}

