import DaybreakCore
import Foundation
import Testing
@testable import Daybreak

// MARK: - Synthetic refresh transport

/// Serves a two-day synthetic archive, an empty story feed and a synthetic
/// 1×1 PNG for every image request. No real Bing media or copy is used.
private actor LibraryThumbnailTransport: BingHTTPTransport {
    private let archive: Data
    private let stories: Data
    private let image: Data
    private(set) var imageRequests: [URL] = []

    init(archive: Data, stories: Data, image: Data) {
        self.archive = archive
        self.stories = stories
        self.image = image
    }

    func perform(_ request: BingHTTPRequest) async throws -> BingHTTPResponse {
        let url = request.url
        if url.path.contains("HPImageArchive") {
            return BingHTTPResponse(
                data: archive,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                finalURL: url
            )
        }
        if url.path.contains("hp/api/model") {
            return BingHTTPResponse(
                data: stories,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                finalURL: url
            )
        }
        if url.host == "www.bing.com", url.path == "/th" {
            imageRequests.append(url)
            return BingHTTPResponse(
                data: image,
                statusCode: 200,
                headers: ["Content-Type": "image/png"],
                finalURL: url
            )
        }
        return BingHTTPResponse(
            data: Data(),
            statusCode: 404,
            headers: [:],
            finalURL: url
        )
    }

    func recordedImageRequests() -> [URL] {
        imageRequests
    }
}

/// Synthetic fixtures only. No real Bing media, story text or metadata is used.
@Suite("Library history")
struct LibraryTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    /// 2026-11-24 12:00 UTC, i.e. 20:00 in the zh-CN source time zone.
    private static let refreshNow = Date(timeIntervalSince1970: 1_795_521_600)
    private static let syntheticPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private func date(_ value: String) -> LocalDate {
        LocalDate(iso8601: value)!
    }

    private func image(_ id: String) -> WallpaperID {
        WallpaperID(source: .bing, sourceImageID: id)
    }

    private func occurrence(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: .bing,
            market: market,
            localDate: date(iso8601),
            wallpaperID: image(imageID)
        )
    }

    private func galleryItem(
        _ iso8601: String,
        imageID: String
    ) -> LibraryGalleryItem {
        let occurrence = occurrence(iso8601, imageID: imageID)
        return LibraryGalleryItem(
            occurrence: occurrence,
            title: nil,
            copyright: nil,
            hasThumbnail: false,
            hasOriginal: false,
            isFavorite: false,
            hasStory: false,
            hasUnavailableStory: false
        )
    }

    // MARK: Month and weekday math

    @Test("month keys normalize and step across year boundaries")
    func monthKeyArithmetic() {
        #expect(
            LibraryMonthKey(year: 2026, month: 11).adding(months: 1)
                == LibraryMonthKey(year: 2026, month: 12)
        )
        #expect(
            LibraryMonthKey(year: 2026, month: 12).adding(months: 1)
                == LibraryMonthKey(year: 2027, month: 1)
        )
        #expect(
            LibraryMonthKey(year: 2026, month: 1).adding(months: -1)
                == LibraryMonthKey(year: 2025, month: 12)
        )
        #expect(
            LibraryMonthKey(year: 2026, month: 13)
                == LibraryMonthKey(year: 2027, month: 1)
        )
        #expect(
            LibraryMonthKey(year: 2026, month: 0)
                == LibraryMonthKey(year: 2025, month: 12)
        )
        #expect(
            LibraryMonthKey(containing: date("2024-02-29"))
                == LibraryMonthKey(year: 2024, month: 2)
        )
    }

    @Test("weekday index is Monday-first and stable")
    func weekdayMath() {
        #expect(LibraryCalendarMath.weekdayIndex(for: date("1970-01-01")) == 3)
        #expect(LibraryCalendarMath.weekdayIndex(for: date("2026-11-23")) == 0)
        #expect(LibraryCalendarMath.weekdayIndex(for: date("2026-11-29")) == 6)
    }

    @Test("market choices require a locally available picture")
    func marketChoicesUseCachedImages() {
        let missingThumbnail = CachedImageAsset(
            wallpaperID: image("missing-thumbnail"),
            kind: .thumbnail,
            relativePath: "missing-thumbnail.jpg",
            byteCount: 100,
            lastAccessedAt: Self.fixedNow
        )
        let snapshot = RepositorySnapshot(
            occurrences: [
                occurrence("2026-11-25", market: .zhCN, imageID: "cached-thumbnail"),
                occurrence("2026-11-24", market: .zhCN, imageID: "cached-thumbnail"),
                occurrence("2026-11-25", market: .enUS, imageID: "cached-original"),
                occurrence("2026-11-25", market: .jaJP, imageID: "missing-thumbnail"),
                occurrence("2026-11-25", market: Market("xx-XX"), imageID: "unsupported")
            ],
            assets: [
                CachedImageAsset(
                    wallpaperID: image("cached-thumbnail"),
                    kind: .thumbnail,
                    relativePath: "cached-thumbnail.jpg",
                    byteCount: 100,
                    lastAccessedAt: Self.fixedNow
                ),
                CachedImageAsset(
                    wallpaperID: image("cached-original"),
                    kind: .original,
                    relativePath: "cached-original.jpg",
                    byteCount: 100,
                    lastAccessedAt: Self.fixedNow
                ),
                missingThumbnail,
                CachedImageAsset(
                    wallpaperID: image("unsupported"),
                    kind: .thumbnail,
                    relativePath: "unsupported.jpg",
                    byteCount: 100,
                    lastAccessedAt: Self.fixedNow
                )
            ],
            missingAssets: [missingThumbnail]
        )

        #expect(LibraryMarketBuilder.availableMarkets(snapshot: snapshot) == [.zhCN, .enUS])
    }

    // MARK: Gallery joins

    @Test("gallery filters market, sorts by source date and joins strict stories")
    func galleryStrictAssociations() throws {
        let imageA = image("image-a")
        let imageB = image("image-b")
        let imageC = image("image-c")
        let newest = occurrence("2026-11-23", imageID: "image-a")
        let older = occurrence("2026-11-22", imageID: "image-b")
        let otherMarket = occurrence("2026-11-23", market: .enUS, imageID: "image-c")

        let storyA = try #require(
            DailyStoryRecord(
                id: "story-a",
                source: .bing,
                market: .zhCN,
                date: newest.localDate,
                associatedWallpaperID: imageA,
                headline: "合成导语",
                body: "合成正文",
                originalLocale: "zh-Hans",
                fetchedAt: Self.fixedNow,
                availability: .available
            )
        )
        let storyB = try #require(
            DailyStoryRecord(
                id: "story-b",
                source: .bing,
                market: .zhCN,
                date: older.localDate,
                associatedWallpaperID: imageB,
                copyright: "合成版权",
                originalLocale: "zh-Hans",
                fetchedAt: Self.fixedNow,
                availability: .unavailable(.notProvidedBySource)
            )
        )
        let storyForAnotherImage = try #require(
            DailyStoryRecord(
                id: "story-conflict",
                source: .bing,
                market: .zhCN,
                date: newest.localDate,
                associatedWallpaperID: imageC,
                headline: "不应挂载",
                body: "合成正文",
                originalLocale: "zh-Hans",
                fetchedAt: Self.fixedNow,
                availability: .available
            )
        )

        let snapshot = RepositorySnapshot(
            occurrences: [older, otherMarket, newest],
            metadata: [
                WallpaperMetadataRecord(
                    key: newest.id,
                    wallpaperID: imageA,
                    title: "合成标题",
                    copyright: "合成版权",
                    originalLocale: "zh-Hans",
                    fetchedAt: Self.fixedNow
                )
            ],
            wallpapers: [
                WallpaperRecord(
                    source: .bing,
                    wallpaperID: imageB,
                    canonicalTitle: "合成镜像标题",
                    fetchedAt: Self.fixedNow
                )
            ],
            stories: [storyA, storyB, storyForAnotherImage],
            assets: [
                CachedImageAsset(
                    wallpaperID: imageA,
                    kind: .thumbnail,
                    relativePath: "thumbnails/image-a.jpg",
                    byteCount: 10,
                    lastAccessedAt: Self.fixedNow
                )
            ],
            favoriteWallpaperIDs: [imageB, imageC]
        )

        let items = LibraryGalleryBuilder.items(snapshot: snapshot, market: .zhCN)
        #expect(items.map(\.date) == [date("2026-11-23"), date("2026-11-22")])
        #expect(!items.contains { $0.wallpaperID == imageC })

        let first = try #require(items.first)
        #expect(first.wallpaperID == imageA)
        #expect(first.title == "合成标题")
        #expect(first.hasThumbnail)
        #expect(!first.hasOriginal)
        #expect(first.hasStory)
        #expect(!first.hasUnavailableStory)
        #expect(!first.isFavorite)

        let second = try #require(items.last)
        #expect(second.wallpaperID == imageB)
        #expect(second.title == "合成镜像标题")
        #expect(second.isFavorite)
        #expect(!second.hasStory)
        #expect(second.hasUnavailableStory)
    }

    @Test("a story from another market is never attached")
    func marketIsolation() throws {
        let occurrence = occurrence("2026-11-23", imageID: "image-a")
        let foreignStory = try #require(
            DailyStoryRecord(
                id: "story-en",
                source: .bing,
                market: .enUS,
                date: occurrence.localDate,
                associatedWallpaperID: occurrence.wallpaperID,
                headline: "Synthetic headline",
                body: "Synthetic body",
                originalLocale: "en-US",
                fetchedAt: Self.fixedNow,
                availability: .available
            )
        )
        let snapshot = RepositorySnapshot(
            occurrences: [occurrence],
            stories: [foreignStory]
        )

        let item = try #require(
            LibraryGalleryBuilder.items(snapshot: snapshot, market: .zhCN).first
        )
        #expect(!item.hasStory)
        #expect(!item.hasUnavailableStory)
    }

    @Test("gallery sections preserve descending month order")
    func gallerySections() {
        let items = [
            galleryItem("2026-11-23", imageID: "image-a"),
            galleryItem("2026-10-05", imageID: "image-b"),
            galleryItem("2026-10-01", imageID: "image-c")
        ]
        let sections = LibraryGallerySection.sections(from: items)

        #expect(
            sections.map(\.key)
                == [
                    LibraryMonthKey(year: 2026, month: 11),
                    LibraryMonthKey(year: 2026, month: 10)
                ]
        )
        #expect(sections.map { $0.items.count } == [1, 2])
    }

    // MARK: Model and shared repository

    @Test("favorites persist through the shared repository and reload")
    @MainActor
    func favoriteRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakLibraryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now: @Sendable () -> Date = { Self.fixedNow }
        let service = try TodayService(directory: directory, now: now)
        let imageID = image("favorite-round-trip")
        let day = date("2027-01-14")
        let earlierDay = date("2027-01-13")
        let occurrence = WallpaperOccurrence(
            source: .bing,
            market: .zhCN,
            localDate: day,
            wallpaperID: imageID
        )
        let earlierOccurrence = WallpaperOccurrence(
            source: .bing,
            market: .zhCN,
            localDate: earlierDay,
            wallpaperID: imageID
        )
        _ = try await service.repository.upsertOccurrences([occurrence, earlierOccurrence])

        let model = LibraryModel(service: service, market: .zhCN, now: now)
        await model.load()
        #expect(model.galleryItems.count == 2)
        #expect(model.month?.observedDayCount == 2)

        await model.selectDate(day)
        let selection = try #require(model.selection)
        guard case .observed(_, let payload) = selection else {
            Issue.record("Expected an observed day with a cached payload")
            return
        }
        #expect(payload.wallpaperID == imageID)
        #expect(!payload.hasThumbnail)
        #expect(!payload.hasOriginal)

        await model.toggleFavorite(imageID)
        #expect(model.galleryItems.allSatisfy { $0.isFavorite })
        #expect(model.favoriteImageCount == 1)

        model.setScope(.favorites)
        #expect(model.visibleGalleryItems.count == 1)
        #expect(model.visibleGalleryItems.first?.date == day)
        model.setScope(.all)

        await model.reload()
        #expect(model.galleryItems.allSatisfy { $0.isFavorite })

        await model.toggleFavorite(imageID)
        #expect(model.favoriteImageCount == 0)
        #expect(model.galleryItems.allSatisfy { !$0.isFavorite })
    }

    @Test("market switches preserve the calendar month and selected date")
    @MainActor
    func marketSwitchPreservesCalendarNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakLibraryMarketNavigation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now: @Sendable () -> Date = { Self.fixedNow }
        let service = try TodayService(directory: directory, now: now)
        let model = LibraryModel(service: service, market: .zhCN, now: now)
        await model.load()

        let selectedDate = date("2026-12-17")
        await model.selectDate(selectedDate)
        let selectedMonth = model.monthKey
        model.updateMarket(.enUS)
        await model.load()

        #expect(model.monthKey == selectedMonth)
        #expect(model.selectedDate == selectedDate)
    }


    @Test("favorite changes hand exactly one coalesced signal to sync")
    @MainActor
    func favoriteChangesSignalSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakLibrarySyncSignal-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now: @Sendable () -> Date = { Self.fixedNow }
        let service = try TodayService(directory: directory, now: now)
        let imageID = image("favorite-sync-signal")
        let occurrence = WallpaperOccurrence(
            source: .bing,
            market: .zhCN,
            localDate: date("2027-01-15"),
            wallpaperID: imageID
        )
        _ = try await service.repository.upsertOccurrences([occurrence])

        let recorder = SyncSignalRecorder()
        let model = LibraryModel(
            service: service,
            market: .zhCN,
            now: now,
            noteSyncActivity: { recorder.note() }
        )
        await model.load()

        await model.toggleFavorite(imageID)
        #expect(model.favoriteImageCount == 1)
        // One user change, one hand-off; the controller owns coalescing.
        #expect(recorder.count == 1)

        await model.toggleFavorite(imageID)
        #expect(model.favoriteImageCount == 0)
        #expect(recorder.count == 2)

        // Re-adding is another local change and hands off again.
        await model.toggleFavorite(imageID)
        #expect(model.favoriteImageCount == 1)
        #expect(recorder.count == 3)
    }

    // MARK: Thumbnail backfill

    @Test("one refresh caches thumbnails for every archived day, not only today")
    func refreshBackfillsArchiveThumbnails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakThumbnailBackfill-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = try #require(Data(base64Encoded: Self.syntheticPNGBase64))
        let archive = try JSONSerialization.data(withJSONObject: [
            "images": [
                [
                    "fullstartdate": "202611221600",
                    "urlbase": "/th?id=OHR.SyntheticFern_ZH-CN123456789_1920x1080",
                    "hsh": "synthetic-fern",
                    "title": "Synthetic fern title",
                    "copyright": "Synthetic fern copyright",
                    "copyrightlink": "https://www.bing.com/search?q=synthetic"
                ],
                [
                    "fullstartdate": "202611231600",
                    "urlbase": "/th?id=OHR.SyntheticOwl_ZH-CN987654321_1920x1080",
                    "hsh": "synthetic-owl",
                    "title": "Synthetic owl title",
                    "copyright": "Synthetic owl copyright",
                    "copyrightlink": "https://www.bing.com/search?q=synthetic"
                ]
            ]
        ])
        let stories = try JSONSerialization.data(
            withJSONObject: ["MediaContents": [Any]()]
        )

        let transport = LibraryThumbnailTransport(
            archive: archive,
            stories: stories,
            image: png
        )
        let provider = BingProvider(
            profile: .zhCN,
            configuration: BingProviderConfiguration(
                maximumAttempts: 1,
                initialRetryDelay: .zero,
                maximumRetryDelay: .zero
            ),
            transport: transport,
            now: { Self.refreshNow },
            sleep: { _ in }
        )
        let service = try TodayService(
            directory: directory,
            now: { Self.refreshNow },
            providerFactory: { _ in provider }
        )

        let outcome = try await service.refreshToday(market: .zhCN)
        #expect(outcome.payload.occurrence.localDate == date("2026-11-24"))
        #expect(outcome.payload.hasThumbnail)

        let snapshot = await service.repository.snapshot()
        #expect(snapshot.occurrences.count == 2)
        #expect(
            snapshot.availableThumbnailIDs
                == Set([image("SyntheticFern"), image("SyntheticOwl")])
        )
        #expect(snapshot.missingAssets.isEmpty)

        let gallery = LibraryGalleryBuilder.items(snapshot: snapshot, market: .zhCN)
        #expect(gallery.count == 2)
        #expect(gallery.allSatisfy { $0.hasThumbnail })

        for wallpaperID in snapshot.availableThumbnailIDs {
            let url = await service.repository.assetURL(kind: .thumbnail, for: wallpaperID)
            if let url {
                #expect(FileManager.default.fileExists(atPath: url.path))
            } else {
                Issue.record("thumbnail asset has no file URL for \(wallpaperID.sourceImageID)")
            }
        }

        let firstRequests = await transport.recordedImageRequests()
        #expect(firstRequests.count == 2)

        // A second refresh must reuse the stored thumbnails instead of
        // downloading them again.
        let secondOutcome = try await service.refreshToday(market: .zhCN)
        #expect(secondOutcome.payload.hasThumbnail)
        let secondRequests = await transport.recordedImageRequests()
        #expect(secondRequests.count == 2)
    }
}

/// Counts local sync hand-offs without creating a controller or touching a
/// folder. `AppModel` passes its own main-actor trigger in production.
@MainActor
private final class SyncSignalRecorder {
    private(set) var count = 0

    func note() {
        count += 1
    }
}
