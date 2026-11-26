import Foundation

// MARK: - Schema and errors

public enum RepositorySchema {
    /// Increment when the on-disk index shape changes. Bump/add a migration
    /// step in `RepositoryFileStore.decode` at the same time.
    ///
    /// Version 2 adds persisted in-flight write reservations. Version 1's
    /// `appliedWallpapers` array was a monotonically growing historical set;
    /// it is ignored on load because current-desktop protection is re-derived
    /// from live system state instead of persisted.
    ///
    /// Version 3 adds the local sync journal (device identity, causal context,
    /// immutable local operations, publish cursor). The field is optional on
    /// read, so version 1 and version 2 indexes still load; the next commit
    /// rewrites them as version 3. No data is dropped by that migration.
    public static let currentVersion = 3

    /// A reservation only has to survive one system wallpaper write. A crash
    /// can leave a reservation behind, but it must not protect an image
    /// forever, so a stale reservation expires on the next launch.
    static let inFlightWriteLifetime: TimeInterval = 15 * 60
}

public enum RepositoryLoadState: String, Hashable, Sendable, Codable {
    case empty
    case loaded
    case recoveredFromBackup
    case migratedLegacyCache
}

public enum RepositoryError: Error, Hashable, Sendable, LocalizedError {
    case invalidDirectory(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case unreadableIndex(primary: String, backup: String?)
    case invalidRecord(String)
    case occurrenceConflict(OccurrenceKey)
    case metadataConflict(OccurrenceKey)
    case wallpaperConflict(WallpaperID)
    case storyConflict(String)
    case pinIdentityMismatch(OccurrenceKey)
    case emptyAsset
    case invalidAssetExtension(String)
    case protectedAsset(WallpaperID)
    case assetWriteFailed(String)
    case writeFailed(String)
    case migrationFailed(String)
    case repairFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path):
            return "The repository directory is not usable: \(path)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "Repository schema version \(found) is not supported (this build reads version \(supported))."
        case .unreadableIndex(let primary, let backup):
            if let backup {
                return "The repository index is unreadable (\(primary)); the backup is also unreadable (\(backup))."
            }
            return "The repository index is unreadable and no usable backup exists (\(primary))."
        case .invalidRecord(let detail):
            return "Invalid repository record: \(detail)"
        case .occurrenceConflict(let key):
            return "Conflicting wallpaper identity for the same occurrence revision: \(key)."
        case .metadataConflict(let key):
            return "Conflicting metadata at the same fetch time for \(key)."
        case .wallpaperConflict(let id):
            return "Conflicting wallpaper metadata at the same fetch time for \(id)."
        case .storyConflict(let id):
            return "Conflicting story content at the same fetch time for \(id)."
        case .pinIdentityMismatch(let key):
            return "Pinned occurrence \(key) does not match the supplied wallpaper identity."
        case .emptyAsset:
            return "Refusing to store an empty image asset."
        case .invalidAssetExtension(let value):
            return "Invalid image asset extension: \(value)."
        case .protectedAsset(let wallpaperID):
            return "Refusing to delete a protected image asset: \(wallpaperID)."
        case .assetWriteFailed(let detail):
            return "Could not write an image asset: \(detail)"
        case .writeFailed(let detail):
            return "Could not write the repository index: \(detail)"
        case .migrationFailed(let detail):
            return "Legacy cache migration failed: \(detail)"
        case .repairFailed(let detail):
            return "Repository repair failed: \(detail)"
        }
    }
}

public struct UpsertSummary: Hashable, Sendable {
    public let inserted: Int
    public let updated: Int
    public let unchanged: Int
    public let ignored: Int

    public init(inserted: Int = 0, updated: Int = 0, unchanged: Int = 0, ignored: Int = 0) {
        self.inserted = inserted
        self.updated = updated
        self.unchanged = unchanged
        self.ignored = ignored
    }

    public var totalProcessed: Int { inserted + updated + unchanged + ignored }
}

// MARK: - Cache policy and reports

public struct CacheLimits: Hashable, Sendable {
    public let thumbnailBytes: Int
    public let originalBytes: Int

    public init(
        thumbnailBytes: Int = 200_000_000,
        originalBytes: Int = 800_000_000
    ) {
        self.thumbnailBytes = thumbnailBytes
        self.originalBytes = originalBytes
    }
}

public struct CacheEvictionResult: Hashable, Sendable {
    public let evictedAssets: [CachedImageAsset]
    public let evictedBytes: Int
    public let thumbnailBytesAfter: Int
    public let originalBytesAfter: Int

    public init(
        evictedAssets: [CachedImageAsset] = [],
        evictedBytes: Int = 0,
        thumbnailBytesAfter: Int = 0,
        originalBytesAfter: Int = 0
    ) {
        self.evictedAssets = evictedAssets
        self.evictedBytes = evictedBytes
        self.thumbnailBytesAfter = thumbnailBytesAfter
        self.originalBytesAfter = originalBytesAfter
    }
}

public struct StorageUsage: Hashable, Sendable {
    public let thumbnailBytes: Int
    public let originalBytes: Int
    public let assetCount: Int
    public let missingAssetCount: Int

    public init(
        thumbnailBytes: Int,
        originalBytes: Int,
        assetCount: Int,
        missingAssetCount: Int
    ) {
        self.thumbnailBytes = thumbnailBytes
        self.originalBytes = originalBytes
        self.assetCount = assetCount
        self.missingAssetCount = missingAssetCount
    }

    public var totalAssetBytes: Int { thumbnailBytes + originalBytes }
}

public struct RepositoryRepairReport: Hashable, Sendable {
    public let missingAssets: [CachedImageAsset]
    public let orphanedFilesRemoved: [String]
    public let failedOrphanRemovals: [String]

    public init(
        missingAssets: [CachedImageAsset] = [],
        orphanedFilesRemoved: [String] = [],
        failedOrphanRemovals: [String] = []
    ) {
        self.missingAssets = missingAssets
        self.orphanedFilesRemoved = orphanedFilesRemoved
        self.failedOrphanRemovals = failedOrphanRemovals
    }
}

// MARK: - Cached asset identity

public enum AssetIdentity {
    /// Stable, filesystem-safe identity for one wallpaper variant.
    ///
    /// UTF-8 bytes are hex encoded, so colons, slashes, percent signs and case
    /// differences cannot collide on a case-insensitive volume.
    public static func id(kind: AssetKind, wallpaperID: WallpaperID) -> String {
        "\(kind.rawValue)-\(hex(wallpaperID.source.rawValue))-\(hex(wallpaperID.sourceImageID))"
    }

    static func fileStem(kind: AssetKind, wallpaperID: WallpaperID) -> String {
        id(kind: kind, wallpaperID: wallpaperID)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hex(_ value: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count * 2)
        for byte in value.utf8 {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// One local thumbnail or original file tracked by the repository.
///
/// Protection is deliberately not stored here: favorites, pinned dates and
/// currently applied images are separate source-of-truth sets. Duplicating
/// `pinReasons` on an asset lets the two drift after a crash.
public struct CachedImageAsset: Hashable, Sendable, Codable, Identifiable {
    public let wallpaperID: WallpaperID
    public let kind: AssetKind
    public let relativePath: String
    public let byteCount: Int
    public let lastAccessedAt: Date

    public init(
        wallpaperID: WallpaperID,
        kind: AssetKind,
        relativePath: String,
        byteCount: Int,
        lastAccessedAt: Date
    ) {
        self.wallpaperID = wallpaperID
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.lastAccessedAt = lastAccessedAt
    }

    public var id: String {
        AssetIdentity.id(kind: kind, wallpaperID: wallpaperID)
    }

    public var isValid: Bool {
        wallpaperID.isValid
            && byteCount >= 0
            && RepositoryPath.isSafeRelativePath(relativePath)
    }

    private enum CodingKeys: String, CodingKey {
        case wallpaperID
        case kind
        case relativePath
        case byteCount
        case lastAccessedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = CachedImageAsset(
            wallpaperID: try container.decode(WallpaperID.self, forKey: .wallpaperID),
            kind: try container.decode(AssetKind.self, forKey: .kind),
            relativePath: try container.decode(String.self, forKey: .relativePath),
            byteCount: try container.decode(Int.self, forKey: .byteCount),
            lastAccessedAt: try container.decode(Date.self, forKey: .lastAccessedAt)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .relativePath,
                in: container,
                debugDescription: "Cached asset path, identity, or byte count is invalid"
            )
        }
        self = value
    }
}

public struct PinnedOccurrence: Hashable, Sendable, Codable {
    public let key: OccurrenceKey
    public let wallpaperID: WallpaperID

    public init(key: OccurrenceKey, wallpaperID: WallpaperID) {
        self.key = key
        self.wallpaperID = wallpaperID
    }

    public var isValid: Bool {
        key.isValid && wallpaperID.isValid && key.source == wallpaperID.source
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case wallpaperID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = PinnedOccurrence(
            key: try container.decode(OccurrenceKey.self, forKey: .key),
            wallpaperID: try container.decode(WallpaperID.self, forKey: .wallpaperID)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .wallpaperID,
                in: container,
                debugDescription: "Pinned occurrence source does not match its wallpaper identity"
            )
        }
        self = value
    }
}

// MARK: - Snapshot

/// Point-in-time immutable view for calendar, recap and UI code.
public struct RepositorySnapshot: Hashable, Sendable {
    public let schemaVersion: Int
    /// How the in-memory state was obtained when this repository instance was
    /// opened. It is diagnostic; updates do not rewrite it to `.loaded`.
    public let loadState: RepositoryLoadState
    public let occurrences: [WallpaperOccurrence]
    public let metadata: [WallpaperMetadataRecord]
    public let wallpapers: [WallpaperRecord]
    public let stories: [DailyStoryRecord]
    public let assets: [CachedImageAsset]
    public let missingAssets: [CachedImageAsset]
    public let favoriteWallpaperIDs: Set<WallpaperID>
    public let pinnedOccurrences: Set<PinnedOccurrence>
    /// Original images used by currently accessible desktops. In-flight write
    /// reservations are tracked separately and are not reported here.
    public let appliedWallpapers: Set<WallpaperID>
    /// Global observation start. `nil` means unknown and recap must not invent
    /// a denominator. Pre-install/backfill dates never move it backward.
    public let firstObservedDate: LocalDate?
    /// First successful occurrence commit wall-clock time. `nil` for legacy
    /// imports where the original timestamp is unknown.
    public let observationStartedAt: Date?

    public init(
        schemaVersion: Int = RepositorySchema.currentVersion,
        loadState: RepositoryLoadState = .loaded,
        occurrences: [WallpaperOccurrence] = [],
        metadata: [WallpaperMetadataRecord] = [],
        wallpapers: [WallpaperRecord] = [],
        stories: [DailyStoryRecord] = [],
        assets: [CachedImageAsset] = [],
        missingAssets: [CachedImageAsset] = [],
        favoriteWallpaperIDs: Set<WallpaperID> = [],
        pinnedOccurrences: Set<PinnedOccurrence> = [],
        appliedWallpapers: Set<WallpaperID> = [],
        firstObservedDate: LocalDate? = nil,
        observationStartedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.loadState = loadState
        self.occurrences = occurrences
        self.metadata = metadata
        self.wallpapers = wallpapers
        self.stories = stories
        self.assets = assets
        self.missingAssets = missingAssets
        self.favoriteWallpaperIDs = favoriteWallpaperIDs
        self.pinnedOccurrences = pinnedOccurrences
        self.appliedWallpapers = appliedWallpapers
        self.firstObservedDate = firstObservedDate
        self.observationStartedAt = observationStartedAt
    }

    public var availableThumbnailIDs: Set<WallpaperID> {
        availableIDs(kind: .thumbnail)
    }

    public var availableOriginalIDs: Set<WallpaperID> {
        availableIDs(kind: .original)
    }

    public func pinReasons(for wallpaperID: WallpaperID) -> Set<PinReason> {
        RepositoryProtection.reasons(
            for: wallpaperID,
            favorites: favoriteWallpaperIDs,
            pinned: pinnedOccurrences,
            applied: appliedWallpapers
        )
    }

    public func metadata(for key: OccurrenceKey) -> WallpaperMetadataRecord? {
        self.metadata.first { $0.key == key }
    }

    public func story(id: String) -> DailyStoryRecord? {
        stories.first { $0.id == id }
    }

    public func asset(kind: AssetKind, for wallpaperID: WallpaperID) -> CachedImageAsset? {
        self.assets.first { $0.kind == kind && $0.wallpaperID == wallpaperID }
    }

    public func assets(for wallpaperID: WallpaperID) -> [CachedImageAsset] {
        self.assets.filter { $0.wallpaperID == wallpaperID }.sorted { $0.id < $1.id }
    }

    public func storyMatch(for key: OccurrenceKey) -> StoryMatch? {
        guard let occurrence = occurrences.first(where: { $0.id == key }) else { return nil }
        return StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadata(for: key),
            stories: stories
        )
    }

    private func availableIDs(kind: AssetKind) -> Set<WallpaperID> {
        let missing = Set(self.missingAssets.map(\.id))
        return Set(
            self.assets
                .filter { $0.kind == kind && !missing.contains($0.id) }
                .map(\.wallpaperID)
        )
    }
}

/// Narrow seam so calendar/recap code can be tested without the actor.
public protocol RepositorySnapshotProviding: Sendable {
    func repositorySnapshot() async throws -> RepositorySnapshot
}

// MARK: - Repository

public actor WallpaperRepository {
    public nonisolated let directory: URL

    var index: RepositoryIndex
    private let initialLoadState: RepositoryLoadState
    private let now: @Sendable () -> Date
    let store: RepositoryFileStore

    /// Opens or creates the repository at the requested directory.
    ///
    /// The directory is created when missing. A corrupt primary index falls
    /// back to `repository.json.backup`; a newer schema is never downgraded.
    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let normalized = directory.standardizedFileURL
        let store = RepositoryFileStore(directory: normalized)
        let loaded = try store.load()
        let currentTime = now()
        self.directory = normalized
        self.index = loaded.index.filteringExpiredReservations(now: currentTime)
        self.initialLoadState = loaded.state
        self.now = now
        self.store = store
    }

    // MARK: Snapshot and queries

    public func snapshot() -> RepositorySnapshot {
        RepositorySnapshot(
            schemaVersion: RepositorySchema.currentVersion,
            loadState: initialLoadState,
            occurrences: OccurrenceIndex.latest(Array(index.occurrences.values)),
            metadata: index.metadata.values.sorted { $0.key < $1.key },
            wallpapers: index.wallpapers.values.sorted { $0.id < $1.id },
            stories: index.stories.values.sorted { $0.id < $1.id },
            assets: index.assets.values.sorted { $0.id < $1.id },
            missingAssets: computeMissingAssets(),
            favoriteWallpaperIDs: index.favorites,
            pinnedOccurrences: index.pinned,
            appliedWallpapers: index.applied,
            firstObservedDate: index.firstObservedDate,
            observationStartedAt: index.observationStartedAt
        )
    }

    public func occurrence(for key: OccurrenceKey) -> WallpaperOccurrence? {
        index.occurrences[key]
    }

    public func occurrences(
        market: Market? = nil,
        source: SourceID? = nil,
        from: LocalDate? = nil,
        through: LocalDate? = nil
    ) -> [WallpaperOccurrence] {
        OccurrenceIndex.latest(Array(index.occurrences.values)).filter { occurrence in
            if let market, occurrence.market != market { return false }
            if let source, occurrence.source != source { return false }
            if let from, occurrence.localDate < from { return false }
            if let through, occurrence.localDate > through { return false }
            return true
        }
    }

    public func metadata(for key: OccurrenceKey) -> WallpaperMetadataRecord? {
        index.metadata[key]
    }

    public func metadata(
        market: Market? = nil,
        from: LocalDate? = nil,
        through: LocalDate? = nil
    ) -> [WallpaperMetadataRecord] {
        index.metadata.values.filter { record in
            if let market, record.key.market != market { return false }
            if let from, record.key.localDate < from { return false }
            if let through, record.key.localDate > through { return false }
            return true
        }
        .sorted { $0.key < $1.key }
    }

    public func wallpaper(_ wallpaperID: WallpaperID) -> WallpaperRecord? {
        index.wallpapers[wallpaperID]
    }

    public func stories(
        market: Market? = nil,
        source: SourceID? = nil,
        date: LocalDate? = nil
    ) -> [DailyStoryRecord] {
        index.stories.values.filter { story in
            if let market, story.market != market { return false }
            if let source, story.source != source { return false }
            if let date, story.date != date { return false }
            return true
        }
        .sorted { $0.id < $1.id }
    }

    public func story(id: String) -> DailyStoryRecord? {
        index.stories[id]
    }

    public func storyMatch(for key: OccurrenceKey) -> StoryMatch? {
        guard let occurrence = index.occurrences[key] else { return nil }
        return StoryMatcher.match(
            occurrence: occurrence,
            metadata: index.metadata[key],
            stories: Array(index.stories.values)
        )
    }

    public func assets(for wallpaperID: WallpaperID) -> [CachedImageAsset] {
        index.assets.values
            .filter { $0.wallpaperID == wallpaperID }
            .sorted { $0.id < $1.id }
    }

    public func asset(kind: AssetKind, for wallpaperID: WallpaperID) -> CachedImageAsset? {
        index.assets[AssetIdentity.id(kind: kind, wallpaperID: wallpaperID)]
    }

    public func assetURL(for asset: CachedImageAsset) -> URL? {
        store.assetURL(relativePath: asset.relativePath)
    }

    public func assetURL(kind: AssetKind, for wallpaperID: WallpaperID) -> URL? {
        guard let asset = asset(kind: kind, for: wallpaperID) else { return nil }
        return store.assetURL(relativePath: asset.relativePath)
    }

    public func missingAssets() -> [CachedImageAsset] {
        computeMissingAssets()
    }

    public func pinReasons(for wallpaperID: WallpaperID) -> Set<PinReason> {
        RepositoryProtection.reasons(
            for: wallpaperID,
            favorites: index.favorites,
            pinned: index.pinned,
            applied: index.applied
        )
    }

    public func storageUsage() -> StorageUsage {
        var thumbnailBytes = 0
        var originalBytes = 0
        for asset in index.assets.values {
            switch asset.kind {
            case .thumbnail:
                thumbnailBytes += asset.byteCount
            case .original:
                originalBytes += asset.byteCount
            }
        }
        return StorageUsage(
            thumbnailBytes: thumbnailBytes,
            originalBytes: originalBytes,
            assetCount: index.assets.count,
            missingAssetCount: computeMissingAssets().count
        )
    }

    // MARK: Writes

    @discardableResult
    public func upsertOccurrences(_ occurrences: [WallpaperOccurrence]) throws -> UpsertSummary {
        guard !occurrences.isEmpty else { return UpsertSummary() }
        for occurrence in occurrences {
            try RepositoryValidation.validate(occurrence)
        }

        var next = index
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var ignored = 0

        for occurrence in occurrences {
            if let existing = next.occurrences[occurrence.id] {
                if occurrence.revision < existing.revision {
                    ignored += 1
                    continue
                }
                if occurrence.revision == existing.revision {
                    guard occurrence.wallpaperID == existing.wallpaperID else {
                        throw RepositoryError.occurrenceConflict(occurrence.id)
                    }
                    if existing.publisherTime == nil, let publisherTime = occurrence.publisherTime {
                        next.occurrences[occurrence.id] = existing.withPublisherTime(publisherTime)
                        updated += 1
                    } else {
                        unchanged += 1
                    }
                    continue
                }

                // A newer revision may change the image. Localized metadata and
                // a pinned date's protected image follow the authoritative row.
                if occurrence.wallpaperID != existing.wallpaperID {
                    next.metadata[occurrence.id] = nil
                    next.pinned = Set(next.pinned.map { pin in
                        pin.key == occurrence.id
                            ? PinnedOccurrence(key: pin.key, wallpaperID: occurrence.wallpaperID)
                            : pin
                    })
                }
                next.occurrences[occurrence.id] = occurrence
                updated += 1
            } else {
                if let metadata = next.metadata[occurrence.id],
                   metadata.wallpaperID != occurrence.wallpaperID {
                    next.metadata[occurrence.id] = nil
                }
                next.occurrences[occurrence.id] = occurrence
                inserted += 1
            }
        }

        if inserted > 0 || updated > 0 {
            if next.firstObservedDate == nil {
                next.firstObservedDate = next.occurrences.values.map(\.localDate).max()
            }
            if next.observationStartedAt == nil {
                next.observationStartedAt = now()
            }
        }

        if next != index {
            try commit(next)
        }
        return UpsertSummary(
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            ignored: ignored
        )
    }

    @discardableResult
    public func upsertMetadata(_ records: [WallpaperMetadataRecord]) throws -> UpsertSummary {
        guard !records.isEmpty else { return UpsertSummary() }
        for record in records {
            try RepositoryValidation.validate(record)
        }

        var next = index
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var ignored = 0

        for record in records {
            if let occurrence = next.occurrences[record.key],
               occurrence.wallpaperID != record.wallpaperID {
                throw RepositoryError.metadataConflict(record.key)
            }

            if let existing = next.metadata[record.key] {
                if existing == record {
                    unchanged += 1
                } else if record.fetchedAt > existing.fetchedAt {
                    next.metadata[record.key] = record
                    updated += 1
                } else if record.fetchedAt < existing.fetchedAt {
                    ignored += 1
                } else {
                    throw RepositoryError.metadataConflict(record.key)
                }
            } else {
                next.metadata[record.key] = record
                inserted += 1
            }
        }

        if next != index {
            try commit(next)
        }
        return UpsertSummary(
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            ignored: ignored
        )
    }

    @discardableResult
    public func upsertWallpapers(_ wallpapers: [WallpaperRecord]) throws -> UpsertSummary {
        guard !wallpapers.isEmpty else { return UpsertSummary() }
        for wallpaper in wallpapers {
            try RepositoryValidation.validate(wallpaper)
        }

        var next = index
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var ignored = 0

        for wallpaper in wallpapers {
            if let existing = next.wallpapers[wallpaper.id] {
                if existing == wallpaper {
                    unchanged += 1
                } else if wallpaper.fetchedAt > existing.fetchedAt {
                    next.wallpapers[wallpaper.id] = wallpaper
                    updated += 1
                } else if wallpaper.fetchedAt < existing.fetchedAt {
                    ignored += 1
                } else {
                    throw RepositoryError.wallpaperConflict(wallpaper.id)
                }
            } else {
                next.wallpapers[wallpaper.id] = wallpaper
                inserted += 1
            }
        }

        if next != index {
            try commit(next)
        }
        return UpsertSummary(
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            ignored: ignored
        )
    }

    @discardableResult
    public func upsertStories(_ stories: [DailyStoryRecord]) throws -> UpsertSummary {
        guard !stories.isEmpty else { return UpsertSummary() }
        for story in stories {
            try RepositoryValidation.validate(story)
        }

        var next = index
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var ignored = 0

        // Normalize revisions left by older builds before merging this batch.
        RepositoryStoryRevision.collapseSuperseded(in: &next.stories)

        for story in stories {
            let result = try RepositoryStoryRevision.merge(story, into: &next.stories)
            switch result {
            case .inserted:
                inserted += 1
            case .updated:
                updated += 1
            case .unchanged:
                unchanged += 1
            case .ignored:
                ignored += 1
            }
        }

        if next != index {
            try commit(next)
        }
        return UpsertSummary(
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            ignored: ignored
        )
    }

    /// Writes a new asset file first, then commits the index. On a failed
    /// commit the new file is removed; a crash in between leaves an orphan
    /// that `repair()` removes.
    @discardableResult
    public func storeAsset(
        _ data: Data,
        kind: AssetKind,
        for wallpaperID: WallpaperID,
        fileExtension: String,
        accessedAt: Date? = nil
    ) throws -> CachedImageAsset {
        try RepositoryValidation.validate(wallpaperID)
        guard !data.isEmpty else { throw RepositoryError.emptyAsset }
        let fileExtension = try RepositoryValidation.assetExtension(fileExtension)

        let assetID = AssetIdentity.id(kind: kind, wallpaperID: wallpaperID)
        let fileName = "\(AssetIdentity.fileStem(kind: kind, wallpaperID: wallpaperID))-\(UUID().uuidString.lowercased()).\(fileExtension)"
        let relativePath = "Assets/\(kind.rawValue)/\(fileName)"
        guard let url = store.assetURL(relativePath: relativePath) else {
            throw RepositoryError.invalidRecord("generated an unsafe asset path")
        }

        try store.writeAsset(data, to: url)

        let asset = CachedImageAsset(
            wallpaperID: wallpaperID,
            kind: kind,
            relativePath: relativePath,
            byteCount: data.count,
            lastAccessedAt: accessedAt ?? now()
        )
        var next = index
        let previousAsset = next.assets[assetID]
        next.assets[assetID] = asset

        do {
            try commit(next)
        } catch {
            RepositoryFileStore.removeFile(at: url)
            throw error
        }

        if let previousAsset,
           previousAsset.relativePath != relativePath,
           let previousURL = store.assetURL(relativePath: previousAsset.relativePath) {
            RepositoryFileStore.removeFile(at: previousURL)
        }
        return asset
    }

    /// Updates LRU metadata without rewriting when the supplied timestamp is
    /// not newer. Callers may throttle this; it never deletes the asset.
    @discardableResult
    public func markAssetAccessed(
        kind: AssetKind,
        for wallpaperID: WallpaperID,
        at date: Date? = nil
    ) throws -> Bool {
        let assetID = AssetIdentity.id(kind: kind, wallpaperID: wallpaperID)
        guard let existing = index.assets[assetID] else { return false }
        let timestamp = date ?? now()
        guard timestamp > existing.lastAccessedAt else { return false }

        var next = index
        next.assets[assetID] = CachedImageAsset(
            wallpaperID: existing.wallpaperID,
            kind: existing.kind,
            relativePath: existing.relativePath,
            byteCount: existing.byteCount,
            lastAccessedAt: timestamp
        )
        try commit(next)
        return true
    }

    /// Explicit asset deletion must not race with a wallpaper write. Protection
    /// is checked in the same actor turn as the deletion, so a concurrent
    /// reservation cannot be lost between a UI check and this call.
    private func ensureNotProtected(_ wallpaperID: WallpaperID) throws {
        let protected = RepositoryProtection.isProtected(
            wallpaperID,
            favorites: index.favorites,
            pinned: index.pinned,
            applied: index.applied,
            reservations: Set(index.reservations.keys)
        )
        guard !protected else {
            throw RepositoryError.protectedAsset(wallpaperID)
        }
    }

    public func removeAsset(kind: AssetKind, for wallpaperID: WallpaperID) throws {
        try ensureNotProtected(wallpaperID)
        let assetID = AssetIdentity.id(kind: kind, wallpaperID: wallpaperID)
        guard let existing = index.assets[assetID] else { return }

        var next = index
        next.assets[assetID] = nil
        try commit(next)

        if let url = store.assetURL(relativePath: existing.relativePath) {
            RepositoryFileStore.removeFile(at: url)
        }
    }

    public func removeAssets(for wallpaperID: WallpaperID) throws {
        try ensureNotProtected(wallpaperID)
        let existing = AssetKind.allCases.compactMap {
            index.assets[AssetIdentity.id(kind: $0, wallpaperID: wallpaperID)]
        }
        guard !existing.isEmpty else { return }

        var next = index
        for asset in existing {
            next.assets[asset.id] = nil
        }
        try commit(next)

        for asset in existing {
            if let url = store.assetURL(relativePath: asset.relativePath) {
                RepositoryFileStore.removeFile(at: url)
            }
        }
    }

    /// Clearing story text never removes image metadata, assets or favorites.
    @discardableResult
    public func clearStories() throws -> Int {
        let count = index.stories.count
        guard count > 0 else { return 0 }
        var next = index
        next.stories = [:]
        try commit(next)
        return count
    }

    /// Explicit user action. Removal ignores protection because the user asked
    /// to discard thumbnails; originals, metadata, stories and favorites stay.
    @discardableResult
    public func clearThumbnails() throws -> Int {
        let thumbnails = index.assets.values.filter { $0.kind == .thumbnail }
        guard !thumbnails.isEmpty else { return 0 }

        var next = index
        for thumbnail in thumbnails {
            next.assets[thumbnail.id] = nil
        }
        try commit(next)

        for thumbnail in thumbnails {
            if let url = store.assetURL(relativePath: thumbnail.relativePath) {
                RepositoryFileStore.removeFile(at: url)
            }
        }
        return thumbnails.count
    }

    /// Favorites are image-level and survive market/date changes.
    @discardableResult
    public func setFavorite(_ wallpaperID: WallpaperID, isFavorite: Bool) throws -> Bool {
        try RepositoryValidation.validate(wallpaperID)
        var next = index
        let changed: Bool
        if isFavorite {
            changed = next.favorites.insert(wallpaperID).inserted
        } else {
            changed = next.favorites.remove(wallpaperID) != nil
        }
        guard changed else { return false }
        _ = try next.sync.recordFavorite(wallpaperID, isFavorite: isFavorite)
        try commit(next)
        return true
    }

    /// Pins a date and protects the image that was current at pin time.
    @discardableResult
    public func setPinned(_ occurrence: WallpaperOccurrence, isPinned: Bool) throws -> Bool {
        try RepositoryValidation.validate(occurrence)
        return try setPinned(
            occurrence.id,
            wallpaperID: occurrence.wallpaperID,
            isPinned: isPinned
        )
    }

    @discardableResult
    public func setPinned(
        _ key: OccurrenceKey,
        wallpaperID: WallpaperID,
        isPinned: Bool
    ) throws -> Bool {
        guard key.isValid else {
            throw RepositoryError.invalidRecord("invalid pinned occurrence key")
        }
        try RepositoryValidation.validate(wallpaperID)
        guard key.source == wallpaperID.source else {
            throw RepositoryError.pinIdentityMismatch(key)
        }
        if let occurrence = index.occurrences[key],
           occurrence.wallpaperID != wallpaperID {
            throw RepositoryError.pinIdentityMismatch(key)
        }

        var next = index
        if isPinned {
            let pin = PinnedOccurrence(key: key, wallpaperID: wallpaperID)
            guard !next.pinned.contains(pin) else { return false }
            next.pinned = next.pinned.filter { $0.key != key }
            next.pinned.insert(pin)
        } else {
            let before = next.pinned.count
            next.pinned = next.pinned.filter { $0.key != key }
            guard next.pinned.count != before else { return false }
        }
        _ = try next.sync.recordPin(
            key,
            wallpaperID: isPinned ? wallpaperID : nil,
            isPinned: isPinned
        )
        try commit(next)
        return true
    }

    /// Replaces the set of images used by currently accessible desktops.
    ///
    /// This is intentionally a whole-set replacement, not a union: historical
    /// images are not protected merely because an inactive Space may still
    /// reference them. In-flight write reservations are tracked separately, so
    /// a replacement cannot erase a concurrent reservation.
    ///
    /// The set is live in-memory state and is not persisted; a new process
    /// re-derives it from the integration's current desktop reads. Persisting
    /// it would resurrect stale protection after a crash or upgrade.
    @discardableResult
    public func replaceAppliedWallpapers(_ wallpaperIDs: Set<WallpaperID>) throws -> Bool {
        for wallpaperID in wallpaperIDs {
            try RepositoryValidation.validate(wallpaperID)
        }
        guard wallpaperIDs != index.applied else { return false }
        index.applied = wallpaperIDs
        return true
    }

    /// Per-kind byte limits plus LRU. Favorites, pinned dates, currently
    /// accessible desktop images and in-flight write reservations are never
    /// victims. Files are deleted after the index commit; a crash can leave
    /// only repairable orphans.
    @discardableResult
    public func evictLeastRecentlyUsed(limits: CacheLimits) throws -> CacheEvictionResult {
        guard limits.thumbnailBytes >= 0, limits.originalBytes >= 0 else {
            throw RepositoryError.invalidRecord("cache limits must be non-negative")
        }

        let protected = RepositoryProtection.protectedImageIDs(
            favorites: index.favorites,
            pinned: index.pinned,
            applied: index.applied,
            reservations: Set(index.reservations.keys)
        )
        var next = index
        var victims: [CachedImageAsset] = []

        for kind in AssetKind.allCases {
            let limit = kind == .thumbnail ? limits.thumbnailBytes : limits.originalBytes
            let kindAssets = next.assets.values.filter { $0.kind == kind }
            var bytes = kindAssets.reduce(0) { $0 + $1.byteCount }
            guard bytes > limit else { continue }

            let candidates = kindAssets
                .filter { !protected.contains($0.wallpaperID) }
                .sorted { lhs, rhs in
                    if lhs.lastAccessedAt != rhs.lastAccessedAt {
                        return lhs.lastAccessedAt < rhs.lastAccessedAt
                    }
                    return lhs.id < rhs.id
                }

            for candidate in candidates {
                guard bytes > limit else { break }
                victims.append(candidate)
                next.assets[candidate.id] = nil
                bytes -= candidate.byteCount
            }
        }

        if !victims.isEmpty {
            try commit(next)
            for victim in victims {
                if let url = store.assetURL(relativePath: victim.relativePath) {
                    RepositoryFileStore.removeFile(at: url)
                }
            }
        }

        var thumbnailBytes = 0
        var originalBytes = 0
        for asset in next.assets.values {
            switch asset.kind {
            case .thumbnail:
                thumbnailBytes += asset.byteCount
            case .original:
                originalBytes += asset.byteCount
            }
        }

        let evicted = victims.sorted { $0.id < $1.id }
        return CacheEvictionResult(
            evictedAssets: evicted,
            evictedBytes: evicted.reduce(0) { $0 + $1.byteCount },
            thumbnailBytesAfter: thumbnailBytes,
            originalBytesAfter: originalBytes
        )
    }

    /// Removes files under `Assets/<kind>/` that the index does not reference
    /// and reports indexed files that are gone. It never scans outside the
    /// repository directory and never deletes metadata or stories.
    public func repair() throws -> RepositoryRepairReport {
        let missing = computeMissingAssets()
        let referenced = Set(index.assets.values.map(\.relativePath))
        var removed: [String] = []
        var failed: [String] = []
        let fileManager = FileManager.default

        for kind in AssetKind.allCases {
            let relativeDirectory = "Assets/\(kind.rawValue)"
            guard let directoryURL = RepositoryPath.assetURL(
                relativePath: relativeDirectory,
                directory: directory
            ) else {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }

            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw RepositoryError.repairFailed(RepositoryFileStore.describe(error))
            }

            for fileURL in contents {
                let relativePath = "\(relativeDirectory)/\(fileURL.lastPathComponent)"
                guard !referenced.contains(relativePath) else { continue }
                do {
                    try fileManager.removeItem(at: fileURL)
                    removed.append(relativePath)
                } catch {
                    failed.append(relativePath)
                }
            }
        }

        return RepositoryRepairReport(
            missingAssets: missing,
            orphanedFilesRemoved: removed.sorted(),
            failedOrphanRemovals: failed.sorted()
        )
    }

    // MARK: Internals

    func commit(_ next: RepositoryIndex) throws {
        try store.write(next, previous: index)
        index = next
    }

    private func computeMissingAssets() -> [CachedImageAsset] {
        let fileManager = FileManager.default
        return index.assets.values.filter { asset in
            guard let url = store.assetURL(relativePath: asset.relativePath) else {
                return true
            }
            return !fileManager.fileExists(atPath: url.path)
        }
        .sorted { $0.id < $1.id }
    }
}

extension WallpaperRepository: RepositorySnapshotProviding {
    public nonisolated func repositorySnapshot() async throws -> RepositorySnapshot {
        await snapshot()
    }
}

// MARK: - Stored index

struct RepositoryIndex: Equatable, Sendable {
    var occurrences: [OccurrenceKey: WallpaperOccurrence] = [:]
    var metadata: [OccurrenceKey: WallpaperMetadataRecord] = [:]
    var wallpapers: [WallpaperID: WallpaperRecord] = [:]
    var stories: [String: DailyStoryRecord] = [:]
    var assets: [String: CachedImageAsset] = [:]
    var favorites: Set<WallpaperID> = []
    var pinned: Set<PinnedOccurrence> = []
    /// Current accessible desktop images. This is a live, replaceable set; it
    /// is never a growing history of every image ever applied.
    var applied: Set<WallpaperID> = []
    /// Images with a wallpaper write in flight. Persisted so a crash during
    /// the system call cannot leave the source file evictable on restart.
    var reservations: [WallpaperID: Date] = [:]
    var firstObservedDate: LocalDate?
    var observationStartedAt: Date?
    /// Durable local sync bookkeeping. This is intentionally part of the same
    /// index file and commit as favorites/pins: a crash can never persist a
    /// user-visible preference change without its causal journal entry (or the
    /// journal entry without the preference change).
    var sync: RepositorySyncState = RepositorySyncState()
}

extension RepositoryIndex {
    /// Drops reservations left by a crash so they cannot become permanent
    /// history. Reservations are only needed for the seconds a system write
    /// takes; current-desktop protection is re-derived separately.
    func filteringExpiredReservations(now: Date) -> RepositoryIndex {
        let cutoff = now.addingTimeInterval(-RepositorySchema.inFlightWriteLifetime)
        var result = self
        result.reservations = reservations.filter { $0.value >= cutoff }
        return result
    }
}

/// Story identity is source + market + date + attached wallpaper image.
///
/// Provider-generated ids are content hashes, so a corrected or re-fetched
/// story can legitimately receive a new id. Treating ids as the only identity
/// leaves revisions side by side and makes `StoryMatcher` see an ambiguity.
/// This helper collapses those revisions by identity and `fetchedAt` while
/// never touching a different image identity.
enum RepositoryStoryRevision {
    struct VersionKey: Hashable {
        let source: SourceID
        let market: Market
        let date: LocalDate
        let wallpaperID: WallpaperID
    }

    enum MergeResult {
        case inserted
        case updated
        case unchanged
        case ignored
    }

    static func versionKey(for story: DailyStoryRecord) -> VersionKey? {
        guard let wallpaperID = story.associatedWallpaperID else { return nil }
        return VersionKey(
            source: story.source,
            market: story.market,
            date: story.date,
            wallpaperID: wallpaperID
        )
    }

    /// Load/cleanup normalization. Strictly older revisions are superseded and
    /// removed. The newest timestamp is kept as a group:
    /// - equal content at that timestamp collapses to the deterministic
    ///   smallest id;
    /// - different content at that timestamp is a real conflict and every
    ///   conflicting record is preserved, never silently deleted.
    /// Different image identities and unbound stories are left alone.
    static func collapseSuperseded(in stories: inout [String: DailyStoryRecord]) {
        var groups: [VersionKey: [DailyStoryRecord]] = [:]
        for story in stories.values {
            guard let key = versionKey(for: story) else { continue }
            groups[key, default: []].append(story)
        }

        for group in groups.values where group.count > 1 {
            guard let newestTime = group.map(\.fetchedAt).max() else { continue }
            let newest = group.filter { $0.fetchedAt == newestTime }
            guard let first = newest.first else { continue }

            if newest.allSatisfy({ StoryContentIdentity.isSameContent(first, $0) }) {
                guard let canonical = newest.min(by: { $0.id < $1.id }) else { continue }
                for story in group where story.id != canonical.id {
                    stories[story.id] = nil
                }
            } else {
                // Same-time content conflict: only strictly older revisions are
                // superseded. All conflicting newest records remain available
                // for explicit resolution/reporting.
                let newestIDs = Set(newest.map(\.id))
                for story in group where !newestIDs.contains(story.id) {
                    stories[story.id] = nil
                }
            }
        }
    }

    /// Merges one incoming story into the store.
    ///
    /// Same image identity + date:
    /// - newer `fetchedAt` replaces the previous revision;
    /// - older `fetchedAt` is ignored;
    /// - equal `fetchedAt` with equal content collapses to the smaller id;
    /// - equal `fetchedAt` with different content is a conflict.
    ///
    /// A story for another image identity is never removed or overwritten.
    static func merge(
        _ story: DailyStoryRecord,
        into stories: inout [String: DailyStoryRecord]
    ) throws -> MergeResult {
        guard let version = versionKey(for: story) else {
            return try mergeUnbound(story, into: &stories)
        }

        // The same provider id must not silently change image identity.
        if let idExisting = stories[story.id], versionKey(for: idExisting) != version {
            throw RepositoryError.storyConflict(story.id)
        }

        let group = stories.values.filter { versionKey(for: $0) == version }
        guard let current = group.first else {
            stories[story.id] = story
            return .inserted
        }

        // A normalized store can still have multiple records here only when
        // the newest fetchedAt is a genuine same-time content conflict.
        if group.count > 1 {
            guard let newestTime = group.map(\.fetchedAt).max() else {
                stories[story.id] = story
                return .inserted
            }
            if story.fetchedAt < newestTime {
                return .ignored
            }
            if story.fetchedAt > newestTime {
                for item in group { stories[item.id] = nil }
                stories[story.id] = story
                return .updated
            }

            let newest = group.filter { $0.fetchedAt == newestTime }
            if newest.contains(where: { StoryContentIdentity.isSameContent($0, story) }) {
                return .unchanged
            }
            throw RepositoryError.storyConflict(story.id)
        }

        if current.id == story.id {
            if current == story { return .unchanged }
            if story.fetchedAt > current.fetchedAt {
                stories[story.id] = story
                return .updated
            }
            if story.fetchedAt < current.fetchedAt {
                return .ignored
            }
            if StoryContentIdentity.isSameContent(current, story) {
                return .unchanged
            }
            throw RepositoryError.storyConflict(story.id)
        }

        if story.fetchedAt < current.fetchedAt {
            return .ignored
        }
        if story.fetchedAt > current.fetchedAt {
            stories[current.id] = nil
            stories[story.id] = story
            return .updated
        }

        if StoryContentIdentity.isSameContent(current, story) {
            if story.id < current.id {
                stories[current.id] = nil
                stories[story.id] = story
                return .updated
            }
            return .unchanged
        }
        throw RepositoryError.storyConflict(story.id)
    }

    private static func mergeUnbound(
        _ story: DailyStoryRecord,
        into stories: inout [String: DailyStoryRecord]
    ) throws -> MergeResult {
        guard let existing = stories[story.id] else {
            stories[story.id] = story
            return .inserted
        }
        // A bound story and an unbound story are different identities even
        // when a provider accidentally reuses an id.
        guard existing.associatedWallpaperID == nil else {
            throw RepositoryError.storyConflict(story.id)
        }
        if existing == story { return .unchanged }
        if story.fetchedAt > existing.fetchedAt {
            stories[story.id] = story
            return .updated
        }
        if story.fetchedAt < existing.fetchedAt {
            return .ignored
        }
        if StoryContentIdentity.isSameContent(existing, story) {
            return .unchanged
        }
        throw RepositoryError.storyConflict(story.id)
    }
}

// MARK: - Wallpaper application reservation

extension WallpaperRepository: WallpaperApplicationProtecting {
    /// Atomically persists the image's in-flight write reservation before a
    /// platform write.
    ///
    /// The same actor also performs eviction and explicit deletion, so once
    /// this method returns a non-nil ID a concurrent cleanup cannot remove the
    /// source original. The file must still exist; an unknown or missing URL
    /// returns nil so callers refuse the write instead of guessing an identity.
    /// Reservations are not part of the current-desktop applied set and expire
    /// after a crash instead of becoming permanent history.
    public func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        let targetKeys = Self.protectionPathKeys(url)
        guard let asset = index.assets.values.first(where: { asset in
            guard asset.kind == .original,
                  let assetURL = store.assetURL(relativePath: asset.relativePath)
            else {
                return false
            }
            return !targetKeys.isDisjoint(with: Self.protectionPathKeys(assetURL))
        }) else {
            return nil
        }
        guard let assetURL = store.assetURL(relativePath: asset.relativePath),
              FileManager.default.fileExists(atPath: assetURL.path)
        else {
            return nil
        }

        let wallpaperID = asset.wallpaperID
        // Always hold an explicit reservation while a write is in flight,
        // even when the image is already in the live current-desktop set. A
        // concurrent reconciliation may replace that set mid-write.
        guard index.reservations[wallpaperID] == nil else {
            return wallpaperID
        }
        var next = index
        next.reservations[wallpaperID] = now()
        try commit(next)
        return wallpaperID
    }

    /// Releases the in-flight reservation after the system write attempt.
    ///
    /// A successful write keeps the image protected as current-desktop state
    /// until the next live reconciliation replaces it. A failed or blocked
    /// write releases only the reservation; favorites, pinned dates and the
    /// current-desktop set are never modified here.
    public func completeAppliedProtection(forImageURL url: URL, succeeded: Bool) async {
        guard let wallpaperID = Self.wallpaperID(
            forImageURL: url,
            assets: index.assets,
            store: store
        ) else {
            return
        }
        guard index.reservations[wallpaperID] != nil || (succeeded && !index.applied.contains(wallpaperID))
        else {
            return
        }

        var next = index
        next.reservations[wallpaperID] = nil
        if succeeded {
            next.applied.insert(wallpaperID)
        }
        // Best effort: if this commit fails, the in-memory reservation stays
        // and keeps the source protected. The next refresh/commit recovers.
        try? commit(next)
    }

    private static func wallpaperID(
        forImageURL url: URL,
        assets: [String: CachedImageAsset],
        store: RepositoryFileStore
    ) -> WallpaperID? {
        let targetKeys = protectionPathKeys(url)
        return assets.values.first(where: { asset in
            guard asset.kind == .original,
                  let assetURL = store.assetURL(relativePath: asset.relativePath)
            else {
                return false
            }
            return !targetKeys.isDisjoint(with: protectionPathKeys(assetURL))
        })?.wallpaperID
    }

    private static func protectionPathKeys(_ url: URL) -> Set<String> {
        let standardized = url.standardizedFileURL
        var keys: Set<String> = [standardized.path]
        let resolved = standardized.resolvingSymlinksInPath()
        if resolved.path != standardized.path {
            keys.insert(resolved.path)
        }
        return keys
    }
}
