import Foundation

// MARK: - Canonical bytes

/// Deterministic, length-prefixed byte encoding used only for SHA-256 identity
/// and stable merge preference. It is intentionally not JSON: JSON key order,
/// number formatting and escaping must never decide whether two operations are
/// the same.
struct SyncCanonicalEncoder {
    private(set) var bytes: [UInt8] = []

    mutating func append(tag: String) {
        appendString(tag)
    }

    mutating func append(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ value: Int) {
        append(Int64(value))
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: Bool) {
        append(UInt8(value ? 1 : 0))
    }

    mutating func append(_ value: String) {
        appendString(value)
    }

    private mutating func appendString(_ value: String) {
        let utf8 = Array(value.utf8)
        append(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    /// Canonical time representation. Timestamps are content, never causality;
    /// millisecond rounding keeps re-encoding stable without consulting a clock.
    mutating func append(_ value: Date) {
        let milliseconds = (value.timeIntervalSince1970 * 1000).rounded()
        let bounded = min(max(milliseconds, -9_000_000_000_000_000), 9_000_000_000_000_000)
        append(Int64(bounded))
    }

    mutating func append(_ value: SyncContentDigest) {
        append(value.hex)
    }

    mutating func append(_ value: SyncDeviceID) {
        append(value.rawValue)
    }

    mutating func append(_ value: SyncVersionVector) {
        append(UInt64(value.counters.count))
        for (device, counter) in value.counters.sorted(by: { $0.key < $1.key }) {
            append(device)
            append(counter)
        }
    }

    mutating func append(_ value: LocalDate) {
        append(value.iso8601)
    }

    mutating func append(_ value: WallpaperID) {
        append(tag: "wallpaperID")
        append(value.source.rawValue)
        append(value.sourceImageID)
    }

    mutating func append(_ value: OccurrenceKey) {
        append(tag: "occurrenceKey")
        append(value.source.rawValue)
        append(value.market.rawValue)
        append(value.localDate)
    }

    mutating func append(_ value: ImageVariantKind) {
        append(value.rawValue)
    }

    mutating func append(_ value: URL) {
        append(value.absoluteString)
    }

    mutating func appendOptional(_ value: String?) {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(value)
    }

    mutating func appendOptional(_ value: Int?) {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(value)
    }

    mutating func appendOptional(_ value: Date?) {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(value)
    }

    mutating func appendOptional(_ value: URL?) {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(value)
    }

    mutating func appendOptional(_ value: WallpaperID?) {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        append(value)
    }

    mutating func append(_ value: ImageVariantDescriptor) {
        append(tag: "variant")
        append(value.wallpaperID)
        append(value.kind)
        append(value.remoteURL)
        appendOptional(value.pixelWidth)
        appendOptional(value.pixelHeight)
        appendOptional(value.mimeType)
        appendOptional(value.checksum)
    }

    mutating func appendSortedVariants(_ variants: [ImageVariantDescriptor]) {
        let sorted = variants.sorted(by: SyncCanonicalOrder.variant)
        append(UInt64(sorted.count))
        for variant in sorted {
            append(variant)
        }
    }

    mutating func append(_ value: WallpaperOccurrence) {
        append(tag: "occurrence")
        append(value.source.rawValue)
        append(value.market.rawValue)
        append(value.localDate)
        append(value.wallpaperID)
        appendOptional(value.publisherTime)
        append(value.revision)
    }

    mutating func append(_ value: WallpaperMetadataRecord) {
        append(tag: "metadata")
        append(value.key)
        append(value.wallpaperID)
        appendOptional(value.title)
        appendOptional(value.copyright)
        appendOptional(value.sourceURL)
        append(value.originalLocale)
        append(value.fetchedAt)
        appendOptional(value.contentHash)
        appendSortedVariants(value.variants)
    }

    mutating func append(_ value: WallpaperRecord) {
        append(tag: "wallpaperRecord")
        append(value.source.rawValue)
        append(value.wallpaperID)
        appendOptional(value.canonicalTitle)
        appendOptional(value.copyright)
        appendOptional(value.sourceURL)
        append(value.fetchedAt)
        appendSortedVariants(value.variants)
    }

    mutating func append(_ value: DailyStoryRecord) {
        append(tag: "story")
        append(value.id)
        append(value.source.rawValue)
        append(value.market.rawValue)
        append(value.date)
        appendOptional(value.associatedWallpaperID)
        appendOptional(value.title)
        appendOptional(value.headline)
        appendOptional(value.body)
        appendOptional(value.quickFact)
        appendOptional(value.copyright)
        append(value.originalLocale)
        appendOptional(value.sourceURL)
        append(value.fetchedAt)
        appendOptional(value.contentHash)
        let fields = value.sourceFields.sorted()
        append(UInt64(fields.count))
        for field in fields {
            append(field)
        }
        append(value.availability)
    }

    mutating func append(_ value: StoryAvailability) {
        switch value {
        case .available:
            append(tag: "available")
        case .unavailable(let reason):
            append(tag: "unavailable")
            append(reason.rawValue)
        }
    }

    mutating func append(_ value: SyncAssetReference) {
        append(tag: "assetReference")
        append(value.wallpaperID)
        append(value.kind)
        append(value.contentSHA256)
        append(value.byteCount)
        appendOptional(value.mimeType)
        appendOptional(value.pixelWidth)
        appendOptional(value.pixelHeight)
    }

    mutating func append(_ value: SyncOperationPayload) {
        switch value {
        case .favorite(let change):
            append(tag: "favorite")
            append(change.wallpaperID)
            append(change.isFavorite)
        case .pin(let change):
            append(tag: "pin")
            append(change.key)
            appendOptional(change.wallpaperID)
            append(change.isPinned)
        case .occurrence(let record):
            append(record)
        case .metadata(let record):
            append(record)
        case .wallpaper(let record):
            append(record)
        case .story(let record):
            append(record)
        case .assets(let references):
            append(tag: "assets")
            let sorted = references.sorted { $0.id < $1.id }
            append(UInt64(sorted.count))
            for reference in sorted {
                append(reference)
            }
        }
    }
}

// MARK: - Canonical identity

enum SyncCanonicalEncoding {
    static func operationBody(
        wireVersion: Int,
        deviceID: SyncDeviceID,
        sequence: UInt64,
        context: SyncVersionVector,
        payload: SyncOperationPayload
    ) -> Data {
        var encoder = SyncCanonicalEncoder()
        encoder.append(tag: "daybreak.sync.operation.body")
        encoder.append(wireVersion)
        encoder.append(deviceID)
        encoder.append(sequence)
        encoder.append(context)
        encoder.append(payload)
        return Data(encoder.bytes)
    }

    static func stableKey(_ bytes: [UInt8]) -> String {
        SyncContentDigest.hashing(Data(bytes)).hex
    }

    static func occurrenceStableKey(_ record: WallpaperOccurrence) -> String {
        let invertedRevision = UInt64.max - UInt64(max(record.revision, 0))
        return padded(invertedRevision) + "|" + wallpaperIDStableKey(record.wallpaperID)
    }

    static func metadataStableKey(_ record: WallpaperMetadataRecord) -> String {
        let score = (record.title == nil ? 0 : 1)
            + (record.copyright == nil ? 0 : 1)
            + (record.sourceURL == nil ? 0 : 1)
            + min(record.variants.count, 99)
        var encoder = SyncCanonicalEncoder()
        encoder.append(tag: "metadata.stable")
        encoder.append(record.key)
        encoder.append(record.wallpaperID)
        encoder.appendOptional(record.title)
        encoder.appendOptional(record.copyright)
        encoder.appendOptional(record.sourceURL)
        encoder.append(record.originalLocale)
        encoder.appendOptional(record.contentHash)
        encoder.appendSortedVariants(record.variants)
        return padded(UInt64(99 - min(score, 99))) + "|" + stableKey(encoder.bytes)
    }

    static func wallpaperStableKey(_ record: WallpaperRecord) -> String {
        let rank = min(record.variants.count, 99)
        var encoder = SyncCanonicalEncoder()
        encoder.append(tag: "wallpaper.stable")
        encoder.append(record.source.rawValue)
        encoder.append(record.wallpaperID)
        encoder.appendOptional(record.canonicalTitle)
        encoder.appendOptional(record.copyright)
        encoder.appendOptional(record.sourceURL)
        encoder.appendSortedVariants(record.variants)
        return padded(UInt64(99 - rank)) + "|" + stableKey(encoder.bytes)
    }

    static func storyStableKey(_ record: DailyStoryRecord) -> String {
        let rank = record.isAvailable ? 0 : 1
        var encoder = SyncCanonicalEncoder()
        encoder.append(tag: "story.stable")
        encoder.append(record.id)
        encoder.append(record.source.rawValue)
        encoder.append(record.market.rawValue)
        encoder.append(record.date)
        encoder.appendOptional(record.associatedWallpaperID)
        encoder.appendOptional(record.title)
        encoder.appendOptional(record.headline)
        encoder.appendOptional(record.body)
        encoder.appendOptional(record.quickFact)
        encoder.appendOptional(record.copyright)
        encoder.append(record.originalLocale)
        encoder.appendOptional(record.sourceURL)
        encoder.appendOptional(record.contentHash)
        let fields = record.sourceFields.sorted()
        encoder.append(UInt64(fields.count))
        for field in fields {
            encoder.append(field)
        }
        encoder.append(record.availability)
        return padded(UInt64(rank)) + "|" + stableKey(encoder.bytes)
    }

    static func wallpaperIDStableKey(_ id: WallpaperID) -> String {
        "\(id.source.rawValue)\u{1F}\(id.sourceImageID)"
    }

    static func padded(_ value: UInt64) -> String {
        let text = String(value)
        guard text.count < 20 else { return text }
        return String(repeating: "0", count: 20 - text.count) + text
    }
}

enum SyncCanonicalOrder {
    static func variant(_ lhs: ImageVariantDescriptor, _ rhs: ImageVariantDescriptor) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.remoteURL.absoluteString != rhs.remoteURL.absoluteString {
            return lhs.remoteURL.absoluteString < rhs.remoteURL.absoluteString
        }
        let lhsWidth = lhs.pixelWidth ?? -1
        let rhsWidth = rhs.pixelWidth ?? -1
        if lhsWidth != rhsWidth { return lhsWidth < rhsWidth }
        let lhsHeight = lhs.pixelHeight ?? -1
        let rhsHeight = rhs.pixelHeight ?? -1
        if lhsHeight != rhsHeight { return lhsHeight < rhsHeight }
        let lhsMIME = lhs.mimeType ?? ""
        let rhsMIME = rhs.mimeType ?? ""
        if lhsMIME != rhsMIME { return lhsMIME < rhsMIME }
        return (lhs.checksum ?? "") < (rhs.checksum ?? "")
    }
}
