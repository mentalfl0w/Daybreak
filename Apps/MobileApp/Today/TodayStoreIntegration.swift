import DaybreakCore
import Foundation

/// Maps the shared store's authoritative Today snapshot onto the Today
/// screen's display value and localized diagnostics.
extension MobileStore {
    @MainActor
    var todayDisplayContent: TodayDisplayContent? {
        guard let snapshot = today else { return nil }
        return TodayDisplayContent(
            occurrence: snapshot.occurrence,
            marketToday: snapshot.marketToday,
            title: snapshot.title,
            copyright: snapshot.copyright,
            sourceURL: snapshot.sourceURL,
            storyMatch: snapshot.storyMatch,
            thumbnailCached: snapshot.hasThumbnail,
            originalCached: snapshot.hasOriginal,
            isFavorite: isTodayFavorite,
            fetchedAt: snapshot.metadata?.fetchedAt ?? snapshot.wallpaper?.fetchedAt,
            cachedAt: snapshot.cachedAt
        )
    }

    @MainActor
    var todayRefreshWarnings: [String] {
        guard let warnings = today?.warnings else { return [] }
        return warnings.map { TodayWarningCopy.text(for: $0, locale: interfaceLocale) }
    }
}

/// User-facing explanations for refresh diagnostics owned by `MobileStore`.
///
/// The store reports reasons, never fabricated story text or a false success.
/// Presentation stays here so every mobile surface can use the same wording.
@MainActor
enum TodayWarningCopy {
    static func text(for warning: MobileRefreshWarning, locale: Locale) -> String {
        switch warning {
        case .sourceDateBehind(let sourceDate, let marketToday):
            return String(
                    format: MobileLocalizedString.resolve(
                        "来源尚未发布该地区的今日内容；当前显示 %@ 的最新来源日期（地区今天为 %@）。",
                    locale: locale
                ),
                TodayFormatting.sourceDate(sourceDate, locale: locale),
                TodayFormatting.sourceDate(marketToday, locale: locale)
            )
        case .storiesUnavailable(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return MobileLocalizedString.resolve("今日介绍未能获取；图片与版权信息仍可使用。", locale: locale)
            }
            return String(
                format: MobileLocalizedString.resolve("今日介绍未能完整获取：%@。图片与版权信息仍可使用。", locale: locale),
                trimmed
            )
        case .thumbnailBackfillIncomplete(let count, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return String(
                    format: MobileLocalizedString.resolve("%lld 张历史预览图未能缓存，联网后可重试。", locale: locale),
                    count
                )
            }
            return String(
                format: MobileLocalizedString.resolve("%lld 张历史预览图未能缓存：%@。联网后可重试。", locale: locale),
                count,
                trimmed
            )
        }
    }
}
