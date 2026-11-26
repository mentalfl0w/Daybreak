import DaybreakCore
import Foundation

enum MacOverwriteDecision: Hashable, Sendable {
    case allowed
    case blocked(MacOverwriteBlockReason)
}

/// Conservative, pure overwrite decision.
///
/// Public APIs cannot identify who changed a wallpaper. Daybreak therefore
/// only overwrites an observed image when it is the exact target, an image
/// Daybreak previously wrote (persisted ledger), or an image the user
/// explicitly approved for this exact display and target. Everything else is
/// paused and surfaced instead of assumed to be safe.
enum MacOverwritePolicy {
    static func decide(
        observedImageURL: URL?,
        desired: DesktopWallpaper,
        isManaged: Bool,
        hasMatchingApproval: Bool,
        isManuallyProtected: Bool,
        allowsAutomaticOverwrite: Bool = false
    ) -> MacOverwriteDecision {
        // An explicit manual protection is a stronger signal than the broad
        // automatic-overwrite opt-in. Only a deliberate per-display action may
        // bypass it.
        if isManuallyProtected {
            return .blocked(.manualProtection)
        }
        // Nil is not a wallpaper identity. Approvals and the managed ledger
        // must never turn "could not read the current wallpaper" into a safe
        // overwrite; only the separate automatic-overwrite consent may.
        guard let observedImageURL else {
            return allowsAutomaticOverwrite
                ? .allowed
                : .blocked(.unreadableCurrentWallpaper)
        }
        if observedImageURL == desired.imageURL {
            return .allowed
        }
        if isManaged {
            return .allowed
        }
        if hasMatchingApproval {
            return .allowed
        }
        if allowsAutomaticOverwrite {
            return .allowed
        }
        return .blocked(.unverifiedExternalWallpaper)
    }
}
