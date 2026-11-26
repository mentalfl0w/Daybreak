import DaybreakCore
import Foundation

/// A display state that was verified against the active manual-apply
/// preflight observation.
struct MacVerifiedDisplayObservation: Hashable, Sendable {
    /// `nil` means the public API did not report a current image URL. A nil
    /// URL is never an identity on its own: the broker additionally requires
    /// unchanged options, a live unexpired scope, and no invalidating event.
    let imageURL: URL?
    let options: MacWallpaperOptions
}

/// The write-side contract for one manual-apply pass.
struct MacManualWriteScope: Sendable {
    let preflightID: UUID
    let expiresAt: Date
    let wallpaperByDisplay: [DesktopDisplayID: DesktopWallpaper]
    let verifiedByDisplay: [DesktopDisplayID: MacVerifiedDisplayObservation]
    /// In read-only mode the write gate was opened only for this manual action,
    /// so displays outside the preflight must not be written by the same pass.
    let restrictsNonTargets: Bool
    /// An explicit one-display confirmation may replace a wallpaper the user
    /// previously pinned. Automatic event passes never set this.
    let overridesManualProtection: Bool
}

enum MacManualWriteDecision: Equatable, Sendable {
    /// This display is not part of the manual apply; normal ledger/policy
    /// rules apply.
    case notInScope
    case allowed
    case blocked(MacOverwriteBlockReason)
}

/// Shared, lock-protected write authorization for the manual-apply path.
///
/// `MacDesktopIntegration` begins a scope only after re-reading and verifying
/// the live display state against the preflight. Any observed desktop event
/// invalidates the scope immediately (synchronously), so the applier refuses
/// every remaining target write even if an approval or ledger entry would
/// otherwise allow it. The scope is kept as invalidated until the pass ends so
/// the applier can distinguish "not part of this manual apply" from "this
/// manual apply was invalidated and must fail closed".
final class MacManualWriteBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: MacManualWriteScope?
    private var invalidated = false
    private var blockedDisplays: Set<DesktopDisplayID> = []

    func begin(_ scope: MacManualWriteScope) {
        lock.lock()
        self.scope = scope
        invalidated = false
        blockedDisplays = []
        lock.unlock()
    }

    /// Invalidate the current manual-apply scope without dropping it. The
    /// applier must fail closed for every target display until `end()`.
    func invalidate() {
        lock.lock()
        if scope != nil {
            invalidated = true
        }
        lock.unlock()
    }

    func end() {
        lock.lock()
        scope = nil
        invalidated = false
        blockedDisplays = []
        lock.unlock()
    }

    func decision(
        displayID: DesktopDisplayID,
        target: DesktopWallpaper,
        observedURL: URL?,
        observedOptions: MacWallpaperOptions,
        at date: Date
    ) -> MacManualWriteDecision {
        lock.lock()
        defer { lock.unlock() }
        guard let scope else { return .notInScope }
        guard let expectedTarget = scope.wallpaperByDisplay[displayID] else {
            if scope.restrictsNonTargets {
                blockedDisplays.insert(displayID)
                return .blocked(.unverifiedExternalWallpaper)
            }
            return .notInScope
        }

        let reason: MacOverwriteBlockReason?
        if invalidated || date >= scope.expiresAt || expectedTarget != target {
            reason = .unverifiedExternalWallpaper
        } else if let verified = scope.verifiedByDisplay[displayID],
                  verified.imageURL == observedURL,
                  verified.options == observedOptions {
            // A non-nil URL is an exact identity match. Two nil URLs cannot
            // prove the same wallpaper through public APIs; in that case the
            // explicit confirmation, unchanged options, live scope and
            // synchronous event invalidation are the authorization boundary.
            reason = nil
        } else if observedURL == nil {
            reason = .unreadableCurrentWallpaper
        } else {
            reason = .unverifiedExternalWallpaper
        }

        if let reason {
            blockedDisplays.insert(displayID)
            return .blocked(reason)
        }
        return .allowed
    }

    /// True only for a live, in-scope, non-invalidated explicit confirmation.
    func authorizesManualProtectionOverride(
        displayID: DesktopDisplayID,
        target: DesktopWallpaper,
        at date: Date
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let scope, !invalidated, date < scope.expiresAt,
              scope.overridesManualProtection,
              scope.wallpaperByDisplay[displayID] == target
        else {
            return false
        }
        return true
    }

    var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    var blocked: Set<DesktopDisplayID> {
        lock.lock()
        defer { lock.unlock() }
        return blockedDisplays
    }

    var activePreflightID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return scope?.preflightID
    }
}
