import Foundation
import Testing
@testable import DaybreakCore

@Suite("Authorized folder access")
struct AuthorizedFolderTests {
    // MARK: - Test doubles

    private final class TestBookmarkCoding: AuthorizedFolderBookmarkCoding, @unchecked Sendable {
        private let lock = NSLock()
        private var resolvedURL: URL
        private var isStale = false
        private var resolutionError: (any Error)?
        private var creationError: (any Error)?
        private var kinds: [AuthorizedFolderAccessKind] = []

        init(resolvedURL: URL) {
            self.resolvedURL = resolvedURL
        }

        func setResolvedURL(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            resolvedURL = url
        }

        func setStale(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            isStale = value
        }

        func setResolutionError(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            resolutionError = error
        }

        func setCreationError(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            creationError = error
        }

        var createdKinds: [AuthorizedFolderAccessKind] {
            lock.lock()
            defer { lock.unlock() }
            return kinds
        }

        func makeBookmark(for url: URL, accessKind: AuthorizedFolderAccessKind) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let creationError {
                throw creationError
            }
            kinds.append(accessKind)
            return Data("bookmark-\(accessKind.rawValue)-\(url.lastPathComponent)".utf8)
        }

        func resolveBookmark(
            _ data: Data,
            accessKind: AuthorizedFolderAccessKind
        ) throws -> AuthorizedFolderResolvedBookmark {
            lock.lock()
            defer { lock.unlock() }
            if let resolutionError {
                throw resolutionError
            }
            return AuthorizedFolderResolvedBookmark(url: resolvedURL, isStale: isStale)
        }
    }

    private final class TestBookmarkStore: AuthorizedFolderBookmarkStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var envelope: AuthorizedFolderBookmarkEnvelope?
        private var loadError: (any Error)?
        private var saveError: (any Error)?
        private var removeError: (any Error)?
        private var saves = 0
        private var removes = 0

        init(envelope: AuthorizedFolderBookmarkEnvelope? = nil) {
            self.envelope = envelope
        }

        func setLoadError(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            loadError = error
        }

        func setSaveError(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            saveError = error
        }

        func setRemoveError(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            removeError = error
        }

        var storedEnvelope: AuthorizedFolderBookmarkEnvelope? {
            lock.lock()
            defer { lock.unlock() }
            return envelope
        }

        var saveCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return saves
        }

        var removeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return removes
        }

        func load() throws -> AuthorizedFolderBookmarkEnvelope? {
            lock.lock()
            defer { lock.unlock() }
            if let loadError {
                throw loadError
            }
            return envelope
        }

        func save(_ envelope: AuthorizedFolderBookmarkEnvelope) throws {
            lock.lock()
            defer { lock.unlock() }
            if let saveError {
                throw saveError
            }
            self.envelope = envelope
            saves += 1
        }

        func remove() throws {
            lock.lock()
            defer { lock.unlock() }
            if let removeError {
                throw removeError
            }
            envelope = nil
            removes += 1
        }
    }

    private final class TestScoping: AuthorizedFolderSecurityScoping, @unchecked Sendable {
        private let lock = NSLock()
        private var nextStartResult = true
        private var startAttempts = 0
        private var successfulStarts = 0
        private var stops = 0
        private var active: [String: Int] = [:]
        private var startedURLs: [String] = []

        func setStartResult(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            nextStartResult = value
        }

        var counts: (attempts: Int, successful: Int, stops: Int, leaked: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (startAttempts, successfulStarts, stops, active.values.contains { $0 > 0 })
        }

        var startedURLStrings: [String] {
            lock.lock()
            defer { lock.unlock() }
            return startedURLs
        }

        func startAccessing(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            startAttempts += 1
            startedURLs.append(url.absoluteString)
            guard nextStartResult else {
                return false
            }
            successfulStarts += 1
            active[url.path, default: 0] += 1
            return true
        }

        func stopAccessing(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            stops += 1
            guard let count = active[url.path], count > 0 else {
                return
            }
            active[url.path] = count - 1
        }
    }

    /// Returns the symlink-resolved form of the URL, the way NSFileCoordinator
    /// does for an iCloud Drive path on iOS.
    private final class NormalizingCoordinating: AuthorizedFolderCoordinating, @unchecked Sendable {
        func coordinateReading<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            try body(url.resolvingSymlinksInPath().standardizedFileURL)
        }

        func coordinateWriting<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            try body(url.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

    /// Simulates another file presenter renaming the item while the coordinated
    /// operation waits for its lock. NSFileCoordinator then passes the URL of
    /// the renamed item, and the operation must use it instead of the stale
    /// requested path.
    private final class RenamingCoordinating: AuthorizedFolderCoordinating, @unchecked Sendable {
        private let lock = NSLock()
        private var renamed: [String] = []

        var renamedNames: [String] {
            lock.lock()
            defer { lock.unlock() }
            return renamed
        }

        func coordinateReading<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            try body(movingIfNeeded(url))
        }

        func coordinateWriting<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            try body(movingIfNeeded(url))
        }

        private func movingIfNeeded(_ url: URL) -> URL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return url
            }
            let moved = url.deletingLastPathComponent()
                .appendingPathComponent("renamed-" + url.lastPathComponent, isDirectory: false)
            guard (try? FileManager.default.moveItem(at: url, to: moved)) != nil else {
                return url
            }
            lock.lock()
            renamed.append(url.lastPathComponent)
            lock.unlock()
            return moved
        }
    }

    /// A misbehaving coordinator that always returns one fixed URL.
    private final class FixedURLCoordinating: AuthorizedFolderCoordinating, @unchecked Sendable {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func coordinateReading<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            try body(self.url)
        }

        func coordinateWriting<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            try body(self.url)
        }
    }

    private final class TestCoordinating: AuthorizedFolderCoordinating, @unchecked Sendable {
        enum Event: Sendable, Equatable {
            case readStarted
            case writeStarted
        }

        private let lock = NSLock()
        private var mainThreadObservations: [Bool] = []
        private let gateReads: Bool
        private let gateWrites: Bool
        private let gate = DispatchSemaphore(value: 0)
        let startedStream: AsyncStream<Event>
        private let startedContinuation: AsyncStream<Event>.Continuation

        init(gateReads: Bool = false, gateWrites: Bool = false) {
            self.gateReads = gateReads
            self.gateWrites = gateWrites
            let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
            self.startedStream = stream
            self.startedContinuation = continuation
        }

        func release() {
            gate.signal()
        }

        var observedMainThreadFlags: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return mainThreadObservations
        }

        func coordinateReading<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            recordThread()
            if gateReads {
                startedContinuation.yield(.readStarted)
                gate.wait()
            }
            return try body(url)
        }

        func coordinateWriting<T: Sendable>(
            at url: URL,
            _ body: @Sendable (URL) throws -> T
        ) throws -> T {
            recordThread()
            if gateWrites {
                startedContinuation.yield(.writeStarted)
                gate.wait()
            }
            return try body(url)
        }

        private func recordThread() {
            lock.lock()
            defer { lock.unlock() }
            mainThreadObservations.append(Thread.isMainThread)
        }
    }

    // MARK: - Fixtures

    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakAuthorizedFolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        bookmarkDirectory: URL,
        coding: TestBookmarkCoding,
        scoping: TestScoping,
        coordinating: any AuthorizedFolderCoordinating = AuthorizedFolderLiveCoordinating(),
        store: TestBookmarkStore? = nil,
        platform: AuthorizedFolderHostPlatform = .macOS,
        sandboxed: Bool = false,
        policy: AuthorizedFolderScopePolicy = .automatic,
        diagnosticsDirectory: URL? = nil
    ) -> AuthorizedFolderStore {
        AuthorizedFolderStore(
            bookmarkDirectory: bookmarkDirectory,
            scopePolicy: policy,
            platform: platform,
            hostIsSandboxed: sandboxed,
            bookmarkCoding: coding,
            scoping: scoping,
            coordinating: coordinating,
            bookmarkStore: store,
            diagnosticsDirectory: diagnosticsDirectory
        )
    }

    private func expectInvalidPath(
        _ store: AuthorizedFolderStore,
        _ path: String
    ) async {
        do {
            try await store.write(Data([0x01]), relativePath: path)
            Issue.record("Expected invalid relative path: \(path)")
        } catch let error as AuthorizedFolderError {
            #expect(error == .invalidRelativePath)
        } catch {
            Issue.record("Unexpected error for \(path): \(error)")
        }
    }

    // MARK: - Persistence

    @Test("A real local bookmark persists across store instances and writes nested files")
    func realBookmarkPersistenceAndNestedWrite() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = try makeDirectory(container.appendingPathComponent("Support", isDirectory: true))

        let store = AuthorizedFolderStore(
            bookmarkDirectory: support,
            scopePolicy: .automatic,
            platform: .macOS,
            hostIsSandboxed: false
        )
        let initialState = await store.open()
        #expect(initialState == .notAuthorized)

        let descriptor = try await store.authorize(folder)
        #expect(descriptor.displayName == "Shared")
        #expect(descriptor.accessKind == .unscopedLocal)
        #expect(AuthorizedFolderGeneration(0) < descriptor.generation)

        let payload = Data("hello".utf8)
        try await store.write(payload, relativePath: "devices/device-1/ops/0001.json")
        let readBack = try await store.read(
            relativePath: "devices/device-1/ops/0001.json",
            maxBytes: 1024
        )
        #expect(readBack == payload)

        let devices = try await store.listDirectory(relativePath: "devices")
        #expect(devices.map(\.relativePath) == ["devices/device-1"])
        #expect(devices.first?.kind == .directory)

        let ops = try await store.listDirectory(relativePath: "devices/device-1/ops")
        #expect(ops.map(\.relativePath) == ["devices/device-1/ops/0001.json"])
        #expect(ops.first?.kind == .file)
        #expect(ops.first?.isDownloaded == true)

        let bookmarkURL = support.appendingPathComponent(
            AuthorizedFolderBookmarkFileStore.fileName,
            isDirectory: false
        )
        #expect(FileManager.default.fileExists(atPath: bookmarkURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(AuthorizedFolderBookmarkFileStore.fileName).path
        ))

        let reopened = AuthorizedFolderStore(
            bookmarkDirectory: support,
            scopePolicy: .automatic,
            platform: .macOS,
            hostIsSandboxed: false
        )
        let reopenedState = await reopened.open()
        guard case .active(let reopenedDescriptor) = reopenedState else {
            Issue.record("Expected reopened active state, got \(reopenedState)")
            return
        }
        #expect(reopenedDescriptor.displayName == "Shared")
        #expect(reopenedDescriptor.accessKind == .unscopedLocal)
        let reread = try await reopened.read(
            relativePath: "devices/device-1/ops/0001.json",
            maxBytes: 1024
        )
        #expect(reread == payload)
    }

    // MARK: - Stale and revoked bookmarks

    @Test("A stale bookmark is reported stale, refreshed, and later active")
    func staleBookmarkIsRefreshed() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let bookmarkStore = TestBookmarkStore()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: bookmarkStore
        )

        let original = try await store.authorize(folder)
        coding.setStale(true)
        let staleState = await store.reopen()
        guard case .stale(let staleDescriptor) = staleState else {
            Issue.record("Expected stale state, got \(staleState)")
            return
        }
        #expect(staleDescriptor.generation > original.generation)
        #expect(staleDescriptor.refreshedAt >= original.refreshedAt)
        #expect(bookmarkStore.storedEnvelope?.accessKind == .unscopedLocal)

        coding.setStale(false)
        let activeState = await store.reopen()
        guard case .active(let activeDescriptor) = activeState else {
            Issue.record("Expected active state after refresh, got \(activeState)")
            return
        }
        #expect(activeDescriptor.generation > staleDescriptor.generation)
        #expect(scoping.counts.successful == scoping.counts.stops)
        #expect(!scoping.counts.leaked)
    }

    @Test("A revoked bookmark reports targetMissing and blocks access until reopened")
    func revokedBookmarkBlocksAccess() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        coding.setResolutionError(
            NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileReadNoSuchFile.rawValue
            )
        )
        let revokedState = await store.reopen()
        guard case .revoked(let revocation) = revokedState else {
            Issue.record("Expected revoked state, got \(revokedState)")
            return
        }
        #expect(revocation.reason == .targetMissing)
        #expect(revocation.displayName == "Shared")

        do {
            _ = try await store.read(relativePath: "missing.json", maxBytes: 64)
            Issue.record("Expected authorizationRevoked")
        } catch let error as AuthorizedFolderError {
            guard case .authorizationRevoked(let current) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(current.reason == .targetMissing)
        }

        coding.setResolutionError(nil)
        let recovered = await store.reopen()
        guard case .active = recovered else {
            Issue.record("Expected recovered active state, got \(recovered)")
            return
        }
    }

    @Test("A corrupted bookmark store reports a revoked state")
    func corruptedBookmarkIsRevoked() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let bookmarkStore = TestBookmarkStore()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: bookmarkStore
        )
        _ = try await store.authorize(folder)
        bookmarkStore.setLoadError(AuthorizedFolderBookmarkStoreError.decodeFailed)

        let state = await store.reopen()
        guard case .revoked(let revocation) = state else {
            Issue.record("Expected revoked state, got \(state)")
            return
        }
        #expect(revocation.reason == .bookmarkCorrupted)

        bookmarkStore.setLoadError(nil)
        let recovered = await store.reopen()
        guard case .active = recovered else {
            Issue.record("Expected recovered active state, got \(recovered)")
            return
        }
    }

    // MARK: - Platform scope behavior

    @Test("iOS requires a security scope and reports denial")
    func iOSScopeDenied() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: TestBookmarkStore(),
            platform: .iOS,
            sandboxed: true
        )

        scoping.setStartResult(false)
        do {
            _ = try await store.authorize(folder)
            Issue.record("Expected scopeDenied")
        } catch let error as AuthorizedFolderError {
            #expect(error == .scopeDenied)
        }
        #expect(scoping.counts.attempts == 1)
        #expect(scoping.counts.successful == 0)
        #expect(scoping.counts.stops == 0)

        scoping.setStartResult(true)
        let descriptor = try await store.authorize(folder)
        #expect(descriptor.accessKind == .securityScoped)
        #expect(scoping.counts.successful == scoping.counts.stops)

        scoping.setStartResult(false)
        let state = await store.reopen()
        guard case .revoked(let revocation) = state else {
            Issue.record("Expected revoked state, got \(state)")
            return
        }
        #expect(revocation.reason == .accessDenied)
    }

    @Test("Authorization starts the scope on the exact picker URL")
    func authorizationUsesTheOriginalURLForScope() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: TestBookmarkStore(),
            platform: .iOS,
            sandboxed: true
        )

        // A derived URL (`standardizedFileURL`) drops the document picker's
        // security scope, so the store must start the scope on the URL it was
        // given even when that URL is not normalized.
        let given = URL(fileURLWithPath: folder.path + "/.")
        _ = try await store.authorize(given)

        #expect(scoping.startedURLStrings.first == given.absoluteString)
        #expect(scoping.startedURLStrings.first != given.standardizedFileURL.absoluteString)
    }

    @Test("A new file under a symlinked root passes path validation")
    func newFileUnderSymlinkedRoot() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let realParent = try makeDirectory(container.appendingPathComponent("RealParent", isDirectory: true))
        let real = try makeDirectory(realParent.appendingPathComponent("Shared", isDirectory: true))
        let linkParent = container.appendingPathComponent("LinkParent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: realParent)
        let link = linkParent.appendingPathComponent("Shared", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: link)
        let scoping = TestScoping()
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: coding,
            scoping: scoping,
            store: TestBookmarkStore(),
            platform: .macOS,
            sandboxed: false
        )

        let descriptor = try await store.authorize(link)
        #expect(descriptor.accessKind == .unscopedLocal)

        // The marker does not exist yet. Foundation leaves a missing leaf's
        // path unresolved, so validating it against the resolved root used to
        // reject the very first write with `invalidPath`.
        try await store.write(Data("marker".utf8), relativePath: "marker.json")

        #expect(FileManager.default.fileExists(
            atPath: real.appendingPathComponent("marker.json").path
        ))
    }

    @Test("A missing leaf keeps the root components for trailing-slash and aliased roots")
    func missingLeafKeepsRootComponentsForRootVariants() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let realParent = try makeDirectory(
            container.appendingPathComponent("RealParent", isDirectory: true)
        )
        let real = try makeDirectory(
            realParent.appendingPathComponent("Shared", isDirectory: true)
        )
        let linkParent = container.appendingPathComponent("LinkParent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkParent,
            withDestinationURL: realParent
        )
        let link = linkParent.appendingPathComponent("Shared", isDirectory: true)

        let roots = [
            real,
            URL(fileURLWithPath: real.path + "/", isDirectory: true),
            URL(fileURLWithPath: real.path + "/.", isDirectory: true),
            link,
            URL(fileURLWithPath: link.path + "/", isDirectory: true),
            URL(fileURLWithPath: link.path + "/.", isDirectory: true),
        ]
        for root in roots {
            let target = AuthorizedFolderPath.target(
                root: root,
                components: ["daybreak-sync.json"]
            )
            #expect(
                target.pathComponents
                    == root.standardized.pathComponents + ["daybreak-sync.json"]
            )
            try AuthorizedFolderPath.validateTarget(
                root: root,
                canonicalRoot: root,
                target: target,
                allowRoot: false,
                relativePath: "daybreak-sync.json"
            )
        }
    }

    @Test("Root spelling does not change when the root becomes visible between build and validation")
    func targetSurvivesRootVisibilityChange() throws {
        // iOS iCloud Drive roots live under `/private/var/mobile/...`; whether
        // the `/var/...` alias resolves depends on the active security scope.
        // Targets are built before the scope lease and validated inside it.
        // `/private/tmp` reproduces the same alias on macOS: build the target
        // while the root is missing, then validate after it exists.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("DaybreakScopeAlias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileTarget = AuthorizedFolderPath.target(root: root, components: ["daybreak-sync.json"])
        let rootTarget = AuthorizedFolderPath.target(root: root, components: [])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        try AuthorizedFolderPath.validateTarget(
            root: root,
            canonicalRoot: root,
            target: fileTarget,
            allowRoot: false,
            relativePath: "daybreak-sync.json"
        )
        try AuthorizedFolderPath.validateTarget(
            root: root,
            canonicalRoot: root,
            target: rootTarget,
            allowRoot: true,
            relativePath: ""
        )
        #expect(AuthorizedFolderPath.relativeComponents(of: rootTarget, under: root) == [])
    }

    @Test("A coordinator-normalized URL is still the authorized target")
    func coordinatorNormalizedURLIsAccepted() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let realParent = try makeDirectory(container.appendingPathComponent("RealParent", isDirectory: true))
        let real = try makeDirectory(realParent.appendingPathComponent("Shared", isDirectory: true))
        let linkParent = container.appendingPathComponent("LinkParent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: realParent)
        let link = linkParent.appendingPathComponent("Shared", isDirectory: true)
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: link),
            scoping: TestScoping(),
            coordinating: NormalizingCoordinating(),
            store: TestBookmarkStore(),
            platform: .macOS,
            sandboxed: false
        )

        _ = try await store.authorize(link)
        try await store.write(Data("marker".utf8), relativePath: "marker.json")
        // The second write targets an existing file, so the coordinator can
        // return its fully resolved URL.
        try await store.write(Data("marker2".utf8), relativePath: "marker.json")

        let written = try Data(contentsOf: real.appendingPathComponent("marker.json"))
        #expect(written == Data("marker2".utf8))
    }

    @Test("A coordinated write follows the coordinator URL after an external rename")
    func coordinatedWriteUsesReturnedURL() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let coordinating = RenamingCoordinating()
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            coordinating: coordinating,
            store: TestBookmarkStore()
        )

        _ = try await store.authorize(folder)
        try await store.write(Data("first".utf8), relativePath: "marker.json")

        // The coordinator renames the existing file before running the write
        // accessor. Ignoring its URL would resurrect the old name and leave the
        // renamed item stale.
        try await store.write(Data("second".utf8), relativePath: "marker.json")

        let moved = folder.appendingPathComponent("renamed-marker.json")
        let movedData = try Data(contentsOf: moved)
        #expect(movedData == Data("second".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("marker.json").path
        ))
        #expect(coordinating.renamedNames == ["marker.json"])
    }

    @Test("A coordinated read follows the coordinator URL after an external rename")
    func coordinatedReadUsesReturnedURL() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let coordinating = RenamingCoordinating()
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            coordinating: coordinating,
            store: TestBookmarkStore()
        )

        _ = try await store.authorize(folder)
        try await store.write(Data("payload".utf8), relativePath: "data.json")

        // Rename between the preflight and the coordinated read, exactly like
        // another file presenter moving the item while we wait for the lock.
        let read = try await store.read(relativePath: "data.json", maxBytes: 64)

        #expect(read == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("data.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("renamed-data.json").path
        ))
    }

    @Test("A coordinator URL outside the authorized folder is rejected")
    func coordinatedURLOutsideFolderIsRejected() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let inside = folder.appendingPathComponent("safe.json")
        try Data("inside".utf8).write(to: inside)
        let outsideDirectory = try makeDirectory(
            container.appendingPathComponent("Outside", isDirectory: true)
        )
        let outside = outsideDirectory.appendingPathComponent("evil.json")
        try Data("outside".utf8).write(to: outside)

        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            coordinating: FixedURLCoordinating(url: outside),
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        do {
            _ = try await store.read(relativePath: "safe.json", maxBytes: 64)
            Issue.record("Expected a coordinated URL outside the folder to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .pathEscapesAuthorizedFolder(relativePath: "safe.json"))
        }

        do {
            try await store.write(Data("written".utf8), relativePath: "created.json")
            Issue.record("Expected a coordinated write outside the folder to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .pathEscapesAuthorizedFolder(relativePath: "created.json"))
        }

        let outsideData = try Data(contentsOf: outside)
        #expect(outsideData == Data("outside".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("created.json").path
        ))
    }

    @Test("A coordinator URL cannot hide an intermediate symlink behind ..")
    func coordinatedURLWithDotDotAfterSymlinkIsRejected() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let outsideDirectory = try makeDirectory(
            container.appendingPathComponent("Outside", isDirectory: true)
        )
        let link = folder.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        // `link/..` resolves to the container after following the link, so this
        // URL standardizes to `Shared/created.json` while the write would land
        // in `container/created.json`, outside the authorized folder.
        let hiddenEscape = link
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("created.json", isDirectory: false)

        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            coordinating: FixedURLCoordinating(url: hiddenEscape),
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        do {
            try await store.write(Data("escape".utf8), relativePath: "created.json")
            Issue.record("Expected a coordinator URL with .. to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .pathEscapesAuthorizedFolder(relativePath: "created.json"))
        } catch {
            Issue.record("Unexpected error for a coordinator URL with ..: \(error)")
        }

        #expect(!FileManager.default.fileExists(
            atPath: container.appendingPathComponent("created.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: outsideDirectory.appendingPathComponent("created.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("created.json").path
        ))
    }

    @Test("A coordinated URL is rechecked for a symlink swapped in after validation")
    func coordinatedURLRechecksSymlinkedParents() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let outsideDirectory = try makeDirectory(
            container.appendingPathComponent("Outside", isDirectory: true)
        )
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)
        let target = link.appendingPathComponent("file.json", isDirectory: false)

        do {
            _ = try AuthorizedFolderPath.coordinatedURL(
                target,
                for: target,
                root: root,
                allowRoot: false,
                relativePath: "link/file.json"
            )
            Issue.record("Expected the symlinked parent to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .unsafeSymbolicLink(relativePath: "link/file.json"))
        } catch {
            Issue.record("Unexpected coordinated URL error: \(error)")
        }
    }

    @Test("Coordinated-access diagnostics are path-free")
    func coordinatedAccessDiagnosticsArePathFree() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let real = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let outside = try makeDirectory(container.appendingPathComponent("Outside", isDirectory: true))
        let outsideFile = outside.appendingPathComponent("daybreak-sync.json")
        let diagnostics = try makeDirectory(
            container.appendingPathComponent("Diagnostics", isDirectory: true)
        )
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: real),
            scoping: TestScoping(),
            coordinating: FixedURLCoordinating(url: outsideFile),
            store: TestBookmarkStore(),
            diagnosticsDirectory: diagnostics
        )
        _ = try await store.authorize(real)

        do {
            try await store.write(Data("marker".utf8), relativePath: "daybreak-sync.json")
            Issue.record("Expected the outside coordinator URL to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .pathEscapesAuthorizedFolder(relativePath: "daybreak-sync.json"))
        }

        let logURL = diagnostics.appendingPathComponent(SyncDiagnostics.fileName)
        let log = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        #expect(log.contains("coordinate-start:stage=write target=missing"))
        #expect(log.contains(
            "coordinate-accessor:stage=write item=rejected relation=outsideRoot"
                + " target=missing"
        ))
        #expect(log.contains("parent=different"))
        #expect(!log.contains(container.path))
        #expect(!log.contains(outside.path))
        #expect(!log.contains("daybreak-sync.json"))
    }

    @Test("Diagnostics report the gate result for an insideRoot URL that is rejected")
    func diagnosticsReflectGateRejection() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let outside = try makeDirectory(container.appendingPathComponent("Outside", isDirectory: true))
        try Data("inside".utf8).write(to: root.appendingPathComponent("data.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        let coordinatedURL = root.appendingPathComponent("link/data.json")
        let diagnostics = try makeDirectory(
            container.appendingPathComponent("Diagnostics", isDirectory: true)
        )
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: root),
            scoping: TestScoping(),
            coordinating: FixedURLCoordinating(url: coordinatedURL),
            store: TestBookmarkStore(),
            diagnosticsDirectory: diagnostics
        )
        _ = try await store.authorize(root)

        do {
            _ = try await store.read(relativePath: "data.json", maxBytes: 64)
            Issue.record("Expected the insideRoot coordinator URL to be rejected")
        } catch let error as AuthorizedFolderError {
            // An existing target that is neither the same item nor the same
            // resolved path is rejected as containment before any symbolic-
            // link walk. The important diagnostic property is that the
            // accessor event does not call this insideRoot URL accepted.
            #expect(error == .pathEscapesAuthorizedFolder(relativePath: "data.json"))
        }

        let logURL = diagnostics.appendingPathComponent(SyncDiagnostics.fileName)
        let log = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        #expect(log.contains(
            "coordinate-accessor:stage=read item=rejected relation=insideRoot"
        ))
        #expect(!log.contains("item=accepted relation=insideRoot"))
        #expect(!log.contains(container.path))
    }

    @Test("Bookmark save diagnostics use a fixed category and no raw error")
    func bookmarkSaveDiagnosticsArePathFree() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let diagnostics = try makeDirectory(
            container.appendingPathComponent("Diagnostics", isDirectory: true)
        )
        let bookmarkStore = TestBookmarkStore()
        bookmarkStore.setSaveError(
            NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileWriteNoPermission.rawValue,
                userInfo: [NSFilePathErrorKey: "/Users/alice/Private"]
            )
        )
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            store: bookmarkStore,
            diagnosticsDirectory: diagnostics
        )

        do {
            _ = try await store.authorize(folder)
            Issue.record("Expected the bookmark save to fail")
        } catch let error as AuthorizedFolderError {
            #expect(error == .bookmarkWriteFailed(
                code: CocoaError.Code.fileWriteNoPermission.rawValue
            ))
        }

        let logURL = diagnostics.appendingPathComponent(SyncDiagnostics.fileName)
        let log = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        #expect(log.contains("bookmark-save-error:bookmarkWriteFailed"))
        #expect(!log.contains("/Users"))
        #expect(!log.contains("alice"))
    }

    @Test("Bookmark creation diagnostics use a fixed category and no raw error")
    func bookmarkCreationDiagnosticsArePathFree() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let diagnostics = try makeDirectory(
            container.appendingPathComponent("Diagnostics", isDirectory: true)
        )
        let coding = TestBookmarkCoding(resolvedURL: folder)
        coding.setCreationError(
            NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileWriteNoPermission.rawValue,
                userInfo: [NSFilePathErrorKey: "/Users/alice/Private"]
            )
        )
        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: coding,
            scoping: TestScoping(),
            store: TestBookmarkStore(),
            diagnosticsDirectory: diagnostics
        )

        do {
            _ = try await store.authorize(folder)
            Issue.record("Expected the bookmark creation to fail")
        } catch let error as AuthorizedFolderError {
            #expect(error == .bookmarkCreationFailed(
                code: CocoaError.Code.fileWriteNoPermission.rawValue
            ))
        }

        let logURL = diagnostics.appendingPathComponent(SyncDiagnostics.fileName)
        let log = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        #expect(log.contains("bookmark-create-error:bookmarkCreationFailed"))
        #expect(!log.contains("/Users"))
        #expect(!log.contains("alice"))
    }

    @Test("A coordinated URL that is a dangling symlink cannot create a file outside the folder")
    func coordinatedWriteToDanglingSymlinkIsRejected() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let outsideDirectory = try makeDirectory(
            container.appendingPathComponent("Outside", isDirectory: true)
        )
        let outside = outsideDirectory.appendingPathComponent("escape.json")

        // A dangling link is invisible to `fileExists`, which follows it and
        // reports the leaf as missing. The coordinator redirects the write to
        // a different leaf inside the authorized folder, so only the check
        // immediately before the write can see the link.
        let redirect = folder.appendingPathComponent("redirect.json")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: outside)

        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            coordinating: FixedURLCoordinating(url: redirect),
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        do {
            try await store.write(Data("escape".utf8), relativePath: "created.json")
            Issue.record("Expected a coordinated write through a dangling symlink to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .unsafeSymbolicLink(relativePath: "created.json"))
        } catch {
            Issue.record("Unexpected error for a dangling symlink: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("created.json").path
        ))
    }

    @Test("A coordinated URL that is an existing symlink cannot overwrite its destination")
    func coordinatedWriteToExistingSymlinkIsRejected() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let outsideDirectory = try makeDirectory(
            container.appendingPathComponent("Outside", isDirectory: true)
        )
        let outside = outsideDirectory.appendingPathComponent("kept.json")
        try Data("outside".utf8).write(to: outside)
        let redirect = folder.appendingPathComponent("redirect.json")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: outside)

        let store = makeStore(
            bookmarkDirectory: container.appendingPathComponent("Support", isDirectory: true),
            coding: TestBookmarkCoding(resolvedURL: folder),
            scoping: TestScoping(),
            coordinating: FixedURLCoordinating(url: redirect),
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        do {
            try await store.write(Data("overwritten".utf8), relativePath: "created.json")
            Issue.record("Expected a coordinated write through a symlink to be rejected")
        } catch let error as AuthorizedFolderError {
            #expect(error == .unsafeSymbolicLink(relativePath: "created.json"))
        } catch {
            Issue.record("Unexpected error for an existing symlink: \(error)")
        }

        let kept = try Data(contentsOf: outside)
        #expect(kept == Data("outside".utf8))
        // The link itself is untouched; only the write is refused.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: redirect.path)) != nil)
    }

    @Test("An unscoped bookmark is rejected on iOS")
    func iOSRejectsUnscopedBookmark() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let now = Date()
        let envelope = AuthorizedFolderBookmarkEnvelope(
            schemaVersion: AuthorizedFolderBookmarkEnvelope.currentSchemaVersion,
            platform: .iOS,
            accessKind: .unscopedLocal,
            generation: AuthorizedFolderGeneration(3),
            authorizedAt: now,
            refreshedAt: now,
            displayName: "Shared",
            bookmarkData: Data([0x01])
        )
        let bookmarkStore = TestBookmarkStore(envelope: envelope)
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: bookmarkStore,
            platform: .iOS,
            sandboxed: true,
            policy: .unscopedLocal
        )

        let state = await store.open()
        guard case .revoked(let revocation) = state else {
            Issue.record("Expected revoked state, got \(state)")
            return
        }
        #expect(revocation.reason == .scopeRequired)
        #expect(scoping.counts.attempts == 0)

        do {
            _ = try await store.authorize(folder)
            Issue.record("Expected unscopedAccessUnsupported")
        } catch let error as AuthorizedFolderError {
            #expect(error == .unscopedAccessUnsupported)
        }
    }

    @Test("MacOS sandboxed builds report a denied security scope")
    func macOSSandboxScopeDenied() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: TestBookmarkStore(),
            platform: .macOS,
            sandboxed: true,
            policy: .automatic
        )
        let descriptor = try await store.authorize(folder)
        #expect(descriptor.accessKind == .securityScoped)

        scoping.setStartResult(false)
        let state = await store.reopen()
        guard case .revoked(let revocation) = state else {
            Issue.record("Expected revoked state, got \(state)")
            return
        }
        #expect(revocation.reason == .accessDenied)
    }

    @Test("A non-sandboxed macOS build degrades a scoped bookmark to local access")
    func macOSAdHocDowngradesScope() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let bookmarkStore = TestBookmarkStore()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: bookmarkStore,
            platform: .macOS,
            sandboxed: false,
            policy: .securityScoped
        )

        let descriptor = try await store.authorize(folder)
        #expect(descriptor.accessKind == .securityScoped)
        #expect(scoping.counts.successful == scoping.counts.stops)
        #expect(!scoping.counts.leaked)

        scoping.setStartResult(false)
        let state = await store.reopen()
        guard case .active(let downgraded) = state else {
            Issue.record("Expected active downgraded state, got \(state)")
            return
        }
        #expect(downgraded.accessKind == .unscopedLocal)
        #expect(bookmarkStore.storedEnvelope?.accessKind == .unscopedLocal)
    }

    // MARK: - Path safety

    @Test("Traversal, absolute paths, and symlinks are rejected")
    func pathSafetyAndSymlinks() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        for path in [
            "../escape.txt",
            "/absolute.txt",
            "a//b.txt",
            "a/./b.txt",
            "a/../b.txt",
            "a\\b.txt",
            "~note.txt",
            ""
        ] {
            await expectInvalidPath(store, path)
        }

        try await store.write(Data("safe".utf8), relativePath: "safe/file.txt")
        let safe = try await store.read(relativePath: "safe/file.txt", maxBytes: 64)
        #expect(safe == Data("safe".utf8))

        let outsideFile = container.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outsideFile)
        let fileLink = folder.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outsideFile)

        do {
            _ = try await store.read(relativePath: "link.txt", maxBytes: 64)
            Issue.record("Expected symlink read rejection")
        } catch let error as AuthorizedFolderError {
            guard case .unsafeSymbolicLink(let path) = error else {
                Issue.record("Unexpected symlink read error \(error)")
                return
            }
            #expect(path == "link.txt")
        }

        do {
            try await store.write(Data("bad".utf8), relativePath: "link.txt")
            Issue.record("Expected symlink write rejection")
        } catch let error as AuthorizedFolderError {
            guard case .unsafeSymbolicLink = error else {
                Issue.record("Unexpected symlink write error \(error)")
                return
            }
        }

        let outsideDirectory = try makeDirectory(container.appendingPathComponent("Outside", isDirectory: true))
        let directoryLink = folder.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(
            at: directoryLink,
            withDestinationURL: outsideDirectory
        )
        do {
            try await store.write(Data("bad".utf8), relativePath: "linkdir/escape.txt")
            Issue.record("Expected directory symlink rejection")
        } catch let error as AuthorizedFolderError {
            guard case .unsafeSymbolicLink = error else {
                Issue.record("Unexpected directory symlink error \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(
            atPath: outsideDirectory.appendingPathComponent("escape.txt").path
        ))
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))

        let entries = try await store.listDirectory()
        #expect(!entries.contains { $0.relativePath == "link.txt" })
        #expect(!entries.contains { $0.relativePath == "linkdir" })
        #expect(entries.contains { $0.relativePath == "safe" && $0.kind == .directory })
    }

    @Test("Reads are bounded by an explicit maximum and reject oversized files")
    func boundedReads() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: TestScoping(),
            store: TestBookmarkStore()
        )
        _ = try await store.authorize(folder)

        let payload = Data(repeating: 0x41, count: 1024)
        try await store.write(payload, relativePath: "big.bin")

        do {
            _ = try await store.read(relativePath: "big.bin", maxBytes: 16)
            Issue.record("Expected fileTooLarge")
        } catch let error as AuthorizedFolderError {
            guard case .fileTooLarge(let path, let byteCount, let maxBytes) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(path == "big.bin")
            #expect(byteCount == 1024)
            #expect(maxBytes == 16)
        }

        let exact = try await store.read(relativePath: "big.bin", maxBytes: 1024)
        #expect(exact.count == 1024)

        do {
            _ = try await store.read(relativePath: "big.bin", maxBytes: 0)
            Issue.record("Expected invalidReadLimit")
        } catch let error as AuthorizedFolderError {
            #expect(error == .invalidReadLimit)
        }

        do {
            _ = try await store.read(relativePath: "missing.bin", maxBytes: 16)
            Issue.record("Expected fileNotFound")
        } catch let error as AuthorizedFolderError {
            guard case .fileNotFound(let path) = error else {
                Issue.record("Unexpected missing-file error \(error)")
                return
            }
            #expect(path == "missing.bin")
        }

        try await store.requestDownload(relativePath: "big.bin")

        let state = await store.state()
        guard case .active = state else {
            Issue.record("Expected active state, got \(state)")
            return
        }
    }

    // MARK: - Generation cancellation

    @Test("Replacing the folder cancels an in-flight write and never writes the old folder")
    func replaceCancelsInFlightWrite() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folderA = try makeDirectory(container.appendingPathComponent("A", isDirectory: true))
        let folderB = try makeDirectory(container.appendingPathComponent("B", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folderA)
        let scoping = TestScoping()
        let bookmarkStore = TestBookmarkStore()
        let coordinating = TestCoordinating(gateWrites: true)
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            coordinating: coordinating,
            store: bookmarkStore
        )

        let original = try await store.authorize(folderA)
        let stream = await store.stateUpdates()
        var updates = stream.makeAsyncIterator()
        _ = await updates.next()

        let writeTask = Task {
            try await store.write(Data("old".utf8), relativePath: "ops/old.json")
        }
        var started = coordinating.startedStream.makeAsyncIterator()
        let firstEvent = await started.next()
        #expect(firstEvent == .writeStarted)

        let replaceTask = Task {
            try await store.replaceAuthorization(with: folderB)
        }
        var sawTransition = false
        while let next = await updates.next() {
            if case .transitioning = next {
                sawTransition = true
                break
            }
        }
        #expect(sawTransition)

        coordinating.release()

        do {
            try await writeTask.value
            Issue.record("Expected superseded write")
        } catch let error as AuthorizedFolderError {
            guard case .superseded(let generation) = error else {
                Issue.record("Unexpected write error \(error)")
                return
            }
            #expect(generation == original.generation)
        }

        let replacement = try await replaceTask.value
        #expect(replacement.displayName == "B")
        #expect(replacement.generation > original.generation)
        #expect(!FileManager.default.fileExists(
            atPath: folderA.appendingPathComponent("ops/old.json").path
        ))

        let current = await store.state()
        guard case .active(let descriptor) = current else {
            Issue.record("Expected active replacement, got \(current)")
            return
        }
        #expect(descriptor.generation == replacement.generation)
        #expect(bookmarkStore.saveCount == 2)
    }

    @Test("Disabling cancels an in-flight read but leaves folder contents untouched")
    func disableCancelsInFlightReadAndKeepsFiles() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let bookmarkStore = TestBookmarkStore()
        let coordinating = TestCoordinating(gateReads: true)
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            coordinating: coordinating,
            store: bookmarkStore
        )
        _ = try await store.authorize(folder)
        try await store.write(Data("keep".utf8), relativePath: "keep.txt")

        let stream = await store.stateUpdates()
        var updates = stream.makeAsyncIterator()
        _ = await updates.next()

        let readTask = Task {
            try await store.read(relativePath: "keep.txt", maxBytes: 64)
        }
        var started = coordinating.startedStream.makeAsyncIterator()
        let firstEvent = await started.next()
        #expect(firstEvent == .readStarted)

        let disableTask = Task {
            try await store.disable()
        }
        var sawTransition = false
        while let next = await updates.next() {
            if case .transitioning = next {
                sawTransition = true
                break
            }
        }
        #expect(sawTransition)

        coordinating.release()

        do {
            _ = try await readTask.value
            Issue.record("Expected superseded read")
        } catch let error as AuthorizedFolderError {
            guard case .superseded = error else {
                Issue.record("Unexpected read error \(error)")
                return
            }
        }

        try await disableTask.value
        let disabledState = await store.state()
        #expect(disabledState == .notAuthorized)
        #expect(bookmarkStore.storedEnvelope == nil)
        #expect(bookmarkStore.removeCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("keep.txt").path
        ))
    }

    @Test("A failed replacement keeps the previous authorization")
    func failedReplacementRestoresPreviousAuthorization() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folderA = try makeDirectory(container.appendingPathComponent("A", isDirectory: true))
        let folderB = try makeDirectory(container.appendingPathComponent("B", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folderA)
        let bookmarkStore = TestBookmarkStore()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: TestScoping(),
            store: bookmarkStore
        )
        let original = try await store.authorize(folderA)
        try await store.write(Data("a".utf8), relativePath: "a.txt")

        bookmarkStore.setSaveError(AuthorizedFolderBookmarkStoreError.writeFailed(code: 13))
        do {
            _ = try await store.replaceAuthorization(with: folderB)
            Issue.record("Expected bookmarkWriteFailed")
        } catch let error as AuthorizedFolderError {
            #expect(error == .bookmarkWriteFailed(code: 13))
        }

        let current = await store.state()
        guard case .active(let descriptor) = current else {
            Issue.record("Expected previous active state, got \(current)")
            return
        }
        #expect(descriptor.displayName == "A")
        #expect(descriptor.generation > original.generation)
        let a = try await store.read(relativePath: "a.txt", maxBytes: 16)
        #expect(a == Data("a".utf8))
    }

    // MARK: - Scope pairing and background execution

    @Test("Each operation runs off-main and pairs successful scope start/stop")
    func scopePairingAndBackgroundExecution() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = container.appendingPathComponent("Support", isDirectory: true)
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let scoping = TestScoping()
        let coordinating = TestCoordinating()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: scoping,
            coordinating: coordinating,
            store: TestBookmarkStore(),
            platform: .iOS,
            sandboxed: true
        )

        _ = try await store.authorize(folder)
        try await store.write(Data("scope".utf8), relativePath: "devices/d1/ops/1.json")
        let readBack = try await store.read(relativePath: "devices/d1/ops/1.json", maxBytes: 64)
        #expect(readBack == Data("scope".utf8))
        let entries = try await store.listDirectory()
        #expect(entries.contains { $0.relativePath == "devices" && $0.kind == .directory })
        try await store.requestDownload(relativePath: "devices/d1/ops/1.json")
        _ = await store.reopen()

        let counts = scoping.counts
        #expect(counts.successful == counts.stops)
        #expect(!counts.leaked)
        #expect(!coordinating.observedMainThreadFlags.isEmpty)
        #expect(coordinating.observedMainThreadFlags.allSatisfy { !$0 })
    }

    @Test("Bookmark storage inside the authorized folder is rejected")
    func bookmarkStorageOverlapIsRejected() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = try makeDirectory(container.appendingPathComponent("Shared", isDirectory: true))
        let support = try makeDirectory(folder.appendingPathComponent("Support", isDirectory: true))
        let coding = TestBookmarkCoding(resolvedURL: folder)
        let bookmarkStore = TestBookmarkStore()
        let store = makeStore(
            bookmarkDirectory: support,
            coding: coding,
            scoping: TestScoping(),
            store: bookmarkStore
        )

        do {
            _ = try await store.authorize(folder)
            Issue.record("Expected bookmarkLocationOverlapsFolder")
        } catch let error as AuthorizedFolderError {
            #expect(error == .bookmarkLocationOverlapsFolder)
        }
        #expect(bookmarkStore.saveCount == 0)
        let state = await store.state()
        #expect(state == .notLoaded)
    }
}

/// The sync layer only sees `CloudSyncFolderAccessError`; these mappings are
/// what a device status reports. Keeping them asserted here means a future
/// device screenshot can be interpreted without guessing which store check
/// rejected the path.
@Suite("Cloud sync folder error classification")
struct CloudSyncFolderErrorClassificationTests {
    @Test("Invalid path errors keep their rejection site")
    func invalidPathSites() {
        #expect(
            AuthorizedFolderStore.syncError(AuthorizedFolderError.invalidRelativePath)
                == .invalidPath(nil, site: .relativePath)
        )
        #expect(
            AuthorizedFolderStore.syncError(
                AuthorizedFolderError.pathEscapesAuthorizedFolder(relativePath: "escape.json")
            ) == .invalidPath("escape.json", site: .containment)
        )
        #expect(
            AuthorizedFolderStore.syncError(
                AuthorizedFolderError.unsafeSymbolicLink(relativePath: "link.json")
            ) == .invalidPath("link.json", site: .symbolicLink)
        )
    }

    @Test("A target outside the root is containment, not a symbolic link")
    func targetOutsideRootIsContainment() {
        let root = URL(fileURLWithPath: "/tmp/daybreak-root", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside.json", isDirectory: false)
        do {
            try AuthorizedFolderPath.validateTarget(
                root: root,
                canonicalRoot: root,
                target: outside,
                allowRoot: false,
                relativePath: "outside.json"
            )
            Issue.record("Expected a containment failure")
        } catch let error as AuthorizedFolderError {
            #expect(error == .pathEscapesAuthorizedFolder(relativePath: "outside.json"))
        } catch {
            Issue.record("Unexpected containment error: \(error)")
        }

        #expect(
            AuthorizedFolderStore.syncError(
                AuthorizedFolderError.pathEscapesAuthorizedFolder(relativePath: "outside.json")
            ) == .invalidPath("outside.json", site: .containment)
        )
    }

    @Test("Diagnostics distinguish the rejection site")
    func diagnosticNames() {
        #expect(
            CloudSyncFolderAccessError.invalidPath(nil, site: .relativePath).diagnosticName
                == "invalidPath(relativePath)"
        )
        #expect(
            CloudSyncFolderAccessError.invalidPath("escape.json", site: .containment)
                .diagnosticName == "invalidPath(containment:escape.json)"
        )
        #expect(
            CloudSyncFolderAccessError.invalidPath("link.json", site: .symbolicLink)
                .diagnosticName == "invalidPath(symbolicLink:link.json)"
        )
    }
}
