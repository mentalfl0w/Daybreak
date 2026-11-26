import CryptoKit
import Foundation

// MARK: - Durable local sync state

/// Local-only bookkeeping for optional Phase E synchronization.
///
/// This state is stored inside `repository.json` and is committed together
/// with the repository content it describes. It intentionally does not mirror
/// the shared-folder archive: only this device's immutable operation journal,
/// its causal frontier, the next sequence to issue and the publish cursor are
/// persisted here. Remote archives are rebuilt from operation files by the sync
/// service and never become an authoritative local index.
struct RepositorySyncState: Equatable, Sendable, Codable {
    /// Stable random identity of this repository/device. Created lazily on the
    /// first journal write or bootstrap, never derived from hardware.
    var deviceID: SyncDeviceID?
    /// Next per-device sequence number to issue. Starts at 1 and never moves
    /// backward, even when an import carries a larger remote frontier.
    var nextLocalSequence: UInt64
    /// Causal context observed by this device: its own issued sequence plus
    /// remotely observed frontiers. New user operations carry this context.
    var causalContext: SyncVersionVector
    /// Append-only local operations, in sequence order. Entries are immutable
    /// and are retained after publishing, so favorite/pin removals remain
    /// durable tombstones instead of disappearing with an export checkpoint.
    var localOperations: [SyncOperation]
    /// Highest local sequence durably written to the shared folder. Pending
    /// operations are those above this cursor; the cursor only trims the
    /// publish queue, never the journal.
    var publishedThroughSequence: UInt64
    /// Content-addressed operation IDs already accepted by the merge engine.
    /// Used for diagnostics and cheap replay suppression; merge correctness
    /// does not depend on this set.
    var appliedOperationIDs: [SyncOperationID]
    /// True after the one-time baseline for pre-existing local favorites/pins
    /// has been written. The baseline deliberately carries only local sequence
    /// context so it cannot override remote tombstones.
    var didBootstrap: Bool

    init() {
        self.deviceID = nil
        self.nextLocalSequence = 1
        self.causalContext = SyncVersionVector()
        self.localOperations = []
        self.publishedThroughSequence = 0
        self.appliedOperationIDs = []
        self.didBootstrap = false
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case nextLocalSequence
        case causalContext
        case localOperations
        case publishedThroughSequence
        case appliedOperationIDs
        case didBootstrap
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decodeIfPresent(SyncDeviceID.self, forKey: .deviceID)
        self.nextLocalSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .nextLocalSequence
        ) ?? 1
        self.causalContext = try container.decodeIfPresent(
            SyncVersionVector.self,
            forKey: .causalContext
        ) ?? SyncVersionVector()
        self.localOperations = try container.decodeIfPresent(
            [SyncOperation].self,
            forKey: .localOperations
        ) ?? []
        self.publishedThroughSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .publishedThroughSequence
        ) ?? 0
        self.appliedOperationIDs = try container.decodeIfPresent(
            [SyncOperationID].self,
            forKey: .appliedOperationIDs
        ) ?? []
        self.didBootstrap = try container.decodeIfPresent(
            Bool.self,
            forKey: .didBootstrap
        ) ?? false
    }

    /// Rejects internally inconsistent state instead of silently choosing a
    /// sequence number that could collide with an already published operation.
    func validated() throws -> RepositorySyncState {
        guard nextLocalSequence >= 1 else {
            throw RepositoryError.invalidRecord("sync nextLocalSequence must be at least 1")
        }
        guard publishedThroughSequence <= (localOperations.last?.sequence ?? 0) else {
            throw RepositoryError.invalidRecord("sync publish cursor is ahead of the journal")
        }

        if let deviceID {
            var lastSequence: UInt64 = 0
            var seen: Set<UInt64> = []
            for operation in localOperations {
                guard operation.deviceID == deviceID else {
                    throw RepositoryError.invalidRecord("sync journal contains an operation from another device")
                }
                guard operation.sequence > lastSequence, seen.insert(operation.sequence).inserted else {
                    throw RepositoryError.invalidRecord("sync journal sequence is not strictly increasing")
                }
                lastSequence = operation.sequence
            }
            let ownCounter = causalContext.counter(for: deviceID)
            guard ownCounter >= lastSequence else {
                throw RepositoryError.invalidRecord("sync causal context is behind the local journal")
            }
            guard nextLocalSequence > ownCounter else {
                throw RepositoryError.invalidRecord("sync nextLocalSequence would reuse an issued sequence")
            }
        } else {
            guard localOperations.isEmpty, publishedThroughSequence == 0 else {
                throw RepositoryError.invalidRecord("sync journal exists without a device identity")
            }
        }

        guard Set(appliedOperationIDs).count == appliedOperationIDs.count else {
            throw RepositoryError.invalidRecord("sync applied operation ids are not unique")
        }
        return self
    }

    // MARK: Journal writes

    /// Records one locally originated payload. Sequence assignment and causal
    /// context advancement happen here, so callers never invent either.
    mutating func record(_ payload: SyncOperationPayload) throws -> SyncOperation {
        let device = ensureDeviceID()
        let sequence = nextLocalSequence
        let knownContext = causalContext
        let operation: SyncOperation
        switch payload {
        case .favorite(let change):
            operation = try SyncOperationFactory.favorite(
                wallpaperID: change.wallpaperID,
                isFavorite: change.isFavorite,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        case .pin(let change):
            operation = try SyncOperationFactory.pin(
                key: change.key,
                wallpaperID: change.wallpaperID,
                isPinned: change.isPinned,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        case .occurrence(let record):
            operation = try SyncOperationFactory.occurrence(
                record,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        case .metadata(let record):
            operation = try SyncOperationFactory.metadata(
                record,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        case .wallpaper(let record):
            operation = try SyncOperationFactory.wallpaper(
                record,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        case .story(let record):
            operation = try SyncOperationFactory.story(
                record,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        case .assets(let references):
            operation = try SyncOperationFactory.assets(
                references,
                deviceID: device,
                sequence: sequence,
                knownContext: knownContext
            )
        }
        localOperations.append(operation)
        nextLocalSequence = operation.sequence + 1
        causalContext = operation.context
        return operation
    }

    mutating func recordFavorite(
        _ wallpaperID: WallpaperID,
        isFavorite: Bool
    ) throws -> SyncOperation {
        try record(.favorite(SyncFavoriteChange(
            wallpaperID: wallpaperID,
            isFavorite: isFavorite
        )))
    }

    mutating func recordPin(
        _ key: OccurrenceKey,
        wallpaperID: WallpaperID?,
        isPinned: Bool
    ) throws -> SyncOperation {
        try record(.pin(SyncPinChange(
            key: key,
            wallpaperID: wallpaperID,
            isPinned: isPinned
        )))
    }

    mutating func ensureDeviceID() -> SyncDeviceID {
        if let deviceID { return deviceID }
        let generated = SyncDeviceID.random()
        deviceID = generated
        return generated
    }

    /// Persists deterministic bootstrap operations produced by
    /// `SyncBootstrapPlanner` (or this repository's preference-only baseline)
    /// into the immutable local journal. Already-journaled IDs are skipped;
    /// stale operations that would reuse an issued sequence are ignored.
    @discardableResult
    mutating func appendAuthorizedLocalOperations(
        _ operations: [SyncOperation]
    ) throws -> Int {
        guard !operations.isEmpty else { return 0 }
        let device = ensureDeviceID()
        var appended = 0
        for operation in operations.sorted(by: { $0.sequence < $1.sequence }) {
            guard operation.deviceID == device else {
                throw RepositoryError.invalidRecord("bootstrap operation belongs to another device")
            }
            if localOperations.contains(where: { $0.id == operation.id }) {
                continue
            }
            let lastSequence = localOperations.last?.sequence ?? 0
            guard operation.sequence > lastSequence else { continue }
            localOperations.append(operation)
            if operation.sequence >= nextLocalSequence {
                nextLocalSequence = operation.sequence + 1
            }
            causalContext = Self.mergedContext(causalContext, operation.context)
            appended += 1
        }
        return appended
    }

    /// Vector max, used when learning a remote frontier. The local device's
    /// own counter is never taken from remote data: only this process may
    /// advance it, otherwise a peer could burn local sequence numbers.
    static func mergedContext(
        _ lhs: SyncVersionVector,
        _ rhs: SyncVersionVector,
        ignoringLocal deviceID: SyncDeviceID? = nil
    ) -> SyncVersionVector {
        var counters = lhs.counters
        for (device, sequence) in rhs.counters {
            if device == deviceID { continue }
            guard sequence > 0 else { continue }
            counters[device] = max(counters[device] ?? 0, sequence)
        }
        return (try? SyncVersionVector(counters)) ?? lhs
    }
}

// MARK: - Import summary

/// Result of one atomic remote import. `journalEntriesCreated` is always zero:
/// imported data is applied through a dedicated path and can never become a
/// local outgoing operation.
public struct RepositorySyncImportResult: Hashable, Sendable {
    public let occurrences: UpsertSummary
    public let metadata: UpsertSummary
    public let wallpapers: UpsertSummary
    public let stories: UpsertSummary
    public let favoritesAdded: Int
    public let favoritesRemoved: Int
    public let pinsAdded: Int
    public let pinsRemoved: Int
    public let rejectedRecords: Int
    public let journalEntriesCreated: Int

    init(
        occurrences: UpsertSummary = UpsertSummary(),
        metadata: UpsertSummary = UpsertSummary(),
        wallpapers: UpsertSummary = UpsertSummary(),
        stories: UpsertSummary = UpsertSummary(),
        favoritesAdded: Int = 0,
        favoritesRemoved: Int = 0,
        pinsAdded: Int = 0,
        pinsRemoved: Int = 0,
        rejectedRecords: Int = 0,
        journalEntriesCreated: Int = 0
    ) {
        self.occurrences = occurrences
        self.metadata = metadata
        self.wallpapers = wallpapers
        self.stories = stories
        self.favoritesAdded = favoritesAdded
        self.favoritesRemoved = favoritesRemoved
        self.pinsAdded = pinsAdded
        self.pinsRemoved = pinsRemoved
        self.rejectedRecords = rejectedRecords
        self.journalEntriesCreated = journalEntriesCreated
    }
}

// MARK: - Repository sync API

extension WallpaperRepository {
    /// Returns the stable local device identity, creating and persisting it on
    /// first use. This is a repository-local random value, not a hardware ID.
    public func syncDeviceIdentifier() throws -> SyncDeviceID {
        if let deviceID = index.sync.deviceID {
            return deviceID
        }
        var next = index
        let generated = next.sync.ensureDeviceID()
        try commit(next)
        return generated
    }

    public func syncCausalContext() -> SyncVersionVector {
        index.sync.causalContext
    }

    public func syncNextLocalSequence() -> UInt64 {
        index.sync.nextLocalSequence
    }

    /// Whether the one-time pre-journal baseline has already been established.
    /// Callers must not re-derive this from current content: content imported
    /// from a peer is not pre-journal local state.
    public func syncDidBootstrapBaseline() -> Bool {
        index.sync.didBootstrap
    }

    public func syncPublishedThroughSequence() -> UInt64 {
        index.sync.publishedThroughSequence
    }

    public func syncAppliedOperationIDs() -> [SyncOperationID] {
        index.sync.appliedOperationIDs
    }

    /// Full immutable local journal, including already published entries and
    /// removal tombstones. Re-exporting these entries is replay-idempotent.
    public func syncLocalOperations() -> [SyncOperation] {
        index.sync.localOperations
    }

    /// Local operations not yet acknowledged as written to the shared folder.
    public func pendingSyncOperations() -> [SyncOperation] {
        index.sync.localOperations.filter {
            $0.sequence > index.sync.publishedThroughSequence
        }
    }

    public func pendingSyncOperationFiles() -> [SyncOperationFile] {
        pendingSyncOperations().map(SyncOperationFile.init(operation:))
    }

    /// Builds the content-addressed reference for one cached local image so the
    /// controller can include it in `SyncLocalSnapshot.assets` and publish the
    /// blob. Returns nil when the asset is not indexed or its file is missing.
    public func syncAssetReference(
        kind: AssetKind,
        for wallpaperID: WallpaperID
    ) throws -> SyncAssetReference? {
        let assetID = AssetIdentity.id(kind: kind, wallpaperID: wallpaperID)
        guard let asset = index.assets[assetID],
              let url = store.assetURL(relativePath: asset.relativePath),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        let digest = try Self.digest(ofFileAt: url)
        let reference = SyncAssetReference(
            wallpaperID: asset.wallpaperID,
            kind: asset.kind,
            contentSHA256: digest.digest,
            byteCount: digest.byteCount
        )
        guard reference.isValid else {
            throw RepositoryError.invalidRecord("cached asset is not representable for sync")
        }
        return reference
    }

    /// Materializes a verified remote blob into the local repository.
    ///
    /// The bytes must match the reference's byte count and SHA-256. Identical
    /// local content is returned without rewriting. A different local payload
    /// is never replaced while the image is applied, reserved by an in-flight
    /// wallpaper write, a favorite or a pinned date; that protects the exact
    /// file a system write or user preference may still reference. Importing an
    /// asset never creates a local outgoing operation.
    @discardableResult
    public func importSyncAsset(
        _ data: Data,
        reference: SyncAssetReference,
        fileExtension: String,
        accessedAt: Date? = nil
    ) throws -> CachedImageAsset {
        try reference.validate()
        guard reference.matches(data) else {
            throw RepositoryError.invalidRecord("remote asset does not match its content digest")
        }
        guard !data.isEmpty else {
            throw RepositoryError.emptyAsset
        }

        let assetID = AssetIdentity.id(
            kind: reference.kind,
            wallpaperID: reference.wallpaperID
        )
        if let existing = index.assets[assetID],
           let existingURL = store.assetURL(relativePath: existing.relativePath),
           FileManager.default.fileExists(atPath: existingURL.path) {
            let existingDigest = try Self.digest(ofFileAt: existingURL)
            if existingDigest.digest == reference.contentSHA256,
               existingDigest.byteCount == reference.byteCount {
                return existing
            }
            let isProtected = RepositoryProtection.isProtected(
                reference.wallpaperID,
                favorites: index.favorites,
                pinned: index.pinned,
                applied: index.applied,
                reservations: Set(index.reservations.keys)
            )
            guard !isProtected else {
                throw RepositoryError.protectedAsset(reference.wallpaperID)
            }
        }

        return try storeAsset(
            data,
            kind: reference.kind,
            for: reference.wallpaperID,
            fileExtension: fileExtension,
            accessedAt: accessedAt
        )
    }

    /// Advances the publish cursor through `sequence`. Journal entries are
    /// retained, so tombstones are never lost when the queue is acknowledged.
    @discardableResult
    public func acknowledgeSyncOperationsPublished(through sequence: UInt64) throws -> Int {
        guard sequence > 0 else { return 0 }
        guard sequence > index.sync.publishedThroughSequence else { return 0 }
        guard let lastSequence = index.sync.localOperations.last?.sequence,
              sequence <= lastSequence
        else {
            throw RepositoryError.invalidRecord("cannot publish through an unissued sync sequence")
        }
        let previous = index.sync.publishedThroughSequence
        var next = index
        next.sync.publishedThroughSequence = sequence
        let count = next.sync.localOperations.filter {
            $0.sequence > previous && $0.sequence <= sequence
        }.count
        try commit(next)
        return count
    }

    /// Persists one locally originated operation with a repository-assigned
    /// sequence and causal context in a single atomic commit. Remote data must
    /// never enter through this method; use `applyRemoteSyncChanges` instead.
    @discardableResult
    public func recordLocalSyncOperation(_ payload: SyncOperationPayload) throws -> SyncOperation {
        try validateLocalSyncPayload(payload)
        var next = index
        let operation = try next.sync.record(payload)
        try commit(next)
        return operation
    }

    /// One-time baseline for favorites and pins that existed before the local
    /// journal was introduced. Baseline operations carry only this device's
    /// sequence context (never a remote frontier), so a concurrent remote
    /// removal wins instead of being revived. Targets already represented by
    /// any local add/remove operation are skipped, including current absences.
    @discardableResult
    public func bootstrapSyncJournal() throws -> [SyncOperation] {
        var next = index
        let deviceID = next.sync.ensureDeviceID()
        guard !next.sync.didBootstrap else {
            if next != index {
                try commit(next)
            }
            return []
        }

        var recordedFavorites: Set<WallpaperID> = []
        var recordedPinKeys: Set<OccurrenceKey> = []
        for operation in next.sync.localOperations {
            switch operation.payload {
            case .favorite(let change):
                recordedFavorites.insert(change.wallpaperID)
            case .pin(let change):
                recordedPinKeys.insert(change.key)
            default:
                break
            }
        }

        var baselineContext = SyncVersionVector()
        var sequence = next.sync.nextLocalSequence
        var created: [SyncOperation] = []

        for favorite in next.favorites.sorted() where !recordedFavorites.contains(favorite) {
            let operation = try SyncOperationFactory.favorite(
                wallpaperID: favorite,
                isFavorite: true,
                deviceID: deviceID,
                sequence: sequence,
                knownContext: baselineContext
            )
            next.sync.localOperations.append(operation)
            baselineContext = operation.context
            sequence = operation.sequence + 1
            created.append(operation)
        }

        let sortedPins = next.pinned.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.wallpaperID < rhs.wallpaperID
        }
        for pin in sortedPins where !recordedPinKeys.contains(pin.key) {
            let operation = try SyncOperationFactory.pin(
                key: pin.key,
                wallpaperID: pin.wallpaperID,
                isPinned: true,
                deviceID: deviceID,
                sequence: sequence,
                knownContext: baselineContext
            )
            next.sync.localOperations.append(operation)
            baselineContext = operation.context
            sequence = operation.sequence + 1
            created.append(operation)
        }

        next.sync.nextLocalSequence = sequence
        // The baseline context was created locally, so its own-device counter
        // is authoritative here. Remote counters are preserved by the merge.
        next.sync.causalContext = RepositorySyncState.mergedContext(
            next.sync.causalContext,
            baselineContext
        )
        next.sync.didBootstrap = true
        try commit(next)
        return created
    }

    /// Applies a resolved remote plan. Asset references are deliberately not
    /// registered here: the repository never trusts remote asset metadata or
    /// paths. The controller verifies and materializes blobs through
    /// `storeAsset` after checking content hashes.
    @discardableResult
    public func applySyncMergePlan(_ plan: SyncMergePlan) throws -> RepositorySyncImportResult {
        let mutation = plan.repositoryMutation
        return try applyRemoteSyncChanges(
            occurrences: mutation.occurrencesToUpsert,
            metadata: mutation.metadataToUpsert,
            wallpapers: mutation.wallpapersToUpsert,
            stories: mutation.storiesToUpsert,
            favoritesToAdd: mutation.favoritesToAdd,
            favoritesToRemove: mutation.favoritesToRemove,
            pinsToAdd: mutation.pinsToAdd,
            pinKeysToRemove: mutation.pinKeysToRemove,
            observedContext: plan.causalContext,
            nextLocalSequence: plan.nextLocalSequence,
            acceptedOperationIDs: plan.mergeOutcome.acceptedOperationIDs,
            bootstrapOperations: plan.bootstrapOperations
        )
    }

    /// Atomic, non-destructive remote import primitive.
    ///
    /// - Occurs in one commit, and never appends to the local journal, so an
    ///   imported change cannot echo back out as a locally originated change.
    /// - Validates every identity. Invalid or locally conflicting records are
    ///   skipped and counted as rejected; they never abort the whole batch or
    ///   overwrite valid local data.
    /// - Never touches `applied`, in-flight reservations or cached asset
    ///   files/metadata. Local favorites and pins not named by the plan stay.
    /// - Advance the observed frontier and `nextLocalSequence` only forward.
    @discardableResult
    public func applyRemoteSyncChanges(
        occurrences: [WallpaperOccurrence] = [],
        metadata: [WallpaperMetadataRecord] = [],
        wallpapers: [WallpaperRecord] = [],
        stories: [DailyStoryRecord] = [],
        favoritesToAdd: [WallpaperID] = [],
        favoritesToRemove: [WallpaperID] = [],
        pinsToAdd: [PinnedOccurrence] = [],
        pinKeysToRemove: [OccurrenceKey] = [],
        observedContext: SyncVersionVector? = nil,
        nextLocalSequence: UInt64? = nil,
        acceptedOperationIDs: [SyncOperationID] = [],
        bootstrapOperations: [SyncOperation] = []
    ) throws -> RepositorySyncImportResult {
        var next = index
        var occurrenceStats = UpsertSummary()
        var metadataStats = UpsertSummary()
        var wallpaperStats = UpsertSummary()
        var storyStats = UpsertSummary()
        var rejected = 0
        var favoritesAdded = 0
        var favoritesRemoved = 0
        var pinsAdded = 0
        var pinsRemoved = 0
        var earliestAppliedImportDate: LocalDate?

        for wallpaper in wallpapers {
            switch next.mergeImportedWallpaper(wallpaper) {
            case .inserted:
                wallpaperStats = wallpaperStats.adding(inserted: 1)
            case .updated:
                wallpaperStats = wallpaperStats.adding(updated: 1)
            case .unchanged:
                wallpaperStats = wallpaperStats.adding(unchanged: 1)
            case .ignored:
                wallpaperStats = wallpaperStats.adding(ignored: 1)
            case .rejected:
                rejected += 1
            }
        }

        for occurrence in occurrences {
            let mergeResult = next.mergeImportedOccurrence(occurrence)
            switch mergeResult {
            case .inserted:
                occurrenceStats = occurrenceStats.adding(inserted: 1)
            case .updated:
                occurrenceStats = occurrenceStats.adding(updated: 1)
            case .unchanged:
                occurrenceStats = occurrenceStats.adding(unchanged: 1)
            case .ignored:
                occurrenceStats = occurrenceStats.adding(ignored: 1)
            case .rejected:
                rejected += 1
            }
            if mergeResult == .inserted || mergeResult == .updated {
                if let earliest = earliestAppliedImportDate {
                    if occurrence.localDate < earliest {
                        earliestAppliedImportDate = occurrence.localDate
                    }
                } else {
                    earliestAppliedImportDate = occurrence.localDate
                }
            }
        }

        for record in metadata {
            switch next.mergeImportedMetadata(record) {
            case .inserted:
                metadataStats = metadataStats.adding(inserted: 1)
            case .updated:
                metadataStats = metadataStats.adding(updated: 1)
            case .unchanged:
                metadataStats = metadataStats.adding(unchanged: 1)
            case .ignored:
                metadataStats = metadataStats.adding(ignored: 1)
            case .rejected:
                rejected += 1
            }
        }

        for story in stories {
            switch next.mergeImportedStory(story) {
            case .inserted:
                storyStats = storyStats.adding(inserted: 1)
            case .updated:
                storyStats = storyStats.adding(updated: 1)
            case .unchanged:
                storyStats = storyStats.adding(unchanged: 1)
            case .ignored:
                storyStats = storyStats.adding(ignored: 1)
            case .rejected:
                rejected += 1
            }
        }

        for key in pinKeysToRemove {
            guard key.isValid else {
                rejected += 1
                continue
            }
            let before = next.pinned.count
            next.pinned = next.pinned.filter { $0.key != key }
            if next.pinned.count != before {
                pinsRemoved += 1
            }
        }

        for pin in pinsToAdd {
            do {
                try RepositoryValidation.validate(pin)
            } catch {
                rejected += 1
                continue
            }
            // A pin names a date; once the local occurrence for that date has
            // a newer revision with another image, the local pin is rebound to
            // the local occurrence (see `mergeImportedOccurrence`). Mirror that
            // here instead of rejecting the archive's pin-time image forever.
            let resolved = PinnedOccurrence(
                key: pin.key,
                wallpaperID: next.occurrences[pin.key]?.wallpaperID ?? pin.wallpaperID
            )
            if next.pinned.contains(resolved) {
                continue
            }
            next.pinned = next.pinned.filter { $0.key != pin.key }
            next.pinned.insert(resolved)
            pinsAdded += 1
        }

        for favorite in favoritesToAdd {
            do {
                try RepositoryValidation.validate(favorite)
            } catch {
                rejected += 1
                continue
            }
            if next.favorites.insert(favorite).inserted {
                favoritesAdded += 1
            }
        }

        // Remove after add: a plan that names the same image in both sets
        // resolves to removal, matching tombstone remove-wins semantics.
        for favorite in favoritesToRemove {
            do {
                try RepositoryValidation.validate(favorite)
            } catch {
                rejected += 1
                continue
            }
            if next.favorites.remove(favorite) != nil {
                favoritesRemoved += 1
            }
        }

        // Imported history may predate the local observation start. Expanding
        // the lower bound makes those dated records visible to recap; it never
        // fabricates missing days, so the wider window stays partial unless
        // every eligible day actually has a stored occurrence.
        //
        // `observationStartedAt` is deliberately unchanged: it records this
        // device's first local occurrence commit, and imported records do not
        // carry a trustworthy local observation timestamp.
        if let earliestAppliedImportDate {
            if let currentStart = next.firstObservedDate {
                if earliestAppliedImportDate < currentStart {
                    next.firstObservedDate = earliestAppliedImportDate
                }
            } else if let earliestStored = next.occurrences.values.map(\.localDate).min() {
                next.firstObservedDate = earliestStored
            }
        } else if next.firstObservedDate == nil,
                  let newest = next.occurrences.values.map(\.localDate).max() {
            next.firstObservedDate = newest
        }

        // Bootstrap operations were authored by this device. Persist them in
        // the immutable journal so they can be published/acked like any other
        // local operation and are never recreated with a colliding sequence.
        if !bootstrapOperations.isEmpty {
            _ = try next.sync.appendAuthorizedLocalOperations(bootstrapOperations)
            next.sync.didBootstrap = true
        }

        if let observedContext {
            next.sync.causalContext = RepositorySyncState.mergedContext(
                next.sync.causalContext,
                observedContext,
                ignoringLocal: next.sync.deviceID
            )
        }
        if let nextLocalSequence,
           nextLocalSequence > next.sync.nextLocalSequence {
            next.sync.nextLocalSequence = nextLocalSequence
        }
        if let deviceID = next.sync.deviceID {
            let required = next.sync.causalContext.counter(for: deviceID) + 1
            if next.sync.nextLocalSequence < required {
                next.sync.nextLocalSequence = required
            }
        }
        if !acceptedOperationIDs.isEmpty {
            var known = Set(next.sync.appliedOperationIDs)
            for operationID in acceptedOperationIDs where known.insert(operationID).inserted {
                next.sync.appliedOperationIDs.append(operationID)
            }
        }

        if next != index {
            try commit(next)
        }

        return RepositorySyncImportResult(
            occurrences: occurrenceStats,
            metadata: metadataStats,
            wallpapers: wallpaperStats,
            stories: storyStats,
            favoritesAdded: favoritesAdded,
            favoritesRemoved: favoritesRemoved,
            pinsAdded: pinsAdded,
            pinsRemoved: pinsRemoved,
            rejectedRecords: rejected,
            journalEntriesCreated: 0
        )
    }

    private static func digest(
        ofFileAt url: URL
    ) throws -> (digest: SyncContentDigest, byteCount: Int) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RepositoryError.invalidRecord("cannot read cached asset for hashing")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount = 0
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 1024 * 1024),
                      !next.isEmpty
                else {
                    break
                }
                chunk = next
            } catch {
                throw RepositoryError.invalidRecord("cannot hash cached asset")
            }
            byteCount += chunk.count
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let digest = SyncContentDigest(hex: hex) else {
            throw RepositoryError.invalidRecord("cached asset hash is not canonical")
        }
        return (digest, byteCount)
    }

    private func validateLocalSyncPayload(_ payload: SyncOperationPayload) throws {
        switch payload {
        case .favorite(let change):
            try RepositoryValidation.validate(change.wallpaperID)
        case .pin(let change):
            guard change.key.isValid else {
                throw RepositoryError.invalidRecord("invalid sync pin occurrence key")
            }
            if let wallpaperID = change.wallpaperID {
                try RepositoryValidation.validate(wallpaperID)
                guard change.key.source == wallpaperID.source else {
                    throw RepositoryError.pinIdentityMismatch(change.key)
                }
            } else if change.isPinned {
                throw RepositoryError.invalidRecord("pinning requires a wallpaper identity")
            }
        case .occurrence(let record):
            try RepositoryValidation.validate(record)
        case .metadata(let record):
            try RepositoryValidation.validate(record)
        case .wallpaper(let record):
            try RepositoryValidation.validate(record)
        case .story(let record):
            try RepositoryValidation.validate(record)
        case .assets:
            break
        }
    }
}

// MARK: - Import merge helpers

private enum RepositoryImportMergeResult: Equatable {
    case inserted
    case updated
    case unchanged
    case ignored
    case rejected
}

private extension UpsertSummary {
    func adding(
        inserted: Int = 0,
        updated: Int = 0,
        unchanged: Int = 0,
        ignored: Int = 0
    ) -> UpsertSummary {
        UpsertSummary(
            inserted: self.inserted + inserted,
            updated: self.updated + updated,
            unchanged: self.unchanged + unchanged,
            ignored: self.ignored + ignored
        )
    }
}

private extension RepositoryIndex {
    mutating func mergeImportedOccurrence(
        _ occurrence: WallpaperOccurrence
    ) -> RepositoryImportMergeResult {
        do {
            try RepositoryValidation.validate(occurrence)
        } catch {
            return .rejected
        }

        if let existing = occurrences[occurrence.id] {
            if occurrence.revision < existing.revision {
                return .ignored
            }
            if occurrence.revision == existing.revision {
                guard occurrence.wallpaperID == existing.wallpaperID else {
                    // A same-revision image change is an upstream conflict.
                    // Keep the local observation instead of flip-flopping.
                    return .rejected
                }
                if existing.publisherTime == nil, let publisherTime = occurrence.publisherTime {
                    occurrences[occurrence.id] = existing.withPublisherTime(publisherTime)
                    return .updated
                }
                return .unchanged
            }

            if occurrence.wallpaperID != existing.wallpaperID {
                metadata[occurrence.id] = nil
                pinned = Set(pinned.map { pin in
                    pin.key == occurrence.id
                        ? PinnedOccurrence(key: pin.key, wallpaperID: occurrence.wallpaperID)
                        : pin
                })
            }
            occurrences[occurrence.id] = occurrence
            return .updated
        }

        if let existingMetadata = metadata[occurrence.id],
           existingMetadata.wallpaperID != occurrence.wallpaperID {
            metadata[occurrence.id] = nil
        }
        occurrences[occurrence.id] = occurrence
        return .inserted
    }

    mutating func mergeImportedMetadata(
        _ record: WallpaperMetadataRecord
    ) -> RepositoryImportMergeResult {
        do {
            try RepositoryValidation.validate(record)
        } catch {
            return .rejected
        }
        if let occurrence = occurrences[record.key],
           occurrence.wallpaperID != record.wallpaperID {
            return .rejected
        }

        guard let existing = metadata[record.key] else {
            metadata[record.key] = record
            return .inserted
        }
        if existing == record {
            return .unchanged
        }
        if record.fetchedAt < existing.fetchedAt {
            return .ignored
        }
        // Equal timestamps are only reached with an engine-resolved plan.
        // Applying that record is deterministic for the plan; direct callers
        // must not supply unresolved same-time conflicts.
        metadata[record.key] = record
        return .updated
    }

    mutating func mergeImportedWallpaper(
        _ wallpaper: WallpaperRecord
    ) -> RepositoryImportMergeResult {
        do {
            try RepositoryValidation.validate(wallpaper)
        } catch {
            return .rejected
        }

        guard let existing = wallpapers[wallpaper.id] else {
            wallpapers[wallpaper.id] = wallpaper
            return .inserted
        }
        if existing == wallpaper {
            return .unchanged
        }
        if wallpaper.fetchedAt < existing.fetchedAt {
            return .ignored
        }
        wallpapers[wallpaper.id] = wallpaper
        return .updated
    }

    mutating func mergeImportedStory(
        _ story: DailyStoryRecord
    ) -> RepositoryImportMergeResult {
        do {
            try RepositoryValidation.validate(story)
            switch try RepositoryStoryRevision.merge(story, into: &stories) {
            case .inserted:
                return .inserted
            case .updated:
                return .updated
            case .unchanged:
                return .unchanged
            case .ignored:
                return .ignored
            }
        } catch {
            // Provenance or same-time content conflict. Keep local data.
            return .rejected
        }
    }
}
