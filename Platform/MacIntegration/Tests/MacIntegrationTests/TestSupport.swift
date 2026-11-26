import DaybreakCore
import Foundation
@testable import MacIntegration

// MARK: - Synthetic wallpaper system

actor FakeWallpaperSystem: MacWallpaperSystem {
    struct ApplyCall: Sendable, Equatable {
        let url: URL
        let displayID: DesktopDisplayID
        let options: MacWallpaperOptions
    }

    private var screensValue: [MacScreenSnapshot]
    private var separateSpaces: Bool
    private var calls: [ApplyCall] = []
    private var attempts: [ApplyCall] = []
    private var failure: DesktopFailure?
    private var suspendNextApply = false
    private var suspendedApply: CheckedContinuation<Void, Never>?
    private var applyObservationLag = false

    init(screens: [MacScreenSnapshot], separateSpaces: Bool = false) {
        self.screensValue = screens
        self.separateSpaces = separateSpaces
    }

    func screens() async -> [MacScreenSnapshot] {
        screensValue
    }

    func screensHaveSeparateSpaces() async -> Bool {
        separateSpaces
    }

    func applyImage(
        at url: URL,
        options: MacWallpaperOptions,
        to displayID: DesktopDisplayID
    ) async throws {
        attempts.append(ApplyCall(url: url, displayID: displayID, options: options))
        if let failure {
            throw failure
        }
        if suspendNextApply {
            suspendNextApply = false
            await withCheckedContinuation { continuation in
                suspendedApply = continuation
            }
        }
        calls.append(ApplyCall(url: url, displayID: displayID, options: options))
        // Models an asynchronous wallpaper agent: the write was accepted, but
        // the public display observation still reports the previous image.
        if applyObservationLag {
            return
        }
        guard let index = screensValue.firstIndex(where: { $0.displayID == displayID }) else {
            return
        }
        screensValue[index] = screensValue[index].with(imageURL: url)
    }

    func setScreens(_ screens: [MacScreenSnapshot]) {
        screensValue = screens
    }

    func setCurrentImageURL(_ url: URL?, for displayID: DesktopDisplayID) {
        guard let index = screensValue.firstIndex(where: { $0.displayID == displayID }) else {
            return
        }
        screensValue[index] = screensValue[index].with(imageURL: url)
    }

    func setFailure(_ failure: DesktopFailure?) {
        self.failure = failure
    }

    func setSuspendNextApply() {
        suspendNextApply = true
    }

    /// Leaves the pre-write screen observation in place after a synthetic
    /// write, modeling a system agent that has not published the new URL yet.
    func setApplyObservationLag(_ enabled: Bool) {
        applyObservationLag = enabled
    }

    func isApplySuspended() -> Bool {
        suspendedApply != nil
    }

    func resumeSuspendedApply() {
        let continuation = suspendedApply
        suspendedApply = nil
        continuation?.resume()
    }

    func appliedCalls() -> [ApplyCall] {
        calls
    }

    /// Every backend write attempt, including ones that failed before the
    /// synthetic system accepted them.
    func attemptedCalls() -> [ApplyCall] {
        attempts
    }
}

// MARK: - Synthetic event source

final class FakeEventObserver: MacSystemEventObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (MacSystemEvent) -> Void)?

    func observe(
        _ handler: @escaping @Sendable (MacSystemEvent) -> Void
    ) -> MacSystemEventObservation {
        lock.lock()
        self.handler = handler
        lock.unlock()
        return MacSystemEventObservation { [weak self] in
            self?.clear()
        }
    }

    func send(_ event: MacSystemEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }

    private func clear() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}

// MARK: - Synthetic pointer source

@MainActor
final class FakePointerObserver: MacPointerDisplayObserving {
    private var handler: (@Sendable (MacPointerDisplayChange) -> Void)?
    private(set) var isObserving = false

    func observeDisplayChanges(
        _ handler: @escaping @Sendable (MacPointerDisplayChange) -> Void
    ) -> MacSystemEventObservation {
        self.handler = handler
        isObserving = true
        return MacSystemEventObservation { [weak self] in
            Task { @MainActor [weak self] in
                self?.handler = nil
                self?.isObserving = false
            }
        }
    }

    func send(_ change: MacPointerDisplayChange) {
        handler?(change)
    }
}

// MARK: - Synthetic protection

/// Stands in for the repository actor in integration tests that use synthetic
/// files outside a real repository. Production always receives the repository.
struct PermissiveWallpaperProtection: WallpaperApplicationProtecting {
    func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        WallpaperID(
            source: SourceID("test-protection"),
            sourceImageID: url.lastPathComponent
        )
    }
}

/// Fail-closed protector for tests that verify a write is blocked.
struct RejectingWallpaperProtection: WallpaperApplicationProtecting {
    func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        throw MacWallpaperProtectionError.notConfigured
    }
}

/// Runs a test hook while the programming reservation is pending. Used to
/// prove that the applier re-reads the live desktop immediately before the
/// system write instead of trusting its pre-await snapshot.
struct CallbackWallpaperProtection: WallpaperApplicationProtecting {
    let onReserve: @Sendable () async -> Void

    func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        await onReserve()
        return WallpaperID(
            source: SourceID("test-callback"),
            sourceImageID: url.lastPathComponent
        )
    }
}

/// Returns no identity, as production does for a non-repository URL.
struct NilWallpaperProtection: WallpaperApplicationProtecting {
    func reserveAppliedProtection(forImageURL url: URL) async throws -> WallpaperID? {
        nil
    }
}

// MARK: - Fixtures

enum TestFixtures {
    static let displayA = DesktopDisplayID("test-display-a")
    static let displayB = DesktopDisplayID("test-display-b")

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakMacIntegration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    static func screenshot(
        _ displayID: DesktopDisplayID,
        name: String = "Display",
        imageURL: URL? = nil,
        options: MacWallpaperOptions = MacWallpaperOptions(
            imageScalingRawValue: 3,
            allowsClipping: true
        )
    ) -> MacScreenSnapshot {
        MacScreenSnapshot(
            displayID: displayID,
            localizedName: name,
            pixelWidth: 1920,
            pixelHeight: 1080,
            isMain: displayID == displayA,
            imageURL: imageURL,
            options: options
        )
    }

    static func writeImage(
        in directory: URL,
        named name: String
    ) throws -> URL {
        // 1x1 PNG; decodable by ImageIO and safe to synthesize in tests.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64) else {
            throw TestFixtureError.invalidFixture
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func externalURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/DaybreakSyntheticExternal/\(name).png")
    }
}

enum TestFixtureError: Error {
    case invalidFixture
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
