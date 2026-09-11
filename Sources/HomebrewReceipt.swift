// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import Foundation

/// Keeps Homebrew's record of the installed cask in step with a build the app swapped in
/// itself.
///
/// The cask installs into `~/Applications` — the very bundle `UpdateInstaller` replaces —
/// but nothing tells Homebrew when that happens, so its receipt stays frozen at whatever
/// it installed. `brew list --cask --versions m_capture` then reports a version that has
/// not been on disk for weeks, and `brew upgrade --greedy` (which ignores the cask's
/// `auto_updates true`) re-downloads a DMG the user already has. Re-stamping the receipt
/// makes the first honest and the second a no-op.
///
/// **Every failure here is silent and harmless.** This reaches into another tool's private
/// layout, so it is written to give up rather than guess: a Homebrew that has moved its
/// files, or an install that isn't ours, leaves the receipt exactly as it found it. An
/// update must never fail because the bookkeeping afterwards did.
enum HomebrewReceipt {
    /// The cask token, which is also the Caskroom directory and the artifact's name.
    private static let token = "m_capture"
    private static let appName = "m_capture.app"

    /// Point Homebrew's receipt at `version`, if this bundle is the one a cask installed.
    ///
    /// Called after a successful swap. Homebrew derives the installed version from the
    /// `<version>` segment of `.metadata/<version>/<timestamp>/Casks/<token>.json`
    /// (`Cask#installed_version`), while `uninstall` and `upgrade` work from the sibling
    /// `Caskroom/<token>/<version>` directory — so both are renamed, and the receipt's own
    /// `source.version` is rewritten to match.
    static func restamp(to version: String) {
        let fm = FileManager.default
        guard let cask = caskroomDirectory(),
              tracksThisBundle(cask),
              let recorded = recordedVersion(in: cask),
              recorded != version else { return }

        let metadata = cask.appendingPathComponent(".metadata", isDirectory: true)
        let moves = [
            (cask.appendingPathComponent(recorded), cask.appendingPathComponent(version)),
            (metadata.appendingPathComponent(recorded), metadata.appendingPathComponent(version)),
        ]
        // A destination that already exists means some other version is half-recorded here;
        // renaming onto it would destroy a record we don't understand.
        guard moves.allSatisfy({ !fm.fileExists(atPath: $0.1.path) }) else { return }
        for (from, to) in moves {
            guard (try? fm.moveItem(at: from, to: to)) != nil else { return }
        }
        rewriteReceiptVersion(in: metadata, to: version)
    }

    /// `Caskroom/<token>` under whichever prefix Homebrew uses, or nil if the app wasn't
    /// installed by a cask. `HOMEBREW_PREFIX` is honoured for a non-standard prefix, but
    /// the app is not launched from a shell, so the two stock prefixes are the real path.
    private static func caskroomDirectory() -> URL? {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let env = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !env.isEmpty {
            prefixes.insert(env, at: 0)
        }
        return prefixes
            .map { URL(fileURLWithPath: $0).appendingPathComponent("Caskroom/\(token)", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// True when the cask's app artifact is a symlink to *this* bundle. Without the check a
    /// second copy of m_capture — a hand-installed one in `/Applications`, say — would have
    /// its receipt rewritten to a version it isn't running.
    private static func tracksThisBundle(_ cask: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cask.path) else { return false }
        let ours = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return entries.contains { entry in
            let link = cask.appendingPathComponent(entry).appendingPathComponent(appName)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return false }
            return URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.path == ours
        }
    }

    /// The version Homebrew currently believes is installed. Deliberately read off disk
    /// rather than assumed to be the running build: the app may have self-updated several
    /// times since the cask was installed, so the receipt can be arbitrarily far behind.
    /// More than one recorded version is a state we didn't write and won't rewrite.
    private static func recordedVersion(in cask: URL) -> String? {
        let metadata = cask.appendingPathComponent(".metadata", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: metadata, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return nil }
        let versions = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard versions.count == 1 else { return nil }
        return versions[0].lastPathComponent
    }

    /// `INSTALL_RECEIPT.json` carries the version a second time, under `source`. Homebrew
    /// reads the directory name rather than this, so a failure here is cosmetic — but a
    /// receipt disagreeing with its own path is exactly the confusion this whole file exists
    /// to remove.
    private static func rewriteReceiptVersion(in metadata: URL, to version: String) {
        let receipt = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
        guard let data = try? Data(contentsOf: receipt),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var source = json["source"] as? [String: Any] else { return }
        source["version"] = version
        json["source"] = source
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? out.write(to: receipt, options: .atomic)
    }
}
