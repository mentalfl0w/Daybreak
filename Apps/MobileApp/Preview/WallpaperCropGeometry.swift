import CoreGraphics
import Foundation

// MARK: - Pixel size

/// Integer pixel dimensions of a decoded image or an exported crop.
///
/// The type stays platform-neutral so crop geometry can be tested without
/// UIKit, ImageIO or a running photo pipeline.
public struct WallpaperPixelSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool { width > 0 && height > 0 }

    public var aspectRatio: Double {
        guard isValid else { return 1 }
        return Double(width) / Double(height)
    }

    public var longEdge: Int { max(width, height) }

    public var description: String { "\(width)×\(height)" }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        guard width > 0, height > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Wallpaper pixel size must be positive"
            )
        }
        self.init(width: width, height: height)
    }
}

// MARK: - Focus

/// Normalized point in the source image (0...1 on both axes).
///
/// Focus describes the source point that is shown at the centre of the crop,
/// not a screen coordinate. It never stores a device-specific offset, so the
/// same crop settings can survive a fold, a rotation or a second window.
public struct WallpaperCropFocus: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0.5
        self.y = y.isFinite ? y : 0.5
    }

    public static let center = WallpaperCropFocus(x: 0.5, y: 0.5)

    public var isCentered: Bool {
        abs(x - 0.5) < 0.0001 && abs(y - 0.5) < 0.0001
    }

    /// Clamps to the visible unit rectangle without knowing the crop size.
    public func clampedToUnit() -> WallpaperCropFocus {
        WallpaperCropFocus(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }

    public func clamped(xRange: ClosedRange<Double>, yRange: ClosedRange<Double>) -> WallpaperCropFocus {
        WallpaperCropFocus(
            x: min(max(x, xRange.lowerBound), xRange.upperBound),
            y: min(max(y, yRange.lowerBound), yRange.upperBound)
        )
    }
}

// MARK: - Presets

/// Export aspect presets for the compositions Daybreak can actually describe.
///
/// These are export/composition presets, not a promise about how iOS applies
/// system wallpaper. Both lock and home use the current iPhone screen ratio;
/// lock-screen and home-screen system chrome are deliberately never drawn.
///
/// The Duo outer preset follows Apple's published iPhone Duo outer-display
/// geometry: a 5.4-inch, 1398-by-2034-pixel display
/// (<https://www.apple.com/iphone-duo/specs/>), reduced to 233:339. It is an
/// explicit user-chosen composition target, never a device or fold-state
/// probe. The Duo inner portrait/wide presets remain their existing 3:4 and
/// 4:3 composition approximations; they are likewise not detected at runtime.
///
/// The iPad landscape preset is a fixed ~4:3 reference composition. Nothing
/// here detects orientation, device family or fold state; background intents
/// have no reliable window geometry, so callers choose a target explicitly.
public enum WallpaperCropPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case lockScreen = "lock-screen"
    case homeScreen = "home-screen"
    case landscape = "landscape"
    /// iPad landscape reference composition (~4:3). A separate preset from
    /// the Duo inner-wide one on purpose: the same ratio must never imply that
    /// the app detected a foldable device.
    case padLandscape = "pad-landscape"
    case duoOuter = "duo-outer"
    case duoInnerPortrait = "duo-inner-portrait"
    case duoInnerWide = "duo-inner-wide"

    public var id: String { rawValue }

    /// Width divided by height.
    public var aspectRatio: Double {
        switch self {
        case .lockScreen, .homeScreen:
            return 9.0 / 19.5
        case .landscape:
            return 19.5 / 9.0
        case .padLandscape, .duoInnerWide:
            return 4.0 / 3.0
        case .duoOuter:
            // 1398:2034 reduced by 6. Apple publishes the outer display as
            // 1398-by-2034 pixels; the ratio is not a guessed device shape.
            return 233.0 / 339.0
        case .duoInnerPortrait:
            return 3.0 / 4.0
        }
    }

    /// Stable non-localized ratio label used next to the localized name.
    public var ratioLabel: String {
        switch self {
        case .lockScreen, .homeScreen: return "9:19.5"
        case .landscape: return "19.5:9"
        case .padLandscape, .duoInnerWide: return "4:3"
        case .duoOuter: return "233:339"
        case .duoInnerPortrait: return "3:4"
        }
    }
}

// MARK: - Settings

/// Codable crop state carried by preview UI, scene restoration and export.
public struct WallpaperCropSettings: Hashable, Sendable, Codable {
    public var preset: WallpaperCropPreset
    public var zoom: Double
    public var focalPoint: WallpaperCropFocus

    public static let `default` = WallpaperCropSettings(
        preset: .lockScreen,
        zoom: WallpaperCropGeometry.minimumZoom,
        focalPoint: .center
    )

    public init(
        preset: WallpaperCropPreset = .lockScreen,
        zoom: Double = WallpaperCropGeometry.minimumZoom,
        focalPoint: WallpaperCropFocus = .center
    ) {
        self.preset = preset
        self.zoom = WallpaperCropGeometry.clampedZoom(zoom)
        self.focalPoint = focalPoint.clampedToUnit()
    }

    private enum CodingKeys: String, CodingKey {
        case preset
        case zoom
        case focalPoint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preset: try container.decode(WallpaperCropPreset.self, forKey: .preset),
            zoom: try container.decodeIfPresent(Double.self, forKey: .zoom)
                ?? WallpaperCropGeometry.minimumZoom,
            focalPoint: try container.decodeIfPresent(WallpaperCropFocus.self, forKey: .focalPoint)
                ?? .center
        )
    }
}

// MARK: - Geometry

/// Pure crop math shared by the interactive preview and the off-main exporter.
///
/// The geometry never mutates an image. It maps a normalized focus point and a
/// zoom factor to an integer pixel rectangle inside the source image.
public struct WallpaperCropGeometry: Hashable, Sendable, Codable {
    public static let minimumZoom = 1.0
    public static let maximumZoom = 4.0

    public let sourceSize: WallpaperPixelSize
    public private(set) var preset: WallpaperCropPreset
    public private(set) var zoom: Double
    public private(set) var focalPoint: WallpaperCropFocus

    public init(
        sourceSize: WallpaperPixelSize,
        preset: WallpaperCropPreset = .lockScreen,
        zoom: Double = WallpaperCropGeometry.minimumZoom,
        focalPoint: WallpaperCropFocus = .center
    ) {
        self.sourceSize = sourceSize
        self.preset = preset
        self.zoom = Self.clampedZoom(zoom)
        self.focalPoint = .center
        self.focalPoint = clampedFocal(focalPoint)
    }

    public init(sourceSize: WallpaperPixelSize, settings: WallpaperCropSettings) {
        self.init(
            sourceSize: sourceSize,
            preset: settings.preset,
            zoom: settings.zoom,
            focalPoint: settings.focalPoint
        )
    }

    public static func clampedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return minimumZoom }
        return min(max(value, minimumZoom), maximumZoom)
    }

    public var settings: WallpaperCropSettings {
        WallpaperCropSettings(preset: preset, zoom: zoom, focalPoint: focalPoint)
    }

    public var isDefault: Bool {
        preset == .lockScreen && abs(zoom - Self.minimumZoom) < 0.0001 && focalPoint.isCentered
    }

    public var sourceAspectRatio: Double { sourceSize.aspectRatio }

    /// Crop size at zoom 1, normalized to the source image dimensions.
    public var baseCropSize: CGSize {
        guard sourceSize.isValid else { return CGSize(width: 1, height: 1) }
        let target = preset.aspectRatio
        let source = sourceAspectRatio
        if source >= target {
            // Source is wider than the target: full height, narrower width.
            return CGSize(width: min(1, target / source), height: 1)
        }
        // Source is taller than the target: full width, shorter height.
        return CGSize(width: 1, height: min(1, source / target))
    }

    /// Crop size after zoom, still normalized to the source dimensions.
    public var normalizedCropSize: CGSize {
        let base = baseCropSize
        let divisor = max(zoom, Self.minimumZoom)
        return CGSize(
            width: min(1, base.width / divisor),
            height: min(1, base.height / divisor)
        )
    }

    /// Crop rectangle in normalized source coordinates (0...1).
    public func normalizedCropRect() -> CGRect {
        guard sourceSize.isValid else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let size = normalizedCropSize
        let focus = clampedFocal(focalPoint)
        let x = min(max(focus.x - size.width / 2, 0), max(0, 1 - size.width))
        let y = min(max(focus.y - size.height / 2, 0), max(0, 1 - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Crop rectangle in integral source pixels.
    ///
    /// Width and height are rounded independently, so the aspect ratio can
    /// differ by at most one pixel. The rectangle always stays inside the
    /// source image and is never empty.
    public func pixelCropRect() -> CGRect {
        guard sourceSize.isValid else { return .zero }
        let normalized = normalizedCropRect()
        let sourceWidth = Double(sourceSize.width)
        let sourceHeight = Double(sourceSize.height)
        let width = min(sourceWidth, max(1, (normalized.width * sourceWidth).rounded()))
        let height = min(sourceHeight, max(1, (normalized.height * sourceHeight).rounded()))
        let x = min(max((normalized.minX * sourceWidth).rounded(), 0), sourceWidth - width)
        let y = min(max((normalized.minY * sourceHeight).rounded(), 0), sourceHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Pixel size of an export bounded by `maximumLongEdge`.
    ///
    /// The result preserves the crop aspect ratio and never upscales a crop
    /// that is already smaller than the requested bound.
    public func outputPixelSize(maximumLongEdge: Int) -> WallpaperPixelSize {
        let crop = pixelCropRect()
        guard crop.width >= 1, crop.height >= 1 else {
            return WallpaperPixelSize(width: 1, height: 1)
        }
        let limit = max(1, maximumLongEdge)
        let scale = min(1, Double(limit) / max(crop.width, crop.height))
        let width = max(1, min(limit, Int((crop.width * scale).rounded())))
        let height = max(1, min(limit, Int((crop.height * scale).rounded())))
        return WallpaperPixelSize(width: width, height: height)
    }

    public mutating func setZoom(_ value: Double) {
        zoom = Self.clampedZoom(value)
        focalPoint = clampedFocal(focalPoint)
    }

    public mutating func setFocalPoint(_ point: WallpaperCropFocus) {
        focalPoint = clampedFocal(point)
    }

    public mutating func setPreset(_ value: WallpaperCropPreset) {
        preset = value
        focalPoint = clampedFocal(focalPoint)
    }

    /// Applies a drag measured in viewport points from an explicit starting focus.
    ///
    /// Using the start focus (rather than incrementally accumulating) keeps the
    /// gesture idempotent when SwiftUI delivers several changed callbacks for
    /// the same translation.
    public mutating func dragFocalPoint(
        from start: WallpaperCropFocus,
        by translation: CGSize,
        viewportSize: CGSize
    ) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let displayed = displayedImageSize(viewportSize: viewportSize)
        guard displayed.width > 0, displayed.height > 0 else { return }
        let deltaX = -translation.width / displayed.width
        let deltaY = -translation.height / displayed.height
        setFocalPoint(WallpaperCropFocus(x: start.x + deltaX, y: start.y + deltaY))
    }

    /// Size, in viewport points, of the image when it covers the viewport at
    /// the current preset and zoom. Exposed for the SwiftUI drag/pinch layer.
    public func displayedImageSize(viewportSize: CGSize) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0, sourceSize.isValid else {
            return .zero
        }
        let viewportAspect = viewportSize.width / viewportSize.height
        let imageAspect = sourceAspectRatio
        let base: CGSize
        if imageAspect >= viewportAspect {
            base = CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)
        } else {
            base = CGSize(width: viewportSize.width, height: viewportSize.width / imageAspect)
        }
        return CGSize(width: base.width * zoom, height: base.height * zoom)
    }

    public mutating func reset() {
        zoom = Self.minimumZoom
        focalPoint = .center
    }

    // MARK: Focus clamping

    private func clampedFocal(_ point: WallpaperCropFocus) -> WallpaperCropFocus {
        guard sourceSize.isValid else { return .center }
        let size = normalizedCropSize
        let halfWidth = min(0.5, max(0, Double(size.width) / 2))
        let halfHeight = min(0.5, max(0, Double(size.height) / 2))
        let xRange = halfWidth...(1 - halfWidth)
        let yRange = halfHeight...(1 - halfHeight)
        return point.clamped(xRange: xRange, yRange: yRange)
    }
}
