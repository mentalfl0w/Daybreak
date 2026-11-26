import DaybreakCore
import Foundation
import MacIntegration

/// The SwiftUI environment locale is not visible to non-View code. Read the
/// interface choice stored by `AppLanguagePreference` so module-provided
/// errors ship in the user's chosen language instead of the system language.
enum WallpaperInterfaceLocale {
    static var current: Locale {
        let raw = UserDefaults.standard.string(forKey: "daybreak.interfaceLanguage") ?? "system"
        return raw == "system" ? .current : Locale(identifier: raw)
    }
}

// MARK: - App-facing values

struct DesktopDisplayOption: Identifiable, Hashable, Sendable {
    let id: DesktopDisplayID
    let name: String

    var label: String {
        name.isEmpty
            ? MacLocalizedString.resolve("未命名显示器", locale: WallpaperInterfaceLocale.current)
            : name
    }
}

struct WallpaperGuardInfo: Identifiable, Hashable, Sendable {
    let displayID: DesktopDisplayID
    let displayName: String
    let reason: String
    let observedImageURL: URL?
    let desiredImageURL: URL?

    var id: DesktopDisplayID { displayID }

    /// A nil live URL can never pass the confirmation re-read. Do not offer a
    /// button that would always fail.
    var canConfirm: Bool { observedImageURL != nil }
}

/// The one compact confirmation shown before a user-initiated wallpaper
/// action. The internal preflight token is generated only when the user taps
/// `confirmLabel`; there are no secondary checkboxes.
enum WallpaperConfirmationAction: Equatable, Sendable {
    case manualApply(imageURL: URL, displayID: DesktopDisplayID?)
    case autoSync(imageURL: URL)
    case automaticOverwrite
}

struct WallpaperConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: WallpaperConfirmationAction
    let title: String
    let message: String
    let confirmLabel: String

    init(
        id: UUID = UUID(),
        action: WallpaperConfirmationAction,
        title: String,
        message: String,
        confirmLabel: String
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
    }
}

struct WallpaperApplyOutcome: Sendable {
    /// Displays the backend actually wrote in this pass.
    let appliedDisplayIDs: [DesktopDisplayID]
    /// Displays whose current wallpaper already matched the requested image.
    /// Kept separate from `appliedDisplayIDs` because no write occurred, but
    /// a confirmed manual apply still refers to a genuinely present image.
    let synchronizedDisplayIDs: [DesktopDisplayID]
    let failures: [String]
    let blocked: [WallpaperGuardInfo]
    let message: String

    init(
        appliedDisplayIDs: [DesktopDisplayID],
        synchronizedDisplayIDs: [DesktopDisplayID] = [],
        failures: [String],
        blocked: [WallpaperGuardInfo],
        message: String
    ) {
        self.appliedDisplayIDs = appliedDisplayIDs
        self.synchronizedDisplayIDs = synchronizedDisplayIDs
        self.failures = failures
        self.blocked = blocked
        self.message = message
    }

    var succeeded: Bool { failures.isEmpty && blocked.isEmpty && !appliedDisplayIDs.isEmpty }
}

/// Result of extending the current automatic target to displays that appeared
/// after the consent-time assignment. `updatedDisplayIDs` is empty when every
/// connected, non-protected display already has an assignment.
struct WallpaperAutoTargetAdoption: Sendable {
    let updatedDisplayIDs: [DesktopDisplayID]
    let outcome: WallpaperAutoOutcome
}

/// Pure topology planner shared by the integration adapter and tests.
enum WallpaperAutoTargetTopology {
    /// Connected displays that have no persisted assignment yet. An existing
    /// assignment may be a user's deliberate historical wallpaper choice and
    /// must never be overwritten by implicit topology adoption. Manually
    /// protected displays are also excluded.
    static func displayIDsNeedingTarget(
        connectedDisplayIDs: [DesktopDisplayID],
        assignedDisplayIDs: Set<DesktopDisplayID>,
        manuallyProtectedDisplayIDs: Set<DesktopDisplayID>
    ) -> [DesktopDisplayID] {
        var seen: Set<DesktopDisplayID> = []
        var result: [DesktopDisplayID] = []
        for displayID in connectedDisplayIDs {
            guard seen.insert(displayID).inserted,
                  !manuallyProtectedDisplayIDs.contains(displayID),
                  !assignedDisplayIDs.contains(displayID)
            else {
                continue
            }
            result.append(displayID)
        }
        return result
    }
}

struct WallpaperAutoOutcome: Sendable {
    /// True only when automatic mode is persisted AND the write gate is open.
    /// A revoked gate is the authoritative fail-closed state even if a settings
    /// write failed after the gate was closed.
    let enabled: Bool
    /// The separate automatic-overwrite consent. It never implies `enabled`.
    let automaticOverwriteEnabled: Bool
    let message: String
    let blockedReason: String?
    let error: String?
    /// True when the current session is fail-closed but the on-disk mode may
    /// still be automatic, so the user should retry the disable operation.
    let requiresDisableRetry: Bool
    /// True only after the integration confirmed that the desired automatic
    /// target was persisted. A failed update must never be followed by a
    /// reconciliation pass: that would apply the previous target while the UI
    /// reports a failure.
    let targetUpdated: Bool

    init(
        enabled: Bool,
        automaticOverwriteEnabled: Bool = false,
        message: String,
        blockedReason: String?,
        error: String?,
        requiresDisableRetry: Bool,
        targetUpdated: Bool
    ) {
        self.enabled = enabled
        self.automaticOverwriteEnabled = automaticOverwriteEnabled
        self.message = message
        self.blockedReason = blockedReason
        self.error = error
        self.requiresDisableRetry = requiresDisableRetry
        self.targetUpdated = targetUpdated
    }
}

enum WallpaperAutomationTruth {
    /// The UI must only claim automatic writes are active when both the mode
    /// and the write gate agree. This mirrors the integration's fail-closed
    /// contract and keeps a failed settings write from looking successful.
    static func isEnabled(automatic: Bool, writeAuthorized: Bool) -> Bool {
        automatic && writeAuthorized
    }
}

enum WallpaperIntegrationError: Error, LocalizedError, Sendable {
    case noConnectedDisplays
    case selectedDisplayUnavailable
    case consentExpired
    case inconsistentConsent
    case staleGuardBlock
    case confirmationUnavailable
    case automationRollbackFailed(String)
    /// A module error already mapped to the app's interface language.
    case localized(String)

    var errorDescription: String? {
        switch self {
        case .noConnectedDisplays:
            return MacLocalizedString.resolve("没有可用的已连接显示器。", locale: WallpaperInterfaceLocale.current)
        case .selectedDisplayUnavailable:
            return MacLocalizedString.resolve("所选显示器当前未连接，壁纸没有写入。", locale: WallpaperInterfaceLocale.current)
        case .consentExpired:
            return MacLocalizedString.resolve("这次写入确认已过期，请重新确认。", locale: WallpaperInterfaceLocale.current)
        case .inconsistentConsent:
            return MacLocalizedString.resolve("写入确认不一致，请重新确认。", locale: WallpaperInterfaceLocale.current)
        case .staleGuardBlock:
            return MacLocalizedString.resolve("该显示器的等待确认状态已失效，请刷新后重试。", locale: WallpaperInterfaceLocale.current)
        case .confirmationUnavailable:
            return MacLocalizedString.resolve("系统没有返回当前壁纸，无法按图片确认覆盖。", locale: WallpaperInterfaceLocale.current)
        case .automationRollbackFailed(let detail):
            return detail
        case .localized(let message):
            return message
        }
    }
}

// MARK: - Protocol

@MainActor
protocol MacWallpaperIntegrating: AnyObject {
    var onStatusChange: (@MainActor () -> Void)? { get set }

    /// Connects the shared repository before any wallpaper write can run.
    func setApplicationProtection(_ protection: any WallpaperApplicationProtecting) async
    /// Reads the live screen topology. May publish an integration snapshot.
    func connectedDisplays() async -> [DesktopDisplayOption]
    /// Displays from the most recent integration snapshot without triggering
    /// another system read or snapshot publication. Snapshot-change callbacks
    /// must use this instead of `connectedDisplays()` to avoid a refresh loop.
    func snapshotDisplays() async -> [DesktopDisplayOption]
    /// Last successfully written wallpaper URL per display. Only successful
    /// backend writes update this map; failed or blocked writes leave it intact.
    func appliedWallpaperURLs() async -> [DesktopDisplayID: URL]
    /// Publicly readable current wallpaper URLs for connected displays. Used
    /// to keep only currently accessible desktops protected; unreadable
    /// displays are omitted.
    func currentWallpaperURLs() async -> [DesktopDisplayID: URL]
    /// Reads the persisted state at launch. An explicit auto-sync opt-in is
    /// resumed; invalid settings fail closed as read-only.
    func resumeAutomation() async -> WallpaperAutoOutcome
    /// One explicit confirmation was shown. Generates the internal preflight
    /// token and writes exactly one accessible desktop.
    func applyManually(
        imageURL: URL,
        displayID: DesktopDisplayID?
    ) async throws -> WallpaperApplyOutcome
    /// One explicit confirmation was shown. Persists auto sync for future
    /// launches, stores today's target, and requests one immediate
    /// reconciliation of the currently accessible desktops. That pass still
    /// obeys the separate overwrite consent and manual protection.
    func enableAutoSync(imageURL: URL) async throws -> WallpaperApplyOutcome
    /// Separate default-off automatic-overwrite consent. Never writes.
    func setAutomaticOverwrite(_ enabled: Bool) async -> WallpaperAutoOutcome
    func disableAutoSync() async -> WallpaperAutoOutcome
    func automationStatus() async -> WallpaperAutoOutcome
    /// Persists today's automatic target for connected displays and for every
    /// existing automatic assignment, including displays that are currently
    /// disconnected. Manual assignments and assignments migrated without
    /// provenance are preserved. Never writes a wallpaper.
    func updateAutoTarget(imageURL: URL) async -> WallpaperAutoOutcome
    /// Requests an event-driven reconciliation after an automatic target
    /// change. Still subject to mode, overwrite consent and manual protection.
    /// Returns only currently accessible displays the backend confirmed
    /// settled on `expectedImageURL`; a configuration write alone returns [].
    func requestReconciliation(
        expectedImageURL: URL
    ) async -> [DesktopDisplayID]
    /// Persists the current authorized target only for connected displays
    /// that have no assignment yet. Never replaces an existing assignment
    /// (which may be an explicit historical wallpaper), never writes
    /// instantly, and never re-targets a manually protected display. The
    /// subsequent reconciliation remains subject to the overwrite policy for
    /// unknown wallpapers.
    func adoptAutoTargetForConnectedDisplays(
        imageURL: URL
    ) async -> WallpaperAutoTargetAdoption
    func guardBlocks() async -> [WallpaperGuardInfo]
    func confirmOverwrite(
        displayID: DesktopDisplayID,
        observedImageURL: URL?
    ) async throws -> WallpaperApplyOutcome
}

extension MacWallpaperIntegrating {
    /// Test doubles and lightweight adapters may not maintain a separate
    /// snapshot; reading the live list is an acceptable fallback for them.
    func snapshotDisplays() async -> [DesktopDisplayOption] {
        await connectedDisplays()
    }
}

// MARK: - Adapter

/// Thin app-side wrapper over `MacDesktopIntegration`.
///
/// All write authority stays inside the integration's preflight + write gate.
/// This wrapper never writes wallpaper from initialization, display listing,
/// refresh, or target updates.
@MainActor
final class MacWallpaperController: MacWallpaperIntegrating {
    var onStatusChange: (@MainActor () -> Void)?

    private let integration: MacDesktopIntegration
    private var started = false

    init() {
        integration = MacDesktopIntegration()
        integration.onSnapshotChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onStatusChange?()
            }
        }
    }

    func setApplicationProtection(
        _ protection: any WallpaperApplicationProtecting
    ) async {
        await integration.setWallpaperProtection(protection)
    }

    func connectedDisplays() async -> [DesktopDisplayOption] {
        await startIfNeeded()
        await integration.refresh()
        return displayOptions(from: integration.snapshot.displays)
    }

    func snapshotDisplays() async -> [DesktopDisplayOption] {
        await startIfNeeded()
        return displayOptions(from: integration.snapshot.displays)
    }

    private func displayOptions(
        from displays: [MacDisplayInfo]
    ) -> [DesktopDisplayOption] {
        var seen: Set<DesktopDisplayID> = []
        return displays
            .sorted { $0.isMain && !$1.isMain }
            .compactMap { display in
                // A fallback identity can theoretically collide when two
                // displays expose identical public metadata. Keep the list
                // usable instead of producing duplicate SwiftUI IDs.
                guard seen.insert(display.displayID).inserted else { return nil }
                return DesktopDisplayOption(
                    id: display.displayID,
                    name: display.localizedName
                )
            }
    }

    func appliedWallpaperURLs() async -> [DesktopDisplayID: URL] {
        await startIfNeeded()
        return integration.snapshot.appliedWallpaperURLsByDisplay
    }

    func currentWallpaperURLs() async -> [DesktopDisplayID: URL] {
        await startIfNeeded()
        // Read the existing published snapshot. Calling `refresh()` here would
        // publish another snapshot from inside the status-change callback and
        // recurse into applied-protection reconciliation. Startup refreshes the
        // topology in `prepareDisplays()` before protection is reconciled.
        //
        // A display whose just-confirmed write has not been observed yet is
        // omitted: its `currentImageURL` may still describe the pre-write
        // desktop, so callers must fall back to the confirmed applied URL
        // instead of releasing the live protection.
        let awaitingObservation = integration.snapshot.displaysAwaitingWriteObservation
        var result: [DesktopDisplayID: URL] = [:]
        for display in integration.snapshot.displays
        where !awaitingObservation.contains(display.displayID) {
            if let url = display.currentImageURL {
                result[display.displayID] = url
            }
        }
        return result
    }

    func resumeAutomation() async -> WallpaperAutoOutcome {
        await startIfNeeded()
        await integration.refresh()
        return statusOutcome(
            from: integration.snapshot,
            message: ""
        )
    }

    func applyManually(
        imageURL: URL,
        displayID: DesktopDisplayID?
    ) async throws -> WallpaperApplyOutcome {
        await startIfNeeded()
        await integration.refresh()

        let displays = integration.snapshot.displays
        guard !displays.isEmpty else {
            throw WallpaperIntegrationError.noConnectedDisplays
        }
        let target: MacDisplayInfo
        if let displayID {
            guard let matched = displays.first(where: { $0.displayID == displayID }) else {
                throw WallpaperIntegrationError.selectedDisplayUnavailable
            }
            target = matched
        } else if let main = displays.first(where: { $0.isMain }) ?? displays.first {
            target = main
        } else {
            throw WallpaperIntegrationError.noConnectedDisplays
        }

        let wallpaper = DesktopWallpaper(imageURL: imageURL, scaling: .fill)
        let preflight = try await localized {
            try await integration.prepareWallpaperWrite()
        }
        let consent = MacWallpaperWriteConsent(preflight: preflight)
        let report = try await localized {
            try await integration.applyOnce(
                [target.displayID: wallpaper],
                consent: consent
            )
        }
        return outcome(
            from: report,
            successMessage: MacLocalizedString.resolve("已更新所选显示器的当前桌面壁纸。", locale: WallpaperInterfaceLocale.current)
        )
    }

    func enableAutoSync(imageURL: URL) async throws -> WallpaperApplyOutcome {
        await startIfNeeded()
        await integration.refresh()
        let locale = WallpaperInterfaceLocale.current

        let displays = integration.snapshot.displays
        guard !displays.isEmpty else {
            throw WallpaperIntegrationError.noConnectedDisplays
        }
        let wallpaper = DesktopWallpaper(imageURL: imageURL, scaling: .fill)
        let preflight = try await localized {
            try await integration.prepareWallpaperWrite()
        }
        let consent = MacWallpaperWriteConsent(preflight: preflight)
        try await localized {
            try await integration.setAutomationEnabled(true, consent: consent)
        }
        do {
            // The opt-in confirmation named every connected display. Convert
            // their targets to automatic and retarget any automatic assignment
            // left behind by an earlier session, including disconnected
            // displays. Manual targets for displays that are not part of this
            // consent remain manual.
            try await integration.setAutomaticTarget(
                wallpaper,
                connectedDisplayIDs: displays.map(\.displayID),
                replacingAssignedConnectedDisplays: true
            )
        } catch {
            var message = MacLocalizedString.resolve("自动同步目标保存失败：\(Self.describe(error))", locale: locale)
            do {
                try await integration.setAutomationEnabled(false, consent: nil)
            } catch {
                message += MacLocalizedString.resolve("；撤销自动同步失败：\(Self.describe(error))", locale: locale)
            }
            throw WallpaperIntegrationError.automationRollbackFailed(message)
        }
        await integration.refresh()
        // Persisting a target is configuration only. Run the existing
        // coordinator once so the opt-in takes effect on the currently
        // accessible desktops instead of waiting for the next Space switch.
        // This pass still obeys automatic-overwrite consent and manual
        // protection; it never widens the write authorization.
        await integration.requestReconciliation()
        await integration.refresh()

        let updated = integration.snapshot
        let report = updated.coordinatorState?.lastReport
        let applied = report?.appliedDisplayIDs ?? []
        let synchronized = report?.outcomes.compactMap { outcome -> DesktopDisplayID? in
            switch outcome.action {
            case .applied, .alreadySynchronized:
                return outcome.displayID
            case .manualProtectionDetected, .alreadyProtected, .unassigned,
                 .disconnected, .deferredRetry, .failed:
                return nil
            }
        } ?? []
        return WallpaperApplyOutcome(
            appliedDisplayIDs: applied,
            synchronizedDisplayIDs: synchronized,
            failures: failureMessages(from: report, in: updated),
            blocked: guardBlocks(from: updated),
            message: MacLocalizedString.resolve("自动同步已开启，并会在重新启动后继续。已立即检查当前可访问的桌面，并按写入策略应用目标；遇到未知壁纸或手动保护时会暂停并等待确认。之后的内容更新、Space 切换、显示器变化、唤醒，或鼠标进入另一台显示器时会继续检查。未激活的 Space 不会立即更新。", locale: locale)
        )
    }

    func setAutomaticOverwrite(_ enabled: Bool) async -> WallpaperAutoOutcome {
        await startIfNeeded()
        let locale = WallpaperInterfaceLocale.current
        var errors: [String] = []
        do {
            try await integration.setAutomaticOverwriteEnabled(enabled)
        } catch {
            errors.append(MacLocalizedString.resolve("无法保存自动覆盖设置：\(Self.describe(error))", locale: locale))
        }
        await integration.refresh()
        let snapshot = integration.snapshot
        let message: String
        if snapshot.automaticOverwriteEnabled {
            message = MacLocalizedString.resolve("自动覆盖已开启。自动同步运行时，遇到未知壁纸也会替换当前可访问的桌面，不再逐台确认；手动保护的显示器仍会保留。", locale: locale)
        } else {
            message = MacLocalizedString.resolve("自动覆盖已关闭。遇到未知壁纸时会暂停，并等待你按显示器确认。", locale: locale)
        }
        let next = statusOutcome(from: snapshot, message: message)
        if errors.isEmpty {
            return next
        }
        return WallpaperAutoOutcome(
            enabled: next.enabled,
            automaticOverwriteEnabled: next.automaticOverwriteEnabled,
            message: message,
            blockedReason: nil,
            error: errors.joined(separator: "\n"),
            requiresDisableRetry: next.requiresDisableRetry,
            targetUpdated: false
        )
    }

    func disableAutoSync() async -> WallpaperAutoOutcome {
        await startIfNeeded()
        let locale = WallpaperInterfaceLocale.current
        var errors: [String] = []
        var disableFailed = false
        var cleanupFailed = false

        do {
            try await integration.setAutomationEnabled(false, consent: nil)
        } catch {
            disableFailed = true
            errors.append(MacLocalizedString.resolve("关闭自动同步失败：\(Self.describe(error))", locale: locale))
        }

        do {
            try await integration.clearDesiredAssignments()
        } catch {
            cleanupFailed = true
            errors.append(MacLocalizedString.resolve("清理自动目标失败：\(Self.describe(error))", locale: locale))
        }

        await integration.refresh()
        let snapshot = integration.snapshot
        let enabled = WallpaperAutomationTruth.isEnabled(
            automatic: snapshot.automationMode == .automatic,
            writeAuthorized: snapshot.writeAccess == .authorized
        )
        let writeOpen = snapshot.writeAccess != .readOnly
        if writeOpen {
            errors.append(MacLocalizedString.resolve("自动写入可能仍在生效，请重试关闭自动同步。", locale: locale))
        }
        if let issue = Self.describe(snapshot.lastIssue),
           !errors.contains(issue) {
            errors.append(issue)
        }

        let message: String
        if enabled || writeOpen {
            message = MacLocalizedString.resolve("未能确认自动同步已关闭；开关和错误信息显示的是当前状态。", locale: locale)
        } else if disableFailed {
            message = MacLocalizedString.resolve("本次会话已停止自动写入，但保存的设置可能仍为自动同步；重新启动后可能恢复，请重试关闭。", locale: locale)
        } else if cleanupFailed {
            message = MacLocalizedString.resolve("自动同步已关闭；清理旧目标失败，下次开启时会重新设置。", locale: locale)
        } else {
            message = MacLocalizedString.resolve("自动同步已关闭；不会继续修改壁纸。", locale: locale)
        }
        return WallpaperAutoOutcome(
            enabled: enabled,
            automaticOverwriteEnabled: snapshot.automaticOverwriteEnabled,
            message: message,
            blockedReason: nil,
            error: errors.isEmpty ? nil : errors.joined(separator: "\n"),
            requiresDisableRetry: disableFailed || writeOpen,
            targetUpdated: false
        )
    }

    func automationStatus() async -> WallpaperAutoOutcome {
        await startIfNeeded()
        return statusOutcome(from: integration.snapshot, message: "")
    }

    func updateAutoTarget(imageURL: URL) async -> WallpaperAutoOutcome {
        await startIfNeeded()
        let locale = WallpaperInterfaceLocale.current
        let snapshot = integration.snapshot
        let enabled = WallpaperAutomationTruth.isEnabled(
            automatic: snapshot.automationMode == .automatic,
            writeAuthorized: snapshot.writeAccess == .authorized
        )
        guard enabled else {
            return WallpaperAutoOutcome(
                enabled: false,
                automaticOverwriteEnabled: snapshot.automaticOverwriteEnabled,
                message: snapshot.automationMode == .automatic
                    ? MacLocalizedString.resolve("自动同步没有生效：当前无法写入壁纸。", locale: locale)
                    : MacLocalizedString.resolve("自动同步未开启，仅保留手动应用。", locale: locale),
                blockedReason: nil,
                error: Self.describe(snapshot.lastIssue),
                requiresDisableRetry: false,
                targetUpdated: false
            )
        }
        let wallpaper = DesktopWallpaper(imageURL: imageURL, scaling: .fill)
        do {
            // Connected displays are joined or retargeted; every existing
            // automatic assignment, including one for a disconnected display,
            // receives the same target. Manual and pre-provenance assignments
            // are preserved, so a reconnect cannot restore yesterday's
            // automatic image or overwrite a user's manual choice.
            try await integration.setAutomaticTarget(
                wallpaper,
                connectedDisplayIDs: snapshot.displays.map(\.displayID)
            )
            let updated = integration.snapshot
            var message = MacLocalizedString.resolve("自动同步目标已更新；已断开的自动目标也会在重新接入时使用新图。将在下次 Space 切换、显示器变化、唤醒，或鼠标进入另一台显示器时应用。", locale: locale)
            let legacyDisplayIDs = updated.legacyAssignmentDisplayIDs
            let manualPreservedCount = updated.assignments
                .filter { $0.source == .manual }
                .count
            if !legacyDisplayIDs.isEmpty {
                message += " " + MacLocalizedString.resolve(
                    "\(legacyDisplayIDs.count) 台显示器保留迁移前目标，自动同步不会更新它们；重新开启自动同步后可纳入。",
                    locale: locale
                )
            }
            if manualPreservedCount > 0 {
                message += " " + MacLocalizedString.resolve(
                    "\(manualPreservedCount) 台显示器保留手动目标。",
                    locale: locale
                )
            }
            if updated.assignments.isEmpty, snapshot.displays.isEmpty {
                message += " " + MacLocalizedString.resolve(
                    "当前没有连接的显示器。",
                    locale: locale
                )
            }
            return WallpaperAutoOutcome(
                enabled: WallpaperAutomationTruth.isEnabled(
                    automatic: updated.automationMode == .automatic,
                    writeAuthorized: updated.writeAccess == .authorized
                ),
                automaticOverwriteEnabled: updated.automaticOverwriteEnabled,
                message: message,
                blockedReason: nil,
                error: Self.describe(updated.lastIssue),
                requiresDisableRetry: false,
                targetUpdated: true
            )
        } catch {
            let updated = integration.snapshot
            return WallpaperAutoOutcome(
                enabled: WallpaperAutomationTruth.isEnabled(
                    automatic: updated.automationMode == .automatic,
                    writeAuthorized: updated.writeAccess == .authorized
                ),
                automaticOverwriteEnabled: updated.automaticOverwriteEnabled,
                message: MacLocalizedString.resolve("自动同步目标保存失败。", locale: locale),
                blockedReason: nil,
                error: Self.describe(error),
                requiresDisableRetry: false,
                targetUpdated: false
            )
        }
    }

    func requestReconciliation(
        expectedImageURL: URL
    ) async -> [DesktopDisplayID] {
        await startIfNeeded()
        await integration.requestReconciliation()
        guard let state = integration.snapshot.coordinatorState,
              let report = state.lastReport
        else {
            return []
        }
        // A notification describes the whole automatic update. If any
        // accessible target failed or remained protected in this pass, do not
        // claim the image was settled; a later pass may try again.
        let hasBlockingOutcome = report.outcomes.contains { outcome in
            switch outcome.action {
            case .failed, .deferredRetry, .manualProtectionDetected, .alreadyProtected:
                return true
            case .applied, .alreadySynchronized, .unassigned, .disconnected:
                return false
            }
        }
        guard !hasBlockingOutcome else { return [] }
        let live = Dictionary(
            state.displays.map { ($0.displayID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return report.outcomes.compactMap { outcome in
            switch outcome.action {
            case .applied, .alreadySynchronized:
                break
            case .manualProtectionDetected, .alreadyProtected, .unassigned,
                 .disconnected, .deferredRetry, .failed:
                return nil
            }
            // A report alone can be stale or belong to an older target. The
            // live coordinator state must still show this exact target as a
            // connected, synchronized display.
            guard let display = live[outcome.displayID],
                  display.isConnected,
                  display.desiredWallpaper?.imageURL == expectedImageURL,
                  display.status == .synchronized
            else {
                return nil
            }
            return outcome.displayID
        }
    }

    func adoptAutoTargetForConnectedDisplays(
        imageURL: URL
    ) async -> WallpaperAutoTargetAdoption {
        await startIfNeeded()
        let snapshot = integration.snapshot
        guard WallpaperAutomationTruth.isEnabled(
            automatic: snapshot.automationMode == .automatic,
            writeAuthorized: snapshot.writeAccess == .authorized
        ) else {
            return WallpaperAutoTargetAdoption(
                updatedDisplayIDs: [],
                outcome: statusOutcome(from: snapshot, message: "")
            )
        }

        let assignedDisplayIDs = Set(snapshot.assignments.map(\.displayID))
        // A display that the coordinator is currently protecting may not be
        // persisted in settings yet; never re-target it implicitly.
        var protectedDisplayIDs = Set(
            snapshot.manualProtections.map(\.displayID)
        )
        if let coordinator = snapshot.coordinatorState {
            for display in coordinator.displays where display.manualProtection != nil {
                protectedDisplayIDs.insert(display.displayID)
            }
            for display in coordinator.displays where display.status == .manualProtection {
                protectedDisplayIDs.insert(display.displayID)
            }
        }

        let needingDisplayIDs = WallpaperAutoTargetTopology.displayIDsNeedingTarget(
            connectedDisplayIDs: snapshot.displays.map(\.displayID),
            assignedDisplayIDs: assignedDisplayIDs,
            manuallyProtectedDisplayIDs: protectedDisplayIDs
        )
        guard !needingDisplayIDs.isEmpty else {
            return WallpaperAutoTargetAdoption(
                updatedDisplayIDs: [],
                outcome: statusOutcome(from: snapshot, message: "")
            )
        }

        let wallpaper = DesktopWallpaper(imageURL: imageURL, scaling: .fill)
        let targets = Dictionary(
            needingDisplayIDs.map { ($0, wallpaper) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            // Intent only. Unknown external wallpapers and manual protections
            // are still enforced by the coordinator/applier during the pass.
            // Existing assignments (including manual or pre-provenance ones)
            // stay untouched; only the newly connected, unprotected displays
            // are added.
            try await integration.setDesiredAssignments(targets)
        } catch {
            let base = statusOutcome(from: integration.snapshot, message: "")
            return WallpaperAutoTargetAdoption(
                updatedDisplayIDs: [],
                outcome: WallpaperAutoOutcome(
                    enabled: base.enabled,
                    automaticOverwriteEnabled: base.automaticOverwriteEnabled,
                    message: "",
                    blockedReason: nil,
                    error: Self.describe(error),
                    requiresDisableRetry: base.requiresDisableRetry,
                    targetUpdated: false
                )
            )
        }

        let updated = integration.snapshot
        return WallpaperAutoTargetAdoption(
            updatedDisplayIDs: needingDisplayIDs,
            outcome: statusOutcome(from: updated, message: "")
        )
    }

    func guardBlocks() async -> [WallpaperGuardInfo] {
        await startIfNeeded()
        return guardBlocks(from: integration.snapshot)
    }

    func confirmOverwrite(
        displayID: DesktopDisplayID,
        observedImageURL: URL?
    ) async throws -> WallpaperApplyOutcome {
        await startIfNeeded()
        guard let block = integration.snapshot.guardBlocks.first(where: {
            $0.displayID == displayID
        }) else {
            throw WallpaperIntegrationError.staleGuardBlock
        }
        guard block.observedImageURL == observedImageURL else {
            throw WallpaperIntegrationError.staleGuardBlock
        }
        guard block.canConfirm else {
            throw WallpaperIntegrationError.confirmationUnavailable
        }
        let report = try await localized {
            try await integration.confirmOverwrite(block.confirmationRequest)
        }
        return outcome(
            from: report,
            successMessage: MacLocalizedString.resolve("已按确认覆盖当前壁纸。", locale: WallpaperInterfaceLocale.current)
        )
    }

    // MARK: Internals

    private func startIfNeeded() async {
        guard !started else { return }
        await integration.start()
        started = true
    }

    private func statusOutcome(
        from snapshot: MacDesktopSnapshot,
        message: String
    ) -> WallpaperAutoOutcome {
        let enabled = WallpaperAutomationTruth.isEnabled(
            automatic: snapshot.automationMode == .automatic,
            writeAuthorized: snapshot.writeAccess == .authorized
        )
        var resolvedMessage = message
        let legacyDisplayIDs = snapshot.legacyAssignmentDisplayIDs
        if enabled, !legacyDisplayIDs.isEmpty {
            let warning = MacLocalizedString.resolve("\(legacyDisplayIDs.count) 台显示器使用迁移前的目标，自动同步不会更新它们；如需纳入，请关闭后重新开启自动同步。", locale: WallpaperInterfaceLocale.current)
            resolvedMessage = resolvedMessage.isEmpty
                ? warning
                : resolvedMessage + " " + warning
        }
        return WallpaperAutoOutcome(
            enabled: enabled,
            automaticOverwriteEnabled: snapshot.automaticOverwriteEnabled,
            message: resolvedMessage,
            blockedReason: nil,
            error: Self.describe(snapshot.lastIssue),
            // A persisted automatic mode whose gate is closed must be fixed by
            // the user; silently trusting it would hide a fail-closed state.
            requiresDisableRetry: snapshot.automationMode == .automatic && !enabled,
            targetUpdated: false
        )
    }

    private func guardBlocks(from snapshot: MacDesktopSnapshot) -> [WallpaperGuardInfo] {
        snapshot.guardBlocks.map { block in
            WallpaperGuardInfo(
                displayID: block.displayID,
                displayName: displayName(for: block.displayID, in: snapshot),
                reason: Self.describe(block.reason),
                observedImageURL: block.observedImageURL,
                desiredImageURL: block.desiredWallpaper.imageURL
            )
        }
    }

    private func displayName(for displayID: DesktopDisplayID, in snapshot: MacDesktopSnapshot) -> String {
        let name = snapshot.displays.first { $0.displayID == displayID }?.localizedName ?? ""
        return name.isEmpty
            ? MacLocalizedString.resolve("未命名显示器", locale: WallpaperInterfaceLocale.current)
            : name
    }

    private func outcome(from report: MacDesktopApplyReport, successMessage: String) -> WallpaperApplyOutcome {
        let locale = WallpaperInterfaceLocale.current
        let snapshot = integration.snapshot
        let reconcile = report.reconcileReport
        let applied = reconcile?.appliedDisplayIDs ?? []
        let synchronized = reconcile?.outcomes.compactMap { outcome -> DesktopDisplayID? in
            switch outcome.action {
            case .applied, .alreadySynchronized:
                return outcome.displayID
            case .manualProtectionDetected, .alreadyProtected, .unassigned,
                 .disconnected, .deferredRetry, .failed:
                return nil
            }
        } ?? []
        let failures = failureMessages(from: reconcile, in: snapshot)
        let blocked = report.blocked.map { block in
            WallpaperGuardInfo(
                displayID: block.displayID,
                displayName: displayName(for: block.displayID, in: snapshot),
                reason: Self.describe(block.reason),
                observedImageURL: block.observedImageURL,
                desiredImageURL: block.desiredWallpaper.imageURL
            )
        }
        let message: String
        if !applied.isEmpty {
            message = successMessage
        } else if !blocked.isEmpty {
            message = MacLocalizedString.resolve("写入已暂停，没有覆盖任何未知壁纸。", locale: locale)
        } else {
            message = MacLocalizedString.resolve("没有显示器需要修改。", locale: locale)
        }
        return WallpaperApplyOutcome(
            appliedDisplayIDs: applied,
            synchronizedDisplayIDs: synchronized,
            failures: failures,
            blocked: blocked,
            message: message
        )
    }

    private func failureMessages(
        from report: DesktopReconcileReport?,
        in snapshot: MacDesktopSnapshot
    ) -> [String] {
        report?.outcomes.compactMap { outcome -> String? in
            guard let failure = outcome.failure else { return nil }
            return String(
                format: MacLocalizedString.resolve("%@：%@", locale: WallpaperInterfaceLocale.current),
                displayName(for: outcome.displayID, in: snapshot),
                Self.describe(failure)
            )
        } ?? []
    }

    /// Runs a module call and converts any escaping integration error into
    /// app copy. `AppModel` reads `LocalizedError.errorDescription`, so a raw
    /// module error must never cross this boundary untranslated.
    private func localized<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw WallpaperIntegrationError.localized(Self.describe(error))
        }
    }

    private static func describe(_ reason: MacOverwriteBlockReason) -> String {
        let locale = WallpaperInterfaceLocale.current
        switch reason {
        case .unverifiedExternalWallpaper:
            return MacLocalizedString.resolve("当前壁纸不是 Daybreak 设置的，或尚未确认要覆盖；已暂停。", locale: locale)
        case .unreadableCurrentWallpaper:
            return MacLocalizedString.resolve("系统没有返回当前壁纸，无法确认这次覆盖；已暂停。", locale: locale)
        case .manualProtection:
            return MacLocalizedString.resolve("这台显示器的当前壁纸已设为手动保护；已暂停。", locale: locale)
        }
    }

    private static func describe(_ error: Error) -> String {
        let locale = WallpaperInterfaceLocale.current
        if let applyError = error as? MacDesktopApplyError {
            switch applyError {
            case .notRunning:
                return MacLocalizedString.resolve("桌面集成尚未启动，壁纸没有写入。", locale: locale)
            case .writePreflightRequired:
                return MacLocalizedString.resolve("写入壁纸前需要先完成一次确认。", locale: locale)
            case .preflightExpired:
                return MacLocalizedString.resolve("这次写入确认已过期，或桌面变化使其失效；请重新确认。", locale: locale)
            case .preflightMismatch:
                return MacLocalizedString.resolve("确认后显示器、壁纸或桌面设置发生了变化；请重新确认。", locale: locale)
            case .noPendingPreflight:
                return MacLocalizedString.resolve("这次写入确认尚未准备好，请重试。", locale: locale)
            case .unknownDisplay:
                return MacLocalizedString.resolve("所选显示器当前未连接。", locale: locale)
            case .persistenceFailed(let reason):
                return MacLocalizedString.resolve("桌面设置未能保存，本次更改可能不会保留：\(reason)", locale: locale)
            }
        }
        if error is MacWallpaperProtectionError {
            return MacLocalizedString.resolve("壁纸缓存保护尚未准备好，写入已暂停。", locale: locale)
        }
        if let failure = error as? DesktopFailure {
            return describe(failure)
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func describe(_ failure: DesktopFailure) -> String {
        let locale = WallpaperInterfaceLocale.current
        switch failure.kind {
        case .displayUnavailable:
            return MacLocalizedString.resolve("显示器已断开，壁纸没有写入。", locale: locale)
        case .imageUnreadable:
            return MacLocalizedString.resolve("无法安全写入：图片无法读取，或不再是受保护的图库原图。", locale: locale)
        case .unsupportedImageFormat:
            return MacLocalizedString.resolve("壁纸图片格式无法读取，没有写入。", locale: locale)
        case .permissionDenied:
            // The exact refusal reason is shown from the structured guard
            // block; this line must only preserve the fail-closed outcome.
            return MacLocalizedString.resolve("写入已暂停，现有壁纸没有被修改。", locale: locale)
        case .systemBusy:
            return MacLocalizedString.resolve("系统正忙，壁纸没有写入。", locale: locale)
        case .timedOut:
            return MacLocalizedString.resolve("系统没有及时响应，壁纸没有写入。", locale: locale)
        case .ioFailure:
            return MacLocalizedString.resolve("壁纸写入未能完成，现有壁纸没有被修改。", locale: locale)
        case .unknown:
            guard !failure.message.isEmpty else {
                return MacLocalizedString.resolve("壁纸写入未能完成，现有壁纸没有被修改。", locale: locale)
            }
            return MacLocalizedString.resolve("壁纸写入失败：\(failure.message)", locale: locale)
        }
    }

    private static func describe(_ issue: MacDesktopSettingsIssue?) -> String? {
        guard let issue else { return nil }
        let locale = WallpaperInterfaceLocale.current
        switch issue.kind {
        case .unsupportedSchemaVersion:
            if let version = issue.schemaVersion {
                return MacLocalizedString.resolve("桌面设置版本（\(version)）不受支持，已使用默认设置。", locale: locale)
            }
            return MacLocalizedString.resolve("桌面设置版本不受支持，已使用默认设置。", locale: locale)
        case .unreadable:
            if let detail = issue.detail, !detail.isEmpty {
                return MacLocalizedString.resolve("桌面设置无法读取，已使用默认设置：\(detail)", locale: locale)
            }
            return MacLocalizedString.resolve("无法读取桌面设置，已使用默认设置。", locale: locale)
        case .saveFailed:
            if let detail = issue.detail, !detail.isEmpty {
                return MacLocalizedString.resolve("桌面设置未能保存，本次更改可能不会保留：\(detail)", locale: locale)
            }
            return MacLocalizedString.resolve("桌面设置未能保存，本次更改可能不会保留。", locale: locale)
        }
    }
}
