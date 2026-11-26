import DaybreakCore
import Foundation
import Testing
@testable import MacIntegration

@Suite("Applied wallpaper ledger")
@MainActor
struct AppliedWallpaperLedgerTests {
    private let displayA = TestFixtures.displayA
    private let displayB = TestFixtures.displayB
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeIntegration(
        directory: URL,
        system: FakeWallpaperSystem,
        observer: FakeEventObserver
    ) -> MacDesktopIntegration {
        let fixed = fixedNow
        return MacDesktopIntegration(
            settingsDirectory: directory,
            system: system,
            eventObserver: observer,
            pointerObserver: FakePointerObserver(),
            eventDebounce: .zero,
            wallpaperProtection: PermissiveWallpaperProtection(),
            now: { fixed }
        )
    }

    private func consent(
        for preflight: MacWallpaperWritePreflight
    ) -> MacWallpaperWriteConsent {
        MacWallpaperWriteConsent(preflight: preflight)
    }

    @Test("Successful writes are recorded per display and replacement is scoped")
    func perDisplayReplacement() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let firstA = try TestFixtures.writeImage(in: directory, named: "first-a.png")
        let firstB = try TestFixtures.writeImage(in: directory, named: "first-b.png")
        let secondA = try TestFixtures.writeImage(in: directory, named: "second-a.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a")),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        let firstPreflight = try await integration.prepareWallpaperWrite()
        let firstReport = try await integration.applyOnce(
            [
                displayA: DesktopWallpaper(imageURL: firstA),
                displayB: DesktopWallpaper(imageURL: firstB)
            ],
            consent: consent(for: firstPreflight)
        )
        #expect(firstReport.blocked.isEmpty)
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == firstA)
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayB] == firstB)

        let secondPreflight = try await integration.prepareWallpaperWrite()
        let secondReport = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: secondA)],
            consent: consent(for: secondPreflight)
        )
        #expect(secondReport.blocked.isEmpty)
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == secondA)
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayB] == firstB)
    }

    @Test("A failed write leaves the previous per-display protection intact")
    func failedWriteKeepsProtection() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let first = try TestFixtures.writeImage(in: directory, named: "first.png")
        let replacement = try TestFixtures.writeImage(in: directory, named: "replacement.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        let firstPreflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: first)],
            consent: consent(for: firstPreflight)
        )
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == first)

        await system.setFailure(
            DesktopFailure(
                stage: .applyingWallpaper,
                kind: .imageUnreadable,
                message: "synthetic write failure"
            )
        )
        let failedPreflight = try await integration.prepareWallpaperWrite()
        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: replacement)],
                consent: consent(for: failedPreflight)
            )
        } catch {
            // The integration may surface the failed pass; either way the
            // confirmed applied state must not change.
        }

        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == first)
    }

    @Test("Guard overwrite success records the exact target for its display")
    func guardOverwriteRecordsSuccess() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("user")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: external)]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()

        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: target)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains { $0.displayID == self.displayA }
        }
        guard let block = integration.snapshot.guardBlocks.first(where: {
            $0.displayID == displayA
        }) else {
            Issue.record("Missing guard block for the synthetic display")
            return
        }

        _ = try await integration.confirmOverwrite(block.confirmationRequest)

        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == target)
        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == target)
    }

    @Test("An automatic event write updates only that display's applied entry")
    func automaticWriteRecordsSuccess() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let first = try TestFixtures.writeImage(in: directory, named: "first.png")
        let second = try TestFixtures.writeImage(in: directory, named: "second.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()

        let manualPreflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: first)],
            consent: consent(for: manualPreflight)
        )
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == first)

        let automationPreflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(
            true,
            consent: consent(for: automationPreflight)
        )
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: second)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.appliedWallpaperURLsByDisplay[self.displayA] == second
        }

        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == second)
        let calls = await system.appliedCalls()
        #expect(calls.contains(where: { $0.displayID == self.displayA && $0.url == second }))
    }

    @Test("A concurrent cleanup cannot delete the original during a write")
    func cleanupDuringWriteCannotDeleteProtectedOriginal() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let repository = try WallpaperRepository(
            directory: directory.appendingPathComponent("Repository", isDirectory: true)
        )
        let imageID = WallpaperID(source: .bing, sourceImageID: "protected-during-write")
        let storedSource = try TestFixtures.writeImage(in: directory, named: "source.png")
        _ = try await repository.storeAsset(
            Data(contentsOf: storedSource),
            kind: .original,
            for: imageID,
            fileExtension: "png"
        )
        let storedURL = await repository.assetURL(kind: .original, for: imageID)
        let assetURL = try #require(storedURL)

        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a"))]
        )
        let fixed = fixedNow
        let integration = MacDesktopIntegration(
            settingsDirectory: directory.appendingPathComponent("Desktop", isDirectory: true),
            system: system,
            eventObserver: FakeEventObserver(),
            pointerObserver: FakePointerObserver(),
            eventDebounce: .zero,
            wallpaperProtection: repository,
            now: { fixed }
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()

        await system.setSuspendNextApply()
        let applyTask = Task {
            try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: assetURL)],
                consent: consent(for: preflight)
            )
        }

        var suspended = false
        for _ in 0..<200 {
            if await system.isApplySuspended() {
                suspended = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(suspended)

        // The applier must have persisted the reservation before the system
        // write is allowed to proceed. Reservations are not exposed as
        // current-desktop wallpaper, but they must block cleanup.
        let snapshotBeforeWrite = await repository.snapshot()
        #expect(!snapshotBeforeWrite.appliedWallpapers.contains(imageID))

        let eviction = try await repository.evictLeastRecentlyUsed(
            limits: CacheLimits(thumbnailBytes: 0, originalBytes: 0)
        )
        #expect(eviction.evictedAssets.isEmpty)
        let stillCached = await repository.asset(kind: .original, for: imageID)
        #expect(stillCached != nil)

        await system.resumeSuspendedApply()
        let report = try await applyTask.value
        #expect(report.blocked.isEmpty)
        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
    }

    @Test("A manual write publishes the post-write desktop observation")
    func manualWritePublishesFreshObservation() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("before")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: external)]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        let preflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: target)],
            consent: consent(for: preflight)
        )

        // The snapshot must describe the desktop left by the write, not the
        // pre-write observation used for verification.
        let published = integration.snapshot.displays.first {
            $0.displayID == displayA
        }
        #expect(published?.currentImageURL == target)
        #expect(integration.snapshot.displaysAwaitingWriteObservation.isEmpty)
    }

    @Test("A lagging observation keeps the confirmed write awaiting and then clears")
    func laggingObservationClearsAfterTheSystemCatchesUp() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let previous = TestFixtures.externalURL("previous")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: previous)]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        await system.setApplyObservationLag(true)

        let preflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: target)],
            consent: consent(for: preflight)
        )

        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == target)
        #expect(integration.snapshot.displaysAwaitingWriteObservation.contains(displayA))
        #expect(
            integration.snapshot.displays.first { $0.displayID == displayA }?
                .currentImageURL == previous
        )

        // Once the system reports the confirmed image the display is released.
        await system.setCurrentImageURL(target, for: displayA)
        await integration.refresh()
        #expect(integration.snapshot.displaysAwaitingWriteObservation.isEmpty)
        #expect(integration.snapshot.displays.first {
            $0.displayID == displayA
        }?.currentImageURL == target)
    }

    @Test("A persistently different observation is released after bounded reads")
    func persistentMismatchIsBounded() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let previous = TestFixtures.externalURL("previous")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: previous)]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        await system.setApplyObservationLag(true)

        let preflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: target)],
            consent: consent(for: preflight)
        )
        #expect(integration.snapshot.displaysAwaitingWriteObservation.contains(displayA))

        // One downstream lagging read is still tolerated.
        await integration.refresh()
        #expect(integration.snapshot.displaysAwaitingWriteObservation.contains(displayA))

        // A third independent observation that still reports a different
        // image proves the live desktop; the old write becomes history and is
        // eligible for cleanup again.
        await integration.refresh()
        #expect(integration.snapshot.displaysAwaitingWriteObservation.isEmpty)
        #expect(integration.snapshot.displays.first {
            $0.displayID == displayA
        }?.currentImageURL == previous)
    }
}
