// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import Network

/// Checks GitHub Releases for a newer build — no dependencies, just URLSession and some
/// regex over the Atom feed — and drives the install.
///
/// **Nothing installs without the user agreeing to it.** A check that finds a newer
/// release records it and *offers* it, with what changed, read out of the feed entry; the
/// download and disk swap only start once Install is clicked, and the relaunch after that
/// is a second, equally declinable question. (An earlier version did the whole thing
/// silently and only asked about the relaunch — quicker to be current, but it swapped the
/// app out from under people without telling them what had changed.)
///
/// Two entry points:
///
/// - `checkIfDue(_:)` — the gated background path (see `scheduleBackgroundChecks`).
///   Silent unless it finds something; failures are recorded, not announced.
/// - `checkManually()` — the "Check for Updates" item; always reports an outcome, and
///   shows anything already outstanding rather than claiming to be up to date.
///
/// Everything the user still owes — an offered release, or an installed build waiting on
/// a relaunch — is one value, `pendingAction`, which drives the menu-bar badge, the menu
/// item and which prompt appears. "Later" is remembered per version for a day, so a
/// deferred offer doesn't come back every quarter of an hour.
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

    /// How long a *successful* check stays good for — the background cadence.
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// How stale a check may be when the user is demonstrably at the machine (launch,
    /// activation, opening the menu). Shorter than `checkInterval` because those are the
    /// moments someone would have reached for "Check for Updates" themselves.
    private static let presenceInterval: TimeInterval = 60 * 60
    /// The heartbeat period, and the floor between two attempts — one value doing both
    /// jobs: a failed attempt is retried at the next beat, while a successful one is held
    /// off by `checkInterval` instead. Replaces the old one-shot retry timer.
    private static let retryInterval: TimeInterval = 15 * 60

    /// Beats `checkIfDue()`. Deliberately *not* the schedule itself: a run-loop timer is
    /// suspended while the Mac sleeps and its interval counts awake time only, which is
    /// how a "daily" check quietly became every few days for anyone who never quits the
    /// app. The wall-clock stamps below are the schedule; this only prompts a re-read.
    private static var heartbeatTimer: Timer?

    /// Polls until the user is idle so a relaunch alert deferred by `isUserBusy()` still
    /// fires once they finish, instead of being dropped until the next daily check.
    private static var relaunchWaitTimer: Timer?

    /// Watches for the offline→online edge. The launch check fires the moment a login
    /// item starts — routinely *before* Wi-Fi/VPN is up — so for those users the first
    /// attempt of every session failed and nothing retried until the next beat.
    private static var pathMonitor: NWPathMonitor?
    private static var wasOffline = false
    private static var wakeObserver: NSObjectProtocol?

    /// True while a fetch is in flight, so the triggers below can't stack requests.
    private static var isChecking = false

    /// When a check last *got an answer* — the schedule's source of truth.
    private static let lastSuccessKey = "updater.lastSuccessfulCheck"
    /// When we last tried at all, successfully or not — the anti-hammering floor.
    private static let lastAttemptKey = "updater.lastAttempt"
    /// Why the last check failed, so Settings → About can name the cause instead of
    /// always blaming the network.
    private static let failureReasonKey = "updater.lastFailureReason"

    /// Fired on the main queue whenever what the user owes changes — a release becomes
    /// available, or a build lands on disk awaiting a relaunch — so the menu bar and the
    /// status menu can re-read `pendingAction`.
    static var onPendingChange: (() -> Void)?

    /// Fired around an explicit install so the menu bar can show it is working. The
    /// download and swap take tens of seconds; having clicked Install and then watched
    /// nothing happen at all, people reasonably conclude the app is broken.
    static var onInstallProgress: ((Bool) -> Void)?

    /// What prompted a check, and therefore how much of the gate it may skip.
    enum Trigger {
        /// The heartbeat — the full background cadence.
        case scheduled
        /// Launch, activation, reopen, opening the menu: the user is at the machine.
        case userPresent
        /// A usable network path just came back, so whatever broke the last attempt is
        /// demonstrably gone.
        case networkReturn
    }

    /// A build we've already swapped onto disk but haven't relaunched into yet. Kept so
    /// the launch check doesn't see the just-installed release as "newer" and reinstall it.
    private static let pendingVersionKey = "updater.pendingVersion"

    /// The raw tag of a newer release the user has been told about but not installed.
    /// Raw rather than normalized, because the download URL is derived from the tag.
    private static let availableTagKey = "updater.availableTag"
    /// Its notes, kept so a deferred offer can be shown again without refetching.
    private static let availableNotesKey = "updater.availableNotes"

    /// "Later" memory: which version was declined, and when. Without it every trigger
    /// would re-ask within minutes — the surest way to train someone to dismiss an
    /// update prompt without reading it.
    private static let snoozedVersionKey = "updater.snoozedVersion"
    private static let snoozedAtKey = "updater.snoozedAt"
    private static let snoozeInterval: TimeInterval = 24 * 60 * 60

    /// Consecutive silent-check fetch failures, persisted so Settings → About can
    /// surface a chronically blocked updater (proxy, rate limit, private repo).
    private static let failedChecksKey = "updater.failedChecks"

    /// True while the relaunch alert is on screen, so a daily re-prompt doesn't stack
    /// a second copy behind the first. Cleared in the alert's completion just before
    /// the relaunch: if termination is ever refused or interrupted (an in-flight
    /// recording's finalize, a hung terminate), a stuck `true` here would otherwise
    /// suppress every future re-offer for the rest of the process lifetime — the
    /// swapped build would sit on disk forever with the user never prompted again.
    private static var alertShowing = false

    /// Whether the silent check has failed enough times in a row that the user should
    /// be told (in Settings → About) that auto-update isn't working for them.
    private static var isCheckFailing: Bool {
        UserDefaults.standard.integer(forKey: failedChecksKey) >= 3
    }

    private struct Release {
        let tagName: String
        /// This release's own change lines, cleaned of provenance. Empty when the feed
        /// entry carried no body.
        let items: [String]
        /// Every unseen version's lines, formatted for the offer. Filled in when a
        /// release is resolved as installable; nil on the entries it was chosen from.
        var notes: String?
    }

    /// Ceiling on the change log in the offer. This is a prompt, not a changelog: past a
    /// certain length people stop reading and start dismissing.
    private static let maxNoteLines = 14

    /// Why a check couldn't answer. Separated so the alert can say "rate limited, try
    /// later" instead of blaming the user's network for GitHub's throttle.
    private enum CheckError: String, Error {
        case rateLimited
        case network
        /// Reaching GitHub worked; putting the build on disk didn't (a read-only volume,
        /// an /Applications copy this user can't write). Silent before — and those users
        /// never update — so it gets its own reason and its own message in About.
        case cantInstall
    }

    /// The version baked into the running bundle (the *old* one even after a swap, since
    /// `Bundle.main` is fixed at launch).
    private static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A newer build already swapped onto disk, waiting for a relaunch to take effect.
    /// The single source for "an update is pending" — the menu item, the menu-bar badge
    /// and the re-offer all read it, so none of them can drift out of step.
    static var stagedVersion: String? {
        guard let pending = UserDefaults.standard.string(forKey: pendingVersionKey),
              isNewer(pending, than: runningVersion) else { return nil }
        return pending
    }

    /// What releases are compared against: the running build, or a newer build already
    /// swapped onto disk and awaiting a relaunch. Prevents reinstalling the same release.
    static var effectiveCurrentVersion: String { stagedVersion ?? runningVersion }

    /// The raw tag of a newer release the user has been told about but hasn't installed.
    /// Goes nil on its own once that release stops being newer than what we have, so
    /// installing needs no separate cleanup.
    static var availableTag: String? {
        guard let tag = UserDefaults.standard.string(forKey: availableTagKey),
              isNewer(tag, than: effectiveCurrentVersion) else { return nil }
        return tag
    }

    private static var availableNotes: String? {
        demoAction != nil ? demoNotes : UserDefaults.standard.string(forKey: availableNotesKey)
    }

    /// What the user still has to act on. A single value drives the menu-bar badge, the
    /// menu item and which prompt appears, so those three can never disagree about what
    /// is outstanding.
    enum PendingAction {
        /// A newer release we have told them about but have not installed.
        case install(String)
        /// A build already on disk, waiting for a relaunch to take effect.
        case relaunch(String)

        var version: String {
            switch self {
            case .install(let v), .relaunch(let v): return v
            }
        }
    }

    static var pendingAction: PendingAction? {
        if let demo = demoAction { return demo }
        if let staged = stagedVersion { return .relaunch(staged) }
        if let tag = availableTag { return .install(normalize(tag)) }
        return nil
    }

    /// "Last checked" for Settings → About. An absolute short timestamp rather than a
    /// relative phrase, so it needs no vocabulary of its own in three languages.
    static var lastCheckDescription: String {
        guard let then = UserDefaults.standard.object(forKey: lastSuccessKey) as? Date else {
            return L("Never")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: then)
    }

    /// What to tell the user when the silent check keeps failing — named by cause, since
    /// "check your network" is actively misleading for a rate limit, or for a bundle we
    /// simply can't write to.
    static var checkFailureMessage: String? {
        guard isCheckFailing else { return nil }
        switch UserDefaults.standard.string(forKey: failureReasonKey).flatMap(CheckError.init(rawValue:)) {
        case .rateLimited:
            return L("GitHub is rate-limiting update checks right now. Try again later.")
        case .cantInstall:
            return L("Updates can't be installed — move m_capture to your Applications folder.")
        default:
            return L("Automatic update checks are failing — check network access to GitHub.")
        }
    }

    /// Drop the pending marker once a relaunch has actually picked up that build (or newer).
    /// Call once at launch.
    static func reconcileAfterRelaunch() {
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: pendingVersionKey) else { return }
        if !isNewer(pending, than: runningVersion) { defaults.removeObject(forKey: pendingVersionKey) }
    }

    private static func markInstalled(_ version: String) {
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: pendingVersionKey)
        // The offer has been answered — drop its bookkeeping so `pendingAction` reports
        // the relaunch rather than an install that already happened.
        defaults.removeObject(forKey: availableTagKey)
        defaults.removeObject(forKey: availableNotesKey)
        defaults.removeObject(forKey: snoozedVersionKey)
        onPendingChange?()
    }

    private static func setAvailable(_ release: Release) {
        let defaults = UserDefaults.standard
        defaults.set(release.tagName, forKey: availableTagKey)
        if let notes = release.notes { defaults.set(notes, forKey: availableNotesKey) }
        else { defaults.removeObject(forKey: availableNotesKey) }
        onPendingChange?()
    }

    private static func clearAvailable() {
        guard UserDefaults.standard.string(forKey: availableTagKey) != nil else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: availableTagKey)
        defaults.removeObject(forKey: availableNotesKey)
        onPendingChange?()
    }

    /// Remember a dismissed offer. The badge and the menu item stay put meanwhile, so
    /// this defers the interruption without losing the update.
    private static func snooze(_ version: String) {
        guard demoAction == nil else { return }
        UserDefaults.standard.set(version, forKey: snoozedVersionKey)
        stamp(snoozedAtKey)
    }

    /// A snooze covers only the exact version that was declined: ship something newer
    /// and the user hears about it straight away.
    private static func isSnoozed(_ version: String) -> Bool {
        UserDefaults.standard.string(forKey: snoozedVersionKey) == version
            && elapsed(since: snoozedAtKey) < snoozeInterval
    }

    /// Manual check — always tells the user the outcome (up to date / available /
    /// couldn't check), and installs on demand.
    static func checkManually() {
        // Something may already be outstanding — a release offered and deferred, or a
        // build staged and waiting on a relaunch. `effectiveCurrentVersion` counts a
        // staged build as current, so without this the user would be told "up to date"
        // while an update sat there waiting. Forced: asking to check is asking to be
        // told, so neither a snooze nor a busy editor may swallow the answer.
        if pendingAction != nil {
            offerPending(force: true)
            return
        }
        stamp(lastAttemptKey)
        fetch { result in
            switch result {
            case .success(let release) where isNewer(release.tagName, than: effectiveCurrentVersion):
                stamp(lastSuccessKey)
                clearFailures()
                setAvailable(release)
                offerPending(force: true)
            case .success:
                // Reaching GitHub at all clears the "updates are failing" warning: the
                // path demonstrably works, whatever it was doing before.
                stamp(lastSuccessKey)
                clearFailures()
                clearAvailable()
                presentUpToDateAlert()
            case .failure(let error):
                // Deliberately not counted toward `failedChecksKey` — that warning is
                // about the *silent* check going unnoticed, and this one just told the
                // user to their face.
                presentErrorAlert(error as? CheckError ?? .network)
            }
        }
    }

    /// Wire up every trigger, then check once for this launch.
    ///
    /// m_capture is a menu-bar agent that's rarely quit, so the periodic path — not the
    /// launch path — is what actually keeps people current. That used to be a repeating
    /// 24 h `Timer`, which is only "daily" on a Mac that never sleeps: run-loop timers
    /// don't fire while the machine is asleep, so a laptop that's shut most of the day
    /// stretched every interval into several calendar days, and a release could sit
    /// unnoticed for a week with the app running the whole time. The schedule now lives
    /// in wall-clock stamps that survive sleep (and quitting), and a spread of cheap
    /// triggers re-read them: the beat below, waking, the user showing up, the network
    /// coming back.
    static func scheduleBackgroundChecks() {
        // Dev switch: forget the recorded schedule so the update path can be exercised
        // without waiting out a real interval.
        if CommandLine.arguments.contains("--update-debug") {
            UserDefaults.standard.removeObject(forKey: lastSuccessKey)
            UserDefaults.standard.removeObject(forKey: lastAttemptKey)
        }
        startNetworkWatch()
        observeWake()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { _ in
            checkIfDue()
        }
        checkIfDue(.userPresent)
    }

    /// The one gate every trigger funnels through — the only place the cadence is
    /// decided. Because it reads the wall clock rather than a timer's progress, nothing
    /// that stops time for the process (sleep, a suspended run loop, the app sitting
    /// quit for a week) can stretch the interval: whatever wakes the app next re-reads
    /// the same two stamps and acts on them.
    static func checkIfDue(_ trigger: Trigger = .scheduled) {
        guard !isChecking, !UpdateInstaller.isInstalling else { return }
        // A build is already staged — it's on disk, there is nothing to fetch. Just make
        // sure its relaunch offer is still in front of the user. A release that's merely
        // *available* deliberately does not short-circuit: we keep checking so a newer
        // one supersedes a deferred offer instead of waiting behind it.
        if stagedVersion != nil { offerPending(); return }
        // A network return is exempt from the floor: the thing that broke the last
        // attempt demonstrably just changed, so waiting it out waits for nothing.
        if trigger != .networkReturn, elapsed(since: lastAttemptKey) < retryInterval { return }
        let staleness = trigger == .scheduled ? checkInterval : presenceInterval
        guard elapsed(since: lastSuccessKey) >= staleness else { return }
        checkInBackground()
    }

    /// A Mac that slept through its next check wakes with the timer still counting from
    /// wherever it left off; re-reading the stamps on wake is what turns the cadence
    /// back into calendar time.
    private static func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            checkIfDue()
        }
    }

    /// Check the moment a usable path comes back. Two very common cases never resolved
    /// themselves before: a login item that starts before Wi-Fi/VPN is up (its launch
    /// check always failed), and a laptop reopened somewhere new. Only the offline→online
    /// edge counts — the handler also fires for interface changes that change nothing.
    private static func startNetworkWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                let satisfied = path.status == .satisfied
                defer { wasOffline = !satisfied }
                guard satisfied, wasOffline else { return }
                checkIfDue(.networkReturn)
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.mesoneer.mcapture.network-watch"))
        pathMonitor = monitor
    }

    /// Put whatever is outstanding back in front of the user. Every nudge goes through
    /// here, so no caller can bypass the two rules that keep it civil: never interrupt a
    /// capture, and never re-ask about a version that was just declined.
    ///
    /// Once a build is swapped in, `effectiveCurrentVersion` reports that release as
    /// current and no later check will ever see it as "newer" again — so if this stopped
    /// offering, the build would sit on disk forever with the user never told.
    ///
    /// - Parameter force: for an explicitly requested check, where staying silent would
    ///   read as the app ignoring the click.
    private static func offerPending(force: Bool = false) {
        guard let action = pendingAction, !alertShowing else { return }
        if !force {
            guard relaunchWaitTimer == nil, !isSnoozed(action.version) else { return }
            guard !isUserBusy() else { waitForIdleThenOffer(); return }
        }
        switch action {
        case .install(let version): presentAvailableAlert(version)
        case .relaunch(let version): presentRelaunchAlert(version)
        }
    }

    /// Download and swap in the available release. Only ever reached from an explicit
    /// Install, which is why — unlike the old unattended path — a failure is reported
    /// rather than swallowed: someone is sitting there waiting on it.
    private static func install() {
        if let demo = demoAction { demoInstall(demo.version); return }
        guard let tag = availableTag, let dmg = dmgURL(for: tag) else {
            presentInstallFailedAlert()
            return
        }
        let version = normalize(tag)
        onInstallProgress?(true)
        UpdateInstaller.install(dmgURL: dmg, expectedVersion: version) { outcome in
            onInstallProgress?(false)
            switch outcome {
            case .success:
                clearFailures()
                markInstalled(version)
                offerPending(force: true)
            case .failure:
                // A machine where the swap can't succeed (the bundle on a read-only
                // volume — running straight from the mounted DMG — or an /Applications
                // copy this user can't write) fails this way every time, so it's also
                // counted toward the About warning.
                recordCheckFailure(.cantInstall)
                presentInstallFailedAlert()
            }
        }
    }

    /// Background check. It *offers* a newer build — with what changed — and installs
    /// nothing until the user says so; swapping the app out from under someone without
    /// asking is not ours to do. Failures stay silent here (nobody asked, so nobody is
    /// waiting) but are recorded, so About can say why someone has been stuck. Call
    /// `checkIfDue(_:)` instead unless you mean "regardless of when we last looked".
    static func checkInBackground() {
        guard !isChecking, !UpdateInstaller.isInstalling else { return }
        if stagedVersion != nil { offerPending(); return }
        isChecking = true
        stamp(lastAttemptKey)
        fetch { result in
            isChecking = false
            switch result {
            case .failure(let error):
                recordCheckFailure(error as? CheckError ?? .network)
            case .success(let release):
                stamp(lastSuccessKey)
                clearFailures()
                guard isNewer(release.tagName, than: effectiveCurrentVersion) else {
                    // A healthy check with nothing to install — the updater works here.
                    clearAvailable()
                    return
                }
                // `resolveInstallable` has already confirmed this release has a
                // downloadable asset, so the offer can't dead-end on a missing .dmg.
                setAvailable(release)
                offerPending()
            }
        }
    }

    private static func stamp(_ key: String) {
        UserDefaults.standard.set(Date(), forKey: key)
    }

    /// Seconds since `key` was stamped; "forever" when it never was. A stamp in the
    /// *future* — a clock correction, a restored backup — counts as forever too, since
    /// otherwise it would hold the gate shut until the clock caught up with it.
    private static func elapsed(since key: String) -> TimeInterval {
        guard let then = UserDefaults.standard.object(forKey: key) as? Date else {
            return .greatestFiniteMagnitude
        }
        let delta = Date().timeIntervalSince(then)
        return delta < 0 ? .greatestFiniteMagnitude : delta
    }

    private static func recordCheckFailure(_ reason: CheckError) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: failedChecksKey) + 1, forKey: failedChecksKey)
        defaults.set(reason.rawValue, forKey: failureReasonKey)
    }

    private static func clearFailures() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: failedChecksKey)
        defaults.removeObject(forKey: failureReasonKey)
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
    /// A later call (e.g. the next check finding yet another release) restarts the wait
    /// rather than stacking timers; what it offers is re-read from `pendingAction`.
    private static func waitForIdleThenOffer() {
        relaunchWaitTimer?.invalidate()
        relaunchWaitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            guard !isUserBusy() else { return }
            timer.invalidate()
            relaunchWaitTimer = nil
            offerPending()
        }
    }

    private static func dmgURL(for tag: String) -> URL? {
        guard let tag = tag
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(dmgAssetName)")
    }

    // MARK: - Demo

    /// In-memory stand-in for `pendingAction` while `--update-demo` runs, so the badge,
    /// the menu item and both prompts can be looked at without writing a single default
    /// or downloading a byte. Quitting clears it — there is nothing to clean up after.
    private static var demoAction: PendingAction?
    private static var demoNotes: String?

    /// Dev switch (`--update-demo`): walk the real update screens — menu-bar badge, the
    /// offer with what changed, the "Updating…" indicator, the relaunch prompt — using
    /// the newest release's *actual* notes, installing nothing.
    ///
    /// It deliberately drives the shipping code path rather than a parallel mock: the
    /// only difference is three guards (`install`, `snooze`, `relaunch`), so what you see
    /// here is what a real update looks like.
    static func runDemo() {
        let version = demoVersion()
        fetchReleases { result in
            // The newest few entries, formatted as though all were unseen — the point is
            // to show what someone several versions behind actually reads. The top one is
            // relabelled to the demo version so the list agrees with the alert's title.
            demoNotes = (try? result.get()).flatMap { releases -> String? in
                var shown = Array(releases.prefix(3))
                guard !shown.isEmpty else { return nil }
                shown[0] = Release(tagName: version, items: shown[0].items)
                return changeLog(shown[...])
            }
            demoAction = .install(version)
            onPendingChange?()
            offerPending(force: true)
        }
    }

    /// The install, minus the install: same progress signal, same follow-up prompt.
    private static func demoInstall(_ version: String) {
        onInstallProgress?(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            onInstallProgress?(false)
            demoAction = .relaunch(version)
            onPendingChange?()
            offerPending(force: true)
        }
    }

    /// One minor version above whatever is running, so the demo reads plausibly from
    /// whichever build it's launched out of.
    private static func demoVersion() -> String {
        var parts = normalize(runningVersion).split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        parts[1] += 1
        parts[2] = 0
        return parts.map(String.init).joined(separator: ".")
    }

    /// The status menu's update item: show whatever is outstanding, right now.
    static func showPending() { offerPending(force: true) }

    /// Relaunch on the user's explicit say-so — the "Relaunch to Finish Update" menu
    /// item. Pins hold captures that were never saved anywhere, so closing them warrants
    /// a confirm; but only when there is actually something to lose, since the ordinary
    /// case deserves a single click rather than a dialog nobody needed. The staged build
    /// is already on disk either way, so declining costs nothing.
    static func relaunchFromMenu() {
        guard PinnedWindowController.hasOpenWindows else { relaunch(); return }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = BrandAlert(title: L("Relaunch now?"),
                                 message: L("Pinned windows will close."),
                                 titles: [L("Relaunch"), L("Cancel")],
                                 primary: 0, cancel: 1, icon: "arrow.clockwise").runModal()
        guard confirm == 0 else { return }
        relaunch()
    }

    /// Quit and reopen the bundle. A detached shell waits for this process to
    /// exit, then relaunches — it outlives our own termination. Internal because
    /// Settings' language switch also restarts through it.
    static func relaunch() {
        // Every route into a relaunch passes through here, so the demo is stopped once,
        // in one place, rather than in each of the callers.
        if demoAction != nil {
            demoAction = nil
            onPendingChange?()
            BrandToast.show("Update demo — the real thing would relaunch here.")
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"\(path)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        try? proc.run()
        NSApp.terminate(nil)
    }

    /// Fetch and pick: the newest release we could actually install, carrying the notes
    /// for every version this user hasn't got yet.
    private static func fetch(_ completion: @escaping (Result<Release, Error>) -> Void) {
        fetchReleases { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let releases): resolveInstallable(releases, from: 0, completion)
            }
        }
    }

    private static func fetchReleases(_ completion: @escaping (Result<[Release], Error>) -> Void) {
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
            let releases = entries(in: feed).filter { !$0.tagName.contains("-") }
            guard !releases.isEmpty else {
                DispatchQueue.main.async { completion(.failure(CheckError.network)) }
                return
            }
            DispatchQueue.main.async { completion(.success(releases)) }
        }.resume()
    }

    /// Releases in feed order (newest first): the tag off each entry's
    /// `…/releases/tag/<tag>` link, plus that entry's notes.
    private static func entries(in feed: String) -> [Release] {
        feed.components(separatedBy: "<entry").dropFirst().compactMap { entry in
            guard let tag = firstGroup("/releases/tag/([^\"]+)\"", in: entry) else { return nil }
            return Release(tagName: tag.removingPercentEncoding ?? tag, items: items(in: entry))
        }
    }

    /// One release's change lines.
    ///
    /// The feed carries the release body as HTML escaped into XML. GitHub's generated
    /// notes are a `<ul>` of pull-request titles, each with a " by @someone in #44"
    /// trailer that means nothing to the person deciding whether to install — so the list
    /// items are pulled out and the provenance dropped. A hand-written body with no list
    /// falls back to its own text.
    private static func items(in entry: String) -> [String] {
        guard let raw = firstGroup("<content[^>]*>(.*?)</content>", in: entry) else { return [] }
        let html = unescape(raw)
        var lines = allGroups("<li[^>]*>(.*?)</li>", in: html).map(stripTags)
        if lines.isEmpty { lines = stripTags(html).components(separatedBy: "\n") }

        return lines.map { line -> String in
            var text = line
            for pattern in [" by @[^ ]+ in #[0-9]+$",              // provenance, not news
                            " [—-] v?[0-9]+(\\.[0-9]+)*$"] {        // the version its heading already gives
                if let r = text.range(of: pattern, options: .regularExpression) {
                    text = String(text[..<r.lowerBound])
                }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty && $0 != "What\u{2019}s Changed" && $0 != "What's Changed"
                    && !$0.hasPrefix("Full Changelog") }
    }

    /// The change log for the offer: **every** version the user hasn't got, newest first,
    /// each under its own number.
    ///
    /// Not just the newest one — somebody who skipped three releases is being asked to
    /// take all three at once, so all three are what they get to read. Someone updating
    /// from months ago is exactly the person who most needs to see what changed.
    private static func changeLog(_ releases: ArraySlice<Release>) -> String? {
        var lines: [String] = []
        var truncated = false
        for release in releases where !release.items.isEmpty {
            guard lines.count < maxNoteLines else { truncated = true; break }
            if !lines.isEmpty { lines.append("") }
            lines.append(normalize(release.tagName))
            for item in release.items {
                guard lines.count < maxNoteLines else { truncated = true; break }
                lines.append(fit("•  " + item))
            }
        }
        guard !lines.isEmpty else { return nil }
        if truncated { lines.append("…") }
        return lines.joined(separator: "\n")
    }

    /// Trim a line to what the offer alert shows without wrapping. A character count
    /// can't do this job: the same ninety characters run from 480 pt to 660 pt depending
    /// on which characters they are, so the cap has to be measured in the actual font.
    private static func fit(_ line: String) -> String {
        let font = Theme.font(12)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        guard width(line) > BrandAlert.wideMessageWidth else { return line }
        var text = line
        while !text.isEmpty, width(text + "…") > BrandAlert.wideMessageWidth {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The offer's body with each version heading picked out in brand lavender.
    ///
    /// Derived from the shape of the lines rather than stored as styling: `availableNotes`
    /// stays plain text in `UserDefaults`, which is what wants persisting.
    private static func styledMessage(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: Theme.font(12),
            .foregroundColor: Theme.textMuted,
            .paragraphStyle: paragraph,
        ])
        // A line that is nothing but a version number is a heading.
        let headings = try? NSRegularExpression(pattern: "^[0-9]+(\\.[0-9]+)+$",
                                                options: [.anchorsMatchLines])
        headings?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let range = match?.range else { return }
            body.addAttributes([.font: Theme.font(12, .bold),
                                .foregroundColor: Theme.lavender], range: range)
        }
        return body
    }

    /// The five XML entities GitHub's feed actually uses. A full parser would be more
    /// than this needs — the content is machine-generated and its shape is stable.
    private static func unescape(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "\u{2019}"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        allGroups(pattern, in: text).first
    }

    private static func allGroups(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Walks the releases newest-first and returns the first we could actually install.
    /// Only a candidate that's *newer* than what we're running gets its `.dmg` probed:
    /// a release whose asset upload failed must not block updates for everyone, but
    /// there's no reason to spend a request confirming an asset we won't download.
    private static func resolveInstallable(_ releases: [Release], from index: Int,
                                           _ completion: @escaping (Result<Release, Error>) -> Void) {
        guard index < releases.count else { completion(.failure(CheckError.network)); return }
        let release = releases[index]
        guard isNewer(release.tagName, than: effectiveCurrentVersion),
              let dmg = dmgURL(for: release.tagName) else {
            completion(.success(release))
            return
        }
        assetExists(dmg) { exists in
            guard exists else { resolveInstallable(releases, from: index + 1, completion); return }
            // Everything from the installable release down to the first one this user
            // already has. Feed order is newest-first, so that's a plain prefix.
            let unseen = releases[index...].prefix { isNewer($0.tagName, than: effectiveCurrentVersion) }
            var resolved = release
            resolved.notes = changeLog(unseen)
            completion(.success(resolved))
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
    /// The offer — what changed, and a choice. The only place an update is ever
    /// described, and the only place it's ever agreed to. Presentation is split from the
    /// decision so `--update-demo` puts the *shipping* alert on screen rather than a
    /// look-alike that can drift away from it.
    private static func presentOffer(_ version: String, notes: String?,
                                     _ done: @escaping (Bool) -> Void) {
        guard !alertShowing else { return }
        alertShowing = true
        announce()
        var message = String(format: L("m_capture %@ is available."), version)
        if let notes, !notes.isEmpty { message += "\n\n" + notes }
        BrandAlert(title: L("Update available"),
                   message: message,
                   titles: [L("Install"), L("Later")], primary: 0, cancel: 1,
                   icon: "arrow.down.circle",
                   maxWidth: BrandAlert.wideMessageWidth,
                   attributedMessage: styledMessage(message)).present { choice in
            alertShowing = false
            NSApp.dockTile.badgeLabel = nil
            done(choice == 0)
        }
    }

    private static func presentAvailableAlert(_ version: String) {
        presentOffer(version, notes: availableNotes) { confirmed in
            if confirmed { install() } else { snooze(version) }
        }
    }

    /// Offered once the build is on disk. Declining is safe and costs nothing — the swap
    /// has already happened, so the next ordinary launch picks it up regardless.
    private static func presentRelaunchPrompt(_ version: String,
                                              _ done: @escaping (Bool) -> Void) {
        guard !alertShowing else { return }
        alertShowing = true
        announce()
        // Pins hold captures that were never saved anywhere, so say so rather than
        // taking them away without warning.
        var message = String(format: L("m_capture %@ is installed."), version)
        if PinnedWindowController.hasOpenWindows {
            message += "\n\n" + L("Pinned windows will close.")
        }
        BrandAlert(title: L("Update installed"),
                   message: message,
                   titles: [L("Relaunch"), L("Later")], primary: 0, cancel: 1,
                   icon: "arrow.clockwise").present { choice in
            alertShowing = false
            NSApp.dockTile.badgeLabel = nil
            done(choice == 0)
        }
    }

    private static func presentRelaunchAlert(_ version: String) {
        presentRelaunchPrompt(version) { confirmed in
            if confirmed { relaunch() } else { snooze(version) }
        }
    }

    /// These alerts are non-modal and the app is usually in the background when a check
    /// fires, so the panel can sit unnoticed behind other windows or on another Space.
    /// Badge the Dock tile and bounce it once so the user knows something is waiting.
    private static func announce() {
        NSApp.dockTile.badgeLabel = "1"
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// The user asked for this install and is waiting on it, so unlike a background
    /// fetch failure it has to be said out loud.
    private static func presentInstallFailedAlert() {
        BrandAlert(title: L("Unable to update"),
                   message: L("The update could not be installed."),
                   titles: [L("Open Releases"), "OK"], primary: 0, cancel: 1).present { choice in
            if choice == 0, let url = URL(string: releasesPage) { NSWorkspace.shared.open(url) }
        }
    }

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

