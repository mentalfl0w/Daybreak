import CoreGraphics
import DaybreakCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DaybreakMobile

@Suite("Wallpaper crop exporter")
struct WallpaperCropExporterTests {
    private func syntheticImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.16, green: 0.32, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.72, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw WallpaperPreviewError.encodingUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WallpaperPreviewError.exportFailed
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test("Crop export creates a new file and leaves the original untouched")
    func exportDoesNotModifyOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("original.jpg")
        try writeJPEG(syntheticImage(width: 1_200, height: 800), to: originalURL)
        let originalData = try Data(contentsOf: originalURL)

        let exporter = WallpaperCropExporter()
        let result = try await exporter.export(
            originalURL: originalURL,
            settings: WallpaperCropSettings(preset: .lockScreen),
            format: .jpeg,
            maximumLongEdge: 640,
            fileNameHint: "regression"
        )
        defer { try? FileManager.default.removeItem(at: result.fileURL) }

        let expectedSize = WallpaperCropGeometry(
            sourceSize: WallpaperPixelSize(width: 1_200, height: 800),
            preset: .lockScreen
        ).outputPixelSize(maximumLongEdge: 640)

        #expect(result.fileURL != originalURL)
        #expect(result.format == .jpeg)
        #expect(result.pixelSize == expectedSize)
        #expect(result.pixelSize.height == 640)
        #expect(result.byteCount > 0)
        #expect(result.isTemporary)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(try Data(contentsOf: originalURL) == originalData)

        let outputSource = CGImageSourceCreateWithURL(result.fileURL as CFURL, nil)
        #expect(outputSource != nil)
        #expect(CGImageSourceCreateImageAtIndex(outputSource!, 0, nil)?.width == expectedSize.width)
        #expect(CGImageSourceCreateImageAtIndex(outputSource!, 0, nil)?.height == expectedSize.height)
    }

    @Test("Two exports produce distinct files")
    func exportsUseUniqueFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("original.jpg")
        try writeJPEG(syntheticImage(width: 900, height: 600), to: originalURL)

        let exporter = WallpaperCropExporter()
        let first = try await exporter.export(
            originalURL: originalURL,
            preset: .duoOuter,
            format: .jpeg,
            fileNameHint: "same-hint"
        )
        let second = try await exporter.export(
            originalURL: originalURL,
            preset: .duoOuter,
            format: .jpeg,
            fileNameHint: "same-hint"
        )
        defer {
            try? FileManager.default.removeItem(at: first.fileURL)
            try? FileManager.default.removeItem(at: second.fileURL)
        }

        #expect(first.fileURL != second.fileURL)
        #expect(FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        #expect(abs(Double(first.pixelSize.width) / Double(first.pixelSize.height)
            - WallpaperCropPreset.duoOuter.aspectRatio) < 0.01)
    }

    @Test("Unreadable source throws instead of exporting a placeholder")
    func unreadableSourceThrows() async {
        let exporter = WallpaperCropExporter()
        do {
            _ = try await exporter.export(
                originalURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg"),
                settings: .default
            )
            Issue.record("Expected an unreadable-file error")
        } catch let error as WallpaperPreviewError {
            #expect(error == .unreadableFile)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("Wallpaper preview metadata")
@MainActor
struct WallpaperPreviewMetadataTests {
    @Test("Preview header localizes the Bing market tag with the app language")
    func subtitleLocalizesMarket() throws {
        let date = try #require(LocalDate(year: 2026, month: 11, day: 25))
        let request = WallpaperPreviewRequest(
            id: "zh-CN-2026-11-25",
            displayImageURL: URL(fileURLWithPath: "/tmp/daybreak-preview.jpg"),
            market: Market("zh-CN"),
            sourceDate: date
        )

        let english = try #require(
            WallpaperPreviewView.subtitle(for: request, locale: Locale(identifier: "en"))
        )
        let chinese = try #require(
            WallpaperPreviewView.subtitle(for: request, locale: Locale(identifier: "zh-Hans"))
        )
        let japanese = try #require(
            WallpaperPreviewView.subtitle(for: request, locale: Locale(identifier: "ja"))
        )

        #expect(english.contains(date.iso8601))
        #expect(chinese.contains(date.iso8601))
        #expect(japanese.contains(date.iso8601))
        #expect(!english.contains("zh-CN"))
        #expect(!chinese.contains("zh-CN"))
        #expect(!japanese.contains("zh-CN"))
        #expect(english != chinese)
    }
}
