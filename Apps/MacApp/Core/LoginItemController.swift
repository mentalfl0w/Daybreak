import Foundation
import Observation
import ServiceManagement
import os

/// The login-item states the settings UI can explain truthfully.
///
/// `SMAppService.Status.notFound` means ServiceManagement hit an error and
/// couldn't find the service. It is not evidence that this build cannot
/// support a login item, so it stays a distinct error state instead of being
/// presented as "unsupported".
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown
        }
    }

    /// Stable diagnostic label. Never user-facing copy.
    var logLabel: String {
        switch self {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        case .unknown: return "unknown"
        }
    }
}

/// Testable seam over the public `SMAppService` login-item API. Only the main
/// application is ever addressed.
@MainActor
protocol LoginItemServicing: AnyObject {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

@MainActor
final class SystemLoginItemService: LoginItemServicing {
    func status() -> LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The durable in-app decision about starting Daybreak at login.
///
/// A decline is remembered independently of ServiceManagement so that a
/// failed or unavailable system registration can never turn an explicit
/// "no" into a repeated startup prompt.
enum LoginItemConsentChoice: String, Equatable, Sendable {
    case enabled
    case declined
}

/// Stores the consent decision in app-private defaults. Settings remains the
/// explicit way for the user to change their mind at any time.
struct LoginItemConsentPreferences {
    static let choiceKey = "daybreak.loginItemConsentChoice.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var choice: LoginItemConsentChoice? {
        get {
            guard let raw = defaults.string(forKey: Self.choiceKey) else {
                return nil
            }
            return LoginItemConsentChoice(rawValue: raw)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.choiceKey)
            } else {
                defaults.removeObject(forKey: Self.choiceKey)
            }
        }
    }
}

/// Presentation state for the one startup consent sheet. Nil means no sheet.
enum LoginItemConsentPhase: Equatable, Sendable {
    case asking
    case awaitingApproval
    case failed

    /// Stable diagnostic label. Never user-facing copy.
    var logLabel: String {
        switch self {
        case .asking: return "asking"
        case .awaitingApproval: return "awaitingApproval"
        case .failed: return "failed"
        }
    }
}

/// Registers the app itself as a login item through the public
/// `SMAppService` API. Nothing is registered until the user turns the toggle
/// on or accepts the startup consent prompt; the controller never adds or
/// modifies any other login item.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var errorMessage: String?
    private(set) var isUpdating = false
    /// Non-nil only while the startup consent sheet should be visible.
    private(set) var consentPhase: LoginItemConsentPhase?

    private let service: any LoginItemServicing
    private let interfaceLocale: @Sendable () -> Locale
    private let preferences: LoginItemConsentPreferences
    /// One automatic prompt per process launch. The durable choice, not this
    /// flag, decides whether a later launch may ask again.
    private var didEvaluateConsentThisLaunch = false

    /// Diagnostics only: login-item states, never account names or paths.
    private static let logger = Logger(
        subsystem: "dev.daybreak.mac",
        category: "LoginItem"
    )

    /// Error identity without its localized description, which can contain
    /// file paths on ServiceManagement failures.
    private static func logDetail(_ error: Error?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    init(
        service: (any LoginItemServicing)? = nil,
        locale: @escaping @Sendable () -> Locale = { WallpaperInterfaceLocale.current },
        defaults: UserDefaults = .standard
    ) {
        self.service = service ?? SystemLoginItemService()
        self.interfaceLocale = locale
        self.preferences = LoginItemConsentPreferences(defaults: defaults)
        refresh()
    }

    /// True only when macOS will actually open Daybreak at login. A
    /// registration waiting for approval is not enabled yet.
    var isEnabled: Bool { status == .enabled }

    /// True only when ServiceManagement confirms a registration the app can
    /// remove, including one that still needs the user's approval.
    /// `.notFound` is an error state and is not treated as either outcome.
    var hasConfirmedRegistration: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool { status == .requiresApproval }

    /// Approval can only be granted in System Settings. Disable the switch in
    /// that state instead of offering a control that would immediately fail
    /// or bounce back; the explicit buttons below still allow approval or
    /// removal.
    var canToggle: Bool { status != .requiresApproval }

    /// `.notFound` and `.unknown` are framework errors, not capability
    /// statements. Offer a fresh read after the app is installed or moved.
    var canRecheck: Bool { status == .notFound || status == .unknown }

    var statusText: String {
        let locale = interfaceLocale()
        switch status {
        case .enabled:
            return MacLocalizedString.resolve("已设为登录时启动", locale: locale)
        case .notRegistered:
            return MacLocalizedString.resolve("未设为登录时启动", locale: locale)
        case .requiresApproval:
            return MacLocalizedString.resolve("需要在系统设置中批准", locale: locale)
        case .notFound:
            return MacLocalizedString.resolve("系统未找到此应用的登录项记录", locale: locale)
        case .unknown:
            return MacLocalizedString.resolve("状态未知", locale: locale)
        }
    }

    /// Explains a ServiceManagement error without claiming that login items
    /// are unsupported. Nil for states that need no extra explanation.
    var recoveryGuidance: String? {
        let locale = interfaceLocale()
        switch status {
        case .notFound:
            return MacLocalizedString.resolve("登录项由 macOS 管理。请确认 Daybreak 位于“应用程序”文件夹并从该副本运行；从构建目录或临时位置运行时，系统可能找不到登录项记录。调整后请重新打开 Daybreak，再重新检测；如果问题持续，请在系统设置的登录项中检查。", locale: locale)
        case .unknown:
            return MacLocalizedString.resolve("系统返回了无法识别的登录项状态。请重新检测；如果问题持续，请在系统设置的登录项中检查。", locale: locale)
        case .notRegistered, .enabled, .requiresApproval:
            return nil
        }
    }

    /// Re-reads the live status. This never registers anything. Clearing the
    /// previous action error keeps a stale failure from contradicting a state
    /// the user has already fixed in System Settings.
    func refresh() {
        errorMessage = nil
        status = service.status()
        Self.logger.debug("refreshed status=\(self.status.logLabel, privacy: .public)")
    }

    // MARK: Startup consent

    /// Decides once per process whether the startup consent sheet may appear.
    ///
    /// The prompt is offered only when nobody has chosen yet and
    /// ServiceManagement reports `.notRegistered` or `.notFound`. `.notFound`
    /// is a framework error, not proof that registration is impossible; the
    /// only truthful way to learn whether this copy can register is to let the
    /// user request it explicitly, and the sheet surfaces a failed attempt
    /// with the real system error and retry. `.unknown` stays conservative
    /// because it exposes no actionable state. A confirmed registration means
    /// the user already enabled the login item somewhere, so it is recorded
    /// as their choice instead of asking again.
    func considerConsentAtLaunch() {
        guard !didEvaluateConsentThisLaunch else { return }
        didEvaluateConsentThisLaunch = true
        guard consentPhase == nil, preferences.choice == nil else {
            Self.logger.debug("launch consent skipped already decided")
            return
        }

        refresh()
        switch status {
        case .notRegistered, .notFound:
            consentPhase = .asking
        case .enabled, .requiresApproval:
            preferences.choice = .enabled
        case .unknown:
            break
        }
        Self.logger.notice(
            "launch consent status=\(self.status.logLabel, privacy: .public) phase=\(self.consentPhase?.logLabel ?? "none", privacy: .public)"
        )
    }

    /// The explicit enable button in the consent sheet. Registration happens
    /// only here, never while the sheet is merely being shown.
    func acceptConsent() {
        guard consentPhase == .asking || consentPhase == .failed, !isUpdating else {
            return
        }
        errorMessage = nil

        // Re-read so a change made in System Settings since the prompt
        // appeared is respected.
        let current = service.status()
        status = current

        if current == .enabled {
            preferences.choice = .enabled
            consentPhase = nil
            Self.logger.notice("consent accept already enabled")
            return
        }
        if current == .requiresApproval {
            // Already registered. Only System Settings can grant approval,
            // so the sheet explains that instead of calling register() again.
            preferences.choice = .enabled
            consentPhase = .awaitingApproval
            Self.logger.notice("consent accept already registered, awaiting approval")
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        var actionError: Error?
        do {
            try service.register()
        } catch {
            actionError = error
        }
        let updated = service.status()
        status = updated
        Self.logger.notice(
            "consent register result status=\(updated.logLabel, privacy: .public) error=\(Self.logDetail(actionError), privacy: .public)"
        )

        if updated == .enabled {
            preferences.choice = .enabled
            consentPhase = nil
            return
        }
        if updated == .requiresApproval {
            // A registration awaiting approval is a real registration even
            // when the call reported kSMErrorLaunchDeniedByUser.
            preferences.choice = .enabled
            consentPhase = .awaitingApproval
            return
        }

        consentPhase = .failed
        let locale = interfaceLocale()
        if let actionError {
            errorMessage = String(
                format: MacLocalizedString.resolve("无法启用登录时启动：%@", locale: locale),
                actionError.localizedDescription
            )
        } else {
            errorMessage = MacLocalizedString.resolve("系统尚未确认登录项更改。请在系统设置的登录项中检查，然后重试。", locale: locale)
        }
    }

    /// Persists an explicit "not now" so no later launch asks again. Settings
    /// can still enable the login item through a deliberate user action.
    func declineConsent() {
        guard consentPhase == .asking || consentPhase == .failed else { return }
        preferences.choice = .declined
        consentPhase = nil
        errorMessage = nil
    }

    /// Closes the sheet without a durable decision, except after a confirmed
    /// registration waiting for approval, where the choice is already stored.
    /// The process-level gate still prevents a second prompt this launch.
    func dismissConsentPrompt() {
        guard consentPhase != nil else { return }
        consentPhase = nil
        errorMessage = nil
    }

    /// The only path that changes the real login item, and only after the
    /// user's explicit toggle or button action.
    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        errorMessage = nil

        // Re-read so a change made in System Settings while the settings pane
        // was open cannot be overwritten by a stale toggle state.
        let current = service.status()
        status = current

        if enabled {
            if current == .enabled {
                preferences.choice = .enabled
                Self.logger.debug("setEnabled(true) already enabled")
                return
            }
            if current == .requiresApproval {
                // Already registered. `register()` would return
                // kSMErrorAlreadyRegistered (or kSMErrorLaunchDeniedByUser)
                // and cannot grant approval; only System Settings can.
                preferences.choice = .enabled
                Self.logger.notice("setEnabled(true) opens login items for approval")
                service.openSystemSettingsLoginItems()
                return
            }
        } else if !hasConfirmedRegistration {
            // Nothing is registered. Never call unregister() for a missing
            // item; ServiceManagement would return kSMErrorJobNotFound.
            Self.logger.debug("setEnabled(false) no confirmed registration, no-op")
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        var actionError: Error?
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            actionError = error
        }

        let updated = service.status()
        status = updated

        let reachedTarget = enabled
            ? (updated == .enabled || updated == .requiresApproval)
            : updated == .notRegistered
        Self.logger.notice(
            "setEnabled(\(enabled, privacy: .public)) before=\(current.logLabel, privacy: .public) after=\(updated.logLabel, privacy: .public) reachedTarget=\(reachedTarget, privacy: .public) error=\(Self.logDetail(actionError), privacy: .public)"
        )

        // A registration that now needs approval is a real registration even
        // if the call reported kSMErrorLaunchDeniedByUser.
        if reachedTarget {
            // An explicit Settings action is also a consent decision: an
            // opt-out must never be undone by a later startup prompt.
            preferences.choice = enabled ? .enabled : .declined
            return
        }

        let locale = interfaceLocale()
        if let actionError {
            errorMessage = String(
                format: MacLocalizedString.resolve("无法更改登录项设置：%@", locale: locale),
                actionError.localizedDescription
            )
        } else {
            errorMessage = MacLocalizedString.resolve("系统尚未确认登录项更改。请重新检测或在系统设置的登录项中检查。", locale: locale)
        }
    }

    /// Read-only navigation to Login Items. The app never changes system
    /// settings on the user's behalf.
    func openSystemSettings() {
        service.openSystemSettingsLoginItems()
    }
}
