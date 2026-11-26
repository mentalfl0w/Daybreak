import CryptoKit
import Foundation

// MARK: - Wire protocol

/// Constants shared by every sync operation file.
///
/// The wire format is deliberately boring: one immutable JSON file per
/// operation, identified by its canonical SHA-256 digest. Any change to the
/// operation shape or merge authority must bump `currentVersion`; older builds
/// reject the whole file instead of partially applying it.
public enum SyncWireProtocol {
    public static let format = "daybreak.sync.operation"
    public static let currentVersion = 1

    /// A story body is the largest field the protocol accepts. The file limit
    /// leaves room for metadata, variants and the envelope.
    public static let maxOperationFileBytes = 2 * 1024 * 1024
    public static let maxVersionVectorDevices = 128
    /// Kept below 2^53 so every JSON implementation can represent a sequence
    /// without losing integer precision.
    public static let maxSequence: UInt64 = 9_007_199_254_740_991
    public static let maxConcurrentVersionsPerKey = 64
    public static let maxAssetReferencesPerOperation = 32
    public static let maxAssetBytes = 128 * 1024 * 1024
}

// MARK: - Errors

public enum SyncProtocolError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedProtocolVersion(found: Int, supported: Int)
    case unsupportedFormat(String)
    case malformedFile(String)
    case fileTooLarge(found: Int, limit: Int)
    case checksumMismatch(expected: SyncContentDigest, found: SyncContentDigest)
    case invalidDeviceID(String)
    case invalidContentDigest(String)
    case invalidOperationID(String)
    case invalidVersionVector(String)
    case duplicateDeviceInVersionVector(String)
    case invalidSequence(UInt64)
    case sequenceNotAdvanced(device: SyncDeviceID, existing: UInt64, requested: UInt64)
    case operationContextMismatch(device: SyncDeviceID, sequence: UInt64, contextSequence: UInt64)
    case invalidPayload(String)
    case invalidAssetReference(String)
    case duplicateAssetReference(SyncAssetKey)
    case limitExceeded(String)
    case invalidFileName(String)
    case fileNameMismatch(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let found, let supported):
            return "Sync protocol version \(found) is not supported (this build supports version \(supported))."
        case .unsupportedFormat(let format):
            return "Unsupported sync file format: \(format)."
        case .malformedFile(let detail):
            return "Malformed sync operation file: \(detail)"
        case .fileTooLarge(let found, let limit):
            return "Sync operation file is \(found) bytes; the limit is \(limit)."
        case .checksumMismatch(let expected, let found):
            return "Sync operation checksum mismatch (expected \(expected.hex), found \(found.hex))."
        case .invalidDeviceID(let value):
            return "Invalid sync device identifier: \(value)"
        case .invalidContentDigest(let value):
            return "Invalid SHA-256 content digest: \(value)"
        case .invalidOperationID(let value):
            return "Invalid sync operation identifier: \(value)"
        case .invalidVersionVector(let detail):
            return "Invalid causal version vector: \(detail)"
        case .duplicateDeviceInVersionVector(let device):
            return "Duplicate device \(device) in causal version vector."
        case .invalidSequence(let sequence):
            return "Invalid sync sequence: \(sequence)"
        case .sequenceNotAdvanced(let device, let existing, let requested):
            return "Device \(device) already published sequence \(existing); \(requested) is not newer."
        case .operationContextMismatch(let device, let sequence, let contextSequence):
            return "Operation sequence \(sequence) for \(device) is not represented in its context (\(contextSequence))."
        case .invalidPayload(let detail):
            return "Invalid sync operation payload: \(detail)"
        case .invalidAssetReference(let detail):
            return "Invalid sync asset reference: \(detail)"
        case .duplicateAssetReference(let key):
            return "Duplicate asset reference for \(key) in one operation."
        case .limitExceeded(let detail):
            return "Sync protocol limit exceeded: \(detail)"
        case .invalidFileName(let name):
            return "Invalid sync operation file name: \(name)"
        case .fileNameMismatch(let expected, let found):
            return "Sync operation file name mismatch (expected \(expected), found \(found))."
        }
    }
}

// MARK: - Content digest

/// Lowercase SHA-256 digest of canonical bytes or downloaded asset content.
public struct SyncContentDigest: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let hex: String

    public init?(hex: String) {
        guard hex.utf8.count == 64 else { return nil }
        let normalized = hex.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy(SyncContentDigest.isHexByte)
        else {
            return nil
        }
        self.hex = normalized
    }

    public static func hashing(_ data: Data) -> SyncContentDigest {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard let value = SyncContentDigest(hex: hex) else {
            preconditionFailure("SHA256 produced a non-canonical digest")
        }
        return value
    }

    public static func hashing(utf8 string: String) -> SyncContentDigest {
        hashing(Data(string.utf8))
    }

    public func matches(_ data: Data) -> Bool {
        SyncContentDigest.hashing(data) == self
    }

    public var description: String { hex }

    public static func < (lhs: SyncContentDigest, rhs: SyncContentDigest) -> Bool {
        lhs.hex < rhs.hex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = SyncContentDigest(hex: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid SHA-256 content digest"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

// MARK: - Device identity

/// Stable identifier of one installation that publishes sync operations.
///
/// The allowed character set is also filesystem-safe: no path separator and no
/// dot, so `<device>.<operation>.json` can never be confused with a path.
public struct SyncDeviceID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 64 else { return nil }
        guard rawValue.utf8.allSatisfy(SyncDeviceID.isAllowedByte) else { return nil }
        self.rawValue = rawValue
    }

    public static func random() -> SyncDeviceID {
        let value = UUID().uuidString.lowercased()
        guard let identifier = SyncDeviceID(value) else {
            preconditionFailure("UUID is not a valid sync device identifier")
        }
        return identifier
    }

    public var description: String { rawValue }

    public static func < (lhs: SyncDeviceID, rhs: SyncDeviceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = SyncDeviceID(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid sync device identifier"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isAllowedByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || byte == 45
            || byte == 95
    }
}

// MARK: - Operation identity

/// SHA-256 of an operation's canonical body.
///
/// The identifier is derived, never supplied by a peer: re-encoding or
/// re-reading the same immutable file produces the same identifier, and a
/// tampered body cannot keep its original identifier.
public struct SyncOperationID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let digest: SyncContentDigest

    public init(digest: SyncContentDigest) {
        self.digest = digest
    }

    public init?(hex: String) {
        guard let digest = SyncContentDigest(hex: hex) else { return nil }
        self.digest = digest
    }

    public var rawValue: String { digest.hex }
    public var description: String { digest.hex }

    public static func < (lhs: SyncOperationID, rhs: SyncOperationID) -> Bool {
        lhs.digest < rhs.digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = SyncOperationID(hex: rawValue) else {
            throw SyncProtocolError.invalidOperationID(rawValue)
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Causal version vector

/// Immutable causal context: how many operations from each device the author
/// had observed before creating an operation.
///
/// Counters are per-device logical clocks, not dates. Nothing in this type
/// consults a wall clock; `dominates` and `merging` are the only ordering
/// authorities.
public struct SyncVersionVector: Hashable, Sendable, Codable, CustomStringConvertible {
    public private(set) var counters: [SyncDeviceID: UInt64]

    public init() {
        self.counters = [:]
    }

    public init(_ counters: [SyncDeviceID: UInt64]) throws {
        guard counters.count <= SyncWireProtocol.maxVersionVectorDevices else {
            throw SyncProtocolError.invalidVersionVector("more than \(SyncWireProtocol.maxVersionVectorDevices) devices")
        }
        for (device, counter) in counters {
            guard counter >= 1, counter <= SyncWireProtocol.maxSequence else {
                throw SyncProtocolError.invalidVersionVector("counter \(counter) for \(device)")
            }
        }
        self.counters = counters
    }

    public var isEmpty: Bool { counters.isEmpty }
    public var deviceCount: Int { counters.count }

    public func counter(for device: SyncDeviceID) -> UInt64 {
        counters[device] ?? 0
    }

    /// The next sequence this device must use when publishing.
    public func nextSequence(for device: SyncDeviceID) -> UInt64 {
        counter(for: device) + 1
    }

    /// True when this vector observed everything `other` observed and more.
    /// Equal vectors do not dominate each other.
    public func dominates(_ other: SyncVersionVector) -> Bool {
        guard self != other else { return false }
        for (device, counter) in other.counters {
            if self.counter(for: device) < counter { return false }
        }
        return true
    }

    /// True when neither vector observed the other's writes.
    public func isConcurrent(with other: SyncVersionVector) -> Bool {
        self != other && !dominates(other) && !other.dominates(self)
    }

    public func merging(_ other: SyncVersionVector) throws -> SyncVersionVector {
        var result = counters
        for (device, counter) in other.counters {
            result[device] = max(result[device] ?? 0, counter)
        }
        return try SyncVersionVector(result)
    }

    /// Returns a context that includes this device's new sequence.
    public func advancing(_ device: SyncDeviceID, to sequence: UInt64) throws -> SyncVersionVector {
        guard sequence >= 1, sequence <= SyncWireProtocol.maxSequence else {
            throw SyncProtocolError.invalidSequence(sequence)
        }
        let existing = counter(for: device)
        guard sequence > existing else {
            throw SyncProtocolError.sequenceNotAdvanced(
                device: device,
                existing: existing,
                requested: sequence
            )
        }
        var result = counters
        result[device] = sequence
        return try SyncVersionVector(result)
    }

    public var description: String {
        counters
            .sorted { $0.key < $1.key }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ",")
    }

    private enum CodingKeys: String, CodingKey {
        case counters
    }

    private struct CodedCounter: Codable {
        let device: SyncDeviceID
        let counter: UInt64
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([CodedCounter].self, forKey: .counters)
        guard values.count <= SyncWireProtocol.maxVersionVectorDevices else {
            throw SyncProtocolError.invalidVersionVector("more than \(SyncWireProtocol.maxVersionVectorDevices) devices")
        }
        var result: [SyncDeviceID: UInt64] = [:]
        for value in values {
            guard result[value.device] == nil else {
                throw SyncProtocolError.duplicateDeviceInVersionVector(value.device.rawValue)
            }
            result[value.device] = value.counter
        }
        self = try SyncVersionVector(result)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let values = counters
            .sorted { $0.key < $1.key }
            .map { CodedCounter(device: $0.key, counter: $0.value) }
        try container.encode(values, forKey: .counters)
    }
}

// MARK: - Scope

/// Optional local transfer policy.
///
/// Scope never changes causal merge semantics: the archive still retains every
/// operation it receives. It only filters which reconciled records and assets a
/// plan proposes to move into the local repository or sync folder.
public struct SyncScope: Hashable, Sendable {
    /// Empty means every market.
    public let markets: Set<Market>
    /// Whether original image assets are eligible. Thumbnails remain eligible.
    public let includesOriginals: Bool

    public init(markets: Set<Market> = [], includesOriginals: Bool = true) {
        self.markets = markets
        self.includesOriginals = includesOriginals
    }

    public static let all = SyncScope()

    public var includesAllMarkets: Bool { markets.isEmpty }

    public func includes(_ market: Market) -> Bool {
        markets.isEmpty || markets.contains(market)
    }

    public func includes(_ kind: ImageVariantKind) -> Bool {
        includesOriginals || kind != .original
    }
}

// MARK: - Asset references

public struct SyncAssetKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let wallpaperID: WallpaperID
    public let kind: ImageVariantKind

    public init(wallpaperID: WallpaperID, kind: ImageVariantKind) {
        self.wallpaperID = wallpaperID
        self.kind = kind
    }

    public var description: String { "\(wallpaperID)#\(kind.rawValue)" }

    public static func < (lhs: SyncAssetKey, rhs: SyncAssetKey) -> Bool {
        if lhs.wallpaperID != rhs.wallpaperID { return lhs.wallpaperID < rhs.wallpaperID }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

/// Content-addressed reference to an image variant.
///
/// There is intentionally no local path, bookmark or URL field: a peer can
/// only name bytes by SHA-256. The receiving service must locate or download
/// content itself and verify the digest before use.
public struct SyncAssetReference: Hashable, Sendable, Codable, Identifiable {
    public let wallpaperID: WallpaperID
    public let kind: ImageVariantKind
    public let contentSHA256: SyncContentDigest
    public let byteCount: Int
    public let mimeType: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        wallpaperID: WallpaperID,
        kind: ImageVariantKind,
        contentSHA256: SyncContentDigest,
        byteCount: Int,
        mimeType: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.wallpaperID = wallpaperID
        self.kind = kind
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        let trimmedMIME = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = (trimmedMIME?.isEmpty == false) ? trimmedMIME?.lowercased() : nil
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var id: SyncAssetKey {
        SyncAssetKey(wallpaperID: wallpaperID, kind: kind)
    }

    public var isValid: Bool {
        SyncProtocolValidation.isValidWallpaperID(wallpaperID)
            && byteCount > 0
            && byteCount <= SyncWireProtocol.maxAssetBytes
            && SyncProtocolValidation.isValidMIMEType(mimeType)
            && (pixelWidth.map { $0 > 0 && $0 <= SyncProtocolValidation.maxDimension } ?? true)
            && (pixelHeight.map { $0 > 0 && $0 <= SyncProtocolValidation.maxDimension } ?? true)
    }

    public func matches(_ data: Data) -> Bool {
        data.count == byteCount && contentSHA256 == SyncContentDigest.hashing(data)
    }

    public func validate() throws {
        guard isValid else {
            throw SyncProtocolError.invalidAssetReference(id.description)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case wallpaperID
        case kind
        case contentSHA256
        case byteCount
        case mimeType
        case pixelWidth
        case pixelHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = SyncAssetReference(
            wallpaperID: try container.decode(WallpaperID.self, forKey: .wallpaperID),
            kind: try container.decode(ImageVariantKind.self, forKey: .kind),
            contentSHA256: try container.decode(SyncContentDigest.self, forKey: .contentSHA256),
            byteCount: try container.decode(Int.self, forKey: .byteCount),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
            pixelWidth: try container.decodeIfPresent(Int.self, forKey: .pixelWidth),
            pixelHeight: try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        )
        guard value.isValid else {
            throw SyncProtocolError.invalidAssetReference(value.id.description)
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallpaperID, forKey: .wallpaperID)
        try container.encode(kind, forKey: .kind)
        try container.encode(contentSHA256, forKey: .contentSHA256)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
    }
}

/// Pure naming policy for content blobs in the user-selected sync folder.
public enum SyncAssetBlobNaming {
    public static let fileExtension = "blob"

    public static func fileName(for digest: SyncContentDigest) -> String {
        "\(digest.hex).\(fileExtension)"
    }

    public static func digest(fromFileName name: String) -> SyncContentDigest? {
        let suffix = ".\(fileExtension)"
        guard name.hasSuffix(suffix) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        return SyncContentDigest(hex: stem)
    }
}

// MARK: - Shared validation

enum SyncProtocolValidation {
    static let maxSourceIDBytes = 64
    static let maxImageIDBytes = 1024
    static let maxMarketBytes = 64
    static let maxURLBytes = 4096
    static let maxTitleBytes = 8192
    static let maxCopyrightBytes = 4096
    static let maxBodyBytes = 65536
    static let maxQuickFactBytes = 4096
    static let maxLocaleBytes = 64
    static let maxContentHashBytes = 256
    static let maxStoryIDBytes = 256
    static let maxMIMETypeBytes = 64
    static let maxDimension = 100_000
    static let maxStoryFields = 64
    static let maxStoryFieldBytes = 512
    static let maxVariants = 16
    static let maxChecksumBytes = 256

    static func isValidWallpaperID(_ id: WallpaperID) -> Bool {
        id.isValid
            && !id.source.rawValue.isEmpty
            && id.source.rawValue.utf8.count <= maxSourceIDBytes
            && id.sourceImageID.utf8.count <= maxImageIDBytes
    }

    static func isValidOccurrenceKey(_ key: OccurrenceKey) -> Bool {
        key.isValid
            && key.source.rawValue.utf8.count <= maxSourceIDBytes
            && key.market.rawValue.utf8.count <= maxMarketBytes
    }

    static func isValidURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme?.lowercased() == "https"
            && url.absoluteString.utf8.count <= maxURLBytes
    }

    static func isBoundedText(_ value: String?, maxBytes: Int) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maxBytes
    }

    static func isBoundedRequiredText(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes
    }

    static func isValidMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return true }
        let lowercased = mimeType.lowercased()
        guard lowercased.utf8.count <= maxMIMETypeBytes,
              lowercased.hasPrefix("image/")
        else {
            return false
        }
        let subtype = lowercased.dropFirst("image/".count)
        guard !subtype.isEmpty else { return false }
        return subtype.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 97 && byte <= 122)
                || byte == 43
                || byte == 45
                || byte == 46
        }
    }

    static func isValidVariant(_ variant: ImageVariantDescriptor) -> Bool {
        variant.isValid
            && isValidWallpaperID(variant.wallpaperID)
            && isValidURL(variant.remoteURL)
            && (variant.pixelWidth.map { $0 > 0 && $0 <= maxDimension } ?? true)
            && (variant.pixelHeight.map { $0 > 0 && $0 <= maxDimension } ?? true)
            && isBoundedText(variant.mimeType, maxBytes: maxMIMETypeBytes)
            && isBoundedText(variant.checksum, maxBytes: maxChecksumBytes)
    }

    static func areValidVariants(_ variants: [ImageVariantDescriptor]) -> Bool {
        variants.count <= maxVariants && variants.allSatisfy(isValidVariant)
    }
}
