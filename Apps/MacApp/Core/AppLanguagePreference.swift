import Foundation
import Observation

/// App-level interface language choice.
///
/// This is separate from the Bing content market: changing the interface
/// language never changes which market's image or source story is displayed.
/// The choice is stored only in Daybreak's own preferences.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// The language names themselves stay in their own language so users can
    /// find their language regardless of the current interface language. Only
    /// the "follow system" label is translated through the supplied locale.
    func title(in locale: Locale) -> String {
        switch self {
        case .system: return MacLocalizedString.resolve("跟随系统", locale: locale)
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

}

@MainActor
@Observable
final class AppLanguagePreference {
    private static let selectionKey = "daybreak.interfaceLanguage"
    private let defaults: UserDefaults
    private(set) var selection: AppLanguage

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = defaults.string(forKey: Self.selectionKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func select(_ language: AppLanguage) {
        selection = language
        defaults.set(language.rawValue, forKey: Self.selectionKey)
    }
}
