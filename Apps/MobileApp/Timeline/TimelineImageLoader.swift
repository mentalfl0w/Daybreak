import CoreGraphics
import Foundation
import ImageIO

/// A decoded image that can cross actor boundaries safely.
///
/// `CGImage` is immutable after creation; the wrapper only exists so the
/// compiler does not have to infer sendability for CoreGraphics.
struct TimelineDecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum TimelineImageError: Error, Equatable, Sendable {
    case unreadableFile
    case unsupportedImage
    case tooLarge
}

/// Bounded ImageIO decoder for calendar and gallery thumbnails plus the
/// detail hero image.
///
/// Decoding happens off the main actor. Thumbnails are always downsampled and
/// the cache is capped so a long month grid cannot hold full-size bitmaps.
/// One process-wide instance is shared by every scene; decoded entries are
/// keyed by file path, target pixel size and modification date so a refreshed
/// file is not served from a stale cache.
actor TimelineImageLoader {
    static let shared = TimelineImageLoader()

    private struct Key: Hashable {
        let path: String
        let maxPixelSize: Int
        let modifiedAt: Date?
    }

    private var cache: [Key: TimelineDecodedImage] = [:]
    private var insertionOrder: [Key] = []
    private let maximumEntries: Int

    init(maximumEntries: Int = 128) {
        self.maximumEntries = max(16, maximumEntries)
    }

    func image(at url: URL, maxPixelSize: Int) throws -> TimelineDecodedImage {
        let boundedSize = max(64, min(maxPixelSize, 4_096))
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let key = Key(
            path: url.path,
            maxPixelSize: boundedSize,
            modifiedAt: modifiedAt
        )
        if let cached = cache[key] {
            return cached
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw TimelineImageError.unreadableFile
        }

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw TimelineImageError.unsupportedImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: boundedSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw TimelineImageError.unsupportedImage
        }
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw TimelineImageError.unsupportedImage
        }

        let decoded = TimelineDecodedImage(
            cgImage: cgImage,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        insert(decoded, for: key)
        return decoded
    }

    func removeAll() {
        cache.removeAll()
        insertionOrder.removeAll()
    }

    private func insert(_ image: TimelineDecodedImage, for key: Key) {
        if cache[key] == nil {
            insertionOrder.append(key)
        }
        cache[key] = image
        while insertionOrder.count > maximumEntries {
            let oldest = insertionOrder.removeFirst()
            cache[oldest] = nil
        }
    }
}
