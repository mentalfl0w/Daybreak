import Foundation
import Testing
import DaybreakCore

struct SyncMergeTests {
    @Test func favoriteAddThenUnfavoriteLeavesOneTombstone() {
        let image = SyncFixture.image("img-a")
        let add = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let remove = SyncFixture.favorite(
            "img-a",
            isFavorite: false,
            device: .deviceA,
            sequence: 2,
            prior: ["device-a": 1]
        )

        let outcome = SyncMergeEngine.merge([add, remove])
        #expect(outcome.rejectedOperations.isEmpty)
        #expect(!outcome.archive.isFavorite(image))
        #expect(outcome.archive.favoriteTombstoneCount == 1)
        #expect(outcome.archive.causalFrontier.counter(for: .deviceA) == 2)
    }

    @Test func concurrentFavoriteUnfavoriteIsRemoveWinsAndOrderIndependent() {
        let image = SyncFixture.image("img-a")
        let add = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let remove = SyncFixture.favorite("img-a", isFavorite: false, device: .deviceB, sequence: 1)

        let forward = SyncMergeEngine.merge([add, remove]).archive
        let reverse = SyncMergeEngine.merge([remove, add]).archive

        #expect(forward == reverse)
        #expect(!forward.isFavorite(image))
        #expect(forward.favoriteTombstoneCount == 1)
    }

    @Test func reFavoriteCausallyAfterRemovalWinsAndPrunesTombstone() {
        let image = SyncFixture.image("img-a")
        let add = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let remove = SyncFixture.favorite(
            "img-a",
            isFavorite: false,
            device: .deviceA,
            sequence: 2,
            prior: ["device-a": 1]
        )
        let reAdd = SyncFixture.favorite(
            "img-a",
            isFavorite: true,
            device: .deviceA,
            sequence: 3,
            prior: ["device-a": 2]
        )

        let archive = SyncMergeEngine.merge([add, remove, reAdd]).archive
        #expect(archive.isFavorite(image))
        #expect(archive.favoriteTombstoneCount == 0)
    }

    @Test func duplicateOperationsAreIdempotent() {
        let operation = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let single = SyncMergeEngine.merge([operation])
        let duplicated = SyncMergeEngine.merge([operation, operation, operation])

        #expect(duplicated.duplicateCount == 1)
        #expect(duplicated.archive == single.archive)

        let remerged = SyncMergeEngine.merge([operation], into: duplicated.archive)
        #expect(remerged.archive == duplicated.archive)
    }

    @Test func sameDeviceSequenceReuseRejectsBothOperations() {
        let first = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let second = SyncFixture.favorite("img-b", isFavorite: true, device: .deviceA, sequence: 1)

        let outcome = SyncMergeEngine.merge([first, second])
        #expect(outcome.rejectedCount == 2)
        #expect(outcome.archive.isEmpty)
        #expect(outcome.rejectedOperations.allSatisfy { $0.reason == .deviceSequenceConflict })
    }

    @Test func mergeIsOrderIndependentForMixedOperations() {
        let occurrence = SyncFixture.occurrenceOperation(
            SyncFixture.occurrence(imageID: "img-a"),
            device: .deviceA,
            sequence: 1
        )
        let metadata = SyncFixture.metadataOperation(
            SyncFixture.metadata(imageID: "img-a"),
            device: .deviceA,
            sequence: 2,
            prior: ["device-a": 1]
        )
        let pin = SyncFixture.pin(
            imageID: "img-a",
            isPinned: true,
            device: .deviceA,
            sequence: 3,
            prior: ["device-a": 2]
        )
        let favorite = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceB, sequence: 1)
        let story = SyncFixture.storyOperation(
            SyncFixture.story(),
            device: .deviceB,
            sequence: 2,
            prior: ["device-b": 1]
        )
        let assets = SyncFixture.assetsOperation(
            [SyncFixture.assetReference("img-a")],
            device: .deviceB,
            sequence: 3,
            prior: ["device-b": 2]
        )
        let operations = [occurrence, metadata, pin, favorite, story, assets]

        let baseline = SyncMergeEngine.merge(operations).archive
        let reversed = SyncMergeEngine.merge(Array(operations.reversed())).archive
        let rotated = SyncMergeEngine.merge(Array(operations.dropFirst(3)) + Array(operations.prefix(3))).archive

        #expect(baseline == reversed)
        #expect(baseline == rotated)
        #expect(baseline.occurrences.count == 1)
        #expect(baseline.metadata.count == 1)
        #expect(baseline.stories.count == 1)
        #expect(baseline.assetReferences.count == 1)
        #expect(baseline.isFavorite(SyncFixture.image("img-a")))
    }

    @Test func sameImageAcrossMarketsKeepsOccurrencesButOneImageFavorite() throws {
        let image = SyncFixture.image("img-a")
        let zhKey = OccurrenceKey(source: .bing, market: .zhCN, localDate: SyncFixture.date("2026-01-01"))
        let enKey = OccurrenceKey(source: .bing, market: .enUS, localDate: SyncFixture.date("2026-01-01"))

        let zhOccurrence = SyncFixture.occurrenceOperation(
            SyncFixture.occurrence(market: .zhCN, imageID: "img-a"),
            device: .deviceA,
            sequence: 1
        )
        let enOccurrence = SyncFixture.occurrenceOperation(
            SyncFixture.occurrence(market: .enUS, imageID: "img-a"),
            device: .deviceA,
            sequence: 2,
            prior: ["device-a": 1]
        )
        let favorite = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceB, sequence: 1)
        let zhPin = SyncFixture.pin(market: .zhCN, imageID: "img-a", isPinned: true, device: .deviceB, sequence: 2, prior: ["device-b": 1])
        let enPin = SyncFixture.pin(market: .enUS, imageID: "img-a", isPinned: true, device: .deviceB, sequence: 3, prior: ["device-b": 2])
        let zhUnpin = SyncFixture.pin(market: .zhCN, imageID: "img-a", isPinned: false, device: .deviceB, sequence: 4, prior: ["device-b": 3])

        let archive = SyncMergeEngine.merge([zhOccurrence, enOccurrence, favorite, zhPin, enPin, zhUnpin]).archive
        #expect(archive.occurrences.count == 2)
        #expect(archive.occurrence(for: zhKey)?.market == .zhCN)
        #expect(archive.occurrence(for: enKey)?.market == .enUS)
        #expect(archive.isFavorite(image))
        #expect(archive.favoriteWallpaperIDs == Set([image]))
        #expect(archive.pin(for: zhKey) == nil)
        #expect(archive.pin(for: enKey)?.wallpaperID == image)
        #expect(archive.pinnedOccurrences == Set([PinnedOccurrence(key: enKey, wallpaperID: image)]))
        #expect(archive.pinTombstoneCount == 1)
    }

    @Test func concurrentPinsForOneOccurrenceChooseDeterministically() {
        let key = OccurrenceKey(source: .bing, market: .zhCN, localDate: SyncFixture.date("2026-01-01"))
        let pinA = SyncFixture.pin(imageID: "img-a", isPinned: true, device: .deviceA, sequence: 1)
        let pinB = SyncFixture.pin(imageID: "img-b", isPinned: true, device: .deviceB, sequence: 1)

        let forward = SyncMergeEngine.merge([pinA, pinB]).archive
        let reverse = SyncMergeEngine.merge([pinB, pinA]).archive
        let expected = min(SyncFixture.image("img-a"), SyncFixture.image("img-b"))

        #expect(forward == reverse)
        #expect(forward.pin(for: key)?.wallpaperID == expected)
    }

    @Test func higherOccurrenceRevisionWinsEvenWhenItsPublisherTimeIsOlder() {
        let key = OccurrenceKey(source: .bing, market: .zhCN, localDate: SyncFixture.date("2026-01-01"))
        let olderRevision = SyncFixture.occurrenceOperation(
            SyncFixture.occurrence(
                imageID: "img-a",
                revision: 0,
                publisherTime: SyncFixture.newerFetchedAt
            ),
            device: .deviceA,
            sequence: 1
        )
        let newerRevision = SyncFixture.occurrenceOperation(
            SyncFixture.occurrence(
                imageID: "img-a",
                revision: 1,
                publisherTime: SyncFixture.olderFetchedAt
            ),
            device: .deviceB,
            sequence: 1
        )

        let forward = SyncMergeEngine.merge([olderRevision, newerRevision]).archive
        let reverse = SyncMergeEngine.merge([newerRevision, olderRevision]).archive

        #expect(forward == reverse)
        #expect(forward.occurrences.count == 1)
        #expect(forward.occurrence(for: key)?.revision == 1)
    }

    @Test func metadataPreferenceIgnoresWallClockFreshness() {
        let key = OccurrenceKey(source: .bing, market: .zhCN, localDate: SyncFixture.date("2026-01-01"))
        let rich = SyncFixture.metadataOperation(
            SyncFixture.metadata(
                imageID: "img-a",
                title: "Rich title",
                copyright: "Rich copyright",
                fetchedAt: SyncFixture.olderFetchedAt,
                variants: [SyncFixture.variant("img-a")]
            ),
            device: .deviceA,
            sequence: 1
        )
        let bareAndNewer = SyncFixture.metadataOperation(
            SyncFixture.metadata(
                imageID: "img-a",
                title: nil,
                copyright: nil,
                sourceURL: nil,
                fetchedAt: SyncFixture.newerFetchedAt,
                contentHash: nil,
                variants: []
            ),
            device: .deviceB,
            sequence: 1
        )

        let archive = SyncMergeEngine.merge([rich, bareAndNewer]).archive
        #expect(archive.metadata.count == 1)
        #expect(archive.metadata(for: key)?.title == "Rich title")
    }

    @Test func storyPresenceIsExplicitAndAvailableRevisionWins() throws {
        let image = SyncFixture.image("img-a")
        let key = try SyncStoryKey(
            source: .bing,
            market: .zhCN,
            date: SyncFixture.date("2026-01-01"),
            associatedWallpaperID: image,
            unboundStoryID: nil
        )
        let occurrence = SyncFixture.occurrenceOperation(
            SyncFixture.occurrence(imageID: "img-a"),
            device: .deviceA,
            sequence: 1
        )
        let withoutStory = SyncMergeEngine.merge([occurrence]).archive
        #expect(withoutStory.stories.isEmpty)
        #expect(withoutStory.story(for: key) == nil)

        let available = SyncFixture.story(
            id: "story-available",
            imageID: "img-a",
            title: "Available story",
            fetchedAt: SyncFixture.olderFetchedAt,
            availability: .available
        )
        let unavailable = SyncFixture.story(
            id: "story-unavailable",
            imageID: "img-a",
            title: "Headline only",
            body: nil,
            fetchedAt: SyncFixture.newerFetchedAt,
            availability: .unavailable(.notProvidedBySource)
        )
        let archive = SyncMergeEngine.merge([
            SyncFixture.storyOperation(available, device: .deviceA, sequence: 1),
            SyncFixture.storyOperation(unavailable, device: .deviceB, sequence: 1)
        ]).archive

        #expect(archive.stories.count == 1)
        #expect(archive.story(for: key)?.id == "story-available")
        #expect(archive.story(for: key)?.isAvailable == true)
    }

    @Test func unrelatedUnboundStoriesRemainDistinct() throws {
        let first = SyncFixture.story(id: "story-u1", imageID: nil, title: "First")
        let second = SyncFixture.story(id: "story-u2", imageID: nil, title: "Second")
        let archive = SyncMergeEngine.merge([
            SyncFixture.storyOperation(first, device: .deviceA, sequence: 1),
            SyncFixture.storyOperation(second, device: .deviceB, sequence: 1)
        ]).archive

        #expect(archive.stories.count == 2)
        let firstKey = try SyncStoryKey(
            source: .bing,
            market: .zhCN,
            date: SyncFixture.date("2026-01-01"),
            associatedWallpaperID: nil,
            unboundStoryID: "story-u1"
        )
        let secondKey = try SyncStoryKey(
            source: .bing,
            market: .zhCN,
            date: SyncFixture.date("2026-01-01"),
            associatedWallpaperID: nil,
            unboundStoryID: "story-u2"
        )
        #expect(archive.story(for: firstKey)?.id == "story-u1")
        #expect(archive.story(for: secondKey)?.id == "story-u2")
    }

    @Test func tombstonesSurviveUnrelatedMerges() {
        let add = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let remove = SyncFixture.favorite("img-a", isFavorite: false, device: .deviceB, sequence: 1)
        let unrelated = SyncFixture.favorite("img-b", isFavorite: true, device: .deviceB, sequence: 2, prior: ["device-b": 1])

        let first = SyncMergeEngine.merge([add, remove]).archive
        let second = SyncMergeEngine.merge([unrelated], into: first).archive

        #expect(!second.isFavorite(SyncFixture.image("img-a")))
        #expect(second.isFavorite(SyncFixture.image("img-b")))
        #expect(second.favoriteTombstoneCount == 1)
    }
}
