import DaybreakCore
import Foundation
import SwiftUI
/// Presentation for the Bing image download preference.
///
/// The raw `BingImagePreference` is the persisted value; this extension only
/// supplies interface copy. Changing it never deletes or re-downloads existing
/// cache entries; it changes which candidate later fetches prefer.
extension BingImagePreference {
    var settingsTitleKey: String.LocalizationValue {
        switch self {
        case .highResolution: return "高清"
        case .fullHD: return "全高清"
        case .compact: return "省流"
        }
    }

    var settingsDetailKey: String.LocalizationValue {
        switch self {
        case .highResolution:
            return "优先选择来源提供的最高分辨率图片；画质最好，占用与流量也最大。"
        case .fullHD:
            return "优先选择约 1920 × 1080 的图片；适合大多数手机和 iPad 屏幕。"
        case .compact:
            return "优先选择约 1366 × 768 的图片；下载更快、占用更小，放大查看时细节较少。"
        }
    }

    var settingsSymbol: String {
        switch self {
        case .highResolution: return "sparkles"
        case .fullHD: return "rectangle.inset.filled"
        case .compact: return "leaf"
        }
    }

    func settingsTitle(locale: Locale) -> String {
        MobileLocalizedString.resolve(settingsTitleKey, locale: locale)
    }

    func settingsDetail(locale: Locale) -> String {
        MobileLocalizedString.resolve(settingsDetailKey, locale: locale)
    }

    /// Honest summary of what the preference can and cannot promise. Bing
    /// chooses the candidate list; a requested tier may be unavailable.
    static var settingsFooterKey: String.LocalizationValue {
        "只影响之后新下载的图片；已缓存图片不会自动替换。来源不一定提供所选的尺寸，Daybreak 会按可用候选回退，不会拉伸或伪造分辨率。"
    }
}
