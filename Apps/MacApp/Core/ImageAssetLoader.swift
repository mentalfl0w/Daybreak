import AppKit
import ImageIO

/// Immutable decoded image handed from a background actor to SwiftUI.
///
/// `NSImage` is created once from a private `CGImage` and is only read after
/// construction, so sharing this box across isolation boundaries is safe.
struct DecodedImage: @unchecked Sendable {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ImageDecodeError: Error, LocalizedError {
    case unreadableFile
    case unsupportedImage

    var errorDescription: String? {
        description(in: WallpaperInterfaceLocale.current)
    }

    func description(in locale: Locale) -> String {
        switch self {
        case .unreadableFile: return MacLocalizedString.resolve("无法读取缓存图片", locale: locale)
        case .unsupportedImage: return MacLocalizedString.resolve("缓存图片无法打开", locale: locale)
        }
    }
}

/// Reads and downsamples cached images away from the main actor.
///
/// ImageIO is asked for a bounded thumbnail instead of decoding a full UHD
/// bitmap for the window preview.
actor ImageAssetLoader {
    private var cache: [String: DecodedImage] = [:]
    private var insertionOrder: [String] = []
    private let maximumEntries = 4

    func image(at url: URL, maxPixelSize: Int) throws -> DecodedImage {
        let boundedSize = max(128, min(maxPixelSize, 8_192))
        let key = "\(url.path)#\(boundedSize)"
        if let cached = cache[key] {
            return cached
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ImageDecodeError.unreadableFile
        }

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw ImageDecodeError.unsupportedImage
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
            throw ImageDecodeError.unsupportedImage
        }

        let decoded = DecodedImage(
            image: NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            ),
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

    private func insert(_ image: DecodedImage, for key: String) {
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
