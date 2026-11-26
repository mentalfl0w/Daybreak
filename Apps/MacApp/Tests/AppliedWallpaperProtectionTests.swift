import AppKit
import DaybreakCore
import Foundation
import Testing
@testable import Daybreak

@Suite("Applied wallpaper protection")
struct AppliedWallpaperProtectionTests {
    private let displayA = DesktopDisplayID("display-a")
    private let displayB = DesktopDisplayID("display-b")

    private func wallpaperID(_ suffix: String) -> WallpaperID {
        WallpaperID(source: .bing, sourceImageID: "image-\(suffix)")
    }

    @Test("A readable current URL selects that display's current wallpaper")
    func readableCurrentURLIsAuthoritative() {
        let oldA = wallpaperID("old-a")
        let newA = wallpaperID("new-a")
        let newAURL = URL(fileURLWithPath: "/tmp/daybreak-new-a.png")

        let current = AppliedWallpaperProtection.current(
            previous: [displayA: oldA],
            connectedDisplayIDs: [displayA],
            currentURLs: [displayA: newAURL],
            confirmedURLs: [:],
            resolved: [newAURL: newA]
        )

        #expect(current[displayA] == newA)
    }

    @Test("A readable external wallpaper releases the previous Daybreak image")
    func readableExternalURLReleasesPrevious() {
        let oldA = wallpaperID("old-a")
        let externalURL = URL(fileURLWithPath: "/tmp/daybreak-external.png")

        let current = AppliedWallpaperProtection.current(
            previous: [displayA: oldA],
            connectedDisplayIDs: [displayA],
            currentURLs: [displayA: externalURL],
            confirmedURLs: [displayA: URL(fileURLWithPath: "/tmp/daybreak-old-a.png")],
            resolved: [:]
        )

        #expect(current.isEmpty)
    }

    @Test("An unreadable display falls back to its confirmed write")
    func unreadableFallsBackToConfirmed() {
        let oldA = wallpaperID("old-a")
        let newA = wallpaperID("new-a")
        let newAURL = URL(fileURLWithPath: "/tmp/daybreak-new-a.png")

        let current = AppliedWallpaperProtection.current(
            previous: [displayA: oldA],
            connectedDisplayIDs: [displayA],
            currentURLs: [:],
            confirmedURLs: [displayA: newAURL],
            resolved: [newAURL: newA]
        )

        #expect(current[displayA] == newA)
    }

    @Test("An unreadable display without a confirmed URL keeps its bounded fallback")
    func unreadableFallsBackToPrevious() {
        let oldA = wallpaperID("old-a")

        let current = AppliedWallpaperProtection.current(
            previous: [displayA: oldA],
            connectedDisplayIDs: [displayA],
            currentURLs: [:],
            confirmedURLs: [:],
            resolved: [:]
        )

        #expect(current[displayA] == oldA)
    }

    @Test("A disconnected display is no longer protected")
    func disconnectedDisplayIsDropped() {
        let oldA = wallpaperID("old-a")
        let oldB = wallpaperID("old-b")
        let sharedURL = URL(fileURLWithPath: "/tmp/daybreak-shared.png")

        let current = AppliedWallpaperProtection.current(
            previous: [displayA: oldA, displayB: oldB],
            connectedDisplayIDs: [displayA],
            currentURLs: [displayA: sharedURL],
            confirmedURLs: [:],
            resolved: [sharedURL: oldA]
        )

        #expect(current == [displayA: oldA])
        #expect(current[displayB] == nil)
    }

    @Test("A wallpaper shared by two connected displays stays once")
    func sharedWallpaperPreserved() {
        let shared = wallpaperID("shared")
        let sharedURL = URL(fileURLWithPath: "/tmp/daybreak-shared.png")

        let current = AppliedWallpaperProtection.current(
            previous: [:],
            connectedDisplayIDs: [displayA, displayB],
            currentURLs: [displayA: sharedURL, displayB: sharedURL],
            confirmedURLs: [:],
            resolved: [sharedURL: shared]
        )

        #expect(current == [displayA: shared, displayB: shared])
    }

    @Test("Local original asset URLs map back to wallpaper identity")
    func localAssetURLMapping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakAppliedMapping-\(UUID().uuidString)", isDirectory: true)
        let service = try TodayService(directory: directory)
        let imageA = wallpaperID("a")

        _ = try await service.repository.storeAsset(
            Data([0x01]),
            kind: .original,
            for: imageA,
            fileExtension: "png"
        )
        let storedAssetURL = await service.repository.assetURL(kind: .original, for: imageA)
        let assetURL = try #require(storedAssetURL)
        let missingURL = URL(fileURLWithPath: "/tmp/daybreak-not-cached.png")

        let resolved = await service.appliedWallpaperIDs(
            forAssetURLs: [assetURL, missingURL]
        )

        #expect(resolved[assetURL] == imageA)
        #expect(resolved[missingURL] == nil)

        try await service.replaceAppliedWallpapers([imageA])
        let snapshot = await service.repository.snapshot()
        #expect(snapshot.appliedWallpapers == Set([imageA]))

        // Replacing with an empty current set releases the image; it is not a
        // permanent historical protection.
        try await service.replaceAppliedWallpapers([])
        let released = await service.repository.snapshot()
        #expect(released.appliedWallpapers.isEmpty)
    }
}

// MARK: - Automatic refresh

@MainActor
private final class FakeAutomaticWallpaperIntegration: MacWallpaperIntegrating {
    var onStatusChange: (@MainActor () -> Void)?
    var outcome = WallpaperAutoOutcome(
        enabled: true,
        message: "",
        blockedReason: nil,
        error: nil,
        requiresDisableRetry: false,
        targetUpdated: false
    )
    private(set) var updatedImageURLs: [URL] = []
    private(set) var reconciliationRequests = 0
    private(set) var reconciliationImageURLs: [URL] = []
    /// Deterministic suspension points for concurrency regression tests.
    /// Other tests leave both nil.
    var updateGate: RequestGate?
    var reconciliationGate: RequestGate?
    private(set) var appliedManualURLs: [URL] = []
    private(set) var adoptionImageURLs: [URL] = []
    var displays: [DesktopDisplayOption] = []
    var settledDisplayIDs: [DesktopDisplayID] = []
    var adoptionCandidateDisplayIDs: [DesktopDisplayID] = []
    var adoptionOutcome: WallpaperAutoOutcome?
    private var adoptedDisplayIDs: Set<DesktopDisplayID> = []
    var manualApplyOutcome = WallpaperApplyOutcome(
        appliedDisplayIDs: [],
        failures: [],
        blocked: [],
        message: "已更新"
    )

    func setApplicationProtection(_ protection: any WallpaperApplicationProtecting) async {}
    func connectedDisplays() async -> [DesktopDisplayOption] { displays }
    func snapshotDisplays() async -> [DesktopDisplayOption] { displays }
    func appliedWallpaperURLs() async -> [DesktopDisplayID: URL] { [:] }
    func currentWallpaperURLs() async -> [DesktopDisplayID: URL] { [:] }
    func resumeAutomation() async -> WallpaperAutoOutcome { outcome }
    func applyManually(
        imageURL: URL,
        displayID: DesktopDisplayID?
    ) async throws -> WallpaperApplyOutcome {
        appliedManualURLs.append(imageURL)
        return manualApplyOutcome
    }
    func enableAutoSync(imageURL: URL) async throws -> WallpaperApplyOutcome {
        throw WallpaperIntegrationError.noConnectedDisplays
    }
    func setAutomaticOverwrite(_ enabled: Bool) async -> WallpaperAutoOutcome {
        outcome = WallpaperAutoOutcome(
            enabled: outcome.enabled,
            automaticOverwriteEnabled: enabled,
            message: outcome.message,
            blockedReason: outcome.blockedReason,
            error: outcome.error,
            requiresDisableRetry: outcome.requiresDisableRetry,
            targetUpdated: outcome.targetUpdated
        )
        return outcome
    }
    func disableAutoSync() async -> WallpaperAutoOutcome { outcome }
    func automationStatus() async -> WallpaperAutoOutcome { outcome }
    func updateAutoTarget(imageURL: URL) async -> WallpaperAutoOutcome {
        updatedImageURLs.append(imageURL)
        await updateGate?.arriveAndWait()
        return outcome
    }
    func requestReconciliation(
        expectedImageURL: URL
    ) async -> [DesktopDisplayID] {
        reconciliationRequests += 1
        reconciliationImageURLs.append(expectedImageURL)
        await reconciliationGate?.arriveAndWait()
        return settledDisplayIDs
    }

    func adoptAutoTargetForConnectedDisplays(
        imageURL: URL
    ) async -> WallpaperAutoTargetAdoption {
        adoptionImageURLs.append(imageURL)
        let connected = Set(displays.map(\.id))
        let needed = adoptionCandidateDisplayIDs.filter {
            connected.contains($0) && !adoptedDisplayIDs.contains($0)
        }
        adoptedDisplayIDs.formUnion(needed)
        return WallpaperAutoTargetAdoption(
            updatedDisplayIDs: needed,
            outcome: adoptionOutcome ?? outcome
        )
    }

    func guardBlocks() async -> [WallpaperGuardInfo] { [] }
    func confirmOverwrite(
        displayID: DesktopDisplayID,
        observedImageURL: URL?
    ) async throws -> WallpaperApplyOutcome {
        throw WallpaperIntegrationError.staleGuardBlock
    }
}

/// Mutable "market/content still current" state shared with the coordinator's
/// validity closure while its integration call is suspended.
@MainActor
private final class CurrentStateFlag {
    var isCurrent = true
}

@Suite("Wallpaper automatic target coordination")
struct WallpaperAutoTargetCoordinatorTests {
    private let originalURL = URL(fileURLWithPath: "/tmp/daybreak-original.png")

    private func payload(
        date: String,
        imageID: String,
        originalURL: URL?
    ) -> TodayPayload {
        let day = LocalDate(iso8601: date)!
        return TodayPayload(
            market: .zhCN,
            marketToday: day,
            occurrence: WallpaperOccurrence(
                source: .bing,
                market: .zhCN,
                localDate: day,
                wallpaperID: WallpaperID(source: .bing, sourceImageID: imageID)
            ),
            metadata: nil,
            wallpaper: nil,
            storyMatch: nil,
            thumbnailURL: nil,
            originalURL: originalURL,
            cachedAt: nil
        )
    }

    private func outcome(
        targetUpdated: Bool,
        enabled: Bool = true
    ) -> WallpaperAutoOutcome {
        WallpaperAutoOutcome(
            enabled: enabled,
            message: "",
            blockedReason: nil,
            error: targetUpdated ? nil : "目标保存失败",
            requiresDisableRetry: false,
            targetUpdated: targetUpdated
        )
    }

    @Test("A failed target update never requests reconciliation")
    @MainActor
    func failedTargetUpdateDoesNotReconcile() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: false)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        let update = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs.count == 1)
        #expect(integration.reconciliationRequests == 0)
        #expect(!update.didRequestReconciliation)
        #expect(update.failed)
        #expect(coordinator.lastUpdateFailed)
    }

    @Test("A confirmed target update requests reconciliation once")
    @MainActor
    func confirmedTargetUpdateReconciles() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let value = payload(date: "2026-11-24", imageID: "new", originalURL: originalURL)

        let update = await coordinator.updateIfNeeded(
            for: value,
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs == [originalURL])
        #expect(integration.reconciliationRequests == 1)
        #expect(update.targetUpdated)
        #expect(update.didRequestReconciliation)
        #expect(update.settledDisplayIDs.isEmpty)
        #expect(!update.failed)
        #expect(coordinator.lastTargetKey == value.key)
    }

    @Test("Settled displays come only from a real reconciliation result")
    @MainActor
    func settledDisplaysPropagateFromReconciliation() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let settledDisplay = DesktopDisplayID("display-settled")
        integration.settledDisplayIDs = [settledDisplay]
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let value = payload(date: "2026-11-24", imageID: "new", originalURL: originalURL)

        let update = await coordinator.updateIfNeeded(
            for: value,
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(update.targetUpdated)
        #expect(update.settledDisplayIDs == [settledDisplay])
        #expect(integration.reconciliationImageURLs == [originalURL])
    }

    @Test("A failed target update never yields settled displays")
    @MainActor
    func failedTargetUpdateHasNoSettledDisplays() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: false)
        integration.settledDisplayIDs = [DesktopDisplayID("display-stale")]
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        let update = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(!update.targetUpdated)
        #expect(update.settledDisplayIDs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
    }

    @Test("A closed gate saves a target without claiming it settled")
    @MainActor
    func closedGateHasNoSettledDisplays() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true, enabled: false)
        integration.settledDisplayIDs = [DesktopDisplayID("display-stale")]
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        let update = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(update.targetUpdated)
        #expect(update.settledDisplayIDs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
    }

    @Test("The same occurrence is not rewritten or reconciled twice")
    @MainActor
    func duplicateOccurrenceIsSkipped() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let value = payload(date: "2026-11-24", imageID: "new", originalURL: originalURL)

        _ = await coordinator.updateIfNeeded(
            for: value,
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )
        let second = await coordinator.updateIfNeeded(
            for: value,
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs.count == 1)
        #expect(integration.reconciliationRequests == 1)
        #expect(!second.targetUpdated)
        #expect(!second.failed)
    }

    @Test("A target saved while the gate is closed is not reconciled")
    @MainActor
    func closedGateBlocksReconciliation() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true, enabled: false)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        let update = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.reconciliationRequests == 0)
        #expect(update.targetUpdated)
        #expect(!update.failed)
    }

    @Test("Without an active opt-in no target is written")
    @MainActor
    func optOutBlocksTargetUpdate() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        let update = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: originalURL),
            autoSyncEnabled: false,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
        #expect(!update.failed)
    }

    @Test("A required disable retry blocks target writes")
    @MainActor
    func disableRetryBlocksTargetUpdate() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        _ = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: true
        )

        #expect(integration.updatedImageURLs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
    }

    @Test("An older cached occurrence never replaces a newer target")
    @MainActor
    func olderOccurrenceDoesNotRegressTarget() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        _ = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "newer", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )
        _ = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-23", imageID: "older", originalURL: originalURL),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs.count == 1)
        #expect(integration.reconciliationRequests == 1)
    }

    @Test("A consent target baseline is not rewritten by the next refresh")
    @MainActor
    func consentBaselineSkipsDuplicateUpdate() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let value = payload(date: "2026-11-24", imageID: "new", originalURL: originalURL)
        coordinator.recordConsentTarget(key: value.key, sourceDate: value.sourceDate)

        let update = await coordinator.updateIfNeeded(
            for: value,
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
        #expect(!update.targetUpdated)
    }

    @Test("A payload without an original image cannot update the target")
    @MainActor
    func missingOriginalURLFailsClosed() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)

        let update = await coordinator.updateIfNeeded(
            for: payload(date: "2026-11-24", imageID: "new", originalURL: nil),
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )

        #expect(integration.updatedImageURLs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
        #expect(update.failed)
        #expect(coordinator.lastUpdateFailed)
    }

    @Test("A reset during an in-flight target write discards the stale result")
    @MainActor
    func resetDuringTargetWriteSupersedesResult() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        integration.settledDisplayIDs = [DesktopDisplayID("display-stale")]
        let gate = RequestGate()
        integration.updateGate = gate
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let value = payload(date: "2026-11-24", imageID: "stale", originalURL: originalURL)

        let task = Task {
            await coordinator.updateIfNeeded(
                for: value,
                autoSyncEnabled: true,
                isUpdatingAutomation: false,
                requiresDisableRetry: false
            )
        }
        #expect(await waitUntil { await gate.arrivalCount() >= 1 })

        // A market switch (or an opt-out) resets the coordinator while the
        // integration is still writing the old target.
        coordinator.reset()
        await gate.releaseAll()
        let update = await task.value

        #expect(update.superseded)
        #expect(update.outcome == nil)
        #expect(!update.targetUpdated)
        #expect(!update.didRequestReconciliation)
        #expect(update.settledDisplayIDs.isEmpty)
        #expect(!update.failed)
        #expect(coordinator.lastTargetKey == nil)
        #expect(coordinator.lastUpdateFailed == false)
        #expect(integration.reconciliationRequests == 0)
    }

    @Test("A content state change during reconciliation discards its result")
    @MainActor
    func contentChangeDuringReconciliationSupersedesResult() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        integration.settledDisplayIDs = [DesktopDisplayID("display-stale")]
        let updateGate = RequestGate()
        let reconciliationGate = RequestGate()
        integration.updateGate = updateGate
        integration.reconciliationGate = reconciliationGate
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let current = CurrentStateFlag()
        let value = payload(date: "2026-11-24", imageID: "stale", originalURL: originalURL)

        let task = Task {
            await coordinator.updateIfNeeded(
                for: value,
                autoSyncEnabled: true,
                isUpdatingAutomation: false,
                requiresDisableRetry: false,
                isCurrent: { current.isCurrent }
            )
        }
        #expect(await waitUntil { await updateGate.arrivalCount() >= 1 })
        await updateGate.releaseAll()
        #expect(await waitUntil { await reconciliationGate.arrivalCount() >= 1 })

        // The market switch happens while the reconciliation write is already
        // running. That write cannot be recalled, but its result must never be
        // reported as a confirmation for the new content state.
        current.isCurrent = false
        await reconciliationGate.releaseAll()
        let update = await task.value

        #expect(update.superseded)
        #expect(update.outcome == nil)
        #expect(!update.targetUpdated)
        #expect(!update.didRequestReconciliation)
        #expect(update.settledDisplayIDs.isEmpty)
        #expect(!update.failed)
    }

    @Test("A newer target operation supersedes an older in-flight write")
    @MainActor
    func newerOperationSupersedesOlderInFlightWrite() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let gate = RequestGate()
        integration.updateGate = gate
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let older = payload(
            date: "2026-11-23",
            imageID: "older",
            originalURL: originalURL
        )
        let newerURL = URL(fileURLWithPath: "/tmp/daybreak-newer.png")
        let newer = payload(
            date: "2026-11-24",
            imageID: "newer",
            originalURL: newerURL
        )

        let olderTask = Task {
            await coordinator.updateIfNeeded(
                for: older,
                autoSyncEnabled: true,
                isUpdatingAutomation: false,
                requiresDisableRetry: false
            )
        }
        #expect(await waitUntil { await gate.arrivalCount() >= 1 })
        let newerTask = Task {
            await coordinator.updateIfNeeded(
                for: newer,
                autoSyncEnabled: true,
                isUpdatingAutomation: false,
                requiresDisableRetry: false
            )
        }
        #expect(await waitUntil { await gate.arrivalCount() >= 2 })
        await gate.releaseAll()

        let olderUpdate = await olderTask.value
        let newerUpdate = await newerTask.value

        #expect(olderUpdate.superseded)
        #expect(!olderUpdate.targetUpdated)
        #expect(!newerUpdate.superseded)
        #expect(newerUpdate.targetUpdated)
        #expect(coordinator.lastTargetKey == newer.key)
        #expect(integration.reconciliationImageURLs == [newerURL])
    }

    @Test("A duplicate request during reconciliation keeps the confirmed result")
    @MainActor
    func duplicateDuringReconciliationKeepsResult() async {
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = outcome(targetUpdated: true)
        let settledDisplay = DesktopDisplayID("display-settled")
        integration.settledDisplayIDs = [settledDisplay]
        let gate = RequestGate()
        integration.reconciliationGate = gate
        let coordinator = WallpaperAutoTargetCoordinator(wallpaper: integration)
        let value = payload(date: "2026-11-24", imageID: "new", originalURL: originalURL)

        let task = Task {
            await coordinator.updateIfNeeded(
                for: value,
                autoSyncEnabled: true,
                isUpdatingAutomation: false,
                requiresDisableRetry: false
            )
        }
        #expect(await waitUntil { await gate.arrivalCount() >= 1 })

        // The occurrence is already persisted, so this call is a no-op. It
        // must not invalidate the reconciliation already in flight.
        let duplicate = await coordinator.updateIfNeeded(
            for: value,
            autoSyncEnabled: true,
            isUpdatingAutomation: false,
            requiresDisableRetry: false
        )
        #expect(!duplicate.targetUpdated)
        #expect(!duplicate.superseded)

        await gate.releaseAll()
        let update = await task.value
        #expect(!update.superseded)
        #expect(update.targetUpdated)
        #expect(update.didRequestReconciliation)
        #expect(update.settledDisplayIDs == [settledDisplay])
    }
}

@Suite("Wallpaper daily refresh policy")
struct WallpaperDailyRefreshPolicyTests {
    private let day = LocalDate(iso8601: "2026-11-24")!
    private let market = Market.zhCN

    @Test("The first attempt is 00:05 in the market time zone")
    func firstAttemptUsesMarketTimeZone() throws {
        let attempt = try #require(
            WallpaperDailyRefreshPolicy.firstAttempt(on: day, market: market)
        )
        let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: attempt
        )

        #expect(components.year == 2026)
        #expect(components.month == 11)
        #expect(components.day == 24)
        #expect(components.hour == 0)
        #expect(components.minute == 5)
        #expect(components.second == 0)
    }

    @Test("A day is due only after the publish grace and outside the retry window")
    func duePolicy() throws {
        let first = try #require(
            WallpaperDailyRefreshPolicy.firstAttempt(on: day, market: market)
        )
        let afterGrace = first.addingTimeInterval(10 * 60)

        #expect(!WallpaperDailyRefreshPolicy.isDue(
            now: first.addingTimeInterval(-1),
            market: market,
            completedDay: nil,
            lastAttemptAt: nil
        ))
        #expect(WallpaperDailyRefreshPolicy.isDue(
            now: afterGrace,
            market: market,
            completedDay: nil,
            lastAttemptAt: nil
        ))
        #expect(!WallpaperDailyRefreshPolicy.isDue(
            now: afterGrace,
            market: market,
            completedDay: day,
            lastAttemptAt: nil
        ))
        #expect(!WallpaperDailyRefreshPolicy.isDue(
            now: afterGrace,
            market: market,
            completedDay: nil,
            lastAttemptAt: afterGrace.addingTimeInterval(-30 * 60)
        ))
        #expect(WallpaperDailyRefreshPolicy.isDue(
            now: afterGrace,
            market: market,
            completedDay: nil,
            lastAttemptAt: afterGrace.addingTimeInterval(
                -(WallpaperDailyRefreshPolicy.retryInterval + 60)
            )
        ))
    }

    @Test("The next check targets the grace, retry, or next local midnight")
    func nextCheckDelay() throws {
        let first = try #require(
            WallpaperDailyRefreshPolicy.firstAttempt(on: day, market: market)
        )
        let midnight = first.addingTimeInterval(-WallpaperDailyRefreshPolicy.publishGrace)

        let beforeGrace = WallpaperDailyRefreshPolicy.nextCheckDelay(
            now: midnight,
            market: market,
            completedDay: nil,
            lastAttemptAt: nil
        )
        #expect(abs(beforeGrace - WallpaperDailyRefreshPolicy.publishGrace) < 1)

        let afterSettled = first.addingTimeInterval(60)
        let untilTomorrow = WallpaperDailyRefreshPolicy.nextCheckDelay(
            now: afterSettled,
            market: market,
            completedDay: day,
            lastAttemptAt: nil
        )
        #expect(untilTomorrow > 23 * 60 * 60)
        #expect(untilTomorrow < 24 * 60 * 60)

        let retryNow = first.addingTimeInterval(10 * 60)
        let untilRetry = WallpaperDailyRefreshPolicy.nextCheckDelay(
            now: retryNow,
            market: market,
            completedDay: nil,
            lastAttemptAt: retryNow.addingTimeInterval(-10 * 60)
        )
        #expect(abs(untilRetry - (WallpaperDailyRefreshPolicy.retryInterval - 10 * 60)) < 1)
    }

    @Test("A completed day waits for the next market midnight")
    func completedDayIsNotDueAgain() throws {
        let first = try #require(
            WallpaperDailyRefreshPolicy.firstAttempt(on: day, market: market)
        )
        let late = first.addingTimeInterval(20 * 60 * 60)

        #expect(!WallpaperDailyRefreshPolicy.isDue(
            now: late,
            market: market,
            completedDay: day,
            lastAttemptAt: first
        ))
    }
}

// MARK: - Confirmation token capture

@Suite("Wallpaper confirmation")
struct WallpaperConfirmationTests {
    @Test("A captured confirmation still runs after the dialog clears presentation")
    @MainActor
    func capturedConfirmationRunsAfterDismissal() async throws {
        let integration = FakeAutomaticWallpaperIntegration()
        let defaults = try #require(UserDefaults(suiteName: "DaybreakConfirm-\(UUID().uuidString)"))
        let model = AppModel(defaults: defaults, wallpaper: integration)
        let imageURL = URL(fileURLWithPath: "/tmp/daybreak-archived.png")
        let confirmation = WallpaperConfirmation(
            action: .manualApply(imageURL: imageURL, displayID: nil),
            title: "更新当前桌面壁纸？",
            message: "仅修改当前可访问的桌面。",
            confirmLabel: "应用"
        )

        // Simulate SwiftUI setting isPresented to false before running the
        // button action: pending has already been cleared/dismissed.
        model.schedulePendingWallpaperConfirmationDismissal(id: nil)
        model.confirmWallpaperAction(confirmation)

        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline,
              integration.appliedManualURLs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(integration.appliedManualURLs == [imageURL])
        #expect(model.isApplyingWallpaper == false)
    }
}

// MARK: - Dock icon visibility

@Suite("Dock icon visibility")
struct DockIconVisibilityTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "DaybreakDockIcon-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("The Dock icon is visible when no choice was saved")
    func defaultsToVisible() throws {
        let defaults = try makeDefaults()

        #expect(DockIconVisibility.isEnabled(in: defaults))
    }

    @Test("Hiding and showing persist across model instances")
    @MainActor
    func choicePersists() throws {
        let defaults = try makeDefaults()
        let hidden = AppModel(
            defaults: defaults,
            wallpaper: FakeAutomaticWallpaperIntegration()
        )
        // The model reads the preference; the activation-policy side effect
        // belongs to the app process and is intentionally not exercised here.
        #expect(hidden.showsDockIcon)

        DockIconVisibility.store(false, in: defaults)
        let reloaded = AppModel(
            defaults: defaults,
            wallpaper: FakeAutomaticWallpaperIntegration()
        )
        #expect(!reloaded.showsDockIcon)

        DockIconVisibility.store(true, in: defaults)
        #expect(DockIconVisibility.isEnabled(in: defaults))
    }

    @Test("Visibility maps to the documented activation policies")
    func activationPolicyMapping() {
        #expect(
            DockIconVisibility.activationPolicy(showDockIcon: true) == .regular
        )
        #expect(
            DockIconVisibility.activationPolicy(showDockIcon: false) == .accessory
        )
    }
}

// MARK: - Dock toggle window preservation

@Suite("Activation policy window preservation")
struct MainWindowRestorationTests {
    @Test("A window the user could not see is never restored or created")
    func nonVisibleWindowStaysAsIs() {
        // Launch before the first window exists.
        #expect(
            MainWindowRestoration.selection(
                hadVisibleMainWindow: false,
                hasExistingMainWindow: false,
                canCreateWindow: true
            ) == .none
        )
        // Toggling while the window is minimized or hidden. SwiftUI may keep
        // the NSWindow around in an ordered-out state; it still must not be
        // brought back or duplicated.
        #expect(
            MainWindowRestoration.selection(
                hadVisibleMainWindow: false,
                hasExistingMainWindow: true,
                canCreateWindow: true
            ) == .none
        )
    }

    @Test("The visible window is reused instead of duplicated")
    func visibleWindowIsReused() {
        #expect(
            MainWindowRestoration.selection(
                hadVisibleMainWindow: true,
                hasExistingMainWindow: true,
                canCreateWindow: true
            ) == .existingWindow
        )
    }

    @Test("A visible window removed by the policy change is recreated")
    func missingVisibleWindowIsRecreated() {
        #expect(
            MainWindowRestoration.selection(
                hadVisibleMainWindow: true,
                hasExistingMainWindow: false,
                canCreateWindow: true
            ) == .newWindow
        )
    }

    @Test("Recreation is skipped when SwiftUI never registered openWindow")
    func recreationRequiresOpenWindowAction() {
        #expect(
            MainWindowRestoration.selection(
                hadVisibleMainWindow: true,
                hasExistingMainWindow: false,
                canCreateWindow: false
            ) == .none
        )
    }
}

// MARK: - Content request cancellation

/// Releases blocked test requests one at a time. A released request still
/// observes Swift concurrency cancellation inside the provider, exactly like
/// a slow URLSession response whose surrounding task was cancelled.
private actor RequestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var opened = false

    func arriveAndWait() async {
        arrivals += 1
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseNext() {
        if waiters.isEmpty {
            opened = true
        } else {
            waiters.removeFirst().resume()
        }
    }

    func releaseAll() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func arrivalCount() -> Int { arrivals }
}

/// Synthetic transport. Archive/story requests fail immediately unless a gate
/// is supplied; image requests return a real 1x1 PNG after an optional gate.
private struct GatedBingTransport: BingHTTPTransport {
    let archiveGate: RequestGate?
    let imageGate: RequestGate?
    let imageData: Data

    func perform(_ request: BingHTTPRequest) async throws -> BingHTTPResponse {
        if request.url.path.contains("HPImageArchive") {
            await archiveGate?.arriveAndWait()
            return BingHTTPResponse(
                data: Data(),
                statusCode: 503,
                headers: [:],
                finalURL: request.url
            )
        }
        if request.url.path.contains("hp/api/model") {
            return BingHTTPResponse(
                data: Data(),
                statusCode: 503,
                headers: [:],
                finalURL: request.url
            )
        }
        if request.url.host == "www.bing.com", request.url.path == "/th" {
            await imageGate?.arriveAndWait()
            return BingHTTPResponse(
                data: imageData,
                statusCode: 200,
                headers: ["Content-Type": "image/png"],
                finalURL: request.url
            )
        }
        return BingHTTPResponse(
            data: Data(),
            statusCode: 404,
            headers: [:],
            finalURL: request.url
        )
    }
}

/// Prevents the tests from touching the real UserNotifications center.
private final class DeniedNotificationSender: DailyWallpaperNotificationSending {
    func authorizationStatus() async -> DailyNotificationAuthorization { .denied }

    func requestAuthorization() async -> DailyWallpaperNotificationAuthorizationOutcome {
        .resolved(.denied, granted: false)
    }

    func deliver(
        _ notification: DailyWallpaperNotificationRequest,
        allowWhenAuthorizationStatusIsStale: Bool
    ) async -> DailyWallpaperNotificationDelivery {
        .notAuthorized
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("App model content request cancellation")
struct AppModelRequestCancellationTests {
    /// 2026-11-24 12:00 UTC, 20:00 in the zh-CN source time zone.
    private static let fixedNow = Date(timeIntervalSince1970: 1_795_521_600)
    private static let syntheticPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    private static let displayA = DesktopDisplayOption(
        id: DesktopDisplayID("display-a"),
        name: "Display A"
    )
    private static let displayB = DesktopDisplayOption(
        id: DesktopDisplayID("display-b"),
        name: "Display B"
    )

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suite = "DaybreakRequestCancellation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(
            "off",
            forKey: DailyWallpaperNotificationSettings.userChoiceKey
        )
        MarketSelection.explicit(.zhCN).store(in: defaults)
        return (suite, defaults)
    }

    @MainActor
    private func makeModel(
        defaults: UserDefaults,
        integration: FakeAutomaticWallpaperIntegration,
        service: TodayService
    ) -> AppModel {
        AppModel(
            defaults: defaults,
            wallpaper: integration,
            dailyNotifications: DailyNotificationController(
                defaults: defaults,
                sender: DeniedNotificationSender(),
                now: { Self.fixedNow }
            ),
            now: { Self.fixedNow },
            hostRegionIdentifier: "CN",
            preferredLanguageIdentifier: "zh-Hans-CN",
            repositoryDirectory: FileManager.default.temporaryDirectory,
            makeService: { _ in service }
        )
    }

    private func seed(
        service: TodayService,
        market: Market,
        day: LocalDate,
        imageID: String,
        storeOriginal: Bool = false
    ) async throws {
        let wallpaperID = WallpaperID(source: .bing, sourceImageID: imageID)
        let occurrence = WallpaperOccurrence(
            source: .bing,
            market: market,
            localDate: day,
            wallpaperID: wallpaperID
        )
        _ = try await service.repository.upsertOccurrences([occurrence])
        let metadata = WallpaperMetadataRecord(
            key: occurrence.id,
            wallpaperID: wallpaperID,
            title: "Synthetic \(imageID)",
            originalLocale: "zh-Hans",
            fetchedAt: Self.fixedNow,
            variants: [
                ImageVariantDescriptor(
                    wallpaperID: wallpaperID,
                    kind: .original,
                    remoteURL: URL(
                        string: "https://www.bing.com/th?id=synthetic-\(imageID)"
                    )!,
                    pixelWidth: 1_920,
                    pixelHeight: 1_080,
                    mimeType: "image/png"
                )
            ]
        )
        _ = try await service.repository.upsertMetadata([metadata])
        if storeOriginal,
           let png = Data(base64Encoded: Self.syntheticPNGBase64) {
            _ = try await service.repository.storeAsset(
                png,
                kind: .original,
                for: wallpaperID,
                fileExtension: "png"
            )
        }
    }

    private func makeService(
        directory: URL,
        transport: GatedBingTransport
    ) -> TodayService? {
        let provider = BingProvider(
            profile: .zhCN,
            configuration: BingProviderConfiguration(
                maximumAttempts: 1,
                initialRetryDelay: .zero,
                maximumRetryDelay: .zero
            ),
            transport: transport,
            now: { Self.fixedNow },
            sleep: { _ in }
        )
        return try? TodayService(
            directory: directory,
            now: { Self.fixedNow },
            providerFactory: { _ in provider }
        )
    }

    @MainActor
    private func disabledOutcome() -> WallpaperAutoOutcome {
        WallpaperAutoOutcome(
            enabled: false,
            message: "",
            blockedReason: nil,
            error: nil,
            requiresDisableRetry: false,
            targetUpdated: false
        )
    }

    @MainActor
    private func enabledOutcome() -> WallpaperAutoOutcome {
        WallpaperAutoOutcome(
            enabled: true,
            message: "",
            blockedReason: nil,
            error: nil,
            requiresDisableRetry: false,
            targetUpdated: true
        )
    }

    /// The synthetic archive always fails, so a started model settles with the
    /// cached payload in `.offline`. Waiting for that state also proves
    /// `prepareDisplays()` ran before a wallpaper action.
    @MainActor
    private func isSettledOffline(
        _ model: AppModel,
        market: Market
    ) -> Bool {
        guard model.payload?.market == market, !model.displays.isEmpty else {
            return false
        }
        if case .offline = model.loadState { return true }
        return false
    }

    @Test("A new display snapshot updates the app list and keeps a live selection")
    @MainActor
    func displaySnapshotRefreshPreservesSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakDisplayRefresh-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: nil,
            imageData: Data()
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = disabledOutcome()
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil {
            model.displays.map(\.id) == [Self.displayA.id]
        })
        #expect(model.selectedDisplayID == Self.displayA.id)

        integration.displays = [Self.displayA, Self.displayB]
        integration.onStatusChange?()
        #expect(await waitUntil {
            model.displays.map(\.id) == [Self.displayA.id, Self.displayB.id]
        })
        #expect(model.selectedDisplayID == Self.displayA.id)

        integration.displays = [Self.displayB]
        integration.onStatusChange?()
        #expect(await waitUntil {
            model.displays.map(\.id) == [Self.displayB.id]
        })
        #expect(model.selectedDisplayID == Self.displayB.id)
    }

    @Test("A superseded refresh cannot clear the newer request's loading state")
    @MainActor
    func supersededRefreshKeepsNewLoadingState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakRefreshCancellation-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let archiveGate = RequestGate()
        let transport = GatedBingTransport(
            archiveGate: archiveGate,
            imageGate: nil,
            imageData: Data()
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let today = try #require(
            LocalDate(
                date: Self.fixedNow,
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            )
        )
        try await seed(
            service: service,
            market: .zhCN,
            day: today,
            imageID: "cached-today"
        )

        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = disabledOutcome()
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil {
            model.payload != nil && model.isRefreshing
        })
        #expect(await waitUntil { await archiveGate.arrivalCount() >= 1 })

        model.refreshNow()
        #expect(await waitUntil { await archiveGate.arrivalCount() >= 2 })

        await archiveGate.releaseNext()
        try await Task.sleep(for: .milliseconds(150))

        // The first request was cancelled and must not overwrite the second
        // request's refreshed loading state or clear its progress flag.
        #expect(model.isRefreshing)
        #expect(model.loadState == .refreshing)

        await archiveGate.releaseNext()
        #expect(await waitUntil { !model.isRefreshing })
        if case .offline = model.loadState {
            // Expected: the synthetic archive intentionally fails.
        } else {
            Issue.record("The superseding refresh did not own the final state.")
        }
        #expect(model.payload != nil)
    }

    @Test("A→B→A cannot re-present a preflight cancelled by the region switch")
    @MainActor
    func regionSwitchBackDoesNotResurrectPreflight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakPreflightCancellation-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let imageGate = RequestGate()
        let png = try #require(Data(base64Encoded: Self.syntheticPNGBase64))
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: imageGate,
            imageData: png
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        let todayCN = try #require(LocalDate(date: Self.fixedNow, timeZone: shanghai))
        let todayTW = try #require(LocalDate(date: Self.fixedNow, timeZone: taipei))
        try await seed(
            service: service,
            market: .zhCN,
            day: todayCN,
            imageID: "region-a"
        )
        try await seed(
            service: service,
            market: Market("zh-TW"),
            day: todayTW,
            imageID: "region-b"
        )

        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = disabledOutcome()
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })

        model.beginAutoSync()
        #expect(await waitUntil {
            guard model.isPreparingConsent else { return false }
            return (await imageGate.arrivalCount()) >= 1
        })

        model.selectMarket(.explicit(Market("zh-TW")))
        #expect(await waitUntil { model.payload?.market == Market("zh-TW") })
        model.selectMarket(.explicit(.zhCN))
        #expect(await waitUntil { model.payload?.market == .zhCN })
        #expect(!model.isPreparingConsent)

        await imageGate.releaseNext()
        try await Task.sleep(for: .milliseconds(200))

        #expect(model.pendingWallpaperConfirmation == nil)
        #expect(!model.isPreparingConsent)
        #expect(model.wallpaperError == nil)

        // Cancellation must also release the preparation gate so the user can
        // start a fresh preflight for the current market.
        model.beginAutoSync()
        #expect(await waitUntil {
            guard model.isPreparingConsent else { return false }
            return (await imageGate.arrivalCount()) >= 2
        })
        model.cancelPendingWallpaperConfirmation()
        await imageGate.releaseAll()
        #expect(await waitUntil { !model.isPreparingConsent })
        #expect(model.pendingWallpaperConfirmation == nil)
    }

    @Test("A region switch resets an in-flight original download immediately")
    @MainActor
    func regionSwitchCancelsOriginalDownloadState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakOriginalCancellation-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let imageGate = RequestGate()
        let png = try #require(Data(base64Encoded: Self.syntheticPNGBase64))
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: imageGate,
            imageData: png
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        let todayCN = try #require(LocalDate(date: Self.fixedNow, timeZone: shanghai))
        let todayTW = try #require(LocalDate(date: Self.fixedNow, timeZone: taipei))
        try await seed(
            service: service,
            market: .zhCN,
            day: todayCN,
            imageID: "download-a"
        )
        try await seed(
            service: service,
            market: Market("zh-TW"),
            day: todayTW,
            imageID: "download-b"
        )

        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = disabledOutcome()
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })

        model.downloadOriginal()
        #expect(await waitUntil {
            guard model.isDownloadingOriginal else { return false }
            return (await imageGate.arrivalCount()) >= 1
        })

        model.selectMarket(.explicit(Market("zh-TW")))
        #expect(!model.isDownloadingOriginal)
        #expect(await waitUntil {
            model.payload?.market == Market("zh-TW")
        })

        await imageGate.releaseNext()
        try await Task.sleep(for: .milliseconds(150))

        #expect(!model.isDownloadingOriginal)
        #expect(model.wallpaperError == nil)
        #expect(model.payload?.market == Market("zh-TW"))
    }

    @Test("A market switch during an in-flight target write still runs the newest update")
    @MainActor
    func marketSwitchDuringTargetWriteRunsNewestUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakTargetSwitch-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let updateGate = RequestGate()
        let png = try #require(Data(base64Encoded: Self.syntheticPNGBase64))
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: nil,
            imageData: png
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        let todayCN = try #require(LocalDate(date: Self.fixedNow, timeZone: shanghai))
        let todayTW = try #require(LocalDate(date: Self.fixedNow, timeZone: taipei))
        try await seed(
            service: service,
            market: .zhCN,
            day: todayCN,
            imageID: "target-a"
        )
        try await seed(
            service: service,
            market: Market("zh-TW"),
            day: todayTW,
            imageID: "target-b"
        )

        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = enabledOutcome()
        integration.updateGate = updateGate
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })
        #expect(model.autoSyncEnabled)

        // The first market's original download reaches the target write and
        // suspends inside the integration.
        model.downloadOriginal()
        #expect(await waitUntil { await updateGate.arrivalCount() >= 1 })
        let staleURL = try #require(integration.updatedImageURLs.first)

        model.selectMarket(.explicit(Market("zh-TW")))
        #expect(await waitUntil { model.payload?.market == Market("zh-TW") })

        // The new market's update request arrives while the stale write is
        // still in flight. It must be parked, not dropped by the guard.
        model.downloadOriginal()
        #expect(await waitUntil {
            !model.isDownloadingOriginal && model.payload?.originalURL != nil
        })
        #expect(integration.updatedImageURLs == [staleURL])

        await updateGate.releaseAll()
        #expect(await waitUntil {
            integration.updatedImageURLs.count == 2
        })
        let currentURL = try #require(integration.updatedImageURLs.last)
        #expect(currentURL != staleURL)
        // Only the newest payload may be reconciled; the stale write must not
        // produce a confirmation or notification.
        #expect(await waitUntil {
            integration.reconciliationImageURLs == [currentURL]
        })
        #expect(model.autoSyncEnabled)
        #expect(model.wallpaperError == nil)
    }

    @Test("Startup shows a non-error legacy target message")
    @MainActor
    func startupShowsNonErrorLegacyTargetMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakLegacyTargetMessage-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: nil,
            imageData: Data()
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let legacyMessage = "2 台显示器使用迁移前的目标，自动同步不会更新它们；如需纳入，请关闭后重新开启自动同步。"
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = WallpaperAutoOutcome(
            enabled: true,
            automaticOverwriteEnabled: false,
            message: legacyMessage,
            blockedReason: nil,
            error: nil,
            requiresDisableRetry: false,
            targetUpdated: false
        )
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil {
            model.wallpaperStatusMessage == legacyMessage
        })
        #expect(model.autoSyncEnabled)
        #expect(model.wallpaperError == nil)
        #expect(await waitUntil { model.displays == [Self.displayA] })
    }

    @Test("Startup does not publish an empty automation message")
    @MainActor
    func startupIgnoresEmptyAutomationMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakEmptyAutomationMessage-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: nil,
            imageData: Data()
        )
        let service = try #require(makeService(directory: directory, transport: transport))
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = WallpaperAutoOutcome(
            enabled: true,
            automaticOverwriteEnabled: false,
            message: "",
            blockedReason: nil,
            error: nil,
            requiresDisableRetry: false,
            targetUpdated: false
        )
        integration.displays = [Self.displayA]
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )

        model.start()
        #expect(await waitUntil { model.displays == [Self.displayA] })
        #expect(model.autoSyncEnabled)
        #expect(model.wallpaperStatusMessage == nil)
        #expect(model.wallpaperError == nil)
    }

    // MARK: Auto target topology adoption

    @MainActor
    private func makeTopologyModel(
        directory: URL,
        defaults: UserDefaults,
        integration: FakeAutomaticWallpaperIntegration,
        imageID: String,
        storeOriginal: Bool,
        sourceDate: LocalDate? = nil
    ) async throws -> (AppModel, URL) {
        let transport = GatedBingTransport(
            archiveGate: nil,
            imageGate: nil,
            imageData: try #require(
                Data(base64Encoded: Self.syntheticPNGBase64)
            )
        )
        let service = try #require(
            makeService(directory: directory, transport: transport)
        )
        let today = try #require(
            LocalDate(
                date: Self.fixedNow,
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            )
        )
        try await seed(
            service: service,
            market: .zhCN,
            day: sourceDate ?? today,
            imageID: imageID,
            storeOriginal: storeOriginal
        )
        let model = makeModel(
            defaults: defaults,
            integration: integration,
            service: service
        )
        let originalURL = URL(
            string: "https://www.bing.com/th?id=synthetic-\(imageID)"
        )!
        return (model, originalURL)
    }

    @Test("A newly connected display adopts the current auto target once")
    @MainActor
    func newDisplayAdoptsCurrentAutoTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakTopologyAdoption-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = enabledOutcome()
        integration.displays = [Self.displayA]
        integration.adoptionCandidateDisplayIDs = [Self.displayB.id]
        integration.adoptionOutcome = enabledOutcome()
        let (model, originalURL) = try await makeTopologyModel(
            directory: directory,
            defaults: defaults,
            integration: integration,
            imageID: "topology",
            storeOriginal: true
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })
        #expect(model.selectedDisplayID == Self.displayA.id)

        integration.displays = [Self.displayA, Self.displayB]
        integration.onStatusChange?()
        #expect(await waitUntil {
            model.displays.map(\.id) == [Self.displayA.id, Self.displayB.id]
        })
        #expect(await waitUntil {
            integration.reconciliationRequests == 1
                && integration.reconciliationImageURLs == [originalURL]
        })
        #expect(model.selectedDisplayID == Self.displayA.id)
        #expect(model.wallpaperError == nil)

        // Another snapshot callback must not add a second reconciliation for
        // the already adopted display.
        integration.onStatusChange?()
        try await Task.sleep(for: .milliseconds(150))
        #expect(integration.reconciliationRequests == 1)
    }

    @Test("Topology adoption is inert while automatic sync is off")
    @MainActor
    func topologyAdoptionRequiresEnabledAutoSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakTopologyDisabled-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = disabledOutcome()
        integration.displays = [Self.displayA]
        integration.adoptionCandidateDisplayIDs = [Self.displayB.id]
        let (model, _) = try await makeTopologyModel(
            directory: directory,
            defaults: defaults,
            integration: integration,
            imageID: "topology-disabled",
            storeOriginal: true
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })
        integration.displays = [Self.displayA, Self.displayB]
        integration.onStatusChange?()
        #expect(await waitUntil { model.displays.count == 2 })
        try await Task.sleep(for: .milliseconds(150))

        #expect(integration.adoptionImageURLs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
    }

    @Test("A payload without an original cannot adopt a target for a new display")
    @MainActor
    func topologyAdoptionRequiresOriginalImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakTopologyNoOriginal-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = enabledOutcome()
        integration.displays = [Self.displayA]
        integration.adoptionCandidateDisplayIDs = [Self.displayB.id]
        integration.adoptionOutcome = enabledOutcome()
        let (model, _) = try await makeTopologyModel(
            directory: directory,
            defaults: defaults,
            integration: integration,
            imageID: "topology-no-original",
            storeOriginal: false
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })
        integration.displays = [Self.displayA, Self.displayB]
        integration.onStatusChange?()
        #expect(await waitUntil { model.displays.count == 2 })
        try await Task.sleep(for: .milliseconds(150))

        #expect(integration.adoptionImageURLs.isEmpty)
    }

    @Test("A stale cached payload cannot adopt a target for a new display")
    @MainActor
    func topologyAdoptionRejectsStaleCachedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DaybreakTopologyStalePayload-\(UUID().uuidString)",
                isDirectory: true
            )
        let (suiteName, defaults) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let today = try #require(
            LocalDate(
                date: Self.fixedNow,
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            )
        )
        let yesterday = try #require(today.previousDay)
        let integration = FakeAutomaticWallpaperIntegration()
        integration.outcome = enabledOutcome()
        integration.displays = [Self.displayA]
        integration.adoptionCandidateDisplayIDs = [Self.displayB.id]
        integration.adoptionOutcome = enabledOutcome()
        let (model, _) = try await makeTopologyModel(
            directory: directory,
            defaults: defaults,
            integration: integration,
            imageID: "topology-stale-payload",
            storeOriginal: true,
            sourceDate: yesterday
        )

        model.start()
        #expect(await waitUntil {
            isSettledOffline(model, market: .zhCN)
        })
        #expect(model.payload?.isSourceDateToday == false)

        integration.displays = [Self.displayA, Self.displayB]
        integration.onStatusChange?()
        #expect(await waitUntil { model.displays.count == 2 })
        try await Task.sleep(for: .milliseconds(150))

        #expect(integration.adoptionImageURLs.isEmpty)
        #expect(integration.reconciliationRequests == 0)
    }
}

// MARK: - Auto target topology planning

@Suite("Auto target topology planning")
struct WallpaperAutoTargetTopologyTests {
    private let displayA = DesktopDisplayID("display-a")
    private let displayB = DesktopDisplayID("display-b")
    private let displayC = DesktopDisplayID("display-c")

    @Test("Only displays without an assignment need the current target")
    func onlyUnassignedDisplaysNeedTarget() {
        let needed = WallpaperAutoTargetTopology.displayIDsNeedingTarget(
            connectedDisplayIDs: [displayA, displayB, displayC],
            assignedDisplayIDs: [displayA, displayB],
            manuallyProtectedDisplayIDs: []
        )

        #expect(needed == [displayC])
    }

    @Test("An existing historical wallpaper assignment is preserved")
    func existingAssignmentIsNeverReplaced() {
        let needed = WallpaperAutoTargetTopology.displayIDsNeedingTarget(
            connectedDisplayIDs: [displayA],
            assignedDisplayIDs: [displayA],
            manuallyProtectedDisplayIDs: []
        )

        #expect(needed.isEmpty)
    }

    @Test("Manually protected displays are never re-targeted implicitly")
    func protectedDisplaysAreSkipped() {
        let needed = WallpaperAutoTargetTopology.displayIDsNeedingTarget(
            connectedDisplayIDs: [displayA, displayB],
            assignedDisplayIDs: [],
            manuallyProtectedDisplayIDs: [displayA]
        )

        #expect(needed == [displayB])
    }

    @Test("An already complete assignment set is a no-op")
    func completeAssignmentsAreIdempotent() {
        let needed = WallpaperAutoTargetTopology.displayIDsNeedingTarget(
            connectedDisplayIDs: [displayA, displayB],
            assignedDisplayIDs: [displayA, displayB],
            manuallyProtectedDisplayIDs: []
        )

        #expect(needed.isEmpty)
    }

    @Test("Duplicate display observations produce one assignment")
    func duplicateDisplayIdentityIsDeduplicated() {
        let needed = WallpaperAutoTargetTopology.displayIDsNeedingTarget(
            connectedDisplayIDs: [displayA, displayA, displayB],
            assignedDisplayIDs: [],
            manuallyProtectedDisplayIDs: []
        )

        #expect(needed == [displayA, displayB])
    }
}
