import DaybreakCore
import Foundation

/// The single repository owner for the mobile app.
///
/// `MobileStore` (UI) and `MobileIntentService` (App Intents) both use
/// `MobileDataStore.shared`. All disk and network work is actor-isolated; the
/// repository is opened lazily off the main thread and exactly one
/// `MobileRepositoryLease` is retained for the process lifetime. The one
/// shared-folder sync controller works on the same repository instance
/// (`processRepository()`); it never opens its own.
///
/// A different process that already holds the lease makes this data store fail
/// closed with `repositoryBusyByAnotherProcess`. Nothing is written and the
/// caller can retry; the store never treats the conflict as success.
public actor MobileDataStore: RepositorySnapshotProviding {
    public static let defaultDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Daybreak", isDirectory: true)
            .appendingPathComponent("MobileRepository", isDirectory: true)
    }()

    public static let shared = MobileDataStore()

    public nonisolated let directory: URL

    let settingsStore: any MobileSettingsPersisting
    private let selectionStore: any MobileSelectionPersisting
    let now: @Sendable () -> Date
    private let providerFactory: @Sendable (BingMarketProfile) -> BingProvider

    private var providers: [String: BingProvider] = [:]
    private var lease: MobileRepositoryLease?
    private var repository: WallpaperRepository?
    private var openTask: Task<Result<OpenedRepository, MobileStoreError>, Never>?

    private struct OpenedRepository: Sendable {
        let lease: MobileRepositoryLease
        let repository: WallpaperRepository
    }

    struct ImageRequestKey: Hashable, Sendable {
        let kind: AssetKind
        let wallpaperID: WallpaperID
    }

    struct InFlightImageRequest: @unchecked Sendable {
        let token: UUID
        let task: Task<URL, any Error>
        var waiters: Int
    }

    var inFlightImages: [ImageRequestKey: InFlightImageRequest] = [:]

    public init(
        directory: URL = MobileDataStore.defaultDirectory,
        settingsStore: any MobileSettingsPersisting = UserDefaultsMobileSettingsStore.standard,
        selectionStore: any MobileSelectionPersisting = UserDefaultsMobileSelectionStore.standard,
        now: @escaping @Sendable () -> Date = { Date() },
        providerFactory: (@Sendable (BingMarketProfile) -> BingProvider)? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.settingsStore = settingsStore
        self.selectionStore = selectionStore
        self.now = now
        self.providerFactory = providerFactory ?? { profile in
            BingProvider(profile: profile)
        }
    }

    // MARK: Repository lifecycle

    /// Opens the repository without blocking the caller's executor with disk
    /// I/O. Concurrent callers await the same attempt; no second lease is
    /// acquired for this data store.
    func repositoryOrThrow() async throws -> WallpaperRepository {
        if let repository { return repository }

        if let openTask {
            let result = await openTask.value
            self.openTask = nil
            switch result {
            case .success(let opened):
                lease = opened.lease
                repository = opened.repository
                return opened.repository
            case .failure(let error):
                throw error
            }
        }

        let directory = self.directory
        let task = Task.detached(
            priority: .userInitiated
        ) { () -> Result<OpenedRepository, MobileStoreError> in
            do {
                return .success(try Self.openRepository(at: directory))
            } catch let error as MobileStoreError {
                return .failure(error)
            } catch {
                return .failure(
                    .repositoryUnavailable(MobileErrorText.describe(error))
                )
            }
        }
        openTask = task

        let result = await task.value
        openTask = nil
        switch result {
        case .success(let opened):
            lease = opened.lease
            repository = opened.repository
            return opened.repository
        case .failure(let error):
            throw error
        }
    }

    /// The process-wide repository instance, opened once behind the lease.
    ///
    /// Shared-folder sync must use this instance. Opening another
    /// `WallpaperRepository` over the same directory would duplicate writers
    /// and fail the same-process lease guard.
    func processRepository() async throws -> WallpaperRepository {
        try await repositoryOrThrow()
    }

    private nonisolated static func openRepository(at directory: URL) throws -> OpenedRepository {
        let lease = try MobileRepositoryLease.acquire(directory: directory)
        do {
            let repository = try WallpaperRepository(directory: directory)
            return OpenedRepository(lease: lease, repository: repository)
        } catch {
            throw MobileStoreError.repositoryUnavailable(MobileErrorText.describe(error))
        }
    }

    // MARK: Snapshot and market helpers

    public func repositorySnapshot() async throws -> RepositorySnapshot {
        let repository = try await repositoryOrThrow()
        return await repository.snapshot()
    }

    public nonisolated static func systemMarketResolution(
        locale: Locale = .current
    ) -> BingMarketResolution {
        BingMarketProfile.resolution(
            regionIdentifier: locale.region?.identifier,
            languageIdentifier: locale.language.languageCode?.identifier
        )
    }

    public nonisolated static func resolvedMarket(
        settings: MobileSettings,
        locale: Locale = .current
    ) -> Market {
        if case .market(let market) = settings.marketPreference,
           let profile = BingMarketProfile.profile(for: market) {
            return profile.market
        }
        return systemMarketResolution(locale: locale).profile.market
    }

    public func currentSettings() -> MobileSettings {
        settingsStore.load()
    }

    // MARK: Favorites and selections

    public func favoriteWallpaperIDs() async throws -> Set<WallpaperID> {
        let repository = try await repositoryOrThrow()
        return await repository.snapshot().favoriteWallpaperIDs
    }

    @discardableResult
    public func setFavorite(
        _ wallpaperID: WallpaperID,
        isFavorite: Bool
    ) async throws -> Bool {
        let repository = try await repositoryOrThrow()
        do {
            return try await repository.setFavorite(wallpaperID, isFavorite: isFavorite)
        } catch let error as MobileStoreError {
            throw error
        } catch {
            throw MobileStoreError.persistenceFailed(MobileErrorText.describe(error))
        }
    }

    public func recordCurrentSelection(_ key: OccurrenceKey?) async {
        selectionStore.saveCurrentSelection(key)
    }

    public func recordCurrentSelectionIfAbsent(_ key: OccurrenceKey) async {
        guard await currentSelection() == nil else { return }
        await recordCurrentSelection(key)
    }

    public func currentSelection() async -> OccurrenceKey? {
        selectionStore.loadCurrentSelection()
    }

    // MARK: Image single-flight

    /// Awaits one shared image request. Cancelling this waiter only cancels the
    /// underlying download when no other waiter still needs it; every caller
    /// still observes cancellation instead of receiving a late success.
    func waitForInFlightImage(
        key: ImageRequestKey,
        token: UUID,
        task: Task<URL, any Error>
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            let url = try await task.value
            try Task.checkCancellation()
            return url
        } onCancel: {
            Task { [weak self] in
                await self?.cancelImageWaiter(key: key, token: token)
            }
        }
    }

    func cancelImageWaiter(key: ImageRequestKey, token: UUID) async {
        guard var request = inFlightImages[key], request.token == token else {
            return
        }
        request.waiters -= 1
        guard request.waiters <= 0 else {
            inFlightImages[key] = request
            return
        }
        inFlightImages[key] = nil
        request.task.cancel()
    }

    func finishImageRequest(key: ImageRequestKey, token: UUID) async {
        guard let request = inFlightImages[key], request.token == token else {
            return
        }
        inFlightImages[key] = nil
    }

    // MARK: Cached reads

    public func cachedImageURL(
        kind: AssetKind,
        for wallpaperID: WallpaperID
    ) async throws -> URL? {
        let repository = try await repositoryOrThrow()
        guard let asset = await repository.asset(kind: kind, for: wallpaperID),
              let url = await repository.assetURL(for: asset),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    public func cachedImageData(
        kind: AssetKind,
        for wallpaperID: WallpaperID
    ) async throws -> Data? {
        guard let url = try await cachedImageURL(kind: kind, for: wallpaperID) else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func wallpaperRecord(_ wallpaperID: WallpaperID) async throws -> WallpaperRecord? {
        let repository = try await repositoryOrThrow()
        return await repository.wallpaper(wallpaperID)
    }

    public func latestOccurrence(for wallpaperID: WallpaperID) async throws -> WallpaperOccurrence? {
        let snapshot = try await repositorySnapshot()
        return snapshot.occurrences
            .filter { $0.wallpaperID == wallpaperID }
            .max { lhs, rhs in
                if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
                if lhs.market != rhs.market { return lhs.market < rhs.market }
                return lhs.id.description < rhs.id.description
            }
    }

    public func cachedTodaySnapshot(market: Market) async throws -> MobileTodaySnapshot? {
        let repository = try await repositoryOrThrow()
        guard let profile = BingMarketProfile.profile(for: market) else {
            throw MobileStoreError.unsupportedMarket(market.rawValue)
        }
        guard let marketToday = LocalDate(date: now(), timeZone: profile.timeZone) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }

        let snapshot = await repository.snapshot()
        let occurrences = snapshot.occurrences.filter {
            $0.market == profile.market && $0.localDate <= marketToday
        }
        let occurrence = occurrences.first(where: { $0.localDate == marketToday })
            ?? occurrences.max { lhs, rhs in
                if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
                return lhs.id.description < rhs.id.description
            }
        guard let occurrence else { return nil }

        var warnings: [MobileRefreshWarning] = []
        if occurrence.localDate != marketToday {
            warnings.append(.sourceDateBehind(
                sourceDate: occurrence.localDate,
                marketToday: marketToday
            ))
        }
        return await makeTodaySnapshot(
            market: profile.market,
            marketToday: marketToday,
            occurrence: occurrence,
            snapshot: snapshot,
            repository: repository,
            warnings: warnings
        )
    }

    public func daySnapshot(for key: OccurrenceKey) async throws -> MobileDaySnapshot? {
        let repository = try await repositoryOrThrow()
        let snapshot = await repository.snapshot()
        guard let occurrence = snapshot.occurrences.first(where: { $0.id == key }) else {
            return nil
        }
        return await makeDaySnapshot(
            occurrence: occurrence,
            snapshot: snapshot,
            repository: repository
        )
    }

    // MARK: Snapshot construction

    func makeTodaySnapshot(
        market: Market,
        marketToday: LocalDate,
        occurrence: WallpaperOccurrence,
        snapshot: RepositorySnapshot,
        repository: WallpaperRepository,
        warnings: [MobileRefreshWarning]
    ) async -> MobileTodaySnapshot {
        let thumbnailURL = await readableAssetURL(
            kind: .thumbnail,
            for: occurrence.wallpaperID,
            snapshot: snapshot,
            repository: repository
        )
        let originalURL = await readableAssetURL(
            kind: .original,
            for: occurrence.wallpaperID,
            snapshot: snapshot,
            repository: repository
        )
        let metadata = snapshot.metadata(for: occurrence.id)
        let wallpaper = snapshot.wallpapers.first {
            $0.wallpaperID == occurrence.wallpaperID
        }
        return MobileTodaySnapshot(
            market: market,
            marketToday: marketToday,
            occurrence: occurrence,
            metadata: metadata,
            wallpaper: wallpaper,
            storyMatch: snapshot.storyMatch(for: occurrence.id),
            thumbnailURL: thumbnailURL,
            originalURL: originalURL,
            cachedAt: metadata?.fetchedAt ?? wallpaper?.fetchedAt,
            warnings: warnings,
            isFavorite: snapshot.favoriteWallpaperIDs.contains(occurrence.wallpaperID)
        )
    }

    private func makeDaySnapshot(
        occurrence: WallpaperOccurrence,
        snapshot: RepositorySnapshot,
        repository: WallpaperRepository
    ) async -> MobileDaySnapshot {
        MobileDaySnapshot(
            occurrence: occurrence,
            metadata: snapshot.metadata(for: occurrence.id),
            wallpaper: snapshot.wallpapers.first {
                $0.wallpaperID == occurrence.wallpaperID
            },
            storyMatch: snapshot.storyMatch(for: occurrence.id),
            thumbnailURL: await readableAssetURL(
                kind: .thumbnail,
                for: occurrence.wallpaperID,
                snapshot: snapshot,
                repository: repository
            ),
            originalURL: await readableAssetURL(
                kind: .original,
                for: occurrence.wallpaperID,
                snapshot: snapshot,
                repository: repository
            ),
            isFavorite: snapshot.favoriteWallpaperIDs.contains(occurrence.wallpaperID)
        )
    }

    private func readableAssetURL(
        kind: AssetKind,
        for wallpaperID: WallpaperID,
        snapshot: RepositorySnapshot,
        repository: WallpaperRepository
    ) async -> URL? {
        guard let asset = snapshot.asset(kind: kind, for: wallpaperID),
              !snapshot.missingAssets.contains(where: { $0.id == asset.id }),
              let url = await repository.assetURL(for: asset),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    // MARK: Providers

    func provider(for market: Market) throws -> BingProvider {
        guard let profile = BingMarketProfile.profile(for: market) else {
            throw MobileStoreError.unsupportedMarket(market.rawValue)
        }
        let key = profile.market.rawValue
        if let existing = providers[key] {
            return existing
        }
        let provider = providerFactory(profile)
        providers[key] = provider
        return provider
    }

    static func mapProviderError(_ error: BingProviderError) -> MobileStoreError {
        switch error {
        case .transport:
            return .offline(MobileErrorText.describe(error))
        default:
            return .refreshFailed(MobileErrorText.describe(error))
        }
    }

    static func mapImageError(_ error: BingProviderError) -> MobileStoreError {
        switch error {
        case .transport:
            return .offline(MobileErrorText.describe(error))
        default:
            return .imageUnavailable(MobileErrorText.describe(error))
        }
    }

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    static func mimeType(forFileExtension value: String) -> String {
        switch value.lowercased() {
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }
}
