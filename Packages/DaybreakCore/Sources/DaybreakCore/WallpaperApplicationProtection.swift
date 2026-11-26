import Foundation

/// Platform integrations must reserve cache protection through the repository
/// actor before asking the system to install a wallpaper.
///
/// The reservation is persisted, so a concurrent cache cleanup cannot delete
/// the source file between the write and its completion. Returning `nil` means
/// the URL is not a repository original or its file is missing; callers must
/// conservatively refuse the write instead of guessing an identity.
public protocol WallpaperApplicationProtecting: Sendable {
    func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID?

    /// Reports that the system write attempt finished. A successful attempt
    /// keeps the image protected as current-desktop state; a failed or blocked
    /// attempt releases only the in-flight reservation.
    func completeAppliedProtection(forImageURL url: URL, succeeded: Bool) async
}

extension WallpaperApplicationProtecting {
    /// Integrations that do not reserve through this protocol have nothing to
    /// release. Production appliers always use the repository-backed
    /// implementation below.
    public func completeAppliedProtection(forImageURL url: URL, succeeded: Bool) async {}
}
