import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Content hashing

enum CloudSyncContentHashing {
    /// Lowercase SHA-256 and byte count of a local asset file.
    static func digest(ofFileAt url: URL) throws -> (digest: SyncContentDigest, byteCount: Int)? {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }
        return (SyncContentDigest.hashing(data), data.count)
    }

    static func digest(of payload: SyncOperationPayload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        return SyncContentDigest.hashing(data).hex
    }
}

// MARK: - Image validation

enum CloudSyncAssetValidationError: Error, Hashable, Sendable {
    case byteCountMismatch
    case digestMismatch
    case unreadableImage
    case unsupportedImageType
    case mimeTypeMismatch
    case dimensionMismatch
    case dimensionsOutOfBounds
}

struct CloudSyncValidatedAsset: Hashable, Sendable {
    let fileExtension: String
    let mimeType: String?
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Bounded, public-framework validation for a content-addressed image blob.
///
/// The digest is checked first; only bytes that match the peer-declared
/// SHA-256 are decoded. Decoding uses a 64 px thumbnail so a decompression
/// bomb cannot allocate full-resolution pixels.
enum CloudSyncAssetValidation {
    static let maxPixelCount = 120_000_000
    static let thumbnailMaxPixelSize = 64

    static func validate(
        data: Data,
        reference: SyncAssetReference
    ) throws -> CloudSyncValidatedAsset {
        guard reference.isValid else {
            throw CloudSyncAssetValidationError.unreadableImage
        }
        guard data.count == reference.byteCount else {
            throw CloudSyncAssetValidationError.byteCountMismatch
        }
        guard reference.contentSHA256.matches(data) else {
            throw CloudSyncAssetValidationError.digestMismatch
        }
        guard !data.isEmpty else {
            throw CloudSyncAssetValidationError.unreadableImage
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw CloudSyncAssetValidationError.unreadableImage
        }
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw CloudSyncAssetValidationError.unreadableImage
        }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image)
        else {
            throw CloudSyncAssetValidationError.unsupportedImageType
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
            throw CloudSyncAssetValidationError.unreadableImage
        }
        guard width <= SyncProtocolValidation.maxDimension,
              height <= SyncProtocolValidation.maxDimension,
              width <= Int.max / height,
              width * height <= maxPixelCount
        else {
            throw CloudSyncAssetValidationError.dimensionsOutOfBounds
        }
        if let declaredWidth = reference.pixelWidth,
           let declaredHeight = reference.pixelHeight,
           declaredWidth != width || declaredHeight != height {
            throw CloudSyncAssetValidationError.dimensionMismatch
        }
        let detectedMIME = type.preferredMIMEType?.lowercased()
        if let declaredMIME = reference.mimeType?.lowercased() {
            let normalizedDeclared = declaredMIME == "image/jpg" ? "image/jpeg" : declaredMIME
            let normalizedDetected = detectedMIME == "image/jpg" ? "image/jpeg" : detectedMIME
            guard normalizedDeclared == normalizedDetected else {
                throw CloudSyncAssetValidationError.mimeTypeMismatch
            }
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) != nil else {
            throw CloudSyncAssetValidationError.unreadableImage
        }
        let fileExtension = type.preferredFilenameExtension
            ?? fallbackExtension(for: typeIdentifier)
            ?? "img"
        return CloudSyncValidatedAsset(
            fileExtension: fileExtension,
            mimeType: detectedMIME,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private static func fallbackExtension(for typeIdentifier: String) -> String? {
        switch typeIdentifier {
        case "public.jpeg":
            return "jpg"
        case "public.png":
            return "png"
        case "public.heic":
            return "heic"
        case "org.webmproject.webp":
            return "webp"
        default:
            return nil
        }
    }
}
