import Foundation

// MARK: - Day state

/// What the local store can honestly say about one source-local date.
public enum TimelineDayState: String, Hashable, Sendable, Codable {
    /// A stored occurrence exists for this source/market/date.
    case observed
    /// No stored occurrence, and the date is inside the known observation
    /// window (or the observation start is unknown). This is a local state,
    /// not evidence that Bing published no image: the app may not have run,
    /// the market may have been disabled, or the provider may have failed.
    case notRecorded
    /// The date precedes the first successful local observation. No record is
    /// expected and recap denominators exclude it.
    case beforeObservationStart
    /// The date is after the supplied `asOf` date. Never counted as observed.
    case future
}

/// Story state for one observed occurrence, independent of image assets.
public enum TimelineStoryStatus: Hashable, Sendable {
    /// No story record is attached by strict image identity + market + date.
    /// The image remains usable; UI must not fabricate a story.
    case notStored
    /// A strictly matched record exists, but the source provided no usable
    /// text. The record may still carry a source headline/copyright for
    /// display.
    case unavailable(reason: StoryUnavailableReason, record: DailyStoryRecord)
    /// A strictly matched record with usable text exists.
    case available(DailyStoryRecord)

    public var record: DailyStoryRecord? {
        switch self {
        case .notStored:
            return nil
        case .available(let record), .unavailable(_, let record):
            return record
        }
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var unavailableReason: StoryUnavailableReason? {
        if case .unavailable(let reason, _) = self { return reason }
        return nil
    }
}

/// Independent local status flags for one observed day. Thumbnail, original,
/// story, and favorite are deliberately separate dimensions; no combination
/// implies another.
public struct TimelineObservedContent: Hashable, Sendable {
    public let occurrence: WallpaperOccurrence
    public let thumbnailCached: Bool
    public let originalCached: Bool
    public let isFavorite: Bool
    public let story: TimelineStoryStatus

    public var wallpaperID: WallpaperID {
        occurrence.wallpaperID
    }
}

/// One calendar cell. Status flags live in `content` so an unobserved date
/// cannot be misread as "observed but not cached".
public struct TimelineDay: Hashable, Sendable, Identifiable {
    public let source: SourceID
    public let market: Market
    public let date: LocalDate
    public let state: TimelineDayState
    public let content: TimelineObservedContent?

    public var id: OccurrenceKey {
        OccurrenceKey(source: source, market: market, localDate: date)
    }

    public var isObserved: Bool {
        state == .observed
    }
}

/// A complete calendar month for one source/market. Every date of the month is
/// present; dates after `asOf` are `future`, and dates before a known
/// observation start are `beforeObservationStart`.
public struct TimelineMonth: Hashable, Sendable {
    public let source: SourceID
    public let market: Market
    public let year: Int
    public let month: Int
    public let asOf: LocalDate
    public let firstObservedDate: LocalDate?
    public let days: [TimelineDay]

    public var observedDayCount: Int {
        countDays { $0.state == .observed }
    }

    public var notRecordedDayCount: Int {
        countDays { $0.state == .notRecorded }
    }

    public var beforeObservationStartDayCount: Int {
        countDays { $0.state == .beforeObservationStart }
    }

    public var futureDayCount: Int {
        countDays { $0.state == .future }
    }

    public var thumbnailCachedDayCount: Int {
        countDays { $0.content?.thumbnailCached == true }
    }

    public var originalCachedDayCount: Int {
        countDays { $0.content?.originalCached == true }
    }

    public var favoriteDayCount: Int {
        countDays { $0.content?.isFavorite == true }
    }

    public var storyAvailableDayCount: Int {
        countDays { $0.content?.story.isAvailable == true }
    }

    public var storyUnavailableDayCount: Int {
        countDays {
            guard let story = $0.content?.story else { return false }
            if case .unavailable = story { return true }
            return false
        }
    }

    private func countDays(_ predicate: (TimelineDay) -> Bool) -> Int {
        days.reduce(into: 0) { count, day in
            if predicate(day) { count += 1 }
        }
    }
}

// MARK: - Pure builders

public enum TimelineBuilder {
    public static func day(
        for date: LocalDate,
        market: Market,
        asOf: LocalDate,
        source: SourceID = .bing,
        snapshot: RepositorySnapshot
    ) -> TimelineDay {
        let index = occurrenceIndex(snapshot.occurrences)
        let key = OccurrenceKey(source: source, market: market, localDate: date)
        let state = dayState(
            date: date,
            key: key,
            asOf: asOf,
            firstObservedDate: snapshot.firstObservedDate,
            occurrenceIndex: index
        )
        let content: TimelineObservedContent?
        if state == .observed, let occurrence = index[key] {
            let match = StoryMatcher.match(
                occurrence: occurrence,
                metadata: snapshot.metadata(for: key),
                stories: snapshot.stories
            )
            content = makeContent(for: occurrence, snapshot: snapshot, match: match)
        } else {
            content = nil
        }
        return TimelineDay(
            source: source,
            market: market,
            date: date,
            state: state,
            content: content
        )
    }

    public static func month(
        year: Int,
        month: Int,
        market: Market,
        asOf: LocalDate,
        source: SourceID = .bing,
        snapshot: RepositorySnapshot
    ) throws -> TimelineMonth {
        let range = try CalendarDateRange.month(year: year, month: month)
        let index = occurrenceIndex(snapshot.occurrences)
        let storyLookup = StoryLookup(metadata: snapshot.metadata, stories: snapshot.stories)

        var days: [TimelineDay] = []
        days.reserveCapacity(range.dayCount)
        var date = range.start
        while date <= range.end {
            let key = OccurrenceKey(source: source, market: market, localDate: date)
            let state = dayState(
                date: date,
                key: key,
                asOf: asOf,
                firstObservedDate: snapshot.firstObservedDate,
                occurrenceIndex: index
            )
            let content: TimelineObservedContent?
            if state == .observed, let occurrence = index[key] {
                content = makeContent(
                    for: occurrence,
                    snapshot: snapshot,
                    match: storyLookup.match(occurrence)
                )
            } else {
                content = nil
            }
            days.append(
                TimelineDay(
                    source: source,
                    market: market,
                    date: date,
                    state: state,
                    content: content
                )
            )
            guard let next = date.nextDay else { break }
            date = next
        }

        return TimelineMonth(
            source: source,
            market: market,
            year: year,
            month: month,
            asOf: asOf,
            firstObservedDate: snapshot.firstObservedDate,
            days: days
        )
    }

    private static func occurrenceIndex(
        _ occurrences: [WallpaperOccurrence]
    ) -> [OccurrenceKey: WallpaperOccurrence] {
        var index: [OccurrenceKey: WallpaperOccurrence] = [:]
        for occurrence in OccurrenceIndex.latest(occurrences) {
            index[occurrence.id] = occurrence
        }
        return index
    }

    private static func dayState(
        date: LocalDate,
        key: OccurrenceKey,
        asOf: LocalDate,
        firstObservedDate: LocalDate?,
        occurrenceIndex: [OccurrenceKey: WallpaperOccurrence]
    ) -> TimelineDayState {
        if occurrenceIndex[key] != nil, date <= asOf {
            return .observed
        }
        if date > asOf {
            return .future
        }
        if let firstObservedDate, date < firstObservedDate {
            return .beforeObservationStart
        }
        return .notRecorded
    }

    private static func makeContent(
        for occurrence: WallpaperOccurrence,
        snapshot: RepositorySnapshot,
        match: StoryMatch
    ) -> TimelineObservedContent {
        let imageID = occurrence.wallpaperID
        return TimelineObservedContent(
            occurrence: occurrence,
            thumbnailCached: snapshot.availableThumbnailIDs.contains(imageID),
            originalCached: snapshot.availableOriginalIDs.contains(imageID),
            isFavorite: snapshot.favoriteWallpaperIDs.contains(imageID),
            story: storyStatus(from: match)
        )
    }

    private static func storyStatus(from match: StoryMatch) -> TimelineStoryStatus {
        switch match {
        case .matched(let story, _):
            return .available(story)
        case .unavailable(let story):
            if case .unavailable(let reason) = story.availability {
                return .unavailable(reason: reason, record: story)
            }
            // Defensive: a future StoryMatch revision may carry a record whose
            // availability changed; keep the usable text rather than inventing
            // an unavailable reason.
            return .available(story)
        case .unmatched:
            return .notStored
        }
    }
}

// MARK: - Service

public struct TimelineService: Sendable {
    private let snapshotProvider: any RepositorySnapshotProviding

    public init(snapshotProvider: any RepositorySnapshotProviding) {
        self.snapshotProvider = snapshotProvider
    }

    /// Single-date query. `asOf` is supplied by the caller; this type never
    /// reads the device clock.
    public func day(
        for date: LocalDate,
        market: Market,
        asOf: LocalDate,
        source: SourceID = .bing
    ) async throws -> TimelineDay {
        let snapshot = try await snapshotProvider.repositorySnapshot()
        return TimelineBuilder.day(
            for: date,
            market: market,
            asOf: asOf,
            source: source,
            snapshot: snapshot
        )
    }

    /// Full-month query, including every calendar date so the UI can show
    /// unobserved, pre-installation, and future cells without inventing data.
    public func month(
        year: Int,
        month: Int,
        market: Market,
        asOf: LocalDate,
        source: SourceID = .bing
    ) async throws -> TimelineMonth {
        // Fail before touching the repository when the request is invalid.
        _ = try CalendarDateRange.month(year: year, month: month)
        let snapshot = try await snapshotProvider.repositorySnapshot()
        return try TimelineBuilder.month(
            year: year,
            month: month,
            market: market,
            asOf: asOf,
            source: source,
            snapshot: snapshot
        )
    }
}
