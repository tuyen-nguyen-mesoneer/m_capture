// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// UI-free mechanics for applying an update in place: download the release `.dmg`,
/// mount it, copy the app out, and atomically swap it over the installed bundle.
///
/// The swap takes effect on the *next* launch — the running process keeps executing
/// from its old (now-relocated) inode, so replacing the on-disk bundle while running is
/// safe. Downloading via `URLSession` sets no `com.apple.quarantine` xattr, so the
/// swapped app doesn't re-trigger Gatekeeper on relaunch, and (when releases share the
/// `m_capture-release` signing identity) the Screen Recording grant carries over.
enum UpdateInstaller {
    /// True while a download/swap is in flight, so the background and manual paths can't
    /// kick off two installs at once. Only touched on the main queue.
    private(set) static var isInstalling = false

    enum InstallError: Error { case busy, download, noMountPoint, appNotFound, notNewer, versionMismatch }

    /// Download `dmgURL`, mount it, and atomically swap `m_capture.app` over the running
    /// bundle. `completion` fires on the main queue; on `.success` the new build is on disk.
    static func install(dmgURL: URL, expectedVersion: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isInstalling else { completion(.failure(InstallError.busy)); return }
        isInstalling = true
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                isInstalling = false
                completion(result)
            }
        }
        URLSession.shared.downloadTask(with: dmgURL) { tempURL, _, error in
            guard let tempURL else { finish(.failure(error ?? InstallError.download)); return }
            do {
                try apply(downloadedDMG: tempURL, expectedVersion: expectedVersion)
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        }.resume()
    }

    /// Mount → copy out → verify newer → atomic swap. Runs on the download queue; all
    /// scratch (the moved `.dmg`, the mount, the staged copy) is cleaned up via `defer`.
    private static func apply(downloadedDMG src: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("m_capture-update-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: src, to: dmg)

        let mount = try attach(dmg)
        var detached = false
        defer { if !detached { detach(mount) } }

        let sourceApp = mount.appendingPathComponent("m_capture.app")
        guard fm.fileExists(atPath: sourceApp.path) else { throw InstallError.appNotFound }

        let staged = work.appendingPathComponent("m_capture.app")
        try run("/usr/bin/ditto", [sourceApp.path, staged.path])

        detach(mount); detached = true

        guard let stagedVersion = bundleShortVersion(at: staged),
              Updater.isNewer(stagedVersion, than: Updater.effectiveCurrentVersion) else {
            throw InstallError.notNewer
        }
        // The bundle must be the version that was offered, not merely *a* newer one. The
        // caller records `expectedVersion` as what is now staged and the relaunch prompt
        // names it, so a mismatched asset (a re-uploaded release, a tag pointing at the
        // wrong build) would otherwise have the app claim a version it isn't running.
        guard Updater.normalize(stagedVersion) == Updater.normalize(expectedVersion) else {
            throw InstallError.versionMismatch
        }

        _ = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged)
    }

    /// `hdiutil attach … -plist` and pull the mounted volume's path out of the plist.
    private static func attach(_ dmg: URL) throws -> URL {
        let out = try run("/usr/bin/hdiutil",
                          ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            throw InstallError.noMountPoint
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw InstallError.noMountPoint
    }

    /// Best-effort unmount; `-force` handles a volume that's briefly busy.
    private static func detach(_ mount: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", mount.path])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
        }
    }

    private static func bundleShortVersion(at app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// Run a CLI tool to completion, returning stdout; throws on a non-zero exit.
    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        try proc.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "UpdateInstaller", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "\(launchPath) exited \(proc.terminationStatus)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

