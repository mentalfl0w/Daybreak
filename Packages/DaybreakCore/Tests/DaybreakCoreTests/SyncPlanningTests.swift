import Foundation
import Testing
import DaybreakCore

struct SyncPlanningTests {
    private static func completeSnapshot() -> (snapshot: SyncLocalSnapshot, image: WallpaperID, pin: PinnedOccurrence) {
        let image = SyncFixture.image("img-a")
        let occurrence = SyncFixture.occurrence(imageID: "img-a")
        let pin = PinnedOccurrence(key: occurrence.id, wallpaperID: image)
        let snapshot = SyncLocalSnapshot(
            favorites: [image],
            pinnedOccurrences: [pin],
            occurrences: [occurrence],
            metadata: [SyncFixture.metadata(imageID: "img-a")],
            wallpapers: [SyncFixture.wallpaper(imageID: "img-a", variants: [SyncFixture.variant("img-a")])],
            stories: [SyncFixture.story()],
            assets: [SyncFixture.assetReference("img-a")]
        )
        return (snapshot, image, pin)
    }

    @Test func bootstrapIsDeterministicAndReproducesLocalState() throws {
        let fixture = Self.completeSnapshot()
        let first = try SyncBootstrapPlanner.operations(
            snapshot: fixture.snapshot,
            deviceID: .deviceA,
            startingSequence: 1
        )
        let second = try SyncBootstrapPlanner.operations(
            snapshot: fixture.snapshot,
            deviceID: .deviceA,
            startingSequence: 1
        )

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.count == 7)
        #expect(first.allSatisfy { Set($0.context.counters.keys) == Set([SyncFixture.deviceA]) })

        let archive = SyncMergeEngine.merge(first).archive
        #expect(archive.favoriteWallpaperIDs == Set([fixture.image]))
        #expect(archive.pin(for: fixture.pin.key) == fixture.pin)
        #expect(archive.occurrences.count == 1)
        #expect(archive.metadata.count == 1)
        #expect(archive.wallpapers.count == 1)
        #expect(archive.stories.count == 1)
        #expect(archive.assetReferences.count == 1)
        #expect(archive.causalFrontier.nextSequence(for: .deviceA) == 8)
    }

    @Test func bootstrapDoesNotObserveRemoteTombstoneThenUserOperationDoes() throws {
        let fixture = Self.completeSnapshot()
        let remoteRemove = SyncFixture.favorite(
            "img-a",
            isFavorite: false,
            device: .deviceB,
            sequence: 1
        )
        let input = SyncReconciliationInput(
            deviceID: .deviceA,
            local: fixture.snapshot,
            nextLocalSequence: 1,
            bootstrapLocalState: true
        )
        let plan = try SyncMergePlanner.plan(input: input, remoteOperations: [remoteRemove])

        #expect(plan.bootstrapOperations.count == 7)
        #expect(plan.bootstrapOperations.allSatisfy {
            $0.context.counter(for: .deviceB) == 0
        })
        #expect(!plan.archive.isFavorite(fixture.image))
        #expect(plan.archive.favoriteTombstoneCount == 1)
        #expect(plan.repositoryMutation.favoritesToRemove == [fixture.image])
        #expect(plan.nextLocalSequence == 8)
        #expect(plan.causalContext.counter(for: .deviceB) == 1)
        #expect(plan.causalContext.counter(for: .deviceA) == 7)

        let userFavorite = try SyncOperationFactory.favorite(
            wallpaperID: fixture.image,
            isFavorite: true,
            deviceID: .deviceA,
            sequence: plan.nextLocalSequence,
            knownContext: plan.causalContext
        )
        let afterUser = SyncMergeEngine.merge(
            [remoteRemove] + plan.bootstrapOperations + [userFavorite]
        ).archive
        #expect(afterUser.isFavorite(fixture.image))
        #expect(afterUser.favoriteTombstoneCount == 0)
    }

    @Test func steadyStatePlanAppliesRemoteTombstoneDirectly() throws {
        let fixture = Self.completeSnapshot()
        let remoteRemove = SyncFixture.favorite(
            "img-a",
            isFavorite: false,
            device: .deviceB,
            sequence: 1
        )
        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(
                deviceID: .deviceA,
                local: fixture.snapshot,
                nextLocalSequence: 1,
                bootstrapLocalState: false
            ),
            remoteOperations: [remoteRemove]
        )

        #expect(plan.bootstrapOperations.isEmpty)
        #expect(!plan.archive.isFavorite(fixture.image))
        #expect(plan.repositoryMutation.favoritesToRemove == [fixture.image])
        #expect(plan.repositoryMutation.favoritesToAdd.isEmpty)
        #expect(plan.nextLocalSequence == 1)
        #expect(plan.causalContext.counter(for: .deviceB) == 1)
    }

    @Test func planComputesFavoriteAndPinDeltas() throws {
        let imageA = SyncFixture.image("img-a")
        let imageB = SyncFixture.image("img-b")
        let pinA = PinnedOccurrence(
            key: OccurrenceKey(source: .bing, market: .zhCN, localDate: SyncFixture.date("2026-01-01")),
            wallpaperID: imageA
        )
        let pinB = PinnedOccurrence(
            key: OccurrenceKey(source: .bing, market: .enUS, localDate: SyncFixture.date("2026-01-02")),
            wallpaperID: imageB
        )
        let local = SyncLocalSnapshot(favorites: [imageA], pinnedOccurrences: [pinA])

        let operations = [
            SyncFixture.favorite("img-b", isFavorite: true, device: .deviceB, sequence: 1),
            SyncFixture.favorite("img-a", isFavorite: false, device: .deviceB, sequence: 2, prior: ["device-b": 1]),
            SyncFixture.pin("2026-01-02", market: .enUS, imageID: "img-b", isPinned: true, device: .deviceB, sequence: 3, prior: ["device-b": 2]),
            SyncFixture.pin("2026-01-01", market: .zhCN, imageID: "img-a", isPinned: false, device: .deviceB, sequence: 4, prior: ["device-b": 3])
        ]
        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(
                deviceID: .deviceA,
                local: local,
                nextLocalSequence: 1
            ),
            remoteOperations: operations
        )

        #expect(plan.repositoryMutation.favoritesToAdd == [imageB])
        #expect(plan.repositoryMutation.favoritesToRemove == [imageA])
        #expect(plan.repositoryMutation.pinsToAdd == [pinB])
        #expect(plan.repositoryMutation.pinKeysToRemove == [pinA.key])
        #expect(plan.archive.pinnedOccurrences == Set([pinB]))
        #expect(plan.nextLocalSequence == 1)
    }

    @Test func planSeparatesMissingAssetsFromAlreadyPresentDigests() throws {
        let localThumb = SyncFixture.assetReference("img-a", kind: .thumbnail, data: Data("shared".utf8))
        let localOnly = SyncFixture.assetReference("img-d", kind: .thumbnail, data: Data("local-only".utf8))
        let remoteShared = SyncFixture.assetReference("img-b", kind: .original, data: Data("shared".utf8))
        let remoteNew = SyncFixture.assetReference("img-c", kind: .original, data: Data("new".utf8))
        let remoteThumb = SyncFixture.assetReference("img-e", kind: .thumbnail, data: Data("thumb".utf8))
        let local = SyncLocalSnapshot(assets: [localThumb, localOnly])

        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(deviceID: .deviceA, local: local),
            remoteOperations: [
                SyncFixture.assetsOperation(
                    [remoteShared, remoteNew, remoteThumb],
                    device: .deviceB,
                    sequence: 1
                )
            ]
        )

        #expect(plan.repositoryMutation.assetReferencesToRegister.count == 3)
        #expect(plan.assetsMissingLocally.count == 2)
        #expect(Set(plan.assetsMissingLocally.map(\.contentSHA256)) == Set([remoteNew.contentSHA256, remoteThumb.contentSHA256]))
        #expect(plan.localAssetsNotInArchive == [localOnly])

        let thumbnailsOnly = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(
                deviceID: .deviceA,
                local: local,
                scope: SyncScope(includesOriginals: false)
            ),
            remoteOperations: [
                SyncFixture.assetsOperation(
                    [remoteShared, remoteNew, remoteThumb],
                    device: .deviceB,
                    sequence: 1
                )
            ]
        )
        #expect(thumbnailsOnly.repositoryMutation.assetReferencesToRegister == [remoteThumb])
        #expect(thumbnailsOnly.assetsMissingLocally == [remoteThumb])
    }

    @Test func marketScopeFiltersDatedContentButNotImageFavorites() throws {
        let operations = [
            SyncFixture.occurrenceOperation(
                SyncFixture.occurrence(market: .zhCN, imageID: "img-a"),
                device: .deviceB,
                sequence: 1
            ),
            SyncFixture.occurrenceOperation(
                SyncFixture.occurrence(market: .enUS, imageID: "img-a"),
                device: .deviceB,
                sequence: 2,
                prior: ["device-b": 1]
            ),
            SyncFixture.metadataOperation(
                SyncFixture.metadata(market: .zhCN, imageID: "img-a"),
                device: .deviceB,
                sequence: 3,
                prior: ["device-b": 2]
            ),
            SyncFixture.storyOperation(
                SyncFixture.story(market: .zhCN),
                device: .deviceB,
                sequence: 4,
                prior: ["device-b": 3]
            ),
            SyncFixture.pin(
                market: .zhCN,
                imageID: "img-a",
                isPinned: true,
                device: .deviceB,
                sequence: 5,
                prior: ["device-b": 4]
            ),
            SyncFixture.favorite("img-b", isFavorite: true, device: .deviceB, sequence: 6, prior: ["device-b": 5])
        ]
        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(
                deviceID: .deviceA,
                local: SyncLocalSnapshot(),
                scope: SyncScope(markets: [.enUS])
            ),
            remoteOperations: operations
        )

        #expect(plan.archive.occurrences.count == 2)
        #expect(plan.repositoryMutation.occurrencesToUpsert.count == 1)
        #expect(plan.repositoryMutation.occurrencesToUpsert.first?.market == .enUS)
        #expect(plan.repositoryMutation.metadataToUpsert.isEmpty)
        #expect(plan.repositoryMutation.storiesToUpsert.isEmpty)
        #expect(plan.repositoryMutation.pinsToAdd.isEmpty)
        #expect(plan.repositoryMutation.favoritesToAdd == [SyncFixture.image("img-b")])
    }

    @Test func matchingArchiveAndLocalStateProduceNoRepositoryWork() throws {
        let image = SyncFixture.image("img-a")
        let occurrence = SyncFixture.occurrence(imageID: "img-a")
        let metadata = SyncFixture.metadata(imageID: "img-a")
        let wallpaper = SyncFixture.wallpaper(imageID: "img-a", variants: [SyncFixture.variant("img-a")])
        let story = SyncFixture.story()
        let asset = SyncFixture.assetReference("img-a")
        let pin = PinnedOccurrence(key: occurrence.id, wallpaperID: image)

        let operations = [
            SyncFixture.favorite("img-a", isFavorite: true, device: .deviceB, sequence: 1),
            SyncFixture.pin(imageID: "img-a", isPinned: true, device: .deviceB, sequence: 2, prior: ["device-b": 1]),
            SyncFixture.occurrenceOperation(occurrence, device: .deviceB, sequence: 3, prior: ["device-b": 2]),
            SyncFixture.metadataOperation(metadata, device: .deviceB, sequence: 4, prior: ["device-b": 3]),
            SyncFixture.wallpaperOperation(wallpaper, device: .deviceB, sequence: 5, prior: ["device-b": 4]),
            SyncFixture.storyOperation(story, device: .deviceB, sequence: 6, prior: ["device-b": 5]),
            SyncFixture.assetsOperation([asset], device: .deviceB, sequence: 7, prior: ["device-b": 6])
        ]
        let local = SyncLocalSnapshot(
            favorites: [image],
            pinnedOccurrences: [pin],
            occurrences: [occurrence],
            metadata: [metadata],
            wallpapers: [wallpaper],
            stories: [story],
            assets: [asset]
        )
        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(deviceID: .deviceA, local: local),
            remoteOperations: operations
        )

        #expect(plan.repositoryMutation.isEmpty)
        #expect(plan.assetsMissingLocally.isEmpty)
        #expect(plan.localAssetsNotInArchive.isEmpty)
        #expect(plan.mergeOutcome.rejectedOperations.isEmpty)
        #expect(plan.isNoOp)
        #expect(plan.nextLocalSequence == 1)
    }

    @Test func duplicateRemoteOperationsDoNotChangeTheMutation() throws {
        let operation = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceB, sequence: 1)
        let single = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(deviceID: .deviceA, local: SyncLocalSnapshot()),
            remoteOperations: [operation]
        )
        let duplicated = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(deviceID: .deviceA, local: SyncLocalSnapshot()),
            remoteOperations: [operation, operation, operation]
        )

        #expect(duplicated.mergeOutcome.duplicateCount == 1)
        #expect(duplicated.repositoryMutation == single.repositoryMutation)
        #expect(duplicated.repositoryMutation.favoritesToAdd == [SyncFixture.image("img-a")])
    }

    @Test func bootstrapNormalizesDuplicateLocalRevisionsDeterministically() throws {
        let imageA = SyncFixture.image("img-a")
        let imageB = SyncFixture.image("img-b")
        let key = OccurrenceKey(source: .bing, market: .zhCN, localDate: SyncFixture.date("2026-01-01"))
        let olderOccurrence = SyncFixture.occurrence(imageID: "img-a", revision: 0)
        let newerOccurrence = SyncFixture.occurrence(imageID: "img-a", revision: 1)
        let richMetadata = SyncFixture.metadata(imageID: "img-a", title: "Rich", variants: [SyncFixture.variant("img-a")])
        let bareMetadata = SyncFixture.metadata(
            imageID: "img-a",
            title: nil,
            copyright: nil,
            sourceURL: nil,
            contentHash: nil
        )
        let availableStory = SyncFixture.story(id: "story-available", title: "Available")
        let unavailableStory = SyncFixture.story(
            id: "story-unavailable",
            title: "Headline",
            body: nil,
            availability: .unavailable(.notProvidedBySource)
        )
        let pinA = PinnedOccurrence(key: key, wallpaperID: imageA)
        let pinB = PinnedOccurrence(key: key, wallpaperID: imageB)

        let snapshot = SyncLocalSnapshot(
            pinnedOccurrences: [pinA, pinB],
            occurrences: [olderOccurrence, newerOccurrence],
            metadata: [richMetadata, bareMetadata],
            stories: [availableStory, unavailableStory]
        )
        let operations = try SyncBootstrapPlanner.operations(
            snapshot: snapshot,
            deviceID: .deviceA,
            startingSequence: 1
        )

        var occurrences: [WallpaperOccurrence] = []
        var metadata: [WallpaperMetadataRecord] = []
        var stories: [DailyStoryRecord] = []
        var pins: [PinnedOccurrence] = []
        for operation in operations {
            switch operation.payload {
            case .occurrence(let record): occurrences.append(record)
            case .metadata(let record): metadata.append(record)
            case .story(let record): stories.append(record)
            case .pin(let change):
                if let wallpaperID = change.wallpaperID {
                    pins.append(PinnedOccurrence(key: change.key, wallpaperID: wallpaperID))
                }
            default:
                break
            }
        }

        #expect(occurrences.count == 1)
        #expect(occurrences.first?.revision == 1)
        #expect(metadata.count == 1)
        #expect(metadata.first?.title == "Rich")
        #expect(stories.count == 1)
        #expect(stories.first?.id == "story-available")
        #expect(pins.count == 1)
        #expect(pins.first?.wallpaperID == min(imageA, imageB))
    }

    @Test func callerSequenceFloorIsPreserved() throws {
        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(
                deviceID: .deviceA,
                local: SyncLocalSnapshot(),
                nextLocalSequence: 42
            ),
            remoteOperations: [
                SyncFixture.favorite("img-a", isFavorite: true, device: .deviceB, sequence: 1)
            ]
        )

        #expect(plan.nextLocalSequence == 42)
        #expect(plan.causalContext.counter(for: .deviceA) == 0)
        #expect(plan.causalContext.counter(for: .deviceB) == 1)
    }
}

/// Absence without any archive record is not evidence of a remote removal.
/// The engine can see an empty or partially downloaded folder; imported
/// favorites and pins must survive that until a real tombstone arrives.
struct SyncArchiveEvidenceTests {
    @Test func emptyArchiveKeepsImportedFavoritesAndPins() throws {
        let image = SyncFixture.image("img-a")
        let occurrence = SyncFixture.occurrence(imageID: "img-a")
        let pin = PinnedOccurrence(key: occurrence.id, wallpaperID: image)
        let local = SyncLocalSnapshot(
            favorites: [image],
            pinnedOccurrences: [pin],
            occurrences: [occurrence],
            metadata: [SyncFixture.metadata(imageID: "img-a")],
            wallpapers: [SyncFixture.wallpaper(imageID: "img-a", variants: [SyncFixture.variant("img-a")])],
            stories: [SyncFixture.story()]
        )

        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(
                deviceID: .deviceA,
                local: local,
                nextLocalSequence: 1
            ),
            remoteOperations: []
        )

        #expect(plan.repositoryMutation.favoritesToRemove.isEmpty)
        #expect(plan.repositoryMutation.pinKeysToRemove.isEmpty)
        #expect(plan.repositoryMutation.favoritesToAdd.isEmpty)
        #expect(plan.repositoryMutation.pinsToAdd.isEmpty)
    }

    @Test func tombstoneStillRemovesImportedFavoriteAndPin() throws {
        let image = SyncFixture.image("img-a")
        let occurrence = SyncFixture.occurrence(imageID: "img-a")
        let pin = PinnedOccurrence(key: occurrence.id, wallpaperID: image)
        let local = SyncLocalSnapshot(favorites: [image], pinnedOccurrences: [pin])
        let operations = [
            SyncFixture.favorite("img-a", isFavorite: false, device: .deviceB, sequence: 1),
            SyncFixture.pin(
                "2026-01-01",
                market: .zhCN,
                imageID: "img-a",
                isPinned: false,
                device: .deviceB,
                sequence: 2,
                prior: ["device-b": 1]
            )
        ]

        let plan = try SyncMergePlanner.plan(
            input: SyncReconciliationInput(deviceID: .deviceA, local: local),
            remoteOperations: operations
        )

        #expect(plan.repositoryMutation.favoritesToRemove == [image])
        #expect(plan.repositoryMutation.pinKeysToRemove == [pin.key])
    }
}
