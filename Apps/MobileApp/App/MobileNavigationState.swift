import DaybreakCore
import Foundation
import Observation

// MARK: - Interface-language lookup

/// Resolves Daybreak string-catalog keys in an explicit interface language.
///
/// `String(localized:locale:)` takes a locale, but Apple documents that it only
/// formats interpolated values with it: “This doesn’t change which locale the
/// system uses to look up the localized string.” A `LocalizedStringResource`
/// stores the locale used for the lookup itself, and the `String(localized:)`
/// initializer that takes a resource honours it, so app-owned copy can follow
/// the in-app interface language without relaunching.
enum MobileLocalizedString {
    /// Returns the string-catalog entry for `key`, looked up in `locale`.
    ///
    /// Keys stay compile-time `String.LocalizationValue` literals, so the
    /// string catalog keeps extracting them; only the lookup locale is decided
    /// at runtime. The resource's default bundle is the app's main bundle,
    /// which is where the compiled catalog lives.
    nonisolated static func resolve(
        _ key: String.LocalizationValue,
        locale: Locale
    ) -> String {
        // `MobileInterfaceLanguage.system` supplies `.autoupdatingCurrent`:
        // there is no explicit override, so defer to the bundle's own language
        // choice. That also honours a per-app language chosen in iOS Settings,
        // which `Locale.current` does not reflect.
        guard locale != .autoupdatingCurrent else {
            return String(localized: key)
        }
        return String(localized: LocalizedStringResource(key, locale: locale))
    }
}

/// Per-window navigation and selection state for the mobile app.
///
/// Exactly one instance exists per `WindowGroup` scene. The shared `MobileStore`
/// is injected once per process, while this object owns the selected primary
/// section and any cross-section request so resizing a window, entering or
/// leaving Duo expanded mode, or opening a second window never shares or loses
/// another scene's navigation.
@MainActor
@Observable
final class MobileNavigationState {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case today
        case timeline
        case settings

        var id: String { rawValue }

        /// Section title resolved from the string catalog in `locale`.
        ///
        /// The locale selects the lookup itself, not just interpolation
        /// formatting: resolving through `MobileLocalizedString` keeps the
        /// catalog key but asks Foundation for the string in `locale`, so a
        /// language change reaches chrome that was already installed.
        ///
        /// Navigation and tab-bar chrome keep the title *string* they
        /// installed and do not re-resolve a `LocalizedStringKey` when only the
        /// interface-language environment changes. Resolving to a plain string
        /// turns a language change into an ordinary value change, which the
        /// system applies in place without replacing the selected section,
        /// navigation path, date or preview.
        func localizedTitle(in locale: Locale) -> String {
            switch self {
            case .today: MobileLocalizedString.resolve("今日", locale: locale)
            case .timeline: MobileLocalizedString.resolve("时光", locale: locale)
            case .settings: MobileLocalizedString.resolve("设置", locale: locale)
            }
        }

        var systemImage: String {
            switch self {
            case .today: "sunrise.fill"
            case .timeline: "calendar"
            case .settings: "gearshape"
            }
        }
    }

    /// A date the user explicitly asked to inspect in Timeline.
    ///
    /// The request carries its own identity so Timeline can distinguish a new
    /// request for the same date from a request it already handled.
    struct TimelineRequest: Hashable, Identifiable {
        let id = UUID()
        let date: LocalDate
        let market: Market
    }

    var selectedSection: Section = .today

    /// Pending hand-off from Today to Timeline. Timeline consumes it (sets its
    /// own selected date/market and clears it) and remains the owner of all
    /// later calendar selection.
    var timelineRequest: TimelineRequest?

    /// Shows Timeline, optionally selecting a real stored date and market.
    func openTimeline(date: LocalDate? = nil, market: Market? = nil) {
        if let date, let market {
            timelineRequest = TimelineRequest(date: date, market: market)
        }
        selectedSection = .timeline
    }
}
