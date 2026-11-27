import DaybreakCore
import Foundation
import Testing
import UserNotifications
@testable import Daybreak

// MARK: - Fixtures

@MainActor
private final class FakeDailyNotificationSender: DailyWallpaperNotificationSending {
    var status: DailyNotificationAuthorization = .authorized
    var requestedStatus: DailyNotificationAuthorization = .authorized
    /// Optional override for the status returned by the request, while the
    /// live `status` can remain stale to model the system's settings lag.
    var requestResultStatus: DailyNotificationAuthorization?
    /// When nil, the Bool mirrors whether the resolved status allows delivery.
    var requestGrant: Bool?
    var updateLiveStatusAfterRequest = true
    var requestFailure: DailyWallpaperNotificationFailure?
    var delivery: DailyWallpaperNotificationDelivery = .delivered

    private(set) var deliveredNotifications: [DailyWallpaperNotificationRequest] = []
    private(set) var authorizationRequestCount = 0
    private(set) var lastDeliveryBypassedAuthorizationCache: Bool?

    init(status: DailyNotificationAuthorization = .authorized) {
        self.status = status
        self.requestedStatus = status
    }

    func authorizationStatus() async -> DailyNotificationAuthorization {
        status
    }

    func requestAuthorization() async -> DailyWallpaperNotificationAuthorizationOutcome {
        authorizationRequestCount += 1
        if let requestFailure {
            return .failed(requestFailure)
        }
        let resolvedStatus = requestResultStatus ?? requestedStatus
        if updateLiveStatusAfterRequest {
            status = resolvedStatus
        }
        let granted = requestGrant ?? resolvedStatus.allowsDelivery
        return .resolved(resolvedStatus, granted: granted)
    }

    func deliver(
        _ notification: DailyWallpaperNotificationRequest,
        allowWhenAuthorizationStatusIsStale: Bool
    ) async -> DailyWallpaperNotificationDelivery {
        lastDeliveryBypassedAuthorizationCache = allowWhenAuthorizationStatusIsStale
        deliveredNotifications.append(notification)
        return delivery
    }
}

private enum NotificationFixtures {
    static func date(_ value: String) -> LocalDate {
        LocalDate(iso8601: value)!
    }

    /// A deterministic instant inside the requested market-local day. Used to
    /// exercise the notification clock without depending on the host clock.
    static func marketInstant(
        day: String = "2026-11-24",
        hour: Int = 12,
        minute: Int = 0
    ) -> Date {
        let timeZone = BingMarketProfile.profile(for: .zhCN)!.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components)!
    }

    static func payload(
        sourceDate: String = "2026-11-24",
        marketToday: String = "2026-11-24",
        imageID: String = "image-a",
        storyMatch: StoryMatch? = nil,
        originalURL: URL? = URL(fileURLWithPath: "/tmp/daybreak-original.jpg"),
        thumbnailURL: URL? = URL(fileURLWithPath: "/tmp/daybreak-thumbnail.jpg")
    ) -> TodayPayload {
        TodayPayload(
            market: .zhCN,
            marketToday: date(marketToday),
            occurrence: WallpaperOccurrence(
                source: .bing,
                market: .zhCN,
                localDate: date(sourceDate),
                wallpaperID: WallpaperID(source: .bing, sourceImageID: imageID)
            ),
            metadata: nil,
            wallpaper: nil,
            storyMatch: storyMatch,
            thumbnailURL: thumbnailURL,
            originalURL: originalURL,
            cachedAt: nil
        )
    }

    static func story(
        availability: StoryAvailability = .available,
        title: String? = "秋日的保护色",
        headline: String? = "晨雾中的森林",
        body: String? = "完整介绍正文。",
        quickFact: String? = "红松鼠会用树枝交织成巢。",
        copyright: String? = "摄影：Example"
    ) -> DailyStoryRecord {
        DailyStoryRecord(
            id: "story-zhCN-2026-11-24",
            source: .bing,
            market: .zhCN,
            date: date("2026-11-24"),
            associatedWallpaperID: WallpaperID(source: .bing, sourceImageID: "image-a"),
            title: title,
            headline: headline,
            body: body,
            quickFact: quickFact,
            copyright: copyright,
            originalLocale: "zh-Hans",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            availability: availability
        )!
    }

    static func defaults() -> UserDefaults {
        let suite = "DaybreakNotifications-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

/// A test clock that can move across a market midnight. The controller only
/// reads it on the main actor, matching every production call site.
private final class NotificationTestClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

// MARK: - Content

@Suite("Daily wallpaper notification content")
struct DailyWallpaperNotificationContentTests {
    @Test("Genuine headline and quick fact become the body, never copyright")
    func genuineStoryFields() throws {
        let story = NotificationFixtures.story()
        let payload = NotificationFixtures.payload(
            storyMatch: .matched(story, evidence: .imageIdentityMarketAndDate)
        )
        let request = DailyWallpaperNotificationPolicy.request(
            for: payload,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(request.title == "秋日的保护色")
        #expect(request.body == "晨雾中的森林\n红松鼠会用树枝交织成巢。")
        #expect(!request.body.contains("摄影：Example"))
        #expect(request.thumbnailURL == payload.thumbnailURL)
        #expect(request.occurrenceDescription == payload.key.description)
    }

    @Test("Unavailable story never borrows copyright as an introduction")
    func unavailableStoryFallsBack() {
        let story = NotificationFixtures.story(
            availability: .unavailable(.notProvidedBySource),
            headline: nil,
            body: nil,
            quickFact: nil
        )
        let payload = NotificationFixtures.payload(
            storyMatch: .unavailable(story)
        )
        let request = DailyWallpaperNotificationPolicy.request(
            for: payload,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(request.title == "秋日的保护色")
        #expect(!request.body.isEmpty)
        #expect(!request.body.contains("摄影：Example"))
        #expect(request.body.contains("来源未提供"))
    }

    @Test("A title-only story does not masquerade as a description")
    func titleOnlyStoryDoesNotBecomeBody() {
        let story = NotificationFixtures.story(
            headline: nil,
            body: nil,
            quickFact: nil
        )
        let payload = NotificationFixtures.payload(
            storyMatch: .matched(story, evidence: .imageIdentityMarketAndDate)
        )
        let request = DailyWallpaperNotificationPolicy.request(
            for: payload,
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(request.title == "秋日的保护色")
        #expect(request.body != "秋日的保护色")
        #expect(request.body.contains("来源未提供"))
    }

    @Test("Missing thumbnail is optional and never invented")
    func missingThumbnailIsOptional() {
        let payload = NotificationFixtures.payload(thumbnailURL: nil)
        let request = DailyWallpaperNotificationPolicy.request(
            for: payload,
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(request.thumbnailURL == nil)
    }
}

// MARK: - Decision policy

@Suite("Daily wallpaper notification policy")
struct DailyWallpaperNotificationPolicyTests {
    private let display = DesktopDisplayID("display-a")

    private func assess(
        payload: TodayPayload?,
        now: Date = NotificationFixtures.marketInstant(),
        isEnabled: Bool = true,
        appliedURLs: [DesktopDisplayID: URL],
        previousURLs: [DesktopDisplayID: URL],
        lastReceipt: DailyWallpaperNotificationReceipt? = nil
    ) -> DailyWallpaperNotificationAssessment {
        DailyWallpaperNotificationPolicy.assess(
            payload: payload,
            now: now,
            isEnabled: isEnabled,
            appliedURLs: appliedURLs,
            previouslyAppliedURLs: previousURLs,
            lastReceipt: lastReceipt,
            locale: Locale(identifier: "zh-Hans")
        )
    }

    @Test("A newly applied original image for today is eligible")
    func newlyAppliedTodayIsEligible() {
        let payload = NotificationFixtures.payload()
        let original = payload.originalURL!
        let result = assess(
            payload: payload,
            appliedURLs: [display: original],
            previousURLs: [:]
        )
        guard case .notify = result else {
            Issue.record("Expected a notification decision")
            return
        }
    }

    @Test("A payload frozen before market midnight does not claim today")
    func crossMidnightDoesNotNotify() {
        // The payload still carries marketToday == 2026-11-24 from before the
        // market midnight; a failed refresh left it cached. At 00:01 on the
        // next market day the notification decision must use the live clock.
        let payload = NotificationFixtures.payload(
            sourceDate: "2026-11-24",
            marketToday: "2026-11-24"
        )
        let afterMidnight = NotificationFixtures.marketInstant(
            day: "2026-11-25",
            hour: 0,
            minute: 1
        )
        let result = assess(
            payload: payload,
            now: afterMidnight,
            appliedURLs: [display: payload.originalURL!],
            previousURLs: [:]
        )
        #expect(result == .skip(.staleSourceDate))
    }

    @Test("The same payload is still eligible before market midnight")
    func beforeMidnightRemainsEligible() {
        let payload = NotificationFixtures.payload(
            sourceDate: "2026-11-24",
            marketToday: "2026-11-24"
        )
        let beforeMidnight = NotificationFixtures.marketInstant(
            day: "2026-11-24",
            hour: 23,
            minute: 59
        )
        let result = assess(
            payload: payload,
            now: beforeMidnight,
            appliedURLs: [display: payload.originalURL!],
            previousURLs: [:]
        )
        guard case .notify = result else {
            Issue.record("Expected a notification decision before midnight")
            return
        }
    }

    @Test("Opt-out and stale dates never notify")
    func failClosedInputs() {
        let payload = NotificationFixtures.payload()
        let original = payload.originalURL!

        #expect(
            assess(
                payload: payload,
                isEnabled: false,
                appliedURLs: [display: original],
                previousURLs: [:]
            ) == .skip(.disabled)
        )
        let stale = NotificationFixtures.payload(
            sourceDate: "2026-11-23",
            marketToday: "2026-11-24"
        )
        #expect(
            assess(
                payload: stale,
                appliedURLs: [display: stale.originalURL!],
                previousURLs: [:]
            ) == .skip(.staleSourceDate)
        )
    }

    @Test("A confirmed applied write notifies even when the URL did not change")
    func confirmedApplyWithReusedURLNotifies() {
        let payload = NotificationFixtures.payload()
        let result = DailyWallpaperNotificationPolicy.assessConfirmedApply(
            payload: payload,
            now: NotificationFixtures.marketInstant(),
            isEnabled: true,
            appliedImageURL: payload.originalURL!,
            appliedDisplayIDs: [display],
            lastReceipt: nil,
            locale: Locale(identifier: "zh-Hans")
        )
        guard case .notify(let request) = result else {
            Issue.record("Expected a confirmed apply to notify")
            return
        }
        #expect(request.occurrenceDescription == payload.key.description)
        #expect(request.thumbnailURL == payload.thumbnailURL)
    }

    @Test("A confirmed write for another image never notifies for today")
    func confirmedArchivedApplyDoesNotNotify() {
        let payload = NotificationFixtures.payload()
        let result = DailyWallpaperNotificationPolicy.assessConfirmedApply(
            payload: payload,
            now: NotificationFixtures.marketInstant(),
            isEnabled: true,
            appliedImageURL: URL(fileURLWithPath: "/tmp/archived.jpg"),
            appliedDisplayIDs: [display],
            lastReceipt: nil,
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(result == .skip(.notNewlyApplied))
    }

    @Test("A confirmed apply with no accepted display does not notify")
    func confirmedApplyWithoutDisplaysDoesNotNotify() {
        let payload = NotificationFixtures.payload()
        let result = DailyWallpaperNotificationPolicy.assessConfirmedApply(
            payload: payload,
            now: NotificationFixtures.marketInstant(),
            isEnabled: true,
            appliedImageURL: payload.originalURL!,
            appliedDisplayIDs: [],
            lastReceipt: nil,
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(result == .skip(.notNewlyApplied))
    }

    @Test("A persisted applied URL is not a new application")
    func unchangedAppliedURLIsNotNew() {
        let payload = NotificationFixtures.payload()
        let original = payload.originalURL!
        #expect(
            assess(
                payload: payload,
                appliedURLs: [display: original],
                previousURLs: [display: original]
            ) == .skip(.notNewlyApplied)
        )
    }

    @Test("Blocked or failed writes leave no applied transition")
    func noTransitionWhenWriteDidNotSucceed() {
        let payload = NotificationFixtures.payload()
        #expect(
            assess(
                payload: payload,
                appliedURLs: [:],
                previousURLs: [:]
            ) == .skip(.notNewlyApplied)
        )
        #expect(
            assess(
                payload: payload,
                appliedURLs: [display: URL(fileURLWithPath: "/tmp/other.jpg")],
                previousURLs: [:]
            ) == .skip(.notNewlyApplied)
        )
    }

    @Test("The same occurrence is not notified twice across restarts")
    func receiptDeduplicates() {
        let payload = NotificationFixtures.payload()
        let receipt = DailyWallpaperNotificationReceipt(
            occurrenceDescription: payload.key.description,
            notifiedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        #expect(
            assess(
                payload: payload,
                appliedURLs: [display: payload.originalURL!],
                previousURLs: [:],
                lastReceipt: receipt
            ) == .skip(.alreadyNotified)
        )
    }
}

// MARK: - Controller

@Suite("Daily notification controller")
struct DailyNotificationControllerTests {
    private let display = DesktopDisplayID("display-a")

    @Test("A confirmed apply delivers once and persists a receipt")
    @MainActor
    func deliversOnceAndPersistsReceipt() async throws {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload(
            storyMatch: .matched(
                NotificationFixtures.story(),
                evidence: .imageIdentityMarketAndDate
            )
        )
        controller.captureBaseline(appliedURLs: [:])

        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(sender.deliveredNotifications.count == 1)
        #expect(sender.deliveredNotifications.first?.title == "秋日的保护色")
        #expect(
            DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt?
                .occurrenceDescription == payload.key.description
        )

        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )
        #expect(sender.deliveredNotifications.count == 1)
    }

    @Test("Baseline capture prevents a startup notification")
    @MainActor
    func startupBaselineDoesNotNotify() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })
        let payload = NotificationFixtures.payload()

        controller.captureBaseline(appliedURLs: [display: payload.originalURL!])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(sender.deliveredNotifications.isEmpty)
    }

    @Test("The first snapshot is always a baseline")
    @MainActor
    func firstSnapshotIsBaseline() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })
        let payload = NotificationFixtures.payload()

        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(sender.deliveredNotifications.isEmpty)
    }

    @Test("A restarted controller does not re-notify the recorded occurrence")
    @MainActor
    func restartDoesNotReNotify() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let payload = NotificationFixtures.payload()
        let receipt = DailyWallpaperNotificationReceipt(
            occurrenceDescription: payload.key.description,
            notifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt = receipt
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(sender.deliveredNotifications.isEmpty)
    }

    @Test("Denied permission reports the truth and records no receipt")
    @MainActor
    func deniedPermissionDoesNotClaimDelivery() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender(status: .denied)
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })
        let payload = NotificationFixtures.payload()
        controller.captureBaseline(appliedURLs: [:])

        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(sender.deliveredNotifications.isEmpty)
        #expect(controller.errorMessage != nil)
        #expect(controller.authorization == .denied)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)
    }

    @Test("A delivery failure records no receipt and reports the raw cause")
    @MainActor
    func deliveryFailureRecordsNoReceipt() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        sender.delivery = .failed(
            DailyWallpaperNotificationFailure(
                domain: "UNErrorDomain",
                code: 1,
                detail: "Notifications are not allowed for this application"
            )
        )
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })
        let payload = NotificationFixtures.payload()
        controller.captureBaseline(appliedURLs: [:])

        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(controller.errorMessage != nil)
        #expect(controller.errorMessage?.contains("UNErrorDomain") == true)
        #expect(controller.errorMessage?.contains("Notifications are not allowed") == true)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)
    }

    @Test("Enabling requests permission only on the explicit action")
    @MainActor
    func enablingRequestsPermission() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .authorized
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })

        #expect(sender.authorizationRequestCount == 0)
        controller.setEnabled(true)

        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline, controller.isUpdating {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(sender.authorizationRequestCount == 1)
        #expect(controller.isEnabled)
        #expect(controller.authorization == .authorized)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
    }

    @Test("A denied permission request leaves the setting off and explains why")
    @MainActor
    func deniedRequestKeepsSettingOff() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .denied
        let controller = DailyNotificationController(defaults: defaults, sender: sender, now: { NotificationFixtures.marketInstant() })

        controller.setEnabled(true)

        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline, controller.isUpdating {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!controller.isEnabled)
        #expect(!DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(controller.errorMessage != nil)
        #expect(controller.isDenied)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .off)
    }

    @Test("A thrown request reports the raw cause and is never shown as a denial")
    @MainActor
    func requestFailureIsNotDenial() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestFailure = DailyWallpaperNotificationFailure(
            domain: "UNErrorDomain",
            code: 1,
            detail: "Notifications are not allowed for this application"
        )
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        controller.setEnabled(true)
        try await waitForUpdate(controller)

        #expect(!controller.isEnabled)
        #expect(controller.authorization == .notDetermined)
        #expect(!controller.isDenied)
        #expect(!controller.canOpenSystemSettings)
        #expect(controller.canRetryAuthorization)
        #expect(controller.authorizationFailure?.domain == "UNErrorDomain")
        #expect(controller.authorizationFailure?.code == 1)
        #expect(controller.errorMessage?.contains("UNErrorDomain") == true)
        #expect(controller.errorMessage?.contains("Notifications are not allowed") == true)
        #expect(controller.errorMessage != nil)
        #expect(!DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == nil)
    }

    @Test("A request failure is cleared when the live system state is already authorized")
    @MainActor
    func requestFailureWithAuthorizedLiveStateKeepsNotificationsEnabled() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .authorized)
        sender.requestFailure = DailyWallpaperNotificationFailure(
            domain: "UNErrorDomain",
            code: 1,
            detail: "Notifications are not allowed for this application"
        )
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        controller.setEnabled(true)
        try await waitForUpdate(controller)

        #expect(controller.isEnabled)
        #expect(controller.authorization == .authorized)
        #expect(controller.authorizationFailure == nil)
        #expect(controller.errorMessage == nil)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
    }

    @Test("A granted request is not lost when settings status has not refreshed")
    @MainActor
    func grantedResultOutranksStaleSettings() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestResultStatus = .notDetermined
        sender.requestGrant = true
        sender.updateLiveStatusAfterRequest = false
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        controller.setEnabled(true)
        try await waitForUpdate(controller)

        #expect(sender.authorizationRequestCount == 1)
        #expect(controller.authorization == .authorized)
        #expect(controller.isEnabled)
        #expect(!controller.isDenied)
        #expect(controller.errorMessage == nil)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .on)

        await controller.refreshPermission()
        #expect(controller.authorization == .authorized)
        #expect(!controller.isDenied)
    }

    @Test("A granted request still delivers a new wallpaper while status is stale")
    @MainActor
    func staleStatusAfterGrantDoesNotEatNotification() async {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestResultStatus = .notDetermined
        sender.requestGrant = true
        sender.updateLiveStatusAfterRequest = false
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()

        await controller.prepareAuthorizationIfNeeded()
        #expect(controller.isEnabled)

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )

        #expect(sender.deliveredNotifications.count == 1)
        #expect(sender.lastDeliveryBypassedAuthorizationCache == true)
        #expect(
            DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt?
                .occurrenceDescription == payload.key.description
        )
    }

    @Test("A wallpaper applied before the launch grant is delivered after the grant")
    @MainActor
    func applyBeforeLaunchGrantIsDeferred() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .authorized
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )
        #expect(sender.deliveredNotifications.isEmpty)

        await controller.prepareAuthorizationIfNeeded()

        #expect(controller.isEnabled)
        #expect(sender.deliveredNotifications.count == 1)
        #expect(
            DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt?
                .occurrenceDescription == payload.key.description
        )
    }

    @Test("A refused request is never reported as allowed")
    @MainActor
    func refusedResultIsNotAnAllow() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestResultStatus = .notDetermined
        sender.requestGrant = false
        sender.updateLiveStatusAfterRequest = false
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        controller.setEnabled(true)
        try await waitForUpdate(controller)

        #expect(controller.authorization == .notDetermined)
        #expect(!controller.authorization.allowsDelivery)
        #expect(!controller.isEnabled)
        #expect(!controller.isDenied)
        #expect(!controller.canOpenSystemSettings)
        #expect(controller.canRetryAuthorization)
        #expect(controller.authorizationRequestIncomplete)
        #expect(controller.errorMessage != nil)
        #expect(!DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == nil)
        #expect(sender.deliveredNotifications.isEmpty)
    }

    @Test("An explicit denied status wins over a contradictory granted result")
    @MainActor
    func deniedStatusOutranksGrantBool() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .denied)
        sender.requestGrant = true
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        controller.setEnabled(true)
        try await waitForUpdate(controller)

        #expect(controller.authorization == .denied)
        #expect(controller.isDenied)
        #expect(!controller.isEnabled)
        #expect(!controller.authorizationRequestIncomplete)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .off)
        #expect(sender.deliveredNotifications.isEmpty)
    }

    @Test("Retrying after a thrown request can still enable notifications")
    @MainActor
    func retryAfterFailureSucceeds() async throws {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestFailure = DailyWallpaperNotificationFailure(
            domain: "UNErrorDomain",
            code: 1,
            detail: "Notifications are not allowed for this application"
        )
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        controller.setEnabled(true)
        try await waitForUpdate(controller)
        #expect(controller.authorizationFailure != nil)

        sender.requestFailure = nil
        sender.requestedStatus = .authorized
        controller.retryAuthorizationRequest()
        try await waitForUpdate(controller)

        #expect(controller.isEnabled)
        #expect(controller.authorization == .authorized)
        #expect(controller.authorizationFailure == nil)
        #expect(controller.errorMessage == nil)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .on)
    }

    @Test("An apply observed while authorization is pending notifies after a grant")
    @MainActor
    func pendingApplyDeliversAfterGrant() async {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .authorized
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )
        #expect(sender.deliveredNotifications.isEmpty)

        await controller.prepareAuthorizationIfNeeded()

        #expect(controller.isEnabled)
        #expect(sender.deliveredNotifications.count == 1)
        #expect(
            DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt?
                .occurrenceDescription == payload.key.description
        )
    }

    @Test("A denied grant discards an apply observed during the prompt")
    @MainActor
    func pendingApplyDiscardedOnDenial() async {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .denied
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: payload.originalURL!]
        )
        await controller.prepareAuthorizationIfNeeded()

        #expect(!controller.isEnabled)
        #expect(sender.deliveredNotifications.isEmpty)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)
    }

    @Test("Launch preparation asks once when the system has not decided")
    @MainActor
    func preparationRequestsOnceWhenNotDetermined() async {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .authorized
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        await controller.prepareAuthorizationIfNeeded()
        #expect(sender.authorizationRequestCount == 1)
        #expect(controller.authorization == .authorized)
        #expect(controller.isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .on)

        await controller.prepareAuthorizationIfNeeded()
        #expect(sender.authorizationRequestCount == 1)
    }

    @Test("Launch preparation reports a thrown request without pretending it was denied")
    @MainActor
    func preparationReportsThrownRequest() async {
        let defaults = NotificationFixtures.defaults()
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestFailure = DailyWallpaperNotificationFailure(
            domain: "UNErrorDomain",
            code: 1,
            detail: "Notifications are not allowed for this application"
        )
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        await controller.prepareAuthorizationIfNeeded()

        #expect(sender.authorizationRequestCount == 1)
        #expect(controller.authorization == .notDetermined)
        #expect(controller.authorizationFailure != nil)
        #expect(!controller.isDenied)
        #expect(!controller.isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == nil)
    }

    @Test("A thrown launch request does not clear an existing opt-in")
    @MainActor
    func preparationFailureKeepsExistingOptIn() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestFailure = DailyWallpaperNotificationFailure(
            domain: "UNErrorDomain",
            code: 1,
            detail: "Notifications are not allowed for this application"
        )
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        await controller.prepareAuthorizationIfNeeded()

        #expect(controller.isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(controller.authorizationFailure != nil)
        #expect(controller.authorization == .notDetermined)
    }

    @Test("Launch preparation never prompts after a denied or authorized app")
    @MainActor
    func preparationSkipsDecidedApps() async {
        for status in [DailyNotificationAuthorization.denied, .authorized] {
            let defaults = NotificationFixtures.defaults()
            let sender = FakeDailyNotificationSender(status: status)
            let controller = DailyNotificationController(
                defaults: defaults,
                sender: sender,
                now: { NotificationFixtures.marketInstant() }
            )

            await controller.prepareAuthorizationIfNeeded()

            #expect(sender.authorizationRequestCount == 0)
            #expect(controller.authorization == status)
        }
    }

    @Test("Legacy disabled value is not treated as an explicit opt-out")
    @MainActor
    func legacyDisabledValueStillRequestsPermission() async {
        let defaults = NotificationFixtures.defaults()
        // Old builds could persist false after a swallowed request error. That
        // is not proof the user chose off.
        defaults.set(false, forKey: DailyWallpaperNotificationSettings.enabledKey)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == nil)

        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .authorized
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )

        await controller.prepareAuthorizationIfNeeded()

        #expect(sender.authorizationRequestCount == 1)
        #expect(controller.isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).isEnabled)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .on)
    }

    @Test("Launch preparation respects an explicit in-app opt-out")
    @MainActor
    func preparationSkipsAfterExplicitOptOut() async throws {
        let defaults = NotificationFixtures.defaults()
        let decidedSender = FakeDailyNotificationSender(status: .authorized)
        let decided = DailyNotificationController(
            defaults: defaults,
            sender: decidedSender,
            now: { NotificationFixtures.marketInstant() }
        )
        decided.setEnabled(false)
        #expect(decidedSender.authorizationRequestCount == 0)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).userChoice == .off)

        let sender = FakeDailyNotificationSender(status: .notDetermined)
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        await controller.prepareAuthorizationIfNeeded()

        #expect(sender.authorizationRequestCount == 0)
        #expect(!controller.isEnabled)
    }

    @Test("A confirmed manual apply notifies even when the applied URL is unchanged")
    @MainActor
    func confirmedApplyWithUnchangedURLDeliversOnce() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()
        let original = payload.originalURL!

        // The display already shows this URL from a previous occurrence, so a
        // snapshot diff would never fire. The confirmed write is authoritative.
        controller.captureBaseline(appliedURLs: [display: original])
        await controller.considerConfirmedApply(
            payload: payload,
            appliedImageURL: original,
            appliedDisplayIDs: [display]
        )

        #expect(sender.deliveredNotifications.count == 1)
        #expect(
            DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt?
                .occurrenceDescription == payload.key.description
        )

        await controller.considerConfirmedApply(
            payload: payload,
            appliedImageURL: original,
            appliedDisplayIDs: [display]
        )
        #expect(sender.deliveredNotifications.count == 1)
    }

    @Test("A snapshot and a confirmed apply for the same occurrence deliver once")
    @MainActor
    func snapshotAndConfirmedApplyDeduplicate() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()
        let original = payload.originalURL!

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(
            payload: payload,
            appliedURLs: [display: original]
        )
        await controller.considerConfirmedApply(
            payload: payload,
            appliedImageURL: original,
            appliedDisplayIDs: [display]
        )

        #expect(sender.deliveredNotifications.count == 1)
    }

    @Test("A confirmed write for another image never notifies for today")
    @MainActor
    func confirmedArchivedApplyIsIgnored() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant() }
        )
        let payload = NotificationFixtures.payload()

        await controller.considerConfirmedApply(
            payload: payload,
            appliedImageURL: URL(fileURLWithPath: "/tmp/archived.jpg"),
            appliedDisplayIDs: [display]
        )

        #expect(sender.deliveredNotifications.isEmpty)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)
    }

    @MainActor
    private func waitForUpdate(_ controller: DailyNotificationController) async throws {
        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline, controller.isUpdating {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Baseline and deferred delivery

    @Test("A launch baseline never notifies for an already applied occurrence")
    @MainActor
    func launchBaselineNeverNotifiesForAPreAppliedOccurrence() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant(day: "2026-11-24") }
        )
        let payload = NotificationFixtures.payload(
            sourceDate: "2026-11-24",
            marketToday: "2026-11-24"
        )
        let applied = [display: payload.originalURL!]

        controller.captureBaseline(appliedURLs: applied)
        await controller.considerAppliedSnapshot(payload: payload, appliedURLs: applied)
        await controller.considerAppliedSnapshot(payload: payload, appliedURLs: applied)

        #expect(sender.deliveredNotifications.isEmpty)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)
    }

    @Test("A reused image on a new day needs a confirmed pass, not a snapshot")
    @MainActor
    func reusedImageNeedsAConfirmedPass() async {
        let defaults = NotificationFixtures.defaults()
        DailyWallpaperNotificationSettings(defaults: defaults).isEnabled = true
        let sender = FakeDailyNotificationSender()
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { NotificationFixtures.marketInstant(day: "2026-11-24") }
        )
        let previousPayload = NotificationFixtures.payload(
            sourceDate: "2026-11-23",
            marketToday: "2026-11-23"
        )
        let payload = NotificationFixtures.payload(
            sourceDate: "2026-11-24",
            marketToday: "2026-11-24"
        )
        // One cached original per image: the same image on two days keeps the
        // same applied URL, so no per-display transition is observable.
        let applied = [display: payload.originalURL!]

        // The app was not running when the market day changed. The persisted
        // applied ledger already contains the reused image, but that is not
        // proof that today's occurrence was applied.
        controller.captureBaseline(appliedURLs: applied)
        await controller.considerAppliedSnapshot(
            payload: previousPayload,
            appliedURLs: applied
        )
        await controller.considerAppliedSnapshot(payload: payload, appliedURLs: applied)
        #expect(sender.deliveredNotifications.isEmpty)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)

        // Only a confirmed pass reporting this occurrence's image as settled
        // may notify.
        await controller.considerConfirmedApply(
            payload: payload,
            appliedImageURL: payload.originalURL!,
            appliedDisplayIDs: [display]
        )
        #expect(sender.deliveredNotifications.count == 1)
        #expect(
            DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt?
                .occurrenceDescription == payload.key.description
        )

        // A repeated confirmed settle for the same occurrence is deduplicated.
        await controller.considerConfirmedApply(
            payload: payload,
            appliedImageURL: payload.originalURL!,
            appliedDisplayIDs: [display]
        )
        #expect(sender.deliveredNotifications.count == 1)
    }

    @Test("A deferred notification is dropped after the market midnight")
    @MainActor
    func deferredNotificationDroppedAfterMarketMidnight() async {
        let defaults = NotificationFixtures.defaults()
        let clock = NotificationTestClock(
            NotificationFixtures.marketInstant(day: "2026-11-24", hour: 23, minute: 58)
        )
        let sender = FakeDailyNotificationSender(status: .notDetermined)
        sender.requestedStatus = .authorized
        let controller = DailyNotificationController(
            defaults: defaults,
            sender: sender,
            now: { clock.date }
        )
        let payload = NotificationFixtures.payload(
            sourceDate: "2026-11-24",
            marketToday: "2026-11-24"
        )
        let applied = [display: payload.originalURL!]

        controller.captureBaseline(appliedURLs: [:])
        await controller.considerAppliedSnapshot(payload: payload, appliedURLs: applied)
        #expect(sender.deliveredNotifications.isEmpty)
        #expect(!controller.isEnabled)

        // The user grants permission after the market midnight. The observed
        // apply belongs to the previous source date and must not be delivered
        // as "today's" notification.
        clock.date = NotificationFixtures.marketInstant(day: "2026-11-25", hour: 0, minute: 2)
        await controller.prepareAuthorizationIfNeeded()

        #expect(controller.isEnabled)
        #expect(sender.deliveredNotifications.isEmpty)
        #expect(DailyWallpaperNotificationSettings(defaults: defaults).lastReceipt == nil)
    }
}

// MARK: - Foreground presentation

@Suite("Daily notification foreground presentation")
struct DailyNotificationForegroundTests {
    @Test("Foreground presentation shows one banner/list entry without sound or badge")
    func foregroundPresentationOptions() {
        let options = DailyWallpaperNotificationPresentation.foreground
        #expect(options == [.banner, .list])
        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(!options.contains(.sound))
        #expect(!options.contains(.badge))
    }
}

// MARK: - Install location

@Suite("Daily notification install location")
struct DailyNotificationInstallLocationTests {
    @Test("Temporary bundle locations are recognized")
    func temporaryLocations() {
        #expect(DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(
                fileURLWithPath: "/private/tmp/daybreak-menuquit-signed/Daybreak.app",
                isDirectory: true
            )
        ))
        #expect(DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(fileURLWithPath: "/tmp/Daybreak.app", isDirectory: true)
        ))
        #expect(DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            ).appendingPathComponent("Daybreak.app", isDirectory: true)
        ))
    }

    @Test("Stable bundle locations are not reported as temporary")
    func stableLocations() {
        #expect(!DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(fileURLWithPath: "/Applications/Daybreak.app", isDirectory: true)
        ))
        #expect(!DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(
                fileURLWithPath: "/Users/example/Applications/Daybreak.app",
                isDirectory: true
            )
        ))
        #expect(!DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(
                fileURLWithPath: "/Users/example/Library/Caches/DaybreakProbe/Daybreak.app",
                isDirectory: true
            )
        ))
        #expect(!DailyWallpaperNotificationInstallLocation.isTemporary(
            bundleURL: URL(fileURLWithPath: "/private/tmpfoo/Daybreak.app", isDirectory: true)
        ))
    }
}

// MARK: - Attachment

@Suite("Daily notification attachment")
struct DailyNotificationAttachmentTests {
    @Test("The cached thumbnail is copied to a temporary file and cleaned up")
    func copiesAndCleansUp() throws {
        let fileManager = FileManager.default
        let sourceDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DaybreakNotificationSource-\(UUID().uuidString)")
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sourceDirectory) }
        let sourceURL = sourceDirectory.appendingPathComponent("thumbnail.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: sourceURL)

        let attachment = try DailyWallpaperNotificationAttachment.prepare(
            thumbnailURL: sourceURL
        )
        defer { attachment.cleanUp() }

        #expect(attachment.fileURL != sourceURL)
        #expect(fileManager.fileExists(atPath: attachment.fileURL.path))
        #expect(fileManager.fileExists(atPath: sourceURL.path))
        #expect(attachment.fileURL.pathExtension == "jpg")

        attachment.cleanUp()
        #expect(!fileManager.fileExists(atPath: attachment.directoryURL.path))
        #expect(fileManager.fileExists(atPath: sourceURL.path))
    }

    @Test("A missing cached thumbnail fails without inventing a file")
    func missingThumbnailFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).jpg")
        #expect(throws: CocoaError.self) {
            _ = try DailyWallpaperNotificationAttachment.prepare(thumbnailURL: missing)
        }
    }
}
