import Foundation

// MARK: - Change payloads

public struct SyncFavoriteChange: Hashable, Sendable, Codable {
    public let wallpaperID: WallpaperID
    public let isFavorite: Bool

    public init(wallpaperID: WallpaperID, isFavorite: Bool) {
        self.wallpaperID = wallpaperID
        self.isFavorite = isFavorite
    }
}

public struct SyncPinChange: Hashable, Sendable, Codable {
    public let key: OccurrenceKey
    /// The image that was pinned. Required for a pin; an unpin tombstone may
    /// omit it, because the occurrence key alone is the removal authority.
    public let wallpaperID: WallpaperID?
    public let isPinned: Bool

    public init(key: OccurrenceKey, wallpaperID: WallpaperID? = nil, isPinned: Bool) {
        self.key = key
        self.wallpaperID = wallpaperID
        self.isPinned = isPinned
    }

    public var isValid: Bool {
        guard key.isValid, SyncProtocolValidation.isValidOccurrenceKey(key) else { return false }
        if let wallpaperID {
            guard SyncProtocolValidation.isValidWallpaperID(wallpaperID),
                  wallpaperID.source == key.source
            else {
                return false
            }
        }
        return isPinned ? wallpaperID != nil : true
    }
}

// MARK: - Operation payload

public enum SyncOperationPayload: Hashable, Sendable {
    case favorite(SyncFavoriteChange)
    case pin(SyncPinChange)
    case occurrence(WallpaperOccurrence)
    case metadata(WallpaperMetadataRecord)
    case wallpaper(WallpaperRecord)
    case story(DailyStoryRecord)
    case assets([SyncAssetReference])

    var payloadKind: SyncPayloadKind {
        switch self {
        case .favorite: return .favorite
        case .pin: return .pin
        case .occurrence: return .occurrence
        case .metadata: return .metadata
        case .wallpaper: return .wallpaper
        case .story: return .story
        case .assets: return .assets
        }
    }
}

enum SyncPayloadKind: String, Codable {
    case favorite
    case pin
    case occurrence
    case metadata
    case wallpaper
    case story
    case assets
}

extension SyncOperationPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case favorite
        case pin
        case occurrence
        case metadata
        case wallpaper
        case story
        case assets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SyncPayloadKind.self, forKey: .kind)
        switch kind {
        case .favorite:
            self = .favorite(try container.decode(SyncFavoriteChange.self, forKey: .favorite))
        case .pin:
            self = .pin(try container.decode(SyncPinChange.self, forKey: .pin))
        case .occurrence:
            self = .occurrence(try container.decode(WallpaperOccurrence.self, forKey: .occurrence))
        case .metadata:
            self = .metadata(try container.decode(WallpaperMetadataRecord.self, forKey: .metadata))
        case .wallpaper:
            self = .wallpaper(try container.decode(WallpaperRecord.self, forKey: .wallpaper))
        case .story:
            self = .story(try container.decode(DailyStoryRecord.self, forKey: .story))
        case .assets:
            self = .assets(try container.decode([SyncAssetReference].self, forKey: .assets))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payloadKind, forKey: .kind)
        switch self {
        case .favorite(let change):
            try container.encode(change, forKey: .favorite)
        case .pin(let change):
            try container.encode(change, forKey: .pin)
        case .occurrence(let record):
            try container.encode(record, forKey: .occurrence)
        case .metadata(let record):
            try container.encode(record, forKey: .metadata)
        case .wallpaper(let record):
            try container.encode(record, forKey: .wallpaper)
        case .story(let record):
            try container.encode(record, forKey: .story)
        case .assets(let references):
            try container.encode(references, forKey: .assets)
        }
    }
}

// MARK: - Payload validation

enum SyncPayloadValidation {
    static func validate(_ payload: SyncOperationPayload) throws {
        switch payload {
        case .favorite(let change):
            guard SyncProtocolValidation.isValidWallpaperID(change.wallpaperID) else {
                throw SyncProtocolError.invalidPayload("favorite image identity is invalid")
            }
        case .pin(let change):
            guard change.isValid else {
                throw SyncProtocolError.invalidPayload("pin identity or image source is invalid")
            }
        case .occurrence(let record):
            try validate(record)
        case .metadata(let record):
            try validate(record)
        case .wallpaper(let record):
            try validate(record)
        case .story(let record):
            try validate(record)
        case .assets(let references):
            guard !references.isEmpty else {
                throw SyncProtocolError.invalidPayload("asset operation has no references")
            }
            guard references.count <= SyncWireProtocol.maxAssetReferencesPerOperation else {
                throw SyncProtocolError.limitExceeded("more than \(SyncWireProtocol.maxAssetReferencesPerOperation) asset references in one operation")
            }
            var keys: Set<SyncAssetKey> = []
            for reference in references {
                try reference.validate()
                guard keys.insert(reference.id).inserted else {
                    throw SyncProtocolError.duplicateAssetReference(reference.id)
                }
            }
        }
    }

    static func validate(_ record: WallpaperOccurrence) throws {
        guard record.isValid,
              SyncProtocolValidation.isValidOccurrenceKey(record.id),
              SyncProtocolValidation.isValidWallpaperID(record.wallpaperID)
        else {
            throw SyncProtocolError.invalidPayload("occurrence identity is invalid")
        }
    }

    static func validate(_ record: WallpaperMetadataRecord) throws {
        guard record.isValid,
              SyncProtocolValidation.isValidOccurrenceKey(record.key),
              SyncProtocolValidation.isValidWallpaperID(record.wallpaperID),
              SyncProtocolValidation.isBoundedRequiredText(record.originalLocale, maxBytes: SyncProtocolValidation.maxLocaleBytes),
              SyncProtocolValidation.isBoundedText(record.title, maxBytes: SyncProtocolValidation.maxTitleBytes),
              SyncProtocolValidation.isBoundedText(record.copyright, maxBytes: SyncProtocolValidation.maxCopyrightBytes),
              SyncProtocolValidation.isValidURL(record.sourceURL),
              SyncProtocolValidation.isBoundedText(record.contentHash, maxBytes: SyncProtocolValidation.maxContentHashBytes),
              SyncProtocolValidation.areValidVariants(record.variants)
        else {
            throw SyncProtocolError.invalidPayload("metadata content is invalid or too large")
        }
    }

    static func validate(_ record: WallpaperRecord) throws {
        guard record.isValid,
              SyncProtocolValidation.isValidWallpaperID(record.wallpaperID),
              SyncProtocolValidation.isBoundedText(record.canonicalTitle, maxBytes: SyncProtocolValidation.maxTitleBytes),
              SyncProtocolValidation.isBoundedText(record.copyright, maxBytes: SyncProtocolValidation.maxCopyrightBytes),
              SyncProtocolValidation.isValidURL(record.sourceURL),
              SyncProtocolValidation.areValidVariants(record.variants)
        else {
            throw SyncProtocolError.invalidPayload("wallpaper content is invalid or too large")
        }
    }

    static func validate(_ record: DailyStoryRecord) throws {
        guard record.source.isValid,
              record.market.isValid,
              SyncProtocolValidation.isBoundedRequiredText(record.id, maxBytes: SyncProtocolValidation.maxStoryIDBytes),
              SyncProtocolValidation.isBoundedRequiredText(record.originalLocale, maxBytes: SyncProtocolValidation.maxLocaleBytes),
              SyncProtocolValidation.isBoundedText(record.title, maxBytes: SyncProtocolValidation.maxTitleBytes),
              SyncProtocolValidation.isBoundedText(record.headline, maxBytes: SyncProtocolValidation.maxTitleBytes),
              SyncProtocolValidation.isBoundedText(record.body, maxBytes: SyncProtocolValidation.maxBodyBytes),
              SyncProtocolValidation.isBoundedText(record.quickFact, maxBytes: SyncProtocolValidation.maxQuickFactBytes),
              SyncProtocolValidation.isBoundedText(record.copyright, maxBytes: SyncProtocolValidation.maxCopyrightBytes),
              SyncProtocolValidation.isValidURL(record.sourceURL),
              SyncProtocolValidation.isBoundedText(record.contentHash, maxBytes: SyncProtocolValidation.maxContentHashBytes),
              record.sourceFields.count <= SyncProtocolValidation.maxStoryFields,
              record.sourceFields.allSatisfy({
                  SyncProtocolValidation.isBoundedRequiredText($0, maxBytes: SyncProtocolValidation.maxStoryFieldBytes)
              })
        else {
            throw SyncProtocolError.invalidPayload("story content is invalid or too large")
        }
        if let associatedWallpaperID = record.associatedWallpaperID {
            guard associatedWallpaperID.source == record.source,
                  SyncProtocolValidation.isValidWallpaperID(associatedWallpaperID)
            else {
                throw SyncProtocolError.invalidPayload("story image identity is invalid")
            }
        }
    }
}

// MARK: - Operation

/// One immutable causal change. The identifier is the SHA-256 of the canonical
/// body, so identical changes deduplicate and tampered files fail verification.
public struct SyncOperation: Hashable, Sendable, Identifiable, Codable {
    public let wireVersion: Int
    public let deviceID: SyncDeviceID
    public let sequence: UInt64
    /// Causal context known to the author before this operation. It always
    /// contains `deviceID: sequence`.
    public let context: SyncVersionVector
    public let payload: SyncOperationPayload
    public let id: SyncOperationID

    public init(
        deviceID: SyncDeviceID,
        sequence: UInt64,
        context: SyncVersionVector,
        payload: SyncOperationPayload
    ) throws {
        try self.init(
            wireVersion: SyncWireProtocol.currentVersion,
            deviceID: deviceID,
            sequence: sequence,
            context: context,
            payload: payload
        )
    }

    init(
        wireVersion: Int,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        context: SyncVersionVector,
        payload: SyncOperationPayload
    ) throws {
        guard wireVersion == SyncWireProtocol.currentVersion else {
            throw SyncProtocolError.unsupportedProtocolVersion(
                found: wireVersion,
                supported: SyncWireProtocol.currentVersion
            )
        }
        guard sequence >= 1, sequence <= SyncWireProtocol.maxSequence else {
            throw SyncProtocolError.invalidSequence(sequence)
        }
        guard !context.isEmpty else {
            throw SyncProtocolError.invalidVersionVector("operation context is empty")
        }
        let contextSequence = context.counter(for: deviceID)
        guard contextSequence == sequence else {
            throw SyncProtocolError.operationContextMismatch(
                device: deviceID,
                sequence: sequence,
                contextSequence: contextSequence
            )
        }
        try SyncPayloadValidation.validate(payload)

        self.wireVersion = wireVersion
        self.deviceID = deviceID
        self.sequence = sequence
        self.context = context
        self.payload = payload
        let body = SyncCanonicalEncoding.operationBody(
            wireVersion: wireVersion,
            deviceID: deviceID,
            sequence: sequence,
            context: context,
            payload: payload
        )
        self.id = SyncOperationID(digest: SyncContentDigest.hashing(body))
    }

    private enum CodingKeys: String, CodingKey {
        case wireVersion
        case deviceID
        case sequence
        case context
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        let deviceID = try container.decode(SyncDeviceID.self, forKey: .deviceID)
        let sequence = try container.decode(UInt64.self, forKey: .sequence)
        let context = try container.decode(SyncVersionVector.self, forKey: .context)
        let payload = try container.decode(SyncOperationPayload.self, forKey: .payload)
        try self.init(
            wireVersion: wireVersion,
            deviceID: deviceID,
            sequence: sequence,
            context: context,
            payload: payload
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(context, forKey: .context)
        try container.encode(payload, forKey: .payload)
    }
}

// MARK: - Factory

public enum SyncOperationFactory {
    public static func favorite(
        wallpaperID: WallpaperID,
        isFavorite: Bool,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(
            .favorite(SyncFavoriteChange(wallpaperID: wallpaperID, isFavorite: isFavorite)),
            deviceID: deviceID,
            sequence: sequence,
            knownContext: knownContext
        )
    }

    public static func pin(
        key: OccurrenceKey,
        wallpaperID: WallpaperID?,
        isPinned: Bool,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(
            .pin(SyncPinChange(key: key, wallpaperID: wallpaperID, isPinned: isPinned)),
            deviceID: deviceID,
            sequence: sequence,
            knownContext: knownContext
        )
    }

    public static func occurrence(
        _ record: WallpaperOccurrence,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(.occurrence(record), deviceID: deviceID, sequence: sequence, knownContext: knownContext)
    }

    public static func metadata(
        _ record: WallpaperMetadataRecord,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(.metadata(record), deviceID: deviceID, sequence: sequence, knownContext: knownContext)
    }

    public static func wallpaper(
        _ record: WallpaperRecord,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(.wallpaper(record), deviceID: deviceID, sequence: sequence, knownContext: knownContext)
    }

    public static func story(
        _ record: DailyStoryRecord,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(.story(record), deviceID: deviceID, sequence: sequence, knownContext: knownContext)
    }

    public static func assets(
        _ references: [SyncAssetReference],
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        try make(.assets(references), deviceID: deviceID, sequence: sequence, knownContext: knownContext)
    }

    /// Creates an operation whose context is `knownContext` advanced by this
    /// device's new sequence. The caller must persist the returned sequence and
    /// frontier before publishing more operations.
    public static func make(
        _ payload: SyncOperationPayload,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        knownContext: SyncVersionVector
    ) throws -> SyncOperation {
        let context = try knownContext.advancing(deviceID, to: sequence)
        return try SyncOperation(
            deviceID: deviceID,
            sequence: sequence,
            context: context,
            payload: payload
        )
    }
}

// MARK: - Wire file

/// One immutable per-device operation file.
///
/// The envelope is versioned before the body is decoded: a build that does not
/// understand a version rejects the whole file instead of applying a partial or
/// reinterpreted operation.
public struct SyncOperationFile: Hashable, Sendable {
    public let operation: SyncOperation

    public init(operation: SyncOperation) {
        self.operation = operation
    }

    public var checksum: SyncContentDigest { operation.id.digest }

    public var fileName: String {
        "\(operation.deviceID.rawValue).\(operation.id.rawValue).json"
    }

    public func encoded() throws -> Data {
        let envelope = Envelope(
            format: SyncWireProtocol.format,
            protocolVersion: SyncWireProtocol.currentVersion,
            checksum: operation.id.digest,
            operation: operation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw SyncProtocolError.malformedFile(String(describing: error))
        }
        guard data.count <= SyncWireProtocol.maxOperationFileBytes else {
            throw SyncProtocolError.fileTooLarge(
                found: data.count,
                limit: SyncWireProtocol.maxOperationFileBytes
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> SyncOperationFile {
        guard data.count <= SyncWireProtocol.maxOperationFileBytes else {
            throw SyncProtocolError.fileTooLarge(
                found: data.count,
                limit: SyncWireProtocol.maxOperationFileBytes
            )
        }

        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw SyncProtocolError.malformedFile(String(describing: error))
        }
        guard header.format == SyncWireProtocol.format else {
            throw SyncProtocolError.unsupportedFormat(header.format)
        }
        guard header.protocolVersion == SyncWireProtocol.currentVersion else {
            throw SyncProtocolError.unsupportedProtocolVersion(
                found: header.protocolVersion,
                supported: SyncWireProtocol.currentVersion
            )
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as SyncProtocolError {
            throw error
        } catch {
            throw SyncProtocolError.malformedFile(String(describing: error))
        }
        guard envelope.format == SyncWireProtocol.format else {
            throw SyncProtocolError.unsupportedFormat(envelope.format)
        }
        guard envelope.protocolVersion == SyncWireProtocol.currentVersion else {
            throw SyncProtocolError.unsupportedProtocolVersion(
                found: envelope.protocolVersion,
                supported: SyncWireProtocol.currentVersion
            )
        }
        guard envelope.operation.wireVersion == envelope.protocolVersion else {
            throw SyncProtocolError.unsupportedProtocolVersion(
                found: envelope.operation.wireVersion,
                supported: SyncWireProtocol.currentVersion
            )
        }
        guard envelope.checksum == envelope.operation.id.digest else {
            throw SyncProtocolError.checksumMismatch(
                expected: envelope.operation.id.digest,
                found: envelope.checksum
            )
        }
        return SyncOperationFile(operation: envelope.operation)
    }

    public static func decode(_ data: Data, fileName: String) throws -> SyncOperationFile {
        let file = try decode(data)
        guard file.fileName == fileName else {
            throw SyncProtocolError.fileNameMismatch(expected: file.fileName, found: fileName)
        }
        return file
    }

    public static func parseFileName(
        _ name: String
    ) -> (deviceID: SyncDeviceID, operationID: SyncOperationID)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              String(parts[2]) == "json",
              let deviceID = SyncDeviceID(String(parts[0])),
              let operationID = SyncOperationID(hex: String(parts[1]))
        else {
            return nil
        }
        return (deviceID, operationID)
    }

    private struct Header: Decodable {
        let format: String
        let protocolVersion: Int
    }

    private struct Envelope: Codable {
        let format: String
        let protocolVersion: Int
        let checksum: SyncContentDigest
        let operation: SyncOperation
    }
}
