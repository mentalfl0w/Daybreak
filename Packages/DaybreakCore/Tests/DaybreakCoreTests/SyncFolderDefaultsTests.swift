import Foundation
import Testing
@testable import DaybreakCore

/// Synthetic home directories only. No real iCloud Drive content is read,
/// created or required by these tests.
@Suite("Sync default folder")
struct SyncFolderDefaultsTests {
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeCloudDocs(in home: URL) throws {
        try FileManager.default.createDirectory(
            at: SyncFolderDefaults.iCloudDriveRoot(homeDirectory: home),
            withIntermediateDirectories: true
        )
    }

    @Test func usesDaybreakFolderInsideICloudDrive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeCloudDocs(in: home)

        let folder = try #require(SyncFolderDefaults.prepareDefaultFolder(homeDirectory: home))

        #expect(folder.lastPathComponent == "Daybreak")
        #expect(folder.deletingLastPathComponent().lastPathComponent == "com~apple~CloudDocs")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func createsMissingDaybreakFolder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeCloudDocs(in: home)

        let folder = try #require(SyncFolderDefaults.prepareDefaultFolder(homeDirectory: home))

        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func adoptsExistingDaybreakFolderWithoutReplacingContent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeCloudDocs(in: home)
        let folder = SyncFolderDefaults.defaultFolder(homeDirectory: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: marker)

        let resolved = try #require(SyncFolderDefaults.prepareDefaultFolder(homeDirectory: home))

        #expect(resolved.standardizedFileURL == folder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func returnsNilWhenICloudDriveIsUnavailable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(SyncFolderDefaults.prepareDefaultFolder(homeDirectory: home) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: SyncFolderDefaults.defaultFolder(homeDirectory: home).path
        ))
    }

    @Test func returnsNilWhenDefaultPathIsAFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeCloudDocs(in: home)
        try Data().write(to: SyncFolderDefaults.defaultFolder(homeDirectory: home))

        #expect(SyncFolderDefaults.prepareDefaultFolder(homeDirectory: home) == nil)
    }

    @Test func detectsPickedICloudDriveRootOnly() {
        let root = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs")
        let child = root.appendingPathComponent("Daybreak", isDirectory: true)

        #expect(SyncFolderDefaults.isICloudDriveRoot(root))
        #expect(!SyncFolderDefaults.isICloudDriveRoot(child))
        #expect(!SyncFolderDefaults.isICloudDriveRoot(root.appendingPathComponent("Other")))
    }

    @Test func daybreakSubfolderKeepsRootAsParent() {
        let root = URL(fileURLWithPath: "/Users/example/Library/Mobile Documents/com~apple~CloudDocs")
        let child = SyncFolderDefaults.daybreakFolder(inICloudDriveRoot: root)

        #expect(child.lastPathComponent == "Daybreak")
        #expect(child.deletingLastPathComponent().path == root.path)
    }
}
