import DaybreakCore
import Foundation
import Observation

/// Process-wide, main-actor observable facade for the mobile app.
///
/// The facade owns only view-facing state. Content reads, content writes and
/// network operations go through the single `MobileDataStore` actor.
/// Shared-folder sync uses the same leased repository through the one
/// process-wide `DaybreakSyncController`, so multiple scenes and App Intents
/// never open independent writers.
@MainActor
@Observable
public final class MobileStore {
    public static let defaultDirectory = MobileDataStore.defaultDirectory
    public static let shared = MobileStore()

    /// Device-local directory for the sync checkpoint and folder bookmark.
    /// It is never the user-selected shared folder and never inside it.
    static func syncStateDirectory(for repositoryDirectory: URL) -> URL {
        repositoryDirectory.standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Sync", isDirectory: true)
    }

    /// Device-local directory that holds the sync checkpoint, folder bookmark
    /// and bounded diagnostic log. The sync page reads the log from here when
    /// the user explicitly exports a report; this is never the user-selected
    /// shared folder and no path is shown in the report.
    var syncDiagnosticsDirectoryURL: URL {
        syncStateDirectory
    }

    // MARK: Observable state

    public private(set) var settings: MobileSettings
    public private(set) var effectiveMarket: Market
    public private(set) var today: MobileTodaySnapshot?
    public private(set) var isLoadingCache = false
    public private(set) var isRefreshing = false
    public private(set) var isDownloadingOriginal = false
    public private(set) var isUpdatingMarket = false
    public private(set) var lastError: MobileStoreError?
    public private(set) var favoriteWallpaperIDs: Set<WallpaperID> = []
    public private(set) var storageUsage: StorageUsage?
    public private(set) var cacheProtectionCounts: [PinReason: Int] = [:]
    public private(set) var isStorageBusy = false
    public private(set) var storageError: MobileStoreError?
    public private(set) var storageFeedback: String?
    public private(set) var dataRevision = 0
    public private(set) var lastUpdated: Date?
    /// The one shared-folder controller for this app process.
    ///
    /// Nil only until the leased repository is open: the controller needs that
    /// exact repository instance, so it cannot be created in the synchronous
    /// initializer. Scenes share this `MobileStore`, therefore they share the
    /// same controller; App Intents never create one.
    public private(set) var syncController: DaybreakSyncController?

    // MARK: Dependencies

    @ObservationIgnored private let dataStore: MobileDataStore
    @ObservationIgnored private let settingsStore: any MobileSettingsPersisting
    @ObservationIgnored private let timelineService: TimelineService
    @ObservationIgnored private let recapService: RecapService
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let syncStateDirectory: URL
    @ObservationIgnored private let syncMarket = SyncMarketProvider()

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var syncControllerTask: Task<DaybreakSyncController?, Never>?

    // MARK: Initialization

    public convenience init() {
        self.init(directory: Self.defaultDirectory)
    }

    /// Creates the app-facing store. The default directory always reuses the
    /// process-wide repository; a distinct directory creates an isolated
    /// repository for tests or previews only.
    public convenience init(directory: URL) {
        self.init(
            directory: directory,
            settingsStore: UserDefaultsMobileSettingsStore.standard,
            defaults: .standard,
            now: { Date() }
        )
    }

    init(
        directory: URL,
        settingsStore: any MobileSettingsPersisting,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date = { Date() },
        syncStateDirectory: URL? = nil,
        providerFactory: (@Sendable (BingMarketProfile) -> BingProvider)? = nil
    ) {
        let normalizedDirectory = directory.standardizedFileURL
        let dataStore: MobileDataStore
        if normalizedDirectory == Self.defaultDirectory.standardizedFileURL {
            dataStore = .shared
        } else {
            dataStore = MobileDataStore(
                directory: normalizedDirectory,
                settingsStore: settingsStore,
                selectionStore: UserDefaultsMobileSelectionStore(defaults: defaults),
                now: now,
                providerFactory: providerFactory
            )
        }

        let loadedSettings = settingsStore.load()
        self.dataStore = dataStore
        self.settingsStore = settingsStore
        self.timelineService = TimelineService(snapshotProvider: dataStore)
        self.recapService = RecapService(snapshotProvider: dataStore)
        self.now = now
        self.syncStateDirectory = syncStateDirectory
            ?? Self.syncStateDirectory(for: normalizedDirectory)
        self.settings = loadedSettings
        let market = MobileDataStore.resolvedMarket(settings: loadedSettings)
        self.effectiveMarket = market
        syncMarket.market = market
    }

    // MARK: Derived preferences

    public var interfaceLanguage: MobileInterfaceLanguage {
        settings.interfaceLanguage
    }

    public var interfaceLocale: Locale {
        settings.interfaceLanguage.locale
    }

    public var marketSelection: MobileMarketPreference {
        settings.marketPreference
    }

    public var isFollowingSystemMarket: Bool {
        settings.marketPreference == .followSystem
    }

    public var systemMarketResolution: BingMarketResolution {
        MobileDataStore.systemMarketResolution(locale: .current)
    }

    public var systemMarket: Market {
        systemMarketResolution.profile.market
    }

    public var supportedMarketProfiles: [BingMarketProfile] {
        BingMarketProfile.catalog
    }

    /// Explains a non-exact "follow system" mapping without pretending the
    /// device region matched a Bing edition.
    public var marketSelectionNotice: String? {
        guard isFollowingSystemMarket else { return nil }
        let resolution = systemMarketResolution
        guard !resolution.isExactMatch else { return nil }
        return String(
            format: MobileLocalizedString.resolve(
                "系统地区没有精确匹配的 Bing 地区，当前使用 %@。",
                locale: interfaceLocale
            ),
            effectiveMarket.rawValue
        )
    }

    public var selectedMarket: Market { effectiveMarket }

    public var isTodayFavorite: Bool {
        guard let wallpaperID = today?.wallpaperID else { return false }
        return favoriteWallpaperIDs.contains(wallpaperID)
    }

    public var todayPhase: MobileTodayPhase {
        if isLoadingCache && today == nil {
            return .loadingCache
        }
        if isRefreshing {
            return .refreshing
        }
        if today != nil {
            return .ready
        }
        if let lastError {
            return .failed(lastError.errorDescription ?? "")
        }
        return .empty
    }

    public var lastErrorMessage: String? {
        lastError?.errorDescription
    }

    public var cacheCapacityBytes: Int64 {
        settings.totalCacheLimitBytes
    }

    public var cacheLimits: CacheLimits {
        settings.cacheLimits
    }

    // MARK: Lifecycle

    /// Loads cached content first, then refreshes only when the market-local
    /// today is not yet represented by a stored occurrence. Idempotent.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        recomputeEffectiveMarket()

        // Open the leased repository once and attach the process-wide sync
        // controller. Restoring the controller schedules the launch pass when
        // sync is already enabled; a failure here leaves sync detached while
        // the normal cache and refresh paths report repository errors.
        await prepareSyncController()

        isLoadingCache = true
        do {
            today = try await dataStore.cachedTodaySnapshot(market: effectiveMarket)
            favoriteWallpaperIDs = try await dataStore.favoriteWallpaperIDs()
            storageUsage = try await dataStore.storageUsage()
            lastError = nil
            if let today {
                lastUpdated = today.cachedAt
            }
        } catch is CancellationError {
            isLoadingCache = false
            hasStarted = false
            return
        } catch let error as MobileStoreError {
            lastError = error
        } catch {
            lastError = .repositoryUnavailable(MobileErrorText.describe(error))
        }
        isLoadingCache = false

        if today == nil || today?.isSourceDateToday == false {
            await refreshToday()
        } else if let today {
            await dataStore.recordCurrentSelectionIfAbsent(today.key)
        }
    }

    public func refreshToday() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let market = effectiveMarket
        isRefreshing = true
        lastError = nil
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }

        do {
            let snapshot = try await dataStore.refreshToday(market: market)
            guard generation == refreshGeneration, market == effectiveMarket else {
                return
            }
            today = snapshot
            lastUpdated = now()
            favoriteWallpaperIDs = try await dataStore.favoriteWallpaperIDs()
            storageUsage = try await dataStore.storageUsage()
            dataRevision += 1
            await dataStore.recordCurrentSelectionIfAbsent(snapshot.key)
            await noteSyncAfterLocalChange()
        } catch is CancellationError {
            return
        } catch let error as MobileStoreError {
            guard generation == refreshGeneration, market == effectiveMarket else {
                return
            }
            lastError = error
            if today == nil {
                today = try? await dataStore.cachedTodaySnapshot(market: market)
            }
        } catch {
            guard generation == refreshGeneration, market == effectiveMarket else {
                return
            }
            lastError = .refreshFailed(MobileErrorText.describe(error))
            if today == nil {
                today = try? await dataStore.cachedTodaySnapshot(market: market)
            }
        }
    }

    /// Foreground/scheduled check. A cached occurrence for the market's
    /// current date avoids a network request; an older or missing one
    /// refreshes.
    public func refreshIfNeeded() async {
        if isRefreshing { return }
        if !hasStarted {
            await start()
            return
        }
        guard let profile = BingMarketProfile.profile(for: effectiveMarket),
              let marketToday = LocalDate(date: now(), timeZone: profile.timeZone)
        else {
            return
        }
        if let today,
           today.market == effectiveMarket,
           today.sourceDate == marketToday {
            return
        }
        await refreshToday()
    }

    /// Foreground/wake trigger for shared-folder sync.
    ///
    /// Every scene calls this once per activation; the single controller
    /// coalesces the triggers, so extra windows never create a parallel pass.
    /// Disabled sync and an unauthorized folder are no-ops inside the
    /// controller, and this returns without waiting for a pass.
    public func noteForegroundActivity() async {
        guard let controller = await prepareSyncController() else { return }
        await controller.noteForegroundActivity()
    }

    // MARK: Today actions

    /// Downloads and caches the current original. Returns nil and sets
    /// `lastError` on failure; cached content remains visible.
    @discardableResult
    public func loadTodayOriginal() async -> URL? {
        guard let snapshot = today else {
            lastError = .noCachedImage("no current occurrence")
            return nil
        }
        guard !isDownloadingOriginal else { return snapshot.originalURL }
        isDownloadingOriginal = true
        defer { isDownloadingOriginal = false }

        do {
            let url = try await dataStore.ensureImage(
                kind: .original,
                for: snapshot.occurrence,
                allowNetwork: true
            )
            if let refreshed = try? await dataStore.cachedTodaySnapshot(
                market: snapshot.market
            ) {
                today = refreshed.withWarnings(snapshot.warnings)
                lastUpdated = refreshed.cachedAt
            }
            storageUsage = try? await dataStore.storageUsage()
            lastError = nil
            dataRevision += 1
            return url
        } catch is CancellationError {
            return nil
        } catch let error as MobileStoreError {
            lastError = error
            return nil
        } catch {
            lastError = .imageUnavailable(MobileErrorText.describe(error))
            return nil
        }
    }

    public func toggleTodayFavorite() async {
        guard let wallpaperID = today?.wallpaperID else { return }
        do {
            try await dataStore.setFavorite(
                wallpaperID,
                isFavorite: !favoriteWallpaperIDs.contains(wallpaperID)
            )
            favoriteWallpaperIDs = try await dataStore.favoriteWallpaperIDs()
            lastError = nil
            dataRevision += 1
            await noteSyncAfterLocalChange()
        } catch let error as MobileStoreError {
            lastError = error
        } catch {
            lastError = .persistenceFailed(MobileErrorText.describe(error))
        }
    }

    public func isFavorite(_ wallpaperID: WallpaperID) -> Bool {
        favoriteWallpaperIDs.contains(wallpaperID)
    }

    // MARK: Image access

    public func imageURL(
        for wallpaperID: WallpaperID,
        variant: AssetKind
    ) async -> URL? {
        (try? await dataStore.cachedImageURL(kind: variant, for: wallpaperID)) ?? nil
    }

    public func imageData(
        for wallpaperID: WallpaperID,
        variant: AssetKind
    ) async -> Data? {
        (try? await dataStore.cachedImageData(kind: variant, for: wallpaperID)) ?? nil
    }

    /// Original if cached, otherwise a cached thumbnail. Never downloads.
    public func displayImageFileURL(for wallpaperID: WallpaperID) async -> URL? {
        if let original = await imageURL(for: wallpaperID, variant: .original) {
            return original
        }
        return await imageURL(for: wallpaperID, variant: .thumbnail)
    }

    public func originalImageFileURL(for wallpaperID: WallpaperID) async -> URL? {
        await imageURL(for: wallpaperID, variant: .original)
    }

    public func ensureOriginalImage(
        for wallpaperID: WallpaperID,
        allowNetwork: Bool = true
    ) async throws -> URL {
        let url = try await dataStore.ensureOriginalImage(
            for: wallpaperID,
            allowNetwork: allowNetwork
        )
        storageUsage = try? await dataStore.storageUsage()
        dataRevision += 1
        return url
    }

    public func ensureImage(
        kind: AssetKind,
        for occurrence: WallpaperOccurrence,
        allowNetwork: Bool = true
    ) async throws -> URL {
        let url = try await dataStore.ensureImage(
            kind: kind,
            for: occurrence,
            allowNetwork: allowNetwork
        )
        storageUsage = try? await dataStore.storageUsage()
        dataRevision += 1
        return url
    }

    public func daySnapshot(for key: OccurrenceKey) async -> MobileDaySnapshot? {
        try? await dataStore.daySnapshot(for: key)
    }

    // MARK: Timeline contract

    public func setSelectedMarket(_ market: Market) async {
        await setMarketSelection(.market(market))
    }

    public func timelineSnapshot() async throws -> RepositorySnapshot {
        try await dataStore.repositorySnapshot()
    }

    public func timelineAssetURL(
        kind: AssetKind,
        wallpaperID: WallpaperID
    ) async -> URL? {
        await imageURL(for: wallpaperID, variant: kind)
    }

    public func timelineEnsureAsset(
        kind: AssetKind,
        for occurrence: WallpaperOccurrence,
        allowNetwork: Bool
    ) async throws -> URL {
        let url = try await dataStore.ensureImage(
            kind: kind,
            for: occurrence,
            allowNetwork: allowNetwork
        )
        storageUsage = try? await dataStore.storageUsage()
        dataRevision += 1
        return url
    }

    public func timelineSetFavorite(
        _ wallpaperID: WallpaperID,
        isFavorite: Bool
    ) async throws {
        let changed = try await dataStore.setFavorite(
            wallpaperID,
            isFavorite: isFavorite
        )
        favoriteWallpaperIDs = try await dataStore.favoriteWallpaperIDs()
        dataRevision += 1
        if changed {
            await noteSyncAfterLocalChange()
        }
    }

    // MARK: Timeline and recap queries

    public func timelineMonth(year: Int, month: Int) async throws -> TimelineMonth {
        guard let asOf = marketToday(for: effectiveMarket) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }
        return try await timelineService.month(
            year: year,
            month: month,
            market: effectiveMarket,
            asOf: asOf
        )
    }

    public func timelineMonth(
        year: Int,
        month: Int,
        market: Market,
        asOf: LocalDate
    ) async throws -> TimelineMonth {
        try await timelineService.month(
            year: year,
            month: month,
            market: market,
            asOf: asOf
        )
    }

    public func timelineDay(
        _ date: LocalDate,
        market: Market? = nil
    ) async throws -> TimelineDay {
        let resolvedMarket = market ?? effectiveMarket
        guard let asOf = marketToday(for: resolvedMarket) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }
        return try await timelineService.day(
            for: date,
            market: resolvedMarket,
            asOf: asOf
        )
    }

    public func monthlyRecap(
        year: Int,
        month: Int,
        markets: Set<Market>? = nil
    ) async throws -> MonthlyRecap {
        guard let asOf = marketToday(for: effectiveMarket) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }
        return try await recapService.monthlyRecap(
            year: year,
            month: month,
            asOf: asOf,
            markets: markets
        )
    }

    public func yearlyRecap(
        year: Int,
        markets: Set<Market>? = nil
    ) async throws -> YearlyRecap {
        guard let asOf = marketToday(for: effectiveMarket) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }
        return try await recapService.yearlyRecap(
            year: year,
            asOf: asOf,
            markets: markets
        )
    }

    public func favoriteRecap(
        markets: Set<Market>? = nil
    ) async throws -> FavoriteRecap {
        guard let asOf = marketToday(for: effectiveMarket) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }
        return try await recapService.favoriteRecap(
            asOf: asOf,
            markets: markets
        )
    }

    // MARK: Settings

    public func setInterfaceLanguage(_ language: MobileInterfaceLanguage) async {
        guard settings.interfaceLanguage != language else { return }
        settings.interfaceLanguage = language
        settingsStore.save(settings)
    }

    public func setMarketSelection(_ selection: MobileMarketPreference) async {
        let normalized: MobileMarketPreference
        switch selection {
        case .followSystem:
            normalized = .followSystem
        case .market(let market):
            guard let profile = BingMarketProfile.profile(for: market) else {
                lastError = .unsupportedMarket(market.rawValue)
                return
            }
            normalized = .market(profile.market)
        }

        guard normalized != settings.marketPreference else { return }

        isUpdatingMarket = true
        defer { isUpdatingMarket = false }

        settings.marketPreference = normalized
        settingsStore.save(settings)
        recomputeEffectiveMarket()

        isLoadingCache = true
        if let cached = try? await dataStore.cachedTodaySnapshot(market: effectiveMarket) {
            today = cached
        } else {
            today = nil
        }
        isLoadingCache = false
        await refreshToday()
    }

    public func setImageQuality(_ quality: BingImagePreference) async {
        guard settings.imageQuality != quality else { return }
        settings.imageQuality = quality
        settingsStore.save(settings)
    }

    /// Applies a total capacity preset using the documented 20/80 split and
    /// immediately evicts unprotected least-recently-used assets.
    public func setCacheCapacity(_ bytes: Int64) async throws -> CacheEvictionResult {
        guard bytes >= 0 else {
            throw MobileStoreError.invalidSelection("negative cache capacity")
        }
        let total = Int(min(bytes, Int64(Int.max)))
        let thumbnail = total / 5
        let original = total - thumbnail

        settings.thumbnailCacheLimitBytes = thumbnail
        settings.originalCacheLimitBytes = original
        settingsStore.save(settings)
        storageError = nil

        do {
            let result = try await dataStore.evict(limits: settings.cacheLimits)
            storageUsage = try? await dataStore.storageUsage()
            storageFeedback = String(
                format: MobileLocalizedString.resolve(
                    "已应用 %@ 上限，清理 %lld 个文件，释放 %@。",
                    locale: interfaceLocale
                ),
                MobileErrorText.bytes(total),
                result.evictedAssets.count,
                MobileErrorText.bytes(result.evictedBytes)
            )
            return result
        } catch let error as MobileStoreError {
            storageError = error
            throw error
        } catch {
            let mapped = MobileStoreError.cacheOperationFailed(
                MobileErrorText.describe(error)
            )
            storageError = mapped
            throw mapped
        }
    }

    public func refreshStorage() async {
        do {
            _ = try await cacheReport()
        } catch {
            // cacheReport records storageError.
        }
    }

    public func cacheReport() async throws -> MobileCacheReport {
        do {
            let report = try await dataStore.cacheReport()
            storageUsage = report.usage
            cacheProtectionCounts = report.protectedImageCountsByReason
            storageError = nil
            return report
        } catch let error as MobileStoreError {
            storageError = error
            throw error
        } catch {
            let mapped = MobileStoreError.cacheOperationFailed(
                MobileErrorText.describe(error)
            )
            storageError = mapped
            throw mapped
        }
    }

    public func clearThumbnails() async throws -> MobileCacheClearResult {
        try beginStorageOperation()
        defer { endStorageOperation() }
        do {
            let result = try await dataStore.clearThumbnails()
            await refreshStorageAfterMutation()
            storageFeedback = String(
                format: MobileLocalizedString.resolve(
                    "已清理 %lld 个缩略图，释放 %@。",
                    locale: interfaceLocale
                ),
                result.removedAssetCount,
                MobileErrorText.bytes(result.removedBytes)
            )
            return result
        } catch {
            throw recordStorageFailure(error)
        }
    }

    public func clearOriginals() async throws -> MobileCacheClearResult {
        try beginStorageOperation()
        defer { endStorageOperation() }
        do {
            let result = try await dataStore.clearOriginals()
            await refreshStorageAfterMutation()
            var message = String(
                format: MobileLocalizedString.resolve(
                    "已清理 %lld 个未受保护原图，释放 %@。",
                    locale: interfaceLocale
                ),
                result.removedAssetCount,
                MobileErrorText.bytes(result.removedBytes)
            )
            if result.skippedProtectedCount > 0 {
                message += String(
                    format: MobileLocalizedString.resolve(
                        " %lld 个受保护原图已保留。",
                        locale: interfaceLocale
                    ),
                    result.skippedProtectedCount
                )
            }
            storageFeedback = message
            return result
        } catch {
            throw recordStorageFailure(error)
        }
    }

    public func clearStories() async throws -> Int {
        try beginStorageOperation()
        defer { endStorageOperation() }
        do {
            let count = try await dataStore.clearStories()
            dataRevision += 1
            storageFeedback = String(
                format: MobileLocalizedString.resolve(
                    "已清理 %lld 条每日介绍。",
                    locale: interfaceLocale
                ),
                count
            )
            return count
        } catch {
            throw recordStorageFailure(error)
        }
    }

    public func repairCache() async throws -> RepositoryRepairReport {
        try beginStorageOperation()
        defer { endStorageOperation() }
        do {
            let report = try await dataStore.repairCache()
            storageUsage = try? await dataStore.storageUsage()
            dataRevision += 1
            var message = String(
                format: MobileLocalizedString.resolve(
                    "已移除 %lld 个孤儿文件。",
                    locale: interfaceLocale
                ),
                report.orphanedFilesRemoved.count
            )
            if !report.missingAssets.isEmpty {
                message += String(
                    format: MobileLocalizedString.resolve(
                        " %lld 个记录缺少本地文件，可联网后重新获取。",
                        locale: interfaceLocale
                    ),
                    report.missingAssets.count
                )
            }
            storageFeedback = message
            return report
        } catch {
            throw recordStorageFailure(error)
        }
    }

    // MARK: Shared-folder sync

    /// Creates the one sync controller for this app process after the shared
    /// leased repository is open.
    ///
    /// Concurrent scenes await the same task. A failed open leaves the
    /// property nil so a later launch or foreground can retry; it never opens
    /// a second repository or substitutes a controller without one.
    @discardableResult
    private func prepareSyncController() async -> DaybreakSyncController? {
        if let syncController { return syncController }
        if let syncControllerTask { return await syncControllerTask.value }

        let dataStore = self.dataStore
        let stateDirectory = syncStateDirectory
        let marketProvider = syncMarket
        let task = Task { @MainActor [weak self] () -> DaybreakSyncController? in
            guard let self else { return nil }
            do {
                let repository = try await dataStore.processRepository()
                if let existing = self.syncController { return existing }
                let controller = DaybreakSyncController(
                    repository: repository,
                    stateDirectory: stateDirectory,
                    market: { marketProvider.market }
                )
                self.syncController = controller
                self.observeSyncImports(controller)
                // Restore and the launch pass run in the controller's own
                // task: folder IO must never delay the first content read.
                Task { @MainActor in
                    await controller.prepare()
                }
                return controller
            } catch {
                return nil
            }
        }
        syncControllerTask = task
        let controller = await task.value
        syncControllerTask = nil
        return controller
    }

    /// Fire-and-forget notification after a local favorite, metadata or story
    /// change. The controller runs the pass in its own task, so this never
    /// blocks the user action.
    private func noteSyncAfterLocalChange() async {
        guard let controller = await prepareSyncController() else { return }
        await controller.noteForegroundActivity()
    }

    /// Re-reads state a completed pass imported, so imported favorites,
    /// stories, metadata and assets become visible without a relaunch.
    private func observeSyncImports(_ controller: DaybreakSyncController) {
        withObservationTracking {
            _ = controller.dataRevision
        } onChange: { [weak self, weak controller] in
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else { return }
                await self.reloadAfterSyncImport()
                self.observeSyncImports(controller)
            }
        }
    }

    private func reloadAfterSyncImport() async {
        if let refreshed = try? await dataStore.cachedTodaySnapshot(
            market: effectiveMarket
        ) {
            today = refreshed
            lastUpdated = refreshed.cachedAt
        }
        if let favorites = try? await dataStore.favoriteWallpaperIDs() {
            favoriteWallpaperIDs = favorites
        }
        storageUsage = try? await dataStore.storageUsage()
        dataRevision += 1
    }

    // MARK: Selections

    public func recordCurrentSelection(_ key: OccurrenceKey?) async {
        await dataStore.recordCurrentSelection(key)
    }

    public func currentSelection() async -> OccurrenceKey? {
        await dataStore.currentSelection()
    }

    // MARK: Internals

    private func recomputeEffectiveMarket() {
        effectiveMarket = MobileDataStore.resolvedMarket(settings: settings)
        syncMarket.market = effectiveMarket
    }

    private func marketToday(for market: Market) -> LocalDate? {
        guard let profile = BingMarketProfile.profile(for: market) else { return nil }
        return LocalDate(date: now(), timeZone: profile.timeZone)
    }

    private func beginStorageOperation() throws {
        guard !isStorageBusy else {
            throw MobileStoreError.operationInProgress
        }
        isStorageBusy = true
        storageError = nil
        storageFeedback = nil
    }

    private func endStorageOperation() {
        isStorageBusy = false
    }

    private func refreshStorageAfterMutation() async {
        dataRevision += 1
        _ = try? await cacheReport()
    }

    private func recordStorageFailure(_ error: any Error) -> MobileStoreError {
        let mapped: MobileStoreError
        if let mobile = error as? MobileStoreError {
            mapped = mobile
        } else {
            mapped = .cacheOperationFailed(MobileErrorText.describe(error))
        }
        storageError = mapped
        return mapped
    }
}

/// Market value shared with the controller's `@Sendable` scope closure.
///
/// The controller evaluates the closure during a pass; the store updates the
/// value on the main actor whenever the effective market changes. The lock
/// keeps that hand-off valid for the closure's nonisolated type.
private final class SyncMarketProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Market = .zhCN

    var market: Market {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
