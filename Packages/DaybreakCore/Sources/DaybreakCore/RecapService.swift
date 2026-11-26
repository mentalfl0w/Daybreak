import Foundation

// MARK: - Errors

public enum CalendarServiceError: Error, Hashable, Sendable {
    case invalidMonth(Int)
    case invalidYear(Int)
}

// MARK: - Coverage

/// Why a recap window has the coverage it reports.
public enum CoverageState: String, Hashable, Sendable, Codable {
    /// No observation start is known, so there is no honest denominator.
    /// Recorded days may still be counted.
    case firstObservedDateUnknown
    /// A usable window exists but no date in it has a stored occurrence.
    case noObservation
    /// Some, but not all, eligible dates have a stored occurrence.
    case partial
    /// Every eligible date in the observation window has a stored occurrence.
    case complete
}

// MARK: - Recap values

/// Counts derived only from stored, dated records in the requested window.
///
/// "Unobserved" is intentionally not called "missing" or "Bing gap": a date
/// without a record may mean the app did not run, the market was not enabled,
/// the request failed, or the source published nothing. This type cannot
/// distinguish those causes and therefore never claims one.
public struct RecapSummary: Hashable, Sendable {
    public let range: LocalDateRange
    public let asOf: LocalDate
    /// Global observation start from the repository. `nil` when the repository
    /// has none, or when the stored start is later than `asOf` and therefore
    /// cannot bound this window (see `RecapBuilder.evaluate`).
    public let firstObservedDate: LocalDate?
    /// `max(range.start, firstObservedDate)...min(range.end, asOf)`, or
    /// `nil` when the first observed date is unknown/the window is empty.
    public let effectiveRange: LocalDateRange?
    /// Inclusive eligible days in `effectiveRange`. Pre-installation days are
    /// never part of this denominator. `nil` when no usable start exists for
    /// the queried window.
    public let eligibleDays: Int?
    /// Distinct dates with at least one stored occurrence, across markets.
    public let observedDays: Int
    /// Eligible dates without a stored occurrence. This is "not recorded
    /// locally", not a claim that the source published nothing.
    public let unobservedDays: Int?
    /// Occurrences after revision collapse, not raw input rows.
    public let totalOccurrences: Int
    /// Distinct content identities; one image on several dates or markets
    /// counts once.
    public let uniqueImageCount: Int
    /// Distinct observed dates per market. Kept separate from the global
    /// `observedDays`, so cross-market duplicates cannot inflate the day count.
    public let marketDayCounts: [Market: Int]
    /// Occurrences per market after revision collapse.
    public let marketOccurrenceCounts: [Market: Int]
    /// Distinct dates with at least one occurrence matched to an available
    /// story. Unavailable, unmatched, and unbound stories do not count.
    public let storyCoveredDays: Int
    /// Favorites intersecting images observed in the window, deduplicated by
    /// image. Favorite actions never inflate this number.
    public let favoriteImageCount: Int
    /// `observedDays / eligibleDays`; `nil` when no denominator exists.
    public let coverage: Double?
    public let coverageState: CoverageState

    /// Number of distinct markets with at least one occurrence in the window.
    public var distinctMarketCount: Int {
        marketDayCounts.count
    }

    /// Market with the most observed days; ties break by occurrence count and
    /// then by the smaller market tag so the result is deterministic. This is
    /// a local observation ranking, not a claim about source popularity.
    public var mostUsedMarket: Market? {
        marketDayCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let lhsOccurrences = marketOccurrenceCounts[lhs.key] ?? 0
            let rhsOccurrences = marketOccurrenceCounts[rhs.key] ?? 0
            if lhsOccurrences != rhsOccurrences {
                return lhsOccurrences < rhsOccurrences
            }
            return lhs.key > rhs.key
        }?.key
    }

    /// Structural floor for comparisons: one observed date cannot support a
    /// "highlight" or "favorite of the year" claim. Not a statistical claim
    /// about two days either.
    public var hasComparableObservations: Bool {
        observedDays >= 2
    }

    public var hasObservations: Bool {
        observedDays > 0
    }
}

/// One observed date inside a monthly recap.
public struct RecapDay: Hashable, Sendable, Identifiable {
    public let date: LocalDate
    /// Latest revision per source/market for this date, in deterministic order.
    public let occurrences: [WallpaperOccurrence]
    /// Number of occurrences on this date with a strictly matched available
    /// story.
    public let storyAvailableOccurrenceCount: Int
    /// Distinct favorited images present on this date, sorted.
    public let favoriteImageIDs: [WallpaperID]

    public var id: LocalDate { date }

    public var imageCount: Int {
        Set(occurrences.map(\.wallpaperID)).count
    }

    public var hasAvailableStory: Bool {
        storyAvailableOccurrenceCount > 0
    }
}

public struct MonthlyRecap: Hashable, Sendable {
    public let summary: RecapSummary
    /// Observed dates only, ascending. Dates without records remain visible in
    /// `summary` as unobserved rather than being filled with zero-valued days.
    public let days: [RecapDay]
}

/// One month bucket inside a yearly recap. Only observed months are present;
/// absent months are unobserved, not months with zero Bing wallpapers.
public struct RecapMonth: Hashable, Sendable, Identifiable {
    public let year: Int
    public let month: Int
    public let observedDays: Int
    public let occurrenceCount: Int
    public let uniqueImageCount: Int
    public let favoriteImageCount: Int
    public let storyCoveredDays: Int
    public let marketDayCounts: [Market: Int]

    public var id: String {
        String(format: "%04d-%02d", year, month)
    }
}

public struct YearlyRecap: Hashable, Sendable {
    public let summary: RecapSummary
    /// Observed months only, ascending. A month with no local record is not a
    /// month with zero source wallpapers.
    public let months: [RecapMonth]
}

/// One favorited image and its stored occurrences.
public struct FavoriteEntry: Hashable, Sendable, Identifiable {
    public let wallpaperID: WallpaperID
    /// Latest revision per source/market/date, ascending by date, then source,
    /// market, and image identity for deterministic output.
    public let occurrences: [WallpaperOccurrence]

    public var id: WallpaperID { wallpaperID }

    public var firstObservedDate: LocalDate? {
        occurrences.first?.localDate
    }

    public var latestObservedDate: LocalDate? {
        occurrences.last?.localDate
    }

    public var markets: [Market] {
        Set(occurrences.map(\.market)).sorted()
    }

    public var isDated: Bool {
        !occurrences.isEmpty
    }
}

/// A month bucket for favorites, keyed by the earliest stored occurrence of
/// each image. This is not the time the user tapped "favorite": no interaction
/// log is assumed, so the UI must not present it as favorite-action history.
public struct FavoriteMonth: Hashable, Sendable, Identifiable {
    public let year: Int
    public let month: Int
    public let imageIDs: [WallpaperID]

    public var id: String {
        String(format: "%04d-%02d", year, month)
    }

    public var imageCount: Int {
        imageIDs.count
    }
}

public struct FavoriteRecap: Hashable, Sendable {
    public let asOf: LocalDate
    /// Every favorite in the snapshot, including ones without a stored
    /// occurrence.
    public let favoriteImageCount: Int
    public let datedFavoriteImageCount: Int
    public let undatedFavoriteImageCount: Int
    /// Occurrences of favorite images after revision collapse and date/market
    /// filtering.
    public let totalOccurrences: Int
    /// Distinct dates with at least one favorite occurrence.
    public let distinctObservedDays: Int
    public let marketOccurrenceCounts: [Market: Int]
    /// Acquisition-style timeline by earliest stored occurrence month,
    /// ascending; cross-year is preserved.
    public let months: [FavoriteMonth]
    /// Latest observation first; images without any stored occurrence last.
    public let entries: [FavoriteEntry]

    public var distinctMarketCount: Int {
        marketOccurrenceCounts.count
    }

    public var hasUndatedFavorites: Bool {
        undatedFavoriteImageCount > 0
    }
}

// MARK: - Pure recap engine

public enum RecapBuilder {
    /// Builds a summary from stored records only. Missing dates are never
    /// filled with zero-valued wallpaper records.
    public static func summary(
        occurrences: [WallpaperOccurrence],
        stories: [DailyStoryRecord] = [],
        metadata: [WallpaperMetadataRecord] = [],
        favoriteImageIDs: Set<WallpaperID> = [],
        range: LocalDateRange,
        asOf: LocalDate,
        firstObservedDate: LocalDate?,
        markets: Set<Market>? = nil
    ) -> RecapSummary {
        evaluate(
            occurrences: occurrences,
            stories: stories,
            metadata: metadata,
            favoriteImageIDs: favoriteImageIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: firstObservedDate,
            markets: markets
        ).summary
    }

    public static func monthly(
        occurrences: [WallpaperOccurrence],
        stories: [DailyStoryRecord] = [],
        metadata: [WallpaperMetadataRecord] = [],
        favoriteImageIDs: Set<WallpaperID> = [],
        range: LocalDateRange,
        asOf: LocalDate,
        firstObservedDate: LocalDate?,
        markets: Set<Market>? = nil
    ) -> MonthlyRecap {
        let evaluation = evaluate(
            occurrences: occurrences,
            stories: stories,
            metadata: metadata,
            favoriteImageIDs: favoriteImageIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: firstObservedDate,
            markets: markets
        )
        let grouped = Dictionary(grouping: evaluation.occurrences, by: \.localDate)
        let days = grouped.keys.sorted().map { date -> RecapDay in
            let dayOccurrences = grouped[date] ?? []
            let favoriteIDs = Set(
                dayOccurrences
                    .map(\.wallpaperID)
                    .filter { favoriteImageIDs.contains($0) }
            ).sorted()
            let storyCount = dayOccurrences.reduce(into: 0) { count, occurrence in
                if evaluation.storyLookup.availableStory(for: occurrence) != nil {
                    count += 1
                }
            }
            return RecapDay(
                date: date,
                occurrences: dayOccurrences,
                storyAvailableOccurrenceCount: storyCount,
                favoriteImageIDs: favoriteIDs
            )
        }
        return MonthlyRecap(summary: evaluation.summary, days: days)
    }

    public static func yearly(
        occurrences: [WallpaperOccurrence],
        stories: [DailyStoryRecord] = [],
        metadata: [WallpaperMetadataRecord] = [],
        favoriteImageIDs: Set<WallpaperID> = [],
        range: LocalDateRange,
        asOf: LocalDate,
        firstObservedDate: LocalDate?,
        markets: Set<Market>? = nil
    ) -> YearlyRecap {
        let evaluation = evaluate(
            occurrences: occurrences,
            stories: stories,
            metadata: metadata,
            favoriteImageIDs: favoriteImageIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: firstObservedDate,
            markets: markets
        )
        let grouped = Dictionary(grouping: evaluation.occurrences) { occurrence in
            YearMonth(year: occurrence.localDate.year, month: occurrence.localDate.month)
        }
        let months = grouped.keys.sorted().map { key -> RecapMonth in
            let monthOccurrences = grouped[key] ?? []
            let imageIDs = Set(monthOccurrences.map(\.wallpaperID))
            let storyDates = Set(monthOccurrences.compactMap { occurrence -> LocalDate? in
                evaluation.storyLookup.availableStory(for: occurrence) == nil
                    ? nil
                    : occurrence.localDate
            })
            let marketDays = Dictionary(grouping: monthOccurrences, by: \.market)
                .mapValues { Set($0.map(\.localDate)).count }
            return RecapMonth(
                year: key.year,
                month: key.month,
                observedDays: Set(monthOccurrences.map(\.localDate)).count,
                occurrenceCount: monthOccurrences.count,
                uniqueImageCount: imageIDs.count,
                favoriteImageCount: imageIDs.intersection(favoriteImageIDs).count,
                storyCoveredDays: storyDates.count,
                marketDayCounts: marketDays
            )
        }
        return YearlyRecap(summary: evaluation.summary, months: months)
    }

    /// Favorite recap is intentionally independent of a recap range: favorites
    /// may span years and are not a coverage statistic.
    public static func favorites(
        occurrences: [WallpaperOccurrence],
        favoriteImageIDs: Set<WallpaperID>,
        asOf: LocalDate,
        markets: Set<Market>? = nil
    ) -> FavoriteRecap {
        let latest = OccurrenceIndex.latest(occurrences).filter { occurrence in
            guard occurrence.localDate <= asOf,
                  favoriteImageIDs.contains(occurrence.wallpaperID)
            else {
                return false
            }
            if let markets, !markets.contains(occurrence.market) {
                return false
            }
            return true
        }

        let byImage = Dictionary(grouping: latest, by: \.wallpaperID)
        var entries: [FavoriteEntry] = favoriteImageIDs.map { imageID in
            let imageOccurrences = (byImage[imageID] ?? []).sorted { lhs, rhs in
                if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
                if lhs.source != rhs.source { return lhs.source < rhs.source }
                if lhs.market != rhs.market { return lhs.market < rhs.market }
                return lhs.wallpaperID < rhs.wallpaperID
            }
            return FavoriteEntry(wallpaperID: imageID, occurrences: imageOccurrences)
        }

        entries.sort { lhs, rhs in
            switch (lhs.latestObservedDate, rhs.latestObservedDate) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.wallpaperID < rhs.wallpaperID
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.wallpaperID < rhs.wallpaperID
            }
        }

        var imageIDsByMonth: [YearMonth: [WallpaperID]] = [:]
        for entry in entries {
            guard let firstDate = entry.firstObservedDate else { continue }
            imageIDsByMonth[YearMonth(year: firstDate.year, month: firstDate.month), default: []]
                .append(entry.wallpaperID)
        }
        let months = imageIDsByMonth.keys.sorted().map { key in
            FavoriteMonth(
                year: key.year,
                month: key.month,
                imageIDs: (imageIDsByMonth[key] ?? []).sorted()
            )
        }

        let datedCount = entries.reduce(into: 0) { count, entry in
            if entry.isDated { count += 1 }
        }
        let marketOccurrenceCounts = Dictionary(grouping: latest, by: \.market)
            .mapValues { $0.count }

        return FavoriteRecap(
            asOf: asOf,
            favoriteImageCount: favoriteImageIDs.count,
            datedFavoriteImageCount: datedCount,
            undatedFavoriteImageCount: favoriteImageIDs.count - datedCount,
            totalOccurrences: latest.count,
            distinctObservedDays: Set(latest.map(\.localDate)).count,
            marketOccurrenceCounts: marketOccurrenceCounts,
            months: months,
            entries: entries
        )
    }

    // MARK: Selection and summary

    static func evaluate(
        occurrences: [WallpaperOccurrence],
        stories: [DailyStoryRecord],
        metadata: [WallpaperMetadataRecord],
        favoriteImageIDs: Set<WallpaperID>,
        range: LocalDateRange,
        asOf: LocalDate,
        firstObservedDate: LocalDate?,
        markets: Set<Market>?
    ) -> RecapEvaluation {
        // The repository stores one global source date as the observation
        // start. In a multi-market installation it can legitimately be later
        // than the requested market's `asOf`: the first fetch used a market
        // whose source date had already rolled over (for example `zh-CN` just
        // after its midnight), and the user then inspects a market west of it.
        // When the window already contains locally recorded days, that anchor
        // cannot bound it: applying it would hide every record and report "no
        // observation" for a window that does have records. Treat the window
        // as having no known start instead, so recorded days stay visible and
        // no denominator is invented. A window with no records at all keeps
        // the anchor, so a period before installation stays distinguishable
        // from an unknown start.
        let inWindow = OccurrenceIndex.latest(occurrences).filter { occurrence in
            guard range.contains(occurrence.localDate),
                  occurrence.localDate <= asOf
            else {
                return false
            }
            if let markets, !markets.contains(occurrence.market) {
                return false
            }
            return true
        }
        let observationStart: LocalDate?
        if let firstObservedDate, firstObservedDate > asOf, !inWindow.isEmpty {
            observationStart = nil
        } else {
            observationStart = firstObservedDate
        }
        let selected = inWindow.filter { occurrence in
            if let observationStart, occurrence.localDate < observationStart {
                return false
            }
            return true
        }
        let storyLookup = StoryLookup(metadata: metadata, stories: stories)
        let summary = makeSummary(
            selected: selected,
            storyLookup: storyLookup,
            favoriteImageIDs: favoriteImageIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: observationStart
        )
        return RecapEvaluation(
            summary: summary,
            occurrences: selected,
            storyLookup: storyLookup
        )
    }

    private static func makeSummary(
        selected: [WallpaperOccurrence],
        storyLookup: StoryLookup,
        favoriteImageIDs: Set<WallpaperID>,
        range: LocalDateRange,
        asOf: LocalDate,
        firstObservedDate: LocalDate?
    ) -> RecapSummary {
        let observedDates = Set(selected.map(\.localDate))
        let imageIDs = Set(selected.map(\.wallpaperID))
        let marketDayCounts = Dictionary(grouping: selected, by: \.market)
            .mapValues { Set($0.map(\.localDate)).count }
        let marketOccurrenceCounts = Dictionary(grouping: selected, by: \.market)
            .mapValues { $0.count }
        let storyCoveredDates = Set(selected.compactMap { occurrence -> LocalDate? in
            storyLookup.availableStory(for: occurrence) == nil
                ? nil
                : occurrence.localDate
        })

        let effectiveRange: LocalDateRange?
        let eligibleDays: Int?
        if let firstObservedDate {
            let lowerBound = Swift.max(range.start, firstObservedDate)
            let upperBound = Swift.min(range.end, asOf)
            if let window = LocalDateRange(start: lowerBound, end: upperBound) {
                effectiveRange = window
                eligibleDays = window.dayCount
            } else {
                effectiveRange = nil
                eligibleDays = 0
            }
        } else {
            effectiveRange = nil
            eligibleDays = nil
        }

        let observedDays = observedDates.count
        let coverage: Double?
        if let eligibleDays, eligibleDays > 0 {
            coverage = Double(observedDays) / Double(eligibleDays)
        } else {
            coverage = nil
        }

        let coverageState: CoverageState
        if firstObservedDate == nil {
            coverageState = .firstObservedDateUnknown
        } else if eligibleDays == 0 || observedDays == 0 {
            coverageState = .noObservation
        } else if observedDays >= (eligibleDays ?? 0) {
            coverageState = .complete
        } else {
            coverageState = .partial
        }

        return RecapSummary(
            range: range,
            asOf: asOf,
            firstObservedDate: firstObservedDate,
            effectiveRange: effectiveRange,
            eligibleDays: eligibleDays,
            observedDays: observedDays,
            unobservedDays: eligibleDays.map { Swift.max(0, $0 - observedDays) },
            totalOccurrences: selected.count,
            uniqueImageCount: imageIDs.count,
            marketDayCounts: marketDayCounts,
            marketOccurrenceCounts: marketOccurrenceCounts,
            storyCoveredDays: storyCoveredDates.count,
            favoriteImageCount: imageIDs.intersection(favoriteImageIDs).count,
            coverage: coverage,
            coverageState: coverageState
        )
    }
}

struct RecapEvaluation {
    let summary: RecapSummary
    let occurrences: [WallpaperOccurrence]
    let storyLookup: StoryLookup
}

/// Groups stories by the only keys the strict matcher may attach them with:
/// source + market + source-local date, plus optional exact source-URL
/// corroboration from the occurrence's metadata row. A story without either
/// corroboration still stays unmatched inside this bucket.
struct StoryLookup: Sendable {
    private let storiesByDay: [OccurrenceKey: [DailyStoryRecord]]
    private let metadataByKey: [OccurrenceKey: WallpaperMetadataRecord]

    init(metadata: [WallpaperMetadataRecord], stories: [DailyStoryRecord]) {
        self.storiesByDay = Dictionary(grouping: stories) { story in
            OccurrenceKey(source: story.source, market: story.market, localDate: story.date)
        }
        var metadataByKey: [OccurrenceKey: WallpaperMetadataRecord] = [:]
        for record in metadata {
            if let existing = metadataByKey[record.key],
               existing.fetchedAt > record.fetchedAt {
                continue
            }
            metadataByKey[record.key] = record
        }
        self.metadataByKey = metadataByKey
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

struct YearMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

enum CalendarDateRange {
    static func month(year: Int, month: Int) throws -> LocalDateRange {
        guard (1...12).contains(month) else {
            throw CalendarServiceError.invalidMonth(month)
        }
        guard let start = LocalDate(year: year, month: month, day: 1) else {
            throw CalendarServiceError.invalidYear(year)
        }
        let lastDay = LocalDate.daysInMonth(year: year, month: month)
        guard let end = LocalDate(year: year, month: month, day: lastDay),
              let range = LocalDateRange(start: start, end: end)
        else {
            throw CalendarServiceError.invalidYear(year)
        }
        return range
    }

    static func year(_ year: Int) throws -> LocalDateRange {
        guard let start = LocalDate(year: year, month: 1, day: 1),
              let end = LocalDate(year: year, month: 12, day: 31),
              let range = LocalDateRange(start: start, end: end)
        else {
            throw CalendarServiceError.invalidYear(year)
        }
        return range
    }
}

// MARK: - Service

public struct RecapService: Sendable {
    private let snapshotProvider: any RepositorySnapshotProviding

    public init(snapshotProvider: any RepositorySnapshotProviding) {
        self.snapshotProvider = snapshotProvider
    }

    /// Calendar-month recap. `asOf` is supplied explicitly; this type never
    /// reads the device clock.
    public func monthlyRecap(
        year: Int,
        month: Int,
        asOf: LocalDate,
        markets: Set<Market>? = nil
    ) async throws -> MonthlyRecap {
        let range = try CalendarDateRange.month(year: year, month: month)
        let snapshot = try await snapshotProvider.repositorySnapshot()
        return RecapBuilder.monthly(
            occurrences: snapshot.occurrences,
            stories: snapshot.stories,
            metadata: snapshot.metadata,
            favoriteImageIDs: snapshot.favoriteWallpaperIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: snapshot.firstObservedDate,
            markets: markets
        )
    }

    /// Calendar-year recap clipped to the local observation window and
    /// `asOf`. Pre-installation dates never enter the denominator.
    public func yearlyRecap(
        year: Int,
        asOf: LocalDate,
        markets: Set<Market>? = nil
    ) async throws -> YearlyRecap {
        let range = try CalendarDateRange.year(year)
        let snapshot = try await snapshotProvider.repositorySnapshot()
        return RecapBuilder.yearly(
            occurrences: snapshot.occurrences,
            stories: snapshot.stories,
            metadata: snapshot.metadata,
            favoriteImageIDs: snapshot.favoriteWallpaperIDs,
            range: range,
            asOf: asOf,
            firstObservedDate: snapshot.firstObservedDate,
            markets: markets
        )
    }

    /// Favorites across all years, independent of recap coverage. Images that
    /// have no stored occurrence remain visible as undated favorites.
    public func favoriteRecap(
        asOf: LocalDate,
        markets: Set<Market>? = nil
    ) async throws -> FavoriteRecap {
        let snapshot = try await snapshotProvider.repositorySnapshot()
        return RecapBuilder.favorites(
            occurrences: snapshot.occurrences,
            favoriteImageIDs: snapshot.favoriteWallpaperIDs,
            asOf: asOf,
            markets: markets
        )
    }
}

