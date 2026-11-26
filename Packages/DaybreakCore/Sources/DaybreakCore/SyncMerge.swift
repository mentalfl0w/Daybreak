import Foundation

// MARK: - Merge value

/// A value that can participate in a deterministic register merge.
///
/// `syncStableOrderKey` may only depend on content, never on wall-clock
/// timestamps or local device state. Lexicographically smaller keys win when
/// true concurrent present values remain.
public protocol SyncMergeValue: Hashable, Sendable {
    var syncStableOrderKey: String { get }
}

/// Marker value for image-level favorite registers.
public struct SyncPresence: Hashable, Sendable, SyncMergeValue {
    public init() {}
    public var syncStableOrderKey: String { "" }
}

extension WallpaperID: SyncMergeValue {
    public var syncStableOrderKey: String {
        SyncCanonicalEncoding.wallpaperIDStableKey(self)
    }
}

extension WallpaperOccurrence: SyncMergeValue {
    public var syncStableOrderKey: String {
        SyncCanonicalEncoding.occurrenceStableKey(self)
    }
}

extension WallpaperMetadataRecord: SyncMergeValue {
    public var syncStableOrderKey: String {
        SyncCanonicalEncoding.metadataStableKey(self)
    }
}

extension WallpaperRecord: SyncMergeValue {
    public var syncStableOrderKey: String {
        SyncCanonicalEncoding.wallpaperStableKey(self)
    }
}

extension DailyStoryRecord: SyncMergeValue {
    public var syncStableOrderKey: String {
        SyncCanonicalEncoding.storyStableKey(self)
    }
}

extension SyncAssetReference: SyncMergeValue {
    public var syncStableOrderKey: String {
        contentSHA256.hex
    }
}

// MARK: - Register

/// Observed-remove register with retained tombstones.
///
/// Merge is set union followed by antichain pruning. That is associative,
/// commutative and idempotent:
/// - a version dominated by another version is dropped forever;
/// - equal versions and truly concurrent versions are both kept;
/// - if any surviving version is a removal, the effective value is absent
///   (remove-wins for true concurrency);
/// - otherwise concurrent present values are resolved by their stable content
///   key, then by operation identifier.
public struct SyncRegister<Value: SyncMergeValue>: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case present(Value)
        case removed
    }

    public struct Entry: Hashable, Sendable {
        public let version: SyncVersionVector
        public let state: State
        public let operationID: SyncOperationID
        public let deviceID: SyncDeviceID

        init(
            version: SyncVersionVector,
            state: State,
            operationID: SyncOperationID,
            deviceID: SyncDeviceID
        ) {
            self.version = version
            self.state = state
            self.operationID = operationID
            self.deviceID = deviceID
        }

        public var isRemoved: Bool {
            if case .removed = state { return true }
            return false
        }
    }

    public private(set) var entries: [Entry]

    public init() {
        self.entries = []
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var value: Value? {
        guard !entries.isEmpty else { return nil }

        let maximal = entries.filter { candidate in
            !entries.contains(where: { other in
                other.operationID != candidate.operationID
                    && other.version.dominates(candidate.version)
            })
        }
        if maximal.contains(where: { $0.isRemoved }) { return nil }

        let present: [(value: Value, operationID: SyncOperationID)] = maximal.compactMap { entry in
            guard case .present(let value) = entry.state else { return nil }
            return (value: value, operationID: entry.operationID)
        }
        return present.min { lhs, rhs in
            if lhs.value.syncStableOrderKey != rhs.value.syncStableOrderKey {
                return lhs.value.syncStableOrderKey < rhs.value.syncStableOrderKey
            }
            return lhs.operationID < rhs.operationID
        }?.value
    }

    public var isTombstoned: Bool {
        value == nil && entries.contains(where: { $0.isRemoved })
    }

    public var tombstoneCount: Int {
        entries.reduce(0) { $0 + ($1.isRemoved ? 1 : 0) }
    }

    mutating func merge(_ entry: Entry) throws {
        guard !entries.contains(where: { $0.operationID == entry.operationID }) else {
            return
        }

        var next = entries
        next.append(entry)

        var index = 0
        while index < next.count {
            let candidate = next[index]
            let dominated = next.contains(where: { other in
                other.operationID != candidate.operationID
                    && other.version.dominates(candidate.version)
            })
            if dominated {
                next.remove(at: index)
            } else {
                index += 1
            }
        }

        guard next.count <= SyncWireProtocol.maxConcurrentVersionsPerKey else {
            throw SyncProtocolError.limitExceeded(
                "more than \(SyncWireProtocol.maxConcurrentVersionsPerKey) concurrent versions for one key"
            )
        }

        next.sort(by: Self.entryOrder)
        entries = next
    }

    private static func entryOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let left = lhs.version.description
        let right = rhs.version.description
        if left != right { return left < right }
        return lhs.operationID < rhs.operationID
    }
}

// MARK: - Story identity

/// Sync identity for a story revision.
///
/// Bound stories are revisions of one logical story per source, market, date
/// and image, matching the repository's revision grouping. Provider-generated
/// ids can change for the same content, so the id is not the sync key for bound
/// stories. Unbound stories have no image identity and remain distinct by id.
public struct SyncStoryKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let source: SourceID
    public let market: Market
    public let date: LocalDate
    public let associatedWallpaperID: WallpaperID?
    public let unboundStoryID: String?

    public init(story: DailyStoryRecord) {
        self.source = story.source
        self.market = story.market
        self.date = story.date
        if let associatedWallpaperID = story.associatedWallpaperID {
            self.associatedWallpaperID = associatedWallpaperID
            self.unboundStoryID = nil
        } else {
            self.associatedWallpaperID = nil
            self.unboundStoryID = story.id
        }
    }

    public init(
        source: SourceID,
        market: Market,
        date: LocalDate,
        associatedWallpaperID: WallpaperID?,
        unboundStoryID: String?
    ) throws {
        guard source.isValid, market.isValid else {
            throw SyncProtocolError.invalidPayload("story key source or market is invalid")
        }
        if let associatedWallpaperID {
            guard unboundStoryID == nil,
                  associatedWallpaperID.source == source,
                  SyncProtocolValidation.isValidWallpaperID(associatedWallpaperID)
            else {
                throw SyncProtocolError.invalidPayload("bound story key image is invalid")
            }
        } else {
            guard let unboundStoryID,
                  SyncProtocolValidation.isBoundedRequiredText(
                      unboundStoryID,
                      maxBytes: SyncProtocolValidation.maxStoryIDBytes
                  )
            else {
                throw SyncProtocolError.invalidPayload("unbound story key id is invalid")
            }
        }
        self.source = source
        self.market = market
        self.date = date
        self.associatedWallpaperID = associatedWallpaperID
        self.unboundStoryID = unboundStoryID
    }

    public var description: String {
        let image = associatedWallpaperID?.description ?? unboundStoryID ?? ""
        return "\(source.rawValue):\(market.rawValue):\(date.iso8601)#\(image)"
    }

    public static func < (lhs: SyncStoryKey, rhs: SyncStoryKey) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.market != rhs.market { return lhs.market < rhs.market }
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if let left = lhs.associatedWallpaperID, let right = rhs.associatedWallpaperID {
            if left != right { return left < right }
        } else if lhs.associatedWallpaperID == nil && rhs.associatedWallpaperID != nil {
            return true
        } else if lhs.associatedWallpaperID != nil && rhs.associatedWallpaperID == nil {
            return false
        }
        return (lhs.unboundStoryID ?? "") < (rhs.unboundStoryID ?? "")
    }
}

// MARK: - Archive

/// Deterministic converged view of every operation observed so far.
///
/// The archive is derived state. Immutable operation files remain the
/// persistence source of truth; `Hashable` equality is useful for tests and
/// for detecting a no-op scan. It is not `Codable` on purpose, because each
/// register needed to reconstruct it is already in its operation file.
public struct SyncArchive: Hashable, Sendable {
    public private(set) var causalFrontier: SyncVersionVector

    private var favoriteRegisters: [WallpaperID: SyncRegister<SyncPresence>]
    private var pinRegisters: [OccurrenceKey: SyncRegister<WallpaperID>]
    private var occurrenceRegisters: [OccurrenceKey: SyncRegister<WallpaperOccurrence>]
    private var metadataRegisters: [OccurrenceKey: SyncRegister<WallpaperMetadataRecord>]
    private var wallpaperRegisters: [WallpaperID: SyncRegister<WallpaperRecord>]
    private var storyRegisters: [SyncStoryKey: SyncRegister<DailyStoryRecord>]
    private var assetRegisters: [SyncAssetKey: SyncRegister<SyncAssetReference>]

    public init() {
        self.causalFrontier = SyncVersionVector()
        self.favoriteRegisters = [:]
        self.pinRegisters = [:]
        self.occurrenceRegisters = [:]
        self.metadataRegisters = [:]
        self.wallpaperRegisters = [:]
        self.storyRegisters = [:]
        self.assetRegisters = [:]
    }

    public var isEmpty: Bool {
        causalFrontier.isEmpty
            && favoriteRegisters.isEmpty
            && pinRegisters.isEmpty
            && occurrenceRegisters.isEmpty
            && metadataRegisters.isEmpty
            && wallpaperRegisters.isEmpty
            && storyRegisters.isEmpty
            && assetRegisters.isEmpty
    }

    public func nextSequence(for device: SyncDeviceID) -> UInt64 {
        causalFrontier.nextSequence(for: device)
    }

    // MARK: Favorites

    public func isFavorite(_ wallpaperID: WallpaperID) -> Bool {
        favoriteRegisters[wallpaperID]?.value != nil
    }

    /// Whether the archive holds any record for this wallpaper, present or
    /// tombstoned. Absence without a record is not evidence of removal: a peer
    /// may simply not have published it, or its file may be unreadable yet.
    public func hasFavoriteRecord(_ wallpaperID: WallpaperID) -> Bool {
        favoriteRegisters[wallpaperID] != nil
    }

    public var favoriteWallpaperIDs: Set<WallpaperID> {
        Set(favoriteRegisters.compactMap { element in
            element.value.value == nil ? nil : element.key
        })
    }

    public var favoriteTombstoneCount: Int {
        favoriteRegisters.values.reduce(0) { $0 + $1.tombstoneCount }
    }

    // MARK: Pins

    public func pin(for key: OccurrenceKey) -> PinnedOccurrence? {
        guard let wallpaperID = pinRegisters[key]?.value else { return nil }
        return PinnedOccurrence(key: key, wallpaperID: wallpaperID)
    }

    /// Whether the archive holds any record for this pinned date, present or
    /// tombstoned. See `hasFavoriteRecord`.
    public func hasPinRecord(_ key: OccurrenceKey) -> Bool {
        pinRegisters[key] != nil
    }

    public var pinnedOccurrences: Set<PinnedOccurrence> {
        Set(pinRegisters.compactMap { element in
            element.value.value.map { PinnedOccurrence(key: element.key, wallpaperID: $0) }
        })
    }

    public var pinTombstoneCount: Int {
        pinRegisters.values.reduce(0) { $0 + $1.tombstoneCount }
    }

    // MARK: Records

    public func occurrence(for key: OccurrenceKey) -> WallpaperOccurrence? {
        occurrenceRegisters[key]?.value
    }

    public var occurrences: [WallpaperOccurrence] {
        occurrenceRegisters.values
            .compactMap { $0.value }
            .sorted { lhs, rhs in
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
                return lhs.wallpaperID < rhs.wallpaperID
            }
    }

    public func metadata(for key: OccurrenceKey) -> WallpaperMetadataRecord? {
        metadataRegisters[key]?.value
    }

    public var metadata: [WallpaperMetadataRecord] {
        metadataRegisters.values
            .compactMap { $0.value }
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.wallpaperID < rhs.wallpaperID
            }
    }

    public func wallpaper(for wallpaperID: WallpaperID) -> WallpaperRecord? {
        wallpaperRegisters[wallpaperID]?.value
    }

    public var wallpapers: [WallpaperRecord] {
        wallpaperRegisters.values
            .compactMap { $0.value }
            .sorted { $0.id < $1.id }
    }

    public func story(for key: SyncStoryKey) -> DailyStoryRecord? {
        storyRegisters[key]?.value
    }

    public var stories: [DailyStoryRecord] {
        storyRegisters.values
            .compactMap { $0.value }
            .sorted { lhs, rhs in
                let left = SyncStoryKey(story: lhs)
                let right = SyncStoryKey(story: rhs)
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
    }

    public func assetReference(for key: SyncAssetKey) -> SyncAssetReference? {
        assetRegisters[key]?.value
    }

    public var assetReferences: [SyncAssetReference] {
        assetRegisters.values
            .compactMap { $0.value }
            .sorted { lhs, rhs in
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                return lhs.contentSHA256 < rhs.contentSHA256
            }
    }

    // MARK: Merge

    mutating func apply(_ operation: SyncOperation) throws {
        let frontier = try causalFrontier.merging(operation.context)

        switch operation.payload {
        case .favorite(let change):
            var register = favoriteRegisters[change.wallpaperID] ?? SyncRegister<SyncPresence>()
            let state: SyncRegister<SyncPresence>.State = change.isFavorite
                ? .present(SyncPresence())
                : .removed
            try register.merge(
                SyncRegister<SyncPresence>.Entry(
                    version: operation.context,
                    state: state,
                    operationID: operation.id,
                    deviceID: operation.deviceID
                )
            )
            favoriteRegisters[change.wallpaperID] = register

        case .pin(let change):
            var register = pinRegisters[change.key] ?? SyncRegister<WallpaperID>()
            let state: SyncRegister<WallpaperID>.State
            if change.isPinned, let wallpaperID = change.wallpaperID {
                state = .present(wallpaperID)
            } else {
                state = .removed
            }
            try register.merge(
                SyncRegister<WallpaperID>.Entry(
                    version: operation.context,
                    state: state,
                    operationID: operation.id,
                    deviceID: operation.deviceID
                )
            )
            pinRegisters[change.key] = register

        case .occurrence(let record):
            try Self.merging(
                record,
                key: record.id,
                into: &occurrenceRegisters,
                operation: operation
            )

        case .metadata(let record):
            try Self.merging(
                record,
                key: record.key,
                into: &metadataRegisters,
                operation: operation
            )

        case .wallpaper(let record):
            try Self.merging(
                record,
                key: record.id,
                into: &wallpaperRegisters,
                operation: operation
            )

        case .story(let record):
            try Self.merging(
                record,
                key: SyncStoryKey(story: record),
                into: &storyRegisters,
                operation: operation
            )

        case .assets(let references):
            for reference in references {
                try Self.merging(
                    reference,
                    key: reference.id,
                    into: &assetRegisters,
                    operation: operation
                )
            }
        }

        causalFrontier = frontier
    }

    private static func merging<Value: SyncMergeValue, Key: Hashable>(
        _ value: Value,
        key: Key,
        into registers: inout [Key: SyncRegister<Value>],
        operation: SyncOperation
    ) throws {
        var register = registers[key] ?? SyncRegister<Value>()
        try register.merge(
            SyncRegister<Value>.Entry(
                version: operation.context,
                state: .present(value),
                operationID: operation.id,
                deviceID: operation.deviceID
            )
        )
        registers[key] = register
    }
}

// MARK: - Merge outcome

public enum SyncRejectionReason: Hashable, Sendable, CustomStringConvertible {
    case deviceSequenceConflict
    case concurrentVersionLimit(String)
    case invalidOperation(String)

    public var description: String {
        switch self {
        case .deviceSequenceConflict:
            return "Two different operations reuse one device sequence."
        case .concurrentVersionLimit(let detail):
            return "Too many concurrent versions: \(detail)"
        case .invalidOperation(let detail):
            return "Invalid operation: \(detail)"
        }
    }
}

public struct SyncRejectedOperation: Hashable, Sendable {
    public let operationID: SyncOperationID
    public let deviceID: SyncDeviceID
    public let sequence: UInt64
    public let reason: SyncRejectionReason

    public init(
        operationID: SyncOperationID,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        reason: SyncRejectionReason
    ) {
        self.operationID = operationID
        self.deviceID = deviceID
        self.sequence = sequence
        self.reason = reason
    }
}

public struct SyncMergeOutcome: Hashable, Sendable {
    public let archive: SyncArchive
    public let acceptedOperationIDs: [SyncOperationID]
    public let duplicateOperationIDs: [SyncOperationID]
    public let rejectedOperations: [SyncRejectedOperation]

    public var acceptedCount: Int { acceptedOperationIDs.count }
    public var duplicateCount: Int { duplicateOperationIDs.count }
    public var rejectedCount: Int { rejectedOperations.count }

    init(
        archive: SyncArchive,
        acceptedOperationIDs: [SyncOperationID],
        duplicateOperationIDs: [SyncOperationID],
        rejectedOperations: [SyncRejectedOperation]
    ) {
        self.archive = archive
        self.acceptedOperationIDs = acceptedOperationIDs
        self.duplicateOperationIDs = duplicateOperationIDs
        self.rejectedOperations = rejectedOperations
    }
}

// MARK: - Engine

public enum SyncMergeEngine {
    /// Merges an unordered batch of operations. Duplicate operation ids are
    /// counted once; two different operations that reuse one device sequence
    /// are both rejected, because the device violated its logical clock.
    /// Order never affects the resulting archive.
    public static func merge(
        _ operations: [SyncOperation],
        into archive: SyncArchive = SyncArchive()
    ) -> SyncMergeOutcome {
        var unique: [SyncOperationID: SyncOperation] = [:]
        var duplicateIDs: Set<SyncOperationID> = []
        for operation in operations {
            if unique[operation.id] != nil {
                duplicateIDs.insert(operation.id)
            } else {
                unique[operation.id] = operation
            }
        }

        var groups: [DeviceSequence: [SyncOperation]] = [:]
        for operation in unique.values {
            groups[DeviceSequence(deviceID: operation.deviceID, sequence: operation.sequence), default: []]
                .append(operation)
        }
        var conflictingIDs: Set<SyncOperationID> = []
        for group in groups.values where group.count > 1 {
            conflictingIDs.formUnion(group.map(\.id))
        }

        var working = archive
        var accepted: [SyncOperationID] = []
        var rejected: [SyncRejectedOperation] = []

        for operation in unique.values.sorted(by: { $0.id < $1.id }) {
            if conflictingIDs.contains(operation.id) {
                rejected.append(
                    SyncRejectedOperation(
                        operationID: operation.id,
                        deviceID: operation.deviceID,
                        sequence: operation.sequence,
                        reason: .deviceSequenceConflict
                    )
                )
                continue
            }

            var candidate = working
            do {
                try candidate.apply(operation)
                working = candidate
                accepted.append(operation.id)
            } catch let error as SyncProtocolError {
                let reason: SyncRejectionReason
                if case .limitExceeded(let detail) = error {
                    reason = .concurrentVersionLimit(detail)
                } else {
                    reason = .invalidOperation(error.localizedDescription)
                }
                rejected.append(
                    SyncRejectedOperation(
                        operationID: operation.id,
                        deviceID: operation.deviceID,
                        sequence: operation.sequence,
                        reason: reason
                    )
                )
            } catch {
                rejected.append(
                    SyncRejectedOperation(
                        operationID: operation.id,
                        deviceID: operation.deviceID,
                        sequence: operation.sequence,
                        reason: .invalidOperation(String(describing: error))
                    )
                )
            }
        }

        rejected.sort { lhs, rhs in
            if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.operationID < rhs.operationID
        }

        return SyncMergeOutcome(
            archive: working,
            acceptedOperationIDs: accepted.sorted(),
            duplicateOperationIDs: duplicateIDs.sorted(),
            rejectedOperations: rejected
        )
    }

    private struct DeviceSequence: Hashable {
        let deviceID: SyncDeviceID
        let sequence: UInt64
    }
}
