import Foundation
import Testing
@testable import Daybreak

@Suite("macOS update fallback")
struct MacUpdateCheckerTests {
    @Test("semantic versions compare numeric fields and prerelease identifiers")
    func semanticVersionOrdering() throws {
        let version129 = try #require(MacUpdateVersion("v1.2.9"))
        let version1210 = try #require(MacUpdateVersion("1.2.10+build.3"))
        let alpha2 = try #require(MacUpdateVersion("1.3.0-alpha.2"))
        let alpha10 = try #require(MacUpdateVersion("1.3.0-alpha.10"))
        let beta = try #require(MacUpdateVersion("1.3.0-beta"))
        let stable = try #require(MacUpdateVersion("1.3.0"))

        #expect(version129 < version1210)
        #expect(alpha2 < alpha10)
        #expect(alpha10 < beta)
        #expect(beta < stable)
        #expect(MacUpdateVersion("1.3.0+other-build") == stable)
    }

    @Test("malformed or noncanonical semantic versions are rejected")
    func rejectsMalformedVersions() {
        #expect(MacUpdateVersion("01.2.3") == nil)
        #expect(MacUpdateVersion("1.2") == nil)
        #expect(MacUpdateVersion("1.2.3-01") == nil)
        #expect(MacUpdateVersion("1.2.3-") == nil)
        #expect(MacUpdateVersion("v1.2.3-beta+build+extra") == nil)
    }

    @Test("latest endpoint accepts only a stable semantic release and one validated DMG")
    func parsesStableReleaseAndOfficialAsset() throws {
        let assetURL = "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg"
        let release = try GitHubReleaseClient.decodeLatestStableRelease(Self.releaseJSON(
            tag: "v1.2.2",
            assetName: "Daybreak.dmg",
            assetURL: assetURL
        ))

        #expect(release.tagName == "v1.2.2")
        #expect(release.notes == "Release notes")
        let currentVersion = try #require(MacUpdateVersion("1.2.1"))
        #expect(release.version > currentVersion)
        #expect(release.asset?.name == "Daybreak.dmg")
        #expect(release.asset?.downloadURL.absoluteString == assetURL)
    }

    @Test("iOS release assets are ignored when selecting the macOS DMG")
    func selectsOnlyDMGAsset() throws {
        let release = try GitHubReleaseClient.decodeLatestStableRelease(Self.releaseJSON(
            tag: "v1.2.2",
            assets: [
                (
                    "Daybreak-1.2.2-iOS.ipa",
                    "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak-1.2.2-iOS.ipa"
                ),
                (
                    "Daybreak-1.2.2-macOS.dmg",
                    "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak-1.2.2-macOS.dmg"
                )
            ]
        ))
        #expect(release.asset?.name == "Daybreak-1.2.2-macOS.dmg")
    }

    @Test("drafts, prereleases, and prerelease tags are never accepted as stable")
    func rejectsNonStableRelease() {
        let drafts = Self.releaseJSON(tag: "v1.2.2", draft: true)
        let prereleases = Self.releaseJSON(tag: "v1.2.2", prerelease: true)
        let prereleaseTag = Self.releaseJSON(tag: "v1.2.2-rc.1")

        for data in [drafts, prereleases, prereleaseTag] {
            do {
                _ = try GitHubReleaseClient.decodeLatestStableRelease(data)
                Issue.record("Expected an unstable release to be rejected")
            } catch let error as MacUpdateClientError {
                #expect(error == .noStableRelease)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }


    @Test("malformed release JSON fails closed")
    func rejectsMalformedPayload() {
        do {
            _ = try GitHubReleaseClient.decodeLatestStableRelease(Data("{not json".utf8))
            Issue.record("Expected malformed JSON to be rejected")
        } catch let error as MacUpdateClientError {
            #expect(error == .malformedPayload)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("unexpected release response shapes fail closed")
    func rejectsUnexpectedSchema() {
        let responses = [
            Data("[]".utf8),
            Data(#"{"tag_name":"v1.2.2","draft":false}"#.utf8)
        ]
        for data in responses {
            do {
                _ = try GitHubReleaseClient.decodeLatestStableRelease(data)
                Issue.record("Expected an unexpected response schema to be rejected")
            } catch let error as MacUpdateClientError {
                #expect(error == .malformedPayload)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("only the exact official HTTPS release asset URL is allowed")
    func validatesAssetURL() {
        let valid = URL(string: "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg")!
        #expect(GitHubReleaseClient.isOfficialDMGURL(
            valid,
            tagName: "v1.2.2",
            assetName: "Daybreak.dmg"
        ))

        let invalidURLs = [
            "http://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg",
            "https://github.com.evil.example/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg",
            "https://github.com/other/Daybreak/releases/download/v1.2.2/Daybreak.dmg",
            "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.3/Daybreak.dmg",
            "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.zip",
            "https://user@github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg",
            "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg?download=1"
        ]
        for rawURL in invalidURLs {
            let url = URL(string: rawURL)!
            #expect(!GitHubReleaseClient.isOfficialDMGURL(
                url,
                tagName: "v1.2.2",
                assetName: "Daybreak.dmg"
            ))
        }
    }
    @Test("API redirects stay on the exact HTTPS GitHub API endpoint")
    func validatesAPIRedirectURLs() throws {
        let endpoint = try #require(URL(string: "https://api.github.com/repos/mentalfl0w/Daybreak/releases/latest"))
        #expect(GitHubReleaseClient.isAllowedAPIURL(endpoint))

        let invalidURLs = [
            "http://api.github.com/repos/mentalfl0w/Daybreak/releases/latest",
            "https://api.github.com.evil.example/repos/mentalfl0w/Daybreak/releases/latest",
            "https://api.github.com/repos/other/Daybreak/releases/latest",
            "https://user@api.github.com/repos/mentalfl0w/Daybreak/releases/latest",
            "https://api.github.com/repos/mentalfl0w/Daybreak/releases/latest?access_token=unexpected"
        ]
        for rawURL in invalidURLs {
            let url = try #require(URL(string: rawURL))
            #expect(!GitHubReleaseClient.isAllowedAPIURL(url))
        }
    }


    @Test("ambiguous DMG assets do not produce a download action")
    func rejectsAmbiguousDMGAssets() throws {
        let data = Self.releaseJSON(
            tag: "v1.2.2",
            assets: [
                ("Daybreak-arm64.dmg", "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak-arm64.dmg"),
                ("Daybreak-intel.dmg", "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak-intel.dmg")
            ]
        )
        let release = try GitHubReleaseClient.decodeLatestStableRelease(data)
        #expect(release.asset == nil)
    }

    @Test("a failed check can be retried and only metadata errors are shown")
    @MainActor
    func retryAfterNetworkFailure() async throws {
        let checker = MacUpdateTestChecker([
            .failure(.httpStatus(503)),
            .success(Self.sampleRelease())
        ])
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MacUpdateController(
            checker: checker,
            defaults: defaults,
            currentVersion: "1.2.1"
        )

        await controller.check(now: Date(timeIntervalSince1970: 100))
        #expect(controller.failure == .request)
        #expect(controller.latestRelease == nil)

        await controller.check(now: Date(timeIntervalSince1970: 200))
        #expect(controller.failure == nil)
        #expect(controller.isUpdateAvailable)
        #expect(controller.downloadURL == Self.sampleRelease().asset?.downloadURL)
        #expect(await checker.requestCount() == 2)
    }

    @Test("the validated current stable DMG remains manually downloadable")
    @MainActor
    func currentReleaseStillOffersManualDownload() async throws {
        let release = try GitHubReleaseClient.decodeLatestStableRelease(
            Self.releaseJSON(tag: "v1.2.1")
        )
        let checker = MacUpdateTestChecker([.success(release)])
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MacUpdateController(
            checker: checker,
            defaults: defaults,
            currentVersion: "1.2.1"
        )

        await controller.check(now: Date(timeIntervalSince1970: 300))
        #expect(!controller.isUpdateAvailable)
        #expect(controller.downloadURL == release.asset?.downloadURL)
    }

    @Test("automatic checks are disabled by default and respect the 24-hour interval")
    @MainActor
    func automaticChecksAreOptionalAndRateLimited() async throws {
        let checker = MacUpdateTestChecker([
            .success(Self.sampleRelease()),
            .success(Self.sampleRelease())
        ])
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MacUpdateController(
            checker: checker,
            defaults: defaults,
            currentVersion: "1.2.1"
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await controller.checkAutomaticallyIfDue(now: start)
        #expect(await checker.requestCount() == 0)

        defaults.set(true, forKey: MacUpdateController.automaticChecksKey)
        await controller.checkAutomaticallyIfDue(now: start)
        #expect(await checker.requestCount() == 1)

        await controller.checkAutomaticallyIfDue(now: start.addingTimeInterval(23 * 60 * 60))
        #expect(await checker.requestCount() == 1)

        await controller.checkAutomaticallyIfDue(now: start.addingTimeInterval(24 * 60 * 60))
        #expect(await checker.requestCount() == 2)
    }

    private static func releaseJSON(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String? = "Daybreak.dmg",
        assetURL: String? = nil,
        assets: [(String, String)]? = nil
    ) -> Data {
        let selectedAssets = assets ?? assetName.map { name in
            [(
                name,
                assetURL ?? "https://github.com/mentalfl0w/Daybreak/releases/download/\(tag)/\(name)"
            )]
        } ?? []
        let assetRecords = selectedAssets.map { name, url in
            ["name": name, "browser_download_url": url]
        }
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "body": "Release notes",
            "assets": assetRecords
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func sampleRelease() -> MacUpdateRelease {
        let url = URL(string: "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.2/Daybreak.dmg")!
        return MacUpdateRelease(
            tagName: "v1.2.2",
            notes: "Release notes",
            version: MacUpdateVersion("v1.2.2")!,
            asset: MacUpdateAsset(name: "Daybreak.dmg", downloadURL: url)
        )
    }

    private static func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "DaybreakMacUpdateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }
}

private actor MacUpdateTestChecker: MacUpdateReleaseChecking {
    private var results: [Result<MacUpdateRelease, MacUpdateClientError>]
    private var requests = 0

    init(_ results: [Result<MacUpdateRelease, MacUpdateClientError>]) {
        self.results = results
    }

    func latestStableRelease() async throws -> MacUpdateRelease {
        requests += 1
        guard !results.isEmpty else {
            throw MacUpdateClientError.httpStatus(503)
        }
        return try results.removeFirst().get()
    }

    func requestCount() -> Int { requests }
}

@Suite("macOS Sparkle configuration")
struct MacSparkleConfigurationTests {
    @Test("Sparkle activates only with a provisioned EdDSA key and the stable HTTPS feed")
    func acceptsConfiguredStableFeed() {
        let publicKey = Data(repeating: 0x5A, count: 32).base64EncodedString()
        let infoDictionary: [String: Any] = [
            "SUFeedURL": MacSparkleConfiguration.stableFeedURL,
            "SUPublicEDKey": publicKey
        ]

        #expect(MacSparkleConfiguration.isConfigured(infoDictionary: infoDictionary))
    }

    @Test("Sparkle stays unavailable when its key is missing, unresolved, or malformed")
    func rejectsMissingOrMalformedKeys() {
        let feedURL = MacSparkleConfiguration.stableFeedURL
        let invalidKeys = [
            "",
            "$(SPARKLE_EDDSA_PUBLIC_KEY)",
            Data(repeating: 0x5A, count: 31).base64EncodedString()
        ]

        #expect(!MacSparkleConfiguration.isConfigured(infoDictionary: ["SUFeedURL": feedURL]))
        for publicKey in invalidKeys {
            #expect(!MacSparkleConfiguration.isConfigured(infoDictionary: [
                "SUFeedURL": feedURL,
                "SUPublicEDKey": publicKey
            ]))
        }
    }

    @Test("Sparkle rejects feeds outside the exact stable HTTPS GitHub release URL")
    func rejectsUntrustedFeedURLs() {
        let publicKey = Data(repeating: 0x5A, count: 32).base64EncodedString()
        for feedURL in [
            "http://github.com/mentalfl0w/Daybreak/releases/latest/download/appcast.xml",
            "https://example.com/mentalfl0w/Daybreak/releases/latest/download/appcast.xml",
            "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.3/appcast.xml"
        ] {
            #expect(!MacSparkleConfiguration.isConfigured(infoDictionary: [
                "SUFeedURL": feedURL,
                "SUPublicEDKey": publicKey
            ]))
        }
    }
}
