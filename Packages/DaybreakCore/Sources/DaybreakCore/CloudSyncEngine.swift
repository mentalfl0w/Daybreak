import Foundation

// MARK: - Engine

/// Serial, single-flight shared-folder synchronizer.
///
/// One pass:
/// 1. Opens the user-authorized folder and verifies the versioned folder marker.
/// 2. Publishes every immutable local journal operation missing from the folder.
/// 3. Scans and validates `operations/<device>/<device>.<operation>.json`.
/// 4. Reconciles the remote archive with the local repository snapshot.
/// 5. Journals genuinely local content changes and remote-import results.
/// 6. Publishes content-addressed blobs and verifies/materializes remote blobs.
/// 7. Persists a device-local checkpoint and reports a local-only status.
///
/// Nothing here logs, returns or stores an absolute folder path. The folder is
/// never deleted, moved or repaired destructively.
public actor CloudSyncEngine {
    private let repository: WallpaperRepository
    private let folder: any CloudSyncFolderAccessing
    private let stateStore: CloudSyncStateStore
    private let stateDirectory: URL
    private let now: @Sendable () -> Date
    private var persisted: CloudSyncPersistedState
    private var didLoadPersisted = false
    private var isRunning = false
    /// Short technical cause of the last failed pass. Relative file names and
    /// error cases only; never an absolute path or content.
    public private(set) var lastFailureDetail: String?
    private var passStage = "idle"

    public init(
        repository: WallpaperRepository,
        folder: any CloudSyncFolderAccessing,
        stateDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.folder = folder
        self.stateStore = CloudSyncStateStore(directory: stateDirectory)
        self.stateDirectory = stateDirectory
        self.now = now
        self.persisted = CloudSyncPersistedState()
    }

    /// Checkpoint IO stays off the main actor: every public entry point runs on
    /// the engine actor and loads the state on first use.
    private func loadPersistedIfNeeded() {
        guard !didLoadPersisted else { return }
        didLoadPersisted = true
        persisted = stateStore.load().state
    }

    // MARK: Local options

    public func localState() -> CloudSyncLocalState {
        loadPersistedIfNeeded()
        return persisted.localState
    }

    public func folderAvailability() async -> CloudSyncFolderState {
        var state = await folder.currentState()
        if case .notLoaded = state {
            state = await folder.openIfNeeded()
        }
        return state
    }

    public func setEnabled(_ enabled: Bool) throws {
        loadPersistedIfNeeded()
        SyncDiagnostics.record("set-enabled:\(enabled)", in: stateDirectory)
        var next = persisted
        next.enabled = enabled
        try commit(next)
    }

    public func setScope(syncOriginals: Bool, syncMarket: Bool) throws {
        loadPersistedIfNeeded()
        var next = persisted
        next.syncOriginals = syncOriginals
        next.syncMarket = syncMarket
        try commit(next)
    }

    // MARK: Authorization

    public func authorizeFolder(_ folderURL: URL) async -> CloudSyncFolderAuthorizationResult {
        let result = await authorizeFolderOnce(folderURL)
        SyncDiagnostics.record("authorize:\(result.diagnosticName)", in: stateDirectory)
        return result
    }

    private func authorizeFolderOnce(_ folderURL: URL) async -> CloudSyncFolderAuthorizationResult {
        loadPersistedIfNeeded()
        do {
            let current = await folder.openIfNeeded()
            let displayName: String
            switch current {
            case .active:
                displayName = try await folder.replaceFolderAuthorization(with: folderURL)
            case .notAuthorized, .revoked, .notLoaded:
                displayName = try await folder.authorizeFolder(folderURL)
            case .transitioning:
                return .unavailable
            }
            var next = persisted
            next.folderName = displayName
            do {
                try commit(next)
            } catch {
                return .failed
            }
            return .authorized(displayName: displayName)
        } catch let error as CloudSyncFolderAccessError {
            SyncDiagnostics.record("authorize-error:\(error.diagnosticName)", in: stateDirectory)
            switch error {
            case .unauthorized, .notAuthorized:
                return .unauthorized
            case .retryable, .notFound, .notDownloaded:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: Pass

    public func synchronize(scope: SyncScope) async -> CloudSyncPassResult {
        guard !isRunning else {
            return CloudSyncPassResult(
                status: .pending,
                issue: .passInProgress,
                folderName: persisted.folderName
            )
        }
        isRunning = true
        defer { isRunning = false }
        loadPersistedIfNeeded()
        lastFailureDetail = nil

        do {
            let result = try await runPass(scope: scope)
            SyncDiagnostics.record(
                "pass:\(result.status)/\(result.issue)/finished=\(result.finishedAt != nil)",
                in: stateDirectory
            )
            return result
        } catch is CancellationError {
            SyncDiagnostics.record("pass:cancelled", in: stateDirectory)
            lastFailureDetail = "cancelled"
            return CloudSyncPassResult(
                status: .cancelled,
                folderName: persisted.folderName
            )
        } catch let abort as CloudSyncAbort {
            let detail = "\(passStage)/" + (abort.detail ?? "abort:\(abort.issue.rawValue)")
            lastFailureDetail = detail
            SyncDiagnostics.record(
                "pass-abort:\(abort.status)/\(abort.issue)/\(detail)",
                in: stateDirectory
            )
            return CloudSyncPassResult(
                status: abort.status,
                issue: abort.issue,
                folderName: persisted.folderName
            )
        } catch let error as CloudSyncFolderAccessError {
            lastFailureDetail = "\(passStage)/folder:\(error.diagnosticName)"
            SyncDiagnostics.record(
                "pass-folder-error:\(error.diagnosticName)",
                in: stateDirectory
            )
            return Self.result(forFolderError: error, folderName: persisted.folderName)
        } catch {
            lastFailureDetail = "error:\(type(of: error))"
            SyncDiagnostics.record("pass-error:\(type(of: error))", in: stateDirectory)
            return CloudSyncPassResult(
                status: .failed,
                issue: .repositoryFailure,
                folderName: persisted.folderName
            )
        }
    }

    // MARK: Pass implementation

    private func runPass(scope: SyncScope) async throws -> CloudSyncPassResult {
        passStage = "ready-folder"
        let displayName = try await readyFolder()
        try Task.checkCancellation()
        passStage = "marker"
        try await ensureMarker()
        try Task.checkCancellation()

        passStage = "snapshot"
        var state = persisted
        let snapshot = await repository.snapshot()
        let deviceID = try await repository.syncDeviceIdentifier()
        let journal = await repository.syncLocalOperations()

        var journaledFavorites: Set<WallpaperID> = []
        var journaledPinKeys: Set<OccurrenceKey> = []
        for operation in journal {
            switch operation.payload {
            case .favorite(let change):
                journaledFavorites.insert(change.wallpaperID)
            case .pin(let change):
                journaledPinKeys.insert(change.key)
            default:
                break
            }
        }

        var requestBudget = CloudSyncFolderLayout.maxDownloadRequestsPerPass
        let localAssets = await localAssetReferences(snapshot: snapshot, scope: scope, state: &state)
        let fullLocal = SyncLocalSnapshot(
            favorites: snapshot.favoriteWallpaperIDs,
            pinnedOccurrences: snapshot.pinnedOccurrences,
            occurrences: snapshot.occurrences,
            metadata: snapshot.metadata,
            wallpapers: snapshot.wallpapers,
            stories: snapshot.stories,
            assets: localAssets.map(\.reference)
        )
        let projected = SyncScopeProjection.local(fullLocal, scope: scope)
        let projectedHasContent = !projected.occurrences.isEmpty
            || !projected.metadata.isEmpty
            || !projected.wallpapers.isEmpty
            || !projected.stories.isEmpty
            || !projected.assets.isEmpty
        let hasUnjournaledState = !fullLocal.favorites.subtracting(journaledFavorites).isEmpty
            || fullLocal.pinnedOccurrences.contains { !journaledPinKeys.contains($0.key) }
        // The baseline is a one-time pre-journal snapshot. Once the repository
        // records that it ran, later content — including records imported from
        // a peer — must never be re-authored as a local bootstrap operation.
        let baselineEstablished = await repository.syncDidBootstrapBaseline()
        let needsBootstrap = !baselineEstablished
            && (projectedHasContent || hasUnjournaledState)

        // Fill the one-time favorites/pins baseline for repositories that
        // predate the journal. When the planner bootstraps content it already
        // includes those operations, so never run both in one pass.
        if !needsBootstrap {
            do {
                _ = try await repository.bootstrapSyncJournal()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
            }
        }

        passStage = "publish-journal"
        let initialPublish = try await publishJournal(deviceID: deviceID)
        passStage = "scan"
        let scan = try await scanOperations(requestBudget: &requestBudget)
        try Task.checkCancellation()

        let planLocal: SyncLocalSnapshot
        if needsBootstrap {
            planLocal = SyncLocalSnapshot(
                favorites: fullLocal.favorites.subtracting(journaledFavorites),
                pinnedOccurrences: Set(fullLocal.pinnedOccurrences.filter {
                    !journaledPinKeys.contains($0.key)
                }),
                occurrences: fullLocal.occurrences,
                metadata: fullLocal.metadata,
                wallpapers: fullLocal.wallpapers,
                stories: fullLocal.stories,
                assets: fullLocal.assets
            )
        } else {
            planLocal = fullLocal
        }

        let nextLocalSequence = await repository.syncNextLocalSequence()
        let input = SyncReconciliationInput(
            deviceID: deviceID,
            local: planLocal,
            nextLocalSequence: nextLocalSequence,
            bootstrapLocalState: needsBootstrap,
            scope: scope
        )
        let plan: SyncMergePlan
        do {
            plan = try SyncMergePlanner.plan(input: input, remoteOperations: scan.operations)
        } catch {
            throw CloudSyncAbort(status: .failed, issue: .planningFailure)
        }
        try Task.checkCancellation()

        let incrementalChanges = needsBootstrap
            ? []
            : incrementalChanges(
                local: fullLocal,
                scope: scope,
                state: state
            )

        let importResult: RepositorySyncImportResult
        do {
            importResult = try await repository.applySyncMergePlan(plan)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
        }
        try Task.checkCancellation()

        for change in incrementalChanges {
            try Task.checkCancellation()
            do {
                _ = try await repository.recordLocalSyncOperation(change.payload)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
            }
        }

        // Persist the echo-suppression checkpoint before folder publication:
        // journal entries are already durable in the repository, so a partial
        // folder write must not cause duplicate operations on the next pass.
        var recordDigests = state.publishedRecordDigests
        var assetDigests = state.publishedAssetDigests
        if needsBootstrap {
            for occurrence in projected.occurrences {
                recordDigests[Self.occurrenceKey(occurrence.id)] = Self.digest(
                    .occurrence(occurrence)
                )
            }
            for record in projected.metadata {
                recordDigests[Self.metadataKey(record.key)] = Self.digest(.metadata(record))
            }
            for record in projected.wallpapers {
                recordDigests[Self.wallpaperKey(record.wallpaperID)] = Self.digest(
                    .wallpaper(record)
                )
            }
            for story in projected.stories {
                recordDigests[Self.storyKey(story)] = Self.digest(.story(story))
            }
            for asset in projected.assets {
                assetDigests[Self.assetKey(asset)] = asset.contentSHA256.hex
            }
        }
        for change in incrementalChanges {
            for update in change.recordUpdates where !update.digest.isEmpty {
                recordDigests[update.key] = update.digest
            }
            for update in change.assetUpdates {
                assetDigests[update.key] = update.digest
            }
        }
        // Imported winners overwrite echo digests: an imported change must not
        // be re-authored as a local operation on the next pass.
        for occurrence in plan.repositoryMutation.occurrencesToUpsert {
            recordDigests[Self.occurrenceKey(occurrence.id)] = Self.digest(.occurrence(occurrence))
        }
        for record in plan.repositoryMutation.metadataToUpsert {
            recordDigests[Self.metadataKey(record.key)] = Self.digest(.metadata(record))
        }
        for record in plan.repositoryMutation.wallpapersToUpsert {
            recordDigests[Self.wallpaperKey(record.wallpaperID)] = Self.digest(.wallpaper(record))
        }
        for story in plan.repositoryMutation.storiesToUpsert {
            recordDigests[Self.storyKey(story)] = Self.digest(.story(story))
        }
        for asset in localAssets {
            if plan.archive.assetReference(for: asset.reference.id)?.contentSHA256
                == asset.reference.contentSHA256 {
                assetDigests[Self.assetKey(asset.reference)] = asset.reference.contentSHA256.hex
            }
        }
        state.publishedRecordDigests = recordDigests
        state.publishedAssetDigests = assetDigests
        state.folderName = displayName
        passStage = "commit"
        try commitPassState(state)
        state = persisted
        try Task.checkCancellation()

        passStage = "final-publish"
        let finalPublish = try await publishJournal(deviceID: deviceID)
        try Task.checkCancellation()
        passStage = "blobs"
        let blobPublish = try await publishBlobs(localAssets: localAssets)
        try Task.checkCancellation()
        passStage = "materialize"
        let materialized = try await materializeAssets(
            plan.assetsMissingLocally,
            state: &state,
            requestBudget: &requestBudget
        )
        try Task.checkCancellation()

        let pendingCount = (initialPublish.backlog || finalPublish.backlog ? 1 : 0)
            + scan.pendingDownloadCount
            + scan.retryableReadFailures
            + blobPublish.pendingCount
            + materialized.pendingCount
        let finishedAt = now()
        state.lastSyncAt = finishedAt
        state.folderName = displayName
        try commitPassState(state)

        let status: CloudSyncPassStatus = pendingCount > 0 ? .pending : .completed
        let issue = Self.issue(
            scan: scan,
            pendingCount: pendingCount,
            pendingDownloads: scan.pendingDownloadCount,
            rejectedRecords: importResult.rejectedRecords,
            rejectedAssets: materialized.rejectedCount
        )
        return CloudSyncPassResult(
            status: status,
            issue: issue,
            uploadedOperationCount: initialPublish.written + finalPublish.written,
            uploadedAssetCount: blobPublish.writtenCount,
            importedOperationCount: plan.mergeOutcome.acceptedCount,
            importedRecordCount: Self.changeCount(of: importResult),
            storedAssetCount: materialized.storedCount,
            pendingAssetCount: blobPublish.pendingCount + materialized.pendingCount,
            rejectedAssetCount: materialized.rejectedCount,
            rejectedFileCount: scan.invalidFileCount,
            rejectedRecordCount: importResult.rejectedRecords,
            folderName: displayName,
            finishedAt: finishedAt
        )
    }

    // MARK: Folder readiness

    private func readyFolder() async throws -> String {
        var state = await folder.currentState()
        if case .notLoaded = state {
            state = await folder.openIfNeeded()
        }
        switch state {
        case .active(let displayName):
            return displayName
        case .transitioning:
            throw CloudSyncAbort(status: .pending, issue: .folderAccess)
        case .revoked(let reason):
            switch reason {
            case .targetMissing, .notDirectory, .unsupportedLocation, .storageUnavailable:
                throw CloudSyncAbort(status: .unavailable, issue: .folderUnavailable)
            default:
                throw CloudSyncAbort(status: .unauthorized, issue: .unauthorized)
            }
        case .notAuthorized, .notLoaded:
            throw CloudSyncAbort(status: .awaitingFolder, issue: .none)
        }
    }

    private func ensureMarker() async throws {
        do {
            let data = try await folder.readFile(
                relativePath: CloudSyncFolderLayout.markerFileName,
                maxBytes: CloudSyncFolderLayout.maxMarkerBytes
            )
            let marker: CloudSyncFolderMarker
            do {
                marker = try JSONDecoder().decode(CloudSyncFolderMarker.self, from: data)
            } catch {
                throw CloudSyncAbort(status: .failed, issue: .incompatibleFolder)
            }
            guard marker.isCompatible else {
                throw CloudSyncAbort(status: .failed, issue: .incompatibleFolder)
            }
        } catch let error as CloudSyncFolderAccessError {
            guard case .notFound = error else {
                throw error
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data: Data
            do {
                data = try encoder.encode(CloudSyncFolderMarker.current)
            } catch {
                throw CloudSyncAbort(status: .failed, issue: .incompatibleFolder)
            }
            do {
                try await folder.writeFile(
                    data,
                    relativePath: CloudSyncFolderLayout.markerFileName
                )
            } catch let writeError as CloudSyncFolderAccessError {
                throw writeError
            } catch {
                throw CloudSyncAbort(status: .pending, issue: .folderAccess)
            }
        } catch let abort as CloudSyncAbort {
            throw abort
        } catch {
            throw CloudSyncAbort(
                status: .failed,
                issue: .folderAccess,
                detail: "marker-read:\(error)"
            )
        }
    }

    // MARK: Folder listing

    private func entries(_ relativePath: String) async throws -> [CloudSyncFolderEntry]? {
        do {
            return try await folder.directoryEntries(relativePath: relativePath)
        } catch let error as CloudSyncFolderAccessError {
            if case .notFound = error { return nil }
            throw error
        }
    }

    private func fileEntries(_ relativePath: String) async throws -> [CloudSyncFolderEntry] {
        let all = try await entries(relativePath) ?? []
        return all
            .filter { $0.kind == .file && CloudSyncFolderLayout.isSafeLeafName($0.name) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Journal publication

    private func publishJournal(
        deviceID: SyncDeviceID
    ) async throws -> (written: Int, backlog: Bool) {
        let journal = await repository.syncLocalOperations()
        guard !journal.isEmpty else { return (0, false) }
        let pending = await repository.pendingSyncOperations()
        let directory = CloudSyncFolderLayout.deviceDirectory(deviceID)
        var existing = Set(try await fileEntries(directory).map(\.name))
        var written = 0
        for operation in journal.sorted(by: { $0.sequence < $1.sequence }) {
            try Task.checkCancellation()
            let file = SyncOperationFile(operation: operation)
            guard CloudSyncFolderLayout.isSafeLeafName(file.fileName) else {
                throw CloudSyncAbort(status: .failed, issue: .invalidOperationFiles)
            }
            if existing.contains(file.fileName) { continue }
            let data: Data
            do {
                data = try file.encoded()
            } catch {
                throw CloudSyncAbort(status: .failed, issue: .invalidOperationFiles)
            }
            try await folder.writeFile(
                data,
                relativePath: CloudSyncFolderLayout.operationPath(
                    deviceID: deviceID,
                    fileName: file.fileName
                )
            )
            existing.insert(file.fileName)
            written += 1
        }
        guard let lastPending = pending.last?.sequence else {
            return (written, false)
        }
        let expected = Set(pending.map { SyncOperationFile(operation: $0).fileName })
        guard expected.isSubset(of: existing) else {
            return (written, true)
        }
        do {
            try await repository.acknowledgeSyncOperationsPublished(through: lastPending)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
        }
        return (written, false)
    }

    // MARK: Operation scan

    private struct ScanResult: Sendable {
        let operations: [SyncOperation]
        let invalidFileCount: Int
        let pendingDownloadCount: Int
        let retryableReadFailures: Int
        let tooManyDevices: Bool
        let tooManyFiles: Bool
    }

    private func scanOperations(
        requestBudget: inout Int
    ) async throws -> ScanResult {
        guard let deviceEntries = try await entries(CloudSyncFolderLayout.operationsDirectory)
        else {
            return ScanResult(
                operations: [],
                invalidFileCount: 0,
                pendingDownloadCount: 0,
                retryableReadFailures: 0,
                tooManyDevices: false,
                tooManyFiles: false
            )
        }

        var operations: [SyncOperation] = []
        var invalidFileCount = 0
        var pendingDownloadCount = 0
        var retryableReadFailures = 0
        var tooManyDevices = false
        var tooManyFiles = false
        var scannedFiles = 0

        let devices = deviceEntries
            .filter { $0.kind == .directory }
            .compactMap { entry -> (SyncDeviceID, String)? in
                guard CloudSyncFolderLayout.isSafeLeafName(entry.name),
                      let identifier = SyncDeviceID(entry.name)
                else {
                    return nil
                }
                return (identifier, entry.name)
            }
            .sorted { $0.1 < $1.1 }

        if devices.count > CloudSyncFolderLayout.maxDeviceDirectories {
            tooManyDevices = true
        }

        for (identifier, name) in devices.prefix(CloudSyncFolderLayout.maxDeviceDirectories) {
            try Task.checkCancellation()
            let directory = "\(CloudSyncFolderLayout.operationsDirectory)/\(name)"
            let files = try await fileEntries(directory)
            for entry in files {
                try Task.checkCancellation()
                if scannedFiles >= CloudSyncFolderLayout.maxTotalOperationFiles {
                    tooManyFiles = true
                    break
                }
                scannedFiles += 1
                guard CloudSyncFolderLayout.isSafeLeafName(entry.name),
                      let parsed = SyncOperationFile.parseFileName(entry.name),
                      parsed.deviceID == identifier
                else {
                    invalidFileCount += 1
                    continue
                }
                if entry.isDownloaded == false {
                    pendingDownloadCount += 1
                    await requestDownload(
                        relativePath: "\(directory)/\(entry.name)",
                        requestBudget: &requestBudget
                    )
                    continue
                }
                if let size = entry.byteCount,
                   size <= 0 || size > SyncWireProtocol.maxOperationFileBytes {
                    invalidFileCount += 1
                    continue
                }
                let data: Data
                do {
                    data = try await folder.readFile(
                        relativePath: "\(directory)/\(entry.name)",
                        maxBytes: SyncWireProtocol.maxOperationFileBytes + 1
                    )
                } catch let error as CloudSyncFolderAccessError {
                    switch error {
                    case .notFound, .tooLarge, .invalidPath:
                        invalidFileCount += 1
                    case .notDownloaded:
                        pendingDownloadCount += 1
                        await requestDownload(
                            relativePath: "\(directory)/\(entry.name)",
                            requestBudget: &requestBudget
                        )
                    case .retryable:
                        retryableReadFailures += 1
                    case .notAuthorized, .unauthorized:
                        throw error
                    case .other:
                        invalidFileCount += 1
                    }
                    continue
                }
                do {
                    let file = try SyncOperationFile.decode(data, fileName: entry.name)
                    operations.append(file.operation)
                } catch {
                    invalidFileCount += 1
                }
            }
            if tooManyFiles { break }
        }

        operations.sort { lhs, rhs in
            if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.id < rhs.id
        }

        return ScanResult(
            operations: operations,
            invalidFileCount: invalidFileCount,
            pendingDownloadCount: pendingDownloadCount,
            retryableReadFailures: retryableReadFailures,
            tooManyDevices: tooManyDevices,
            tooManyFiles: tooManyFiles
        )
    }

    private func requestDownload(relativePath: String, requestBudget: inout Int) async {
        guard requestBudget > 0 else { return }
        requestBudget -= 1
        try? await folder.requestFileDownload(relativePath: relativePath)
    }

    // MARK: Local assets

    private struct LocalAsset: Sendable {
        let reference: SyncAssetReference
        let relativePath: String
        let fileURL: URL
    }

    private func localAssetReferences(
        snapshot: RepositorySnapshot,
        scope: SyncScope,
        state: inout CloudSyncPersistedState
    ) async -> [LocalAsset] {
        let base = SyncLocalSnapshot(
            favorites: snapshot.favoriteWallpaperIDs,
            pinnedOccurrences: snapshot.pinnedOccurrences,
            occurrences: snapshot.occurrences,
            metadata: snapshot.metadata,
            wallpapers: snapshot.wallpapers,
            stories: snapshot.stories
        )
        let projected = SyncScopeProjection.local(base, scope: scope)
        var referenced = projected.favorites
        referenced.formUnion(projected.occurrences.map(\.wallpaperID))
        referenced.formUnion(projected.metadata.map(\.wallpaperID))
        referenced.formUnion(projected.stories.compactMap(\.associatedWallpaperID))
        referenced.formUnion(projected.pins.map(\.wallpaperID))

        var cache = state.assetDigestCache
        var result: [LocalAsset] = []
        for asset in snapshot.assets.sorted(by: { $0.id < $1.id }) {
            guard scope.includes(asset.kind) else { continue }
            guard scope.includesAllMarkets || referenced.contains(asset.wallpaperID) else {
                continue
            }
            guard let fileURL = await repository.assetURL(for: asset) else { continue }
            let digest: SyncContentDigest
            let byteCount: Int
            if let cached = cache[asset.relativePath],
               let parsed = Self.parseCacheEntry(cached) {
                digest = parsed.digest
                byteCount = parsed.byteCount
            } else {
                guard let hashed = try? CloudSyncContentHashing.digest(ofFileAt: fileURL)
                else {
                    continue
                }
                digest = hashed.digest
                byteCount = hashed.byteCount
                cache[asset.relativePath] = "\(digest.hex):\(byteCount)"
            }
            let reference = SyncAssetReference(
                wallpaperID: asset.wallpaperID,
                kind: asset.kind,
                contentSHA256: digest,
                byteCount: byteCount
            )
            guard reference.isValid else { continue }
            result.append(LocalAsset(
                reference: reference,
                relativePath: asset.relativePath,
                fileURL: fileURL
            ))
        }
        state.assetDigestCache = cache
        return result
    }

    private static func parseCacheEntry(
        _ value: String
    ) -> (digest: SyncContentDigest, byteCount: Int)? {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let digest = SyncContentDigest(hex: String(parts[0])),
              let byteCount = Int(parts[1]),
              byteCount > 0
        else {
            return nil
        }
        return (digest, byteCount)
    }

    // MARK: Incremental local changes

    private struct IncrementalChange: Sendable {
        let payload: SyncOperationPayload
        let recordUpdates: [(key: String, digest: String)]
        let assetUpdates: [(key: String, digest: String)]
    }

    private func incrementalChanges(
        local: SyncLocalSnapshot,
        scope: SyncScope,
        state: CloudSyncPersistedState
    ) -> [IncrementalChange] {
        let projected = SyncScopeProjection.local(local, scope: scope)
        var changes: [IncrementalChange] = []
        let publishedRecords = state.publishedRecordDigests
        let publishedAssets = state.publishedAssetDigests

        for occurrence in projected.occurrences {
            let key = Self.occurrenceKey(occurrence.id)
            let digest = Self.digest(.occurrence(occurrence))
            guard publishedRecords[key] != digest else {
                continue
            }
            changes.append(IncrementalChange(
                payload: .occurrence(occurrence),
                recordUpdates: [(key, digest)],
                assetUpdates: []
            ))
        }
        for record in projected.metadata {
            let key = Self.metadataKey(record.key)
            let digest = Self.digest(.metadata(record))
            guard publishedRecords[key] != digest else {
                continue
            }
            changes.append(IncrementalChange(
                payload: .metadata(record),
                recordUpdates: [(key, digest)],
                assetUpdates: []
            ))
        }
        for record in projected.wallpapers {
            let key = Self.wallpaperKey(record.wallpaperID)
            let digest = Self.digest(.wallpaper(record))
            guard publishedRecords[key] != digest else {
                continue
            }
            changes.append(IncrementalChange(
                payload: .wallpaper(record),
                recordUpdates: [(key, digest)],
                assetUpdates: []
            ))
        }
        for story in projected.stories {
            let key = Self.storyKey(story)
            let digest = Self.digest(.story(story))
            guard publishedRecords[key] != digest else {
                continue
            }
            changes.append(IncrementalChange(
                payload: .story(story),
                recordUpdates: [(key, digest)],
                assetUpdates: []
            ))
        }

        var pendingAssets: [SyncAssetReference] = []
        for asset in projected.assets {
            let key = Self.assetKey(asset)
            guard publishedAssets[key] != asset.contentSHA256.hex else { continue }
            pendingAssets.append(asset)
        }
        var index = 0
        while index < pendingAssets.count {
            let end = min(index + SyncWireProtocol.maxAssetReferencesPerOperation, pendingAssets.count)
            let chunk = Array(pendingAssets[index..<end])
            changes.append(IncrementalChange(
                payload: .assets(chunk),
                recordUpdates: [],
                assetUpdates: chunk.map {
                    (Self.assetKey($0), $0.contentSHA256.hex)
                }
            ))
            index = end
        }
        return changes
    }

    // MARK: Blob publication

    private func publishBlobs(
        localAssets: [LocalAsset]
    ) async throws -> (writtenCount: Int, pendingCount: Int) {
        guard !localAssets.isEmpty else { return (0, 0) }
        let blobEntries = try await entries(CloudSyncFolderLayout.blobsDirectory)
        var existing = Set(
            (blobEntries ?? [])
                .filter { $0.kind == .file }
                .map(\.name)
        )
        var written = 0
        var pending = 0
        for asset in localAssets {
            try Task.checkCancellation()
            let name = SyncAssetBlobNaming.fileName(for: asset.reference.contentSHA256)
            if existing.contains(name) { continue }
            guard let hashed = try? CloudSyncContentHashing.digest(ofFileAt: asset.fileURL),
                  hashed.digest == asset.reference.contentSHA256,
                  hashed.byteCount == asset.reference.byteCount,
                  let data = try? Data(contentsOf: asset.fileURL, options: .mappedIfSafe)
            else {
                pending += 1
                continue
            }
            do {
                try await folder.writeFile(
                    data,
                    relativePath: CloudSyncFolderLayout.blobPath(
                        asset.reference.contentSHA256
                    )
                )
                existing.insert(name)
                written += 1
            } catch let error as CloudSyncFolderAccessError {
                switch error {
                case .notAuthorized, .unauthorized:
                    throw error
                default:
                    pending += 1
                }
            } catch {
                pending += 1
            }
        }
        return (written, pending)
    }

    // MARK: Asset materialization

    private struct MaterializationResult: Sendable {
        let storedCount: Int
        let pendingCount: Int
        let rejectedCount: Int
    }

    private func materializeAssets(
        _ references: [SyncAssetReference],
        state: inout CloudSyncPersistedState,
        requestBudget: inout Int
    ) async throws -> MaterializationResult {
        guard !references.isEmpty else {
            return MaterializationResult(storedCount: 0, pendingCount: 0, rejectedCount: 0)
        }
        let ordered = references.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.contentSHA256 < $1.contentSHA256
        }
        var existing = Set(
            (try await entries(CloudSyncFolderLayout.blobsDirectory) ?? [])
                .filter { $0.kind == .file }
                .map(\.name)
        )
        var rejected = Set(state.rejectedAssetKeys)
        var stored = 0
        var pending = 0
        var rejectedCount = 0

        for reference in ordered {
            try Task.checkCancellation()
            let rejectionKey = "\(reference.id)|\(reference.contentSHA256.hex)"
            if rejected.contains(rejectionKey) {
                rejectedCount += 1
                continue
            }
            let name = SyncAssetBlobNaming.fileName(for: reference.contentSHA256)
            guard existing.contains(name) else {
                pending += 1
                continue
            }
            let relativePath = CloudSyncFolderLayout.blobPath(reference.contentSHA256)
            if let entry = try await blobEntry(named: name) {
                if entry.isDownloaded == false {
                    await requestDownload(relativePath: relativePath, requestBudget: &requestBudget)
                    pending += 1
                    continue
                }
                if let size = entry.byteCount, size != reference.byteCount {
                    pending += 1
                    continue
                }
            }
            let data: Data
            do {
                data = try await folder.readFile(
                    relativePath: relativePath,
                    maxBytes: max(reference.byteCount, 1)
                )
            } catch let error as CloudSyncFolderAccessError {
                switch error {
                case .notFound:
                    existing.remove(name)
                    pending += 1
                case .notDownloaded:
                    await requestDownload(relativePath: relativePath, requestBudget: &requestBudget)
                    pending += 1
                case .retryable:
                    pending += 1
                case .tooLarge:
                    rejected.insert(rejectionKey)
                    rejectedCount += 1
                case .invalidPath:
                    rejected.insert(rejectionKey)
                    rejectedCount += 1
                case .notAuthorized, .unauthorized:
                    throw error
                case .other:
                    pending += 1
                }
                continue
            }
            let validated: CloudSyncValidatedAsset
            do {
                validated = try CloudSyncAssetValidation.validate(data: data, reference: reference)
            } catch let error as CloudSyncAssetValidationError {
                switch error {
                case .byteCountMismatch, .digestMismatch:
                    // A partially uploaded iCloud item is retryable; the same
                    // bytes may become consistent after download completes.
                    pending += 1
                case .unreadableImage, .unsupportedImageType, .mimeTypeMismatch,
                     .dimensionMismatch, .dimensionsOutOfBounds:
                    rejected.insert(rejectionKey)
                    rejectedCount += 1
                }
                continue
            } catch {
                pending += 1
                continue
            }
            do {
                let storedAsset = try await repository.importSyncAsset(
                    data,
                    reference: reference,
                    fileExtension: validated.fileExtension,
                    accessedAt: now()
                )
                state.publishedAssetDigests[Self.assetKey(reference)] =
                    reference.contentSHA256.hex
                state.assetDigestCache[storedAsset.relativePath] =
                    "\(reference.contentSHA256.hex):\(data.count)"
                stored += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RepositoryError {
                if case .protectedAsset = error {
                    rejected.insert(rejectionKey)
                    rejectedCount += 1
                } else {
                    throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
                }
            } catch {
                throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
            }
        }
        state.rejectedAssetKeys = Array(rejected).sorted()
        return MaterializationResult(
            storedCount: stored,
            pendingCount: pending,
            rejectedCount: rejectedCount
        )
    }

    private func blobEntry(named name: String) async throws -> CloudSyncFolderEntry? {
        let all = try await entries(CloudSyncFolderLayout.blobsDirectory) ?? []
        return all.first { $0.kind == .file && $0.name == name }
    }

    // MARK: Helpers

    private func commit(_ state: CloudSyncPersistedState) throws {
        var normalized = state
        normalized.normalize()
        do {
            try stateStore.save(normalized)
        } catch {
            throw CloudSyncAbort(status: .failed, issue: .repositoryFailure)
        }
        persisted = normalized
    }

    /// Commits pass progress without reverting options the user changed while
    /// this pass was suspended on IO. `setEnabled`/`setScope` run on the same
    /// actor and must always win over a pass's older copy.
    private func commitPassState(_ state: CloudSyncPersistedState) throws {
        var next = state
        next.enabled = persisted.enabled
        next.syncOriginals = persisted.syncOriginals
        next.syncMarket = persisted.syncMarket
        try commit(next)
    }

    private static func result(
        forFolderError error: CloudSyncFolderAccessError,
        folderName: String?
    ) -> CloudSyncPassResult {
        switch error {
        case .notAuthorized, .unauthorized:
            return CloudSyncPassResult(status: .unauthorized, issue: .unauthorized, folderName: folderName)
        case .notFound, .retryable, .notDownloaded:
            // Offline, coordinated-access pressure and not-yet-materialized
            // items keep pending work instead of failing the pass.
            return CloudSyncPassResult(status: .pending, issue: .folderAccess, folderName: folderName)
        case .tooLarge, .invalidPath, .other:
            return CloudSyncPassResult(status: .failed, issue: .folderAccess, folderName: folderName)
        }
    }

    private static func issue(
        scan: ScanResult,
        pendingCount: Int,
        pendingDownloads: Int,
        rejectedRecords: Int,
        rejectedAssets: Int
    ) -> CloudSyncIssueCode {
        if scan.tooManyDevices { return .tooManyDevices }
        if scan.tooManyFiles { return .tooManyOperationFiles }
        if scan.invalidFileCount > 0 { return .invalidOperationFiles }
        if rejectedRecords > 0 { return .rejectedRecords }
        if rejectedAssets > 0 { return .rejectedAssets }
        if pendingCount > 0 {
            return pendingDownloads > 0 ? .pendingDownloads : .pendingAssets
        }
        return .none
    }

    private static func changeCount(of result: RepositorySyncImportResult) -> Int {
        result.occurrences.inserted + result.occurrences.updated
            + result.metadata.inserted + result.metadata.updated
            + result.wallpapers.inserted + result.wallpapers.updated
            + result.stories.inserted + result.stories.updated
            + result.favoritesAdded + result.favoritesRemoved
            + result.pinsAdded + result.pinsRemoved
    }

    private static func digest(_ payload: SyncOperationPayload) -> String {
        CloudSyncContentHashing.digest(of: payload) ?? ""
    }

    private static func occurrenceKey(_ key: OccurrenceKey) -> String {
        "o:\(key.source.rawValue)|\(key.market.rawValue)|\(key.localDate.iso8601)"
    }

    private static func metadataKey(_ key: OccurrenceKey) -> String {
        "m:\(key.source.rawValue)|\(key.market.rawValue)|\(key.localDate.iso8601)"
    }

    private static func wallpaperKey(_ id: WallpaperID) -> String {
        "w:\(id.source.rawValue)|\(id.sourceImageID)"
    }

    private static func storyKey(_ story: DailyStoryRecord) -> String {
        "s:\(SyncStoryKey(story: story).description)"
    }

    private static func assetKey(_ reference: SyncAssetReference) -> String {
        "a:\(reference.wallpaperID.source.rawValue)|\(reference.wallpaperID.sourceImageID)|\(reference.kind.rawValue)"
    }
}

// MARK: - Internal errors

struct CloudSyncAbort: Error {
    let status: CloudSyncPassStatus
    let issue: CloudSyncIssueCode
    var detail: String? = nil
}

// MARK: - Payload classification

extension SyncOperationPayload {
    /// User content (everything except favorite/pin tombstones). Used to decide
    /// whether pre-existing repository content already has a journal baseline.
    var isContentPayload: Bool {
        switch self {
        case .occurrence, .metadata, .wallpaper, .story, .assets:
            return true
        case .favorite, .pin:
            return false
        }
    }
}
