import DaybreakCore
import Foundation

/// Resolved, view-facing content for the Today screen.
///
/// This is a value snapshot, not a second store: `MobileStore.todayDisplayContent`
/// maps the shared store's authoritative Today snapshot into this type so the
/// photograph, story and provenance views never invent a date, title or story.
struct TodayDisplayContent: Equatable, Sendable {
    let occurrence: WallpaperOccurrence
    let marketToday: LocalDate
    let title: String?
    let copyright: String?
    let sourceURL: URL?
    let storyMatch: StoryMatch?
    let thumbnailCached: Bool
    let originalCached: Bool
    let isFavorite: Bool
    let fetchedAt: Date?
    let cachedAt: Date?

    var market: Market { occurrence.market }
    var sourceDate: LocalDate { occurrence.localDate }
    var wallpaperID: WallpaperID { occurrence.wallpaperID }
    var key: OccurrenceKey { occurrence.id }
    var isSourceDateToday: Bool { sourceDate == marketToday }

    var imageAvailability: TodayImageAvailability {
        if originalCached { return .original }
        if thumbnailCached { return .thumbnail }
        return .missing
    }
}

enum TodayImageAvailability: Equatable, Sendable {
    case original
    case thumbnail
    case missing
}

enum TodayLoadPhase: Equatable, Sendable {
    case idle
    case loadingCache
    case refreshing
    case ready
    case empty
    case failed(String)
}

// MARK: - Formatting

/// Interface-language formatting for app-owned date and provenance labels.
///
/// Source dates are calendar dates from the provider's market, so they are
/// formatted in a fixed Gregorian calendar rather than by converting the
/// device clock's instant into another zone. Story text itself is never passed
/// through these helpers.
@MainActor
enum TodayFormatting {
    static func sourceDate(_ date: LocalDate, locale: Locale) -> String {
        let style = Date.FormatStyle(
            date: .long,
            time: .omitted,
            locale: locale,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt
        )
        return referenceDate(for: date).formatted(style)
    }

    static func referenceDate(for date: LocalDate) -> Date {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components) ?? .distantPast
    }

    static func marketName(_ market: Market, locale: Locale) -> String {
        guard let profile = BingMarketProfile.profile(for: market) else {
            return market.rawValue
        }
        let region = locale.localizedString(forRegionCode: profile.regionCode)
        let language = locale.localizedString(forLanguageCode: profile.languageCode)
        switch (region, language) {
        case let (region?, language?) where !region.isEmpty && !language.isEmpty:
            return "\(region) · \(language)"
        case let (region?, _) where !region.isEmpty:
            return region
        case let (_, language?) where !language.isEmpty:
            return language
        default:
            return market.rawValue
        }
    }

    static func sourceLanguageName(_ tag: String, locale: Locale) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        let languageCode = normalized.split(separator: "-").first.map(String.init) ?? normalized
        guard !["und", "zxx", "mul", "mis"].contains(languageCode.lowercased()) else {
            return nil
        }
        guard let name = locale.localizedString(forIdentifier: normalized), !name.isEmpty else {
            return trimmed
        }
        return name
    }

    static func list(_ items: [String], locale: Locale) -> String {
        guard !items.isEmpty else { return "" }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    static func dateTime(_ date: Date, locale: Locale) -> String {
        date.formatted(
            .dateTime
                .year()
                .month()
                .day()
                .hour()
                .minute()
                .locale(locale)
        )
    }
}
