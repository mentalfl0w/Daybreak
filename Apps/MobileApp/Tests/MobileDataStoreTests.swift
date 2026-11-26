import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Mobile data store")
struct MobileDataStoreTests {
    @Test("refresh persists the archive, joins the story and backfills thumbnails")
    func refreshPersistsArchiveStoryAndThumbnails() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Refresh")
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

        #expect(today.market == .zhCN)
        #expect(today.sourceDate == MobileSyntheticFixture.date("2026-11-24"))
        #expect(today.wallpaperID == MobileSyntheticFixture.owlID)
        #expect(today.hasThumbnail)
        #expect(!today.hasOriginal)
        #expect(today.storyMatch?.isMatched == true)
        #expect(
            today.storyMatch?.availableStory?.headline
                == "Synthetic owl story headline"
        )

        let snapshot = try await store.repositorySnapshot()
        #expect(snapshot.occurrences.count == 2)
        #expect(snapshot.stories.count == 1)
        #expect(
            snapshot.availableThumbnailIDs
                == Set([MobileSyntheticFixture.fernID, MobileSyntheticFixture.owlID])
        )
        #expect(snapshot.missingAssets.isEmpty)

        let cached = try await store.cachedTodaySnapshot(market: .zhCN)
        #expect(cached?.key == today.key)
        #expect(cached?.hasThumbnail == true)

        let counts = await transport.counts()
        #expect(counts.archive == 1)
        #expect(counts.stories == 1)
        #expect(counts.images == 2)
    }

    @Test("an original download is verified, recorded and reused")
    func originalDownloadIsVerifiedAndReused() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Original")
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

        let firstURL = try await store.ensureImage(
            kind: .original,
            for: today.occurrence,
            allowNetwork: true
        )
        let values = try firstURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        #expect(values.isRegularFile == true)
        #expect((values.fileSize ?? 0) > 0)

        let day = try await store.daySnapshot(for: today.key)
        #expect(day?.hasOriginal == true)
        #expect(day?.hasThumbnail == true)

        let firstCounts = await transport.counts()
        let secondURL = try await store.ensureImage(
            kind: .original,
            for: today.occurrence,
            allowNetwork: true
        )
        let secondCounts = await transport.counts()
        #expect(secondURL == firstURL)
        #expect(secondCounts.images == firstCounts.images)
    }

    @Test("offline and cancelled refreshes keep cached records")
    func failedRefreshesKeepCache() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Offline")
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
        let original = try await store.refreshToday(market: .zhCN)

        await transport.setMode(.failure)
        do {
            _ = try await store.refreshToday(market: .zhCN)
            Issue.record("Offline refresh unexpectedly succeeded")
        } catch let error as MobileStoreError {
            guard case .offline = error else {
                Issue.record("Expected an offline error, got \(error)")
                return
            }
        }

        let cached = try await store.cachedTodaySnapshot(market: .zhCN)
        #expect(cached?.key == original.key)
        #expect(cached?.hasThumbnail == true)

        await transport.setMode(.cancellation)
        do {
            _ = try await store.refreshToday(market: .zhCN)
            Issue.record("Cancelled refresh unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation is not converted into a data loss error.
        }

        let afterCancellation = try await store.cachedTodaySnapshot(market: .zhCN)
        #expect(afterCancellation?.key == original.key)
    }

    @Test("parallel original requests for one image share a single download")
    func concurrentOriginalRequestsAreCoalesced() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Coalesce")
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
        await transport.setImageDelay(.milliseconds(500))
        let before = await transport.counts()

        async let first = store.ensureImage(
            kind: .original,
            for: today.occurrence,
            allowNetwork: true
        )
        async let second = store.ensureImage(
            kind: .original,
            for: today.occurrence,
            allowNetwork: true
        )
        let urls = try await (first, second)
        let after = await transport.counts()

        #expect(urls.0 == urls.1)
        #expect(after.images == before.images + 1)
        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: today.wallpaperID
            ) == urls.0
        )
    }

    @Test("cancelling the sole waiter cancels the shared download")
    func cancellationCancelsSharedDownload() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("CancelDownload")
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
        await transport.setImageDelay(.milliseconds(500))

        let request = Task {
            try await store.ensureImage(
                kind: .original,
                for: today.occurrence,
                allowNetwork: true
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()

        do {
            _ = try await request.value
            Issue.record("Cancelled image request unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation is not hidden behind a successful file.
        }

        #expect(
            try await store.cachedImageURL(
                kind: .original,
                for: today.wallpaperID
            ) == nil
        )
    }
}
