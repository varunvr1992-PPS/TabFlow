import Cocoa
import Combine

// MARK: - Key / modifier helpers

enum ModMask {
    static let command: UInt64 = CGEventFlags.maskCommand.rawValue
    static let option: UInt64 = CGEventFlags.maskAlternate.rawValue
    static let control: UInt64 = CGEventFlags.maskControl.rawValue
    static let shift: UInt64 = CGEventFlags.maskShift.rawValue
    /// Modifiers that define a shortcut. Shift is reserved for "go backwards".
    static let relevant: UInt64 = command | option | control

    static func symbols(_ m: UInt64) -> String {
        var s = ""
        if m & control != 0 { s += "⌃" }
        if m & option != 0 { s += "⌥" }
        if m & shift != 0 { s += "⇧" }
        if m & command != 0 { s += "⌘" }
        return s
    }
}

enum KeyCodes {
    static let tab: Int64 = 48
    static let space: Int64 = 49
    /// The key directly above Tab on ANSI keyboards (` ~).
    static let aboveTab: Int64 = 50
    /// The key directly above Tab on ISO keyboards (§ ±).
    static let aboveTabISO: Int64 = 10
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36
    static let enter: Int64 = 76
    static let delete: Int64 = 51
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
    static let digits: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// Treats both physical "key above Tab" codes as the same key, so the shortcut
    /// works on US (ANSI) and international (ISO) keyboards alike.
    static func matches(_ pressed: Int64, _ configured: Int64) -> Bool {
        if pressed == configured { return true }
        let pair: Set<Int64> = [aboveTab, aboveTabISO]
        return pair.contains(pressed) && pair.contains(configured)
    }
}

// MARK: - Settings model

enum SwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case thumbnails, icons, list
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .icons: return "App icons"
        case .list: return "List"
        }
    }
}

enum SizePreset: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var factor: CGFloat {
        switch self {
        case .small: return 0.78
        case .medium: return 1
        case .large: return 1.35
        }
    }
}

enum Theme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Placement: String, Codable, CaseIterable, Identifiable {
    case mouseScreen, activeWindowScreen, mainScreen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mouseScreen: return "Screen with the mouse"
        case .activeWindowScreen: return "Screen with the active window"
        case .mainScreen: return "Main screen"
        }
    }
}

enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case recent, appName, space
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Recently used"
        case .appName: return "App name"
        case .space: return "Desktop (Space)"
        }
    }
}

enum AppScope: String, Codable, CaseIterable, Identifiable {
    case allApps, activeApp
    var id: String { rawValue }
    var label: String { self == .allApps ? "All apps" : "Active app only" }
}

enum SpaceScope: String, Codable, CaseIterable, Identifiable {
    case allSpaces, currentSpace
    var id: String { rawValue }
    var label: String { self == .allSpaces ? "All Desktops" : "Current Desktop" }
}

enum ScreenScope: String, Codable, CaseIterable, Identifiable {
    case allScreens, currentScreen
    var id: String { rawValue }
    var label: String { self == .allScreens ? "All screens" : "Current screen" }
}

struct ShortcutConfig: Codable, Equatable, Identifiable {
    var id: Int
    var enabled: Bool
    var modifiers: UInt64
    var keyCode: Int64
    var apps: AppScope
    var spaces: SpaceScope
    var screens: ScreenScope

    var display: String { ModMask.symbols(modifiers) + KeyNames.name(keyCode) }
}

struct Settings: Codable, Equatable {
    var shortcuts: [ShortcutConfig] = [
        ShortcutConfig(id: 0, enabled: true, modifiers: ModMask.option, keyCode: KeyCodes.tab,
                       apps: .allApps, spaces: .allSpaces, screens: .allScreens),
        ShortcutConfig(id: 1, enabled: true, modifiers: ModMask.command, keyCode: KeyCodes.aboveTab,
                       apps: .activeApp, spaces: .allSpaces, screens: .allScreens),
        ShortcutConfig(id: 2, enabled: false, modifiers: ModMask.command, keyCode: KeyCodes.tab,
                       apps: .allApps, spaces: .allSpaces, screens: .allScreens),
    ]
    var style: SwitcherStyle = .thumbnails
    var size: SizePreset = .medium
    var theme: Theme = .system
    var placement: Placement = .mouseScreen
    var sort: SortOrder = .recent
    var showDelayMs: Double = 90

    var showMinimized = true
    var showHidden = true
    var showFullscreen = true
    var showWindowlessApps = false
    var hideUntitled = false

    var hoverSelects = true
    var showNumberHints = true
    var showBadges = true
    var showHintBar = true
    var showCloseButtons = true

    var excludedApps: [String] = []
    var disabledInApps: [String] = []
    var paused = false
    var onboarded = false
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let key = "settings.v1"

    @Published var s: Settings {
        didSet { if s != oldValue { save() } }
    }

    private init() { s = Prefs.load() }

    /// Loads stored settings, filling in defaults for any keys added in newer versions.
    private static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(Settings()),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any]
        else { return Settings() }
        merged.merge(stored) { _, new in new }
        guard let mdata = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(Settings.self, from: mdata)
        else { return Settings() }
        return s
    }

    private func save() {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Prefs.key) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
