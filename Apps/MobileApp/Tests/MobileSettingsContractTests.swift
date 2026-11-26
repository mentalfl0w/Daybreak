import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Mobile settings contract")
struct MobileSettingsContractTests {
    @Test("defaults are follow-system, high resolution and 1 GB split 20/80")
    func defaults() {
        let settings = MobileSettings()
        #expect(settings.interfaceLanguage == .system)
        #expect(settings.marketPreference == .followSystem)
        #expect(settings.imageQuality == .highResolution)
        #expect(settings.thumbnailCacheLimitBytes == 200_000_000)
        #expect(settings.originalCacheLimitBytes == 800_000_000)
        #expect(settings.totalCacheLimitBytes == 1_000_000_000)
        #expect(settings.totalCacheLimitBytes == MobileSettings.defaultCacheCapacityBytes)
        #expect(settings.cacheLimits.thumbnailBytes == 200_000_000)
        #expect(settings.cacheLimits.originalBytes == 800_000_000)
    }

    @Test("explicit market preference round-trips without losing the tag")
    func marketPreferenceCodable() throws {
        let values: [MobileMarketPreference] = [
            .followSystem,
            .market(.zhCN),
            .market(.enUS),
            .market(.jaJP),
            .market(Market("zh-HK"))
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(
                MobileMarketPreference.self,
                from: data
            )
            #expect(decoded == value)
        }
    }

    @Test("settings persist in the shared standard key and raw language key")
    func persistence() {
        let environment = MobileTestDefaults()
        defer { environment.cleanUp() }

        let store = environment.settingsStore
        #expect(store.load() == MobileSettings())

        var settings = MobileSettings()
        settings.interfaceLanguage = .japanese
        settings.marketPreference = .market(.jaJP)
        settings.imageQuality = .fullHD
        settings.thumbnailCacheLimitBytes = 100
        settings.originalCacheLimitBytes = 400
        store.save(settings)

        #expect(
            environment.defaults.string(
                forKey: UserDefaultsMobileSettingsStore.interfaceLanguageKey
            ) == "ja"
        )

        let reloaded = environment.settingsStore.load()
        #expect(reloaded == settings)
    }

    @Test("follow-system removes the raw language key")
    func systemLanguageRemovesRawKey() {
        let environment = MobileTestDefaults()
        defer { environment.cleanUp() }
        let store = environment.settingsStore

        var settings = MobileSettings()
        settings.interfaceLanguage = .english
        store.save(settings)
        #expect(
            environment.defaults.string(
                forKey: UserDefaultsMobileSettingsStore.interfaceLanguageKey
            ) == "en"
        )

        settings.interfaceLanguage = .system
        store.save(settings)
        #expect(
            environment.defaults.string(
                forKey: UserDefaultsMobileSettingsStore.interfaceLanguageKey
            ) == nil
        )
        #expect(environment.settingsStore.load().interfaceLanguage == .system)
    }

    @Test("malformed JSON falls back to defaults; a known raw language still applies")
    func malformedSettingsFallback() {
        let environment = MobileTestDefaults()
        defer { environment.cleanUp() }
        let store = environment.settingsStore

        environment.defaults.set(
            Data("not-json".utf8),
            forKey: UserDefaultsMobileSettingsStore.settingsKey
        )
        environment.defaults.set(
            "en",
            forKey: UserDefaultsMobileSettingsStore.interfaceLanguageKey
        )

        let loaded = store.load()
        #expect(loaded.interfaceLanguage == .english)
        #expect(loaded.marketPreference == .followSystem)
        #expect(loaded.imageQuality == .highResolution)
        #expect(loaded.thumbnailCacheLimitBytes == MobileSettings.defaultThumbnailCacheLimitBytes)
        #expect(loaded.originalCacheLimitBytes == MobileSettings.defaultOriginalCacheLimitBytes)
    }

    @Test("section titles resolve in the selected interface language")
    @MainActor
    func sectionTitlesResolveInInterfaceLanguage() {
        let cases = MobileNavigationState.Section.allCases
        // Each expectation pairs a non-source language with the catalog entry
        // for that language. Resolving with `String(localized:locale:)` alone
        // ignores the locale for lookup and returns the launch language for
        // every case, so at least one of these assertions fails on any host.
        #expect(
            cases.map { $0.localizedTitle(in: MobileInterfaceLanguage.english.locale) }
                == ["Today", "Timeline", "Settings"]
        )
        #expect(
            cases.map { $0.localizedTitle(in: MobileInterfaceLanguage.japanese.locale) }
                == ["今日", "タイムライン", "設定"]
        )
        #expect(
            cases.map { $0.localizedTitle(in: MobileInterfaceLanguage.simplifiedChinese.locale) }
                == ["今日", "时光", "设置"]
        )
        // Region-qualified locales still match the catalog's language.
        #expect(
            cases.map { $0.localizedTitle(in: Locale(identifier: "en_GB")) }
                == ["Today", "Timeline", "Settings"]
        )
    }

    @Test("shared localization helper looks the key up in the requested locale")
    func sharedLocalizationHelperUsesRequestedLocale() {
        // Navigation titles resolve through the same helper as the section
        // titles above, so this covers the shared path with other catalog keys.
        #expect(MobileLocalizedString.resolve("缓存", locale: Locale(identifier: "en")) == "Cache")
        #expect(MobileLocalizedString.resolve("缓存", locale: Locale(identifier: "ja")) == "キャッシュ")
        #expect(MobileLocalizedString.resolve("关于", locale: Locale(identifier: "en")) == "About")
        #expect(MobileLocalizedString.resolve("关于", locale: Locale(identifier: "zh-Hans")) == "关于")
    }

    @Test("unknown language raw value stays follow-system")
    func unknownLanguageIsSystem() {
        let environment = MobileTestDefaults()
        defer { environment.cleanUp() }

        environment.defaults.set(
            "fr",
            forKey: UserDefaultsMobileSettingsStore.interfaceLanguageKey
        )
        #expect(environment.settingsStore.load().interfaceLanguage == .system)
    }
}
