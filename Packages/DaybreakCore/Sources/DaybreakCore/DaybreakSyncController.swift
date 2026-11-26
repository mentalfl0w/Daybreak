import Foundation
import Observation

// MARK: - Observable status

/// Local-only description of the shared-folder sync state.
///
/// `completed` means this device finished its own pass; it never claims that
/// another device has received or applied anything.
public enum DaybreakSyncStatus: String, Hashable, Sendable, Codable {
    case disabled
    case awaitingFolder
    case syncing
    case completed
    case pending
    case unavailable
    case unauthorized
    case failed
}

// MARK: - Controller

/// Main-actor, observable facade over the serial `CloudSyncEngine`.
///
/// Responsibilities:
/// - Own the single in-flight pass and coalesce every trigger into at most one
///   extra pass (single-flight, no overlapping folder writes).
/// - Cancel and invalidate in-flight work when sync is disabled or the folder
///   is replaced; stale results can never publish state.
/// - Never report `enabled` without an authorized folder.
/// - Run all folder and repository IO in the engine actor, not on main.
///
/// Create exactly one instance per shared `WallpaperRepository` (for example in
/// the app model) and inject it into every window or scene.
@MainActor
@Observable
public final class DaybreakSyncController {
    public private(set) var enabled: Bool = false
    public private(set) var folderName: String?
    public private(set) var status: DaybreakSyncStatus = .disabled
    public private(set) var lastSyncAt: Date?
    public private(set) var syncOriginals: Bool = false
    public private(set) var syncMarket: Bool = false
    /// Incremented after a pass imports records, favorites, pins or verified
    /// assets. Observers use it to refresh timeline/library/recap models.
    public private(set) var dataRevision: Int = 0
    /// Stage of the last pass, so the UI can explain why content is pending or
    /// failed instead of showing one generic sentence.
    public private(set) var lastIssue: CloudSyncIssueCode = .none
    /// Short technical cause of the last failed pass, shown as a detail line.
    public private(set) var lastFailureDetail: String?

    @ObservationIgnored private let engine: CloudSyncEngine
    @ObservationIgnored private let market: @Sendable () -> Market
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var isRestored = false
    @ObservationIgnored private var isTransitioning = false

    // MARK: Initialization

    /// Production initializer: stores the bookmark under
    /// `<stateDirectory>/authorized-folder` and uses standard scope policy.
    public convenience init(
        repository: WallpaperRepository,
        stateDirectory: URL,
        market: @escaping @Sendable () -> Market = { .zhCN }
    ) {
        let bookmarkDirectory = stateDirectory.appendingPathComponent(
            "authorized-folder",
            isDirectory: true
        )
        self.init(
            repository: repository,
            stateDirectory: stateDirectory,
            folderStore: AuthorizedFolderStore(
                bookmarkDirectory: bookmarkDirectory,
                scopePolicy: .automatic,
                diagnosticsDirectory: stateDirectory
            ),
            now: { Date() },
            market: market
        )
    }

    /// Testing seam: inject a folder double and a deterministic clock.
    public init(
        repository: WallpaperRepository,
        stateDirectory: URL,
        folderStore: any CloudSyncFolderAccessing,
        now: @escaping @Sendable () -> Date = { Date() },
        market: @escaping @Sendable () -> Market = { .zhCN }
    ) {
        self.engine = CloudSyncEngine(
            repository: repository,
            folder: folderStore,
            stateDirectory: stateDirectory,
            now: now
        )
        self.market = market
        self.restoreTask = nil
        self.restoreTask = Task { [weak self] in
            guard let self else { return }
            await self.restore()
        }
    }

    // MARK: Lifecycle

    /// Restores persisted options and folder authorization. Idempotent and
    /// cheap; `init` already starts the same work.
    public func prepare() async {
        if isRestored { return }
        if let task = restoreTask {
            await task.value
        }
        if !isRestored {
            await restore()
        }
    }

    /// Enables or disables sync. Enabling requires an authorized folder; with
    /// no usable folder this leaves `enabled == false` and reports the reason.
    public func setEnabled(_ enabled: Bool) async {
        await prepare()
        if self.enabled == enabled {
            if enabled {
                await triggerSync(waitForCompletion: false)
            }
            return
        }
        if enabled {
            await enableWithAuthorizedFolder()
        } else {
            await stopAndDisable()
        }
    }

    /// Authorizes or replaces the shared folder and, on success, enables sync.
    public func selectFolder(_ folderURL: URL) async {
        await prepare()
        isTransitioning = true
        generation &+= 1
        needsAnotherPass = false
        await cancelInFlightPass()
        status = .syncing

        let result = await engine.authorizeFolder(folderURL)
        isTransitioning = false
        switch result {
        case .authorized(let displayName):
            folderName = displayName
            do {
                try await engine.setEnabled(true)
            } catch {
                enabled = false
                status = .failed
                return
            }
            enabled = true
            await triggerSync(waitForCompletion: false)
        case .unauthorized:
            await forceDisabled(status: .unauthorized)
        case .unavailable:
            await forceDisabled(status: .unavailable)
        case .failed:
            await forceDisabled(status: .failed)
        }
    }

    /// Awaits one coalesced pass. Additional callers join the same pass and a
    /// trigger arriving mid-pass schedules at most one additional pass.
    public func syncNow() async {
        await prepare()
        guard enabled else { return }
        await triggerSync(waitForCompletion: true)
    }

    /// Fire-and-forget trigger for launch, foreground, wake and local
    /// mutations. Coalesces with any in-flight pass.
    public func noteForegroundActivity() async {
        await prepare()
        guard enabled else { return }
        await triggerSync(waitForCompletion: false)
    }

    public func setSyncOriginals(_ value: Bool) async {
        await prepare()
        guard syncOriginals != value else { return }
        do {
            try await engine.setScope(syncOriginals: value, syncMarket: syncMarket)
        } catch {
            status = .failed
            return
        }
        syncOriginals = value
        if enabled {
            await triggerSync(waitForCompletion: false)
        }
    }

    public func setSyncMarket(_ value: Bool) async {
        await prepare()
        guard syncMarket != value else { return }
        do {
            try await engine.setScope(syncOriginals: syncOriginals, syncMarket: value)
        } catch {
            status = .failed
            return
        }
        syncMarket = value
        if enabled {
            await triggerSync(waitForCompletion: false)
        }
    }

    // MARK: Restore

    private func restore() async {
        guard !isRestored else { return }
        let state = await engine.localState()
        let availability = await engine.folderAvailability()

        syncOriginals = state.syncOriginals
        syncMarket = state.syncMarket
        lastSyncAt = state.lastSyncAt
        folderName = state.folderName
        if case .active(let name) = availability {
            folderName = name
        }

        guard state.enabled else {
            enabled = false
            status = .disabled
            isRestored = true
            return
        }

        switch availability {
        case .active:
            enabled = true
            status = .syncing
            isRestored = true
            await triggerSync(waitForCompletion: false)
        case .transitioning:
            enabled = false
            status = .pending
            isRestored = true
        case .revoked(let reason):
            enabled = false
            status = Self.syncStatus(for: reason)
            isRestored = true
            try? await engine.setEnabled(false)
        case .notAuthorized, .notLoaded:
            enabled = false
            folderName = nil
            status = .awaitingFolder
            isRestored = true
            try? await engine.setEnabled(false)
        }
    }

    // MARK: Single-flight scheduling

    private func triggerSync(waitForCompletion: Bool) async {
        guard enabled, !isTransitioning else { return }
        needsAnotherPass = true
        if syncTask == nil {
            let startedGeneration = generation
            syncTask = Task { [weak self] in
                guard let self else { return }
                await self.runLoop(generation: startedGeneration)
            }
        }
        if waitForCompletion, let task = syncTask {
            await task.value
        }
    }

    private func runLoop(generation startedGeneration: UInt64) async {
        while !Task.isCancelled, startedGeneration == generation, enabled {
            needsAnotherPass = false
            await performPass(generation: startedGeneration)
            if !needsAnotherPass { break }
        }
        syncTask = nil
    }

    private func performPass(generation startedGeneration: UInt64) async {
        guard startedGeneration == generation, enabled else { return }
        status = .syncing
        let markets: Set<Market> = syncMarket ? [] : [market()]
        let scope = SyncScope(markets: markets, includesOriginals: syncOriginals)
        let result = await engine.synchronize(scope: scope)
        guard startedGeneration == generation else { return }
        if result.didChangeLocalData {
            dataRevision &+= 1
        }
        if let name = result.folderName {
            folderName = name
        }
        if let finishedAt = result.finishedAt {
            lastSyncAt = finishedAt
        }
        lastIssue = result.issue
        lastFailureDetail = await engine.lastFailureDetail
        switch result.status {
        case .completed:
            status = .completed
        case .pending:
            status = .pending
        case .failed:
            status = .failed
            if result.issue == .incompatibleFolder {
                // A selected folder that is not a Daybreak sync folder must
                // never keep showing sync as enabled.
                await forceDisabled(status: .failed)
            }
        case .unavailable:
            status = .unavailable
        case .unauthorized:
            status = .unauthorized
            await forceDisabled(status: .unauthorized)
        case .awaitingFolder:
            folderName = nil
            await forceDisabled(status: .awaitingFolder)
        case .cancelled:
            status = .pending
        }
    }

    // MARK: State transitions

    private func enableWithAuthorizedFolder() async {
        let availability = await engine.folderAvailability()
        switch availability {
        case .active(let displayName):
            do {
                try await engine.setEnabled(true)
            } catch {
                status = .failed
                return
            }
            folderName = displayName
            enabled = true
            status = .syncing
            await triggerSync(waitForCompletion: false)
        case .transitioning:
            await forceDisabled(status: .pending)
        case .revoked(let reason):
            await forceDisabled(status: Self.syncStatus(for: reason))
        case .notAuthorized, .notLoaded:
            folderName = nil
            await forceDisabled(status: .awaitingFolder)
        }
    }

    private func stopAndDisable() async {
        isTransitioning = true
        try? await engine.setEnabled(false)
        generation &+= 1
        needsAnotherPass = false
        await cancelInFlightPass()
        enabled = false
        status = .disabled
        isTransitioning = false
    }

    private func forceDisabled(status newStatus: DaybreakSyncStatus) async {
        if enabled {
            enabled = false
            try? await engine.setEnabled(false)
        }
        status = newStatus
    }

    private func cancelInFlightPass() async {
        let task = syncTask
        task?.cancel()
        await task?.value
        syncTask = nil
    }

    private static func syncStatus(for reason: CloudSyncFolderRevocation) -> DaybreakSyncStatus {
        switch reason {
        case .targetMissing, .notDirectory, .unsupportedLocation, .storageUnavailable:
            return .unavailable
        default:
            return .unauthorized
        }
    }
}
