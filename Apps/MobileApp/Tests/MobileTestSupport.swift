import DaybreakCore
import Foundation
@testable import DaybreakMobile

/// Synthetic Bing transport for mobile store tests. No real Bing media,
/// metadata or story text is used.
actor MobileSyntheticTransport: BingHTTPTransport {
    enum Mode: Sendable {
        case success
        case failure
        case cancellation
    }

    private let archive: Data
    private let stories: Data
    private let image: Data
    private var mode: Mode
    private var imageDelay: Duration = .zero
    private var archiveRequestCount = 0
    private var storyRequestCount = 0
    private var imageRequestCount = 0

    init(
        archive: Data,
        stories: Data,
        image: Data,
        mode: Mode = .success
    ) {
        self.archive = archive
        self.stories = stories
        self.image = image
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func setImageDelay(_ delay: Duration) {
        imageDelay = delay
    }

    func counts() -> (archive: Int, stories: Int, images: Int) {
        (archiveRequestCount, storyRequestCount, imageRequestCount)
    }

    func perform(_ request: BingHTTPRequest) async throws -> BingHTTPResponse {
        switch mode {
        case .failure:
            throw BingTransportError.transport(code: nil)
        case .cancellation:
            throw CancellationError()
        case .success:
            break
        }

        let url = request.url
        if url.path.contains("HPImageArchive") {
            archiveRequestCount += 1
            return BingHTTPResponse(
                data: archive,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                finalURL: url
            )
        }
        if url.path.contains("hp/api/model") {
            storyRequestCount += 1
            return BingHTTPResponse(
                data: stories,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                finalURL: url
            )
        }
        if url.host == "www.bing.com", url.path == "/th" {
            imageRequestCount += 1
            if imageDelay > .zero {
                try await Task.sleep(for: imageDelay)
            }
            return BingHTTPResponse(
                data: image,
                statusCode: 200,
                headers: ["Content-Type": "image/png"],
                finalURL: url
            )
        }
        return BingHTTPResponse(
            data: Data(),
            statusCode: 404,
            headers: [:],
            finalURL: url
        )
    }
}

enum MobileSyntheticFixture {
    /// 2026-11-24 12:00 UTC, i.e. 20:00 in the zh-CN market zone.
    static let refreshNow = Date(timeIntervalSince1970: 1_795_521_600)
    static let syntheticPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    static var syntheticPNG: Data {
        Data(base64Encoded: syntheticPNGBase64)!
    }

    static let fernID = WallpaperID(
        source: .bing,
        sourceImageID: "SyntheticFern"
    )
    static let owlID = WallpaperID(
        source: .bing,
        sourceImageID: "SyntheticOwl"
    )

    static func date(_ value: String) -> LocalDate {
        LocalDate(iso8601: value)!
    }

    static var archiveData: Data {
        json([
            "images": [
                [
                    "fullstartdate": "202611221600",
                    "urlbase": "/th?id=OHR.SyntheticFern_ZH-CN123456789_1920x1080",
                    "hsh": "synthetic-fern",
                    "title": "Synthetic fern title",
                    "copyright": "Synthetic fern copyright",
                    "copyrightlink": "https://www.bing.com/search?q=synthetic-fern"
                ],
                [
                    "fullstartdate": "202611231600",
                    "urlbase": "/th?id=OHR.SyntheticOwl_ZH-CN987654321_1920x1080",
                    "hsh": "synthetic-owl",
                    "title": "Synthetic owl title",
                    "copyright": "Synthetic owl copyright",
                    "copyrightlink": "https://www.bing.com/search?q=synthetic-owl"
                ]
            ]
        ])
    }

    static var storyData: Data {
        json([
            "MediaContents": [
                [
                    "Ssd": "20261124",
                    "Market": "ZH-CN",
                    "Hash": "synthetic-owl-story",
                    "Name": "Synthetic media content",
                    "FullDateString": "Synthetic localized date (never parsed)",
                    "ImageContent": [
                        "Title": "Synthetic owl story title",
                        "Headline": "Synthetic owl story headline",
                        "Description": "Synthetic owl story description",
                        "QuickFact": ["MainText": "Synthetic owl quick fact"],
                        "Copyright": "Synthetic owl story copyright",
                        "BackstageUrl": "https://www.bing.com/search?q=synthetic-owl-story",
                        "Image": [
                            "Url": "/th?id=OHR.SyntheticOwl_ZH-CN123456789_1920x1080.jpg",
                            "Wallpaper": "/th?id=OHR.SyntheticOwl_ZH-CN123456789_1920x1080.jpg"
                        ]
                    ]
                ]
            ]
        ])
    }

    static func makeProvider(
        transport: MobileSyntheticTransport,
        now: Date = refreshNow
    ) -> BingProvider {
        BingProvider(
            profile: .zhCN,
            configuration: BingProviderConfiguration(
                maximumAttempts: 1,
                initialRetryDelay: .zero,
                maximumRetryDelay: .zero
            ),
            transport: transport,
            now: { now },
            sleep: { _ in }
        )
    }

    static func makeDataStore(
        directory: URL,
        settingsStore: any MobileSettingsPersisting,
        selectionStore: any MobileSelectionPersisting,
        transport: MobileSyntheticTransport,
        now: Date = refreshNow
    ) -> MobileDataStore {
        let provider = makeProvider(transport: transport, now: now)
        return MobileDataStore(
            directory: directory,
            settingsStore: settingsStore,
            selectionStore: selectionStore,
            now: { now },
            providerFactory: { _ in provider }
        )
    }

    static func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakMobile-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private static func json(_ object: Any) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            preconditionFailure("Synthetic mobile fixture could not be encoded: \(error)")
        }
    }
}

/// A private defaults suite per test; removes its persistent domain on cleanup.
final class MobileTestDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = "dev.daybreak.mobile.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    var settingsStore: UserDefaultsMobileSettingsStore {
        UserDefaultsMobileSettingsStore(defaults: defaults)
    }

    var selectionStore: UserDefaultsMobileSelectionStore {
        UserDefaultsMobileSelectionStore(defaults: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
