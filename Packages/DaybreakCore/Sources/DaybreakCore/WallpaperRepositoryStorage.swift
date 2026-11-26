import Foundation

// MARK: - Repository index storage

struct RepositoryIndexFile: Codable, Sendable {
    var schemaVersion: Int
    var occurrences: [WallpaperOccurrence]
    var metadata: [WallpaperMetadataRecord]
    var wallpapers: [WallpaperRecord]
    var stories: [DailyStoryRecord]
    var assets: [CachedImageAsset]
    var favorites: [WallpaperID]
    var pinnedOccurrences: [PinnedOccurrence]
    /// Legacy field. Current-desktop protection is live state re-derived from
    /// system reads, so v2 always writes an empty array and ignores decoded
    /// values. It stays in the file shape to decode version 1 indexes.
    var appliedWallpapers: [WallpaperID]
    var reservations: [AppliedReservation]
    var firstObservedDate: LocalDate?
    var observationStartedAt: Date?
    /// Optional so version 1 and version 2 indexes still decode.
    var sync: RepositorySyncState?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case occurrences
        case metadata
        case wallpapers
        case stories
        case assets
        case favorites
        case pinnedOccurrences
        case appliedWallpapers
        case reservations
        case firstObservedDate
        case observationStartedAt
        case sync
    }

    init(index: RepositoryIndex) {
        self.schemaVersion = RepositorySchema.currentVersion
        self.occurrences = OccurrenceIndex.latest(Array(index.occurrences.values))
        self.metadata = index.metadata.values.sorted { $0.key < $1.key }
        self.wallpapers = index.wallpapers.values.sorted { $0.id < $1.id }
        self.stories = index.stories.values.sorted { $0.id < $1.id }
        self.assets = index.assets.values.sorted { $0.id < $1.id }
        self.favorites = index.favorites.sorted()
        self.pinnedOccurrences = index.pinned.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.wallpaperID < rhs.wallpaperID
        }
        self.appliedWallpapers = []
        self.reservations = index.reservations
            .map { AppliedReservation(wallpaperID: $0.key, reservedAt: $0.value) }
            .sorted { $0.wallpaperID < $1.wallpaperID }
        self.firstObservedDate = index.firstObservedDate
        self.observationStartedAt = index.observationStartedAt
        self.sync = index.sync
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.occurrences = try container.decode([WallpaperOccurrence].self, forKey: .occurrences)
        self.metadata = try container.decode([WallpaperMetadataRecord].self, forKey: .metadata)
        self.wallpapers = try container.decode([WallpaperRecord].self, forKey: .wallpapers)
        self.stories = try container.decode([DailyStoryRecord].self, forKey: .stories)
        self.assets = try container.decode([CachedImageAsset].self, forKey: .assets)
        self.favorites = try container.decode([WallpaperID].self, forKey: .favorites)
        self.pinnedOccurrences = try container.decode([PinnedOccurrence].self, forKey: .pinnedOccurrences)
        self.appliedWallpapers = try container.decodeIfPresent(
            [WallpaperID].self,
            forKey: .appliedWallpapers
        ) ?? []
        self.reservations = try container.decodeIfPresent(
            [AppliedReservation].self,
            forKey: .reservations
        ) ?? []
        self.firstObservedDate = try container.decodeIfPresent(
            LocalDate.self,
            forKey: .firstObservedDate
        )
        self.observationStartedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .observationStartedAt
        )
        self.sync = try container.decodeIfPresent(
            RepositorySyncState.self,
            forKey: .sync
        )
    }

    func makeIndex() throws -> RepositoryIndex {
        var result = RepositoryIndex()

        for occurrence in occurrences {
            try RepositoryValidation.validate(occurrence)
            guard result.occurrences[occurrence.id] == nil else {
                throw RepositoryError.invalidRecord("duplicate occurrence \(occurrence.id)")
            }
            result.occurrences[occurrence.id] = occurrence
        }

        for record in metadata {
            try RepositoryValidation.validate(record)
            guard result.metadata[record.key] == nil else {
                throw RepositoryError.invalidRecord("duplicate metadata \(record.key)")
            }
            if let occurrence = result.occurrences[record.key],
               occurrence.wallpaperID != record.wallpaperID {
                throw RepositoryError.invalidRecord("metadata/occurrence identity mismatch \(record.key)")
            }
            result.metadata[record.key] = record
        }

        for wallpaper in wallpapers {
            try RepositoryValidation.validate(wallpaper)
            guard result.wallpapers[wallpaper.id] == nil else {
                throw RepositoryError.invalidRecord("duplicate wallpaper \(wallpaper.id)")
            }
            result.wallpapers[wallpaper.id] = wallpaper
        }

        for story in stories {
            try RepositoryValidation.validate(story)
            guard result.stories[story.id] == nil else {
                throw RepositoryError.invalidRecord("duplicate story \(story.id)")
            }
            result.stories[story.id] = story
        }
        RepositoryStoryRevision.collapseSuperseded(in: &result.stories)

        for asset in assets {
            try RepositoryValidation.validate(asset)
            guard result.assets[asset.id] == nil else {
                throw RepositoryError.invalidRecord("duplicate asset \(asset.id)")
            }
            result.assets[asset.id] = asset
        }

        for favorite in favorites {
            try RepositoryValidation.validate(favorite)
            result.favorites.insert(favorite)
        }

        for pin in pinnedOccurrences {
            try RepositoryValidation.validate(pin)
            guard !result.pinned.contains(where: { $0.key == pin.key }) else {
                throw RepositoryError.invalidRecord("duplicate pinned occurrence \(pin.key)")
            }
            result.pinned.insert(pin)
        }

        // `appliedWallpapers` is deliberately ignored: it may be either the
        // old monotonic history or a previous process's last-known current
        // set. Neither is safe to treat as protection after a relaunch.
        for reservation in reservations {
            try RepositoryValidation.validate(reservation.wallpaperID)
            result.reservations[reservation.wallpaperID] = reservation.reservedAt
        }

        let newestOccurrence = result.occurrences.values.map(\.localDate).max()
        if let firstObservedDate = self.firstObservedDate {
            if let newestOccurrence, firstObservedDate > newestOccurrence {
                throw RepositoryError.invalidRecord("firstObservedDate is later than the newest occurrence")
            }
            result.firstObservedDate = firstObservedDate
        } else {
            result.firstObservedDate = newestOccurrence
        }
        result.observationStartedAt = observationStartedAt
        result.sync = try (sync ?? RepositorySyncState()).validated()
        return result
    }
}

struct AppliedReservation: Codable, Hashable, Sendable {
    var wallpaperID: WallpaperID
    var reservedAt: Date
}

// MARK: - File store

struct LoadedRepository: Sendable {
    let index: RepositoryIndex
    let state: RepositoryLoadState
}

struct RepositoryFileStore: Sendable {
    let directory: URL

    var indexURL: URL {
        directory.appendingPathComponent("repository.json", isDirectory: false)
    }

    var backupURL: URL {
        directory.appendingPathComponent("repository.json.backup", isDirectory: false)
    }

    private enum LegacyFile {
        static let occurrences = "occurrences.json"
        static let stories = "stories.json"
        static let assets = "image-assets.json"
        static let favorites = "favorites.json"
    }

    func load() throws -> LoadedRepository {
        try ensureDirectory()
        let fileManager = FileManager.default
        let primaryExists = fileManager.fileExists(atPath: indexURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists {
            do {
                return LoadedRepository(index: try decodeFile(at: indexURL), state: .loaded)
            } catch let error as RepositoryError {
                if case .unsupportedSchemaVersion = error {
                    throw error
                }
                return try recoverFromBackup(
                    primaryMessage: Self.describe(error),
                    backupExists: backupExists
                )
            } catch {
                return try recoverFromBackup(
                    primaryMessage: Self.describe(error),
                    backupExists: backupExists
                )
            }
        }

        var backupMessage: String?
        if backupExists {
            do {
                return LoadedRepository(index: try decodeFile(at: backupURL), state: .recoveredFromBackup)
            } catch let error as RepositoryError {
                if case .unsupportedSchemaVersion = error {
                    throw error
                }
                backupMessage = Self.describe(error)
            } catch {
                backupMessage = Self.describe(error)
            }
        }

        if let imported = try loadLegacyIfPresent() {
            do {
                try write(imported, previous: imported)
            } catch {
                throw RepositoryError.migrationFailed(Self.describe(error))
            }
            return LoadedRepository(index: imported, state: .migratedLegacyCache)
        }

        if let backupMessage {
            throw RepositoryError.unreadableIndex(primary: "missing", backup: backupMessage)
        }
        return LoadedRepository(index: RepositoryIndex(), state: .empty)
    }

    /// Writes the previous in-memory index to backup before replacing the
    /// primary. Using in-memory state (not the possibly corrupt primary) means
    /// a recovered backup never gets overwritten with corruption.
    func write(_ next: RepositoryIndex, previous: RepositoryIndex) throws {
        try ensureDirectory()
        do {
            let nextData = try Self.encode(next)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let previousData = try Self.encode(previous)
                try Self.writeAtomically(previousData, to: backupURL)
            }
            try Self.writeAtomically(nextData, to: indexURL)
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.writeFailed(Self.describe(error))
        }
    }

    func writeAsset(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw RepositoryError.assetWriteFailed(Self.describe(error))
        }
    }

    func assetURL(relativePath: String) -> URL? {
        RepositoryPath.assetURL(relativePath: relativePath, directory: directory)
    }

    func ensureDirectory() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw RepositoryError.invalidDirectory(directory.path)
            }
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RepositoryError.invalidDirectory("\(directory.path): \(Self.describe(error))")
        }
    }

    static func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func describe(_ error: Error) -> String {
        let text: String
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            text = description
        } else {
            text = String(describing: error)
        }
        return String(text.prefix(400))
    }

    // MARK: Private loading

    private func recoverFromBackup(
        primaryMessage: String,
        backupExists: Bool
    ) throws -> LoadedRepository {
        guard backupExists else {
            throw RepositoryError.unreadableIndex(primary: primaryMessage, backup: nil)
        }
        do {
            return LoadedRepository(index: try decodeFile(at: backupURL), state: .recoveredFromBackup)
        } catch let error as RepositoryError {
            if case .unsupportedSchemaVersion = error {
                throw error
            }
            throw RepositoryError.unreadableIndex(
                primary: primaryMessage,
                backup: Self.describe(error)
            )
        } catch {
            throw RepositoryError.unreadableIndex(
                primary: primaryMessage,
                backup: Self.describe(error)
            )
        }
    }

    private func decodeFile(at url: URL) throws -> RepositoryIndex {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RepositoryError.invalidRecord(
                "cannot read \(url.lastPathComponent): \(Self.describe(error))"
            )
        }
        return try Self.decode(data: data)
    }

    private func loadLegacyIfPresent() throws -> RepositoryIndex? {
        let fileManager = FileManager.default
        let names = [
            LegacyFile.occurrences,
            LegacyFile.stories,
            LegacyFile.assets,
            LegacyFile.favorites
        ]
        let present = names.filter {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard !present.isEmpty else { return nil }

        let occurrences = try decodeLegacyArray(
            [WallpaperOccurrence].self,
            name: LegacyFile.occurrences
        )
        let stories = try decodeLegacyArray(
            [DailyStoryRecord].self,
            name: LegacyFile.stories
        )
        let legacyAssets = try decodeLegacyArray(
            [LegacyCachedImageAsset].self,
            name: LegacyFile.assets
        )
        let favorites = try decodeLegacyArray(
            [WallpaperID].self,
            name: LegacyFile.favorites
        )

        var index = RepositoryIndex()

        // Phase A allowed multiple revisions; the formal schema stores the
        // deterministic latest row per key.
        for occurrence in OccurrenceIndex.latest(occurrences) {
            try RepositoryValidation.validate(occurrence)
            index.occurrences[occurrence.id] = occurrence
        }

        for story in stories {
            try RepositoryValidation.validate(story)
            if let existing = index.stories[story.id] {
                if story.fetchedAt > existing.fetchedAt {
                    index.stories[story.id] = story
                }
            } else {
                index.stories[story.id] = story
            }
        }
        RepositoryStoryRevision.collapseSuperseded(in: &index.stories)

        for legacy in legacyAssets {
            let asset = CachedImageAsset(
                wallpaperID: legacy.wallpaperID,
                kind: legacy.kind,
                relativePath: legacy.relativePath,
                byteCount: legacy.byteCount,
                lastAccessedAt: legacy.lastAccessedAt
            )
            do {
                try RepositoryValidation.validate(asset)
            } catch {
                // A legacy path outside the repository is never imported.
                // The remaining metadata/favorites remain usable.
                continue
            }
            index.assets[asset.id] = asset

            if let reasons = legacy.pinReasons {
                if reasons.contains(.favorite) {
                    index.favorites.insert(asset.wallpaperID)
                }
                // Phase A did not persist pinned keys separately. Rebuild a
                // single pinned occurrence for the image when an occurrence
                // exists so pinned-date protection still works. A historical
                // .currentlyApplied flag is obsolete and intentionally not
                // imported.
                if reasons.contains(.pinnedDate),
                   let occurrence = index.occurrences.values
                       .filter({ $0.wallpaperID == asset.wallpaperID })
                       .max(by: { $0.localDate < $1.localDate }) {
                    index.pinned.insert(
                        PinnedOccurrence(
                            key: occurrence.id,
                            wallpaperID: asset.wallpaperID
                        )
                    )
                }
            }
        }

        for favorite in favorites {
            try RepositoryValidation.validate(favorite)
            index.favorites.insert(favorite)
        }

        index.firstObservedDate = index.occurrences.values.map(\.localDate).max()
        index.observationStartedAt = nil
        return index
    }

    private func decodeLegacyArray<T: Decodable>(
        _ type: [T].Type,
        name: String
    ) throws -> [T] {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RepositoryError.migrationFailed("\(name): \(Self.describe(error))")
        }
    }

    // MARK: Encoding

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private static func encode(_ index: RepositoryIndex) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(RepositoryIndexFile(index: index))
        } catch {
            throw RepositoryError.writeFailed(describe(error))
        }
    }

    private static func decode(data: Data) throws -> RepositoryIndex {
        let decoder = JSONDecoder()
        let header: SchemaHeader
        do {
            header = try decoder.decode(SchemaHeader.self, from: data)
        } catch {
            throw RepositoryError.invalidRecord("index header: \(describe(error))")
        }

        guard header.schemaVersion > 0 else {
            throw RepositoryError.unsupportedSchemaVersion(
                found: header.schemaVersion,
                supported: RepositorySchema.currentVersion
            )
        }
        guard header.schemaVersion <= RepositorySchema.currentVersion else {
            throw RepositoryError.unsupportedSchemaVersion(
                found: header.schemaVersion,
                supported: RepositorySchema.currentVersion
            )
        }

        do {
            let file = try decoder.decode(RepositoryIndexFile.self, from: data)
            return try file.makeIndex()
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.invalidRecord("index: \(describe(error))")
        }
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

private struct LegacyCachedImageAsset: Decodable {
    let id: String?
    let wallpaperID: WallpaperID
    let kind: AssetKind
    let relativePath: String
    let byteCount: Int
    let lastAccessedAt: Date
    let pinReasons: Set<PinReason>?
}
