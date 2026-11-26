import Foundation

// MARK: - Local snapshot

/// Repository state that can be reconciled with the sync folder.
///
/// This mirrors the pure parts of `RepositorySnapshot`; local file paths,
/// bookmarks, applied-wallpaper state and permissions are deliberately absent.
/// Asset references must already carry the caller-computed SHA-256 of the local
/// bytes.
public struct SyncLocalSnapshot: Hashable, Sendable {
    public let favorites: Set<WallpaperID>
    public let pinnedOccurrences: Set<PinnedOccurrence>
    public let occurrences: [WallpaperOccurrence]
    public let metadata: [WallpaperMetadataRecord]
    public let wallpapers: [WallpaperRecord]
    public let stories: [DailyStoryRecord]
    public let assets: [SyncAssetReference]

    public init(
        favorites: Set<WallpaperID> = [],
        pinnedOccurrences: Set<PinnedOccurrence> = [],
        occurrences: [WallpaperOccurrence] = [],
        metadata: [WallpaperMetadataRecord] = [],
        wallpapers: [WallpaperRecord] = [],
        stories: [DailyStoryRecord] = [],
        assets: [SyncAssetReference] = []
    ) {
        self.favorites = favorites
        self.pinnedOccurrences = pinnedOccurrences
        self.occurrences = occurrences
        self.metadata = metadata
        self.wallpapers = wallpapers
        self.stories = stories
        self.assets = assets
    }

    /// Filters invalid records, collapses duplicate keys deterministically and
    /// sorts every collection. Bootstrap and delta planning always use this.
    func normalized() -> SyncLocalSnapshot {
        let favorites = Set(self.favorites.filter { SyncProtocolValidation.isValidWallpaperID($0) })

        var pinsByKey: [OccurrenceKey: PinnedOccurrence] = [:]
        for pin in pinnedOccurrences {
            guard pin.isValid,
                  SyncProtocolValidation.isValidOccurrenceKey(pin.key),
                  SyncProtocolValidation.isValidWallpaperID(pin.wallpaperID)
            else {
                continue
            }
            if let existing = pinsByKey[pin.key] {
                if pin.wallpaperID < existing.wallpaperID {
                    pinsByKey[pin.key] = pin
                }
            } else {
                pinsByKey[pin.key] = pin
            }
        }

        let occurrences = OccurrenceIndex.latest(
            self.occurrences.filter { (try? SyncPayloadValidation.validate($0)) != nil }
        )

        let metadata = Self.dedupe(
            self.metadata.filter { (try? SyncPayloadValidation.validate($0)) != nil },
            key: { $0.key },
            isPreferred: { $0.syncStableOrderKey < $1.syncStableOrderKey }
        )
        .sorted(by: SyncPlanOrder.metadata)

        let wallpapers = Self.dedupe(
            self.wallpapers.filter { (try? SyncPayloadValidation.validate($0)) != nil },
            key: { $0.id },
            isPreferred: { $0.syncStableOrderKey < $1.syncStableOrderKey }
        )
        .sorted { $0.id < $1.id }

        let stories = Self.dedupe(
            self.stories.filter { (try? SyncPayloadValidation.validate($0)) != nil },
            key: { SyncStoryKey(story: $0) },
            isPreferred: { $0.syncStableOrderKey < $1.syncStableOrderKey }
        )
        .sorted(by: SyncPlanOrder.story)

        let assets = Self.dedupe(
            self.assets.filter { $0.isValid },
            key: { $0.id },
            isPreferred: { $0.contentSHA256 < $1.contentSHA256 }
        )
        .sorted(by: SyncPlanOrder.asset)

        return SyncLocalSnapshot(
            favorites: favorites,
            pinnedOccurrences: Set(pinsByKey.values),
            occurrences: occurrences,
            metadata: metadata,
            wallpapers: wallpapers,
            stories: stories,
            assets: assets
        )
    }

    private static func dedupe<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key,
        isPreferred: (Value, Value) -> Bool
    ) -> [Value] {
        var selected: [Key: Value] = [:]
        for value in values {
            let valueKey = key(value)
            if let existing = selected[valueKey] {
                if isPreferred(value, existing) {
                    selected[valueKey] = value
                }
            } else {
                selected[valueKey] = value
            }
        }
        return Array(selected.values)
    }
}

// MARK: - Reconciliation input

public struct SyncReconciliationInput: Hashable, Sendable {
    public let deviceID: SyncDeviceID
    public let local: SyncLocalSnapshot
    /// Next logical sequence for this device. Must never reuse a published value.
    public let nextLocalSequence: UInt64
    /// True only for the one-time import of pre-sync local state. Bootstrap
    /// operations carry this device's own sequence context only; they never
    /// claim to have observed the remote frontier. Remote removals therefore
    /// stay concurrent and remove-wins instead of being resurrected.
    public let bootstrapLocalState: Bool
    public let scope: SyncScope

    public init(
        deviceID: SyncDeviceID,
        local: SyncLocalSnapshot,
        nextLocalSequence: UInt64 = 1,
        bootstrapLocalState: Bool = false,
        scope: SyncScope = .all
    ) {
        self.deviceID = deviceID
        self.local = local
        self.nextLocalSequence = nextLocalSequence
        self.bootstrapLocalState = bootstrapLocalState
        self.scope = scope
    }
}

// MARK: - Repository mutation

/// One atomic repository batch produced by a merge plan.
///
/// The plan is already reconciled: apply every field in one repository
/// transaction. Pin additions replace the same occurrence key; pin removals
/// only name keys that are absent from the desired archive. There is no
/// timestamp ordering to apply.
public struct SyncRepositoryMutation: Hashable, Sendable {
    public let favoritesToAdd: [WallpaperID]
    public let favoritesToRemove: [WallpaperID]
    public let pinsToAdd: [PinnedOccurrence]
    public let pinKeysToRemove: [OccurrenceKey]
    public let occurrencesToUpsert: [WallpaperOccurrence]
    public let metadataToUpsert: [WallpaperMetadataRecord]
    public let wallpapersToUpsert: [WallpaperRecord]
    public let storiesToUpsert: [DailyStoryRecord]
    public let assetReferencesToRegister: [SyncAssetReference]

    public init(
        favoritesToAdd: [WallpaperID] = [],
        favoritesToRemove: [WallpaperID] = [],
        pinsToAdd: [PinnedOccurrence] = [],
        pinKeysToRemove: [OccurrenceKey] = [],
        occurrencesToUpsert: [WallpaperOccurrence] = [],
        metadataToUpsert: [WallpaperMetadataRecord] = [],
        wallpapersToUpsert: [WallpaperRecord] = [],
        storiesToUpsert: [DailyStoryRecord] = [],
        assetReferencesToRegister: [SyncAssetReference] = []
    ) {
        self.favoritesToAdd = favoritesToAdd
        self.favoritesToRemove = favoritesToRemove
        self.pinsToAdd = pinsToAdd
        self.pinKeysToRemove = pinKeysToRemove
        self.occurrencesToUpsert = occurrencesToUpsert
        self.metadataToUpsert = metadataToUpsert
        self.wallpapersToUpsert = wallpapersToUpsert
        self.storiesToUpsert = storiesToUpsert
        self.assetReferencesToRegister = assetReferencesToRegister
    }

    public static let empty = SyncRepositoryMutation()

    public var isEmpty: Bool {
        favoritesToAdd.isEmpty
            && favoritesToRemove.isEmpty
            && pinsToAdd.isEmpty
            && pinKeysToRemove.isEmpty
            && occurrencesToUpsert.isEmpty
            && metadataToUpsert.isEmpty
            && wallpapersToUpsert.isEmpty
            && storiesToUpsert.isEmpty
            && assetReferencesToRegister.isEmpty
    }
}

// MARK: - Plan

public struct SyncMergePlan: Hashable, Sendable {
    /// Archive built from remote operations only.
    public let remoteArchive: SyncArchive
    /// Final archive, including deterministic bootstrap operations when the
    /// caller requested a one-time local-state import.
    public let archive: SyncArchive
    /// Accepted bootstrap operations to publish as immutable files.
    public let bootstrapOperations: [SyncOperation]
    public let mergeOutcome: SyncMergeOutcome
    public let repositoryMutation: SyncRepositoryMutation
    public let nextLocalSequence: UInt64
    /// Observed causal frontier for the next real user operation. Operations
    /// created after a bootstrap with this context do observe remote removals.
    public let causalContext: SyncVersionVector
    /// Content-addressed assets referenced by the archive but absent locally.
    public let assetsMissingLocally: [SyncAssetReference]
    /// In-scope local assets whose content is not referenced by the archive.
    public let localAssetsNotInArchive: [SyncAssetReference]

    public init(
        remoteArchive: SyncArchive,
        archive: SyncArchive,
        bootstrapOperations: [SyncOperation],
        mergeOutcome: SyncMergeOutcome,
        repositoryMutation: SyncRepositoryMutation,
        nextLocalSequence: UInt64,
        causalContext: SyncVersionVector,
        assetsMissingLocally: [SyncAssetReference],
        localAssetsNotInArchive: [SyncAssetReference]
    ) {
        self.remoteArchive = remoteArchive
        self.archive = archive
        self.bootstrapOperations = bootstrapOperations
        self.mergeOutcome = mergeOutcome
        self.repositoryMutation = repositoryMutation
        self.nextLocalSequence = nextLocalSequence
        self.causalContext = causalContext
        self.assetsMissingLocally = assetsMissingLocally
        self.localAssetsNotInArchive = localAssetsNotInArchive
    }

    public var isNoOp: Bool {
        repositoryMutation.isEmpty
            && bootstrapOperations.isEmpty
            && assetsMissingLocally.isEmpty
            && localAssetsNotInArchive.isEmpty
            && mergeOutcome.rejectedOperations.isEmpty
    }
}

// MARK: - Bootstrap

public enum SyncBootstrapPlanner {
    /// One operation per existing local record, with deterministic ordering and
    /// deterministic identifiers.
    ///
    /// Critical invariant: bootstrap contexts contain only this device's own
    /// sequence. They never include the remote frontier, because pre-sync local
    /// state has no causal evidence about remote removals. A concurrent remote
    /// tombstone therefore wins (remove-wins) instead of being overwritten.
    public static func operations(
        snapshot: SyncLocalSnapshot,
        deviceID: SyncDeviceID,
        startingSequence: UInt64,
        scope: SyncScope = .all
    ) throws -> [SyncOperation] {
        let content = SyncScopeProjection.local(snapshot.normalized(), scope: scope)

        var payloads: [SyncOperationPayload] = []
        payloads.append(contentsOf: content.favorites.sorted().map {
            SyncOperationPayload.favorite(SyncFavoriteChange(wallpaperID: $0, isFavorite: true))
        })
        payloads.append(contentsOf: content.pins.map {
            SyncOperationPayload.pin(SyncPinChange(key: $0.key, wallpaperID: $0.wallpaperID, isPinned: true))
        })
        payloads.append(contentsOf: content.occurrences.map { SyncOperationPayload.occurrence($0) })
        payloads.append(contentsOf: content.metadata.map { SyncOperationPayload.metadata($0) })
        payloads.append(contentsOf: content.wallpapers.map { SyncOperationPayload.wallpaper($0) })
        payloads.append(contentsOf: content.stories.map { SyncOperationPayload.story($0) })
        payloads.append(contentsOf: content.assets.map { SyncOperationPayload.assets([$0]) })

        guard !payloads.isEmpty else { return [] }
        guard startingSequence <= SyncWireProtocol.maxSequence else {
            throw SyncProtocolError.limitExceeded(
                "local sequence \(startingSequence) exceeds the protocol maximum"
            )
        }

        let firstSequence = max(startingSequence, 1)
        let lastSequence = firstSequence + UInt64(payloads.count - 1)
        guard lastSequence <= SyncWireProtocol.maxSequence else {
            throw SyncProtocolError.limitExceeded(
                "bootstrap would exceed the protocol sequence maximum"
            )
        }

        var result: [SyncOperation] = []
        result.reserveCapacity(payloads.count)
        for (offset, payload) in payloads.enumerated() {
            let sequence = firstSequence + UInt64(offset)
            let context = try SyncVersionVector([deviceID: sequence])
            result.append(
                try SyncOperation(
                    deviceID: deviceID,
                    sequence: sequence,
                    context: context,
                    payload: payload
                )
            )
        }
        return result
    }
}

// MARK: - Planner

public enum SyncMergePlanner {
    public static func plan(
        input: SyncReconciliationInput,
        remoteOperations: [SyncOperation]
    ) throws -> SyncMergePlan {
        let mergeOutcome = SyncMergeEngine.merge(remoteOperations)
        let remoteArchive = mergeOutcome.archive
        let local = input.local.normalized()

        var archive = remoteArchive
        var bootstrapOperations: [SyncOperation] = []
        if input.bootstrapLocalState {
            let startingSequence = max(
                max(input.nextLocalSequence, remoteArchive.nextSequence(for: input.deviceID)),
                1
            )
            bootstrapOperations = try SyncBootstrapPlanner.operations(
                snapshot: local,
                deviceID: input.deviceID,
                startingSequence: startingSequence,
                scope: input.scope
            )
            let bootstrapOutcome = SyncMergeEngine.merge(bootstrapOperations, into: archive)
            if let rejection = bootstrapOutcome.rejectedOperations.first {
                throw SyncProtocolError.limitExceeded(
                    "bootstrap operation rejected: \(rejection.reason)"
                )
            }
            archive = bootstrapOutcome.archive
        }

        let lastBootstrapSequence = bootstrapOperations.last?.sequence ?? 0
        let nextLocalSequence = max(
            max(input.nextLocalSequence, archive.nextSequence(for: input.deviceID)),
            max(lastBootstrapSequence + 1, 1)
        )
        guard nextLocalSequence <= SyncWireProtocol.maxSequence else {
            throw SyncProtocolError.limitExceeded("local sequence is exhausted")
        }

        let scopedArchive = SyncScopeProjection.archive(archive, scope: input.scope)
        let scopedLocal = SyncScopeProjection.local(local, scope: input.scope)

        let desiredFavorites = archive.favoriteWallpaperIDs
        let favoritesToAdd = desiredFavorites.subtracting(local.favorites).sorted()
        // Absence is only evidence of removal when the archive actually has a
        // record for that key (present wins above; otherwise it is tombstoned).
        // Files that are not downloaded yet, unreadable, or never published by
        // a peer must not delete a locally imported favorite.
        let favoritesToRemove = local.favorites
            .filter { !desiredFavorites.contains($0) && archive.hasFavoriteRecord($0) }
            .sorted()

        let desiredPins = Set(scopedArchive.pins)
        let pinsToAdd = desiredPins.subtracting(local.pinnedOccurrences).sorted(by: SyncPlanOrder.pin)
        let localPinsInScope = local.pinnedOccurrences.filter {
            input.scope.includes($0.key.market)
        }
        let desiredPinKeys = Set(desiredPins.map(\.key))
        let pinKeysToRemove = Set(localPinsInScope.map(\.key))
            .filter { !desiredPinKeys.contains($0) && archive.hasPinRecord($0) }
            .sorted()

        let localOccurrences = Dictionary(
            local.occurrences.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.syncStableOrderKey <= rhs.syncStableOrderKey ? lhs : rhs
            }
        )
        let occurrencesToUpsert = scopedArchive.occurrences.filter {
            localOccurrences[$0.id] != $0
        }

        let localMetadata = Dictionary(
            local.metadata.map { ($0.key, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.syncStableOrderKey <= rhs.syncStableOrderKey ? lhs : rhs
            }
        )
        let metadataToUpsert = scopedArchive.metadata.filter {
            localMetadata[$0.key] != $0
        }

        let localWallpapers = Dictionary(
            local.wallpapers.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.syncStableOrderKey <= rhs.syncStableOrderKey ? lhs : rhs
            }
        )
        let wallpapersToUpsert = scopedArchive.wallpapers.filter {
            localWallpapers[$0.id] != $0
        }

        let localStories = Dictionary(
            local.stories.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.syncStableOrderKey <= rhs.syncStableOrderKey ? lhs : rhs
            }
        )
        let storiesToUpsert = scopedArchive.stories.filter {
            localStories[$0.id] != $0
        }

        let localAssetsByKey = Dictionary(
            local.assets.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.contentSHA256 <= rhs.contentSHA256 ? lhs : rhs
            }
        )
        let assetReferencesToRegister = scopedArchive.assets.filter {
            localAssetsByKey[$0.id] != $0
        }

        let localDigests = Set(local.assets.map(\.contentSHA256))
        var missingDigests: Set<SyncContentDigest> = []
        var assetsMissingLocally: [SyncAssetReference] = []
        for reference in scopedArchive.assets.sorted(by: SyncPlanOrder.asset) {
            guard !localDigests.contains(reference.contentSHA256) else { continue }
            guard missingDigests.insert(reference.contentSHA256).inserted else { continue }
            assetsMissingLocally.append(reference)
        }

        let archiveDigests = Set(archive.assetReferences.map(\.contentSHA256))
        var localOnlyDigests: Set<SyncContentDigest> = []
        var localAssetsNotInArchive: [SyncAssetReference] = []
        for reference in scopedLocal.assets.sorted(by: SyncPlanOrder.asset) {
            guard !archiveDigests.contains(reference.contentSHA256) else { continue }
            guard localOnlyDigests.insert(reference.contentSHA256).inserted else { continue }
            localAssetsNotInArchive.append(reference)
        }

        let mutation = SyncRepositoryMutation(
            favoritesToAdd: favoritesToAdd,
            favoritesToRemove: favoritesToRemove,
            pinsToAdd: pinsToAdd,
            pinKeysToRemove: pinKeysToRemove,
            occurrencesToUpsert: occurrencesToUpsert,
            metadataToUpsert: metadataToUpsert,
            wallpapersToUpsert: wallpapersToUpsert,
            storiesToUpsert: storiesToUpsert,
            assetReferencesToRegister: assetReferencesToRegister
        )

        return SyncMergePlan(
            remoteArchive: remoteArchive,
            archive: archive,
            bootstrapOperations: bootstrapOperations,
            mergeOutcome: mergeOutcome,
            repositoryMutation: mutation,
            nextLocalSequence: nextLocalSequence,
            causalContext: archive.causalFrontier,
            assetsMissingLocally: assetsMissingLocally,
            localAssetsNotInArchive: localAssetsNotInArchive
        )
    }
}

// MARK: - Ordering and scope

enum SyncPlanOrder {
    static func pin(_ lhs: PinnedOccurrence, _ rhs: PinnedOccurrence) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.wallpaperID < rhs.wallpaperID
    }

    static func occurrence(_ lhs: WallpaperOccurrence, _ rhs: WallpaperOccurrence) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        return lhs.wallpaperID < rhs.wallpaperID
    }

    static func metadata(_ lhs: WallpaperMetadataRecord, _ rhs: WallpaperMetadataRecord) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.wallpaperID < rhs.wallpaperID
    }

    static func story(_ lhs: DailyStoryRecord, _ rhs: DailyStoryRecord) -> Bool {
        let left = SyncStoryKey(story: lhs)
        let right = SyncStoryKey(story: rhs)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    static func asset(_ lhs: SyncAssetReference, _ rhs: SyncAssetReference) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.contentSHA256 < rhs.contentSHA256
    }
}

enum SyncScopeProjection {
    struct Content {
        let favorites: Set<WallpaperID>
        let pins: [PinnedOccurrence]
        let occurrences: [WallpaperOccurrence]
        let metadata: [WallpaperMetadataRecord]
        let wallpapers: [WallpaperRecord]
        let stories: [DailyStoryRecord]
        let assets: [SyncAssetReference]
    }

    static func local(_ snapshot: SyncLocalSnapshot, scope: SyncScope) -> Content {
        project(
            favorites: snapshot.favorites,
            pins: snapshot.pinnedOccurrences,
            occurrences: snapshot.occurrences,
            metadata: snapshot.metadata,
            wallpapers: snapshot.wallpapers,
            stories: snapshot.stories,
            assets: snapshot.assets,
            scope: scope
        )
    }

    static func archive(_ archive: SyncArchive, scope: SyncScope) -> Content {
        project(
            favorites: archive.favoriteWallpaperIDs,
            pins: archive.pinnedOccurrences,
            occurrences: archive.occurrences,
            metadata: archive.metadata,
            wallpapers: archive.wallpapers,
            stories: archive.stories,
            assets: archive.assetReferences,
            scope: scope
        )
    }

    private static func project(
        favorites: Set<WallpaperID>,
        pins: Set<PinnedOccurrence>,
        occurrences: [WallpaperOccurrence],
        metadata: [WallpaperMetadataRecord],
        wallpapers: [WallpaperRecord],
        stories: [DailyStoryRecord],
        assets: [SyncAssetReference],
        scope: SyncScope
    ) -> Content {
        let scopedPins = pins
            .filter { scope.includes($0.key.market) }
            .sorted(by: SyncPlanOrder.pin)
        let scopedOccurrences = occurrences
            .filter { scope.includes($0.market) }
            .sorted(by: SyncPlanOrder.occurrence)
        let scopedMetadata = metadata
            .filter { scope.includes($0.key.market) }
            .sorted(by: SyncPlanOrder.metadata)
        let scopedStories = stories
            .filter { scope.includes($0.market) }
            .sorted(by: SyncPlanOrder.story)

        var referencedWallpaperIDs = favorites
        referencedWallpaperIDs.formUnion(scopedOccurrences.map(\.wallpaperID))
        referencedWallpaperIDs.formUnion(scopedMetadata.map(\.wallpaperID))
        referencedWallpaperIDs.formUnion(scopedStories.compactMap(\.associatedWallpaperID))
        referencedWallpaperIDs.formUnion(scopedPins.map(\.wallpaperID))

        let scopedWallpapers = wallpapers
            .filter { scope.includesAllMarkets || referencedWallpaperIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        let scopedAssets = assets
            .filter {
                scope.includes($0.kind)
                    && (scope.includesAllMarkets || referencedWallpaperIDs.contains($0.wallpaperID))
            }
            .sorted(by: SyncPlanOrder.asset)

        return Content(
            favorites: favorites,
            pins: scopedPins,
            occurrences: scopedOccurrences,
            metadata: scopedMetadata,
            wallpapers: scopedWallpapers,
            stories: scopedStories,
            assets: scopedAssets
        )
    }
}
