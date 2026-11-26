import DaybreakCore
import Foundation

// MARK: - Presentation values

/// Everything the Today screen needs for one market/date occurrence.
///
/// The payload carries the authoritative source date instead of assuming the
/// device clock matches Bing's market-local publication date.
struct TodayPayload: Sendable, Equatable {
    let market: Market
    let marketToday: LocalDate
    let occurrence: WallpaperOccurrence
    let metadata: WallpaperMetadataRecord?
    let wallpaper: WallpaperRecord?
    let storyMatch: StoryMatch?
    let thumbnailURL: URL?
    let originalURL: URL?
    let cachedAt: Date?

    var sourceDate: LocalDate { occurrence.localDate }
    var wallpaperID: WallpaperID { occurrence.wallpaperID }
    var key: OccurrenceKey { occurrence.id }
    var isSourceDateToday: Bool { sourceDate == marketToday }
    var title: String? { metadata?.title ?? wallpaper?.canonicalTitle }
    var copyright: String? { metadata?.copyright ?? wallpaper?.copyright }
    var sourceURL: URL? { metadata?.sourceURL ?? wallpaper?.sourceURL }
    var hasThumbnail: Bool { thumbnailURL != nil }
    var hasOriginal: Bool { originalURL != nil }
}

struct TodayRefreshOutcome: Sendable {
    let payload: TodayPayload
    let fetchedAt: Date
    let warnings: [String]
}

enum TodayServiceError: Error, Sendable, LocalizedError, Equatable {
    case unsupportedMarket(String)
    case archiveUnavailable(String)
    case persistenceFailed(String)
    case imageUnavailable(String)

    var errorDescription: String? {
        description(in: WallpaperInterfaceLocale.current)
    }

    func description(in locale: Locale) -> String {
        switch self {
        case .unsupportedMarket:
            return MacLocalizedString.resolve("不支持这个地区，它不在可选的 Bing 地区中。", locale: locale)
        case .archiveUnavailable(let detail):
            return MacLocalizedString.resolve("无法取得今日图片：\(detail)", locale: locale)
        case .persistenceFailed(let detail):
            return MacLocalizedString.resolve("本地缓存写入失败：\(detail)", locale: locale)
        case .imageUnavailable(let detail):
            return MacLocalizedString.resolve("图片不可用：\(detail)", locale: locale)
        }
    }
}

// MARK: - Service

/// Serializes all repository and provider work off the main actor.
///
/// The service never invents a story or a date. When the archive has no entry
/// for the market's current date it returns the newest available occurrence
/// together with its real source date.
actor TodayService {
    let repository: WallpaperRepository
    private let now: @Sendable () -> Date
    private let providerFactory: @Sendable (BingMarketProfile) -> BingProvider
    private var providers: [String: BingProvider] = [:]

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        providerFactory: (@Sendable (BingMarketProfile) -> BingProvider)? = nil
    ) throws {
        self.repository = try WallpaperRepository(directory: directory)
        self.now = now
        self.providerFactory = providerFactory ?? { profile in
            BingProvider(profile: profile)
        }
    }

    // MARK: Cache reads

    func cachedToday(market: Market) async -> TodayPayload? {
        guard let profile = BingMarketProfile.profile(for: market) else { return nil }
        let canonicalMarket = profile.market
        let snapshot = await repository.snapshot()
        guard let today = LocalDate(date: now(), timeZone: profile.timeZone) else { return nil }

        let occurrences = snapshot.occurrences.filter { $0.market == canonicalMarket }
        guard let occurrence = occurrences.first(where: { $0.localDate == today })
                ?? occurrences.max(by: { $0.localDate < $1.localDate })
        else {
            return nil
        }

        return await makePayload(
            market: canonicalMarket,
            occurrence: occurrence,
            marketToday: today,
            snapshot: snapshot
        )
    }

    func cachedPayload(market: Market, key: OccurrenceKey) async -> TodayPayload? {
        guard let profile = BingMarketProfile.profile(for: market),
              let canonicalKeyMarket = BingMarketProfile.canonicalMarket(key.market),
              canonicalKeyMarket == profile.market
        else {
            return nil
        }
        let canonicalKey = key.market == canonicalKeyMarket
            ? key
            : OccurrenceKey(source: key.source, market: canonicalKeyMarket, localDate: key.localDate)
        let snapshot = await repository.snapshot()
        guard let today = LocalDate(date: now(), timeZone: profile.timeZone) else { return nil }
        guard let occurrence = snapshot.occurrences.first(where: { $0.id == canonicalKey }) else {
            return nil
        }
        return await makePayload(
            market: profile.market,
            occurrence: occurrence,
            marketToday: today,
            snapshot: snapshot
        )
    }

    // MARK: Network refresh

    func refreshToday(market: Market) async throws -> TodayRefreshOutcome {
        guard let profile = BingMarketProfile.profile(for: market) else {
            throw TodayServiceError.unsupportedMarket(market.rawValue)
        }
        let canonicalMarket = profile.market
        guard let provider = provider(for: canonicalMarket) else {
            throw TodayServiceError.unsupportedMarket(market.rawValue)
        }

        let daily = try await provider.fetchDailySnapshot()
        try Task.checkCancellation()

        guard let archive = daily.archive.value else {
            let detail = daily.archive.error.map { Self.describe($0) }
                ?? MacLocalizedString.resolve("Bing 图片服务暂时不可用", locale: WallpaperInterfaceLocale.current)
            throw TodayServiceError.archiveUnavailable(detail)
        }
        guard !archive.entries.isEmpty else {
            throw TodayServiceError.archiveUnavailable(
                MacLocalizedString.resolve("Bing 没有返回任何图片", locale: WallpaperInterfaceLocale.current)
            )
        }

        guard let today = LocalDate(date: now(), timeZone: profile.timeZone) else {
            throw TodayServiceError.archiveUnavailable(
                MacLocalizedString.resolve("无法计算该地区的来源日期", locale: WallpaperInterfaceLocale.current)
            )
        }
        guard let entry = archive.entries.first(where: { $0.occurrence.localDate == today })
                ?? archive.entries.max(by: { $0.occurrence.localDate < $1.occurrence.localDate })
        else {
            throw TodayServiceError.archiveUnavailable(
                MacLocalizedString.resolve("Bing 没有返回任何图片", locale: WallpaperInterfaceLocale.current)
            )
        }
        let occurrence = entry.occurrence

        var warnings: [String] = []
        if occurrence.localDate != today {
            warnings.append(MacLocalizedString.resolve("Bing 尚未发布该地区今日内容；当前最新来源日期为 \(occurrence.localDate.iso8601)。", locale: WallpaperInterfaceLocale.current))
        }
        if let storyError = daily.stories.error {
            warnings.append(MacLocalizedString.resolve("介绍获取失败：\(Self.describe(storyError))。已缓存的介绍仍会显示。", locale: WallpaperInterfaceLocale.current))
        }

        try await persist(archive: archive, stories: daily.stories.value)

        var snapshot = await repository.snapshot()
        var payload = await makePayload(
            market: canonicalMarket,
            occurrence: occurrence,
            marketToday: today,
            snapshot: snapshot
        )

        // Metadata is archived for every returned day, but thumbnails are
        // only useful while the image is still retrievable. Backfill the whole
        // bounded archive window so the Library can show images for the days
        // it records instead of leaving them permanently metadata-only.
        let backfill = try await cacheMissingThumbnails(
            entries: archive.entries,
            provider: provider,
            snapshot: snapshot
        )
        warnings.append(contentsOf: backfill.warnings)
        if backfill.storedCount > 0 {
            snapshot = await repository.snapshot()
            payload = await makePayload(
                market: canonicalMarket,
                occurrence: occurrence,
                marketToday: today,
                snapshot: snapshot
            )
        }

        return TodayRefreshOutcome(
            payload: payload,
            fetchedAt: daily.fetchedAt,
            warnings: warnings
        )
    }

    /// Stores thumbnails for archive entries that do not have one yet.
    ///
    /// The archive is bounded by provider configuration (at most eight days),
    /// so this stays a small, sequential backfill instead of a month-wide
    /// download. Existing, protected and readable assets are never replaced.
    /// Failures are reported as one non-fatal warning so a single unavailable
    /// historical image cannot block today's refresh.
    private func cacheMissingThumbnails(
        entries: [BingArchiveEntry],
        provider: BingProvider,
        snapshot: RepositorySnapshot
    ) async throws -> (storedCount: Int, warnings: [String]) {
        var available = snapshot.availableThumbnailIDs
        var attempted: Set<WallpaperID> = []
        var storedCount = 0
        var failureCount = 0
        var firstFailure: (any Error)?

        for entry in entries {
            let wallpaperID = entry.metadata.wallpaperID
            guard !available.contains(wallpaperID),
                  attempted.insert(wallpaperID).inserted
            else {
                continue
            }

            do {
                let image = try await provider.fetchImage(for: entry, preference: .fullHD)
                try Task.checkCancellation()
                _ = try await repository.storeAsset(
                    image.data,
                    kind: .thumbnail,
                    for: wallpaperID,
                    fileExtension: Self.fileExtension(for: image.mimeType)
                )
                available.insert(wallpaperID)
                storedCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failureCount += 1
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }

        var warnings: [String] = []
        if let firstFailure {
            let detail: String
            if let providerError = firstFailure as? BingProviderError {
                detail = Self.describe(providerError)
            } else {
                detail = AppErrorCopy.describe(firstFailure)
            }
            warnings.append(MacLocalizedString.resolve("\(failureCount) 张历史预览图未能缓存：\(detail)。图片信息已保留，联网后可以重试。", locale: WallpaperInterfaceLocale.current))
        }
        return (storedCount, warnings)
    }

    func downloadOriginal(for payload: TodayPayload) async throws -> URL {
        guard let provider = provider(for: payload.market) else {
            throw TodayServiceError.unsupportedMarket(payload.market.rawValue)
        }
        if let existing = await existingAssetURL(kind: .original, for: payload.wallpaperID) {
            return existing
        }

        guard let metadata = await repository.metadata(for: payload.key) ?? payload.metadata else {
            throw TodayServiceError.imageUnavailable(
                MacLocalizedString.resolve("缺少这张图片的信息，无法安全下载原图", locale: WallpaperInterfaceLocale.current)
            )
        }

        do {
            let image = try await provider.fetchImage(for: metadata, preference: .highResolution)
            try Task.checkCancellation()
            _ = try await repository.storeAsset(
                image.data,
                kind: .original,
                for: payload.wallpaperID,
                fileExtension: Self.fileExtension(for: image.mimeType)
            )
            guard let url = await existingAssetURL(kind: .original, for: payload.wallpaperID) else {
                throw TodayServiceError.persistenceFailed(
                    MacLocalizedString.resolve("原图已保存，但缓存记录无法读取", locale: WallpaperInterfaceLocale.current)
                )
            }
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BingProviderError {
            throw TodayServiceError.imageUnavailable(Self.describe(error))
        } catch let error as RepositoryError {
            throw TodayServiceError.persistenceFailed(AppErrorCopy.describe(error))
        }
    }

    func storageUsage() async -> StorageUsage {
        await repository.storageUsage()
    }

    /// Maps local asset URLs back to wallpaper identities. Only original
    /// assets are considered because desktop integration writes the original.
    /// Unresolved URLs are omitted; callers must not treat that as a failed
    /// write or remove unrelated protection.
    func appliedWallpaperIDs(forAssetURLs urls: [URL]) async -> [URL: WallpaperID] {
        guard !urls.isEmpty else { return [:] }
        let snapshot = await repository.snapshot()
        var idByPath: [String: WallpaperID] = [:]
        for asset in snapshot.assets where asset.kind == .original {
            guard let url = await repository.assetURL(for: asset) else { continue }
            for key in Self.assetPathKeys(url) {
                idByPath[key] = asset.wallpaperID
            }
        }

        var result: [URL: WallpaperID] = [:]
        for url in urls {
            for key in Self.assetPathKeys(url) {
                if let id = idByPath[key] {
                    result[url] = id
                    break
                }
            }
        }
        return result
    }

    /// Replaces the repository's live current-desktop protection set. The
    /// caller derives it from public system reads; this method never grows a
    /// historical set.
    func replaceAppliedWallpapers(_ wallpaperIDs: Set<WallpaperID>) async throws {
        _ = try await repository.replaceAppliedWallpapers(wallpaperIDs)
    }

    /// Applies the built-in cache limits with LRU eviction. Favorites, pinned
    /// dates, currently accessible desktops and in-flight writes are retained
    /// by the repository actor.
    func enforceCacheLimits(_ limits: CacheLimits = CacheLimits()) async -> CacheEvictionResult? {
        try? await repository.evictLeastRecentlyUsed(limits: limits)
    }

    private static func assetPathKeys(_ url: URL) -> [String] {
        let standardized = url.standardizedFileURL
        var keys = [standardized.path]
        let resolved = standardized.resolvingSymlinksInPath()
        if resolved.path != standardized.path {
            keys.append(resolved.path)
        }
        return keys
    }

    // MARK: Internals

    private func provider(for market: Market) -> BingProvider? {
        guard let profile = BingMarketProfile.profile(for: market) else { return nil }
        let cacheKey = profile.market.rawValue
        if let existing = providers[cacheKey] {
            return existing
        }
        let provider = providerFactory(profile)
        providers[cacheKey] = provider
        return provider
    }

    private func persist(
        archive: BingArchiveSnapshot,
        stories: BingStorySnapshot?
    ) async throws {
        do {
            _ = try await repository.upsertOccurrences(archive.occurrences)
            _ = try await repository.upsertMetadata(archive.metadataRecords)
            _ = try await repository.upsertWallpapers(archive.wallpapers)
            if let stories, !stories.records.isEmpty {
                _ = try await repository.upsertStories(stories.records)
            }
        } catch {
            throw TodayServiceError.persistenceFailed(AppErrorCopy.describe(error))
        }
    }

    private func makePayload(
        market: Market,
        occurrence: WallpaperOccurrence,
        marketToday: LocalDate,
        snapshot: RepositorySnapshot
    ) async -> TodayPayload {
        let key = occurrence.id
        let metadata = snapshot.metadata(for: key)
        let wallpaper = snapshot.wallpapers.first { $0.wallpaperID == occurrence.wallpaperID }
        let match = snapshot.storyMatch(for: key)
        let thumbnailURL = await existingAssetURL(
            kind: .thumbnail,
            for: occurrence.wallpaperID,
            snapshot: snapshot
        )
        let originalURL = await existingAssetURL(
            kind: .original,
            for: occurrence.wallpaperID,
            snapshot: snapshot
        )
        return TodayPayload(
            market: market,
            marketToday: marketToday,
            occurrence: occurrence,
            metadata: metadata,
            wallpaper: wallpaper,
            storyMatch: match,
            thumbnailURL: thumbnailURL,
            originalURL: originalURL,
            cachedAt: metadata?.fetchedAt ?? wallpaper?.fetchedAt
        )
    }

    private func existingAssetURL(
        kind: AssetKind,
        for wallpaperID: WallpaperID,
        snapshot: RepositorySnapshot
    ) async -> URL? {
        guard snapshot.asset(kind: kind, for: wallpaperID) != nil,
              !snapshot.missingAssets.contains(where: {
                  $0.kind == kind && $0.wallpaperID == wallpaperID
              })
        else {
            return nil
        }
        guard let url = await repository.assetURL(kind: kind, for: wallpaperID) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func existingAssetURL(kind: AssetKind, for wallpaperID: WallpaperID) async -> URL? {
        await existingAssetURL(
            kind: kind,
            for: wallpaperID,
            snapshot: await repository.snapshot()
        )
    }

    // MARK: Messages

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    static func describe(_ error: BingProviderError) -> String {
        describe(error, locale: WallpaperInterfaceLocale.current)
    }

    static func describe(_ error: BingProviderError, locale: Locale) -> String {
        switch error {
        case .invalidConfiguration(let detail):
            return MacLocalizedString.resolve("请求设置无效（\(detail)）", locale: locale)
        case .blockedURL(let host):
            return host.map { MacLocalizedString.resolve("出于安全考虑，已阻止来自 \($0) 的图片", locale: locale) }
                ?? MacLocalizedString.resolve("出于安全考虑，已阻止该图片来源", locale: locale)
        case .unexpectedRedirect(let statusCode, let host):
            return host.map {
                MacLocalizedString.resolve("图片跳转被拒绝（HTTP \(statusCode)，\($0)）", locale: locale)
            } ?? MacLocalizedString.resolve("图片跳转被拒绝（HTTP \(statusCode)）", locale: locale)
        case .responseTooLarge(let limit):
            return MacLocalizedString.resolve("图片文件超过大小限制（\(limit) 字节）", locale: locale)
        case .unexpectedContentType(let contentType):
            return contentType.map { MacLocalizedString.resolve("图片格式异常：\($0)", locale: locale) }
                ?? MacLocalizedString.resolve("图片格式异常", locale: locale)
        case .httpStatus(let code, _):
            return MacLocalizedString.resolve("Bing 返回 HTTP \(code)", locale: locale)
        case .malformedJSON, .malformedResponse:
            return MacLocalizedString.resolve("无法读取 Bing 返回的内容", locale: locale)
        case .noUsableEntries:
            return MacLocalizedString.resolve("Bing 没有返回可用的内容", locale: locale)
        case .noImageCandidates:
            return MacLocalizedString.resolve("没有可用的图片链接", locale: locale)
        case .allImageCandidatesFailed:
            return MacLocalizedString.resolve("所有候选图片都下载失败", locale: locale)
        case .imageMimeRejected, .imageDecodeFailed, .imageDimensionsRejected:
            return MacLocalizedString.resolve("图片验证未通过，未保存", locale: locale)
        case .transport(let code):
            return code.map {
                MacLocalizedString.resolve("网络传输失败（\(String($0))）", locale: locale)
            } ?? MacLocalizedString.resolve("网络连接失败", locale: locale)
        }
    }
}
