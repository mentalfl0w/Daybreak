import DaybreakCore
import Foundation
import Testing
@testable import MacIntegration

@Suite("MacOverwritePolicy")
struct MacOverwritePolicyTests {
    private let desired = DesktopWallpaper(
        imageURL: URL(fileURLWithPath: "/tmp/Daybreak/target.png"),
        scaling: .fill
    )

    @Test("Exact target is always allowed")
    func exactTarget() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: desired.imageURL,
            desired: desired,
            isManaged: false,
            hasMatchingApproval: false,
            isManuallyProtected: false
        )
        #expect(decision == .allowed)
    }

    @Test("Managed ledger image may be replaced")
    func managedImage() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: URL(fileURLWithPath: "/tmp/Daybreak/yesterday.png"),
            desired: desired,
            isManaged: true,
            hasMatchingApproval: false,
            isManuallyProtected: false
        )
        #expect(decision == .allowed)
    }

    @Test("Unknown external wallpaper is blocked")
    func unknownWallpaper() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: URL(fileURLWithPath: "/tmp/User/manual.jpg"),
            desired: desired,
            isManaged: false,
            hasMatchingApproval: false,
            isManuallyProtected: false
        )
        #expect(decision == .blocked(.unverifiedExternalWallpaper))
    }

    @Test("Unreadable current wallpaper is blocked")
    func unreadableWallpaper() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: nil,
            desired: desired,
            isManaged: false,
            hasMatchingApproval: false,
            isManuallyProtected: false
        )
        #expect(decision == .blocked(.unreadableCurrentWallpaper))
    }

    @Test("Protection outranks approvals and managed URLs")
    func protectionOutranks() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: desired.imageURL,
            desired: desired,
            isManaged: true,
            hasMatchingApproval: true,
            isManuallyProtected: true
        )
        #expect(decision == .blocked(.manualProtection))
    }

    @Test("A matching one-shot approval allows an external wallpaper")
    func approvalAllows() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: URL(fileURLWithPath: "/tmp/User/manual.jpg"),
            desired: desired,
            isManaged: false,
            hasMatchingApproval: true,
            isManuallyProtected: false
        )
        #expect(decision == .allowed)
    }

    @Test("Nil observed URLs cannot be bypassed by approval or ledger")
    func nilCannotBeBypassed() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: nil,
            desired: desired,
            isManaged: true,
            hasMatchingApproval: true,
            isManuallyProtected: false
        )
        #expect(decision == .blocked(.unreadableCurrentWallpaper))
    }

    @Test("Explicit automatic overwrite allows an unknown external wallpaper")
    func automaticOverwriteAllowsExternal() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: URL(fileURLWithPath: "/tmp/User/manual.jpg"),
            desired: desired,
            isManaged: false,
            hasMatchingApproval: false,
            isManuallyProtected: false,
            allowsAutomaticOverwrite: true
        )
        #expect(decision == .allowed)
    }

    @Test("Explicit automatic overwrite allows an unreadable current wallpaper")
    func automaticOverwriteAllowsUnreadable() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: nil,
            desired: desired,
            isManaged: false,
            hasMatchingApproval: false,
            isManuallyProtected: false,
            allowsAutomaticOverwrite: true
        )
        #expect(decision == .allowed)
    }

    @Test("Manual protection still wins over automatic overwrite")
    func protectionOutranksAutomaticOverwrite() {
        let decision = MacOverwritePolicy.decide(
            observedImageURL: URL(fileURLWithPath: "/tmp/User/manual.jpg"),
            desired: desired,
            isManaged: false,
            hasMatchingApproval: false,
            isManuallyProtected: true,
            allowsAutomaticOverwrite: true
        )
        #expect(decision == .blocked(.manualProtection))
    }
}
