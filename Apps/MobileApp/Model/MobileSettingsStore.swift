import DaybreakCore
import Foundation

/// Persistence seam for mobile preferences.
///
/// The production implementation uses the standard suite so App Intents and
/// the UI process read the same values without an App Group or extension.
public protocol MobileSettingsPersisting: Sendable {
    func load() -> MobileSettings
    func save(_ settings: MobileSettings)
}

/// JSON-backed preferences in `UserDefaults.standard`.
///
/// The interface-language key is also written as a raw string because the App
/// Intent layer reads it directly to localize runtime dialogs. Both writes are
/// guarded by the same lock so a concurrent intent launch never observes a
/// half-updated preference set.
/// Persistence for the App Intent "current selection" context.
///
/// This is shared data, not per-scene navigation: Today records its occurrence
/// on first load, and a user opening a historical day may replace it. Each
/// scene still owns its own selection UI.
public protocol MobileSelectionPersisting: Sendable {
    func loadCurrentSelection() -> OccurrenceKey?
    func saveCurrentSelection(_ key: OccurrenceKey?)
}

/// Thread-safe bridge to `UserDefaults` for the current-selection key.
public final class UserDefaultsMobileSelectionStore: MobileSelectionPersisting, @unchecked Sendable {
    public static let currentSelectionKey = "daybreak.mobile.currentSelection"
    public static let standard = UserDefaultsMobileSelectionStore(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func loadCurrentSelection() -> OccurrenceKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.currentSelectionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(OccurrenceKey.self, from: data)
    }

    public func saveCurrentSelection(_ key: OccurrenceKey?) {
        lock.lock()
        defer { lock.unlock() }
        if let key, let data = try? JSONEncoder().encode(key) {
            defaults.set(data, forKey: Self.currentSelectionKey)
        } else {
            defaults.removeObject(forKey: Self.currentSelectionKey)
        }
    }
}

public final class UserDefaultsMobileSettingsStore: MobileSettingsPersisting, @unchecked Sendable {
    public static let settingsKey = "daybreak.mobile.settings.v1"
    /// Shared with the App Intent runtime. Raw values are `zh-Hans`, `en` or
    /// `ja`; absence means "follow system".
    public static let interfaceLanguageKey = "daybreak.interfaceLanguage"

    public static let standard = UserDefaultsMobileSettingsStore(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> MobileSettings {
        lock.lock()
        defer { lock.unlock() }

        var settings: MobileSettings
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(MobileSettings.self, from: data) {
            settings = decoded
        } else {
            settings = MobileSettings()
        }

        // The raw key is authoritative for interface language because App
        // Intents can only read that shape. A legacy/edited value is accepted
        // only when it names a known explicit language.
        if let rawValue = defaults.string(forKey: Self.interfaceLanguageKey),
           let language = MobileInterfaceLanguage(rawValue: rawValue) {
            settings.interfaceLanguage = language
        }

        settings.normalize()
        return settings
    }

    public func save(_ settings: MobileSettings) {
        lock.lock()
        defer { lock.unlock() }

        var normalized = settings
        normalized.normalize()

        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: Self.settingsKey)
        }

        if normalized.interfaceLanguage == .system {
            defaults.removeObject(forKey: Self.interfaceLanguageKey)
        } else {
            defaults.set(normalized.interfaceLanguage.rawValue, forKey: Self.interfaceLanguageKey)
        }
    }
}
