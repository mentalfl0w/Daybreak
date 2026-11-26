import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Off-main, non-destructive crop exporter.
///
/// The original file is only opened for reading. Export writes a new, uniquely
/// named file in the app cache. ImageIO/CoreGraphics work runs inside this
/// actor, never on the main actor, and every stage checks cooperative
/// cancellation. The exporter never opens a wallpaper repository and never
/// changes system wallpaper.
public actor WallpaperCropExporter {
    public static let shared = WallpaperCropExporter()

    /// Defensive bounds for untrusted or corrupt images.
    private static let maximumSourcePixels = 60_000_000
    private static let maximumSourceLongEdge = 20_000
    private static let exportLifetime: TimeInterval = 24 * 60 * 60
    private static let maximumLongEdgeLimit = 16_384
    private static let exportDirectoryName = "DaybreakExports"

    public init() {}

    public func export(
        originalURL: URL,
        settings: WallpaperCropSettings,
        format: WallpaperExportFormat = .automatic,
        maximumLongEdge: Int = 3_840,
        fileNameHint: String? = nil
    ) async throws -> WallpaperExportResult {
        try Task.checkCancellation()

        guard originalURL.isFileURL else { throw WallpaperPreviewError.notAFileURL }
        guard FileManager.default.isReadableFile(atPath: originalURL.path) else {
            throw WallpaperPreviewError.unreadableFile
        }

        let source = try openImageSource(at: originalURL)
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        try validateSourceSize(sourceProperties, source: source)

        try Task.checkCancellation()

        let decoded = try decodeOrientedImage(from: source)
        try Task.checkCancellation()

        let decodedSize = WallpaperPixelSize(width: decoded.width, height: decoded.height)
        let geometry = WallpaperCropGeometry(sourceSize: decodedSize, settings: settings)
        let cropRect = geometry.pixelCropRect().integral
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = decoded.cropping(to: cropRect) else {
            throw WallpaperPreviewError.cropFailed
        }

        try Task.checkCancellation()

        let boundedEdge = min(
            max(maximumLongEdge, 1),
            Self.maximumLongEdgeLimit
        )
        let outputSize = geometry.outputPixelSize(maximumLongEdge: boundedEdge)
        let resized = try resize(cropped, to: outputSize)

        try Task.checkCancellation()

        let resolvedFormat = try resolve(format)
        let directory = try exportDirectory()
        removeStaleExports(in: directory)

        let stem = exportFileStem(
            hint: fileNameHint,
            settings: settings,
            format: resolvedFormat
        )
        let finalURL = directory
            .appendingPathComponent(stem)
            .appendingPathExtension(resolvedFormat.fileExtension)
        let temporaryURL = directory
            .appendingPathComponent("\(stem)-\(UUID().uuidString)")
            .appendingPathExtension("partial")

        defer {
            // The move removes this file on success; failures and cancellation
            // must not leave a partial export behind.
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        try encode(
            resized,
            format: resolvedFormat,
            to: temporaryURL
        )
        try Task.checkCancellation()

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            throw WallpaperPreviewError.exportFailed
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        return WallpaperExportResult(
            fileURL: finalURL,
            pixelSize: outputSize,
            format: resolvedFormat,
            byteCount: byteCount,
            isTemporary: true
        )
    }

    public func export(
        originalURL: URL,
        preset: WallpaperCropPreset,
        zoom: Double = WallpaperCropGeometry.minimumZoom,
        focalPoint: WallpaperCropFocus = .center,
        format: WallpaperExportFormat = .automatic,
        maximumLongEdge: Int = 3_840,
        fileNameHint: String? = nil
    ) async throws -> WallpaperExportResult {
        try await export(
            originalURL: originalURL,
            settings: WallpaperCropSettings(
                preset: preset,
                zoom: zoom,
                focalPoint: focalPoint
            ),
            format: format,
            maximumLongEdge: maximumLongEdge,
            fileNameHint: fileNameHint
        )
    }

    // MARK: - Source

    private func openImageSource(at url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw WallpaperPreviewError.unreadableFile
        }
        return source
    }

    private func validateSourceSize(
        _ properties: [CFString: Any]?,
        source: CGImageSource
    ) throws {
        guard let properties else { return }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return }
        let pixels = width.multipliedReportingOverflow(by: height)
        if pixels.overflow
            || pixels.partialValue > Self.maximumSourcePixels
            || max(width, height) > Self.maximumSourceLongEdge {
            throw WallpaperPreviewError.imageTooLarge
        }
    }

    private func decodeOrientedImage(from source: CGImageSource) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rawHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let proposed = max(rawWidth, rawHeight)
        let bounded = min(max(proposed, 1), Self.maximumSourceLongEdge)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bounded,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw WallpaperPreviewError.unsupportedImage
        }
        return image
    }

    // MARK: - Crop/resize

    private func resize(_ image: CGImage, to size: WallpaperPixelSize) throws -> CGImage {
        guard size.isValid else { throw WallpaperPreviewError.cropFailed }
        if image.width == size.width, image.height == size.height {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw WallpaperPreviewError.cropFailed
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        )
        guard let result = context.makeImage() else {
            throw WallpaperPreviewError.cropFailed
        }
        return result
    }

    // MARK: - Encoding

    private func resolve(_ requested: WallpaperExportFormat) throws -> WallpaperExportFormat {
        switch requested {
        case .automatic:
            return Self.supportsEncoding(.heic) ? .heic : .jpeg
        case .heic:
            guard Self.supportsEncoding(.heic) else {
                throw WallpaperPreviewError.encodingUnavailable
            }
            return .heic
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }

    private static func supportsEncoding(_ format: WallpaperExportFormat) -> Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
        return identifiers.contains(format.contentType.identifier)
    }

    private func encode(
        _ image: CGImage,
        format: WallpaperExportFormat,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw WallpaperPreviewError.encodingUnavailable
        }

        let options: [CFString: Any]
        if format.isLossy {
            options = [kCGImageDestinationLossyCompressionQuality: 0.95]
        } else {
            options = [:]
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WallpaperPreviewError.exportFailed
        }
    }

    // MARK: - Files

    private func exportDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw WallpaperPreviewError.exportFailed
        }
        let directory = caches
            .appendingPathComponent(Self.exportDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw WallpaperPreviewError.exportFailed
        }
        return directory
    }

    private func removeStaleExports(in directory: URL) {
        let cutoff = Date(timeIntervalSinceNow: -Self.exportLifetime)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            guard modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func exportFileStem(
        hint: String?,
        settings: WallpaperCropSettings,
        format: WallpaperExportFormat
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let sanitizedHint = Self.sanitizedComponent(hint) ?? "wallpaper"
        let unique = UUID().uuidString.prefix(8).lowercased()
        return "Daybreak-\(sanitizedHint)-\(settings.preset.rawValue)-\(formatter.string(from: Date()))-\(unique)"
    }

    private static func sanitizedComponent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        let collapsed = scalars
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(48))
    }
}
