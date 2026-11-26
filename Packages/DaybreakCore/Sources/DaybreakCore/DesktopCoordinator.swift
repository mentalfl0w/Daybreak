import Foundation

// MARK: - Display identity and wallpaper intent

/// Stable identity of one physical display.
///
/// The value is supplied by the platform integration layer. It must remain
/// stable across reconnects and must not be derived from a temporary screen
/// index or the current screen ordering. DaybreakCore deliberately does not
/// know how the native layer obtains it.
public struct DesktopDisplayID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: DesktopDisplayID, rhs: DesktopDisplayID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// System-supported wallpaper scaling, expressed without importing AppKit.
public enum DesktopImageScaling: String, Hashable, Sendable, Codable, CaseIterable {
    case fill
    case fit
    case stretch
    case center
}

/// The wallpaper Daybreak wants on a display.
///
/// `imageURL` is expected to be a canonical local file URL that the platform
/// layer can pass to the public desktop-image API. URL equality is exact; the
/// backend is responsible for reporting the same canonical URL it was given.
public struct DesktopWallpaper: Hashable, Sendable, Codable {
    public let imageURL: URL
    public let scaling: DesktopImageScaling

    public init(imageURL: URL, scaling: DesktopImageScaling = .fill) {
        self.imageURL = imageURL
        self.scaling = scaling
    }
}

/// One display's current state as reported by the platform adapter.
public struct DesktopDisplaySnapshot: Hashable, Sendable, Codable {
    public let displayID: DesktopDisplayID
    public let currentImageURL: URL?
    /// Actual current scaling, when the public system API can report it.
    /// `nil` explicitly means "not observable", never "matches the target".
    public let reportedScaling: DesktopImageScaling?

    public init(
        displayID: DesktopDisplayID,
        currentImageURL: URL? = nil,
        reportedScaling: DesktopImageScaling? = nil
    ) {
        self.displayID = displayID
        self.currentImageURL = currentImageURL
        self.reportedScaling = reportedScaling
    }
}

/// A point-in-time view of the connected displays.
///
/// `screensHaveSeparateSpaces` mirrors the public system capability flag. It is
/// exposed for diagnostics and UI, but the coordinator reconciles every display
/// identically: public APIs cannot enumerate or address inactive Spaces, so no
/// behaviour may promise an atomic update of all Spaces.
public struct DesktopTopology: Hashable, Sendable, Codable {
    public let displays: [DesktopDisplaySnapshot]
    public let screensHaveSeparateSpaces: Bool

    public init(displays: [DesktopDisplaySnapshot] = [], screensHaveSeparateSpaces: Bool = false) {
        self.displays = displays
        self.screensHaveSeparateSpaces = screensHaveSeparateSpaces
    }

    public var connectedDisplayIDs: Set<DesktopDisplayID> {
        Set(displays.map(\.displayID))
    }
}

/// Platform boundary implemented by the macOS integration layer.
///
/// The adapter owns `NSScreen`/`NSWorkspace` usage. It must not use private
/// APIs or touch Dock/WallpaperAgent data. `readTopology` should be cheap and
/// side-effect free; `applyWallpaper` should throw a `DesktopFailure` when the
/// public system API rejects the request.
public protocol DesktopPlatformBackend: Sendable {
    func readTopology() async throws -> DesktopTopology
    func applyWallpaper(_ wallpaper: DesktopWallpaper, to displayID: DesktopDisplayID) async throws
}

// MARK: - Failures

/// A structured, platform-neutral failure.
public struct DesktopFailure: Error, Hashable, Sendable, Codable, LocalizedError {
    public enum Stage: String, Hashable, Sendable, Codable {
        case readingDisplays
        case applyingWallpaper
    }

    public enum Kind: String, Hashable, Sendable, Codable {
        /// The display disappeared between the snapshot and the write.
        case displayUnavailable
        /// The local image file is missing, unreadable or still being written.
        case imageUnreadable
        /// The system rejected the image format.
        case unsupportedImageFormat
        /// The process lacks permission to change the desktop image.
        case permissionDenied
        /// The system is temporarily busy.
        case systemBusy
        /// The public system call timed out.
        case timedOut
        /// A local file or preference write failed.
        case ioFailure
        /// Any failure the adapter could not classify.
        case unknown
    }

    public let stage: Stage
    public let kind: Kind
    public let message: String

    public init(stage: Stage, kind: Kind, message: String = "") {
        self.stage = stage
        self.kind = kind
        self.message = message
    }

    /// Bounded automatic retries are useful only for failures that may clear on
    /// their own. A missing display is handled by the reconnect path instead.
    public var isRetryable: Bool {
        switch kind {
        case .systemBusy, .timedOut, .ioFailure, .unknown:
            return true
        case .displayUnavailable, .imageUnreadable, .unsupportedImageFormat, .permissionDenied:
            return false
        }
    }

    public var errorDescription: String? {
        message.isEmpty ? "Desktop operation failed: \(kind.rawValue)" : message
    }

    func withStage(_ stage: Stage) -> DesktopFailure {
        DesktopFailure(stage: stage, kind: kind, message: message)
    }
}

// MARK: - Assignment and protection state

/// Why a display has a desired wallpaper.
///
/// Persisted alongside the assignment so an automatic target update can
/// replace its own previous target on a display that is currently
/// disconnected without replacing a wallpaper the user chose manually.
public enum DesktopAssignmentSource: String, Hashable, Sendable, Codable {
    /// Written by an automatic-sync target update. Only these assignments may
    /// be retargeted implicitly.
    case automatic
    /// Written by an explicit user wallpaper action. Automation must preserve
    /// it until the user assigns a new target, re-enables automatic sync, or
    /// removes the assignment.
    case manual
    /// Persisted before provenance existed. Automatic and manual writes were
    /// indistinguishable, so automatic target updates must preserve it.
    /// Migration keeps the assignment instead of guessing or deleting it.
    case unknown
}

/// Persistable desired-wallpaper entry for one display.
public struct DesktopDisplayAssignment: Hashable, Sendable, Codable, Identifiable {
    public let displayID: DesktopDisplayID
    public let wallpaper: DesktopWallpaper
    public let source: DesktopAssignmentSource

    public init(
        displayID: DesktopDisplayID,
        wallpaper: DesktopWallpaper,
        source: DesktopAssignmentSource = .unknown
    ) {
        self.displayID = displayID
        self.wallpaper = wallpaper
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case displayID
        case wallpaper
        case source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decode(DesktopDisplayID.self, forKey: .displayID)
        wallpaper = try container.decode(DesktopWallpaper.self, forKey: .wallpaper)
        // Schema 1/2 assignments have no provenance. Guessing would either
        // overwrite a manual choice or strand an automatic target, so keep the
        // conservative unknown value and preserve the entry. An unrecognized
        // source string also stays unknown instead of making the whole
        // settings file unreadable.
        if let raw = try? container.decodeIfPresent(String.self, forKey: .source),
           let decoded = DesktopAssignmentSource(rawValue: raw) {
            source = decoded
        } else {
            source = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(wallpaper, forKey: .wallpaper)
        try container.encode(source, forKey: .source)
    }

    public var id: DesktopDisplayID { displayID }
}

/// A wallpaper that Daybreak successfully handed to the platform layer.
public struct DesktopAppliedWallpaper: Hashable, Sendable, Codable {
    public let wallpaper: DesktopWallpaper
    public let appliedAt: Date
    public let spaceGeneration: UInt64

    public init(wallpaper: DesktopWallpaper, appliedAt: Date, spaceGeneration: UInt64) {
        self.wallpaper = wallpaper
        self.appliedAt = appliedAt
        self.spaceGeneration = spaceGeneration
    }
}

/// Why automation stopped overwriting a display.
public struct DesktopManualProtection: Hashable, Sendable, Codable {
    public enum Origin: String, Hashable, Sendable, Codable {
        /// Detected from an observed wallpaper that Daybreak never wrote.
        case detectedExternalChange
        /// Requested by the user through `protectCurrentWallpaper(for:)`.
        case explicitlyRequested
    }

    public let imageURL: URL
    /// Scaling that accompanied the protected image when the backend could
    /// report it. `nil` means the actual options were not observable.
    public let imageScaling: DesktopImageScaling?
    public let detectedAt: Date
    public let spaceGeneration: UInt64
    public let origin: Origin

    public init(
        imageURL: URL,
        imageScaling: DesktopImageScaling? = nil,
        detectedAt: Date,
        spaceGeneration: UInt64,
        origin: Origin
    ) {
        self.imageURL = imageURL
        self.imageScaling = imageScaling
        self.detectedAt = detectedAt
        self.spaceGeneration = spaceGeneration
        self.origin = origin
    }
}

/// How the coordinator treats a wallpaper it did not write.
public enum DesktopManualSelectionPolicy: String, Hashable, Sendable, Codable {
    /// Any observed wallpaper that Daybreak never wrote is treated as a user
    /// choice and preserved until the user assigns a new target, explicitly
    /// clears protection, confirms an overwrite, or removes the assignment.
    /// This also applies before the first successful write, so a display with
    /// an existing unknown wallpaper is never overwritten by automation just
    /// because Daybreak has no write history for it.
    ///
    /// This is a heuristic: public APIs do not say who changed the wallpaper.
    /// Daybreak-managed files are recognised by URL, so an image Daybreak wrote
    /// earlier (including in another Space) is not protected as a user choice.
    case protectManualSelections

    /// The desired wallpaper wins on every accessible Space at the next event.
    case replaceManualSelections
}

/// Bounded exponential retry settings.
public struct DesktopRetryPolicy: Hashable, Sendable {
    public static let `default` = DesktopRetryPolicy()

    /// Number of retries after the initial failed attempt. Zero disables
    /// automatic retries.
    public let maximumRetryCount: Int
    public let initialDelay: TimeInterval
    public let multiplier: Double
    public let maximumDelay: TimeInterval

    public init(
        maximumRetryCount: Int = 3,
        initialDelay: TimeInterval = 2,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 30
    ) {
        self.maximumRetryCount = max(0, maximumRetryCount)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
    }

    /// One-based retry number: retry 1 uses `initialDelay`.
    public func delay(forRetryNumber retryNumber: Int) -> TimeInterval {
        guard retryNumber > 0 else { return 0 }
        guard initialDelay > 0 else { return 0 }
        var delay = initialDelay
        if retryNumber > 1 {
            for _ in 1..<retryNumber {
                if delay >= maximumDelay { break }
                delay = min(delay * multiplier, maximumDelay)
            }
        }
        return delay
    }
}

public struct DesktopCoordinatorConfiguration: Hashable, Sendable {
    public static let `default` = DesktopCoordinatorConfiguration()

    public let manualSelectionPolicy: DesktopManualSelectionPolicy
    public let retryPolicy: DesktopRetryPolicy

    public init(
        manualSelectionPolicy: DesktopManualSelectionPolicy = .protectManualSelections,
        retryPolicy: DesktopRetryPolicy = .default
    ) {
        self.manualSelectionPolicy = manualSelectionPolicy
        self.retryPolicy = retryPolicy
    }
}

// MARK: - Retry scheduling boundary

/// Cancellation token returned by a retry scheduler.
public struct DesktopRetryCancellation: Sendable {
    private let handler: @Sendable () -> Void

    public init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    public func cancel() {
        handler()
    }

    public static let none = DesktopRetryCancellation {}
}

/// Injectable delay scheduling so coordinator tests remain deterministic.
///
/// Implementations must not run `operation` synchronously from `schedule`;
/// they may run it later or never.
public protocol DesktopRetryScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) -> DesktopRetryCancellation
}

/// Production scheduler backed by a detached sleep task.
public struct TaskDesktopRetryScheduler: DesktopRetryScheduling {
    public init() {}

    public func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) -> DesktopRetryCancellation {
        let clamped = max(0, delay)
        let task = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .seconds(clamped))
            } catch {
                return
            }
            await operation()
        }
        return DesktopRetryCancellation {
            task.cancel()
        }
    }
}

// MARK: - Observable state and reports

public enum DesktopDisplayStatus: String, Hashable, Sendable, Codable {
    /// No desired wallpaper is configured.
    case unassigned
    /// A target exists but the display has not been reconciled yet.
    case pending
    /// The observed wallpaper already matches the target.
    case synchronized
    /// Automation is paused because a manual selection is protected.
    case manualProtection
    /// The last attempt failed and a retry is scheduled or due.
    case retrying
    /// The last attempt failed and automatic retries are exhausted, or the
    /// failure is not retryable.
    case failed
    /// A target is retained for a display that is not connected.
    case disconnected
}

public enum DesktopScalingSource: String, Hashable, Sendable, Codable {
    /// The backend reported the display's actual scaling in the latest
    /// snapshot. This is the only value that proves the system options.
    case observedByBackend
    /// The backend cannot report options; the value is the scaling of
    /// Daybreak's last successful write. It is known because Daybreak set it,
    /// not because the system was re-read.
    case appliedByDaybreak
    /// The image URL may match, but scaling has neither been observed nor
    /// written by this coordinator. It must not be reported as synchronized.
    case unknown
}

public struct DesktopDisplayState: Hashable, Sendable, Codable, Identifiable {
    public let displayID: DesktopDisplayID
    public let isConnected: Bool
    public let desiredWallpaper: DesktopWallpaper?
    public let observedImageURL: URL?
    /// Best known current scaling. Read `scalingSource` to know whether this
    /// was observed from the system or inferred from Daybreak's last write.
    public let currentScaling: DesktopImageScaling?
    public let scalingSource: DesktopScalingSource
    public let lastSuccessfulApply: DesktopAppliedWallpaper?
    public let manualProtection: DesktopManualProtection?
    public let failure: DesktopFailure?
    public let consecutiveFailureCount: Int
    public let nextRetryAt: Date?
    public let lastReconciledSpaceGeneration: UInt64?
    public let status: DesktopDisplayStatus

    public init(
        displayID: DesktopDisplayID,
        isConnected: Bool,
        desiredWallpaper: DesktopWallpaper? = nil,
        observedImageURL: URL? = nil,
        currentScaling: DesktopImageScaling? = nil,
        scalingSource: DesktopScalingSource = .unknown,
        lastSuccessfulApply: DesktopAppliedWallpaper? = nil,
        manualProtection: DesktopManualProtection? = nil,
        failure: DesktopFailure? = nil,
        consecutiveFailureCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastReconciledSpaceGeneration: UInt64? = nil,
        status: DesktopDisplayStatus
    ) {
        self.displayID = displayID
        self.isConnected = isConnected
        self.desiredWallpaper = desiredWallpaper
        self.observedImageURL = observedImageURL
        self.currentScaling = currentScaling
        self.scalingSource = scalingSource
        self.lastSuccessfulApply = lastSuccessfulApply
        self.manualProtection = manualProtection
        self.failure = failure
        self.consecutiveFailureCount = consecutiveFailureCount
        self.nextRetryAt = nextRetryAt
        self.lastReconciledSpaceGeneration = lastReconciledSpaceGeneration
        self.status = status
    }

    public var id: DesktopDisplayID { displayID }
}

public enum DesktopDisplayAction: String, Hashable, Sendable, Codable {
    /// The backend accepted the write. This is not proof that every Space was
    /// updated; only the accessible desktop is addressed by public APIs.
    case applied
    case alreadySynchronized
    /// An observed wallpaper Daybreak never wrote was protected this pass.
    case manualProtectionDetected
    /// Protection existed before this pass.
    case alreadyProtected
    case unassigned
    case disconnected
    /// A retry is pending; the backoff deadline has not arrived.
    case deferredRetry
    /// The attempt failed or was skipped because retries are exhausted.
    case failed
}

public struct DesktopDisplayOutcome: Hashable, Sendable, Codable {
    public let displayID: DesktopDisplayID
    public let action: DesktopDisplayAction
    public let status: DesktopDisplayStatus
    public let failure: DesktopFailure?
    /// Delay of the retry scheduled by this pass, if any.
    public let retryDelay: TimeInterval?

    public init(
        displayID: DesktopDisplayID,
        action: DesktopDisplayAction,
        status: DesktopDisplayStatus,
        failure: DesktopFailure? = nil,
        retryDelay: TimeInterval? = nil
    ) {
        self.displayID = displayID
        self.action = action
        self.status = status
        self.failure = failure
        self.retryDelay = retryDelay
    }

    public var retryScheduled: Bool { retryDelay != nil }
}

public struct DesktopReconcileReport: Hashable, Sendable, Codable {
    public let trigger: DesktopEvent
    public let spaceGeneration: UInt64
    public let startedAt: Date
    public let finishedAt: Date
    public let outcomes: [DesktopDisplayOutcome]
    public let topologyFailure: DesktopFailure?
    /// Number of additional events merged into this pass while it was running.
    public let coalescedTriggerCount: Int

    public init(
        trigger: DesktopEvent,
        spaceGeneration: UInt64,
        startedAt: Date,
        finishedAt: Date,
        outcomes: [DesktopDisplayOutcome],
        topologyFailure: DesktopFailure? = nil,
        coalescedTriggerCount: Int = 0
    ) {
        self.trigger = trigger
        self.spaceGeneration = spaceGeneration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
        self.topologyFailure = topologyFailure
        self.coalescedTriggerCount = coalescedTriggerCount
    }

    public var appliedDisplayIDs: [DesktopDisplayID] {
        outcomes.filter { $0.action == .applied }.map(\.displayID)
    }

    public var didApplyWallpaper: Bool {
        outcomes.contains { $0.action == .applied }
    }
}

public struct DesktopCoordinatorState: Hashable, Sendable, Codable {
    public let assignments: [DesktopDisplayAssignment]
    public let displays: [DesktopDisplayState]
    public let spaceGeneration: UInt64
    public let screensHaveSeparateSpaces: Bool
    public let lastTopologyFailure: DesktopFailure?
    public let lastReport: DesktopReconcileReport?
    public let isReconciling: Bool
    /// Events currently coalesced behind the running reconciliation.
    public let queuedReconciliationCount: Int

    public init(
        assignments: [DesktopDisplayAssignment] = [],
        displays: [DesktopDisplayState] = [],
        spaceGeneration: UInt64 = 0,
        screensHaveSeparateSpaces: Bool = false,
        lastTopologyFailure: DesktopFailure? = nil,
        lastReport: DesktopReconcileReport? = nil,
        isReconciling: Bool = false,
        queuedReconciliationCount: Int = 0
    ) {
        self.assignments = assignments
        self.displays = displays
        self.spaceGeneration = spaceGeneration
        self.screensHaveSeparateSpaces = screensHaveSeparateSpaces
        self.lastTopologyFailure = lastTopologyFailure
        self.lastReport = lastReport
        self.isReconciling = isReconciling
        self.queuedReconciliationCount = queuedReconciliationCount
    }

    public func displayState(for displayID: DesktopDisplayID) -> DesktopDisplayState? {
        displays.first { $0.displayID == displayID }
    }

    public func assignment(for displayID: DesktopDisplayID) -> DesktopDisplayAssignment? {
        assignments.first { $0.displayID == displayID }
    }
}

// MARK: - Events

public enum DesktopEvent: Hashable, Sendable, Codable {
    case initial
    /// Direct user intent, including a newly assigned target.
    case manualRequest
    /// The accessible desktop changed. Only the now-visible Space can be
    /// reconciled; inactive Spaces are not addressable with public APIs.
    case spaceDidChange
    case displayConfigurationChanged
    case systemWake
    case userLogin
    case networkAvailable
    case retry(displayID: DesktopDisplayID)
}

extension DesktopEvent {
    fileprivate func isRetry(for displayID: DesktopDisplayID) -> Bool {
        if case .retry(let target) = self {
            return target == displayID
        }
        return false
    }

    /// Explicit or system-level recovery events grant a fresh retry budget.
    /// Space notifications do not, so rapid Space switching cannot bypass
    /// bounded backoff.
    fileprivate var resetsFailureBudgetForEveryDisplay: Bool {
        switch self {
        case .manualRequest, .systemWake, .userLogin, .networkAvailable:
            return true
        case .initial, .spaceDidChange, .displayConfigurationChanged, .retry:
            return false
        }
    }
}

// MARK: - Coordinator

/// Event-driven, platform-neutral coordinator for per-display wallpaper
/// intent.
///
/// Responsibilities:
/// - keep a desired wallpaper per stable display identity;
/// - reconcile the accessible desktop on Space, display, wake, login and
///   network events;
/// - restore targets when a display reconnects;
/// - preserve a detected manual selection according to policy;
/// - coalesce bursts of events and avoid duplicate writes;
/// - retry only bounded, classified failures with deterministic backoff.
///
/// It never polls, never uses private APIs and never claims that inactive
/// Spaces were updated. All system access is behind `DesktopPlatformBackend`.
public actor DesktopCoordinator {
    private struct DisplayRuntime {
        var isConnected = false
        var observedImageURL: URL?
        var currentScaling: DesktopImageScaling?
        var scalingSource: DesktopScalingSource = .unknown
        var lastSuccessfulApply: DesktopAppliedWallpaper?
        var manualProtection: DesktopManualProtection?
        var failure: DesktopFailure?
        var consecutiveFailureCount = 0
        var nextRetryAt: Date?
        var lastReconciledSpaceGeneration: UInt64?
        var retryToken: UUID?
        var retryCancellation: DesktopRetryCancellation?
        /// Set by an explicit assignment or an explicit protection release.
        /// Until the next successful write, an unmanaged observed wallpaper is
        /// not reclassified as a manual selection.
        var adoptsUnmanagedWallpaper = false
    }

    private let backend: any DesktopPlatformBackend
    private let configuration: DesktopCoordinatorConfiguration
    private let retryScheduler: any DesktopRetryScheduling
    private let now: @Sendable () -> Date

    private var assignments: [DesktopDisplayID: DesktopWallpaper]
    private var runtimeByDisplay: [DesktopDisplayID: DisplayRuntime] = [:]
    /// Every URL Daybreak successfully handed to the platform layer. Used only
    /// to distinguish a stale Daybreak wallpaper from an unmanaged one.
    private var managedImageURLs: Set<URL> = []
    /// Explicit assignments for displays no topology pass has observed yet.
    /// The authorisation is applied when the runtime is created so the public
    /// state stays `.pending` instead of pretending the display is
    /// disconnected. Only an explicit assignment can add an entry.
    private var pendingUnmanagedAdoptions: Set<DesktopDisplayID> = []

    private var spaceGeneration: UInt64 = 0
    private var screensHaveSeparateSpaces = false
    private var lastTopologyFailure: DesktopFailure?
    private var lastReport: DesktopReconcileReport?

    private var isReconciling = false
    private var pendingTrigger: DesktopEvent?
    private var pendingTriggerCount = 0
    private var reconcileWaiters: [CheckedContinuation<DesktopReconcileReport, Never>] = []
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        backend: any DesktopPlatformBackend,
        configuration: DesktopCoordinatorConfiguration = .default,
        initialAssignments: [DesktopDisplayID: DesktopWallpaper] = [:],
        managedImageURLs: Set<URL> = [],
        retryScheduler: any DesktopRetryScheduling = TaskDesktopRetryScheduler(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.configuration = configuration
        self.assignments = initialAssignments
        self.managedImageURLs = managedImageURLs
        self.retryScheduler = retryScheduler
        self.now = now
    }

    // MARK: Observation

    /// Current in-memory state. Does not perform system I/O.
    public func state() -> DesktopCoordinatorState {
        coordinatorState()
    }

    // MARK: Assignment

    /// Assigns one target and immediately reconciles. An explicit assignment
    /// overrides an existing manual protection and authorises overwriting the
    /// currently observed unmanaged wallpaper.
    @discardableResult
    public func assign(
        _ wallpaper: DesktopWallpaper,
        to displayID: DesktopDisplayID
    ) async -> DesktopReconcileReport {
        await assign([displayID: wallpaper])
    }

    /// Updates several targets atomically and reconciles once. Assignments not
    /// present in the dictionary are retained.
    ///
    /// `reconcilingOnly` restricts which displays this call may reconcile and
    /// write. A display whose target is retained but outside the scope is not
    /// contacted at all, so a user-authorised write for one display can never
    /// pause on, or blame, another display. Events coalesced into this call
    /// inherit the same scope; callers that need an unscoped catch-up pass must
    /// request one afterwards.
    @discardableResult
    public func assign(
        _ assignments: [DesktopDisplayID: DesktopWallpaper],
        reconcilingOnly displayIDs: Set<DesktopDisplayID>? = nil
    ) async -> DesktopReconcileReport {
        await waitForIdleReconciliation()
        for (displayID, wallpaper) in assignments {
            self.assignments[displayID] = wallpaper
            prepareForExplicitAssignment(displayID)
        }
        // The unmanaged-adoption authorization is valid for this explicit pass
        // only. `run` revokes it after the first pass, including coalesced
        // event passes and topology/write failures.
        return await run(
            .manualRequest,
            reconcilingOnly: displayIDs,
            explicitAdoptionScope: Set(assignments.keys)
        )
    }

    /// Removes a target. A connected display becomes unassigned; a disconnected
    /// display is forgotten on the next reconciliation.
    @discardableResult
    public func removeAssignment(for displayID: DesktopDisplayID) async -> DesktopCoordinatorState {
        await waitForIdleReconciliation()
        assignments[displayID] = nil
        pendingUnmanagedAdoptions.remove(displayID)
        if var runtime = runtimeByDisplay[displayID] {
            clearFailureState(&runtime)
            runtime.manualProtection = nil
            runtime.adoptsUnmanagedWallpaper = false
            runtimeByDisplay[displayID] = runtime
        }
        pruneRuntime()
        return coordinatorState()
    }

    // MARK: Manual protection

    /// Protects the wallpaper currently observed for a display. This only uses
    /// the last successful snapshot; call a reconciliation event first if the
    /// UI state may be stale.
    @discardableResult
    public func protectCurrentWallpaper(for displayID: DesktopDisplayID) async -> DesktopCoordinatorState {
        await waitForIdleReconciliation()
        guard var runtime = runtimeByDisplay[displayID],
              runtime.isConnected,
              let observed = runtime.observedImageURL
        else {
            return coordinatorState()
        }
        runtime.manualProtection = DesktopManualProtection(
            imageURL: observed,
            imageScaling: runtime.scalingSource == .observedByBackend ? runtime.currentScaling : nil,
            detectedAt: now(),
            spaceGeneration: spaceGeneration,
            origin: .explicitlyRequested
        )
        clearFailureState(&runtime)
        runtime.adoptsUnmanagedWallpaper = false
        runtimeByDisplay[displayID] = runtime
        return coordinatorState()
    }

    /// Releases protection and immediately reconciles so automation resumes.
    @discardableResult
    public func clearManualProtection(for displayID: DesktopDisplayID) async -> DesktopReconcileReport {
        await waitForIdleReconciliation()
        if var runtime = runtimeByDisplay[displayID] {
            runtime.manualProtection = nil
            runtime.adoptsUnmanagedWallpaper = true
            runtimeByDisplay[displayID] = runtime
        }
        // Releasing protection is a one-pass explicit action. If that pass
        // fails, the disable/enable authorization must not leak into the next
        // event.
        return await run(
            .manualRequest,
            reconcilingOnly: nil,
            explicitAdoptionScope: [displayID]
        )
    }

    // MARK: Events

    /// Handles one platform or user event.
    ///
    /// Events that arrive while a pass is running are merged into a single
    /// follow-up pass. All waiting callers receive the report of the pass that
    /// incorporated their event.
    @discardableResult
    public func handle(_ event: DesktopEvent) async -> DesktopReconcileReport {
        await run(event, reconcilingOnly: nil, explicitAdoptionScope: [])
    }

    /// Shared event loop. A scoped run keeps its scope for coalesced passes so
    /// a space or display event cannot widen a deliberate one-display write
    /// into an all-display pass while the same write gate is open.
    private func run(
        _ event: DesktopEvent,
        reconcilingOnly: Set<DesktopDisplayID>?,
        explicitAdoptionScope: Set<DesktopDisplayID>
    ) async -> DesktopReconcileReport {
        if case .spaceDidChange = event {
            spaceGeneration &+= 1
            // Changing the accessible Space cancels any one-pass authorization
            // to replace an unmanaged wallpaper. A later event must re-prove
            // the user's intent.
            revokeExplicitAdoptions()
        }

        if isReconciling {
            pendingTrigger = Self.merged(pendingTrigger, event)
            pendingTriggerCount += 1
            return await withCheckedContinuation { continuation in
                reconcileWaiters.append(continuation)
            }
        }

        isReconciling = true
        var report = await performPass(
            trigger: event,
            coalescedTriggerCount: 0,
            reconcilingOnly: reconcilingOnly
        )
        // Scope the authorization to the pass that consumed the explicit
        // assignment. A failure, an empty topology or a coalesced event must
        // never inherit it.
        revokeExplicitAdoptions(explicitAdoptionScope)

        while let next = pendingTrigger {
            let coalesced = pendingTriggerCount
            pendingTrigger = nil
            pendingTriggerCount = 0
            let waiters = reconcileWaiters
            reconcileWaiters.removeAll()
            report = await performPass(
                trigger: next,
                coalescedTriggerCount: coalesced,
                reconcilingOnly: reconcilingOnly
            )
            for waiter in waiters {
                waiter.resume(returning: report)
            }
        }

        isReconciling = false
        let mutations = mutationWaiters
        mutationWaiters.removeAll()
        for waiter in mutations {
            waiter.resume()
        }
        return report
    }

    // MARK: Pass implementation

    private func performPass(
        trigger: DesktopEvent,
        coalescedTriggerCount: Int,
        reconcilingOnly: Set<DesktopDisplayID>?
    ) async -> DesktopReconcileReport {
        let startedAt = now()
        let generation = spaceGeneration

        let topology: DesktopTopology
        do {
            topology = try await backend.readTopology()
        } catch {
            let failure = normalizedFailure(error, stage: .readingDisplays)
            lastTopologyFailure = failure
            let report = DesktopReconcileReport(
                trigger: trigger,
                spaceGeneration: generation,
                startedAt: startedAt,
                finishedAt: now(),
                outcomes: [],
                topologyFailure: failure,
                coalescedTriggerCount: coalescedTriggerCount
            )
            lastReport = report
            return report
        }

        lastTopologyFailure = nil
        screensHaveSeparateSpaces = topology.screensHaveSeparateSpaces
        let newlyConnected = updateConnectivity(with: topology)

        var outcomes: [DesktopDisplayOutcome] = []
        var displayIDs = Set(assignments.keys).union(runtimeByDisplay.keys).sorted()
        if let reconcilingOnly {
            displayIDs = displayIDs.filter { reconcilingOnly.contains($0) }
        }
        for displayID in displayIDs {
            if let outcome = await reconcileDisplay(
                displayID,
                trigger: trigger,
                generation: generation,
                newlyConnected: newlyConnected
            ) {
                outcomes.append(outcome)
            }
        }
        pruneRuntime()

        let report = DesktopReconcileReport(
            trigger: trigger,
            spaceGeneration: generation,
            startedAt: startedAt,
            finishedAt: now(),
            outcomes: outcomes,
            topologyFailure: nil,
            coalescedTriggerCount: coalescedTriggerCount
        )
        lastReport = report
        return report
    }

    /// Updates connection state. Returns displays that were not connected
    /// before this snapshot.
    @discardableResult
    private func updateConnectivity(with topology: DesktopTopology) -> Set<DesktopDisplayID> {
        var snapshots: [DesktopDisplayID: DesktopDisplaySnapshot] = [:]
        for snapshot in topology.displays {
            // A duplicate identity is a backend contract violation. Keep the
            // last value deterministically instead of writing twice.
            snapshots[snapshot.displayID] = snapshot
        }

        let previouslyConnected = Set(
            runtimeByDisplay.compactMap { displayID, runtime in
                runtime.isConnected ? displayID : nil
            }
        )

        for displayID in Array(runtimeByDisplay.keys) {
            runtimeByDisplay[displayID]?.isConnected = false
        }

        var newlyConnected: Set<DesktopDisplayID> = []
        for displayID in snapshots.keys.sorted() {
            guard let snapshot = snapshots[displayID] else { continue }
            let hadRuntime = runtimeByDisplay[displayID] != nil
            var runtime = runtimeByDisplay[displayID] ?? DisplayRuntime()
            if !hadRuntime, pendingUnmanagedAdoptions.remove(displayID) != nil {
                runtime.adoptsUnmanagedWallpaper = true
            }
            let wasConnected = previouslyConnected.contains(displayID)
            if !wasConnected {
                newlyConnected.insert(displayID)
                clearFailureState(&runtime)
            }
            runtime.isConnected = true
            runtime.observedImageURL = snapshot.currentImageURL
            if let reportedScaling = snapshot.reportedScaling {
                runtime.currentScaling = reportedScaling
                runtime.scalingSource = .observedByBackend
            } else if let lastApplied = runtime.lastSuccessfulApply,
                      snapshot.currentImageURL == lastApplied.wallpaper.imageURL {
                // Only fall back to our own write parameters when the observed
                // image is still the exact image we wrote. A different image
                // has unknown options even if the URL alone matches the target.
                runtime.currentScaling = lastApplied.wallpaper.scaling
                runtime.scalingSource = .appliedByDaybreak
            } else {
                runtime.currentScaling = nil
                runtime.scalingSource = .unknown
            }
            runtimeByDisplay[displayID] = runtime
        }

        for displayID in Array(runtimeByDisplay.keys) {
            guard let runtime = runtimeByDisplay[displayID], !runtime.isConnected else { continue }
            cancelPendingRetry(for: displayID)
        }

        // Retain targets for displays that are currently absent.
        for displayID in assignments.keys where runtimeByDisplay[displayID] == nil {
            var runtime = DisplayRuntime()
            if pendingUnmanagedAdoptions.remove(displayID) != nil {
                runtime.adoptsUnmanagedWallpaper = true
            }
            runtimeByDisplay[displayID] = runtime
        }

        return newlyConnected
    }

    private func isSynchronized(
        observedURL: URL?,
        runtime: DisplayRuntime,
        desired: DesktopWallpaper
    ) -> Bool {
        guard observedURL == desired.imageURL else { return false }
        switch runtime.scalingSource {
        case .observedByBackend, .appliedByDaybreak:
            return runtime.currentScaling == desired.scaling
        case .unknown:
            // The image matches but options were neither observed nor written.
            // Do not claim the target is applied; one write establishes them.
            return false
        }
    }

    /// Conservative manual-change detection. It never treats an unverified
    /// scaling value as a user choice.
    private func currentWallpaperWasChangedOutsideDaybreak(
        observedURL: URL?,
        runtime: DisplayRuntime,
        desired: DesktopWallpaper
    ) -> Bool {
        guard configuration.manualSelectionPolicy == .protectManualSelections,
              !runtime.adoptsUnmanagedWallpaper,
              let observedURL
        else {
            return false
        }

        if observedURL != desired.imageURL {
            return !managedImageURLs.contains(observedURL)
        }

        // Same image with externally changed options: only knowable when the
        // backend reported them and Daybreak had written exactly this target.
        return runtime.scalingSource == .observedByBackend
            && runtime.currentScaling != desired.scaling
            && runtime.lastSuccessfulApply?.wallpaper == desired
    }

    private func reconcileDisplay(
        _ displayID: DesktopDisplayID,
        trigger: DesktopEvent,
        generation: UInt64,
        newlyConnected: Set<DesktopDisplayID>
    ) async -> DesktopDisplayOutcome? {
        guard let wallpaper = assignments[displayID] else {
            guard let runtime = runtimeByDisplay[displayID] else { return nil }
            if !runtime.isConnected {
                return DesktopDisplayOutcome(
                    displayID: displayID,
                    action: .disconnected,
                    status: .disconnected
                )
            }
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .unassigned,
                status: .unassigned
            )
        }

        guard var runtime = runtimeByDisplay[displayID], runtime.isConnected else {
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .disconnected,
                status: .disconnected
            )
        }

        let observed = runtime.observedImageURL
        let retryAttempt = trigger.isRetry(for: displayID)
        let resetBudget = trigger.resetsFailureBudgetForEveryDisplay

        if isSynchronized(observedURL: observed, runtime: runtime, desired: wallpaper) {
            clearFailureState(&runtime)
            runtime.manualProtection = nil
            runtime.adoptsUnmanagedWallpaper = false
            runtime.lastReconciledSpaceGeneration = generation
            runtimeByDisplay[displayID] = runtime
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .alreadySynchronized,
                status: .synchronized
            )
        }

        if resetBudget {
            clearFailureState(&runtime)
        }

        if let protection = runtime.manualProtection {
            let observedScaling = runtime.scalingSource == .observedByBackend
                ? runtime.currentScaling
                : nil
            // Keep the recorded observation equal to the currently accessible
            // desktop. Public APIs cannot enumerate Spaces, so a different Space
            // legitimately changes this wallpaper; a stale record would make
            // the confirmation flow fail with "changed again" forever. Updating
            // the record never authorises a write and never clears protection.
            if let observed,
               protection.imageURL != observed || protection.imageScaling != observedScaling {
                runtime.manualProtection = DesktopManualProtection(
                    imageURL: observed,
                    imageScaling: observedScaling,
                    detectedAt: protection.detectedAt,
                    spaceGeneration: protection.spaceGeneration,
                    origin: protection.origin
                )
            }
            runtime.lastReconciledSpaceGeneration = generation
            runtimeByDisplay[displayID] = runtime
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .alreadyProtected,
                status: .manualProtection
            )
        }

        if currentWallpaperWasChangedOutsideDaybreak(
            observedURL: observed,
            runtime: runtime,
            desired: wallpaper
        ) {
            runtime.manualProtection = DesktopManualProtection(
                imageURL: observed ?? wallpaper.imageURL,
                imageScaling: runtime.scalingSource == .observedByBackend ? runtime.currentScaling : nil,
                detectedAt: now(),
                spaceGeneration: generation,
                origin: .detectedExternalChange
            )
            clearFailureState(&runtime)
            runtime.lastReconciledSpaceGeneration = generation
            runtimeByDisplay[displayID] = runtime
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .manualProtectionDetected,
                status: .manualProtection
            )
        }

        let currentTime = now()
        if let failure = runtime.failure {
            if resetBudget || retryAttempt {
                // Allowed to attempt; a retry fired by the scheduler has
                // already marked its deadline as due.
            } else if let due = runtime.nextRetryAt {
                if currentTime < due {
                    runtime.lastReconciledSpaceGeneration = generation
                    runtimeByDisplay[displayID] = runtime
                    return DesktopDisplayOutcome(
                        displayID: displayID,
                        action: .deferredRetry,
                        status: .retrying,
                        failure: failure
                    )
                }
            } else {
                // Non-retryable failure, or retry budget exhausted.
                runtime.lastReconciledSpaceGeneration = generation
                runtimeByDisplay[displayID] = runtime
                return DesktopDisplayOutcome(
                    displayID: displayID,
                    action: .failed,
                    status: .failed,
                    failure: failure
                )
            }
        }

        // From here this pass is the only writer for the display and mutators
        // are held behind the active reconciliation.
        cancelPendingRetry(for: displayID)
        runtime = runtimeByDisplay[displayID] ?? runtime
        runtime.failure = nil

        do {
            try await backend.applyWallpaper(wallpaper, to: displayID)
            runtime.observedImageURL = wallpaper.imageURL
            runtime.currentScaling = wallpaper.scaling
            runtime.scalingSource = .appliedByDaybreak
            runtime.lastSuccessfulApply = DesktopAppliedWallpaper(
                wallpaper: wallpaper,
                appliedAt: now(),
                spaceGeneration: generation
            )
            clearFailureState(&runtime)
            runtime.manualProtection = nil
            runtime.adoptsUnmanagedWallpaper = false
            runtime.lastReconciledSpaceGeneration = generation
            managedImageURLs.insert(wallpaper.imageURL)
            runtimeByDisplay[displayID] = runtime
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .applied,
                status: .synchronized
            )
        } catch {
            let failure = normalizedFailure(error, stage: .applyingWallpaper)
            runtime.failure = failure
            runtime.consecutiveFailureCount += 1
            let delay = scheduleRetryIfNeeded(
                for: displayID,
                runtime: &runtime,
                failure: failure,
                at: currentTime
            )
            runtime.lastReconciledSpaceGeneration = generation
            runtimeByDisplay[displayID] = runtime
            return DesktopDisplayOutcome(
                displayID: displayID,
                action: .failed,
                status: delay == nil ? .failed : .retrying,
                failure: failure,
                retryDelay: delay
            )
        }
    }

    // MARK: Retry

    private func scheduleRetryIfNeeded(
        for displayID: DesktopDisplayID,
        runtime: inout DisplayRuntime,
        failure: DesktopFailure,
        at currentTime: Date
    ) -> TimeInterval? {
        guard failure.isRetryable,
              runtime.consecutiveFailureCount <= configuration.retryPolicy.maximumRetryCount
        else {
            runtime.nextRetryAt = nil
            runtime.retryToken = nil
            runtime.retryCancellation = nil
            return nil
        }

        let delay = configuration.retryPolicy.delay(forRetryNumber: runtime.consecutiveFailureCount)
        let token = UUID()
        runtime.retryCancellation?.cancel()
        runtime.retryToken = token
        runtime.nextRetryAt = currentTime.addingTimeInterval(delay)
        runtime.retryCancellation = retryScheduler.schedule(after: delay) { [weak self] in
            await self?.scheduledRetryFired(displayID: displayID, token: token)
        }
        return delay
    }

    private func scheduledRetryFired(displayID: DesktopDisplayID, token: UUID) async {
        guard var runtime = runtimeByDisplay[displayID],
              runtime.retryToken == token
        else {
            return
        }

        runtime.retryToken = nil
        runtime.retryCancellation = nil
        // Mark the retry as due. If a pass is already running, it will pick
        // this up instead of classifying the display as terminally failed.
        runtime.nextRetryAt = now()
        runtimeByDisplay[displayID] = runtime

        guard assignments[displayID] != nil,
              runtime.isConnected,
              runtime.manualProtection == nil
        else {
            return
        }

        _ = await handle(.retry(displayID: displayID))
    }

    private func cancelPendingRetry(for displayID: DesktopDisplayID) {
        guard var runtime = runtimeByDisplay[displayID] else { return }
        runtime.retryCancellation?.cancel()
        runtime.retryCancellation = nil
        runtime.retryToken = nil
        runtime.nextRetryAt = nil
        runtimeByDisplay[displayID] = runtime
    }

    private func clearFailureState(_ runtime: inout DisplayRuntime) {
        runtime.retryCancellation?.cancel()
        runtime.retryCancellation = nil
        runtime.retryToken = nil
        runtime.failure = nil
        runtime.consecutiveFailureCount = 0
        runtime.nextRetryAt = nil
    }

    // MARK: Assignment preparation

    private func prepareForExplicitAssignment(_ displayID: DesktopDisplayID) {
        guard var runtime = runtimeByDisplay[displayID] else {
            // No topology pass has observed this display yet. Defer the
            // authorisation until the runtime exists so the observable state
            // stays `.pending` rather than becoming `.disconnected`.
            pendingUnmanagedAdoptions.insert(displayID)
            return
        }
        clearFailureState(&runtime)
        runtime.manualProtection = nil
        runtime.adoptsUnmanagedWallpaper = true
        runtimeByDisplay[displayID] = runtime
    }

    /// Ends a one-pass permission to replace an unmanaged wallpaper. Called
    /// after the explicit assignment pass and whenever the accessible Space
    /// changes. A failed write or topology read leaves the next event with the
    /// normal manual-selection protection.
    private func revokeExplicitAdoptions(
        _ displayIDs: Set<DesktopDisplayID>? = nil
    ) {
        if let displayIDs {
            pendingUnmanagedAdoptions.subtract(displayIDs)
        } else {
            pendingUnmanagedAdoptions.removeAll()
        }
        for displayID in runtimeByDisplay.keys {
            if let displayIDs, !displayIDs.contains(displayID) { continue }
            runtimeByDisplay[displayID]?.adoptsUnmanagedWallpaper = false
        }
    }

    // MARK: Waiting and coalescing

    private func waitForIdleReconciliation() async {
        while isReconciling {
            await withCheckedContinuation { continuation in
                mutationWaiters.append(continuation)
            }
        }
    }

    private static func merged(_ existing: DesktopEvent?, _ new: DesktopEvent) -> DesktopEvent {
        guard let existing else { return new }
        return priority(of: new) >= priority(of: existing) ? new : existing
    }

    private static func priority(of event: DesktopEvent) -> Int {
        switch event {
        case .manualRequest: return 6
        case .systemWake, .userLogin: return 5
        case .networkAvailable: return 4
        case .displayConfigurationChanged: return 3
        case .retry, .spaceDidChange: return 2
        case .initial: return 1
        }
    }

    // MARK: State projection

    private func pruneRuntime() {
        runtimeByDisplay = runtimeByDisplay.filter { displayID, runtime in
            runtime.isConnected || assignments[displayID] != nil
        }
    }

    private func coordinatorState() -> DesktopCoordinatorState {
        let displayIDs = Set(assignments.keys).union(runtimeByDisplay.keys).sorted()
        var displayStates: [DesktopDisplayState] = []
        displayStates.reserveCapacity(displayIDs.count)
        for displayID in displayIDs {
            let runtime = runtimeByDisplay[displayID]
            displayStates.append(
                DesktopDisplayState(
                    displayID: displayID,
                    isConnected: runtime?.isConnected ?? false,
                    desiredWallpaper: assignments[displayID],
                    observedImageURL: runtime?.observedImageURL,
                    currentScaling: runtime?.currentScaling,
                    scalingSource: runtime?.scalingSource ?? .unknown,
                    lastSuccessfulApply: runtime?.lastSuccessfulApply,
                    manualProtection: runtime?.manualProtection,
                    failure: runtime?.failure,
                    consecutiveFailureCount: runtime?.consecutiveFailureCount ?? 0,
                    nextRetryAt: runtime?.nextRetryAt,
                    lastReconciledSpaceGeneration: runtime?.lastReconciledSpaceGeneration,
                    status: displayStatus(for: displayID, runtime: runtime)
                )
            )
        }

        let assignments = self.assignments
            .map { DesktopDisplayAssignment(displayID: $0.key, wallpaper: $0.value) }
            .sorted { $0.displayID < $1.displayID }

        return DesktopCoordinatorState(
            assignments: assignments,
            displays: displayStates,
            spaceGeneration: spaceGeneration,
            screensHaveSeparateSpaces: screensHaveSeparateSpaces,
            lastTopologyFailure: lastTopologyFailure,
            lastReport: lastReport,
            isReconciling: isReconciling,
            queuedReconciliationCount: pendingTriggerCount
        )
    }

    private func displayStatus(for displayID: DesktopDisplayID, runtime: DisplayRuntime?) -> DesktopDisplayStatus {
        guard let runtime else {
            return assignments[displayID] == nil ? .unassigned : .pending
        }
        guard runtime.isConnected else { return .disconnected }
        guard let desired = assignments[displayID] else { return .unassigned }
        if runtime.manualProtection != nil { return .manualProtection }
        if isSynchronized(
            observedURL: runtime.observedImageURL,
            runtime: runtime,
            desired: desired
        ) {
            return .synchronized
        }
        if let failure = runtime.failure {
            return (failure.isRetryable && runtime.nextRetryAt != nil) ? .retrying : .failed
        }
        return .pending
    }

    private func normalizedFailure(_ error: any Error, stage: DesktopFailure.Stage) -> DesktopFailure {
        if let failure = error as? DesktopFailure {
            return failure.withStage(stage)
        }
        return DesktopFailure(stage: stage, kind: .unknown, message: String(describing: error))
    }
}
