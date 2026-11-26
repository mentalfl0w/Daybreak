import Foundation
import Testing
@testable import DaybreakCore

@Suite("Wallpaper application protection")
struct ApplicationProtectionTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakApplicationProtection-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func imageID(_ suffix: String) -> WallpaperID {
        WallpaperID(source: .bing, sourceImageID: "application-\(suffix)")
    }

    @Test("Reservation protects a source before a write and blocks eviction and deletion")
    func reservationProtectsOriginal() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WallpaperRepository(directory: directory)
        let image = imageID("protected")

        _ = try await repository.storeAsset(
            Data([0x01, 0x02, 0x03]),
            kind: .original,
            for: image,
            fileExtension: "png"
        )
        let storedURL = await repository.assetURL(kind: .original, for: image)
        let assetURL = try #require(storedURL)

        let reserved = try await repository.reserveAppliedProtection(forImageURL: assetURL)
        #expect(reserved == image)

        // A reservation is not reported as current-desktop wallpaper.
        let snapshot = await repository.snapshot()
        #expect(!snapshot.appliedWallpapers.contains(image))

        let unrelated = imageID("unrelated")
        _ = try await repository.replaceAppliedWallpapers([unrelated])
        let afterAdditiveUpdate = await repository.snapshot()
        #expect(!afterAdditiveUpdate.appliedWallpapers.contains(image))
        #expect(afterAdditiveUpdate.appliedWallpapers.contains(unrelated))

        let eviction = try await repository.evictLeastRecentlyUsed(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 0)
        )
        #expect(eviction.evictedAssets.isEmpty)
        let stillCached = await repository.asset(kind: .original, for: image)
        #expect(stillCached != nil)

        do {
            try await repository.removeAsset(kind: .original, for: image)
            Issue.record("Expected protected asset deletion to be refused")
        } catch let error as RepositoryError {
            #expect(error == .protectedAsset(image))
        }

        // Completing a failed write releases the reservation, so the image is
        // no longer protected by a write that never happened.
        await repository.completeAppliedProtection(forImageURL: assetURL, succeeded: false)
        try await repository.removeAsset(kind: .original, for: image)
        let removed = await repository.asset(kind: .original, for: image)
        #expect(removed == nil)
    }

    @Test("A successful write keeps only the just-written image protected")
    func successfulWritePromotesReservation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WallpaperRepository(directory: directory)
        let image = imageID("written")

        _ = try await repository.storeAsset(
            Data([0x09, 0x08]),
            kind: .original,
            for: image,
            fileExtension: "png"
        )
        let storedURL = await repository.assetURL(kind: .original, for: image)
        let assetURL = try #require(storedURL)

        _ = try await repository.reserveAppliedProtection(forImageURL: assetURL)
        await repository.completeAppliedProtection(forImageURL: assetURL, succeeded: true)

        let snapshot = await repository.snapshot()
        #expect(snapshot.appliedWallpapers == Set([image]))
        #expect(snapshot.pinReasons(for: image).contains(.currentlyApplied))

        // The live current-desktop set is replaceable; a later reconciliation
        // releases the image instead of accumulating history.
        try await repository.replaceAppliedWallpapers([])
        let released = await repository.snapshot()
        #expect(released.appliedWallpapers.isEmpty)
    }

    @Test("A repository record whose file is missing cannot be reserved")
    func missingFileReturnsNil() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WallpaperRepository(directory: directory)
        let image = imageID("missing")

        _ = try await repository.storeAsset(
            Data([0x07]),
            kind: .original,
            for: image,
            fileExtension: "png"
        )
        let storedURL = await repository.assetURL(kind: .original, for: image)
        let assetURL = try #require(storedURL)
        try FileManager.default.removeItem(at: assetURL)

        let reserved = try await repository.reserveAppliedProtection(forImageURL: assetURL)
        #expect(reserved == nil)
    }

    @Test("Unknown URLs are not guessed and return nil")
    func unknownURLReturnsNil() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WallpaperRepository(directory: directory)
        let unknown = URL(fileURLWithPath: "/tmp/DaybreakUnknown-\(UUID().uuidString).png")

        let reserved = try await repository.reserveAppliedProtection(forImageURL: unknown)
        #expect(reserved == nil)
    }

    @Test("An unprotected asset can still be removed explicitly")
    func unprotectedRemovalStillWorks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WallpaperRepository(directory: directory)
        let image = imageID("unprotected")

        _ = try await repository.storeAsset(
            Data([0x04, 0x05]),
            kind: .original,
            for: image,
            fileExtension: "png"
        )
        try await repository.removeAsset(kind: .original, for: image)

        let remaining = await repository.asset(kind: .original, for: image)
        #expect(remaining == nil)
    }
}
