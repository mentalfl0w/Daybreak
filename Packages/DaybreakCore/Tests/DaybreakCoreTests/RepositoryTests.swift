import Foundation
import Testing
import DaybreakCore

// MARK: - Synthetic fixtures

private enum RepositoryFixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_100)

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
        publisherTime: Date? = nil,
        source: SourceID = .bing
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: source,
            market: market,
            localDate: date(iso8601),
            wallpaperID: image(imageID, source: source),
            publisherTime: publisherTime,
            revision: revision
        )
    }

    static func metadata(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String,
        title: String = "Synthetic metadata title",
        copyright: String = "Synthetic copyright",
        sourceURL: URL = URL(string: "https://example.invalid/synthetic-content")!,
        fetchedAt: Date = fetchedAt,
        contentHash: String = "synthetic-content-hash"
    ) -> WallpaperMetadataRecord {
        WallpaperMetadataRecord(
            key: OccurrenceKey(
                source: .bing,
                market: market,
                localDate: date(iso8601)
            ),
            wallpaperID: image(imageID),
            title: title,
            copyright: copyright,
            sourceURL: sourceURL,
            originalLocale: market.rawValue,
            fetchedAt: fetchedAt,
            contentHash: contentHash
        )
    }

    static func story(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String?,
        id: String? = nil,
        title: String? = "Synthetic story title",
        headline: String? = "Synthetic headline",
        body: String? = "Synthetic story body.",
        quickFact: String? = nil,
        sourceURL: URL = URL(string: "https://example.invalid/synthetic-content")!,
        fetchedAt: Date = fetchedAt,
        contentHash: String? = nil,
        availability: StoryAvailability = .available
    ) -> DailyStoryRecord {
        let identifier = id ?? "story:\(market.rawValue):\(iso8601):\(imageID ?? "unbound")"
        let effectiveBody: String?
        let effectiveQuickFact: String?
        switch availability {
        case .available:
            effectiveBody = body
            effectiveQuickFact = quickFact
        case .unavailable:
            effectiveBody = nil
            effectiveQuickFact = nil
        }
        guard let story = DailyStoryRecord(
            id: identifier,
            source: .bing,
            market: market,
            date: date(iso8601),
            associatedWallpaperID: imageID.map { image($0) },
            title: title,
            headline: headline,
            body: effectiveBody,
            quickFact: effectiveQuickFact,
            copyright: "Synthetic copyright",
            originalLocale: market.rawValue,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt,
            contentHash: contentHash ?? "synthetic-\(identifier)",
            sourceFields: ["Synthetic.ImageContent.Headline"],
            availability: availability
        ) else {
            preconditionFailure("Invalid synthetic story fixture")
        }
        return story
    }

    static func wallpaper(
        _ imageID: String,
        title: String = "Synthetic wallpaper title",
        fetchedAt: Date = fetchedAt
    ) -> WallpaperRecord {
        WallpaperRecord(
            source: .bing,
            wallpaperID: image(imageID),
            canonicalTitle: title,
            copyright: "Synthetic copyright",
            sourceURL: URL(string: "https://example.invalid/synthetic-wallpaper"),
            fetchedAt: fetchedAt
        )
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct LegacyStory: Encodable {
    let id: String
    let source: SourceID
    let market: Market
    let date: LocalDate
    let associatedWallpaperID: WallpaperID?
    let headline: String?
    let body: String?
    let quickFact: String?
    let originalLocale: String
    let sourceURL: URL?
    let fetchedAt: Date
    let contentHash: String?
    let availability: StoryAvailability
}

private struct LegacyAsset: Encodable {
    let id: String
    let wallpaperID: WallpaperID
    let kind: AssetKind
    let relativePath: String
    let byteCount: Int
    let lastAccessedAt: Date
    let pinReasons: Set<PinReason>
}

/// A version 1 or 2 index written before the sync journal existed.
/// `reservations`, first-observation fields and `sync` are optional in the
/// reader; `appliedWallpapers` is legacy and ignored on load.
private struct LegacyRepositoryIndex: Encodable {
    let schemaVersion: Int
    let occurrences: [WallpaperOccurrence]
    let metadata: [WallpaperMetadataRecord]
    let wallpapers: [WallpaperRecord]
    let stories: [DailyStoryRecord]
    let assets: [CachedImageAsset]
    let favorites: [WallpaperID]
    let pinnedOccurrences: [PinnedOccurrence]
    let appliedWallpapers: [WallpaperID]
}

// MARK: - Tests

struct RepositoryTests {
    @Test func emptyRepositoryLoadsEmptySnapshot() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let repository = try WallpaperRepository(directory: directory)
        let snapshot = await repository.snapshot()
        let usage = await repository.storageUsage()

        #expect(snapshot.loadState == .empty)
        #expect(snapshot.schemaVersion == RepositorySchema.currentVersion)
        #expect(snapshot.occurrences.isEmpty)
        #expect(snapshot.stories.isEmpty)
        #expect(snapshot.favoriteWallpaperIDs.isEmpty)
        #expect(usage.assetCount == 0)
        #expect(usage.totalAssetBytes == 0)
    }

    @Test func upsertAndOfflineReloadPreserveContentAndAssetFile() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let metadata = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let story = RepositoryFixture.story("2026-11-23", imageID: "image-A", body: "Synthetic offline story.")
        let wallpaper = RepositoryFixture.wallpaper("image-A")

        let repository = try WallpaperRepository(directory: directory, now: { RepositoryFixture.fixedNow })
        let occurrenceSummary = try await repository.upsertOccurrences([occurrence])
        let metadataSummary = try await repository.upsertMetadata([metadata])
        let wallpaperSummary = try await repository.upsertWallpapers([wallpaper])
        let storySummary = try await repository.upsertStories([story])
        #expect(occurrenceSummary.inserted == 1)
        #expect(metadataSummary.inserted == 1)
        #expect(wallpaperSummary.inserted == 1)
        #expect(storySummary.inserted == 1)

        let storedAsset = try await repository.storeAsset(
            Data("synthetic-jpeg-bytes".utf8),
            kind: .original,
            for: occurrence.wallpaperID,
            fileExtension: "jpg",
            accessedAt: RepositoryFixture.fetchedAt
        )
        let assetURLOptional = await repository.assetURL(for: storedAsset)
        let assetURL = try #require(assetURLOptional)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))

        let reopened = try WallpaperRepository(directory: directory)
        let snapshot = await reopened.snapshot()

        #expect(snapshot.loadState == .loaded)
        #expect(snapshot.occurrences == [occurrence])
        #expect(snapshot.metadata == [metadata])
        #expect(snapshot.wallpapers == [wallpaper])
        #expect(snapshot.stories == [story])
        #expect(snapshot.assets == [storedAsset])
        #expect(snapshot.missingAssets.isEmpty)
        #expect(snapshot.availableOriginalIDs == Set([occurrence.wallpaperID]))
        #expect(snapshot.firstObservedDate == RepositoryFixture.date("2026-11-23"))
        #expect(snapshot.observationStartedAt == RepositoryFixture.fixedNow)

        let match = await reopened.storyMatch(for: occurrence.id)
        #expect(match?.availableStory?.body == "Synthetic offline story.")
    }

    @Test func storyCacheIsIndependentFromMetadataAndAssets() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let metadata = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let story = RepositoryFixture.story("2026-11-23", imageID: "image-A")
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertOccurrences([occurrence])
        try await repository.upsertMetadata([metadata])
        try await repository.upsertStories([story])
        let thumbnail = try await repository.storeAsset(
            Data([UInt8(1), UInt8(2), UInt8(3)]),
            kind: .thumbnail,
            for: occurrence.wallpaperID,
            fileExtension: "png"
        )
        try await repository.setFavorite(occurrence.wallpaperID, isFavorite: true)

        let clearedStories = try await repository.clearStories()
        #expect(clearedStories == 1)
        let afterStoryClear = await repository.snapshot()
        #expect(afterStoryClear.stories.isEmpty)
        #expect(afterStoryClear.occurrences == [occurrence])
        #expect(afterStoryClear.metadata == [metadata])
        #expect(afterStoryClear.favoriteWallpaperIDs == Set([occurrence.wallpaperID]))
        #expect(afterStoryClear.assets == [thumbnail])

        let clearedThumbnails = try await repository.clearThumbnails()
        #expect(clearedThumbnails == 1)
        let afterThumbnailClear = await repository.snapshot()
        #expect(afterThumbnailClear.assets.isEmpty)
        #expect(afterThumbnailClear.metadata == [metadata])
        #expect(afterThumbnailClear.favoriteWallpaperIDs == Set([occurrence.wallpaperID]))
    }

    @Test func missingAssetIsReportedAndStoryStillMatchesOffline() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let metadata = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let story = RepositoryFixture.story("2026-11-23", imageID: "image-A", body: "Synthetic offline story.")
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertOccurrences([occurrence])
        try await repository.upsertMetadata([metadata])
        try await repository.upsertStories([story])
        let asset = try await repository.storeAsset(
            Data("synthetic-bytes".utf8),
            kind: .original,
            for: occurrence.wallpaperID,
            fileExtension: "jpg"
        )
        let assetURLOptional = await repository.assetURL(for: asset)
        let assetURL = try #require(assetURLOptional)
        try FileManager.default.removeItem(at: assetURL)

        let reopened = try WallpaperRepository(directory: directory)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.missingAssets.map(\.id) == [asset.id])
        #expect(snapshot.availableOriginalIDs.isEmpty)
        #expect(snapshot.stories.first?.body == "Synthetic offline story.")

        let match = await reopened.storyMatch(for: occurrence.id)
        #expect(match?.availableStory?.body == "Synthetic offline story.")
    }

    @Test func assetReplacementKeepsOneIndexEntryAndRemovesOldFile() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let image = RepositoryFixture.image("image-A")
        let repository = try WallpaperRepository(directory: directory)
        let first = try await repository.storeAsset(
            Data("first".utf8),
            kind: .original,
            for: image,
            fileExtension: "jpg",
            accessedAt: Date(timeIntervalSince1970: 100)
        )
        let firstURLOptional = await repository.assetURL(for: first)
        let firstURL = try #require(firstURLOptional)

        let second = try await repository.storeAsset(
            Data("second".utf8),
            kind: .original,
            for: image,
            fileExtension: "jpg",
            accessedAt: Date(timeIntervalSince1970: 200)
        )
        let secondURLOptional = await repository.assetURL(for: second)
        let secondURL = try #require(secondURLOptional)

        #expect(first.relativePath != second.relativePath)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))

        let snapshot = await repository.snapshot()
        #expect(snapshot.assets.count == 1)
        #expect(snapshot.assets.first?.relativePath == second.relativePath)
    }

    @Test func invalidAssetExtensionAndEmptyDataAreRejected() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let repository = try WallpaperRepository(directory: directory)
        let image = RepositoryFixture.image("image-A")

        do {
            _ = try await repository.storeAsset(
                Data([UInt8(1)]),
                kind: .original,
                for: image,
                fileExtension: "../jpg"
            )
            Issue.record("Expected an invalid extension error")
        } catch let error as RepositoryError {
            #expect(error == .invalidAssetExtension("../jpg"))
        }

        do {
            _ = try await repository.storeAsset(
                Data(),
                kind: .original,
                for: image,
                fileExtension: "jpg"
            )
            Issue.record("Expected an empty asset error")
        } catch let error as RepositoryError {
            #expect(error == .emptyAsset)
        }

        let snapshot = await repository.snapshot()
        #expect(snapshot.assets.isEmpty)
    }

    @Test func occurrenceRevisionConflictAndStaleRevision() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let key = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A", revision: 1)
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([key])

        let stale = RepositoryFixture.occurrence("2026-11-23", imageID: "image-B", revision: 0)
        let staleSummary = try await repository.upsertOccurrences([stale])
        #expect(staleSummary.ignored == 1)

        let conflict = RepositoryFixture.occurrence("2026-11-23", imageID: "image-B", revision: 1)
        do {
            _ = try await repository.upsertOccurrences([conflict])
            Issue.record("Expected an occurrence conflict")
        } catch let error as RepositoryError {
            #expect(error == .occurrenceConflict(key.id))
        }

        let snapshot = await repository.snapshot()
        #expect(snapshot.occurrences == [key])
    }

    @Test func newerRevisionDropsStaleMetadataAndMovesPinnedImage() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A", revision: 0)
        let metadata = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertOccurrences([first])
        try await repository.upsertMetadata([metadata])
        try await repository.setPinned(first, isPinned: true)

        let second = RepositoryFixture.occurrence("2026-11-23", imageID: "image-B", revision: 1)
        try await repository.upsertOccurrences([second])

        let snapshot = await repository.snapshot()
        #expect(snapshot.occurrences == [second])
        #expect(snapshot.metadata.isEmpty)
        #expect(snapshot.pinnedOccurrences.contains(
            PinnedOccurrence(key: second.id, wallpaperID: second.wallpaperID)
        ))
        #expect(!snapshot.pinnedOccurrences.contains(
            PinnedOccurrence(key: first.id, wallpaperID: first.wallpaperID)
        ))
        let reasons = await repository.pinReasons(for: second.wallpaperID)
        #expect(reasons.contains(.pinnedDate))
    }

    @Test func metadataFreshnessAndConflict() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let key = OccurrenceKey(
            source: .bing,
            market: .zhCN,
            localDate: RepositoryFixture.date("2026-11-23")
        )
        let first = RepositoryFixture.metadata("2026-11-23", imageID: "image-A", title: "Title A")
        let newer = RepositoryFixture.metadata(
            "2026-11-23",
            imageID: "image-A",
            title: "Title B",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertMetadata([first])
        let updateSummary = try await repository.upsertMetadata([newer])
        #expect(updateSummary.updated == 1)

        let staleSummary = try await repository.upsertMetadata([first])
        #expect(staleSummary.ignored == 1)

        let conflict = RepositoryFixture.metadata(
            "2026-11-23",
            imageID: "image-A",
            title: "Title C",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        do {
            _ = try await repository.upsertMetadata([conflict])
            Issue.record("Expected a metadata conflict")
        } catch let error as RepositoryError {
            #expect(error == .metadataConflict(key))
        }

        let snapshot = await repository.snapshot()
        #expect(snapshot.metadata.first?.title == "Title B")
    }

    @Test func metadataIdentityMismatchAndUnboundMetadataReplacement() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let mismatched = RepositoryFixture.metadata("2026-11-23", imageID: "image-B")
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertOccurrences([occurrence])
        do {
            _ = try await repository.upsertMetadata([mismatched])
            Issue.record("Expected metadata identity conflict")
        } catch let error as RepositoryError {
            #expect(error == .metadataConflict(occurrence.id))
        }

        try await repository.removeAssets(for: occurrence.wallpaperID)
        let secondDirectory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(secondDirectory) }
        let secondRepository = try WallpaperRepository(directory: secondDirectory)
        try await secondRepository.upsertMetadata([mismatched])
        let unboundMetadata = await secondRepository.metadata(for: mismatched.key)
        #expect(unboundMetadata != nil)
        try await secondRepository.upsertOccurrences([occurrence])
        let snapshot = await secondRepository.snapshot()
        #expect(snapshot.occurrences == [occurrence])
        #expect(snapshot.metadata.isEmpty)
    }

    @Test func storyFreshnessAndConflict() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-1",
            body: "Story A"
        )
        let newer = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-1",
            body: "Story B",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let conflict = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-1",
            body: "Story C",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertStories([first])
        let updateSummary = try await repository.upsertStories([newer])
        #expect(updateSummary.updated == 1)
        let staleSummary = try await repository.upsertStories([first])
        #expect(staleSummary.ignored == 1)

        do {
            _ = try await repository.upsertStories([conflict])
            Issue.record("Expected a story conflict")
        } catch let error as RepositoryError {
            #expect(error == .storyConflict("story-1"))
        }

        let snapshot = await repository.snapshot()
        #expect(snapshot.stories.first?.body == "Story B")
    }

    @Test func wallpaperFreshnessAndConflict() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.wallpaper("image-A", title: "Title A")
        let newer = RepositoryFixture.wallpaper(
            "image-A",
            title: "Title B",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let conflict = RepositoryFixture.wallpaper(
            "image-A",
            title: "Title C",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertWallpapers([first])
        let updateSummary = try await repository.upsertWallpapers([newer])
        #expect(updateSummary.updated == 1)
        let staleSummary = try await repository.upsertWallpapers([first])
        #expect(staleSummary.ignored == 1)

        do {
            _ = try await repository.upsertWallpapers([conflict])
            Issue.record("Expected a wallpaper conflict")
        } catch let error as RepositoryError {
            #expect(error == .wallpaperConflict(first.wallpaperID))
        }

        let snapshot = await repository.snapshot()
        #expect(snapshot.wallpapers.first?.canonicalTitle == "Title B")
    }

    @Test func favoritePinAndAppliedProtectFromLRU() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let a = RepositoryFixture.image("image-A")
        let b = RepositoryFixture.image("image-B")
        let c = RepositoryFixture.image("image-C")
        let d = RepositoryFixture.image("image-D")
        let repository = try WallpaperRepository(directory: directory)

        for (index, image) in [a, b, c, d].enumerated() {
            _ = try await repository.storeAsset(
                Data(repeating: UInt8(index + 1), count: 10),
                kind: .original,
                for: image,
                fileExtension: "jpg",
                accessedAt: Date(timeIntervalSince1970: TimeInterval(100 * (index + 1)))
            )
        }
        try await repository.setFavorite(a, isFavorite: true)
        let pinKey = OccurrenceKey(
            source: .bing,
            market: .zhCN,
            localDate: RepositoryFixture.date("2026-11-23")
        )
        try await repository.setPinned(pinKey, wallpaperID: b, isPinned: true)
        try await repository.replaceAppliedWallpapers(Set([c]))

        let result = try await repository.evictLeastRecentlyUsed(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 30)
        )
        #expect(result.evictedAssets.map(\.wallpaperID) == [d])
        #expect(result.evictedBytes == 10)

        let snapshot = await repository.snapshot()
        #expect(snapshot.asset(kind: .original, for: a) != nil)
        #expect(snapshot.asset(kind: .original, for: b) != nil)
        #expect(snapshot.asset(kind: .original, for: c) != nil)
        #expect(snapshot.asset(kind: .original, for: d) == nil)
        #expect(snapshot.pinReasons(for: a).contains(.favorite))
        #expect(snapshot.pinReasons(for: b).contains(.pinnedDate))
        #expect(snapshot.pinReasons(for: c).contains(.currentlyApplied))
    }

    @Test func lruEvictsLeastRecentlyAccessedUnprotectedAsset() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let a = RepositoryFixture.image("image-A")
        let b = RepositoryFixture.image("image-B")
        let c = RepositoryFixture.image("image-C")
        let repository = try WallpaperRepository(directory: directory)

        for (image, timestamp) in [(a, 100.0), (b, 200.0), (c, 300.0)] {
            _ = try await repository.storeAsset(
                Data(repeating: 1, count: 10),
                kind: .original,
                for: image,
                fileExtension: "jpg",
                accessedAt: Date(timeIntervalSince1970: timestamp)
            )
        }

        let result = try await repository.evictLeastRecentlyUsed(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 20)
        )
        #expect(result.evictedAssets.map(\.wallpaperID) == [a])
        let snapshot = await repository.snapshot()
        #expect(snapshot.asset(kind: .original, for: a) == nil)
        #expect(snapshot.asset(kind: .original, for: b) != nil)
        #expect(snapshot.asset(kind: .original, for: c) != nil)
    }

    @Test func markAssetAccessedChangesLRUOrder() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let a = RepositoryFixture.image("image-A")
        let b = RepositoryFixture.image("image-B")
        let repository = try WallpaperRepository(directory: directory)

        _ = try await repository.storeAsset(
            Data(repeating: 1, count: 10),
            kind: .original,
            for: a,
            fileExtension: "jpg",
            accessedAt: Date(timeIntervalSince1970: 100)
        )
        _ = try await repository.storeAsset(
            Data(repeating: 2, count: 10),
            kind: .original,
            for: b,
            fileExtension: "jpg",
            accessedAt: Date(timeIntervalSince1970: 200)
        )
        let changed = try await repository.markAssetAccessed(
            kind: .original,
            for: a,
            at: Date(timeIntervalSince1970: 300)
        )
        #expect(changed)

        let result = try await repository.evictLeastRecentlyUsed(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 10)
        )
        #expect(result.evictedAssets.map(\.wallpaperID) == [b])
        let snapshot = await repository.snapshot()
        #expect(snapshot.asset(kind: .original, for: a) != nil)
        #expect(snapshot.asset(kind: .original, for: b) == nil)
    }

    @Test func corruptPrimaryRecoversFromBackup() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.occurrence("2026-11-22", imageID: "image-A")
        let second = RepositoryFixture.occurrence("2026-11-23", imageID: "image-B")
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([first])
        try await repository.upsertOccurrences([second])

        let primaryURL = directory.appendingPathComponent("repository.json")
        let backupURL = directory.appendingPathComponent("repository.json.backup")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        try Data("{not-json".utf8).write(to: primaryURL, options: .atomic)

        let recovered = try WallpaperRepository(directory: directory)
        let snapshot = await recovered.snapshot()
        #expect(snapshot.loadState == .recoveredFromBackup)
        #expect(snapshot.occurrences == [first])
    }

    @Test func unsupportedSchemaVersionIsRejected() throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        try Data(#"{"schemaVersion":99}"#.utf8).write(
            to: directory.appendingPathComponent("repository.json"),
            options: .atomic
        )

        do {
            _ = try WallpaperRepository(directory: directory)
            Issue.record("Expected an unsupported schema version error")
        } catch let error as RepositoryError {
            #expect(error == .unsupportedSchemaVersion(
                found: 99,
                supported: RepositorySchema.currentVersion
            ))
        }
    }

    @Test func legacyCacheMigratesWithoutHistoricalAppliedProtection() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let legacyOldStory = LegacyStory(
            id: "legacy-story-0",
            source: .bing,
            market: .zhCN,
            date: occurrence.localDate,
            associatedWallpaperID: occurrence.wallpaperID,
            headline: "Legacy old headline",
            body: "Legacy old story body.",
            quickFact: nil,
            originalLocale: "zh-CN",
            sourceURL: URL(string: "https://example.invalid/legacy-story"),
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(-10),
            contentHash: "legacy-old-hash",
            availability: .available
        )
        let legacyStory = LegacyStory(
            id: "legacy-story-1",
            source: .bing,
            market: .zhCN,
            date: occurrence.localDate,
            associatedWallpaperID: occurrence.wallpaperID,
            headline: "Legacy synthetic headline",
            body: "Legacy synthetic story body.",
            quickFact: nil,
            originalLocale: "zh-CN",
            sourceURL: URL(string: "https://example.invalid/legacy-story"),
            fetchedAt: RepositoryFixture.fetchedAt,
            contentHash: "legacy-hash",
            availability: .available
        )
        let legacyAsset = LegacyAsset(
            id: "legacy-asset-1",
            wallpaperID: occurrence.wallpaperID,
            kind: .original,
            relativePath: "Assets/image-A-original.jpg",
            byteCount: 123,
            lastAccessedAt: RepositoryFixture.fetchedAt,
            pinReasons: [.favorite, .currentlyApplied]
        )

        let encoder = JSONEncoder()
        try encoder.encode([occurrence]).write(
            to: directory.appendingPathComponent("occurrences.json"),
            options: .atomic
        )
        try encoder.encode([legacyOldStory, legacyStory]).write(
            to: directory.appendingPathComponent("stories.json"),
            options: .atomic
        )
        try encoder.encode([legacyAsset]).write(
            to: directory.appendingPathComponent("image-assets.json"),
            options: .atomic
        )
        try encoder.encode([occurrence.wallpaperID]).write(
            to: directory.appendingPathComponent("favorites.json"),
            options: .atomic
        )

        let repository = try WallpaperRepository(directory: directory)
        let snapshot = await repository.snapshot()
        #expect(snapshot.loadState == .migratedLegacyCache)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("repository.json").path
        ))
        #expect(snapshot.occurrences == [occurrence])
        #expect(snapshot.stories.count == 1)
        #expect(snapshot.stories.first?.id == "legacy-story-1")
        #expect(snapshot.stories.first?.body == "Legacy synthetic story body.")
        #expect(snapshot.favoriteWallpaperIDs == Set([occurrence.wallpaperID]))
        // A historical .currentlyApplied flag is not imported as permanent
        // protection; current-desktop protection is re-derived per launch.
        #expect(snapshot.appliedWallpapers.isEmpty)
        #expect(snapshot.assets.count == 1)
        #expect(snapshot.missingAssets.count == 1)
        #expect(snapshot.firstObservedDate == occurrence.localDate)
        #expect(snapshot.observationStartedAt == nil)
        #expect(snapshot.pinReasons(for: occurrence.wallpaperID).contains(.favorite))
        #expect(!snapshot.pinReasons(for: occurrence.wallpaperID).contains(.currentlyApplied))

        let reopened = try WallpaperRepository(directory: directory)
        let reloaded = await reopened.snapshot()
        #expect(reloaded.loadState == .loaded)
        #expect(reloaded.occurrences == [occurrence])
    }

    @Test func corruptLegacyFileFailsMigrationWithoutWritingFormalIndex() throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        try Data("{not-json".utf8).write(
            to: directory.appendingPathComponent("occurrences.json"),
            options: .atomic
        )

        do {
            _ = try WallpaperRepository(directory: directory)
            Issue.record("Expected a migration failure")
        } catch let error as RepositoryError {
            if case .migrationFailed = error {
                // Expected.
            } else {
                Issue.record("Unexpected repository error: \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("repository.json").path
        ))
    }

    @Test func firstObservedDateDoesNotMoveBackward() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let newer = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let older = RepositoryFixture.occurrence("2026-11-22", imageID: "image-B")
        let repository = try WallpaperRepository(directory: directory, now: { RepositoryFixture.fixedNow })

        try await repository.upsertOccurrences([newer])
        try await repository.upsertOccurrences([older])

        let snapshot = await repository.snapshot()
        #expect(snapshot.occurrences.count == 2)
        #expect(snapshot.firstObservedDate == newer.localDate)
        #expect(snapshot.observationStartedAt == RepositoryFixture.fixedNow)
    }

    @Test func idempotentProtectionUpdatesDoNotRewrite() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let image = RepositoryFixture.image("image-A")
        let repository = try WallpaperRepository(directory: directory)

        let firstFavorite = try await repository.setFavorite(image, isFavorite: true)
        let secondFavorite = try await repository.setFavorite(image, isFavorite: true)
        #expect(firstFavorite)
        #expect(!secondFavorite)

        let firstApplied = try await repository.replaceAppliedWallpapers(Set([image]))
        let secondApplied = try await repository.replaceAppliedWallpapers(Set([image]))
        #expect(firstApplied)
        #expect(!secondApplied)

        let snapshot = await repository.snapshot()
        #expect(snapshot.favoriteWallpaperIDs == Set([image]))
        #expect(snapshot.appliedWallpapers == Set([image]))
    }

    @Test func repairRemovesOrphansAndReportsMissingFiles() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let image = RepositoryFixture.image("image-A")
        let repository = try WallpaperRepository(directory: directory)
        let asset = try await repository.storeAsset(
            Data("synthetic".utf8),
            kind: .original,
            for: image,
            fileExtension: "jpg"
        )
        let assetURLOptional = await repository.assetURL(for: asset)
        let assetURL = try #require(assetURLOptional)
        try FileManager.default.removeItem(at: assetURL)

        let thumbnailDirectory = directory.appendingPathComponent("Assets/thumbnail", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let orphan = thumbnailDirectory.appendingPathComponent("orphan.jpg")
        try Data("orphan".utf8).write(to: orphan, options: .atomic)

        let report = try await repository.repair()
        #expect(report.missingAssets.map(\.id) == [asset.id])
        #expect(report.orphanedFilesRemoved == ["Assets/thumbnail/orphan.jpg"])
        #expect(report.failedOrphanRemovals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func assetIdentityIsDelimiterAndCaseSafe() {
        let left = WallpaperID(source: SourceID("a"), sourceImageID: "b:c")
        let right = WallpaperID(source: SourceID("a:b"), sourceImageID: "c")
        #expect(AssetIdentity.id(kind: .original, wallpaperID: left)
            != AssetIdentity.id(kind: .original, wallpaperID: right))
        #expect(AssetIdentity.id(kind: .original, wallpaperID: left)
            == AssetIdentity.id(kind: .original, wallpaperID: left))
        #expect(AssetIdentity.id(kind: .thumbnail, wallpaperID: left)
            != AssetIdentity.id(kind: .original, wallpaperID: left))
    }

    @Test func unsafeAssetPathIsRejectedDuringDecode() {
        let json = """
        {"wallpaperID":{"source":"bing","sourceImageID":"image-A"},"kind":"original","relativePath":"../escape.jpg","byteCount":1,"lastAccessedAt":0}
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CachedImageAsset.self, from: Data(json.utf8))
        }
    }

    @Test func localDateUsesExplicitMarketTimeZone() throws {
        let formatter = ISO8601DateFormatter()
        let instant = try #require(formatter.date(from: "2026-12-31T16:00:00Z"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))

        #expect(LocalDate(date: instant, timeZone: tokyo) == RepositoryFixture.date("2027-01-01"))
        #expect(LocalDate(date: instant, timeZone: losAngeles) == RepositoryFixture.date("2026-12-31"))
    }

    @Test func storyMatchingUsesIdentityThenExactSourceURL() {
        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let metadata = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")

        let identityStory = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-identity"
        )
        let identityMatch = StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [identityStory]
        )
        if case let .matched(matched, evidence) = identityMatch {
            #expect(matched.id == identityStory.id)
            #expect(evidence == .imageIdentityMarketAndDate)
        } else {
            Issue.record("Expected identity match")
        }

        let urlStory = RepositoryFixture.story(
            "2026-11-23",
            imageID: nil,
            id: "story-url"
        )
        let urlMatch = StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [urlStory]
        )
        if case let .matched(matched, evidence) = urlMatch {
            #expect(matched.id == urlStory.id)
            #expect(evidence == .sourceURLCorroboration)
        } else {
            Issue.record("Expected source-URL corroboration match")
        }

        let differentURLStory = RepositoryFixture.story(
            "2026-11-23",
            imageID: nil,
            id: "story-different-url",
            sourceURL: URL(string: "https://example.invalid/other-story")!
        )
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [differentURLStory]
        ) == .unmatched(.imageIdentityMissing(candidateCount: 1)))

        let otherMarketStory = RepositoryFixture.story(
            "2026-11-23",
            market: .enUS,
            imageID: nil,
            id: "story-other-market"
        )
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [otherMarketStory]
        ) == .unmatched(.marketMismatch(candidateMarket: .enUS)))

        let unavailableStory = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-unavailable",
            availability: .unavailable(.notProvidedBySource)
        )
        if case let .unavailable(story) = StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [unavailableStory]
        ) {
            #expect(story.id == unavailableStory.id)
        } else {
            Issue.record("Expected an unavailable identity-backed story")
        }

        let duplicateIdentityA = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-duplicate-a"
        )
        let duplicateIdentityB = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-duplicate-b"
        )
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [duplicateIdentityA, duplicateIdentityB]
        ) == .unmatched(.ambiguousCandidates(count: 2)))
    }

    @Test func storyRevisionsVersionByIdentityAndFetchedAt() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let old = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-old",
            body: "Old revision body.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let new = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-new",
            body: "New revision body.",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertStories([old])
        let update = try await repository.upsertStories([new])
        #expect(update.updated == 1)

        let stale = try await repository.upsertStories([old])
        #expect(stale.ignored == 1)

        let snapshot = await repository.snapshot()
        #expect(snapshot.stories.count == 1)
        #expect(snapshot.stories.first?.id == new.id)
        #expect(snapshot.stories.first?.body == "New revision body.")

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let match = StoryMatcher.match(occurrence: occurrence, stories: [old, new])
        if case let .matched(matched, evidence) = match {
            #expect(matched.id == new.id)
            #expect(evidence == .imageIdentityMarketAndDate)
        } else {
            Issue.record("Expected newest story revision to match")
        }
    }

    @Test func sameTimeDifferentStoryContentIsAConflict() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-first",
            body: "First content.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let conflicting = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-conflict",
            body: "Different content.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertStories([first])

        do {
            _ = try await repository.upsertStories([conflicting])
            Issue.record("Expected same-time story content conflict")
        } catch let error as RepositoryError {
            #expect(error == .storyConflict("story-conflict"))
        }

        let snapshot = await repository.snapshot()
        #expect(snapshot.stories.map(\.id) == ["story-first"])

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            stories: [first, conflicting]
        ) == .unmatched(.ambiguousCandidates(count: 2)))
    }

    @Test func sameTimeSameStoryContentCollapsesDeterministically() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-a",
            body: "Identical content.",
            fetchedAt: RepositoryFixture.fetchedAt,
            contentHash: "same-content-hash"
        )
        let second = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-b",
            body: "Identical content.",
            fetchedAt: RepositoryFixture.fetchedAt,
            contentHash: "same-content-hash"
        )
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertStories([first])
        let duplicate = try await repository.upsertStories([second])
        #expect(duplicate.unchanged == 1)

        let snapshot = await repository.snapshot()
        #expect(snapshot.stories.map(\.id) == ["story-a"])

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        if case let .matched(matched, _) = StoryMatcher.match(
            occurrence: occurrence,
            stories: [first, second]
        ) {
            #expect(matched.id == "story-a")
        } else {
            Issue.record("Expected deterministic duplicate collapse")
        }
    }

    @Test func storyRevisionDoesNotOverwriteDifferentImageIdentity() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let aOld = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-a-old",
            body: "Old A body.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let aNew = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-a-new",
            body: "New A body.",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let bStory = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-B",
            id: "story-b",
            body: "B body.",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(5)
        )
        let repository = try WallpaperRepository(directory: directory)

        try await repository.upsertStories([aOld, bStory])
        try await repository.upsertStories([aNew])

        let snapshot = await repository.snapshot()
        #expect(snapshot.stories.count == 2)
        #expect(Set(snapshot.stories.map(\.id)) == Set(["story-a-new", "story-b"]))

        let occurrenceA = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        if case let .matched(matched, _) = StoryMatcher.match(
            occurrence: occurrenceA,
            stories: snapshot.stories
        ) {
            #expect(matched.id == "story-a-new")
        } else {
            Issue.record("Expected image-A revision match")
        }

        let occurrenceB = RepositoryFixture.occurrence("2026-11-23", imageID: "image-B")
        if case let .matched(matched, _) = StoryMatcher.match(
            occurrence: occurrenceB,
            stories: snapshot.stories
        ) {
            #expect(matched.id == "story-b")
        } else {
            Issue.record("Expected image-B story to remain independent")
        }
    }

    @Test func persistedDuplicateStoryRevisionsCollapseOnLoad() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let current = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-current",
            body: "Current persisted body.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([occurrence])
        try await repository.upsertStories([current])

        let indexURL = directory.appendingPathComponent("repository.json")
        let indexData = try Data(contentsOf: indexURL)
        let rawObject = try JSONSerialization.jsonObject(with: indexData)
        var object = try #require(rawObject as? [String: Any])
        var stories = try #require(object["stories"] as? [[String: Any]])
        #expect(stories.count == 1)

        var older = stories[0]
        older["id"] = "story-superseded"
        older["body"] = "Superseded persisted body."
        older["fetchedAt"] = RepositoryFixture.fetchedAt
            .addingTimeInterval(-10)
            .timeIntervalSinceReferenceDate
        stories.append(older)
        object["stories"] = stories
        let updatedData = try JSONSerialization.data(withJSONObject: object)
        try updatedData.write(to: indexURL, options: .atomic)

        let reopened = try WallpaperRepository(directory: directory)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.stories.count == 1)
        #expect(snapshot.stories.first?.id == "story-current")
        #expect(snapshot.stories.first?.body == "Current persisted body.")
    }

    @Test func persistedSameTimeStoryConflictIsPreserved() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let current = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-current",
            body: "Current persisted body.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([occurrence])
        try await repository.upsertStories([current])

        let indexURL = directory.appendingPathComponent("repository.json")
        let indexData = try Data(contentsOf: indexURL)
        let rawObject = try JSONSerialization.jsonObject(with: indexData)
        var object = try #require(rawObject as? [String: Any])
        var stories = try #require(object["stories"] as? [[String: Any]])
        #expect(stories.count == 1)

        var conflict = stories[0]
        conflict["id"] = "story-conflict"
        conflict["body"] = "Conflicting persisted body."
        conflict["contentHash"] = "conflicting-content-hash"
        // Deliberately same fetchedAt: this is a genuine same-time conflict.
        stories.append(conflict)
        object["stories"] = stories
        let updatedData = try JSONSerialization.data(withJSONObject: object)
        try updatedData.write(to: indexURL, options: .atomic)

        let reopened = try WallpaperRepository(directory: directory)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.stories.count == 2)
        #expect(Set(snapshot.stories.map(\.id)) == Set(["story-current", "story-conflict"]))
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            stories: snapshot.stories
        ) == .unmatched(.ambiguousCandidates(count: 2)))

        let third = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-third",
            body: "Third content.",
            fetchedAt: RepositoryFixture.fetchedAt,
            contentHash: "third-content-hash"
        )
        do {
            _ = try await reopened.upsertStories([third])
            Issue.record("Expected persisted same-time conflict to reject another peer")
        } catch let error as RepositoryError {
            #expect(error == .storyConflict("story-third"))
        }

        let resolved = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: "story-resolved",
            body: "Resolved content.",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        let resolution = try await reopened.upsertStories([resolved])
        #expect(resolution.updated == 1)
        let afterResolution = await reopened.snapshot()
        #expect(afterResolution.stories.map(\.id) == ["story-resolved"])
    }

    @Test func legacySameTimeStoryConflictIsPreserved() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let first = LegacyStory(
            id: "legacy-conflict-a",
            source: .bing,
            market: .zhCN,
            date: occurrence.localDate,
            associatedWallpaperID: occurrence.wallpaperID,
            headline: "Legacy conflict headline",
            body: "Legacy conflict A.",
            quickFact: nil,
            originalLocale: "zh-CN",
            sourceURL: URL(string: "https://example.invalid/legacy-conflict"),
            fetchedAt: RepositoryFixture.fetchedAt,
            contentHash: "legacy-conflict-a-hash",
            availability: .available
        )
        let second = LegacyStory(
            id: "legacy-conflict-b",
            source: .bing,
            market: .zhCN,
            date: occurrence.localDate,
            associatedWallpaperID: occurrence.wallpaperID,
            headline: "Legacy conflict headline",
            body: "Legacy conflict B.",
            quickFact: nil,
            originalLocale: "zh-CN",
            sourceURL: URL(string: "https://example.invalid/legacy-conflict"),
            fetchedAt: RepositoryFixture.fetchedAt,
            contentHash: "legacy-conflict-b-hash",
            availability: .available
        )

        let encoder = JSONEncoder()
        try encoder.encode([occurrence]).write(
            to: directory.appendingPathComponent("occurrences.json"),
            options: .atomic
        )
        try encoder.encode([first, second]).write(
            to: directory.appendingPathComponent("stories.json"),
            options: .atomic
        )

        let repository = try WallpaperRepository(directory: directory)
        let snapshot = await repository.snapshot()
        #expect(snapshot.loadState == .migratedLegacyCache)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("repository.json").path
        ))
        #expect(snapshot.stories.count == 2)
        #expect(Set(snapshot.stories.map(\.id)) == Set(["legacy-conflict-a", "legacy-conflict-b"]))
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            stories: snapshot.stories
        ) == .unmatched(.ambiguousCandidates(count: 2)))
    }

    @Test func unboundStoryURLRevisionsResolveToNewest() {
        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let metadata = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let old = RepositoryFixture.story(
            "2026-11-23",
            imageID: nil,
            id: "url-old",
            body: "Old URL body.",
            fetchedAt: RepositoryFixture.fetchedAt
        )
        let new = RepositoryFixture.story(
            "2026-11-23",
            imageID: nil,
            id: "url-new",
            body: "New URL body.",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )

        if case let .matched(matched, evidence) = StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [old, new]
        ) {
            #expect(matched.id == new.id)
            #expect(evidence == .sourceURLCorroboration)
        } else {
            Issue.record("Expected newest URL-backed revision to match")
        }

        let conflict = RepositoryFixture.story(
            "2026-11-23",
            imageID: nil,
            id: "url-conflict",
            body: "Conflicting URL body.",
            fetchedAt: RepositoryFixture.fetchedAt.addingTimeInterval(10)
        )
        #expect(StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata,
            stories: [new, conflict]
        ) == .unmatched(.ambiguousCandidates(count: 2)))
    }

    // MARK: - Durable sync journal and controlled import

    @Test func favoriteAndPinChangesAreJournaledAcrossRestart() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let favorite = RepositoryFixture.image("image-A")
        let pinImage = RepositoryFixture.image("image-B")
        let pinKey = OccurrenceKey(
            source: .bing,
            market: .zhCN,
            localDate: RepositoryFixture.date("2026-11-23")
        )
        let repository = try WallpaperRepository(
            directory: directory,
            now: { RepositoryFixture.fixedNow }
        )

        let first = try await repository.setFavorite(favorite, isFavorite: true)
        let duplicate = try await repository.setFavorite(favorite, isFavorite: true)
        let removal = try await repository.setFavorite(favorite, isFavorite: false)
        let pinned = try await repository.setPinned(
            pinKey,
            wallpaperID: pinImage,
            isPinned: true
        )
        let unpinned = try await repository.setPinned(
            pinKey,
            wallpaperID: pinImage,
            isPinned: false
        )
        #expect(first)
        #expect(!duplicate)
        #expect(removal)
        #expect(pinned)
        #expect(unpinned)

        let deviceID = try await repository.syncDeviceIdentifier()
        let operations = await repository.pendingSyncOperations()
        #expect(operations.count == 4)
        #expect(operations.map(\.sequence) == [1, 2, 3, 4])
        #expect(operations.allSatisfy { $0.deviceID == deviceID })
        #expect(operations.allSatisfy {
            $0.context.counter(for: deviceID) == $0.sequence
        })

        if case .favorite(let change) = operations[0].payload {
            #expect(change.wallpaperID == favorite)
            #expect(change.isFavorite)
        } else {
            Issue.record("Expected a favorite-add operation first")
        }
        if case .favorite(let change) = operations[1].payload {
            #expect(change.wallpaperID == favorite)
            #expect(!change.isFavorite)
        } else {
            Issue.record("Expected a favorite-remove tombstone second")
        }
        if case .pin(let change) = operations[2].payload {
            #expect(change.key == pinKey)
            #expect(change.wallpaperID == pinImage)
            #expect(change.isPinned)
        } else {
            Issue.record("Expected a pin-add operation third")
        }
        if case .pin(let change) = operations[3].payload {
            #expect(change.key == pinKey)
            #expect(change.wallpaperID == nil)
            #expect(!change.isPinned)
        } else {
            Issue.record("Expected a pin-remove tombstone fourth")
        }

        // Atomic durability: the preference state and its journal entries are
        // in the same file, so a reopen sees both or neither.
        let reopened = try WallpaperRepository(directory: directory)
        let reopenedDevice = try await reopened.syncDeviceIdentifier()
        let reopenedOperations = await reopened.pendingSyncOperations()
        let snapshot = await reopened.snapshot()
        #expect(reopenedDevice == deviceID)
        #expect(reopenedOperations == operations)
        #expect(snapshot.favoriteWallpaperIDs.isEmpty)
        #expect(snapshot.pinnedOccurrences.isEmpty)
    }

    @Test func legacyVersionTwoIndexBootstrapsOnceWithoutRevivingRemovals() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let favorite = RepositoryFixture.image("image-A")
        let pinImage = RepositoryFixture.image("image-B")
        let pinKey = OccurrenceKey(
            source: .bing,
            market: .zhCN,
            localDate: RepositoryFixture.date("2026-11-23")
        )
        let legacy = LegacyRepositoryIndex(
            schemaVersion: 2,
            occurrences: [],
            metadata: [],
            wallpapers: [],
            stories: [],
            assets: [],
            favorites: [favorite],
            pinnedOccurrences: [
                PinnedOccurrence(key: pinKey, wallpaperID: pinImage)
            ],
            appliedWallpapers: []
        )
        try JSONEncoder().encode(legacy).write(
            to: directory.appendingPathComponent("repository.json"),
            options: .atomic
        )

        let repository = try WallpaperRepository(directory: directory)
        let before = await repository.snapshot()
        #expect(before.favoriteWallpaperIDs == Set([favorite]))
        #expect(before.pinnedOccurrences == Set([
            PinnedOccurrence(key: pinKey, wallpaperID: pinImage)
        ]))

        let bootstrap = try await repository.bootstrapSyncJournal()
        #expect(bootstrap.count == 2)
        #expect(bootstrap.allSatisfy { $0.context.counters.count == 1 })

        let second = try await repository.bootstrapSyncJournal()
        #expect(second.isEmpty)

        let indexData = try Data(
            contentsOf: directory.appendingPathComponent("repository.json")
        )
        let indexObject = try JSONSerialization.jsonObject(with: indexData)
        let index = try #require(indexObject as? [String: Any])
        #expect(index["schemaVersion"] as? Int == RepositorySchema.currentVersion)

        // A recorded removal is a tombstone: neither a second bootstrap nor a
        // restart may re-add the image.
        let removed = try await repository.setFavorite(favorite, isFavorite: false)
        #expect(removed)
        let third = try await repository.bootstrapSyncJournal()
        #expect(third.isEmpty)

        let reopened = try WallpaperRepository(directory: directory)
        let reopenedBootstrap = try await reopened.bootstrapSyncJournal()
        let reopenedOperations = await reopened.pendingSyncOperations()
        let reopenedSnapshot = await reopened.snapshot()
        #expect(reopenedBootstrap.isEmpty)
        #expect(reopenedOperations.count == 3)
        #expect(reopenedSnapshot.favoriteWallpaperIDs.isEmpty)
        #expect(reopenedSnapshot.pinnedOccurrences == before.pinnedOccurrences)

        let favoriteOperations = reopenedOperations.compactMap { operation -> (Bool, WallpaperID)? in
            guard case .favorite(let change) = operation.payload else { return nil }
            return (change.isFavorite, change.wallpaperID)
        }
        #expect(favoriteOperations.count == 2)
        #expect(favoriteOperations.contains { $0.0 && $0.1 == favorite })
        #expect(favoriteOperations.contains { !$0.0 && $0.1 == favorite })
    }

    @Test func bootstrapUsesLocalSequenceContextAndLaterActionsSeeRemoteFrontier() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let favorite = RepositoryFixture.image("image-A")
        let laterFavorite = RepositoryFixture.image("image-B")
        let remoteDevice = try #require(SyncDeviceID("remote-device"))
        let remoteContext = try SyncVersionVector([remoteDevice: 7])

        let legacy = LegacyRepositoryIndex(
            schemaVersion: 2,
            occurrences: [],
            metadata: [],
            wallpapers: [],
            stories: [],
            assets: [],
            favorites: [favorite],
            pinnedOccurrences: [],
            appliedWallpapers: []
        )
        try JSONEncoder().encode(legacy).write(
            to: directory.appendingPathComponent("repository.json"),
            options: .atomic
        )

        let repository = try WallpaperRepository(directory: directory)
        _ = try await repository.applyRemoteSyncChanges(observedContext: remoteContext)
        let localDevice = try await repository.syncDeviceIdentifier()
        let bootstrap = try await repository.bootstrapSyncJournal()
        let bootstrapOperation = try #require(bootstrap.first)
        #expect(bootstrapOperation.context.counter(for: localDevice) == 1)
        #expect(bootstrapOperation.context.counter(for: remoteDevice) == 0)
        #expect(bootstrapOperation.context.counters.count == 1)

        _ = try await repository.setFavorite(laterFavorite, isFavorite: true)
        let operations = await repository.pendingSyncOperations()
        let laterOperation = try #require(operations.last)
        #expect(laterOperation.context.counter(for: remoteDevice) == 7)
        #expect(laterOperation.context.counter(for: localDevice) == 2)
    }

    @Test func versionOneFormalIndexLoadsAndMigratesWithoutAppliedHistory() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let occurrence = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let legacy = LegacyRepositoryIndex(
            schemaVersion: 1,
            occurrences: [occurrence],
            metadata: [],
            wallpapers: [],
            stories: [],
            assets: [],
            favorites: [occurrence.wallpaperID],
            pinnedOccurrences: [],
            appliedWallpapers: [occurrence.wallpaperID]
        )
        try JSONEncoder().encode(legacy).write(
            to: directory.appendingPathComponent("repository.json"),
            options: .atomic
        )

        let repository = try WallpaperRepository(directory: directory)
        let snapshot = await repository.snapshot()
        #expect(snapshot.loadState == .loaded)
        #expect(snapshot.schemaVersion == RepositorySchema.currentVersion)
        #expect(snapshot.occurrences == [occurrence])
        #expect(snapshot.favoriteWallpaperIDs == Set([occurrence.wallpaperID]))
        // Version 1's historical applied set is never protection after load.
        #expect(snapshot.appliedWallpapers.isEmpty)

        let bootstrap = try await repository.bootstrapSyncJournal()
        #expect(bootstrap.count == 1)
        let reopened = try WallpaperRepository(directory: directory)
        let reopenedOperations = await reopened.pendingSyncOperations()
        #expect(reopenedOperations.count == 1)
        let indexData = try Data(
            contentsOf: directory.appendingPathComponent("repository.json")
        )
        let indexObject = try JSONSerialization.jsonObject(with: indexData)
        let index = try #require(indexObject as? [String: Any])
        #expect(index["schemaVersion"] as? Int == RepositorySchema.currentVersion)
    }

    @Test func importedHistoricalOccurrenceExpandsObservationRangeWithoutCompleteCoverage() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let recent = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let historical = RepositoryFixture.occurrence("2026-11-20", imageID: "image-B")
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([recent])

        let before = await repository.snapshot()
        #expect(before.firstObservedDate == recent.localDate)

        let result = try await repository.applyRemoteSyncChanges(
            occurrences: [historical]
        )
        #expect(result.occurrences.inserted == 1)
        #expect(result.journalEntriesCreated == 0)

        let snapshot = await repository.snapshot()
        #expect(snapshot.occurrences.count == 2)
        #expect(snapshot.firstObservedDate == historical.localDate)

        let range = try #require(LocalDateRange(
            start: historical.localDate,
            end: recent.localDate
        ))
        let summary = RecapBuilder.summary(
            occurrences: snapshot.occurrences,
            range: range,
            asOf: recent.localDate,
            firstObservedDate: snapshot.firstObservedDate
        )
        #expect(summary.eligibleDays == 4)
        #expect(summary.observedDays == 2)
        #expect(summary.coverageState == .partial)
    }

    @Test func remoteImportMergesContentAndPreferencesWithoutLocalEcho() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let imageA = RepositoryFixture.image("image-A")
        let imageB = RepositoryFixture.image("image-B")
        let occurrenceA = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A")
        let metadataA = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let storyA = RepositoryFixture.story("2026-11-23", imageID: "image-A")
        let pinA = PinnedOccurrence(key: occurrenceA.id, wallpaperID: imageA)

        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([occurrenceA])
        try await repository.upsertMetadata([metadataA])
        try await repository.upsertStories([storyA])
        _ = try await repository.setFavorite(imageA, isFavorite: true)
        _ = try await repository.setPinned(
            occurrenceA.id,
            wallpaperID: imageA,
            isPinned: true
        )
        _ = try await repository.replaceAppliedWallpapers(Set([imageA]))
        let asset = try await repository.storeAsset(
            Data("synthetic-image-a".utf8),
            kind: .original,
            for: imageA,
            fileExtension: "jpg"
        )
        let assetURLOptional = await repository.assetURL(for: asset)
        let assetURL = try #require(assetURLOptional)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))

        let pendingBefore = await repository.pendingSyncOperations()
        let snapshotBefore = await repository.snapshot()
        #expect(pendingBefore.count == 2)

        let occurrenceB = RepositoryFixture.occurrence("2026-11-24", imageID: "image-B")
        let metadataB = RepositoryFixture.metadata("2026-11-24", imageID: "image-B")
        let storyB = RepositoryFixture.story("2026-11-24", imageID: "image-B")
        let wallpaperB = RepositoryFixture.wallpaper("image-B")
        let pinB = PinnedOccurrence(key: occurrenceB.id, wallpaperID: imageB)
        let remoteDevice = try #require(SyncDeviceID("remote-device"))
        let remoteContext = try SyncVersionVector([remoteDevice: 5])

        let result = try await repository.applyRemoteSyncChanges(
            occurrences: [occurrenceB],
            metadata: [metadataB],
            wallpapers: [wallpaperB],
            stories: [storyB],
            favoritesToAdd: [imageB],
            favoritesToRemove: [imageA],
            pinsToAdd: [pinB],
            pinKeysToRemove: [pinA.key],
            observedContext: remoteContext,
            nextLocalSequence: 9
        )
        #expect(result.occurrences.inserted == 1)
        #expect(result.metadata.inserted == 1)
        #expect(result.wallpapers.inserted == 1)
        #expect(result.stories.inserted == 1)
        #expect(result.favoritesAdded == 1)
        #expect(result.favoritesRemoved == 1)
        #expect(result.pinsAdded == 1)
        #expect(result.pinsRemoved == 1)
        #expect(result.rejectedRecords == 0)
        #expect(result.journalEntriesCreated == 0)

        let snapshot = await repository.snapshot()
        let pendingAfter = await repository.pendingSyncOperations()
        let nextSequence = await repository.syncNextLocalSequence()
        let causalContext = await repository.syncCausalContext()
        let deviceID = try await repository.syncDeviceIdentifier()
        #expect(snapshot.favoriteWallpaperIDs == Set([imageB]))
        #expect(snapshot.pinnedOccurrences == Set([pinB]))
        #expect(snapshot.appliedWallpapers == Set([imageA]))
        #expect(snapshot.asset(kind: .original, for: imageA) != nil)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))
        #expect(snapshot.occurrences.count == 2)
        #expect(snapshot.metadata.count == 2)
        #expect(snapshot.wallpapers.map(\.id) == [imageB])
        #expect(snapshot.stories.count == 2)
        #expect(pendingAfter == pendingBefore)
        #expect(nextSequence == 9)
        #expect(causalContext.counter(for: remoteDevice) == 5)
        #expect(causalContext.counter(for: deviceID) == 2)

        // Replaying the same resolved import must be a no-op and must never
        // create a local outgoing change.
        let replay = try await repository.applyRemoteSyncChanges(
            occurrences: [occurrenceB],
            metadata: [metadataB],
            wallpapers: [wallpaperB],
            stories: [storyB],
            favoritesToAdd: [imageB],
            favoritesToRemove: [imageA],
            pinsToAdd: [pinB],
            pinKeysToRemove: [pinA.key],
            observedContext: remoteContext,
            nextLocalSequence: 9
        )
        #expect(replay.occurrences == UpsertSummary(unchanged: 1))
        #expect(replay.metadata == UpsertSummary(unchanged: 1))
        #expect(replay.wallpapers == UpsertSummary(unchanged: 1))
        #expect(replay.stories == UpsertSummary(unchanged: 1))
        #expect(replay.favoritesAdded == 0)
        #expect(replay.favoritesRemoved == 0)
        #expect(replay.pinsAdded == 0)
        #expect(replay.pinsRemoved == 0)
        #expect(replay.journalEntriesCreated == 0)
        let snapshotAfterReplay = await repository.snapshot()
        let pendingAfterReplay = await repository.pendingSyncOperations()
        #expect(snapshotAfterReplay == snapshot)
        #expect(pendingAfterReplay == pendingBefore)
        #expect(snapshotBefore != snapshotAfterReplay)
    }

    @Test func remoteImportRejectsConflictsWithoutDamagingLocalState() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let imageA = RepositoryFixture.image("image-A")
        let imageB = RepositoryFixture.image("image-B")
        let occurrenceA = RepositoryFixture.occurrence(
            "2026-11-23",
            imageID: "image-A",
            revision: 1
        )
        let metadataA = RepositoryFixture.metadata("2026-11-23", imageID: "image-A")
        let storyA = RepositoryFixture.story("2026-11-23", imageID: "image-A")

        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([occurrenceA])
        try await repository.upsertMetadata([metadataA])
        try await repository.upsertStories([storyA])
        _ = try await repository.setFavorite(imageA, isFavorite: true)
        _ = try await repository.setPinned(
            occurrenceA.id,
            wallpaperID: imageA,
            isPinned: true
        )
        _ = try await repository.replaceAppliedWallpapers(Set([imageA]))

        let before = await repository.snapshot()
        let pendingBefore = await repository.pendingSyncOperations()

        let conflictingOccurrence = RepositoryFixture.occurrence(
            "2026-11-23",
            imageID: "image-B",
            revision: 1
        )
        let conflictingMetadata = RepositoryFixture.metadata(
            "2026-11-23",
            imageID: "image-B"
        )
        let conflictingStory = RepositoryFixture.story(
            "2026-11-23",
            imageID: "image-A",
            id: storyA.id,
            body: "Different synthetic body at the same fetch time."
        )
        let invalidFavorite = WallpaperID(source: .bing, sourceImageID: "")

        // A pin for this date is not a conflict: it names the date and is
        // rebound to the local occurrence image. See
        // `RepositoryPinRebindingTests.importedPinRebindsToTheLocalOccurrenceImage`.
        let result = try await repository.applyRemoteSyncChanges(
            occurrences: [conflictingOccurrence],
            metadata: [conflictingMetadata],
            stories: [conflictingStory],
            favoritesToAdd: [invalidFavorite]
        )

        #expect(result.occurrences == UpsertSummary())
        #expect(result.metadata == UpsertSummary())
        #expect(result.stories == UpsertSummary())
        #expect(result.favoritesAdded == 0)
        #expect(result.pinsAdded == 0)
        #expect(result.rejectedRecords == 4)

        let after = await repository.snapshot()
        let pendingAfter = await repository.pendingSyncOperations()
        #expect(after == before)
        #expect(after.appliedWallpapers == Set([imageA]))
        #expect(pendingAfter == pendingBefore)
    }

    @Test func localCleanupDoesNotCreateCloudDeletes() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let favorite = RepositoryFixture.image("image-A")
        let removedAssetImage = RepositoryFixture.image("image-B")
        let evictedAssetImage = RepositoryFixture.image("image-C")
        let repository = try WallpaperRepository(directory: directory)

        _ = try await repository.setFavorite(favorite, isFavorite: true)
        _ = try await repository.storeAsset(
            Data(repeating: 1, count: 10),
            kind: .original,
            for: removedAssetImage,
            fileExtension: "jpg",
            accessedAt: Date(timeIntervalSince1970: 100)
        )
        _ = try await repository.storeAsset(
            Data(repeating: 2, count: 10),
            kind: .original,
            for: evictedAssetImage,
            fileExtension: "jpg",
            accessedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try await repository.upsertStories([
            RepositoryFixture.story("2026-11-23", imageID: "image-A")
        ])

        let pendingBefore = await repository.pendingSyncOperations()
        try await repository.removeAsset(kind: .original, for: removedAssetImage)
        _ = try await repository.evictLeastRecentlyUsed(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 5)
        )
        _ = try await repository.clearStories()
        let pendingAfter = await repository.pendingSyncOperations()

        #expect(pendingAfter == pendingBefore)
        #expect(pendingAfter.count == 1)
        let snapshot = await repository.snapshot()
        #expect(snapshot.favoriteWallpaperIDs == Set([favorite]))
        #expect(snapshot.stories.isEmpty)
    }

    @Test func remoteAssetImportVerifiesDigestAndPreservesLeases() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let image = RepositoryFixture.image("image-A")
        let data = Data("synthetic-remote-asset".utf8)
        let reference = SyncAssetReference(
            wallpaperID: image,
            kind: .original,
            contentSHA256: SyncContentDigest.hashing(data),
            byteCount: data.count
        )
        let repository = try WallpaperRepository(directory: directory)

        let imported = try await repository.importSyncAsset(
            data,
            reference: reference,
            fileExtension: "jpg"
        )
        #expect(imported.wallpaperID == image)
        #expect(imported.kind == .original)
        #expect(imported.byteCount == data.count)

        let exportedOptional = try await repository.syncAssetReference(
            kind: .original,
            for: image
        )
        let exported = try #require(exportedOptional)
        #expect(exported == reference)

        // Identical content is idempotent and keeps the existing file path.
        let again = try await repository.importSyncAsset(
            data,
            reference: reference,
            fileExtension: "jpg"
        )
        #expect(again.relativePath == imported.relativePath)

        // Bytes that do not match the declared digest are rejected.
        let bogus = SyncAssetReference(
            wallpaperID: image,
            kind: .original,
            contentSHA256: SyncContentDigest.hashing(Data("other".utf8)),
            byteCount: data.count
        )
        do {
            _ = try await repository.importSyncAsset(
                data,
                reference: bogus,
                fileExtension: "jpg"
            )
            Issue.record("Expected a digest mismatch")
        } catch let error as RepositoryError {
            if case .invalidRecord = error {
                // Expected.
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }

        // An applied image has a live lease: different bytes must not replace
        // the exact file the system wallpaper may be reading.
        _ = try await repository.replaceAppliedWallpapers(Set([image]))
        let replacementData = Data("different-remote-asset".utf8)
        let replacement = SyncAssetReference(
            wallpaperID: image,
            kind: .original,
            contentSHA256: SyncContentDigest.hashing(replacementData),
            byteCount: replacementData.count
        )
        do {
            _ = try await repository.importSyncAsset(
                replacementData,
                reference: replacement,
                fileExtension: "jpg"
            )
            Issue.record("Expected a protected asset error")
        } catch let error as RepositoryError {
            #expect(error == .protectedAsset(image))
        }

        let assetURLOptional = await repository.assetURL(kind: .original, for: image)
        let assetURL = try #require(assetURLOptional)
        let storedData = try Data(contentsOf: assetURL)
        #expect(storedData == data)
    }

    @Test func publishAcknowledgementKeepsTombstonesAndSequenceMonotonic() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let imageA = RepositoryFixture.image("image-A")
        let imageB = RepositoryFixture.image("image-B")
        let repository = try WallpaperRepository(directory: directory)

        _ = try await repository.setFavorite(imageA, isFavorite: true)
        _ = try await repository.setFavorite(imageB, isFavorite: true)
        _ = try await repository.setFavorite(imageA, isFavorite: false)

        let published = try await repository.acknowledgeSyncOperationsPublished(through: 2)
        #expect(published == 2)
        let remaining = await repository.pendingSyncOperations()
        #expect(remaining.map(\.sequence) == [3])
        let repeated = try await repository.acknowledgeSyncOperationsPublished(through: 2)
        #expect(repeated == 0)
        let allOperations = await repository.syncLocalOperations()
        #expect(allOperations.count == 3)

        let last = try await repository.acknowledgeSyncOperationsPublished(through: 3)
        #expect(last == 1)
        let empty = await repository.pendingSyncOperations()
        #expect(empty.isEmpty)

        let reopened = try WallpaperRepository(directory: directory)
        let reopenedOperations = await reopened.syncLocalOperations()
        let reopenedPending = await reopened.pendingSyncOperations()
        let reopenedCursor = await reopened.syncPublishedThroughSequence()
        #expect(reopenedOperations.count == 3)
        #expect(reopenedPending.isEmpty)
        #expect(reopenedCursor == 3)

        _ = try await reopened.setFavorite(imageB, isFavorite: false)
        let afterUnfavorite = await reopened.pendingSyncOperations()
        let unfavorite = try #require(afterUnfavorite.first)
        #expect(unfavorite.sequence == 4)
        if case .favorite(let change) = unfavorite.payload {
            #expect(change.wallpaperID == imageB)
            #expect(!change.isFavorite)
        } else {
            Issue.record("Expected the unfavorite tombstone after publishing")
        }
    }

    @Test func mergePlanPersistsBootstrapOperationsInTheJournal() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let favorite = RepositoryFixture.image("image-A")
        let pinImage = RepositoryFixture.image("image-B")
        let pinKey = OccurrenceKey(
            source: .bing,
            market: .zhCN,
            localDate: RepositoryFixture.date("2026-11-23")
        )
        // A version 2 repository whose favorites/pins predate the journal, so
        // the planner's one-time bootstrap owns those payloads.
        let legacy = LegacyRepositoryIndex(
            schemaVersion: 2,
            occurrences: [],
            metadata: [],
            wallpapers: [],
            stories: [],
            assets: [],
            favorites: [favorite],
            pinnedOccurrences: [
                PinnedOccurrence(key: pinKey, wallpaperID: pinImage)
            ],
            appliedWallpapers: []
        )
        try JSONEncoder().encode(legacy).write(
            to: directory.appendingPathComponent("repository.json"),
            options: .atomic
        )
        let repository = try WallpaperRepository(directory: directory)

        let snapshot = await repository.snapshot()
        let deviceID = try await repository.syncDeviceIdentifier()
        let nextSequence = await repository.syncNextLocalSequence()
        let input = SyncReconciliationInput(
            deviceID: deviceID,
            local: SyncLocalSnapshot(
                favorites: snapshot.favoriteWallpaperIDs,
                pinnedOccurrences: snapshot.pinnedOccurrences,
                occurrences: snapshot.occurrences,
                metadata: snapshot.metadata,
                wallpapers: snapshot.wallpapers,
                stories: snapshot.stories
            ),
            nextLocalSequence: nextSequence,
            bootstrapLocalState: true
        )
        let plan = try SyncMergePlanner.plan(input: input, remoteOperations: [])
        #expect(plan.bootstrapOperations.count == 2)
        #expect(plan.nextLocalSequence == 3)

        let result = try await repository.applySyncMergePlan(plan)
        #expect(result.journalEntriesCreated == 0)
        let pending = await repository.pendingSyncOperations()
        let appliedSequence = await repository.syncNextLocalSequence()
        let context = await repository.syncCausalContext()
        #expect(pending == plan.bootstrapOperations)
        #expect(appliedSequence == 3)
        #expect(context.counter(for: deviceID) == 2)

        // The bootstrap path is now recorded, so the preference-only fallback
        // must not duplicate it.
        let fallback = try await repository.bootstrapSyncJournal()
        #expect(fallback.isEmpty)

        _ = try await repository.setFavorite(
            RepositoryFixture.image("image-C"),
            isFavorite: true
        )
        let operations = await repository.pendingSyncOperations()
        let lastOperation = try #require(operations.last)
        #expect(lastOperation.sequence == 3)
        #expect(lastOperation.context.counter(for: deviceID) == 3)
    }
}

/// A pin names a date, not a pixel revision. When the local occurrence for
/// that date moved to a newer image, importing the archive's pin-time image
/// must rebind the pin instead of rejecting it forever.
struct RepositoryPinRebindingTests {
    @Test func importedPinRebindsToTheLocalOccurrenceImage() async throws {
        let directory = try RepositoryFixture.makeDirectory()
        defer { RepositoryFixture.remove(directory) }

        let first = RepositoryFixture.occurrence("2026-11-23", imageID: "image-A", revision: 0)
        let second = RepositoryFixture.occurrence("2026-11-23", imageID: "image-B", revision: 1)
        let repository = try WallpaperRepository(directory: directory)
        try await repository.upsertOccurrences([second])

        let result = try await repository.applyRemoteSyncChanges(
            pinsToAdd: [
                PinnedOccurrence(key: first.id, wallpaperID: first.wallpaperID)
            ]
        )
        #expect(result.rejectedRecords == 0)
        #expect(result.pinsAdded == 1)

        let snapshot = await repository.snapshot()
        #expect(snapshot.pinnedOccurrences == Set([
            PinnedOccurrence(key: second.id, wallpaperID: second.wallpaperID)
        ]))
        let replay = try await repository.applyRemoteSyncChanges(
            pinsToAdd: [
                PinnedOccurrence(key: first.id, wallpaperID: first.wallpaperID)
            ]
        )
        #expect(replay.pinsAdded == 0)
        #expect(replay.rejectedRecords == 0)
    }
}
