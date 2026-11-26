import ImageIO
import UIKit

/// Immutable decoded image handed from a background actor to SwiftUI.
///
/// `UIImage` is created from a private `CGImage` and only read afterwards; the
/// box is safe to pass across isolation boundaries.
struct WallpaperPreviewImage: @unchecked Sendable {
    let image: UIImage
    let pixelSize: WallpaperPixelSize
}

/// Loads a bounded preview image away from the main actor.
///
/// ImageIO is asked for a transformed thumbnail instead of a full UHD bitmap.
/// Export re-reads the original at export time; this cache only feeds the
/// on-screen composition.
actor WallpaperPreviewImageLoader {
    private struct CacheKey: Hashable {
        let path: String
        let modifiedAt: Date?
        let maximumPixelSize: Int
    }

    private var cache: [CacheKey: WallpaperPreviewImage] = [:]
    private var insertionOrder: [CacheKey] = []
    private let maximumEntries = 2

    func load(
        url: URL,
        maximumPixelSize: Int = 3_000
    ) async throws -> WallpaperPreviewImage {
        guard url.isFileURL else { throw WallpaperPreviewError.notAFileURL }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw WallpaperPreviewError.unreadableFile
        }

        let boundedSize = min(max(maximumPixelSize, 720), 4_096)
        let modifiedAt = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? nil
        let key = CacheKey(
            path: url.path,
            modifiedAt: modifiedAt,
            maximumPixelSize: boundedSize
        )
        if let cached = cache[key] {
            return cached
        }

        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw WallpaperPreviewError.unreadableFile
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
            throw WallpaperPreviewError.unsupportedImage
        }

        try Task.checkCancellation()

        let image = WallpaperPreviewImage(
            image: UIImage(cgImage: cgImage, scale: 1, orientation: .up),
            pixelSize: WallpaperPixelSize(width: cgImage.width, height: cgImage.height)
        )
        insert(image, for: key)
        return image
    }

    func removeAll() {
        cache.removeAll()
        insertionOrder.removeAll()
    }

    private func insert(_ image: WallpaperPreviewImage, for key: CacheKey) {
        if cache[key] != nil {
            insertionOrder.removeAll { $0 == key }
        }
        cache[key] = image
        insertionOrder.append(key)
        while insertionOrder.count > maximumEntries {
            let oldest = insertionOrder.removeFirst()
            cache[oldest] = nil
        }
    }
}
