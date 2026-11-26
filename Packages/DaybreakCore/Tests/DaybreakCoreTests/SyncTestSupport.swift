import Foundation
import DaybreakCore

extension SyncDeviceID {
    static let deviceA = SyncDeviceID("device-a")!
    static let deviceB = SyncDeviceID("device-b")!
}

enum SyncFixture {
    static let deviceA = SyncDeviceID("device-a")!
    static let deviceB = SyncDeviceID("device-b")!
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let olderFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let newerFetchedAt = Date(timeIntervalSince1970: 1_900_000_000)

    static func date(_ iso8601: String) -> LocalDate {
        guard let value = LocalDate(iso8601: iso8601) else {
            preconditionFailure("Invalid synthetic date: \(iso8601)")
        }
        return value
    }

    static func image(_ sourceImageID: String, source: SourceID = .bing) -> WallpaperID {
        WallpaperID(source: source, sourceImageID: sourceImageID)
    }

    static func occurrence(
        _ iso8601: String = "2026-01-01",
        market: Market = .zhCN,
        imageID: String,
        revision: Int = 0,
        publisherTime: Date? = nil
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: .bing,
            market: market,
            localDate: date(iso8601),
            wallpaperID: image(imageID),
            publisherTime: publisherTime,
            revision: revision
        )
    }

    static func variant(
        _ imageID: String,
        kind: ImageVariantKind = .original,
        url: String = "https://example.invalid/synthetic.jpg",
        checksum: String = "synthetic-checksum"
    ) -> ImageVariantDescriptor {
        ImageVariantDescriptor(
            wallpaperID: image(imageID),
            kind: kind,
            remoteURL: URL(string: url)!,
            pixelWidth: 1920,
            pixelHeight: 1080,
            mimeType: "image/jpeg",
            checksum: checksum
        )
    }

    static func metadata(
        _ iso8601: String = "2026-01-01",
        market: Market = .zhCN,
        imageID: String,
        title: String? = "Synthetic metadata title",
        copyright: String? = "Synthetic copyright",
        sourceURL: URL? = URL(string: "https://example.invalid/synthetic-content")!,
        fetchedAt: Date = fetchedAt,
        contentHash: String? = "synthetic-content-hash",
        variants: [ImageVariantDescriptor] = []
    ) -> WallpaperMetadataRecord {
        WallpaperMetadataRecord(
            key: OccurrenceKey(source: .bing, market: market, localDate: date(iso8601)),
            wallpaperID: image(imageID),
            title: title,
            copyright: copyright,
            sourceURL: sourceURL,
            originalLocale: market.rawValue,
            fetchedAt: fetchedAt,
            contentHash: contentHash,
            variants: variants
        )
    }

    static func wallpaper(
        imageID: String,
        title: String? = "Synthetic wallpaper",
        fetchedAt: Date = fetchedAt,
        variants: [ImageVariantDescriptor] = []
    ) -> WallpaperRecord {
        WallpaperRecord(
            source: .bing,
            wallpaperID: image(imageID),
            canonicalTitle: title,
            copyright: "Synthetic copyright",
            sourceURL: URL(string: "https://example.invalid/synthetic-wallpaper")!,
            fetchedAt: fetchedAt,
            variants: variants
        )
    }

    static func story(
        id: String = "story-a",
        iso8601: String = "2026-01-01",
        market: Market = .zhCN,
        imageID: String? = "img-a",
        title: String? = "Synthetic story title",
        body: String? = "Synthetic story body",
        quickFact: String? = nil,
        fetchedAt: Date = fetchedAt,
        availability: StoryAvailability = .available
    ) -> DailyStoryRecord {
        guard let record = DailyStoryRecord(
            id: id,
            source: .bing,
            market: market,
            date: date(iso8601),
            associatedWallpaperID: imageID.map { image($0) },
            title: title,
            body: body,
            quickFact: quickFact,
            copyright: "Synthetic copyright",
            originalLocale: market.rawValue,
            sourceURL: URL(string: "https://example.invalid/synthetic-story")!,
            fetchedAt: fetchedAt,
            contentHash: "story-hash-\(id)",
            sourceFields: ["title", "body"],
            availability: availability
        ) else {
            preconditionFailure("Invalid synthetic story fixture")
        }
        return record
    }

    static func assetReference(
        _ imageID: String,
        kind: ImageVariantKind = .original,
        data: Data = Data("synthetic-asset".utf8),
        mimeType: String? = "image/jpeg"
    ) -> SyncAssetReference {
        SyncAssetReference(
            wallpaperID: image(imageID),
            kind: kind,
            contentSHA256: SyncContentDigest.hashing(data),
            byteCount: data.count,
            mimeType: mimeType,
            pixelWidth: 1920,
            pixelHeight: 1080
        )
    }

    static func versionVector(_ counters: [String: UInt64]) -> SyncVersionVector {
        var typed: [SyncDeviceID: UInt64] = [:]
        for (key, value) in counters {
            guard let device = SyncDeviceID(key) else {
                preconditionFailure("Invalid synthetic device id: \(key)")
            }
            typed[device] = value
        }
        do {
            return try SyncVersionVector(typed)
        } catch {
            preconditionFailure("Invalid synthetic version vector: \(error)")
        }
    }

    static func operation(
        _ payload: SyncOperationPayload,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        do {
            let context = try versionVector(prior).advancing(device, to: sequence)
            return try SyncOperation(
                deviceID: device,
                sequence: sequence,
                context: context,
                payload: payload
            )
        } catch {
            preconditionFailure("Invalid synthetic operation: \(error)")
        }
    }

    static func favorite(
        _ imageID: String,
        isFavorite: Bool,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        operation(
            .favorite(SyncFavoriteChange(wallpaperID: image(imageID), isFavorite: isFavorite)),
            device: device,
            sequence: sequence,
            prior: prior
        )
    }

    static func pin(
        _ iso8601: String = "2026-01-01",
        market: Market = .zhCN,
        imageID: String,
        isPinned: Bool,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        let key = OccurrenceKey(source: .bing, market: market, localDate: date(iso8601))
        return operation(
            .pin(
                SyncPinChange(
                    key: key,
                    wallpaperID: isPinned ? image(imageID) : nil,
                    isPinned: isPinned
                )
            ),
            device: device,
            sequence: sequence,
            prior: prior
        )
    }

    static func occurrenceOperation(
        _ record: WallpaperOccurrence,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        operation(.occurrence(record), device: device, sequence: sequence, prior: prior)
    }

    static func metadataOperation(
        _ record: WallpaperMetadataRecord,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        operation(.metadata(record), device: device, sequence: sequence, prior: prior)
    }

    static func wallpaperOperation(
        _ record: WallpaperRecord,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        operation(.wallpaper(record), device: device, sequence: sequence, prior: prior)
    }

    static func storyOperation(
        _ record: DailyStoryRecord,
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        operation(.story(record), device: device, sequence: sequence, prior: prior)
    }

    static func assetsOperation(
        _ references: [SyncAssetReference],
        device: SyncDeviceID,
        sequence: UInt64,
        prior: [String: UInt64] = [:]
    ) -> SyncOperation {
        operation(.assets(references), device: device, sequence: sequence, prior: prior)
    }
}
