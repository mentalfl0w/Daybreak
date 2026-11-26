import Foundation

/// Interface-language choices rendered by Settings.
///
/// Raw values match the shared preference written by `MobileStore` and read by
/// App Intents (`daybreak.interfaceLanguage`). Keeping this enum in the view
/// layer lets the picker compile independently of the store's concrete type;
/// Settings maps it to the store at the integration boundary.
enum SettingsLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// Language names stay in their own language so users can recognize them
    /// regardless of the current interface language. Only “follow system” is
    /// localized.
    func title(in locale: Locale) -> String {
        switch self {
        case .system:
            return MobileLocalizedString.resolve("跟随系统", locale: locale)
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        case .japanese:
            return "日本語"
        }
    }

    /// Locale used for app-owned copy. `nil` means “do not override”.
    var explicitLocale: Locale? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        case .japanese: return Locale(identifier: "ja")
        }
    }

    static func matching(rawValue: String) -> SettingsLanguage {
        SettingsLanguage(rawValue: rawValue) ?? .system
    }
}
