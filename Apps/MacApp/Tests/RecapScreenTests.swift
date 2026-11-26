import DaybreakCore
import Foundation
import Testing
@testable import Daybreak

// MARK: - Synthetic fixtures

private enum RecapTestFixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static func date(_ value: String) -> LocalDate {
        guard let date = LocalDate(iso8601: value) else {
            preconditionFailure("Invalid synthetic test date: \(value)")
        }
        return date
    }

    static func image(_ sourceImageID: String) -> WallpaperID {
        WallpaperID(source: .bing, sourceImageID: sourceImageID)
    }

    static func occurrence(
        _ value: String,
        market: Market = .zhCN,
        imageID: String,
        revision: Int = 0
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: .bing,
            market: market,
            localDate: date(value),
            wallpaperID: image(imageID),
            revision: revision
        )
    }

    static func availableStory(
        _ value: String,
        market: Market = .zhCN,
        imageID: String,
        headline: String = "Synthetic headline",
        body: String = "Synthetic story body.",
        title: String = "Synthetic story title"
    ) -> DailyStoryRecord {
        guard let story = DailyStoryRecord(
            id: "story:\(market.rawValue):\(value):\(imageID)",
            source: .bing,
            market: market,
            date: date(value),
            associatedWallpaperID: image(imageID),
            title: title,
            headline: headline,
            body: body,
            quickFact: nil,
            copyright: "Synthetic copyright",
            originalLocale: market.rawValue,
            sourceURL: URL(string: "https://example.invalid/synthetic-story")!,
            fetchedAt: fetchedAt,
            contentHash: "synthetic-story-\(imageID)",
            availability: .available
        ) else {
            preconditionFailure("Invalid synthetic story fixture")
        }
        return story
    }

    static func unavailableStory(
        _ value: String,
        market: Market = .zhCN,
        imageID: String,
        reason: StoryUnavailableReason = .notProvidedBySource,
        headline: String = "Synthetic source headline"
    ) -> DailyStoryRecord {
        guard let story = DailyStoryRecord(
            id: "story-unavailable:\(market.rawValue):\(value):\(imageID)",
            source: .bing,
            market: market,
            date: date(value),
            associatedWallpaperID: image(imageID),
            title: nil,
            headline: headline,
            body: nil,
            quickFact: nil,
            copyright: nil,
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

    static func utcInstant(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else {
            preconditionFailure("UTC time zone unavailable")
        }
        calendar.timeZone = utc
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = utc
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid synthetic UTC instant")
        }
        return date
    }

    /// Noon UTC keeps the three supported market-local dates on the same day.
    static func noonUTC(year: Int, month: Int, day: Int) -> Date {
        utcInstant(year: year, month: month, day: day, hour: 12)
    }

    static func makeRepository() throws -> (WallpaperRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakRecapScreenTests-\(UUID().uuidString)", isDirectory: true)
        let repository = try WallpaperRepository(directory: directory)
        return (repository, directory)
    }

    /// The repository treats the newest occurrence of its first successful
    /// commit as the observation start, so install day is seeded alone before
    /// later dates (and before any pre-installation backfill).
    static func seedInstallDay(
        _ repository: WallpaperRepository,
        date: String,
        imageID: String,
        market: Market = .zhCN
    ) async throws {
        _ = try await repository.upsertOccurrences([
            occurrence(date, market: market, imageID: imageID)
        ])
    }
}

// MARK: - Monthly

@MainActor
@Suite("Recap screen model")
struct RecapScreenTests {
    @Test("monthly coverage uses only the observed window and never zero-fills")
    func monthlyCoverageAndNavigation() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "install"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence("2026-11-24", imageID: "b"),
            RecapTestFixture.occurrence("2026-11-25", imageID: "c"),
            RecapTestFixture.occurrence("2026-11-26", imageID: "d"),
            RecapTestFixture.occurrence("2026-11-27", imageID: "e"),
            RecapTestFixture.occurrence("2026-11-20", imageID: "pre-install")
        ])

        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        #expect(model.loadError == nil)
        #expect(model.asOf == RecapTestFixture.date("2026-11-30"))
        #expect(model.selectedYear == 2026)
        #expect(model.selectedMonth == 11)
        #expect(model.isCurrentMonth)
        #expect(model.canGoToNextMonth == false)

        let recap = try #require(model.monthlyRecap)
        #expect(recap.summary.eligibleDays == 8)
        #expect(recap.summary.observedDays == 5)
        #expect(recap.summary.unobservedDays == 3)
        #expect(recap.summary.coverage == 0.625)
        #expect(recap.summary.coverageState == .partial)
        #expect(recap.days.map(\.date) == [
            "2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26", "2026-11-27"
        ].map(RecapTestFixture.date))
        #expect(recap.days.allSatisfy { $0.date >= RecapTestFixture.date("2026-11-23") })

        await model.showPreviousMonth()
        #expect(model.selectedMonth == 10)
        #expect(model.canGoToNextMonth)

        let october = try #require(model.monthlyRecap)
        #expect(october.days.isEmpty)
        #expect(october.summary.eligibleDays == 0)
        #expect(october.summary.observedDays == 0)
        #expect(october.summary.coverage == nil)
        #expect(october.summary.coverageState == .noObservation)
        #expect(model.monthEmptyReason(year: 2026, month: 10).contains("早于本机第一次记录"))

        await model.showNextMonth()
        #expect(model.selectedMonth == 11)
        #expect(model.monthlyRecap?.days.count == 5)
    }

    @Test("market filter changes the as-of date without reading the device time zone")
    func marketFilterAndMarketLocalAsOf() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-30",
            imageID: "zh-install"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence(
                "2026-12-01",
                market: .jaJP,
                imageID: "jp-next-day"
            )
        ])

        // 23:30 UTC is still 2026-11-30 in Los Angeles but already 2026-12-01
        // in Shanghai and Tokyo.
        let now = RecapTestFixture.utcInstant(
            year: 2026,
            month: 11,
            day: 30,
            hour: 23,
            minute: 30
        )
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        #expect(model.asOf == RecapTestFixture.date("2026-12-01"))
        #expect(model.selectedMonth == 12)
        #expect(model.marketOptions.contains(.zhCN))
        #expect(model.marketOptions.contains(.enUS))
        #expect(model.marketOptions.contains(.jaJP))

        let allMarkets = try #require(model.monthlyRecap)
        #expect(allMarkets.summary.eligibleDays == 1)
        #expect(allMarkets.summary.observedDays == 1)
        #expect(allMarkets.summary.coverageState == .complete)
        #expect(allMarkets.summary.marketDayCounts == [.jaJP: 1])
        #expect(allMarkets.days.count == 1)

        await model.selectMarket(.enUS)
        #expect(model.asOf == RecapTestFixture.date("2026-11-30"))
        // Switching to a market that is still in the previous month clamps the
        // future selection instead of describing December as unobserved.
        #expect(model.selectedMonth == 11)
        #expect(model.isSelectedMonthInFuture == false)

        let usOnly = try #require(model.monthlyRecap)
        #expect(usOnly.days.isEmpty)
        #expect(usOnly.summary.eligibleDays == 1)
        #expect(usOnly.summary.observedDays == 0)
        #expect(usOnly.summary.coverage == 0.0)
        #expect(usOnly.summary.coverageState == .noObservation)
        #expect(!model.monthEmptyReason(year: 2026, month: 11).contains("还没有发生"))

        await model.selectMarket(nil)
        #expect(model.asOf == RecapTestFixture.date("2026-12-01"))
        #expect(model.selectedMonth == 11)
        #expect(model.monthlyRecap?.summary.observedDays == 1)
        #expect(model.marketFilter == nil)
        #expect(model.canGoToNextMonth)

        await model.showNextMonth()
        #expect(model.selectedMonth == 12)
        #expect(model.monthlyRecap?.summary.marketDayCounts == [.jaJP: 1])
    }

    @Test("expanded markets bound recap dates from observed records")
    func expandedMarketAsOfUsesObservedRecords() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence(
                "2026-11-23",
                market: Market("en-US"),
                imageID: "us-same-day"
            )
        ])
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence(
                "2026-11-24",
                market: Market("de-DE"),
                imageID: "de-next-day"
            )
        ])

        // 23:30 UTC is already 2026-11-24 in Berlin but still 2026-11-23 in
        // Los Angeles. The unfiltered bound follows the observed markets, not
        // every catalog zone.
        let now = RecapTestFixture.utcInstant(
            year: 2026,
            month: 11,
            day: 23,
            hour: 23,
            minute: 30
        )
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        #expect(model.marketOptions.contains(Market("de-DE")))
        #expect(model.marketOptions.contains(Market("fr-CA")))
        #expect(model.asOf == RecapTestFixture.date("2026-11-24"))
        #expect(model.selectedMonth == 11)

        let allMarkets = try #require(model.monthlyRecap)
        #expect(allMarkets.days.map(\.date) == [
            RecapTestFixture.date("2026-11-23"),
            RecapTestFixture.date("2026-11-24")
        ])

        await model.selectMarket(Market("en-US"))
        #expect(model.marketFilter == Market("en-US"))
        #expect(model.asOf == RecapTestFixture.date("2026-11-23"))

        await model.selectMarket(Market("de-DE"))
        #expect(model.asOf == RecapTestFixture.date("2026-11-24"))

        await model.selectMarket(nil)
        #expect(model.asOf == RecapTestFixture.date("2026-11-24"))
    }

    @Test("market switch clamps a future selection across a year boundary")
    func marketSwitchClampsAcrossYearBoundary() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-12-30",
            imageID: "zh-install"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence(
                "2026-12-31",
                market: .enUS,
                imageID: "us-year-end"
            ),
            RecapTestFixture.occurrence(
                "2027-01-01",
                market: .jaJP,
                imageID: "jp-new-year"
            )
        ])

        // 00:30 UTC is already 2027-01-01 in Shanghai/Tokyo but still
        // 2026-12-31 in Los Angeles.
        let now = RecapTestFixture.utcInstant(
            year: 2027,
            month: 1,
            day: 1,
            hour: 0,
            minute: 30
        )
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        #expect(model.asOf == RecapTestFixture.date("2027-01-01"))
        #expect(model.selectedYear == 2027)
        #expect(model.selectedMonth == 1)
        #expect(model.yearlyRecap?.months.first?.month == 1)

        await model.selectMarket(.enUS)
        #expect(model.asOf == RecapTestFixture.date("2026-12-31"))
        #expect(model.selectedYear == 2026)
        #expect(model.selectedMonth == 12)
        #expect(model.isSelectedYearInFuture == false)
        #expect(model.isSelectedMonthInFuture == false)
        #expect(model.canGoToNextYear == false)

        let usYear = try #require(model.yearlyRecap)
        #expect(usYear.months.count == 1)
        #expect(usYear.months.first?.month == 12)
        #expect(usYear.summary.eligibleDays == 2)
        #expect(usYear.summary.observedDays == 1)
        #expect(usYear.summary.coverage == 0.5)
        #expect(usYear.summary.coverageState == .partial)

        let usMonth = try #require(model.monthlyRecap)
        #expect(usMonth.days.count == 1)
        #expect(usMonth.days.first?.date == RecapTestFixture.date("2026-12-31"))
        #expect(usMonth.summary.eligibleDays == 2)
        #expect(usMonth.summary.observedDays == 1)
        #expect(usMonth.summary.coverage == 0.5)
        #expect(usMonth.summary.coverageState == .partial)
        #expect(usMonth.summary.marketDayCounts == [.enUS: 1])

        // The clamp moved the selection back to 2026, so 2027 is a future
        // window and must be described as such, never as "no records".
        #expect(model.monthEmptyReason(year: 2027, month: 1).contains("还没有发生"))
        #expect(model.yearEmptyReason(year: 2027).contains("还没有发生"))

        await model.selectMarket(nil)
        #expect(model.asOf == RecapTestFixture.date("2027-01-01"))
        // A past selection is preserved rather than snapped forward.
        #expect(model.selectedYear == 2026)
        #expect(model.selectedMonth == 12)
        #expect(model.yearlyRecap?.summary.observedDays == 2)
        #expect(model.monthlyRecap?.summary.observedDays == 2)

        await model.showNextYear()
        #expect(model.selectedYear == 2027)
        #expect(model.yearlyRecap?.summary.observedDays == 1)
        #expect(model.yearlyRecap?.months.first?.month == 1)
    }

    // MARK: Yearly

    @Test("yearly recap lists only observed months and pre-install years stay empty")
    func yearlyRecapAndMonthNavigation() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "install"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence("2026-11-24", imageID: "b"),
            RecapTestFixture.occurrence("2026-11-25", imageID: "c"),
            RecapTestFixture.occurrence("2026-11-26", imageID: "d"),
            RecapTestFixture.occurrence("2026-11-27", imageID: "e")
        ])

        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        let recap = try #require(model.yearlyRecap)
        #expect(recap.summary.eligibleDays == 8)
        #expect(recap.summary.observedDays == 5)
        #expect(recap.summary.hasComparableObservations)
        #expect(recap.months.count == 1)

        let november = try #require(recap.months.first)
        #expect(november.year == 2026)
        #expect(november.month == 11)
        #expect(november.observedDays == 5)
        #expect(november.occurrenceCount == 5)
        #expect(model.eligibleDays(year: 2026, month: 11) == 8)
        #expect(model.monthCoverage(november) == 0.625)

        #expect(model.canGoToNextYear == false)
        await model.showPreviousYear()
        #expect(model.selectedYear == 2025)
        #expect(model.canGoToNextYear)

        let emptyYear = try #require(model.yearlyRecap)
        #expect(emptyYear.months.isEmpty)
        #expect(emptyYear.summary.eligibleDays == 0)
        #expect(emptyYear.summary.observedDays == 0)
        #expect(emptyYear.summary.coverageState == .noObservation)
        #expect(model.yearEmptyReason(year: 2025).contains("早于本机第一次记录"))

        await model.openMonth(year: 2026, month: 11)
        #expect(model.section == .monthly)
        #expect(model.selectedYear == 2026)
        #expect(model.selectedMonth == 11)
        #expect(model.monthlyRecap?.days.count == 5)
    }

    // MARK: Favorites

    @Test("favorites deduplicate images and removal requires confirmation")
    func favoritesAndRemovalConfirmation() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageA = RecapTestFixture.image("A")
        let undated = RecapTestFixture.image("Z")

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "A"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence("2026-11-24", market: .enUS, imageID: "A"),
            RecapTestFixture.occurrence("2026-11-25", imageID: "B")
        ])
        _ = try await repository.setFavorite(imageA, isFavorite: true)
        _ = try await repository.setFavorite(undated, isFavorite: true)

        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        let recap = try #require(model.favoriteRecap)
        #expect(recap.favoriteImageCount == 2)
        #expect(recap.datedFavoriteImageCount == 1)
        #expect(recap.undatedFavoriteImageCount == 1)
        #expect(recap.totalOccurrences == 2)
        #expect(recap.distinctObservedDays == 2)
        #expect(recap.months.count == 1)
        #expect(recap.months.first?.imageIDs == [imageA])
        #expect(recap.entries.count == 2)
        #expect(recap.entries.first?.wallpaperID == imageA)
        #expect(recap.entries.last?.wallpaperID == undated)

        let entry = try #require(model.favoriteEntry(for: imageA))
        #expect(entry.occurrences.count == 2)
        #expect(entry.markets == [.enUS, .zhCN])
        #expect(model.favoriteEntry(for: undated)?.isDated == false)
        #expect(model.favoriteEntry(for: undated)?.firstObservedDate == nil)

        model.requestRemoveFavorite(imageA)
        #expect(model.pendingCleanup == .removeFavorite(imageA))
        model.cancelPendingCleanup()
        #expect(model.pendingCleanup == nil)
        #expect(model.isFavorite(imageA))

        model.requestRemoveFavorite(imageA)
        let confirmedAction = try #require(model.pendingCleanup)
        // SwiftUI can dismiss the alert before its async confirmation task runs.
        model.cancelPendingCleanup()
        await model.confirmPendingCleanup(confirmedAction)
        #expect(model.pendingCleanup == nil)
        #expect(model.actionError == nil)
        #expect(model.isFavorite(imageA) == false)
        #expect(model.isFavorite(undated))
        #expect(model.favoriteRecap?.favoriteImageCount == 1)
        #expect(model.favoriteRecap?.undatedFavoriteImageCount == 1)

        let storedSnapshot = await repository.snapshot()
        #expect(storedSnapshot.favoriteWallpaperIDs == Set<WallpaperID>([undated]))
    }

    // MARK: Storage

    @Test("cleanup preserves favorites and confirmed single-file deletion stays honest")
    func storageCleanupPreservesProtectedAssets() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageA = RecapTestFixture.image("A")
        let imageB = RecapTestFixture.image("B")

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "A"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence("2026-11-24", imageID: "B")
        ])
        let assetsToStore: [(AssetKind, WallpaperID)] = [
            (.thumbnail, imageA),
            (.thumbnail, imageB),
            (.original, imageA),
            (.original, imageB)
        ]
        for (kind, imageID) in assetsToStore {
            _ = try await repository.storeAsset(
                Data([1, 2, 3]),
                kind: kind,
                for: imageID,
                fileExtension: "jpg"
            )
        }
        _ = try await repository.setFavorite(imageA, isFavorite: true)

        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let protection = CurrentWallpaperProtectionGate()
        protection.setReconciled(true)
        let model = RecapScreenModel(
            repository: repository,
            currentWallpaperProtection: protection,
            now: { now }
        )
        await model.reload()

        #expect(model.cachedAssets.count == 4)
        #expect(model.storageUsage?.totalAssetBytes == 12)
        #expect(model.thumbnailURL(for: imageA) != nil)
        #expect(model.thumbnailURL(for: imageB) != nil)
        #expect(model.protectionReasons(for: imageA) == Set<PinReason>([.favorite]))
        #expect(model.protectionReasons(for: imageB).isEmpty)

        model.requestCleanup(.removeAsset(kind: .thumbnail, wallpaperID: imageA))
        #expect(model.pendingCleanup == nil)
        #expect(model.actionError != nil)
        let protectedThumbnail = await repository.asset(kind: .thumbnail, for: imageA)
        #expect(protectedThumbnail != nil)

        model.dismissActionFeedback()
        model.requestCleanup(.removeAsset(kind: .original, wallpaperID: imageB))
        #expect(model.pendingCleanup == .removeAsset(kind: .original, wallpaperID: imageB))
        await model.confirmPendingCleanup()

        let removedOriginal = await repository.asset(kind: .original, for: imageB)
        let keptOriginal = await repository.asset(kind: .original, for: imageA)
        #expect(model.actionError == nil)
        #expect(removedOriginal == nil)
        #expect(keptOriginal != nil)

        model.requestCleanup(.clearUnprotectedThumbnails)
        await model.confirmPendingCleanup()

        let keptThumbnail = await repository.asset(kind: .thumbnail, for: imageA)
        let evictedThumbnail = await repository.asset(kind: .thumbnail, for: imageB)
        let originalAfterCleanup = await repository.asset(kind: .original, for: imageA)
        #expect(model.actionError == nil)
        #expect(keptThumbnail != nil)
        #expect(evictedThumbnail == nil)
        #expect(originalAfterCleanup != nil)
        #expect(model.storageUsage?.assetCount == 2)

        _ = try await repository.upsertStories([
            RecapTestFixture.availableStory("2026-11-23", imageID: "A")
        ])
        await model.reload()

        let day = try #require(model.monthlyRecap?.days.first)
        let occurrence = try #require(day.occurrences.first)
        guard case .available(let story) = model.storyPresentation(for: occurrence) else {
            Issue.record("Expected the strict matcher to attach the synthetic story")
            return
        }
        #expect(story.body == "Synthetic story body.")

        model.requestCleanup(.clearStories)
        await model.confirmPendingCleanup()

        #expect(model.actionError == nil)
        let remainingStories = await repository.stories()
        let protectedOriginalAfterStoryClear = await repository.asset(
            kind: .original,
            for: imageA
        )
        #expect(remainingStories.isEmpty)
        #expect(model.isFavorite(imageA))
        #expect(protectedOriginalAfterStoryClear != nil)

        let afterClear = try #require(model.monthlyRecap?.days.first?.occurrences.first)
        #expect(model.storyPresentation(for: afterClear) == .notFetched)

        model.requestCleanup(.removeAsset(kind: .original, wallpaperID: imageA))
        #expect(model.pendingCleanup == nil)
        #expect(model.actionError != nil)

        model.dismissActionFeedback()
        model.requestCleanup(.repairIndex)
        await model.confirmPendingCleanup()
        #expect(model.actionError == nil)
        #expect(model.actionMessage != nil)
    }

    @Test("explicit original cleanup waits for reconciled current-wallpaper protection")
    func originalCleanupRequiresReconciledProtection() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageA = RecapTestFixture.image("A")
        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "A"
        )
        _ = try await repository.storeAsset(
            Data([1, 2, 3]),
            kind: .original,
            for: imageA,
            fileExtension: "jpg"
        )

        let protection = CurrentWallpaperProtectionGate()
        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(
            repository: repository,
            currentWallpaperProtection: protection,
            now: { now }
        )
        await model.reload()

        model.requestCleanup(.clearUnprotectedOriginals)
        #expect(model.pendingCleanup == nil)
        #expect(
            model.actionError
                == RecapScreenError.appliedProtectionUnavailable.localizedDescription
        )

        // A confirmation that outlived its protection window is refused too.
        await model.confirmPendingCleanup(.clearUnprotectedOriginals)
        let stillCached = await repository.asset(kind: .original, for: imageA)
        #expect(stillCached != nil)
        #expect(model.actionError != nil)

        model.dismissActionFeedback()
        model.requestCleanup(.removeAsset(kind: .original, wallpaperID: imageA))
        #expect(model.pendingCleanup == nil)
        let stillCachedAfterSingle = await repository.asset(kind: .original, for: imageA)
        #expect(stillCachedAfterSingle != nil)

        // A trustworthy reconciliation reopens cleanup.
        protection.setReconciled(true)
        model.dismissActionFeedback()
        model.requestCleanup(.clearUnprotectedOriginals)
        #expect(model.pendingCleanup == .clearUnprotectedOriginals)
        await model.confirmPendingCleanup()
        let removed = await repository.asset(kind: .original, for: imageA)
        #expect(model.actionError == nil)
        #expect(removed == nil)
    }

    @Test("default limits skip originals only while current wallpaper is unknown")
    func defaultLimitsSkipOriginalsUntilReconciled() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageA = RecapTestFixture.image("A")
        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "A"
        )
        _ = try await repository.storeAsset(
            Data([1, 2, 3]),
            kind: .original,
            for: imageA,
            fileExtension: "jpg"
        )

        let protection = CurrentWallpaperProtectionGate()
        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(
            repository: repository,
            currentWallpaperProtection: protection,
            now: { now }
        )
        await model.reload()

        model.requestCleanup(.applyDefaultLimits)
        #expect(model.pendingCleanup == .applyDefaultLimits)
        await model.confirmPendingCleanup()
        let skippedMessage = try #require(model.actionMessage)
        #expect(skippedMessage.contains("已跳过原图清理"))
        let kept = await repository.asset(kind: .original, for: imageA)
        #expect(kept != nil)

        protection.setReconciled(true)
        model.dismissActionFeedback()
        model.requestCleanup(.applyDefaultLimits)
        await model.confirmPendingCleanup()
        #expect(model.actionMessage?.contains("已跳过原图清理") == false)
    }

    // MARK: Story strictness

    @Test("story text appears only for strict available matches")
    func storyPresentationNeverInventsContent() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await RecapTestFixture.seedInstallDay(
            repository,
            date: "2026-11-23",
            imageID: "A"
        )
        _ = try await repository.upsertOccurrences([
            RecapTestFixture.occurrence("2026-11-24", imageID: "B"),
            RecapTestFixture.occurrence("2026-11-25", imageID: "C")
        ])
        _ = try await repository.upsertStories([
            RecapTestFixture.availableStory("2026-11-23", imageID: "A"),
            RecapTestFixture.availableStory("2026-11-24", imageID: "other-image"),
            RecapTestFixture.unavailableStory("2026-11-25", imageID: "C")
        ])

        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        let recap = try #require(model.monthlyRecap)
        let day23 = try #require(recap.days.first { $0.date == RecapTestFixture.date("2026-11-23") })
        let day24 = try #require(recap.days.first { $0.date == RecapTestFixture.date("2026-11-24") })
        let day25 = try #require(recap.days.first { $0.date == RecapTestFixture.date("2026-11-25") })

        let availableOccurrence = try #require(day23.occurrences.first)
        guard case .available(let storyText) = model.storyPresentation(for: availableOccurrence) else {
            Issue.record("Expected an available matched story")
            return
        }
        #expect(storyText.headline == "Synthetic headline")
        #expect(storyText.body == "Synthetic story body.")
        #expect(storyText.copyright == "Synthetic copyright")
        #expect(day23.hasAvailableStory)

        let mismatchedOccurrence = try #require(day24.occurrences.first)
        #expect(
            model.storyPresentation(for: mismatchedOccurrence)
                == .unmatched(hasCandidates: true)
        )
        #expect(day24.hasAvailableStory == false)

        let unavailableOccurrence = try #require(day25.occurrences.first)
        guard case .unavailable(let reason, let headline, _, _) =
                model.storyPresentation(for: unavailableOccurrence)
        else {
            Issue.record("Expected an unavailable story presentation")
            return
        }
        #expect(reason == .notProvidedBySource)
        #expect(headline == "Synthetic source headline")
        #expect(day25.hasAvailableStory == false)

        #expect(recap.summary.storyCoveredDays == 1)
    }

    // MARK: Empty repository

    @Test("an empty repository reports unknown observation start without invented days")
    func emptyRepositoryStaysHonest() async throws {
        let (repository, directory) = try RecapTestFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = RecapTestFixture.noonUTC(year: 2026, month: 11, day: 30)
        let model = RecapScreenModel(repository: repository, now: { now })
        await model.reload()

        #expect(model.loadError == nil)
        #expect(model.snapshot?.firstObservedDate == nil)
        #expect(model.cachedAssets.isEmpty)
        #expect(model.storageUsage?.assetCount == 0)
        #expect(model.favoriteRecap?.favoriteImageCount == 0)

        let monthly = try #require(model.monthlyRecap)
        #expect(monthly.days.isEmpty)
        #expect(monthly.summary.eligibleDays == nil)
        #expect(monthly.summary.unobservedDays == nil)
        #expect(monthly.summary.observedDays == 0)
        #expect(monthly.summary.coverage == nil)
        #expect(monthly.summary.coverageState == .firstObservedDateUnknown)
        #expect(model.monthEmptyReason(year: 2026, month: 11).contains("还没有确认第一次记录是哪天"))

        let yearly = try #require(model.yearlyRecap)
        #expect(yearly.months.isEmpty)
        #expect(yearly.summary.coverageState == .firstObservedDateUnknown)
        #expect(model.yearEmptyReason(year: 2025).contains("还没有确认第一次记录是哪天"))
    }
}
