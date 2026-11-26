import Foundation
import ImageIO
// MARK: - Image validation

struct BingValidatedImage {
    let mimeType: String
    let uti: String
    let width: Int
    let height: Int
}

enum BingImageValidator {
    static func validate(
        data: Data,
        declaredContentType: String?,
        maximumDimension: Int,
        maximumPixelCount: Int
    ) throws -> BingValidatedImage {
        guard !data.isEmpty else {
            throw BingProviderError.imageDecodeFailed
        }
        guard let declared = BingContentType.canonicalImageMime(declaredContentType) else {
            throw BingProviderError.imageMimeRejected(
                declared: declaredContentType,
                detected: nil
            )
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw BingProviderError.imageDecodeFailed
        }
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw BingProviderError.imageDecodeFailed
        }
        guard let type = CGImageSourceGetType(source) else {
            throw BingProviderError.imageDecodeFailed
        }
        let uti = String(describing: type)
        guard let detected = BingContentType.canonicalImageMime(forUTI: uti),
              detected == declared
        else {
            throw BingProviderError.imageMimeRejected(declared: declared, detected: uti)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            throw BingProviderError.imageDecodeFailed
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            throw BingProviderError.imageDimensionsRejected(width: width, height: height)
        }
        guard width <= Int.max / height,
              width * height <= maximumPixelCount
        else {
            throw BingProviderError.imageDimensionsRejected(width: width, height: height)
        }

        // Bounded decode: prove the pixels are decodable without materializing
        // the full-resolution image in memory.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) != nil else {
            throw BingProviderError.imageDecodeFailed
        }
        return BingValidatedImage(
            mimeType: detected,
            uti: uti,
            width: width,
            height: height
        )
    }
}
