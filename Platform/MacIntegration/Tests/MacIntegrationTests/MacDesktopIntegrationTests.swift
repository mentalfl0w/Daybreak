import DaybreakCore
import Foundation
import Testing
@testable import MacIntegration

@Suite("MacDesktopIntegration")
@MainActor
struct MacDesktopIntegrationTests {
    private let displayA = TestFixtures.displayA
    private let displayB = TestFixtures.displayB
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeIntegration(
        directory: URL,
        system: FakeWallpaperSystem,
        observer: FakeEventObserver,
        pointerObserver: FakePointerObserver? = nil,
        eventDebounce: Duration = .zero,
        protection: (any WallpaperApplicationProtecting)? = nil
    ) -> MacDesktopIntegration {
        let fixed = fixedNow
        return MacDesktopIntegration(
            settingsDirectory: directory,
            system: system,
            eventObserver: observer,
            pointerObserver: pointerObserver ?? FakePointerObserver(),
            eventDebounce: eventDebounce,
            wallpaperProtection: protection ?? PermissiveWallpaperProtection(),
            now: { fixed }
        )
    }

    private func consent(
        for preflight: MacWallpaperWritePreflight
    ) -> MacWallpaperWriteConsent {
        MacWallpaperWriteConsent(preflight: preflight)
    }

    @Test("Start is read-only and manual apply writes only after consent")
    func manualApply() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("manual")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: external)
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(directory: directory, system: system, observer: observer)
        await integration.start()

        #expect(integration.snapshot.automationMode == .readOnly)
        #expect(integration.snapshot.writeAccess == .readOnly)
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        let preflight = try await integration.prepareWallpaperWrite()
        #expect(preflight.observation.displays.count == 1)

        let target = DesktopWallpaper(imageURL: image, scaling: .fill)
        let report = try await integration.applyOnce([displayA: target], consent: consent(for: preflight))
        #expect(report.blocked.isEmpty)

        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.displayID == displayA)
        #expect(calls.first?.url == image)
        #expect(calls.first?.options.scaling == .fill)
        #expect(integration.snapshot.writeAccess == .readOnly)
        #expect(integration.snapshot.assignments.map(\.displayID) == [displayA])
        #expect(integration.snapshot.coordinatorState?.displayState(for: displayA)?.status == .synchronized)
    }

    @Test("Manual apply rejects displays that are not connected")
    func unknownDisplay() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("manual"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()

        do {
            _ = try await integration.applyOnce(
                [displayB: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected unknown display")
        } catch let error as MacDesktopApplyError {
            #expect(error == .unknownDisplay(displayB))
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Enabling automation performs no write and does not approve unknown wallpapers")
    func automationDoesNotAuthorizeUnknownWallpaper() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("user")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: external)
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(directory: directory, system: system, observer: observer)
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()

        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        #expect(integration.snapshot.automationMode == .automatic)
        #expect(integration.snapshot.writeAccess == .authorized)
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])
        calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains { $0.displayID == displayA }
        }
        calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        #expect(
            integration.snapshot.guardBlocks.first?.reason
                == .unverifiedExternalWallpaper
        )
        #expect(
            integration.snapshot.coordinatorState?.displayState(for: displayA)?.status
                == .manualProtection
        )

        guard let block = integration.snapshot.guardBlocks.first else {
            Issue.record("Missing guard block")
            return
        }

        // A stale confirmation must not overwrite a newer wallpaper.
        await system.setCurrentImageURL(TestFixtures.externalURL("newer"), for: displayA)
        do {
            _ = try await integration.confirmOverwrite(block.confirmationRequest)
            Issue.record("Expected a stale-request rejection")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }
        calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        await system.setCurrentImageURL(external, for: displayA)
        _ = try await integration.confirmOverwrite(block.confirmationRequest)
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(integration.snapshot.guardBlocks.isEmpty)
    }

    @Test("Automation mode and managed ledger survive a restart")
    func restartUsesPersistedLedger() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let firstImage = try TestFixtures.writeImage(in: directory, named: "first.png")
        let secondImage = try TestFixtures.writeImage(in: directory, named: "second.png")
        let external = TestFixtures.externalURL("user")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: external)
            ]
        )
        let firstObserver = FakeEventObserver()
        let first = makeIntegration(directory: directory, system: system, observer: firstObserver)
        await first.start()
        let firstPreflight = try await first.prepareWallpaperWrite()
        _ = try await first.applyOnce(
            [displayA: DesktopWallpaper(imageURL: firstImage, scaling: .fill)],
            consent: consent(for: firstPreflight)
        )
        try await first.setAutomationEnabled(true, consent: consent(for: firstPreflight))
        try await first.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: secondImage, scaling: .fill)
        ])
        first.stop()

        let secondObserver = FakeEventObserver()
        let second = makeIntegration(directory: directory, system: system, observer: secondObserver)
        await second.start()
        #expect(second.snapshot.automationMode == .automatic)
        var calls = await system.appliedCalls()
        #expect(calls.count == 1)

        secondObserver.send(.activeSpaceDidChange)
        await waitUntil {
            let snapshot = second.snapshot
            return snapshot.coordinatorState?.displayState(for: self.displayA)?.status == .synchronized
        }
        calls = await system.appliedCalls()
        #expect(calls.count == 2)
        #expect(calls.last?.url == secondImage)

        // A later Space with an unknown wallpaper must pause, not be replaced.
        await system.setCurrentImageURL(TestFixtures.externalURL("other-space"), for: displayA)
        secondObserver.send(.activeSpaceDidChange)
        await waitUntil {
            second.snapshot.guardBlocks.contains { $0.displayID == self.displayA }
        }
        calls = await system.appliedCalls()
        #expect(calls.count == 2)
        #expect(
            second.snapshot.guardBlocks.first?.reason
                == .unverifiedExternalWallpaper
        )
        second.stop()
    }

    @Test("Read-only events refresh status without writing")
    func readOnlyEventDoesNotWrite() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("first"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(directory: directory, system: system, observer: observer)
        await integration.start()
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image)
        ])

        let newer = TestFixtures.externalURL("second")
        await system.setCurrentImageURL(newer, for: displayA)
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.displays.first?.currentImageURL == newer
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        #expect(integration.snapshot.writeAccess == .readOnly)
    }

    @Test("Manual protection pauses automation and can be cleared explicitly")
    func manualProtection() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("protected")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: external)
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(directory: directory, system: system, observer: observer)
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image)
        ])
        try await integration.protectCurrentWallpaper(for: displayA)

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.displayID == self.displayA && $0.reason == .manualProtection
            }
        }
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        let report = try await integration.clearManualProtection(for: displayA)
        #expect(report != nil)
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(integration.snapshot.manualProtections.isEmpty)
        #expect(integration.snapshot.guardBlocks.isEmpty)
    }

    @Test("A preflight records only the currently accessible desktop observation")
    func preflightObservation() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil)
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        let preflight = try await integration.prepareWallpaperWrite()
        #expect(preflight.observation.displays.map(\.displayID) == [displayA])
        #expect(preflight.observation.displays.first?.imageURL == nil)
    }

    @Test("Corrupt settings fall back to read-only without writing")
    func corruptSettings() async throws {
        let directory = TestFixtures.temporaryDirectory()
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(MacDesktopSettingsStore.fileName)
        )
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        #expect(integration.snapshot.automationMode == .readOnly)
        #expect(integration.snapshot.writeAccess == .readOnly)
        #expect(integration.snapshot.lastError != nil)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Legacy backup fields in settings are ignored, not restored")
    func legacyBackupFieldsAreIgnored() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let legacy = """
        {
          "schemaVersion": 2,
          "automationMode": "readOnly",
          "automaticOverwriteEnabled": false,
          "assignments": [],
          "managedImageURLs": [],
          "manualProtections": [],
          "backup": {"capturedAt": 0, "displays": []},
          "restorePoint": {"capturedAt": 0, "displays": []}
        }
        """
        try Data(legacy.utf8).write(
            to: directory.appendingPathComponent(MacDesktopSettingsStore.fileName)
        )
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        #expect(integration.snapshot.automationMode == .readOnly)
        #expect(integration.snapshot.assignments.isEmpty)
        #expect(integration.snapshot.manualProtections.isEmpty)
        #expect(integration.snapshot.pendingPreflight == nil)
        #expect(integration.snapshot.lastIssue == nil)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Desired assignments persist across a restart without writing")
    func desiredAssignmentsPersist() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let first = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await first.start()
        try await first.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fit)
        ])
        first.stop()

        let second = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await second.start()
        #expect(second.snapshot.assignments.count == 1)
        #expect(second.snapshot.assignments.first?.displayID == displayA)
        #expect(second.snapshot.assignments.first?.wallpaper.imageURL == image)
        #expect(second.snapshot.assignments.first?.wallpaper.scaling == .fit)
        #expect(second.snapshot.assignments.first?.source == .automatic)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        second.stop()
    }

    @Test("Automatic target update retargets a disconnected automatic assignment")
    func automaticTargetUpdateRetargetsDisconnectedDisplay() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let oldImage = try TestFixtures.writeImage(in: directory, named: "old.png")
        let newImage = try TestFixtures.writeImage(in: directory, named: "new.png")
        let oldWallpaper = DesktopWallpaper(imageURL: oldImage, scaling: .fill)
        let newWallpaper = DesktopWallpaper(imageURL: newImage, scaling: .fill)
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: oldImage),
                TestFixtures.screenshot(displayB, imageURL: oldImage)
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(
            true,
            consent: consent(for: preflight)
        )
        try await integration.setAutomaticOverwriteEnabled(true)
        try await integration.setDesiredAssignments([
            displayA: oldWallpaper,
            displayB: oldWallpaper
        ])
        #expect(
            integration.snapshot.assignments
                .allSatisfy { $0.source == .automatic }
        )
        #expect(integration.snapshot.legacyAssignmentDisplayIDs.isEmpty)

        // Display B disappears while the automatic target is still the old
        // image. The target update must still reach its persisted assignment.
        await system.setScreens([
            TestFixtures.screenshot(displayA, imageURL: oldImage)
        ])
        observer.send(.screenParametersChanged)
        await waitUntil {
            integration.snapshot.displays.map(\.displayID) == [self.displayA]
        }

        try await integration.setAutomaticTarget(
            newWallpaper,
            connectedDisplayIDs: [displayA]
        )
        #expect(
            integration.snapshot.assignments
                .allSatisfy {
                    $0.source == .automatic && $0.wallpaper == newWallpaper
                }
        )
        #expect(
            integration.snapshot.assignments
                .first(where: { $0.displayID == displayB })?
                .wallpaper == newWallpaper
        )
        // Persisting intent must never write by itself.
        let callsAfterUpdate = await system.appliedCalls()
        #expect(callsAfterUpdate.isEmpty)

        // Reconnect B while the old automatic image is still visible. The
        // coordinator must apply the new target instead of treating the stale
        // assignment as current.
        await system.setScreens([
            TestFixtures.screenshot(displayA, imageURL: oldImage),
            TestFixtures.screenshot(displayB, imageURL: oldImage)
        ])
        observer.send(.screenParametersChanged)
        await waitUntil {
            integration.snapshot.appliedWallpaperURLsByDisplay[self.displayB] == newImage
        }

        let calls = await system.appliedCalls()
        #expect(
            calls.contains {
                $0.displayID == self.displayB && $0.url == newImage
            }
        )
        #expect(
            !calls.contains {
                $0.displayID == self.displayB && $0.url == oldImage
            }
        )
    }

    @Test("Automatic target update preserves a manual assignment")
    func automaticTargetUpdatePreservesManualAssignment() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let manualImage = try TestFixtures.writeImage(in: directory, named: "manual.png")
        let automaticOld = try TestFixtures.writeImage(in: directory, named: "auto-old.png")
        let automaticNew = try TestFixtures.writeImage(in: directory, named: "auto-new.png")
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

        // A was written by an explicit user action; B carries only an
        // automatic target.
        let preflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: manualImage, scaling: .fit)],
            consent: consent(for: preflight)
        )
        try await integration.protectCurrentWallpaper(for: displayA)
        try await integration.setDesiredAssignments([
            displayB: DesktopWallpaper(imageURL: automaticOld, scaling: .fill)
        ])
        #expect(
            integration.snapshot.assignments
                .first(where: { $0.displayID == displayA })?
                .source == .manual
        )

        let writesBefore = await system.appliedCalls().count
        try await integration.setAutomaticTarget(
            DesktopWallpaper(imageURL: automaticNew, scaling: .fill),
            connectedDisplayIDs: [displayA, displayB]
        )

        let assignmentA = integration.snapshot.assignments
            .first(where: { $0.displayID == displayA })
        #expect(assignmentA?.source == .manual)
        #expect(assignmentA?.wallpaper.imageURL == manualImage)
        #expect(assignmentA?.wallpaper.scaling == .fit)
        #expect(integration.snapshot.legacyAssignmentDisplayIDs.isEmpty)
        let assignmentB = integration.snapshot.assignments
            .first(where: { $0.displayID == displayB })
        #expect(assignmentB?.source == .automatic)
        #expect(assignmentB?.wallpaper.imageURL == automaticNew)
        #expect(integration.snapshot.manualProtections.map(\.displayID) == [displayA])
        let callsAfterPreservation = await system.appliedCalls()
        #expect(callsAfterPreservation.count == writesBefore)
    }

    @Test("A schema 2 manual target stays unknown even with ledger evidence")
    func legacyManualAssignmentIsNeverAutoAdopted() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let legacyImage = try TestFixtures.writeImage(in: directory, named: "legacy-manual.png")
        let newImage = try TestFixtures.writeImage(in: directory, named: "new.png")
        // Simulate a pre-schema-3 manual apply: the wallpaper is recorded in
        // both the per-display applied map and the global managed ledger.
        let legacy = """
        {
          "schemaVersion": 2,
          "automationMode": "automatic",
          "automaticOverwriteEnabled": true,
          "assignments": [
            {
              "displayID": "test-display-a",
              "wallpaper": {
                "imageURL": "\(legacyImage.absoluteString)",
                "scaling": "fit"
              },
              "source": "automatic"
            }
          ],
          "managedImageURLs": ["\(legacyImage.absoluteString)"],
          "appliedImageURLsByDisplay": {
            "test-display-a": "\(legacyImage.absoluteString)"
          },
          "manualProtections": []
        }
        """
        try Data(legacy.utf8).write(
            to: directory.appendingPathComponent(MacDesktopSettingsStore.fileName)
        )
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: legacyImage)
            ]
        )
        let first = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await first.start()

        let migrated = first.snapshot.assignments
            .first(where: { $0.displayID == displayA })
        // The legacy file deliberately injects `"source": "automatic"`.
        // Pre-schema-3 data must ignore it and load conservatively.
        #expect(migrated?.source == .unknown)
        #expect(migrated?.wallpaper.imageURL == legacyImage)
        #expect(migrated?.wallpaper.scaling == .fit)
        #expect(first.snapshot.legacyAssignmentDisplayIDs == [displayA])

        // Ledger evidence MUST NOT turn an unknown manual target into an
        // automatic one, even while automatic mode and overwrite are enabled.
        try await first.setAutomaticTarget(
            DesktopWallpaper(imageURL: newImage, scaling: .fill),
            connectedDisplayIDs: [displayA]
        )
        #expect(first.snapshot.legacyAssignmentDisplayIDs == [displayA])
        let preserved = first.snapshot.assignments
            .first(where: { $0.displayID == displayA })
        #expect(preserved?.source == .unknown)
        #expect(preserved?.wallpaper.imageURL == legacyImage)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        // Saving after migration records provenance explicitly and keeps the
        // assignment; it does not silently delete old user data.
        let data = try Data(
            contentsOf: directory.appendingPathComponent(MacDesktopSettingsStore.fileName)
        )
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected settings JSON object")
            return
        }
        let savedSchemaVersion = raw["schemaVersion"] as? Int
        #expect(savedSchemaVersion == MacDesktopSettings.currentSchemaVersion)
        let rawAssignments = raw["assignments"] as? [[String: Any]]
        #expect(rawAssignments?.count == 1)
        let savedSource = rawAssignments?.first?["source"] as? String
        #expect(savedSource == "unknown")
        first.stop()

        let second = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await second.start()
        #expect(second.snapshot.assignments.count == 1)
        #expect(second.snapshot.assignments.first?.source == .unknown)
        #expect(second.snapshot.assignments.first?.wallpaper.imageURL == legacyImage)
        second.stop()
    }

    @Test("Two displays receive independent targets")
    func multiDisplayApply() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let imageA = try TestFixtures.writeImage(in: directory, named: "a.png")
        let imageB = try TestFixtures.writeImage(in: directory, named: "b.png")
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
        let preflight = try await integration.prepareWallpaperWrite()
        let report = try await integration.applyOnce(
            [
                displayA: DesktopWallpaper(imageURL: imageA, scaling: .fill),
                displayB: DesktopWallpaper(imageURL: imageB, scaling: .fit)
            ],
            consent: consent(for: preflight)
        )
        #expect(report.blocked.isEmpty)

        let calls = await system.appliedCalls()
        #expect(calls.count == 2)
        let byDisplay = Dictionary(
            uniqueKeysWithValues: calls.map { ($0.displayID, $0) }
        )
        #expect(byDisplay[displayA]?.url == imageA)
        #expect(byDisplay[displayA]?.options.scaling == .fill)
        #expect(byDisplay[displayB]?.url == imageB)
        #expect(byDisplay[displayB]?.options.scaling == .fit)
        #expect(integration.snapshot.assignments.count == 2)
        #expect(integration.snapshot.coordinatorState?.displays.count == 2)
    }

    @Test("Manual apply never pauses on a display outside its scope")
    func manualApplyDoesNotGuardNonTargetDisplay() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let imageA = try TestFixtures.writeImage(in: directory, named: "a.png")
        let imageB = try TestFixtures.writeImage(in: directory, named: "b.png")
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
        // A retained automatic target for display B exists, but the user only
        // asked to write display A.
        try await integration.setDesiredAssignments([
            displayB: DesktopWallpaper(imageURL: imageB, scaling: .fill)
        ])

        let preflight = try await integration.prepareWallpaperWrite()
        let report = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: imageA, scaling: .fill)],
            consent: consent(for: preflight)
        )

        #expect(report.blocked.isEmpty)
        #expect(integration.snapshot.guardBlocks.isEmpty)
        let calls = await system.appliedCalls()
        #expect(calls.map(\.displayID) == [displayA])
        #expect(
            integration.snapshot.assignments
                .first(where: { $0.displayID == displayB })?
                .wallpaper.imageURL == imageB
        )
    }

    @Test("A scoped manual apply keeps another display's pause visible")
    func manualApplyKeepsOtherDisplayGuard() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let imageA = try TestFixtures.writeImage(in: directory, named: "a.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a")),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            eventDebounce: .zero
        )
        await integration.start()
        let enablePreflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(
            true,
            consent: consent(for: enablePreflight)
        )
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: imageA, scaling: .fill),
            displayB: DesktopWallpaper(imageURL: imageA, scaling: .fill)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil { integration.snapshot.guardBlocks.count == 2 }

        let applyPreflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: imageA, scaling: .fill)],
            consent: consent(for: applyPreflight)
        )

        let calls = await system.appliedCalls()
        #expect(calls.map(\.displayID) == [displayA])
        #expect(integration.snapshot.guardBlocks.map(\.displayID) == [displayB])
    }

    @Test("Space switch keeps the guard confirmable for the visible wallpaper")
    func guardTracksAccessibleSpaceWallpaper() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let firstSpaceWallpaper = TestFixtures.externalURL("space-one")
        let secondSpaceWallpaper = TestFixtures.externalURL("space-two")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: firstSpaceWallpaper)
            ]
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
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks
                .first(where: { $0.displayID == self.displayA })?
                .observedImageURL == firstSpaceWallpaper
        }
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        // Another Space legitimately shows a different wallpaper. Protection
        // must follow the visible observation, not stay pinned to the old one.
        await system.setCurrentImageURL(secondSpaceWallpaper, for: displayA)
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks
                .first(where: { $0.displayID == self.displayA })?
                .observedImageURL == secondSpaceWallpaper
        }

        guard let block = integration.snapshot.guardBlocks.first(where: {
            $0.displayID == displayA
        }) else {
            Issue.record("Missing guard block for the current Space wallpaper")
            return
        }
        let report = try await integration.confirmOverwrite(block.confirmationRequest)
        #expect(report.blocked.isEmpty)
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(integration.snapshot.guardBlocks.isEmpty)
        #expect(
            integration.snapshot.coordinatorState?.displayState(for: displayA)?.status
                == .synchronized
        )
    }

    @Test("Disconnected displays are not listed as awaiting confirmation")
    func disconnectedDisplayGuardIsHidden() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a")),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
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
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill),
            displayB: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil { integration.snapshot.guardBlocks.count == 2 }
        #expect(integration.snapshot.guardBlocks.map(\.displayID) == [displayA, displayB])

        await system.setScreens([
            TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a"))
        ])
        observer.send(.screenParametersChanged)
        await waitUntil { integration.snapshot.displays.count == 1 }

        #expect(integration.snapshot.guardBlocks.map(\.displayID) == [displayA])
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("A newly connected display appears after a screen-parameter event")
    func connectedDisplayAppearsAfterScreenParametersEvent() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let first = TestFixtures.externalURL("a")
        let second = TestFixtures.externalURL("b")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: first)]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            eventDebounce: .zero
        )
        await integration.start()
        #expect(integration.snapshot.displays.map(\.displayID) == [displayA])

        await system.setScreens([
            TestFixtures.screenshot(displayA, imageURL: first),
            TestFixtures.screenshot(displayB, imageURL: second)
        ])
        observer.send(.screenParametersChanged)
        await waitUntil { integration.snapshot.displays.count == 2 }

        #expect(integration.snapshot.displays.map(\.displayID) == [displayA, displayB])
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Stopping cancels a pending debounced reconciliation")
    func stopCancelsPendingEvent() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            eventDebounce: .milliseconds(80)
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image)
        ])

        observer.send(.activeSpaceDidChange)
        integration.stop()
        try await Task.sleep(for: .milliseconds(150))

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Disabling automation fails closed when settings cannot be persisted")
    func disableFailsClosed() async throws {
        let root = TestFixtures.temporaryDirectory()
        let settingsDirectory = root.appendingPathComponent("Settings", isDirectory: true)
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let integration = makeIntegration(
            directory: settingsDirectory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        #expect(integration.snapshot.automationMode == .automatic)
        #expect(integration.snapshot.writeAccess == .authorized)

        // Replace the settings directory with a regular file so every
        // subsequent save fails deterministically.
        try FileManager.default.removeItem(at: settingsDirectory)
        try Data("not a directory".utf8).write(to: settingsDirectory)
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }

        do {
            try await integration.setAutomationEnabled(false, consent: nil)
            Issue.record("Expected the disable to surface a persistence failure")
        } catch let error as MacDesktopApplyError {
            guard case .persistenceFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(integration.snapshot.automationMode == .readOnly)
        #expect(integration.snapshot.writeAccess == .readOnly)
        #expect(integration.snapshot.lastError != nil)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("A Space event invalidates a prepared preflight")
    func spaceEventInvalidatesPreflight() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.pendingPreflight == nil
        }

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected the invalidated preflight to be rejected")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightExpired)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Changing the current wallpaper after preflight is rejected")
    func changedWallpaperInvalidatesPreflight() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("before"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        await system.setCurrentImageURL(TestFixtures.externalURL("after"), for: displayA)

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected a preflight mismatch")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }

        #expect(integration.snapshot.pendingPreflight == nil)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Changing desktop options after preflight is rejected")
    func changedOptionsInvalidatePreflight() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("same-image")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: external)
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        await system.setScreens([
            TestFixtures.screenshot(
                displayA,
                imageURL: external,
                options: MacWallpaperOptions(
                    imageScalingRawValue: 1,
                    allowsClipping: false
                )
            )
        ])

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected changed options to invalidate the preflight")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("An unreadable current wallpaper does not block an explicit manual apply")
    func nilWallpaperExplicitApplyWrites() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil)
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        #expect(preflight.observation.displays.first?.imageURL == nil)

        let report = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: image, scaling: .fill)],
            consent: consent(for: preflight)
        )
        #expect(report.blocked.isEmpty)

        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(calls.first?.options.scaling == .fill)
        #expect(integration.snapshot.appliedWallpaperURLsByDisplay[displayA] == image)
    }

    @Test("A Space event still invalidates a preflight that observed no image URL")
    func nilWallpaperSpaceEventInvalidatesPreflight() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil)
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()

        observer.send(.activeSpaceDidChange)
        await waitUntil { integration.snapshot.pendingPreflight == nil }

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected the invalidated preflight to be rejected")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightExpired)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Changed desktop options still reject a preflight with no image URL")
    func nilWallpaperChangedOptionsRejected() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil)
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        await system.setScreens([
            TestFixtures.screenshot(
                displayA,
                imageURL: nil,
                options: MacWallpaperOptions(
                    imageScalingRawValue: 1,
                    allowsClipping: false
                )
            )
        ])

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected changed options to invalidate the preflight")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("A disconnected display is still rejected when its wallpaper is unreadable")
    func nilWallpaperDisconnectedDisplayRejected() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil)
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        await system.setScreens([])

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected the missing display to be rejected")
        } catch let error as MacDesktopApplyError {
            #expect(error == .unknownDisplay(displayA))
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("An unreadable display does not block a manual apply to another display")
    func nilWallpaperDoesNotBlockOtherDisplay() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let imageA = try TestFixtures.writeImage(in: directory, named: "a.png")
        let imageB = try TestFixtures.writeImage(in: directory, named: "b.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        let report = try await integration.applyOnce(
            [
                displayA: DesktopWallpaper(imageURL: imageA, scaling: .fill),
                displayB: DesktopWallpaper(imageURL: imageB, scaling: .fit)
            ],
            consent: consent(for: preflight)
        )
        #expect(report.blocked.isEmpty)

        let calls = await system.appliedCalls()
        #expect(calls.count == 2)
        let byDisplay = Dictionary(
            uniqueKeysWithValues: calls.map { ($0.displayID, $0) }
        )
        #expect(byDisplay[displayA]?.url == imageA)
        #expect(byDisplay[displayB]?.url == imageB)
    }

    @Test("Guard confirmation still rejects a nil observation; explicit apply is the supported path")
    func nilWallpaperConfirmationRejected() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: nil)
            ]
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
            displayA: DesktopWallpaper(imageURL: image)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.displayID == self.displayA && $0.reason == .unreadableCurrentWallpaper
            }
        }
        guard let block = integration.snapshot.guardBlocks.first else {
            Issue.record("Missing unreadable-wallpaper guard block")
            return
        }

        do {
            _ = try await integration.confirmOverwrite(block.confirmationRequest)
            Issue.record("Expected a nil confirmation to be rejected")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("A wallpaper change while applyOnce waits for a pass invalidates the preflight")
    func waitingPassChangeRejects() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let first = try TestFixtures.writeImage(in: directory, named: "first.png")
        let second = try TestFixtures.writeImage(in: directory, named: "second.png")
        let third = try TestFixtures.writeImage(in: directory, named: "third.png")
        let external = TestFixtures.externalURL("user")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: external)
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        let seedPreflight = try await integration.prepareWallpaperWrite()
        _ = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: first, scaling: .fill)],
            consent: consent(for: seedPreflight)
        )

        let enablePreflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: enablePreflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: second, scaling: .fill)
        ])

        await system.setSuspendNextApply()
        let passTask = Task { await integration.requestReconciliation() }
        await waitForSuspension(system)

        // The running pass is suspended before it writes, so the manual
        // preflight still captures `first`.
        let manualPreflight = try await integration.prepareWallpaperWrite()
        let applyTask = Task {
            try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: third, scaling: .fill)],
                consent: consent(for: manualPreflight)
            )
        }

        await waitUntil {
            integration.snapshot.assignments.first(where: {
                $0.displayID == self.displayA
            })?.wallpaper.imageURL == third
        }

        // Change the wallpaper while applyOnce is queued behind the running
        // pass, then let the running pass finish.
        await system.setCurrentImageURL(TestFixtures.externalURL("changed"), for: displayA)
        await system.resumeSuspendedApply()
        _ = await passTask.value

        do {
            _ = try await applyTask.value
            Issue.record("Expected the queued manual apply to reject")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }

        let calls = await system.appliedCalls()
        #expect(calls.count == 2)
        #expect(calls.last?.url == second)
        #expect(calls.contains(where: { $0.url == third }) == false)
    }

    // MARK: Automatic overwrite consent

    @Test("An unsupported schema version fails closed to read-only")
    func unsupportedSchemaFailsClosed() async throws {
        let directory = TestFixtures.temporaryDirectory()
        try Data(#"{"schemaVersion":99,"automationMode":"automatic","automaticOverwriteEnabled":true}"#.utf8)
            .write(to: directory.appendingPathComponent(MacDesktopSettingsStore.fileName))
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()

        #expect(integration.snapshot.automationMode == .readOnly)
        #expect(integration.snapshot.writeAccess == .readOnly)
        #expect(integration.snapshot.automaticOverwriteEnabled == false)
        #expect(integration.snapshot.lastIssue?.kind == .unsupportedSchemaVersion)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Schema 1 migration keeps auto sync but leaves automatic overwrite off")
    func schemaOneMigrationDefaultsOverwriteOff() async throws {
        let directory = TestFixtures.temporaryDirectory()
        try Data(#"{"schemaVersion":1,"automationMode":"automatic","automaticOverwriteEnabled":true}"#.utf8).write(
            to: directory.appendingPathComponent(MacDesktopSettingsStore.fileName)
        )
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()

        #expect(integration.snapshot.automationMode == .automatic)
        #expect(integration.snapshot.writeAccess == .authorized)
        #expect(integration.snapshot.automaticOverwriteEnabled == false)

        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains { $0.displayID == self.displayA }
        }
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        #expect(integration.snapshot.guardBlocks.first?.reason == .unverifiedExternalWallpaper)
    }

    @Test("Automatic overwrite and auto sync both survive a restart")
    func automaticOverwriteSurvivesRestart() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("user")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: external)]
        )
        let firstObserver = FakeEventObserver()
        let first = makeIntegration(
            directory: directory,
            system: system,
            observer: firstObserver
        )
        await first.start()
        let preflight = try await first.prepareWallpaperWrite()
        try await first.setAutomationEnabled(true, consent: consent(for: preflight))
        try await first.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])
        try await first.setAutomaticOverwriteEnabled(true)
        first.stop()

        let secondObserver = FakeEventObserver()
        let second = makeIntegration(
            directory: directory,
            system: system,
            observer: secondObserver
        )
        await second.start()
        #expect(second.snapshot.automationMode == .automatic)
        #expect(second.snapshot.writeAccess == .authorized)
        #expect(second.snapshot.automaticOverwriteEnabled)

        secondObserver.send(.activeSpaceDidChange)
        await waitUntil {
            second.snapshot.coordinatorState?.displayState(for: self.displayA)?.status
                == .synchronized
        }
        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(second.snapshot.guardBlocks.isEmpty)
        second.stop()
    }

    @Test("A wake event restores a persisted target after a restart")
    func wakeRestoresPersistedTargetAfterRestart() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("user"))]
        )
        let first = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await first.start()
        let preflight = try await first.prepareWallpaperWrite()
        try await first.setAutomationEnabled(true, consent: consent(for: preflight))
        try await first.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])
        try await first.setAutomaticOverwriteEnabled(true)
        first.stop()

        let observer = FakeEventObserver()
        let second = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            eventDebounce: .zero
        )
        await second.start()
        #expect(second.snapshot.automationMode == .automatic)
        #expect(second.snapshot.writeAccess == .authorized)

        observer.send(.systemDidWake)
        await waitUntil {
            second.snapshot.coordinatorState?.displayState(for: self.displayA)?.status
                == .synchronized
        }
        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        second.stop()
    }

    @Test("A reconnected display restores its target without rewriting the other display")
    func reconnectedDisplayRestoresTarget() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let imageA = try TestFixtures.writeImage(in: directory, named: "a.png")
        let imageB = try TestFixtures.writeImage(in: directory, named: "b.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a")),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            eventDebounce: .zero
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: imageA, scaling: .fill),
            displayB: DesktopWallpaper(imageURL: imageB, scaling: .fill)
        ])
        try await integration.setAutomaticOverwriteEnabled(true)

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            let state = integration.snapshot.coordinatorState
            return state?.displayState(for: self.displayA)?.status == .synchronized
                && state?.displayState(for: self.displayB)?.status == .synchronized
        }
        var calls = await system.appliedCalls()
        #expect(calls.count == 2)

        // Display B disappears. Its retained target must not be written.
        await system.setScreens([
            TestFixtures.screenshot(displayA, imageURL: imageA)
        ])
        observer.send(.screenParametersChanged)
        await waitUntil {
            integration.snapshot.displays.count == 1
                && integration.snapshot.coordinatorState?
                    .displayState(for: self.displayB)?.status == .disconnected
        }
        calls = await system.appliedCalls()
        #expect(calls.count == 2)

        // Display B reconnects showing an external wallpaper. Automatic
        // overwrite is already authorized, so only B is written again.
        await system.setScreens([
            TestFixtures.screenshot(displayA, imageURL: imageA),
            TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b-again"))
        ])
        observer.send(.screenParametersChanged)
        await waitUntil {
            integration.snapshot.displays.count == 2
                && integration.snapshot.coordinatorState?
                    .displayState(for: self.displayB)?.status == .synchronized
        }
        calls = await system.appliedCalls()
        #expect(calls.count == 3)
        #expect(calls.filter { $0.displayID == displayA }.count == 1)
        #expect(calls.filter { $0.displayID == displayB }.count == 2)
        #expect(calls.last?.displayID == displayB)
        #expect(calls.last?.url == imageB)
    }

    @Test("Unknown wallpapers block when overwrite is off, run when on, and block after revocation")
    func automaticOverwriteOffOnOff() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("first")
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
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])

        // Default off: first unknown wallpaper pauses.
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains { $0.displayID == self.displayA }
        }
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        // Explicit opt-in: the next event replaces the unknown wallpaper.
        try await integration.setAutomaticOverwriteEnabled(true)
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.coordinatorState?.displayState(for: self.displayA)?.status
                == .synchronized
        }
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(integration.snapshot.guardBlocks.isEmpty)

        // Revocation: a new unknown wallpaper pauses again.
        await system.setCurrentImageURL(TestFixtures.externalURL("second"), for: displayA)
        try await integration.setAutomaticOverwriteEnabled(false)
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.displayID == self.displayA
                    && $0.observedImageURL == TestFixtures.externalURL("second")
            }
        }
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(integration.snapshot.automaticOverwriteEnabled == false)
    }

    @Test("A read-only menu confirmation creates its own preflight and writes once")
    func readOnlyGuardConfirmationWorksAfterRestart() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("protected")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: external)]
        )
        let first = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await first.start()
        try await first.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])
        try await first.protectCurrentWallpaper(for: displayA)
        first.stop()

        let second = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await second.start()
        #expect(second.snapshot.automationMode == .readOnly)
        guard let block = second.snapshot.guardBlocks.first(where: {
            $0.displayID == displayA
        }) else {
            Issue.record("Missing persisted manual-protection guard")
            return
        }
        #expect(block.canConfirm)

        let report = try await second.confirmOverwrite(block.confirmationRequest)
        #expect(report.blocked.isEmpty)
        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(second.snapshot.manualProtections.isEmpty)
        #expect(second.snapshot.guardBlocks.isEmpty)
        #expect(second.snapshot.writeAccess == .readOnly)
    }

    @Test("Explicit manual protection blocks automatic overwrite even when enabled")
    func manualProtectionOutranksAutomaticOverwrite() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let protected = TestFixtures.externalURL("protected")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: protected)]
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
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])
        try await integration.protectCurrentWallpaper(for: displayA)
        try await integration.setAutomaticOverwriteEnabled(true)

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.displayID == self.displayA && $0.reason == .manualProtection
            }
        }
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        #expect(integration.snapshot.manualProtections.map(\.displayID) == [displayA])
    }

    @Test("An unreadable protected wallpaper stays visible and blocks automation")
    func unreadableManualProtectionIsVisible() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: nil)]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()
        try await integration.protectCurrentWallpaper(for: displayA)
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])

        guard let block = integration.snapshot.guardBlocks.first(where: {
            $0.displayID == displayA
        }) else {
            Issue.record("Expected an unreadable manual-protection guard")
            return
        }
        #expect(block.reason == .manualProtection)
        #expect(block.observedImageURL == nil)
        #expect(block.canConfirm == false)

        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setAutomaticOverwriteEnabled(true)
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.coordinatorState?
                .displayState(for: self.displayA)?.status == .failed
        }

        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        #expect(integration.snapshot.manualProtections.map(\.displayID) == [displayA])
        #expect(integration.snapshot.guardBlocks.first?.reason == .manualProtection)

        // The explicit per-display confirmation remains the way to replace a
        // protected, unreadable wallpaper.
        let explicitPreflight = try await integration.prepareWallpaperWrite()
        let report = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: image, scaling: .fill)],
            consent: consent(for: explicitPreflight)
        )
        #expect(report.blocked.isEmpty)
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(integration.snapshot.manualProtections.isEmpty)
        #expect(integration.snapshot.guardBlocks.isEmpty)
    }

    @Test("A failed manual apply keeps persisted manual protection")
    func failedManualApplyKeepsProtection() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let protected = TestFixtures.externalURL("protected")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: protected)]
        )
        let observer = FakeEventObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer
        )
        await integration.start()
        try await integration.protectCurrentWallpaper(for: displayA)
        let preflight = try await integration.prepareWallpaperWrite()
        await system.setFailure(
            DesktopFailure(
                stage: .applyingWallpaper,
                kind: .ioFailure,
                message: "synthetic failure"
            )
        )

        let report = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: image, scaling: .fill)],
            consent: consent(for: preflight)
        )
        #expect(report.reconcileReport?.outcomes.first?.failure != nil)
        #expect(integration.snapshot.manualProtections.map(\.displayID) == [displayA])
        // The explicit write did reach the system backend and fail there.
        var attempts = await system.attemptedCalls()
        #expect(attempts.count == 1)
        #expect(attempts.first?.url == image)
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        // The failed write did not consume the protection. A later automatic
        // attempt must be blocked before it reaches the system backend.
        await system.setFailure(nil)
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setAutomaticOverwriteEnabled(true)
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.displayID == self.displayA && $0.reason == .manualProtection
            }
        }
        attempts = await system.attemptedCalls()
        calls = await system.appliedCalls()
        #expect(attempts.count == 1)
        #expect(calls.isEmpty)
    }

    @Test("An invalidated preflight never removes manual protection")
    func invalidatedPreflightKeepsProtection() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("first"))
            ]
        )
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver()
        )
        await integration.start()
        try await integration.protectCurrentWallpaper(for: displayA)
        let preflight = try await integration.prepareWallpaperWrite()
        await system.setCurrentImageURL(TestFixtures.externalURL("second"), for: displayA)

        do {
            _ = try await integration.applyOnce(
                [displayA: DesktopWallpaper(imageURL: image, scaling: .fill)],
                consent: consent(for: preflight)
            )
            Issue.record("Expected preflight mismatch")
        } catch let error as MacDesktopApplyError {
            #expect(error == .preflightMismatch)
        }
        #expect(integration.snapshot.manualProtections.map(\.displayID) == [displayA])
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("An unreadable current wallpaper is never offered as confirmable")
    func unreadableGuardIsNotConfirmable() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: nil)]
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
            displayA: DesktopWallpaper(imageURL: image, scaling: .fill)
        ])

        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.reason == .unreadableCurrentWallpaper
            }
        }
        guard let block = integration.snapshot.guardBlocks.first else {
            Issue.record("Missing guard block")
            return
        }
        #expect(block.canConfirm == false)
    }

    @Test("A desktop change during cache protection blocks the write before the system call")
    func desktopChangeDuringProtectionBlocksWrite() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let before = TestFixtures.externalURL("before")
        let after = TestFixtures.externalURL("after")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(displayA, imageURL: before)]
        )
        let displayID = displayA
        let protection = CallbackWallpaperProtection {
            await system.setCurrentImageURL(after, for: displayID)
        }
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver(),
            protection: protection
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        let report = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: image, scaling: .fill)],
            consent: consent(for: preflight)
        )

        #expect(report.reconcileReport?.outcomes.first?.failure != nil)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("A persisted automatic target applies on one explicit reconciliation")
    func persistedAutomaticTargetReconcilesImmediately() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
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
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setAutomaticTarget(
            DesktopWallpaper(imageURL: image),
            connectedDisplayIDs: [displayA],
            replacingAssignedConnectedDisplays: true
        )
        try await integration.setAutomaticOverwriteEnabled(true)

        // This is the enable-flow sequence: configuration alone must not
        // write, and one explicit reconciliation must apply it immediately.
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        await integration.requestReconciliation()

        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.displayID == displayA)
        #expect(integration.snapshot.assignments.first?.wallpaper.imageURL == image)
    }

    @Test("Pointer tracker fires only on a real display identity change")
    func pointerTrackerOnlyFiresAcrossDisplays() {
        var tracker = MacPointerDisplayTracker()
        #expect(tracker.update(to: displayA) == nil)
        #expect(tracker.update(to: displayA) == nil)

        let change = tracker.update(to: displayB)
        #expect(change == MacPointerDisplayChange(
            displayID: displayB,
            previousDisplayID: displayA
        ))
        #expect(tracker.update(to: displayB) == nil)

        // A gap between displays is not an identity change.
        #expect(tracker.update(to: nil) == nil)
        #expect(tracker.update(to: displayA)?.displayID == displayA)
    }

    @Test("A pointer crossing does not invalidate a prepared preflight")
    func pointerCrossingKeepsPreflight() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let externalA = TestFixtures.externalURL("a")
        let externalB = TestFixtures.externalURL("b")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: externalA),
                TestFixtures.screenshot(displayB, imageURL: externalB)
            ]
        )
        let observer = FakeEventObserver()
        let pointerObserver = FakePointerObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            pointerObserver: pointerObserver
        )
        await integration.start()
        let enablePreflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(
            true,
            consent: consent(for: enablePreflight)
        )
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image)
        ])

        let prepared = try await integration.prepareWallpaperWrite()
        pointerObserver.send(MacPointerDisplayChange(
            displayID: displayB,
            previousDisplayID: displayA
        ))

        // The pointer pass still runs and the overwrite policy still refuses an
        // unknown wallpaper; it must not consume the manual confirmation.
        await waitUntil {
            integration.snapshot.guardBlocks.contains {
                $0.displayID == self.displayA
                    && $0.reason == .unverifiedExternalWallpaper
            }
        }
        #expect(integration.snapshot.pendingPreflight?.id == prepared.id)
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)

        let report = try await integration.applyOnce(
            [displayA: DesktopWallpaper(imageURL: image)],
            consent: consent(for: prepared)
        )
        #expect(report.blocked.isEmpty)
        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.displayID == displayA)
    }

    @Test("A pointer crossing applies assigned targets when automatic overwrite allows it")
    func pointerCrossingReconciles() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let imageA = try TestFixtures.writeImage(in: directory, named: "a.png")
        let imageB = try TestFixtures.writeImage(in: directory, named: "b.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a")),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
        )
        let observer = FakeEventObserver()
        let pointerObserver = FakePointerObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            pointerObserver: pointerObserver
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: imageA),
            displayB: DesktopWallpaper(imageURL: imageB)
        ])
        // Separate consent: without it the unknown wallpapers above stay
        // protected. This test proves the pointer trigger is filtered by it.
        try await integration.setAutomaticOverwriteEnabled(true)

        pointerObserver.send(MacPointerDisplayChange(
            displayID: displayB,
            previousDisplayID: displayA
        ))
        await waitUntil {
            let state = integration.snapshot.coordinatorState
            return state?.displayState(for: self.displayA)?.status == .synchronized
                && state?.displayState(for: self.displayB)?.status == .synchronized
        }
        var calls = await system.appliedCalls()
        #expect(calls.count == 2)

        // A same-display sample is not a crossing and must not start a pass.
        pointerObserver.send(MacPointerDisplayChange(
            displayID: displayB,
            previousDisplayID: displayB
        ))
        try await Task.sleep(for: .milliseconds(60))
        calls = await system.appliedCalls()
        #expect(calls.count == 2)
    }

    @Test("A pointer crossing waits for automatic sync")
    func pointerCrossingInReadOnlyDoesNothing() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a")),
                TestFixtures.screenshot(displayB, imageURL: TestFixtures.externalURL("b"))
            ]
        )
        let pointerObserver = FakePointerObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: FakeEventObserver(),
            pointerObserver: pointerObserver
        )
        await integration.start()
        _ = try await integration.prepareWallpaperWrite()

        pointerObserver.send(MacPointerDisplayChange(
            displayID: displayB,
            previousDisplayID: displayA
        ))
        try await Task.sleep(for: .milliseconds(60))

        #expect(integration.snapshot.coordinatorState?.lastReport == nil)
        #expect(integration.snapshot.pendingPreflight != nil)
        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("A pointer crossing coalesces with a pending Space event and keeps its semantics")
    func pointerCrossingCoalescesWithSpaceEvent() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(displayA, imageURL: TestFixtures.externalURL("a"))
            ]
        )
        let observer = FakeEventObserver()
        let pointerObserver = FakePointerObserver()
        let integration = makeIntegration(
            directory: directory,
            system: system,
            observer: observer,
            pointerObserver: pointerObserver,
            eventDebounce: .milliseconds(40)
        )
        await integration.start()
        let preflight = try await integration.prepareWallpaperWrite()
        try await integration.setAutomationEnabled(true, consent: consent(for: preflight))
        try await integration.setDesiredAssignments([
            displayA: DesktopWallpaper(imageURL: image)
        ])
        try await integration.setAutomaticOverwriteEnabled(true)

        pointerObserver.send(MacPointerDisplayChange(
            displayID: displayB,
            previousDisplayID: displayA
        ))
        observer.send(.activeSpaceDidChange)
        await waitUntil {
            integration.snapshot.coordinatorState?
                .displayState(for: self.displayA)?.status == .synchronized
        }

        let state = integration.snapshot.coordinatorState
        #expect(state?.lastReport?.trigger == .spaceDidChange)
        #expect(state?.spaceGeneration == 1)
        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
    }

    private func waitForSuspension(_ system: FakeWallpaperSystem) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if await system.isApplySuspended() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Fake wallpaper apply never suspended")
    }
}
