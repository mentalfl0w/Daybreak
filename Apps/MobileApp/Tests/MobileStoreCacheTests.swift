import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Mobile store cache settings")
struct MobileStoreCacheTests {
    @Test("capacity changes persist, evict and preserve favorite originals")
    @MainActor
    func capacityAppliesImmediately() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("StoreCapacity")
        defer {
            environment.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }

        var settings = MobileSettings()
        settings.marketPreference = .market(.zhCN)
        environment.settingsStore.save(settings)

        let transport = MobileSyntheticTransport(
            archive: MobileSyntheticFixture.archiveData,
            stories: MobileSyntheticFixture.storyData,
            image: MobileSyntheticFixture.syntheticPNG
        )
        let provider = MobileSyntheticFixture.makeProvider(transport: transport)
        let store = MobileStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            defaults: environment.defaults,
            now: { MobileSyntheticFixture.refreshNow },
            providerFactory: { _ in provider }
        )

        await store.start()
        let today = try #require(store.today)
        #expect(store.todayPhase == .ready)
        #expect(store.isTodayFavorite == false)

        await store.toggleTodayFavorite()
        #expect(store.isTodayFavorite)
        await store.refreshStorage()
        #expect(store.cacheProtectionCounts[.favorite] == 1)

        let originalURL = await store.loadTodayOriginal()
        #expect(originalURL != nil)
        #expect(store.today?.hasOriginal == true)

        let eviction = try await store.setCacheCapacity(0)
        #expect(store.cacheCapacityBytes == 0)
        #expect(store.cacheLimits.thumbnailBytes == 0)
        #expect(store.cacheLimits.originalBytes == 0)
        #expect(store.settings.thumbnailCacheLimitBytes == 0)
        #expect(store.settings.originalCacheLimitBytes == 0)
        #expect(store.storageFeedback != nil)
        #expect(
            !eviction.evictedAssets.contains {
                $0.wallpaperID == today.wallpaperID && $0.kind == .original
            }
        )

        let protectedOriginal = await store.imageURL(
            for: today.wallpaperID,
            variant: .original
        )
        #expect(protectedOriginal != nil)
        #expect((store.storageUsage?.originalBytes ?? 0) > 0)

        let persisted = environment.settingsStore.load()
        #expect(persisted.cacheLimits.thumbnailBytes == 0)
        #expect(persisted.cacheLimits.originalBytes == 0)
        #expect(persisted.imageQuality == .highResolution)
    }
}
