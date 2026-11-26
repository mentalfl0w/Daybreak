import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Mobile cache policy")
struct MobileCachePolicyTests {
    @Test("favorites protect originals from explicit cleanup")
    func favoriteProtectsOriginal() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Policy")
        defer {
            environment.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }

        let transport = MobileSyntheticTransport(
            archive: MobileSyntheticFixture.archiveData,
            stories: MobileSyntheticFixture.storyData,
            image: MobileSyntheticFixture.syntheticPNG
        )
        let store = MobileSyntheticFixture.makeDataStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            selectionStore: environment.selectionStore,
            transport: transport
        )
        _ = try await store.refreshToday(market: .zhCN)
        let snapshot = try await store.repositorySnapshot()
        let fern = try #require(
            snapshot.occurrences.first {
                $0.wallpaperID == MobileSyntheticFixture.fernID
            }
        )
        let owl = try #require(
            snapshot.occurrences.first {
                $0.wallpaperID == MobileSyntheticFixture.owlID
            }
        )

        _ = try await store.ensureImage(kind: .original, for: fern, allowNetwork: true)
        _ = try await store.ensureImage(kind: .original, for: owl, allowNetwork: true)
        _ = try await store.setFavorite(MobileSyntheticFixture.owlID, isFavorite: true)

        let report = try await store.cacheReport()
        #expect(report.usage.assetCount == 4)
        #expect(report.protectedImageCountsByReason[.favorite] == 1)
        #expect(report.protectedThumbnailAssetCount == 1)
        #expect(report.protectedOriginalAssetCount == 1)

        let cleared = try await store.clearOriginals()
        #expect(cleared.removedAssetCount == 1)
        #expect(cleared.skippedProtectedCount == 1)
        #expect(cleared.failedCount == 0)
        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: MobileSyntheticFixture.fernID
            ) == nil
        )
        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: MobileSyntheticFixture.owlID
            ) != nil
        )
    }

    @Test("thumbnail cleanup leaves originals and story text independent")
    func thumbnailCleanupIndependence() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Thumbs")
        defer {
            environment.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }

        let transport = MobileSyntheticTransport(
            archive: MobileSyntheticFixture.archiveData,
            stories: MobileSyntheticFixture.storyData,
            image: MobileSyntheticFixture.syntheticPNG
        )
        let store = MobileSyntheticFixture.makeDataStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            selectionStore: environment.selectionStore,
            transport: transport
        )
        let today = try await store.refreshToday(market: .zhCN)
        _ = try await store.ensureImage(
            kind: .original,
            for: today.occurrence,
            allowNetwork: true
        )

        let cleared = try await store.clearThumbnails()
        #expect(cleared.removedAssetCount == 2)
        #expect(cleared.removedBytes > 0)
        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: today.wallpaperID
            ) != nil
        )
        #expect(
            try await store.cachedImageURL(
                kind: .thumbnail,
                for: today.wallpaperID
            ) == nil
        )

        let storiesRemoved = try await store.clearStories()
        #expect(storiesRemoved == 1)
        let after = try await store.repositorySnapshot()
        #expect(after.stories.isEmpty)
        #expect(after.occurrences.count == 2)
        #expect(after.metadata.count == 2)
        #expect(after.favoriteWallpaperIDs.isEmpty)
    }

    @Test("repair removes only orphans and keeps the process lease file")
    func repairKeepsLeaseAndProtection() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("RepairStore")
        defer {
            environment.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }

        let transport = MobileSyntheticTransport(
            archive: MobileSyntheticFixture.archiveData,
            stories: MobileSyntheticFixture.storyData,
            image: MobileSyntheticFixture.syntheticPNG
        )
        let store = MobileSyntheticFixture.makeDataStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            selectionStore: environment.selectionStore,
            transport: transport
        )
        let today = try await store.refreshToday(market: .zhCN)
        _ = try await store.setFavorite(today.wallpaperID, isFavorite: true)
        _ = try await store.ensureImage(
            kind: .original,
            for: today.occurrence,
            allowNetwork: true
        )

        let orphanDirectory = directory
            .appendingPathComponent("Assets/thumbnail", isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: true
        )
        let orphan = orphanDirectory.appendingPathComponent("orphan.png")
        try Data([0x01, 0x02, 0x03]).write(to: orphan)

        let report = try await store.repairCache()
        #expect(report.orphanedFilesRemoved.contains("Assets/thumbnail/orphan.png"))
        #expect(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent(MobileRepositoryLease.fileName)
                    .path
            )
        )

        let snapshot = try await store.repositorySnapshot()
        #expect(snapshot.favoriteWallpaperIDs.contains(today.wallpaperID))
        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: today.wallpaperID
            ) != nil
        )
    }

    @Test("capacity eviction never removes a favorite original")
    func evictionRespectsProtection() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Evict")
        defer {
            environment.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }

        let transport = MobileSyntheticTransport(
            archive: MobileSyntheticFixture.archiveData,
            stories: MobileSyntheticFixture.storyData,
            image: MobileSyntheticFixture.syntheticPNG
        )
        let store = MobileSyntheticFixture.makeDataStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            selectionStore: environment.selectionStore,
            transport: transport
        )
        _ = try await store.refreshToday(market: .zhCN)
        let snapshot = try await store.repositorySnapshot()
        let fern = try #require(
            snapshot.occurrences.first {
                $0.wallpaperID == MobileSyntheticFixture.fernID
            }
        )
        let owl = try #require(
            snapshot.occurrences.first {
                $0.wallpaperID == MobileSyntheticFixture.owlID
            }
        )

        _ = try await store.ensureImage(kind: .original, for: fern, allowNetwork: true)
        _ = try await store.ensureImage(kind: .original, for: owl, allowNetwork: true)
        _ = try await store.setFavorite(MobileSyntheticFixture.owlID, isFavorite: true)

        let result = try await store.evict(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 0)
        )
        #expect(result.evictedAssets.contains { $0.wallpaperID == MobileSyntheticFixture.fernID })
        #expect(!result.evictedAssets.contains { $0.wallpaperID == MobileSyntheticFixture.owlID })
        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: MobileSyntheticFixture.owlID
            ) != nil
        )
    }
}
