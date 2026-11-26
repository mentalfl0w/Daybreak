import DaybreakCore
import Foundation
import Observation

/// Coordinates connected-display selection and current-wallpaper cache protection.
///
/// The protection set is derived only from currently connected displays. A
/// reconciliation is considered complete only when each display has a
/// readable current wallpaper, a confirmed Daybreak write, or a bounded
/// previous fallback.
@MainActor
@Observable
final class WallpaperDisplayCoordinator {
    private static let appliedProtectionDefaultsKey = "daybreak.appliedWallpapersByDisplay.v1"

    private let defaults: UserDefaults
    private let wallpaper: any MacWallpaperIntegrating
    let currentWallpaperProtection: CurrentWallpaperProtectionGate

    private(set) var displays: [DesktopDisplayOption] = []
    private(set) var selectedDisplayID: DesktopDisplayID?

    @ObservationIgnored private var appliedWallpaperByDisplay: [DesktopDisplayID: WallpaperID]
    @ObservationIgnored private var appliedProtectionGeneration = 0

    init(
        defaults: UserDefaults,
        wallpaper: any MacWallpaperIntegrating,
        currentWallpaperProtection: CurrentWallpaperProtectionGate
    ) {
        self.defaults = defaults
        self.wallpaper = wallpaper
        self.currentWallpaperProtection = currentWallpaperProtection
        self.appliedWallpaperByDisplay = Self.loadAppliedProtection(from: defaults)
    }

    /// Replaces the visible topology while preserving a selection that still
    /// exists. A new display never steals the user's current target, and a
    /// disconnected target falls back to the first connected display.
    func applyConnectedDisplays(_ updated: [DesktopDisplayOption]) {
        if displays != updated {
            displays = updated
        }
        if let selectedDisplayID,
           updated.contains(where: { $0.id == selectedDisplayID }) {
            return
        }
        selectedDisplayID = updated.first?.id
    }

    func selectDisplay(_ id: DesktopDisplayID?) {
        selectedDisplayID = id
    }

    /// Refreshes the bounded set of currently applied wallpaper IDs. The
    /// returned error is formatted by AppModel for the existing UI message.
    func refreshAppliedProtection(service: TodayService?) async -> Error? {
        appliedProtectionGeneration &+= 1
        let generation = appliedProtectionGeneration
        guard let service else {
            currentWallpaperProtection.setReconciled(false)
            return nil
        }

        let connectedDisplayIDs = Set(displays.map(\.id))
        guard !connectedDisplayIDs.isEmpty else {
            // Topology is unknown or transiently empty. Keep the previous live
            // set, but fail closed for destructive cleanup until a display is visible.
            currentWallpaperProtection.setReconciled(false)
            return nil
        }

        let currentURLs = await wallpaper.currentWallpaperURLs()
        guard generation == appliedProtectionGeneration else { return nil }
        let confirmedURLs = await wallpaper.appliedWallpaperURLs()
        guard generation == appliedProtectionGeneration else { return nil }
        let urls = Set(currentURLs.values).union(confirmedURLs.values)
        let resolved = await service.appliedWallpaperIDs(forAssetURLs: Array(urls))
        guard generation == appliedProtectionGeneration else { return nil }

        // If any connected display has neither a readable current URL nor a
        // confirmed/previous fallback, its current image is unknown. Replace
        // the live set anyway, but do not permit automatic original eviction.
        let hasUnknownDisplay = connectedDisplayIDs.contains { displayID in
            currentURLs[displayID] == nil
                && confirmedURLs[displayID] == nil
                && appliedWallpaperByDisplay[displayID] == nil
        }

        let candidate = AppliedWallpaperProtection.current(
            previous: appliedWallpaperByDisplay,
            connectedDisplayIDs: connectedDisplayIDs,
            currentURLs: currentURLs,
            confirmedURLs: confirmedURLs,
            resolved: resolved
        )

        do {
            try await service.replaceAppliedWallpapers(Set(candidate.values))
            guard generation == appliedProtectionGeneration else { return nil }
            currentWallpaperProtection.setReconciled(!hasUnknownDisplay)
            if candidate != appliedWallpaperByDisplay {
                appliedWallpaperByDisplay = candidate
                persistAppliedProtection(candidate)
            }
        } catch {
            guard generation == appliedProtectionGeneration else { return nil }
            currentWallpaperProtection.setReconciled(false)
            return error
        }
        return nil
    }

    /// Skips original eviction until current wallpaper protection is known to
    /// cover every connected display.
    func enforceAutomaticCacheLimits(service: TodayService?) async {
        guard let service else { return }
        let limits = currentWallpaperProtection.isReconciled
            ? CacheLimits()
            : CacheLimits(
                thumbnailBytes: CacheLimits().thumbnailBytes,
                originalBytes: Int.max
            )
        _ = await service.enforceCacheLimits(limits)
    }

    private func persistAppliedProtection(
        _ mapping: [DesktopDisplayID: WallpaperID]
    ) {
        var raw: [String: WallpaperID] = [:]
        for (displayID, wallpaperID) in mapping
        where !displayID.rawValue.isEmpty && wallpaperID.isValid {
            raw[displayID.rawValue] = wallpaperID
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.appliedProtectionDefaultsKey)
    }

    private static func loadAppliedProtection(
        from defaults: UserDefaults
    ) -> [DesktopDisplayID: WallpaperID] {
        guard let data = defaults.data(forKey: appliedProtectionDefaultsKey),
              let raw = try? JSONDecoder().decode([String: WallpaperID].self, from: data)
        else {
            return [:]
        }
        var result: [DesktopDisplayID: WallpaperID] = [:]
        for (displayRawValue, wallpaperID) in raw
        where !displayRawValue.isEmpty && wallpaperID.isValid {
            result[DesktopDisplayID(displayRawValue)] = wallpaperID
        }
        return result
    }
}

/// Shared liveness state for the current-desktop protection set.
///
/// It becomes true only after a live reconciliation successfully covers every
/// connected display (each has a readable current URL, a confirmed write, or a
/// bounded previous fallback). While it is false, or while topology is unknown,
/// destructive original cleanup must not run because the current wallpaper
/// cannot be proven protected. A later trustworthy reconciliation turns it
/// back on so cleanup resumes.
@MainActor
final class CurrentWallpaperProtectionGate {
    private(set) var isReconciled = false

    func setReconciled(_ reconciled: Bool) {
        guard isReconciled != reconciled else { return }
        isReconciled = reconciled
    }
}

/// Pure per-display reconciliation used by the wallpaper display coordinator.
///
/// This builds only the currently accessible desktop set; it never merges in
/// historical images. A readable current URL is authoritative. When it cannot
/// be read, the last confirmed Daybreak write is the fallback, then the
/// previous bounded per-display entry.
enum AppliedWallpaperProtection {
    static func current(
        previous: [DesktopDisplayID: WallpaperID],
        connectedDisplayIDs: Set<DesktopDisplayID>,
        currentURLs: [DesktopDisplayID: URL],
        confirmedURLs: [DesktopDisplayID: URL],
        resolved: [URL: WallpaperID]
    ) -> [DesktopDisplayID: WallpaperID] {
        var result: [DesktopDisplayID: WallpaperID] = [:]
        for displayID in connectedDisplayIDs {
            if let currentURL = currentURLs[displayID] {
                // A readable URL is authoritative, even when it is external
                // and therefore has no repository identity. Keeping a previous
                // Daybreak image here would over-protect a non-current file.
                if let wallpaperID = resolved[currentURL] {
                    result[displayID] = wallpaperID
                }
                continue
            }
            if let confirmedURL = confirmedURLs[displayID],
               let wallpaperID = resolved[confirmedURL] {
                result[displayID] = wallpaperID
                continue
            }
            if let previousID = previous[displayID] {
                result[displayID] = previousID
            }
        }
        return result
    }
}
