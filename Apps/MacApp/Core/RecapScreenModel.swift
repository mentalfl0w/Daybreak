import AppKit
import DaybreakCore
import Foundation
import Observation

// MARK: - Sections

enum RecapSection: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case yearly
    case favorites

    var id: String { rawValue }

    var title: String {
        title(in: WallpaperInterfaceLocale.current)
    }

    func title(in locale: Locale) -> String {
        switch self {
        case .monthly: return MacLocalizedString.resolve("月度", locale: locale)
        case .yearly: return MacLocalizedString.resolve("年度", locale: locale)
        case .favorites: return MacLocalizedString.resolve("收藏", locale: locale)
        }
    }
}

// MARK: - Destructive actions

/// Every entry here is destructive and is presented by the UI behind an
/// explicit confirmation. None of them removes metadata, and bulk asset
/// cleanup relies on the repository's protection rules so favorites, pinned
/// dates and currently applied images survive.
enum RecapCleanupAction: Identifiable, Equatable, Sendable {
    case clearUnprotectedThumbnails
    case clearUnprotectedOriginals
    case applyDefaultLimits
    case clearStories
    case repairIndex
    case removeAsset(kind: AssetKind, wallpaperID: WallpaperID)
    case removeFavorite(WallpaperID)

    var id: String {
        switch self {
        case .clearUnprotectedThumbnails:
            return "clear-unprotected-thumbnails"
        case .clearUnprotectedOriginals:
            return "clear-unprotected-originals"
        case .applyDefaultLimits:
            return "apply-default-limits"
        case .clearStories:
            return "clear-stories"
        case .repairIndex:
            return "repair-index"
        case .removeAsset(let kind, let wallpaperID):
            return "remove-asset:\(kind.rawValue):\(wallpaperID.description)"
        case .removeFavorite(let wallpaperID):
            return "remove-favorite:\(wallpaperID.description)"
        }
    }

    var title: String {
        title(in: WallpaperInterfaceLocale.current)
    }

    func title(in locale: Locale) -> String {
        switch self {
        case .clearUnprotectedThumbnails:
            return MacLocalizedString.resolve("清理未受保护缩略图？", locale: locale)
        case .clearUnprotectedOriginals:
            return MacLocalizedString.resolve("清理未受保护原图？", locale: locale)
        case .applyDefaultLimits:
            return MacLocalizedString.resolve("按内置上限清理缓存？", locale: locale)
        case .clearStories:
            return MacLocalizedString.resolve("清除已缓存的介绍文本？", locale: locale)
        case .repairIndex:
            return MacLocalizedString.resolve("修复本地缓存？", locale: locale)
        case .removeAsset(let kind, _):
            return kind == .original
                ? MacLocalizedString.resolve("删除这张原图缓存？", locale: locale)
                : MacLocalizedString.resolve("删除这张缩略图缓存？", locale: locale)
        case .removeFavorite:
            return MacLocalizedString.resolve("取消这张图片的收藏？", locale: locale)
        }
    }

    var message: String {
        message(in: WallpaperInterfaceLocale.current)
    }

    func message(in locale: Locale) -> String {
        switch self {
        case .clearUnprotectedThumbnails:
            return MacLocalizedString.resolve("只删除未被收藏、固定日期或当前壁纸保护的缩略图。原图、图片信息、介绍和收藏都会保留，缩略图可在联网后重新缓存。", locale: locale)
        case .clearUnprotectedOriginals:
            return MacLocalizedString.resolve("只删除未被收藏、固定日期或当前壁纸保护的原图。缩略图、图片信息、介绍和收藏都会保留；删除的原图需要重新下载才能设为壁纸。", locale: locale)
        case .applyDefaultLimits:
            return MacLocalizedString.resolve("按内置默认上限（缩略图 200 MB、原图 800 MB）清理最久未使用的缓存。收藏、固定日期和当前使用的图片不会被删除；介绍文本也会保留。", locale: locale)
        case .clearStories:
            return MacLocalizedString.resolve("删除所有已缓存的每日介绍文本。图片、图片信息、收藏和固定日期保持不变；介绍需要在联网后重新获取。此操作不可撤销。", locale: locale)
        case .repairIndex:
            return MacLocalizedString.resolve("移除缓存中没有任何记录引用的残留文件，并检查记录中缺失的文件。不会删除图片信息、介绍、收藏或受保护图片。", locale: locale)
        case .removeAsset:
            return MacLocalizedString.resolve("只删除这一份缓存文件，图片信息与介绍保持不变。受收藏、固定日期或当前壁纸保护的图片会被拒绝删除。", locale: locale)
        case .removeFavorite:
            return MacLocalizedString.resolve("取消收藏后，这张图片不再受收藏保护；之后的缓存清理可能删除缩略图或原图。本机图片信息、介绍以及固定日期/当前壁纸保护不受影响。", locale: locale)
        }
    }

    var confirmLabel: String {
        confirmLabel(in: WallpaperInterfaceLocale.current)
    }

    func confirmLabel(in locale: Locale) -> String {
        switch self {
        case .clearUnprotectedThumbnails, .clearUnprotectedOriginals, .applyDefaultLimits:
            return MacLocalizedString.resolve("清理", locale: locale)
        case .clearStories:
            return MacLocalizedString.resolve("清除介绍", locale: locale)
        case .repairIndex:
            return MacLocalizedString.resolve("修复", locale: locale)
        case .removeAsset:
            return MacLocalizedString.resolve("删除缓存", locale: locale)
        case .removeFavorite:
            return MacLocalizedString.resolve("取消收藏", locale: locale)
        }
    }
}

// MARK: - Storage rows

struct RecapAssetRow: Identifiable, Equatable, Sendable {
    let asset: CachedImageAsset
    let title: String?
    let protection: Set<PinReason>
    let isMissing: Bool

    var id: String { asset.id }

    var isProtected: Bool { !protection.isEmpty }

    var protectionLabel: String {
        if protection.isEmpty { return MacLocalizedString.resolve("可清理", locale: WallpaperInterfaceLocale.current) }
        return protection
            .map { RecapCopy.protectionLabel($0) }
            .sorted()
            .joined(separator: " · ")
    }
}

// MARK: - Story presentation

/// Mirrors the Today screen's strict story rules: only a matched, available
/// record may expose body text. Unavailable or unmatched records never do.
enum RecapStoryPresentation: Equatable, Sendable {
    case available(StoryText)
    case unavailable(
        reason: StoryUnavailableReason,
        headline: String?,
        copyright: String?,
        sourceURL: URL?
    )
    case unmatched(hasCandidates: Bool)
    case notFetched

    init(
        match: StoryMatch,
        fallbackCopyright: String?,
        fallbackSourceURL: URL?
    ) {
        switch match {
        case .matched(let story, _):
            if story.isAvailable {
                self = .available(StoryText(
                    title: story.title,
                    headline: story.headline,
                    body: story.body,
                    quickFact: story.quickFact,
                    copyright: story.copyright ?? fallbackCopyright,
                    sourceURL: story.sourceURL ?? fallbackSourceURL,
                    locale: story.originalLocale,
                    fetchedAt: story.fetchedAt
                ))
            } else {
                self = .unavailable(
                    reason: Self.reason(for: story.availability),
                    headline: story.headline,
                    copyright: story.copyright ?? fallbackCopyright,
                    sourceURL: story.sourceURL ?? fallbackSourceURL
                )
            }
        case .unavailable(let story):
            self = .unavailable(
                reason: Self.reason(for: story.availability),
                headline: story.headline,
                copyright: story.copyright ?? fallbackCopyright,
                sourceURL: story.sourceURL ?? fallbackSourceURL
            )
        case .unmatched(let failure):
            switch failure {
            case .noCandidate:
                self = .notFetched
            case .imageIdentityMissing, .dateMismatch, .marketMismatch,
                 .imageIdentityConflict, .ambiguousCandidates:
                self = .unmatched(hasCandidates: true)
            }
        }
    }

    private static func reason(for availability: StoryAvailability) -> StoryUnavailableReason {
        switch availability {
        case .available:
            return .emptyContent
        case .unavailable(let reason):
            return reason
        }
    }
}

// MARK: - Errors

enum RecapScreenError: Error, Equatable, LocalizedError, Sendable {
    case clockUnavailable
    case protectedAsset
    case missingAsset
    /// The current desktop wallpaper has not been reconciled yet, so deleting
    /// originals could remove the image that is actually in use.
    case appliedProtectionUnavailable

    var errorDescription: String? {
        description(in: WallpaperInterfaceLocale.current)
    }

    func description(in locale: Locale) -> String {
        switch self {
        case .clockUnavailable:
            return MacLocalizedString.resolve("无法按来源地区换算当前日期，暂不生成回顾。", locale: locale)
        case .protectedAsset:
            return MacLocalizedString.resolve("该图片受收藏、固定日期或当前壁纸保护，不能单独删除缓存。请先在对应界面解除保护。", locale: locale)
        case .missingAsset:
            return MacLocalizedString.resolve("该缓存项已不存在，列表已刷新。", locale: locale)
        case .appliedProtectionUnavailable:
            return MacLocalizedString.resolve("暂时无法确认当前桌面壁纸，为避免误删正在使用的原图，本次没有清理原图。请稍后重试。", locale: locale)
        }
    }
}

// MARK: - Screen model

/// Reads recap and storage state from the single shared repository actor and
/// sends every mutation back through that same actor. It never creates another
/// repository and never invents missing days, favorites or stories.
@MainActor
@Observable
final class RecapScreenModel {
    var section: RecapSection = .monthly
    /// The recap screen always renders every locally recorded market and has no
    /// region picker, so this stays `nil` in the app. The setter remains for
    /// model-level tests of source-local date windows; no UI can leave a
    /// filter applied out of sight.
    private(set) var marketFilter: Market?
    private(set) var selectedYear: Int
    private(set) var selectedMonth: Int
    private(set) var asOf: LocalDate?
    private(set) var monthlyRecap: MonthlyRecap?
    private(set) var yearlyRecap: YearlyRecap?
    private(set) var favoriteRecap: FavoriteRecap?
    private(set) var snapshot: RepositorySnapshot?
    private(set) var storageUsage: StorageUsage?
    private(set) var cachedAssets: [RecapAssetRow] = []
    private(set) var pendingCleanup: RecapCleanupAction?
    private(set) var isLoading = false
    private(set) var isPerformingAction = false
    private(set) var actionMessage: String?
    private(set) var actionError: String?
    private(set) var loadError: String?

    /// Every catalog market. This is a filter list, not a claim that each
    /// market has distinct or complete provider coverage.
    static let supportedMarkets: [Market] = BingMarketProfile.catalog.map(\.market)
    static let defaultCacheLimits = CacheLimits()

    private let repository: WallpaperRepository
    /// Shared with `AppModel`. When present, explicit original deletion waits
    /// until live current-desktop protection has been reconciled.
    private let currentWallpaperProtection: CurrentWallpaperProtectionGate?
    private let imageLoader = ImageAssetLoader()
    private let now: @Sendable () -> Date
    /// Coalescing hand-off to the one sync controller. Favorite changes are
    /// synchronized content; recap and storage updates never wait for it.
    @ObservationIgnored private let noteSyncActivity: @MainActor () -> Void

    private var didInitializeSelection = false
    private var loadToken = 0
    private var thumbnailURLs: [WallpaperID: URL] = [:]
    private var originalURLs: [WallpaperID: URL] = [:]
    private var wallpapersByID: [WallpaperID: WallpaperRecord] = [:]
    private var metadataByKey: [OccurrenceKey: WallpaperMetadataRecord] = [:]

    init(
        repository: WallpaperRepository,
        currentWallpaperProtection: CurrentWallpaperProtectionGate? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        noteSyncActivity: @escaping @MainActor () -> Void = {}
    ) {
        self.repository = repository
        self.currentWallpaperProtection = currentWallpaperProtection
        self.now = now
        self.noteSyncActivity = noteSyncActivity

        let reference = LocalDate(date: now(), timeZone: .current)
        self.selectedYear = reference?.year ?? 1970
        self.selectedMonth = reference?.month ?? 1
    }

    // MARK: Derived values

    var marketOptions: [Market] {
        var result = Self.supportedMarkets
        if let marketFilter, !result.contains(marketFilter) {
            result.append(marketFilter)
        }
        guard let snapshot else { return result }
        for market in Set(snapshot.occurrences.map(\.market)).sorted()
        where !result.contains(market) {
            result.append(market)
        }
        return result
    }

    var canGoToNextMonth: Bool {
        guard let asOf else { return false }
        return (selectedYear, selectedMonth) < (asOf.year, asOf.month)
    }

    var canGoToNextYear: Bool {
        guard let asOf else { return false }
        return selectedYear < asOf.year
    }

    var isCurrentMonth: Bool {
        guard let asOf else { return false }
        return selectedYear == asOf.year && selectedMonth == asOf.month
    }

    var isCurrentYear: Bool {
        guard let asOf else { return false }
        return selectedYear == asOf.year
    }

    var isSelectedMonthInFuture: Bool {
        guard let asOf else { return false }
        return (selectedYear, selectedMonth) > (asOf.year, asOf.month)
    }

    var isSelectedYearInFuture: Bool {
        guard let asOf else { return false }
        return selectedYear > asOf.year
    }

    var favoriteImageCount: Int {
        favoriteRecap?.favoriteImageCount ?? snapshot?.favoriteWallpaperIDs.count ?? 0
    }

    var pinnedDateCount: Int {
        snapshot?.pinnedOccurrences.count ?? 0
    }

    /// Images used by currently accessible desktops. In-flight write
    /// reservations are deliberately not counted as visible wallpaper.
    var currentAppliedImageCount: Int {
        snapshot?.appliedWallpapers.count ?? 0
    }

    // MARK: Loading

    func load() async {
        await reload()
    }

    /// Refreshes every recap window and the storage snapshot from the shared
    /// repository. A newer selection invalidates older in-flight results.
    func reload() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        loadError = nil

        do {
            let snapshot = await repository.snapshot()
            guard let asOf = currentAsOf(snapshot: snapshot) else {
                throw RecapScreenError.clockUnavailable
            }
            guard token == loadToken else { return }

            self.asOf = asOf
            if !didInitializeSelection {
                selectedYear = asOf.year
                selectedMonth = asOf.month
                didInitializeSelection = true
            } else {
                clampSelection(notAfter: asOf)
            }

            let markets: Set<Market>? = marketFilter.map { Set([$0]) }
            let service = RecapService(
                snapshotProvider: RecapFrozenSnapshotProvider(snapshot: snapshot)
            )
            let monthly = try await service.monthlyRecap(
                year: selectedYear,
                month: selectedMonth,
                asOf: asOf,
                markets: markets
            )
            let yearly = try await service.yearlyRecap(
                year: selectedYear,
                asOf: asOf,
                markets: markets
            )
            let favorites = try await service.favoriteRecap(
                asOf: asOf,
                markets: markets
            )
            let usage = Self.storageUsage(from: snapshot)

            guard token == loadToken else { return }
            self.monthlyRecap = monthly
            self.yearlyRecap = yearly
            self.favoriteRecap = favorites
            self.storageUsage = usage
            applySnapshot(snapshot)
        } catch is CancellationError {
            // Keep the previously presented data.
        } catch {
            guard token == loadToken else { return }
            loadError = Self.loadDescription(error)
        }

        if token == loadToken {
            isLoading = false
        }
    }

    // MARK: Navigation

    func selectSection(_ section: RecapSection) {
        self.section = section
    }

    func selectMarket(_ market: Market?) async {
        let canonical = market.flatMap { BingMarketProfile.canonicalMarket($0) } ?? market
        guard canonical != marketFilter else { return }
        marketFilter = canonical
        // The previous selection may be a future month/year in the newly
        // selected market (for example Tokyo has already reached the next day).
        // Clamp before querying so the UI never describes a future window as
        // "no local records".
        if let asOf = resolvedAsOf(for: canonical, snapshot: snapshot) {
            clampSelection(notAfter: asOf)
        }
        await reload()
    }

    func showPreviousMonth() async {
        guard selectedYear > 1970 || selectedMonth > 1 else { return }
        if selectedMonth == 1 {
            selectedMonth = 12
            selectedYear -= 1
        } else {
            selectedMonth -= 1
        }
        await reload()
    }

    func showNextMonth() async {
        guard canGoToNextMonth else { return }
        if selectedMonth == 12 {
            selectedMonth = 1
            selectedYear += 1
        } else {
            selectedMonth += 1
        }
        await reload()
    }

    func showPreviousYear() async {
        guard selectedYear > 1970 else { return }
        selectedYear -= 1
        await reload()
    }

    func showNextYear() async {
        guard canGoToNextYear else { return }
        selectedYear += 1
        await reload()
    }

    func goToCurrentMonth() async {
        guard let asOf else { return }
        selectedYear = asOf.year
        selectedMonth = asOf.month
        await reload()
    }

    func goToCurrentYear() async {
        guard let asOf else { return }
        selectedYear = asOf.year
        await reload()
    }

    func openMonth(year: Int, month: Int) async {
        guard (1...12).contains(month), year > 0 else { return }
        section = .monthly
        selectedYear = year
        selectedMonth = month
        await reload()
    }

    // MARK: Favorites

    func isFavorite(_ wallpaperID: WallpaperID) -> Bool {
        snapshot?.favoriteWallpaperIDs.contains(wallpaperID) ?? false
    }

    func addFavorite(_ wallpaperID: WallpaperID) async {
        guard !isPerformingAction, !isFavorite(wallpaperID) else { return }
        loadToken += 1
        isPerformingAction = true
        actionMessage = nil
        actionError = nil
        defer { isPerformingAction = false }

        do {
            let changed = try await repository.setFavorite(wallpaperID, isFavorite: true)
            if changed {
                // Favorites are synchronized content; hand the change to the
                // one coalescing controller without delaying the reload.
                noteSyncActivity()
            }
            await reload()
            actionMessage = changed
                ? MacLocalizedString.resolve("已加入收藏。收藏图片不会被自动缓存清理。", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("该图片已在收藏中。", locale: WallpaperInterfaceLocale.current)
        } catch {
            await reload()
            actionError = Self.actionDescription(error, title: MacLocalizedString.resolve("收藏失败", locale: WallpaperInterfaceLocale.current))
        }
    }

    func requestRemoveFavorite(_ wallpaperID: WallpaperID) {
        guard isFavorite(wallpaperID) else { return }
        requestCleanup(.removeFavorite(wallpaperID))
    }

    // MARK: Destructive actions

    func requestCleanup(_ action: RecapCleanupAction) {
        guard !isPerformingAction else { return }
        actionMessage = nil
        actionError = nil

        switch action {
        case .removeAsset(let kind, let wallpaperID):
            guard let snapshot,
                  snapshot.asset(kind: kind, for: wallpaperID) != nil else {
                actionError = RecapScreenError.missingAsset.localizedDescription
                return
            }
            guard snapshot.pinReasons(for: wallpaperID).isEmpty else {
                actionError = RecapScreenError.protectedAsset.localizedDescription
                return
            }
            if kind == .original, !canDeleteOriginals {
                actionError = RecapScreenError.appliedProtectionUnavailable.localizedDescription
                return
            }
        case .removeFavorite(let wallpaperID):
            guard isFavorite(wallpaperID) else { return }
        case .clearUnprotectedOriginals:
            guard canDeleteOriginals else {
                actionError = RecapScreenError.appliedProtectionUnavailable.localizedDescription
                return
            }
        case .clearUnprotectedThumbnails,
             .applyDefaultLimits, .clearStories, .repairIndex:
            break
        }

        pendingCleanup = action
    }

    func cancelPendingCleanup() {
        pendingCleanup = nil
    }

    func confirmPendingCleanup(_ confirmedAction: RecapCleanupAction? = nil) async {
        guard let action = confirmedAction ?? pendingCleanup, !isPerformingAction else { return }
        pendingCleanup = nil
        loadToken += 1
        isPerformingAction = true
        actionMessage = nil
        actionError = nil
        defer { isPerformingAction = false }

        do {
            let message = try await perform(action)
            await reload()
            actionMessage = message
        } catch is CancellationError {
            await reload()
        } catch {
            await reload()
            actionError = Self.actionDescription(error, title: MacLocalizedString.resolve("清理失败", locale: WallpaperInterfaceLocale.current))
        }
    }

    func dismissActionFeedback() {
        actionMessage = nil
        actionError = nil
    }

    private func perform(_ action: RecapCleanupAction) async throws -> String {
        switch action {
        case .clearUnprotectedThumbnails:
            let result = try await repository.evictLeastRecentlyUsed(
                limits: CacheLimits(thumbnailBytes: 0, originalBytes: Int.max)
            )
            return Self.evictionMessage(
                result,
                empty: MacLocalizedString.resolve("没有可清理的未受保护缩略图。", locale: WallpaperInterfaceLocale.current)
            )
        case .clearUnprotectedOriginals:
            guard canDeleteOriginals else {
                throw RecapScreenError.appliedProtectionUnavailable
            }
            let result = try await repository.evictLeastRecentlyUsed(
                limits: CacheLimits(thumbnailBytes: Int.max, originalBytes: 0)
            )
            return Self.evictionMessage(
                result,
                empty: MacLocalizedString.resolve("没有可清理的未受保护原图。", locale: WallpaperInterfaceLocale.current)
            )
        case .applyDefaultLimits:
            // Thumbnails can never be the current wallpaper. When the live
            // protection set cannot be proven, still clean them but leave
            // originals untouched and say so instead of silently over-cleaning.
            let originalsAreSafe = canDeleteOriginals
            let result = try await repository.evictLeastRecentlyUsed(
                limits: originalsAreSafe
                    ? Self.defaultCacheLimits
                    : CacheLimits(
                        thumbnailBytes: CacheLimits().thumbnailBytes,
                        originalBytes: Int.max
                    )
            )
            let base: String
            if result.evictedAssets.isEmpty {
                base = MacLocalizedString.resolve("缓存已在内置上限内，没有清理任何文件。", locale: WallpaperInterfaceLocale.current)
            } else {
                base = String(
                    format: MacLocalizedString.resolve("已按内置上限清理 %lld 个缓存文件，释放 %@。", locale: WallpaperInterfaceLocale.current),
                    result.evictedAssets.count,
                    StatusFormatter.bytes(result.evictedBytes)
                )
            }
            guard !originalsAreSafe else { return base }
            return base + MacLocalizedString.resolve(" 当前壁纸尚未确认，已跳过原图清理。", locale: WallpaperInterfaceLocale.current)
        case .clearStories:
            let count = try await repository.clearStories()
            if count == 0 { return MacLocalizedString.resolve("没有已缓存的介绍文本。", locale: WallpaperInterfaceLocale.current) }
            return String(
                format: MacLocalizedString.resolve("已清除 %lld 条介绍文本；图片、图片信息与收藏未受影响。", locale: WallpaperInterfaceLocale.current),
                count
            )
        case .repairIndex:
            let report = try await repository.repair()
            var parts: [String] = [
                String(
                    format: MacLocalizedString.resolve("已移除 %lld 个没有记录的残留文件", locale: WallpaperInterfaceLocale.current),
                    report.orphanedFilesRemoved.count
                )
            ]
            if !report.missingAssets.isEmpty {
                parts.append(String(
                    format: MacLocalizedString.resolve("%lld 条缓存记录缺少文件", locale: WallpaperInterfaceLocale.current),
                    report.missingAssets.count
                ))
            }
            if !report.failedOrphanRemovals.isEmpty {
                parts.append(String(
                    format: MacLocalizedString.resolve("%lld 个文件无法移除", locale: WallpaperInterfaceLocale.current),
                    report.failedOrphanRemovals.count
                ))
            }
            return parts.joined(separator: MacLocalizedString.resolve("；", locale: WallpaperInterfaceLocale.current))
                + MacLocalizedString.resolve("。图片信息、介绍与收藏未被删除。", locale: WallpaperInterfaceLocale.current)
        case .removeAsset(let kind, let wallpaperID):
            let reasons = await repository.pinReasons(for: wallpaperID)
            guard reasons.isEmpty else {
                throw RecapScreenError.protectedAsset
            }
            if kind == .original, !canDeleteOriginals {
                throw RecapScreenError.appliedProtectionUnavailable
            }
            try await repository.removeAsset(kind: kind, for: wallpaperID)
            return kind == .original
                ? MacLocalizedString.resolve("已删除该原图缓存；缩略图、图片信息、介绍与收藏未受影响。", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("已删除该缩略图缓存；原图、图片信息、介绍与收藏未受影响。", locale: WallpaperInterfaceLocale.current)
        case .removeFavorite(let wallpaperID):
            let changed = try await repository.setFavorite(wallpaperID, isFavorite: false)
            guard changed else { return MacLocalizedString.resolve("该图片已不在收藏中。", locale: WallpaperInterfaceLocale.current) }
            // Removal keeps its delete semantics for sync; the controller
            // coalesces it with any other pending work.
            noteSyncActivity()
            let reasons = await repository.pinReasons(for: wallpaperID)
            if reasons.isEmpty {
                return MacLocalizedString.resolve("已取消收藏；该图片不再受收藏保护，后续缓存清理可能删除其缓存文件。", locale: WallpaperInterfaceLocale.current)
            }
            return MacLocalizedString.resolve("已取消收藏；该图片仍受固定日期或当前壁纸保护。", locale: WallpaperInterfaceLocale.current)
        }
    }

    // MARK: Presentation helpers

    /// Original deletion requires a reconciled live protection set. Without an
    /// injected gate the set is unproven, so fail closed rather than risk
    /// deleting the wallpaper currently in use.
    private var canDeleteOriginals: Bool {
        currentWallpaperProtection?.isReconciled ?? false
    }

    func thumbnailURL(for wallpaperID: WallpaperID) -> URL? {
        thumbnailURLs[wallpaperID]
    }

    func originalURL(for wallpaperID: WallpaperID) -> URL? {
        originalURLs[wallpaperID]
    }

    func protectionReasons(for wallpaperID: WallpaperID) -> Set<PinReason> {
        snapshot?.pinReasons(for: wallpaperID) ?? []
    }

    func title(for wallpaperID: WallpaperID) -> String? {
        wallpapersByID[wallpaperID]?.canonicalTitle
    }

    func title(for occurrence: WallpaperOccurrence) -> String? {
        metadataByKey[occurrence.id]?.title
            ?? wallpapersByID[occurrence.wallpaperID]?.canonicalTitle
    }

    func copyright(for occurrence: WallpaperOccurrence) -> String? {
        metadataByKey[occurrence.id]?.copyright
            ?? wallpapersByID[occurrence.wallpaperID]?.copyright
    }

    func sourceURL(for occurrence: WallpaperOccurrence) -> URL? {
        metadataByKey[occurrence.id]?.sourceURL
            ?? wallpapersByID[occurrence.wallpaperID]?.sourceURL
    }

    func originalLocale(for occurrence: WallpaperOccurrence) -> String? {
        LocalePresentation.determinedLanguageTag(metadataByKey[occurrence.id]?.originalLocale)
    }

    func markets(for day: RecapDay) -> [Market] {
        Set(day.occurrences.map(\.market)).sorted()
    }

    func dayThumbnailURL(for day: RecapDay) -> URL? {
        for occurrence in day.occurrences {
            if let url = thumbnailURL(for: occurrence.wallpaperID) {
                return url
            }
        }
        return nil
    }

    func storyPresentation(for occurrence: WallpaperOccurrence) -> RecapStoryPresentation {
        guard let snapshot else { return .notFetched }
        let match = StoryMatcher.match(
            occurrence: occurrence,
            metadata: metadataByKey[occurrence.id],
            stories: snapshot.stories
        )
        return RecapStoryPresentation(
            match: match,
            fallbackCopyright: copyright(for: occurrence),
            fallbackSourceURL: sourceURL(for: occurrence)
        )
    }

    func eligibleDays(year: Int, month: Int) -> Int? {
        guard let snapshot,
              let firstObservedDate = snapshot.firstObservedDate,
              let asOf,
              let start = LocalDate(year: year, month: month, day: 1),
              let end = LocalDate(
                year: year,
                month: month,
                day: LocalDate.daysInMonth(year: year, month: month)
              )
        else {
            return nil
        }
        let lower = Swift.max(start, firstObservedDate)
        let upper = Swift.min(end, asOf)
        guard let window = LocalDateRange(start: lower, end: upper) else { return 0 }
        return window.dayCount
    }

    func monthCoverage(_ month: RecapMonth) -> Double? {
        guard let eligible = eligibleDays(year: month.year, month: month.month),
              eligible > 0
        else {
            return nil
        }
        return Double(month.observedDays) / Double(eligible)
    }

    func monthEmptyReason(year: Int, month: Int) -> String {
        guard let snapshot else {
            return MacLocalizedString.resolve("尚未读取本地记录。", locale: WallpaperInterfaceLocale.current)
        }
        if let asOf, (year, month) > (asOf.year, asOf.month) {
            return MacLocalizedString.resolve("所选月份晚于当前来源日期（截至 \(asOf.iso8601)），还没有发生，不能据此判断缺失。", locale: WallpaperInterfaceLocale.current)
        }
        guard let firstObservedDate = snapshot.firstObservedDate else {
            return MacLocalizedString.resolve("本机还没有确认第一次记录是哪天，因此不补写任何日期；应用第一次保存记录之前的日期不计入统计。", locale: WallpaperInterfaceLocale.current)
        }
        if let end = LocalDate(
               year: year,
               month: month,
               day: LocalDate.daysInMonth(year: year, month: month)
           ),
           end < firstObservedDate {
            return MacLocalizedString.resolve("这个月早于本机第一次记录（\(firstObservedDate.iso8601)），也就是应用第一次保存记录之前；不计入统计，也不会补造图片。", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("该月没有本机记录。这不代表 Bing 当时没有发布图片：应用可能未运行、未获取该地区内容，或网络请求失败。", locale: WallpaperInterfaceLocale.current)
    }

    func yearEmptyReason(year: Int) -> String {
        guard let snapshot else {
            return MacLocalizedString.resolve("尚未读取本地记录。", locale: WallpaperInterfaceLocale.current)
        }
        if let asOf, year > asOf.year {
            return MacLocalizedString.resolve("所选年份晚于当前来源日期（截至 \(asOf.iso8601)），还没有发生，不能据此判断缺失。", locale: WallpaperInterfaceLocale.current)
        }
        guard let firstObservedDate = snapshot.firstObservedDate else {
            return MacLocalizedString.resolve("本机还没有确认第一次记录是哪天，因此不补写任何月份；应用第一次保存记录之前的月份不计入统计。", locale: WallpaperInterfaceLocale.current)
        }
        if year < firstObservedDate.year {
            return MacLocalizedString.resolve("这一年早于本机第一次记录（\(firstObservedDate.iso8601)），也就是应用第一次保存记录之前；不计入统计，也不会补造月份。", locale: WallpaperInterfaceLocale.current)
        }
        if year == firstObservedDate.year {
            return MacLocalizedString.resolve("本机从 \(firstObservedDate.iso8601) 开始记录；该年此前的日期不计入统计范围。", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("该年没有本机记录。这不代表 Bing 当时没有发布图片：应用可能未运行或未获取内容。", locale: WallpaperInterfaceLocale.current)
    }

    func favoriteEntry(for wallpaperID: WallpaperID) -> FavoriteEntry? {
        favoriteRecap?.entries.first { $0.wallpaperID == wallpaperID }
    }

    func latestOccurrence(for entry: FavoriteEntry) -> WallpaperOccurrence? {
        entry.occurrences.last
    }

    // MARK: Image loading

    func thumbnailImage(at url: URL, maxPixelSize: Int = 360) async -> NSImage? {
        do {
            return try await imageLoader.image(at: url, maxPixelSize: maxPixelSize).image
        } catch {
            return nil
        }
    }

    // MARK: Internals

    private func currentAsOf(snapshot: RepositorySnapshot) -> LocalDate? {
        resolvedAsOf(for: marketFilter, snapshot: snapshot)
    }

    /// For one selected market, its catalog time zone bounds the window.
    ///
    /// With no filter, the bound is the latest source-local date among markets
    /// actually observed locally. That keeps an expanded catalog from
    /// declaring an unobserved market's tomorrow as "today". An empty
    /// repository falls back to the catalog maximum as a ceiling; no day is
    /// ever synthesized.
    private func resolvedAsOf(for market: Market?, snapshot: RepositorySnapshot?) -> LocalDate? {
        let instant = now()
        if let market,
           let profile = BingMarketProfile.profile(for: market) {
            return LocalDate(date: instant, timeZone: profile.timeZone)
        }

        let observed = Set(snapshot?.occurrences.map(\.market) ?? [])
        let markets = observed.isEmpty
            ? Set(BingMarketProfile.catalog.map(\.market))
            : observed
        return markets
            .compactMap { observedMarket in
                BingMarketProfile.profile(for: observedMarket)?.timeZone
            }
            .compactMap { LocalDate(date: instant, timeZone: $0) }
            .max()
    }

    /// Keeps the selected window inside dates the source-local clock has
    /// already reached. A past selection is preserved; only a future month or
    /// year is clamped to the current source-local month/year.
    private func clampSelection(notAfter asOf: LocalDate) {
        if selectedYear > asOf.year {
            selectedYear = asOf.year
            selectedMonth = asOf.month
        } else if selectedYear == asOf.year, selectedMonth > asOf.month {
            selectedMonth = asOf.month
        }
    }

    private func applySnapshot(_ snapshot: RepositorySnapshot) {
        self.snapshot = snapshot

        wallpapersByID.removeAll(keepingCapacity: true)
        for record in snapshot.wallpapers {
            wallpapersByID[record.wallpaperID] = record
        }

        metadataByKey.removeAll(keepingCapacity: true)
        for record in snapshot.metadata {
            metadataByKey[record.key] = record
        }

        let missingIDs = Set(snapshot.missingAssets.map(\.id))
        thumbnailURLs.removeAll(keepingCapacity: true)
        originalURLs.removeAll(keepingCapacity: true)
        for asset in snapshot.assets where !missingIDs.contains(asset.id) {
            guard let url = resolvedAssetURL(relativePath: asset.relativePath) else { continue }
            switch asset.kind {
            case .thumbnail:
                thumbnailURLs[asset.wallpaperID] = url
            case .original:
                originalURLs[asset.wallpaperID] = url
            }
        }

        var rows: [RecapAssetRow] = []
        rows.reserveCapacity(snapshot.assets.count)
        for asset in snapshot.assets.sorted(by: Self.assetSortOrder) {
            rows.append(RecapAssetRow(
                asset: asset,
                title: wallpapersByID[asset.wallpaperID]?.canonicalTitle,
                protection: snapshot.pinReasons(for: asset.wallpaperID),
                isMissing: missingIDs.contains(asset.id)
            ))
        }
        cachedAssets = rows
    }

    /// Pure path resolution; file existence is already reflected by
    /// `snapshot.missingAssets`, which the repository checks off the main actor.
    private func resolvedAssetURL(relativePath: String) -> URL? {
        let root = repository.directory.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private static func storageUsage(from snapshot: RepositorySnapshot) -> StorageUsage {
        var thumbnailBytes = 0
        var originalBytes = 0
        for asset in snapshot.assets {
            switch asset.kind {
            case .thumbnail:
                thumbnailBytes += asset.byteCount
            case .original:
                originalBytes += asset.byteCount
            }
        }
        return StorageUsage(
            thumbnailBytes: thumbnailBytes,
            originalBytes: originalBytes,
            assetCount: snapshot.assets.count,
            missingAssetCount: snapshot.missingAssets.count
        )
    }

    private static func assetSortOrder(_ lhs: CachedImageAsset, _ rhs: CachedImageAsset) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .original
        }
        if lhs.lastAccessedAt != rhs.lastAccessedAt {
            return lhs.lastAccessedAt > rhs.lastAccessedAt
        }
        return lhs.id < rhs.id
    }

    private static func evictionMessage(
        _ result: CacheEvictionResult,
        empty: String
    ) -> String {
        guard !result.evictedAssets.isEmpty else { return empty }
        return String(
            format: MacLocalizedString.resolve("已清理 %lld 个缓存文件，释放 %@。", locale: WallpaperInterfaceLocale.current),
            result.evictedAssets.count,
            StatusFormatter.bytes(result.evictedBytes)
        )
    }

    private static func loadDescription(_ error: Error) -> String {
        MacLocalizedString.resolve("读取本地回顾数据失败：\(describe(error))", locale: WallpaperInterfaceLocale.current)
    }

    private static func actionDescription(_ error: Error, title: String) -> String {
        String(format: MacLocalizedString.resolve("%@：%@", locale: WallpaperInterfaceLocale.current), title, describe(error))
    }

    private static func describe(_ error: Error) -> String {
        AppErrorCopy.describe(error)
    }
}

// MARK: - Copy

enum RecapCopy {
    static func marketLabel(_ market: Market, in locale: Locale) -> String {
        LocalePresentation.marketName(for: market, in: locale)
    }

    static func marketTag(_ market: Market, in locale: Locale) -> String {
        LocalePresentation.marketTag(for: market, in: locale)
    }

    static func monthTitle(
        year: Int,
        month: Int,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        String(format: MacLocalizedString.resolve("%lld年%lld月", locale: locale), year, month)
    }

    static func dayTitle(
        _ date: LocalDate,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        String(format: MacLocalizedString.resolve("%lld月%lld日", locale: locale), date.month, date.day)
    }

    static func protectionLabel(
        _ reason: PinReason,
        in locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        switch reason {
        case .favorite: return MacLocalizedString.resolve("收藏", locale: locale)
        case .pinnedDate: return MacLocalizedString.resolve("固定日期", locale: locale)
        case .currentlyApplied: return MacLocalizedString.resolve("当前壁纸", locale: locale)
        }
    }

    static func assetKindLabel(
        _ kind: AssetKind,
        in locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        kind == .original
            ? MacLocalizedString.resolve("原图", locale: locale)
            : MacLocalizedString.resolve("缩略图", locale: locale)
    }

    static func coverageStateLabel(
        _ state: CoverageState,
        in locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        switch state {
        case .firstObservedDateUnknown: return MacLocalizedString.resolve("起始日期未知", locale: locale)
        case .noObservation: return MacLocalizedString.resolve("尚无记录", locale: locale)
        case .partial: return MacLocalizedString.resolve("部分日期有记录", locale: locale)
        case .complete: return MacLocalizedString.resolve("每天都有记录", locale: locale)
        }
    }

    static func percentage(
        _ coverage: Double?,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        guard let coverage else { return "—" }
        return coverage.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    static func rangeLabel(_ range: LocalDateRange?) -> String {
        guard let range else { return MacLocalizedString.resolve("日期未知", locale: WallpaperInterfaceLocale.current) }
        return String(
            format: MacLocalizedString.resolve("%@ 至 %@", locale: WallpaperInterfaceLocale.current),
            range.start.iso8601,
            range.end.iso8601
        )
    }

    static func favoriteDateRange(_ entry: FavoriteEntry) -> String {
        guard let first = entry.firstObservedDate,
              let latest = entry.latestObservedDate
        else {
            return MacLocalizedString.resolve("无日期记录", locale: WallpaperInterfaceLocale.current)
        }
        if first == latest { return first.iso8601 }
        return "\(first.iso8601) – \(latest.iso8601)"
    }

    static func marketsLabel(_ markets: [Market], in locale: Locale) -> String {
        if markets.isEmpty { return MacLocalizedString.resolve("无地区记录", locale: locale) }
        return LocalePresentation.joined(
            markets.map { marketLabel($0, in: locale) },
            in: locale
        )
    }
}

/// A single immutable snapshot shared by the three recap queries of one
/// refresh, so monthly, yearly and favorite values cannot observe a write in
/// between. The repository actor still owns all reads and writes elsewhere.
private struct RecapFrozenSnapshotProvider: RepositorySnapshotProviding {
    let snapshot: RepositorySnapshot

    func repositorySnapshot() async throws -> RepositorySnapshot {
        snapshot
    }
}
