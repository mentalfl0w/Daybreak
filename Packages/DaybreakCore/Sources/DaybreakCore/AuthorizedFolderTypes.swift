import Foundation

// MARK: - Generation and access kind

/// Monotonic identity for one authorized-folder epoch.
///
/// Every replacement or forced reopen starts a new epoch. Operations capture
/// the epoch they began under; a replacement cancels and drains them so no
/// write can silently land in the previous folder after the switch.
public struct AuthorizedFolderGeneration: RawRepresentable, Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: AuthorizedFolderGeneration, rhs: AuthorizedFolderGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        String(rawValue)
    }
}

/// How the resolved folder is actually reachable in this process.
public enum AuthorizedFolderAccessKind: String, Hashable, Sendable, Codable {
    /// The URL is security scoped and must be started/stopped around access.
    case securityScoped

    /// The URL is a normal local file URL. This is the normal macOS
    /// non-sandboxed / ad-hoc result; iOS never uses it.
    case unscopedLocal
}

/// How the host should obtain access when the user selects a folder.
public enum AuthorizedFolderScopePolicy: String, Hashable, Sendable, Codable {
    /// iOS: security scoped. macOS: security scoped when sandboxed, plain
    /// local access for non-sandboxed / ad-hoc builds.
    case automatic

    /// Require a security-scoped bookmark. On macOS this degrades to local
    /// access only when the process is demonstrably not sandboxed and the
    /// system refuses to start a scope; the descriptor reports the effective
    /// kind.
    case securityScoped

    /// Plain local access. Rejected on iOS and in a sandboxed macOS process.
    case unscopedLocal
}

// MARK: - Descriptor, revocation, state

/// Stable, non-sensitive description of the currently authorized folder.
///
/// The raw folder URL is deliberately not exposed; callers use the store's
/// operations, which start scope and coordinate access. `displayName` is the
/// last path component, never the full path.
public struct AuthorizedFolderDescriptor: Hashable, Sendable, Codable {
    public let generation: AuthorizedFolderGeneration
    public let displayName: String
    public let accessKind: AuthorizedFolderAccessKind
    public let authorizedAt: Date
    public let refreshedAt: Date

    init(
        generation: AuthorizedFolderGeneration,
        displayName: String,
        accessKind: AuthorizedFolderAccessKind,
        authorizedAt: Date,
        refreshedAt: Date
    ) {
        self.generation = generation
        self.displayName = displayName
        self.accessKind = accessKind
        self.authorizedAt = authorizedAt
        self.refreshedAt = refreshedAt
    }
}

public enum AuthorizedFolderRevocationReason: String, Hashable, Sendable, Codable {
    case bookmarkCorrupted
    case unsupportedBookmarkVersion
    case platformMismatch
    case bookmarkUnresolvable
    case targetMissing
    case targetNotDirectory
    case unsupportedLocation
    case accessDenied
    case scopeRequired
    case bookmarkStorageUnavailable
}

/// Why a previously saved authorization can no longer be used.
public struct AuthorizedFolderRevocation: Hashable, Sendable, Codable {
    public let generation: AuthorizedFolderGeneration?
    public let displayName: String?
    public let reason: AuthorizedFolderRevocationReason

    init(
        generation: AuthorizedFolderGeneration?,
        displayName: String?,
        reason: AuthorizedFolderRevocationReason
    ) {
        self.generation = generation
        self.displayName = displayName
        self.reason = reason
    }

    /// A transient unavailability that a scheduler may retry without asking
    /// the user to select a folder again.
    public var isRetryable: Bool {
        switch reason {
        case .accessDenied, .targetMissing, .bookmarkUnresolvable, .bookmarkStorageUnavailable:
            return true
        default:
            return false
        }
    }

    public var requiresUserReselection: Bool {
        switch reason {
        case .scopeRequired, .bookmarkCorrupted, .unsupportedBookmarkVersion,
             .platformMismatch, .unsupportedLocation, .targetNotDirectory:
            return true
        default:
            return false
        }
    }
}

/// Observable lifecycle of the local authorization.
public enum AuthorizedFolderState: Hashable, Sendable {
    /// Nothing has been loaded from local storage yet. Call `open()`.
    case notLoaded
    /// No bookmark is stored (or it was disabled).
    case notAuthorized
    case active(AuthorizedFolderDescriptor)
    /// The bookmark resolved but reported itself stale; access remains usable.
    /// The store attempts to refresh the bookmark, and the next forced reopen
    /// normally returns `.active`.
    case stale(AuthorizedFolderDescriptor)
    case revoked(AuthorizedFolderRevocation)
    /// A replace, disable, or forced reopen is in progress.
    case transitioning(from: AuthorizedFolderDescriptor?)

    public var descriptor: AuthorizedFolderDescriptor? {
        switch self {
        case .active(let descriptor), .stale(let descriptor):
            return descriptor
        case .transitioning(let descriptor):
            return descriptor
        case .notLoaded, .notAuthorized, .revoked:
            return nil
        }
    }
}

// MARK: - Directory entries

/// One direct child returned by `listDirectory`.
///
/// Symbolic links are never returned, so every entry is safe to address by its
/// `relativePath` through the same store. `isDownloaded` is `false` for an
/// iCloud item whose content is not materialized locally; reading such an item
/// fails with `.itemNotDownloaded` instead of forcing a download.
public struct AuthorizedFolderEntry: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case file
        case directory
    }

    public let relativePath: String
    public let kind: Kind
    public let fileSize: Int?
    public let modificationDate: Date?
    public let isDownloaded: Bool

    init(
        relativePath: String,
        kind: Kind,
        fileSize: Int?,
        modificationDate: Date?,
        isDownloaded: Bool
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isDownloaded = isDownloaded
    }
}

// MARK: - Errors

public enum AuthorizedFolderError: Error, Hashable, Sendable, LocalizedError {
    case notLoaded
    case notAuthorized
    case alreadyAuthorized(displayName: String)
    case authorizationRevoked(AuthorizedFolderRevocation)
    case transitionInProgress
    case superseded(generation: AuthorizedFolderGeneration)

    case invalidFolderURL
    case folderNotDirectory
    case unscopedAccessUnsupported
    case scopeDenied

    case invalidBookmarkDirectory
    case bookmarkLocationOverlapsFolder
    case bookmarkReadFailed(code: Int)
    case bookmarkWriteFailed(code: Int)
    case bookmarkRemoveFailed(code: Int)
    case bookmarkCreationFailed(code: Int)
    case bookmarkCorrupted
    case unsupportedBookmarkVersion(Int)
    case platformMismatch

    case invalidRelativePath
    case pathEscapesAuthorizedFolder(relativePath: String)
    case unsafeSymbolicLink(relativePath: String)
    case fileNotFound(relativePath: String)
    case targetIsDirectory(relativePath: String)
    case targetIsNotDirectory(relativePath: String)
    case targetIsNotFile(relativePath: String)
    case itemNotDownloaded(relativePath: String)
    case invalidReadLimit
    case fileTooLarge(relativePath: String, byteCount: Int, maxBytes: Int)
    case downloadRequestFailed(relativePath: String, code: Int)
    case accessDenied(relativePath: String?)
    case coordinatedAccessFailed(code: Int)
    case ioFailed(relativePath: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The authorized folder has not been loaded yet."
        case .notAuthorized:
            return "No folder is authorized."
        case .alreadyAuthorized(let displayName):
            return "A folder is already authorized: \(displayName)."
        case .authorizationRevoked(let revocation):
            return "The authorized folder is unavailable: \(revocation.reason.rawValue)."
        case .transitionInProgress:
            return "The authorized folder is changing."
        case .superseded(let generation):
            return "The operation belongs to an older authorization (generation \(generation))."
        case .invalidFolderURL:
            return "The selected folder URL is not a local file URL."
        case .folderNotDirectory:
            return "The selected URL is not a directory."
        case .unscopedAccessUnsupported:
            return "Unscoped local folder access is not supported in this process."
        case .scopeDenied:
            return "Access to the selected folder was denied."
        case .invalidBookmarkDirectory:
            return "The bookmark storage location is not a local directory URL."
        case .bookmarkLocationOverlapsFolder:
            return "The bookmark storage location must not be inside the authorized folder."
        case .bookmarkReadFailed(let code):
            return "The local bookmark could not be read (code \(code))."
        case .bookmarkWriteFailed(let code):
            return "The local bookmark could not be saved (code \(code))."
        case .bookmarkRemoveFailed(let code):
            return "The local bookmark could not be removed (code \(code))."
        case .bookmarkCreationFailed(let code):
            return "A bookmark for the selected folder could not be created (code \(code))."
        case .bookmarkCorrupted:
            return "The local bookmark is damaged."
        case .unsupportedBookmarkVersion(let version):
            return "The local bookmark format version \(version) is not supported."
        case .platformMismatch:
            return "The local bookmark belongs to another platform."
        case .invalidRelativePath:
            return "The relative path is invalid."
        case .pathEscapesAuthorizedFolder(let relativePath):
            return "The path escapes the authorized folder: \(relativePath)."
        case .unsafeSymbolicLink(let relativePath):
            return "The path uses a symbolic link: \(relativePath)."
        case .fileNotFound(let relativePath):
            return "The item does not exist: \(relativePath)."
        case .targetIsDirectory(let relativePath):
            return "The item is a directory, not a file: \(relativePath)."
        case .targetIsNotDirectory(let relativePath):
            return "The item is not a directory: \(relativePath)."
        case .targetIsNotFile(let relativePath):
            return "The item is not a regular file: \(relativePath)."
        case .itemNotDownloaded(let relativePath):
            return "The item is not downloaded locally: \(relativePath)."
        case .invalidReadLimit:
            return "The read limit must be greater than zero."
        case .fileTooLarge(let relativePath, let byteCount, let maxBytes):
            return "The item \(relativePath) is too large (\(byteCount) bytes; limit \(maxBytes))."
        case .downloadRequestFailed(let relativePath, let code):
            return "A download request failed for \(relativePath) (code \(code))."
        case .accessDenied(let relativePath):
            if let relativePath {
                return "Access was denied for \(relativePath)."
            }
            return "Access was denied."
        case .coordinatedAccessFailed(let code):
            return "Coordinated file access failed (code \(code))."
        case .ioFailed(let relativePath, let code):
            return "File access failed for \(relativePath) (code \(code))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .authorizationRevoked, .scopeDenied, .accessDenied:
            return "Select the folder again to grant access."
        case .notAuthorized:
            return "Choose a folder before syncing."
        case .superseded:
            return "Retry the operation after the folder finishes changing."
        case .transitionInProgress:
            return "Wait for the folder change to finish."
        default:
            return nil
        }
    }

    /// A transient failure that the caller may retry without user action.
    ///
    /// Missing or not-yet-materialized items, permission failures while the
    /// system settles, coordinated-access failures, and local bookmark I/O
    /// failures are all kept distinct from `.authorizationRevoked` so a sync
    /// scheduler can keep pending work instead of dropping it.
    public var isRetryable: Bool {
        switch self {
        case .itemNotDownloaded,
             .downloadRequestFailed,
             .fileNotFound,
             .accessDenied,
             .coordinatedAccessFailed,
             .ioFailed,
             .bookmarkReadFailed,
             .bookmarkWriteFailed,
             .bookmarkRemoveFailed,
             .transitionInProgress:
            return true
        default:
            return false
        }
    }

    /// The user must choose a folder again before access can recover.
    public var requiresUserReselection: Bool {
        switch self {
        case .notAuthorized,
             .authorizationRevoked,
             .scopeDenied,
             .unscopedAccessUnsupported:
            return true
        default:
            return false
        }
    }
}
