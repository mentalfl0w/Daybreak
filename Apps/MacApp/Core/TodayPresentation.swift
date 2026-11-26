import DaybreakCore
import Foundation

// MARK: - Locale presentation

/// Human-readable names for app-owned market and language identifiers.
///
/// Only identifiers owned by Daybreak are named here. Bing story text, titles,
/// and copyright remain verbatim and never pass through this helper. A tag that
/// Foundation cannot name is returned unchanged so provenance stays explicit
/// instead of being guessed or mapped onto a nearby language.
enum LocalePresentation {
    /// Localized region and language for a catalog market, such as
    /// `China mainland · Chinese` in English or `中国大陆 · 中文` in Chinese.
    /// A market outside the catalog is returned as its raw provider tag.
    static func marketName(for market: Market, in locale: Locale) -> String {
        guard let profile = BingMarketProfile.profile(for: market) else {
            return market.rawValue
        }
        return marketName(for: profile, in: locale)
    }

    static func marketName(for profile: BingMarketProfile, in locale: Locale) -> String {
        let region = locale.localizedString(forRegionCode: profile.regionCode)
        let language = locale.localizedString(forLanguageCode: profile.languageCode)
        let regionText = region.flatMap { $0.isEmpty ? nil : $0 }
        let languageText = language.flatMap { $0.isEmpty ? nil : $0 }

        switch (regionText, languageText) {
        case let (region?, language?):
            return "\(region) · \(language)"
        case let (region?, nil):
            return region
        case let (nil, language?):
            return language
        case (nil, nil):
            return profile.market.rawValue
        }
    }

    /// Localized name followed by the canonical provider tag. Use in
    /// provenance contexts where the technical market code must stay visible.
    static func marketTag(for market: Market, in locale: Locale) -> String {
        let name = marketName(for: market, in: locale)
        guard name != market.rawValue else { return market.rawValue }
        return "\(name) · \(market.rawValue)"
    }

    /// Human-readable name for a BCP-47 tag such as `zh-Hans` or `en-US`.
    /// Unknown or malformed tags are returned verbatim. Foundation can
    /// synthesize names for partially unknown tags (`en-ZZ` becomes
    /// `English (Unknown Region)`), so the components are validated first to
    /// keep provenance exact instead of mapping an unknown region or language.
    static func sourceLanguageName(_ tag: String, in locale: Locale) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        guard isDisplayableLocaleTag(normalized, in: locale) else { return trimmed }
        return locale.localizedString(forIdentifier: normalized) ?? trimmed
    }

    /// Drops tags that do not identify a concrete source language.
    ///
    /// A provider response without a verified market marker stores
    /// `undeterminedLocale` instead of guessing the request language. That
    /// marker (and the other ISO 639 collective codes) has no user-facing
    /// provenance, so callers hide it rather than printing `und` beside the
    /// image. Concrete tags are returned unchanged.
    static func determinedLanguageTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let language = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .first
        guard let language, !unknownLanguageTags.contains(language.lowercased()) else {
            return nil
        }
        return trimmed
    }

    private static func isDisplayableLocaleTag(_ tag: String, in locale: Locale) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let language = parts.first else { return false }
        guard isLanguageSubtag(language),
              !unknownLanguageTags.contains(language.lowercased()),
              locale.localizedString(forLanguageCode: String(language)) != nil
        else {
            return false
        }

        var index = 1
        if index < parts.count, isScriptSubtag(parts[index]) {
            guard parts[index].lowercased() != "zzzz",
                  locale.localizedString(forScriptCode: String(parts[index])) != nil
            else {
                return false
            }
            index += 1
        }
        if index < parts.count {
            guard isRegionSubtag(parts[index]),
                  !unknownRegionTags.contains(parts[index].uppercased()),
                  locale.localizedString(forRegionCode: String(parts[index])) != nil
            else {
                return false
            }
            index += 1
        }
        return index == parts.count
    }

    private static func isLanguageSubtag(_ value: Substring) -> Bool {
        (2...3).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func isScriptSubtag(_ value: Substring) -> Bool {
        value.count == 4 && value.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func isRegionSubtag(_ value: Substring) -> Bool {
        (value.count == 2 && value.allSatisfy { $0.isASCII && $0.isLetter })
            || (value.count == 3 && value.allSatisfy { $0.isASCII && $0.isNumber })
    }

    /// ISO 639 codes that do not identify a concrete source language.
    private static let unknownLanguageTags: Set<String> = ["und", "zxx", "mul", "mis"]
    /// ISO 3166 user-assigned codes that Foundation names as unknown/pseudo.
    private static let unknownRegionTags: Set<String> = ["ZZ", "XA", "XB"]

    /// Joins already-localized fragments with the interface language's list
    /// separator instead of the system locale's.
    static func joined(_ items: [String], in locale: Locale) -> String {
        guard !items.isEmpty else { return "" }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}

// MARK: - Market

/// One explicit market in the Bing catalog, ready for display.
///
/// Only catalog entries become choices. Unknown provider tags stay raw
/// `Market` values elsewhere and are never mapped onto a different region.
struct MarketChoice: Hashable, Identifiable, Sendable {
    let profile: BingMarketProfile

    init(profile: BingMarketProfile) {
        self.profile = profile
    }

    var id: String { profile.market.rawValue }
    var market: Market { profile.market }

    /// Localized region and language for this market. Uses the SwiftUI
    /// environment locale supplied by the caller, not `Locale.current`, so an
    /// explicit interface-language choice is honored.
    func displayName(in locale: Locale) -> String {
        LocalePresentation.marketName(for: profile, in: locale)
    }

    /// Picker label keeps the provider tag visible after the localized name.
    func menuLabel(in locale: Locale) -> String {
        LocalePresentation.marketTag(for: profile.market, in: locale)
    }

    static let allCases: [MarketChoice] = BingMarketProfile.catalog.map { MarketChoice(profile: $0) }

    static let zhCN = MarketChoice(profile: .zhCN)
    static let enUS = MarketChoice(profile: .enUS)
    static let jaJP = MarketChoice(profile: .jaJP)

    /// Catalog choice for a tag, or `nil` when the market has no enumerated
    /// edition. Callers must disclose the miss instead of substituting.
    static func matching(_ market: Market) -> MarketChoice? {
        BingMarketProfile.profile(for: market).map { MarketChoice(profile: $0) }
    }
}

/// Persisted content-market preference.
///
/// Following the system is the default and is represented by the absence of a
/// stored market. Only explicit choices are written, using the catalog's
/// canonical tag, so a future launch cannot mistake a system default for a
/// user choice.
enum MarketSelection: Hashable, Sendable {
    case followSystem
    case explicit(Market)

    struct Stored: Hashable, Sendable {
        let selection: MarketSelection
        /// Present only when a saved value was outside the catalog. The value
        /// is ignored rather than coerced, and callers may disclose it.
        let unsupportedRawValue: String?
    }

    static func storedPreference(in defaults: UserDefaults) -> Stored {
        guard let raw = defaults.string(forKey: PreferenceKey.market)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return Stored(selection: .followSystem, unsupportedRawValue: nil)
        }
        guard let canonical = BingMarketProfile.canonicalMarket(Market(raw)) else {
            return Stored(selection: .followSystem, unsupportedRawValue: raw)
        }
        return Stored(selection: .explicit(canonical), unsupportedRawValue: nil)
    }

    static func stored(in defaults: UserDefaults) -> MarketSelection {
        storedPreference(in: defaults).selection
    }

    func store(in defaults: UserDefaults) {
        switch self {
        case .followSystem:
            defaults.removeObject(forKey: PreferenceKey.market)
        case .explicit(let market):
            guard let canonical = BingMarketProfile.canonicalMarket(market) else { return }
            defaults.set(canonical.rawValue, forKey: PreferenceKey.market)
        }
    }
}

enum PreferenceKey {
    static let market = "daybreak.market"
}

struct StoryText: Equatable, Sendable {
    let title: String?
    let headline: String?
    let body: String?
    let quickFact: String?
    let copyright: String?
    let sourceURL: URL?
    let locale: String
    let fetchedAt: Date

    var hasBody: Bool {
        [headline, quickFact, body].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum StoryPanel: Equatable, Sendable {
    case available(StoryText)
    case unavailable(reason: StoryUnavailableReason, title: String?, headline: String?, copyright: String?, sourceURL: URL?)
    case unmatched(hasCandidates: Bool)
    case notFetched

    static func make(from payload: TodayPayload) -> StoryPanel {
        guard let match = payload.storyMatch else { return .notFetched }
        switch match {
        case .matched(let story, _):
            if story.isAvailable {
                return .available(StoryText(
                    title: story.title,
                    headline: story.headline,
                    body: story.body,
                    quickFact: story.quickFact,
                    copyright: story.copyright ?? payload.copyright,
                    sourceURL: story.sourceURL ?? payload.sourceURL,
                    locale: story.originalLocale,
                    fetchedAt: story.fetchedAt
                ))
            }
            return .unavailable(
                reason: reason(for: story.availability),
                title: story.title ?? payload.title,
                headline: story.headline,
                copyright: story.copyright ?? payload.copyright,
                sourceURL: story.sourceURL ?? payload.sourceURL
            )
        case .unavailable(let story):
            return .unavailable(
                reason: reason(for: story.availability),
                title: story.title ?? payload.title,
                headline: story.headline,
                copyright: story.copyright ?? payload.copyright,
                sourceURL: story.sourceURL ?? payload.sourceURL
            )
        case .unmatched(let failure):
            switch failure {
            case .noCandidate:
                return .notFetched
            case .imageIdentityMissing, .dateMismatch, .marketMismatch,
                 .imageIdentityConflict, .ambiguousCandidates:
                return .unmatched(hasCandidates: true)
            }
        }
    }

    static func reason(for availability: StoryAvailability) -> StoryUnavailableReason {
        switch availability {
        case .available:
            return .emptyContent
        case .unavailable(let reason):
            return reason
        }
    }
}

enum StoryCopy {
    static func unavailableReason(_ reason: StoryUnavailableReason) -> String {
        unavailableReason(reason, in: WallpaperInterfaceLocale.current)
    }

    static func unavailableReason(
        _ reason: StoryUnavailableReason,
        in locale: Locale
    ) -> String {
        switch reason {
        case .notFetched:
            return MacLocalizedString.resolve("本次尚未获取该日介绍。", locale: locale)
        case .notProvidedBySource:
            return MacLocalizedString.resolve("该地区来源未提供每日介绍。", locale: locale)
        case .fetchFailed:
            return MacLocalizedString.resolve("每日介绍获取失败；图片仍可正常使用。", locale: locale)
        case .emptyContent:
            return MacLocalizedString.resolve("来源未返回可读的介绍正文。", locale: locale)
        case .rateLimited:
            return MacLocalizedString.resolve("来源暂时限制了请求，介绍稍后可以重试。", locale: locale)
        case .malformedResponse:
            return MacLocalizedString.resolve("介绍内容格式异常，已停止读取。", locale: locale)
        case .localeMismatch:
            return MacLocalizedString.resolve("介绍语言与所选地区不一致，因此没有显示在今天的内容里。", locale: locale)
        }
    }

    /// Provenance line for a story panel.
    ///
    /// A tag that does not identify a concrete source language carries no
    /// usable provenance; the line then shows only the localized fetch time
    /// instead of printing the technical tag (`und`) as if it were a language.
    static func provenance(
        localeTag: String,
        fetchedAt: Date,
        in locale: Locale
    ) -> String {
        let timestamp = StatusFormatter.dateTime(fetchedAt, locale: locale)
        guard let language = LocalePresentation.determinedLanguageTag(localeTag) else {
            return MacLocalizedString.resolve("更新于 \(timestamp)", locale: locale)
        }
        let name = LocalePresentation.sourceLanguageName(language, in: locale)
        return MacLocalizedString.resolve("来源语言 \(name) · \(timestamp)", locale: locale)
    }
}

// MARK: - App-localized errors

/// App-owned wrapper for errors that originate in `DaybreakCore`.
///
/// Repository failures carry English technical descriptions from the package.
/// The known cases are mapped to String Catalog copy so they follow the
/// interface language while retaining paths, keys, versions and other
/// diagnostic details. Errors this helper does not recognize keep their own
/// localized description, preserving the original system text for `NSError`
/// and provider failures.
enum AppErrorCopy {
    static func describe(_ error: Error) -> String {
        describe(error, locale: WallpaperInterfaceLocale.current)
    }

    static func describe(_ error: Error, locale: Locale) -> String {
        if let repositoryError = error as? RepositoryError {
            return describe(repositoryError, locale: locale)
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    static func describe(_ error: RepositoryError) -> String {
        describe(error, locale: WallpaperInterfaceLocale.current)
    }

    static func describe(_ error: RepositoryError, locale: Locale) -> String {
        switch error {
        case .invalidDirectory(let path):
            return MacLocalizedString.resolve("缓存目录不可用：\(path)", locale: locale)
        case .unsupportedSchemaVersion(let found, let supported):
            return MacLocalizedString.resolve("缓存数据版本 \(found) 不受支持（当前版本可读取 \(supported)）。", locale: locale)
        case .unreadableIndex(let primary, let backup):
            if let backup {
                return MacLocalizedString.resolve("无法读取缓存索引（\(primary)），备份也无法读取（\(backup)）。", locale: locale)
            }
            return MacLocalizedString.resolve("无法读取缓存索引（\(primary)），且没有可用备份。", locale: locale)
        case .invalidRecord(let detail):
            return MacLocalizedString.resolve("缓存记录无效：\(detail)", locale: locale)
        case .occurrenceConflict(let key), .metadataConflict(let key):
            return MacLocalizedString.resolve("缓存记录冲突：\(String(describing: key))", locale: locale)
        case .wallpaperConflict(let id):
            return MacLocalizedString.resolve("缓存记录冲突：\(String(describing: id))", locale: locale)
        case .storyConflict(let id):
            return MacLocalizedString.resolve("缓存记录冲突：\(id)", locale: locale)
        case .pinIdentityMismatch(let key):
            return MacLocalizedString.resolve("固定日期的记录与图片标识不一致：\(String(describing: key))", locale: locale)
        case .emptyAsset:
            return MacLocalizedString.resolve("无法保存空图片缓存。", locale: locale)
        case .invalidAssetExtension(let value):
            return MacLocalizedString.resolve("图片缓存扩展名无效：\(value)", locale: locale)
        case .protectedAsset(let wallpaperID):
            return MacLocalizedString.resolve("该图片受保护，不能删除缓存：\(String(describing: wallpaperID))", locale: locale)
        case .assetWriteFailed(let detail):
            return MacLocalizedString.resolve("无法写入图片缓存：\(detail)", locale: locale)
        case .writeFailed(let detail):
            return MacLocalizedString.resolve("无法写入缓存索引：\(detail)", locale: locale)
        case .migrationFailed(let detail):
            return MacLocalizedString.resolve("迁移旧缓存失败：\(detail)", locale: locale)
        case .repairFailed(let detail):
            return MacLocalizedString.resolve("修复缓存失败：\(detail)", locale: locale)
        }
    }
}

enum StatusFormatter {
    /// Dates shown beside app-owned names use the same interface locale as the
    /// surrounding SwiftUI text. Callers that already have the SwiftUI
    /// environment locale pass it explicitly; the default is the app-selected
    /// language so model-produced status text cannot fall back to the system
    /// locale.
    static func dateTime(
        _ date: Date,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    /// Byte counts are formatted with the interface locale so decimal
    /// separators and localized unit names match the rest of the UI.
    ///
    /// `ByteCountFormatter` has no per-instance locale on macOS, so its
    /// spelled-out unit words would follow the system language. The value
    /// format style keeps the file-size units while honoring the app-selected
    /// language. Sub-kilobyte values keep a spelled-out byte unit instead of
    /// being rounded up to one kilobyte.
    static func bytes(_ count: Int, locale: Locale = WallpaperInterfaceLocale.current) -> String {
        let units: ByteCountFormatStyle.Units = count.magnitude < 1_000 ? .bytes : .all
        return Int64(count).formatted(
            .byteCount(style: .file, allowedUnits: units).locale(locale)
        )
    }
}
