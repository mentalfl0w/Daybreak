import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

// MARK: - Fixtures

private func timelineDate(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
    LocalDate(year: year, month: month, day: day)!
}

private func timelineKey(_ market: Market, _ date: LocalDate) -> OccurrenceKey {
    OccurrenceKey(source: .bing, market: market, localDate: date)
}

private func timelineSnapshot(
    assets: [CachedImageAsset] = [],
    favorites: Set<WallpaperID> = [],
    includeNovember24: Bool = true
) -> RepositorySnapshot {
    let imageA = WallpaperID(source: .bing, sourceImageID: "A")
    let imageB = WallpaperID(source: .bing, sourceImageID: "B")
    let imageC = WallpaperID(source: .bing, sourceImageID: "C")
    var occurrences: [WallpaperOccurrence] = [
        WallpaperOccurrence(
            source: .bing,
            market: .zhCN,
            localDate: timelineDate(2026, 11, 25),
            wallpaperID: imageB
        ),
        WallpaperOccurrence(
            source: .bing,
            market: .enUS,
            localDate: timelineDate(2026, 11, 25),
            wallpaperID: imageC
        ),
        WallpaperOccurrence(
            source: .bing,
            market: .jaJP,
            localDate: timelineDate(2026, 11, 25),
            wallpaperID: imageA
        ),
        WallpaperOccurrence(
            source: .bing,
            market: .zhCN,
            localDate: timelineDate(2026, 10, 3),
            wallpaperID: imageC
        ),
        WallpaperOccurrence(
            source: .bing,
            market: .zhCN,
            localDate: timelineDate(2026, 12, 1),
            wallpaperID: imageA
        )
    ]
    if includeNovember24 {
        occurrences.append(
            WallpaperOccurrence(
                source: .bing,
                market: .zhCN,
                localDate: timelineDate(2026, 11, 24),
                wallpaperID: imageA,
                revision: 1
            )
        )
    }
    let metadata = [
        WallpaperMetadataRecord(
            key: timelineKey(.zhCN, timelineDate(2026, 11, 25)),
            wallpaperID: imageB,
            title: "ZH B",
            copyright: "© B",
            originalLocale: "zh-Hans",
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        ),
        WallpaperMetadataRecord(
            key: timelineKey(.enUS, timelineDate(2026, 11, 25)),
            wallpaperID: imageC,
            title: "EN C",
            originalLocale: "en-US",
            fetchedAt: Date(timeIntervalSince1970: 1_001)
        )
    ]
    let wrongImageStory = DailyStoryRecord(
        id: "en-wrong-image",
        source: .bing,
        market: .enUS,
        date: timelineDate(2026, 11, 25),
        associatedWallpaperID: imageA,
        headline: "EN headline",
        body: "EN body",
        originalLocale: "en-US",
        fetchedAt: Date(timeIntervalSince1970: 2_000),
        availability: .available
    )!
    return RepositorySnapshot(
        occurrences: occurrences,
        metadata: metadata,
        wallpapers: [
            WallpaperRecord(
                source: .bing,
                wallpaperID: imageA,
                canonicalTitle: "A",
                fetchedAt: Date(timeIntervalSince1970: 10)
            ),
            WallpaperRecord(
                source: .bing,
                wallpaperID: imageB,
                canonicalTitle: "B",
                fetchedAt: Date(timeIntervalSince1970: 11)
            )
        ],
        stories: [wrongImageStory],
        assets: assets,
        favoriteWallpaperIDs: favorites,
        firstObservedDate: timelineDate(2026, 10, 1),
        observationStartedAt: Date(timeIntervalSince1970: 20)
    )
}

private func timelineNow() -> Date {
    ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
}

// MARK: - Calendar and builders

@Suite("Timeline calendar and archive builders")
struct TimelineBuilderTests {
    @Test("Monday-first and Sunday-first grids use the same source dates")
    func calendarLeadingBlanks() throws {
        let snapshot = timelineSnapshot()
        let asOf = timelineDate(2026, 11, 25)
        let month = try TimelineBuilder.month(
            year: 2026,
            month: 11,
            market: .zhCN,
            asOf: asOf,
            snapshot: snapshot
        )
        #expect(TimelineCalendarMath.sundayBasedWeekday(for: timelineDate(2026, 11, 1)) == 0)
        #expect(TimelineCalendarMath.leadingBlankCount(for: month, firstWeekday: 1) == 0)
        #expect(TimelineCalendarMath.leadingBlankCount(for: month, firstWeekday: 2) == 6)
        #expect(month.days.count == 30)
        #expect(month.days.last?.state == .future)
    }

    @Test("Future occurrences never appear in gallery or year statistics")
    func futureContentExcluded() throws {
        let snapshot = timelineSnapshot()
        let asOf = timelineDate(2026, 11, 25)
        let all = TimelineGalleryBuilder.items(
            snapshot: snapshot,
            market: .zhCN,
            asOf: asOf,
            scope: .all
        )
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.date <= asOf })

        let year = TimelineYearBuilder.summaries(
            year: 2026,
            markets: [.zhCN],
            snapshot: snapshot,
            asOf: asOf
        )
        #expect(year[10].observedDays == 2)
        #expect(year[9].observedDays == 1)
        #expect(year[11].observedDays == 0)
    }

    @Test("Market choices require a locally available picture")
    func marketChoicesUseCachedImages() {
        let zhImage = WallpaperID(source: .bing, sourceImageID: "cached-thumbnail")
        let enImage = WallpaperID(source: .bing, sourceImageID: "cached-original")
        let jaImage = WallpaperID(source: .bing, sourceImageID: "missing-file")
        let unsupportedImage = WallpaperID(source: .bing, sourceImageID: "unsupported")
        let date = timelineDate(2026, 11, 25)

        let missingThumbnail = CachedImageAsset(
            wallpaperID: jaImage,
            kind: .thumbnail,
            relativePath: "missing-thumbnail.jpg",
            byteCount: 100,
            lastAccessedAt: Date(timeIntervalSince1970: 1)
        )
        let snapshot = RepositorySnapshot(
            occurrences: [
                WallpaperOccurrence(source: .bing, market: .zhCN, localDate: date, wallpaperID: zhImage),
                WallpaperOccurrence(source: .bing, market: .zhCN, localDate: date, wallpaperID: zhImage, revision: 1),
                WallpaperOccurrence(source: .bing, market: .enUS, localDate: date, wallpaperID: enImage),
                WallpaperOccurrence(source: .bing, market: .jaJP, localDate: date, wallpaperID: jaImage),
                WallpaperOccurrence(source: .bing, market: Market("xx-XX"), localDate: date, wallpaperID: unsupportedImage)
            ],
            assets: [
                CachedImageAsset(
                    wallpaperID: zhImage,
                    kind: .thumbnail,
                    relativePath: "cached-thumbnail.jpg",
                    byteCount: 100,
                    lastAccessedAt: Date(timeIntervalSince1970: 1)
                ),
                CachedImageAsset(
                    wallpaperID: enImage,
                    kind: .original,
                    relativePath: "cached-original.jpg",
                    byteCount: 100,
                    lastAccessedAt: Date(timeIntervalSince1970: 1)
                ),
                missingThumbnail,
                CachedImageAsset(
                    wallpaperID: unsupportedImage,
                    kind: .thumbnail,
                    relativePath: "unsupported.jpg",
                    byteCount: 100,
                    lastAccessedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            missingAssets: [missingThumbnail]
        )

        #expect(TimelineMarketBuilder.availableMarkets(snapshot: snapshot) == [.zhCN, .enUS])
    }

    @Test("Favorites are image-level and keep the newest cross-market occurrence")
    func favoriteGalleryDeduplicatesImages() throws {
        let imageA = WallpaperID(source: .bing, sourceImageID: "A")
        let imageC = WallpaperID(source: .bing, sourceImageID: "C")
        let undated = WallpaperID(source: .bing, sourceImageID: "UNDATED")
        let snapshot = timelineSnapshot(favorites: [imageA, imageC, undated])
        let asOf = timelineDate(2026, 11, 25)

        let favorites = TimelineGalleryBuilder.items(
            snapshot: snapshot,
            market: .zhCN,
            asOf: asOf,
            scope: .favorites
        )
        #expect(favorites.count == 2)
        #expect(favorites.contains { $0.wallpaperID == imageA && $0.date == asOf })
        #expect(favorites.contains { $0.wallpaperID == imageC && $0.market == .enUS })
        #expect(TimelineGalleryBuilder.undatedFavoriteCount(snapshot: snapshot, asOf: asOf) == 1)
    }

    @Test("Detail keeps every market separate and never borrows a wrong-image story")
    func detailMultiMarketAndStrictStory() throws {
        let snapshot = timelineSnapshot()
        let asOf = timelineDate(2026, 11, 25)

        let zh = TimelineDetailBuilder.detail(
            target: .day(asOf),
            selectedMarket: .zhCN,
            snapshot: snapshot,
            asOf: asOf
        )
        #expect(zh.title == "ZH B")
        #expect(zh.otherMarkets.map(\.market) == [.enUS, .jaJP])
        #expect(zh.storyStatus.record == nil)

        let en = TimelineDetailBuilder.detail(
            target: .day(asOf),
            selectedMarket: .enUS,
            snapshot: snapshot,
            asOf: asOf
        )
        #expect(en.title == "EN C")
        #expect(en.storyStatus.record == nil)
        #expect(!en.storyStatus.isAvailable)

        let missing = TimelineDetailBuilder.detail(
            target: .day(timelineDate(2026, 11, 20)),
            selectedMarket: .zhCN,
            snapshot: snapshot,
            asOf: asOf
        )
        #expect(missing.day.state == .notRecorded)

        let before = TimelineDetailBuilder.detail(
            target: .day(timelineDate(2026, 8, 1)),
            selectedMarket: .zhCN,
            snapshot: snapshot,
            asOf: asOf
        )
        #expect(before.day.state == .beforeObservationStart)
    }

    @Test("Monthly recap uses only the requested market and caps eligible days at asOf")
    func monthlyRecapMarketAndCoverage() throws {
        let snapshot = timelineSnapshot()
        let asOf = timelineDate(2026, 11, 25)
        let month = try TimelineBuilder.month(
            year: 2026,
            month: 11,
            market: .zhCN,
            asOf: asOf,
            snapshot: snapshot
        )
        let recap = try #require(
            TimelineRecapBuilder.month(
                monthKey: TimelineMonthKey(year: 2026, month: 11),
                month: month,
                snapshot: snapshot,
                asOf: asOf,
                markets: [.zhCN]
            )
        )
        #expect(recap.recap.summary.observedDays == 2)
        #expect(recap.recap.summary.totalOccurrences == 2)
        #expect(recap.recap.summary.eligibleDays == 25)
        #expect(recap.recap.summary.favoriteImageCount == 0)
    }

    @Test("Gallery retains dated history while a monthly recap uses its eligible observation window")
    func galleryAndMonthlyRecapUseDifferentObservationWindows() throws {
        let beforeObservation = timelineDate(2026, 10, 31)
        let firstObserved = timelineDate(2026, 11, 24)
        let asOf = timelineDate(2026, 11, 25)
        let future = timelineDate(2026, 11, 26)
        let snapshot = RepositorySnapshot(
            occurrences: [
                WallpaperOccurrence(
                    source: .bing,
                    market: .zhCN,
                    localDate: beforeObservation,
                    wallpaperID: WallpaperID(source: .bing, sourceImageID: "before-observation")
                ),
                WallpaperOccurrence(
                    source: .bing,
                    market: .zhCN,
                    localDate: firstObserved,
                    wallpaperID: WallpaperID(source: .bing, sourceImageID: "first-observed")
                ),
                WallpaperOccurrence(
                    source: .bing,
                    market: .zhCN,
                    localDate: asOf,
                    wallpaperID: WallpaperID(source: .bing, sourceImageID: "as-of")
                ),
                WallpaperOccurrence(
                    source: .bing,
                    market: .zhCN,
                    localDate: future,
                    wallpaperID: WallpaperID(source: .bing, sourceImageID: "future")
                )
            ],
            firstObservedDate: firstObserved
        )

        let gallery = TimelineGalleryBuilder.items(
            snapshot: snapshot,
            market: .zhCN,
            asOf: asOf,
            scope: .all
        )
        #expect(gallery.map(\.date) == [asOf, firstObserved, beforeObservation])

        let month = try TimelineBuilder.month(
            year: 2026,
            month: 11,
            market: .zhCN,
            asOf: asOf,
            snapshot: snapshot
        )
        let recap = try #require(
            TimelineRecapBuilder.month(
                monthKey: TimelineMonthKey(year: 2026, month: 11),
                month: month,
                snapshot: snapshot,
                asOf: asOf,
                markets: [.zhCN]
            )
        )
        #expect(recap.recap.days.map(\.date) == [firstObserved, asOf])
        #expect(recap.recap.summary.effectiveRange?.start == firstObserved)
        #expect(recap.recap.summary.effectiveRange?.end == asOf)
        #expect(recap.recap.summary.eligibleDays == 2)
    }

    @Test("Favorites recap separates dated and undated favorites")
    func favoritesRecap() {
        let imageA = WallpaperID(source: .bing, sourceImageID: "A")
        let undated = WallpaperID(source: .bing, sourceImageID: "UNDATED")
        let snapshot = timelineSnapshot(favorites: [imageA, undated])
        let recap = TimelineRecapBuilder.favorites(
            snapshot: snapshot,
            asOf: timelineDate(2026, 11, 25)
        )
        #expect(recap.recap.favoriteImageCount == 2)
        #expect(recap.recap.datedFavoriteImageCount == 1)
        #expect(recap.recap.undatedFavoriteImageCount == 1)
        #expect(recap.undatedFavoriteCount == 1)
    }
}

@Suite("Timeline responsive presentation")
struct TimelinePresentationTests {
    @Test("Split layout requires both a wide and sufficiently tall window")
    func splitLayoutThresholds() {
        #expect(!TimelineLayout.isWide(CGSize(width: 759, height: 900)))
        #expect(!TimelineLayout.isWide(CGSize(width: 844, height: 390)))
        #expect(!TimelineLayout.isWide(CGSize(width: 1024, height: 499)))
        #expect(TimelineLayout.isWide(CGSize(width: 760, height: 500)))
        #expect(TimelineLayout.isWide(CGSize(width: 1024, height: 768)))
    }

    @Test("Split layout keeps the calendar readable without squeezing the detail column")
    func splitColumnWidthsPreserveMinimums() {
        for totalWidth: CGFloat in [760, 834, 1024, 1366] {
            let listWidth = TimelineLayout.listColumnWidth(for: totalWidth)
            #expect(listWidth >= 360)
            #expect(listWidth <= 560)
            #expect(totalWidth - listWidth >= 380)
        }
    }

    @Test("Month header and short date formatting preserve a source-local calendar date")
    func sourceLocalMonthAndDateFormatting() {
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = timelineDate(2026, 11, 25)

        #expect(
            TimelinePresentation.monthTitle(
                TimelineMonthKey(year: date.year, month: date.month),
                locale: locale,
                timeZone: timeZone
            ) == "November 2026"
        )
        #expect(
            TimelinePresentation.shortDate(date, locale: locale, timeZone: timeZone)
                == "11/25/2026"
        )
    }
}


// MARK: - Model

@MainActor
private final class TimelineFakeStore: TimelineDataStore {
    var selectedMarket: Market = .zhCN
    var dataRevision = 0
    var snapshot: RepositorySnapshot
    var failEnsure = false
    private(set) var ensureCalls: [AssetKind] = []

    init(snapshot: RepositorySnapshot) {
        self.snapshot = snapshot
    }

    func setSelectedMarket(_ market: Market) async {
        selectedMarket = market
        dataRevision += 1
    }

    func timelineSnapshot() async throws -> RepositorySnapshot {
        snapshot
    }

    func timelineAssetURL(kind: AssetKind, wallpaperID: WallpaperID) async -> URL? {
        guard let asset = snapshot.asset(kind: kind, for: wallpaperID) else { return nil }
        return URL(fileURLWithPath: "/tmp/timeline-tests/\(asset.relativePath)")
    }

    func timelineEnsureAsset(
        kind: AssetKind,
        for occurrence: WallpaperOccurrence,
        allowNetwork: Bool
    ) async throws -> URL {
        ensureCalls.append(kind)
        if failEnsure { throw CocoaError(.fileNoSuchFile) }
        let url = URL(fileURLWithPath: "/tmp/timeline-tests/\(kind.rawValue)-\(occurrence.wallpaperID.sourceImageID).jpg")
        let asset = CachedImageAsset(
            wallpaperID: occurrence.wallpaperID,
            kind: kind,
            relativePath: url.lastPathComponent,
            byteCount: 100,
            lastAccessedAt: Date()
        )
        replaceSnapshot(assets: snapshot.assets.filter { $0.id != asset.id } + [asset])
        dataRevision += 1
        return url
    }

    func recordCurrentSelection(_ key: OccurrenceKey?) async {}

    func timelineSetFavorite(_ wallpaperID: WallpaperID, isFavorite: Bool) async throws {
        var favorites = snapshot.favoriteWallpaperIDs
        if isFavorite {
            favorites.insert(wallpaperID)
        } else {
            favorites.remove(wallpaperID)
        }
        replaceSnapshot(favorites: favorites)
        dataRevision += 1
    }

    private func replaceSnapshot(
        assets: [CachedImageAsset]? = nil,
        favorites: Set<WallpaperID>? = nil
    ) {
        snapshot = RepositorySnapshot(
            occurrences: snapshot.occurrences,
            metadata: snapshot.metadata,
            wallpapers: snapshot.wallpapers,
            stories: snapshot.stories,
            assets: assets ?? snapshot.assets,
            favoriteWallpaperIDs: favorites ?? snapshot.favoriteWallpaperIDs,
            pinnedOccurrences: snapshot.pinnedOccurrences,
            appliedWallpapers: snapshot.appliedWallpapers,
            firstObservedDate: snapshot.firstObservedDate,
            observationStartedAt: snapshot.observationStartedAt
        )
    }
}

@Suite("Timeline model navigation")
@MainActor
struct TimelineModelTests {
    @Test("Initial load selects market-local today and exposes all markets on that date")
    func initialSelection() async throws {
        let store = TimelineFakeStore(snapshot: timelineSnapshot())
        let model = TimelineModel(store: store, now: timelineNow)
        await model.load()

        #expect(model.loadState == .ready)
        #expect(model.market == .zhCN)
        #expect(model.asOf == timelineDate(2026, 11, 25))
        #expect(model.selectedDate == model.asOf)
        #expect(model.detail?.title == "ZH B")
        #expect(model.detail?.otherMarkets.count == 2)
        #expect(model.galleryItems.count == 2)
        #expect(model.yearMonths.count == 12)
        #expect(model.monthRecap?.recap.summary.observedDays == 2)
    }

    @Test("Choosing another market's gallery item keeps the calendar market")
    func galleryItemDoesNotChangeMarket() async throws {
        let imageA = WallpaperID(source: .bing, sourceImageID: "A")
        let store = TimelineFakeStore(snapshot: timelineSnapshot(favorites: [imageA]))
        let model = TimelineModel(store: store, now: timelineNow)
        await model.load()
        model.setGalleryScope(.favorites)

        let item = try #require(model.galleryItems.first)
        #expect(item.market == .jaJP)
        model.selectGalleryItem(item)

        #expect(model.market == .zhCN)
        #expect(model.detail?.market == .jaJP)
        #expect(model.detail?.date == timelineDate(2026, 11, 25))
        #expect(model.selectedDate == timelineDate(2026, 11, 25))
    }

    @Test("Market switch preserves the inspected date and never invents a thumbnail")
    func marketSwitchAndMissingAssets() async throws {
        let store = TimelineFakeStore(snapshot: timelineSnapshot())
        let model = TimelineModel(store: store, now: timelineNow)
        await model.load()

        await model.setMarket(.enUS)
        #expect(store.selectedMarket == .enUS)
        #expect(model.market == .enUS)
        #expect(model.selectedDate == timelineDate(2026, 11, 25))
        #expect(model.detail?.title == "EN C")
        #expect(model.detail?.hasThumbnail == false)
        #expect(model.detail?.hasOriginal == false)
    }

    @Test("Favorite toggle updates detail and recap, and is image-level")
    func favoriteToggle() async throws {
        let imageB = WallpaperID(source: .bing, sourceImageID: "B")
        let store = TimelineFakeStore(snapshot: timelineSnapshot())
        let model = TimelineModel(store: store, now: timelineNow)
        await model.load()

        #expect(!model.isFavorite(imageB))
        await model.toggleFavorite(imageB)
        #expect(model.isFavorite(imageB))
        #expect(model.detail?.isFavorite == true)

        await model.toggleFavorite(imageB)
        #expect(!model.isFavorite(imageB))
    }

    @Test("Moving to another month clears a selection that is no longer visible")
    func monthNavigationClearsSelection() async throws {
        let store = TimelineFakeStore(snapshot: timelineSnapshot())
        let model = TimelineModel(store: store, now: timelineNow)
        await model.load()
        #expect(model.selectedDate != nil)

        model.goToPreviousMonth()
        #expect(model.monthKey == TimelineMonthKey(year: 2026, month: 10))
        #expect(model.selectedDate == nil)
        #expect(model.detail == nil)
        #expect(model.canGoToNextMonth)
    }

    @Test("Offline original download reports failure without creating an asset")
    func offlineOriginalFailure() async throws {
        let store = TimelineFakeStore(snapshot: timelineSnapshot())
        let storeModel = TimelineModel(store: store, now: timelineNow)
        await storeModel.load()
        let detail = try #require(storeModel.detail)

        store.failEnsure = true
        let downloaded = await storeModel.downloadOriginal(for: detail)
        #expect(!downloaded)
        #expect(storeModel.assetError?.kind == .assetUnavailable)
        #expect(store.ensureCalls == [.original])
    }
}
