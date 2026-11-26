import Foundation
import Testing
@testable import DaybreakCore

/// Synthetic market checks. No provider response is used here; provider
/// fallback behavior is covered by the synthetic transport tests.
@Suite("Bing market catalog")
struct BingMarketCatalogTests {
    private func date(_ value: String) -> LocalDate {
        guard let date = LocalDate(iso8601: value) else {
            preconditionFailure("Invalid synthetic test date: \(value)")
        }
        return date
    }

    private func utc(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let zone = TimeZone(identifier: "UTC") else {
            preconditionFailure("UTC unavailable")
        }
        formatter.timeZone = zone
        guard let date = formatter.date(from: value) else {
            preconditionFailure("Invalid synthetic UTC instant: \(value)")
        }
        return date
    }

    @Test("catalog is explicit, unique and internally consistent")
    func catalogShape() {
        // The documented Bing Image Search market list is finite. This is not
        // a promise that the daily-wallpaper endpoint serves every entry.
        #expect(BingMarketProfile.catalog.count == 38)

        let tags = BingMarketProfile.catalog.map(\.market.rawValue)
        #expect(Set(tags).count == tags.count)
        for required in [
            "zh-CN", "en-US", "ja-JP", "en-GB", "de-DE",
            "fr-CA", "zh-TW", "es-US", "no-NO", "pt-BR"
        ] {
            #expect(tags.contains(required), "Missing catalog market \(required)")
        }

        for profile in BingMarketProfile.catalog {
            #expect(BingMarketProfile.profile(for: profile.market) == profile)
            #expect(!profile.contentLocaleIdentifier.isEmpty)
            #expect(!profile.languageCode.isEmpty)
            #expect(profile.regionCode.count == 2)
        }

        let grouped = Dictionary(grouping: BingMarketProfile.catalog, by: { $0.languageCode })
        for (language, profiles) in grouped where profiles.count > 1 {
            #expect(
                profiles.filter({ $0.isPrimaryLanguageDefault }).count == 1,
                "Language \(language) needs exactly one declared default market"
            )
        }
    }

    @Test("the original three markets keep their exact zones and content locales")
    func originalMarketsPreserved() throws {
        let zh = try #require(BingMarketProfile.profile(for: Market("zh-CN")))
        #expect(zh == .zhCN)
        #expect(zh.timeZone.identifier == "Asia/Shanghai")
        #expect(zh.contentLocaleIdentifier == "zh-Hans")

        let en = try #require(BingMarketProfile.profile(for: Market("en-US")))
        #expect(en == .enUS)
        #expect(en.timeZone.identifier == "America/Los_Angeles")
        #expect(en.contentLocaleIdentifier == "en-US")

        let ja = try #require(BingMarketProfile.profile(for: Market("ja-JP")))
        #expect(ja == .jaJP)
        #expect(ja.timeZone.identifier == "Asia/Tokyo")
        #expect(ja.contentLocaleIdentifier == "ja-JP")
    }

    @Test("market tags canonicalize without inventing an edition")
    func canonicalization() {
        #expect(BingMarketProfile.profile(for: Market(" EN-us "))?.market.rawValue == "en-US")
        #expect(BingMarketProfile.profile(for: Market("zh_cn"))?.market.rawValue == "zh-CN")
        #expect(BingMarketProfile.profile(for: Market("Zh-Hans-CN"))?.market.rawValue == "zh-CN")
        #expect(BingMarketProfile.profile(for: Market("nb-no"))?.market.rawValue == "no-NO")
        #expect(BingMarketProfile.canonicalMarket(Market("fr-ca")) == Market("fr-CA"))

        #expect(BingMarketProfile.profile(for: Market("pt-PT")) == nil)
        #expect(BingMarketProfile.profile(for: Market("en")) == nil)
        #expect(BingMarketProfile.profile(for: Market("xx-XX")) == nil)
        #expect(BingMarketProfile.profile(for: Market("")) == nil)
        #expect(BingMarketProfile.canonicalMarket(Market("es-419")) == nil)
    }

    @Test("host locale resolves exactly or is disclosed as a fallback")
    func hostLocaleResolution() {
        let exact = BingMarketProfile.resolution(
            regionIdentifier: "de",
            languageIdentifier: "de-DE"
        )
        #expect(exact.profile.market == Market("de-DE"))
        #expect(exact.basis == .languageAndRegion)
        #expect(exact.isExactMatch)
        #expect(exact.requestedLanguageCode == "de")
        #expect(exact.requestedRegionCode == "DE")

        let norway = BingMarketProfile.resolution(
            regionIdentifier: "NO",
            languageIdentifier: "nb-NO"
        )
        #expect(norway.profile.market == Market("no-NO"))
        #expect(norway.basis == .languageAndRegion)

        let embeddedRegion = BingMarketProfile.resolution(
            regionIdentifier: nil,
            languageIdentifier: "fr-CA"
        )
        #expect(embeddedRegion.profile.market == Market("fr-CA"))
        #expect(embeddedRegion.basis == .languageAndRegion)
        #expect(embeddedRegion.requestedRegionCode == "CA")

        let chineseInUS = BingMarketProfile.resolution(
            regionIdentifier: "US",
            languageIdentifier: "zh-Hans-CN"
        )
        #expect(chineseInUS.profile.market == Market("zh-CN"))
        #expect(chineseInUS.basis == .languageDefault)
        #expect(!chineseInUS.isExactMatch)

        let englishInJapan = BingMarketProfile.resolution(
            regionIdentifier: "JP",
            languageIdentifier: "en-US"
        )
        #expect(englishInJapan.profile.market == Market("en-US"))
        #expect(englishInJapan.basis == .languageDefault)

        let portugal = BingMarketProfile.resolution(
            regionIdentifier: "PT",
            languageIdentifier: "pt-PT"
        )
        #expect(portugal.profile.market == Market("pt-BR"))
        #expect(portugal.basis == .languageDefault)
        #expect(portugal.requestedRegionCode == "PT")

        let regionOnly = BingMarketProfile.resolution(
            regionIdentifier: "IT",
            languageIdentifier: nil
        )
        #expect(regionOnly.profile.market == Market("it-IT"))
        #expect(regionOnly.basis == .regionOnly)

        let fallback = BingMarketProfile.resolution(
            regionIdentifier: "ZZ",
            languageIdentifier: "xx"
        )
        #expect(fallback.profile.market == Market("en-US"))
        #expect(fallback.basis == .fallback)
        #expect(!fallback.isExactMatch)

        let empty = BingMarketProfile.resolution(regionIdentifier: nil, languageIdentifier: nil)
        #expect(empty.profile.market == Market("en-US"))
        #expect(empty.basis == .fallback)
    }

    @Test("new markets convert one UTC instant into different source dates")
    func marketDateBoundaries() throws {
        let instant = utc("2026-11-23T23:30:00Z")

        func localDate(_ tag: String) throws -> LocalDate {
            let profile = try #require(BingMarketProfile.profile(for: Market(tag)))
            return try #require(LocalDate(date: instant, timeZone: profile.timeZone))
        }

        let berlin = try localDate("de-DE")
        let shanghai = try localDate("zh-CN")
        let tokyo = try localDate("ja-JP")
        let taipei = try localDate("zh-TW")
        let auckland = try localDate("en-NZ")
        let losAngeles = try localDate("en-US")
        let london = try localDate("en-GB")
        let saoPaulo = try localDate("pt-BR")

        #expect(berlin == date("2026-11-24"))
        #expect(shanghai == date("2026-11-24"))
        #expect(tokyo == date("2026-11-24"))
        #expect(taipei == date("2026-11-24"))
        #expect(auckland == date("2026-11-24"))
        #expect(losAngeles == date("2026-11-23"))
        #expect(london == date("2026-11-23"))
        #expect(saoPaulo == date("2026-11-23"))
    }
}
