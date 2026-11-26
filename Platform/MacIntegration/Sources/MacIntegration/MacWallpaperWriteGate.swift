import DaybreakCore
import Foundation

/// The single point through which every real wallpaper write must pass.
///
/// The gate starts closed (`readOnly`). `MacDesktopIntegration` grants access
/// only after an explicit manual-apply consent, an explicit automation opt-in,
/// or a persisted automation mode at launch. Direct `grant()` is intentionally
/// module-internal so app code cannot bypass the consent and preflight flow.
public actor MacWallpaperWriteGate {
    public private(set) var access: MacWallpaperWriteAccess = .readOnly

    public init() {}

    func grant() {
        access = .authorized
    }

    public func revoke() {
        access = .readOnly
    }

    public func isAuthorized() -> Bool {
        access == .authorized
    }

    /// Called by `MacWallpaperApplier` immediately before every write.
    func requireWritable() throws {
        guard access == .authorized else {
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .permissionDenied,
                message: "Wallpaper writes are disabled until the user explicitly authorizes them."
            )
        }
    }
}
