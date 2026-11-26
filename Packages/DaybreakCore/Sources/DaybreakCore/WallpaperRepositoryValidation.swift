import Foundation

// MARK: - Validation and path safety

enum RepositoryPath {
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.utf8.contains(0)
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            let value = String(component)
            guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("~") else {
                return false
            }
        }
        return true
    }

    static func assetURL(relativePath: String, directory: URL) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        let root = directory.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }
}

enum RepositoryValidation {
    static let maxSourceIDBytes = 32
    static let maxImageIDBytes = 64

    static func validate(_ occurrence: WallpaperOccurrence) throws {
        guard occurrence.isValid else {
            throw RepositoryError.invalidRecord("invalid occurrence identity or revision")
        }
        try validate(occurrence.wallpaperID)
    }

    static func validate(_ metadata: WallpaperMetadataRecord) throws {
        guard metadata.isValid else {
            throw RepositoryError.invalidRecord("invalid metadata \(metadata.key)")
        }
        try validate(metadata.wallpaperID)
    }

    static func validate(_ wallpaper: WallpaperRecord) throws {
        guard wallpaper.isValid else {
            throw RepositoryError.invalidRecord("invalid wallpaper \(wallpaper.id)")
        }
        try validate(wallpaper.wallpaperID)
    }

    static func validate(_ story: DailyStoryRecord) throws {
        guard story.source.isValid,
              story.market.isValid,
              !story.id.isEmpty,
              !story.originalLocale.isEmpty
        else {
            throw RepositoryError.invalidRecord("invalid story identity")
        }
        guard story.source.rawValue.utf8.count <= maxSourceIDBytes else {
            throw RepositoryError.invalidRecord("story source id is too long")
        }
        if let associatedWallpaperID = story.associatedWallpaperID {
            try validate(associatedWallpaperID)
            guard associatedWallpaperID.source == story.source else {
                throw RepositoryError.invalidRecord("story image source mismatch")
            }
        }
        if let sourceURL = story.sourceURL,
           sourceURL.scheme?.lowercased() != "https" {
            throw RepositoryError.invalidRecord("story URL must use HTTPS")
        }
        switch story.availability {
        case .available:
            guard story.title != nil
                    || story.headline != nil
                    || story.body != nil
                    || story.quickFact != nil
            else {
                throw RepositoryError.invalidRecord("available story has no text")
            }
        case .unavailable:
            guard story.body == nil, story.quickFact == nil else {
                throw RepositoryError.invalidRecord("unavailable story carries body text")
            }
        }
    }

    static func validate(_ asset: CachedImageAsset) throws {
        guard asset.isValid else {
            throw RepositoryError.invalidRecord("invalid cached asset")
        }
        guard asset.relativePath.hasPrefix("Assets/") else {
            throw RepositoryError.invalidRecord("asset path must stay under Assets/")
        }
        try validate(asset.wallpaperID)
    }

    static func validate(_ pin: PinnedOccurrence) throws {
        guard pin.isValid else {
            throw RepositoryError.invalidRecord("invalid pinned occurrence")
        }
        try validate(pin.wallpaperID)
    }

    static func validate(_ wallpaperID: WallpaperID) throws {
        guard wallpaperID.isValid else {
            throw RepositoryError.invalidRecord("invalid wallpaper identity")
        }
        guard wallpaperID.source.rawValue.utf8.count <= maxSourceIDBytes else {
            throw RepositoryError.invalidRecord("source id is too long for safe asset paths")
        }
        guard wallpaperID.sourceImageID.utf8.count <= maxImageIDBytes else {
            throw RepositoryError.invalidRecord("image id is too long for safe asset paths")
        }
    }

    static func assetExtension(_ rawValue: String) throws -> String {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 8 else {
            throw RepositoryError.invalidAssetExtension(rawValue)
        }
        let bytes = Array(trimmed.utf8)
        guard bytes.allSatisfy({ byte in
            (48...57).contains(byte) || (97...122).contains(byte)
        }) else {
            throw RepositoryError.invalidAssetExtension(rawValue)
        }
        return trimmed
    }
}
