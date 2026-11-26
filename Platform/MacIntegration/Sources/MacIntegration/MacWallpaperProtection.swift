import DaybreakCore
import Foundation

public enum MacWallpaperProtectionError: Error, LocalizedError, Sendable {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Wallpaper cache protection has not been connected to the repository."
        }
    }
}

/// Fail-closed default used by lower-level appliers that have not been wired to
/// a repository. Every wallpaper write is refused until a real protector is
/// supplied.
public struct UnavailableWallpaperProtection: WallpaperApplicationProtecting {
    public init() {}

    public func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        throw MacWallpaperProtectionError.notConfigured
    }
}

/// Allows the app to attach the shared repository after the integration has
/// been created. The box itself holds no cache state; the repository actor
/// performs the atomic reservation.
actor MacWallpaperProtectionBox: WallpaperApplicationProtecting {
    private var protection: (any WallpaperApplicationProtecting)?

    init(_ protection: (any WallpaperApplicationProtecting)? = nil) {
        self.protection = protection
    }

    func set(_ protection: any WallpaperApplicationProtecting) {
        self.protection = protection
    }

    func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        guard let protection else {
            throw MacWallpaperProtectionError.notConfigured
        }
        return try await protection.reserveAppliedProtection(forImageURL: url)
    }

    func completeAppliedProtection(forImageURL url: URL, succeeded: Bool) async {
        await protection?.completeAppliedProtection(
            forImageURL: url,
            succeeded: succeeded
        )
    }
}
