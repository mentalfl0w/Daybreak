import Foundation

/// Bounded, path-free sync diagnostics.
///
/// Sync failures on a device are hard to inspect: the UI can only show a
/// status, and `os_log` is not always reachable. This appends short stage
/// names and error cases (never file paths or content) to a size-capped file
/// next to the sync checkpoint so a failure can be reported precisely.
enum SyncDiagnostics {
    static let fileName = "sync-diagnostics.log"
    static let maxBytes = 32 * 1024

    static func record(_ event: String, in directory: URL) {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let line = "\(Self.timestamp()) \(event)\n"
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > Self.maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {
            // Diagnostics must never affect sync behavior.
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
