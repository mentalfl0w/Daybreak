import DaybreakCore
import Foundation

// MARK: - Data contract

/// The narrow surface the shared mobile store exposes to the timeline.
///
/// Timeline never opens a repository of its own: every snapshot, asset URL,
/// favorite mutation and download goes through the one process-wide store so a
/// second scene or an App Intent cannot race a second index writer.
@MainActor
protocol TimelineDataStore: AnyObject {
    /// Content market shared with Today and Settings.
    var selectedMarket: Market { get }

    /// Increments after every repository mutation so a scene can re-read its
    /// snapshot without polling.
    var dataRevision: Int { get }

    /// Persists the selected content market and starts its refresh.
    func setSelectedMarket(_ market: Market) async

    /// Point-in-time repository view. Safe to call on every appearance.
    func timelineSnapshot() async throws -> RepositorySnapshot

    /// Cached file for a verified asset, or `nil` when it is not cached.
    /// Must not download.
    func timelineAssetURL(kind: AssetKind, wallpaperID: WallpaperID) async -> URL?

    /// Returns a readable local file for the asset. When `allowNetwork` is
    /// true the store may download and cache it; downloads must validate the
    /// response and never leave a partial file behind.
    func timelineEnsureAsset(
        kind: AssetKind,
        for occurrence: WallpaperOccurrence,
        allowNetwork: Bool
    ) async throws -> URL

    /// Persists an image-level favorite. One image is one favorite even when
    /// it occurs on several dates or in several markets.
    func timelineSetFavorite(_ wallpaperID: WallpaperID, isFavorite: Bool) async throws

    /// Records a recent explicit selection for Shortcuts' "current selection"
    /// intent. This is a recency context, not shared navigation state.
    func recordCurrentSelection(_ key: OccurrenceKey?) async
}

// MARK: - Navigation values

enum TimelineSection: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case gallery
    case recap

    var id: String { rawValue }
}

enum TimelineGalleryScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites

    var id: String { rawValue }
}

enum TimelineRecapScope: String, CaseIterable, Identifiable, Sendable {
    case month
    case year
    case favorites

    var id: String { rawValue }
}

/// Month/year recap statistics can include every locally recorded market (the
/// default, matching the product's cross-market coverage) or only the market
/// currently shown by the calendar. Favorites are always image-level and
/// cross-market.
enum TimelineRecapMarketScope: String, CaseIterable, Identifiable, Sendable {
    case allMarkets
    case currentMarket

    var id: String { rawValue }
}

enum TimelineCalendarDisplay: String, Sendable {
    case month
    case year
}

/// A concrete detail request. A calendar cell opens the selected market's day;
/// a gallery cell or an "other markets" row opens one exact occurrence.
enum TimelineDetailTarget: Hashable, Sendable {
    case day(LocalDate)
    case occurrence(OccurrenceKey)

    var date: LocalDate {
        switch self {
        case .day(let date): return date
        case .occurrence(let key): return key.localDate
        }
    }
}

/// Push route for the compact layout. Selection itself lives in the model so
/// resizing to a split layout never loses it.
enum TimelineDetailRoute: Hashable, Sendable {
    case day(LocalDate)
    case occurrence(OccurrenceKey)
}

// MARK: - Month identity

struct TimelineMonthKey: Hashable, Sendable, Comparable, Identifiable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        let total = year * 12 + (month - 1)
        var normalizedYear = total / 12
        var normalizedMonth = total % 12
        if normalizedMonth < 0 {
            normalizedMonth += 12
            normalizedYear -= 1
        }
        self.year = normalizedYear
        self.month = normalizedMonth + 1
    }

    init(containing date: LocalDate) {
        self.init(year: date.year, month: date.month)
    }

    var id: String { String(format: "%04d-%02d", year, month) }

    var firstDay: LocalDate? {
        LocalDate(year: year, month: month, day: 1)
    }

    var lastDay: LocalDate? {
        LocalDate(year: year, month: month, day: LocalDate.daysInMonth(year: year, month: month))
    }

    func adding(months: Int) -> TimelineMonthKey {
        TimelineMonthKey(year: year, month: month + months)
    }

    static func < (lhs: TimelineMonthKey, rhs: TimelineMonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

// MARK: - Gallery values

struct TimelineGalleryItem: Identifiable, Sendable {
    let key: OccurrenceKey
    let wallpaperID: WallpaperID
    let title: String?
    let copyright: String?
    let hasThumbnail: Bool
    let hasOriginal: Bool
    let isFavorite: Bool
    let hasAvailableStory: Bool
    let hasUnavailableStory: Bool

    var id: OccurrenceKey { key }
    var date: LocalDate { key.localDate }
    var market: Market { key.market }
}

/// One market's observation of the currently inspected date.
struct TimelineMarketOccurrence: Identifiable, Sendable {
    let day: TimelineDay
    let metadata: WallpaperMetadataRecord?
    let wallpaper: WallpaperRecord?
    let isFavorite: Bool
    let hasThumbnail: Bool
    let hasOriginal: Bool

    var id: OccurrenceKey { day.id }
    var key: OccurrenceKey { day.id }
    var market: Market { day.market }
    var date: LocalDate { day.date }
    var wallpaperID: WallpaperID? { day.content?.wallpaperID }
    var title: String? { metadata?.title ?? wallpaper?.canonicalTitle }
    var copyright: String? { metadata?.copyright ?? wallpaper?.copyright }

    var storyStatus: TimelineStoryStatus {
        day.content?.story ?? .notStored
    }
}

// MARK: - Detail values

struct TimelineDayDetail: Identifiable, Sendable {
    let key: OccurrenceKey
    let day: TimelineDay
    let metadata: WallpaperMetadataRecord?
    let wallpaper: WallpaperRecord?
    let isFavorite: Bool
    let otherMarkets: [TimelineMarketOccurrence]
    let firstObservedDate: LocalDate?
    let asOf: LocalDate

    var id: OccurrenceKey { key }
    var date: LocalDate { key.localDate }
    var market: Market { key.market }
    var occurrence: WallpaperOccurrence? { day.content?.occurrence }
    var wallpaperID: WallpaperID? { day.content?.wallpaperID }
    var hasThumbnail: Bool { day.content?.thumbnailCached == true }
    var hasOriginal: Bool { day.content?.originalCached == true }
    var title: String? { metadata?.title ?? wallpaper?.canonicalTitle }
    var copyright: String? { metadata?.copyright ?? wallpaper?.copyright }
    var storyStatus: TimelineStoryStatus { day.content?.story ?? .notStored }

    var isRecorded: Bool {
        day.state == .observed && day.content != nil
    }
}

// MARK: - Year overview values

struct TimelineYearMonthSummary: Identifiable, Sendable {
    let year: Int
    let month: Int
    let observedDays: Int
    let thumbnailDays: Int
    let favoriteImageCount: Int
    let storyDays: Int
    let totalDays: Int

    var id: String { String(format: "%04d-%02d", year, month) }

    var hasRecords: Bool { observedDays > 0 }
}

// MARK: - Recap values

struct TimelineMonthRecapData: Sendable {
    let month: TimelineMonth
    let recap: MonthlyRecap
    let monthKey: TimelineMonthKey
}

struct TimelineYearRecapData: Sendable {
    let year: Int
    let recap: YearlyRecap
    let months: [TimelineYearMonthSummary]
}

struct TimelineFavoritesRecapData: Sendable {
    let recap: FavoriteRecap
    let undatedFavoriteCount: Int
}

// MARK: - Failures

enum TimelineFailureKind: String, Sendable {
    case unsupportedMarket
    case snapshotUnavailable
    case assetUnavailable
    case favoriteFailed
    case dateNotAvailable
    case actionFailed
}

struct TimelineFailure: Equatable, Sendable, Identifiable {
    let kind: TimelineFailureKind
    /// Technical detail for diagnostics. Never shown as the primary copy and
    /// never used to claim what the source did or did not publish.
    let detail: String?

    var id: String { "\(kind.rawValue)-\(detail ?? "")" }
}

enum TimelineBanner: Equatable, Sendable, Identifiable {
    case favorited
    case unfavorited
    case originalReady
    case assetUnavailable

    var id: String {
        switch self {
        case .favorited: return "favorited"
        case .unfavorited: return "unfavorited"
        case .originalReady: return "originalReady"
        case .assetUnavailable: return "assetUnavailable"
        }
    }
}

// MARK: - Builders

enum TimelineGalleryBuilder {
    static func items(
        snapshot: RepositorySnapshot,
        market: Market,
        asOf: LocalDate,
        scope: TimelineGalleryScope
    ) -> [TimelineGalleryItem] {
        let latest = OccurrenceIndex.latest(snapshot.occurrences)
        let candidates: [WallpaperOccurrence]
        switch scope {
        case .all:
            candidates = latest.filter { $0.market == market && $0.localDate <= asOf }
        case .favorites:
            candidates = latest.filter {
                snapshot.favoriteWallpaperIDs.contains($0.wallpaperID)
                    && $0.localDate <= asOf
            }
        }

        let ordered = candidates.sorted { lhs, rhs in
            if lhs.localDate != rhs.localDate { return lhs.localDate > rhs.localDate }
            if lhs.market != rhs.market { return lhs.market < rhs.market }
            return lhs.wallpaperID < rhs.wallpaperID
        }

        var seenFavorites: Set<WallpaperID> = []
        var items: [TimelineGalleryItem] = []
        items.reserveCapacity(ordered.count)
        for occurrence in ordered {
            if scope == .favorites,
               !seenFavorites.insert(occurrence.wallpaperID).inserted {
                continue
            }
            items.append(item(for: occurrence, snapshot: snapshot))
        }
        return items
    }

    static func undatedFavoriteCount(
        snapshot: RepositorySnapshot,
        asOf: LocalDate
    ) -> Int {
        let dated = Set(
            OccurrenceIndex.latest(snapshot.occurrences)
                .filter { $0.localDate <= asOf }
                .map(\.wallpaperID)
        )
        return snapshot.favoriteWallpaperIDs.subtracting(dated).count
    }

    static func item(
        for occurrence: WallpaperOccurrence,
        snapshot: RepositorySnapshot
    ) -> TimelineGalleryItem {
        let key = occurrence.id
        let metadata = snapshot.metadata(for: key)
        let wallpaper = snapshot.wallpapers.first { $0.wallpaperID == occurrence.wallpaperID }
        let match = StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: snapshot.stories
        )
        let hasUnavailableStory: Bool
        if case .unavailable = match {
            hasUnavailableStory = true
        } else {
            hasUnavailableStory = false
        }
        return TimelineGalleryItem(
            key: key,
            wallpaperID: occurrence.wallpaperID,
            title: metadata?.title ?? wallpaper?.canonicalTitle,
            copyright: metadata?.copyright ?? wallpaper?.copyright,
            hasThumbnail: snapshot.availableThumbnailIDs.contains(occurrence.wallpaperID),
            hasOriginal: snapshot.availableOriginalIDs.contains(occurrence.wallpaperID),
            isFavorite: snapshot.favoriteWallpaperIDs.contains(occurrence.wallpaperID),
            hasAvailableStory: match.availableStory != nil,
            hasUnavailableStory: hasUnavailableStory
        )
    }
}

enum TimelineDetailBuilder {
    static func detail(
        target: TimelineDetailTarget,
        selectedMarket: Market,
        snapshot: RepositorySnapshot,
        asOf: LocalDate
    ) -> TimelineDayDetail {
        let key: OccurrenceKey
        switch target {
        case .day(let date):
            key = OccurrenceKey(source: .bing, market: selectedMarket, localDate: date)
        case .occurrence(let occurrenceKey):
            key = occurrenceKey
        }
        let day = TimelineBuilder.day(
            for: key.localDate,
            market: key.market,
            asOf: asOf,
            source: key.source,
            snapshot: snapshot
        )
        return makeDetail(day: day, key: key, snapshot: snapshot, asOf: asOf)
    }

    private static func makeDetail(
        day: TimelineDay,
        key: OccurrenceKey,
        snapshot: RepositorySnapshot,
        asOf: LocalDate
    ) -> TimelineDayDetail {
        let metadata = snapshot.metadata(for: key)
        let occurrence = day.content?.occurrence
        let wallpaper = occurrence.flatMap { active in
            snapshot.wallpapers.first { $0.wallpaperID == active.wallpaperID }
        }
        let others = OccurrenceIndex.latest(snapshot.occurrences)
            .filter { $0.localDate == key.localDate && $0.market != key.market && $0.localDate <= asOf }
            .sorted { lhs, rhs in
                if lhs.market != rhs.market { return lhs.market < rhs.market }
                return lhs.wallpaperID < rhs.wallpaperID
            }
            .map { occurrence -> TimelineMarketOccurrence in
                let otherDay = TimelineBuilder.day(
                    for: occurrence.localDate,
                    market: occurrence.market,
                    asOf: asOf,
                    source: occurrence.source,
                    snapshot: snapshot
                )
                return TimelineMarketOccurrence(
                    day: otherDay,
                    metadata: snapshot.metadata(for: occurrence.id),
                    wallpaper: snapshot.wallpapers.first { $0.wallpaperID == occurrence.wallpaperID },
                    isFavorite: snapshot.favoriteWallpaperIDs.contains(occurrence.wallpaperID),
                    hasThumbnail: snapshot.availableThumbnailIDs.contains(occurrence.wallpaperID),
                    hasOriginal: snapshot.availableOriginalIDs.contains(occurrence.wallpaperID)
                )
            }

        return TimelineDayDetail(
            key: key,
            day: day,
            metadata: metadata,
            wallpaper: wallpaper,
            isFavorite: occurrence.map { snapshot.favoriteWallpaperIDs.contains($0.wallpaperID) } ?? false,
            otherMarkets: others,
            firstObservedDate: snapshot.firstObservedDate,
            asOf: asOf
        )
    }
}

enum TimelineYearBuilder {
    static func summaries(
        year: Int,
        markets: Set<Market>?,
        snapshot: RepositorySnapshot,
        asOf: LocalDate
    ) -> [TimelineYearMonthSummary] {
        let thumbnails = snapshot.availableThumbnailIDs
        let favorites = snapshot.favoriteWallpaperIDs
        let latest = OccurrenceIndex.latest(snapshot.occurrences).filter { occurrence in
            guard occurrence.localDate.year == year, occurrence.localDate <= asOf else {
                return false
            }
            if let markets, !markets.contains(occurrence.market) {
                return false
            }
            return true
        }
        let byMonth = Dictionary(grouping: latest) { $0.localDate.month }
        let storyLookup = TimelineStoryLookup(
            metadata: snapshot.metadata,
            stories: snapshot.stories
        )

        return (1...12).map { month in
            let occurrences = byMonth[month] ?? []
            let dates = Set(occurrences.map(\.localDate))
            let thumbDates = Set(
                occurrences.compactMap { occurrence -> LocalDate? in
                    thumbnails.contains(occurrence.wallpaperID) ? occurrence.localDate : nil
                }
            )
            let favoriteImages = Set(occurrences.map(\.wallpaperID)).intersection(favorites)
            let storyDates = Set(
                occurrences.compactMap { occurrence -> LocalDate? in
                    storyLookup.availableStory(for: occurrence) == nil ? nil : occurrence.localDate
                }
            )
            return TimelineYearMonthSummary(
                year: year,
                month: month,
                observedDays: dates.count,
                thumbnailDays: thumbDates.count,
                favoriteImageCount: favoriteImages.count,
                storyDays: storyDates.count,
                totalDays: LocalDate.daysInMonth(year: year, month: month)
            )
        }
    }
}

/// Dictionary-backed strict story lookup so year/recap builders do not scan
/// every story for every occurrence.
struct TimelineStoryLookup: Sendable {
    private let storiesByDay: [OccurrenceKey: [DailyStoryRecord]]
    private let metadataByKey: [OccurrenceKey: WallpaperMetadataRecord]

    init(metadata: [WallpaperMetadataRecord], stories: [DailyStoryRecord]) {
        self.storiesByDay = Dictionary(grouping: stories) { story in
            OccurrenceKey(source: story.source, market: story.market, localDate: story.date)
        }
        var latest: [OccurrenceKey: WallpaperMetadataRecord] = [:]
        for record in metadata {
            if let existing = latest[record.key], existing.fetchedAt > record.fetchedAt {
                continue
            }
            latest[record.key] = record
        }
        self.metadataByKey = latest
    }

    func match(_ occurrence: WallpaperOccurrence) -> StoryMatch {
        StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadataByKey[occurrence.id],
            stories: storiesByDay[occurrence.id] ?? []
        )
    }

    func availableStory(for occurrence: WallpaperOccurrence) -> DailyStoryRecord? {
        match(occurrence).availableStory
    }
}

enum TimelineRecapBuilder {
    static func month(
        monthKey: TimelineMonthKey,
        month: TimelineMonth,
        snapshot: RepositorySnapshot,
        asOf: LocalDate,
        markets: Set<Market>?
    ) -> TimelineMonthRecapData? {
        guard let start = monthKey.firstDay, let end = monthKey.lastDay,
              let range = LocalDateRange(start: start, end: end)
        else { return nil }
        let recap = RecapBuilder.monthly(
            occurrences: snapshot.occurrences,
            stories: snapshot.stories,
            metadata: snapshot.metadata,
            favoriteImageIDs: snapshot.favoriteWallpaperIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: snapshot.firstObservedDate,
            markets: markets
        )
        return TimelineMonthRecapData(month: month, recap: recap, monthKey: monthKey)
    }

    static func year(
        year: Int,
        snapshot: RepositorySnapshot,
        asOf: LocalDate,
        markets: Set<Market>?
    ) -> TimelineYearRecapData? {
        guard let start = LocalDate(year: year, month: 1, day: 1),
              let end = LocalDate(year: year, month: 12, day: 31),
              let range = LocalDateRange(start: start, end: end)
        else { return nil }
        let recap = RecapBuilder.yearly(
            occurrences: snapshot.occurrences,
            stories: snapshot.stories,
            metadata: snapshot.metadata,
            favoriteImageIDs: snapshot.favoriteWallpaperIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: snapshot.firstObservedDate,
            markets: markets
        )
        return TimelineYearRecapData(
            year: year,
            recap: recap,
            months: TimelineYearBuilder.summaries(
                year: year,
                markets: markets,
                snapshot: snapshot,
                asOf: asOf
            )
        )
    }

    static func favorites(
        snapshot: RepositorySnapshot,
        asOf: LocalDate
    ) -> TimelineFavoritesRecapData {
        let recap = RecapBuilder.favorites(
            occurrences: snapshot.occurrences,
            favoriteImageIDs: snapshot.favoriteWallpaperIDs,
            asOf: asOf
        )
        return TimelineFavoritesRecapData(
            recap: recap,
            undatedFavoriteCount: recap.undatedFavoriteImageCount
        )
    }
}

// MARK: - Calendar math and formatting

enum TimelineCalendarMath {
    /// 1970-01-01 (`dayNumber == 0`) was a Thursday. `+4` maps it to a
    /// Sunday-based index where Sunday is 0, matching Foundation's symbols.
    static func sundayBasedWeekday(for date: LocalDate) -> Int {
        let raw = (date.dayNumber + 4) % 7
        return raw >= 0 ? raw : raw + 7
    }

    static func leadingBlankCount(for month: TimelineMonth, firstWeekday: Int) -> Int {
        guard let first = month.days.first else { return 0 }
        let firstColumn = (firstWeekday - 1 + 7) % 7
        let offset = sundayBasedWeekday(for: first.date) - firstColumn
        return (offset + 7) % 7
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let start = (calendar.firstWeekday - 1) % 7
        return (0..<7).map { symbols[(start + $0) % 7] }
    }

    static func date(
        from localDate: LocalDate,
        timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = localDate.year
        components.month = localDate.month
        components.day = localDate.day
        components.hour = 12
        return calendar.date(from: components)
    }

    static func displayCalendar(locale: Locale, timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }
}

enum TimelinePresentation {
    static func marketName(for market: Market, in locale: Locale) -> String {
        guard let profile = BingMarketProfile.profile(for: market) else {
            return market.rawValue
        }
        let region = locale.localizedString(forRegionCode: profile.regionCode)
        let language = locale.localizedString(forLanguageCode: profile.languageCode)
        switch (region.flatMap { $0.isEmpty ? nil : $0 },
                language.flatMap { $0.isEmpty ? nil : $0 }) {
        case let (regionText?, languageText?):
            return "\(regionText) · \(languageText)"
        case let (regionText?, nil):
            return regionText
        case let (nil, languageText?):
            return languageText
        case (nil, nil):
            return market.rawValue
        }
    }

    static func marketTag(for market: Market, in locale: Locale) -> String {
        let name = marketName(for: market, in: locale)
        return name == market.rawValue ? name : "\(name) · \(market.rawValue)"
    }

    /// Compact label for dense cells: the localized region, falling back to
    /// the provider tag. The full market name stays available to accessibility.
    static func marketShortName(for market: Market, in locale: Locale) -> String {
        guard let profile = BingMarketProfile.profile(for: market) else {
            return market.rawValue
        }
        if let region = locale.localizedString(forRegionCode: profile.regionCode),
           !region.isEmpty {
            return region
        }
        return market.rawValue
    }

    /// Source language is provenance; unknown tags stay hidden instead of
    /// being guessed from the app language.
    static func sourceLanguageName(_ tag: String?, in locale: Locale) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let primary = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { String($0).lowercased() }
        guard let primary, !["und", "mul", "zxx"].contains(primary) else { return nil }
        return locale.localizedString(forIdentifier: trimmed) ?? trimmed
    }

    static func monthTitle(_ key: TimelineMonthKey, locale: Locale, timeZone: TimeZone) -> String {
        guard let first = key.firstDay,
              let date = TimelineCalendarMath.date(from: first, timeZone: timeZone)
        else { return key.id }
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func yearTitle(_ year: Int, locale: Locale, timeZone: TimeZone) -> String {
        guard let first = LocalDate(year: year, month: 1, day: 1),
              let date = TimelineCalendarMath.date(from: first, timeZone: timeZone)
        else { return String(year) }
        var style = Date.FormatStyle.dateTime.year()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func monthName(month: Int, year: Int, locale: Locale, timeZone: TimeZone) -> String {
        guard let first = LocalDate(year: year, month: month, day: 1),
              let date = TimelineCalendarMath.date(from: first, timeZone: timeZone)
        else { return String(month) }
        var style = Date.FormatStyle.dateTime.month(.wide)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func fullDate(_ date: LocalDate, locale: Locale, timeZone: TimeZone) -> String {
        guard let instant = TimelineCalendarMath.date(from: date, timeZone: timeZone) else {
            return date.iso8601
        }
        var style = Date.FormatStyle.dateTime
            .weekday(.wide)
            .year()
            .month(.wide)
            .day()
        style.locale = locale
        style.timeZone = timeZone
        return instant.formatted(style)
    }

    static func shortDate(_ date: LocalDate, locale: Locale, timeZone: TimeZone) -> String {
        guard let instant = TimelineCalendarMath.date(from: date, timeZone: timeZone) else {
            return date.iso8601
        }
        var style = Date.FormatStyle.dateTime.year().month().day()
        style.locale = locale
        style.timeZone = timeZone
        return instant.formatted(style)
    }

    static func fetchedAt(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
