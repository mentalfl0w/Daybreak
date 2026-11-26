import Foundation
import Testing
@testable import DaybreakCore

@Suite("DesktopCoordinator")
struct DesktopCoordinatorTests {
    let displayA = DesktopDisplayID("display-a")
    let displayB = DesktopDisplayID("display-b")

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func imageURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/DaybreakSynthetic/\(name).png")
    }

    private func wallpaper(
        _ name: String,
        scaling: DesktopImageScaling = .fill
    ) -> DesktopWallpaper {
        DesktopWallpaper(imageURL: imageURL(name), scaling: scaling)
    }

    private func makeCoordinator(
        backend: FakeBackend,
        scheduler: ManualRetryScheduler,
        clock: TestClock,
        initialAssignments: [DesktopDisplayID: DesktopWallpaper] = [:],
        manualSelectionPolicy: DesktopManualSelectionPolicy = .protectManualSelections,
        retryPolicy: DesktopRetryPolicy = .default
    ) -> DesktopCoordinator {
        DesktopCoordinator(
            backend: backend,
            configuration: DesktopCoordinatorConfiguration(
                manualSelectionPolicy: manualSelectionPolicy,
                retryPolicy: retryPolicy
            ),
            initialAssignments: initialAssignments,
            retryScheduler: scheduler,
            now: { clock.now }
        )
    }

    // MARK: - Apply and dedup

    @Test
    func appliesTargetAndSkipsDuplicateWrite() async {
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)
        let target = wallpaper("target-a", scaling: .fit)

        let first = await coordinator.assign(target, to: displayA)
        #expect(first.outcomes.map(\.displayID) == [displayA])
        #expect(first.outcomes.first?.action == .applied)
        #expect(first.outcomes.first?.status == .synchronized)
        #expect(first.didApplyWallpaper)
        #expect(first.coalescedTriggerCount == 0)
        #expect(first.topologyFailure == nil)

        let callsAfterFirst = await backend.applyCalls
        #expect(callsAfterFirst == [FakeBackend.ApplyCall(displayID: displayA, wallpaper: target)])

        let second = await coordinator.handle(.spaceDidChange)
        #expect(second.outcomes.first?.action == .alreadySynchronized)
        #expect(second.outcomes.first?.status == .synchronized)

        let callsAfterSecond = await backend.applyCalls
        #expect(callsAfterSecond.count == 1)

        let state = await coordinator.state()
        #expect(state.spaceGeneration == 1)
        #expect(state.isReconciling == false)
        #expect(state.queuedReconciliationCount == 0)

        let displayState = state.displayState(for: displayA)
        #expect(displayState?.status == .synchronized)
        #expect(displayState?.observedImageURL == target.imageURL)
        #expect(displayState?.lastReconciledSpaceGeneration == 1)
        #expect(displayState?.lastSuccessfulApply?.wallpaper == target)
        #expect(displayState?.lastSuccessfulApply?.spaceGeneration == 0)
    }

    @Test
    func appliesMultipleDisplaysInStableOrder() async {
        let backend = FakeBackend(
            displayIDs: [displayB, displayA],
            screensHaveSeparateSpaces: true
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)
        let targetA = wallpaper("target-a", scaling: .fit)
        let targetB = wallpaper("target-b", scaling: .center)

        let report = await coordinator.assign([displayB: targetB, displayA: targetA])

        #expect(report.outcomes.map(\.displayID) == [displayA, displayB])
        #expect(report.outcomes.map(\.action) == [.applied, .applied])
        #expect(report.appliedDisplayIDs == [displayA, displayB])

        let calls = await backend.applyCalls
        #expect(calls.map(\.displayID) == [displayA, displayB])
        #expect(calls.first?.wallpaper == targetA)
        #expect(calls.last?.wallpaper == targetB)
        #expect(calls.last?.wallpaper.scaling == .center)

        let state = await coordinator.state()
        #expect(state.screensHaveSeparateSpaces)
        #expect(state.assignments.map(\.displayID) == [displayA, displayB])
        #expect(state.displayState(for: displayA)?.status == .synchronized)
        #expect(state.displayState(for: displayB)?.status == .synchronized)
    }

    @Test
    func duplicateDisplaySnapshotsCollapseToOneOutcome() async {
        let backend = FakeBackend(displayIDs: [displayA, displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let report = await coordinator.assign(wallpaper("target-a"), to: displayA)

        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.action == .applied)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)

        let state = await coordinator.state()
        #expect(state.displays.count == 1)
    }

    @Test
    func spaceGenerationIncrementsForEachNotification() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: target.imageURL],
            currentScalings: [displayA: target.scaling]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            initialAssignments: [displayA: target]
        )

        let first = await coordinator.handle(.spaceDidChange)
        #expect(first.spaceGeneration == 1)
        #expect(first.outcomes.first?.action == .alreadySynchronized)

        let second = await coordinator.handle(.spaceDidChange)
        #expect(second.spaceGeneration == 2)
        #expect(second.outcomes.first?.action == .alreadySynchronized)

        let calls = await backend.applyCalls
        #expect(calls.isEmpty)

        let state = await coordinator.state()
        #expect(state.spaceGeneration == 2)
        #expect(state.displayState(for: displayA)?.lastReconciledSpaceGeneration == 2)
        #expect(state.displayState(for: displayA)?.currentScaling == target.scaling)
        #expect(state.displayState(for: displayA)?.scalingSource == .observedByBackend)
        #expect(state.lastReport?.spaceGeneration == 2)
    }

    // MARK: - Assignment persistence

    @Test
    func assignmentWithoutProvenanceDecodesAsUnknownAndKeepsItsTarget() throws {
        let json = """
        {
          "displayID": "display-a",
          "wallpaper": {
            "imageURL": "file:///tmp/DaybreakSynthetic/legacy.png",
            "scaling": "fit"
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            DesktopDisplayAssignment.self,
            from: Data(json.utf8)
        )

        #expect(decoded.displayID == displayA)
        #expect(decoded.wallpaper.imageURL.lastPathComponent == "legacy.png")
        #expect(decoded.wallpaper.scaling == .fit)
        #expect(decoded.source == .unknown)

        let unrecognizedJSON = """
        {
          "displayID": "display-a",
          "wallpaper": {
            "imageURL": "file:///tmp/DaybreakSynthetic/legacy.png",
            "scaling": "fit"
          },
          "source": "future-source"
        }
        """
        let unrecognized = try JSONDecoder().decode(
            DesktopDisplayAssignment.self,
            from: Data(unrecognizedJSON.utf8)
        )
        #expect(unrecognized.source == .unknown)
    }

    @Test
    func assignmentProvenanceRoundTripsThroughCodable() throws {
        for source in [
            DesktopAssignmentSource.automatic,
            .manual,
            .unknown
        ] {
            let assignment = DesktopDisplayAssignment(
                displayID: displayA,
                wallpaper: wallpaper("target-a", scaling: .fill),
                source: source
            )
            let data = try JSONEncoder().encode(assignment)
            let decoded = try JSONDecoder().decode(DesktopDisplayAssignment.self, from: data)

            #expect(decoded == assignment)
            #expect(decoded.source == source)
        }
    }

    // MARK: - Scaling-aware synchronization

    @Test
    func sameImageWithNewScalingIsReapplied() async {
        let fillTarget = wallpaper("target-a", scaling: .fill)
        let fitTarget = wallpaper("target-a", scaling: .fit)
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let first = await coordinator.assign(fillTarget, to: displayA)
        #expect(first.outcomes.first?.action == .applied)

        let second = await coordinator.assign(fitTarget, to: displayA)
        #expect(second.outcomes.first?.action == .applied)
        #expect(second.outcomes.first?.status == .synchronized)

        let callsAfterSecond = await backend.applyCalls
        #expect(callsAfterSecond.count == 2)
        #expect(callsAfterSecond.last?.wallpaper == fitTarget)

        let reportedScaling = await backend.currentScaling(for: displayA)
        #expect(reportedScaling == .fit)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.currentScaling == .fit)
        #expect(state.displayState(for: displayA)?.status == .synchronized)

        let idempotent = await coordinator.handle(.spaceDidChange)
        #expect(idempotent.outcomes.first?.action == .alreadySynchronized)
        let callsAfterThird = await backend.applyCalls
        #expect(callsAfterThird.count == 2)
    }

    @Test
    func unobservableScalingUsesLastWriteParameters() async {
        let fillTarget = wallpaper("target-a", scaling: .fill)
        let fitTarget = wallpaper("target-a", scaling: .fit)
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: fillTarget.imageURL],
            reportsScaling: false
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        // The URL already matches, but options were never observed or written.
        // One write establishes them instead of claiming synchronization.
        let first = await coordinator.assign(fillTarget, to: displayA)
        #expect(first.outcomes.first?.action == .applied)

        let firstState = await coordinator.state()
        #expect(firstState.displayState(for: displayA)?.currentScaling == .fill)
        #expect(firstState.displayState(for: displayA)?.scalingSource == .appliedByDaybreak)
        #expect(firstState.displayState(for: displayA)?.status == .synchronized)

        let idempotent = await coordinator.handle(.spaceDidChange)
        #expect(idempotent.outcomes.first?.action == .alreadySynchronized)
        let callsAfterIdempotent = await backend.applyCalls
        #expect(callsAfterIdempotent.count == 1)

        // The known last write used a different scaling, so the new target must
        // be written even though the URL is unchanged and options stay hidden.
        let rescaled = await coordinator.assign(fitTarget, to: displayA)
        #expect(rescaled.outcomes.first?.action == .applied)

        let finalState = await coordinator.state()
        #expect(finalState.displayState(for: displayA)?.currentScaling == .fit)
        #expect(finalState.displayState(for: displayA)?.scalingSource == .appliedByDaybreak)
        #expect(finalState.displayState(for: displayA)?.status == .synchronized)

        let callsAfterRescale = await backend.applyCalls
        #expect(callsAfterRescale.count == 2)
        #expect(callsAfterRescale.last?.wallpaper == fitTarget)

        let stable = await coordinator.handle(.spaceDidChange)
        #expect(stable.outcomes.first?.action == .alreadySynchronized)
        let callsAfterStable = await backend.applyCalls
        #expect(callsAfterStable.count == 2)
    }

    @Test
    func unobservableScalingFallbackRequiresSameImageURL() async {
        let targetA = wallpaper("target-a", scaling: .fill)
        let targetB = wallpaper("target-b", scaling: .fill)
        let backend = FakeBackend(
            displayIDs: [displayA],
            reportsScaling: false
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let first = await coordinator.assign(targetA, to: displayA)
        #expect(first.outcomes.first?.action == .applied)

        // External change to a different image. Options are not reportable, so
        // A/fill's scaling must not be attributed to the new B image.
        await backend.setCurrentImageURL(targetB.imageURL, for: displayA)

        let second = await coordinator.assign(targetB, to: displayA)
        #expect(second.outcomes.first?.action == .applied)
        #expect(second.outcomes.first?.status == .synchronized)

        let callsAfterSecond = await backend.applyCalls
        #expect(callsAfterSecond.count == 2)
        #expect(callsAfterSecond.last?.wallpaper == targetB)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.currentScaling == .fill)
        #expect(state.displayState(for: displayA)?.scalingSource == .appliedByDaybreak)
        #expect(state.displayState(for: displayA)?.status == .synchronized)

        let idempotent = await coordinator.handle(.spaceDidChange)
        #expect(idempotent.outcomes.first?.action == .alreadySynchronized)
        let callsAfterIdempotent = await backend.applyCalls
        #expect(callsAfterIdempotent.count == 2)
    }

    @Test
    func externalScalingChangeIsProtectedWhenPolicyAllows() async {
        let target = wallpaper("target-a", scaling: .fill)
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)
        await backend.setCurrentScaling(.fit, for: displayA)

        let detected = await coordinator.handle(.spaceDidChange)
        #expect(detected.outcomes.first?.action == .manualProtectionDetected)
        #expect(detected.outcomes.first?.status == .manualProtection)

        let protectedState = await coordinator.state()
        #expect(protectedState.displayState(for: displayA)?.manualProtection?.imageScaling == .fit)
        #expect(protectedState.displayState(for: displayA)?.manualProtection?.imageURL == target.imageURL)

        let callsBeforeRelease = await backend.applyCalls
        #expect(callsBeforeRelease.count == 1)

        let released = await coordinator.clearManualProtection(for: displayA)
        #expect(released.outcomes.first?.action == .applied)

        let finalState = await coordinator.state()
        #expect(finalState.displayState(for: displayA)?.currentScaling == .fill)
        #expect(finalState.displayState(for: displayA)?.status == .synchronized)

        let callsAfterRelease = await backend.applyCalls
        #expect(callsAfterRelease.count == 2)
        #expect(callsAfterRelease.last?.wallpaper == target)
    }

    // MARK: - Manual protection

    @Test
    func manualSelectionIsProtectedWhenPolicyAllows() async {
        let target = wallpaper("target-a")
        let original = imageURL("system-original")
        let manual = imageURL("user-manual")
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: original]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let initial = await coordinator.assign(target, to: displayA)
        #expect(initial.outcomes.first?.action == .applied)

        await backend.setCurrentImageURL(manual, for: displayA)

        let detected = await coordinator.handle(.spaceDidChange)
        #expect(detected.outcomes.first?.action == .manualProtectionDetected)
        #expect(detected.outcomes.first?.status == .manualProtection)

        let afterDetection = await coordinator.state()
        let protection = afterDetection.displayState(for: displayA)?.manualProtection
        #expect(protection?.imageURL == manual)
        #expect(protection?.origin == .detectedExternalChange)
        #expect(protection?.spaceGeneration == 1)
        #expect(afterDetection.displayState(for: displayA)?.lastSuccessfulApply?.wallpaper == target)

        let repeated = await coordinator.handle(.spaceDidChange)
        #expect(repeated.outcomes.first?.action == .alreadyProtected)
        #expect(repeated.outcomes.first?.status == .manualProtection)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)

        let currentURL = await backend.currentImageURL(for: displayA)
        #expect(currentURL == manual)
    }

    @Test
    func replacePolicyOverwritesManualSelection() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: imageURL("system-original")]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            manualSelectionPolicy: .replaceManualSelections
        )

        _ = await coordinator.assign(target, to: displayA)
        await backend.setCurrentImageURL(imageURL("user-manual"), for: displayA)

        let report = await coordinator.handle(.spaceDidChange)
        #expect(report.outcomes.first?.action == .applied)
        #expect(report.outcomes.first?.status == .synchronized)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection == nil)
        #expect(state.displayState(for: displayA)?.status == .synchronized)

        let calls = await backend.applyCalls
        #expect(calls.count == 2)
        let currentURL = await backend.currentImageURL(for: displayA)
        #expect(currentURL == target.imageURL)
    }

    @Test
    func explicitProtectionAndReleaseResumeAutomation() async {
        let target = wallpaper("target-a")
        let manual = imageURL("user-manual")
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)
        await backend.setCurrentImageURL(manual, for: displayA)

        // `protectCurrentWallpaper` protects the last observed wallpaper, so
        // first reconcile the external change the way a Space event would.
        let observed = await coordinator.handle(.spaceDidChange)
        #expect(observed.outcomes.first?.action == .manualProtectionDetected)

        let protectedState = await coordinator.protectCurrentWallpaper(for: displayA)
        #expect(protectedState.displayState(for: displayA)?.status == .manualProtection)
        #expect(protectedState.displayState(for: displayA)?.manualProtection?.origin == .explicitlyRequested)
        #expect(protectedState.displayState(for: displayA)?.manualProtection?.imageURL == manual)

        let skipped = await coordinator.handle(.spaceDidChange)
        #expect(skipped.outcomes.first?.action == .alreadyProtected)

        let released = await coordinator.clearManualProtection(for: displayA)
        #expect(released.outcomes.first?.action == .applied)
        #expect(released.outcomes.first?.status == .synchronized)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection == nil)
        #expect(state.displayState(for: displayA)?.status == .synchronized)

        let calls = await backend.applyCalls
        #expect(calls.count == 2)
        let currentURL = await backend.currentImageURL(for: displayA)
        #expect(currentURL == target.imageURL)
    }

    @Test
    func protectionClearsWhenObservedWallpaperBecomesTarget() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)
        await backend.setCurrentImageURL(imageURL("user-manual"), for: displayA)
        let protected = await coordinator.handle(.spaceDidChange)
        #expect(protected.outcomes.first?.action == .manualProtectionDetected)

        await backend.setCurrentImageURL(target.imageURL, for: displayA)
        let synchronized = await coordinator.handle(.spaceDidChange)
        #expect(synchronized.outcomes.first?.action == .alreadySynchronized)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection == nil)
        #expect(state.displayState(for: displayA)?.status == .synchronized)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)
    }

    @Test
    func managedWallpaperIsNotTreatedAsManualSelection() async {
        let targetA = wallpaper("target-a")
        let targetB = wallpaper("target-b")
        let backend = FakeBackend(displayIDs: [displayA, displayB])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign([displayA: targetA, displayB: targetB])

        // A Daybreak-managed image from another display/date is stale content,
        // not a manual system selection.
        await backend.setCurrentImageURL(targetB.imageURL, for: displayA)

        let report = await coordinator.handle(.spaceDidChange)
        let outcome = report.outcomes.first { $0.displayID == displayA }
        #expect(outcome?.action == .applied)
        #expect(outcome?.status == .synchronized)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection == nil)

        let calls = await backend.applyCalls
        let callsForA = calls.filter { $0.displayID == displayA }
        #expect(callsForA.count == 2)
        #expect(callsForA.last?.wallpaper == targetA)
    }

    @Test
    func newAssignmentOverridesProtectedManualWallpaper() async {
        let targetA = wallpaper("target-a")
        let targetB = wallpaper("target-b")
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(targetA, to: displayA)
        await backend.setCurrentImageURL(imageURL("user-manual"), for: displayA)
        _ = await coordinator.handle(.spaceDidChange)

        let reassigned = await coordinator.assign(targetB, to: displayA)
        #expect(reassigned.outcomes.first?.action == .applied)
        #expect(reassigned.outcomes.first?.status == .synchronized)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection == nil)
        #expect(state.assignment(for: displayA)?.wallpaper == targetB)
        #expect(state.displayState(for: displayA)?.status == .synchronized)

        let calls = await backend.applyCalls
        #expect(calls.count == 2)
        let currentURL = await backend.currentImageURL(for: displayA)
        #expect(currentURL == targetB.imageURL)
    }

    @Test
    func manualProtectionPersistsAcrossDisconnectAndReconnect() async {
        let target = wallpaper("target-a")
        let manual = imageURL("user-manual")
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)
        await backend.setCurrentImageURL(manual, for: displayA)
        _ = await coordinator.handle(.spaceDidChange)

        await backend.setDisplayIDs([])
        let disconnected = await coordinator.handle(.displayConfigurationChanged)
        #expect(disconnected.outcomes.first?.action == .disconnected)
        let afterDisconnect = await coordinator.state()
        #expect(afterDisconnect.displayState(for: displayA)?.manualProtection?.imageURL == manual)

        await backend.setDisplayIDs([displayA])
        await backend.setCurrentImageURL(manual, for: displayA)
        let reconnected = await coordinator.handle(.displayConfigurationChanged)
        #expect(reconnected.outcomes.first?.action == .alreadyProtected)
        #expect(reconnected.outcomes.first?.status == .manualProtection)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)
    }

    // MARK: - Retry and backoff

    @Test
    func transientFailureSchedulesBoundedBackoffAndRecovers() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .timedOut),
            for: displayA
        )
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .systemBusy),
            for: displayA
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let retryPolicy = DesktopRetryPolicy(
            maximumRetryCount: 3,
            initialDelay: 2,
            multiplier: 2,
            maximumDelay: 30
        )
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            retryPolicy: retryPolicy
        )

        let first = await coordinator.assign(target, to: displayA)
        #expect(first.outcomes.first?.action == .failed)
        #expect(first.outcomes.first?.status == .retrying)
        #expect(first.outcomes.first?.retryDelay == 2)
        #expect(first.outcomes.first?.failure?.kind == .timedOut)
        #expect(scheduler.delays == [2])

        let firstState = await coordinator.state()
        #expect(firstState.displayState(for: displayA)?.consecutiveFailureCount == 1)
        #expect(firstState.displayState(for: displayA)?.nextRetryAt == Self.fixedNow.addingTimeInterval(2))
        #expect(firstState.displayState(for: displayA)?.status == .retrying)

        let firedFirst = await scheduler.fireNext()
        #expect(firedFirst)
        #expect(scheduler.delays == [4])

        let secondState = await coordinator.state()
        #expect(secondState.displayState(for: displayA)?.consecutiveFailureCount == 2)
        #expect(secondState.displayState(for: displayA)?.status == .retrying)
        #expect(secondState.lastReport?.trigger == .retry(displayID: displayA))
        #expect(secondState.lastReport?.outcomes.first?.retryDelay == 4)

        let firedSecond = await scheduler.fireNext()
        #expect(firedSecond)
        #expect(scheduler.isIdle)

        let finalState = await coordinator.state()
        #expect(finalState.displayState(for: displayA)?.status == .synchronized)
        #expect(finalState.displayState(for: displayA)?.failure == nil)
        #expect(finalState.displayState(for: displayA)?.nextRetryAt == nil)
        #expect(finalState.displayState(for: displayA)?.consecutiveFailureCount == 0)
        #expect(finalState.lastReport?.outcomes.first?.action == .applied)

        let calls = await backend.applyCalls
        #expect(calls.count == 3)
    }

    @Test
    func retryExhaustionStopsUntilExplicitRecovery() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .ioFailure),
            for: displayA
        )
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .ioFailure),
            for: displayA
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let retryPolicy = DesktopRetryPolicy(
            maximumRetryCount: 1,
            initialDelay: 1,
            multiplier: 1,
            maximumDelay: 1
        )
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            retryPolicy: retryPolicy
        )

        let first = await coordinator.assign(target, to: displayA)
        #expect(first.outcomes.first?.status == .retrying)
        #expect(first.outcomes.first?.retryDelay == 1)

        _ = await scheduler.fireNext()
        let exhausted = await coordinator.state()
        #expect(exhausted.displayState(for: displayA)?.status == .failed)
        #expect(exhausted.displayState(for: displayA)?.nextRetryAt == nil)
        #expect(scheduler.isIdle)

        let callsAtExhaustion = await backend.applyCalls
        #expect(callsAtExhaustion.count == 2)

        let skipped = await coordinator.handle(.spaceDidChange)
        #expect(skipped.outcomes.first?.action == .failed)
        #expect(skipped.outcomes.first?.status == .failed)
        let callsAfterSkip = await backend.applyCalls
        #expect(callsAfterSkip.count == 2)

        let recovered = await coordinator.handle(.manualRequest)
        #expect(recovered.outcomes.first?.action == .applied)
        #expect(recovered.outcomes.first?.status == .synchronized)

        let finalState = await coordinator.state()
        #expect(finalState.displayState(for: displayA)?.status == .synchronized)
        #expect(finalState.displayState(for: displayA)?.failure == nil)

        let callsAfterRecovery = await backend.applyCalls
        #expect(callsAfterRecovery.count == 3)
    }

    @Test
    func permanentFailureDoesNotRetryAutomatically() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .permissionDenied, message: "denied"),
            for: displayA
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let report = await coordinator.assign(target, to: displayA)
        #expect(report.outcomes.first?.action == .failed)
        #expect(report.outcomes.first?.status == .failed)
        #expect(report.outcomes.first?.retryDelay == nil)
        #expect(report.outcomes.first?.failure?.kind == .permissionDenied)
        #expect(scheduler.isIdle)

        let skipped = await coordinator.handle(.spaceDidChange)
        #expect(skipped.outcomes.first?.action == .failed)
        let callsBeforeRecovery = await backend.applyCalls
        #expect(callsBeforeRecovery.count == 1)

        let recovered = await coordinator.handle(.manualRequest)
        #expect(recovered.outcomes.first?.action == .applied)
        let callsAfterRecovery = await backend.applyCalls
        #expect(callsAfterRecovery.count == 2)
    }

    @Test
    func unclassifiedErrorIsRetriedAsUnknown() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueRawFailure(.boom, for: displayA)
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let report = await coordinator.assign(target, to: displayA)
        #expect(report.outcomes.first?.action == .failed)
        #expect(report.outcomes.first?.status == .retrying)
        #expect(report.outcomes.first?.failure?.stage == .applyingWallpaper)
        #expect(report.outcomes.first?.failure?.kind == .unknown)
        #expect(report.outcomes.first?.retryDelay == 2)
        #expect(scheduler.delays == [2])
    }

    @Test
    func backoffDefersNormalEventsButWakeForcesAttempt() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .systemBusy),
            for: displayA
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let retryPolicy = DesktopRetryPolicy(
            maximumRetryCount: 3,
            initialDelay: 10,
            multiplier: 2,
            maximumDelay: 60
        )
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            retryPolicy: retryPolicy
        )

        _ = await coordinator.assign(target, to: displayA)
        #expect(scheduler.delays == [10])

        let deferred = await coordinator.handle(.spaceDidChange)
        #expect(deferred.outcomes.first?.action == .deferredRetry)
        #expect(deferred.outcomes.first?.status == .retrying)
        #expect(scheduler.delays == [10])

        let callsBeforeWake = await backend.applyCalls
        #expect(callsBeforeWake.count == 1)

        let woke = await coordinator.handle(.systemWake)
        #expect(woke.trigger == .systemWake)
        #expect(woke.outcomes.first?.action == .applied)
        #expect(woke.outcomes.first?.status == .synchronized)
        #expect(scheduler.isIdle)

        let callsAfterWake = await backend.applyCalls
        #expect(callsAfterWake.count == 2)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.status == .synchronized)
        #expect(state.displayState(for: displayA)?.failure == nil)
    }

    @Test
    func disconnectCancelsPendingRetryAndReconnectRetries() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .timedOut),
            for: displayA
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)
        #expect(scheduler.delays == [2])

        await backend.setDisplayIDs([])
        let disconnected = await coordinator.handle(.displayConfigurationChanged)
        #expect(disconnected.outcomes.first?.action == .disconnected)
        #expect(disconnected.outcomes.first?.status == .disconnected)
        #expect(scheduler.isIdle)

        let disconnectedState = await coordinator.state()
        #expect(disconnectedState.assignment(for: displayA)?.wallpaper == target)
        #expect(disconnectedState.displayState(for: displayA)?.status == .disconnected)

        await backend.setDisplayIDs([displayA])
        let reconnected = await coordinator.handle(.displayConfigurationChanged)
        #expect(reconnected.outcomes.first?.action == .applied)
        #expect(reconnected.outcomes.first?.status == .synchronized)

        let finalState = await coordinator.state()
        #expect(finalState.displayState(for: displayA)?.status == .synchronized)
        #expect(finalState.displayState(for: displayA)?.failure == nil)

        let calls = await backend.applyCalls
        #expect(calls.count == 2)
    }

    // MARK: - Connectivity and topology

    @Test
    func emptyTopologyKeepsTargetUntilDisplayAppears() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            initialAssignments: [displayA: target]
        )

        let initial = await coordinator.handle(.initial)
        #expect(initial.outcomes.count == 1)
        #expect(initial.outcomes.first?.action == .disconnected)
        #expect(initial.outcomes.first?.status == .disconnected)

        let absentState = await coordinator.state()
        #expect(absentState.assignment(for: displayA)?.wallpaper == target)
        #expect(absentState.displayState(for: displayA)?.status == .disconnected)

        await backend.setDisplayIDs([displayA])
        let appeared = await coordinator.handle(.displayConfigurationChanged)
        #expect(appeared.outcomes.first?.action == .applied)
        #expect(appeared.outcomes.first?.status == .synchronized)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)
    }

    @Test
    func reconnectRestoresUpdatedTargetForDisconnectedDisplay() async {
        let targetA = wallpaper("target-a")
        let targetB = wallpaper("target-b")
        let targetB2 = wallpaper("target-b2", scaling: .fit)
        let backend = FakeBackend(displayIDs: [displayA, displayB])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign([displayA: targetA, displayB: targetB])

        await backend.setDisplayIDs([displayA])
        let disconnected = await coordinator.handle(.displayConfigurationChanged)
        let disconnectedB = disconnected.outcomes.first { $0.displayID == displayB }
        #expect(disconnectedB?.action == .disconnected)
        let afterDisconnect = await coordinator.state()
        #expect(afterDisconnect.assignment(for: displayB)?.wallpaper == targetB)

        let callsAfterDisconnect = await backend.applyCalls
        let callsForB = callsAfterDisconnect.filter { $0.displayID == displayB }
        #expect(callsForB.count == 1)

        let reassigned = await coordinator.assign(targetB2, to: displayB)
        let reassignedB = reassigned.outcomes.first { $0.displayID == displayB }
        #expect(reassignedB?.action == .disconnected)

        let callsWhileDisconnected = await backend.applyCalls
        #expect(callsWhileDisconnected.filter { $0.displayID == displayB }.count == 1)

        await backend.setDisplayIDs([displayA, displayB])
        let reconnected = await coordinator.handle(.displayConfigurationChanged)
        let reconnectedB = reconnected.outcomes.first { $0.displayID == displayB }
        #expect(reconnectedB?.action == .applied)
        #expect(reconnectedB?.status == .synchronized)

        let finalState = await coordinator.state()
        #expect(finalState.assignment(for: displayB)?.wallpaper == targetB2)
        #expect(finalState.displayState(for: displayB)?.status == .synchronized)

        let finalCalls = await backend.applyCalls
        let finalCallsForB = finalCalls.filter { $0.displayID == displayB }
        #expect(finalCallsForB.count == 2)
        #expect(finalCallsForB.last?.wallpaper == targetB2)
        let currentB = await backend.currentImageURL(for: displayB)
        #expect(currentB == targetB2.imageURL)
    }

    @Test
    func topologyFailurePreservesAssignmentsAndPreviousState() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        await backend.enqueueTopologyFailure(
            DesktopFailure(stage: .readingDisplays, kind: .ioFailure, message: "snapshot failed")
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        let failed = await coordinator.assign(target, to: displayA)
        #expect(failed.topologyFailure?.kind == .ioFailure)
        #expect(failed.topologyFailure?.stage == .readingDisplays)
        #expect(failed.outcomes.isEmpty)
        #expect(failed.didApplyWallpaper == false)

        let failedState = await coordinator.state()
        #expect(failedState.lastTopologyFailure?.kind == .ioFailure)
        #expect(failedState.assignment(for: displayA)?.wallpaper == target)
        #expect(failedState.displayState(for: displayA)?.status == .pending)

        let recovered = await coordinator.handle(.initial)
        #expect(recovered.topologyFailure == nil)
        #expect(recovered.outcomes.first?.action == .applied)

        let recoveredState = await coordinator.state()
        #expect(recoveredState.lastTopologyFailure == nil)
        #expect(recoveredState.displayState(for: displayA)?.status == .synchronized)

        await backend.enqueueTopologyFailure(
            DesktopFailure(stage: .readingDisplays, kind: .timedOut)
        )
        let failedAgain = await coordinator.handle(.spaceDidChange)
        #expect(failedAgain.topologyFailure?.kind == .timedOut)
        #expect(failedAgain.spaceGeneration == 1)
        #expect(failedAgain.outcomes.isEmpty)

        let stateAfterSecondFailure = await coordinator.state()
        #expect(stateAfterSecondFailure.lastTopologyFailure?.kind == .timedOut)
        #expect(stateAfterSecondFailure.displayState(for: displayA)?.isConnected == true)
        #expect(stateAfterSecondFailure.displayState(for: displayA)?.status == .synchronized)
        #expect(stateAfterSecondFailure.assignment(for: displayA)?.wallpaper == target)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)
    }

    @Test
    func removingAssignmentStopsAutomationAndPrunesDisconnectedState() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)
        let removedState = await coordinator.removeAssignment(for: displayA)
        #expect(removedState.assignment(for: displayA) == nil)
        #expect(removedState.displayState(for: displayA)?.desiredWallpaper == nil)
        #expect(removedState.displayState(for: displayA)?.status == .unassigned)

        let afterRemove = await coordinator.handle(.spaceDidChange)
        #expect(afterRemove.outcomes.first?.action == .unassigned)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)

        await backend.setDisplayIDs([])
        let disconnected = await coordinator.handle(.displayConfigurationChanged)
        #expect(disconnected.outcomes.first?.action == .disconnected)

        let finalState = await coordinator.state()
        #expect(finalState.displayState(for: displayA) == nil)
        #expect(finalState.assignments.isEmpty)
    }

    // MARK: - Coalescing

    @Test
    func coalescesConcurrentEventsIntoOneFollowUpPass() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        let gate = Gate()
        let arrival = ArrivalSignal()
        await backend.configureTopologyGate(arrival: arrival, gate: gate)

        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            initialAssignments: [displayA: target]
        )

        let first = Task {
            await coordinator.handle(.spaceDidChange)
        }

        await arrival.wait()

        let second = Task {
            await coordinator.handle(.manualRequest)
        }

        var queued = 0
        for _ in 0..<10_000 {
            let state = await coordinator.state()
            queued = state.queuedReconciliationCount
            if queued == 1 { break }
            await Task.yield()
        }
        #expect(queued == 1)

        await gate.open()

        let firstReport = await first.value
        let secondReport = await second.value

        #expect(firstReport.coalescedTriggerCount == 1)
        #expect(secondReport.coalescedTriggerCount == 1)
        #expect(firstReport.trigger == .manualRequest)
        #expect(secondReport.trigger == .manualRequest)
        #expect(firstReport.outcomes.first?.action == .alreadySynchronized)
        #expect(secondReport.outcomes.first?.action == .alreadySynchronized)

        let topologyCalls = await backend.topologyCallCount
        #expect(topologyCalls == 2)
        let applyCalls = await backend.applyCalls
        #expect(applyCalls.count == 1)

        let state = await coordinator.state()
        #expect(state.spaceGeneration == 1)
        #expect(state.isReconciling == false)
        #expect(state.queuedReconciliationCount == 0)
        #expect(state.displayState(for: displayA)?.status == .synchronized)
    }

    // MARK: - Space changes, protection and scoped writes

    @Test
    func protectedObservationFollowsAccessibleSpaceWallpaper() async {
        let target = wallpaper("target-a")
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign(target, to: displayA)

        let firstSpaceWallpaper = imageURL("user-space-1")
        await backend.setCurrentImageURL(firstSpaceWallpaper, for: displayA)
        let detected = await coordinator.handle(.spaceDidChange)
        #expect(detected.outcomes.first?.action == .manualProtectionDetected)

        // Another Space legitimately shows a different wallpaper. Protection
        // must keep blocking writes, but the recorded observation has to be the
        // wallpaper the user can see and confirm right now.
        let secondSpaceWallpaper = imageURL("user-space-2")
        await backend.setCurrentImageURL(secondSpaceWallpaper, for: displayA)
        let repeated = await coordinator.handle(.spaceDidChange)
        #expect(repeated.outcomes.first?.action == .alreadyProtected)
        #expect(repeated.outcomes.first?.status == .manualProtection)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection?.imageURL == secondSpaceWallpaper)
        #expect(state.displayState(for: displayA)?.manualProtection?.origin == .detectedExternalChange)
        #expect(state.displayState(for: displayA)?.manualProtection?.spaceGeneration == 1)

        let calls = await backend.applyCalls
        #expect(calls.count == 1)
        let currentURL = await backend.currentImageURL(for: displayA)
        #expect(currentURL == secondSpaceWallpaper)
    }

    @Test
    func detectedProtectionKeepsBlockingEvenWhenSpaceShowsManagedImage() async {
        let targetA = wallpaper("target-a")
        let targetB = wallpaper("target-b")
        let backend = FakeBackend(displayIDs: [displayA, displayB])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(backend: backend, scheduler: scheduler, clock: clock)

        _ = await coordinator.assign([displayA: targetA, displayB: targetB])

        await backend.setCurrentImageURL(imageURL("user-manual"), for: displayA)
        let detected = await coordinator.handle(.spaceDidChange)
        #expect(detected.outcomes.first { $0.displayID == displayA }?.action == .manualProtectionDetected)

        // Public APIs cannot prove that this is the same desktop as before,
        // even when the now-visible image is one Daybreak wrote earlier.
        // Protection stays in force; only the confirmable observation moves.
        await backend.setCurrentImageURL(targetB.imageURL, for: displayA)
        let report = await coordinator.handle(.spaceDidChange)
        let outcome = report.outcomes.first { $0.displayID == displayA }
        #expect(outcome?.action == .alreadyProtected)
        #expect(outcome?.status == .manualProtection)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection?.imageURL == targetB.imageURL)
        #expect(state.displayState(for: displayA)?.observedImageURL == targetB.imageURL)
        let calls = await backend.applyCalls
        #expect(calls.filter { $0.displayID == displayA }.count == 1)
    }

    @Test
    func unknownWallpaperIsProtectedBeforeFirstSuccessfulApply() async {
        let target = wallpaper("target-a")
        let original = imageURL("user-original")
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: original]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            initialAssignments: [displayA: target]
        )

        let report = await coordinator.handle(.initial)
        #expect(report.outcomes.first?.action == .manualProtectionDetected)
        #expect(report.outcomes.first?.status == .manualProtection)

        let calls = await backend.applyCalls
        #expect(calls.isEmpty)

        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.manualProtection?.imageURL == original)
        #expect(state.displayState(for: displayA)?.manualProtection?.origin == .detectedExternalChange)
        #expect(state.displayState(for: displayA)?.observedImageURL == original)
    }

    @Test
    func scopedAssignmentReconcilesOnlyRequestedDisplays() async {
        let targetA = wallpaper("target-a")
        let targetB = wallpaper("target-b")
        let backend = FakeBackend(
            displayIDs: [displayA, displayB],
            currentImageURLs: [
                displayA: imageURL("user-a"),
                displayB: imageURL("user-b")
            ]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            initialAssignments: [displayB: targetB]
        )

        let report = await coordinator.assign(
            [displayA: targetA],
            reconcilingOnly: [displayA]
        )
        #expect(report.outcomes.map(\.displayID) == [displayA])
        #expect(report.outcomes.first?.action == .applied)

        let calls = await backend.applyCalls
        #expect(calls.map(\.displayID) == [displayA])

        let state = await coordinator.state()
        #expect(state.assignment(for: displayB)?.wallpaper == targetB)
        #expect(state.displayState(for: displayB)?.lastSuccessfulApply == nil)
        let currentB = await backend.currentImageURL(for: displayB)
        #expect(currentB == imageURL("user-b"))
    }

    // MARK: - One-pass explicit assignment authorization

    @Test
    func explicitAssignmentAuthorizationDoesNotSurviveTopologyFailure() async {
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock
        )
        let target = wallpaper("target-a")
        await backend.enqueueTopologyFailure(
            DesktopFailure(stage: .readingDisplays, kind: .ioFailure, message: "synthetic")
        )

        let failed = await coordinator.assign(target, to: displayA)
        #expect(failed.topologyFailure != nil)

        // The display is now readable and shows an unmanaged user wallpaper.
        // A later event must treat it as a manual selection, not inherit the
        // explicit assignment's one-pass authorization.
        await backend.setCurrentImageURL(imageURL("user-a"), for: displayA)
        let next = await coordinator.handle(.spaceDidChange)
        #expect(next.topologyFailure == nil)
        #expect(next.outcomes.first?.action == .manualProtectionDetected)
        let calls = await backend.applyCalls
        #expect(calls.isEmpty)
        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.status == .manualProtection)
    }

    @Test
    func explicitAssignmentAuthorizationDoesNotSurviveFailedWrite() async {
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: imageURL("user-a")]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock
        )
        let target = wallpaper("target-a")
        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .ioFailure, message: "synthetic"),
            for: displayA
        )

        let failed = await coordinator.assign(target, to: displayA)
        #expect(failed.outcomes.first?.failure != nil)

        // A system recovery event grants a new retry budget. It must not reuse
        // the failed explicit assignment's permission to replace an unknown
        // wallpaper.
        await backend.setCurrentImageURL(imageURL("user-b"), for: displayA)
        let next = await coordinator.handle(.systemWake)
        #expect(next.outcomes.first?.action == .manualProtectionDetected)
        let calls = await backend.applyCalls
        #expect(calls.count == 1)
        let state = await coordinator.state()
        #expect(state.displayState(for: displayA)?.status == .manualProtection)
    }

    @Test
    func failedProtectionReleaseDoesNotAuthorizeLaterPass() async {
        let backend = FakeBackend(
            displayIDs: [displayA],
            currentImageURLs: [displayA: imageURL("user-a")]
        )
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let target = wallpaper("target-a")
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock,
            initialAssignments: [displayA: target]
        )

        let detected = await coordinator.handle(.spaceDidChange)
        #expect(detected.outcomes.first?.action == .manualProtectionDetected)
        var calls = await backend.applyCalls
        #expect(calls.isEmpty)

        await backend.enqueueFailure(
            DesktopFailure(stage: .applyingWallpaper, kind: .ioFailure, message: "synthetic"),
            for: displayA
        )
        let released = await coordinator.clearManualProtection(for: displayA)
        #expect(released.outcomes.first?.failure != nil)

        // The failed one-pass release must not authorize a later system event.
        await backend.setCurrentImageURL(imageURL("user-b"), for: displayA)
        let next = await coordinator.handle(.systemWake)
        #expect(next.outcomes.first?.action == .manualProtectionDetected)
        calls = await backend.applyCalls
        #expect(calls.count == 1)
    }

    @Test
    func failedExplicitAssignmentForUnobservedDisplayDoesNotAuthorizeLaterPass() async {
        let backend = FakeBackend(displayIDs: [displayA])
        let scheduler = ManualRetryScheduler()
        let clock = TestClock(Self.fixedNow)
        let coordinator = makeCoordinator(
            backend: backend,
            scheduler: scheduler,
            clock: clock
        )
        let target = wallpaper("target-a")
        await backend.enqueueTopologyFailure(
            DesktopFailure(stage: .readingDisplays, kind: .timedOut, message: "synthetic")
        )
        _ = await coordinator.assign(target, to: displayA)

        // A different event must not consume the stale pending authorization
        // when the runtime is first created.
        await backend.setCurrentImageURL(imageURL("user-a"), for: displayA)
        let recovered = await coordinator.handle(.userLogin)
        #expect(recovered.outcomes.first?.action == .manualProtectionDetected)
        let calls = await backend.applyCalls
        #expect(calls.isEmpty)
    }

    // MARK: - Test doubles

    private struct RawBackendError: Error, Hashable, Sendable {
        static let boom = RawBackendError()
    }

    private actor FakeBackend: DesktopPlatformBackend {
        struct ApplyCall: Hashable, Sendable {
            let displayID: DesktopDisplayID
            let wallpaper: DesktopWallpaper
        }

        private var displayIDs: [DesktopDisplayID]
        private var currentImageURLs: [DesktopDisplayID: URL]
        private var currentScalings: [DesktopDisplayID: DesktopImageScaling]
        private let reportsScaling: Bool
        private var failureQueues: [DesktopDisplayID: [DesktopFailure]] = [:]
        private var rawFailureQueues: [DesktopDisplayID: [RawBackendError]] = [:]
        private var topologyFailureQueue: [DesktopFailure] = []
        private var hasSeparateSpaces: Bool
        private var topologyArrival: ArrivalSignal?
        private var topologyGate: Gate?

        private(set) var topologyCallCount = 0
        private(set) var applyCalls: [ApplyCall] = []

        init(
            displayIDs: [DesktopDisplayID],
            currentImageURLs: [DesktopDisplayID: URL] = [:],
            currentScalings: [DesktopDisplayID: DesktopImageScaling] = [:],
            reportsScaling: Bool = true,
            screensHaveSeparateSpaces: Bool = false
        ) {
            self.displayIDs = displayIDs
            self.currentImageURLs = currentImageURLs
            self.currentScalings = currentScalings
            self.reportsScaling = reportsScaling
            self.hasSeparateSpaces = screensHaveSeparateSpaces
        }

        func setDisplayIDs(_ displayIDs: [DesktopDisplayID]) {
            self.displayIDs = displayIDs
        }

        func setCurrentImageURL(_ url: URL?, for displayID: DesktopDisplayID) {
            if let url {
                currentImageURLs[displayID] = url
            } else {
                currentImageURLs.removeValue(forKey: displayID)
                currentScalings.removeValue(forKey: displayID)
            }
        }

        func setCurrentScaling(_ scaling: DesktopImageScaling?, for displayID: DesktopDisplayID) {
            currentScalings[displayID] = scaling
        }

        func currentImageURL(for displayID: DesktopDisplayID) -> URL? {
            currentImageURLs[displayID]
        }

        func currentScaling(for displayID: DesktopDisplayID) -> DesktopImageScaling? {
            currentScalings[displayID]
        }

        func setScreensHaveSeparateSpaces(_ value: Bool) {
            hasSeparateSpaces = value
        }

        func enqueueFailure(_ failure: DesktopFailure, for displayID: DesktopDisplayID) {
            failureQueues[displayID, default: []].append(failure)
        }

        func enqueueRawFailure(_ failure: RawBackendError, for displayID: DesktopDisplayID) {
            rawFailureQueues[displayID, default: []].append(failure)
        }

        func enqueueTopologyFailure(_ failure: DesktopFailure) {
            topologyFailureQueue.append(failure)
        }

        func configureTopologyGate(arrival: ArrivalSignal?, gate: Gate?) {
            topologyArrival = arrival
            topologyGate = gate
        }

        func readTopology() async throws -> DesktopTopology {
            topologyCallCount += 1
            if let topologyArrival {
                await topologyArrival.signal()
            }
            if let topologyGate {
                await topologyGate.wait()
            }
            if !topologyFailureQueue.isEmpty {
                throw topologyFailureQueue.removeFirst()
            }
            let snapshots = displayIDs.map { displayID in
                DesktopDisplaySnapshot(
                    displayID: displayID,
                    currentImageURL: currentImageURLs[displayID],
                    reportedScaling: reportsScaling ? currentScalings[displayID] : nil
                )
            }
            return DesktopTopology(
                displays: snapshots,
                screensHaveSeparateSpaces: hasSeparateSpaces
            )
        }

        func applyWallpaper(_ wallpaper: DesktopWallpaper, to displayID: DesktopDisplayID) async throws {
            applyCalls.append(ApplyCall(displayID: displayID, wallpaper: wallpaper))

            if var queue = failureQueues[displayID], !queue.isEmpty {
                let failure = queue.removeFirst()
                failureQueues[displayID] = queue
                throw failure
            }
            if var queue = rawFailureQueues[displayID], !queue.isEmpty {
                let failure = queue.removeFirst()
                rawFailureQueues[displayID] = queue
                throw failure
            }

            currentImageURLs[displayID] = wallpaper.imageURL
            currentScalings[displayID] = wallpaper.scaling
        }
    }

    private final class ManualRetryScheduler: @unchecked Sendable, DesktopRetryScheduling {
        private struct Pending {
            let id: UUID
            let delay: TimeInterval
            let operation: @Sendable () async -> Void
        }

        private let lock = NSLock()
        private var pending: [Pending] = []

        func schedule(
            after delay: TimeInterval,
            operation: @escaping @Sendable () async -> Void
        ) -> DesktopRetryCancellation {
            let id = UUID()
            lock.withLock {
                pending.append(Pending(id: id, delay: delay, operation: operation))
            }
            return DesktopRetryCancellation { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.pending.removeAll { $0.id == id }
                }
            }
        }

        var delays: [TimeInterval] {
            lock.withLock { pending.map(\.delay) }
        }

        var isIdle: Bool {
            lock.withLock { pending.isEmpty }
        }

        @discardableResult
        func fireNext() async -> Bool {
            let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            guard let next else { return false }
            await next.operation()
            return true
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var now: Date {
            lock.withLock { value }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    private actor ArrivalSignal {
        private var available = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            if waiters.isEmpty {
                available += 1
            } else {
                waiters.removeFirst().resume()
            }
        }

        func wait() async {
            if available > 0 {
                available -= 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }
}
