import Foundation

// MARK: - Protection calculations

enum RepositoryProtection {
    static func reasons(
        for wallpaperID: WallpaperID,
        favorites: Set<WallpaperID>,
        pinned: Set<PinnedOccurrence>,
        applied: Set<WallpaperID>
    ) -> Set<PinReason> {
        var reasons: Set<PinReason> = []
        if favorites.contains(wallpaperID) {
            reasons.insert(.favorite)
        }
        if pinned.contains(where: { $0.wallpaperID == wallpaperID }) {
            reasons.insert(.pinnedDate)
        }
        if applied.contains(wallpaperID) {
            reasons.insert(.currentlyApplied)
        }
        return reasons
    }

    static func protectedImageIDs(
        favorites: Set<WallpaperID>,
        pinned: Set<PinnedOccurrence>,
        applied: Set<WallpaperID>,
        reservations: Set<WallpaperID>
    ) -> Set<WallpaperID> {
        var protected = favorites.union(applied).union(reservations)
        for pin in pinned {
            protected.insert(pin.wallpaperID)
        }
        return protected
    }

    static func isProtected(
        _ wallpaperID: WallpaperID,
        favorites: Set<WallpaperID>,
        pinned: Set<PinnedOccurrence>,
        applied: Set<WallpaperID>,
        reservations: Set<WallpaperID>
    ) -> Bool {
        favorites.contains(wallpaperID)
            || applied.contains(wallpaperID)
            || reservations.contains(wallpaperID)
            || pinned.contains(where: { $0.wallpaperID == wallpaperID })
    }
}
