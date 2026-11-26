import Foundation
import ServiceManagement
import Testing
@testable import Daybreak

// MARK: - Fixtures

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var currentStatus: LoginItemStatus
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterRegister: LoginItemStatus?
    var statusAfterUnregister: LoginItemStatus?

    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LoginItemStatus = .notRegistered) {
        self.currentStatus = status
    }

    func status() -> LoginItemStatus {
        currentStatus
    }

    func register() throws {
        registerCount += 1
        if let statusAfterRegister {
            currentStatus = statusAfterRegister
        }
        if let registerError {
            throw registerError
        }
    }

    func unregister() throws {
        unregisterCount += 1
        if let statusAfterUnregister {
            currentStatus = statusAfterUnregister
        }
        if let unregisterError {
            throw unregisterError
        }
    }

    func openSystemSettingsLoginItems() {
        openSettingsCount += 1
    }
}

private struct LoginItemTestError: LocalizedError {
    var errorDescription: String? { "模拟系统错误" }
}

// MARK: - Controller

@Suite("Login item controller")
struct LoginItemControllerTests {
    static func defaults() -> UserDefaults {
        let suite = "DaybreakLoginItem-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeController(
        status: LoginItemStatus,
        locale: Locale = Locale(identifier: "zh-Hans"),
        defaults: UserDefaults? = nil
    ) -> (LoginItemController, FakeLoginItemService) {
        let service = FakeLoginItemService(status: status)
        let controller = LoginItemController(
            service: service,
            locale: { locale },
            defaults: defaults ?? Self.defaults()
        )
        return (controller, service)
    }

    @Test("ServiceManagement notFound stays a truthful error state")
    @MainActor
    func mapsNotFoundWithoutClaimingUnsupported() {
        #expect(LoginItemStatus(SMAppService.Status.notFound) == .notFound)
        #expect(LoginItemStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(SMAppService.Status.enabled) == .enabled)
        #expect(LoginItemStatus(SMAppService.Status.notRegistered) == .notRegistered)
    }

    @Test("notFound is an error state and never an unsupported-build claim")
    @MainActor
    func notFoundIsNotUnsupported() {
        let (controller, _) = makeController(status: .notFound)

        #expect(controller.status == .notFound)
        #expect(controller.isEnabled == false)
        #expect(controller.hasConfirmedRegistration == false)
        #expect(!controller.statusText.contains("不支持"))
        #expect(controller.statusText.contains("未找到"))
        #expect(controller.recoveryGuidance != nil)
        #expect(controller.recoveryGuidance?.contains("不支持") == false)
        #expect(controller.canRecheck)
        #expect(controller.errorMessage == nil)
    }

    @Test("A registration awaiting approval is not reported as enabled")
    @MainActor
    func requiresApprovalIsNotEnabled() {
        let (controller, _) = makeController(status: .requiresApproval)

        #expect(controller.isEnabled == false)
        #expect(controller.hasConfirmedRegistration)
        #expect(controller.requiresApproval)
        #expect(controller.statusText.contains("批准"))
        #expect(controller.canToggle == false)
    }

    @Test("Enabling registers once and reports the enabled state")
    @MainActor
    func enablingRegisters() {
        let (controller, service) = makeController(status: .notRegistered)
        service.statusAfterRegister = .enabled

        controller.setEnabled(true)

        #expect(service.registerCount == 1)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
        #expect(controller.isUpdating == false)
    }

    @Test("A registration error is surfaced without inventing a new state")
    @MainActor
    func registrationErrorIsSurfaced() {
        let (controller, service) = makeController(status: .notFound)
        service.registerError = LoginItemTestError()

        controller.setEnabled(true)

        #expect(service.registerCount == 1)
        #expect(controller.status == .notFound)
        #expect(controller.isEnabled == false)
        #expect(controller.errorMessage?.contains("模拟系统错误") == true)
    }

    @Test("Enabling re-reads state so an external registration is not repeated")
    @MainActor
    func enablingReReadsExternalRegistration() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        // The user enabled the login item in System Settings after this
        // controller read its initial state.
        service.currentStatus = .enabled

        controller.setEnabled(true)

        #expect(service.registerCount == 0)
        #expect(controller.status == .enabled)
        #expect(controller.errorMessage == nil)
        #expect(
            defaults.string(forKey: LoginItemConsentPreferences.choiceKey)
                == LoginItemConsentChoice.enabled.rawValue
        )
    }

    @Test("Disabling re-reads state and removes an externally enabled login item")
    @MainActor
    func disablingReReadsExternalRegistration() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        service.currentStatus = .enabled
        service.statusAfterUnregister = .notRegistered

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(controller.status == .notRegistered)
        #expect(controller.errorMessage == nil)
        #expect(
            defaults.string(forKey: LoginItemConsentPreferences.choiceKey)
                == LoginItemConsentChoice.declined.rawValue
        )
    }

    @Test("Approval opens System Settings instead of re-registering")
    @MainActor
    func approvalOpensSystemSettings() {
        let (controller, service) = makeController(status: .requiresApproval)

        controller.setEnabled(true)

        #expect(service.registerCount == 0)
        #expect(service.openSettingsCount == 1)
        #expect(controller.status == .requiresApproval)
        #expect(controller.errorMessage == nil)
    }

    @Test("Removing a pending login item unregisters it")
    @MainActor
    func removingPendingItemUnregisters() {
        let (controller, service) = makeController(status: .requiresApproval)
        service.statusAfterUnregister = .notRegistered

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(controller.status == .notRegistered)
        #expect(controller.isEnabled == false)
        #expect(controller.errorMessage == nil)
    }

    @Test("Disabling an unregistered item performs no system change")
    @MainActor
    func disablingUnregisteredIsNoOp() {
        let (controller, service) = makeController(status: .notRegistered)

        controller.setEnabled(false)

        #expect(service.unregisterCount == 0)
        #expect(controller.errorMessage == nil)
    }

    @Test("An unconfirmed unregister is explained instead of hidden")
    @MainActor
    func unconfirmedUnregisterIsReported() {
        let (controller, service) = makeController(status: .enabled)
        service.statusAfterUnregister = .enabled

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(controller.isEnabled)
        #expect(controller.errorMessage?.contains("尚未确认") == true)
    }

    @Test("A thrown error is cleared when the system reached the target state")
    @MainActor
    func actionErrorClearedWhenOutcomeConfirmed() {
        let (controller, service) = makeController(status: .notRegistered)
        service.registerError = LoginItemTestError()
        service.statusAfterRegister = .requiresApproval

        controller.setEnabled(true)

        #expect(controller.status == .requiresApproval)
        #expect(controller.requiresApproval)
        #expect(controller.errorMessage == nil)
    }

    @Test("Refresh reports external approval but keeps approval-only state off")
    @MainActor
    func refreshReadsLiveStatus() {
        let (controller, service) = makeController(status: .requiresApproval)
        service.currentStatus = .enabled

        controller.refresh()

        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
    }

    @Test("Refresh clears the last failure after a ServiceManagement error")
    @MainActor
    func refreshClearsTheLastFailure() {
        let (controller, service) = makeController(status: .notFound)
        service.registerError = LoginItemTestError()
        controller.setEnabled(true)
        #expect(controller.errorMessage != nil)

        service.currentStatus = .notRegistered
        controller.refresh()

        #expect(controller.status == .notRegistered)
        #expect(controller.errorMessage == nil)
    }

    @Test("An unknown status never claims success")
    @MainActor
    func unknownStatusIsNotSuccess() {
        let (controller, _) = makeController(status: .unknown)

        #expect(controller.isEnabled == false)
        #expect(controller.canRecheck)
        #expect(controller.statusText.contains("未知"))
        #expect(controller.recoveryGuidance != nil)
    }
}

// MARK: - Startup consent

@Suite("Login item startup consent")
struct LoginItemConsentTests {
    private static func defaults() -> UserDefaults {
        let suite = "DaybreakLoginItemConsent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeController(
        status: LoginItemStatus,
        defaults: UserDefaults
    ) -> (LoginItemController, FakeLoginItemService) {
        let service = FakeLoginItemService(status: status)
        let controller = LoginItemController(
            service: service,
            locale: { Locale(identifier: "zh-Hans") },
            defaults: defaults
        )
        return (controller, service)
    }

    private func storedChoice(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: LoginItemConsentPreferences.choiceKey)
    }

    @Test("An undecided user is asked once per launch and showing the prompt registers nothing")
    @MainActor
    func promptsOncePerLaunch() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )

        controller.considerConsentAtLaunch()

        #expect(controller.consentPhase == .asking)
        #expect(service.registerCount == 0)
        #expect(storedChoice(defaults) == nil)

        controller.dismissConsentPrompt()
        controller.considerConsentAtLaunch()

        #expect(controller.consentPhase == nil)
        #expect(service.registerCount == 0)

        // A dismissal is not a durable decline: the next process launch may ask.
        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()

        #expect(nextLaunch.consentPhase == .asking)
        #expect(nextService.registerCount == 0)
    }

    @Test("A decline is persisted and never re-prompts")
    @MainActor
    func declineIsRemembered() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )

        controller.considerConsentAtLaunch()
        controller.declineConsent()

        #expect(controller.consentPhase == nil)
        #expect(service.registerCount == 0)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.declined.rawValue)

        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()

        #expect(nextLaunch.consentPhase == nil)
        #expect(nextService.registerCount == 0)
    }

    @Test("Accepting registers once, reports enabled, and suppresses later prompts")
    @MainActor
    func acceptRegistersOnce() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        service.statusAfterRegister = .enabled

        controller.considerConsentAtLaunch()
        #expect(service.registerCount == 0)

        controller.acceptConsent()

        #expect(service.registerCount == 1)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.consentPhase == nil)
        #expect(controller.isUpdating == false)
        #expect(controller.errorMessage == nil)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue)

        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()

        #expect(nextLaunch.consentPhase == nil)
        #expect(nextService.registerCount == 0)
    }

    @Test("Accepting respects an enable made in System Settings before the sheet")
    @MainActor
    func acceptConsentRespectsExternalEnable() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        controller.considerConsentAtLaunch()
        #expect(controller.consentPhase == .asking)

        service.currentStatus = .enabled
        controller.acceptConsent()

        #expect(service.registerCount == 0)
        #expect(controller.status == .enabled)
        #expect(controller.consentPhase == nil)
        #expect(controller.errorMessage == nil)
        #expect(
            storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue
        )
    }

    @Test("A registration needing approval is explained, not claimed as enabled")
    @MainActor
    func acceptanceRequiringApprovalIsTruthful() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        service.statusAfterRegister = .requiresApproval

        controller.considerConsentAtLaunch()
        controller.acceptConsent()

        #expect(service.registerCount == 1)
        #expect(controller.consentPhase == .awaitingApproval)
        #expect(controller.status == .requiresApproval)
        #expect(controller.isEnabled == false)
        #expect(controller.requiresApproval)
        #expect(controller.errorMessage == nil)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue)
        // Consent never navigates to System Settings on its own.
        #expect(service.openSettingsCount == 0)

        controller.openSystemSettings()
        #expect(service.openSettingsCount == 1)

        controller.dismissConsentPrompt()
        #expect(controller.consentPhase == nil)

        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()

        #expect(nextLaunch.consentPhase == nil)
        #expect(nextService.registerCount == 0)
    }

    @Test("A registration failure keeps the prompt truthful and retryable")
    @MainActor
    func registrationFailureIsSurfacedAndRetryable() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        service.registerError = LoginItemTestError()

        controller.considerConsentAtLaunch()
        controller.acceptConsent()

        #expect(service.registerCount == 1)
        #expect(controller.consentPhase == .failed)
        #expect(controller.status == .notRegistered)
        #expect(controller.isEnabled == false)
        #expect(controller.errorMessage?.contains("模拟系统错误") == true)
        #expect(controller.errorMessage?.contains("不支持") == false)
        #expect(storedChoice(defaults) == nil)

        // A failure is not a consent decision, so a later launch may offer the
        // choice again instead of treating it as an opt-in or opt-out.
        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()
        #expect(nextLaunch.consentPhase == .asking)
        #expect(nextService.registerCount == 0)

        // Retrying from the still-visible failure state can succeed.
        service.registerError = nil
        service.statusAfterRegister = .enabled
        controller.acceptConsent()

        #expect(service.registerCount == 2)
        #expect(controller.status == .enabled)
        #expect(controller.consentPhase == nil)
        #expect(controller.errorMessage == nil)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue)
    }

    @Test("A notFound state still offers consent and explains a failed registration")
    @MainActor
    func notFoundStillPromptsAndExplainsFailure() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notFound,
            defaults: defaults
        )

        controller.considerConsentAtLaunch()

        #expect(controller.consentPhase == .asking)
        #expect(service.registerCount == 0)
        #expect(storedChoice(defaults) == nil)
        #expect(controller.statusText.contains("未找到"))
        #expect(controller.statusText.contains("不支持") == false)
        #expect(controller.recoveryGuidance?.contains("不支持") == false)

        // A real system state can only be confirmed by trying. The failed
        // attempt must report the actual error instead of hiding the feature.
        service.registerError = LoginItemTestError()
        controller.acceptConsent()

        #expect(service.registerCount == 1)
        #expect(controller.status == .notFound)
        #expect(controller.consentPhase == .failed)
        #expect(controller.isEnabled == false)
        #expect(controller.errorMessage?.contains("模拟系统错误") == true)
        #expect(controller.errorMessage?.contains("不支持") == false)
        #expect(controller.recoveryGuidance?.contains("找不到") == true)
        #expect(controller.recoveryGuidance?.contains("不支持") == false)
        #expect(storedChoice(defaults) == nil)

        // Retrying remains available, and a real success leaves the failure
        // state instead of claiming the login item was enabled prematurely.
        service.registerError = nil
        service.statusAfterRegister = .requiresApproval
        controller.acceptConsent()

        #expect(service.registerCount == 2)
        #expect(controller.status == .requiresApproval)
        #expect(controller.consentPhase == .awaitingApproval)
        #expect(controller.isEnabled == false)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue)
    }

    @Test("An unknown framework state remains conservative")
    @MainActor
    func unknownDoesNotPrompt() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .unknown,
            defaults: defaults
        )

        controller.considerConsentAtLaunch()

        #expect(controller.consentPhase == nil)
        #expect(service.registerCount == 0)
        #expect(storedChoice(defaults) == nil)
        #expect(controller.canRecheck)
        #expect(controller.recoveryGuidance != nil)
    }

    @Test("An existing registration suppresses the prompt without changing it")
    @MainActor
    func existingRegistrationIsRespected() {
        for status in [LoginItemStatus.enabled, LoginItemStatus.requiresApproval] {
            let defaults = Self.defaults()
            let (controller, service) = makeController(
                status: status,
                defaults: defaults
            )

            controller.considerConsentAtLaunch()

            #expect(controller.consentPhase == nil)
            #expect(service.registerCount == 0)
            #expect(service.unregisterCount == 0)
            #expect(storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue)
        }
    }

    @Test("An explicit Settings opt-out blocks every later automatic prompt")
    @MainActor
    func settingsOptOutBlocksPrompt() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .enabled,
            defaults: defaults
        )
        service.statusAfterUnregister = .notRegistered

        controller.setEnabled(false)

        #expect(controller.status == .notRegistered)
        #expect(service.unregisterCount == 1)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.declined.rawValue)

        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()

        #expect(nextLaunch.consentPhase == nil)
        #expect(nextService.registerCount == 0)
    }

    @Test("An explicit Settings opt-in is respected")
    @MainActor
    func settingsOptInSuppressesPrompt() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        service.statusAfterRegister = .enabled

        controller.setEnabled(true)

        #expect(controller.status == .enabled)
        #expect(service.registerCount == 1)
        #expect(storedChoice(defaults) == LoginItemConsentChoice.enabled.rawValue)

        let (nextLaunch, nextService) = makeController(
            status: .notRegistered,
            defaults: defaults
        )
        nextLaunch.considerConsentAtLaunch()

        #expect(nextLaunch.consentPhase == nil)
        #expect(nextService.registerCount == 0)
    }

    @Test("Disabling an unregistered item is not recorded as a consent decline")
    @MainActor
    func noOpDisableIsNotADecline() {
        let defaults = Self.defaults()
        let (controller, service) = makeController(
            status: .notRegistered,
            defaults: defaults
        )

        controller.setEnabled(false)

        #expect(service.unregisterCount == 0)
        #expect(storedChoice(defaults) == nil)
    }
}
