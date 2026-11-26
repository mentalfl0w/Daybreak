import AppIntents
import DaybreakCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Store boundary

/// A real image prepared by the shared mobile store for one intent.
///
/// The store owns the file. Intents never open the repository, never download
/// from an extension and never guess a date. `fileURL` is an app-owned copy in
/// the temporary directory that stays valid until the intent returns.
struct DaybreakShortcutImage: Sendable, Hashable {
    let wallpaperID: WallpaperID
    let fileURL: URL
    let mimeType: String
    let fileExtension: String
    let sourceDate: LocalDate
    let market: Market
    let title: String?
    let sourceURL: URL?
    let isOriginal: Bool
}

/// A real, readable file the intent can hand to Shortcuts.
struct DaybreakShortcutExport: Sendable, Hashable {
    let fileURL: URL
    let filename: String
    let contentType: UTType
    /// True only for app-cache exports that may be removed after the shortcut
    /// finishes. A long-lived repository original must never be marked
    /// removable here.
    let removeOnCompletion: Bool
}

/// The narrow, background-safe boundary the intents need from the single
/// shared mobile store.
///
/// Intents never open `WallpaperRepository` themselves. In the app process the
/// live implementation forwards to `MobileIntentService.shared`, which uses
/// the same process-wide store/repository as the UI. No App Intents extension
/// is added, so Shortcuts launches the app bundle (foreground or background)
/// rather than a second repository writer.
protocol DaybreakShortcutDataSource: Sendable {
    func prepareImage(_ target: DaybreakShortcutTarget) async throws -> DaybreakShortcutImage
}

// MARK: - Requested image

enum DaybreakShortcutTarget: Sendable, Hashable {
    /// `nil` market means the app's preferred market.
    case today(market: Market?)
    case date(LocalDate, market: Market?)
    /// A specific market's local today; never the preferred market silently.
    case marketToday(Market)
    case randomCached
    case favorite
    case currentSelection
    case wallpaperID(String)
}

// MARK: - Errors

enum DaybreakShortcutError: Error, Equatable, Sendable, LocalizedError {
    case malformedWallpaperID
    case unsupportedMarket(Market)
    case todayNotAvailable(market: Market, date: LocalDate)
    case dayNotStored(date: LocalDate, market: Market)
    case unknownWallpaper(String)
    case noFavorites
    case noCachedWallpapers
    case noCurrentSelection
    case invalidDate
    case offline(String)
    case repositoryBusy
    case imageUnavailable(String)
    case originalUnavailable(String)
    case cropUnavailable(String)
    case storeUnavailable(String)
    case timedOut

    var errorDescription: String? {
        let locale = DaybreakShortcutLocale.current
        switch self {
        case .malformedWallpaperID:
            return MobileLocalizedString.resolve(
                "壁纸 ID 无效。请使用“来源:图片 ID”的格式，例如 bing:OHR.Example。",
                locale: locale
            )
        case .unsupportedMarket(let market):
            return String(
                format: MobileLocalizedString.resolve("不支持这个地区：%@。请先在 Daybreak 设置中选择一个支持的地区。", locale: locale),
                market.rawValue
            )
        case .todayNotAvailable(let market, let date):
            return String(
                    format: MobileLocalizedString.resolve(
                        "%@ 的 %@ 图片尚未缓存，或只缓存了其他日期。请先打开 Daybreak 更新，或把快捷指令自动化改到稍晚的时间。",
                    locale: locale
                ),
                DaybreakShortcutDisplay.marketName(market, locale: locale),
                DaybreakShortcutDisplay.dateText(date, locale: locale)
            )
        case .dayNotStored(let date, let market):
            return String(
                    format: MobileLocalizedString.resolve(
                        "%@ 没有 %@ 的本地图片。请在 Daybreak 的时光页打开并缓存这一天。",
                    locale: locale
                ),
                DaybreakShortcutDisplay.marketName(market, locale: locale),
                DaybreakShortcutDisplay.dateText(date, locale: locale)
            )
        case .unknownWallpaper(let rawValue):
            return String(
                format: MobileLocalizedString.resolve("本机没有壁纸 %@ 的记录。请先在 Daybreak 中打开这张图片。", locale: locale),
                rawValue
            )
        case .noFavorites:
            return MobileLocalizedString.resolve("还没有可用的收藏壁纸。先在 Daybreak 中收藏并缓存一张图片。", locale: locale)
        case .noCachedWallpapers:
            return MobileLocalizedString.resolve("本机还没有可用的壁纸缓存。请先打开 Daybreak 下载或更新今日壁纸。", locale: locale)
        case .noCurrentSelection:
            return MobileLocalizedString.resolve("Daybreak 还没有可用的当前选中壁纸。请先在今日或时光页选择并缓存一张图片。", locale: locale)
        case .invalidDate:
            return MobileLocalizedString.resolve("日期无效，无法转换为来源日历日期。请重新选择日期。", locale: locale)
        case .offline(let detail):
            return String(
                format: MobileLocalizedString.resolve("当前离线，且所选壁纸没有完整缓存：%@。请联网后重试，或先在 Daybreak 中缓存这张图片。", locale: locale),
                detail
            )
        case .repositoryBusy:
            return MobileLocalizedString.resolve(
                "Daybreak 本地资料库正被另一个进程使用。请关闭其他 Daybreak 窗口或扩展后重试；本次没有写入任何数据。",
                locale: locale
            )
        case .imageUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve("无法准备壁纸图片：%@", locale: locale),
                detail
            )
        case .originalUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve("只找到缓存缩略图，未取得完整原图：%@。请联网后重试，或先在 Daybreak 中下载原图。", locale: locale),
                detail
            )
        case .cropUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve("无法生成裁切导出：%@", locale: locale),
                detail
            )
        case .storeUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve("无法打开 Daybreak 本地资料库：%@", locale: locale),
                detail
            )
        case .timedOut:
            return MobileLocalizedString.resolve(
                "准备壁纸超时。请稍后重试，或先打开 Daybreak 完成更新。",
                locale: locale
            )
        }
    }
}

// MARK: - Locale and display helpers

/// Interface-language lookup for app-owned intent strings.
///
/// The App Intents framework localizes titles and parameter names through the
/// app catalog. Runtime dialogs and errors use the app's own language choice
/// when present, so a user who set Daybreak to Japanese does not get Chinese
/// error text merely because the device language is different.
enum DaybreakShortcutLocale {
    static let interfaceLanguageDefaultsKey = "daybreak.interfaceLanguage"

    static var current: Locale {
        let stored = UserDefaults.standard.string(forKey: interfaceLanguageDefaultsKey) ?? ""
        switch stored {
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "en": return Locale(identifier: "en")
        case "ja": return Locale(identifier: "ja")
        default: return Locale.current
        }
    }
}

enum DaybreakShortcutDisplay {
    static func dateText(_ date: LocalDate, locale: Locale) -> String {
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

    static func marketName(_ market: Market, locale: Locale) -> String {
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

    static func shortDate(_ date: LocalDate, locale: Locale) -> String {
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
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: reference)
    }
}

// MARK: - Calendar date

enum DaybreakCalendarDate {
    /// Shortcuts date values are calendar picks. Interpret their year, month
    /// and day directly instead of converting the instant through Bing's
    /// market time zone (which could move the request to a neighbouring day).
    static func localDate(from date: Date, timeZone: TimeZone = .current) -> LocalDate? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return LocalDate(year: year, month: month, day: day)
    }
}

// MARK: - Wallpaper ID text

/// Canonical text form of a wallpaper identity for Shortcuts text input.
///
/// A run-shortcut URL can only carry text, not a sandbox file URL. The text is
/// therefore the canonical `source:sourceImageID` identity; the intent resolves
/// it through the shared store and returns a real file. Parsing is strict so a
/// missing ID cannot silently become a different wallpaper.
struct DaybreakWallpaperReference: Hashable, Sendable {
    let wallpaperID: WallpaperID

    init(wallpaperID: WallpaperID) {
        self.wallpaperID = wallpaperID
    }

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let source = SourceID(String(parts[0]))
        let imageID = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.isValid, !imageID.isEmpty else { return nil }
        let identifier = WallpaperID(source: source, sourceImageID: imageID)
        guard identifier.isValid else { return nil }
        self.wallpaperID = identifier
    }

    var text: String { wallpaperID.description }
}

// MARK: - App entity and enum parameters

/// One selectable Bing market for Shortcuts, covering the full app catalog.
///
/// The query returns every `BingMarketProfile.catalog` market plus an
/// automatic option that follows Daybreak's own setting. No market is silently
/// dropped because it is outside the three most common product markets.
struct DaybreakMarketEntity: AppEntity, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "地区" }
    static var defaultQuery: DaybreakMarketQuery { DaybreakMarketQuery() }

    static let automatic = DaybreakMarketEntity(id: "automatic", market: nil)

    /// Catalog order is preserved so the picker stays stable.
    static var all: [DaybreakMarketEntity] {
        [.automatic] + BingMarketProfile.catalog.map { DaybreakMarketEntity(market: $0.market) }
    }

    let id: String
    let market: Market?

    private init(id: String, market: Market?) {
        self.id = id
        self.market = market
    }

    init(market: Market) {
        self.init(id: market.rawValue, market: market)
    }

    init?(identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Self.automatic.id {
            self = .automatic
            return
        }
        guard let canonical = BingMarketProfile.canonicalMarket(Market(trimmed)) else {
            return nil
        }
        self.init(market: canonical)
    }

    var displayRepresentation: DisplayRepresentation {
        if let market {
            let name = DaybreakShortcutDisplay.marketName(market, locale: DaybreakShortcutLocale.current)
            return DisplayRepresentation(
                title: LocalizedStringResource(stringLiteral: name),
                subtitle: LocalizedStringResource(stringLiteral: market.rawValue)
            )
        }
        return DisplayRepresentation(
            title: "跟随 Daybreak 设置",
            subtitle: "使用应用当前地区"
        )
    }

    var explicitMarket: Market? { market }

    func resolved(preferred: Market) -> Market { market ?? preferred }
}

struct DaybreakMarketQuery: EntityQuery {
    typealias Entity = DaybreakMarketEntity

    init() {}

    func entities(for identifiers: [DaybreakMarketEntity.ID]) async throws -> [DaybreakMarketEntity] {
        identifiers.compactMap { DaybreakMarketEntity(identifier: $0) }
    }

    func suggestedEntities() async throws -> [DaybreakMarketEntity] {
        DaybreakMarketEntity.all
    }
}

enum DaybreakWallpaperOutput: String, AppEnum, CaseIterable, Sendable {
    case original
    case lockScreen
    case homeScreen
    case landscape
    case padLandscape
    case duoOuter
    case duoInnerPortrait
    case duoInnerWide

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "输出文件" }

    static var caseDisplayRepresentations: [DaybreakWallpaperOutput: DisplayRepresentation] {
        [
            .original: DisplayRepresentation(
                title: "原图（推荐）",
                subtitle: "从 Daybreak 缓存返回已验证的原图文件"
            ),
            .lockScreen: DisplayRepresentation(
                title: "锁屏裁切导出",
                subtitle: "生成文件；不代表系统可分别设置锁屏和主屏幕"
            ),
            .homeScreen: DisplayRepresentation(
                title: "主屏幕裁切导出",
                subtitle: "生成文件；不代表系统可分别设置锁屏和主屏幕"
            ),
            .landscape: DisplayRepresentation(title: "横屏裁切导出"),
            .padLandscape: DisplayRepresentation(
                title: "iPad 横屏裁切导出",
                subtitle: "近似 4:3 构图；后台不检测方向或折叠状态，请手动选择"
            ),
            .duoOuter: DisplayRepresentation(title: "Duo 外屏裁切导出"),
            .duoInnerPortrait: DisplayRepresentation(title: "Duo 内屏竖屏裁切导出"),
            .duoInnerWide: DisplayRepresentation(title: "Duo 内屏宽屏裁切导出")
        ]
    }

    var isOriginal: Bool { self == .original }

    var cropPreset: WallpaperCropPreset? {
        switch self {
        case .original: return nil
        case .lockScreen: return .lockScreen
        case .homeScreen: return .homeScreen
        case .landscape: return .landscape
        case .padLandscape: return .padLandscape
        case .duoOuter: return .duoOuter
        case .duoInnerPortrait: return .duoInnerPortrait
        case .duoInnerWide: return .duoInnerWide
        }
    }

    var localizedTitle: String {
        let locale = DaybreakShortcutLocale.current
        switch self {
        case .original: return MobileLocalizedString.resolve("原图", locale: locale)
        case .lockScreen: return MobileLocalizedString.resolve("锁屏裁切", locale: locale)
        case .homeScreen: return MobileLocalizedString.resolve("主屏幕裁切", locale: locale)
        case .landscape: return MobileLocalizedString.resolve("横屏裁切", locale: locale)
        case .padLandscape: return MobileLocalizedString.resolve("iPad 横屏裁切", locale: locale)
        case .duoOuter: return MobileLocalizedString.resolve("Duo 外屏裁切", locale: locale)
        case .duoInnerPortrait: return MobileLocalizedString.resolve("Duo 内屏竖屏裁切", locale: locale)
        case .duoInnerWide: return MobileLocalizedString.resolve("Duo 内屏宽屏裁切", locale: locale)
        }
    }
}
