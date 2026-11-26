import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Mobile intent data")
struct MobileIntentDataTests {
    @Test("intent image preparation is real, dated and variant-honest")
    func intentImagePreparation() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("Intent")
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
        let store = MobileSyntheticFixture.makeDataStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            selectionStore: environment.selectionStore,
            transport: transport
        )
        let today = try await store.refreshToday(market: .zhCN)
        let service = MobileIntentService(
            dataStore: store,
            settingsStore: environment.settingsStore
        )

        #expect(await service.preferredMarket() == .zhCN)
        #expect(await service.lookupWallpaperID("bing:SyntheticOwl") == MobileSyntheticFixture.owlID)
        #expect(await service.lookupWallpaperID("bing:") == nil)
        #expect(await service.lookupWallpaperID("img:SyntheticOwl") == nil)

        let original = try await service.prepareIntentImage(
            .today(market: .zhCN),
            variant: .original,
            allowNetwork: true
        )
        defer { try? FileManager.default.removeItem(at: original.fileURL) }
        #expect(original.isOriginal)
        #expect(original.wallpaperID == MobileSyntheticFixture.owlID)
        #expect(original.sourceDate == MobileSyntheticFixture.date("2026-11-24"))
        #expect(original.mimeType == "image/png")
        #expect(original.fileExtension == "png")
        #expect(original.title == "Synthetic owl title")
        #expect(FileManager.default.fileExists(atPath: original.fileURL.path))

        let thumbnail = try await service.prepareIntentImage(
            .date(MobileSyntheticFixture.date("2026-11-23"), market: .zhCN),
            variant: .thumbnail,
            allowNetwork: false
        )
        defer { try? FileManager.default.removeItem(at: thumbnail.fileURL) }
        #expect(!thumbnail.isOriginal)
        #expect(thumbnail.wallpaperID == MobileSyntheticFixture.fernID)
        #expect(thumbnail.sourceDate == MobileSyntheticFixture.date("2026-11-23"))
        #expect(FileManager.default.fileExists(atPath: thumbnail.fileURL.path))

        let random = try await service.prepareIntentImage(
            .randomCached,
            variant: .thumbnail,
            allowNetwork: false
        )
        defer { try? FileManager.default.removeItem(at: random.fileURL) }
        #expect(!random.isOriginal)
        #expect(
            [MobileSyntheticFixture.fernID, MobileSyntheticFixture.owlID]
                .contains(random.wallpaperID)
        )

        do {
            _ = try await service.prepareIntentImage(
                .currentSelection,
                variant: .thumbnail,
                allowNetwork: false
            )
            Issue.record("Current selection unexpectedly existed")
        } catch let error as MobileStoreError {
            #expect(error == .noCurrentSelection)
        }

        await service.recordSelection(today.key)
        #expect(await service.currentSelection() == today.key)
        #expect(await service.currentSelectionWallpaperID() == today.wallpaperID)

        let current = try await service.prepareIntentImage(
            .currentSelection,
            variant: .original,
            allowNetwork: false
        )
        defer { try? FileManager.default.removeItem(at: current.fileURL) }
        #expect(current.isOriginal)
        #expect(current.wallpaperID == today.wallpaperID)
        #expect(current.fileURL.path != original.fileURL.path)
    }

    @Test("favorites and market-specific today use the shared repository")
    func favoritesAndMarketToday() async throws {
        let environment = MobileTestDefaults()
        let directory = MobileSyntheticFixture.temporaryDirectory("IntentFavorite")
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
        let store = MobileSyntheticFixture.makeDataStore(
            directory: directory,
            settingsStore: environment.settingsStore,
            selectionStore: environment.selectionStore,
            transport: transport
        )
        let today = try await store.refreshToday(market: .zhCN)
        let service = MobileIntentService(
            dataStore: store,
            settingsStore: environment.settingsStore
        )

        do {
            _ = try await service.prepareIntentImage(
                .randomFavorite,
                variant: .thumbnail,
                allowNetwork: false
            )
            Issue.record("Random favorite unexpectedly succeeded")
        } catch let error as MobileStoreError {
            #expect(error == .noFavorites)
        }

        _ = try await store.setFavorite(today.wallpaperID, isFavorite: true)

        let favorite = try await service.prepareIntentImage(
            .randomFavorite,
            variant: .original,
            allowNetwork: true
        )
        defer { try? FileManager.default.removeItem(at: favorite.fileURL) }
        #expect(favorite.wallpaperID == today.wallpaperID)
        #expect(favorite.isOriginal)

        let byID = try await service.prepareIntentImage(
            .wallpaper(today.wallpaperID),
            variant: .thumbnail,
            allowNetwork: false
        )
        defer { try? FileManager.default.removeItem(at: byID.fileURL) }
        #expect(byID.wallpaperID == today.wallpaperID)
        #expect(!byID.isOriginal)

        do {
            _ = try await service.prepareIntentImage(
                .date(MobileSyntheticFixture.date("2026-11-20"), market: .zhCN),
                variant: .thumbnail,
                allowNetwork: false
            )
            Issue.record("Missing date unexpectedly succeeded")
        } catch let error as MobileStoreError {
            #expect(
                error == .noImageForDate(
                    MobileSyntheticFixture.date("2026-11-20"),
                    .zhCN
                )
            )
        }
    }
}
