import CoreGraphics
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Wallpaper crop geometry")
struct WallpaperCropGeometryTests {
    private func size(_ width: Int, _ height: Int) -> WallpaperPixelSize {
        WallpaperPixelSize(width: width, height: height)
    }

    @Test("Portrait preset on a landscape source keeps full height and centres")
    func portraitCropFromLandscapeSource() {
        let geometry = WallpaperCropGeometry(
            sourceSize: size(4_000, 2_250),
            preset: .lockScreen
        )
        let rect = geometry.pixelCropRect()

        #expect(rect.height == 2_250)
        #expect(abs(rect.width - 2_250 * 9.0 / 19.5) <= 1)
        #expect(abs(rect.midX - 2_000) <= 1)
        #expect(abs(rect.midY - 1_125) <= 1)
        #expect(rect.minX >= 0)
        #expect(rect.maxX <= 4_000)
    }

    @Test("Landscape preset on a portrait source keeps full width and centres")
    func landscapeCropFromPortraitSource() {
        let geometry = WallpaperCropGeometry(
            sourceSize: size(3_000, 4_000),
            preset: .landscape
        )
        let rect = geometry.pixelCropRect()

        #expect(rect.width == 3_000)
        #expect(abs(rect.height - 3_000 * 9.0 / 19.5) <= 1)
        #expect(abs(rect.midX - 1_500) <= 1)
        #expect(abs(rect.midY - 2_000) <= 1)
        #expect(rect.minY >= 0)
        #expect(rect.maxY <= 4_000)
    }

    @Test("Zoom shrinks the crop around the current focus")
    func zoomShrinksCropAroundFocus() {
        var geometry = WallpaperCropGeometry(
            sourceSize: size(4_000, 2_250),
            preset: .lockScreen
        )
        geometry.setFocalPoint(WallpaperCropFocus(x: 0.62, y: 0.40))
        let base = geometry.pixelCropRect()
        let baseFocus = geometry.focalPoint

        geometry.setZoom(2)
        let zoomed = geometry.pixelCropRect()

        #expect(abs(zoomed.width - base.width / 2) <= 1)
        #expect(abs(zoomed.height - base.height / 2) <= 1)
        #expect(abs(geometry.focalPoint.x - baseFocus.x) < 0.02)
        #expect(abs(geometry.focalPoint.y - baseFocus.y) < 0.02)
        #expect(abs(zoomed.midX - base.midX) <= 1)
        #expect(abs(zoomed.midY - base.midY) <= 1)
    }

    @Test("Focus is clamped so the crop never leaves the source")
    func focusClampingKeepsCropInsideSource() {
        var geometry = WallpaperCropGeometry(
            sourceSize: size(4_000, 2_250),
            preset: .lockScreen
        )
        geometry.setZoom(2.5)

        geometry.setFocalPoint(WallpaperCropFocus(x: -1, y: -1))
        let topLeft = geometry.pixelCropRect()
        #expect(topLeft.minX >= 0)
        #expect(topLeft.minY >= 0)
        #expect(geometry.focalPoint.x >= 0)
        #expect(geometry.focalPoint.y >= 0)

        geometry.setFocalPoint(WallpaperCropFocus(x: 2, y: 2))
        let bottomRight = geometry.pixelCropRect()
        #expect(bottomRight.maxX <= 4_000)
        #expect(bottomRight.maxY <= 2_250)
        #expect(geometry.focalPoint.x <= 1)
        #expect(geometry.focalPoint.y <= 1)
        #expect(bottomRight.width >= 1)
        #expect(bottomRight.height >= 1)
    }

    @Test("Focus maps to the crop centre in source coordinates")
    func focusMapsToCropCentre() {
        var geometry = WallpaperCropGeometry(
            sourceSize: size(4_000, 2_250),
            preset: .lockScreen
        )
        geometry.setZoom(2)
        geometry.setFocalPoint(WallpaperCropFocus(x: 0.35, y: 0.60))
        let rect = geometry.pixelCropRect()

        #expect(abs(rect.midX - 0.35 * 4_000) <= 1)
        #expect(abs(rect.midY - 0.60 * 2_250) <= 1)
    }

    @Test("Dragging left reveals the right side and cannot escape the image")
    func dragDirectionAndClamping() {
        var geometry = WallpaperCropGeometry(
            sourceSize: size(4_000, 3_000),
            preset: .landscape
        )
        // Landscape preset uses the full source width at zoom 1, so zoom in
        // first to give the focal point horizontal freedom.
        geometry.setZoom(2)
        let viewport = CGSize(width: 390, height: 180)
        let before = geometry.focalPoint

        geometry.dragFocalPoint(
            from: before,
            by: CGSize(width: -39, height: 0),
            viewportSize: viewport
        )
        #expect(geometry.focalPoint.x > before.x)
        #expect(geometry.focalPoint.y == before.y)

        geometry.dragFocalPoint(
            from: before,
            by: CGSize(width: 100_000, height: 100_000),
            viewportSize: viewport
        )
        let rect = geometry.pixelCropRect()
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= 4_000)
        #expect(rect.maxY <= 3_000)
    }

    @Test("Drag recomputes from the supplied start focus, not accumulated state")
    func dragUsesExplicitStartFocus() {
        var geometry = WallpaperCropGeometry(
            sourceSize: size(4_000, 3_000),
            preset: .landscape
        )
        geometry.setFocalPoint(WallpaperCropFocus(x: 0.9, y: 0.9))
        geometry.dragFocalPoint(
            from: .center,
            by: .zero,
            viewportSize: CGSize(width: 390, height: 180)
        )
        #expect(abs(geometry.focalPoint.x - 0.5) < 0.001)
        #expect(abs(geometry.focalPoint.y - 0.5) < 0.001)
    }

    @Test("Zoom and decoded settings are clamped to supported bounds")
    func zoomClamping() throws {
        var geometry = WallpaperCropGeometry(
            sourceSize: size(3_000, 4_000),
            preset: .duoInnerWide
        )
        geometry.setZoom(100)
        #expect(geometry.zoom == WallpaperCropGeometry.maximumZoom)
        geometry.setZoom(-4)
        #expect(geometry.zoom == WallpaperCropGeometry.minimumZoom)

        let json = Data(
            #"{"preset":"duo-outer","zoom":99,"focalPoint":{"x":-2,"y":3}}"#.utf8
        )
        let settings = try JSONDecoder().decode(WallpaperCropSettings.self, from: json)
        #expect(settings.preset == .duoOuter)
        #expect(settings.zoom == WallpaperCropGeometry.maximumZoom)
        #expect(settings.focalPoint.x == 0)
        #expect(settings.focalPoint.y == 1)
    }

    @Test("Settings round-trip through Codable unchanged")
    func settingsCodableRoundTrip() throws {
        let original = WallpaperCropSettings(
            preset: .duoInnerPortrait,
            zoom: 2.25,
            focalPoint: WallpaperCropFocus(x: 0.3, y: 0.8)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WallpaperCropSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test("Every preset keeps its aspect ratio within one pixel")
    func presetsPreserveAspectRatio() {
        let sources = [
            size(4_032, 3_024),
            size(3_024, 4_032),
            size(6_000, 4_000),
            size(2_250, 4_000)
        ]
        for preset in WallpaperCropPreset.allCases {
            for source in sources {
                for zoom in [1.0, 1.75, 4.0] {
                    let geometry = WallpaperCropGeometry(
                        sourceSize: source,
                        preset: preset,
                        zoom: zoom
                    )
                    let rect = geometry.pixelCropRect()
                    #expect(rect.width >= 1)
                    #expect(rect.height >= 1)
                    #expect(rect.minX >= 0)
                    #expect(rect.minY >= 0)
                    #expect(rect.maxX <= CGFloat(source.width))
                    #expect(rect.maxY <= CGFloat(source.height))

                    let actual = rect.width / rect.height
                    let expected = preset.aspectRatio
                    // Integer rounding can move the ratio by less than 1%.
                    #expect(abs(actual - expected) / expected < 0.01)
                }
            }
        }
    }

    @Test("Output size caps the long edge and never upscales")
    func outputSizeCapsAndNeverUpscales() {
        let geometry = WallpaperCropGeometry(
            sourceSize: size(6_000, 4_000),
            preset: .landscape
        )
        let crop = geometry.pixelCropRect()
        let capped = geometry.outputPixelSize(maximumLongEdge: 3_840)
        #expect(capped.longEdge <= 3_840)
        #expect(capped.width <= Int(crop.width))
        #expect(capped.height <= Int(crop.height))
        #expect(abs(Double(capped.width) / Double(capped.height)
            - Double(crop.width) / Double(crop.height)) < 0.01)

        let small = WallpaperCropGeometry(
            sourceSize: size(800, 600),
            preset: .lockScreen
        )
        let smallCrop = small.pixelCropRect()
        let uncapped = small.outputPixelSize(maximumLongEdge: 3_840)
        #expect(uncapped.width == Int(smallCrop.width))
        #expect(uncapped.height == Int(smallCrop.height))
    }

    @Test("Invalid source dimensions are handled without crashing")
    func invalidSourceIsSafe() {
        let geometry = WallpaperCropGeometry(sourceSize: size(0, 0))
        #expect(geometry.pixelCropRect() == .zero)
        #expect(geometry.outputPixelSize(maximumLongEdge: 3_840) == size(1, 1))
        #expect(geometry.normalizedCropRect() == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("Preset ratios are distinct where the product needs them to be")
    func presetRatios() {
        #expect(abs(WallpaperCropPreset.lockScreen.aspectRatio - 9.0 / 19.5) < 0.0001)
        #expect(abs(WallpaperCropPreset.landscape.aspectRatio - 19.5 / 9.0) < 0.0001)
        #expect(abs(WallpaperCropPreset.padLandscape.aspectRatio - 4.0 / 3.0) < 0.0001)
        #expect(WallpaperCropPreset.padLandscape.rawValue != WallpaperCropPreset.duoInnerWide.rawValue)
        #expect(WallpaperCropPreset.lockScreen.aspectRatio == WallpaperCropPreset.homeScreen.aspectRatio)
        // Apple describes the iPhone Duo outer display as wider and shorter
        // than a typical iPhone display; the old 9:21 preset was narrower.
        #expect(WallpaperCropPreset.duoOuter.aspectRatio > WallpaperCropPreset.lockScreen.aspectRatio)
        #expect(WallpaperCropPreset.duoOuter.aspectRatio < 1)
        #expect(WallpaperCropPreset.duoInnerPortrait.aspectRatio < 1)
        #expect(WallpaperCropPreset.duoInnerWide.aspectRatio > 1)
    }

    @Test("Duo outer preset follows Apple's published display resolution")
    func duoOuterPublishedRatio() {
        let preset = WallpaperCropPreset.duoOuter
        // Apple publishes the iPhone Duo outer display as 1398-by-2034 pixels:
        // https://www.apple.com/iphone-duo/specs/
        #expect(abs(preset.aspectRatio - 1398.0 / 2034.0) < 0.000_001)
        #expect(abs(preset.aspectRatio - 233.0 / 339.0) < 0.000_001)
        #expect(preset.ratioLabel == "233:339")
    }

    @Test("Default settings are centred at minimum zoom")
    func defaultSettings() {
        let settings = WallpaperCropSettings.default
        #expect(settings.preset == .lockScreen)
        #expect(settings.zoom == WallpaperCropGeometry.minimumZoom)
        #expect(settings.focalPoint.isCentered)
        let geometry = WallpaperCropGeometry(sourceSize: size(1_000, 1_000), settings: settings)
        #expect(geometry.isDefault)
    }
}
