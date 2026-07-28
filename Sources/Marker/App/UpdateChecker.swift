import Foundation

/// A release found on GitHub that is newer than the running build.
struct AvailableUpdate: Equatable {
    var version: String
    var url: URL
}

extension Notification.Name {
    static let markerUpdateAvailable = Notification.Name("MarkerUpdateAvailable")
}

/// Checks GitHub Releases for a newer version.
///
/// This is the only part of the app that touches the network, and it is the
/// only reason it ever would, so it is a preference and it only ever talks to
/// `api.github.com`. Nothing about the document is sent — the request carries
/// no query, no body and no identifier beyond a user agent naming the app.
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    private static let endpoint = URL(
        string: "https://api.github.com/repos/noahvandenberg/Marker/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedVersionKey = "skippedUpdateVersion"

    private(set) var available: AvailableUpdate?
    private var isChecking = false

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Runs at most once a day; used on launch.
    func checkIfDue() {
        guard Preferences.shared.checkForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        check(userInitiated: false)
    }

    /// - Parameter userInitiated: a manual check reports "you're up to date" and
    ///   ignores a previously skipped version; the automatic one stays quiet.
    func check(userInitiated: Bool, completion: ((Result<AvailableUpdate?, Error>) -> Void)? = nil) {
        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Marker/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

                if let error {
                    completion?(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    // No releases published yet is a 404, not a failure worth surfacing.
                    completion?(.success(nil))
                    return
                }

                let latest = release.tag_name
                guard UpdateChecker.version(latest, isNewerThan: self.currentVersion),
                      let url = URL(string: release.html_url) else {
                    completion?(.success(nil))
                    return
                }
                if !userInitiated, self.skippedVersion == latest {
                    completion?(.success(nil))
                    return
                }

                let update = AvailableUpdate(version: UpdateChecker.strippingPrefix(latest), url: url)
                self.available = update
                NotificationCenter.default.post(name: .markerUpdateAvailable, object: update)
                completion?(.success(update))
            }
        }.resume()
    }

    /// Stops the bar reappearing for a version the user dismissed.
    func skip(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.version, forKey: Self.skippedVersionKey)
        available = nil
    }

    private var skippedVersion: String? {
        UserDefaults.standard.string(forKey: Self.skippedVersionKey)
            .map { UpdateChecker.strippingPrefix($0) }
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    // MARK: - Version comparison

    nonisolated static func strippingPrefix(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        return text
    }

    /// Numeric component-wise comparison: 1.10 is newer than 1.9, and a missing
    /// component counts as zero so 1.2 and 1.2.0 are the same release.
    nonisolated static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        func components(_ text: String) -> [Int] {
            strippingPrefix(text)
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
        }
        let lhs = components(candidate)
        let rhs = components(current)
        guard !lhs.isEmpty else { return false }

        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
