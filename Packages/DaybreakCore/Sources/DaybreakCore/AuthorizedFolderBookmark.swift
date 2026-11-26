import Foundation

// MARK: - Host platform

enum AuthorizedFolderHostPlatform: String, Hashable, Sendable, Codable {
    case macOS
    case iOS

    static var current: AuthorizedFolderHostPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

// MARK: - Bookmark envelope

struct AuthorizedFolderBookmarkEnvelope: Equatable, Sendable, Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let platform: AuthorizedFolderHostPlatform
    let accessKind: AuthorizedFolderAccessKind
    let generation: AuthorizedFolderGeneration
    let authorizedAt: Date
    let refreshedAt: Date
    let displayName: String
    let bookmarkData: Data
}

enum AuthorizedFolderBookmarkStoreError: Error, Hashable, Sendable {
    case invalidDirectory
    case readFailed(code: Int)
    case writeFailed(code: Int)
    case removeFailed(code: Int)
    case decodeFailed
    case unsupportedVersion(Int)
}

protocol AuthorizedFolderBookmarkStoring: Sendable {
    func load() throws -> AuthorizedFolderBookmarkEnvelope?
    func save(_ envelope: AuthorizedFolderBookmarkEnvelope) throws
    func remove() throws
}

/// Local-only bookmark file. It must live in the caller-supplied application
/// support directory and is never written into the authorized folder.
struct AuthorizedFolderBookmarkFileStore: AuthorizedFolderBookmarkStoring {
    static let fileName = "authorized-folder.bookmark.json"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func load() throws -> AuthorizedFolderBookmarkEnvelope? {
        guard directory.isFileURL else {
            throw AuthorizedFolderBookmarkStoreError.invalidDirectory
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AuthorizedFolderBookmarkStoreError.readFailed(code: (error as NSError).code)
        }
        let envelope: AuthorizedFolderBookmarkEnvelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(AuthorizedFolderBookmarkEnvelope.self, from: data)
        } catch {
            throw AuthorizedFolderBookmarkStoreError.decodeFailed
        }
        guard envelope.schemaVersion == AuthorizedFolderBookmarkEnvelope.currentSchemaVersion else {
            throw AuthorizedFolderBookmarkStoreError.unsupportedVersion(envelope.schemaVersion)
        }
        guard envelope.generation.rawValue > 0,
              !envelope.displayName.isEmpty,
              !envelope.bookmarkData.isEmpty
        else {
            throw AuthorizedFolderBookmarkStoreError.decodeFailed
        }
        return envelope
    }

    func save(_ envelope: AuthorizedFolderBookmarkEnvelope) throws {
        guard directory.isFileURL else {
            throw AuthorizedFolderBookmarkStoreError.invalidDirectory
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw AuthorizedFolderBookmarkStoreError.writeFailed(code: (error as NSError).code)
        }
    }

    func remove() throws {
        guard directory.isFileURL else {
            throw AuthorizedFolderBookmarkStoreError.invalidDirectory
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw AuthorizedFolderBookmarkStoreError.removeFailed(code: (error as NSError).code)
        }
    }
}

// MARK: - Bookmark coding

struct AuthorizedFolderResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol AuthorizedFolderBookmarkCoding: Sendable {
    func makeBookmark(for url: URL, accessKind: AuthorizedFolderAccessKind) throws -> Data
    func resolveBookmark(_ data: Data, accessKind: AuthorizedFolderAccessKind) throws -> AuthorizedFolderResolvedBookmark
}

struct AuthorizedFolderLiveBookmarkCoding: AuthorizedFolderBookmarkCoding {
    func makeBookmark(for url: URL, accessKind: AuthorizedFolderAccessKind) throws -> Data {
        switch accessKind {
        case .securityScoped:
            #if os(macOS)
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            // iOS has no `.withSecurityScope` creation flag. A minimal
            // bookmark from a document-picker URL is the platform-correct
            // security-scoped form and is resolved back as a scoped URL.
            return try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
        case .unscopedLocal:
            #if os(macOS)
            // This is the normal non-sandboxed / ad-hoc macOS path. Avoid
            // carrying an implicit ephemeral cross-process scope.
            return try url.bookmarkData(
                options: [.minimalBookmark, .withoutImplicitSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            return try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
        }
    }

    func resolveBookmark(_ data: Data, accessKind: AuthorizedFolderAccessKind) throws -> AuthorizedFolderResolvedBookmark {
        var isStale = false
        let options: URL.BookmarkResolutionOptions
        switch accessKind {
        case .securityScoped:
            #if os(macOS)
            options = [.withSecurityScope, .withoutUI, .withoutImplicitStartAccessing]
            #else
            options = [.withoutUI, .withoutImplicitStartAccessing]
            #endif
        case .unscopedLocal:
            options = [.withoutUI, .withoutImplicitStartAccessing]
        }
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return AuthorizedFolderResolvedBookmark(url: url, isStale: isStale)
    }
}

// MARK: - Security scope

protocol AuthorizedFolderSecurityScoping: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct AuthorizedFolderLiveSecurityScoping: AuthorizedFolderSecurityScoping {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

struct AuthorizedFolderScopeLease: Sendable {
    private let url: URL
    private let started: Bool
    private let scoping: any AuthorizedFolderSecurityScoping

    init(url: URL, started: Bool, scoping: any AuthorizedFolderSecurityScoping) {
        self.url = url
        self.started = started
        self.scoping = scoping
    }

    func stop() {
        guard started else { return }
        scoping.stopAccessing(url)
    }
}
