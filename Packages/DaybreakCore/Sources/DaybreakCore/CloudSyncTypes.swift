import Foundation

// MARK: - Folder access seam

/// Why a previously authorized folder can no longer be used.
public enum CloudSyncFolderRevocation: String, Hashable, Sendable {
    case bookmarkCorrupted
    case unsupportedVersion
    case platformMismatch
    case unresolvable
    case targetMissing
    case notDirectory
    case unsupportedLocation
    case accessDenied
    case storageUnavailable
}

/// Lifecycle of the user-authorized shared folder, without exposing its path.
public enum CloudSyncFolderState: Hashable, Sendable {
    case notLoaded
    case notAuthorized
    case active(displayName: String)
    case revoked(CloudSyncFolderRevocation)
    case transitioning

    public var displayName: String? {
        if case .active(let displayName) = self { return displayName }
        return nil
    }
}

/// One direct child of a folder directory.
public struct CloudSyncFolderEntry: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case file
        case directory
    }

    /// Last path component only. It can never contain a path separator.
    public let name: String
    public let kind: Kind
    public let byteCount: Int?
    public let isDownloaded: Bool

    public init(name: String, kind: Kind, byteCount: Int?, isDownloaded: Bool = true) {
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.isDownloaded = isDownloaded
    }
}

/// Distinguishes why a folder path was rejected. The sync status shows this
/// site so a device report can tell a genuinely missing file or bad name apart
/// from a symbolic link or a path-spelling mismatch.
public enum CloudSyncInvalidPathSite: String, Hashable, Sendable {
    /// The relative path itself is not a safe file name.
    case relativePath
    /// The item did not resolve inside the authorized folder.
    case containment
    /// The item or one of its parents is a symbolic link.
    case symbolicLink
}

/// Failure vocabulary shared by the production store and test doubles.
///
/// Only relative names may appear here; absolute paths and content never do.
public enum CloudSyncFolderAccessError: Error, Hashable, Sendable {
    case notAuthorized
    case unauthorized
    case notFound
    case notDownloaded
    case retryable
    case tooLarge
    case invalidPath(String?, site: CloudSyncInvalidPathSite)
    case other

    var diagnosticName: String {
        switch self {
        case .notAuthorized: "notAuthorized"
        case .unauthorized: "unauthorized"
        case .notFound: "notFound"
        case .notDownloaded: "notDownloaded"
        case .retryable: "retryable"
        case .tooLarge: "tooLarge"
        case .invalidPath(let path, let site):
            path.map { "invalidPath(\(site.rawValue):\($0))" }
                ?? "invalidPath(\(site.rawValue))"
        case .other: "other"
        }
    }
}

/// Narrow seam over the coordinated folder store.
///
/// The production implementation is `AuthorizedFolderStore`; tests use an
/// in-memory/local-directory double. Every operation is asynchronous and
/// bounded; there is intentionally no delete, move or remote-deletion API.
public protocol CloudSyncFolderAccessing: Sendable {
    func currentState() async -> CloudSyncFolderState
    func openIfNeeded() async -> CloudSyncFolderState
    func authorizeFolder(_ folderURL: URL) async throws -> String
    func replaceFolderAuthorization(with folderURL: URL) async throws -> String
    func disableFolder() async throws
    func readFile(relativePath: String, maxBytes: Int) async throws -> Data
    func writeFile(_ data: Data, relativePath: String) async throws
    func directoryEntries(relativePath: String) async throws -> [CloudSyncFolderEntry]
    func requestFileDownload(relativePath: String) async throws
}

// MARK: - Production adapter

extension AuthorizedFolderStore: CloudSyncFolderAccessing {
    public func currentState() async -> CloudSyncFolderState {
        Self.syncState(state())
    }

    public func openIfNeeded() async -> CloudSyncFolderState {
        Self.syncState(await open())
    }

    public func authorizeFolder(_ folderURL: URL) async throws -> String {
        do {
            return try await authorize(folderURL).displayName
        } catch {
            throw Self.syncError(error)
        }
    }

    public func replaceFolderAuthorization(with folderURL: URL) async throws -> String {
        do {
            return try await replaceAuthorization(with: folderURL).displayName
        } catch {
            throw Self.syncError(error)
        }
    }

    public func disableFolder() async throws {
        do {
            try await disable()
        } catch {
            throw Self.syncError(error)
        }
    }

    public func readFile(relativePath: String, maxBytes: Int) async throws -> Data {
        do {
            return try await read(relativePath: relativePath, maxBytes: maxBytes)
        } catch {
            throw Self.syncError(error)
        }
    }

    public func writeFile(_ data: Data, relativePath: String) async throws {
        do {
            try await write(data, relativePath: relativePath)
        } catch {
            throw Self.syncError(error)
        }
    }

    public func directoryEntries(relativePath: String) async throws -> [CloudSyncFolderEntry] {
        do {
            return try await listDirectory(relativePath: relativePath).map { entry in
                CloudSyncFolderEntry(
                    name: entry.relativePath.split(separator: "/").last.map(String.init) ?? "",
                    kind: entry.kind == .directory ? .directory : .file,
                    byteCount: entry.fileSize,
                    isDownloaded: entry.isDownloaded
                )
            }
        } catch {
            throw Self.syncError(error)
        }
    }

    public func requestFileDownload(relativePath: String) async throws {
        do {
            try await requestDownload(relativePath: relativePath)
        } catch {
            throw Self.syncError(error)
        }
    }

    private static func syncState(_ state: AuthorizedFolderState) -> CloudSyncFolderState {
        switch state {
        case .notLoaded:
            return .notLoaded
        case .notAuthorized:
            return .notAuthorized
        case .active(let descriptor), .stale(let descriptor):
            return .active(displayName: descriptor.displayName)
        case .revoked(let revocation):
            return .revoked(revocation.syncReason)
        case .transitioning:
            return .transitioning
        }
    }

    static func syncError(_ error: Error) -> CloudSyncFolderAccessError {
        guard let error = error as? AuthorizedFolderError else {
            return .other
        }
        switch error {
        case .notAuthorized:
            return .notAuthorized
        case .authorizationRevoked(let revocation):
            if revocation.reason == .targetMissing
                || revocation.reason == .targetNotDirectory
                || revocation.reason == .unsupportedLocation
                || revocation.reason == .bookmarkStorageUnavailable {
                return .retryable
            }
            return .unauthorized
        case .fileNotFound:
            return .notFound
        case .itemNotDownloaded:
            return .notDownloaded
        case .fileTooLarge:
            return .tooLarge
        case .invalidRelativePath:
            return .invalidPath(nil, site: .relativePath)
        case .pathEscapesAuthorizedFolder(let relativePath):
            return .invalidPath(relativePath, site: .containment)
        case .unsafeSymbolicLink(let relativePath):
            return .invalidPath(relativePath, site: .symbolicLink)
        case .transitionInProgress, .superseded, .coordinatedAccessFailed,
             .accessDenied, .ioFailed, .downloadRequestFailed,
             .bookmarkReadFailed, .bookmarkWriteFailed, .bookmarkRemoveFailed:
            return .retryable
        default:
            return error.requiresUserReselection ? .unauthorized : .other
        }
    }
}

private extension AuthorizedFolderRevocation {
    var syncReason: CloudSyncFolderRevocation {
        switch reason {
        case .bookmarkCorrupted: return .bookmarkCorrupted
        case .unsupportedBookmarkVersion: return .unsupportedVersion
        case .platformMismatch: return .platformMismatch
        case .bookmarkUnresolvable: return .unresolvable
        case .targetMissing: return .targetMissing
        case .targetNotDirectory: return .notDirectory
        case .unsupportedLocation: return .unsupportedLocation
        case .accessDenied: return .accessDenied
        case .scopeRequired: return .accessDenied
        case .bookmarkStorageUnavailable: return .storageUnavailable
        }
    }
}

// MARK: - Result vocabulary

public enum CloudSyncPassStatus: String, Hashable, Sendable, Codable {
    case completed
    case pending
    case awaitingFolder
    case unavailable
    case unauthorized
    case failed
    case cancelled
}

public enum CloudSyncIssueCode: String, Hashable, Sendable, Codable {
    case none
    case incompatibleFolder
    case folderAccess
    case folderUnavailable
    case unauthorized
    case tooManyDevices
    case tooManyOperationFiles
    case invalidOperationFiles
    case rejectedRecords
    case rejectedAssets
    case pendingAssets
    case pendingDownloads
    case journalBacklog
    case repositoryFailure
    case planningFailure
    case passInProgress
}

/// Outcome of exactly one serialized folder pass.
public struct CloudSyncPassResult: Hashable, Sendable {
    public let status: CloudSyncPassStatus
    public let issue: CloudSyncIssueCode
    public let uploadedOperationCount: Int
    public let uploadedAssetCount: Int
    public let importedOperationCount: Int
    public let importedRecordCount: Int
    public let storedAssetCount: Int
    public let pendingAssetCount: Int
    public let rejectedAssetCount: Int
    public let rejectedFileCount: Int
    public let rejectedRecordCount: Int
    public let folderName: String?
    public let finishedAt: Date?

    public init(
        status: CloudSyncPassStatus,
        issue: CloudSyncIssueCode = .none,
        uploadedOperationCount: Int = 0,
        uploadedAssetCount: Int = 0,
        importedOperationCount: Int = 0,
        importedRecordCount: Int = 0,
        storedAssetCount: Int = 0,
        pendingAssetCount: Int = 0,
        rejectedAssetCount: Int = 0,
        rejectedFileCount: Int = 0,
        rejectedRecordCount: Int = 0,
        folderName: String? = nil,
        finishedAt: Date? = nil
    ) {
        self.status = status
        self.issue = issue
        self.uploadedOperationCount = uploadedOperationCount
        self.uploadedAssetCount = uploadedAssetCount
        self.importedOperationCount = importedOperationCount
        self.importedRecordCount = importedRecordCount
        self.storedAssetCount = storedAssetCount
        self.pendingAssetCount = pendingAssetCount
        self.rejectedAssetCount = rejectedAssetCount
        self.rejectedFileCount = rejectedFileCount
        self.rejectedRecordCount = rejectedRecordCount
        self.folderName = folderName
        self.finishedAt = finishedAt
    }

    public var didChangeLocalData: Bool {
        importedRecordCount > 0 || storedAssetCount > 0
    }
}

public enum CloudSyncFolderAuthorizationResult: Hashable, Sendable {
    case authorized(displayName: String)
    case unauthorized
    case unavailable
    case failed

    var diagnosticName: String {
        switch self {
        case .authorized: "authorized"
        case .unauthorized: "unauthorized"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }
}

/// Persisted, device-local controller options.
public struct CloudSyncLocalState: Hashable, Sendable {
    public let enabled: Bool
    public let syncOriginals: Bool
    public let syncMarket: Bool
    public let folderName: String?
    public let lastSyncAt: Date?

    public init(
        enabled: Bool = false,
        syncOriginals: Bool = false,
        syncMarket: Bool = false,
        folderName: String? = nil,
        lastSyncAt: Date? = nil
    ) {
        self.enabled = enabled
        self.syncOriginals = syncOriginals
        self.syncMarket = syncMarket
        self.folderName = folderName
        self.lastSyncAt = lastSyncAt
    }
}

// MARK: - Folder layout

enum CloudSyncFolderLayout {
    static let markerFileName = "daybreak-sync.json"
    static let operationsDirectory = "operations"
    static let blobsDirectory = "blobs"
    static let markerFormat = "daybreak.sync.folder"
    static let markerVersion = 1
    static let maxDeviceDirectories = SyncWireProtocol.maxVersionVectorDevices
    static let maxOperationFilesPerDevice = 20_000
    static let maxTotalOperationFiles = 50_000
    /// Download requests are non-blocking. A higher per-pass cap prevents the
    /// first few not-yet-materialized iCloud files from starving later files.
    static let maxDownloadRequestsPerPass = 256
    static let maxMarkerBytes = 4_096

    static func deviceDirectory(_ deviceID: SyncDeviceID) -> String {
        "\(operationsDirectory)/\(deviceID.rawValue)"
    }

    static func operationPath(deviceID: SyncDeviceID, fileName: String) -> String {
        "\(deviceDirectory(deviceID))/\(fileName)"
    }

    static func blobPath(_ digest: SyncContentDigest) -> String {
        "\(blobsDirectory)/\(SyncAssetBlobNaming.fileName(for: digest))"
    }

    /// A leaf name is safe when it is a single, bounded path component.
    static func isSafeLeafName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.hasPrefix("~") else { return false }
        return !name.unicodeScalars.contains { scalar in
            scalar.value == 0x2F
                || scalar.value == 0x5C
                || scalar.value == 0x3A
                || scalar.value == 0x00
        }
    }
}

struct CloudSyncFolderMarker: Codable, Equatable, Sendable {
    let format: String
    let version: Int

    static let current = CloudSyncFolderMarker(
        format: CloudSyncFolderLayout.markerFormat,
        version: CloudSyncFolderLayout.markerVersion
    )

    var isCompatible: Bool {
        format == CloudSyncFolderLayout.markerFormat
            && version == CloudSyncFolderLayout.markerVersion
    }
}

// MARK: - Durable local checkpoint

struct CloudSyncPersistedState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maxDigestEntries = 30_000
    static let maxRejectedAssets = 1_024

    var schemaVersion: Int = CloudSyncPersistedState.currentSchemaVersion
    var enabled = false
    var syncOriginals = false
    var syncMarket = false
    var folderName: String?
    var lastSyncAt: Date?
    /// repository relativePath -> "<sha256>:<byteCount>" for local asset files.
    var assetDigestCache: [String: String] = [:]
    /// local record entity key -> digest of the local content last published/imported.
    var publishedRecordDigests: [String: String] = [:]
    /// asset identity -> content digest last published/imported.
    var publishedAssetDigests: [String: String] = [:]
    /// "<asset identity>|<digest>" entries that can never be materialized.
    var rejectedAssetKeys: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case syncOriginals
        case syncMarket
        case folderName
        case lastSyncAt
        case assetDigestCache
        case publishedRecordDigests
        case publishedAssetDigests
        case rejectedAssetKeys
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported local sync state version"
            )
        }
        self.schemaVersion = schemaVersion
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.syncOriginals = try container.decodeIfPresent(Bool.self, forKey: .syncOriginals) ?? false
        self.syncMarket = try container.decodeIfPresent(Bool.self, forKey: .syncMarket) ?? false
        self.folderName = try container.decodeIfPresent(String.self, forKey: .folderName)
        self.lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        self.assetDigestCache = try container.decodeIfPresent(
            [String: String].self,
            forKey: .assetDigestCache
        ) ?? [:]
        self.publishedRecordDigests = try container.decodeIfPresent(
            [String: String].self,
            forKey: .publishedRecordDigests
        ) ?? [:]
        self.publishedAssetDigests = try container.decodeIfPresent(
            [String: String].self,
            forKey: .publishedAssetDigests
        ) ?? [:]
        self.rejectedAssetKeys = try container.decodeIfPresent(
            [String].self,
            forKey: .rejectedAssetKeys
        ) ?? []
        normalize()
    }

    var localState: CloudSyncLocalState {
        CloudSyncLocalState(
            enabled: enabled,
            syncOriginals: syncOriginals,
            syncMarket: syncMarket,
            folderName: folderName,
            lastSyncAt: lastSyncAt
        )
    }

    mutating func normalize() {
        schemaVersion = Self.currentSchemaVersion
        if let date = lastSyncAt, !date.timeIntervalSince1970.isFinite {
            lastSyncAt = nil
        }
        if let name = folderName {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            folderName = CloudSyncFolderLayout.isSafeLeafName(trimmed) ? trimmed : nil
        }
        assetDigestCache = Self.bounded(assetDigestCache)
        publishedRecordDigests = Self.bounded(publishedRecordDigests)
        publishedAssetDigests = Self.bounded(publishedAssetDigests)
        rejectedAssetKeys = Array(Set(rejectedAssetKeys)).sorted()
        if rejectedAssetKeys.count > Self.maxRejectedAssets {
            rejectedAssetKeys = Array(rejectedAssetKeys.prefix(Self.maxRejectedAssets))
        }
    }

    private static func bounded(_ values: [String: String]) -> [String: String] {
        guard values.count > maxDigestEntries else { return values }
        let keptKeys = values.keys.sorted().prefix(maxDigestEntries)
        var result: [String: String] = [:]
        result.reserveCapacity(keptKeys.count)
        for key in keptKeys {
            result[key] = values[key]
        }
        return result
    }
}

struct CloudSyncStateStore: Sendable {
    static let fileName = "daybreak-sync-state.json"
    static let maxFileBytes = 4 * 1024 * 1024

    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func load() -> (state: CloudSyncPersistedState, recovered: Bool) {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maxFileBytes
        else {
            return (CloudSyncPersistedState(), false)
        }
        do {
            return (try JSONDecoder().decode(CloudSyncPersistedState.self, from: data), false)
        } catch {
            return (CloudSyncPersistedState(), true)
        }
    }

    func save(_ state: CloudSyncPersistedState) throws {
        var normalized = state
        normalized.normalize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(normalized)
        } catch {
            throw CloudSyncStateStoreError.encodingFailed
        }
        guard data.count <= Self.maxFileBytes else {
            throw CloudSyncStateStoreError.tooLarge
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CloudSyncStateStoreError.writeFailed
        }
    }
}

enum CloudSyncStateStoreError: Error, Hashable, Sendable {
    case encodingFailed
    case tooLarge
    case writeFailed
}
