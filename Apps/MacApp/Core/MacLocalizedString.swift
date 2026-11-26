import Foundation

/// Resolves Daybreak string-catalog keys in an explicit interface language.
///
/// `String(localized:locale:)` only formats interpolated values with that
/// locale; it does not change which localization the system looks up. A
/// `LocalizedStringResource` stores the lookup locale, and the
/// `String(localized:)` initializer that takes a resource honours it, so
/// model-owned copy can follow the in-app interface choice. This mirrors the
/// mobile app's `MobileLocalizedString.resolve`.
///
/// `.current` and `.autoupdatingCurrent` mean "follow the system": the bundle's
/// own language choice is authoritative there, which also honours a per-app
/// language selected in System Settings.
enum MacLocalizedString {
    nonisolated static func resolve(
        _ key: String.LocalizationValue,
        locale: Locale
    ) -> String {
        guard locale != .autoupdatingCurrent, locale != .current else {
            return String(localized: key)
        }
        return String(localized: LocalizedStringResource(key, locale: locale))
    }
}
