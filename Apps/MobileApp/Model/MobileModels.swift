import DaybreakCore
import Foundation

// MARK: - Interface language and content market

/// Interface-language choice, independent of the Bing content market.
///
/// Raw values for explicit languages exactly match the shared preference key
/// `daybreak.interfaceLanguage` used by App Intents. `.system` removes that
/// key rather than writing a fourth value.
public enum MobileInterfaceLanguage: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    public var id: String { rawValue }

    /// Locale for Daybreak-owned copy and SwiftUI's `\.locale` environment.
    public var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        case .japanese:
            return Locale(identifier: "ja")
        }
    }
}

/// Persisted content-market choice. `.followSystem` never stores a guessed
/// market as if the user picked it; an explicit value stores a canonical
/// catalog tag.
public enum MobileMarketPreference: Hashable, Sendable, Codable {
    case followSystem
    case market(Market)

    private enum CodingKeys: String, CodingKey {
        case kind
        case market
    }

    private enum Kind: String, Codable {
        case followSystem
        case market
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .followSystem:
            self = .followSystem
        case .market:
            self = .market(try container.decode(Market.self, forKey: .market))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .followSystem:
            try container.encode(Kind.followSystem, forKey: .kind)
        case .market(let market):
            try container.encode(Kind.market, forKey: .kind)
            try container.encode(market, forKey: .market)
        }
    }
}

// MARK: - Settings

/// User preferences owned by `MobileStore` and persisted in the shared
/// standard `UserDefaults` suite so App Intents read the same values.
public struct MobileSettings: Hashable, Sendable, Codable {
    public static let defaultThumbnailCacheLimitBytes = 200_000_000
    public static let defaultOriginalCacheLimitBytes = 800_000_000
    public static let defaultCacheCapacityBytes =
        Int64(defaultThumbnailCacheLimitBytes + defaultOriginalCacheLimitBytes)

    public internal(set) var interfaceLanguage: MobileInterfaceLanguage
    public internal(set) var marketPreference: MobileMarketPreference
    public internal(set) var imageQuality: BingImagePreference
    public internal(set) var thumbnailCacheLimitBytes: Int
    public internal(set) var originalCacheLimitBytes: Int

    public init(
        interfaceLanguage: MobileInterfaceLanguage = .system,
        marketPreference: MobileMarketPreference = .followSystem,
        imageQuality: BingImagePreference = .highResolution,
        thumbnailCacheLimitBytes: Int = MobileSettings.defaultThumbnailCacheLimitBytes,
        originalCacheLimitBytes: Int = MobileSettings.defaultOriginalCacheLimitBytes
    ) {
        self.interfaceLanguage = interfaceLanguage
        self.marketPreference = marketPreference
        self.imageQuality = imageQuality
        self.thumbnailCacheLimitBytes = thumbnailCacheLimitBytes
        self.originalCacheLimitBytes = originalCacheLimitBytes
        normalize()
    }

    public var cacheLimits: CacheLimits {
        CacheLimits(
            thumbnailBytes: max(0, thumbnailCacheLimitBytes),
            originalBytes: max(0, originalCacheLimitBytes)
        )
    }

    public var totalCacheLimitBytes: Int64 {
        Int64(cacheLimits.thumbnailBytes) + Int64(cacheLimits.originalBytes)
    }

    public var marketSelection: MobileMarketPreference { marketPreference }

    /// Clamps values that may have been written by an older build or a manual
    /// defaults edit. Callers should treat negative capacity as zero, never as
    /// unlimited.
    public mutating func normalize() {
        thumbnailCacheLimitBytes = max(0, thumbnailCacheLimitBytes)
        originalCacheLimitBytes = max(0, originalCacheLimitBytes)
    }
}

// MARK: - Refresh diagnostics

/// Typed refresh warnings. Presentation belongs to the UI layer so the store
/// never hard-codes a language or invents story text.
public enum MobileRefreshWarning: Hashable, Sendable {
    /// The provider has not published content for the market's current date;
    /// the snapshot honestly shows a newer cached source date instead.
    case sourceDateBehind(sourceDate: LocalDate, marketToday: LocalDate)
    case storiesUnavailable(detail: String)
    case thumbnailBackfillIncomplete(count: Int, detail: String)
}

// MARK: - Today and day snapshots

/// Everything Today needs for one authoritative source occurrence.
///
/// `marketToday` is computed in the market profile's time zone; `sourceDate`
/// comes from the occurrence. A device time-zone change never moves the image
/// to another day.
public struct MobileTodaySnapshot: Hashable, Sendable {
    public let market: Market
    public let marketToday: LocalDate
    public let occurrence: WallpaperOccurrence
    public let metadata: WallpaperMetadataRecord?
    public let wallpaper: WallpaperRecord?
    public let storyMatch: StoryMatch?
    public let thumbnailURL: URL?
    public let originalURL: URL?
    public let cachedAt: Date?
    public let warnings: [MobileRefreshWarning]
    public let isFavorite: Bool

    public init(
        market: Market,
        marketToday: LocalDate,
        occurrence: WallpaperOccurrence,
        metadata: WallpaperMetadataRecord? = nil,
        wallpaper: WallpaperRecord? = nil,
        storyMatch: StoryMatch? = nil,
        thumbnailURL: URL? = nil,
        originalURL: URL? = nil,
        cachedAt: Date? = nil,
        warnings: [MobileRefreshWarning] = [],
        isFavorite: Bool = false
    ) {
        self.market = market
        self.marketToday = marketToday
        self.occurrence = occurrence
        self.metadata = metadata
        self.wallpaper = wallpaper
        self.storyMatch = storyMatch
        self.thumbnailURL = thumbnailURL
        self.originalURL = originalURL
        self.cachedAt = cachedAt
        self.warnings = warnings
        self.isFavorite = isFavorite
    }

    public var sourceDate: LocalDate { occurrence.localDate }
    public var wallpaperID: WallpaperID { occurrence.wallpaperID }
    public var key: OccurrenceKey { occurrence.id }
    public var isSourceDateToday: Bool { sourceDate == marketToday }
    public var title: String? { metadata?.title ?? wallpaper?.canonicalTitle }
    public var copyright: String? { metadata?.copyright ?? wallpaper?.copyright }
    public var sourceURL: URL? { metadata?.sourceURL ?? wallpaper?.sourceURL }
    public var hasThumbnail: Bool { thumbnailURL != nil }
    public var hasOriginal: Bool { originalURL != nil }
    public var displayImageURL: URL? { originalURL ?? thumbnailURL }
    public var canLoadOriginal: Bool { metadata != nil || wallpaper != nil }

    public func withWarnings(_ warnings: [MobileRefreshWarning]) -> MobileTodaySnapshot {
        MobileTodaySnapshot(
            market: market,
            marketToday: marketToday,
            occurrence: occurrence,
            metadata: metadata,
            wallpaper: wallpaper,
            storyMatch: storyMatch,
            thumbnailURL: thumbnailURL,
            originalURL: originalURL,
            cachedAt: cachedAt,
            warnings: warnings,
            isFavorite: isFavorite
        )
    }
}

/// One observed historical day, including the localized source metadata that
/// a detail screen needs. No date or story is inferred when the record is
/// missing.
public struct MobileDaySnapshot: Hashable, Sendable, Identifiable {
    public let key: OccurrenceKey
    public let occurrence: WallpaperOccurrence
    public let metadata: WallpaperMetadataRecord?
    public let wallpaper: WallpaperRecord?
    public let storyMatch: StoryMatch?
    public let thumbnailURL: URL?
    public let originalURL: URL?
    public let isFavorite: Bool

    public init(
        occurrence: WallpaperOccurrence,
        metadata: WallpaperMetadataRecord? = nil,
        wallpaper: WallpaperRecord? = nil,
        storyMatch: StoryMatch? = nil,
        thumbnailURL: URL? = nil,
        originalURL: URL? = nil,
        isFavorite: Bool = false
    ) {
        self.key = occurrence.id
        self.occurrence = occurrence
        self.metadata = metadata
        self.wallpaper = wallpaper
        self.storyMatch = storyMatch
        self.thumbnailURL = thumbnailURL
        self.originalURL = originalURL
        self.isFavorite = isFavorite
    }

    public var id: OccurrenceKey { key }
    public var date: LocalDate { key.localDate }
    public var market: Market { key.market }
    public var wallpaperID: WallpaperID { occurrence.wallpaperID }
    public var title: String? { metadata?.title ?? wallpaper?.canonicalTitle }
    public var copyright: String? { metadata?.copyright ?? wallpaper?.copyright }
    public var sourceURL: URL? { metadata?.sourceURL ?? wallpaper?.sourceURL }
    public var hasThumbnail: Bool { thumbnailURL != nil }
    public var hasOriginal: Bool { originalURL != nil }
    public var displayImageURL: URL? { originalURL ?? thumbnailURL }
}

// MARK: - Cache values

public struct MobileCacheReport: Hashable, Sendable {
    public let usage: StorageUsage
    /// Distinct protected images per reason. One image may appear in several
    /// categories, so the counts must not be summed.
    public let protectedImageCountsByReason: [PinReason: Int]
    public let protectedThumbnailAssetCount: Int
    public let protectedOriginalAssetCount: Int

    public init(
        usage: StorageUsage,
        protectedImageCountsByReason: [PinReason: Int] = [:],
        protectedThumbnailAssetCount: Int = 0,
        protectedOriginalAssetCount: Int = 0
    ) {
        self.usage = usage
        self.protectedImageCountsByReason = protectedImageCountsByReason
        self.protectedThumbnailAssetCount = protectedThumbnailAssetCount
        self.protectedOriginalAssetCount = protectedOriginalAssetCount
    }
}

public struct MobileCacheClearResult: Hashable, Sendable {
    public let removedAssetCount: Int
    public let removedBytes: Int
    public let skippedProtectedCount: Int
    public let failedCount: Int
    public let failedDetail: String?

    public init(
        removedAssetCount: Int = 0,
        removedBytes: Int = 0,
        skippedProtectedCount: Int = 0,
        failedCount: Int = 0,
        failedDetail: String? = nil
    ) {
        self.removedAssetCount = removedAssetCount
        self.removedBytes = removedBytes
        self.skippedProtectedCount = skippedProtectedCount
        self.failedCount = failedCount
        self.failedDetail = failedDetail
    }
}

public enum MobileTodayPhase: Equatable, Sendable {
    case idle
    case loadingCache
    case refreshing
    case ready
    case empty
    case failed(String)
}

// MARK: - Errors

public enum MobileStoreError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedMarket(String)
    case repositoryUnavailable(String)
    case repositoryBusyByAnotherProcess
    case repositoryAlreadyOpenInProcess
    case offline(String)
    case noCachedImage(String)
    case noImageForDate(LocalDate, Market)
    case noFavorites
    case noCachedImages
    case noCurrentSelection
    case unknownWallpaper(String)
    case malformedWallpaperID(String)
    case imageUnavailable(String)
    case persistenceFailed(String)
    case cacheOperationFailed(String)
    case operationInProgress
    case invalidSelection(String)
    case settingsUnavailable
    case refreshFailed(String)

    public var errorDescription: String? {
        let locale = MobileCopyLocale.current
        switch self {
        case .unsupportedMarket(let rawValue):
            return String(
                format: MobileLocalizedString.resolve("不支持这个地区：%@。请选择一个可用的 Bing 地区。", locale: locale),
                rawValue
            )
        case .repositoryUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve("无法打开 Daybreak 本地资料库：%@", locale: locale),
                detail
            )
        case .repositoryBusyByAnotherProcess:
            return MobileLocalizedString.resolve(
                "Daybreak 本地资料库正被另一个进程使用。请关闭其他 Daybreak 实例后重试；本次没有写入任何数据。",
                locale: locale
            )
        case .repositoryAlreadyOpenInProcess:
            return MobileLocalizedString.resolve(
                "本进程已打开 Daybreak 本地资料库。请复用共享的 MobileStore，不要重复打开。",
                locale: locale
            )
        case .offline(let detail):
            return String(
                format: MobileLocalizedString.resolve("当前离线，且所需内容没有完整缓存：%@。请联网后重试，已缓存内容仍可使用。", locale: locale),
                detail
            )
        case .noCachedImage(let detail):
            return String(
                format: MobileLocalizedString.resolve("所选图片尚未缓存：%@。请先在 Daybreak 中打开或下载。", locale: locale),
                detail
            )
        case .noImageForDate(let date, let market):
            return String(
                format: MobileLocalizedString.resolve("%@ 的 %@ 没有本地图片记录。请在 Daybreak 的时光页打开这一天。", locale: locale),
                MobileMarketName.name(for: market, locale: locale),
                MobileDateText.text(date, locale: locale)
            )
        case .noFavorites:
            return MobileLocalizedString.resolve("还没有收藏的壁纸。先在 Daybreak 中收藏一张图片。", locale: locale)
        case .noCachedImages:
            return MobileLocalizedString.resolve("本机还没有缓存任何壁纸。请先在 Daybreak 中打开今日内容。", locale: locale)
        case .noCurrentSelection:
            return MobileLocalizedString.resolve("Daybreak 还没有当前选中的壁纸。请先在今日或时光页选择一张图片。", locale: locale)
        case .unknownWallpaper(let rawValue):
            return String(
                format: MobileLocalizedString.resolve("本机没有壁纸 %@ 的记录。请先在 Daybreak 中打开这张图片。", locale: locale),
                rawValue
            )
        case .malformedWallpaperID(let rawValue):
            return String(
                format: MobileLocalizedString.resolve("壁纸 ID 无效：%@。请使用“来源:图片 ID”格式，例如 bing:OHR.Example。", locale: locale),
                rawValue
            )
        case .imageUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve("无法准备图片：%@", locale: locale),
                detail
            )
        case .persistenceFailed(let detail):
            return String(
                format: MobileLocalizedString.resolve("本地缓存写入失败：%@", locale: locale),
                detail
            )
        case .cacheOperationFailed(let detail):
            return String(
                format: MobileLocalizedString.resolve("缓存操作未完成：%@", locale: locale),
                detail
            )
        case .operationInProgress:
            return MobileLocalizedString.resolve("已有缓存操作正在进行，请稍后再试。", locale: locale)
        case .invalidSelection(let detail):
            return String(
                format: MobileLocalizedString.resolve("当前选择无效：%@", locale: locale),
                detail
            )
        case .settingsUnavailable:
            return MobileLocalizedString.resolve("设置无法读取或保存。", locale: locale)
        case .refreshFailed(let detail):
            return String(
                format: MobileLocalizedString.resolve("无法更新今日内容：%@", locale: locale),
                detail
            )
        }
    }
}

// MARK: - Copy helpers

/// The interface locale used by error text outside SwiftUI's environment.
/// App Intents and repository errors still respect the user's app-language
/// choice instead of always using the device language.
enum MobileCopyLocale {
    static var current: Locale {
        let rawValue = UserDefaults.standard.string(forKey: "daybreak.interfaceLanguage") ?? ""
        switch rawValue {
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "en": return Locale(identifier: "en")
        case "ja": return Locale(identifier: "ja")
        default: return Locale.autoupdatingCurrent
        }
    }
}

enum MobileDateText {
    static func text(_ date: LocalDate, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        let reference = calendar.date(from: components) ?? .distantPast
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: reference)
    }
}

enum MobileMarketName {
    static func name(for market: Market, locale: Locale) -> String {
        guard let profile = BingMarketProfile.profile(for: market) else {
            return market.rawValue
        }
        let region = locale.localizedString(forRegionCode: profile.regionCode)
        let language = locale.localizedString(forLanguageCode: profile.languageCode)
        switch (region, language) {
        case let (region?, language?) where !region.isEmpty && !language.isEmpty:
            return "\(region) · \(language)"
        case let (region?, _) where !region.isEmpty:
            return region
        case let (_, language?) where !language.isEmpty:
            return language
        default:
            return market.rawValue
        }
    }
}

enum MobileErrorText {
    static func describe(_ error: any Error) -> String {
        if let mobile = error as? MobileStoreError {
            return mobile.errorDescription ?? String(describing: mobile)
        }
        if let provider = error as? BingProviderError {
            return describe(provider)
        }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    static func describe(_ error: BingProviderError) -> String {
        let locale = MobileCopyLocale.current
        switch error {
        case .invalidConfiguration(let detail):
            return String(
                format: MobileLocalizedString.resolve("请求设置无效（%@）", locale: locale),
                detail
            )
        case .blockedURL(let host):
            return host.map {
                String(format: MobileLocalizedString.resolve("出于安全考虑，已阻止来自 %@ 的图片", locale: locale), $0)
            } ?? MobileLocalizedString.resolve("出于安全考虑，已阻止该图片来源", locale: locale)
        case .unexpectedRedirect(let statusCode, let host):
            return host.map {
                String(
                    format: MobileLocalizedString.resolve("图片跳转被拒绝（HTTP %lld，%@）", locale: locale),
                    statusCode,
                    $0
                )
            } ?? String(
                format: MobileLocalizedString.resolve("图片跳转被拒绝（HTTP %lld）", locale: locale),
                statusCode
            )
        case .responseTooLarge(let limit):
            return String(
                format: MobileLocalizedString.resolve("文件超过大小限制（%lld 字节）", locale: locale),
                limit
            )
        case .unexpectedContentType(let contentType):
            return contentType.map {
                String(format: MobileLocalizedString.resolve("内容格式异常：%@", locale: locale), $0)
            } ?? MobileLocalizedString.resolve("内容格式异常", locale: locale)
        case .httpStatus(let code, _):
            return String(
                format: MobileLocalizedString.resolve("Bing 返回 HTTP %lld", locale: locale),
                code
            )
        case .malformedJSON, .malformedResponse:
            return MobileLocalizedString.resolve("无法读取 Bing 返回的内容", locale: locale)
        case .noUsableEntries:
            return MobileLocalizedString.resolve("Bing 没有返回可用的内容", locale: locale)
        case .transport(let code):
            return code.map {
                String(format: MobileLocalizedString.resolve("网络传输失败（%@）", locale: locale), String($0))
            } ?? MobileLocalizedString.resolve("网络连接失败", locale: locale)
        case .noImageCandidates:
            return MobileLocalizedString.resolve("没有可用的图片链接", locale: locale)
        case .allImageCandidatesFailed:
            return MobileLocalizedString.resolve("所有候选图片都下载失败", locale: locale)
        case .imageMimeRejected, .imageDecodeFailed, .imageDimensionsRejected:
            return MobileLocalizedString.resolve("图片验证未通过，未保存", locale: locale)
        }
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .file)
    }
}
