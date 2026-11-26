import Foundation

// MARK: - Shared text/URL normalization

private enum ModelText {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedList(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }
}

// MARK: - Identity

/// Stable identifier of a data source. Values are not inferred from URLs.
public struct SourceID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let bing = SourceID("bing")

    public var isValid: Bool { !rawValue.isEmpty }

    public var description: String { rawValue }

    public static func < (lhs: SourceID, rhs: SourceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SourceID must not be empty"
            )
        }
        self.init(trimmed)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Exact provider market tag such as `zh-CN`.
///
/// Values are intentionally not aliased or normalized: a story fetched for
/// `zh-CN` never matches an `en-US` occurrence just because the image is the
/// same. Callers pass the provider's own market tag.
public struct Market: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let zhCN = Market("zh-CN")
    public static let enUS = Market("en-US")
    public static let jaJP = Market("ja-JP")

    public var isValid: Bool { !rawValue.isEmpty }

    public var description: String { rawValue }

    public static func < (lhs: Market, rhs: Market) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Market must not be empty"
            )
        }
        self.init(trimmed)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Content identity of an image, independent of any market or date.
///
/// One `WallpaperID` may occur on several dates and in several markets.
public struct WallpaperID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let source: SourceID
    public let sourceImageID: String

    public init(source: SourceID, sourceImageID: String) {
        self.source = source
        self.sourceImageID = sourceImageID
    }

    public var isValid: Bool {
        source.isValid
            && !sourceImageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var description: String { "\(source.rawValue):\(sourceImageID)" }

    public static func < (lhs: WallpaperID, rhs: WallpaperID) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        return lhs.sourceImageID < rhs.sourceImageID
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case sourceImageID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(SourceID.self, forKey: .source)
        let sourceImageID = try container.decode(String.self, forKey: .sourceImageID)
        guard !sourceImageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceImageID,
                in: container,
                debugDescription: "Wallpaper sourceImageID must not be empty"
            )
        }
        self.init(source: source, sourceImageID: sourceImageID)
    }
}

/// Occurrence-level key: source + market + source-local date.
///
/// This is not an image-level key. Revisions of the same occurrence share it.
public struct OccurrenceKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let source: SourceID
    public let market: Market
    public let localDate: LocalDate

    public init(source: SourceID, market: Market, localDate: LocalDate) {
        self.source = source
        self.market = market
        self.localDate = localDate
    }

    public var isValid: Bool { source.isValid && market.isValid }

    public var description: String {
        "\(source.rawValue):\(market.rawValue):\(localDate.iso8601)"
    }

    public static func < (lhs: OccurrenceKey, rhs: OccurrenceKey) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.market != rhs.market { return lhs.market < rhs.market }
        return lhs.localDate < rhs.localDate
    }
}

/// One market/date observation of an image.
public struct WallpaperOccurrence: Hashable, Sendable, Codable, Identifiable {
    public let source: SourceID
    public let market: Market
    public let localDate: LocalDate
    public let wallpaperID: WallpaperID
    public let publisherTime: Date?
    public let revision: Int

    public init(
        source: SourceID,
        market: Market,
        localDate: LocalDate,
        wallpaperID: WallpaperID,
        publisherTime: Date? = nil,
        revision: Int = 0
    ) {
        self.source = source
        self.market = market
        self.localDate = localDate
        self.wallpaperID = wallpaperID
        self.publisherTime = publisherTime
        self.revision = revision
    }

    public var id: OccurrenceKey {
        OccurrenceKey(source: source, market: market, localDate: localDate)
    }

    public var isValid: Bool {
        wallpaperID.source == source && wallpaperID.isValid && revision >= 0
    }

    public func withPublisherTime(_ publisherTime: Date?) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: source,
            market: market,
            localDate: localDate,
            wallpaperID: wallpaperID,
            publisherTime: publisherTime,
            revision: revision
        )
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case market
        case localDate
        case wallpaperID
        case publisherTime
        case revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(SourceID.self, forKey: .source)
        let market = try container.decode(Market.self, forKey: .market)
        let localDate = try container.decode(LocalDate.self, forKey: .localDate)
        let wallpaperID = try container.decode(WallpaperID.self, forKey: .wallpaperID)
        let publisherTime = try container.decodeIfPresent(Date.self, forKey: .publisherTime)
        let revision = try container.decode(Int.self, forKey: .revision)
        let occurrence = WallpaperOccurrence(
            source: source,
            market: market,
            localDate: localDate,
            wallpaperID: wallpaperID,
            publisherTime: publisherTime,
            revision: revision
        )
        guard occurrence.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .wallpaperID,
                in: container,
                debugDescription: "Occurrence source/image identity or revision is invalid"
            )
        }
        self = occurrence
    }
}

public enum OccurrenceIndex {
    /// Collapses revisions of the same source/market/date, keeping the highest
    /// revision. Equal revisions are resolved deterministically by the
    /// lexicographically smallest `WallpaperID`; a same-revision content change
    /// is an upstream conflict, not a reason to count the date twice.
    public static func latest(_ occurrences: [WallpaperOccurrence]) -> [WallpaperOccurrence] {
        var selected: [OccurrenceKey: WallpaperOccurrence] = [:]
        for occurrence in occurrences {
            guard let current = selected[occurrence.id] else {
                selected[occurrence.id] = occurrence
                continue
            }
            if occurrence.revision > current.revision {
                selected[occurrence.id] = occurrence
            } else if occurrence.revision == current.revision,
                      occurrence.wallpaperID < current.wallpaperID {
                selected[occurrence.id] = occurrence
            }
        }
        return selected.values.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.market != rhs.market { return lhs.market < rhs.market }
            if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
            if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
            return lhs.wallpaperID < rhs.wallpaperID
        }
    }
}

// MARK: - Image variants and content metadata

public enum ImageVariantKind: String, CaseIterable, Hashable, Sendable, Codable {
    case original
    case thumbnail
}

/// Cache-facing spelling for the same two variants. Both names remain valid.
public typealias AssetKind = ImageVariantKind

public enum PinReason: String, CaseIterable, Hashable, Sendable, Codable {
    case favorite
    case pinnedDate
    case currentlyApplied
}

public struct ImageVariantDescriptor: Hashable, Sendable, Codable {
    public let wallpaperID: WallpaperID
    public let kind: ImageVariantKind
    public let remoteURL: URL
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let mimeType: String?
    public let checksum: String?

    public init(
        wallpaperID: WallpaperID,
        kind: ImageVariantKind,
        remoteURL: URL,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        mimeType: String? = nil,
        checksum: String? = nil
    ) {
        self.wallpaperID = wallpaperID
        self.kind = kind
        self.remoteURL = remoteURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mimeType = ModelText.normalized(mimeType)
        self.checksum = ModelText.normalized(checksum)
    }

    public var isValid: Bool {
        wallpaperID.isValid
            && ModelText.isHTTPS(remoteURL)
            && (pixelWidth.map { $0 > 0 } ?? true)
            && (pixelHeight.map { $0 > 0 } ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case wallpaperID
        case kind
        case remoteURL
        case pixelWidth
        case pixelHeight
        case mimeType
        case checksum
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wallpaperID = try container.decode(WallpaperID.self, forKey: .wallpaperID)
        let kind = try container.decode(ImageVariantKind.self, forKey: .kind)
        let remoteURL = try container.decode(URL.self, forKey: .remoteURL)
        let pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        let pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
        let variant = ImageVariantDescriptor(
            wallpaperID: wallpaperID,
            kind: kind,
            remoteURL: remoteURL,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mimeType: mimeType,
            checksum: checksum
        )
        guard variant.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteURL,
                in: container,
                debugDescription: "Image variant must use HTTPS and positive dimensions"
            )
        }
        self = variant
    }
}

/// Image-level content record. Market/date observations live in
/// `WallpaperOccurrence`; localized copy lives in `WallpaperMetadataRecord`.
public struct WallpaperRecord: Hashable, Sendable, Codable, Identifiable {
    public let source: SourceID
    public let wallpaperID: WallpaperID
    public let canonicalTitle: String?
    public let copyright: String?
    public let sourceURL: URL?
    public let fetchedAt: Date
    public let variants: [ImageVariantDescriptor]

    public init(
        source: SourceID,
        wallpaperID: WallpaperID,
        canonicalTitle: String? = nil,
        copyright: String? = nil,
        sourceURL: URL? = nil,
        fetchedAt: Date,
        variants: [ImageVariantDescriptor] = []
    ) {
        self.source = source
        self.wallpaperID = wallpaperID
        self.canonicalTitle = ModelText.normalized(canonicalTitle)
        self.copyright = ModelText.normalized(copyright)
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.variants = variants
    }

    public var id: WallpaperID { wallpaperID }

    public var isValid: Bool {
        source.isValid
            && wallpaperID.isValid
            && wallpaperID.source == source
            && (sourceURL.map(ModelText.isHTTPS) ?? true)
            && variants.allSatisfy { $0.isValid && $0.wallpaperID == wallpaperID }
    }

    public var hasAnyContent: Bool {
        canonicalTitle != nil || copyright != nil || sourceURL != nil || !variants.isEmpty
    }

    public func preferredVariant(kind: ImageVariantKind) -> ImageVariantDescriptor? {
        variants.first { $0.kind == kind }
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case wallpaperID
        case canonicalTitle
        case copyright
        case sourceURL
        case fetchedAt
        case variants
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = WallpaperRecord(
            source: try container.decode(SourceID.self, forKey: .source),
            wallpaperID: try container.decode(WallpaperID.self, forKey: .wallpaperID),
            canonicalTitle: try container.decodeIfPresent(String.self, forKey: .canonicalTitle),
            copyright: try container.decodeIfPresent(String.self, forKey: .copyright),
            sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            variants: try container.decodeIfPresent([ImageVariantDescriptor].self, forKey: .variants) ?? []
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .wallpaperID,
                in: container,
                debugDescription: "Wallpaper record identity, URL, or variants are invalid"
            )
        }
        self = value
    }
}

/// Authoritative localized metadata for one source/market/date observation.
///
/// `WallpaperRecord` is image-level; this record preserves the title,
/// copyright, locale and variant URLs that the provider actually returned for
/// the selected market and date.
public struct WallpaperMetadataRecord: Hashable, Sendable, Codable, Identifiable {
    public let key: OccurrenceKey
    public let wallpaperID: WallpaperID
    public let title: String?
    public let copyright: String?
    public let sourceURL: URL?
    /// Language of the source text, as supported by source evidence. When the
    /// provider supplied no evidence (for example an archive response without
    /// a verified market marker), this is `undeterminedLocale` instead of the
    /// requested market's locale.
    public let originalLocale: String
    public let fetchedAt: Date
    public let contentHash: String?
    public let variants: [ImageVariantDescriptor]

    /// ISO 639-3 / BCP 47 `und` ("undetermined"). Consumers must present it as
    /// unknown, never as a language name or as the requested market's locale.
    public static let undeterminedLocale = "und"

    public init(
        key: OccurrenceKey,
        wallpaperID: WallpaperID,
        title: String? = nil,
        copyright: String? = nil,
        sourceURL: URL? = nil,
        originalLocale: String,
        fetchedAt: Date,
        contentHash: String? = nil,
        variants: [ImageVariantDescriptor] = []
    ) {
        self.key = key
        self.wallpaperID = wallpaperID
        self.title = ModelText.normalized(title)
        self.copyright = ModelText.normalized(copyright)
        self.sourceURL = sourceURL
        self.originalLocale = originalLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fetchedAt = fetchedAt
        self.contentHash = ModelText.normalized(contentHash)
        self.variants = variants
    }

    public var id: OccurrenceKey { key }

    public var isValid: Bool {
        key.isValid
            && wallpaperID.isValid
            && key.source == wallpaperID.source
            && !originalLocale.isEmpty
            && (sourceURL.map(ModelText.isHTTPS) ?? true)
            && variants.allSatisfy { $0.isValid && $0.wallpaperID == wallpaperID }
    }

    public var hasAnyContent: Bool {
        title != nil || copyright != nil || sourceURL != nil || !variants.isEmpty
    }

    public func preferredVariant(kind: ImageVariantKind) -> ImageVariantDescriptor? {
        variants.first { $0.kind == kind }
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case wallpaperID
        case title
        case copyright
        case sourceURL
        case originalLocale
        case fetchedAt
        case contentHash
        case variants
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = WallpaperMetadataRecord(
            key: try container.decode(OccurrenceKey.self, forKey: .key),
            wallpaperID: try container.decode(WallpaperID.self, forKey: .wallpaperID),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            copyright: try container.decodeIfPresent(String.self, forKey: .copyright),
            sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
            originalLocale: try container.decode(String.self, forKey: .originalLocale),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            contentHash: try container.decodeIfPresent(String.self, forKey: .contentHash),
            variants: try container.decodeIfPresent([ImageVariantDescriptor].self, forKey: .variants) ?? []
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "Metadata key, locale, URL, or variants are invalid"
            )
        }
        self = value
    }
}

// MARK: - Story

public enum StoryUnavailableReason: String, Hashable, Sendable, Codable {
    case notFetched
    case notProvidedBySource
    case fetchFailed
    case emptyContent
    case rateLimited
    case malformedResponse
    case localeMismatch
}

public enum StoryAvailability: Hashable, Sendable, Codable {
    case available
    case unavailable(StoryUnavailableReason)
}

/// Optional, attributed story for one source/market/date.
///
/// A record may be unavailable while retaining a source title, headline,
/// copyright and provenance. It must not carry a body or quick fact that the
/// source did not provide. The failable initializer enforces that rule.
public struct DailyStoryRecord: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let source: SourceID
    public let market: Market
    public let date: LocalDate
    public let associatedWallpaperID: WallpaperID?
    public let title: String?
    public let headline: String?
    public let body: String?
    public let quickFact: String?
    public let copyright: String?
    public let originalLocale: String
    public let sourceURL: URL?
    public let fetchedAt: Date
    public let contentHash: String?
    public let sourceFields: [String]
    public let availability: StoryAvailability

    public init?(
        id: String,
        source: SourceID,
        market: Market,
        date: LocalDate,
        associatedWallpaperID: WallpaperID? = nil,
        title: String? = nil,
        headline: String? = nil,
        body: String? = nil,
        quickFact: String? = nil,
        copyright: String? = nil,
        originalLocale: String,
        sourceURL: URL? = nil,
        fetchedAt: Date,
        contentHash: String? = nil,
        sourceFields: [String] = [],
        availability: StoryAvailability
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocale = originalLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              !trimmedLocale.isEmpty,
              source.isValid,
              market.isValid
        else {
            return nil
        }
        if let associatedWallpaperID, associatedWallpaperID.source != source {
            return nil
        }
        if let sourceURL, !ModelText.isHTTPS(sourceURL) {
            return nil
        }

        let normalizedTitle = ModelText.normalized(title)
        let normalizedHeadline = ModelText.normalized(headline)
        let normalizedBody = ModelText.normalized(body)
        let normalizedQuickFact = ModelText.normalized(quickFact)
        let normalizedCopyright = ModelText.normalized(copyright)

        switch availability {
        case .available:
            guard normalizedTitle != nil
                    || normalizedHeadline != nil
                    || normalizedBody != nil
                    || normalizedQuickFact != nil
            else {
                return nil
            }
        case .unavailable:
            // A title, headline or copyright may survive for display; story
            // body and quick fact must never be invented when the source did
            // not provide them.
            guard normalizedBody == nil, normalizedQuickFact == nil else { return nil }
        }

        self.id = trimmedID
        self.source = source
        self.market = market
        self.date = date
        self.associatedWallpaperID = associatedWallpaperID
        self.title = normalizedTitle
        self.headline = normalizedHeadline
        self.body = normalizedBody
        self.quickFact = normalizedQuickFact
        self.copyright = normalizedCopyright
        self.originalLocale = trimmedLocale
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.contentHash = ModelText.normalized(contentHash)
        self.sourceFields = ModelText.normalizedList(sourceFields)
        self.availability = availability
    }

    public var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case market
        case date
        case associatedWallpaperID
        case title
        case headline
        case body
        case quickFact
        case copyright
        case originalLocale
        case sourceURL
        case fetchedAt
        case contentHash
        case sourceFields
        case availability
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let source = try container.decode(SourceID.self, forKey: .source)
        let market = try container.decode(Market.self, forKey: .market)
        let date = try container.decode(LocalDate.self, forKey: .date)
        let associatedWallpaperID = try container.decodeIfPresent(WallpaperID.self, forKey: .associatedWallpaperID)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let headline = try container.decodeIfPresent(String.self, forKey: .headline)
        let body = try container.decodeIfPresent(String.self, forKey: .body)
        let quickFact = try container.decodeIfPresent(String.self, forKey: .quickFact)
        let copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        let originalLocale = try container.decode(String.self, forKey: .originalLocale)
        let sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        let fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        let contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        let sourceFields = try container.decodeIfPresent([String].self, forKey: .sourceFields) ?? []
        let availability = try container.decode(StoryAvailability.self, forKey: .availability)

        guard let value = DailyStoryRecord(
            id: id,
            source: source,
            market: market,
            date: date,
            associatedWallpaperID: associatedWallpaperID,
            title: title,
            headline: headline,
            body: body,
            quickFact: quickFact,
            copyright: copyright,
            originalLocale: originalLocale,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt,
            contentHash: contentHash,
            sourceFields: sourceFields,
            availability: availability
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Daily story record violates availability or identity rules"
            )
        }
        self = value
    }
}

/// Evidence used for a successful attachment.
public enum StoryMatchEvidence: String, Hashable, Sendable, Codable {
    /// Same source image identity, market and source-local date.
    case imageIdentityMarketAndDate

    /// No image identity, but the exact same trusted content URL on the same
    /// source, market and source-local date. Adjacent dates and other markets
    /// are never eligible.
    case sourceURLCorroboration
}

public enum StoryMatchFailure: Hashable, Sendable {
    case noCandidate
    /// One or more stories exist for this market/date but none carries a
    /// matching image identity or corroborating content URL.
    case imageIdentityMissing(candidateCount: Int)
    case dateMismatch(candidateDate: LocalDate)
    case marketMismatch(candidateMarket: Market)
    case imageIdentityConflict(candidateWallpaperID: WallpaperID)
    case ambiguousCandidates(count: Int)
}

/// Result of strict story matching.
public enum StoryMatch: Hashable, Sendable {
    case matched(DailyStoryRecord, evidence: StoryMatchEvidence)
    case unavailable(DailyStoryRecord)
    case unmatched(StoryMatchFailure)

    public var story: DailyStoryRecord? {
        switch self {
        case .matched(let story, _), .unavailable(let story):
            return story
        case .unmatched:
            return nil
        }
    }

    public var availableStory: DailyStoryRecord? {
        guard case .matched(let story, _) = self, story.isAvailable else { return nil }
        return story
    }

    public var isMatched: Bool {
        if case .matched(_, _) = self { return true }
        return false
    }
}

/// Compares story content independently of provider-generated ids and fetch
/// timestamps. The same content can be fetched repeatedly with a new id or a
/// newer fetch time; that is a revision, not an ambiguity.
enum StoryContentIdentity {
    static func isSameContent(_ lhs: DailyStoryRecord, _ rhs: DailyStoryRecord) -> Bool {
        lhs.source == rhs.source
            && lhs.market == rhs.market
            && lhs.date == rhs.date
            && lhs.associatedWallpaperID == rhs.associatedWallpaperID
            && lhs.title == rhs.title
            && lhs.headline == rhs.headline
            && lhs.body == rhs.body
            && lhs.quickFact == rhs.quickFact
            && lhs.copyright == rhs.copyright
            && lhs.originalLocale == rhs.originalLocale
            && lhs.sourceURL == rhs.sourceURL
            && lhs.contentHash == rhs.contentHash
            && lhs.sourceFields == rhs.sourceFields
            && lhs.availability == rhs.availability
    }

    /// Returns the newest revision. `nil` means the newest timestamp itself
    /// contains conflicting content, which is a genuine same-time conflict
    /// rather than two versions of the same story.
    static func resolveNewest(_ candidates: [DailyStoryRecord]) -> DailyStoryRecord? {
        guard !candidates.isEmpty else { return nil }

        var byID: [String: DailyStoryRecord] = [:]
        for candidate in candidates {
            if let existing = byID[candidate.id] {
                if candidate.fetchedAt > existing.fetchedAt {
                    byID[candidate.id] = candidate
                } else if candidate.fetchedAt == existing.fetchedAt,
                          !isSameContent(existing, candidate) {
                    return nil
                }
            } else {
                byID[candidate.id] = candidate
            }
        }

        guard let newestTime = byID.values.map(\.fetchedAt).max() else {
            return nil
        }
        let newest = byID.values.filter { $0.fetchedAt == newestTime }
        guard let first = newest.first,
              newest.allSatisfy({ isSameContent(first, $0) })
        else {
            return nil
        }
        return newest.min { $0.id < $1.id }
    }
}

public enum StoryMatcher {
    /// Strictly matches one occurrence to one story using image identity only.
    public static func match(
        occurrence: WallpaperOccurrence,
        stories: [DailyStoryRecord]
    ) -> StoryMatch {
        match(occurrence: occurrence, metadata: nil, stories: stories)
    }

    /// Strictly matches one occurrence to one story.
    ///
    /// Attachment order:
    /// 1. same source image identity + market + source date;
    /// 2. same source, market and date with an exact trusted content URL
    ///    match for a story that has no conflicting image identity.
    ///
    /// Multiple records for the same logical story are revisions: the newest
    /// `fetchedAt` wins. Equal timestamps are accepted only when content is
    /// equal (then the lexicographically smallest id is deterministic); equal
    /// timestamps with different content remain an explicit ambiguity/conflict.
    /// Stories from another date, market or image identity are never forced
    /// onto the occurrence.
    public static func match(
        occurrence: WallpaperOccurrence,
        metadata: WallpaperMetadataRecord?,
        stories: [DailyStoryRecord]
    ) -> StoryMatch {
        let sameSource = stories.filter { $0.source == occurrence.source }
        let sameDayMarket = sameSource.filter {
            $0.market == occurrence.market && $0.date == occurrence.localDate
        }

        let identityMatches = sameDayMarket.filter {
            $0.associatedWallpaperID == occurrence.wallpaperID
        }
        if !identityMatches.isEmpty {
            guard let story = StoryContentIdentity.resolveNewest(identityMatches) else {
                return .unmatched(.ambiguousCandidates(count: identityMatches.count))
            }
            return outcome(for: story, evidence: .imageIdentityMarketAndDate)
        }

        if let metadata,
           metadata.key == occurrence.id,
           metadata.wallpaperID == occurrence.wallpaperID,
           let canonicalURL = metadata.sourceURL {
            let urlMatches = sameDayMarket.filter {
                $0.associatedWallpaperID == nil && $0.sourceURL == canonicalURL
            }
            if !urlMatches.isEmpty {
                guard let story = StoryContentIdentity.resolveNewest(urlMatches) else {
                    return .unmatched(.ambiguousCandidates(count: urlMatches.count))
                }
                return outcome(for: story, evidence: .sourceURLCorroboration)
            }
        }

        let conflictIDs = sameDayMarket
            .compactMap { $0.associatedWallpaperID }
            .filter { $0 != occurrence.wallpaperID }
            .sorted()
        if let conflictID = conflictIDs.first {
            return .unmatched(.imageIdentityConflict(candidateWallpaperID: conflictID))
        }

        let unboundCount = sameDayMarket.filter { $0.associatedWallpaperID == nil }.count
        if unboundCount > 0 {
            return .unmatched(.imageIdentityMissing(candidateCount: unboundCount))
        }

        let otherDates = sameSource.filter {
            $0.market == occurrence.market && $0.date != occurrence.localDate
        }
        if let nearest = nearestStory(otherDates, to: occurrence.localDate) {
            return .unmatched(.dateMismatch(candidateDate: nearest.date))
        }

        let otherMarkets = sameSource.filter {
            $0.date == occurrence.localDate && $0.market != occurrence.market
        }
        if let nearest = otherMarkets.min(by: { lhs, rhs in
            if lhs.market != rhs.market { return lhs.market < rhs.market }
            return lhs.id < rhs.id
        }) {
            return .unmatched(.marketMismatch(candidateMarket: nearest.market))
        }

        return .unmatched(.noCandidate)
    }

    private static func outcome(
        for story: DailyStoryRecord,
        evidence: StoryMatchEvidence
    ) -> StoryMatch {
        switch story.availability {
        case .available:
            return .matched(story, evidence: evidence)
        case .unavailable:
            return .unavailable(story)
        }
    }

    private static func nearestStory(
        _ stories: [DailyStoryRecord],
        to date: LocalDate
    ) -> DailyStoryRecord? {
        stories.min { lhs, rhs in
            let lhsDistance = abs(lhs.date.days(until: date))
            let rhsDistance = abs(rhs.date.days(until: date))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
    }
}
