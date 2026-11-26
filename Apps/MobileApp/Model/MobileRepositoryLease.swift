import Darwin
import Foundation

/// A process-lifetime exclusive lease on one mobile repository directory.
///
/// Apple documents that app-target App Intents execute from the app bundle,
/// but it does **not** promise that the runtime can never create a second
/// process. Daybreak therefore does not claim same-process execution as an
/// invariant. This lease fails closed if another process already owns the
/// repository: the newcomer performs no writes and returns
/// `repositoryBusyByAnotherProcess`, which App Intents surface as an explicit
/// retryable error instead of reporting a fake daily success. Normal
/// foreground-plus-background use still goes through the one
/// `MobileDataStore.shared` instance and does not re-acquire the lease.
///
/// The lock file lives at the repository root, deliberately outside
/// `Assets/**`. Cache cleanup and `repair()` only enumerate `Assets/<kind>`, so
/// the lease file is never deleted or recreated by normal product operations.
final class MobileRepositoryLease: @unchecked Sendable {
    static let fileName = ".process-lease"

    private let descriptor: Int32
    let fileURL: URL

    private init(descriptor: Int32, fileURL: URL) {
        self.descriptor = descriptor
        self.fileURL = fileURL
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Acquires a non-blocking exclusive lock. Failure is explicit: a caller
    /// must not write the repository without a lease.
    static func acquire(directory: URL) throws -> MobileRepositoryLease {
        let normalized = directory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: normalized,
                withIntermediateDirectories: true
            )
        } catch {
            throw MobileStoreError.repositoryUnavailable(
                "cannot create repository directory: \(MobileErrorText.describe(error))"
            )
        }

        let lockURL = normalized.appendingPathComponent(fileName, isDirectory: false)
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw MobileStoreError.repositoryUnavailable(
                "cannot open process lease: errno \(errno)"
            )
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                if let owner = ownerPID(at: lockURL), owner == getpid() {
                    throw MobileStoreError.repositoryAlreadyOpenInProcess
                }
                throw MobileStoreError.repositoryBusyByAnotherProcess
            }
            throw MobileStoreError.repositoryUnavailable(
                "cannot acquire process lease: errno \(code)"
            )
        }

        writeOwnerPID(descriptor)
        return MobileRepositoryLease(descriptor: descriptor, fileURL: lockURL)
    }

    /// Diagnostic only. The lock itself is authoritative; a malformed or
    /// unreadable PID file does not make an unowned lock appear owned.
    private static func ownerPID(at url: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init)
        return firstLine.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func writeOwnerPID(_ descriptor: Int32) {
        let payload = Array("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        payload.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = pwrite(descriptor, baseAddress, buffer.count, 0)
        }
    }
}
