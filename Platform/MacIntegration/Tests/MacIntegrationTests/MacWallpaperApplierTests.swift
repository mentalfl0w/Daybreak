import DaybreakCore
import Foundation
import Testing
@testable import MacIntegration

@Suite("MacWallpaperApplier")
struct MacWallpaperApplierTests {
    private let display = DesktopDisplayID("applier-display-a")

    @Test("Read-only applier never reaches the system")
    func readOnlyApplierRefuses() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(display, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let applier = MacWallpaperApplier(system: system)
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)

        do {
            try await applier.applyWallpaper(wallpaper, to: display)
            Issue.record("Expected a permission failure")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .permissionDenied)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Unknown external wallpaper is blocked and can be approved once")
    func guardBlocksThenApprovalAllows() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("user")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(display, imageURL: external)
            ]
        )
        let store = MacDesktopSettingsStore(directory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let gate = MacWallpaperWriteGate()
        let audit = MacWriteGuardAudit()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: audit,
            protection: PermissiveWallpaperProtection()
        )
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)
        await gate.grant()

        do {
            try await applier.applyWallpaper(wallpaper, to: display)
            Issue.record("Expected the overwrite guard to block")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .permissionDenied)
        }
        var calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        let blocks = await audit.snapshot()
        #expect(blocks.map(\.reason) == [.unverifiedExternalWallpaper])
        #expect(blocks.first?.confirmationRequest.observedImageURL == external)

        await store.addApproval(
            displayID: display,
            observedImageURL: external,
            target: wallpaper
        )
        try await applier.applyWallpaper(wallpaper, to: display)

        calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
        #expect(calls.first?.options.scaling == .fill)
        let afterSuccessBlocks = await audit.snapshot()
        #expect(afterSuccessBlocks.isEmpty)
        let settings = await store.snapshot()
        #expect(settings.managedImageURLs.contains(image))
    }

    @Test("A managed image from the persisted ledger may be replaced")
    func managedLedgerAllows() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let previous = try TestFixtures.writeImage(in: directory, named: "previous.png")
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(display, imageURL: previous)
            ]
        )
        let store = MacDesktopSettingsStore(directory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        await store.recordAppliedWallpaper(url: previous, for: display)
        let gate = MacWallpaperWriteGate()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            protection: PermissiveWallpaperProtection()
        )
        await gate.grant()

        try await applier.applyWallpaper(
            DesktopWallpaper(imageURL: target, scaling: .fit),
            to: display
        )

        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == target)
        #expect(calls.first?.options.scaling == .fit)
    }

    @Test("Missing or invalid image files fail before any write")
    func invalidImageFails() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let system = FakeWallpaperSystem(
            screens: [
                TestFixtures.screenshot(display, imageURL: TestFixtures.externalURL("user"))
            ]
        )
        let store = MacDesktopSettingsStore(directory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let gate = MacWallpaperWriteGate()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            protection: PermissiveWallpaperProtection()
        )
        await gate.grant()

        do {
            try await applier.applyWallpaper(
                DesktopWallpaper(imageURL: directory.appendingPathComponent("missing.png")),
                to: display
            )
            Issue.record("Expected an unreadable image failure")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .imageUnreadable)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Manual broker allows exact preflight state without a store approval")
    func brokerAllowsExactState() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("preflight")
        let screenshot = TestFixtures.screenshot(display, imageURL: external)
        let system = FakeWallpaperSystem(screens: [screenshot])
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let gate = MacWallpaperWriteGate()
        let broker = MacManualWriteBroker()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            manualWriteBroker: broker,
            protection: PermissiveWallpaperProtection(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)
        broker.begin(
            MacManualWriteScope(
                preflightID: UUID(),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
                wallpaperByDisplay: [display: wallpaper],
                verifiedByDisplay: [
                    display: MacVerifiedDisplayObservation(
                        imageURL: external,
                        options: screenshot.options
                    )
                ],
                restrictsNonTargets: false,
                overridesManualProtection: false
            )
        )
        await gate.grant()

        try await applier.applyWallpaper(wallpaper, to: display)

        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
    }

    @Test("Invalidated manual broker fails closed even when the current wallpaper still matches")
    func brokerInvalidationBlocks() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let external = TestFixtures.externalURL("preflight")
        let screenshot = TestFixtures.screenshot(display, imageURL: external)
        let system = FakeWallpaperSystem(screens: [screenshot])
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let gate = MacWallpaperWriteGate()
        let broker = MacManualWriteBroker()
        let audit = MacWriteGuardAudit()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: audit,
            manualWriteBroker: broker,
            protection: PermissiveWallpaperProtection(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)
        broker.begin(
            MacManualWriteScope(
                preflightID: UUID(),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
                wallpaperByDisplay: [display: wallpaper],
                verifiedByDisplay: [
                    display: MacVerifiedDisplayObservation(
                        imageURL: external,
                        options: screenshot.options
                    )
                ],
                restrictsNonTargets: false,
                overridesManualProtection: false
            )
        )
        broker.invalidate()
        await gate.grant()

        do {
            try await applier.applyWallpaper(wallpaper, to: display)
            Issue.record("Expected the invalidated broker to block")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .permissionDenied)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        let blocks = await audit.snapshot()
        #expect(blocks.map(\.reason) == [.unverifiedExternalWallpaper])
    }

    @Test("Manual broker blocks when the live wallpaper changed after verification")
    func brokerChangedWallpaperBlocks() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let verifiedURL = TestFixtures.externalURL("verified")
        let changedURL = TestFixtures.externalURL("changed")
        let screenshot = TestFixtures.screenshot(display, imageURL: changedURL)
        let system = FakeWallpaperSystem(screens: [screenshot])
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let gate = MacWallpaperWriteGate()
        let broker = MacManualWriteBroker()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            manualWriteBroker: broker,
            protection: PermissiveWallpaperProtection(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)
        broker.begin(
            MacManualWriteScope(
                preflightID: UUID(),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
                wallpaperByDisplay: [display: wallpaper],
                verifiedByDisplay: [
                    display: MacVerifiedDisplayObservation(
                        imageURL: verifiedURL,
                        options: screenshot.options
                    )
                ],
                restrictsNonTargets: false,
                overridesManualProtection: false
            )
        )
        await gate.grant()

        do {
            try await applier.applyWallpaper(wallpaper, to: display)
            Issue.record("Expected the changed wallpaper to block")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .permissionDenied)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Manual broker allows a verified nil observation when options still match")
    func brokerAllowsUnreadableExactState() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let screenshot = TestFixtures.screenshot(display, imageURL: nil)
        let system = FakeWallpaperSystem(screens: [screenshot])
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let gate = MacWallpaperWriteGate()
        let broker = MacManualWriteBroker()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            manualWriteBroker: broker,
            protection: PermissiveWallpaperProtection(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)
        broker.begin(
            MacManualWriteScope(
                preflightID: UUID(),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
                wallpaperByDisplay: [display: wallpaper],
                verifiedByDisplay: [
                    display: MacVerifiedDisplayObservation(
                        imageURL: nil,
                        options: screenshot.options
                    )
                ],
                restrictsNonTargets: false,
                overridesManualProtection: false
            )
        )
        await gate.grant()

        try await applier.applyWallpaper(wallpaper, to: display)

        let calls = await system.appliedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.url == image)
    }

    @Test("Manual broker blocks when an unreadable desktop's options changed")
    func brokerChangedOptionsBlocksUnreadable() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let image = try TestFixtures.writeImage(in: directory, named: "target.png")
        let liveOptions = MacWallpaperOptions(
            imageScalingRawValue: 1,
            allowsClipping: false
        )
        let verifiedOptions = MacWallpaperOptions(
            imageScalingRawValue: 3,
            allowsClipping: true
        )
        let screenshot = TestFixtures.screenshot(
            display,
            imageURL: nil,
            options: liveOptions
        )
        let system = FakeWallpaperSystem(screens: [screenshot])
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let gate = MacWallpaperWriteGate()
        let broker = MacManualWriteBroker()
        let audit = MacWriteGuardAudit()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: audit,
            manualWriteBroker: broker,
            protection: PermissiveWallpaperProtection(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let wallpaper = DesktopWallpaper(imageURL: image, scaling: .fill)
        broker.begin(
            MacManualWriteScope(
                preflightID: UUID(),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
                wallpaperByDisplay: [display: wallpaper],
                verifiedByDisplay: [
                    display: MacVerifiedDisplayObservation(
                        imageURL: nil,
                        options: verifiedOptions
                    )
                ],
                restrictsNonTargets: false,
                overridesManualProtection: false
            )
        )
        await gate.grant()

        do {
            try await applier.applyWallpaper(wallpaper, to: display)
            Issue.record("Expected changed options to block the write")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .permissionDenied)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
        let blocks = await audit.snapshot()
        #expect(blocks.map(\.reason) == [.unreadableCurrentWallpaper])
    }

    @Test("A protection persistence failure blocks the system write")
    func protectionFailureBlocksWrite() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let previous = try TestFixtures.writeImage(in: directory, named: "previous.png")
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(display, imageURL: previous)]
        )
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await store.recordAppliedWallpaper(url: previous, for: display)
        let gate = MacWallpaperWriteGate()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            protection: RejectingWallpaperProtection()
        )
        await gate.grant()

        do {
            try await applier.applyWallpaper(
                DesktopWallpaper(imageURL: target),
                to: display
            )
            Issue.record("Expected protection failure to block the write")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .ioFailure)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

    @Test("An unmappable repository identity blocks the system write")
    func unmappableIdentityBlocksWrite() async throws {
        let directory = TestFixtures.temporaryDirectory()
        let previous = try TestFixtures.writeImage(in: directory, named: "previous.png")
        let target = try TestFixtures.writeImage(in: directory, named: "target.png")
        let system = FakeWallpaperSystem(
            screens: [TestFixtures.screenshot(display, imageURL: previous)]
        )
        let store = MacDesktopSettingsStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await store.recordAppliedWallpaper(url: previous, for: display)
        let gate = MacWallpaperWriteGate()
        let applier = MacWallpaperApplier(
            system: system,
            gate: gate,
            store: store,
            audit: MacWriteGuardAudit(),
            protection: NilWallpaperProtection()
        )
        await gate.grant()

        do {
            try await applier.applyWallpaper(
                DesktopWallpaper(imageURL: target),
                to: display
            )
            Issue.record("Expected an unmappable identity to block the write")
        } catch let failure as DesktopFailure {
            #expect(failure.kind == .imageUnreadable)
        }

        let calls = await system.appliedCalls()
        #expect(calls.isEmpty)
    }

}
