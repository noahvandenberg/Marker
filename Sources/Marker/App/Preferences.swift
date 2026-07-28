import AppKit
import Combine

enum AppearanceChoice: String, CaseIterable, Codable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Notification.Name {
    static let markerPreferencesDidChange = Notification.Name("MarkerPreferencesDidChange")
}

/// User-facing settings, persisted in `UserDefaults` and observed by every editor.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private enum Key {
        static let fontSize = "fontSize"
        static let contentWidth = "contentWidth"
        static let lineHeight = "lineHeight"
        static let typeface = "typeface"
        static let appearance = "appearance"
        static let typewriterMode = "typewriterMode"
        static let focusMode = "focusMode"
        static let spellChecking = "spellChecking"
        static let smartSubstitutions = "smartSubstitutions"
        static let autoPairMarkers = "autoPairMarkers"
        static let renderDiagrams = "renderDiagrams"
        static let loadRemoteImages = "loadRemoteImages"
        static let showMarkdownSource = "showMarkdownSource"
        static let showTokenCount = "showTokenCount"
        static let checkForUpdates = "checkForUpdates"
    }

    @Published var fontSize: CGFloat { didSet { persist(Double(fontSize), Key.fontSize) } }
    @Published var contentWidth: CGFloat { didSet { persist(Double(contentWidth), Key.contentWidth) } }
    @Published var lineHeight: CGFloat { didSet { persist(Double(lineHeight), Key.lineHeight) } }
    @Published var typeface: TypefaceChoice { didSet { persist(typeface.rawValue, Key.typeface) } }
    @Published var appearance: AppearanceChoice {
        didSet {
            persist(appearance.rawValue, Key.appearance)
            NSApp?.appearance = appearance.nsAppearance
        }
    }
    @Published var typewriterMode: Bool { didSet { persist(typewriterMode, Key.typewriterMode) } }
    @Published var focusMode: Bool { didSet { persist(focusMode, Key.focusMode) } }
    @Published var spellChecking: Bool { didSet { persist(spellChecking, Key.spellChecking) } }
    @Published var smartSubstitutions: Bool { didSet { persist(smartSubstitutions, Key.smartSubstitutions) } }
    @Published var autoPairMarkers: Bool { didSet { persist(autoPairMarkers, Key.autoPairMarkers) } }
    @Published var renderDiagrams: Bool { didSet { persist(renderDiagrams, Key.renderDiagrams) } }
    @Published var loadRemoteImages: Bool { didSet { persist(loadRemoteImages, Key.loadRemoteImages) } }
    /// Escape hatch: show every syntax marker instead of hiding them.
    @Published var showMarkdownSource: Bool { didSet { persist(showMarkdownSource, Key.showMarkdownSource) } }
    /// Token counting loads a ~3.6 MB vocabulary, so it can be switched off.
    @Published var showTokenCount: Bool { didSet { persist(showTokenCount, Key.showTokenCount) } }
    /// The only thing in the app that uses the network.
    @Published var checkForUpdates: Bool { didSet { persist(checkForUpdates, Key.checkForUpdates) } }

    private var suppressNotifications = true
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.fontSize: 17.0,
            Key.contentWidth: 700.0,
            Key.lineHeight: 1.55,
            Key.typeface: TypefaceChoice.system.rawValue,
            Key.appearance: AppearanceChoice.system.rawValue,
            Key.typewriterMode: false,
            Key.focusMode: false,
            Key.spellChecking: true,
            Key.smartSubstitutions: false,
            Key.autoPairMarkers: true,
            Key.renderDiagrams: true,
            Key.loadRemoteImages: false,
            Key.showMarkdownSource: false,
            Key.showTokenCount: true,
            Key.checkForUpdates: true,
        ])

        fontSize = CGFloat(defaults.double(forKey: Key.fontSize))
        contentWidth = CGFloat(defaults.double(forKey: Key.contentWidth))
        lineHeight = CGFloat(defaults.double(forKey: Key.lineHeight))
        typeface = TypefaceChoice(rawValue: defaults.string(forKey: Key.typeface) ?? "") ?? .system
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        typewriterMode = defaults.bool(forKey: Key.typewriterMode)
        focusMode = defaults.bool(forKey: Key.focusMode)
        spellChecking = defaults.bool(forKey: Key.spellChecking)
        smartSubstitutions = defaults.bool(forKey: Key.smartSubstitutions)
        autoPairMarkers = defaults.bool(forKey: Key.autoPairMarkers)
        renderDiagrams = defaults.bool(forKey: Key.renderDiagrams)
        loadRemoteImages = defaults.bool(forKey: Key.loadRemoteImages)
        showMarkdownSource = defaults.bool(forKey: Key.showMarkdownSource)
        showTokenCount = defaults.bool(forKey: Key.showTokenCount)
        checkForUpdates = defaults.bool(forKey: Key.checkForUpdates)

        suppressNotifications = false
    }

    var theme: Theme { Theme(preferences: self) }

    func resetToDefaults() {
        fontSize = 17
        contentWidth = 700
        lineHeight = 1.55
        typeface = .system
        appearance = .system
    }

    private func persist(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        guard !suppressNotifications else { return }
        NotificationCenter.default.post(name: .markerPreferencesDidChange, object: self)
    }
}
