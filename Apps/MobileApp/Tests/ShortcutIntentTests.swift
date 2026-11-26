import CoreGraphics
import DaybreakCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DaybreakMobile

@Suite("Shortcuts intent link and identity rules")
struct ShortcutIntentTests {
    @Test("Canonical wallpaper text round-trips")
    func wallpaperReferenceRoundTrip() throws {
        let reference = try #require(DaybreakWallpaperReference(text: "  bing:OHR.Example_2026  "))
        #expect(reference.text == "bing:OHR.Example_2026")
        #expect(reference.wallpaperID == WallpaperID(source: .bing, sourceImageID: "OHR.Example_2026"))
    }

    @Test("Colons inside the image identifier are preserved")
    func wallpaperReferenceAllowsColonInIdentifier() throws {
        let reference = try #require(DaybreakWallpaperReference(text: "bing:album:frame"))
        #expect(reference.wallpaperID.sourceImageID == "album:frame")
    }

    @Test(
        "Malformed wallpaper text is rejected",
        arguments: [
            "",
            "   ",
            "bing",
            "bing:",
            ":image",
            "bing:image\nnext",
            String(repeating: "a", count: 513)
        ]
    )
    func wallpaperReferenceRejectsInvalidText(_ text: String) {
        #expect(DaybreakWallpaperReference(text: text) == nil)
    }

    @Test("Run URL passes the wallpaper ID as text without losing characters")
    func runURLCarriesTextInput() throws {
        let text = "bing:OHR.A+B & C/é"
        let url = try #require(
            DaybreakShortcutURL.runShortcutURL(
                name: DaybreakShortcutName.apply,
                textInput: text
            )
        )
        #expect(url.scheme == "shortcuts")
        #expect(url.host == "run-shortcut")
        #expect(!url.absoluteString.contains("+"))
        #expect(!url.absoluteString.contains(" "))

        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let items = try #require(components.queryItems)
        #expect(items.first(where: { $0.name == "name" })?.value == "Daybreak Apply")
        #expect(items.first(where: { $0.name == "input" })?.value == "text")
        #expect(items.first(where: { $0.name == "text" })?.value == text)
    }

    @Test("Run URL without input omits the text parameters")
    func runURLWithoutInput() throws {
        let url = try #require(
            DaybreakShortcutURL.runShortcutURL(name: DaybreakShortcutName.daily, textInput: nil)
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = Set((components.queryItems ?? []).map(\.name))
        #expect(names == ["name"])
    }

    @Test("No import-shortcut URL is fabricated")
    func noImportURLIsOffered() {
        #expect(DaybreakShortcutURL.openShortcutsApp?.absoluteString == "shortcuts://")
        #expect(DaybreakShortcutURL.runShortcutURL(name: "Daybreak Apply", textInput: "bing:x")?.absoluteString
            .contains("import-shortcut") == false)
    }

    @Test("Published shortcut links are real HTTPS iCloud share pages")
    func publishedShortcutLinksAreICloudSharePages() {
        #expect(DaybreakShortcutShareLink.apply.scheme == "https")
        #expect(DaybreakShortcutShareLink.apply.host == "www.icloud.com")
        #expect(DaybreakShortcutShareLink.apply.path == "/shortcuts/9e944b28935f4b7da8ce9542ca059ef1")

        #expect(DaybreakShortcutShareLink.daily.scheme == "https")
        #expect(DaybreakShortcutShareLink.daily.host == "www.icloud.com")
        #expect(DaybreakShortcutShareLink.daily.path == "/shortcuts/61f30d50e6bb42108c2e6b5c0a23b1e2")
    }

    @Test("Automatic market follows the app preference; explicit markets do not")
    func marketOptionResolution() {
        #expect(DaybreakMarketEntity.automatic.resolved(preferred: .jaJP) == .jaJP)
        #expect(DaybreakMarketEntity(market: .zhCN).resolved(preferred: .jaJP) == .zhCN)
        #expect(DaybreakMarketEntity.automatic.explicitMarket == nil)
    }

    @Test("Every catalog market, including non-primary ones, is selectable")
    func catalogMarketsAreSelectable() async throws {
        let query = DaybreakMarketQuery()
        let entities = try await query.suggestedEntities()
        #expect(entities.count == BingMarketProfile.catalog.count + 1)
        for profile in BingMarketProfile.catalog {
            #expect(entities.contains { $0.explicitMarket == profile.market })
        }

        let germanResults = try await query.entities(for: ["de-DE"])
        let german = try #require(germanResults.first)
        #expect(german.explicitMarket == Market("de-DE"))

        #expect(DaybreakMarketEntity(identifier: "xx-XX") == nil)
        #expect(DaybreakMarketEntity(identifier: "automatic")?.explicitMarket == nil)
    }

    @Test("Every crop output maps to a concrete preset; original has none")
    func outputPresetMapping() {
        #expect(DaybreakWallpaperOutput.original.cropPreset == nil)
        #expect(DaybreakWallpaperOutput.lockScreen.cropPreset == .lockScreen)
        #expect(DaybreakWallpaperOutput.homeScreen.cropPreset == .homeScreen)
        #expect(DaybreakWallpaperOutput.landscape.cropPreset == .landscape)
        #expect(DaybreakWallpaperOutput.padLandscape.cropPreset == .padLandscape)
        #expect(DaybreakWallpaperOutput.duoOuter.cropPreset == .duoOuter)
        #expect(DaybreakWallpaperOutput.duoInnerPortrait.cropPreset == .duoInnerPortrait)
        #expect(DaybreakWallpaperOutput.duoInnerWide.cropPreset == .duoInnerWide)
    }

    @Test("Today and by-ID intents expose a usable output default")
    func intentsDefaultToOriginalOutput() {
        #expect(GetTodayWallpaperIntent().output == .original)
        #expect(GetWallpaperByIDIntent().output == .original)
    }

    @Test("Shortcuts calendar picks keep their displayed day")
    func shortcutsDateUsesCalendarPick() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let pick = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 23, minute: 30))
        )
        let date = try #require(DaybreakCalendarDate.localDate(from: pick, timeZone: timeZone))
        #expect(date == LocalDate(year: 2026, month: 11, day: 25))
    }

    @Test("Errors stay explanatory and never claim a system wallpaper write")
    func errorDescriptionsAreHonest() {
        let errors: [DaybreakShortcutError] = [
            .malformedWallpaperID,
            .unsupportedMarket(Market("de-DE")),
            .todayNotAvailable(market: .zhCN, date: LocalDate(year: 2026, month: 11, day: 25)!),
            .dayNotStored(date: LocalDate(year: 2026, month: 11, day: 25)!, market: .enUS),
            .unknownWallpaper("bing:missing"),
            .noFavorites,
            .noCachedWallpapers,
            .noCurrentSelection,
            .invalidDate,
            .offline("network unreachable"),
            .repositoryBusy,
            .imageUnavailable("corrupt"),
            .originalUnavailable("bing:thumb"),
            .cropUnavailable("encoder missing"),
            .storeUnavailable("locked"),
            .timedOut
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.isEmpty)
            #expect(!text.contains("已设置壁纸"))
            #expect(!text.contains("wallpaper set"))
        }
    }
}

// MARK: - Service pipeline

@Suite("Shortcuts intent service")
struct ShortcutIntentServiceTests {
    private enum StubFailure: Error, Sendable {
        case domain(DaybreakShortcutError)
        case unknown
    }

    private struct StubSource: DaybreakShortcutDataSource {
        let image: DaybreakShortcutImage
        let failure: StubFailure?

        init(image: DaybreakShortcutImage, failure: StubFailure? = nil) {
            self.image = image
            self.failure = failure
        }

        func prepareImage(_ target: DaybreakShortcutTarget) async throws -> DaybreakShortcutImage {
            switch failure {
            case .domain(let error): throw error
            case .unknown: throw StubFailure.unknown
            case nil: return image
            }
        }
    }

    private func marketNoon(_ iso8601: String) -> Date {
        let parts = iso8601.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 4)
        )!
    }

    private func makeImage() throws -> (DaybreakShortcutImage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakIntentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("daybreak-original.png")
        // 1×1 PNG: a real decodable image, so the boundary validation can be
        // tested without depending on Bing or another agent's cache fixture.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: file)
        let image = DaybreakShortcutImage(
            wallpaperID: WallpaperID(source: .bing, sourceImageID: "OHR.Test"),
            fileURL: file,
            mimeType: "image/png",
            fileExtension: "png",
            sourceDate: LocalDate(iso8601: "2026-11-25")!,
            market: .zhCN,
            title: "测试图片",
            sourceURL: URL(string: "https://www.bing.com/"),
            isOriginal: true
        )
        return (image, directory)
    }

    private func makeCropSource() throws -> (DaybreakShortcutImage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakIntentCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("daybreak-crop-source.png")
        let width = 400
        let height = 200
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SyntheticImageFailure.context
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                file as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw SyntheticImageFailure.encode
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticImageFailure.encode
        }
        let image = DaybreakShortcutImage(
            wallpaperID: WallpaperID(source: .bing, sourceImageID: "OHR.CropTest"),
            fileURL: file,
            mimeType: "image/png",
            fileExtension: "png",
            sourceDate: LocalDate(iso8601: "2026-11-25")!,
            market: .zhCN,
            title: "裁切测试",
            sourceURL: URL(string: "https://www.bing.com/"),
            isOriginal: true
        )
        return (image, directory)
    }

    @Test("iPad landscape output exports a real ~4:3 file instead of the original")
    func padLandscapeExport() async throws {
        let (image, directory) = try makeCropSource()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DaybreakShortcutService(dataSource: StubSource(image: image))

        let prepared = try await service.prepare(target: .randomCached, output: .padLandscape)
        defer { try? FileManager.default.removeItem(at: prepared.export.fileURL) }

        #expect(prepared.output == .padLandscape)
        #expect(prepared.export.fileURL != image.fileURL)
        #expect(prepared.export.filename.contains("pad-landscape"))
        #expect(prepared.export.removeOnCompletion)

        let source = try #require(
            CGImageSourceCreateWithURL(prepared.export.fileURL as CFURL, nil)
        )
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        #expect(height > 0)
        #expect(abs(Double(width) / Double(height) - 4.0 / 3.0) < 0.01)
    }

    @Test("Crop exports describe the chosen ratio and never claim a system write")
    func cropDialogIsHonest() throws {
        let prepared = DaybreakPreparedWallpaper(
            image: try makeImage().0,
            output: .padLandscape,
            export: DaybreakShortcutExport(
                fileURL: URL(fileURLWithPath: "/tmp/daybreak-pad.png"),
                filename: "daybreak-pad.png",
                contentType: .png,
                removeOnCompletion: true
            )
        )
        let text = DaybreakShortcutService.live.dialog(for: prepared)
        #expect(text.contains("4:3"))
        #expect(!text.contains("已直接设置"))
    }

    private enum SyntheticImageFailure: Error {
        case context
        case encode
    }

    @Test("Original export points at the store copy and may be removed after the shortcut")
    func originalExport() async throws {
        let (image, directory) = try makeImage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DaybreakShortcutService(dataSource: StubSource(image: image))

        let prepared = try await service.prepare(
            target: .today(market: .zhCN),
            output: .original,
            now: marketNoon("2026-11-25")
        )

        #expect(prepared.export.fileURL == image.fileURL)
        #expect(prepared.export.removeOnCompletion)
        #expect(!service.dialog(for: prepared).isEmpty)
        #expect(!service.dialog(for: prepared).contains("已直接设置"))
    }

    @Test("A thumbnail or preview fallback is never passed off as the original")
    func nonOriginalIsRejected() async throws {
        let (image, directory) = try makeImage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let degraded = DaybreakShortcutImage(
            wallpaperID: image.wallpaperID,
            fileURL: image.fileURL,
            mimeType: image.mimeType,
            fileExtension: image.fileExtension,
            sourceDate: image.sourceDate,
            market: image.market,
            title: image.title,
            sourceURL: image.sourceURL,
            isOriginal: false
        )
        let service = DaybreakShortcutService(dataSource: StubSource(image: degraded))

        do {
            _ = try await service.prepare(
                target: .today(market: .zhCN),
                output: .original,
                now: marketNoon("2026-11-25")
            )
            Issue.record("Expected originalUnavailable")
        } catch let error as DaybreakShortcutError {
            guard case .originalUnavailable = error else {
                Issue.record("Expected originalUnavailable, got \(error)")
                return
            }
        }
    }

    @Test("Today never falls back to an older cached date")
    func staleTodayIsRejected() async throws {
        let (image, directory) = try makeImage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = DaybreakShortcutImage(
            wallpaperID: image.wallpaperID,
            fileURL: image.fileURL,
            mimeType: image.mimeType,
            fileExtension: image.fileExtension,
            sourceDate: LocalDate(iso8601: "2026-11-24")!,
            market: .zhCN,
            title: image.title,
            sourceURL: image.sourceURL,
            isOriginal: true
        )
        let service = DaybreakShortcutService(dataSource: StubSource(image: stale))

        do {
            _ = try await service.prepare(
                target: .today(market: .zhCN),
                output: .original,
                now: marketNoon("2026-11-25")
            )
            Issue.record("Expected todayNotAvailable")
        } catch let error as DaybreakShortcutError {
            guard case .todayNotAvailable(let market, let date) = error else {
                Issue.record("Expected todayNotAvailable, got \(error)")
                return
            }
            #expect(market == .zhCN)
            #expect(date == LocalDate(iso8601: "2026-11-25"))
        }
    }

    @Test("An empty file is rejected instead of being handed to Shortcuts")
    func emptyFileIsRejected() async throws {
        let (image, directory) = try makeImage()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: image.fileURL)
        let service = DaybreakShortcutService(dataSource: StubSource(image: image))

        await #expect(throws: DaybreakShortcutError.self) {
            try await service.prepare(
                target: .today(market: .zhCN),
                output: .original,
                now: marketNoon("2026-11-25")
            )
        }
    }

    @Test("Domain errors pass through unchanged")
    func domainErrorPassesThrough() async throws {
        let (image, directory) = try makeImage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DaybreakShortcutService(
            dataSource: StubSource(image: image, failure: .domain(.noFavorites))
        )

        do {
            _ = try await service.prepare(target: .favorite, output: .original)
            Issue.record("Expected noFavorites")
        } catch let error as DaybreakShortcutError {
            #expect(error == .noFavorites)
        }
    }

    @Test("Unknown errors are reported as repository failures, not fake images")
    func unknownErrorIsWrapped() async throws {
        let (image, directory) = try makeImage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DaybreakShortcutService(
            dataSource: StubSource(image: image, failure: .unknown)
        )

        do {
            _ = try await service.prepare(target: .randomCached, output: .original)
            Issue.record("Expected storeUnavailable")
        } catch let error as DaybreakShortcutError {
            guard case .storeUnavailable = error else {
                Issue.record("Expected storeUnavailable, got \(error)")
                return
            }
        }
    }
}
