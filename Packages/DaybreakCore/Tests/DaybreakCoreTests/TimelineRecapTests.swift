import Foundation
import Testing
import DaybreakCore

/// Synthetic-only fixtures. No real Bing media, story text, or metadata is
/// used anywhere in this file.
enum Fixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static func date(_ iso8601: String) -> LocalDate {
        guard let value = LocalDate(iso8601: iso8601) else {
            preconditionFailure("Invalid synthetic test date: \(iso8601)")
        }
        return value
    }

    static func image(_ sourceImageID: String, source: SourceID = .bing) -> WallpaperID {
        WallpaperID(source: source, sourceImageID: sourceImageID)
    }

    static func occurrence(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String,
        revision: Int = 0,
        source: SourceID = .bing
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: source,
            market: market,
            localDate: date(iso8601),
            wallpaperID: image(imageID, source: source),
            revision: revision
        )
    }

    static func availableStory(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String?,
        headline: String = "Synthetic headline",
        body: String = "Synthetic story body for tests.",
        quickFact: String? = nil,
        id: String? = nil,
        sourceURL: URL = URL(string: "https://example.invalid/synthetic-story")!,
        source: SourceID = .bing
    ) -> DailyStoryRecord {
        let identifier = id ?? "story:\(source.rawValue):\(market.rawValue):\(iso8601):\(imageID ?? "unbound")"
        guard let story = DailyStoryRecord(
            id: identifier,
            source: source,
            market: market,
            date: date(iso8601),
            associatedWallpaperID: imageID.map { image($0, source: source) },
            headline: headline,
            body: body,
            quickFact: quickFact,
            originalLocale: market.rawValue,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt,
            contentHash: "synthetic-\(identifier)",
            availability: .available
        ) else {
            preconditionFailure("Invalid synthetic available story fixture")
        }
        return story
    }

    static func metadata(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String,
        sourceURL: URL? = URL(string: "https://example.invalid/synthetic-image"),
        source: SourceID = .bing
    ) -> WallpaperMetadataRecord {
        WallpaperMetadataRecord(
            key: OccurrenceKey(
                source: source,
                market: market,
                localDate: date(iso8601)
            ),
            wallpaperID: image(imageID, source: source),
            title: "Synthetic title",
            copyright: "Synthetic copyright",
            sourceURL: sourceURL,
            originalLocale: market.rawValue,
            fetchedAt: fetchedAt,
            contentHash: "synthetic-metadata-\(imageID)"
        )
    }

    static func unavailableStory(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String? = nil,
        reason: StoryUnavailableReason = .notProvidedBySource,
        headline: String? = nil,
        id: String? = nil,
        source: SourceID = .bing
    ) -> DailyStoryRecord {
        let identifier = id ?? "story-unavailable:\(source.rawValue):\(market.rawValue):\(iso8601):\(imageID ?? "unbound")"
        guard let story = DailyStoryRecord(
            id: identifier,
            source: source,
            market: market,
            date: date(iso8601),
            associatedWallpaperID: imageID.map { image($0, source: source) },
            headline: headline,
            body: nil,
            quickFact: nil,
            originalLocale: market.rawValue,
            sourceURL: nil,
            fetchedAt: fetchedAt,
            contentHash: nil,
            availability: .unavailable(reason)
        ) else {
            preconditionFailure("Invalid synthetic unavailable story fixture")
        }
        return story
    }

    static func snapshot(
        occurrences: [WallpaperOccurrence],
        stories: [DailyStoryRecord] = [],
        metadata: [WallpaperMetadataRecord] = [],
        favorites: Set<WallpaperID> = [],
        observationStart: LocalDate?,
        thumbnails: Set<WallpaperID> = [],
        originals: Set<WallpaperID> = []
    ) -> RepositorySnapshot {
        var assets: [CachedImageAsset] = []
        for imageID in thumbnails.sorted() {
            assets.append(
                CachedImageAsset(
                    wallpaperID: imageID,
                    kind: .thumbnail,
                    relativePath: "Thumbnails/\(imageID.source.rawValue)-\(imageID.sourceImageID).jpg",
                    byteCount: 1_024,
                    lastAccessedAt: fetchedAt
                )
            )
        }
        for imageID in originals.sorted() {
            assets.append(
                CachedImageAsset(
                    wallpaperID: imageID,
                    kind: .original,
                    relativePath: "Originals/\(imageID.source.rawValue)-\(imageID.sourceImageID).jpg",
                    byteCount: 1_024,
                    lastAccessedAt: fetchedAt
                )
            )
        }
        return RepositorySnapshot(
            occurrences: occurrences,
            metadata: metadata,
            stories: stories,
            assets: assets,
            favoriteWallpaperIDs: favorites,
            firstObservedDate: observationStart
        )
    }
}

struct FakeRepositorySnapshotProvider: RepositorySnapshotProviding {
    let snapshot: RepositorySnapshot

    func repositorySnapshot() async throws -> RepositorySnapshot {
        snapshot
    }
}

// MARK: - Timeline

struct TimelineServiceTests {
    @Test func independentThumbnailOriginalStoryAndFavoriteStatus() async throws {
        let imageID = Fixture.image("image-A")
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-23", imageID: "image-A")],
            stories: [Fixture.availableStory("2026-11-23", imageID: "image-A")],
            favorites: [imageID],
            observationStart: Fixture.date("2026-11-23"),
            thumbnails: [imageID],
            originals: []
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let day = try await service.day(
            for: Fixture.date("2026-11-23"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-23")
        )

        #expect(day.state == .observed)
        let content = try #require(day.content)
        #expect(content.thumbnailCached)
        #expect(content.originalCached == false)
        #expect(content.isFavorite)
        #expect(content.story.isAvailable)
        #expect(content.story.record?.headline == "Synthetic headline")
        #expect(content.wallpaperID == imageID)
    }

    @Test func unavailableStoryIsIndependentFromCachedOriginal() async throws {
        let imageID = Fixture.image("image-A")
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-23", imageID: "image-A")],
            stories: [
                Fixture.unavailableStory(
                    "2026-11-23",
                    imageID: "image-A",
                    reason: .notProvidedBySource,
                    headline: "Synthetic source headline"
                )
            ],
            observationStart: Fixture.date("2026-11-23"),
            thumbnails: [],
            originals: [imageID]
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let day = try await service.day(
            for: Fixture.date("2026-11-23"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-23")
        )

        let content = try #require(day.content)
        #expect(content.story.isAvailable == false)
        #expect(content.story.unavailableReason == .notProvidedBySource)
        #expect(content.story.record?.headline == "Synthetic source headline")
        #expect(content.originalCached)
        #expect(content.thumbnailCached == false)
        #expect(content.isFavorite == false)
    }

    @Test func exactSourceURLCorroboratesStoryWithoutImageIdentity() async throws {
        let contentURL = URL(string: "https://example.invalid/synthetic-day-page")!
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-23", imageID: "image-A")],
            stories: [
                Fixture.availableStory(
                    "2026-11-23",
                    imageID: nil,
                    sourceURL: contentURL
                )
            ],
            metadata: [
                Fixture.metadata("2026-11-23", imageID: "image-A", sourceURL: contentURL)
            ],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let day = try await service.day(
            for: Fixture.date("2026-11-23"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-23")
        )

        let content = try #require(day.content)
        #expect(content.story.isAvailable)
        #expect(content.story.record?.associatedWallpaperID == nil)
        #expect(content.story.record?.sourceURL == contentURL)
    }

    @Test func distinguishesObservedNotRecordedPreInstallationAndFuture() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-24", imageID: "image-A")],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let beforeStart = try await service.day(
            for: Fixture.date("2026-11-22"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-30")
        )
        let insideWindow = try await service.day(
            for: Fixture.date("2026-11-23"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-30")
        )
        let observed = try await service.day(
            for: Fixture.date("2026-11-24"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-30")
        )
        let future = try await service.day(
            for: Fixture.date("2026-12-01"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-30")
        )

        #expect(beforeStart.state == .beforeObservationStart)
        #expect(beforeStart.content == nil)
        #expect(insideWindow.state == .notRecorded)
        #expect(insideWindow.content == nil)
        #expect(observed.state == .observed)
        #expect(observed.content != nil)
        #expect(future.state == .future)
        #expect(future.content == nil)
    }

    @Test func unknownObservationStartNeverClaimsTheDateIsMissingFromTheSource() async throws {
        let snapshot = Fixture.snapshot(occurrences: [], observationStart: nil)
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let day = try await service.day(
            for: Fixture.date("2026-11-23"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-23")
        )

        #expect(day.state == .notRecorded)
        #expect(day.content == nil)
    }

    @Test func backfilledPreInstallationDateRemainsBrowsable() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-20", imageID: "image-backfilled")],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let day = try await service.day(
            for: Fixture.date("2026-11-20"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-30")
        )

        #expect(day.state == .observed)
        #expect(day.content?.wallpaperID == Fixture.image("image-backfilled"))
    }

    @Test func monthContainsEveryDateWithIndependentAggregates() async throws {
        let imageID = Fixture.image("image-A")
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-06", imageID: "image-A"),
                Fixture.occurrence("2026-11-07", imageID: "image-B")
            ],
            stories: [
                Fixture.availableStory("2026-11-06", imageID: "image-A"),
                Fixture.unavailableStory("2026-11-07", imageID: "image-B", reason: .notProvidedBySource)
            ],
            favorites: [imageID],
            observationStart: Fixture.date("2026-11-05"),
            thumbnails: [imageID],
            originals: []
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let month = try await service.month(
            year: 2026,
            month: 11,
            market: .zhCN,
            asOf: Fixture.date("2026-11-10")
        )

        #expect(month.days.count == 30)
        #expect(month.days[3].date == Fixture.date("2026-11-04"))
        #expect(month.days[3].state == .beforeObservationStart)
        #expect(month.days[5].state == .observed)
        #expect(month.days[6].state == .observed)
        #expect(month.days[6].content?.story.unavailableReason == .notProvidedBySource)
        #expect(month.days[7].date == Fixture.date("2026-11-08"))
        #expect(month.days[7].state == .notRecorded)
        #expect(month.days[10].date == Fixture.date("2026-11-11"))
        #expect(month.days[10].state == .future)

        #expect(month.observedDayCount == 2)
        #expect(month.notRecordedDayCount == 4)
        #expect(month.beforeObservationStartDayCount == 4)
        #expect(month.futureDayCount == 20)
        #expect(month.thumbnailCachedDayCount == 1)
        #expect(month.originalCachedDayCount == 0)
        #expect(month.favoriteDayCount == 1)
        #expect(month.storyAvailableDayCount == 1)
        #expect(month.storyUnavailableDayCount == 1)
    }

    @Test func monthRejectsInvalidMonthBeforeQueryingTheRepository() async {
        let service = TimelineService(
            snapshotProvider: FakeRepositorySnapshotProvider(snapshot: Fixture.snapshot(occurrences: [], observationStart: nil))
        )

        do {
            _ = try await service.month(
                year: 2026,
                month: 13,
                market: .zhCN,
                asOf: Fixture.date("2026-11-30")
            )
            Issue.record("Expected an invalid-month error")
        } catch let error as CalendarServiceError {
            #expect(error == .invalidMonth(13))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func monthRejectsInvalidYear() {
        do {
            _ = try TimelineBuilder.month(
                year: 0,
                month: 1,
                market: .zhCN,
                asOf: Fixture.date("2026-11-30"),
                snapshot: Fixture.snapshot(occurrences: [], observationStart: nil)
            )
            Issue.record("Expected an invalid-year error")
        } catch let error as CalendarServiceError {
            #expect(error == .invalidYear(0))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func sourceIsolationKeepsAnotherSourcesOccurrenceOutOfTheCell() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", imageID: "image-A", source: SourceID("other"))
            ],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = TimelineService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let day = try await service.day(
            for: Fixture.date("2026-11-23"),
            market: .zhCN,
            asOf: Fixture.date("2026-11-23"),
            source: .bing
        )

        #expect(day.state == .notRecorded)
        #expect(day.content == nil)
    }
}

// MARK: - Recap

struct RecapServiceTests {
    @Test func monthlyCoverageStartsAtFirstObservationAndNeverZeroFills() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", imageID: "image-1"),
                Fixture.occurrence("2026-11-25", imageID: "image-2"),
                Fixture.occurrence("2026-11-26", imageID: "image-3"),
                Fixture.occurrence("2026-11-27", imageID: "image-4"),
                Fixture.occurrence("2026-11-28", imageID: "image-5"),
                Fixture.occurrence("2026-11-20", imageID: "image-pre-install"),
                Fixture.occurrence("2026-12-05", imageID: "image-after-as-of")
            ],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-30")
        )

        #expect(recap.summary.eligibleDays == 8)
        #expect(recap.summary.observedDays == 5)
        #expect(recap.summary.unobservedDays == 3)
        #expect(recap.summary.coverage == 0.625)
        #expect(recap.summary.coverageState == .partial)
        #expect(recap.summary.totalOccurrences == 5)
        #expect(recap.summary.uniqueImageCount == 5)
        #expect(recap.summary.effectiveRange == LocalDateRange(
            start: Fixture.date("2026-11-23"),
            end: Fixture.date("2026-11-30")
        ))
        #expect(recap.days.count == 5)
        #expect(recap.days.first?.date == Fixture.date("2026-11-23"))
    }

    @Test func crossMarketSameDateCountsOneDayButKeepsMarketCountsSeparate() async throws {
        let favorite = Fixture.image("image-A")
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", market: .zhCN, imageID: "image-A"),
                Fixture.occurrence("2026-11-23", market: .enUS, imageID: "image-A"),
                Fixture.occurrence("2026-11-24", market: .zhCN, imageID: "image-B")
            ],
            favorites: [favorite],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-24")
        )

        #expect(recap.summary.observedDays == 2)
        #expect(recap.summary.totalOccurrences == 3)
        #expect(recap.summary.uniqueImageCount == 2)
        #expect(recap.summary.favoriteImageCount == 1)
        #expect(recap.summary.marketDayCounts == [Market.zhCN: 2, Market.enUS: 1])
        #expect(recap.summary.marketOccurrenceCounts == [Market.zhCN: 2, Market.enUS: 1])
        #expect(recap.summary.distinctMarketCount == 2)
        #expect(recap.summary.mostUsedMarket == .zhCN)
        #expect(recap.days[0].imageCount == 1)
        #expect(recap.days[0].occurrences.count == 2)
        #expect(recap.days[0].favoriteImageIDs == [favorite])
    }

    @Test func yearlyRecapOnlyCoversRecordedWindowAndOmitsUnobservedMonths() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", imageID: "image-1"),
                Fixture.occurrence("2026-11-25", imageID: "image-2"),
                Fixture.occurrence("2026-11-26", imageID: "image-3"),
                Fixture.occurrence("2026-11-27", imageID: "image-4"),
                Fixture.occurrence("2026-11-28", imageID: "image-5")
            ],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.yearlyRecap(
            year: 2026,
            asOf: Fixture.date("2026-11-30")
        )

        #expect(recap.summary.range == LocalDateRange(
            start: Fixture.date("2026-01-01"),
            end: Fixture.date("2026-12-31")
        ))
        #expect(recap.summary.eligibleDays == 8)
        #expect(recap.summary.observedDays == 5)
        #expect(recap.summary.unobservedDays == 3)
        #expect(recap.summary.coverageState == .partial)
        #expect(recap.months.count == 1)
        #expect(recap.months.first?.year == 2026)
        #expect(recap.months.first?.month == 11)
        #expect(recap.months.first?.observedDays == 5)
        #expect(recap.months.first?.occurrenceCount == 5)
        #expect(recap.months.first?.uniqueImageCount == 5)
    }

    @Test func yearBeforeInstallationHasNoEligibleDaysOrFabricatedMonths() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-23", imageID: "image-A")],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.yearlyRecap(
            year: 2025,
            asOf: Fixture.date("2026-01-31")
        )

        #expect(recap.summary.effectiveRange == nil)
        #expect(recap.summary.eligibleDays == 0)
        #expect(recap.summary.observedDays == 0)
        #expect(recap.summary.unobservedDays == 0)
        #expect(recap.summary.coverage == nil)
        #expect(recap.summary.coverageState == .noObservation)
        #expect(recap.months.isEmpty)
    }

    @Test func singleObservationIsNotPresentedAsComparableAnnualCoverage() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-23", imageID: "image-A")],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.yearlyRecap(
            year: 2026,
            asOf: Fixture.date("2026-12-31")
        )

        #expect(recap.summary.eligibleDays == 39)
        #expect(recap.summary.observedDays == 1)
        #expect(recap.summary.unobservedDays == 38)
        #expect(recap.summary.hasComparableObservations == false)
        #expect(recap.summary.coverageState == .partial)
        #expect((recap.summary.coverage ?? 0) < 0.1)
        #expect(recap.months.count == 1)
    }

    @Test func unknownObservationStartLeavesCoverageUncomputable() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", imageID: "image-A"),
                Fixture.occurrence("2026-11-24", imageID: "image-B")
            ],
            observationStart: nil
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-30")
        )

        #expect(recap.summary.observedDays == 2)
        #expect(recap.summary.eligibleDays == nil)
        #expect(recap.summary.unobservedDays == nil)
        #expect(recap.summary.coverage == nil)
        #expect(recap.summary.coverageState == .firstObservedDateUnknown)
        #expect(recap.summary.effectiveRange == nil)
    }

    @Test func occurrenceRevisionsCountOnceAndPreferLatestContent() async throws {
        let oldImage = Fixture.image("image-old")
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", imageID: "image-old", revision: 0),
                Fixture.occurrence("2026-11-23", imageID: "image-new", revision: 1)
            ],
            favorites: [oldImage],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-23")
        )

        #expect(recap.summary.totalOccurrences == 1)
        #expect(recap.summary.observedDays == 1)
        #expect(recap.summary.uniqueImageCount == 1)
        #expect(recap.summary.favoriteImageCount == 0)
        #expect(recap.days.first?.occurrences.first?.wallpaperID == Fixture.image("image-new"))
    }

    @Test func onlyMatchedAvailableStoriesContributeStoryCoverage() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-22", imageID: "image-A"),
                Fixture.occurrence("2026-11-23", imageID: "image-B"),
                Fixture.occurrence("2026-11-24", imageID: "image-C")
            ],
            stories: [
                Fixture.availableStory("2026-11-22", imageID: "image-A"),
                Fixture.unavailableStory("2026-11-23", imageID: "image-B", reason: .fetchFailed),
                Fixture.availableStory("2026-11-23", imageID: "image-C"),
                Fixture.availableStory("2026-11-24", imageID: nil)
            ],
            observationStart: Fixture.date("2026-11-22")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-24")
        )

        #expect(recap.summary.storyCoveredDays == 1)
        #expect(recap.days[0].storyAvailableOccurrenceCount == 1)
        #expect(recap.days[1].storyAvailableOccurrenceCount == 0)
        #expect(recap.days[2].storyAvailableOccurrenceCount == 0)
    }

    @Test func marketFilterKeepsGlobalAndPerMarketCountsSeparate() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", market: .zhCN, imageID: "image-A"),
                Fixture.occurrence("2026-11-23", market: .enUS, imageID: "image-B"),
                Fixture.occurrence("2026-11-24", market: .zhCN, imageID: "image-C")
            ],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-24"),
            markets: [Market.zhCN]
        )

        #expect(recap.summary.observedDays == 2)
        #expect(recap.summary.totalOccurrences == 2)
        #expect(recap.summary.uniqueImageCount == 2)
        #expect(recap.summary.marketDayCounts == [Market.zhCN: 2])
        #expect(recap.summary.marketDayCounts[Market.enUS] == nil)
        #expect(recap.summary.distinctMarketCount == 1)
        #expect(recap.summary.mostUsedMarket == .zhCN)
    }

    @Test func emptyMarketSetExcludesEveryWithoutPretendingTheRangeWasAbsent() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-23", imageID: "image-A")],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-24"),
            markets: []
        )

        #expect(recap.summary.eligibleDays == 2)
        #expect(recap.summary.observedDays == 0)
        #expect(recap.summary.totalOccurrences == 0)
        #expect(recap.summary.marketDayCounts.isEmpty)
        #expect(recap.summary.marketOccurrenceCounts.isEmpty)
        #expect(recap.summary.storyCoveredDays == 0)
        #expect(recap.summary.favoriteImageCount == 0)
        #expect(recap.summary.coverage == 0.0)
        #expect(recap.summary.coverageState == .noObservation)
    }

    @Test func mostUsedMarketTieBreaksDeterministically() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-11-23", market: .zhCN, imageID: "image-A"),
                Fixture.occurrence("2026-11-23", market: .enUS, imageID: "image-B")
            ],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-23")
        )

        #expect(recap.summary.marketDayCounts == [Market.zhCN: 1, Market.enUS: 1])
        #expect(recap.summary.marketOccurrenceCounts == [Market.zhCN: 1, Market.enUS: 1])
        #expect(recap.summary.mostUsedMarket == .enUS)
    }

    @Test func preInstallationRecordIsNotCountedAsCoverage() async throws {
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-20", imageID: "image-pre-install")],
            observationStart: Fixture.date("2026-11-23")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-30")
        )

        #expect(recap.summary.eligibleDays == 8)
        #expect(recap.summary.observedDays == 0)
        #expect(recap.summary.unobservedDays == 8)
        #expect(recap.summary.coverageState == .noObservation)
        #expect(recap.days.isEmpty)
    }

    @Test func observationStartLaterThanTheWindowDoesNotHideRecordedDays() async throws {
        // A multi-market first fetch can store an anchor from a market that
        // had already rolled over (here 2026-11-26) while the queried market's
        // asOf is still 2026-11-25. The anchor cannot bound this window: the
        // recorded day must stay visible and no denominator may be invented.
        let snapshot = Fixture.snapshot(
            occurrences: [Fixture.occurrence("2026-11-25", market: .enUS, imageID: "image-west")],
            observationStart: Fixture.date("2026-11-26")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.monthlyRecap(
            year: 2026,
            month: 11,
            asOf: Fixture.date("2026-11-25"),
            markets: [Market.enUS]
        )

        #expect(recap.summary.firstObservedDate == nil)
        #expect(recap.summary.effectiveRange == nil)
        #expect(recap.summary.eligibleDays == nil)
        #expect(recap.summary.unobservedDays == nil)
        #expect(recap.summary.coverage == nil)
        #expect(recap.summary.coverageState == .firstObservedDateUnknown)
        #expect(recap.summary.observedDays == 1)
        #expect(recap.summary.totalOccurrences == 1)
        #expect(recap.days.map(\.date) == [Fixture.date("2026-11-25")])
    }
}

// MARK: - Favorites

struct FavoriteRecapTests {
    @Test func favoriteRecapDeduplicatesImagesAcrossOccurrences() async throws {
        let favoriteA = Fixture.image("image-A")
        let favoriteB = Fixture.image("image-B")
        let favoriteC = Fixture.image("image-C")
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2025-12-31", market: .zhCN, imageID: "image-A"),
                Fixture.occurrence("2026-01-01", market: .zhCN, imageID: "image-A"),
                Fixture.occurrence("2026-01-01", market: .enUS, imageID: "image-A"),
                Fixture.occurrence("2026-01-02", market: .zhCN, imageID: "image-C")
            ],
            favorites: [favoriteA, favoriteB, favoriteC],
            observationStart: Fixture.date("2025-12-31")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.favoriteRecap(asOf: Fixture.date("2026-01-01"))

        #expect(recap.favoriteImageCount == 3)
        #expect(recap.datedFavoriteImageCount == 1)
        #expect(recap.undatedFavoriteImageCount == 2)
        #expect(recap.hasUndatedFavorites)
        #expect(recap.totalOccurrences == 3)
        #expect(recap.distinctObservedDays == 2)
        #expect(recap.marketOccurrenceCounts == [Market.zhCN: 2, Market.enUS: 1])
        #expect(recap.distinctMarketCount == 2)
        #expect(recap.months.count == 1)
        #expect(recap.months.first?.id == "2025-12")
        #expect(recap.months.first?.imageIDs == [favoriteA])
        #expect(recap.entries.first?.wallpaperID == favoriteA)
        #expect(recap.entries.first?.occurrences.count == 3)
        #expect(recap.entries.first?.firstObservedDate == Fixture.date("2025-12-31"))
        #expect(recap.entries.first?.latestObservedDate == Fixture.date("2026-01-01"))
        #expect(recap.entries.last?.isDated == false)
    }

    @Test func favoriteTimelinePreservesCrossYearEarliestObservationMonths() async throws {
        let favoriteA = Fixture.image("image-A")
        let favoriteB = Fixture.image("image-B")
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2025-12-31", imageID: "image-A"),
                Fixture.occurrence("2026-01-01", imageID: "image-A"),
                Fixture.occurrence("2026-01-02", imageID: "image-B")
            ],
            favorites: [favoriteA, favoriteB],
            observationStart: Fixture.date("2025-12-31")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.favoriteRecap(asOf: Fixture.date("2026-01-02"))

        #expect(recap.months.map(\.id) == ["2025-12", "2026-01"])
        #expect(recap.months[0].imageIDs == [favoriteA])
        #expect(recap.months[1].imageIDs == [favoriteB])
        #expect(recap.entries.map(\.wallpaperID) == [favoriteB, favoriteA])
        #expect(recap.entries[0].latestObservedDate == Fixture.date("2026-01-02"))
        #expect(recap.entries[1].latestObservedDate == Fixture.date("2026-01-01"))
    }

    @Test func favoriteRecapMarketFilterReducesOccurrencesNotTheFavoriteImageCount() async throws {
        let favorite = Fixture.image("image-A")
        let snapshot = Fixture.snapshot(
            occurrences: [
                Fixture.occurrence("2026-01-01", market: .zhCN, imageID: "image-A"),
                Fixture.occurrence("2026-01-01", market: .enUS, imageID: "image-A")
            ],
            favorites: [favorite],
            observationStart: Fixture.date("2026-01-01")
        )
        let service = RecapService(snapshotProvider: FakeRepositorySnapshotProvider(snapshot: snapshot))

        let recap = try await service.favoriteRecap(
            asOf: Fixture.date("2026-01-01"),
            markets: [Market.zhCN]
        )

        #expect(recap.favoriteImageCount == 1)
        #expect(recap.totalOccurrences == 1)
        #expect(recap.marketOccurrenceCounts == [Market.zhCN: 1])
        #expect(recap.distinctMarketCount == 1)
        #expect(recap.distinctObservedDays == 1)
    }
}
