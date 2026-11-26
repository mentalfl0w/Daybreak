import AppKit
import Combine
import DaybreakCore
import Foundation
import Observation

// MARK: - Load state

enum TodayLoadState: Equatable {
    case idle
    case loadingCache
    case empty
    case ready
    case refreshing
    case offline(message: String)
    case failed(message: String)
}

// MARK: - Dock icon visibility

/// Persisted Dock icon choice and the public activation-policy mapping that
/// applies it. Hiding the Dock icon uses `NSApplication.ActivationPolicy
/// .accessory`; the app keeps its menu bar extra and main window, so there is
/// no second UI mode to maintain. Showing it again uses `.regular`.
///
/// Applying a policy change at runtime or launch goes through
/// `MainWindowAccess`, which also keeps the on-screen main window visible and
/// focused across the transition. This type stays limited to the persisted
/// value and the raw AppKit call.
///
/// The default is visible for new and existing installs: the absence of a
/// saved preference must not hide the Dock icon for users upgrading from a
/// build that never had this setting.
enum DockIconVisibility {
    static let defaultsKey = "daybreak.showDockIcon"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? true
    }

    static func store(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    /// Pure mapping so preference behavior can be tested without changing
    /// the process-wide activation policy of the test host.
    static func activationPolicy(
        showDockIcon: Bool
    ) -> NSApplication.ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }

    /// Applies the choice immediately. Returns the API result so callers can
    /// keep the persisted value and UI state aligned with the actual policy.
    /// Re-asserting the current policy is a no-op, which matters at launch and
    /// after every external reopen event.
    @MainActor
    @discardableResult
    static func apply(showDockIcon: Bool) -> Bool {
        let policy = activationPolicy(showDockIcon: showDockIcon)
        let application = NSApplication.shared
        guard application.activationPolicy() != policy else { return true }
        return application.setActivationPolicy(policy)
    }
}

// MARK: - Automatic wallpaper target coordination

/// Stateful app-side policy for the automatic wallpaper target.
///
/// This exists so the fail-closed ordering is explicit and testable without a
/// live integration:
/// - no update without the user's current automatic opt-in;
/// - no update for an older source date than the one already targeted;
/// - no duplicate update for the same occurrence;
/// - reconciliation is requested only after a confirmed target write.
@MainActor
final class WallpaperAutoTargetCoordinator {
    struct Update: Sendable {
        /// Non-nil only when the integration was asked to update the target.
        let outcome: WallpaperAutoOutcome?
        let targetUpdated: Bool
        let didRequestReconciliation: Bool
        /// Currently accessible displays confirmed settled on this target by
        /// the reconciliation pass. Empty when no pass ran or nothing settled.
        let settledDisplayIDs: [DesktopDisplayID]
        /// True only when an update was required but could not be confirmed.
        let failed: Bool
        /// True when a newer operation or a newer content/market state took
        /// ownership while this one was awaiting the integration. Every other
        /// field is then inert: this operation withholds its outcome and
        /// settled displays so the caller cannot apply a stale outcome or
        /// notify. An integration write that already started cannot be
        /// recalled; the newer operation overwrites its target.
        let superseded: Bool

        static let superseded = Update(
            outcome: nil,
            targetUpdated: false,
            didRequestReconciliation: false,
            settledDisplayIDs: [],
            failed: false,
            superseded: true
        )
    }

    private let wallpaper: any MacWallpaperIntegrating
    private(set) var lastTargetKey: OccurrenceKey?
    private(set) var lastTargetSourceDate: LocalDate?
    private(set) var lastUpdateFailed = false
    /// Monotonic identity of the latest requested target operation. Every
    /// await in `updateIfNeeded` re-checks it, so an older operation that
    /// returns late can never overwrite newer state or reconcile a target the
    /// current content/market state no longer wants.
    private var operationGeneration = 0

    init(wallpaper: any MacWallpaperIntegrating) {
        self.wallpaper = wallpaper
    }

    /// The explicit auto-sync consent already persisted assignments for the
    /// image it showed. Recording it prevents a following refresh or original
    /// download from rewriting the same target and triggering a write right
    /// after the user opted in.
    func recordConsentTarget(key: OccurrenceKey, sourceDate: LocalDate) {
        recordPersistedTarget(key: key, sourceDate: sourceDate)
    }

    /// Target intent persisted outside the normal target-update path, for
    /// example when a newly connected display adopts the current target.
    func recordPersistedTarget(key: OccurrenceKey, sourceDate: LocalDate) {
        lastTargetKey = key
        lastTargetSourceDate = sourceDate
        lastUpdateFailed = false
    }

    func reset() {
        // Invalidate an operation still awaiting the integration so a target
        // write that returns after a market switch or opt-out cannot restore
        // stale coordinator state or start another reconciliation. A write
        // already running inside the integration cannot be recalled.
        operationGeneration &+= 1
        lastTargetKey = nil
        lastTargetSourceDate = nil
        lastUpdateFailed = false
    }

    func updateIfNeeded(
        for payload: TodayPayload,
        autoSyncEnabled: Bool,
        isUpdatingAutomation: Bool,
        requiresDisableRetry: Bool,
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> Update {
        guard autoSyncEnabled, !isUpdatingAutomation, !requiresDisableRetry else {
            lastUpdateFailed = false
            return Update(
                outcome: nil,
                targetUpdated: false,
                didRequestReconciliation: false,
                settledDisplayIDs: [],
                failed: false,
                superseded: false
            )
        }
        guard let imageURL = payload.originalURL else {
            lastUpdateFailed = true
            return Update(
                outcome: nil,
                targetUpdated: false,
                didRequestReconciliation: false,
                settledDisplayIDs: [],
                failed: true,
                superseded: false
            )
        }
        // A cached payload or a late original download must never move the
        // automatic target back to an older source date.
        if let lastTargetSourceDate, payload.sourceDate < lastTargetSourceDate {
            lastUpdateFailed = false
            return Update(
                outcome: nil,
                targetUpdated: false,
                didRequestReconciliation: false,
                settledDisplayIDs: [],
                failed: false,
                superseded: false
            )
        }
        if lastTargetKey == payload.key {
            lastUpdateFailed = false
            return Update(
                outcome: nil,
                targetUpdated: false,
                didRequestReconciliation: false,
                settledDisplayIDs: [],
                failed: false,
                superseded: false
            )
        }

        // Only an operation that may actually write becomes the newest intent.
        // A no-op duplicate must not cancel an in-flight reconciliation for
        // the occurrence it duplicates.
        operationGeneration &+= 1
        let generation = operationGeneration

        // The content/market state may already have changed before the first
        // await; never start a write for a target that is no longer wanted.
        guard generation == operationGeneration, isCurrent() else {
            return Update.superseded
        }

        let outcome = await wallpaper.updateAutoTarget(imageURL: imageURL)
        // A market switch, opt-out, or newer operation may have landed while
        // the integration was writing. The write itself cannot be recalled,
        // but this operation must not claim it: leaving coordinator state
        // unpersisted lets the latest operation run and supersede it.
        guard generation == operationGeneration, isCurrent() else {
            return Update.superseded
        }
        guard outcome.targetUpdated else {
            lastUpdateFailed = true
            return Update(
                outcome: outcome,
                targetUpdated: false,
                didRequestReconciliation: false,
                settledDisplayIDs: [],
                failed: true,
                superseded: false
            )
        }

        lastTargetKey = payload.key
        lastTargetSourceDate = max(
            lastTargetSourceDate ?? payload.sourceDate,
            payload.sourceDate
        )
        lastUpdateFailed = false

        // A target saved while the gate closed is not reconciled: nothing may
        // write until a fresh opt-in reopens the gate.
        guard outcome.enabled else {
            return Update(
                outcome: outcome,
                targetUpdated: true,
                didRequestReconciliation: false,
                settledDisplayIDs: [],
                failed: false,
                superseded: false
            )
        }
        // Re-check at the reconciliation boundary: the persisted target state
        // alone is safe to keep only until a newer operation owns the state.
        guard generation == operationGeneration, isCurrent() else {
            return Update.superseded
        }
        let settledDisplayIDs = await wallpaper.requestReconciliation(
            expectedImageURL: imageURL
        )
        // A reconciliation is an actual wallpaper write. If the market or
        // content changed while it ran, its settled displays describe the
        // stale target and must not be reported as a current confirmation.
        guard generation == operationGeneration, isCurrent() else {
            return Update.superseded
        }
        return Update(
            outcome: outcome,
            targetUpdated: true,
            didRequestReconciliation: true,
            settledDisplayIDs: settledDisplayIDs,
            failed: false,
            superseded: false
        )
    }
}

// MARK: - Folder sync plumbing

/// Market read by the sync scope provider.
///
/// `DaybreakSyncController` stores its provider as `@Sendable`, while the app
/// selects a market on the main actor at runtime. A small locked value keeps
/// that hand-off total and race-free without capturing the app model.
final class SyncMarketContext: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMarket: Market

    init(_ market: Market) {
        self.storedMarket = market
    }

    var market: Market {
        get { lock.withLock { storedMarket } }
        set { lock.withLock { storedMarket = newValue } }
    }
}

// MARK: - Daily automatic refresh schedule

/// Pure scheduling rules for one automatic refresh per market-local day.
///
/// Bing publishes per market, so the boundary and the post-midnight grace use
/// the selected market's time zone, not the device time zone. An explicit
/// persisted auto-sync opt-in resumes after launch; there is no implicit
/// opt-in on a fresh install.
enum WallpaperDailyRefreshPolicy {
    /// Publisher data usually appears shortly after local midnight. A grace
    /// period avoids repeatedly fetching yesterday's occurrence.
    static let publishGrace: TimeInterval = 5 * 60
    /// Retry cadence when the new day is not available yet, or when the
    /// refresh or target write failed. At most one attempt per hour.
    static let retryInterval: TimeInterval = 60 * 60

    static func marketDate(at instant: Date, market: Market) -> LocalDate? {
        guard let timeZone = BingMarketProfile.profile(for: market)?.timeZone else {
            return nil
        }
        return LocalDate(date: instant, timeZone: timeZone)
    }

    /// First attempt for a market-local source date: 00:05 local time.
    static func firstAttempt(on day: LocalDate, market: Market) -> Date? {
        guard let timeZone = BingMarketProfile.profile(for: market)?.timeZone else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let startOfDay = calendar.date(from: components) else {
            return nil
        }
        return startOfDay.addingTimeInterval(publishGrace)
    }

    /// True when the automatic pipeline has not settled the current
    /// market-local day and the retry interval has elapsed.
    static func isDue(
        now: Date,
        market: Market,
        completedDay: LocalDate?,
        lastAttemptAt: Date?
    ) -> Bool {
        guard let today = marketDate(at: now, market: market),
              let todayFirstAttempt = firstAttempt(on: today, market: market),
              now >= todayFirstAttempt,
              completedDay != today
        else {
            return false
        }
        if let lastAttemptAt {
            let elapsed = now.timeIntervalSince(lastAttemptAt)
            if elapsed >= 0, elapsed < retryInterval {
                return false
            }
        }
        return true
    }

    /// Delay before the next scheduler wake-up. After a settled day this is
    /// the next local 00:05; after a failed attempt it is the remaining retry
    /// interval; if the day is already due it is immediate.
    static func nextCheckDelay(
        now: Date,
        market: Market,
        completedDay: LocalDate?,
        lastAttemptAt: Date?
    ) -> TimeInterval {
        guard let today = marketDate(at: now, market: market),
              let todayFirstAttempt = firstAttempt(on: today, market: market)
        else {
            return retryInterval
        }
        if completedDay == today,
           let tomorrow = today.nextDay,
           let tomorrowFirstAttempt = firstAttempt(on: tomorrow, market: market) {
            return max(1, tomorrowFirstAttempt.timeIntervalSince(now))
        }
        if now < todayFirstAttempt {
            return max(1, todayFirstAttempt.timeIntervalSince(now))
        }
        guard let lastAttemptAt else { return 1 }
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        guard elapsed >= 0, elapsed < retryInterval else { return 1 }
        let remaining = retryInterval - elapsed
        if let tomorrow = today.nextDay,
           let tomorrowFirstAttempt = firstAttempt(on: tomorrow, market: market),
           tomorrowFirstAttempt.timeIntervalSince(now) < remaining {
            return max(1, tomorrowFirstAttempt.timeIntervalSince(now))
        }
        return remaining
    }
}

// MARK: - App model

@MainActor
@Observable
final class AppModel {
    /// What the user chose. `.followSystem` is the default and is not
    /// persisted as a market; explicit choices persist their canonical tag.
    private(set) var marketSelection: MarketSelection
    /// The concrete catalog market currently in effect.
    private(set) var marketChoice: MarketChoice
    private(set) var payload: TodayPayload?
    private(set) var previewImage: NSImage?
    private(set) var originalImage: NSImage?
    private(set) var loadState: TodayLoadState = .idle
    private(set) var isRefreshing = false
    private(set) var isDownloadingOriginal = false
    private(set) var isApplyingWallpaper = false
    private(set) var warnings: [String] = []
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?
    private(set) var autoSyncEnabled = false
    /// Separate, default-off consent to replace unverified wallpapers during
    /// automatic events. Never inferred from `autoSyncEnabled`.
    private(set) var autoOverwriteEnabled = false
    /// Saved Dock icon choice. The app delegate applies the same value before
    /// the first window is created; the model owns runtime changes.
    private(set) var showsDockIcon: Bool
    /// Non-nil when the last activation-policy change was rejected. The
    /// persisted choice and `showsDockIcon` stay unchanged in that case.
    private(set) var dockIconError: String?
    var displays: [DesktopDisplayOption] { displayCoordinator.displays }
    var selectedDisplayID: DesktopDisplayID? { displayCoordinator.selectedDisplayID }
    private(set) var wallpaperStatusMessage: String?
    private(set) var wallpaperError: String?
    /// The single compact confirmation currently awaiting the user.
    private(set) var pendingWallpaperConfirmation: WallpaperConfirmation?
    /// History payload currently being prepared, confirmed, or written. Used by
    /// Library/Recap for per-item progress without replacing Today's payload.
    private(set) var applyingPayloadKey: OccurrenceKey?
    private(set) var guardBlocks: [WallpaperGuardInfo] = []
    private(set) var isPreparingConsent = false
    private(set) var isUpdatingAutomation = false
    private(set) var requiresDisableRetry = false
    private(set) var storageSummary: String?

    /// Notification opt-in, permission state, and once-per-occurrence receipt
    /// shared with the Settings UI and the applied-wallpaper snapshot path.
    let dailyNotifications: DailyNotificationController

    /// The process-wide folder sync controller.
    ///
    /// It is created exactly once, immediately after the single shared
    /// repository opens in `start()`. A second repository or a placeholder
    /// controller is never created, so the value stays `nil` only while local
    /// data is still opening; views treat that as "not ready yet", never as
    /// "sync is off".
    private(set) var syncController: DaybreakSyncController?

    /// Monotonic count of local changes imported by folder sync. Views that
    /// show repository-backed collections observe it and reload in place.
    var syncDataRevision: Int { syncController?.dataRevision ?? 0 }

    private let defaults: UserDefaults
    private let imageLoader = ImageAssetLoader()
    private let wallpaper: any MacWallpaperIntegrating
    private let now: @Sendable () -> Date
    private let repositoryDirectory: URL
    /// Local-only sync state: option flags and the authorized folder bookmark.
    /// Kept beside the repository, never inside the user-selected folder and
    /// never inside the repository itself.
    private let syncStateDirectory: URL
    private let makeService: @Sendable (URL) throws -> TodayService
    /// Market read by the sync scope provider. The controller stores its
    /// provider as `@Sendable`, while the app changes market on the main actor.
    private let syncMarketContext: SyncMarketContext
    @ObservationIgnored private var syncLifecycleCancellables: Set<AnyCancellable> = []
    private let autoTarget: WallpaperAutoTargetCoordinator
    private let displayCoordinator: WallpaperDisplayCoordinator
    /// Host locale mapping captured at launch. Following the system does not
    /// observe live locale changes; a relaunch re-resolves it.
    private let systemMarketResolution: BingMarketResolution
    /// A persisted value outside the catalog is ignored, never coerced to a
    /// different market, and disclosed while the app follows the system.
    private let discardedMarketPreference: String?
    private(set) var service: TodayService?
    /// Repository initialization failure retained so a language change can
    /// re-render the same failure instead of leaving a permanent loader.
    private var lastRepositoryFailure: Error?
    /// Shared with the recap/storage screen so explicit original cleanup obeys
    /// the same reconciliation boundary as automatic eviction.
    let currentWallpaperProtection: CurrentWallpaperProtectionGate
    /// Historical from builds that never released applied-image protection.
    /// Removed on launch so it cannot resurrect permanent protection.
    private static let legacyProtectedAppliedDefaultsKey = "daybreak.protectedAppliedWallpapers.v1"
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var originalTask: Task<Void, Never>?
    private var dailyRefreshTask: Task<Void, Never>?
    /// Identifies the operation allowed to mutate content and loading state.
    /// A newer request invalidates older ones even when they share the same
    /// market generation (repeated refresh) or observe cancellation late.
    private var contentRequestToken = 0
    /// Cancels a stale preflight preparation so it cannot re-present a panel
    /// the user already dismissed by changing market or payload.
    private var consentPreparationToken = 0
    private var consentPreparationTask: Task<Void, Never>?
    /// Prevents a cancelled original download from clearing the download flag
    /// or surfacing its error after a newer request has started.
    private var originalDownloadToken = 0
    private struct PreparedAutoSyncTarget {
        let key: OccurrenceKey
        let sourceDate: LocalDate
    }
    /// One requested automatic target update. `generation` is monotonic across
    /// all calls, so only the newest request may apply its result or notify.
    private struct AutoTargetUpdateRequest {
        let payload: TodayPayload
        let contentToken: Int
        let generation: Int
    }
    private var preparedAutoSyncTarget: PreparedAutoSyncTarget?
    /// Market-local day whose automatic refresh produced current content and a
    /// settled target. Nil forces a catch-up attempt when automation is on.
    private var lastDailyAutoRefreshDay: LocalDate?
    private var lastDailyAutoRefreshAttemptAt: Date?
    /// True while one target update owns the integration writes. A newer
    /// request is parked in `queuedAutoTargetUpdate` instead of being dropped,
    /// and runs as soon as the in-flight integration call returns.
    private var isUpdatingAutoTarget = false
    private var autoTargetUpdateGeneration = 0
    private var queuedAutoTargetUpdate: AutoTargetUpdateRequest?
    private var isAdoptingAutoTargetTopology = false
    private var confirmationDismissalTask: Task<Void, Never>?
    private var generation = 0
    private var didStart = false

    init(
        defaults: UserDefaults = .standard,
        wallpaper: (any MacWallpaperIntegrating)? = nil,
        dailyNotifications: DailyNotificationController? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        hostRegionIdentifier: String? = Locale.current.region?.identifier,
        preferredLanguageIdentifier: String? = Locale.preferredLanguages.first,
        repositoryDirectory: URL? = nil,
        syncStateDirectory: URL? = nil,
        makeService: (@Sendable (URL) throws -> TodayService)? = nil
    ) {
        self.defaults = defaults
        self.dailyNotifications = dailyNotifications
            ?? DailyNotificationController(defaults: defaults, now: now)
        let resolution = BingMarketProfile.resolution(
            regionIdentifier: hostRegionIdentifier,
            languageIdentifier: preferredLanguageIdentifier
        )
        self.systemMarketResolution = resolution

        let storedPreference = MarketSelection.storedPreference(in: defaults)
        let effectiveSelection: MarketSelection
        let effectiveChoice: MarketChoice
        switch storedPreference.selection {
        case .followSystem:
            effectiveSelection = .followSystem
            effectiveChoice = MarketChoice(profile: resolution.profile)
        case .explicit(let market):
            if let profile = BingMarketProfile.profile(for: market) {
                effectiveSelection = .explicit(profile.market)
                effectiveChoice = MarketChoice(profile: profile)
            } else {
                effectiveSelection = .followSystem
                effectiveChoice = MarketChoice(profile: resolution.profile)
            }
        }
        self.marketSelection = effectiveSelection
        self.marketChoice = effectiveChoice
        self.syncMarketContext = SyncMarketContext(effectiveChoice.market)
        self.discardedMarketPreference = storedPreference.unsupportedRawValue
        self.showsDockIcon = DockIconVisibility.isEnabled(in: defaults)
        let protectionGate = CurrentWallpaperProtectionGate()
        self.currentWallpaperProtection = protectionGate
        // Older builds kept an unbounded set of every image ever applied.
        // That set is obsolete; current-desktop protection is re-derived from
        // live system reads and in-flight reservations.
        defaults.removeObject(forKey: Self.legacyProtectedAppliedDefaultsKey)
        self.now = now
        let resolvedRepositoryDirectory = repositoryDirectory ?? Self.repositoryDirectory
        self.repositoryDirectory = resolvedRepositoryDirectory
        self.syncStateDirectory = syncStateDirectory
            ?? Self.defaultSyncStateDirectory(for: resolvedRepositoryDirectory)
        self.makeService = makeService ?? { directory in
            try TodayService(directory: directory)
        }
        let integration = wallpaper ?? MacWallpaperController()
        self.wallpaper = integration
        self.displayCoordinator = WallpaperDisplayCoordinator(
            defaults: defaults,
            wallpaper: integration,
            currentWallpaperProtection: protectionGate
        )
        self.autoTarget = WallpaperAutoTargetCoordinator(wallpaper: integration)
        integration.onStatusChange = { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                // A screen event already refreshed the integration snapshot;
                // consume it without publishing another snapshot.
                self.displayCoordinator.applyConnectedDisplays(await self.wallpaper.snapshotDisplays())
                // Deliver the notification decision before the slower
                // protection/repository refresh so a confirmed write is not
                // missed if the app quits or the UI work takes long.
                let appliedURLs = await self.wallpaper.appliedWallpaperURLs()
                await self.dailyNotifications.considerAppliedSnapshot(
                    payload: self.payload,
                    appliedURLs: appliedURLs
                )
                await self.adoptAutoTargetForTopologyIfNeeded()
                self.guardBlocks = await self.wallpaper.guardBlocks()
                await self.refreshAppliedProtection()
            }
        }
    }

    // MARK: Derived values

    var market: Market { marketChoice.market }

    var isFollowingSystemMarket: Bool {
        if case .followSystem = marketSelection { return true }
        return false
    }

    /// Catalog market the host locale currently resolves to, whether or not
    /// the user is following the system.
    var systemMarket: Market { systemMarketResolution.profile.market }

    /// Discloses an ignored persisted value or a host-locale fallback while
    /// following the system. Explicit choices need no explanation. Known
    /// markets are named in the interface language; an unknown saved value is
    /// shown verbatim because it cannot be translated safely.
    func marketSelectionNotice(in locale: Locale) -> String? {
        guard isFollowingSystemMarket else { return nil }
        if let discarded = discardedMarketPreference {
            return MacLocalizedString.resolve("已忽略之前保存的地区“\(discarded)”（不在可选的 Bing 地区中），当前跟随系统。", locale: locale)
        }
        let resolved = LocalePresentation.marketName(for: systemMarket, in: locale)
        switch systemMarketResolution.basis {
        case .languageAndRegion:
            return nil
        case .languageDefault:
            return MacLocalizedString.resolve("系统地区和首选语言没有完全对应的 Bing 地区；已按语言使用 \(resolved)，这不是系统地区的内容。", locale: locale)
        case .regionOnly:
            return MacLocalizedString.resolve("首选语言没有对应的 Bing 地区；已按系统地区使用 \(resolved)，这不是系统语言的内容。", locale: locale)
        case .fallback:
            return MacLocalizedString.resolve("系统语言和地区没有对应的 Bing 地区；暂用 \(resolved)，可以在下方手动选择。", locale: locale)
        }
    }

    var heroImage: NSImage? { originalImage ?? previewImage }

    var storyPanel: StoryPanel? {
        payload.map { StoryPanel.make(from: $0) }
    }

    var canApplyWallpaper: Bool {
        payload != nil && !isApplyingWallpaper && !isDownloadingOriginal
    }

    var statusTitle: String {
        switch loadState {
        case .idle: return String(appModelLocalized: "准备中")
        case .loadingCache: return String(appModelLocalized: "读取本地缓存")
        case .empty: return String(appModelLocalized: "尚无本地内容")
        case .ready:
            return lastUpdated == nil
                ? String(appModelLocalized: "已载入缓存")
                : String(appModelLocalized: "已更新")
        case .refreshing: return String(appModelLocalized: "正在刷新")
        case .offline: return String(appModelLocalized: "离线模式")
        case .failed: return String(appModelLocalized: "更新失败")
        }
    }

    var sourceOriginLabel: String {
        switch loadState {
        case .ready, .refreshing:
            return lastUpdated == nil
                ? String(appModelLocalized: "本地缓存")
                : String(appModelLocalized: "网络")
        case .offline:
            return String(appModelLocalized: "本地缓存")
        default:
            return "—"
        }
    }

    var errorBanner: String? {
        if let errorMessage { return errorMessage }
        if case .offline(let message) = loadState { return message }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        loadState = .loadingCache
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = self.repositoryDirectory
                let makeService = self.makeService
                let service = try await Task.detached(priority: .userInitiated) {
                    try makeService(directory)
                }.value
                guard !Task.isCancelled else { return }
                self.service = service
                self.lastRepositoryFailure = nil
                let repository = service.repository
                // Exactly one controller per shared repository. It is created
                // synchronously in the same step that publishes the ready
                // service, so no view can observe local data without the sync
                // lifecycle already attached.
                self.prepareSyncController(repository: repository)
                await self.wallpaper.setApplicationProtection(repository)
                await self.reloadCache()
                await self.prepareDisplays()
                await self.adoptAutoTargetForTopologyIfNeeded()
                await self.refreshAppliedProtection()
                await self.enforceAutomaticCacheLimits()
                // A market switch or manual refresh during startup owns the
                // content state; a token taken here still starts a refresh
                // for the market that is current when the infrastructure is
                // ready. Keeping it in `refreshTask` lets a region switch
                // cancel the in-flight request instead of only ignoring it.
                let token = self.beginContentRequest()
                let refreshGeneration = self.generation
                let refresh = Task { [weak self] in
                    guard let self else { return }
                    await self.performRefresh(
                        generation: refreshGeneration,
                        token: token
                    )
                }
                self.refreshTask = refresh
                await refresh.value
                if token == self.contentRequestToken {
                    await self.refreshStorageSummary()
                }
            } catch is CancellationError {
                return
            } catch {
                self.lastRepositoryFailure = error
                let message = Self.describe(error)
                self.loadState = .failed(message: message)
                self.errorMessage = message
            }
        }
    }

    func selectMarket(_ selection: MarketSelection) {
        guard !isApplyingWallpaper else { return }
        let choice: MarketChoice
        let effectiveSelection: MarketSelection
        switch selection {
        case .followSystem:
            choice = MarketChoice(profile: systemMarketResolution.profile)
            effectiveSelection = .followSystem
        case .explicit(let market):
            guard let profile = BingMarketProfile.profile(for: market) else { return }
            choice = MarketChoice(profile: profile)
            effectiveSelection = .explicit(profile.market)
        }
        guard effectiveSelection != marketSelection || choice != marketChoice else { return }

        cancelPendingWallpaperConfirmation()
        marketSelection = effectiveSelection
        marketChoice = choice
        // A following-system start inherits the capture-time market; an
        // explicit choice switches immediately. Keep the sync scope provider
        // aligned with what the content pages show.
        syncMarketContext.market = choice.market
        effectiveSelection.store(in: defaults)
        generation &+= 1
        let token = beginContentRequest()
        let currentGeneration = generation
        refreshTask?.cancel()
        originalTask?.cancel()
        originalTask = nil
        originalDownloadToken &+= 1
        isDownloadingOriginal = false
        dailyRefreshTask?.cancel()
        dailyRefreshTask = nil
        isRefreshing = false
        autoTarget.reset()
        lastDailyAutoRefreshDay = nil
        lastDailyAutoRefreshAttemptAt = nil
        preparedAutoSyncTarget = nil
        payload = nil
        previewImage = nil
        originalImage = nil
        warnings = []
        errorMessage = nil
        lastUpdated = nil
        loadState = .loadingCache
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadCache()
            guard token == self.contentRequestToken else { return }
            // Establish the pre-refresh applied map for the newly selected
            // market so a persisted URL cannot look like a fresh application.
            self.dailyNotifications.captureBaseline(
                appliedURLs: await self.wallpaper.appliedWallpaperURLs()
            )
            guard token == self.contentRequestToken else { return }
            await self.performRefresh(
                generation: currentGeneration,
                token: token
            )
            guard token == self.contentRequestToken else { return }
            await self.refreshStorageSummary()
        }
    }

    func refreshNow() {
        // Before the repository exists there is no request to own; `start()`
        // will run the first refresh once it is ready.
        guard service != nil else { return }
        refreshTask?.cancel()
        let token = beginContentRequest()
        let currentGeneration = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(
                generation: currentGeneration,
                token: token
            )
            guard token == self.contentRequestToken else { return }
            await self.refreshStorageSummary()
        }
    }

    func retry() {
        if service == nil {
            didStart = false
            start()
            return
        }
        refreshNow()
    }

    /// Model copy is resolved when produced. After an in-app interface
    /// language change, clear the old-language snapshots and re-run the local
    /// paths that can regenerate them without a network request.
    func interfaceLanguageDidChange() {
        warnings = []
        errorMessage = nil
        wallpaperError = nil
        wallpaperStatusMessage = nil
        dockIconError = nil
        storageSummary = nil
        if case .failed = loadState {
            if let failure = lastRepositoryFailure {
                // Repository initialization never produced a service, so
                // reloading would leave a permanent loader. Re-render the
                // retained failure in the newly selected language instead.
                let message = Self.describe(failure)
                loadState = .failed(message: message)
                errorMessage = message
            } else if service != nil {
                loadState = .loadingCache
            }
        } else if case .offline = loadState {
            loadState = payload == nil ? .empty : .ready
        }

        let shouldReloadCache = !isRefreshing && service != nil
        Task { [weak self] in
            guard let self else { return }
            if shouldReloadCache {
                await self.reloadCache()
            }
            await self.refreshStorageSummary()
            guard self.service != nil else { return }
            let automation = await self.wallpaper.automationStatus()
            if let error = automation.error, !error.isEmpty {
                self.wallpaperError = error
            }
            self.requiresDisableRetry = automation.requiresDisableRetry
        }
    }

    /// Applies the user's Dock icon choice through the public activation
    /// policy. Persistence happens only after the API accepts the change, so a
    /// rejected change leaves both the saved value and the visible switch
    /// consistent with the actual Dock state. Applying the policy can hide the
    /// window during the transition, so the window that was on screen is
    /// re-shown and focused immediately in both directions.
    func setShowsDockIcon(_ visible: Bool) {
        guard visible != showsDockIcon else { return }
        dockIconError = nil
        guard MainWindowAccess.shared.applyActivationPolicy(showDockIcon: visible) else {
            dockIconError = MacLocalizedString.resolve("无法更改 Dock 图标显示，当前状态未改变。Daybreak 仍可通过菜单栏访问。", locale: WallpaperInterfaceLocale.current)
            return
        }
        showsDockIcon = visible
        DockIconVisibility.store(visible, in: defaults)
    }

    func selectDisplay(_ id: DesktopDisplayID?) {
        displayCoordinator.selectDisplay(id)
    }

    // MARK: Folder sync

    /// Creates the single sync controller for the shared repository and starts
    /// the sources that mean "the user is back". Called once from `start()`
    /// immediately after the repository opens, so no view can observe a ready
    /// repository without an attached sync lifecycle.
    private func prepareSyncController(repository: WallpaperRepository) {
        guard syncController == nil else { return }
        let marketContext = syncMarketContext
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: syncStateDirectory,
            market: { marketContext.market }
        )
        syncController = controller
        observeSyncLifecycle()
        // Restore options/authorization and run the launch trigger without
        // making the Today screen wait for folder IO.
        Task { [weak self] in
            guard let self, self.syncController === controller else { return }
            await controller.prepare()
            await controller.noteForegroundActivity()
        }
    }

    /// Public, observable activation and wake are the only two moments a Mac
    /// app learns the user is present again. The controller has no platform
    /// observer of its own, and its own scheduler coalesces repeated triggers.
    private func observeSyncLifecycle() {
        guard syncLifecycleCancellables.isEmpty else { return }
        // AppKit posts activation on the default center and workspace wake on
        // the workspace center; subscribing to the wrong one silently never
        // fires.
        let defaultCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        defaultCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: workspaceCenter.publisher(for: NSWorkspace.didWakeNotification))
            .sink { [weak self] _ in
                // NotificationCenter delivers on the posting thread; the
                // trigger and the controller both live on the main actor.
                Task { @MainActor [weak self] in
                    self?.noteSyncActivity()
                }
            }
            .store(in: &syncLifecycleCancellables)
    }

    /// Fire-and-forget hand-off for local repository changes that may create
    /// sync work: a network refresh that stored occurrences, metadata or
    /// stories, a downloaded original, and favorite changes reported by the
    /// library and recap models. Never blocks local business and never changes
    /// a wallpaper or a permission.
    func noteSyncActivity() {
        guard let syncController else { return }
        Task { await syncController.noteForegroundActivity() }
    }

    /// Local sync state lives next to the repository under Application
    /// Support. Deriving it from the repository directory keeps an injected
    /// test or custom repository from reading the real folder bookmark.
    static func defaultSyncStateDirectory(for repositoryDirectory: URL) -> URL {
        repositoryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Sync", isDirectory: true)
    }

    // MARK: Cache

    private func reloadCache() async {
        guard let service else { return }
        let currentGeneration = generation
        if let cached = await service.cachedToday(market: market) {
            guard currentGeneration == generation else { return }
            payload = cached
            loadState = .ready
            errorMessage = nil
            await loadImages(for: cached)
        } else {
            guard currentGeneration == generation else { return }
            payload = nil
            previewImage = nil
            originalImage = nil
            loadState = .empty
        }
    }

    // MARK: Network

    /// Starts a new content request and invalidates every older request.
    @discardableResult
    private func beginContentRequest() -> Int {
        contentRequestToken &+= 1
        return contentRequestToken
    }

    /// Returns true only when a network refresh completed for the current
    /// generation and still owns the content state. A superseded request may
    /// finish after a newer one started (including after cooperative
    /// cancellation); it must not publish data, clear `isRefreshing`, or
    /// replace the newer request's loading state.
    @discardableResult
    private func performRefresh(
        generation currentGeneration: Int,
        token: Int
    ) async -> Bool {
        guard let service, token == contentRequestToken else { return false }
        isRefreshing = true
        loadState = .refreshing
        warnings = []
        errorMessage = nil
        if autoSyncEnabled, !requiresDisableRetry {
            lastDailyAutoRefreshAttemptAt = now()
        }
        defer {
            if token == contentRequestToken {
                isRefreshing = false
                synchronizeDailyAutoRefreshLoop()
            }
        }

        do {
            let outcome = try await service.refreshToday(market: market)
            try Task.checkCancellation()
            guard token == contentRequestToken,
                  currentGeneration == generation
            else {
                return false
            }
            payload = outcome.payload
            warnings = outcome.warnings
            lastUpdated = outcome.fetchedAt
            loadState = .ready
            await loadImages(for: outcome.payload)
            guard token == contentRequestToken else { return false }
            if autoSyncEnabled, !requiresDisableRetry, self.payload?.originalURL == nil {
                _ = try? await ensureOriginalURL(for: outcome.payload)
                guard token == contentRequestToken else { return false }
            }
            // Automatic LRU keeps cached history within the built-in limits.
            // Current desktops, favorites, pinned dates and in-flight writes
            // are protected inside the repository actor.
            await enforceAutomaticCacheLimits()
            await refreshStorageSummary()
            guard token == contentRequestToken else { return false }
            if let current = self.payload {
                await updateAutoTargetIfNeeded(for: current)
                guard token == contentRequestToken else { return false }
                await adoptAutoTargetForTopologyIfNeeded()
                guard token == contentRequestToken else { return false }
            }
            recordAutomaticContentIfSettled()
            // New occurrences, metadata and story text are now in the shared
            // repository; the coalescing controller picks them up without
            // delaying this refresh.
            noteSyncActivity()
            return true
        } catch is CancellationError {
            guard token == contentRequestToken,
                  currentGeneration == generation,
                  case .refreshing = loadState
            else {
                return false
            }
            loadState = payload == nil ? .empty : .ready
            return false
        } catch {
            guard token == contentRequestToken,
                  currentGeneration == generation
            else {
                return false
            }
            let message = Self.describe(error)
            errorMessage = message
            if payload != nil {
                loadState = .offline(message: String(appModelLocalized: "离线或更新失败：\(message)"))
            } else {
                loadState = .failed(message: message)
            }
            return false
        }
    }

    private func loadImages(for payload: TodayPayload) async {
        let expectedKey = payload.key
        if let thumbnailURL = payload.thumbnailURL {
            do {
                let loaded = try await imageLoader.image(at: thumbnailURL, maxPixelSize: 2_400)
                guard self.payload?.key == expectedKey else { return }
                previewImage = loaded.image
            } catch {
                // A late failure from a superseded payload must not clear the
                // current image.
                guard self.payload?.key == expectedKey else { return }
                previewImage = nil
            }
        } else if self.payload?.key == expectedKey {
            previewImage = nil
        }

        if let originalURL = payload.originalURL {
            do {
                let loaded = try await imageLoader.image(at: originalURL, maxPixelSize: 3_840)
                guard self.payload?.key == expectedKey else { return }
                originalImage = loaded.image
            } catch {
                guard self.payload?.key == expectedKey else { return }
                originalImage = nil
            }
        } else if self.payload?.key == expectedKey {
            originalImage = nil
        }
    }

    // MARK: Original download

    func downloadOriginal() {
        guard let payload, let service, !isDownloadingOriginal else { return }
        originalTask?.cancel()
        originalDownloadToken &+= 1
        let token = originalDownloadToken
        isDownloadingOriginal = true
        wallpaperError = nil
        originalTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == self.originalDownloadToken {
                    self.isDownloadingOriginal = false
                }
            }
            do {
                _ = try await service.downloadOriginal(for: payload)
                guard token == self.originalDownloadToken else { return }
                // The original is stored locally; an enabled sync may now
                // publish it when the user opted into originals.
                self.noteSyncActivity()
                guard let updated = await service.cachedPayload(
                    market: payload.market,
                    key: payload.key
                ) else { return }
                guard token == self.originalDownloadToken,
                      self.payload?.key == payload.key
                else {
                    return
                }
                self.payload = updated
                await self.loadImages(for: updated)
                guard token == self.originalDownloadToken else { return }
                await self.enforceAutomaticCacheLimits()
                await self.refreshStorageSummary()
                guard token == self.originalDownloadToken else { return }
                await self.updateAutoTargetIfNeeded(for: updated)
                guard token == self.originalDownloadToken else { return }
                await self.adoptAutoTargetForTopologyIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                guard token == self.originalDownloadToken,
                      self.payload?.key == payload.key
                else {
                    return
                }
                self.wallpaperError = Self.describe(error)
            }
        }
    }

    private func ensureOriginalURL(for payload: TodayPayload) async throws -> URL {
        if let existing = payload.originalURL {
            return existing
        }
        guard let service else {
            throw TodayServiceError.imageUnavailable(String(appModelLocalized: "本地缓存尚未准备好"))
        }
        let url = try await service.downloadOriginal(for: payload)
        noteSyncActivity()
        if let updated = await service.cachedPayload(
            market: payload.market,
            key: payload.key
        ), self.payload?.key == payload.key {
            self.payload = updated
            await loadImages(for: updated)
            await enforceAutomaticCacheLimits()
            await refreshStorageSummary()
        }
        return url
    }

    // MARK: Wallpaper

    private func prepareDisplays() async {
        // Capture the pre-write applied map before resuming automation. A
        // launch-time system event can trigger a reconciliation as soon as the
        // integration starts observing; if that write landed before the
        // baseline, its newly applied URL would become the baseline and the
        // notification would be swallowed.
        dailyNotifications.captureBaseline(
            appliedURLs: await wallpaper.appliedWallpaperURLs()
        )
        // An explicit persisted opt-in resumes across launches. Invalid or
        // unreadable settings already fell back to read-only inside the
        // integration; this never infers automation from a fresh install.
        let automation = await wallpaper.resumeAutomation()
        autoSyncEnabled = automation.enabled
        autoOverwriteEnabled = automation.automaticOverwriteEnabled
        requiresDisableRetry = automation.requiresDisableRetry
        if let error = automation.error {
            wallpaperError = error
        }
        // `message` also carries non-error guidance, such as migrated legacy
        // targets that automatic sync will not update. Surface it even when
        // there is no error, but never replace an existing prompt with an
        // empty string.
        if !automation.message.isEmpty {
            wallpaperStatusMessage = automation.message
        }
        displayCoordinator.applyConnectedDisplays(await wallpaper.connectedDisplays())
        guardBlocks = await wallpaper.guardBlocks()
        // Start the first-run authorization request without blocking content
        // loading. The controller de-duplicates and can be awaited by startup
        // code that needs to sequence another system prompt after it.
        Task { [weak self] in
            await self?.dailyNotifications.prepareAuthorizationIfNeeded()
        }
        synchronizeDailyAutoRefreshLoop()
    }

    // MARK: Manual apply

    func beginApplyWallpaper() {
        guard let payload else { return }
        prepareManualApply(payload: payload, requiresCurrentPayload: true)
    }

    /// Applies a selected archived wallpaper without replacing Today's
    /// payload. The original is downloaded into the shared cache when missing;
    /// the caller's payload object is never mutated.
    func beginApplyWallpaper(for payload: TodayPayload) {
        prepareManualApply(payload: payload, requiresCurrentPayload: false)
    }

    private func prepareManualApply(
        payload: TodayPayload,
        requiresCurrentPayload: Bool
    ) {
        guard !displays.isEmpty else {
            wallpaperError = WallpaperIntegrationError.noConnectedDisplays.localizedDescription
            return
        }
        guard pendingWallpaperConfirmation == nil,
              !isPreparingConsent,
              !isApplyingWallpaper,
              !isDownloadingOriginal
        else {
            return
        }
        preparedAutoSyncTarget = nil
        let token = beginConsentPreparation()
        applyingPayloadKey = payload.key
        wallpaperError = nil
        wallpaperStatusMessage = nil
        consentPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishConsentPreparation(token: token) }
            do {
                let url = requiresCurrentPayload
                    ? try await self.ensureOriginalURL(for: payload)
                    : try await self.cachedOriginalURL(for: payload)
                guard token == self.consentPreparationToken else { return }
                if requiresCurrentPayload, self.payload?.key != payload.key {
                    self.cancelPendingWallpaperConfirmation()
                    return
                }
                guard token == self.consentPreparationToken,
                      self.applyingPayloadKey == payload.key
                else {
                    return
                }
                self.presentManualApplyConfirmation(
                    imageURL: url,
                    displayID: self.selectedDisplayID
                )
            } catch is CancellationError {
                return
            } catch {
                guard token == self.consentPreparationToken,
                      self.applyingPayloadKey == payload.key
                else {
                    return
                }
                self.applyingPayloadKey = nil
                self.wallpaperError = Self.describe(error)
            }
        }
    }

    /// Invalidates any older preflight and marks a new one as preparing. The
    /// returned token is the only authority allowed to present its panel.
    private func beginConsentPreparation() -> Int {
        consentPreparationToken &+= 1
        consentPreparationTask?.cancel()
        consentPreparationTask = nil
        isPreparingConsent = true
        return consentPreparationToken
    }

    private func finishConsentPreparation(token: Int) {
        guard token == consentPreparationToken else { return }
        consentPreparationTask = nil
        isPreparingConsent = false
    }

    /// Generic designated-image entry point for Library/Recap. It shows the
    /// same single confirmation and targets one display; Today's payload is
    /// untouched.
    func requestManualApply(
        imageURL: URL,
        displayID: DesktopDisplayID? = nil
    ) {
        guard !displays.isEmpty else {
            wallpaperError = WallpaperIntegrationError.noConnectedDisplays.localizedDescription
            return
        }
        guard pendingWallpaperConfirmation == nil,
              !isPreparingConsent,
              !isApplyingWallpaper,
              !isDownloadingOriginal
        else {
            return
        }
        wallpaperError = nil
        wallpaperStatusMessage = nil
        presentManualApplyConfirmation(imageURL: imageURL, displayID: displayID)
    }

    private func presentManualApplyConfirmation(
        imageURL: URL,
        displayID: DesktopDisplayID?
    ) {
        let resolvedID: DesktopDisplayID?
        if let displayID {
            // Never substitute a different display after the user saw the
            // target. If it disappeared, fail and ask again.
            resolvedID = displays.first(where: { $0.id == displayID })?.id
        } else {
            resolvedID = selectedDisplayID.flatMap { id in
                displays.first(where: { $0.id == id })?.id
            } ?? displays.first?.id
        }
        guard let resolvedID,
              let display = displays.first(where: { $0.id == resolvedID })
        else {
            applyingPayloadKey = nil
            wallpaperError = displayID == nil
                ? WallpaperIntegrationError.noConnectedDisplays.localizedDescription
                : WallpaperIntegrationError.selectedDisplayUnavailable.localizedDescription
            return
        }
        let targetName = imageURL.lastPathComponent.isEmpty
            ? String(appModelLocalized: "所选图片")
            : imageURL.lastPathComponent
        pendingWallpaperConfirmation = WallpaperConfirmation(
            action: .manualApply(imageURL: imageURL, displayID: resolvedID),
            title: String(appModelLocalized: "更新当前桌面壁纸？"),
            message: String(
                format: String(appModelLocalized: "显示器：%@\n仅修改当前可访问的桌面；其他 Space 和显示器不会立即更新。\n目标图片：%@"),
                display.label,
                targetName
            ),
            confirmLabel: String(appModelLocalized: "应用")
        )
    }

    private func cachedOriginalURL(for payload: TodayPayload) async throws -> URL {
        if let existing = payload.originalURL {
            return existing
        }
        guard let service else {
            throw TodayServiceError.imageUnavailable(String(appModelLocalized: "本地缓存尚未准备好"))
        }
        _ = try await service.downloadOriginal(for: payload)
        // The archived original is now local; sync may publish it only when
        // the user enabled originals. Wallpaper behavior is unchanged.
        noteSyncActivity()
        guard let updated = await service.cachedPayload(
            market: payload.market,
            key: payload.key
        ), let url = updated.originalURL else {
            throw TodayServiceError.imageUnavailable(String(appModelLocalized: "原图尚未准备好，请稍后重试"))
        }
        return url
    }

    // MARK: Auto sync / overwrite

    func beginAutoSync() {
        guard let payload,
              pendingWallpaperConfirmation == nil,
              !isPreparingConsent,
              !isDownloadingOriginal,
              !isApplyingWallpaper,
              !displays.isEmpty
        else {
            return
        }
        preparedAutoSyncTarget = nil
        let token = beginConsentPreparation()
        wallpaperError = nil
        wallpaperStatusMessage = nil
        consentPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishConsentPreparation(token: token) }
            do {
                let url = try await self.ensureOriginalURL(for: payload)
                // The token, not just the occurrence key, is authoritative:
                // switching A→B→A can restore the same key after the user
                // already cancelled this preflight.
                guard token == self.consentPreparationToken,
                      self.payload?.key == payload.key
                else {
                    return
                }
                self.presentAutoSyncConfirmation(imageURL: url)
                guard token == self.consentPreparationToken,
                      self.pendingWallpaperConfirmation != nil
                else {
                    return
                }
                self.preparedAutoSyncTarget = PreparedAutoSyncTarget(
                    key: payload.key,
                    sourceDate: payload.sourceDate
                )
            } catch is CancellationError {
                return
            } catch {
                guard token == self.consentPreparationToken else { return }
                self.wallpaperError = Self.describe(error)
            }
        }
    }

    private func presentAutoSyncConfirmation(imageURL: URL) {
        let displayNames = displays.map(\.label).joined(separator: String(appModelLocalized: "、"))
        pendingWallpaperConfirmation = WallpaperConfirmation(
            action: .autoSync(imageURL: imageURL),
            title: String(appModelLocalized: "开启自动同步？"),
            message: String(
                format: String(appModelLocalized: "Daybreak 会为全部 %d 台已连接显示器保存今日目标，并在重新启动后继续。启用后会立即检查当前可访问的桌面；之后的内容更新、Space 切换、显示器变化、唤醒，或鼠标进入另一台显示器时会继续检查。\n未激活的 Space 不会立即更新；遇到未知壁纸时默认暂停并等待确认。\n显示器：%@"),
                displays.count,
                displayNames
            ),
            confirmLabel: String(appModelLocalized: "开启自动同步")
        )
    }

    func setAutoOverwrite(_ enabled: Bool) {
        guard !isUpdatingAutomation else { return }
        if enabled {
            guard pendingWallpaperConfirmation == nil,
                  !isPreparingConsent,
                  !isApplyingWallpaper,
                  !autoOverwriteEnabled
            else {
                return
            }
            pendingWallpaperConfirmation = WallpaperConfirmation(
                action: .automaticOverwrite,
                title: String(appModelLocalized: "开启自动覆盖？"),
                message: String(appModelLocalized: "开启后，Daybreak 会在 Space 切换、显示器变化、唤醒或鼠标进入另一台显示器时直接替换当前可访问桌面的壁纸，不再逐台确认。手动保护的显示器不会被覆盖；未激活的 Space 仍不会立即更新。"),
                confirmLabel: String(appModelLocalized: "开启自动覆盖")
            )
            return
        }
        guard autoOverwriteEnabled else { return }
        isUpdatingAutomation = true
        wallpaperError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isUpdatingAutomation = false }
            let state = await self.wallpaper.setAutomaticOverwrite(false)
            self.applyAutoOutcome(state)
            self.guardBlocks = await self.wallpaper.guardBlocks()
            self.synchronizeDailyAutoRefreshLoop()
        }
    }

    func confirmPendingWallpaperAction() {
        guard let confirmation = pendingWallpaperConfirmation else { return }
        confirmWallpaperAction(confirmation)
    }

    /// Runs the confirmation the user actually saw. The dialog passes its
    /// captured value, so SwiftUI clearing `isPresented` (and thereby the
    /// pending value) before invoking the button action cannot turn the
    /// confirmation into a no-op.
    func confirmWallpaperAction(_ confirmation: WallpaperConfirmation) {
        guard !isApplyingWallpaper else { return }
        confirmationDismissalTask?.cancel()
        confirmationDismissalTask = nil
        pendingWallpaperConfirmation = nil
        isApplyingWallpaper = true
        wallpaperError = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isApplyingWallpaper = false
                self.applyingPayloadKey = nil
            }
            do {
                switch confirmation.action {
                case .manualApply(let imageURL, let displayID):
                    let outcome = try await self.wallpaper.applyManually(
                        imageURL: imageURL,
                        displayID: displayID
                    )
                    self.applyApplyOutcome(outcome)
                    // A confirmed backend write is authoritative. This path
                    // also covers a reused image URL whose applied-map diff
                    // would not change, while the policy still requires the
                    // applied image to be today's original.
                    await self.dailyNotifications.considerConfirmedApply(
                        payload: self.payload,
                        appliedImageURL: imageURL,
                        appliedDisplayIDs: outcome.synchronizedDisplayIDs
                    )

                case .autoSync(let imageURL):
                    let outcome = try await self.wallpaper.enableAutoSync(imageURL: imageURL)
                    self.applyApplyOutcome(outcome)
                    let state = await self.wallpaper.automationStatus()
                    self.applyAutoOutcome(state)
                    let prepared = self.preparedAutoSyncTarget
                    self.preparedAutoSyncTarget = nil
                    if state.enabled, let prepared {
                        self.adoptAutoSyncConsentBaseline(prepared)
                    }

                case .automaticOverwrite:
                    let state = await self.wallpaper.setAutomaticOverwrite(true)
                    self.applyAutoOutcome(state)
                }
                // Protection is refreshed from the integration's confirmed
                // per-display applied URLs, never from the live payload: the
                // user may have changed region while this was pending.
                self.guardBlocks = await self.wallpaper.guardBlocks()
                await self.refreshAppliedProtection()
            } catch {
                self.preparedAutoSyncTarget = nil
                var message = Self.describe(error)
                if case .autoSync = confirmation.action {
                    let state = await self.wallpaper.automationStatus()
                    self.applyAutoOutcome(state, overwriteMessage: true)
                    if let stateError = state.error,
                       !stateError.isEmpty,
                       !message.contains(stateError) {
                        message += "\n\(stateError)"
                    }
                }
                self.wallpaperError = message
            }
            self.synchronizeDailyAutoRefreshLoop()
        }
    }

    func cancelPendingWallpaperConfirmation() {
        confirmationDismissalTask?.cancel()
        confirmationDismissalTask = nil
        // Invalidate and cancel any preflight still downloading its image, so
        // it cannot re-present a panel after a market/payload change.
        consentPreparationToken &+= 1
        consentPreparationTask?.cancel()
        consentPreparationTask = nil
        isPreparingConsent = false
        pendingWallpaperConfirmation = nil
        preparedAutoSyncTarget = nil
        applyingPayloadKey = nil
    }

    /// A system dialog can set its presentation binding to false immediately
    /// before running the chosen button. Defer dismissal one turn so the
    /// button action can cancel it; an actual cancel/Escape still clears the
    /// pending value.
    func schedulePendingWallpaperConfirmationDismissal(id: UUID?) {
        confirmationDismissalTask?.cancel()
        confirmationDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, !self.isApplyingWallpaper,
                  let id, self.pendingWallpaperConfirmation?.id == id
            else {
                return
            }
            self.cancelPendingWallpaperConfirmation()
        }
    }

    private func applyApplyOutcome(_ outcome: WallpaperApplyOutcome) {
        if !outcome.message.isEmpty {
            wallpaperStatusMessage = outcome.message
        }
        if !outcome.failures.isEmpty {
            wallpaperError = outcome.failures.joined(separator: "\n")
        }
    }

    private func applyAutoOutcome(
        _ state: WallpaperAutoOutcome,
        overwriteMessage: Bool = false
    ) {
        autoSyncEnabled = state.enabled
        autoOverwriteEnabled = state.automaticOverwriteEnabled
        if overwriteMessage || !state.message.isEmpty {
            wallpaperStatusMessage = state.message
        }
        wallpaperError = state.error
        requiresDisableRetry = state.requiresDisableRetry
    }

    func confirmGuardOverwrite(displayID: DesktopDisplayID, observedImageURL: URL?) {
        guard !isApplyingWallpaper else { return }
        isApplyingWallpaper = true
        wallpaperError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isApplyingWallpaper = false }
            do {
                let outcome = try await self.wallpaper.confirmOverwrite(
                    displayID: displayID,
                    observedImageURL: observedImageURL
                )
                self.applyApplyOutcome(outcome)
                self.guardBlocks = await self.wallpaper.guardBlocks()
                await self.refreshAppliedProtection()
            } catch {
                self.wallpaperError = Self.describe(error)
            }
        }
    }

    func setAutoSync(_ enabled: Bool) {
        if !enabled {
            guard !isUpdatingAutomation else { return }
            isUpdatingAutomation = true
            wallpaperError = nil
            Task { [weak self] in
                guard let self else { return }
                defer { self.isUpdatingAutomation = false }
                let outcome = await self.wallpaper.disableAutoSync()
                self.autoSyncEnabled = outcome.enabled
                self.autoOverwriteEnabled = outcome.automaticOverwriteEnabled
                self.wallpaperStatusMessage = outcome.message
                self.wallpaperError = outcome.error
                self.requiresDisableRetry = outcome.requiresDisableRetry
                if !outcome.enabled {
                    self.autoTarget.reset()
                }
                self.guardBlocks = await self.wallpaper.guardBlocks()
                self.synchronizeDailyAutoRefreshLoop()
            }
            return
        }
        beginAutoSync()
    }

    /// Applies the automatic target only after the user's current opt-in is
    /// active. The coordinator owns the fail-closed ordering so no
    /// reconciliation can follow a failed target save.
    ///
    /// Calls are serialized through `queuedAutoTargetUpdate`: a market switch
    /// or a late original download that requests an update while an older
    /// integration write is still awaiting must not be dropped by the
    /// in-flight guard. The newest request runs immediately after the older
    /// call returns, and stale results are never applied or notified.
    private func updateAutoTargetIfNeeded(for payload: TodayPayload) async {
        autoTargetUpdateGeneration &+= 1
        let request = AutoTargetUpdateRequest(
            payload: payload,
            contentToken: contentRequestToken,
            generation: autoTargetUpdateGeneration
        )
        guard !isUpdatingAutoTarget else {
            // The active update drains this slot before releasing the flag.
            queuedAutoTargetUpdate = request
            return
        }
        isUpdatingAutoTarget = true
        defer { isUpdatingAutoTarget = false }

        var next: AutoTargetUpdateRequest? = request
        var didAttemptCurrentFallback = false
        while let current = next {
            queuedAutoTargetUpdate = nil
            let applied = await performAutoTargetUpdate(current)
            if let queued = queuedAutoTargetUpdate {
                next = queued
            } else if !applied,
                      !didAttemptCurrentFallback,
                      let fallback = currentAutoTargetUpdateRequest() {
                // The in-flight operation may have belonged to a market that
                // is gone and no newer refresh has requested the current
                // payload yet. Re-check the current state once so a switch
                // cannot leave the latest target unwritten until the next
                // scheduled refresh.
                didAttemptCurrentFallback = true
                next = fallback
            } else {
                next = nil
            }
        }
        synchronizeDailyAutoRefreshLoop()
    }

    /// Runs one serialized target update. Returns false when the request lost
    /// its content/market ownership or the coordinator superseded it, so the
    /// caller never applies a stale outcome or notification.
    @discardableResult
    private func performAutoTargetUpdate(
        _ request: AutoTargetUpdateRequest
    ) async -> Bool {
        let payload = request.payload
        guard request.contentToken == contentRequestToken,
              request.generation == autoTargetUpdateGeneration,
              self.payload?.key == payload.key,
              payload.market == market
        else {
            return false
        }
        let update = await autoTarget.updateIfNeeded(
            for: payload,
            autoSyncEnabled: autoSyncEnabled,
            isUpdatingAutomation: isUpdatingAutomation,
            requiresDisableRetry: requiresDisableRetry,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return request.contentToken == self.contentRequestToken
                    && request.generation == self.autoTargetUpdateGeneration
                    && self.payload?.key == payload.key
                    && payload.market == self.market
                    && self.autoSyncEnabled
                    && !self.isUpdatingAutomation
                    && !self.requiresDisableRetry
            }
        )
        // Re-check after every integration await. A market switch, refresh,
        // or newer target request may own the state now; its own operation
        // will persist and reconcile, and this stale result must stay inert.
        guard !update.superseded,
              request.contentToken == contentRequestToken,
              request.generation == autoTargetUpdateGeneration,
              self.payload?.key == payload.key,
              payload.market == market,
              autoSyncEnabled,
              !isUpdatingAutomation,
              !requiresDisableRetry
        else {
            return false
        }
        if let outcome = update.outcome {
            autoSyncEnabled = outcome.enabled
            wallpaperStatusMessage = outcome.message
            if let error = outcome.error ?? outcome.blockedReason {
                wallpaperError = error
            }
            if outcome.requiresDisableRetry {
                requiresDisableRetry = true
            }
        }
        // A saved target is only configuration. Notify only after the
        // reconciliation pass itself confirmed this exact image is settled on
        // the currently accessible displays; otherwise same-URL cross-day
        // reuse would be fabricated from the applied ledger.
        if update.targetUpdated,
           !update.settledDisplayIDs.isEmpty,
           let appliedImageURL = payload.originalURL {
            await dailyNotifications.considerConfirmedApply(
                payload: payload,
                appliedImageURL: appliedImageURL,
                appliedDisplayIDs: update.settledDisplayIDs
            )
        }
        return true
    }

    /// Builds one opportunistic update for the payload the user is looking at
    /// now. Used only when the previous owner lost its state; the coordinator
    /// still de-duplicates an occurrence that was already persisted.
    private func currentAutoTargetUpdateRequest() -> AutoTargetUpdateRequest? {
        guard autoSyncEnabled,
              !requiresDisableRetry,
              !isUpdatingAutomation,
              let current = payload,
              current.market == market,
              current.originalURL != nil
        else {
            return nil
        }
        autoTargetUpdateGeneration &+= 1
        return AutoTargetUpdateRequest(
            payload: current,
            contentToken: contentRequestToken,
            generation: autoTargetUpdateGeneration
        )
    }

    /// Extends the current authorized automatic target to displays that
    /// appeared after the original consent/assignment. Intent persistence and
    /// reconciliation are separated so a market switch between them can never
    /// trigger a write for a target the user is no longer looking at. Only a
    /// current market-day payload may be adopted: a stale cached payload must
    /// never install (or reconcile) yesterday's image on a new display.
    private func adoptAutoTargetForTopologyIfNeeded() async {
        guard !isAdoptingAutoTargetTopology,
              autoSyncEnabled,
              !requiresDisableRetry,
              !isUpdatingAutomation,
              !isUpdatingAutoTarget,
              !isPreparingConsent,
              !isApplyingWallpaper,
              let payload,
              payload.market == market,
              let currentMarketDay = WallpaperDailyRefreshPolicy.marketDate(
                  at: now(),
                  market: market
              ),
              payload.sourceDate == currentMarketDay,
              let imageURL = payload.originalURL
        else {
            return
        }
        isAdoptingAutoTargetTopology = true
        defer { isAdoptingAutoTargetTopology = false }
        let token = contentRequestToken

        let adoption = await wallpaper.adoptAutoTargetForConnectedDisplays(
            imageURL: imageURL
        )
        guard token == contentRequestToken,
              self.payload?.key == payload.key,
              self.payload?.market == market,
              let currentDay = WallpaperDailyRefreshPolicy.marketDate(
                  at: now(),
                  market: market
              ),
              self.payload?.sourceDate == currentDay
        else {
            return
        }

        if !adoption.updatedDisplayIDs.isEmpty {
            applyAutoOutcome(adoption.outcome)
            autoTarget.recordPersistedTarget(
                key: payload.key,
                sourceDate: payload.sourceDate
            )
            if adoption.outcome.enabled {
                _ = await wallpaper.requestReconciliation(
                    expectedImageURL: imageURL
                )
                guard token == contentRequestToken else {
                    synchronizeDailyAutoRefreshLoop()
                    return
                }
            }
        } else if adoption.outcome.error != nil {
            applyAutoOutcome(adoption.outcome)
        }
        synchronizeDailyAutoRefreshLoop()
    }

    /// Marks the market-local day as settled only when today's content is
    /// loaded and no automatic target write for it is outstanding or failed.
    /// A failed target update therefore keeps the daily retry armed instead of
    /// being treated as done.
    private func recordAutomaticContentIfSettled() {
        guard autoSyncEnabled,
              !requiresDisableRetry,
              !isUpdatingAutoTarget,
              !autoTarget.lastUpdateFailed,
              let payload,
              payload.market == market,
              payload.isSourceDateToday
        else {
            return
        }
        lastDailyAutoRefreshDay = payload.marketToday
    }

    /// The consent flow already saved the automatic target it showed. Treat it
    /// as the current target so the next refresh does not rewrite and
    /// reconcile the same occurrence immediately after opt-in.
    private func adoptAutoSyncConsentBaseline(
        _ prepared: PreparedAutoSyncTarget
    ) {
        guard prepared.key.market == market else { return }
        autoTarget.recordConsentTarget(
            key: prepared.key,
            sourceDate: prepared.sourceDate
        )
        guard let today = WallpaperDailyRefreshPolicy.marketDate(
            at: now(),
            market: market
        ), prepared.sourceDate == today else {
            return
        }
        lastDailyAutoRefreshDay = today
    }

    // MARK: Daily automatic refresh

    /// Runs only while the user's persisted automatic opt-in is still active.
    /// Quitting stops the loop; a relaunch resumes it from the saved mode. A
    /// missed boundary is caught up on the next loop wake, including resuming
    /// after system sleep.
    private func synchronizeDailyAutoRefreshLoop() {
        guard autoSyncEnabled, !requiresDisableRetry, service != nil else {
            dailyRefreshTask?.cancel()
            dailyRefreshTask = nil
            return
        }
        startDailyAutoRefreshLoopIfNeeded()
    }

    private func startDailyAutoRefreshLoopIfNeeded() {
        guard dailyRefreshTask == nil else { return }
        dailyRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay: TimeInterval
                do {
                    // Keep `self` scoped to the work block so the sleeping
                    // task does not retain the app model.
                    guard let self else { return }
                    await self.performScheduledAutoRefreshIfDue()
                    guard !Task.isCancelled else { return }
                    delay = self.nextScheduledAutoRefreshDelay()
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func performScheduledAutoRefreshIfDue() async {
        guard autoSyncEnabled, !requiresDisableRetry, service != nil else {
            synchronizeDailyAutoRefreshLoop()
            return
        }
        // A manual refresh already in flight owns this attempt; the loop will
        // retry after that attempt's recorded time.
        guard !isRefreshing else { return }
        let attemptAt = now()
        guard WallpaperDailyRefreshPolicy.isDue(
            now: attemptAt,
            market: market,
            completedDay: lastDailyAutoRefreshDay,
            lastAttemptAt: lastDailyAutoRefreshAttemptAt
        ) else {
            return
        }
        lastDailyAutoRefreshAttemptAt = attemptAt
        let currentGeneration = generation
        let token = beginContentRequest()
        await performRefresh(
            generation: currentGeneration,
            token: token
        )
        if currentGeneration != generation || !autoSyncEnabled || requiresDisableRetry {
            synchronizeDailyAutoRefreshLoop()
        }
    }

    private func nextScheduledAutoRefreshDelay() -> TimeInterval {
        // A manual refresh owns the network right now; avoid a one-second
        // poll while it finishes.
        if isRefreshing { return 30 }
        return WallpaperDailyRefreshPolicy.nextCheckDelay(
            now: now(),
            market: market,
            completedDay: lastDailyAutoRefreshDay,
            lastAttemptAt: lastDailyAutoRefreshAttemptAt
        )
    }

    // MARK: Applied wallpaper protection

    private func refreshAppliedProtection() async {
        guard let error = await displayCoordinator.refreshAppliedProtection(service: service) else {
            return
        }
        wallpaperError = String(appModelLocalized: "无法更新当前壁纸的缓存保护：\(Self.describe(error))")
    }

    private func enforceAutomaticCacheLimits() async {
        await displayCoordinator.enforceAutomaticCacheLimits(service: service)
    }

    // MARK: Storage

    private func refreshStorageSummary() async {
        guard let service else { return }
        let usage = await service.storageUsage()
        storageSummary = MacLocalizedString.resolve("\(StatusFormatter.bytes(usage.totalAssetBytes)) · \(usage.assetCount) 个文件", locale: WallpaperInterfaceLocale.current)
    }

    // MARK: Helpers

    static var repositoryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Daybreak", isDirectory: true)
            .appendingPathComponent("Repository", isDirectory: true)
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(appModelLocalized: "网络不可用，已保留本地缓存。")
            case .timedOut:
                return String(appModelLocalized: "请求超时，已保留本地缓存。")
            case .cancelled:
                return String(appModelLocalized: "请求已取消。")
            default:
                return String(appModelLocalized: "网络请求失败：\(urlError.localizedDescription)")
            }
        }
        if error is RepositoryError {
            return AppErrorCopy.describe(error)
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}


// MARK: - App-language copy

private extension String {
    /// `String(localized:)` defaults to the system language. User-facing model
    /// copy must follow the in-app interface choice instead.
    init(appModelLocalized key: String.LocalizationValue) {
        self.init(
            localized: key,
            locale: WallpaperInterfaceLocale.current
        )
    }
}
