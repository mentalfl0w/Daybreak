import AppIntents
import DaybreakCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Shared result

private enum DaybreakIntentResult {
    static func make(
        for prepared: DaybreakPreparedWallpaper
    ) -> IntentResultContainer<IntentFile, Never, Never, IntentDialog> {
        var file = IntentFile(
            fileURL: prepared.export.fileURL,
            filename: prepared.export.filename,
            type: prepared.export.contentType
        )
        // Both files are intent-owned temporary copies. System removal after
        // the shortcut finishes is safe; the repository original is untouched.
        file.removedOnCompletion = prepared.export.removeOnCompletion
        return .result(
            value: file,
            dialog: IntentDialog(stringLiteral: DaybreakShortcutService.live.dialog(for: prepared))
        )
    }

    static func resolvedDate(from date: Date) throws -> LocalDate {
        guard let value = DaybreakCalendarDate.localDate(from: date) else {
            throw DaybreakShortcutError.invalidDate
        }
        return value
    }
}

// MARK: - Today

struct GetTodayWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource { "获取今日 Daybreak 壁纸" }
    static var description: IntentDescription {
        IntentDescription("返回 Daybreak 为应用当前地区缓存的今日壁纸文件；若今天尚未缓存会明确报错，不拿旧图冒充今日。“输出”可选原图或目标屏幕比例的构图裁切；后台不会检测方向或折叠状态，请按设备手动选择。")
    }
    /// Background is intentional: a personal daily automation must work while
    /// the app UI is not in the foreground.
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "地区")
    var market: DaybreakMarketEntity

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    init() {
        market = .automatic
        output = .original
    }

    static var parameterSummary: some ParameterSummary {
        Summary("获取今日壁纸") {
            \.$market
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: .today(market: market.explicitMarket),
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}

// MARK: - Specific date and market

struct GetDateWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource { "获取指定日期的 Daybreak 壁纸" }
    static var description: IntentDescription {
        IntentDescription("按来源日期和地区返回 Daybreak 已缓存的壁纸；日期按你选择的日历日期解释，不会静默换图。")
    }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "日期", kind: .date)
    var date: Date

    @Parameter(title: "地区")
    var market: DaybreakMarketEntity

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    static var parameterSummary: some ParameterSummary {
        Summary("获取指定日期的壁纸") {
            \.$date
            \.$market
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let sourceDate = try DaybreakIntentResult.resolvedDate(from: date)
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: .date(sourceDate, market: market.explicitMarket),
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}

struct GetMarketWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource { "获取指定地区今日的 Daybreak 壁纸" }
    static var description: IntentDescription {
        IntentDescription("返回指定 Bing 地区市场今天发布的 Daybreak 壁纸文件；与设备界面语言无关。")
    }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "地区")
    var market: DaybreakMarketEntity

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    static var parameterSummary: some ParameterSummary {
        Summary("获取指定地区今日的壁纸") {
            \.$market
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let target: DaybreakShortcutTarget = if let explicit = market.explicitMarket {
            .marketToday(explicit)
        } else {
            .today(market: nil)
        }
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: target,
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}

// MARK: - Random and favorites

struct GetRandomWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource { "随机获取一张 Daybreak 壁纸" }
    static var description: IntentDescription {
        IntentDescription("从本机已缓存的壁纸中随机返回一张；没有缓存时明确报错，不联网编造结果。")
    }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    init() {
        output = .original
    }

    static var parameterSummary: some ParameterSummary {
        Summary("随机获取一张壁纸") {
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: .randomCached,
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}

struct GetFavoriteWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource { "获取一张收藏的 Daybreak 壁纸" }
    static var description: IntentDescription {
        IntentDescription("从你在 Daybreak 中收藏的图片里随机返回一张；还没有收藏时明确报错。")
    }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    init() {
        output = .original
    }

    static var parameterSummary: some ParameterSummary {
        Summary("获取一张收藏的壁纸") {
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: .favorite,
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}

// MARK: - Current selection

struct GetCurrentWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource { "获取 Daybreak 当前选中的壁纸" }
    static var description: IntentDescription {
        IntentDescription("返回 Daybreak 应用内当前选中的图片。iOS 没有公开 API 读取系统壁纸，所以这里不会假装是系统当前壁纸。")
    }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    init() {
        output = .original
    }

    static var parameterSummary: some ParameterSummary {
        Summary("获取当前选中的壁纸") {
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: .currentSelection,
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}

// MARK: - Wallpaper ID from Shortcuts text input

/// The bridge used by the `shortcuts://run-shortcut?name=…&input=text&text=…`
/// flow: the app passes a canonical wallpaper ID as text, the shortcut feeds
/// that text into this action, and the action returns a real file resolved
/// through the app's own store. A sandbox file URL never crosses processes.
struct GetWallpaperByIDIntent: AppIntent {
    static var title: LocalizedStringResource { "按 ID 获取 Daybreak 壁纸" }
    static var description: IntentDescription {
        IntentDescription("把“来源:图片 ID”文本（例如 bing:OHR.Example）解析为 Daybreak 已缓存的真实图片文件。用于“Daybreak Apply”快捷指令接住从应用传入的文本。“输出”可选原图或目标屏幕比例；后台不检测方向或折叠状态，请手动选择。")
    }
    static var supportedModes: IntentModes { .background }

    @Parameter(
        title: "壁纸 ID",
        description: "来源:图片 ID，例如 bing:OHR.Example。可在 Daybreak 的快捷指令指南中复制。",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var wallpaperID: String

    @Parameter(title: "输出")
    var output: DaybreakWallpaperOutput

    init() {
        output = .original
    }

    static var parameterSummary: some ParameterSummary {
        Summary("按 ID 获取壁纸") {
            \.$wallpaperID
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let prepared = try await DaybreakShortcutService.live.prepare(
            target: .wallpaperID(wallpaperID),
            output: output
        )
        return DaybreakIntentResult.make(for: prepared)
    }
}
