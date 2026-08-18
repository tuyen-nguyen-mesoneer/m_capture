// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// First-launch self-install into `~/Applications`. The DMG ships no `/Applications` drop
/// target, so the app installs itself: whenever a distributed build is launched from
/// anywhere other than `~/Applications` — a mounted DMG, `~/Downloads`, an App Translocation
/// path, even `/Applications` — it copies itself into `~/Applications`, strips the download
/// quarantine, and relaunches from there. Always landing in the user's own Applications
/// folder means the silent updater can swap the bundle in place without admin rights.
///
/// Only real release builds opt in (the `MCAutoInstall` Info.plist flag, set by `build.sh`
/// for DMG builds), and `--…-demo` inspection launches are skipped — so the dev `--run`
/// loop and the demos never move out of `build/`.
enum Relocator {
    /// Returns `true` if a relocation+relaunch was started — the caller should then bail out
    /// of the rest of launch, since this instance is about to terminate.
    static func relocateToUserApplicationsIfNeeded() -> Bool {
        if CommandLine.arguments.contains(where: { $0.hasSuffix("-demo") }) { return false }
        guard Bundle.main.object(forInfoDictionaryKey: "MCAutoInstall") as? Bool == true else { return false }

        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)

        if bundleURL.path.hasPrefix(userApps.path + "/") { return false }

        let target = userApps.appendingPathComponent(bundleURL.lastPathComponent)
        do {
            try fm.createDirectory(at: userApps, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: bundleURL, to: target)
        } catch {
            return false
        }
        stripQuarantine(target)
        relaunch(at: target)
        return true
    }

    /// Drop the download quarantine on the installed copy so the relaunch — and every launch
    /// after — doesn't trip Gatekeeper (the user already approved this build to get this far).
    private static func stripQuarantine(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", app.path]
        try? p.run()
        p.waitUntilExit()
    }

    /// Wait for this process to exit, then open the freshly installed copy.
    ///
    /// Launch flags are forwarded, because `open` drops the original argv: without this a
    /// build started with `--simulate-recording` silently came up in normal mode after
    /// relocating, which reads as the flag being ignored. Only our own `--…` flags are
    /// passed on, each quoted.
    private static func relaunch(at app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }
        let argsClause = flags.isEmpty ? ""
            : " --args " + flags.map { "\"\($0)\"" }.joined(separator: " ")
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"\(app.path)\"\(argsClause)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        try? proc.run()
        NSApp.terminate(nil)
    }
}

