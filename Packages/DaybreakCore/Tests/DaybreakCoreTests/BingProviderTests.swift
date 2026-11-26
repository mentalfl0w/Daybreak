import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DaybreakCore

/// All HTTP payloads, images and story text in this file are synthetic.
/// No real Bing media, story copy or metadata is used.

// MARK: - Scripted transport

private actor ScriptedTransport: BingHTTPTransport {
    enum Step: Sendable {
        case response(BingHTTPResponse)
        case transportFailure(BingTransportError)
        case cancellation
    }

    private var steps: [Step]
    private(set) var requests: [BingHTTPRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func perform(_ request: BingHTTPRequest) async throws -> BingHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else {
            throw BingTransportError.transport(code: nil)
        }
        switch steps.removeFirst() {
        case .response(let response):
            return response
        case .transportFailure(let error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }

    func recordedRequests() -> [BingHTTPRequest] {
        requests
    }

    func remainingStepCount() -> Int {
        steps.count
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    func record(_ duration: Duration) {
        lock.lock()
        values.append(duration)
        lock.unlock()
    }

    var recorded: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

// MARK: - Fixtures

private enum BingFixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let archiveURL = URL(string: "https://www.bing.com/HPImageArchive.aspx")!
    static let storyURL = URL(string: "https://www.bing.com/hp/api/model")!
    static let syntheticCopyrightLink = "https://www.bing.com/search?q=synthetic"

    static func archiveImage(
        fullStart: String? = "202611221600",
        startDate: String? = "20261122",
        endDate: String? = "20261123",
        urlbase: String? = "/th?id=OHR.SyntheticFern_ZH-CN123456789_1920x1080",
        url: String? = "/th?id=OHR.SyntheticFern_ZH-CN123456789_1920x1080&rf=synthetic&pid=hp",
        hash: String? = "abc123def",
        title: String? = "Synthetic title",
        copyright: String? = "Synthetic copyright",
        copyrightLink: String? = syntheticCopyrightLink
    ) -> [String: Any] {
        var object: [String: Any] = [:]
        if let fullStart { object["fullstartdate"] = fullStart }
        if let startDate { object["startdate"] = startDate }
        if let endDate { object["enddate"] = endDate }
        if let urlbase { object["urlbase"] = urlbase }
        if let url { object["url"] = url }
        if let hash { object["hsh"] = hash }
        if let title { object["title"] = title }
        if let copyright { object["copyright"] = copyright }
        if let copyrightLink { object["copyrightlink"] = copyrightLink }
        return object
    }

    static func storyEntry(
        market: String? = "ZH-CN",
        ssd: String = "20261123",
        hash: String? = "abc123def",
        imageMarket: String = "ZH-CN",
        slug: String? = "SyntheticFern",
        includeImageContent: Bool = true,
        title: Any? = "Synthetic title",
        headline: Any? = "Synthetic headline",
        description: Any? = "Synthetic description",
        quickFact: Any? = "Synthetic quick fact",
        copyright: Any? = "Synthetic copyright",
        backstage: Any? = syntheticCopyrightLink
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "Ssd": ssd,
            "Name": "Synthetic media content",
            "FullDateString": "Synthetic localized date (never parsed)"
        ]
        if let market { entry["Market"] = market }
        if let hash { entry["Hash"] = hash }

        guard includeImageContent else { return entry }

        var content: [String: Any] = [:]
        if let title { content["Title"] = title }
        if let headline { content["Headline"] = headline }
        if let description { content["Description"] = description }
        if let copyright { content["Copyright"] = copyright }
        if let quickFact { content["QuickFact"] = ["MainText": quickFact] }
        if let backstage { content["BackstageUrl"] = backstage }

        var image: [String: Any] = [:]
        if let slug {
            image["Url"] = "/th?id=OHR.\(slug)_\(imageMarket)123456789_1920x1080.jpg"
            image["Wallpaper"] = "/th?id=OHR.\(slug)_\(imageMarket)123456789_1920x1080.jpg"
        } else {
            image["Url"] = "/th?id=SyntheticImage_\(imageMarket)123456_1920x1080.jpg"
            image["Wallpaper"] = "/th?id=SyntheticImage_\(imageMarket)123456_1920x1080.jpg"
        }
        content["Image"] = image
        entry["ImageContent"] = content
        return entry
    }

    static func archiveBody(_ images: [[String: Any]]) -> Data {
        json(["images": images])
    }

    static func storyBody(
        _ contents: [[String: Any]],
        preload: [[String: Any]] = []
    ) -> Data {
        json(["MediaContents": contents, "PreloadMediaContents": preload])
    }

    static func json(_ object: Any) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            preconditionFailure("Synthetic JSON fixture could not be encoded: \(error)")
        }
    }

    static func response(
        _ data: Data,
        status: Int = 200,
        contentType: String? = "application/json; charset=utf-8",
        url: URL,
        headers: [String: String] = [:]
    ) -> BingHTTPResponse {
        var all = headers
        if let contentType {
            all["Content-Type"] = contentType
        }
        return BingHTTPResponse(
            data: data,
            statusCode: status,
            headers: all,
            finalURL: url
        )
    }

    static func successArchive(_ images: [[String: Any]] = [archiveImage()]) -> BingHTTPResponse {
        response(archiveBody(images), url: archiveURL)
    }

    static func successStory(
        _ contents: [[String: Any]],
        preload: [[String: Any]] = []
    ) -> BingHTTPResponse {
        response(storyBody(contents, preload: preload), url: storyURL)
    }

    static func png(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("Synthetic CGContext could not be created")
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            preconditionFailure("Synthetic CGImage could not be created")
        }
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            preconditionFailure("Synthetic CGImageDestination could not be created")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            preconditionFailure("Synthetic PNG could not be finalized")
        }
        return mutable as Data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Suite

@Suite("BingProvider synthetic transport")
struct BingProviderTests {
    private func makeProvider(
        transport: ScriptedTransport,
        profile: BingMarketProfile = .zhCN,
        configuration: BingProviderConfiguration = BingProviderConfiguration(
            maximumAttempts: 1,
            initialRetryDelay: .zero,
            maximumRetryDelay: .zero
        ),
        sleepRecorder: SleepRecorder? = nil
    ) -> BingProvider {
        BingProvider(
            profile: profile,
            configuration: configuration,
            transport: transport,
            now: { BingFixture.fetchedAt },
            sleep: { duration in
                sleepRecorder?.record(duration)
            }
        )
    }

    private func thrownError<T>(_ operation: () async throws -> T) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Archive

    @Test("Archive converts the UTC publisher instant to the market-local date")
    func archiveMarketLocalDate() async throws {
        let transport = ScriptedTransport([.response(BingFixture.successArchive())])
        let provider = makeProvider(transport: transport)

        let snapshot = try await provider.fetchArchive()
        #expect(snapshot.entries.count == 1)
        let entry = try #require(snapshot.entries.first)
        #expect(entry.occurrence.localDate.iso8601 == "2026-11-23")
        #expect(entry.occurrence.market == .zhCN)
        #expect(entry.occurrence.wallpaperID.sourceImageID == "SyntheticFern")
        #expect(entry.metadata.title == "Synthetic title")
        #expect(entry.metadata.copyright == "Synthetic copyright")
        #expect(entry.metadata.sourceURL == URL(string: BingFixture.syntheticCopyrightLink))
        #expect(entry.metadata.originalLocale == "zh-Hans")
        #expect(entry.identityEvidence == .imageURLSlug)
        #expect(entry.imageCandidates.map(\.kind) == [
            .ultraHighResolution, .provided, .fullHD, .compact
        ])
        #expect(entry.imageCandidates[0].url.absoluteString.contains("_UHD.jpg"))
        #expect(entry.imageCandidates[2].url.absoluteString.contains("_1920x1080.jpg"))
        #expect(entry.metadata.variants.count == entry.imageCandidates.count)
        #expect(entry.metadata.variants.allSatisfy { $0.kind == .original })
        #expect(snapshot.wallpapers.count == 1)

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "mkt" })?.value == "zh-CN")
        #expect(components.queryItems?.first(where: { $0.name == "n" })?.value == "8")
        #expect(request.headers["Accept-Language"] == "zh-CN")
        #expect(request.headers["Accept"] == "application/json")
    }

    @Test("An expanded market sends its own tag and uses its declared zone")
    func expandedMarketArchive() async throws {
        let profile = try #require(BingMarketProfile.profile(for: Market("DE-de")))
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    fullStart: "202611222300",
                    startDate: "20261122",
                    endDate: "20261123",
                    urlbase: "/th?id=OHR.SyntheticFern_DE-DE123456789_1920x1080",
                    url: "/th?id=OHR.SyntheticFern_DE-DE123456789_1920x1080&rf=synthetic&pid=hp"
                )
            ]))
        ])
        let provider = makeProvider(transport: transport, profile: profile)

        let snapshot = try await provider.fetchArchive()
        let entry = try #require(snapshot.entries.first)
        #expect(entry.occurrence.market == Market("de-DE"))
        // 23:00 UTC is already the next day in Berlin and still the previous
        // day in Los Angeles, so this asserts the profile zone rather than UTC.
        #expect(entry.occurrence.localDate.iso8601 == "2026-11-23")
        #expect(entry.metadata.originalLocale == "de-DE")

        let requests = await transport.recordedRequests()
        let request = try #require(requests.first)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "mkt" })?.value == "de-DE")
        #expect(request.headers["Accept-Language"] == "de-DE")
    }

    @Test("A row-fallback archive row claims no locale and no placeholder title")
    func rowFallbackLocaleAndPlaceholderTitle() async throws {
        // Bing serves its global edition when a market has no localized
        // content: no OHR market marker, the literal title "Info" and English
        // copyright. The real copyright and identity must be kept, but the
        // response must not be labelled with the requested locale and "Info"
        // must not stand in for a title.
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    urlbase: "/th?id=OHR.SyntheticRow_ROW123456789_1920x1080",
                    url: "/th?id=OHR.SyntheticRow_ROW123456789_1920x1080&rf=synthetic&pid=hp",
                    title: "Info",
                    copyright: "Synthetic global copyright"
                )
            ]))
        ])
        let provider = makeProvider(transport: transport, profile: .zhCN)

        let snapshot = try await provider.fetchArchive()
        let entry = try #require(snapshot.entries.first)
        #expect(entry.occurrence.localDate.iso8601 == "2026-11-23")
        #expect(entry.occurrence.wallpaperID.sourceImageID == "SyntheticRow")
        #expect(entry.metadata.originalLocale == WallpaperMetadataRecord.undeterminedLocale)
        #expect(entry.metadata.title == nil)
        #expect(entry.metadata.copyright == "Synthetic global copyright")
        #expect(snapshot.wallpapers.first?.canonicalTitle == nil)
        #expect(entry.occurrence.isValid)
    }

    @Test("A verified market marker keeps the request locale and a real title")
    func verifiedMarkerKeepsLocaleAndRealTitle() async throws {
        // Only the exact "Info" placeholder is dropped; a genuine title that
        // merely contains the word survives, and a matching URL marker still
        // supports the requested locale as provenance.
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(title: "Information desk")
            ]))
        ])
        let provider = makeProvider(transport: transport, profile: .zhCN)

        let snapshot = try await provider.fetchArchive()
        let entry = try #require(snapshot.entries.first)
        #expect(entry.metadata.originalLocale == "zh-Hans")
        #expect(entry.metadata.title == "Information desk")
    }

    @Test("Cross-year dates use the explicit market time zone")
    func crossYearBoundary() async throws {
        let zhTransport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    fullStart: "202612311600",
                    startDate: "20261231",
                    urlbase: "/th?id=OHR.SyntheticFern_ZH-CN123456789_1920x1080"
                )
            ]))
        ])
        let zhProvider = makeProvider(transport: zhTransport, profile: .zhCN)
        let zhSnapshot = try await zhProvider.fetchArchive()
        #expect(zhSnapshot.entries.first?.occurrence.localDate.iso8601 == "2027-01-01")

        let usTransport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    fullStart: "202701010800",
                    startDate: "20261231",
                    urlbase: "/th?id=OHR.SyntheticFern_EN-US987654321_1920x1080",
                    url: "/th?id=OHR.SyntheticFern_EN-US987654321_1920x1080"
                )
            ]))
        ])
        let usProvider = makeProvider(transport: usTransport, profile: .enUS)
        let usSnapshot = try await usProvider.fetchArchive()
        #expect(usSnapshot.entries.first?.occurrence.localDate.iso8601 == "2027-01-01")
    }

    @Test("Impossible calendar dates are rejected instead of normalized")
    func invalidCalendarDateRejected() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(fullStart: "202602300000")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let rawError = await thrownError { try await provider.fetchArchive() }
        let error = try #require(rawError as? BingProviderError)
        guard case .noUsableEntries(let diagnostics) = error else {
            Issue.record("Expected noUsableEntries, got \(error)")
            return
        }
        #expect(diagnostics.contains { $0.code == .recordRejected })
    }

    @Test("Archive market marker must match the requested market")
    func archiveMarketMarkerMismatch() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    urlbase: "/th?id=OHR.SyntheticFern_EN-US123456789_1920x1080",
                    url: "/th?id=OHR.SyntheticFern_EN-US123456789_1920x1080"
                )
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let rawError = await thrownError { try await provider.fetchArchive() }
        let error = try #require(rawError as? BingProviderError)
        guard case .noUsableEntries(let diagnostics) = error else {
            Issue.record("Expected noUsableEntries, got \(error)")
            return
        }
        #expect(diagnostics.contains { $0.code == .imageMarketMarkerMismatch })
    }

    @Test("Archive rejects a non-JSON content type")
    func archiveRejectsHTML() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.response(
                BingFixture.archiveBody([BingFixture.archiveImage()]),
                contentType: "text/html",
                url: BingFixture.archiveURL
            ))
        ])
        let provider = makeProvider(transport: transport)
        let rawError = await thrownError { try await provider.fetchArchive() }
        let error = try #require(rawError as? BingProviderError)
        guard case .unexpectedContentType(let type) = error else {
            Issue.record("Expected unexpectedContentType, got \(error)")
            return
        }
        #expect(type == "text/html")
    }

    @Test("Archive rejects responses over the configured byte bound")
    func archiveRejectsOversizedResponse() async throws {
        let configuration = BingProviderConfiguration(
            maximumMetadataBytes: 65_536,
            maximumAttempts: 1,
            initialRetryDelay: .zero,
            maximumRetryDelay: .zero
        )
        let transport = ScriptedTransport([
            .response(BingFixture.response(
                Data(repeating: 0x7B, count: 70_000),
                url: BingFixture.archiveURL
            ))
        ])
        let provider = makeProvider(transport: transport, configuration: configuration)
        let rawError = await thrownError { try await provider.fetchArchive() }
        let error = try #require(rawError as? BingProviderError)
        guard case .responseTooLarge(let limit) = error else {
            Issue.record("Expected responseTooLarge, got \(error)")
            return
        }
        #expect(limit == 65_536)
    }

    @Test("Archive rejects a final URL outside the HTTPS host allowlist")
    func archiveRejectsDisallowedFinalURL() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.response(
                BingFixture.archiveBody([BingFixture.archiveImage()]),
                url: URL(string: "https://evil.example/HPImageArchive.aspx")!
            ))
        ])
        let provider = makeProvider(transport: transport)
        let rawError = await thrownError { try await provider.fetchArchive() }
        let error = try #require(rawError as? BingProviderError)
        guard case .blockedURL(let host) = error else {
            Issue.record("Expected blockedURL, got \(error)")
            return
        }
        #expect(host == "evil.example")
    }

    @Test("Archive retries bounded transient failures and then succeeds")
    func archiveRetriesTransientFailures() async throws {
        let recorder = SleepRecorder()
        let transport = ScriptedTransport([
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL)),
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL)),
            .response(BingFixture.successArchive())
        ])
        let configuration = BingProviderConfiguration(
            maximumAttempts: 3,
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(2)
        )
        let provider = makeProvider(
            transport: transport,
            configuration: configuration,
            sleepRecorder: recorder
        )

        let snapshot = try await provider.fetchArchive()
        #expect(snapshot.entries.count == 1)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
        #expect(recorder.recorded.count == 2)
    }

    @Test("Retry exhaustion is bounded and observable")
    func archiveRetryExhaustion() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL)),
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL)),
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL))
        ])
        let configuration = BingProviderConfiguration(
            maximumAttempts: 3,
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(2)
        )
        let provider = makeProvider(transport: transport, configuration: configuration)

        let rawError = await thrownError { try await provider.fetchArchive() }
        let error = try #require(rawError as? BingProviderError)
        guard case .httpStatus(let code, _) = error else {
            Issue.record("Expected httpStatus, got \(error)")
            return
        }
        #expect(code == 503)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
    }

    @Test("Retry-After is honored and clamped by configuration")
    func retryAfterHeader() async throws {
        let recorder = SleepRecorder()
        let transport = ScriptedTransport([
            .response(BingFixture.response(
                Data(),
                status: 429,
                url: BingFixture.archiveURL,
                headers: ["Retry-After": "2"]
            )),
            .response(BingFixture.successArchive())
        ])
        let configuration = BingProviderConfiguration(
            maximumAttempts: 2,
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .seconds(4)
        )
        let provider = makeProvider(
            transport: transport,
            configuration: configuration,
            sleepRecorder: recorder
        )

        _ = try await provider.fetchArchive()
        #expect(recorder.recorded == [.seconds(2)])
    }

    @Test("Cancellation from transport and retry sleep is never swallowed")
    func cancellationPropagates() async throws {
        let transport = ScriptedTransport([.cancellation])
        let provider = makeProvider(transport: transport)
        let rawError = await thrownError { try await provider.fetchArchive() }
        #expect((rawError as? CancellationError) != nil)

        let sleepTransport = ScriptedTransport([
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL))
        ])
        let configuration = BingProviderConfiguration(
            maximumAttempts: 3,
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(2)
        )
        let sleepingProvider = BingProvider(
            profile: .zhCN,
            configuration: configuration,
            transport: sleepTransport,
            now: { BingFixture.fetchedAt },
            sleep: { _ in throw CancellationError() }
        )
        let sleepError = await thrownError { try await sleepingProvider.fetchArchive() }
        #expect((sleepError as? CancellationError) != nil)
    }

    @Test("Repeated market/date adds a revision and a diagnostic")
    func duplicateOccurrenceRevisions() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    urlbase: "/th?id=OHR.SyntheticFern_ZH-CN111111_1920x1080",
                    url: "/th?id=OHR.SyntheticFern_ZH-CN111111_1920x1080"
                ),
                BingFixture.archiveImage(
                    urlbase: "/th?id=OHR.SyntheticMoss_ZH-CN222222_1920x1080",
                    url: "/th?id=OHR.SyntheticMoss_ZH-CN222222_1920x1080"
                )
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchArchive()
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries.map(\.occurrence.revision) == [0, 1])
        #expect(snapshot.diagnostics.contains { $0.code == .duplicateOccurrence })
    }

    // MARK: Stories

    @Test("Story fields, identity and provenance are kept separate")
    func storyFieldsAndProvenance() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory(
                [BingFixture.storyEntry()],
                preload: [BingFixture.storyEntry(ssd: "20261124", title: "Synthetic preload")]
            ))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()

        #expect(snapshot.records.count == 1)
        #expect(snapshot.ignoredPreloadCount == 1)
        #expect(snapshot.responseMarkets == ["ZH-CN"])
        let record = try #require(snapshot.records.first)
        #expect(record.market == .zhCN)
        #expect(record.date.iso8601 == "2026-11-23")
        #expect(record.associatedWallpaperID?.sourceImageID == "SyntheticFern")
        #expect(record.title == "Synthetic title")
        #expect(record.headline == "Synthetic headline")
        #expect(record.body == "Synthetic description")
        #expect(record.quickFact == "Synthetic quick fact")
        #expect(record.copyright == "Synthetic copyright")
        #expect(record.sourceURL == URL(string: BingFixture.syntheticCopyrightLink))
        #expect(record.originalLocale == "zh-Hans")
        #expect(record.availability == .available)
        #expect(record.sourceFields.contains("MediaContents[].ImageContent.Title"))
        #expect(record.sourceFields.contains("MediaContents[].ImageContent.Headline"))
        #expect(record.sourceFields.contains("MediaContents[].ImageContent.Description"))
        #expect(record.sourceFields.contains("MediaContents[].ImageContent.QuickFact.MainText"))
        #expect(record.contentHash?.hasPrefix("sha256:") == true)
    }

    @Test("Copyright alone never becomes a story body")
    func storyCopyrightOnlyIsUnavailable() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(
                    title: "Synthetic title",
                    headline: nil,
                    description: nil,
                    quickFact: nil,
                    copyright: "Synthetic copyright"
                )
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()
        let record = try #require(snapshot.records.first)
        #expect(record.title == "Synthetic title")
        #expect(record.headline == nil)
        #expect(record.body == nil)
        #expect(record.quickFact == nil)
        #expect(record.copyright == "Synthetic copyright")
        #expect(record.availability == .unavailable(.emptyContent))
        #expect(snapshot.diagnostics.contains { $0.code == .emptyStoryContent })
    }

    @Test("A response for another market becomes an explicit unavailable record")
    func storyMarketMismatchBecomesLocaleUnavailable() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(market: "EN-US", imageMarket: "ZH-CN")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()

        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(record.market == .zhCN)
        #expect(record.date.iso8601 == "2026-11-23")
        #expect(record.associatedWallpaperID == nil)
        #expect(record.title == nil)
        #expect(record.headline == nil)
        #expect(record.body == nil)
        #expect(record.availability == .unavailable(.localeMismatch))
        #expect(snapshot.responseMarkets == ["EN-US"])
        #expect(snapshot.diagnostics.contains { $0.code == .responseMarketMismatch })
    }

    @Test("An expanded market never labels substituted story text as its own locale")
    func expandedMarketStoryFallback() async throws {
        let profile = try #require(BingMarketProfile.profile(for: Market("de-DE")))
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(market: "EN-US", imageMarket: "EN-US")
            ]))
        ])
        let provider = makeProvider(transport: transport, profile: profile)
        let snapshot = try await provider.fetchStories()

        let record = try #require(snapshot.records.first)
        #expect(record.market == Market("de-DE"))
        #expect(record.availability == .unavailable(.localeMismatch))
        #expect(record.originalLocale == "EN-US")
        #expect(record.body == nil)
        #expect(snapshot.responseMarkets == ["EN-US"])
        #expect(snapshot.diagnostics.contains { $0.code == .responseMarketMismatch })
    }

    @Test("A missing response market is not assumed to be the requested market")
    func storyMissingMarket() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(market: nil, imageMarket: "ZH-CN")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()
        let record = try #require(snapshot.records.first)
        #expect(record.availability == .unavailable(.localeMismatch))
        #expect(record.associatedWallpaperID == nil)
        #expect(snapshot.diagnostics.contains { $0.code == .responseMarketMissing })
    }

    @Test("An image URL market marker conflicting with the Market field is rejected")
    func storyImageMarkerMismatch() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(market: "ZH-CN", imageMarket: "EN-US")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()
        let record = try #require(snapshot.records.first)
        #expect(record.availability == .unavailable(.localeMismatch))
        #expect(record.associatedWallpaperID == nil)
        #expect(snapshot.diagnostics.contains { $0.code == .imageMarketMarkerMismatch })
    }

    @Test("Impossible story dates are rejected without adjacent-date fallback")
    func storyInvalidDate() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(ssd: "20260230")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()
        #expect(snapshot.records.isEmpty)
        #expect(snapshot.diagnostics.contains { $0.code == .recordRejected })
    }

    @Test("One unexpected field type does not discard the rest of the story")
    func storyToleratesPerFieldTypeChanges() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(
                    title: 42,
                    headline: "Synthetic headline",
                    description: NSNull()
                )
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()
        let record = try #require(snapshot.records.first)
        #expect(record.title == nil)
        #expect(record.headline == "Synthetic headline")
        #expect(record.body == nil)
        #expect(record.availability == .available)
    }

    @Test("Disallowed BackstageUrl is dropped but story text survives")
    func storyDisallowedSourceURL() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successStory([
                BingFixture.storyEntry(backstage: "https://evil.example/story")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchStories()
        let record = try #require(snapshot.records.first)
        #expect(record.body == "Synthetic description")
        #expect(record.sourceURL == nil)
        #expect(snapshot.diagnostics.contains { $0.code == .invalidSourceURL })
    }

    // MARK: Images

    @Test("High-resolution failure falls back to the next allowed candidate")
    func imageResolutionFallback() async throws {
        let archiveTransport = ScriptedTransport([.response(BingFixture.successArchive())])
        let archiveProvider = makeProvider(transport: archiveTransport)
        let archive = try await archiveProvider.fetchArchive()
        let entry = try #require(archive.entries.first)
        let candidates = entry.imageCandidates
        #expect(candidates.count >= 4)

        let png = BingFixture.png(width: 64, height: 36)
        let imageTransport = ScriptedTransport([
            .response(BingFixture.response(
                Data(),
                status: 404,
                contentType: "text/plain",
                url: candidates[0].url
            )),
            .response(BingFixture.response(
                Data(),
                status: 404,
                contentType: "text/plain",
                url: candidates[1].url
            )),
            .response(BingFixture.response(
                png,
                contentType: "image/png",
                url: candidates[2].url
            ))
        ])
        let provider = makeProvider(transport: imageTransport)
        let asset = try await provider.fetchImage(for: entry)

        #expect(asset.resolvedKind == .fullHD)
        #expect(asset.mimeType == "image/png")
        #expect(asset.uti == "public.png")
        #expect(asset.pixelWidth == 64)
        #expect(asset.pixelHeight == 36)
        #expect(asset.data == png)
        #expect(asset.sha256 == BingFixture.sha256(png))
        #expect(asset.requestedURL == candidates[2].url)
        #expect(asset.sourceURL == candidates[2].url)
    }

    @Test("Declared image MIME must agree with ImageIO's detected type")
    func imageMIMEMismatchRejected() async throws {
        let archiveTransport = ScriptedTransport([.response(BingFixture.successArchive())])
        let archiveProvider = makeProvider(transport: archiveTransport)
        let archive = try await archiveProvider.fetchArchive()
        let entry = try #require(archive.entries.first)
        let png = BingFixture.png(width: 64, height: 36)

        let steps: [ScriptedTransport.Step] = entry.imageCandidates.map { candidate in
            .response(BingFixture.response(
                png,
                contentType: "image/jpeg",
                url: candidate.url
            ))
        }
        let imageTransport = ScriptedTransport(steps)
        let provider = makeProvider(transport: imageTransport)
        let rawError = await thrownError { try await provider.fetchImage(for: entry) }
        let error = try #require(rawError as? BingProviderError)
        guard case .allImageCandidatesFailed(_, let failures) = error else {
            Issue.record("Expected allImageCandidatesFailed, got \(error)")
            return
        }
        #expect(failures.count == entry.imageCandidates.count)
        #expect(failures.allSatisfy { $0.reason == .imageMimeRejected })
    }

    @Test("Images over the dimension bound are rejected")
    func imageDimensionsRejected() async throws {
        let archiveTransport = ScriptedTransport([.response(BingFixture.successArchive())])
        let archiveProvider = makeProvider(transport: archiveTransport)
        let archive = try await archiveProvider.fetchArchive()
        let entry = try #require(archive.entries.first)
        let png = BingFixture.png(width: 640, height: 360)

        let configuration = BingProviderConfiguration(
            maximumAttempts: 1,
            initialRetryDelay: .zero,
            maximumRetryDelay: .zero,
            maximumImageDimension: 512
        )
        let steps: [ScriptedTransport.Step] = entry.imageCandidates.map { candidate in
            .response(BingFixture.response(
                png,
                contentType: "image/png",
                url: candidate.url
            ))
        }
        let imageTransport = ScriptedTransport(steps)
        let provider = makeProvider(
            transport: imageTransport,
            configuration: configuration
        )
        let rawError = await thrownError { try await provider.fetchImage(for: entry) }
        let error = try #require(rawError as? BingProviderError)
        guard case .allImageCandidatesFailed(_, let failures) = error else {
            Issue.record("Expected allImageCandidatesFailed, got \(error)")
            return
        }
        #expect(failures.count == entry.imageCandidates.count)
        #expect(failures.allSatisfy { $0.reason == .imageDimensionsRejected })
    }

    @Test("Non-allowlisted image hosts are rejected before any request")
    func imageHostAllowlist() async throws {
        let transport = ScriptedTransport([])
        let provider = makeProvider(transport: transport)
        let wallpaperID = WallpaperID(source: .bing, sourceImageID: "SyntheticImage")
        let candidates = [
            BingImageCandidate(
                url: URL(string: "https://evil.example/image.png")!,
                kind: .ultraHighResolution
            )
        ]
        let rawError = await thrownError {
            try await provider.fetchImage(wallpaperID: wallpaperID, candidates: candidates)
        }
        let error = try #require(rawError as? BingProviderError)
        guard case .allImageCandidatesFailed(_, let failures) = error else {
            Issue.record("Expected allImageCandidatesFailed, got \(error)")
            return
        }
        #expect(failures.count == 1)
        #expect(failures.first?.reason == .blockedURL)
        let requests = await transport.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test("Persisted metadata variants can be fetched with a compact preference")
    func imageFromPersistedMetadata() async throws {
        let archiveTransport = ScriptedTransport([.response(BingFixture.successArchive())])
        let archiveProvider = makeProvider(transport: archiveTransport)
        let archive = try await archiveProvider.fetchArchive()
        let entry = try #require(archive.entries.first)
        let compact = try #require(entry.imageCandidates.first { $0.kind == .compact })
        let png = BingFixture.png(width: 48, height: 27)

        let imageTransport = ScriptedTransport([
            .response(BingFixture.response(png, contentType: "image/png", url: compact.url))
        ])
        let provider = makeProvider(transport: imageTransport)
        let asset = try await provider.fetchImage(
            for: entry.metadata,
            preference: .compact
        )
        #expect(asset.resolvedKind == .compact)
        #expect(asset.pixelWidth == 48)
        let requests = await imageTransport.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url.absoluteString.contains("_1366x768") == true)
    }

    @Test("Image transport cancellation propagates")
    func imageCancellation() async throws {
        let wallpaperID = WallpaperID(source: .bing, sourceImageID: "SyntheticImage")
        let candidate = BingImageCandidate(
            url: URL(string: "https://www.bing.com/th?id=OHR.SyntheticImage_ZH-CN123_1920x1080.jpg")!,
            kind: .fullHD
        )
        let transport = ScriptedTransport([.cancellation])
        let provider = makeProvider(transport: transport)
        let rawError = await thrownError {
            try await provider.fetchImage(wallpaperID: wallpaperID, candidates: [candidate])
        }
        #expect((rawError as? CancellationError) != nil)
    }

    // MARK: Independent daily snapshot and join

    @Test("Exact identity, market and date is the primary join path")
    func dailyJoinUsesImageIdentity() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive()),
            .response(BingFixture.successStory([BingFixture.storyEntry()]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchDailySnapshot()

        #expect(snapshot.isCompleteSuccess)
        #expect(snapshot.joined.count == 1)
        let joined = try #require(snapshot.joined.first)
        let match = try #require(joined.storyMatch)
        guard case .matched(let story, let evidence) = match else {
            Issue.record("Expected a matched story, got \(match)")
            return
        }
        #expect(evidence == .imageIdentityMarketAndDate)
        #expect(story.headline == "Synthetic headline")
    }

    @Test("Adjacent-date stories are never attached to the wrong occurrence")
    func dailyJoinRejectsAdjacentDate() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive()),
            .response(BingFixture.successStory([
                BingFixture.storyEntry(ssd: "20261124")
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchDailySnapshot()
        let joined = try #require(snapshot.joined.first)
        let match = try #require(joined.storyMatch)
        guard case .unmatched(.dateMismatch(let candidateDate)) = match else {
            Issue.record("Expected dateMismatch, got \(match)")
            return
        }
        #expect(candidateDate.iso8601 == "2026-11-24")
        #expect(match.availableStory == nil)
    }

    @Test("A trusted content URL corroborates a story without image identity")
    func dailyJoinUsesSourceURLCorroboration() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive()),
            .response(BingFixture.successStory([
                BingFixture.storyEntry(hash: nil, slug: nil)
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchDailySnapshot()
        let joined = try #require(snapshot.joined.first)
        let match = try #require(joined.storyMatch)
        guard case .matched(let story, let evidence) = match else {
            Issue.record("Expected a matched story, got \(match)")
            return
        }
        #expect(evidence == .sourceURLCorroboration)
        #expect(story.associatedWallpaperID == nil)
        #expect(story.sourceURL == URL(string: BingFixture.syntheticCopyrightLink))
    }

    @Test("Story failure leaves archive data intact as a partial success")
    func dailyPartialSuccess() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive()),
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.storyURL))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchDailySnapshot()

        #expect(snapshot.isPartialSuccess)
        #expect(snapshot.archive.value?.entries.count == 1)
        guard case .failure(.httpStatus(let code, _)) = snapshot.stories else {
            Issue.record("Expected story httpStatus failure")
            return
        }
        #expect(code == 503)
        #expect(snapshot.joined.count == 1)
        #expect(snapshot.joined.first?.storyMatch == nil)
    }

    @Test("Archive failure leaves stories available as a partial success")
    func dailyArchiveFailureKeepsStories() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.response(Data(), status: 503, url: BingFixture.archiveURL)),
            .response(BingFixture.successStory([BingFixture.storyEntry()]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchDailySnapshot()

        #expect(snapshot.isPartialSuccess)
        #expect(snapshot.stories.value?.records.count == 1)
        guard case .failure(.httpStatus(let code, _)) = snapshot.archive else {
            Issue.record("Expected archive httpStatus failure")
            return
        }
        #expect(code == 503)
        #expect(snapshot.joined.isEmpty)
    }

    @Test("Provider hash fallback joins only with the same per-market hash")
    func providerHashFallbackJoin() async throws {
        let transport = ScriptedTransport([
            .response(BingFixture.successArchive([
                BingFixture.archiveImage(
                    urlbase: "/th?id=SyntheticImage_ZH-CN123456_1920x1080",
                    url: "/th?id=SyntheticImage_ZH-CN123456_1920x1080",
                    hash: "deadbeef01"
                )
            ])),
            .response(BingFixture.successStory([
                BingFixture.storyEntry(hash: "deadbeef01", slug: nil)
            ]))
        ])
        let provider = makeProvider(transport: transport)
        let snapshot = try await provider.fetchDailySnapshot()

        let entry = try #require(snapshot.archive.value?.entries.first)
        #expect(entry.identityEvidence == .providerHash)
        #expect(entry.occurrence.wallpaperID.sourceImageID == "hsh:deadbeef01")
        let joined = try #require(snapshot.joined.first)
        let match = try #require(joined.storyMatch)
        guard case .matched(_, let evidence) = match else {
            Issue.record("Expected hash-backed match, got \(match)")
            return
        }
        #expect(evidence == .imageIdentityMarketAndDate)
    }
}
