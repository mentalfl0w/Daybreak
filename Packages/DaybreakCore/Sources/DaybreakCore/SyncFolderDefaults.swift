import Foundation

/// Locates the shared folder Daybreak uses when the user has not authorized
/// one yet.
///
/// The product default is `iCloud Drive/Daybreak`. macOS builds are not
/// sandboxed, so the app can create that folder directly. iOS builds are
/// sandboxed and may only reach iCloud Drive through the document picker, so
/// this type only provides the path helpers there; the app creates the folder
/// inside the scope the user granted.
public enum SyncFolderDefaults {
    /// Folder name inside iCloud Drive. Kept as a constant so macOS, iOS and
    /// the documentation cannot drift apart.
    public static let folderName = "Daybreak"

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` — the iCloud Drive
    /// root as it appears on both platforms.
    public static func iCloudDriveRoot(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// `iCloud Drive/Daybreak`.
    public static func defaultFolder(homeDirectory: URL) -> URL {
        iCloudDriveRoot(homeDirectory: homeDirectory)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Returns a ready-to-authorize default folder, creating it when iCloud
    /// Drive is available. Returns `nil` when iCloud Drive itself is missing so
    /// callers fall back to the folder picker instead of creating a stray
    /// local folder that would never sync.
    public static func prepareDefaultFolder(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = iCloudDriveRoot(homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        let folder = defaultFolder(homeDirectory: homeDirectory)
        if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return nil }
            return folder
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        } catch {
            return nil
        }
    }

    /// True when `url` is the iCloud Drive root itself, which the iOS picker
    /// can return. The app then creates `Daybreak` inside that granted scope.
    public static func isICloudDriveRoot(_ url: URL) -> Bool {
        url.standardizedFileURL.lastPathComponent == "com~apple~CloudDocs"
    }

    /// `Daybreak` inside a picked iCloud Drive root.
    public static func daybreakFolder(inICloudDriveRoot root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }
}
