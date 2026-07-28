import AppKit

/// Loads images referenced by Markdown, off the main thread, with a cache.
///
/// Local files only unless the user opts in to remote loading — fetching a
/// remote image would leak the fact that a document was opened.
@MainActor
final class ImageLoader {

    static let shared = ImageLoader()

    private struct Key: Hashable {
        var url: URL
        var modified: Date?
    }

    private var cache: [Key: NSImage] = [:]
    private var failed: Set<Key> = []
    private var loading: Set<Key> = []

    private init() {}

    /// Resolves a Markdown destination against the document's own folder.
    func resolve(_ destination: String, relativeTo base: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("data:") { return URL(string: trimmed) }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "file": return url
            case "http", "https":
                return Preferences.shared.loadRemoteImages ? url : nil
            default:
                return nil
            }
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        guard let base else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
    }

    /// Cached image, or nil while it loads (or if it failed).
    func image(for url: URL) -> NSImage? {
        let key = Key(url: url, modified: modificationDate(of: url))
        if let image = cache[key] { return image }
        guard !failed.contains(key), !loading.contains(key) else { return nil }

        loading.insert(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = ImageLoader.load(url)
            Task { @MainActor in
                self.loading.remove(key)
                if let image, image.size.width > 0, image.size.height > 0 {
                    self.cache[key] = image
                } else {
                    self.failed.insert(key)
                }
                NotificationCenter.default.post(name: .markerRenderDidFinish, object: nil)
            }
        }
        return nil
    }

    func hasFailed(_ url: URL) -> Bool {
        failed.contains(Key(url: url, modified: modificationDate(of: url)))
    }

    func clearCache() {
        cache.removeAll()
        failed.removeAll()
    }

    // MARK: - Private

    private func modificationDate(of url: URL) -> Date? {
        guard url.isFileURL else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private nonisolated static func load(_ url: URL) -> NSImage? {
        if url.scheme == "data" {
            guard let comma = url.absoluteString.firstIndex(of: ","),
                  let data = Data(base64Encoded:
                    String(url.absoluteString[url.absoluteString.index(after: comma)...]),
                                  options: .ignoreUnknownCharacters) else { return nil }
            return NSImage(data: data)
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        // Cap absurd images so one bad file can't stall layout.
        guard data.count < 64 * 1024 * 1024 else { return nil }
        return NSImage(data: data)
    }
}
