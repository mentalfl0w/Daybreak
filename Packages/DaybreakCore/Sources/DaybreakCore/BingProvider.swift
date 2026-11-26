import CryptoKit
import Foundation

// MARK: - Market profile

/// Everything needed to interpret one Bing market without consulting the
/// device time zone.
///
/// `market` is sent verbatim as the provider's `mkt` parameter.
///
/// `timeZone` is an application convention used only to turn Bing's UTC
/// publisher instant into a source-local date. Bing does not publish or
/// confirm a time zone per market, so this value must never be presented as
/// provider-confirmed. It is a representative IANA zone for the market's
/// primary region; DST transitions come from the IANA database.
///
/// `contentLocaleIdentifier` is the locale the request asks for. It becomes
/// provenance only where the response itself carries matching market
/// evidence; archive responses carry no per-entry locale evidence.
public struct BingMarketProfile: Hashable, Sendable {
    public let market: Market
    public let timeZone: TimeZone
    public let contentLocaleIdentifier: String
    /// One market per language is the declared default when the host has that
    /// language but no exact language-region market. It never asserts that the
    /// provider returned distinct content for that region.
    public let isPrimaryLanguageDefault: Bool

    public init(
        market: Market,
        timeZone: TimeZone,
        contentLocaleIdentifier: String,
        isPrimaryLanguageDefault: Bool = false
    ) {
        self.market = market
        self.timeZone = timeZone
        self.contentLocaleIdentifier = contentLocaleIdentifier
        self.isPrimaryLanguageDefault = isPrimaryLanguageDefault
    }

    public static let zhCN = BingMarketProfile(
        market: .zhCN,
        timeZone: TimeZone(identifier: "Asia/Shanghai")!,
        contentLocaleIdentifier: "zh-Hans",
        isPrimaryLanguageDefault: true
    )

    public static let enUS = BingMarketProfile(
        market: .enUS,
        timeZone: TimeZone(identifier: "America/Los_Angeles")!,
        contentLocaleIdentifier: "en-US",
        isPrimaryLanguageDefault: true
    )

    public static let jaJP = BingMarketProfile(
        market: .jaJP,
        timeZone: TimeZone(identifier: "Asia/Tokyo")!,
        contentLocaleIdentifier: "ja-JP"
    )

    /// Explicit catalog of the market codes published for the Bing Image
    /// Search `mkt` parameter.
    ///
    /// The public list is documentation, not a guarantee for the undocumented
    /// daily-wallpaper endpoint. Bing may fall back to another market's
    /// content; the provider therefore refuses story records whose response
    /// market evidence does not match the requested market. Not every country
    /// or language has a distinct edition, so the catalog is enumerated
    /// rather than derived from a region code.
    public static let catalog: [BingMarketProfile] = [
        make("es-AR", zone: "America/Argentina/Buenos_Aires"),
        make("en-AU", zone: "Australia/Sydney"),
        make("de-AT", zone: "Europe/Vienna"),
        make("nl-BE", zone: "Europe/Brussels"),
        make("fr-BE", zone: "Europe/Brussels"),
        make("pt-BR", zone: "America/Sao_Paulo"),
        make("en-CA", zone: "America/Toronto"),
        make("fr-CA", zone: "America/Toronto"),
        make("es-CL", zone: "America/Santiago"),
        make("da-DK", zone: "Europe/Copenhagen"),
        make("fi-FI", zone: "Europe/Helsinki"),
        make("fr-FR", zone: "Europe/Paris", primary: true),
        make("de-DE", zone: "Europe/Berlin", primary: true),
        make("zh-HK", zone: "Asia/Hong_Kong"),
        make("en-IN", zone: "Asia/Kolkata"),
        make("en-ID", zone: "Asia/Jakarta"),
        make("it-IT", zone: "Europe/Rome"),
        make("ja-JP", zone: "Asia/Tokyo"),
        make("ko-KR", zone: "Asia/Seoul"),
        make("en-MY", zone: "Asia/Kuala_Lumpur"),
        make("es-MX", zone: "America/Mexico_City"),
        make("nl-NL", zone: "Europe/Amsterdam", primary: true),
        make("en-NZ", zone: "Pacific/Auckland"),
        make("no-NO", zone: "Europe/Oslo"),
        make("zh-CN", zone: "Asia/Shanghai", locale: "zh-Hans", primary: true),
        make("pl-PL", zone: "Europe/Warsaw"),
        make("en-PH", zone: "Asia/Manila"),
        make("ru-RU", zone: "Europe/Moscow"),
        make("en-ZA", zone: "Africa/Johannesburg"),
        make("es-ES", zone: "Europe/Madrid", primary: true),
        make("sv-SE", zone: "Europe/Stockholm"),
        make("fr-CH", zone: "Europe/Zurich"),
        make("de-CH", zone: "Europe/Zurich"),
        make("zh-TW", zone: "Asia/Taipei"),
        make("tr-TR", zone: "Europe/Istanbul"),
        make("en-GB", zone: "Europe/London"),
        make("en-US", zone: "America/Los_Angeles", primary: true),
        make("es-US", zone: "America/Los_Angeles")
    ]

    /// Catalog profile for a provider market tag. The lookup accepts common
    /// casing and separator variants, canonicalizes them, and returns `nil`
    /// for tags outside the catalog instead of guessing an edition.
    public static func profile(for market: Market) -> BingMarketProfile? {
        guard let tag = canonicalMarketTag(market.rawValue) else { return nil }
        return profilesByCanonicalTag[tag]
    }

    /// Canonical catalog tag for a user- or provider-supplied value, or `nil`
    /// when the value is not one of the enumerated markets.
    public static func canonicalMarket(_ market: Market) -> Market? {
        canonicalMarketTag(market.rawValue).map { Market($0) }
    }

    /// The language subtag declared by the market tag, lowercased.
    public var languageCode: String {
        market.rawValue.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
    }

    /// The two-letter region subtag declared by the market tag, uppercased.
    /// Empty when the tag has no region subtag.
    public var regionCode: String {
        guard let last = market.rawValue.split(separator: "-").last,
              last.count == 2,
              last.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return ""
        }
        return last.uppercased()
    }

    /// Deterministic host-locale resolution for the "follow system" default.
    ///
    /// Order: exact language + region, then the language's declared market,
    /// then a region's only market, then `en-US` as an explicitly labelled
    /// fallback. A fallback resolution never claims the host locale matched.
    public static func resolution(
        regionIdentifier: String?,
        languageIdentifier: String?
    ) -> BingMarketResolution {
        let language = normalizedLanguageCode(languageIdentifier)
        var region = normalizedRegionCode(regionIdentifier)
        if region == nil, let languageIdentifier {
            region = regionComponent(of: languageIdentifier)
        }

        if let language, let region {
            let mapped = catalogLanguageCode(language)
            let exact = catalog.filter {
                $0.languageCode == mapped && $0.regionCode == region
            }
            if exact.count == 1, let profile = exact.first {
                return BingMarketResolution(
                    profile: profile,
                    basis: .languageAndRegion,
                    requestedLanguageCode: language,
                    requestedRegionCode: region
                )
            }
        }

        if let language {
            let mapped = catalogLanguageCode(language)
            let candidates = catalog.filter { $0.languageCode == mapped }
            if candidates.count == 1, let profile = candidates.first {
                return BingMarketResolution(
                    profile: profile,
                    basis: .languageDefault,
                    requestedLanguageCode: language,
                    requestedRegionCode: region
                )
            }
            if let profile = candidates.first(where: { $0.isPrimaryLanguageDefault }) {
                return BingMarketResolution(
                    profile: profile,
                    basis: .languageDefault,
                    requestedLanguageCode: language,
                    requestedRegionCode: region
                )
            }
        }

        if let region {
            let candidates = catalog.filter { $0.regionCode == region }
            if candidates.count == 1, let profile = candidates.first {
                return BingMarketResolution(
                    profile: profile,
                    basis: .regionOnly,
                    requestedLanguageCode: language,
                    requestedRegionCode: region
                )
            }
        }

        guard let fallback = profilesByCanonicalTag["en-US"] else {
            preconditionFailure("Bing market catalog must contain en-US")
        }
        return BingMarketResolution(
            profile: fallback,
            basis: .fallback,
            requestedLanguageCode: language,
            requestedRegionCode: region
        )
    }

    // MARK: Catalog internals

    private static func make(
        _ market: String,
        zone: String,
        locale: String? = nil,
        primary: Bool = false
    ) -> BingMarketProfile {
        guard let timeZone = TimeZone(identifier: zone) else {
            preconditionFailure("Unknown IANA time zone in the Bing market catalog: \(zone)")
        }
        return BingMarketProfile(
            market: Market(market),
            timeZone: timeZone,
            contentLocaleIdentifier: locale ?? market,
            isPrimaryLanguageDefault: primary
        )
    }

    private static let profilesByCanonicalTag: [String: BingMarketProfile] = {
        var result: [String: BingMarketProfile] = [:]
        result.reserveCapacity(catalog.count)
        for profile in catalog {
            result[profile.market.rawValue] = profile
        }
        return result
    }()

    /// Script-qualified or platform-spelled forms that resolve to one
    /// catalog entry. Anything else is rejected.
    private static let canonicalAliases: [String: String] = [
        "nb-NO": "no-NO",
        "zh-Hans-CN": "zh-CN",
        "zh-Hant-HK": "zh-HK",
        "zh-Hant-TW": "zh-TW"
    ]

    private static func canonicalMarketTag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard (2...3).contains(components.count) else { return nil }

        let language = components[0].lowercased()
        guard (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return nil
        }

        let script: String?
        let regionComponent: Substring
        if components.count == 3 {
            let rawScript = components[1]
            guard rawScript.count == 4,
                  rawScript.allSatisfy({ $0.isASCII && $0.isLetter })
            else {
                return nil
            }
            script = rawScript.prefix(1).uppercased() + rawScript.dropFirst().lowercased()
            regionComponent = components[2]
        } else {
            script = nil
            regionComponent = components[1]
        }

        guard regionComponent.count == 2,
              regionComponent.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return nil
        }

        var parts = [language]
        if let script { parts.append(script) }
        parts.append(regionComponent.uppercased())
        let canonical = parts.joined(separator: "-")

        if let alias = canonicalAliases[canonical] {
            return alias
        }
        guard profilesByCanonicalTag[canonical] != nil else { return nil }
        return canonical
    }

    private static func normalizedLanguageCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let primary = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map({ String($0).lowercased() })
        else {
            return nil
        }
        guard (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return nil
        }
        return primary
    }

    private static func normalizedRegionCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 2,
              trimmed.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return nil
        }
        return trimmed.uppercased()
    }

    private static func regionComponent(of languageTag: String) -> String? {
        let components = languageTag.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard components.count >= 2 else { return nil }
        return normalizedRegionCode(String(components[components.count - 1]))
    }

    private static func catalogLanguageCode(_ normalized: String) -> String {
        switch normalized {
        case "nb", "nn": return "no"
        default: return normalized
        }
    }
}

/// Outcome of mapping the host region and preferred language onto the market
/// catalog. `basis` records why a market was chosen so callers can disclose a
/// fallback instead of pretending the host locale was matched.
public struct BingMarketResolution: Hashable, Sendable {
    public enum Basis: String, Hashable, Sendable {
        case languageAndRegion
        case languageDefault
        case regionOnly
        case fallback
    }

    public let profile: BingMarketProfile
    public let basis: Basis
    public let requestedLanguageCode: String?
    public let requestedRegionCode: String?

    public init(
        profile: BingMarketProfile,
        basis: Basis,
        requestedLanguageCode: String?,
        requestedRegionCode: String?
    ) {
        self.profile = profile
        self.basis = basis
        self.requestedLanguageCode = requestedLanguageCode
        self.requestedRegionCode = requestedRegionCode
    }

    public var isExactMatch: Bool { basis == .languageAndRegion }
}

// MARK: - Configuration

public struct BingProviderConfiguration: Hashable, Sendable {
    /// Per-URLSession request timeout in seconds.
    public var requestTimeout: TimeInterval
    /// Hard response bounds applied before JSON/image decoding.
    public var maximumMetadataBytes: Int
    public var maximumStoryBytes: Int
    public var maximumImageBytes: Int
    /// Total attempts per HTTP request, including the first attempt.
    public var maximumAttempts: Int
    public var initialRetryDelay: Duration
    public var maximumRetryDelay: Duration
    /// `n` sent to HPImageArchive (Bing accepts at most 8).
    public var archiveCount: Int
    public var maximumArchiveEntries: Int
    public var maximumStoryEntries: Int
    public var maximumImageCandidates: Int
    public var maximumImageDimension: Int
    public var maximumImagePixelCount: Int
    /// Guards against a parser regression producing years such as `0022`.
    public var earliestPlausibleYear: Int
    public var latestPlausibleYear: Int
    public var userAgent: String
    public var apiHosts: Set<String>
    public var mediaHosts: Set<String>
    public var navigationHosts: Set<String>

    public init(
        requestTimeout: TimeInterval = 25,
        maximumMetadataBytes: Int = 1_048_576,
        maximumStoryBytes: Int = 4_194_304,
        maximumImageBytes: Int = 24_000_000,
        maximumAttempts: Int = 3,
        initialRetryDelay: Duration = .milliseconds(400),
        maximumRetryDelay: Duration = .seconds(4),
        archiveCount: Int = 8,
        maximumArchiveEntries: Int = 8,
        maximumStoryEntries: Int = 32,
        maximumImageCandidates: Int = 6,
        maximumImageDimension: Int = 12_000,
        maximumImagePixelCount: Int = 80_000_000,
        earliestPlausibleYear: Int = 2009,
        latestPlausibleYear: Int = 2100,
        userAgent: String = "Daybreak/0.1 (macOS; Apple public APIs)",
        apiHosts: Set<String> = ["www.bing.com", "bing.com"],
        mediaHosts: Set<String> = ["www.bing.com", "bing.com", "th.bing.com"],
        navigationHosts: Set<String> = ["www.bing.com", "bing.com", "cn.bing.com"]
    ) {
        self.requestTimeout = requestTimeout
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumStoryBytes = maximumStoryBytes
        self.maximumImageBytes = maximumImageBytes
        self.maximumAttempts = maximumAttempts
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
        self.archiveCount = archiveCount
        self.maximumArchiveEntries = maximumArchiveEntries
        self.maximumStoryEntries = maximumStoryEntries
        self.maximumImageCandidates = maximumImageCandidates
        self.maximumImageDimension = maximumImageDimension
        self.maximumImagePixelCount = maximumImagePixelCount
        self.earliestPlausibleYear = earliestPlausibleYear
        self.latestPlausibleYear = latestPlausibleYear
        self.userAgent = userAgent
        self.apiHosts = apiHosts
        self.mediaHosts = mediaHosts
        self.navigationHosts = navigationHosts
    }

    public static let `default` = BingProviderConfiguration()

    func normalized() -> BingProviderConfiguration {
        var copy = self
        copy.requestTimeout = min(max(5, copy.requestTimeout), 120)
        copy.maximumMetadataBytes = min(max(65_536, copy.maximumMetadataBytes), 16_777_216)
        copy.maximumStoryBytes = min(max(65_536, copy.maximumStoryBytes), 16_777_216)
        copy.maximumImageBytes = min(max(1_048_576, copy.maximumImageBytes), 64_000_000)
        copy.maximumAttempts = min(max(1, copy.maximumAttempts), 6)
        copy.initialRetryDelay = Self.nonNegative(copy.initialRetryDelay)
        copy.maximumRetryDelay = Self.nonNegative(copy.maximumRetryDelay)
        if copy.maximumRetryDelay < copy.initialRetryDelay {
            copy.maximumRetryDelay = copy.initialRetryDelay
        }
        copy.archiveCount = min(max(1, copy.archiveCount), 8)
        copy.maximumArchiveEntries = min(max(1, copy.maximumArchiveEntries), 8)
        copy.maximumStoryEntries = min(max(1, copy.maximumStoryEntries), 64)
        copy.maximumImageCandidates = min(max(1, copy.maximumImageCandidates), 8)
        copy.maximumImageDimension = min(max(512, copy.maximumImageDimension), 20_000)
        copy.maximumImagePixelCount = min(max(1_000_000, copy.maximumImagePixelCount), 200_000_000)
        copy.earliestPlausibleYear = min(max(1900, copy.earliestPlausibleYear), 2999)
        copy.latestPlausibleYear = min(max(copy.earliestPlausibleYear + 1, copy.latestPlausibleYear), 3000)
        copy.apiHosts = Self.normalizedHosts(copy.apiHosts)
        copy.mediaHosts = Self.normalizedHosts(copy.mediaHosts)
        copy.navigationHosts = Self.normalizedHosts(copy.navigationHosts)
        return copy
    }

    private static func normalizedHosts(_ hosts: Set<String>) -> Set<String> {
        Set(hosts.compactMap { host -> String? in
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    private static func nonNegative(_ duration: Duration) -> Duration {
        duration < .zero ? .zero : duration
    }

    static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = min(max(Int64(0), components.seconds), 3_600)
        let attoseconds = min(max(Int64(0), components.attoseconds), 999_999_999_999_999_999)
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}


// MARK: - Provider-owned output

public enum BingIdentityEvidence: String, Hashable, Sendable, Codable {
    case imageURLSlug
    case providerHash
}

public enum BingImageVariantKind: String, Hashable, Sendable, Codable, CaseIterable {
    case ultraHighResolution
    case provided
    case fullHD
    case compact

    var preferredPixels: (width: Int?, height: Int?) {
        switch self {
        case .ultraHighResolution: return (3_840, 2_160)
        case .provided: return (nil, nil)
        case .fullHD: return (1_920, 1_080)
        case .compact: return (1_366, 768)
        }
    }
}

public struct BingImageCandidate: Hashable, Sendable, Codable {
    public let url: URL
    public let kind: BingImageVariantKind
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        url: URL,
        kind: BingImageVariantKind,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.url = url
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum BingImagePreference: String, Hashable, Sendable, Codable, CaseIterable {
    case highResolution
    case fullHD
    case compact
}

public struct BingDiagnostic: Hashable, Sendable, Codable {
    public enum Code: String, Hashable, Sendable, Codable {
        case invalidDate
        case implausibleDate
        case missingField
        case blockedURL
        case invalidImageURL
        case invalidSourceURL
        case missingImageIdentity
        case identityConflict
        case responseMarketMissing
        case responseMarketMismatch
        case imageMarketMarkerMismatch
        case emptyStoryContent
        case ignoredPreloadEntries
        case truncatedEntries
        case duplicateOccurrence
        case recordRejected
        case htmlInStoryText
    }

    public let code: Code
    public let field: String?
    public let detail: String?

    public init(code: Code, field: String? = nil, detail: String? = nil) {
        self.code = code
        self.field = field
        self.detail = detail
    }
}

public enum BingImageFailureReason: String, Hashable, Sendable, Codable {
    case httpStatus
    case blockedURL
    case responseTooLarge
    case unexpectedContentType
    case imageMimeRejected
    case imageDecodeFailed
    case imageDimensionsRejected
    case transport
}

public struct BingImageAttemptFailure: Hashable, Sendable {
    public let kind: BingImageVariantKind
    public let host: String?
    public let reason: BingImageFailureReason
    public let httpStatusCode: Int?

    public init(
        kind: BingImageVariantKind,
        host: String?,
        reason: BingImageFailureReason,
        httpStatusCode: Int? = nil
    ) {
        self.kind = kind
        self.host = host
        self.reason = reason
        self.httpStatusCode = httpStatusCode
    }
}

public enum BingProviderError: Error, Hashable, Sendable {
    case invalidConfiguration(String)
    case blockedURL(host: String?)
    case unexpectedRedirect(statusCode: Int, locationHost: String?)
    case responseTooLarge(limit: Int)
    case unexpectedContentType(String?)
    case httpStatus(code: Int, retryAfterSeconds: Double?)
    case malformedJSON(String)
    case malformedResponse(String)
    case noUsableEntries(diagnostics: [BingDiagnostic])
    case transport(code: Int?)
    case noImageCandidates(wallpaperID: WallpaperID)
    case allImageCandidatesFailed(wallpaperID: WallpaperID, failures: [BingImageAttemptFailure])
    case imageMimeRejected(declared: String?, detected: String?)
    case imageDecodeFailed
    case imageDimensionsRejected(width: Int, height: Int)
}

public struct BingArchiveEntry: Hashable, Sendable {
    public let occurrence: WallpaperOccurrence
    public let metadata: WallpaperMetadataRecord
    public let sourceStartDate: LocalDate?
    public let sourceEndDate: LocalDate?
    public let identityEvidence: BingIdentityEvidence
    public let imageCandidates: [BingImageCandidate]

    public init(
        occurrence: WallpaperOccurrence,
        metadata: WallpaperMetadataRecord,
        sourceStartDate: LocalDate? = nil,
        sourceEndDate: LocalDate? = nil,
        identityEvidence: BingIdentityEvidence,
        imageCandidates: [BingImageCandidate]
    ) {
        self.occurrence = occurrence
        self.metadata = metadata
        self.sourceStartDate = sourceStartDate
        self.sourceEndDate = sourceEndDate
        self.identityEvidence = identityEvidence
        self.imageCandidates = imageCandidates
    }

    /// Content-level grouping. Per-market/date copy remains authoritative in
    /// `metadata`.
    public var wallpaper: WallpaperRecord {
        WallpaperRecord(
            source: metadata.key.source,
            wallpaperID: metadata.wallpaperID,
            canonicalTitle: metadata.title,
            copyright: metadata.copyright,
            sourceURL: metadata.sourceURL,
            fetchedAt: metadata.fetchedAt,
            variants: metadata.variants
        )
    }
}

public struct BingArchiveSnapshot: Sendable {
    public let market: Market
    public let endpoint: URL
    public let fetchedAt: Date
    public let entries: [BingArchiveEntry]
    public let diagnostics: [BingDiagnostic]

    public init(
        market: Market,
        endpoint: URL,
        fetchedAt: Date,
        entries: [BingArchiveEntry],
        diagnostics: [BingDiagnostic]
    ) {
        self.market = market
        self.endpoint = endpoint
        self.fetchedAt = fetchedAt
        self.entries = entries
        self.diagnostics = diagnostics
    }

    public var occurrences: [WallpaperOccurrence] { entries.map(\.occurrence) }
    public var metadataRecords: [WallpaperMetadataRecord] { entries.map(\.metadata) }

    public var wallpapers: [WallpaperRecord] {
        var seen: [WallpaperID: WallpaperRecord] = [:]
        for entry in entries {
            if let existing = seen[entry.metadata.wallpaperID] {
                if existing.canonicalTitle == nil, let title = entry.metadata.title {
                    seen[entry.metadata.wallpaperID] = WallpaperRecord(
                        source: existing.source,
                        wallpaperID: existing.wallpaperID,
                        canonicalTitle: title,
                        copyright: existing.copyright ?? entry.metadata.copyright,
                        sourceURL: existing.sourceURL ?? entry.metadata.sourceURL,
                        fetchedAt: existing.fetchedAt,
                        variants: existing.variants
                    )
                }
            } else {
                seen[entry.metadata.wallpaperID] = entry.wallpaper
            }
        }
        return seen.values.sorted { $0.wallpaperID < $1.wallpaperID }
    }
}

public struct BingStorySnapshot: Sendable {
    public let market: Market
    public let endpoint: URL
    public let fetchedAt: Date
    public let records: [DailyStoryRecord]
    public let diagnostics: [BingDiagnostic]
    public let ignoredPreloadCount: Int
    /// Values actually observed in `MediaContents[].Market`, for provenance
    /// and tests. Records are only emitted after the requested-market check.
    public let responseMarkets: [String]

    public init(
        market: Market,
        endpoint: URL,
        fetchedAt: Date,
        records: [DailyStoryRecord],
        diagnostics: [BingDiagnostic],
        ignoredPreloadCount: Int = 0,
        responseMarkets: [String] = []
    ) {
        self.market = market
        self.endpoint = endpoint
        self.fetchedAt = fetchedAt
        self.records = records
        self.diagnostics = diagnostics
        self.ignoredPreloadCount = ignoredPreloadCount
        self.responseMarkets = responseMarkets
    }
}

public struct BingImageAsset: Hashable, Sendable {
    public let wallpaperID: WallpaperID
    public let data: Data
    public let mimeType: String
    public let uti: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Final URL after safe redirects.
    public let sourceURL: URL
    public let requestedURL: URL
    public let resolvedKind: BingImageVariantKind
    public let sha256: String
    public let fetchedAt: Date

    public init(
        wallpaperID: WallpaperID,
        data: Data,
        mimeType: String,
        uti: String,
        pixelWidth: Int,
        pixelHeight: Int,
        sourceURL: URL,
        requestedURL: URL,
        resolvedKind: BingImageVariantKind,
        sha256: String,
        fetchedAt: Date
    ) {
        self.wallpaperID = wallpaperID
        self.data = data
        self.mimeType = mimeType
        self.uti = uti
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceURL = sourceURL
        self.requestedURL = requestedURL
        self.resolvedKind = resolvedKind
        self.sha256 = sha256
        self.fetchedAt = fetchedAt
    }
}

public enum BingComponentResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(BingProviderError)

    public var value: Value? {
        if case .success(let value) = self { return value }
        return nil
    }

    public var error: BingProviderError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

public struct BingJoinedDay: Hashable, Sendable {
    public let archiveEntry: BingArchiveEntry
    /// `nil` means the story component failed; it is not evidence that no
    /// story was published for that date.
    public let storyMatch: StoryMatch?

    public init(archiveEntry: BingArchiveEntry, storyMatch: StoryMatch?) {
        self.archiveEntry = archiveEntry
        self.storyMatch = storyMatch
    }

    public var occurrence: WallpaperOccurrence { archiveEntry.occurrence }
}

public struct BingDailySnapshot: Sendable {
    public let market: Market
    public let fetchedAt: Date
    public let archive: BingComponentResult<BingArchiveSnapshot>
    public let stories: BingComponentResult<BingStorySnapshot>
    public let joined: [BingJoinedDay]
    public let diagnostics: [BingDiagnostic]

    public init(
        market: Market,
        fetchedAt: Date,
        archive: BingComponentResult<BingArchiveSnapshot>,
        stories: BingComponentResult<BingStorySnapshot>,
        joined: [BingJoinedDay],
        diagnostics: [BingDiagnostic]
    ) {
        self.market = market
        self.fetchedAt = fetchedAt
        self.archive = archive
        self.stories = stories
        self.joined = joined
        self.diagnostics = diagnostics
    }

    public var isCompleteSuccess: Bool {
        guard case .success = archive else { return false }
        if case .success = stories { return true }
        return false
    }

    public var isPartialSuccess: Bool {
        switch (archive, stories) {
        case (.success, .failure), (.failure, .success): return true
        default: return false
        }
    }
}

// MARK: - Provider

public actor BingProvider {
    public nonisolated let profile: BingMarketProfile
    public nonisolated let configuration: BingProviderConfiguration

    private let requestExecutor: BingRequestExecutor
    private let now: @Sendable () -> Date

    public init(
        profile: BingMarketProfile,
        configuration: BingProviderConfiguration = .default,
        transport: (any BingHTTPTransport)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping BingSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let normalized = configuration.normalized()
        self.profile = profile
        self.configuration = normalized
        let knownHosts = normalized.apiHosts
            .union(normalized.mediaHosts)
            .union(normalized.navigationHosts)
        let selectedTransport: any BingHTTPTransport
        if let transport {
            selectedTransport = transport
        } else {
            selectedTransport = URLSessionBingTransport(
                redirectPolicy: BingRedirectPolicy(allowedHosts: knownHosts)
            )
        }
        self.requestExecutor = BingRequestExecutor(
            transport: selectedTransport,
            configuration: normalized,
            sleep: sleep
        )
        self.now = now
    }

    // MARK: Metadata

    /// Fetches HPImageArchive only. Stories are never inferred from the
    /// archive title or copyright.
    public func fetchArchive() async throws -> BingArchiveSnapshot {
        let profile = try validatedProfile()
        let fetchedAt = now()
        let request = try makeArchiveRequest(profile: profile)
        let response = try await requestExecutor.perform(request, policy: apiPolicy)

        guard BingContentType.isJSON(response.header("Content-Type")) else {
            throw BingProviderError.unexpectedContentType(response.header("Content-Type"))
        }
        guard !response.data.isEmpty else {
            throw BingProviderError.malformedResponse("archive body is empty")
        }

        let payload: ArchivePayload
        do {
            payload = try JSONDecoder().decode(ArchivePayload.self, from: response.data)
        } catch {
            throw BingProviderError.malformedJSON(BingDecoding.description(error))
        }
        guard let images = payload.images else {
            throw BingProviderError.malformedResponse("archive response has no images array")
        }

        var diagnostics: [BingDiagnostic] = []
        if images.count > configuration.maximumArchiveEntries {
            diagnostics.append(BingDiagnostic(
                code: .truncatedEntries,
                field: "images",
                detail: "\(images.count) entries; used \(configuration.maximumArchiveEntries)"
            ))
        }

        var entries: [BingArchiveEntry] = []
        var occurrenceCounts: [OccurrenceKey: Int] = [:]
        for (index, raw) in images.prefix(configuration.maximumArchiveEntries).enumerated() {
            do {
                let entry = try makeArchiveEntry(
                    raw,
                    index: index,
                    profile: profile,
                    fetchedAt: fetchedAt,
                    diagnostics: &diagnostics
                )
                var occurrence = entry.occurrence
                let priorCount = occurrenceCounts[occurrence.id, default: 0]
                if priorCount > 0 {
                    diagnostics.append(BingDiagnostic(
                        code: .duplicateOccurrence,
                        field: "images[\(index)]",
                        detail: "repeated market/date; revision \(priorCount)"
                    ))
                    occurrence = WallpaperOccurrence(
                        source: occurrence.source,
                        market: occurrence.market,
                        localDate: occurrence.localDate,
                        wallpaperID: occurrence.wallpaperID,
                        publisherTime: occurrence.publisherTime,
                        revision: priorCount
                    )
                }
                occurrenceCounts[occurrence.id] = priorCount + 1
                entries.append(BingArchiveEntry(
                    occurrence: occurrence,
                    metadata: entry.metadata,
                    sourceStartDate: entry.sourceStartDate,
                    sourceEndDate: entry.sourceEndDate,
                    identityEvidence: entry.identityEvidence,
                    imageCandidates: entry.imageCandidates
                ))
            } catch let error as BingProviderError {
                diagnostics.append(BingDiagnostic(
                    code: .recordRejected,
                    field: "images[\(index)]",
                    detail: BingDecoding.safeDescription(error)
                ))
            }
        }

        guard !entries.isEmpty else {
            throw BingProviderError.noUsableEntries(diagnostics: diagnostics)
        }
        return BingArchiveSnapshot(
            market: profile.market,
            endpoint: request.url,
            fetchedAt: fetchedAt,
            entries: entries,
            diagnostics: diagnostics
        )
    }

    // MARK: Stories

    /// Fetches the homepage model only. A valid empty result is returned as an
    /// empty snapshot; transport/schema failures throw so the caller can store
    /// an explicit unavailable reason instead of inventing text.
    public func fetchStories() async throws -> BingStorySnapshot {
        let profile = try validatedProfile()
        let fetchedAt = now()
        let request = try makeStoryRequest(profile: profile)
        let response = try await requestExecutor.perform(request, policy: apiPolicy)

        guard BingContentType.isJSON(response.header("Content-Type")) else {
            throw BingProviderError.unexpectedContentType(response.header("Content-Type"))
        }
        guard !response.data.isEmpty else {
            throw BingProviderError.malformedResponse("homepage model body is empty")
        }

        let payload: HomepagePayload
        do {
            payload = try JSONDecoder().decode(HomepagePayload.self, from: response.data)
        } catch {
            throw BingProviderError.malformedJSON(BingDecoding.description(error))
        }
        guard let mediaContents = payload.mediaContents else {
            throw BingProviderError.malformedResponse("homepage model has no MediaContents array")
        }

        var diagnostics: [BingDiagnostic] = []
        let preloadCount = payload.preloadMediaContents?.count ?? 0
        if preloadCount > 0 {
            diagnostics.append(BingDiagnostic(
                code: .ignoredPreloadEntries,
                detail: "\(preloadCount) future/preload entries ignored"
            ))
        }
        if mediaContents.count > configuration.maximumStoryEntries {
            diagnostics.append(BingDiagnostic(
                code: .truncatedEntries,
                field: "MediaContents",
                detail: "\(mediaContents.count) entries; used \(configuration.maximumStoryEntries)"
            ))
        }

        var records: [DailyStoryRecord] = []
        var responseMarkets: Set<String> = []
        for (index, raw) in mediaContents.prefix(configuration.maximumStoryEntries).enumerated() {
            if let observed = raw.market?.trimmingCharacters(in: .whitespacesAndNewlines),
               !observed.isEmpty {
                responseMarkets.insert(observed)
            }
            do {
                if let record = try makeStoryRecord(
                    raw,
                    index: index,
                    profile: profile,
                    fetchedAt: fetchedAt,
                    diagnostics: &diagnostics
                ) {
                    records.append(record)
                }
            } catch let error as BingProviderError {
                diagnostics.append(BingDiagnostic(
                    code: .recordRejected,
                    field: "MediaContents[\(index)]",
                    detail: BingDecoding.safeDescription(error)
                ))
            }
        }

        return BingStorySnapshot(
            market: profile.market,
            endpoint: request.url,
            fetchedAt: fetchedAt,
            records: records,
            diagnostics: diagnostics,
            ignoredPreloadCount: preloadCount,
            responseMarkets: responseMarkets.sorted()
        )
    }

    // MARK: Independent combination

    /// Fetches both components independently. One failing component never
    /// erases the other, and cancellation is always propagated.
    public func fetchDailySnapshot() async throws -> BingDailySnapshot {
        let fetchedAt = now()

        let archiveResult: BingComponentResult<BingArchiveSnapshot>
        do {
            archiveResult = .success(try await fetchArchive())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BingProviderError {
            archiveResult = .failure(error)
        } catch {
            archiveResult = .failure(BingRequestExecutor.providerError(from: error))
        }

        try Task.checkCancellation()

        let storyResult: BingComponentResult<BingStorySnapshot>
        do {
            storyResult = .success(try await fetchStories())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BingProviderError {
            storyResult = .failure(error)
        } catch {
            storyResult = .failure(BingRequestExecutor.providerError(from: error))
        }

        try Task.checkCancellation()

        var diagnostics: [BingDiagnostic] = []
        if let archive = archiveResult.value {
            diagnostics.append(contentsOf: archive.diagnostics)
        }
        if let stories = storyResult.value {
            diagnostics.append(contentsOf: stories.diagnostics)
        }

        var joined: [BingJoinedDay] = []
        if let archive = archiveResult.value {
            let storyRecords = storyResult.value?.records
            for entry in archive.entries {
                let match = storyRecords.map {
                    StoryMatcher.match(
                        occurrence: entry.occurrence,
                        metadata: entry.metadata,
                        stories: $0
                    )
                }
                joined.append(BingJoinedDay(archiveEntry: entry, storyMatch: match))
            }
        }

        return BingDailySnapshot(
            market: profile.market,
            fetchedAt: fetchedAt,
            archive: archiveResult,
            stories: storyResult,
            joined: joined,
            diagnostics: diagnostics
        )
    }

    // MARK: Images

    public func fetchImage(
        for entry: BingArchiveEntry,
        preference: BingImagePreference = .highResolution
    ) async throws -> BingImageAsset {
        try await fetchImage(
            wallpaperID: entry.metadata.wallpaperID,
            candidates: entry.imageCandidates,
            preference: preference
        )
    }

    /// Fetches from descriptors previously persisted by the repository. URLs
    /// are re-validated; descriptors are not trusted merely because they were
    /// stored locally.
    public func fetchImage(
        for metadata: WallpaperMetadataRecord,
        preference: BingImagePreference = .highResolution
    ) async throws -> BingImageAsset {
        let candidates = metadata.variants.compactMap { descriptor -> BingImageCandidate? in
            let kind = Self.candidateKind(
                width: descriptor.pixelWidth,
                height: descriptor.pixelHeight,
                url: descriptor.remoteURL
            )
            return BingImageCandidate(
                url: descriptor.remoteURL,
                kind: kind,
                pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight
            )
        }
        guard !candidates.isEmpty else {
            throw BingProviderError.noImageCandidates(wallpaperID: metadata.wallpaperID)
        }
        return try await fetchImage(
            wallpaperID: metadata.wallpaperID,
            candidates: candidates,
            preference: preference
        )
    }

    /// Tries ordered candidates. 404/415/decode/size failures fall back to the
    /// next resolution; rate limits, exhausted 5xx and transport failures stop
    /// the attempt chain instead of hammering the same host.
    public func fetchImage(
        wallpaperID: WallpaperID,
        candidates: [BingImageCandidate],
        preference: BingImagePreference = .highResolution
    ) async throws -> BingImageAsset {
        guard wallpaperID.isValid else {
            throw BingProviderError.invalidConfiguration("wallpaperID is empty")
        }
        guard !candidates.isEmpty else {
            throw BingProviderError.noImageCandidates(wallpaperID: wallpaperID)
        }

        let ordered = Self.orderedCandidates(candidates, preference: preference)
        var failures: [BingImageAttemptFailure] = []
        var seen: Set<String> = []

        for candidate in ordered {
            try Task.checkCancellation()
            guard seen.insert(candidate.url.absoluteString).inserted else { continue }
            guard mediaPolicy.allows(candidate.url) else {
                failures.append(BingImageAttemptFailure(
                    kind: candidate.kind,
                    host: candidate.url.host,
                    reason: .blockedURL
                ))
                continue
            }

            let request = BingHTTPRequest(
                url: candidate.url,
                headers: makeHeaders(profile: profile, accept: Self.imageAcceptHeader),
                timeout: configuration.requestTimeout,
                maximumBytes: configuration.maximumImageBytes
            )

            do {
                let response = try await requestExecutor.perform(request, policy: mediaPolicy)
                guard BingContentType.canonicalImageMime(response.header("Content-Type")) != nil else {
                    failures.append(BingImageAttemptFailure(
                        kind: candidate.kind,
                        host: candidate.url.host,
                        reason: .unexpectedContentType
                    ))
                    continue
                }

                let validated: BingValidatedImage
                do {
                    validated = try BingImageValidator.validate(
                        data: response.data,
                        declaredContentType: response.header("Content-Type"),
                        maximumDimension: configuration.maximumImageDimension,
                        maximumPixelCount: configuration.maximumImagePixelCount
                    )
                } catch let error as BingProviderError {
                    failures.append(Self.failure(for: error, candidate: candidate))
                    continue
                }

                return BingImageAsset(
                    wallpaperID: wallpaperID,
                    data: response.data,
                    mimeType: validated.mimeType,
                    uti: validated.uti,
                    pixelWidth: validated.width,
                    pixelHeight: validated.height,
                    sourceURL: response.finalURL,
                    requestedURL: candidate.url,
                    resolvedKind: candidate.kind,
                    sha256: Self.sha256Hex(response.data),
                    fetchedAt: now()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BingProviderError {
                if Self.isFatalForImageChain(error) {
                    throw error
                }
                failures.append(Self.failure(for: error, candidate: candidate))
            } catch {
                let mapped = BingRequestExecutor.providerError(from: error)
                if Self.isFatalForImageChain(mapped) {
                    throw mapped
                }
                failures.append(Self.failure(for: mapped, candidate: candidate))
            }
        }

        throw BingProviderError.allImageCandidatesFailed(
            wallpaperID: wallpaperID,
            failures: failures
        )
    }

    // MARK: Request plumbing

    private func validatedProfile() throws -> BingMarketProfile {
        let market = profile.market.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard market == profile.market.rawValue,
              !market.isEmpty,
              market.utf8.count <= 32,
              market.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || (byte >= 48 && byte <= 57)
                      || byte == 45
                      || byte == 95
              })
        else {
            throw BingProviderError.invalidConfiguration("market must be a simple tag such as zh-CN")
        }
        let locale = profile.contentLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locale.isEmpty, locale == profile.contentLocaleIdentifier else {
            throw BingProviderError.invalidConfiguration("contentLocaleIdentifier must be non-empty")
        }
        return profile
    }

    private var apiPolicy: BingRedirectPolicy {
        BingRedirectPolicy(allowedHosts: configuration.apiHosts)
    }

    private var mediaPolicy: BingRedirectPolicy {
        BingRedirectPolicy(allowedHosts: configuration.mediaHosts)
    }

    private var navigationPolicy: BingRedirectPolicy {
        BingRedirectPolicy(allowedHosts: configuration.navigationHosts)
    }

    private func makeArchiveRequest(profile: BingMarketProfile) throws -> BingHTTPRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.bing.com"
        components.path = "/HPImageArchive.aspx"
        components.queryItems = [
            URLQueryItem(name: "format", value: "js"),
            URLQueryItem(name: "idx", value: "0"),
            URLQueryItem(name: "n", value: String(configuration.archiveCount)),
            URLQueryItem(name: "mkt", value: profile.market.rawValue)
        ]
        guard let url = components.url, apiPolicy.allows(url) else {
            throw BingProviderError.invalidConfiguration("archive endpoint is not an allowed HTTPS URL")
        }
        return BingHTTPRequest(
            url: url,
            headers: makeHeaders(profile: profile, accept: "application/json"),
            timeout: configuration.requestTimeout,
            maximumBytes: configuration.maximumMetadataBytes
        )
    }

    private func makeStoryRequest(profile: BingMarketProfile) throws -> BingHTTPRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.bing.com"
        components.path = "/hp/api/model"
        components.queryItems = [URLQueryItem(name: "mkt", value: profile.market.rawValue)]
        guard let url = components.url, apiPolicy.allows(url) else {
            throw BingProviderError.invalidConfiguration("story endpoint is not an allowed HTTPS URL")
        }
        return BingHTTPRequest(
            url: url,
            headers: makeHeaders(profile: profile, accept: "application/json"),
            timeout: configuration.requestTimeout,
            maximumBytes: configuration.maximumStoryBytes
        )
    }

    private func makeHeaders(profile: BingMarketProfile, accept: String) -> [String: String] {
        [
            "Accept": accept,
            "Accept-Language": profile.market.rawValue,
            "User-Agent": configuration.userAgent,
            "Cache-Control": "no-cache"
        ]
    }

    // MARK: Archive parsing

    private func makeArchiveEntry(
        _ raw: ArchiveImage,
        index: Int,
        profile: BingMarketProfile,
        fetchedAt: Date,
        diagnostics: inout [BingDiagnostic]
    ) throws -> BingArchiveEntry {
        guard let fullStart = raw.fullstartdate,
              let instant = BingDateParser.fullStartInstant(fullStart)
        else {
            throw BingProviderError.malformedResponse("images[\(index)].fullstartdate is not yyyyMMddHHmm")
        }
        guard let localDate = LocalDate(date: instant, timeZone: profile.timeZone),
              isPlausible(localDate)
        else {
            throw BingProviderError.malformedResponse("images[\(index)].fullstartdate is outside the supported range")
        }

        let startDate = BingDateParser.compactDate(raw.startdate)
        if raw.startdate != nil, startDate == nil {
            diagnostics.append(BingDiagnostic(
                code: .invalidDate,
                field: "images[\(index)].startdate"
            ))
        }
        let endDate = BingDateParser.compactDate(raw.enddate)
        if raw.enddate != nil, endDate == nil {
            diagnostics.append(BingDiagnostic(
                code: .invalidDate,
                field: "images[\(index)].enddate"
            ))
        }

        guard let identity = BingIdentityResolver.identity(
            urlStrings: [raw.urlbase, raw.url],
            providerHash: raw.hsh,
            field: "images[\(index)]",
            diagnostics: &diagnostics
        ) else {
            throw BingProviderError.malformedResponse("images[\(index)] has no verifiable image identity")
        }

        let markers = BingIdentityResolver.marketMarkers(in: [raw.urlbase, raw.url])
        if markers.count > 1 {
            diagnostics.append(BingDiagnostic(
                code: .identityConflict,
                field: "images[\(index)].url",
                detail: "conflicting market markers"
            ))
            throw BingProviderError.malformedResponse("images[\(index)] has conflicting market markers")
        }
        if let marker = markers.first, !Self.market(marker, matches: profile.market) {
            diagnostics.append(BingDiagnostic(
                code: .imageMarketMarkerMismatch,
                field: "images[\(index)].url",
                detail: marker
            ))
            throw BingProviderError.malformedResponse("images[\(index)] market marker does not match request")
        }

        var urlDiagnostics: [BingDiagnostic] = []
        let candidates = BingImageURLBuilder.candidates(
            urlbase: raw.urlbase,
            url: raw.url,
            policy: mediaPolicy,
            maximum: configuration.maximumImageCandidates,
            diagnostics: &urlDiagnostics
        )
        diagnostics.append(contentsOf: urlDiagnostics)
        guard !candidates.isEmpty else {
            throw BingProviderError.malformedResponse("images[\(index)] has no allowed HTTPS image URL")
        }

        let title = BingText.imageTitle(raw.title)
        let copyright = BingText.normalized(raw.copyright)
        var sourceURL: URL? = nil
        if let link = BingText.normalized(raw.copyrightlink) {
            sourceURL = BingURLResolver.resolveHTTPS(link, policy: navigationPolicy)
            if sourceURL == nil {
                diagnostics.append(BingDiagnostic(
                    code: .invalidSourceURL,
                    field: "images[\(index)].copyrightlink"
                ))
            }
        }

        let variants = candidates.map { candidate in
            ImageVariantDescriptor(
                wallpaperID: identity.wallpaperID,
                kind: .original,
                remoteURL: candidate.url,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight
            )
        }
        let key = OccurrenceKey(source: .bing, market: profile.market, localDate: localDate)
        // HPImageArchive carries no per-entry locale field. A URL market
        // marker that matches the requested market is the only available
        // evidence that this row belongs to that market's edition; a
        // conflicting marker has already been rejected above. Without it,
        // Bing may have served its global (ROW) edition, whose title and
        // copyright are not in the requested language. Record `und`
        // ("undetermined") instead of claiming the request locale. The story
        // path records the observed `Market` value separately and is
        // unaffected by this decision.
        let originalLocale = markers.isEmpty
            ? WallpaperMetadataRecord.undeterminedLocale
            : profile.contentLocaleIdentifier
        let metadata = WallpaperMetadataRecord(
            key: key,
            wallpaperID: identity.wallpaperID,
            title: title,
            copyright: copyright,
            sourceURL: sourceURL,
            originalLocale: originalLocale,
            fetchedAt: fetchedAt,
            contentHash: BingText.contentHash([
                ("title", title),
                ("copyright", copyright),
                ("sourceURL", sourceURL?.absoluteString)
            ]),
            variants: variants
        )
        let occurrence = WallpaperOccurrence(
            source: .bing,
            market: profile.market,
            localDate: localDate,
            wallpaperID: identity.wallpaperID,
            publisherTime: instant
        )
        guard metadata.isValid, occurrence.isValid else {
            throw BingProviderError.malformedResponse("images[\(index)] produced an invalid model record")
        }
        return BingArchiveEntry(
            occurrence: occurrence,
            metadata: metadata,
            sourceStartDate: startDate,
            sourceEndDate: endDate,
            identityEvidence: identity.evidence,
            imageCandidates: candidates
        )
    }

    // MARK: Story parsing

    private func makeStoryRecord(
        _ raw: StoryMediaContent,
        index: Int,
        profile: BingMarketProfile,
        fetchedAt: Date,
        diagnostics: inout [BingDiagnostic]
    ) throws -> DailyStoryRecord? {
        // The live homepage model uses compact `yyyyMMdd` for `Ssd` (unlike
        // the localized `FullDateString`, which is never parsed). Accepting
        // only this documented machine-readable shape prevents a silent
        // zero-story result when the response is otherwise valid.
        guard let date = BingDateParser.compactDate(raw.ssd),
              isPlausible(date)
        else {
            throw BingProviderError.malformedResponse("MediaContents[\(index)].Ssd is not a strict yyyyMMdd date")
        }

        let observedMarket = BingText.normalized(raw.market)
        let marketMatches = observedMarket.map { Self.market($0, matches: profile.market) } ?? false
        let markers = BingIdentityResolver.marketMarkers(in: [
            raw.imageContent?.image?.url,
            raw.imageContent?.image?.wallpaper
        ])
        let markerMismatch: String? = {
            guard markers.count <= 1 else { return "conflicting-image-markers" }
            guard let marker = markers.first else { return nil }
            return Self.market(marker, matches: profile.market) ? nil : marker
        }()

        if !marketMatches || markerMismatch != nil {
            if observedMarket == nil {
                diagnostics.append(BingDiagnostic(
                    code: .responseMarketMissing,
                    field: "MediaContents[\(index)].Market"
                ))
            } else if !marketMatches, let observedMarket {
                diagnostics.append(BingDiagnostic(
                    code: .responseMarketMismatch,
                    field: "MediaContents[\(index)].Market",
                    detail: observedMarket
                ))
            }
            if let markerMismatch, markerMismatch != "conflicting-image-markers" {
                diagnostics.append(BingDiagnostic(
                    code: .imageMarketMarkerMismatch,
                    field: "MediaContents[\(index)].ImageContent.Image",
                    detail: markerMismatch
                ))
            }
            if markerMismatch == "conflicting-image-markers" {
                diagnostics.append(BingDiagnostic(
                    code: .identityConflict,
                    field: "MediaContents[\(index)].ImageContent.Image"
                ))
            }
            let localeHint = observedMarket ?? markerMismatch ?? "unknown"
            return DailyStoryRecord(
                id: "bing:story:\(profile.market.rawValue):\(date.iso8601):locale-mismatch:\(index)",
                source: .bing,
                market: profile.market,
                date: date,
                associatedWallpaperID: nil,
                originalLocale: localeHint,
                fetchedAt: fetchedAt,
                availability: .unavailable(.localeMismatch)
            )
        }

        guard let content = raw.imageContent else {
            diagnostics.append(BingDiagnostic(
                code: .emptyStoryContent,
                field: "MediaContents[\(index)].ImageContent"
            ))
            return DailyStoryRecord(
                id: "bing:story:\(profile.market.rawValue):\(date.iso8601):not-provided:\(index)",
                source: .bing,
                market: profile.market,
                date: date,
                associatedWallpaperID: nil,
                originalLocale: profile.contentLocaleIdentifier,
                fetchedAt: fetchedAt,
                availability: .unavailable(.notProvidedBySource)
            )
        }

        let title = BingText.normalized(content.title)
        let headline = BingText.normalized(content.headline)
        let description = BingText.normalized(content.description)
        let quickFact = BingText.normalized(content.quickFact?.mainText)
        let copyright = BingText.normalized(content.copyright)

        var sourceURL: URL? = nil
        if let backstage = BingText.normalized(content.backstageURL) {
            sourceURL = BingURLResolver.resolveHTTPS(backstage, policy: navigationPolicy)
            if sourceURL == nil {
                diagnostics.append(BingDiagnostic(
                    code: .invalidSourceURL,
                    field: "MediaContents[\(index)].ImageContent.BackstageUrl"
                ))
            }
        }

        let identity = BingIdentityResolver.identity(
            urlStrings: [content.image?.url, content.image?.wallpaper],
            providerHash: raw.hash,
            field: "MediaContents[\(index)].ImageContent.Image",
            diagnostics: &diagnostics
        )

        var sourceFields: [String] = []
        if title != nil { sourceFields.append("MediaContents[].ImageContent.Title") }
        if headline != nil { sourceFields.append("MediaContents[].ImageContent.Headline") }
        if description != nil { sourceFields.append("MediaContents[].ImageContent.Description") }
        if quickFact != nil { sourceFields.append("MediaContents[].ImageContent.QuickFact.MainText") }
        if copyright != nil { sourceFields.append("MediaContents[].ImageContent.Copyright") }
        if sourceURL != nil { sourceFields.append("MediaContents[].ImageContent.BackstageUrl") }

        if BingText.containsHTML(description)
            || BingText.containsHTML(headline)
            || BingText.containsHTML(quickFact) {
            diagnostics.append(BingDiagnostic(
                code: .htmlInStoryText,
                field: "MediaContents[\(index)].ImageContent"
            ))
        }

        let contentHash = BingText.contentHash([
            ("title", title),
            ("headline", headline),
            ("description", description),
            ("quickFact", quickFact),
            ("copyright", copyright),
            ("sourceURL", sourceURL?.absoluteString)
        ])

        let availability: StoryAvailability
        // A short title (and a copyright line) is not a daily introduction.
        // Only headline/description/quick-fact text makes the story available;
        // title/copyright survive on an explicitly unavailable record.
        if headline != nil || description != nil || quickFact != nil {
            availability = .available
        } else {
            diagnostics.append(BingDiagnostic(
                code: .emptyStoryContent,
                field: "MediaContents[\(index)].ImageContent"
            ))
            availability = .unavailable(.emptyContent)
        }

        let idSuffix: String
        if let contentHash, let first = contentHash.split(separator: ":").last {
            idSuffix = String(first)
        } else {
            idSuffix = "empty:\(index)"
        }

        let record = DailyStoryRecord(
            id: "bing:story:\(profile.market.rawValue):\(date.iso8601):\(idSuffix)",
            source: .bing,
            market: profile.market,
            date: date,
            associatedWallpaperID: identity?.wallpaperID,
            title: title,
            headline: headline,
            body: description,
            quickFact: quickFact,
            copyright: copyright,
            originalLocale: profile.contentLocaleIdentifier,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt,
            contentHash: contentHash,
            sourceFields: sourceFields,
            availability: availability
        )
        guard let record else {
            throw BingProviderError.malformedResponse("MediaContents[\(index)] violates story availability rules")
        }
        return record
    }

    // MARK: Helpers

    private func isPlausible(_ date: LocalDate) -> Bool {
        date.year >= configuration.earliestPlausibleYear
            && date.year <= configuration.latestPlausibleYear
    }

    private static func market(_ observed: String, matches expected: Market) -> Bool {
        let trimmed = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(expected.rawValue) == .orderedSame {
            return true
        }
        // Script-qualified spellings of the same catalog entry are the same
        // market evidence; a different catalog entry is still a mismatch.
        guard let observedMarket = BingMarketProfile.canonicalMarket(Market(trimmed)),
              let expectedMarket = BingMarketProfile.canonicalMarket(expected)
        else {
            return false
        }
        return observedMarket == expectedMarket
    }


    private static func isFatalForImageChain(_ error: BingProviderError) -> Bool {
        switch error {
        case .transport:
            return true
        case .httpStatus(let code, _):
            return code == 429 || (500...599).contains(code)
        default:
            return false
        }
    }

    private static func failure(
        for error: BingProviderError,
        candidate: BingImageCandidate
    ) -> BingImageAttemptFailure {
        let reason: BingImageFailureReason
        var status: Int? = nil
        switch error {
        case .httpStatus(let code, _):
            reason = .httpStatus
            status = code
        case .blockedURL:
            reason = .blockedURL
        case .responseTooLarge:
            reason = .responseTooLarge
        case .unexpectedContentType:
            reason = .unexpectedContentType
        case .imageMimeRejected:
            reason = .imageMimeRejected
        case .imageDecodeFailed:
            reason = .imageDecodeFailed
        case .imageDimensionsRejected:
            reason = .imageDimensionsRejected
        default:
            reason = .transport
        }
        return BingImageAttemptFailure(
            kind: candidate.kind,
            host: candidate.url.host,
            reason: reason,
            httpStatusCode: status
        )
    }

    private static func orderedCandidates(
        _ candidates: [BingImageCandidate],
        preference: BingImagePreference
    ) -> [BingImageCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            let left = priority(lhs.element.kind, preference: preference)
            let right = priority(rhs.element.kind, preference: preference)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func priority(
        _ kind: BingImageVariantKind,
        preference: BingImagePreference
    ) -> Int {
        switch preference {
        case .highResolution:
            switch kind {
            case .ultraHighResolution: return 0
            case .provided: return 1
            case .fullHD: return 2
            case .compact: return 3
            }
        case .fullHD:
            switch kind {
            case .fullHD: return 0
            case .provided: return 1
            case .ultraHighResolution: return 2
            case .compact: return 3
            }
        case .compact:
            switch kind {
            case .compact: return 0
            case .fullHD: return 1
            case .provided: return 2
            case .ultraHighResolution: return 3
            }
        }
    }

    private static func candidateKind(
        width: Int?,
        height: Int?,
        url: URL
    ) -> BingImageVariantKind {
        if let width, let height {
            if width >= 3_000 || height >= 2_000 { return .ultraHighResolution }
            if width >= 1_800 { return .fullHD }
            if width >= 1_200 { return .compact }
            return .provided
        }
        if let hint = BingImageURLBuilder.resolutionHint(url.absoluteString) {
            if hint.width >= 3_000 || hint.height >= 2_000 { return .ultraHighResolution }
            if hint.width >= 1_800 { return .fullHD }
            if hint.width >= 1_200 { return .compact }
        }
        if url.absoluteString.lowercased().contains("_uhd") { return .ultraHighResolution }
        return .provided
    }

    private static let imageAcceptHeader = "image/jpeg,image/png,image/webp,image/heic,image/heif"

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Decoding models

private struct ArchivePayload: Decodable, Sendable {
    let images: [ArchiveImage]?
}

private struct ArchiveImage: Decodable, Sendable {
    let startdate: String?
    let enddate: String?
    let fullstartdate: String?
    let urlbase: String?
    let url: String?
    let hsh: String?
    let title: String?
    let copyright: String?
    let copyrightlink: String?

    private enum CodingKeys: String, CodingKey {
        case startdate, enddate, fullstartdate, urlbase, url, hsh, title, copyright, copyrightlink
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startdate = try? container.decode(String.self, forKey: .startdate)
        self.enddate = try? container.decode(String.self, forKey: .enddate)
        self.fullstartdate = try? container.decode(String.self, forKey: .fullstartdate)
        self.urlbase = try? container.decode(String.self, forKey: .urlbase)
        self.url = try? container.decode(String.self, forKey: .url)
        self.hsh = try? container.decode(String.self, forKey: .hsh)
        self.title = try? container.decode(String.self, forKey: .title)
        self.copyright = try? container.decode(String.self, forKey: .copyright)
        self.copyrightlink = try? container.decode(String.self, forKey: .copyrightlink)
    }
}

private struct HomepagePayload: Decodable, Sendable {
    let mediaContents: [StoryMediaContent]?
    let preloadMediaContents: [StoryMediaContent]?

    private enum CodingKeys: String, CodingKey {
        case mediaContents = "MediaContents"
        case preloadMediaContents = "PreloadMediaContents"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mediaContents = try? container.decode([StoryMediaContent].self, forKey: .mediaContents)
        self.preloadMediaContents = try? container.decode([StoryMediaContent].self, forKey: .preloadMediaContents)
    }
}

private struct StoryMediaContent: Decodable, Sendable {
    let ssd: String?
    let market: String?
    let hash: String?
    let imageContent: StoryImageContent?

    private enum CodingKeys: String, CodingKey {
        case ssd = "Ssd"
        case market = "Market"
        case hash = "Hash"
        case imageContent = "ImageContent"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ssd = try? container.decode(String.self, forKey: .ssd)
        self.market = try? container.decode(String.self, forKey: .market)
        self.hash = try? container.decode(String.self, forKey: .hash)
        self.imageContent = try? container.decode(StoryImageContent.self, forKey: .imageContent)
    }
}

private struct StoryImageContent: Decodable, Sendable {
    let title: String?
    let headline: String?
    let description: String?
    let copyright: String?
    let backstageURL: String?
    let quickFact: StoryQuickFact?
    let image: StoryImageInfo?

    private enum CodingKeys: String, CodingKey {
        case title = "Title"
        case headline = "Headline"
        case description = "Description"
        case copyright = "Copyright"
        case backstageURL = "BackstageUrl"
        case quickFact = "QuickFact"
        case image = "Image"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try? container.decode(String.self, forKey: .title)
        self.headline = try? container.decode(String.self, forKey: .headline)
        self.description = try? container.decode(String.self, forKey: .description)
        self.copyright = try? container.decode(String.self, forKey: .copyright)
        self.backstageURL = try? container.decode(String.self, forKey: .backstageURL)
        self.quickFact = try? container.decode(StoryQuickFact.self, forKey: .quickFact)
        self.image = try? container.decode(StoryImageInfo.self, forKey: .image)
    }
}

private struct StoryQuickFact: Decodable, Sendable {
    let mainText: String?

    private enum CodingKeys: String, CodingKey {
        case mainText = "MainText"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mainText = (try? container.decode(LenientString.self, forKey: .mainText))?.value
    }
}

private struct StoryImageInfo: Decodable, Sendable {
    let url: String?
    let wallpaper: String?

    private enum CodingKeys: String, CodingKey {
        case url = "Url"
        case wallpaper = "Wallpaper"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try? container.decode(String.self, forKey: .url)
        self.wallpaper = (try? container.decode(LenientString.self, forKey: .wallpaper))?.value
    }
}

/// Tolerates an unexpected JSON type for one optional field instead of
/// failing the whole response.
private struct LenientString: Decodable, Sendable {
    let value: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else {
            self.value = try? container.decode(String.self)
        }
    }
}

// MARK: - Content type

enum BingContentType {
    static func mediaType(_ header: String?) -> String? {
        guard let header else { return nil }
        let first = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let first else { return nil }
        let type = String(first).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !type.isEmpty,
              type.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return type
    }

    static func isJSON(_ header: String?) -> Bool {
        guard let type = mediaType(header) else { return false }
        return type == "application/json"
            || type == "text/json"
            || (type.hasPrefix("application/") && type.hasSuffix("+json"))
    }

    static func canonicalImageMime(_ header: String?) -> String? {
        guard let type = mediaType(header) else { return nil }
        switch type {
        case "image/jpeg", "image/jpg", "image/pjpeg":
            return "image/jpeg"
        case "image/png":
            return "image/png"
        case "image/webp":
            return "image/webp"
        case "image/heic":
            return "image/heic"
        case "image/heif":
            return "image/heif"
        default:
            return nil
        }
    }

    static func canonicalImageMime(forUTI uti: String) -> String? {
        switch uti {
        case "public.jpeg": return "image/jpeg"
        case "public.png": return "image/png"
        case "org.webmproject.webp": return "image/webp"
        case "public.heic": return "image/heic"
        case "public.heif": return "image/heif"
        default: return nil
        }
    }
}

// MARK: - Dates

private enum BingDateParser {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// `fullstartdate` is exactly 12 ASCII digits: yyyyMMddHHmm, interpreted
    /// as a UTC instant. The four-digit year is never split into 2+2 digits.
    static func fullStartInstant(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8)
        guard bytes.count == 12, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        func value(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        return strictUTCDate(
            year: value(0..<4),
            month: value(4..<6),
            day: value(6..<8),
            hour: value(8..<10),
            minute: value(10..<12)
        )
    }

    static func compactDate(_ raw: String?) -> LocalDate? {
        guard let raw else { return nil }
        let bytes = Array(raw.utf8)
        guard bytes.count == 8, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        func value(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        return LocalDate(
            year: value(0..<4),
            month: value(4..<6),
            day: value(6..<8)
        )
    }

    private static func strictUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date? {
        guard (1...9999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        let calendar = utcCalendar
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard check.year == year,
              check.month == month,
              check.day == day,
              check.hour == hour,
              check.minute == minute
        else { return nil }
        return date
    }
}

// MARK: - Identity

private enum BingIdentityResolver {
    private static let slugPattern = #"OHR\.([A-Za-z0-9-]+)_"#
    private static let markerPattern = #"OHR\.[A-Za-z0-9-]+_([A-Za-z]{2}-[A-Za-z]{2})[0-9]+_"#

    static func identity(
        urlStrings: [String?],
        providerHash: String?,
        field: String,
        diagnostics: inout [BingDiagnostic]
    ) -> (wallpaperID: WallpaperID, evidence: BingIdentityEvidence)? {
        let slugs = Set(urlStrings.compactMap { slug(in: $0) })
        if slugs.count > 1 {
            diagnostics.append(BingDiagnostic(code: .identityConflict, field: field))
            return nil
        }
        if let slug = slugs.first {
            return (WallpaperID(source: .bing, sourceImageID: slug), .imageURLSlug)
        }
        if let hash = normalizedHash(providerHash) {
            return (WallpaperID(source: .bing, sourceImageID: "hsh:\(hash)"), .providerHash)
        }
        diagnostics.append(BingDiagnostic(code: .missingImageIdentity, field: field))
        return nil
    }

    static func slug(in raw: String?) -> String? {
        guard let raw,
              let range = raw.range(of: slugPattern, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var token = String(raw[range])
        guard token.hasPrefix("OHR."), token.hasSuffix("_") else { return nil }
        token.removeFirst(4)
        token.removeLast()
        guard (1...128).contains(token.count),
              token.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
                      || (scalar.value >= 97 && scalar.value <= 122)
                      || scalar == "-"
              })
        else { return nil }
        return token
    }

    static func marketMarkers(in rawStrings: [String?]) -> Set<String> {
        var markers: Set<String> = []
        for raw in rawStrings {
            guard let raw,
                  let range = raw.range(of: markerPattern, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let token = String(raw[range]).uppercased()
            guard let last = token.split(separator: "_").last else { continue }
            // last is the market segment with trailing digits; strip them.
            let marker = String(last.prefix { !$0.isNumber })
            if !marker.isEmpty { markers.insert(marker) }
        }
        return markers
    }

    private static func normalizedHash(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...128).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
                      || (scalar.value >= 97 && scalar.value <= 122)
              })
        else { return nil }
        return trimmed
    }
}

// MARK: - URL derivation

private enum BingURLResolver {
    static func resolveHTTPS(_ raw: String, policy: BingRedirectPolicy) -> URL? {
        guard let url = resolveHTTPS(raw) else { return nil }
        guard policy.allows(url) else { return nil }
        return url
    }

    static func resolveHTTPS(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute: String
        if trimmed.hasPrefix("//") {
            absolute = "https:" + trimmed
        } else if trimmed.hasPrefix("/") {
            absolute = "https://www.bing.com" + trimmed
        } else {
            absolute = trimmed
        }
        guard var components = URLComponents(string: absolute) else { return nil }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }
        components.fragment = nil
        return components.url
    }
}

private enum BingImageURLBuilder {
    static func candidates(
        urlbase: String?,
        url: String?,
        policy: BingRedirectPolicy,
        maximum: Int,
        diagnostics: inout [BingDiagnostic]
    ) -> [BingImageCandidate] {
        var result: [BingImageCandidate] = []
        var seen: Set<String> = []
        var wasTruncated = false
        var blockedHosts: Set<String> = []

        func add(_ candidateURL: URL?, kind: BingImageVariantKind, width: Int?, height: Int?) {
            guard let candidateURL else { return }
            guard policy.allows(candidateURL) else {
                if let host = candidateURL.host { blockedHosts.insert(host) }
                return
            }
            guard seen.insert(candidateURL.absoluteString).inserted else { return }
            guard result.count < maximum else {
                wasTruncated = true
                return
            }
            result.append(BingImageCandidate(
                url: candidateURL,
                kind: kind,
                pixelWidth: width,
                pixelHeight: height
            ))
        }

        let resolvedBase = urlbase.flatMap { BingURLResolver.resolveHTTPS($0) }
        let resolvedProvided = url.flatMap { BingURLResolver.resolveHTTPS($0) }
        let baseURL = resolvedBase ?? resolvedProvided

        if let baseURL, let base = idBase(from: baseURL) {
            add(variantURL(base, suffix: "_UHD.jpg"), kind: .ultraHighResolution, width: 3_840, height: 2_160)
            add(resolvedProvided, kind: .provided, width: nil, height: nil)
            add(variantURL(base, suffix: "_1920x1080.jpg"), kind: .fullHD, width: 1_920, height: 1_080)
            add(variantURL(base, suffix: "_1366x768.jpg"), kind: .compact, width: 1_366, height: 768)
        } else {
            let hint = resolutionHint(resolvedProvided?.absoluteString)
            add(resolvedProvided, kind: .provided, width: hint?.width, height: hint?.height)
            let baseHint = resolutionHint(resolvedBase?.absoluteString)
            add(resolvedBase, kind: .provided, width: baseHint?.width, height: baseHint?.height)
        }

        if !blockedHosts.isEmpty {
            diagnostics.append(BingDiagnostic(
                code: .blockedURL,
                field: "image",
                detail: blockedHosts.sorted().joined(separator: ",")
            ))
        }
        if wasTruncated {
            diagnostics.append(BingDiagnostic(
                code: .truncatedEntries,
                field: "imageCandidates",
                detail: "more than \(maximum) candidates"
            ))
        }
        if result.isEmpty {
            diagnostics.append(BingDiagnostic(code: .invalidImageURL, field: "image"))
        }
        return result
    }

    static func resolutionHint(_ raw: String?) -> (width: Int, height: Int)? {
        guard let raw,
              let range = raw.range(
                of: #"_[0-9]{3,4}x[0-9]{3,4}[.&]?"#,
                options: [.regularExpression]
              )
        else { return nil }
        var token = String(raw[range])
        while let last = token.last, !last.isNumber {
            token.removeLast()
        }
        guard token.hasPrefix("_") else { return nil }
        token.removeFirst()
        let parts = token.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0
        else { return nil }
        return (width, height)
    }

    private static func idBase(from url: URL) -> (components: URLComponents, value: String)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let idIndex = items.firstIndex(where: { $0.name.lowercased() == "id" }),
              let rawID = items[idIndex].value
        else { return nil }
        var value = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".jpg", ".jpeg", ".png", ".webp"] where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        for pattern in [#"_[0-9]{3,4}x[0-9]{3,4}$"#, #"_UHD$"#] {
            if let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                value.removeSubrange(range)
                break
            }
        }
        guard !value.isEmpty else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: value)]
        components.fragment = nil
        return (components, value)
    }

    private static func variantURL(
        _ base: (components: URLComponents, value: String),
        suffix: String
    ) -> URL? {
        var components = base.components
        components.queryItems = [URLQueryItem(name: "id", value: base.value + suffix)]
        return components.url
    }
}

// MARK: - Text

private enum BingText {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Bing's literal `Info` placeholder is a label, not an image title.
    /// It is observed on archive rows for editions Bing does not localize
    /// (the global/ROW fallback), where it must not be presented as photo
    /// metadata. Text that merely contains the word is preserved verbatim,
    /// and the real copyright, date and URL are never touched.
    static func imageTitle(_ value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        guard normalized.caseInsensitiveCompare(placeholderImageTitle) != .orderedSame else {
            return nil
        }
        return normalized
    }

    private static let placeholderImageTitle = "Info"

    static func containsHTML(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil
    }

    static func contentHash(_ pairs: [(String, String?)]) -> String? {
        let parts = pairs.sorted { $0.0 < $1.0 }.compactMap { pair -> String? in
            guard let value = pair.1 else { return nil }
            return "\(pair.0)=\(value)"
        }
        guard !parts.isEmpty else { return nil }
        let data = Data(parts.joined(separator: "\u{1F}").utf8)
        return "sha256:" + BingProvider.sha256Hex(data)
    }
}

// MARK: - Decoding error descriptions

private enum BingDecoding {
    static func description(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            return "dataCorrupted at \(path(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(path(context.codingPath))"
        case DecodingError.typeMismatch(_, let context):
            return "typeMismatch at \(path(context.codingPath))"
        case DecodingError.valueNotFound(_, let context):
            return "valueNotFound at \(path(context.codingPath))"
        default:
            return "unreadable JSON"
        }
    }

    static func safeDescription(_ error: BingProviderError) -> String {
        switch error {
        case .malformedResponse(let detail): return detail
        case .malformedJSON(let detail): return detail
        case .blockedURL(let host): return "blocked host \(host ?? "unknown")"
        case .unexpectedContentType(let type): return "content type \(type ?? "missing")"
        case .responseTooLarge(let limit): return "response over \(limit) bytes"
        case .httpStatus(let code, _): return "HTTP \(code)"
        default: return "record rejected"
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "<root>" }
        return codingPath.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }.joined(separator: ".")
    }
}

