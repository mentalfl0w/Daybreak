import Foundation
import Observation

struct MacUpdateVersion: Comparable, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case number(String)
        case text(String)
    }

    private let major: String
    private let minor: String
    private let patch: String
    private let prerelease: [PrereleaseIdentifier]

    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ rawValue: String) {
        var value = rawValue
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }

        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2,
           Self.parseIdentifiers(String(buildParts[1]), disallowLeadingZeroes: false) == nil {
            return nil
        }

        let versionParts = String(buildParts[0]).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let core = versionParts.first else { return nil }
        let coreParts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3,
              let major = Self.parseCoreNumber(coreParts[0]),
              let minor = Self.parseCoreNumber(coreParts[1]),
              let patch = Self.parseCoreNumber(coreParts[2])
        else {
            return nil
        }

        let prerelease: [PrereleaseIdentifier]
        if versionParts.count == 2 {
            guard let parsed = Self.parseIdentifiers(
                String(versionParts[1]),
                disallowLeadingZeroes: true
            ) else {
                return nil
            }
            prerelease = parsed
        } else {
            prerelease = []
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(
            [lhs.major, lhs.minor, lhs.patch],
            [rhs.major, rhs.minor, rhs.patch]
        ) {
            let order = compareDecimalStrings(left, right)
            if order != 0 { return order < 0 }
        }

        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (left, right) {
            case (.number(let left), .number(let right)):
                return compareDecimalStrings(left, right) < 0
            case (.number, .text):
                return true
            case (.text, .number):
                return false
            case (.text(let left), .text(let right)):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCoreNumber(_ value: Substring) -> String? {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.allSatisfy({ (48...57).contains($0) }),
              bytes.count == 1 || bytes.first != 48
        else {
            return nil
        }
        return String(value)
    }

    private static func parseIdentifiers(
        _ rawValue: String,
        disallowLeadingZeroes: Bool
    ) -> [PrereleaseIdentifier]? {
        guard !rawValue.isEmpty else { return nil }
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var identifiers: [PrereleaseIdentifier] = []
        identifiers.reserveCapacity(parts.count)
        for part in parts {
            let bytes = part.utf8
            guard !bytes.isEmpty,
                  bytes.allSatisfy({
                      (48...57).contains($0)
                          || (65...90).contains($0)
                          || (97...122).contains($0)
                          || $0 == 45
                  })
            else {
                return nil
            }

            let isNumeric = bytes.allSatisfy { (48...57).contains($0) }
            if isNumeric {
                guard !disallowLeadingZeroes || bytes.count == 1 || bytes.first != 48 else {
                    return nil
                }
                identifiers.append(.number(String(part)))
            } else {
                identifiers.append(.text(String(part)))
            }
        }
        return identifiers
    }

    private static func compareDecimalStrings(_ lhs: String, _ rhs: String) -> Int {
        if lhs.utf8.count != rhs.utf8.count {
            return lhs.utf8.count < rhs.utf8.count ? -1 : 1
        }
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }
}

struct MacUpdateAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
}

struct MacUpdateRelease: Equatable, Sendable {
    let tagName: String
    let notes: String
    let version: MacUpdateVersion
    let asset: MacUpdateAsset?
}

protocol MacUpdateReleaseChecking: Sendable {
    func latestStableRelease() async throws -> MacUpdateRelease
}

enum MacUpdateClientError: Error, Equatable {
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case malformedPayload
    case noStableRelease
}

/// Fetches only public release metadata. It never downloads release assets.
struct GitHubReleaseClient: MacUpdateReleaseChecking, Sendable {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    private static let endpoint = URL(string: "https://api.github.com/repos/mentalfl0w/Daybreak/releases/latest")!
    private static let endpointPath = "/repos/mentalfl0w/Daybreak/releases/latest"

    private let session: URLSession
    private let redirectDelegate: GitHubRedirectDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
        redirectDelegate = GitHubRedirectDelegate()
    }

    func latestStableRelease() async throws -> MacUpdateRelease {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Daybreak macOS release checker", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let response = response as? HTTPURLResponse,
              let responseURL = response.url,
              Self.isAllowedAPIURL(responseURL)
        else {
            throw MacUpdateClientError.invalidResponse
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 404 {
                throw MacUpdateClientError.noStableRelease
            }
            throw MacUpdateClientError.httpStatus(response.statusCode)
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            throw MacUpdateClientError.invalidResponse
        }
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw MacUpdateClientError.responseTooLarge
        }

        var data = Data()
        let initialCapacity = response.expectedContentLength > 0
            ? Int(response.expectedContentLength)
            : 64 * 1_024
        data.reserveCapacity(initialCapacity)
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw MacUpdateClientError.responseTooLarge
            }
            data.append(byte)
        }
        return try Self.decodeLatestStableRelease(data)
    }

    static func decodeLatestStableRelease(_ data: Data) throws -> MacUpdateRelease {
        let record: GitHubReleaseRecord
        do {
            record = try JSONDecoder().decode(GitHubReleaseRecord.self, from: data)
        } catch {
            throw MacUpdateClientError.malformedPayload
        }

        guard !record.draft,
              !record.prerelease,
              let version = MacUpdateVersion(record.tagName),
              !version.isPrerelease
        else {
            throw MacUpdateClientError.noStableRelease
        }

        let asset = selectDMGAsset(from: record.assets ?? [], tagName: record.tagName)
        return MacUpdateRelease(
            tagName: record.tagName,
            notes: record.body ?? "",
            version: version,
            asset: asset
        )
    }

    static func isOfficialDMGURL(_ url: URL, tagName: String, assetName: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              assetName.lowercased().hasSuffix(".dmg"),
              !assetName.contains("/"),
              !assetName.contains("\\")
        else {
            return false
        }

        let encodedSegments = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard encodedSegments.count == 7, encodedSegments.first?.isEmpty == true else {
            return false
        }
        let decodedSegments = encodedSegments.dropFirst().compactMap {
            String($0).removingPercentEncoding
        }
        guard decodedSegments.count == 6,
              decodedSegments.allSatisfy({ !$0.contains("/") && !$0.contains("\\") })
        else {
            return false
        }

        return decodedSegments[0] == "mentalfl0w"
            && decodedSegments[1] == "Daybreak"
            && decodedSegments[2] == "releases"
            && decodedSegments[3] == "download"
            && decodedSegments[4] == tagName
            && decodedSegments[5] == assetName
    }

    static func isAllowedAPIURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.github.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.path == endpointPath
            && components.query == nil
            && components.fragment == nil
    }

    private static func selectDMGAsset(
        from records: [GitHubReleaseAssetRecord],
        tagName: String
    ) -> MacUpdateAsset? {
        let candidates = records.compactMap { record -> MacUpdateAsset? in
            guard let name = record.name,
                  name.lowercased().hasSuffix(".dmg"),
                  let rawURL = record.browserDownloadURL,
                  let url = URL(string: rawURL),
                  isOfficialDMGURL(url, tagName: tagName, assetName: name)
            else {
                return nil
            }
            return MacUpdateAsset(name: name, downloadURL: url)
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }
}

private final class GitHubReleaseRecord: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [GitHubReleaseAssetRecord]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case body
        case assets
    }
}

private struct GitHubReleaseAssetRecord: Decodable {
    let name: String?
    let browserDownloadURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private final class GitHubRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              GitHubReleaseClient.isAllowedAPIURL(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum MacUpdateFailure: Equatable {
    case request
    case noStableRelease
    case invalidCurrentVersion
    case browserOpen
}

@MainActor
@Observable
final class MacUpdateController {
    static let shared = MacUpdateController()
    static let automaticChecksKey = "daybreak.updates.automaticChecksEnabled"
    private static let lastCheckKey = "daybreak.updates.lastCheckedAt"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    let currentVersion: String
    private(set) var latestRelease: MacUpdateRelease?
    private(set) var isChecking = false
    private(set) var failure: MacUpdateFailure?
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private let checker: any MacUpdateReleaseChecking
    @ObservationIgnored private let defaults: UserDefaults

    var isUpdateAvailable: Bool {
        guard let latestRelease,
              let installedVersion = MacUpdateVersion(currentVersion)
        else {
            return false
        }
        return latestRelease.version > installedVersion
    }

    var downloadURL: URL? {
        guard let release = latestRelease,
              let asset = release.asset,
              GitHubReleaseClient.isOfficialDMGURL(
                  asset.downloadURL,
                  tagName: release.tagName,
                  assetName: asset.name
              )
        else {
            return nil
        }
        return asset.downloadURL
    }

    var automaticChecksEnabled: Bool {
        defaults.bool(forKey: Self.automaticChecksKey)
    }

    init(
        checker: any MacUpdateReleaseChecking = GitHubReleaseClient(),
        defaults: UserDefaults = .standard,
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion ?? "—"
        self.lastCheckedAt = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    func check(now: Date = .now) async {
        guard !isChecking else { return }
        guard MacUpdateVersion(currentVersion) != nil else {
            latestRelease = nil
            failure = .invalidCurrentVersion
            return
        }

        isChecking = true
        failure = nil
        latestRelease = nil
        lastCheckedAt = now
        defaults.set(now, forKey: Self.lastCheckKey)
        defer { isChecking = false }

        do {
            latestRelease = try await checker.latestStableRelease()
        } catch let error as MacUpdateClientError where error == .noStableRelease {
            failure = .noStableRelease
        } catch is CancellationError {
            failure = nil
        } catch {
            failure = .request
        }
    }

    func checkAutomaticallyIfDue(now: Date = .now) async {
        guard automaticChecksEnabled else { return }
        if let lastCheckedAt,
           now.timeIntervalSince(lastCheckedAt) < Self.checkInterval {
            return
        }
        await check(now: now)
    }

    func recordBrowserOpenResult(_ opened: Bool) {
        failure = opened ? nil : .browserOpen
    }
}
