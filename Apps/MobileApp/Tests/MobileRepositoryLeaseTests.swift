import DaybreakCore
import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Mobile repository lease")
struct MobileRepositoryLeaseTests {
    @Test("a second lease for the same directory fails closed in this process")
    func duplicateLeaseFailsClosed() throws {
        let directory = MobileSyntheticFixture.temporaryDirectory("Lease")
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: MobileRepositoryLease? = try MobileRepositoryLease.acquire(
            directory: directory
        )
        #expect(FileManager.default.fileExists(atPath: first!.fileURL.path))

        do {
            _ = try MobileRepositoryLease.acquire(directory: directory)
            Issue.record("A second lease unexpectedly succeeded")
        } catch let error as MobileStoreError {
            #expect(error == .repositoryAlreadyOpenInProcess)
        }

        first = nil
        let second = try MobileRepositoryLease.acquire(directory: directory)
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    @Test("repair removes only orphan assets and never the lease file")
    func repairPreservesLeaseFile() async throws {
        let directory = MobileSyntheticFixture.temporaryDirectory("Repair")
        defer { try? FileManager.default.removeItem(at: directory) }

        let lease = try MobileRepositoryLease.acquire(directory: directory)
        let repository = try WallpaperRepository(directory: directory)

        let orphanDirectory = directory
            .appendingPathComponent("Assets/thumbnail", isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: true
        )
        let orphan = orphanDirectory.appendingPathComponent("orphan.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: orphan)

        let report = try await repository.repair()

        #expect(report.orphanedFilesRemoved == ["Assets/thumbnail/orphan.png"])
        #expect(
            FileManager.default.fileExists(atPath: lease.fileURL.path),
            "The lease file must survive cache repair"
        )
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}
