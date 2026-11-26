import Foundation

// MARK: - Coordination

protocol AuthorizedFolderCoordinating: Sendable {
    func coordinateReading<T: Sendable>(
        at url: URL,
        _ body: @Sendable (URL) throws -> T
    ) throws -> T

    func coordinateWriting<T: Sendable>(
        at url: URL,
        _ body: @Sendable (URL) throws -> T
    ) throws -> T

}

struct AuthorizedFolderLiveCoordinating: AuthorizedFolderCoordinating {
    func coordinateReading<T: Sendable>(
        at url: URL,
        _ body: @Sendable (URL) throws -> T
    ) throws -> T {
        try AuthorizedFolderFileCoordination.perform(writing: false, at: url, body)
    }

    func coordinateWriting<T: Sendable>(
        at url: URL,
        _ body: @Sendable (URL) throws -> T
    ) throws -> T {
        try AuthorizedFolderFileCoordination.perform(writing: true, at: url, body)
    }

}

enum AuthorizedFolderFileCoordination {
    static func perform<T: Sendable>(
        writing: Bool,
        at url: URL,
        _ body: @Sendable (URL) throws -> T
    ) throws -> T {
        // NSFileCoordinator must be used on one thread for one operation. Each
        // call creates its own coordinator on the detached operation task.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var outcome: Result<T, any Error>?
        let accessor: (URL) -> Void = { coordinatedURL in
            do {
                outcome = .success(try body(coordinatedURL))
            } catch {
                outcome = .failure(error)
            }
        }
        if writing {
            coordinator.coordinate(
                writingItemAt: url,
                options: [],
                error: &coordinatorError,
                byAccessor: accessor
            )
        } else {
            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinatorError,
                byAccessor: accessor
            )
        }
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw AuthorizedFolderError.coordinatedAccessFailed(code: coordinatorError?.code ?? 0)
        }
    }

}

// MARK: - Environment

enum AuthorizedFolderAccessProbe: Sendable {
    case granted(AuthorizedFolderAccessKind)
    case revoked(AuthorizedFolderRevocationReason)
}

struct AuthorizedFolderEnvironment: Sendable {
    let platform: AuthorizedFolderHostPlatform
    let scopePolicy: AuthorizedFolderScopePolicy
    let hostIsSandboxed: Bool
    let bookmarkCoding: any AuthorizedFolderBookmarkCoding
    let scoping: any AuthorizedFolderSecurityScoping
    let coordinating: any AuthorizedFolderCoordinating

    static func detectSandboxed(platform: AuthorizedFolderHostPlatform) -> Bool {
        switch platform {
        case .iOS:
            return true
        case .macOS:
            let environment = ProcessInfo.processInfo.environment
            if environment["APP_SANDBOX_CONTAINER_ID"] != nil {
                return true
            }
            return NSHomeDirectory().contains("/Library/Containers/")
        }
    }

    var allowsUnscopedLocalAccess: Bool {
        platform == .macOS && !hostIsSandboxed
    }

    func desiredAccessKind() throws -> AuthorizedFolderAccessKind {
        switch (platform, scopePolicy) {
        case (.iOS, .automatic), (.iOS, .securityScoped):
            return .securityScoped
        case (.iOS, .unscopedLocal):
            throw AuthorizedFolderError.unscopedAccessUnsupported
        case (.macOS, .unscopedLocal):
            guard allowsUnscopedLocalAccess else {
                throw AuthorizedFolderError.unscopedAccessUnsupported
            }
            return .unscopedLocal
        case (.macOS, .securityScoped):
            return .securityScoped
        case (.macOS, .automatic):
            return hostIsSandboxed ? .securityScoped : .unscopedLocal
        }
    }

    func probeAccess(
        stored: AuthorizedFolderAccessKind,
        url: URL
    ) -> AuthorizedFolderAccessProbe {
        switch (platform, stored) {
        case (.iOS, .unscopedLocal):
            // iOS only grants access through a security-scoped URL.
            return .revoked(.scopeRequired)
        case (.iOS, .securityScoped):
            guard scoping.startAccessing(url) else {
                return .revoked(.accessDenied)
            }
            scoping.stopAccessing(url)
            return .granted(.securityScoped)
        case (.macOS, .unscopedLocal):
            guard allowsUnscopedLocalAccess else {
                return .revoked(.scopeRequired)
            }
            return .granted(.unscopedLocal)
        case (.macOS, .securityScoped):
            if scoping.startAccessing(url) {
                scoping.stopAccessing(url)
                return .granted(.securityScoped)
            }
            // Ad-hoc / non-sandboxed macOS builds cannot start a scope. If the
            // process is demonstrably local-only, the user-selected folder is
            // still usable without one.
            guard allowsUnscopedLocalAccess else {
                return .revoked(.accessDenied)
            }
            return .granted(.unscopedLocal)
        }
    }

    func beginAccess(
        url: URL,
        accessKind: AuthorizedFolderAccessKind
    ) throws -> AuthorizedFolderScopeLease {
        switch (platform, accessKind) {
        case (.iOS, .unscopedLocal):
            throw AuthorizedFolderError.scopeDenied
        case (.iOS, .securityScoped),
             (.macOS, .securityScoped):
            if scoping.startAccessing(url) {
                return AuthorizedFolderScopeLease(url: url, started: true, scoping: scoping)
            }
            guard allowsUnscopedLocalAccess else {
                throw AuthorizedFolderError.scopeDenied
            }
            return AuthorizedFolderScopeLease(url: url, started: false, scoping: scoping)
        case (.macOS, .unscopedLocal):
            guard allowsUnscopedLocalAccess else {
                throw AuthorizedFolderError.scopeDenied
            }
            return AuthorizedFolderScopeLease(url: url, started: false, scoping: scoping)
        }
    }
}

// MARK: - Availability and bounded reads

enum AuthorizedFolderAvailability {
    static func isContentAvailable(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else {
            return true
        }
        guard let status = values.ubiquitousItemDownloadingStatus else {
            return false
        }
        return status == .current || status == .downloaded
    }
}

// MARK: - Path safety and file helpers

enum AuthorizedFolderPath {
    static let itemKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    static func validate(relativePath: String, allowRoot: Bool) throws -> [String] {
        if relativePath.isEmpty {
            guard allowRoot else {
                throw AuthorizedFolderError.invalidRelativePath
            }
            return []
        }
        guard !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.utf8.contains(0)
        else {
            throw AuthorizedFolderError.invalidRelativePath
        }
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty else {
            throw AuthorizedFolderError.invalidRelativePath
        }
        for component in components {
            guard isSafeComponent(component) else {
                throw AuthorizedFolderError.invalidRelativePath
            }
        }
        return components
    }

    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.hasPrefix("~")
            && !component.contains("/")
            && !component.contains("\\")
            && !component.utf8.contains(0)
    }

    /// Lexical root normalization shared by every target/containment check.
    ///
    /// `standardizedFileURL` is filesystem-dependent: it strips a leading
    /// `/private` only when the shortened path currently exists. On iOS the
    /// iCloud Drive root lives under `/private/var/mobile/...`, and whether
    /// that check succeeds depends on whether the security scope is active.
    /// Targets are built before the scope lease and validated inside it, so a
    /// filesystem-dependent spelling made every authorized path look outside
    /// the root. `standardized` only removes dot segments.
    static func lexicalRoot(_ root: URL) -> URL {
        root.standardized
    }

    static func target(root: URL, components: [String]) -> URL {
        var url = lexicalRoot(root)
        for component in components {
            url.appendPathComponent(component, isDirectory: false)
        }
        return url
    }

    static func relativeComponents(of target: URL, under root: URL) -> [String]? {
        let rootComponents = lexicalRoot(root).pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        return Array(targetComponents.dropFirst(rootComponents.count))
    }

    static func canonicalDirectory(for url: URL) throws -> URL {
        guard url.isFileURL else {
            throw AuthorizedFolderError.invalidFolderURL
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw mapFileError(error, relativePath: url.lastPathComponent)
        }
        guard values.isDirectory == true else {
            throw AuthorizedFolderError.folderNotDirectory
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func validateTarget(
        root: URL,
        canonicalRoot: URL,
        target: URL,
        allowRoot: Bool,
        relativePath: String
    ) throws {
        let rootComponents = lexicalRoot(root).pathComponents
        let targetComponents = target.pathComponents
        let contained = targetComponents == rootComponents
            ? allowRoot
            : targetComponents.count > rootComponents.count
                && Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        guard contained else {
            throw AuthorizedFolderError.pathEscapesAuthorizedFolder(relativePath: relativePath)
        }
        _ = try validate(relativePath: relativePath, allowRoot: allowRoot)
        try ensureNoSymbolicLinkComponents(
            root: root,
            target: target,
            relativePath: relativePath
        )
    }

    /// Rejects a symbolic link at the exact URL, including a dangling link.
    ///
    /// `fileExists` follows links, so a dangling link looks exactly like a
    /// missing file; writing through it would create the file at the link's
    /// destination, outside the authorized folder. `destinationOfSymbolicLink`
    /// uses `readlink`, which reports the link even when its destination does
    /// not exist. Any failure means the leaf is not a link that can be followed
    /// (it is missing or a regular item), so the caller's existence and type
    /// checks decide, and a write to a leaf that cannot be inspected fails on
    /// its own.
    static func rejectSymbolicLink(at url: URL, relativePath: String) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return
        }
        throw AuthorizedFolderError.unsafeSymbolicLink(relativePath: relativePath)
    }

    static func ensureNoSymbolicLinkComponents(
        root: URL,
        target: URL,
        relativePath: String
    ) throws {
        let components = try validate(
            relativePath: relativePath,
            allowRoot: relativePath.isEmpty
        )
        guard !components.isEmpty else { return }
        var cursor = lexicalRoot(root)
        for (index, component) in components.enumerated() {
            cursor.appendPathComponent(component)
            try rejectSymbolicLink(at: cursor, relativePath: relativePath)
            let values: URLResourceValues
            do {
                values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            } catch {
                if isMissingFileError(error) { break }
                throw mapFileError(error, relativePath: relativePath)
            }
            guard values.isSymbolicLink != true else {
                throw AuthorizedFolderError.unsafeSymbolicLink(relativePath: relativePath)
            }
            if index < components.count - 1, values.isDirectory != true {
                throw AuthorizedFolderError.targetIsNotDirectory(relativePath: relativePath)
            }
        }
    }

    static func prepareParentDirectories(
        root: URL,
        canonicalRoot: URL,
        components: [String],
        relativePath: String
    ) throws {
        guard components.count > 1 else {
            return
        }
        var cursor = lexicalRoot(root)
        for index in 0..<(components.count - 1) {
            cursor.appendPathComponent(components[index], isDirectory: true)
            try rejectSymbolicLink(at: cursor, relativePath: relativePath)
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(
                atPath: cursor.path,
                isDirectory: &isDirectory
            )
            if exists {
                guard isDirectory.boolValue else {
                    throw AuthorizedFolderError.targetIsNotDirectory(relativePath: relativePath)
                }
            } else {
                do {
                    try FileManager.default.createDirectory(
                        at: cursor,
                        withIntermediateDirectories: false
                    )
                } catch {
                    var raceIsDirectory = ObjCBool(false)
                    guard FileManager.default.fileExists(
                        atPath: cursor.path,
                        isDirectory: &raceIsDirectory
                    ) else {
                        throw mapFileError(error, relativePath: relativePath)
                    }
                    guard raceIsDirectory.boolValue else {
                        throw AuthorizedFolderError.targetIsNotDirectory(relativePath: relativePath)
                    }
                }
            }
            try validateTarget(
                root: root,
                canonicalRoot: canonicalRoot,
                target: cursor,
                allowRoot: false,
                relativePath: relativePath
            )
        }
    }

    /// Lexical containment based on URL path components, not string prefixes.
    ///
    /// Directory URLs can carry a trailing slash in `absoluteString` while
    /// `.path` drops it, and the document picker, a bookmark, and
    /// `URL(string:)` can disagree about that separator for the same folder. A
    /// raw prefix test then rejects a child of the authorized folder. Path
    /// components normalize those spellings without touching the filesystem.
    static func isContained(_ candidate: URL, in root: URL, allowRoot: Bool) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        if candidateComponents == rootComponents {
            return allowRoot
        }
        guard candidateComponents.count > rootComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Resolves the URL that a coordinated operation must use for I/O.
    ///
    /// `NSFileCoordinator` owns the item while the accessor runs and may hand
    /// back a URL that differs from the one we requested: the system may
    /// normalize it (`/var` versus `/private/var`), expose the same directory
    /// through a file-provider alias, or reflect a rename performed by another
    /// file presenter. The accessor URL is the authoritative location, so I/O
    /// must use it. It is accepted only when it still identifies the requested
    /// item, or the requested item's parent folder when the item does not exist
    /// yet; otherwise a buggy or hostile provider could redirect I/O outside
    /// the authorized folder.
    static func coordinatedURL(
        _ coordinatedURL: URL,
        for target: URL,
        root: URL,
        allowRoot: Bool,
        relativePath: String
    ) throws -> URL {
        guard coordinatedURL.isFileURL else {
            throw AuthorizedFolderError.pathEscapesAuthorizedFolder(relativePath: relativePath)
        }
        // The kernel resolves `.` and `..` after following any symbolic link in
        // the preceding components. A URL such as `folder/link/../file` can
        // therefore standardize to `folder/file` while the actual I/O lands in
        // the link's destination. Percent-encoded dots arrive decoded in
        // `pathComponents`, so this also rejects `%2E%2E`.
        for component in coordinatedURL.pathComponents
        where component == "." || component == ".." {
            throw AuthorizedFolderError.pathEscapesAuthorizedFolder(relativePath: relativePath)
        }
        // The common case: the same lexical path, or a spelling that differs
        // only by separators. Alias prefixes such as `/var` and
        // `/private/var` do not standardize to the same path; they are
        // accepted by the parent-identity checks below. Re-check symbolic links
        // here because another process may have replaced a parent while
        // coordination was waiting; the pre-coordination check cannot cover
        // that window.
        if coordinatedURL.standardizedFileURL.path == target.standardizedFileURL.path {
            try ensureNoSymbolicLinkComponents(
                root: root,
                target: coordinatedURL,
                relativePath: relativePath
            )
            return coordinatedURL
        }
        if sameItem(coordinatedURL, target) {
            return coordinatedURL
        }
        if FileManager.default.fileExists(atPath: target.path) {
            // An existing item can also be reached through a directory alias.
            // Resolving both paths compares the item, not its spelling.
            if coordinatedURL.resolvingSymlinksInPath().standardizedFileURL.path
                == target.resolvingSymlinksInPath().standardizedFileURL.path {
                return coordinatedURL
            }
        } else {
            // A new file has no identity yet. The coordinator may hand back the
            // same item under a different leaf after another writer renamed it,
            // or under a provider-specific spelling of its directory, so compare
            // the existing parent folders instead of the missing leaf.
            let coordinatedParent = resolvedParent(of: coordinatedURL)
            let targetParent = resolvedParent(of: target)
            if sameItem(coordinatedParent, targetParent) {
                return coordinatedURL
            }
            if coordinatedParent.path == targetParent.path {
                return coordinatedURL
            }
            if isContained(coordinatedURL, in: root, allowRoot: false) {
                try ensureNoSymbolicLinkComponents(
                    root: root,
                    target: coordinatedURL,
                    relativePath: relativePath
                )
                return coordinatedURL
            }
        }
        throw AuthorizedFolderError.pathEscapesAuthorizedFolder(relativePath: relativePath)
    }

    /// Diagnostic-only classification. It never decides whether I/O proceeds;
    /// `coordinatedURL` remains the single acceptance gate.
    static func diagnosticRelation(
        _ coordinatedURL: URL,
        for target: URL,
        root: URL,
        allowRoot: Bool
    ) -> String {
        guard coordinatedURL.isFileURL else {
            return "notFileURL"
        }
        for component in coordinatedURL.pathComponents
        where component == "." || component == ".." {
            return "dotComponent"
        }
        if coordinatedURL.standardizedFileURL.path == target.standardizedFileURL.path {
            return "samePath"
        }
        if sameItem(coordinatedURL, target) {
            return "sameItem"
        }
        if FileManager.default.fileExists(atPath: target.path) {
            if coordinatedURL.resolvingSymlinksInPath().standardizedFileURL.path
                == target.resolvingSymlinksInPath().standardizedFileURL.path {
                return "resolvedItem"
            }
            return isContained(coordinatedURL, in: root, allowRoot: allowRoot)
                ? "insideRoot"
                : "outsideRoot"
        }
        let coordinatedParent = resolvedParent(of: coordinatedURL)
        let targetParent = resolvedParent(of: target)
        if sameItem(coordinatedParent, targetParent) {
            return "sameParentItem"
        }
        if coordinatedParent.path == targetParent.path {
            return "sameParentPath"
        }
        return isContained(coordinatedURL, in: root, allowRoot: allowRoot)
            ? "insideRoot"
            : "outsideRoot"
    }

    /// Diagnostic-only parent token. It never decides whether I/O proceeds.
    static func diagnosticParentRelation(_ coordinatedURL: URL, target: URL) -> String {
        let coordinatedParent = coordinatedURL.deletingLastPathComponent()
        let targetParent = target.deletingLastPathComponent()
        if sameItem(coordinatedParent, targetParent) {
            return "sameItem"
        }
        if coordinatedParent.standardizedFileURL.path == targetParent.standardizedFileURL.path {
            return "samePath"
        }
        return "different"
    }

    /// Resolves the existing prefix of a URL that may end in a missing leaf.
    /// `resolvingSymlinksInPath()` returns such a URL unchanged, so the parent
    /// must be resolved explicitly.
    private static func resolvedParent(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    /// Filesystem identity rather than a path string. File providers can expose
    /// the same directory through several paths; only device plus inode proves
    /// that two URLs name the same item.
    static func sameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = fileIdentity(lhs), let right = fileIdentity(rhs) else {
            return false
        }
        return left.device == right.device && left.inode == right.inode
    }

    private static func fileIdentity(_ url: URL) -> (device: NSNumber, inode: NSNumber)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            return nil
        }
        return (device, inode)
    }

    static func ensureExists(_ url: URL, relativePath: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorizedFolderError.fileNotFound(relativePath: relativePath)
        }
    }

    static func resourceValues(_ url: URL, relativePath: String) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: itemKeys)
        } catch {
            throw mapFileError(error, relativePath: relativePath)
        }
    }

    static func validateReadableFile(
        _ values: URLResourceValues,
        maxBytes: Int,
        relativePath: String
    ) throws {
        guard values.isSymbolicLink != true else {
            throw AuthorizedFolderError.unsafeSymbolicLink(relativePath: relativePath)
        }
        guard values.isDirectory != true else {
            throw AuthorizedFolderError.targetIsDirectory(relativePath: relativePath)
        }
        guard values.isRegularFile == true else {
            throw AuthorizedFolderError.targetIsNotFile(relativePath: relativePath)
        }
        guard AuthorizedFolderAvailability.isContentAvailable(values) else {
            // Never force a cloud download implicitly. The caller can use
            // `requestDownload`, poll `listDirectory`, then retry the read.
            throw AuthorizedFolderError.itemNotDownloaded(relativePath: relativePath)
        }
        if let fileSize = values.fileSize, fileSize > maxBytes {
            throw AuthorizedFolderError.fileTooLarge(
                relativePath: relativePath,
                byteCount: fileSize,
                maxBytes: maxBytes
            )
        }
    }

    static func readBounded(
        _ url: URL,
        maxBytes: Int,
        relativePath: String
    ) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw mapFileError(error, relativePath: relativePath)
        }
        defer {
            try? handle.close()
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        while data.count <= maxBytes {
            let remaining = maxBytes + 1 - data.count
            let chunkSize = min(64 * 1024, remaining)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw mapFileError(error, relativePath: relativePath)
            }
            if chunk.isEmpty {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maxBytes else {
            throw AuthorizedFolderError.fileTooLarge(
                relativePath: relativePath,
                byteCount: data.count,
                maxBytes: maxBytes
            )
        }
        return data
    }

    static func requestDownloadIfNeeded(
        _ url: URL,
        values: URLResourceValues,
        relativePath: String
    ) throws {
        guard values.isUbiquitousItem == true,
              !AuthorizedFolderAvailability.isContentAvailable(values)
        else {
            return
        }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw AuthorizedFolderError.downloadRequestFailed(
                relativePath: relativePath,
                code: (error as NSError).code
            )
        }
    }

    static func checkCancellation(_ generation: AuthorizedFolderGeneration) throws {
        if Task.isCancelled {
            throw AuthorizedFolderError.superseded(generation: generation)
        }
    }

    static func mapFileError(_ error: Error, relativePath: String) -> AuthorizedFolderError {
        if let folderError = error as? AuthorizedFolderError {
            return folderError
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.Code.fileReadNoSuchFile.rawValue:
                return .fileNotFound(relativePath: relativePath)
            case CocoaError.Code.fileReadNoPermission.rawValue,
                 CocoaError.Code.fileWriteNoPermission.rawValue:
                return .accessDenied(relativePath: relativePath)
            default:
                break
            }
        }
        return .ioFailed(relativePath: relativePath, code: nsError.code)
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }
}

// MARK: - Store

public actor AuthorizedFolderStore {
    private struct ActiveAuthorization: Sendable {
        let url: URL
        let canonicalRoot: URL
        let descriptor: AuthorizedFolderDescriptor
        let envelope: AuthorizedFolderBookmarkEnvelope
    }

    private struct PreparedAuthorization: Sendable {
        let url: URL
        let canonicalRoot: URL
        let accessKind: AuthorizedFolderAccessKind
        let bookmarkData: Data
        let displayName: String
    }

    private struct InFlightOperation: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private let environment: AuthorizedFolderEnvironment
    private let bookmarkStore: any AuthorizedFolderBookmarkStoring
    private let bookmarkDirectory: URL
    private let diagnosticsDirectory: URL?

    private var active: ActiveAuthorization?
    private var currentState: AuthorizedFolderState = .notLoaded
    private var lastGeneration: UInt64 = 0
    private var isTransitioning = false
    private var inFlight: [UUID: InFlightOperation] = [:]
    private var observers: [UUID: AsyncStream<AuthorizedFolderState>.Continuation] = [:]

    public init(
        bookmarkDirectory: URL,
        scopePolicy: AuthorizedFolderScopePolicy = .automatic,
        diagnosticsDirectory: URL? = nil
    ) {
        let platform = AuthorizedFolderHostPlatform.current
        self.init(
            bookmarkDirectory: bookmarkDirectory,
            scopePolicy: scopePolicy,
            platform: platform,
            hostIsSandboxed: AuthorizedFolderEnvironment.detectSandboxed(platform: platform),
            diagnosticsDirectory: diagnosticsDirectory
        )
    }

    init(
        bookmarkDirectory: URL,
        scopePolicy: AuthorizedFolderScopePolicy,
        platform: AuthorizedFolderHostPlatform,
        hostIsSandboxed: Bool,
        bookmarkCoding: any AuthorizedFolderBookmarkCoding = AuthorizedFolderLiveBookmarkCoding(),
        scoping: any AuthorizedFolderSecurityScoping = AuthorizedFolderLiveSecurityScoping(),
        coordinating: any AuthorizedFolderCoordinating = AuthorizedFolderLiveCoordinating(),
        bookmarkStore: (any AuthorizedFolderBookmarkStoring)? = nil,
        diagnosticsDirectory: URL? = nil
    ) {
        self.environment = AuthorizedFolderEnvironment(
            platform: platform,
            scopePolicy: scopePolicy,
            hostIsSandboxed: hostIsSandboxed,
            bookmarkCoding: bookmarkCoding,
            scoping: scoping,
            coordinating: coordinating
        )
        self.bookmarkStore = bookmarkStore ?? AuthorizedFolderBookmarkFileStore(
            directory: bookmarkDirectory
        )
        self.bookmarkDirectory = bookmarkDirectory.standardizedFileURL
        self.diagnosticsDirectory = diagnosticsDirectory
    }

    /// Records only the stage and the error case; never a path or content.
    private func record(_ event: String) {
        guard let diagnosticsDirectory else { return }
        SyncDiagnostics.record(event, in: diagnosticsDirectory)
    }

    /// A Sendable sink for coordinated-access events recorded from inside the
    /// synchronous `NSFileCoordinator` accessor. The events contain fixed
    /// tokens and booleans only, never paths or user-visible names.
    private func diagnosticSink() -> @Sendable (String) -> Void {
        guard let diagnosticsDirectory else {
            return { _ in }
        }
        return { event in
            SyncDiagnostics.record(event, in: diagnosticsDirectory)
        }
    }

    /// Builds the accessor event after the real acceptance gate has run.
    /// `item` must be derived from `coordinatedURL` itself; a separate
    /// relationship guess can label an item accepted when the gate later
    /// rejects it, for example because of a symlinked parent.
    private static func diagnosticAccessorEvent(
        stage: String,
        item: String,
        relation: String,
        coordinatedURL: URL,
        target: URL,
        targetExistedBefore: Bool
    ) -> String {
        "coordinate-accessor:stage=\(stage)"
            + " item=\(item)"
            + " relation=\(relation)"
            + " target=\(targetExistedBefore ? "existing" : "missing")"
            + " leaf=\(coordinatedURL.lastPathComponent == target.lastPathComponent ? "same" : "different")"
            + " parent=\(AuthorizedFolderPath.diagnosticParentRelation(coordinatedURL, target: target))"
    }

    // MARK: Observation

    public func state() -> AuthorizedFolderState {
        currentState
    }

    public func stateUpdates() -> AsyncStream<AuthorizedFolderState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthorizedFolderState.self)
        let observerID = UUID()
        observers[observerID] = continuation
        continuation.yield(currentState)
        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task { await self.removeObserver(observerID) }
        }
        return stream
    }

    // MARK: Lifecycle

    @discardableResult
    public func open() async -> AuthorizedFolderState {
        guard !isTransitioning else {
            return currentState
        }
        switch currentState {
        case .notLoaded, .notAuthorized, .revoked:
            return loadAuthorization()
        case .active, .stale, .transitioning:
            return currentState
        }
    }

    @discardableResult
    public func reopen() async -> AuthorizedFolderState {
        guard !isTransitioning else {
            return currentState
        }
        do {
            _ = try beginTransition()
        } catch {
            return currentState
        }
        await drainOperations()
        let result = loadAuthorization()
        isTransitioning = false
        return result
    }

    @discardableResult
    public func authorize(_ folderURL: URL) async throws -> AuthorizedFolderDescriptor {
        guard !isTransitioning else {
            throw AuthorizedFolderError.transitionInProgress
        }
        switch currentState {
        case .active(let descriptor), .stale(let descriptor):
            throw AuthorizedFolderError.alreadyAuthorized(displayName: descriptor.displayName)
        case .transitioning:
            throw AuthorizedFolderError.transitionInProgress
        case .notLoaded, .notAuthorized, .revoked:
            break
        }

        if case .notLoaded = currentState {
            var stored: AuthorizedFolderBookmarkEnvelope?
            do {
                stored = try bookmarkStore.load()
            } catch {
                stored = nil
            }
            if let stored {
                lastGeneration = max(lastGeneration, stored.generation.rawValue)
                if stored.platform == environment.platform {
                    throw AuthorizedFolderError.alreadyAuthorized(displayName: stored.displayName)
                }
            }
        }

        let prepared = try prepareAuthorization(for: folderURL)
        let generation = nextGeneration()
        let now = Date()
        let envelope = makeEnvelope(
            prepared: prepared,
            generation: generation,
            authorizedAt: now,
            refreshedAt: now
        )
        do {
            try bookmarkStore.save(envelope)
        } catch {
            record("bookmark-save-error:bookmarkWriteFailed")
            throw Self.publicError(for: error)
        }
        let descriptor = makeDescriptor(
            generation: generation,
            prepared: prepared,
            authorizedAt: now,
            refreshedAt: now
        )
        active = ActiveAuthorization(
            url: prepared.url,
            canonicalRoot: prepared.canonicalRoot,
            descriptor: descriptor,
            envelope: envelope
        )
        setState(.active(descriptor))
        return descriptor
    }

    @discardableResult
    public func replaceAuthorization(with folderURL: URL) async throws -> AuthorizedFolderDescriptor {
        guard !isTransitioning else {
            throw AuthorizedFolderError.transitionInProgress
        }
        // Validate and create the new bookmark before cancelling old work. A
        // bad selection must not disrupt the previous authorization.
        let prepared = try prepareAuthorization(for: folderURL)
        let previousState = try beginTransition()
        await drainOperations()

        let generation = AuthorizedFolderGeneration(lastGeneration)
        let now = Date()
        let envelope = makeEnvelope(
            prepared: prepared,
            generation: generation,
            authorizedAt: now,
            refreshedAt: now
        )
        do {
            try bookmarkStore.save(envelope)
        } catch {
            restoreState(previousState)
            throw Self.publicError(for: error)
        }
        let descriptor = makeDescriptor(
            generation: generation,
            prepared: prepared,
            authorizedAt: now,
            refreshedAt: now
        )
        active = ActiveAuthorization(
            url: prepared.url,
            canonicalRoot: prepared.canonicalRoot,
            descriptor: descriptor,
            envelope: envelope
        )
        isTransitioning = false
        setState(.active(descriptor))
        return descriptor
    }

    public func disable() async throws {
        guard !isTransitioning else {
            throw AuthorizedFolderError.transitionInProgress
        }
        let previousState = try beginTransition()
        await drainOperations()
        do {
            // Local bookmark only. Disabling never deletes files in the
            // authorized folder, local data, or previously synced cloud data.
            try bookmarkStore.remove()
        } catch {
            restoreState(previousState)
            throw Self.publicError(for: error)
        }
        active = nil
        isTransitioning = false
        setState(.notAuthorized)
    }

    // MARK: Reads and writes

    /// Reads one regular file, never more than `maxBytes`.
    ///
    /// `maxBytes` is required so no caller can accidentally materialize an
    /// unbounded file. A cloud item that is present but not materialized gets
    /// an explicit download request before this method reports it as pending.
    /// The request is non-blocking and the caller can retry after the provider
    /// finishes materialization.
    public func read(relativePath: String, maxBytes: Int) async throws -> Data {
        guard maxBytes > 0, maxBytes < Int.max else {
            throw AuthorizedFolderError.invalidReadLimit
        }
        let session = try requireSession()
        let components = try AuthorizedFolderPath.validate(relativePath: relativePath, allowRoot: false)
        let target = AuthorizedFolderPath.target(root: session.url, components: components)
        let generation = session.descriptor.generation
        let environment = self.environment
        let sink = diagnosticSink()
        return try await runOperation(generation: generation) {
            try AuthorizedFolderPath.checkCancellation(generation)
            let lease = try environment.beginAccess(
                url: session.url,
                accessKind: session.descriptor.accessKind
            )
            defer { lease.stop() }
            try AuthorizedFolderPath.validateTarget(
                root: session.url,
                canonicalRoot: session.canonicalRoot,
                target: target,
                allowRoot: false,
                relativePath: relativePath
            )
            let preflightValues = try AuthorizedFolderPath.resourceValues(
                target,
                relativePath: relativePath
            )
            // Ask the file provider to materialize cloud content before any
            // coordinated read. This keeps callers from having to discover
            // and special-case `notDownloaded` before requesting the download.
            try AuthorizedFolderPath.requestDownloadIfNeeded(
                target,
                values: preflightValues,
                relativePath: relativePath
            )
            try AuthorizedFolderPath.validateReadableFile(
                preflightValues,
                maxBytes: maxBytes,
                relativePath: relativePath
            )
            sink("coordinate-start:stage=read target=existing")
            do {
                return try environment.coordinating.coordinateReading(at: target) { coordinatedURL in
                    try AuthorizedFolderPath.checkCancellation(generation)
                    let relation = AuthorizedFolderPath.diagnosticRelation(
                        coordinatedURL,
                        for: target,
                        root: session.url,
                        allowRoot: false
                    )
                    let coordinatedTarget: URL
                    do {
                        coordinatedTarget = try AuthorizedFolderPath.coordinatedURL(
                            coordinatedURL,
                            for: target,
                            root: session.url,
                            allowRoot: false,
                            relativePath: relativePath
                        )
                    } catch {
                        sink(
                            Self.diagnosticAccessorEvent(
                                stage: "read",
                                item: "rejected",
                                relation: relation,
                                coordinatedURL: coordinatedURL,
                                target: target,
                                targetExistedBefore: true
                            )
                        )
                        throw error
                    }
                    sink(
                        Self.diagnosticAccessorEvent(
                            stage: "read",
                            item: "accepted",
                            relation: relation,
                            coordinatedURL: coordinatedURL,
                            target: target,
                            targetExistedBefore: true
                        )
                    )
                    let values = try AuthorizedFolderPath.resourceValues(
                        coordinatedTarget,
                        relativePath: relativePath
                    )
                    try AuthorizedFolderPath.validateReadableFile(
                        values,
                        maxBytes: maxBytes,
                        relativePath: relativePath
                    )
                    return try AuthorizedFolderPath.readBounded(
                        coordinatedTarget,
                        maxBytes: maxBytes,
                        relativePath: relativePath
                    )
                }
            } catch let error as AuthorizedFolderError {
                if case .coordinatedAccessFailed = error {
                    sink("coordinate-failed:stage=read reason=coordination")
                }
                throw error
            }
        }
    }

    /// Atomically writes one file, creating missing parent directories inside
    /// the authorized folder. Only the exact relative path is replaced; the
    /// store exposes no deletion, move, or remote-deletion operation.
    public func write(_ data: Data, relativePath: String) async throws {
        let session = try requireSession()
        let components = try AuthorizedFolderPath.validate(relativePath: relativePath, allowRoot: false)
        let target = AuthorizedFolderPath.target(root: session.url, components: components)
        let generation = session.descriptor.generation
        let environment = self.environment
        let sink = diagnosticSink()
        _ = try await runOperation(generation: generation) {
            try AuthorizedFolderPath.checkCancellation(generation)
            let lease = try environment.beginAccess(
                url: session.url,
                accessKind: session.descriptor.accessKind
            )
            defer { lease.stop() }
            try AuthorizedFolderPath.prepareParentDirectories(
                root: session.url,
                canonicalRoot: session.canonicalRoot,
                components: components,
                relativePath: relativePath
            )
            try AuthorizedFolderPath.validateTarget(
                root: session.url,
                canonicalRoot: session.canonicalRoot,
                target: target,
                allowRoot: false,
                relativePath: relativePath
            )
            let targetExistedBefore = FileManager.default.fileExists(atPath: target.path)
            sink(
                "coordinate-start:stage=write"
                    + " target=\(targetExistedBefore ? "existing" : "missing")"
            )
            do {
                return try environment.coordinating.coordinateWriting(at: target) { coordinatedURL in
                    try AuthorizedFolderPath.checkCancellation(generation)
                    let relation = AuthorizedFolderPath.diagnosticRelation(
                        coordinatedURL,
                        for: target,
                        root: session.url,
                        allowRoot: false
                    )
                    let coordinatedTarget: URL
                    do {
                        coordinatedTarget = try AuthorizedFolderPath.coordinatedURL(
                            coordinatedURL,
                            for: target,
                            root: session.url,
                            allowRoot: false,
                            relativePath: relativePath
                        )
                    } catch {
                        sink(
                            Self.diagnosticAccessorEvent(
                                stage: "write",
                                item: "rejected",
                                relation: relation,
                                coordinatedURL: coordinatedURL,
                                target: target,
                                targetExistedBefore: targetExistedBefore
                            )
                        )
                        throw error
                    }
                    sink(
                        Self.diagnosticAccessorEvent(
                            stage: "write",
                            item: "accepted",
                            relation: relation,
                            coordinatedURL: coordinatedURL,
                            target: target,
                            targetExistedBefore: targetExistedBefore
                        )
                    )
                    // The coordinator may hand back a different leaf inside the
                    // same folder. Check that leaf for a symbolic link before
                    // `fileExists`, which follows links and reports a dangling
                    // one as missing; writing through it would create the file
                    // at the link's destination, possibly outside the
                    // authorized folder.
                    try AuthorizedFolderPath.rejectSymbolicLink(
                        at: coordinatedTarget,
                        relativePath: relativePath
                    )
                    if FileManager.default.fileExists(atPath: coordinatedTarget.path) {
                        let values: URLResourceValues
                        do {
                            values = try coordinatedTarget.resourceValues(forKeys: AuthorizedFolderPath.itemKeys)
                        } catch {
                            throw AuthorizedFolderPath.mapFileError(error, relativePath: relativePath)
                        }
                        guard values.isSymbolicLink != true else {
                            throw AuthorizedFolderError.unsafeSymbolicLink(relativePath: relativePath)
                        }
                        guard values.isDirectory != true else {
                            throw AuthorizedFolderError.targetIsDirectory(relativePath: relativePath)
                        }
                        guard values.isRegularFile == true else {
                            throw AuthorizedFolderError.targetIsNotFile(relativePath: relativePath)
                        }
                    }
                    do {
                        // Coordination already serializes the replacement.
                        // Writing atomically here would add a second temp-file
                        // + rename step, which file providers (iCloud Drive)
                        // can reject.
                        try data.write(to: coordinatedTarget)
                    } catch {
                        throw AuthorizedFolderPath.mapFileError(error, relativePath: relativePath)
                    }
                }
            } catch let error as AuthorizedFolderError {
                if case .coordinatedAccessFailed = error {
                    sink("coordinate-failed:stage=write reason=coordination")
                }
                throw error
            }
        }
    }

    /// Lists direct children of a folder (the root when `relativePath` is
    /// empty). Returned paths are relative to the authorized folder root and
    /// symbolic links are omitted. Non-materialized iCloud items are reported
    /// with `isDownloaded == false`.
    public func listDirectory(
        relativePath: String = "",
        includingHiddenFiles: Bool = false
    ) async throws -> [AuthorizedFolderEntry] {
        let session = try requireSession()
        let components = try AuthorizedFolderPath.validate(relativePath: relativePath, allowRoot: true)
        let target = AuthorizedFolderPath.target(root: session.url, components: components)
        let generation = session.descriptor.generation
        let environment = self.environment
        let sink = diagnosticSink()
        return try await runOperation(generation: generation) {
            try AuthorizedFolderPath.checkCancellation(generation)
            let lease = try environment.beginAccess(
                url: session.url,
                accessKind: session.descriptor.accessKind
            )
            defer { lease.stop() }
            try AuthorizedFolderPath.validateTarget(
                root: session.url,
                canonicalRoot: session.canonicalRoot,
                target: target,
                allowRoot: true,
                relativePath: relativePath
            )
            try AuthorizedFolderPath.ensureExists(target, relativePath: relativePath)
            sink("coordinate-start:stage=list target=existing")
            do {
                return try environment.coordinating.coordinateReading(at: target) { coordinatedURL in
                    try AuthorizedFolderPath.checkCancellation(generation)
                    let relation = AuthorizedFolderPath.diagnosticRelation(
                        coordinatedURL,
                        for: target,
                        root: session.url,
                        allowRoot: true
                    )
                    let coordinatedTarget: URL
                    do {
                        coordinatedTarget = try AuthorizedFolderPath.coordinatedURL(
                            coordinatedURL,
                            for: target,
                            root: session.url,
                            allowRoot: true,
                            relativePath: relativePath
                        )
                    } catch {
                        sink(
                            Self.diagnosticAccessorEvent(
                                stage: "list",
                                item: "rejected",
                                relation: relation,
                                coordinatedURL: coordinatedURL,
                                target: target,
                                targetExistedBefore: true
                            )
                        )
                        throw error
                    }
                    sink(
                        Self.diagnosticAccessorEvent(
                            stage: "list",
                            item: "accepted",
                            relation: relation,
                            coordinatedURL: coordinatedURL,
                            target: target,
                            targetExistedBefore: true
                        )
                    )
                guard let actualComponents = AuthorizedFolderPath.relativeComponents(
                    of: target,
                    under: session.url
                ) else {
                    throw AuthorizedFolderError.pathEscapesAuthorizedFolder(
                        relativePath: relativePath
                    )
                }
                let actualPrefix = actualComponents.joined(separator: "/")
                let values: URLResourceValues
                do {
                    values = try coordinatedTarget.resourceValues(forKeys: AuthorizedFolderPath.itemKeys)
                } catch {
                    throw AuthorizedFolderPath.mapFileError(error, relativePath: relativePath)
                }
                guard values.isDirectory == true else {
                    throw AuthorizedFolderError.targetIsNotDirectory(
                        relativePath: relativePath.isEmpty ? "/" : relativePath
                    )
                }
                let options: FileManager.DirectoryEnumerationOptions = includingHiddenFiles
                    ? []
                    : [.skipsHiddenFiles]
                let children: [URL]
                do {
                    children = try FileManager.default.contentsOfDirectory(
                        at: coordinatedTarget,
                        includingPropertiesForKeys: Array(AuthorizedFolderPath.itemKeys),
                        options: options
                    )
                } catch {
                    throw AuthorizedFolderPath.mapFileError(error, relativePath: relativePath)
                }
                var entries: [AuthorizedFolderEntry] = []
                for child in children {
                    try AuthorizedFolderPath.checkCancellation(generation)
                    let name = child.lastPathComponent
                    guard AuthorizedFolderPath.isSafeComponent(name) else {
                        continue
                    }
                    let childValues: URLResourceValues
                    do {
                        childValues = try child.resourceValues(forKeys: AuthorizedFolderPath.itemKeys)
                    } catch {
                        continue
                    }
                    guard childValues.isSymbolicLink != true else {
                        continue
                    }
                    let kind: AuthorizedFolderEntry.Kind
                    if childValues.isDirectory == true {
                        kind = .directory
                    } else if childValues.isRegularFile == true {
                        kind = .file
                    } else {
                        continue
                    }
                    let entryPath = actualPrefix.isEmpty ? name : actualPrefix + "/" + name
                    entries.append(
                        AuthorizedFolderEntry(
                            relativePath: entryPath,
                            kind: kind,
                            fileSize: kind == .file ? childValues.fileSize : nil,
                            modificationDate: childValues.contentModificationDate,
                            isDownloaded: kind == .directory
                                ? true
                                : AuthorizedFolderAvailability.isContentAvailable(childValues)
                        )
                    )
                }
                    return entries.sorted { $0.relativePath < $1.relativePath }
                }
            } catch let error as AuthorizedFolderError {
                if case .coordinatedAccessFailed = error {
                    sink("coordinate-failed:stage=list reason=coordination")
                }
                throw error
            }
        }
    }

    /// Asks the system to download one not-yet-materialized iCloud item.
    ///
    /// This is a public, explicit request; it does not wait for completion and
    /// does not download automatically as a side effect of `read`. Poll
    /// `listDirectory` for `isDownloaded`, then retry the read. Local items are
    /// a no-op.
    public func requestDownload(relativePath: String) async throws {
        let session = try requireSession()
        let components = try AuthorizedFolderPath.validate(relativePath: relativePath, allowRoot: false)
        let target = AuthorizedFolderPath.target(root: session.url, components: components)
        let generation = session.descriptor.generation
        let environment = self.environment
        _ = try await runOperation(generation: generation) {
            try AuthorizedFolderPath.checkCancellation(generation)
            let lease = try environment.beginAccess(
                url: session.url,
                accessKind: session.descriptor.accessKind
            )
            defer { lease.stop() }
            try AuthorizedFolderPath.validateTarget(
                root: session.url,
                canonicalRoot: session.canonicalRoot,
                target: target,
                allowRoot: false,
                relativePath: relativePath
            )
            try AuthorizedFolderPath.ensureExists(target, relativePath: relativePath)
            // `startDownloadingUbiquitousItem` must be called before any
            // coordinated read, otherwise the coordinator itself could block
            // waiting for materialization.
            let values = try AuthorizedFolderPath.resourceValues(
                target,
                relativePath: relativePath
            )
            guard values.isSymbolicLink != true else {
                throw AuthorizedFolderError.unsafeSymbolicLink(relativePath: relativePath)
            }
            guard values.isDirectory != true else {
                throw AuthorizedFolderError.targetIsDirectory(relativePath: relativePath)
            }
            guard values.isRegularFile == true else {
                throw AuthorizedFolderError.targetIsNotFile(relativePath: relativePath)
            }
            try AuthorizedFolderPath.requestDownloadIfNeeded(
                target,
                values: values,
                relativePath: relativePath
            )
        }
    }

    /// Runs `body` while holding a paired security scope for the authorized
    /// folder. This is the escape hatch for advanced coordinated work; normal
    /// syncing should use `read`, `write`, and `listDirectory`.
    public func withSecurityScopedAccess<T: Sendable>(
        _ body: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let session = try requireSession()
        let generation = session.descriptor.generation
        let environment = self.environment
        return try await runOperation(generation: generation) {
            try AuthorizedFolderPath.checkCancellation(generation)
            let lease = try environment.beginAccess(
                url: session.url,
                accessKind: session.descriptor.accessKind
            )
            defer { lease.stop() }
            try AuthorizedFolderPath.checkCancellation(generation)
            let value = try await body(session.url)
            try AuthorizedFolderPath.checkCancellation(generation)
            return value
        }
    }

    // MARK: Authorization preparation

    private func prepareAuthorization(for folderURL: URL) throws -> PreparedAuthorization {
        let desiredAccessKind = try environment.desiredAccessKind()
        guard folderURL.isFileURL else {
            throw AuthorizedFolderError.invalidFolderURL
        }

        // A document-picker URL carries its security scope on the object the
        // system returned. Any derived URL (`standardizedFileURL`,
        // `resolvingSymlinksInPath`, ...) can lose that scope, after which the
        // first read or write fails with accessDenied even though the folder is
        // perfectly reachable in Files. Start and keep the lease on the exact
        // URL we were handed and store that URL for later operations.
        var effectiveAccessKind = desiredAccessKind
        var lease: AuthorizedFolderScopeLease?
        if desiredAccessKind == .securityScoped {
            if environment.scoping.startAccessing(folderURL) {
                lease = AuthorizedFolderScopeLease(
                    url: folderURL,
                    started: true,
                    scoping: environment.scoping
                )
            } else if environment.allowsUnscopedLocalAccess {
                // macOS non-sandboxed / ad-hoc: fall back to plain local
                // access instead of failing authorization.
                effectiveAccessKind = .unscopedLocal
            } else {
                record("scope-denied: startAccessing=false")
                throw AuthorizedFolderError.scopeDenied
            }
        }
        defer { lease?.stop() }

        let canonicalRoot = try AuthorizedFolderPath.canonicalDirectory(for: folderURL)
        try validateBookmarkLocation(against: canonicalRoot)
        let bookmarkData = try makeBookmarkData(for: folderURL, accessKind: effectiveAccessKind)
        let name = folderURL.lastPathComponent
        return PreparedAuthorization(
            url: folderURL,
            canonicalRoot: canonicalRoot,
            accessKind: effectiveAccessKind,
            bookmarkData: bookmarkData,
            displayName: name.isEmpty ? "/" : name
        )
    }

    private func makeBookmarkData(
        for url: URL,
        accessKind: AuthorizedFolderAccessKind
    ) throws -> Data {
        if accessKind == .unscopedLocal {
            guard environment.allowsUnscopedLocalAccess else {
                throw AuthorizedFolderError.unscopedAccessUnsupported
            }
        }
        do {
            return try environment.bookmarkCoding.makeBookmark(
                for: url,
                accessKind: accessKind
            )
        } catch {
            record("bookmark-create-error:bookmarkCreationFailed")
            throw AuthorizedFolderError.bookmarkCreationFailed(code: (error as NSError).code)
        }
    }

    private func validateBookmarkLocation(against folderCanonical: URL) throws {
        guard bookmarkDirectory.isFileURL else {
            throw AuthorizedFolderError.invalidBookmarkDirectory
        }
        let storeCanonical = bookmarkDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        if AuthorizedFolderPath.isContained(storeCanonical, in: folderCanonical, allowRoot: true) {
            throw AuthorizedFolderError.bookmarkLocationOverlapsFolder
        }
    }

    private func makeEnvelope(
        prepared: PreparedAuthorization,
        generation: AuthorizedFolderGeneration,
        authorizedAt: Date,
        refreshedAt: Date
    ) -> AuthorizedFolderBookmarkEnvelope {
        AuthorizedFolderBookmarkEnvelope(
            schemaVersion: AuthorizedFolderBookmarkEnvelope.currentSchemaVersion,
            platform: environment.platform,
            accessKind: prepared.accessKind,
            generation: generation,
            authorizedAt: authorizedAt,
            refreshedAt: refreshedAt,
            displayName: prepared.displayName,
            bookmarkData: prepared.bookmarkData
        )
    }

    private func makeDescriptor(
        generation: AuthorizedFolderGeneration,
        prepared: PreparedAuthorization,
        authorizedAt: Date,
        refreshedAt: Date
    ) -> AuthorizedFolderDescriptor {
        AuthorizedFolderDescriptor(
            generation: generation,
            displayName: prepared.displayName,
            accessKind: prepared.accessKind,
            authorizedAt: authorizedAt,
            refreshedAt: refreshedAt
        )
    }

    // MARK: Loading and revocation

    private func loadAuthorization() -> AuthorizedFolderState {
        let stored: AuthorizedFolderBookmarkEnvelope?
        do {
            stored = try bookmarkStore.load()
        } catch {
            return revoke(reason: Self.loadRevocationReason(for: error))
        }
        guard let envelope = stored else {
            active = nil
            setState(.notAuthorized)
            return .notAuthorized
        }

        lastGeneration = max(lastGeneration, envelope.generation.rawValue)
        let generation = AuthorizedFolderGeneration(lastGeneration)

        guard envelope.platform == environment.platform else {
            return revoke(
                reason: .platformMismatch,
                displayName: envelope.displayName,
                generation: generation
            )
        }

        let resolved: AuthorizedFolderResolvedBookmark
        do {
            resolved = try environment.bookmarkCoding.resolveBookmark(
                envelope.bookmarkData,
                accessKind: envelope.accessKind
            )
        } catch {
            return revoke(
                reason: Self.resolutionRevocationReason(for: error),
                displayName: envelope.displayName,
                generation: generation
            )
        }

        guard resolved.url.isFileURL else {
            return revoke(
                reason: .unsupportedLocation,
                displayName: envelope.displayName,
                generation: generation
            )
        }
        let root = resolved.url.standardizedFileURL
        let effectiveAccessKind: AuthorizedFolderAccessKind
        switch environment.probeAccess(stored: envelope.accessKind, url: root) {
        case .granted(let accessKind):
            effectiveAccessKind = accessKind
        case .revoked(let reason):
            return revoke(
                reason: reason,
                displayName: envelope.displayName,
                generation: generation
            )
        }

        // Validate the directory while the effective scope is held. On iOS a
        // resolved security-scoped URL cannot be inspected before starting it.
        let canonicalRoot: URL
        do {
            let lease = try environment.beginAccess(
                url: root,
                accessKind: effectiveAccessKind
            )
            defer { lease.stop() }
            canonicalRoot = try AuthorizedFolderPath.canonicalDirectory(for: root)
        } catch let error as AuthorizedFolderError {
            return revoke(
                reason: error.revocationReason,
                displayName: envelope.displayName,
                generation: generation
            )
        } catch {
            return revoke(
                reason: .targetMissing,
                displayName: envelope.displayName,
                generation: generation
            )
        }

        let needsRefresh = resolved.isStale || effectiveAccessKind != envelope.accessKind
        var activeEnvelope = envelope
        var refreshedAt = envelope.refreshedAt
        if needsRefresh,
           let refreshed = refreshBookmark(
               envelope: envelope,
               url: root,
               accessKind: effectiveAccessKind,
               generation: generation
           ) {
            activeEnvelope = refreshed
            refreshedAt = refreshed.refreshedAt
        }

        let displayName = envelope.displayName.isEmpty
            ? (root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent)
            : envelope.displayName
        let descriptor = AuthorizedFolderDescriptor(
            generation: generation,
            displayName: displayName,
            accessKind: effectiveAccessKind,
            authorizedAt: envelope.authorizedAt,
            refreshedAt: refreshedAt
        )
        active = ActiveAuthorization(
            url: root,
            canonicalRoot: canonicalRoot,
            descriptor: descriptor,
            envelope: activeEnvelope
        )
        let newState: AuthorizedFolderState = resolved.isStale
            ? .stale(descriptor)
            : .active(descriptor)
        setState(newState)
        return newState
    }

    private func refreshBookmark(
        envelope: AuthorizedFolderBookmarkEnvelope,
        url: URL,
        accessKind: AuthorizedFolderAccessKind,
        generation: AuthorizedFolderGeneration
    ) -> AuthorizedFolderBookmarkEnvelope? {
        guard let data = bookmarkDataForRefresh(url: url, accessKind: accessKind) else {
            return nil
        }
        // Defensive: never refresh a local bookmark into a synced folder if
        // the caller's storage configuration now overlaps the selection.
        do {
            try validateBookmarkLocation(
                against: url.resolvingSymlinksInPath().standardizedFileURL
            )
        } catch {
            return nil
        }
        let now = Date()
        let refreshed = AuthorizedFolderBookmarkEnvelope(
            schemaVersion: AuthorizedFolderBookmarkEnvelope.currentSchemaVersion,
            platform: environment.platform,
            accessKind: accessKind,
            generation: generation,
            authorizedAt: envelope.authorizedAt,
            refreshedAt: now,
            displayName: envelope.displayName,
            bookmarkData: data
        )
        do {
            try bookmarkStore.save(refreshed)
            return refreshed
        } catch {
            return nil
        }
    }

    private func bookmarkDataForRefresh(
        url: URL,
        accessKind: AuthorizedFolderAccessKind
    ) -> Data? {
        switch accessKind {
        case .unscopedLocal:
            guard environment.allowsUnscopedLocalAccess else {
                return nil
            }
            return try? environment.bookmarkCoding.makeBookmark(
                for: url,
                accessKind: .unscopedLocal
            )
        case .securityScoped:
            guard environment.scoping.startAccessing(url) else {
                return nil
            }
            defer { environment.scoping.stopAccessing(url) }
            return try? environment.bookmarkCoding.makeBookmark(
                for: url,
                accessKind: .securityScoped
            )
        }
    }

    private func revoke(
        reason: AuthorizedFolderRevocationReason,
        displayName: String? = nil,
        generation: AuthorizedFolderGeneration? = nil
    ) -> AuthorizedFolderState {
        active = nil
        let revocationGeneration = generation
            ?? (lastGeneration > 0 ? AuthorizedFolderGeneration(lastGeneration) : nil)
        record("revoked: \(reason.rawValue)")
        let revocation = AuthorizedFolderRevocation(
            generation: revocationGeneration,
            displayName: displayName,
            reason: reason
        )
        setState(.revoked(revocation))
        return .revoked(revocation)
    }

    private static func loadRevocationReason(for error: Error) -> AuthorizedFolderRevocationReason {
        guard let storeError = error as? AuthorizedFolderBookmarkStoreError else {
            return .bookmarkStorageUnavailable
        }
        switch storeError {
        case .decodeFailed:
            return .bookmarkCorrupted
        case .unsupportedVersion:
            return .unsupportedBookmarkVersion
        case .invalidDirectory, .readFailed, .writeFailed, .removeFailed:
            return .bookmarkStorageUnavailable
        }
    }

    private static func resolutionRevocationReason(for error: Error) -> AuthorizedFolderRevocationReason {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.Code.fileReadNoSuchFile.rawValue:
                return .targetMissing
            case CocoaError.Code.fileReadNoPermission.rawValue:
                return .accessDenied
            case CocoaError.Code.fileReadCorruptFile.rawValue:
                return .bookmarkCorrupted
            default:
                break
            }
        }
        return .bookmarkUnresolvable
    }

    // MARK: Transitions and operations

    private func requireSession() throws -> ActiveAuthorization {
        switch currentState {
        case .notLoaded:
            throw AuthorizedFolderError.notLoaded
        case .notAuthorized:
            throw AuthorizedFolderError.notAuthorized
        case .revoked(let revocation):
            throw AuthorizedFolderError.authorizationRevoked(revocation)
        case .transitioning:
            throw AuthorizedFolderError.transitionInProgress
        case .active, .stale:
            guard let active else {
                throw AuthorizedFolderError.notAuthorized
            }
            return active
        }
    }

    @discardableResult
    private func beginTransition() throws -> AuthorizedFolderState {
        guard !isTransitioning else {
            throw AuthorizedFolderError.transitionInProgress
        }
        let previousState = currentState
        isTransitioning = true
        _ = nextGeneration()
        setState(.transitioning(from: previousState.descriptor))
        return previousState
    }

    private func restoreState(_ previousState: AuthorizedFolderState) {
        switch previousState {
        case .active(let descriptor):
            restoreActive(descriptor, stale: false)
        case .stale(let descriptor):
            restoreActive(descriptor, stale: true)
        case .revoked(let revocation):
            active = nil
            isTransitioning = false
            setState(.revoked(revocation))
        case .notAuthorized:
            active = nil
            isTransitioning = false
            setState(.notAuthorized)
        case .notLoaded:
            active = nil
            isTransitioning = false
            setState(.notLoaded)
        case .transitioning(let descriptor):
            if let descriptor {
                restoreActive(descriptor, stale: false)
            } else {
                active = nil
                isTransitioning = false
                setState(.notAuthorized)
            }
        }
    }

    private func restoreActive(_ descriptor: AuthorizedFolderDescriptor, stale: Bool) {
        guard let active else {
            isTransitioning = false
            setState(.notAuthorized)
            return
        }
        let refreshedDescriptor = AuthorizedFolderDescriptor(
            generation: AuthorizedFolderGeneration(lastGeneration),
            displayName: descriptor.displayName,
            accessKind: descriptor.accessKind,
            authorizedAt: descriptor.authorizedAt,
            refreshedAt: descriptor.refreshedAt
        )
        self.active = ActiveAuthorization(
            url: active.url,
            canonicalRoot: active.canonicalRoot,
            descriptor: refreshedDescriptor,
            envelope: active.envelope
        )
        isTransitioning = false
        setState(stale ? .stale(refreshedDescriptor) : .active(refreshedDescriptor))
    }

    @discardableResult
    private func nextGeneration() -> AuthorizedFolderGeneration {
        lastGeneration &+= 1
        if lastGeneration == 0 {
            lastGeneration = 1
        }
        return AuthorizedFolderGeneration(lastGeneration)
    }

    private func drainOperations() async {
        let operations = Array(inFlight.values)
        inFlight.removeAll()
        for operation in operations {
            operation.cancel()
        }
        for operation in operations {
            await operation.wait()
        }
    }

    private func runOperation<T: Sendable>(
        generation: AuthorizedFolderGeneration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard !isTransitioning else {
            throw AuthorizedFolderError.transitionInProgress
        }
        guard let active, active.descriptor.generation == generation else {
            throw AuthorizedFolderError.superseded(generation: generation)
        }

        let operationID = UUID()
        let task = Task.detached(priority: .utility) {
            try AuthorizedFolderPath.checkCancellation(generation)
            return try await body()
        }
        inFlight[operationID] = InFlightOperation(
            cancel: { task.cancel() },
            wait: { _ = await task.result }
        )

        var produced: T?
        var failure: (any Error)?
        do {
            produced = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
        } catch {
            failure = error
        }
        inFlight[operationID] = nil

        if let failure {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let folderError = failure as? AuthorizedFolderError {
                throw folderError
            }
            if failure is CancellationError {
                throw AuthorizedFolderError.superseded(generation: generation)
            }
            throw failure
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        try validateGeneration(generation)
        guard let produced else {
            throw AuthorizedFolderError.coordinatedAccessFailed(code: -1)
        }
        return produced
    }

    private func validateGeneration(_ generation: AuthorizedFolderGeneration) throws {
        guard !isTransitioning else {
            throw AuthorizedFolderError.superseded(generation: generation)
        }
        guard let active, active.descriptor.generation == generation else {
            throw AuthorizedFolderError.superseded(generation: generation)
        }
    }

    private func setState(_ newState: AuthorizedFolderState) {
        currentState = newState
        for continuation in observers.values {
            continuation.yield(newState)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func publicError(for error: Error) -> AuthorizedFolderError {
        guard let storeError = error as? AuthorizedFolderBookmarkStoreError else {
            return .bookmarkWriteFailed(code: (error as NSError).code)
        }
        switch storeError {
        case .invalidDirectory:
            return .invalidBookmarkDirectory
        case .readFailed(let code):
            return .bookmarkReadFailed(code: code)
        case .writeFailed(let code):
            return .bookmarkWriteFailed(code: code)
        case .removeFailed(let code):
            return .bookmarkRemoveFailed(code: code)
        case .decodeFailed:
            return .bookmarkCorrupted
        case .unsupportedVersion(let version):
            return .unsupportedBookmarkVersion(version)
        }
    }
}

extension AuthorizedFolderError {
    var revocationReason: AuthorizedFolderRevocationReason {
        switch self {
        case .fileNotFound:
            return .targetMissing
        case .folderNotDirectory, .targetIsNotDirectory:
            return .targetNotDirectory
        case .invalidFolderURL:
            return .unsupportedLocation
        case .accessDenied:
            return .accessDenied
        case .scopeDenied:
            return .accessDenied
        case .unscopedAccessUnsupported:
            return .scopeRequired
        case .bookmarkCorrupted:
            return .bookmarkCorrupted
        case .unsupportedBookmarkVersion:
            return .unsupportedBookmarkVersion
        case .platformMismatch:
            return .platformMismatch
        case .bookmarkReadFailed,
             .bookmarkWriteFailed,
             .bookmarkRemoveFailed,
             .bookmarkCreationFailed,
             .invalidBookmarkDirectory:
            return .bookmarkStorageUnavailable
        default:
            return .bookmarkUnresolvable
        }
    }
}
