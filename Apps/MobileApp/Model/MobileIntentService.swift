import DaybreakCore
import Foundation

// MARK: - Intent request and result

/// One image the app can hand to an App Intent. `.today(market: nil)` follows
/// the user's preferred market; any explicit market is resolved independently.
public enum MobileIntentImageSelection: Hashable, Sendable {
    case today(market: Market?)
    case date(LocalDate, market: Market?)
    case wallpaper(WallpaperID)
    case latestFavorite
    case favorite(WallpaperID)
    case randomCached
    case randomFavorite
    case currentSelection
}

/// A real, readable file prepared for Shortcuts. `fileURL` is an app-owned
/// temporary copy, never the repository's only original, so the caller may set
/// `IntentFile.removedOnCompletion = true`.
public struct MobileIntentImage: Hashable, Sendable {
    public let wallpaperID: WallpaperID
    public let fileURL: URL
    public let mimeType: String
    public let fileExtension: String
    public let sourceDate: LocalDate
    public let market: Market
    public let title: String?
    public let sourceURL: URL?
    public let isOriginal: Bool
    public let pixelWidth: Int?
    public let pixelHeight: Int?
}

// MARK: - Service

/// Background-safe App Intent facade.
///
/// This actor never touches `MobileStore`, SwiftUI or `UIApplication`, so an
/// intent launched with no foreground scene can still read the process-wide
/// repository. No extension uses this type. If another process owns the
/// repository lease, every operation throws `repositoryBusyByAnotherProcess`;
/// the intent reports a retryable failure rather than a fabricated success.
public actor MobileIntentService {
    public static let shared = MobileIntentService()

    private let dataStore: MobileDataStore
    private let settingsStore: any MobileSettingsPersisting

    public init(
        dataStore: MobileDataStore = .shared,
        settingsStore: any MobileSettingsPersisting = UserDefaultsMobileSettingsStore.standard
    ) {
        self.dataStore = dataStore
        self.settingsStore = settingsStore
    }

    // MARK: Market and snapshots

    public func preferredMarket() async -> Market {
        MobileDataStore.resolvedMarket(settings: settingsStore.load())
    }

    /// Today's image for intent use. A cached older occurrence is never
    /// relabeled as today: when the provider has not published the market's
    /// current date, this throws `noImageForDate`.
    public func todaySnapshot(market: Market?) async throws -> MobileTodaySnapshot {
        try await todaySnapshot(market: market, allowNetwork: true)
    }

    private func todaySnapshot(
        market: Market?,
        allowNetwork: Bool
    ) async throws -> MobileTodaySnapshot {
        let resolved = try await resolveMarket(market)
        let snapshot = try await dataStore.todaySnapshot(
            market: resolved,
            allowNetwork: allowNetwork
        )
        guard snapshot.isSourceDateToday else {
            throw MobileStoreError.noImageForDate(
                snapshot.marketToday,
                snapshot.market
            )
        }
        return snapshot
    }

    // MARK: Selection context

    public func currentSelection() async -> OccurrenceKey? {
        await dataStore.currentSelection()
    }

    public func recordSelection(_ key: OccurrenceKey?) async {
        await dataStore.recordCurrentSelection(key)
    }

    public func currentSelectionWallpaperID() async -> WallpaperID? {
        guard let key = await dataStore.currentSelection() else { return nil }
        guard let snapshot = try? await dataStore.repositorySnapshot() else {
            return nil
        }
        return snapshot.occurrences.first(where: { $0.id == key })?.wallpaperID
    }

    /// Accepts the canonical `bing:<sourceImageID>` text used by Shortcuts and
    /// run-shortcut URLs. Lookup is image-level; duplicate dates/markets are
    /// expected and do not change the identity.
    public func lookupWallpaperID(_ rawValue: String) async -> WallpaperID? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 512,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        let parts = trimmed.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }
        let source = SourceID(String(parts[0]))
        guard source == .bing else { return nil }
        let imageID = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let wallpaperID = WallpaperID(
            source: source,
            sourceImageID: imageID
        )
        guard wallpaperID.isValid,
              wallpaperID.sourceImageID.utf8.count <= 64
        else {
            return nil
        }

        guard let snapshot = try? await dataStore.repositorySnapshot() else {
            return nil
        }
        let known = snapshot.occurrences.contains {
            $0.wallpaperID == wallpaperID
        } || snapshot.assets.contains {
            $0.wallpaperID == wallpaperID
        } || snapshot.favoriteWallpaperIDs.contains(wallpaperID)
        return known ? wallpaperID : nil
    }

    // MARK: Image preparation

    public func prepareIntentImage(
        _ selection: MobileIntentImageSelection,
        variant: AssetKind = .original,
        allowNetwork: Bool = true
    ) async throws -> MobileIntentImage {
        let target = try await resolveTarget(
            selection,
            allowNetwork: allowNetwork
        )

        let fileURL: URL
        if let cached = try await dataStore.cachedImageURL(
            kind: variant,
            for: target.wallpaperID
        ) {
            fileURL = cached
        } else {
            fileURL = try await dataStore.ensureImage(
                kind: variant,
                for: target.occurrence,
                allowNetwork: allowNetwork
            )
        }

        let temporaryURL = try copyToTemporary(fileURL)
        let descriptor = bestDescriptor(
            target: target,
            preferredKind: variant
        )
        let fileExtension = temporaryURL.pathExtension.lowercased()
        return MobileIntentImage(
            wallpaperID: target.wallpaperID,
            fileURL: temporaryURL,
            mimeType: MobileDataStore.mimeType(forFileExtension: fileExtension),
            fileExtension: fileExtension,
            sourceDate: target.occurrence.localDate,
            market: target.market,
            title: target.metadata?.title ?? target.wallpaper?.canonicalTitle,
            sourceURL: target.metadata?.sourceURL ?? target.wallpaper?.sourceURL,
            isOriginal: variant == .original,
            pixelWidth: descriptor?.pixelWidth,
            pixelHeight: descriptor?.pixelHeight
        )
    }

    // MARK: Resolution

    private struct ResolvedTarget {
        let occurrence: WallpaperOccurrence
        let metadata: WallpaperMetadataRecord?
        let wallpaper: WallpaperRecord?
        let market: Market
        let wallpaperID: WallpaperID
    }

    private func resolveTarget(
        _ selection: MobileIntentImageSelection,
        allowNetwork: Bool
    ) async throws -> ResolvedTarget {
        switch selection {
        case .today(let market):
            let snapshot = try await todaySnapshot(
                market: market,
                allowNetwork: allowNetwork
            )
            return ResolvedTarget(
                occurrence: snapshot.occurrence,
                metadata: snapshot.metadata,
                wallpaper: snapshot.wallpaper,
                market: snapshot.market,
                wallpaperID: snapshot.wallpaperID
            )

        case .date(let date, let requestedMarket):
            let market = try await resolveMarket(requestedMarket)
            let key = OccurrenceKey(source: .bing, market: market, localDate: date)
            guard let day = try await dataStore.daySnapshot(for: key) else {
                throw MobileStoreError.noImageForDate(date, market)
            }
            return ResolvedTarget(
                occurrence: day.occurrence,
                metadata: day.metadata,
                wallpaper: day.wallpaper,
                market: market,
                wallpaperID: day.wallpaperID
            )

        case .wallpaper(let wallpaperID):
            return try await target(for: wallpaperID)

        case .latestFavorite:
            guard let wallpaperID = try await latestDatedFavorite() else {
                throw MobileStoreError.noFavorites
            }
            return try await target(for: wallpaperID)

        case .favorite(let wallpaperID):
            let favorites = try await dataStore.favoriteWallpaperIDs()
            guard favorites.contains(wallpaperID) else {
                throw MobileStoreError.noFavorites
            }
            return try await target(for: wallpaperID)

        case .randomCached:
            guard let wallpaperID = try await randomCachedWallpaperID() else {
                throw MobileStoreError.noCachedImages
            }
            return try await target(for: wallpaperID)

        case .randomFavorite:
            guard let wallpaperID = try await randomFavoriteWallpaperID() else {
                throw MobileStoreError.noFavorites
            }
            return try await target(for: wallpaperID)

        case .currentSelection:
            guard let key = await dataStore.currentSelection() else {
                throw MobileStoreError.noCurrentSelection
            }
            guard let day = try await dataStore.daySnapshot(for: key) else {
                throw MobileStoreError.noCurrentSelection
            }
            return ResolvedTarget(
                occurrence: day.occurrence,
                metadata: day.metadata,
                wallpaper: day.wallpaper,
                market: day.market,
                wallpaperID: day.wallpaperID
            )
        }
    }

    private func target(for wallpaperID: WallpaperID) async throws -> ResolvedTarget {
        guard let occurrence = try await dataStore.latestOccurrence(for: wallpaperID) else {
            throw MobileStoreError.unknownWallpaper(wallpaperID.description)
        }
        let snapshot = try await dataStore.repositorySnapshot()
        return ResolvedTarget(
            occurrence: occurrence,
            metadata: snapshot.metadata(for: occurrence.id),
            wallpaper: snapshot.wallpapers.first { $0.wallpaperID == wallpaperID },
            market: occurrence.market,
            wallpaperID: wallpaperID
        )
    }

    private func resolveMarket(_ market: Market?) async throws -> Market {
        guard let market else { return await preferredMarket() }
        guard let profile = BingMarketProfile.profile(for: market) else {
            throw MobileStoreError.unsupportedMarket(market.rawValue)
        }
        return profile.market
    }

    // MARK: Selection heuristics

    private func latestDatedFavorite() async throws -> WallpaperID? {
        let snapshot = try await dataStore.repositorySnapshot()
        let favorites = snapshot.favoriteWallpaperIDs
        guard !favorites.isEmpty else { return nil }
        let dated = snapshot.occurrences
            .filter { favorites.contains($0.wallpaperID) }
            .sorted { lhs, rhs in
                if lhs.localDate != rhs.localDate {
                    return lhs.localDate > rhs.localDate
                }
                return lhs.id.description < rhs.id.description
            }
        return dated.first?.wallpaperID
    }

    private func randomCachedWallpaperID() async throws -> WallpaperID? {
        let snapshot = try await dataStore.repositorySnapshot()
        let available = snapshot.availableThumbnailIDs.union(
            snapshot.availableOriginalIDs
        )
        guard !available.isEmpty else { return nil }
        let candidates = snapshot.occurrences
            .filter { available.contains($0.wallpaperID) }
        guard !candidates.isEmpty else { return nil }
        return candidates.randomElement()?.wallpaperID
    }

    private func randomFavoriteWallpaperID() async throws -> WallpaperID? {
        let snapshot = try await dataStore.repositorySnapshot()
        let favorites = snapshot.favoriteWallpaperIDs
        guard !favorites.isEmpty else { return nil }
        let dated = Set(
            snapshot.occurrences
                .filter { favorites.contains($0.wallpaperID) }
                .map(\.wallpaperID)
        )
        guard !dated.isEmpty else { return nil }
        return dated.randomElement()
    }

    // MARK: Temporary image copies

    private func copyToTemporary(_ source: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DaybreakIntent", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw MobileStoreError.imageUnavailable(
                MobileErrorText.describe(error)
            )
        }
        removeStaleTemporaryFiles(in: directory, fileManager: fileManager)

        let rawExtension = source.pathExtension.lowercased()
        let allowed: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
        let fileExtension = allowed.contains(rawExtension) ? rawExtension : "jpg"
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            try fileManager.copyItem(at: source, to: destination)
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                try? fileManager.removeItem(at: destination)
                throw MobileStoreError.imageUnavailable("empty intent image copy")
            }
            return destination
        } catch let error as MobileStoreError {
            throw error
        } catch {
            throw MobileStoreError.imageUnavailable(
                MobileErrorText.describe(error)
            )
        }
    }

    private func removeStaleTemporaryFiles(
        in directory: URL,
        fileManager: FileManager
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in contents {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ),
            let modified = values.contentModificationDate,
            modified < cutoff
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private func bestDescriptor(
        target: ResolvedTarget,
        preferredKind: AssetKind
    ) -> ImageVariantDescriptor? {
        let descriptors = target.metadata?.variants
            ?? target.wallpaper?.variants
            ?? []
        switch preferredKind {
        case .original:
            return descriptors.max { lhs, rhs in
                (lhs.pixelWidth ?? 0) < (rhs.pixelWidth ?? 0)
            }
        case .thumbnail:
            return descriptors.min { lhs, rhs in
                (lhs.pixelWidth ?? Int.max) < (rhs.pixelWidth ?? Int.max)
            } ?? descriptors.first
        }
    }
}
