import DaybreakCore
import Foundation
import Testing
@testable import Daybreak

@Suite("Today presentation")
struct TodayPresentationTests {
    private func date(_ value: String) -> LocalDate {
        LocalDate(iso8601: value)!
    }

    private func occurrence(
        date value: String = "2026-11-23",
        market: Market = .zhCN,
        imageID: String = "image-a"
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: .bing,
            market: market,
            localDate: date(value),
            wallpaperID: WallpaperID(source: .bing, sourceImageID: imageID)
        )
    }

    private func story(
        for occurrence: WallpaperOccurrence,
        availability: StoryAvailability,
        body: String? = "完整介绍正文"
    ) -> DailyStoryRecord {
        DailyStoryRecord(
            id: "story-\(occurrence.market.rawValue)-\(occurrence.localDate.iso8601)",
            source: occurrence.source,
            market: occurrence.market,
            date: occurrence.localDate,
            associatedWallpaperID: occurrence.wallpaperID,
            title: "标题",
            headline: "导语",
            body: body,
            quickFact: nil,
            copyright: "摄影：Example",
            originalLocale: "zh-Hans",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            availability: availability
        )!
    }

    private func payload(
        storyMatch: StoryMatch?,
        market: Market = .zhCN,
        sourceDate: String = "2026-11-23",
        marketToday: String = "2026-11-23"
    ) -> TodayPayload {
        let occurrence = occurrence(date: sourceDate, market: market)
        return TodayPayload(
            market: market,
            marketToday: date(marketToday),
            occurrence: occurrence,
            metadata: nil,
            wallpaper: nil,
            storyMatch: storyMatch,
            thumbnailURL: nil,
            originalURL: nil,
            cachedAt: nil
        )
    }

    @Test("available story keeps full body and provenance")
    func availableStory() throws {
        let occurrence = occurrence()
        let record = story(for: occurrence, availability: .available)
        let panel = StoryPanel.make(from: payload(
            storyMatch: .matched(record, evidence: .imageIdentityMarketAndDate)
        ))

        guard case .available(let text) = panel else {
            Issue.record("Expected an available story panel")
            return
        }
        #expect(text.body == "完整介绍正文")
        #expect(text.headline == "导语")
        #expect(text.copyright == "摄影：Example")
        #expect(text.locale == "zh-Hans")
        #expect(text.hasBody)
    }

    @Test("unavailable story never exposes a body")
    func unavailableStory() {
        let occurrence = occurrence()
        let record = story(
            for: occurrence,
            availability: .unavailable(.emptyContent),
            body: nil
        )
        let panel = StoryPanel.make(from: payload(storyMatch: .unavailable(record)))

        guard case .unavailable(let reason, _, let headline, let copyright, _) = panel else {
            Issue.record("Expected an unavailable story panel")
            return
        }
        #expect(reason == .emptyContent)
        #expect(headline == "导语")
        #expect(copyright == "摄影：Example")
    }

    @Test("strict matching failure is not treated as a published story")
    func unmatchedStory() {
        let panel = StoryPanel.make(from: payload(storyMatch: .unmatched(.noCandidate)))
        #expect(panel == .notFetched)

        let conflicting = StoryPanel.make(from: payload(
            storyMatch: .unmatched(.imageIdentityMissing(candidateCount: 2))
        ))
        #expect(conflicting == .unmatched(hasCandidates: true))
    }

    @Test("missing match value is not fetched")
    func nilStoryMatch() {
        #expect(StoryPanel.make(from: payload(storyMatch: nil)) == .notFetched)
    }

    @Test("source date and market date are independent")
    func dateIndependence() {
        let stale = payload(
            storyMatch: nil,
            sourceDate: "2026-11-22",
            marketToday: "2026-11-23"
        )
        #expect(!stale.isSourceDateToday)
        #expect(stale.sourceDate.iso8601 == "2026-11-22")
        #expect(stale.marketToday.iso8601 == "2026-11-23")

        let current = payload(storyMatch: nil)
        #expect(current.isSourceDateToday)
    }

    @Test("market choices cover the catalog and never substitute an unknown market")
    func marketChoices() {
        #expect(MarketChoice.matching(.zhCN) == .zhCN)
        #expect(MarketChoice.matching(.enUS) == .enUS)
        #expect(MarketChoice.matching(.jaJP) == .jaJP)
        #expect(MarketChoice.matching(Market("EN-us")) == .enUS)
        #expect(MarketChoice.matching(Market("zh-Hans-CN")) == .zhCN)
        #expect(MarketChoice.matching(Market("de-DE"))?.market == Market("de-DE"))
        #expect(MarketChoice.matching(Market("pt-PT")) == nil)
        #expect(MarketChoice.matching(Market("xx-XX")) == nil)
        #expect(MarketChoice.allCases.count == BingMarketProfile.catalog.count)
        #expect(Set(MarketChoice.allCases.map(\.market)).count == MarketChoice.allCases.count)
        #expect(MarketChoice.allCases.contains { $0.market == Market("fr-CA") })
        #expect(MarketChoice.allCases.contains { $0.market == Market("no-NO") })
    }

    @Test("market labels use the supplied interface locale")
    func marketLabelFormat() throws {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        let japanese = Locale(identifier: "ja")

        let englishRegion = try #require(english.localizedString(forRegionCode: "CN"))
        let englishLanguage = try #require(english.localizedString(forLanguageCode: "zh"))
        let chineseRegion = try #require(chinese.localizedString(forRegionCode: "CN"))
        let chineseLanguage = try #require(chinese.localizedString(forLanguageCode: "zh"))
        let japaneseRegion = try #require(japanese.localizedString(forRegionCode: "CN"))
        let japaneseLanguage = try #require(japanese.localizedString(forLanguageCode: "zh"))

        let englishName = MarketChoice.zhCN.displayName(in: english)
        #expect(englishName == "\(englishRegion) · \(englishLanguage)")
        #expect(!englishName.contains(MarketChoice.zhCN.market.rawValue))

        let chineseName = MarketChoice.zhCN.displayName(in: chinese)
        #expect(chineseName == "\(chineseRegion) · \(chineseLanguage)")
        #expect(chineseName != englishName)

        let japaneseName = MarketChoice.zhCN.displayName(in: japanese)
        #expect(japaneseName == "\(japaneseRegion) · \(japaneseLanguage)")

        // Markets sharing a region must still be distinguished by language.
        let spanishUS = try #require(MarketChoice.matching(Market("es-US")))
        let unitedStates = try #require(english.localizedString(forRegionCode: "US"))
        let englishLanguageUS = try #require(english.localizedString(forLanguageCode: "en"))
        let spanishLanguageUS = try #require(english.localizedString(forLanguageCode: "es"))
        #expect(MarketChoice.enUS.displayName(in: english) == "\(unitedStates) · \(englishLanguageUS)")
        #expect(spanishUS.displayName(in: english) == "\(unitedStates) · \(spanishLanguageUS)")
        #expect(MarketChoice.enUS.displayName(in: english) != spanishUS.displayName(in: english))

        for choice in MarketChoice.allCases {
            #expect(choice.displayName(in: english).contains(" · "))
            #expect(RecapCopy.marketLabel(choice.market, in: english) == choice.displayName(in: english))
            #expect(choice.menuLabel(in: english).hasSuffix(" · \(choice.market.rawValue)"))
        }
    }

    @Test("known source language is named in the supplied interface locale")
    func sourceLanguageName() throws {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        let expectedEnglish = try #require(english.localizedString(forIdentifier: "zh-Hans"))
        let expectedChinese = try #require(chinese.localizedString(forIdentifier: "zh-Hans"))

        #expect(LocalePresentation.sourceLanguageName("zh-Hans", in: english) == expectedEnglish)
        #expect(LocalePresentation.sourceLanguageName("zh-Hans", in: chinese) == expectedChinese)
        #expect(expectedEnglish != "zh-Hans")
        #expect(expectedChinese != "zh-Hans")
    }

    @Test("unknown market and language tags stay explicit")
    func unknownLocaleTags() {
        let english = Locale(identifier: "en")
        let unknownMarket = Market("xx-XX")

        #expect(LocalePresentation.marketName(for: unknownMarket, in: english) == "xx-XX")
        #expect(LocalePresentation.marketTag(for: unknownMarket, in: english) == "xx-XX")
        #expect(LocalePresentation.sourceLanguageName("xx-YY", in: english) == "xx-YY")
        // Foundation would otherwise synthesize "English (Unknown Region)".
        #expect(LocalePresentation.sourceLanguageName("en-ZZ", in: english) == "en-ZZ")
        #expect(LocalePresentation.sourceLanguageName("xx-CN", in: english) == "xx-CN")
        #expect(LocalePresentation.sourceLanguageName("zh-Hans-XX", in: english) == "zh-Hans-XX")
        #expect(LocalePresentation.sourceLanguageName("  ", in: english) == "")
    }

    @Test("recap market lists use the supplied interface locale")
    func recapMarketListLocale() {
        let english = Locale(identifier: "en")
        let joined = RecapCopy.marketsLabel([.zhCN, .enUS], in: english)

        #expect(joined.contains(MarketChoice.zhCN.displayName(in: english)))
        #expect(joined.contains(MarketChoice.enUS.displayName(in: english)))
    }

    @Test("explicit market choices persist canonically and follow-system clears them")
    func marketSelectionPersistence() {
        let suiteName = "DaybreakTodayPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MarketSelection.stored(in: defaults) == .followSystem)

        MarketSelection.explicit(Market("fr-ca")).store(in: defaults)
        #expect(defaults.string(forKey: PreferenceKey.market) == "fr-CA")
        #expect(MarketSelection.stored(in: defaults) == .explicit(Market("fr-CA")))

        MarketSelection.explicit(Market("nb-NO")).store(in: defaults)
        #expect(defaults.string(forKey: PreferenceKey.market) == "no-NO")

        MarketSelection.followSystem.store(in: defaults)
        #expect(defaults.string(forKey: PreferenceKey.market) == nil)
        #expect(MarketSelection.stored(in: defaults) == .followSystem)

        // A legacy or hand-edited value is read as the same explicit market.
        defaults.set("de-de", forKey: PreferenceKey.market)
        #expect(MarketSelection.stored(in: defaults) == .explicit(Market("de-DE")))
    }

    @Test("out-of-catalog saved markets are ignored and disclosed, not coerced")
    func unsupportedStoredMarket() {
        let suiteName = "DaybreakTodayPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("pt-PT", forKey: PreferenceKey.market)
        let stored = MarketSelection.storedPreference(in: defaults)
        #expect(stored.selection == .followSystem)
        #expect(stored.unsupportedRawValue == "pt-PT")

        defaults.set("  ", forKey: PreferenceKey.market)
        #expect(MarketSelection.stored(in: defaults) == .followSystem)
    }

    @Test("automatic writes require both persisted mode and an open gate")
    func automationTruth() {
        #expect(WallpaperAutomationTruth.isEnabled(
            automatic: true,
            writeAuthorized: true
        ))
        #expect(!WallpaperAutomationTruth.isEnabled(
            automatic: true,
            writeAuthorized: false
        ))
        #expect(!WallpaperAutomationTruth.isEnabled(
            automatic: false,
            writeAuthorized: true
        ))
        #expect(!WallpaperAutomationTruth.isEnabled(
            automatic: false,
            writeAuthorized: false
        ))
    }

    @Test("image file extension follows validated MIME type")
    func imageExtensions() {
        #expect(TodayService.fileExtension(for: "image/jpeg") == "jpg")
        #expect(TodayService.fileExtension(for: "image/png") == "png")
        #expect(TodayService.fileExtension(for: "image/heic") == "heic")
        #expect(TodayService.fileExtension(for: "image/webp") == "webp")
        #expect(TodayService.fileExtension(for: "application/octet-stream") == "jpg")
    }
}

/// Regression coverage for Phase C4 interface-language consistency in the
/// non-View Core models.
///
/// These tests never read or write the real interface-language preference.
/// Every assertion passes an explicit locale to a locale-aware helper, so the
/// suite is isolated from the user's defaults and from other suites.
@Suite("Core interface locale")
struct CoreInterfaceLocaleRegressionTests {
    /// The same catalog lookup the app performs, but pinned to one language.
    private func localized(_ key: String, _ language: String) -> String {
        MacLocalizedString.resolve(String.LocalizationValue(key), locale: Locale(identifier: language))
    }

    private func explicitDateTime(_ date: Date, _ language: String) -> String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: Locale(identifier: language)
        ))
    }

    @Test("Core error copy follows the supplied locale")
    @MainActor
    func coreErrorsFollowExplicitLocale() {
        for language in ["en", "zh-Hans", "ja"] {
            let locale = Locale(identifier: language)
            #expect(
                TodayServiceError.unsupportedMarket("xx").description(in: locale)
                    == localized("不支持这个地区，它不在可选的 Bing 地区中。", language)
            )
            #expect(
                TodayServiceError.imageUnavailable("synthetic").description(in: locale)
                    == String(
                        format: localized("图片不可用：%@", language),
                        "synthetic"
                    )
            )
            #expect(
                RecapScreenError.clockUnavailable.description(in: locale)
                    == localized("无法按来源地区换算当前日期，暂不生成回顾。", language)
            )
            #expect(
                ImageDecodeError.unreadableFile.description(in: locale)
                    == localized("无法读取缓存图片", language)
            )
            #expect(
                TodayService.describe(.noUsableEntries(diagnostics: []), locale: locale)
                    == localized("Bing 没有返回可用的内容", language)
            )
            #expect(
                TodayService.describe(.transport(code: -1009), locale: locale)
                    == String(
                        format: localized("网络传输失败（%@）", language),
                        "-1009"
                    )
            )
        }
    }

    @Test("Recap and story copy follow the supplied locale")
    @MainActor
    func recapAndStoryCopyFollowExplicitLocale() {
        // The app-hosted test bundle must expose the String Catalog. Without
        // this guard the comparisons below would fall back to the same source
        // key for every language and pass without testing localization.
        #expect(localized("月度", "en") != localized("月度", "zh-Hans"))
        for language in ["en", "zh-Hans", "ja"] {
            let locale = Locale(identifier: language)
            #expect(RecapSection.monthly.title(in: locale) == localized("月度", language))
            #expect(
                RecapCleanupAction.clearUnprotectedThumbnails.title(in: locale)
                    == localized("清理未受保护缩略图？", language)
            )
            #expect(
                RecapCleanupAction.clearUnprotectedThumbnails.message(in: locale)
                    == localized(
                        "只删除未被收藏、固定日期或当前壁纸保护的缩略图。原图、图片信息、介绍和收藏都会保留，缩略图可在联网后重新缓存。",
                        language
                    )
            )
            #expect(
                RecapCleanupAction.clearUnprotectedThumbnails.confirmLabel(in: locale)
                    == localized("清理", language)
            )
            #expect(
                RecapCleanupAction.removeFavorite(
                    WallpaperID(source: .bing, sourceImageID: "locale-test")
                ).title(in: locale) == localized("取消这张图片的收藏？", language)
            )
            #expect(
                RecapCopy.protectionLabel(.favorite, in: locale)
                    == localized("收藏", language)
            )
            #expect(
                RecapCopy.assetKindLabel(.original, in: locale)
                    == localized("原图", language)
            )
            #expect(
                RecapCopy.coverageStateLabel(.complete, in: locale)
                    == localized("每天都有记录", language)
            )
            #expect(
                StoryCopy.unavailableReason(.notFetched, in: locale)
                    == localized("本次尚未获取该日介绍。", language)
            )
            #expect(
                StoryCopy.unavailableReason(.notProvidedBySource, in: locale)
                    == localized("该地区来源未提供每日介绍。", language)
            )
        }
    }

    @Test("Dates, byte counts and percentages follow the supplied locale")
    @MainActor
    func formattingFollowsExplicitLocale() throws {
        let day = try #require(LocalDate(iso8601: "2026-11-25"))
        let instant = Date(timeIntervalSince1970: 1_794_744_000)
        let count = 1_500_000

        // "fr" is not an app-selectable language. It only makes the
        // locale-sensitive decimal separators observable in byte counts so a
        // system-locale fallback cannot pass by coincidence.
        for language in ["en", "zh-Hans", "ja", "fr"] {
            let locale = Locale(identifier: language)
            #expect(
                StatusFormatter.dateTime(instant, locale: locale)
                    == explicitDateTime(instant, language)
            )
            #expect(
                StatusFormatter.bytes(count, locale: locale)
                    == Int64(count).formatted(.byteCount(style: .file).locale(locale))
            )
            #expect(
                StatusFormatter.bytes(999, locale: locale)
                    == Int64(999).formatted(
                        .byteCount(style: .file, allowedUnits: .bytes).locale(locale)
                    )
            )
            #expect(
                RecapCopy.percentage(0.42, locale: locale)
                    == 0.42.formatted(
                        .percent.precision(.fractionLength(0)).locale(locale)
                    )
            )
            #expect(
                RecapCopy.monthTitle(year: 2026, month: 11, locale: locale)
                    == String(format: localized("%lld年%lld月", language), 2026, 11)
            )
            #expect(
                RecapCopy.dayTitle(day, locale: locale)
                    == String(format: localized("%lld月%lld日", language), 11, 25)
            )
        }
        #expect(RecapCopy.percentage(nil, locale: Locale(identifier: "en")) == "—")
    }

    @Test("Dropped source tags never display as undetermined provenance")
    @MainActor
    func undeterminedSourceTagsAreHidden() {
        #expect(LocalePresentation.determinedLanguageTag("und") == nil)
        #expect(LocalePresentation.determinedLanguageTag("UND") == nil)
        #expect(LocalePresentation.determinedLanguageTag("zxx") == nil)
        #expect(LocalePresentation.determinedLanguageTag("mul") == nil)
        #expect(LocalePresentation.determinedLanguageTag("mis") == nil)
        #expect(LocalePresentation.determinedLanguageTag("und-Latn") == nil)
        #expect(LocalePresentation.determinedLanguageTag("  ") == nil)
        #expect(LocalePresentation.determinedLanguageTag(nil) == nil)
        #expect(LocalePresentation.determinedLanguageTag("zh-Hans") == "zh-Hans")
        #expect(LocalePresentation.determinedLanguageTag("en-US") == "en-US")
        #expect(LocalePresentation.determinedLanguageTag("ja") == "ja")
    }

    @Test("Story provenance hides undetermined source tags")
    @MainActor
    func storyProvenanceHidesUndeterminedTags() {
        let instant = Date(timeIntervalSince1970: 1_794_744_000)
        let english = Locale(identifier: "en")
        let timestamp = StatusFormatter.dateTime(instant, locale: english)

        let unknown = StoryCopy.provenance(
            localeTag: "und",
            fetchedAt: instant,
            in: english
        )
        #expect(!unknown.contains("und"))
        #expect(unknown == MacLocalizedString.resolve("更新于 \(timestamp)", locale: english))

        let unknownScript = StoryCopy.provenance(
            localeTag: "und-Latn",
            fetchedAt: instant,
            in: english
        )
        #expect(!unknownScript.contains("und"))

        let known = StoryCopy.provenance(
            localeTag: "zh-Hans",
            fetchedAt: instant,
            in: english
        )
        #expect(known.contains(LocalePresentation.sourceLanguageName("zh-Hans", in: english)))
        #expect(known.contains(timestamp))
    }

    @Test("Repository errors use app-localized copy and keep diagnostics")
    @MainActor
    func repositoryErrorsUseAppCopy() {
        for language in ["en", "zh-Hans", "ja"] {
            let locale = Locale(identifier: language)
            #expect(
                AppErrorCopy.describe(
                    RepositoryError.invalidDirectory("/tmp/daybreak"),
                    locale: locale
                ) == String(
                    format: localized("缓存目录不可用：%@", language),
                    "/tmp/daybreak"
                )
            )
            #expect(
                AppErrorCopy.describe(
                    RepositoryError.assetWriteFailed("disk full"),
                    locale: locale
                ) == String(
                    format: localized("无法写入图片缓存：%@", language),
                    "disk full"
                )
            )
            #expect(
                AppErrorCopy.describe(RepositoryError.emptyAsset, locale: locale)
                    == localized("无法保存空图片缓存。", language)
            )
            #expect(
                AppErrorCopy.describe(
                    RepositoryError.unreadableIndex(
                        primary: "/a/index",
                        backup: "/b/backup"
                    ),
                    locale: locale
                ) == String(
                    format: localized(
                        "无法读取缓存索引（%@），备份也无法读取（%@）。",
                        language
                    ),
                    "/a/index",
                    "/b/backup"
                )
            )
        }

        let systemError = NSError(
            domain: "DaybreakInterfaceLocaleTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "raw system failure"]
        )
        #expect(
            AppErrorCopy.describe(systemError, locale: Locale(identifier: "en"))
                .contains("raw system failure")
        )
    }

    @Test("Library month title follows the supplied locale")
    @MainActor
    func libraryMonthTitleFollowsExplicitLocale() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakInterfaceLocaleTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        // 2026-11-15 20:00 in the synthetic market's UTC+8 time zone.
        let now: @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_794_744_000)
        }
        let service = try TodayService(directory: directory, now: now)
        let model = LibraryModel(service: service, market: .zhCN, now: now)

        for language in ["en", "zh-Hans", "ja"] {
            #expect(
                model.monthTitle(in: Locale(identifier: language))
                    == String(format: localized("%lld年%lld月", language), 2026, 11)
            )
        }
    }
}
