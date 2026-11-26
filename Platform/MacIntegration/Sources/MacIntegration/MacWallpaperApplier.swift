import DaybreakCore
import Foundation
import ImageIO
import os

/// Records the latest guard refusal per display so the UI can explain why
/// automation paused. Purely in-memory; blocks are not a persistent claim.
actor MacWriteGuardAudit {
    private var blocks: [DesktopDisplayID: MacWriteGuardBlock] = [:]

    func record(_ block: MacWriteGuardBlock) {
        blocks[block.displayID] = block
    }

    func clear(displayID: DesktopDisplayID) {
        blocks[displayID] = nil
    }

    func clearAll() {
        blocks.removeAll()
    }

    func snapshot() -> [MacWriteGuardBlock] {
        blocks.values.sorted { $0.displayID < $1.displayID }
    }
}

/// The only macOS implementation of `DesktopPlatformBackend`.
///
/// Every write is checked by `MacWallpaperWriteGate` and by
/// `MacOverwritePolicy` against the persisted managed-wallpaper ledger. A
/// blocked write throws a non-retryable `permissionDenied` failure, which the
/// coordinator surfaces as a failed display instead of retrying or pretending
/// success.
public struct MacWallpaperApplier: DesktopPlatformBackend, Sendable {
    private let system: any MacWallpaperSystem
    private let gate: MacWallpaperWriteGate
    private let store: MacDesktopSettingsStore?
    private let audit: MacWriteGuardAudit
    private let manualWriteBroker: MacManualWriteBroker
    private let protection: any WallpaperApplicationProtecting
    private let now: @Sendable () -> Date

    /// Read-only diagnostics adapter. Writes always fail with `permissionDenied`.
    public init(system: any MacWallpaperSystem = AppKitWallpaperSystem()) {
        self.init(
            system: system,
            gate: MacWallpaperWriteGate(),
            store: nil,
            audit: MacWriteGuardAudit(),
            manualWriteBroker: MacManualWriteBroker(),
            protection: UnavailableWallpaperProtection(),
            now: { Date() }
        )
    }

    init(
        system: any MacWallpaperSystem,
        gate: MacWallpaperWriteGate,
        store: MacDesktopSettingsStore?,
        audit: MacWriteGuardAudit,
        manualWriteBroker: MacManualWriteBroker = MacManualWriteBroker(),
        protection: any WallpaperApplicationProtecting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.system = system
        self.gate = gate
        self.store = store
        self.audit = audit
        self.manualWriteBroker = manualWriteBroker
        self.protection = protection
        self.now = now
    }

    public func readTopology() async throws -> DesktopTopology {
        let screens = await system.screens()
        let separateSpaces = await system.screensHaveSeparateSpaces()
        let displays = screens
            .sorted { $0.displayID < $1.displayID }
            .map {
                DesktopDisplaySnapshot(
                    displayID: $0.displayID,
                    currentImageURL: $0.imageURL,
                    reportedScaling: $0.options.scaling
                )
            }
        return DesktopTopology(
            displays: displays,
            screensHaveSeparateSpaces: separateSpaces
        )
    }

    private func record(_ block: MacWriteGuardBlock) async {
        await audit.record(block)
        MacIntegrationLog.logger.notice(
            "Wallpaper write paused display=\(block.displayID.rawValue, privacy: .private) reason=\(block.reason.rawValue, privacy: .public)"
        )
    }

    public func applyWallpaper(
        _ wallpaper: DesktopWallpaper,
        to displayID: DesktopDisplayID
    ) async throws {
        // Central write gate: no other path in this module writes wallpaper.
        try await gate.requireWritable()

        guard wallpaper.imageURL.isFileURL else {
            MacIntegrationLog.logger.notice(
                "Wallpaper write refused reason=non-file-url"
            )
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .imageUnreadable,
                message: "The wallpaper URL is not a local file URL."
            )
        }
        guard FileManager.default.isReadableFile(atPath: wallpaper.imageURL.path) else {
            MacIntegrationLog.logger.notice(
                "Wallpaper write refused reason=image-missing-or-unreadable"
            )
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .imageUnreadable,
                message: "The wallpaper file is missing or unreadable."
            )
        }
        guard let source = CGImageSourceCreateWithURL(wallpaper.imageURL as CFURL, nil),
              CGImageSourceGetType(source) != nil else {
            MacIntegrationLog.logger.notice(
                "Wallpaper write refused reason=undecodable-image"
            )
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .unsupportedImageFormat,
                message: "The wallpaper file is not a decodable image."
            )
        }

        let initialScreens = await system.screens()
        guard let initialCurrent = initialScreens.first(where: {
            $0.displayID == displayID
        }) else {
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .displayUnavailable,
                message: "The display is no longer connected."
            )
        }

        var guardContext: MacGuardContext?
        if let store {
            guardContext = await store.guardContext(
                displayID: displayID,
                observedImageURL: initialCurrent.imageURL,
                target: wallpaper
            )
        } else {
            guardContext = nil
        }

        // Re-read after the store await. A Space switch or a user wallpaper
        // change during that window must fail closed, not be overwritten using
        // the pre-await snapshot.
        let screens = await system.screens()
        guard let current = screens.first(where: { $0.displayID == displayID }) else {
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .displayUnavailable,
                message: "The display is no longer connected."
            )
        }
        if initialCurrent.imageURL != current.imageURL
            || initialCurrent.options != current.options {
            let reason: MacOverwriteBlockReason = current.imageURL == nil
                ? .unreadableCurrentWallpaper
                : .unverifiedExternalWallpaper
            let block = MacWriteGuardBlock(
                displayID: displayID,
                observedImageURL: current.imageURL,
                desiredWallpaper: wallpaper,
                reason: reason,
                detectedAt: now()
            )
            await record(block)
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .permissionDenied,
                message: "Daybreak paused: the desktop changed while the current wallpaper was being verified. The existing wallpaper was left unchanged."
            )
        }

        // A manual-apply pass has a write-side contract independent of the
        // persisted approval/ledger heuristics. It is checked synchronously at
        // the last moment before the public write call. If the scope was
        // invalidated by a Space/screen event, or the live URL/options changed
        // after the preflight, the write fails closed for every target.
        let brokerDecision = manualWriteBroker.decision(
            displayID: displayID,
            target: wallpaper,
            observedURL: current.imageURL,
            observedOptions: current.options,
            at: now()
        )
        let overridesProtection = brokerDecision == .allowed
            && manualWriteBroker.authorizesManualProtectionOverride(
                displayID: displayID,
                target: wallpaper,
                at: now()
            )

        if guardContext?.isManuallyProtected == true, !overridesProtection {
            let block = MacWriteGuardBlock(
                displayID: displayID,
                observedImageURL: current.imageURL,
                desiredWallpaper: wallpaper,
                reason: .manualProtection,
                detectedAt: now()
            )
            await record(block)
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .permissionDenied,
                message: Self.blockedMessage(.manualProtection)
            )
        }

        switch brokerDecision {
        case .allowed:
            break
        case .blocked(let reason):
            let block = MacWriteGuardBlock(
                displayID: displayID,
                observedImageURL: current.imageURL,
                desiredWallpaper: wallpaper,
                reason: reason,
                detectedAt: now()
            )
            await record(block)
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .permissionDenied,
                message: Self.manualPreflightBlockedMessage(reason)
            )
        case .notInScope:
            if let guardContext {
                let decision = MacOverwritePolicy.decide(
                    observedImageURL: current.imageURL,
                    desired: wallpaper,
                    isManaged: guardContext.isManaged,
                    hasMatchingApproval: guardContext.hasMatchingApproval,
                    isManuallyProtected: guardContext.isManuallyProtected,
                    allowsAutomaticOverwrite: guardContext.allowsAutomaticOverwrite
                )
                if case .blocked(let reason) = decision {
                    let block = MacWriteGuardBlock(
                        displayID: displayID,
                        observedImageURL: current.imageURL,
                        desiredWallpaper: wallpaper,
                        reason: reason,
                        detectedAt: now()
                    )
                    await record(block)
                    throw DesktopFailure(
                        stage: .applyingWallpaper,
                        kind: .permissionDenied,
                        message: Self.blockedMessage(reason)
                    )
                }
            }
        }

        do {
            try await ensureProtection(forImageURL: wallpaper.imageURL)

            // `ensureProtection` is an async hop through the repository actor.
            // A Space switch, a manual wallpaper change, a protection toggle or
            // a revoked gate may land while it runs. Re-read the live screen
            // and all authorization state immediately before the system call;
            // never rely on the snapshot taken before the protection commit.
            try await gate.requireWritable()
            let finalScreens = await system.screens()
            guard let finalScreen = finalScreens.first(where: {
                $0.displayID == displayID
            }) else {
                throw DesktopFailure(
                    stage: .applyingWallpaper,
                    kind: .displayUnavailable,
                    message: "The display is no longer connected."
                )
            }
            if finalScreen.imageURL != current.imageURL
                || finalScreen.options != current.options {
                let reason: MacOverwriteBlockReason = finalScreen.imageURL == nil
                    ? .unreadableCurrentWallpaper
                    : .unverifiedExternalWallpaper
                let block = MacWriteGuardBlock(
                    displayID: displayID,
                    observedImageURL: finalScreen.imageURL,
                    desiredWallpaper: wallpaper,
                    reason: reason,
                    detectedAt: now()
                )
                await record(block)
                throw DesktopFailure(
                    stage: .applyingWallpaper,
                    kind: .permissionDenied,
                    message: "Daybreak paused: the desktop changed while cache protection was being recorded. The existing wallpaper was left unchanged."
                )
            }

            if let store {
                guardContext = await store.guardContext(
                    displayID: displayID,
                    observedImageURL: finalScreen.imageURL,
                    target: wallpaper
                )
            }

            let finalBrokerDecision = manualWriteBroker.decision(
                displayID: displayID,
                target: wallpaper,
                observedURL: finalScreen.imageURL,
                observedOptions: finalScreen.options,
                at: now()
            )
            let finalOverridesProtection = finalBrokerDecision == .allowed
                && manualWriteBroker.authorizesManualProtectionOverride(
                    displayID: displayID,
                    target: wallpaper,
                    at: now()
                )
            if guardContext?.isManuallyProtected == true, !finalOverridesProtection {
                let block = MacWriteGuardBlock(
                    displayID: displayID,
                    observedImageURL: finalScreen.imageURL,
                    desiredWallpaper: wallpaper,
                    reason: .manualProtection,
                    detectedAt: now()
                )
                await record(block)
                throw DesktopFailure(
                    stage: .applyingWallpaper,
                    kind: .permissionDenied,
                    message: Self.blockedMessage(.manualProtection)
                )
            }
            switch finalBrokerDecision {
            case .blocked(let reason):
                let block = MacWriteGuardBlock(
                    displayID: displayID,
                    observedImageURL: finalScreen.imageURL,
                    desiredWallpaper: wallpaper,
                    reason: reason,
                    detectedAt: now()
                )
                await record(block)
                throw DesktopFailure(
                    stage: .applyingWallpaper,
                    kind: .permissionDenied,
                    message: Self.manualPreflightBlockedMessage(reason)
                )
            case .allowed:
                break
            case .notInScope:
                guard let guardContext else { break }
                let decision = MacOverwritePolicy.decide(
                    observedImageURL: finalScreen.imageURL,
                    desired: wallpaper,
                    isManaged: guardContext.isManaged,
                    hasMatchingApproval: guardContext.hasMatchingApproval,
                    isManuallyProtected: guardContext.isManuallyProtected,
                    allowsAutomaticOverwrite: guardContext.allowsAutomaticOverwrite
                )
                if case .blocked(let reason) = decision {
                    let block = MacWriteGuardBlock(
                        displayID: displayID,
                        observedImageURL: finalScreen.imageURL,
                        desiredWallpaper: wallpaper,
                        reason: reason,
                        detectedAt: now()
                    )
                    await record(block)
                    throw DesktopFailure(
                        stage: .applyingWallpaper,
                        kind: .permissionDenied,
                        message: Self.blockedMessage(reason)
                    )
                }
            }

            try await system.applyImage(
                at: wallpaper.imageURL,
                options: .forScaling(wallpaper.scaling),
                to: displayID
            )
        } catch {
            await protection.completeAppliedProtection(
                forImageURL: wallpaper.imageURL,
                succeeded: false
            )
            let failure = Self.normalizedFailure(error)
            MacIntegrationLog.logger.error(
                "Wallpaper write failed display=\(displayID.rawValue, privacy: .private) kind=\(failure.kind.rawValue, privacy: .public)"
            )
            throw failure
        }

        await protection.completeAppliedProtection(
            forImageURL: wallpaper.imageURL,
            succeeded: true
        )
        if let store {
            await store.recordAppliedWallpaper(url: wallpaper.imageURL, for: displayID)
            await store.consumeApproval(
                displayID: displayID,
                observedImageURL: current.imageURL,
                target: wallpaper
            )
            await audit.clear(displayID: displayID)
        }
        MacIntegrationLog.logger.notice(
            "Wallpaper write succeeded display=\(displayID.rawValue, privacy: .private) scaling=\(wallpaper.scaling.rawValue, privacy: .public)"
        )
    }

    /// Persists cache protection before the system call. A missing identity,
    /// missing file or a failed repository commit blocks the write. The
    /// reservation is released after the attempt; a successful attempt keeps
    /// the image protected as current-desktop state.
    private func ensureProtection(forImageURL url: URL) async throws {
        let reservedID: WallpaperID?
        do {
            reservedID = try await protection.reserveAppliedProtection(forImageURL: url)
        } catch {
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .ioFailure,
                message: "Daybreak blocked the wallpaper write because cache protection could not be persisted: \(error.localizedDescription)"
            )
        }

        guard reservedID != nil else {
            throw DesktopFailure(
                stage: .applyingWallpaper,
                kind: .imageUnreadable,
                message: "Daybreak blocked the wallpaper write because the image is not a readable repository original (the cache file is missing or unknown)."
            )
        }
    }

    private static func manualPreflightBlockedMessage(
        _ reason: MacOverwriteBlockReason
    ) -> String {
        switch reason {
        case .unreadableCurrentWallpaper:
            return "Daybreak paused: the current wallpaper could not be read while performing the manual apply. The existing wallpaper was left unchanged."
        case .unverifiedExternalWallpaper, .manualProtection:
            return "Daybreak paused: the manual-apply preflight no longer matches the current desktop (Space, wallpaper, or options changed). The existing wallpaper was left unchanged."
        }
    }

    private static func blockedMessage(_ reason: MacOverwriteBlockReason) -> String {
        switch reason {
        case .unverifiedExternalWallpaper:
            return "Daybreak paused: the current wallpaper was not written by Daybreak and has not been explicitly approved for replacement. The existing wallpaper was left unchanged."
        case .unreadableCurrentWallpaper:
            return "Daybreak paused: the system did not report the current wallpaper. The existing wallpaper was left unchanged."
        case .manualProtection:
            return "Daybreak paused: this display is marked to preserve its current wallpaper."
        }
    }

    private static func normalizedFailure(_ error: any Error) -> DesktopFailure {
        if let failure = error as? DesktopFailure {
            return DesktopFailure(
                stage: .applyingWallpaper,
                kind: failure.kind,
                message: failure.message
            )
        }
        return DesktopFailure(
            stage: .applyingWallpaper,
            kind: .unknown,
            message: String(describing: error)
        )
    }
}
