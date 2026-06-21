// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Checks GitHub Releases for a newer build — no dependencies, just URLSession +
/// JSONDecoder. Drives the "Check for Updates" menu item (manual; always reports
/// a result) and a silent once-a-day check at launch.
///
/// Both paths require the repo's releases to be readable by the running user;
/// for an internal rollout the repo (or its releases) must be public or
/// org-accessible.
enum Updater {
    private static let repo = "tuyen-nguyen-mesoneer/m_capture"
    private static let releasesURL = URL(string: "https://api.github.com/repos/\(repo)/releases")!
    private static let releasesPage = "https://github.com/\(repo)/releases"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private static let lastCheckKey = "updater.lastCheck"

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

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Entry points

    /// Manual check — always tells the user the outcome (up to date / available /
    /// couldn't check).
    static func checkManually() {
        fetch { result in
            switch result {
            case .success(let release) where isNewer(release.tagName, than: currentVersion):
                presentUpdateAlert(release)
            case .success:
                presentUpToDateAlert()
            case .failure:
                presentErrorAlert()
            }
        }
    }

    /// Silent launch check, throttled to once a day; only surfaces a newer version.
    static func checkInBackgroundIfDue() {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: lastCheckKey) >= checkInterval else { return }
        fetch { result in
            defaults.set(now, forKey: lastCheckKey)   // record only on a completed check
            guard case .success(let release) = result,
                  isNewer(release.tagName, than: currentVersion)
            else { return }
            presentUpdateAlert(release)
        }
    }

    // MARK: - Networking

    private static func fetch(_ completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("m_capture", forHTTPHeaderField: "User-Agent")   // GitHub rejects requests without one
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

    // MARK: - Version comparison

    /// Drop a leading "v" and any pre-release suffix so tags compare numerically.
    private static func normalize(_ tag: String) -> String {
        var t = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
        return t
    }

    private static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = normalize(tag).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Alerts

    private static func presentUpdateAlert(_ release: Release) {
        let message = "m_capture \(normalize(release.tagName)) is available."
        let choice = BrandAlert(title: "Update available", message: message,
                                titles: ["Download", "Later"], primary: 0, cancel: 1).runModal()
        if choice == 0 {
            let link = release.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadURL ?? release.htmlURL
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
    }

    private static func presentUpToDateAlert() {
        BrandAlert(title: "You’re up to date",
                   message: "m_capture \(currentVersion) is the latest version.",
                   titles: ["OK"], primary: 0, cancel: 0).runModal()
    }

    private static func presentErrorAlert() {
        let choice = BrandAlert(title: "Couldn't check for updates",
                                message: "Check your connection and try again.",
                                titles: ["Open Releases", "OK"], primary: 0, cancel: 1).runModal()
        if choice == 0, let url = URL(string: releasesPage) { NSWorkspace.shared.open(url) }
    }
}
