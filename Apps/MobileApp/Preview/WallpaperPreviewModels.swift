import DaybreakCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Request

/// Everything the fullscreen preview needs, resolved by the caller.
///
/// The preview deliberately does not query `MobileStore` or
/// `WallpaperRepository`. Today, Timeline and App Intents already resolve
/// media through the single shared store; they pass immutable, readable file
/// URLs here so one preview can never become a second repository writer.
///
/// `displayImageURL` and `originalImageURL` are stable for the lifetime of the
/// request. `originalImageURL` is used for full-resolution export; when it is
/// nil the export falls back to `displayImageURL` and the UI says so rather
/// than pretending the result is the original.
public struct WallpaperPreviewRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayImageURL: URL
    public let originalImageURL: URL?
    public let wallpaperID: WallpaperID?
    public let market: Market?
    public let sourceDate: LocalDate?
    public let title: String?
    public let copyright: String?
    public let sourcePageURL: URL?
    public let initialSettings: WallpaperCropSettings

    public init(
        id: String,
        displayImageURL: URL,
        originalImageURL: URL? = nil,
        wallpaperID: WallpaperID? = nil,
        market: Market? = nil,
        sourceDate: LocalDate? = nil,
        title: String? = nil,
        copyright: String? = nil,
        sourcePageURL: URL? = nil,
        initialSettings: WallpaperCropSettings = .default
    ) {
        self.id = id
        self.displayImageURL = displayImageURL
        self.originalImageURL = originalImageURL
        self.wallpaperID = wallpaperID
        self.market = market
        self.sourceDate = sourceDate
        self.title = title
        self.copyright = copyright
        self.sourcePageURL = sourcePageURL
        self.initialSettings = initialSettings
    }

    /// Builds a request from the authoritative occurrence and its matching
    /// metadata. Metadata from another market/date is ignored.
    public init(
        occurrence: WallpaperOccurrence,
        metadata: WallpaperMetadataRecord?,
        displayImageURL: URL,
        originalImageURL: URL? = nil,
        initialSettings: WallpaperCropSettings = .default
    ) {
        let matchingMetadata = metadata?.key == occurrence.id ? metadata : nil
        self.init(
            id: "\(occurrence.id)-\(occurrence.wallpaperID)",
            displayImageURL: displayImageURL,
            originalImageURL: originalImageURL,
            wallpaperID: occurrence.wallpaperID,
            market: occurrence.market,
            sourceDate: occurrence.localDate,
            title: matchingMetadata?.title,
            copyright: matchingMetadata?.copyright,
            sourcePageURL: matchingMetadata?.sourceURL,
            initialSettings: initialSettings
        )
    }

    /// The URL used for export. Never modifies either input file.
    public var exportSourceURL: URL { originalImageURL ?? displayImageURL }

    /// True when the export will be limited to the cached preview resolution.
    public var exportsAtPreviewResolution: Bool { originalImageURL == nil }
}

// MARK: - Errors

public enum WallpaperPreviewError: Error, Hashable, Sendable, LocalizedError {
    case notAFileURL
    case unreadableFile
    case unsupportedImage
    case imageTooLarge
    case cropFailed
    case encodingUnavailable
    case exportFailed
    case photosPermissionDenied
    case photosUnavailable
    case photosSaveFailed

    public var errorDescription: String? {
        description(in: .current)
    }

    /// Localized for the app-selected interface language rather than only the
    /// system language.
    public func description(in locale: Locale) -> String {
        switch self {
        case .notAFileURL:
            return MobileLocalizedString.resolve("需要已下载到本机的图片文件", locale: locale)
        case .unreadableFile:
            return MobileLocalizedString.resolve("无法读取图片文件", locale: locale)
        case .unsupportedImage:
            return MobileLocalizedString.resolve("图片格式无法解码", locale: locale)
        case .imageTooLarge:
            return MobileLocalizedString.resolve("图片尺寸过大，无法安全导出", locale: locale)
        case .cropFailed:
            return MobileLocalizedString.resolve("裁切失败，原图未修改", locale: locale)
        case .encodingUnavailable:
            return MobileLocalizedString.resolve("没有可用的图片编码格式", locale: locale)
        case .exportFailed:
            return MobileLocalizedString.resolve("导出失败，原图未修改", locale: locale)
        case .photosPermissionDenied:
            return MobileLocalizedString.resolve("没有添加到照片的权限，可在系统设置中允许", locale: locale)
        case .photosUnavailable:
            return MobileLocalizedString.resolve("当前构建未配置照片权限说明", locale: locale)
        case .photosSaveFailed:
            return MobileLocalizedString.resolve("保存到照片失败", locale: locale)
        }
    }
}

// MARK: - Export format

public enum WallpaperExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    /// HEIC when the device supports HEIC encoding, otherwise JPEG.
    case automatic
    case heic
    case jpeg
    case png

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .automatic, .heic: return "heic"
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    public var contentType: UTType {
        switch self {
        case .automatic, .heic: return .heic
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }

    public var isLossy: Bool {
        switch self {
        case .png: return false
        case .automatic, .heic, .jpeg: return true
        }
    }
}

// MARK: - Export result

public struct WallpaperExportResult: Hashable, Sendable {
    public let fileURL: URL
    public let pixelSize: WallpaperPixelSize
    public let format: WallpaperExportFormat
    public let byteCount: Int
    /// Exports live in the app cache. Callers must consume/copy the file
    /// promptly; Daybreak removes stale exports after a bounded interval.
    public let isTemporary: Bool

    public init(
        fileURL: URL,
        pixelSize: WallpaperPixelSize,
        format: WallpaperExportFormat,
        byteCount: Int,
        isTemporary: Bool
    ) {
        self.fileURL = fileURL
        self.pixelSize = pixelSize
        self.format = format
        self.byteCount = byteCount
        self.isTemporary = isTemporary
    }
}
