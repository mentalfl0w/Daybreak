import CoreGraphics
import Foundation
import ImageIO
import Testing
import DaybreakCore

// MARK: - Fixtures

private enum CloudSyncFixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_100)
    static let pngData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    /// Distinct bytes from `pngData` so thumbnail and original cannot collapse
    /// into one content-addressed blob.
    static let originalPNGData = makePNG(width: 2, height: 2, red: 0.7, green: 0.25, blue: 0.1)

    private static func makePNG(
        width: Int,
        height: Int,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> Data {
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
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
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

    static func date(_ iso8601: String) -> LocalDate {
        guard let value = LocalDate(iso8601: iso8601) else {
            preconditionFailure("Invalid synthetic date")
        }
        return value
    }

    static func image(_ sourceImageID: String, source: SourceID = .bing) -> WallpaperID {
        WallpaperID(source: source, sourceImageID: sourceImageID)
    }

    static func occurrence(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String
    ) -> WallpaperOccurrence {
        WallpaperOccurrence(
            source: .bing,
            market: market,
            localDate: date(iso8601),
            wallpaperID: image(imageID),
            publisherTime: fetchedAt,
            revision: 0
        )
    }

    static func metadata(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String,
        title: String = "Synthetic metadata title"
    ) -> WallpaperMetadataRecord {
        WallpaperMetadataRecord(
            key: OccurrenceKey(source: .bing, market: market, localDate: date(iso8601)),
            wallpaperID: image(imageID),
            title: title,
            copyright: "Synthetic copyright",
            sourceURL: URL(string: "https://example.invalid/synthetic-content")!,
            originalLocale: market.rawValue,
            fetchedAt: fetchedAt,
            contentHash: "synthetic-content-hash"
        )
    }

    static func story(
        _ iso8601: String,
        market: Market = .zhCN,
        imageID: String?
    ) -> DailyStoryRecord {
        let identifier = "story:\(market.rawValue):\(iso8601):\(imageID ?? "unbound")"
        guard let story = DailyStoryRecord(
            id: identifier,
            source: .bing,
            market: market,
            date: date(iso8601),
            associatedWallpaperID: imageID.map { image($0) },
            title: "Synthetic story title",
            headline: "Synthetic headline",
            body: "Synthetic story body.",
            quickFact: nil,
            copyright: "Synthetic copyright",
            originalLocale: market.rawValue,
            sourceURL: URL(string: "https://example.invalid/synthetic-content")!,
            fetchedAt: fetchedAt,
            contentHash: "synthetic-\(identifier)",
            sourceFields: ["Synthetic.ImageContent.Headline"],
            availability: .available
        ) else {
            preconditionFailure("Invalid synthetic story fixture")
        }
        return story
    }

    static func wallpaper(_ imageID: String) -> WallpaperRecord {
        WallpaperRecord(
            source: .bing,
            wallpaperID: image(imageID),
            canonicalTitle: "Synthetic wallpaper title",
            copyright: "Synthetic copyright",
            sourceURL: URL(string: "https://example.invalid/synthetic-wallpaper"),
            fetchedAt: fetchedAt
        )
    }

    static func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakSyncTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct SyncSeed {
    let wallpaper: WallpaperRecord
    let occurrence: WallpaperOccurrence
    let metadata: WallpaperMetadataRecord
    let story: DailyStoryRecord
    let pin: PinnedOccurrence
    let localDate: LocalDate

    var wallpaperID: WallpaperID { wallpaper.wallpaperID }
}

private enum SyncSeeder {
    @discardableResult
    static func populate(
        _ repository: WallpaperRepository,
        market: Market = .zhCN,
        imageID: String = "image-A",
        iso8601: String = "2026-11-23",
        includeOriginal: Bool = false,
        thumbnailData: Data = CloudSyncFixture.pngData
    ) async throws -> SyncSeed {
        let wallpaper = CloudSyncFixture.wallpaper(imageID)
        let occurrence = CloudSyncFixture.occurrence(iso8601, market: market, imageID: imageID)
        let metadata = CloudSyncFixture.metadata(iso8601, market: market, imageID: imageID)
        let story = CloudSyncFixture.story(iso8601, market: market, imageID: imageID)
        _ = try await repository.upsertWallpapers([wallpaper])
        _ = try await repository.upsertOccurrences([occurrence])
        _ = try await repository.upsertMetadata([metadata])
        _ = try await repository.upsertStories([story])
        _ = try await repository.setFavorite(wallpaper.wallpaperID, isFavorite: true)
        _ = try await repository.setPinned(occurrence, isPinned: true)
        _ = try await repository.storeAsset(
            thumbnailData,
            kind: .thumbnail,
            for: wallpaper.wallpaperID,
            fileExtension: thumbnailData == CloudSyncFixture.pngData ? "png" : "bin"
        )
        if includeOriginal {
            _ = try await repository.storeAsset(
                CloudSyncFixture.originalPNGData,
                kind: .original,
                for: wallpaper.wallpaperID,
                fileExtension: "png"
            )
        }
        return SyncSeed(
            wallpaper: wallpaper,
            occurrence: occurrence,
            metadata: metadata,
            story: story,
            pin: PinnedOccurrence(key: occurrence.id, wallpaperID: wallpaper.wallpaperID),
            localDate: occurrence.localDate
        )
    }
}

// MARK: - Folder double

private actor TestGate {
    private var isOpen = false
    private var waitingCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        waitingCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        waitingCount = 0
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume()
        }
    }

    func waiting() -> Int {
        waitingCount
    }
}

private actor TestCloudFolderStore: CloudSyncFolderAccessing {
    let root: URL
    private var stateValue: CloudSyncFolderState = .notAuthorized
    private var failIO = false
    private var gate: TestGate?
    private var gatePrefix: String?
    private(set) var writeCount = 0
    private(set) var operationListings = 0
    private(set) var downloadRequests: [String] = []
    private var notDownloadedPaths: Set<String> = []

    init(root: URL) {
        self.root = root
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func setState(_ state: CloudSyncFolderState) {
        stateValue = state
    }

    func setNotDownloadedPaths(_ paths: Set<String>) {
        notDownloadedPaths = paths
    }

    func setFailIO(_ value: Bool) {
        failIO = value
    }

    func setGate(_ gate: TestGate?, prefix: String? = nil) {
        self.gate = gate
        self.gatePrefix = prefix
    }

    func resetCounters() {
        writeCount = 0
        operationListings = 0
        downloadRequests = []
    }

    func currentState() async -> CloudSyncFolderState {
        stateValue
    }

    func openIfNeeded() async -> CloudSyncFolderState {
        stateValue
    }

    func authorizeFolder(_ folderURL: URL) async throws -> String {
        stateValue = .active(displayName: "SyntheticSync")
        return "SyntheticSync"
    }

    func replaceFolderAuthorization(with folderURL: URL) async throws -> String {
        stateValue = .active(displayName: "SyntheticSync")
        return "SyntheticSync"
    }

    func disableFolder() async throws {
        stateValue = .notAuthorized
    }

    func readFile(relativePath: String, maxBytes: Int) async throws -> Data {
        if failIO { throw CloudSyncFolderAccessError.retryable }
        let url = root.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw CloudSyncFolderAccessError.notFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CloudSyncFolderAccessError.other
        }
        guard data.count <= maxBytes else {
            throw CloudSyncFolderAccessError.tooLarge
        }
        return data
    }

    func writeFile(_ data: Data, relativePath: String) async throws {
        if let gate, gatePrefix.map({ relativePath.hasPrefix($0) }) ?? true {
            await gate.wait()
        }
        if failIO { throw CloudSyncFolderAccessError.retryable }
        let url = root.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw CloudSyncFolderAccessError.other
        }
        writeCount += 1
    }

    func directoryEntries(relativePath: String) async throws -> [CloudSyncFolderEntry] {
        if failIO { throw CloudSyncFolderAccessError.retryable }
        if relativePath == CloudSyncFolderLayoutForTests.operationsDirectory {
            operationListings += 1
        }
        let url = relativePath.isEmpty
            ? root
            : root.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CloudSyncFolderAccessError.notFound
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ],
                options: []
            )
        } catch {
            throw CloudSyncFolderAccessError.retryable
        }
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]), values.isSymbolicLink != true
            else {
                return nil
            }
            if values.isDirectory == true {
                return CloudSyncFolderEntry(
                    name: child.lastPathComponent,
                    kind: .directory,
                    byteCount: nil,
                    isDownloaded: true
                )
            }
            let childPath = relativePath.isEmpty
                ? child.lastPathComponent
                : "\(relativePath)/\(child.lastPathComponent)"
            return CloudSyncFolderEntry(
                name: child.lastPathComponent,
                kind: .file,
                byteCount: values.fileSize,
                isDownloaded: !notDownloadedPaths.contains(childPath)
            )
        }
        .sorted { $0.name < $1.name }
    }

    func requestFileDownload(relativePath: String) async throws {
        downloadRequests.append(relativePath)
    }
}

/// The folder layout constants are internal to DaybreakCore; tests only need
/// the one directory name they assert on.
private enum CloudSyncFolderLayoutForTests {
    static let markerFileName = "daybreak-sync.json"
    static let markerFormat = "daybreak.sync.folder"
    static let markerVersion = 1
    static let operationsDirectory = "operations"
    static let blobsDirectory = "blobs"
}

/// The on-disk marker contract. Decoding a dedicated shape (instead of the
/// internal product type) keeps the assertion independent of `@testable`
/// visibility while still failing when the encoded format drifts.
private struct ExpectedFolderMarker: Decodable {
    let format: String
    let version: Int
}

// MARK: - Helpers

private func allFiles(in directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return []
    }
    var result: [URL] = []
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result.append(url)
        }
    }
    return result.sorted { $0.path < $1.path }
}

private func relativeNames(in directory: URL) -> Set<String> {
    let prefix = directory.standardizedFileURL.path + "/"
    return Set(allFiles(in: directory).compactMap { url -> String? in
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    })
}

private func blobFiles(in root: URL) -> [URL] {
    allFiles(in: root.appendingPathComponent(CloudSyncFolderLayoutForTests.blobsDirectory))
}

private func operationFiles(in root: URL) -> [URL] {
    allFiles(in: root.appendingPathComponent(CloudSyncFolderLayoutForTests.operationsDirectory))
}

private func makeRepository(at directory: URL) throws -> WallpaperRepository {
    try WallpaperRepository(directory: directory)
}

private func makeEngine(
    repository: WallpaperRepository,
    folder: TestCloudFolderStore,
    stateDirectory: URL
) -> CloudSyncEngine {
    CloudSyncEngine(
        repository: repository,
        folder: folder,
        stateDirectory: stateDirectory,
        now: { CloudSyncFixture.fixedNow }
    )
}

private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

// MARK: - Engine tests

struct CloudSyncEngineTests {
    @Test func bootstrapRoundTripRestoresPeerContentAndThumbnail() async throws {
        let root = try CloudSyncFixture.makeDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let aDirectory = try CloudSyncFixture.makeDirectory("roundtrip-a")
        let a = try makeRepository(at: aDirectory)
        let seed = try await SyncSeeder.populate(a)
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )
        let scope = SyncScope(markets: [], includesOriginals: false)

        let resultA = await engineA.synchronize(scope: scope)
        #expect(resultA.status == .completed)
        #expect(resultA.issue == .none)
        #expect(!operationFiles(in: shared).isEmpty)
        #expect(blobFiles(in: shared).count == 1)

        let bDirectory = try CloudSyncFixture.makeDirectory("roundtrip-b")
        let b = try makeRepository(at: bDirectory)
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )

        let resultB = await engineB.synchronize(scope: scope)
        #expect(resultB.status == .completed)
        #expect(resultB.importedRecordCount > 0)
        #expect(resultB.didChangeLocalData)
        #expect(resultB.storedAssetCount == 1)

        let snapshotB = await b.snapshot()
        #expect(snapshotB.favoriteWallpaperIDs.contains(seed.wallpaperID))
        #expect(snapshotB.pinnedOccurrences.contains(seed.pin))
        #expect(snapshotB.occurrences.contains(seed.occurrence))
        #expect(snapshotB.metadata.contains(seed.metadata))
        #expect(snapshotB.stories.contains { $0.id == seed.story.id })
        #expect(snapshotB.wallpapers.contains { $0.id == seed.wallpaperID })

        let thumbnailURL = await b.assetURL(kind: .thumbnail, for: seed.wallpaperID)
        let unwrappedThumbnailURL = try #require(thumbnailURL)
        let thumbnailData = try Data(contentsOf: unwrappedThumbnailURL)
        #expect(thumbnailData == CloudSyncFixture.pngData)

        // Imported records must not be re-authored as local operations.
        let journalAfterImport = await b.syncLocalOperations().count
        let secondB = await engineB.synchronize(scope: scope)
        #expect(secondB.status == .completed)
        #expect(secondB.uploadedOperationCount == 0)
        #expect(secondB.importedRecordCount == 0)
        #expect(await b.syncLocalOperations().count == journalAfterImport)
    }

    @Test func repeatedPassIsIdempotent() async throws {
        let root = try CloudSyncFixture.makeDirectory("idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("idempotent-a"))
        _ = try await SyncSeeder.populate(a)
        let store = TestCloudFolderStore(root: shared)
        await store.setState(.active(displayName: "Shared"))
        let engine = makeEngine(
            repository: a,
            folder: store,
            stateDirectory: root.appendingPathComponent("state")
        )
        let scope = SyncScope(markets: [], includesOriginals: false)

        let first = await engine.synchronize(scope: scope)
        #expect(first.status == .completed)
        let firstNames = relativeNames(in: shared)
        let journalAfterFirst = await a.syncLocalOperations().count

        let second = await engine.synchronize(scope: scope)
        #expect(second.status == .completed)
        #expect(second.uploadedOperationCount == 0)
        #expect(second.uploadedAssetCount == 0)
        #expect(relativeNames(in: shared) == firstNames)
        #expect(await a.syncLocalOperations().count == journalAfterFirst)
    }

    @Test func favoriteRemovalConvergesAndNeverDeletesRemoteFiles() async throws {
        let root = try CloudSyncFixture.makeDirectory("favorite-removal")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("favorite-a"))
        let seed = try await SyncSeeder.populate(a)
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )
        #expect(await engineA.synchronize(scope: scope).status == .completed)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("favorite-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )
        #expect(await engineB.synchronize(scope: scope).status == .completed)
        #expect(await b.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))

        let namesBeforeRemoval = relativeNames(in: shared)
        _ = try await b.setFavorite(seed.wallpaperID, isFavorite: false)
        #expect(await engineB.synchronize(scope: scope).status == .completed)
        #expect(await engineA.synchronize(scope: scope).status == .completed)

        #expect(await a.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID) == false)
        let namesAfterRemoval = relativeNames(in: shared)
        #expect(namesBeforeRemoval.isSubset(of: namesAfterRemoval))
        #expect(namesAfterRemoval.count > namesBeforeRemoval.count)
    }

    @Test func missingBlobKeepsPendingUntilItAppears() async throws {
        let root = try CloudSyncFixture.makeDirectory("missing-blob")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("missing-a"))
        let seed = try await SyncSeeder.populate(a)
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )
        #expect(await engineA.synchronize(scope: scope).status == .completed)

        let blobs = blobFiles(in: shared)
        #expect(blobs.count == 1)
        let blobURL = try #require(blobs.first)
        let blobData = try Data(contentsOf: blobURL)
        try FileManager.default.removeItem(at: blobURL)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("missing-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )

        let pending = await engineB.synchronize(scope: scope)
        #expect(pending.status == .pending)
        #expect(pending.storedAssetCount == 0)
        #expect(pending.pendingAssetCount == 1)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) == nil)

        try blobData.write(to: blobURL, options: .atomic)
        let recovered = await engineB.synchronize(scope: scope)
        #expect(recovered.status == .completed)
        #expect(recovered.storedAssetCount == 1)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) != nil)
    }

    @Test func corruptBlobIsRetriedAfterReplacement() async throws {
        let root = try CloudSyncFixture.makeDirectory("corrupt-blob")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("corrupt-a"))
        let seed = try await SyncSeeder.populate(a)
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )
        #expect(await engineA.synchronize(scope: scope).status == .completed)

        let blobURL = try #require(blobFiles(in: shared).first)
        let validBlob = try Data(contentsOf: blobURL)
        try Data(repeating: 0, count: validBlob.count).write(to: blobURL, options: .atomic)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("corrupt-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )

        let pending = await engineB.synchronize(scope: scope)
        #expect(pending.status == .pending)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) == nil)

        try validBlob.write(to: blobURL, options: .atomic)
        let recovered = await engineB.synchronize(scope: scope)
        #expect(recovered.status == .completed)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) != nil)
    }

    @Test func hostileAndInvalidOperationFilesAreIgnoredWithoutDeletion() async throws {
        let root = try CloudSyncFixture.makeDirectory("hostile")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("hostile-a"))
        _ = try await SyncSeeder.populate(a)
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )
        #expect(await engineA.synchronize(scope: scope).status == .completed)

        let operations = shared.appendingPathComponent("operations")
        try Data("not json".utf8).write(
            to: operations.appendingPathComponent("loose.json"),
            options: .atomic
        )
        let disguised = operations.appendingPathComponent("evil.device", isDirectory: true)
        try FileManager.default.createDirectory(at: disguised, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: disguised.appendingPathComponent("notes.txt"),
            options: .atomic
        )
        let zeros = String(repeating: "0", count: 64)
        let wrongDevice = operations.appendingPathComponent("bad-device", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongDevice, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: wrongDevice.appendingPathComponent("bad-device.\(zeros).json"),
            options: .atomic
        )
        try Data("{}".utf8).write(
            to: wrongDevice.appendingPathComponent("other-device.\(zeros).json"),
            options: .atomic
        )
        let hostileNames = relativeNames(in: shared)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("hostile-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )

        let result = await engineB.synchronize(scope: scope)
        #expect(result.status == .completed)
        #expect(result.issue == .invalidOperationFiles)
        #expect(result.rejectedFileCount >= 2)
        // No remote deletion or repair: every hostile file is still present.
        #expect(hostileNames.isSubset(of: relativeNames(in: shared)))
    }

    @Test func originalScopeIsOptInAndNeverDeletesPreviouslySyncedBlobs() async throws {
        let root = try CloudSyncFixture.makeDirectory("originals")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("originals-a"))
        let seed = try await SyncSeeder.populate(a, includeOriginal: true)
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )

        let thumbnailsOnly = SyncScope(markets: [], includesOriginals: false)
        #expect(await engineA.synchronize(scope: thumbnailsOnly).status == .completed)
        #expect(blobFiles(in: shared).count == 1)

        let withOriginals = SyncScope(markets: [], includesOriginals: true)
        #expect(await engineA.synchronize(scope: withOriginals).status == .completed)
        #expect(blobFiles(in: shared).count == 2)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("originals-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )

        let bThumbnailsOnly = await engineB.synchronize(scope: thumbnailsOnly)
        #expect(bThumbnailsOnly.status == .completed)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) != nil)
        #expect(await b.assetURL(kind: .original, for: seed.wallpaperID) == nil)

        #expect(await engineB.synchronize(scope: withOriginals).status == .completed)
        #expect(await b.assetURL(kind: .original, for: seed.wallpaperID) != nil)

        // Turning originals back off must not delete blobs already shared.
        #expect(await engineA.synchronize(scope: thumbnailsOnly).status == .completed)
        #expect(blobFiles(in: shared).count == 2)
        #expect(await a.assetURL(kind: .original, for: seed.wallpaperID) != nil)
    }

    @Test func marketScopeFiltersContentUntilOptedIn() async throws {
        let root = try CloudSyncFixture.makeDirectory("markets")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("markets-a"))
        let zhSeed = try await SyncSeeder.populate(a, market: .zhCN, imageID: "image-zh")
        let enSeed = try await SyncSeeder.populate(
            a,
            market: .enUS,
            imageID: "image-en",
            iso8601: "2026-11-24"
        )
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )

        let zhOnly = SyncScope(markets: [.zhCN], includesOriginals: false)
        #expect(await engineA.synchronize(scope: zhOnly).status == .completed)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("markets-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )
        #expect(await engineB.synchronize(scope: zhOnly).status == .completed)
        let restricted = await b.snapshot()
        #expect(restricted.occurrences.contains { $0.wallpaperID == zhSeed.wallpaperID })
        #expect(restricted.occurrences.contains { $0.wallpaperID == enSeed.wallpaperID } == false)
        #expect(restricted.metadata.contains { $0.wallpaperID == enSeed.wallpaperID } == false)

        let allMarkets = SyncScope(markets: [], includesOriginals: false)
        #expect(await engineA.synchronize(scope: allMarkets).status == .completed)
        #expect(await engineB.synchronize(scope: allMarkets).status == .completed)
        let merged = await b.snapshot()
        #expect(merged.occurrences.contains { $0.wallpaperID == enSeed.wallpaperID })
        #expect(merged.metadata.contains { $0.wallpaperID == enSeed.wallpaperID })
    }

    @Test func restartAndFolderReselectDoNotDuplicateOperations() async throws {
        let root = try CloudSyncFixture.makeDirectory("restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("restart-a"))
        let seed = try await SyncSeeder.populate(a)
        let stateDirectory = root.appendingPathComponent("state-a")
        let store = TestCloudFolderStore(root: shared)
        await store.setState(.active(displayName: "Shared"))
        let firstEngine = makeEngine(
            repository: a,
            folder: store,
            stateDirectory: stateDirectory
        )
        #expect(await firstEngine.synchronize(scope: scope).status == .completed)
        let namesAfterFirst = relativeNames(in: shared)

        let restarted = makeEngine(
            repository: a,
            folder: store,
            stateDirectory: stateDirectory
        )
        #expect(await restarted.synchronize(scope: scope).status == .completed)
        #expect(relativeNames(in: shared) == namesAfterFirst)

        let newFavorite = CloudSyncFixture.image("image-new")
        let addedFavorite = try await a.setFavorite(newFavorite, isFavorite: true)
        #expect(addedFavorite)
        #expect(await restarted.synchronize(scope: scope).status == .completed)
        #expect(relativeNames(in: shared).count == namesAfterFirst.count + 1)

        // A second, empty folder replays the immutable journal instead of
        // creating a second bootstrap of the same content.
        let secondFolder = root.appendingPathComponent("shared-2", isDirectory: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let secondStore = TestCloudFolderStore(root: secondFolder)
        await secondStore.setState(.active(displayName: "Shared2"))
        let reselected = makeEngine(
            repository: a,
            folder: secondStore,
            stateDirectory: stateDirectory
        )
        #expect(await reselected.synchronize(scope: scope).status == .completed)
        let journal = await a.syncLocalOperations()
        #expect(relativeNames(in: secondFolder).count >= journal.count)
        // The old folder is untouched by the reselect.
        #expect(namesAfterFirst.isSubset(of: relativeNames(in: shared)))
        #expect(await a.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))
    }

    @Test func nonImageBlobIsRejectedPermanently() async throws {
        let root = try CloudSyncFixture.makeDirectory("non-image")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("non-image-a"))
        let seed = try await SyncSeeder.populate(
            a,
            thumbnailData: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        )
        let storeA = TestCloudFolderStore(root: shared)
        await storeA.setState(.active(displayName: "Shared"))
        let engineA = makeEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a")
        )
        #expect(await engineA.synchronize(scope: scope).status == .completed)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("non-image-b"))
        let storeB = TestCloudFolderStore(root: shared)
        await storeB.setState(.active(displayName: "Shared"))
        let engineB = makeEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b")
        )

        let rejected = await engineB.synchronize(scope: scope)
        #expect(rejected.status == .completed)
        #expect(rejected.issue == .rejectedAssets)
        #expect(rejected.rejectedAssetCount == 1)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) == nil)

        let retried = await engineB.synchronize(scope: scope)
        #expect(retried.status == .completed)
        #expect(retried.rejectedAssetCount == 1)
        #expect(await b.assetURL(kind: .thumbnail, for: seed.wallpaperID) == nil)
    }

    @Test func revokeAndUnavailableStatesKeepLocalData() async throws {
        let root = try CloudSyncFixture.makeDirectory("revoked")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("revoked-a"))
        let seed = try await SyncSeeder.populate(a)
        let store = TestCloudFolderStore(root: shared)
        await store.setState(.revoked(.bookmarkCorrupted))
        let engine = makeEngine(
            repository: a,
            folder: store,
            stateDirectory: root.appendingPathComponent("state")
        )

        let unauthorized = await engine.synchronize(scope: scope)
        #expect(unauthorized.status == .unauthorized)
        #expect(await a.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))

        await store.setState(.revoked(.targetMissing))
        let unavailable = await engine.synchronize(scope: scope)
        #expect(unavailable.status == .unavailable)
        #expect(await a.snapshot().occurrences.contains(seed.occurrence))

        await store.setState(.active(displayName: "Shared"))
        await store.setFailIO(true)
        let offline = await engine.synchronize(scope: scope)
        #expect(offline.status == .pending)

        await store.setFailIO(false)
        let recovered = await engine.synchronize(scope: scope)
        #expect(recovered.status == .completed)
        #expect(await a.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))
    }

    @Test func concurrentSynchronizeCallsAreSingleFlight() async throws {
        let root = try CloudSyncFixture.makeDirectory("singleflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("singleflight-a"))
        _ = try await SyncSeeder.populate(a)
        let store = TestCloudFolderStore(root: shared)
        await store.setState(.active(displayName: "Shared"))
        let engine = makeEngine(
            repository: a,
            folder: store,
            stateDirectory: root.appendingPathComponent("state")
        )

        let gate = TestGate()
        await store.setGate(gate)
        let first = Task { await engine.synchronize(scope: scope) }
        let waiting = await waitUntil { await gate.waiting() > 0 }
        #expect(waiting)
        let second = await engine.synchronize(scope: scope)
        #expect(second.status == .pending)
        #expect(second.issue == .passInProgress)
        await gate.open()
        let firstResult = await first.value
        #expect(firstResult.status == .completed)
        await store.setGate(nil)
    }
}

// MARK: - Controller tests

struct DaybreakSyncControllerTests {
    @MainActor
    @Test func enablingWithoutFolderNeverReportsEnabled() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-no-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-no-folder-repo"))
        _ = try await SyncSeeder.populate(repository)
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: root.appendingPathComponent("state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.prepare()
        await controller.setEnabled(true)
        #expect(controller.enabled == false)
        #expect(controller.status == .awaitingFolder)
    }

    @MainActor
    @Test func selectFolderEnablesAndCompletesLocalPass() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-select")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-select-repo"))
        let seed = try await SyncSeeder.populate(repository)
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: root.appendingPathComponent("state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.prepare()
        #expect(controller.status == .disabled)

        await controller.selectFolder(root.appendingPathComponent("shared"))
        #expect(controller.enabled)
        #expect(controller.folderName == "SyntheticSync")
        await controller.syncNow()
        #expect(controller.status == .completed)
        #expect(controller.lastSyncAt == CloudSyncFixture.fixedNow)
        #expect(controller.dataRevision == 0)
        #expect(controller.syncOriginals == false)
        #expect(controller.syncMarket == false)
        #expect(await repository.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))
    }

    @MainActor
    @Test func persistedOptionsSurviveRestart() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-persist")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-persist-repo"))
        _ = try await SyncSeeder.populate(repository, includeOriginal: true)
        let stateDirectory = root.appendingPathComponent("state")
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: stateDirectory,
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.prepare()
        await controller.selectFolder(root.appendingPathComponent("shared"))
        await controller.syncNow()
        await controller.setSyncOriginals(true)
        await controller.setSyncMarket(true)
        await controller.syncNow()
        #expect(controller.syncOriginals)
        #expect(controller.syncMarket)
        #expect(controller.enabled)

        let restoredStore = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        await restoredStore.setState(.active(displayName: "SyntheticSync"))
        let restored = DaybreakSyncController(
            repository: repository,
            stateDirectory: stateDirectory,
            folderStore: restoredStore,
            now: { CloudSyncFixture.fixedNow }
        )
        await restored.prepare()
        await restored.syncNow()
        #expect(restored.enabled)
        #expect(restored.folderName == "SyntheticSync")
        #expect(restored.syncOriginals)
        #expect(restored.syncMarket)
        #expect(restored.status == .completed)
    }

    @MainActor
    @Test func foregroundTriggersCoalesceIntoAtMostOneExtraPass() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-coalesce")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-coalesce-repo"))
        let seed = try await SyncSeeder.populate(repository)
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: root.appendingPathComponent("state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.selectFolder(root.appendingPathComponent("shared"))
        await controller.syncNow()
        #expect(controller.status == .completed)
        await store.resetCounters()

        let gate = TestGate()
        await store.setGate(gate)
        _ = try await repository.setFavorite(seed.wallpaperID, isFavorite: false)
        for _ in 0..<5 {
            await controller.noteForegroundActivity()
        }
        let started = await waitUntil { await gate.waiting() > 0 }
        #expect(started)
        await store.setGate(nil)
        await gate.open()
        let settled = await waitUntil { controller.status != .syncing }
        #expect(settled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let listings = await store.operationListings
        #expect(listings >= 1)
        #expect(listings <= 2)
        #expect(controller.status == .completed)
        await store.setGate(nil)
    }

    @MainActor
    @Test func disableCancelsInFlightPassAndKeepsStatusDisabled() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-cancel-repo"))
        let seed = try await SyncSeeder.populate(repository)
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: root.appendingPathComponent("state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.selectFolder(root.appendingPathComponent("shared"))
        await controller.syncNow()
        #expect(controller.status == .completed)

        let gate = TestGate()
        await store.setGate(gate)
        _ = try await repository.setFavorite(seed.wallpaperID, isFavorite: false)
        await controller.noteForegroundActivity()
        let blocked = await waitUntil { await gate.waiting() > 0 }
        #expect(blocked)

        let disableTask = Task { await controller.setEnabled(false) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        await disableTask.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.enabled == false)
        #expect(controller.status == .disabled)

        await store.setGate(nil)
        await controller.setEnabled(true)
        await controller.syncNow()
        #expect(controller.enabled)
        #expect(controller.status == .completed)
        #expect(await repository.syncPublishedThroughSequence() > 0)
    }

    @MainActor
    @Test func dataRevisionAdvancesWhenRemoteContentIsImported() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let sourceRepository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-revision-a"))
        _ = try await SyncSeeder.populate(sourceRepository)
        let sourceStore = TestCloudFolderStore(root: shared)
        await sourceStore.setState(.active(displayName: "Shared"))
        let sourceEngine = makeEngine(
            repository: sourceRepository,
            folder: sourceStore,
            stateDirectory: root.appendingPathComponent("source-state")
        )
        #expect(await sourceEngine.synchronize(
            scope: SyncScope(markets: [], includesOriginals: false)
        ).status == .completed)

        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-revision-b"))
        let store = TestCloudFolderStore(root: shared)
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: root.appendingPathComponent("receiver-state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        #expect(controller.dataRevision == 0)
        await controller.selectFolder(shared)
        await controller.syncNow()
        #expect(controller.status == .completed)
        #expect(controller.dataRevision >= 1)
    }

    @MainActor
    @Test func revokedAuthorizationDisablesAndReportsUnauthorized() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-revoked")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-revoked-repo"))
        _ = try await SyncSeeder.populate(repository)
        let stateDirectory = root.appendingPathComponent("state")
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: stateDirectory,
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.selectFolder(root.appendingPathComponent("shared"))
        await controller.syncNow()
        #expect(controller.enabled)

        await store.setState(.revoked(.bookmarkCorrupted))
        await controller.syncNow()
        #expect(controller.status == .unauthorized)
        #expect(controller.enabled == false)
    }

    @MainActor
    @Test func unavailableFolderRecoversWithoutLosingLocalData() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-offline")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("controller-offline-repo"))
        let seed = try await SyncSeeder.populate(repository)
        let store = TestCloudFolderStore(root: root.appendingPathComponent("shared"))
        let controller = DaybreakSyncController(
            repository: repository,
            stateDirectory: root.appendingPathComponent("state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await controller.selectFolder(root.appendingPathComponent("shared"))
        await controller.syncNow()
        #expect(controller.status == .completed)

        await store.setFailIO(true)
        await controller.syncNow()
        #expect(controller.status == .pending)
        #expect(controller.enabled)

        await store.setFailIO(false)
        await controller.syncNow()
        #expect(controller.status == .completed)
        #expect(await repository.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))
    }

    @MainActor
    @Test func pendingDownloadsRetryAfterMaterializationAndCancelOnDisable() async throws {
        let root = try CloudSyncFixture.makeDirectory("controller-pending-downloads")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let scope = SyncScope(markets: [], includesOriginals: false)

        let sourceRepository = try makeRepository(
            at: try CloudSyncFixture.makeDirectory("controller-pending-source")
        )
        let seed = try await SyncSeeder.populate(sourceRepository)
        let sourceStore = TestCloudFolderStore(root: shared)
        await sourceStore.setState(.active(displayName: "Shared"))
        let sourceEngine = makeEngine(
            repository: sourceRepository,
            folder: sourceStore,
            stateDirectory: root.appendingPathComponent("source-state")
        )
        #expect(await sourceEngine.synchronize(scope: scope).status == .completed)

        let operation = try #require(operationFiles(in: shared).first)
        let sharedPath = shared.standardizedFileURL.path
        let operationPath = operation.standardizedFileURL.path
        let relativeOperationPath = String(operationPath.dropFirst(sharedPath.count + 1))

        let receiver = try makeRepository(
            at: try CloudSyncFixture.makeDirectory("controller-pending-receiver")
        )
        let store = TestCloudFolderStore(root: shared)
        let controller = DaybreakSyncController(
            repository: receiver,
            stateDirectory: root.appendingPathComponent("receiver-state"),
            folderStore: store,
            now: { CloudSyncFixture.fixedNow }
        )
        await store.setState(.active(displayName: "Shared"))
        await store.setNotDownloadedPaths([relativeOperationPath])
        await controller.prepare()
        await controller.selectFolder(shared)
        await controller.syncNow()

        #expect(controller.status == .pending)
        #expect(controller.lastIssue == .pendingDownloads)
        #expect(await store.downloadRequests.contains(relativeOperationPath))
        let pendingListings = await store.operationListings

        await store.setNotDownloadedPaths([])
        let recovered = await waitUntil(timeout: 10) {
            controller.status == .completed
        }
        #expect(recovered)
        #expect(await store.operationListings > pendingListings)
        #expect(await receiver.snapshot().favoriteWallpaperIDs.contains(seed.wallpaperID))

        await store.setNotDownloadedPaths([relativeOperationPath])
        await controller.syncNow()
        #expect(controller.status == .pending)
        let listingsBeforeDisable = await store.operationListings
        await controller.setEnabled(false)
        #expect(controller.status == .disabled)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(await store.operationListings == listingsBeforeDisable)
    }

}

/// End-to-end through the production folder adapter: real bookmark file,
/// real directory coordination and real repository directories.
struct CloudSyncRealFolderTests {
    @Test func realAuthorizedFolderRoundTripsBetweenTwoRepositories() async throws {
        let root = try CloudSyncFixture.makeDirectory("real-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let a = try makeRepository(at: try CloudSyncFixture.makeDirectory("real-a"))
        let seed = try await SyncSeeder.populate(a)
        let storeA = AuthorizedFolderStore(
            bookmarkDirectory: root.appendingPathComponent("bookmarks-a", isDirectory: true)
        )
        _ = await storeA.open()
        _ = try await storeA.authorize(shared)
        let engineA = CloudSyncEngine(
            repository: a,
            folder: storeA,
            stateDirectory: root.appendingPathComponent("state-a", isDirectory: true),
            now: { CloudSyncFixture.fixedNow }
        )
        let scope = SyncScope(markets: [], includesOriginals: false)
        let resultA = await engineA.synchronize(scope: scope)
        #expect(resultA.status == .completed)
        #expect(!operationFiles(in: shared).isEmpty)
        #expect(blobFiles(in: shared).count == 1)

        let b = try makeRepository(at: try CloudSyncFixture.makeDirectory("real-b"))
        let storeB = AuthorizedFolderStore(
            bookmarkDirectory: root.appendingPathComponent("bookmarks-b", isDirectory: true)
        )
        _ = await storeB.open()
        _ = try await storeB.authorize(shared)
        let engineB = CloudSyncEngine(
            repository: b,
            folder: storeB,
            stateDirectory: root.appendingPathComponent("state-b", isDirectory: true),
            now: { CloudSyncFixture.fixedNow }
        )
        let resultB = await engineB.synchronize(scope: scope)
        #expect(resultB.status == .completed)
        #expect(resultB.didChangeLocalData)
        let snapshotB = await b.snapshot()
        #expect(snapshotB.favoriteWallpaperIDs.contains(seed.wallpaperID))
        #expect(snapshotB.occurrences.contains(seed.occurrence))
        let thumbnailURL = await b.assetURL(kind: .thumbnail, for: seed.wallpaperID)
        let unwrapped = try #require(thumbnailURL)
        #expect(try Data(contentsOf: unwrapped) == CloudSyncFixture.pngData)
    }

    @Test func firstSyncOnAnEmptyAuthorizedFolderCreatesTheMarker() async throws {
        let root = try CloudSyncFixture.makeDirectory("real-folder-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        // The reported device scenario: a user-selected folder with no files
        // and no local content. The first pass must create the versioned marker
        // before it does anything else.
        let before = try FileManager.default.contentsOfDirectory(atPath: shared.path)
        #expect(before.isEmpty)

        let repository = try makeRepository(
            at: try CloudSyncFixture.makeDirectory("real-folder-marker-repo")
        )
        let store = AuthorizedFolderStore(
            bookmarkDirectory: root.appendingPathComponent("bookmarks", isDirectory: true)
        )
        _ = await store.open()
        _ = try await store.authorize(shared)
        let engine = CloudSyncEngine(
            repository: repository,
            folder: store,
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            now: { CloudSyncFixture.fixedNow }
        )

        let result = await engine.synchronize(
            scope: SyncScope(markets: [], includesOriginals: false)
        )
        #expect(result.status == .completed)

        let markerURL = shared.appendingPathComponent(
            CloudSyncFolderLayoutForTests.markerFileName
        )
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        let marker = try JSONDecoder().decode(
            ExpectedFolderMarker.self,
            from: Data(contentsOf: markerURL)
        )
        #expect(marker.format == CloudSyncFolderLayoutForTests.markerFormat)
        #expect(marker.version == CloudSyncFolderLayoutForTests.markerVersion)
    }
}

/// User options written while a pass is suspended must survive that pass.
struct CloudSyncOptionRaceTests {
    @Test func optionChangesDuringAPassAreNotReverted() async throws {
        let root = try CloudSyncFixture.makeDirectory("option-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let repository = try makeRepository(at: try CloudSyncFixture.makeDirectory("option-race-repo"))
        _ = try await SyncSeeder.populate(repository)
        let store = TestCloudFolderStore(root: shared)
        await store.setState(.active(displayName: "Shared"))
        let engine = CloudSyncEngine(
            repository: repository,
            folder: store,
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            now: { CloudSyncFixture.fixedNow }
        )
        try await engine.setEnabled(true)
        try await engine.setScope(syncOriginals: false, syncMarket: false)

        let gate = TestGate()
        await store.setGate(gate, prefix: "operations/")
        let pass = Task { await engine.synchronize(scope: SyncScope(markets: [], includesOriginals: false)) }
        let blocked = await waitUntil { await gate.waiting() > 0 }
        #expect(blocked)

        try await engine.setEnabled(false)
        try await engine.setScope(syncOriginals: true, syncMarket: true)
        await gate.open()
        _ = await pass.value
        await store.setGate(nil)

        let state = await engine.localState()
        #expect(state.enabled == false)
        #expect(state.syncOriginals)
        #expect(state.syncMarket)

        let restarted = CloudSyncEngine(
            repository: repository,
            folder: store,
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            now: { CloudSyncFixture.fixedNow }
        )
        let reloaded = await restarted.localState()
        #expect(reloaded.enabled == false)
        #expect(reloaded.syncOriginals)
        #expect(reloaded.syncMarket)
    }
}
