import AppKit
import DaybreakCore
import Foundation
import Observation
import UserNotifications
import os

// MARK: - Authorization

/// The app-facing subset of `UNAuthorizationStatus` used by the settings UI and
/// the delivery gate. Only the allowed cases may ever claim a notification was
/// delivered.
enum DailyNotificationAuthorization: String, Sendable, Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        @unknown default: self = .unknown
        }
    }
}

/// The raw `NSError` from UserNotifications. Kept field-by-field so the app
/// reports the real cause instead of rewriting an infrastructure failure as a
/// user denial.
struct DailyWallpaperNotificationFailure: Equatable, Sendable {
    let domain: String
    let code: Int
    let detail: String

    init(domain: String, code: Int, detail: String) {
        self.domain = domain
        self.code = code
        self.detail = detail
    }

    init(_ error: Error) {
        let nsError = error as NSError
        self.init(
            domain: nsError.domain,
            code: nsError.code,
            detail: nsError.localizedDescription
        )
    }

    /// `UNErrorCodeNotificationsNotAllowed`. On macOS this means the system
    /// did not register the running build for notifications at all. A first
    /// request from a temporary folder is a confirmed cause even for a
    /// complete, validly ad-hoc-signed bundle; the same bundle registers once
    /// it is moved to a stable folder. Invalid signatures also produce this
    /// error, so the location check only refines the explanation.
    var isNotificationsNotAllowed: Bool {
        domain == "UNErrorDomain" && code == 1
    }
}

/// Whether the running bundle is at a location macOS treats as temporary.
///
/// `UserNotifications` registers a notification client only for an app at a
/// stable location. A first authorization request from `/tmp` or the per-user
/// temporary directory is rejected with `UNErrorDomain` 1 before the system
/// prompt appears, even for a complete `.app` with a valid ad-hoc signature.
/// LaunchServices records those bundles with its `in-temp-dir` flag, which is
/// not exposed by a public API; these roots are the public equivalent.
///
/// This only chooses the explanation shown for a system rejection. It never
/// skips the system request or claims a notification was delivered.
enum DailyWallpaperNotificationInstallLocation {
    static func isTemporary(bundleURL: URL) -> Bool {
        var candidatePaths = [
            bundleURL.standardizedFileURL.path,
            bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        candidatePaths = candidatePaths.map { path in
            var trimmed = path
            while trimmed.count > 1, trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            return trimmed
        }

        let roots = ["/private/tmp", "/tmp", NSTemporaryDirectory()]
        for root in roots {
            var rootPath = URL(fileURLWithPath: root, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            while rootPath.count > 1, rootPath.hasSuffix("/") {
                rootPath.removeLast()
            }
            for candidate in candidatePaths where
                candidate == rootPath || candidate.hasPrefix(rootPath + "/")
            {
                return true
            }
        }
        return false
    }
}

enum DailyWallpaperNotificationAuthorizationOutcome: Equatable, Sendable {
    /// The status reported by the system plus the `granted` Bool returned by
    /// `requestAuthorization`. The Bool is authoritative when the settings
    /// snapshot has not caught up yet.
    case resolved(DailyNotificationAuthorization, granted: Bool)
    case failed(DailyWallpaperNotificationFailure)
}

// MARK: - Notification value types

struct DailyWallpaperNotificationRequest: Sendable, Equatable {
    /// The occurrence this notification describes. Used for both the receipt
    /// and the system request identifier so one occurrence can never stack
    /// multiple delivered notifications.
    let occurrenceDescription: String
    let title: String
    let body: String
    /// A cached, genuine thumbnail. The sender copies it to a temporary file
    /// before handing it to UserNotifications.
    let thumbnailURL: URL?
}

enum DailyWallpaperNotificationDelivery: Sendable, Equatable {
    /// The system accepted the notification request. This is the only value
    /// that allows the app to record an occurrence receipt.
    case delivered
    /// The system permission does not allow alerts right now.
    case notAuthorized
    /// The request was rejected. No receipt is recorded. The underlying
    /// `NSError` is kept so the UI can show the real cause.
    case failed(DailyWallpaperNotificationFailure)
}

struct DailyWallpaperNotificationReceipt: Codable, Equatable, Sendable {
    let occurrenceDescription: String
    let notifiedAt: Date
}

// MARK: - Persistence

/// Lightweight settings and occurrence receipt storage. The receipt stores only
/// the occurrence identity and delivery time, never story text or media.
struct DailyWallpaperNotificationSettings {
    static let enabledKey = "daybreak.dailyWallpaperNotificationsEnabled.v1"
    static let receiptKey = "daybreak.dailyWallpaperNotificationReceipt.v1"
    static let userChoiceKey = "daybreak.dailyWallpaperNotificationsUserChoice.v1"

    /// A durable record of an explicit in-app decision. It lets the launch
    /// preparation ask the system once for users who never decided, while a
    /// user who turned notifications off is never prompted again.
    enum UserChoice: String {
        case on
        case off
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var userChoice: UserChoice? {
        get {
            guard let raw = defaults.string(forKey: Self.userChoiceKey) else {
                return nil
            }
            return UserChoice(rawValue: raw)
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.userChoiceKey)
                return
            }
            defaults.set(newValue.rawValue, forKey: Self.userChoiceKey)
        }
    }

    var lastReceipt: DailyWallpaperNotificationReceipt? {
        get {
            guard let data = defaults.data(forKey: Self.receiptKey) else {
                return nil
            }
            return try? JSONDecoder().decode(
                DailyWallpaperNotificationReceipt.self,
                from: data
            )
        }
        nonmutating set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue)
            else {
                defaults.removeObject(forKey: Self.receiptKey)
                return
            }
            defaults.set(data, forKey: Self.receiptKey)
        }
    }
}

// MARK: - Decision policy

enum DailyWallpaperNotificationAssessment: Equatable {
    case notify(DailyWallpaperNotificationRequest)
    case skip(SkipReason)

    enum SkipReason: Equatable {
        case disabled
        case staleSourceDate
        case noOriginalImage
        case alreadyNotified
        case notNewlyApplied

        /// Stable diagnostic label. Never user-facing copy.
        var logLabel: String {
            switch self {
            case .disabled: return "disabled"
            case .staleSourceDate: return "staleSourceDate"
            case .noOriginalImage: return "noOriginalImage"
            case .alreadyNotified: return "alreadyNotified"
            case .notNewlyApplied: return "notNewlyApplied"
            }
        }
    }
}

/// Pure rules for "the new daily wallpaper was really applied". Every guard is
/// intentionally fail-closed: only a confirmed applied-URL transition — or an
/// explicit confirmed write outcome — for the current market-local day produces
/// a notification.
enum DailyWallpaperNotificationPolicy {
    static func assess(
        payload: TodayPayload?,
        now: Date,
        isEnabled: Bool,
        appliedURLs: [DesktopDisplayID: URL],
        previouslyAppliedURLs: [DesktopDisplayID: URL],
        lastReceipt: DailyWallpaperNotificationReceipt?,
        locale: Locale
    ) -> DailyWallpaperNotificationAssessment {
        let eligibilityResult = eligibility(
            payload: payload,
            now: now,
            isEnabled: isEnabled,
            lastReceipt: lastReceipt
        )
        let eligible: EligiblePayload
        switch eligibilityResult {
        case .skipped(let reason):
            return .skip(reason)
        case .eligible(let payload):
            eligible = payload
        }

        // The integration's applied map only changes after a confirmed backend
        // write. Requiring a per-display transition distinguishes a real apply
        // from a stale persisted map that merely contains the same URL after a
        // relaunch.
        var newlyApplied = false
        for (displayID, url) in appliedURLs {
            if url == eligible.originalURL,
               previouslyAppliedURLs[displayID] != eligible.originalURL {
                newlyApplied = true
                break
            }
        }
        guard newlyApplied else { return .skip(.notNewlyApplied) }

        return .notify(request(for: eligible.payload, locale: locale))
    }

    /// Explicit pass outcomes are authoritative: the app already knows the
    /// backend confirmed this image for these displays. This path covers a
    /// manual or automatic pass whose occurrence is newly applied even when the
    /// image URL itself happens to be unchanged (for example a reused Bing
    /// asset), which a URL-diff snapshot cannot observe.
    static func assessConfirmedApply(
        payload: TodayPayload?,
        now: Date,
        isEnabled: Bool,
        appliedImageURL: URL,
        appliedDisplayIDs: [DesktopDisplayID],
        lastReceipt: DailyWallpaperNotificationReceipt?,
        locale: Locale
    ) -> DailyWallpaperNotificationAssessment {
        let eligibilityResult = eligibility(
            payload: payload,
            now: now,
            isEnabled: isEnabled,
            lastReceipt: lastReceipt
        )
        let eligible: EligiblePayload
        switch eligibilityResult {
        case .skipped(let reason):
            return .skip(reason)
        case .eligible(let payload):
            eligible = payload
        }
        guard !appliedDisplayIDs.isEmpty,
              appliedImageURL == eligible.originalURL
        else {
            return .skip(.notNewlyApplied)
        }
        return .notify(request(for: eligible.payload, locale: locale))
    }

    private enum Eligibility {
        case eligible(EligiblePayload)
        case skipped(DailyWallpaperNotificationAssessment.SkipReason)
    }

    private struct EligiblePayload {
        let payload: TodayPayload
        let originalURL: URL
    }

    private static func eligibility(
        payload: TodayPayload?,
        now: Date,
        isEnabled: Bool,
        lastReceipt: DailyWallpaperNotificationReceipt?
    ) -> Eligibility {
        guard isEnabled else { return .skipped(.disabled) }
        guard let payload else { return .skipped(.notNewlyApplied) }
        // Resolve the current market-local day from the injected clock instead
        // of the payload's frozen `marketToday`. A cached payload from before a
        // market midnight must not produce a "today" notification after a
        // failed or skipped refresh. An unknown market fails closed.
        guard let profile = BingMarketProfile.profile(for: payload.market),
              let marketToday = LocalDate(date: now, timeZone: profile.timeZone)
        else {
            return .skipped(.staleSourceDate)
        }
        guard payload.sourceDate == marketToday else {
            return .skipped(.staleSourceDate)
        }
        guard let originalURL = payload.originalURL else {
            return .skipped(.noOriginalImage)
        }
        guard lastReceipt?.occurrenceDescription != payload.key.description else {
            return .skipped(.alreadyNotified)
        }
        return .eligible(EligiblePayload(payload: payload, originalURL: originalURL))
    }

    /// Builds the notification from genuine source fields only.
    ///
    /// Title: story title, then story headline, then the image title. Body:
    /// headline and quick fact (or the story description when neither exists).
    /// Copyright is attribution, never an introduction, and is never used here.
    static func request(
        for payload: TodayPayload,
        locale: Locale
    ) -> DailyWallpaperNotificationRequest {
        let story = payload.storyMatch?.story
        let availableStory = payload.storyMatch?.availableStory
        let title = firstNonEmpty([story?.title, story?.headline, payload.title])
            ?? MacLocalizedString.resolve("今日 Bing 壁纸已应用", locale: locale)

        var parts: [String] = []
        func append(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != title,
                  !parts.contains(trimmed)
            else {
                return
            }
            parts.append(trimmed)
        }
        if let availableStory {
            append(availableStory.headline)
            append(availableStory.quickFact)
            if parts.isEmpty {
                append(availableStory.body)
            }
        }
        let body = parts.isEmpty
            ? MacLocalizedString.resolve("已应用今天的必应壁纸。来源未提供可读的每日介绍。", locale: locale)
            : parts.joined(separator: "\n")

        return DailyWallpaperNotificationRequest(
            occurrenceDescription: payload.key.description,
            title: title,
            body: body,
            thumbnailURL: payload.thumbnailURL
        )
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

// MARK: - Attachment copy

/// A temporary copy of the cached thumbnail. UserNotifications moves the file
/// it receives into its own store, so the app never hands over a repository
/// file and always removes its copy afterwards.
struct DailyWallpaperNotificationAttachment: Sendable, Equatable {
    let fileURL: URL
    let directoryURL: URL

    static func prepare(thumbnailURL: URL) throws -> DailyWallpaperNotificationAttachment {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: thumbnailURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "DaybreakNotification-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionName = thumbnailURL.pathExtension
        let fileName = extensionName.isEmpty
            ? "thumbnail"
            : "thumbnail.\(extensionName)"
        let destination = directory.appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: thumbnailURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return DailyWallpaperNotificationAttachment(
            fileURL: destination,
            directoryURL: directory
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

// MARK: - System sender

@MainActor
protocol DailyWallpaperNotificationSending: AnyObject {
    func authorizationStatus() async -> DailyNotificationAuthorization
    /// Presents the system prompt when the system has not decided yet.
    func requestAuthorization() async -> DailyWallpaperNotificationAuthorizationOutcome
    /// `allowWhenAuthorizationStatusIsStale` is set only immediately after a
    /// successful grant whose settings snapshot has not refreshed yet. The
    /// system's add call remains the authority; this never fabricates success.
    func deliver(
        _ notification: DailyWallpaperNotificationRequest,
        allowWhenAuthorizationStatusIsStale: Bool
    ) async -> DailyWallpaperNotificationDelivery
}

/// Presentation options for an already-authorized notification while Daybreak
/// is frontmost. A wallpaper notice is informational, so it never plays a
/// sound or badges the app. Without a `UNUserNotificationCenterDelegate` that
/// implements `willPresent`, UserNotifications suppresses foreground alerts
/// entirely: `add` succeeds, but the user never sees anything.
enum DailyWallpaperNotificationPresentation {
    /// A banner plus a Notification Center entry: one notification, shown while
    /// Daybreak is frontmost and still findable afterwards. Never sound/badge.
    static var foreground: UNNotificationPresentationOptions { [.banner, .list] }
}

/// The delegate is intentionally stateless and retained by the sender. It only
/// chooses how an already-delivered request is presented in the foreground; it
/// never schedules or duplicates a notification.
final class DailyWallpaperForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(DailyWallpaperNotificationPresentation.foreground)
    }
}

/// Local-only delivery through UserNotifications. No backend, telemetry or
/// remote service is involved.
@MainActor
final class SystemDailyWallpaperNotificationSender: DailyWallpaperNotificationSending {
    private let center: UNUserNotificationCenter
    private let presenter = DailyWallpaperForegroundPresenter()
    private static let logger = Logger(
        subsystem: "dev.daybreak.mac",
        category: "DailyNotificationSender"
    )

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        // Set as early as the app model is created so a notification added
        // while Daybreak is frontmost is actually presented. The center holds
        // the delegate weakly; the sender owns it for the process lifetime.
        center.delegate = presenter
    }

    func authorizationStatus() async -> DailyNotificationAuthorization {
        let settings = await center.notificationSettings()
        return DailyNotificationAuthorization(settings.authorizationStatus)
    }

    func requestAuthorization() async -> DailyWallpaperNotificationAuthorizationOutcome {
        do {
            // Alerts only: a new wallpaper is informational and must not make
            // sound or badge the app. No provisional authorization is requested.
            let granted = try await center.requestAuthorization(options: [.alert])
            // Reading settings immediately can race the prompt's decision. The
            // Bool is the direct answer; the status may still be
            // `.notDetermined` for a short time after a real grant.
            let status = await authorizationStatus()
            return .resolved(status, granted: granted)
        } catch {
            // A thrown error means the system never presented a choice. It must
            // not be rewritten as a user denial; `setEnabled` reports the raw
            // domain/code/message and offers a retry.
            return .failed(DailyWallpaperNotificationFailure(error))
        }
    }

    func deliver(
        _ notification: DailyWallpaperNotificationRequest,
        allowWhenAuthorizationStatusIsStale: Bool
    ) async -> DailyWallpaperNotificationDelivery {
        if !allowWhenAuthorizationStatusIsStale {
            let settings = await center.notificationSettings()
            guard DailyNotificationAuthorization(settings.authorizationStatus).allowsDelivery else {
                return .notAuthorized
            }
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body

        var preparedAttachment: DailyWallpaperNotificationAttachment?
        if let thumbnailURL = notification.thumbnailURL {
            let prepared = try? DailyWallpaperNotificationAttachment.prepare(
                thumbnailURL: thumbnailURL
            )
            if let prepared,
               let attachment = try? UNNotificationAttachment(
                   identifier: "daybreak-thumbnail",
                   url: prepared.fileURL,
                   options: nil
               ) {
                content.attachments = [attachment]
                preparedAttachment = prepared
            } else {
                prepared?.cleanUp()
            }
        }
        defer { preparedAttachment?.cleanUp() }

        let request = UNNotificationRequest(
            identifier: "daybreak.daily.\(notification.occurrenceDescription)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .delivered
        } catch {
            let failure = DailyWallpaperNotificationFailure(error)
            Self.logger.error(
                "add rejected domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
            )
            return .failed(failure)
        }
    }
}

// MARK: - Controller

/// Owns the persisted opt-in, the actual system permission state and the
/// once-per-occurrence delivery receipt. `AppModel` creates exactly one and
/// hands it to both the Settings UI and the applied-wallpaper snapshot path.
@MainActor
@Observable
final class DailyNotificationController {
    private(set) var isEnabled: Bool
    private(set) var authorization: DailyNotificationAuthorization = .unknown
    /// Non-nil only when the last system request threw before presenting a
    /// choice. This is not a denial, and the UI must not send the user to a
    /// notification settings pane that may not list this build at all.
    private(set) var authorizationFailure: DailyWallpaperNotificationFailure?
    /// True when the system returned a non-grant without a definitive status
    /// (still `.notDetermined`/`.unknown`). This is not a denial; the UI must
    /// keep showing the real undecided state and offer a retry.
    private(set) var authorizationRequestIncomplete = false
    private(set) var errorMessage: String?
    private(set) var isUpdating = false

    private let settings: DailyWallpaperNotificationSettings
    private let sender: any DailyWallpaperNotificationSending
    private let now: @Sendable () -> Date
    private var lastObservedAppliedURLs: [DesktopDisplayID: URL] = [:]
    private var hasBaseline = false
    private var isDelivering = false
    private var didPrepareThisLaunch = false
    private var preparationTask: Task<Void, Never>?
    /// A successful authorization result is authoritative until the settings
    /// snapshot reports a definitive state. It lets `deliver` call the system
    /// `add` even if `notificationSettings` is still `.notDetermined`; the add
    /// result is the only thing that records a receipt.
    private var hasConfirmedAuthorizationGrant = false
    /// A confirmed apply observed while the system authorization prompt is
    /// still pending. It is delivered once if the user grants permission
    /// shortly afterwards; this is a real observed transition, not a
    /// fabricated delivery.
    private var pendingAuthorizationNotification: PendingAuthorizationNotification?
    private var receipt: DailyWallpaperNotificationReceipt?

    /// Diagnostics only: never story text, notification bodies or file paths.
    private static let logger = Logger(
        subsystem: "dev.daybreak.mac",
        category: "DailyNotification"
    )

    /// The market-local day a notification decision was made for. A deferred
    /// delivery is re-validated against it so a grant that arrives after the
    /// market midnight cannot deliver the previous day's notice.
    private struct OccurrenceContext: Sendable, Equatable {
        let market: Market
        let sourceDate: LocalDate

        func isCurrentDay(at date: Date) -> Bool {
            guard let profile = BingMarketProfile.profile(for: market),
                  let today = LocalDate(date: date, timeZone: profile.timeZone)
            else {
                return false
            }
            return today == sourceDate
        }
    }

    private struct PendingAuthorizationNotification {
        let request: DailyWallpaperNotificationRequest
        let context: OccurrenceContext
        let observedAt: Date
    }

    /// A deferred notification older than this is no longer about the
    /// wallpaper the user just watched change.
    private static let pendingNotificationLifetime: TimeInterval = 5 * 60

    init(
        defaults: UserDefaults = .standard,
        sender: (any DailyWallpaperNotificationSending)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = DailyWallpaperNotificationSettings(defaults: defaults)
        self.sender = sender ?? SystemDailyWallpaperNotificationSender()
        self.now = now
        self.isEnabled = settings.isEnabled
        self.receipt = settings.lastReceipt
    }

    var isDenied: Bool { authorization == .denied }

    /// A thrown or incomplete request is retryable. A status-confirmed denial
    /// is not: it must be changed by the user in System Settings.
    var canRetryAuthorization: Bool {
        authorizationFailure != nil || authorizationRequestIncomplete
    }

    /// Only a real `.denied` status may offer the system settings pane. A
    /// failed request for an unsigned or unregistered build has no entry there.
    var canOpenSystemSettings: Bool { authorization == .denied }

    /// The actual system state. This never reports that a notification was
    /// delivered; delivery is not a permission state.
    var permissionLabel: String {
        let locale = WallpaperInterfaceLocale.current
        switch authorization {
        case .unknown:
            return canRetryAuthorization
                ? MacLocalizedString.resolve("通知授权未完成，可重试", locale: locale)
                : MacLocalizedString.resolve("正在检查通知权限…", locale: locale)
        case .notDetermined:
            return canRetryAuthorization
                ? MacLocalizedString.resolve("通知授权未完成，可重试", locale: locale)
                : MacLocalizedString.resolve("尚未获得系统通知权限", locale: locale)
        case .denied:
            return MacLocalizedString.resolve("系统通知已拒绝", locale: locale)
        case .authorized:
            return MacLocalizedString.resolve("系统通知已授权", locale: locale)
        case .provisional:
            return MacLocalizedString.resolve("系统通知已临时授权", locale: locale)
        case .ephemeral:
            return MacLocalizedString.resolve("系统通知仅本次会话有效", locale: locale)
        }
    }

    /// Called once when the notification feature is prepared at launch. The
    /// app asks the system on first use instead of hiding the request behind a
    /// settings toggle; it never asks again for an authorized or denied app,
    /// and never asks a user who explicitly turned notifications off.
    ///
    /// Migration rule: the pre-`userChoice` builds also wrote `isEnabled =
    /// false` when an authorization request failed and its error was swallowed.
    /// Therefore an absent `userChoice` is not an opt-out; only the explicit
    /// `.off` recorded by this build suppresses the first-run request. The
    /// system's `.denied` status always wins and is never requested again.
    ///
    /// The method is awaitable and idempotent: startup code (for example the
    /// login-item prompt) can await it to ensure the two system dialogs never
    /// overlap, and a later call from `AppModel` joins the same operation.
    func prepareAuthorizationIfNeeded() async {
        if let preparationTask {
            await preparationTask.value
            return
        }
        guard !didPrepareThisLaunch else { return }
        didPrepareThisLaunch = true
        let task = Task { [weak self] in
            guard let self else { return }
            self.authorization = await self.sender.authorizationStatus()
            Self.logger.debug(
                "launch preparation status=\(self.authorization.rawValue, privacy: .public) optedOut=\(self.settings.userChoice == .off, privacy: .public)"
            )
            guard self.authorization == .notDetermined,
                  self.settings.userChoice != .off
            else {
                return
            }
            guard !self.isUpdating else { return }
            await self.requestAuthorization()
        }
        preparationTask = task
        await task.value
    }

    /// The explicit user action. Turning the toggle off never touches system
    /// settings.
    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        errorMessage = nil
        guard enabled else {
            isEnabled = false
            settings.isEnabled = false
            settings.userChoice = .off
            authorizationFailure = nil
            authorizationRequestIncomplete = false
            hasConfirmedAuthorizationGrant = false
            pendingAuthorizationNotification = nil
            return
        }
        guard !isEnabled else { return }
        isUpdating = true
        Task { [weak self] in
            await self?.requestAuthorization()
        }
    }

    /// Retries a request that threw before the system presented a choice.
    func retryAuthorizationRequest() {
        guard !isUpdating else { return }
        errorMessage = nil
        isUpdating = true
        Task { [weak self] in
            await self?.requestAuthorization()
        }
    }

    /// Opens the system notification pane for this app. Read-only navigation:
    /// the app never changes the user's system notification settings itself.
    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else {
            errorMessage = MacLocalizedString.resolve("无法打开系统通知设置。", locale: WallpaperInterfaceLocale.current)
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorMessage = MacLocalizedString.resolve("无法打开系统通知设置。", locale: WallpaperInterfaceLocale.current)
        }
    }

    /// Reads the current system permission without presenting a prompt.
    func refreshPermission() async {
        guard !isUpdating else { return }
        let live = await sender.authorizationStatus()
        if live.allowsDelivery {
            authorization = live
            hasConfirmedAuthorizationGrant = true
            authorizationRequestIncomplete = false
        } else if live == .denied {
            authorization = .denied
            hasConfirmedAuthorizationGrant = false
            authorizationRequestIncomplete = false
            pendingAuthorizationNotification = nil
        } else {
            // A status snapshot that still says "not determined" must not
            // erase a grant the system already returned, and an incomplete
            // request stays visibly incomplete rather than becoming a denial.
            authorization = hasConfirmedAuthorizationGrant ? .authorized : live
        }
        if authorization.allowsDelivery, authorizationFailure != nil {
            authorizationFailure = nil
            errorMessage = nil
        }
    }

    /// Records the applied map that existed before any new write may happen.
    /// Startup and market switches call this so a persisted applied URL cannot
    /// look like a fresh application.
    func captureBaseline(appliedURLs: [DesktopDisplayID: URL]) {
        lastObservedAppliedURLs = appliedURLs
        hasBaseline = true
        Self.logger.debug(
            "baseline captured displays=\(appliedURLs.count, privacy: .public)"
        )
    }

    /// Called after every confirmed integration snapshot change. Only a
    /// per-display transition to this occurrence's original image can notify.
    func considerAppliedSnapshot(
        payload: TodayPayload?,
        appliedURLs: [DesktopDisplayID: URL]
    ) async {
        let previous = lastObservedAppliedURLs
        let hadBaseline = hasBaseline
        lastObservedAppliedURLs = appliedURLs
        hasBaseline = true
        let context = payload.map {
            OccurrenceContext(market: $0.market, sourceDate: $0.sourceDate)
        }

        // The first observed map is a baseline, never a new application.
        guard hadBaseline else {
            Self.logger.debug("first snapshot treated as baseline")
            return
        }

        let assessment = DailyWallpaperNotificationPolicy.assess(
            payload: payload,
            now: now(),
            isEnabled: isEnabled,
            appliedURLs: appliedURLs,
            previouslyAppliedURLs: previous,
            lastReceipt: receipt,
            locale: WallpaperInterfaceLocale.current
        )
        switch assessment {
        case .notify(let request):
            Self.logger.notice(
                "snapshot transition notify market=\(payload?.market.rawValue ?? "none", privacy: .public) sourceDate=\(payload?.sourceDate.iso8601 ?? "none", privacy: .public)"
            )
            await deliver(request, context: context)
        case .skip(.disabled):
            rememberPendingNotificationIfAuthorizationPending(
                payload: payload,
                appliedURLs: appliedURLs,
                previouslyAppliedURLs: previous
            )
        case .skip(let reason):
            Self.logger.debug(
                "snapshot skip reason=\(reason.logLabel, privacy: .public)"
            )
        }
    }

    private static func context(for payload: TodayPayload) -> OccurrenceContext {
        OccurrenceContext(market: payload.market, sourceDate: payload.sourceDate)
    }

    /// The wallpaper can be written while the first-run permission prompt is
    /// still open. The transition is real, so keep the built request and
    /// deliver it once if the user grants permission shortly after. Nothing is
    /// delivered for a stale or explicitly opted-out preference.
    private func rememberPendingNotificationIfAuthorizationPending(
        payload: TodayPayload?,
        appliedURLs: [DesktopDisplayID: URL],
        previouslyAppliedURLs: [DesktopDisplayID: URL]
    ) {
        guard canDeferAuthorizationNotification, let payload else { return }
        let wouldNotify = DailyWallpaperNotificationPolicy.assess(
            payload: payload,
            now: now(),
            isEnabled: true,
            appliedURLs: appliedURLs,
            previouslyAppliedURLs: previouslyAppliedURLs,
            lastReceipt: receipt,
            locale: WallpaperInterfaceLocale.current
        )
        guard case .notify(let request) = wouldNotify else { return }
        pendingAuthorizationNotification = PendingAuthorizationNotification(
            request: request,
            context: Self.context(for: payload),
            observedAt: now()
        )
        Self.logger.debug("deferred notification stored pending authorization")
    }

    private func rememberPendingConfirmedApplyIfAuthorizationPending(
        payload: TodayPayload?,
        appliedImageURL: URL,
        appliedDisplayIDs: [DesktopDisplayID]
    ) {
        guard canDeferAuthorizationNotification, let payload else { return }
        let wouldNotify = DailyWallpaperNotificationPolicy.assessConfirmedApply(
            payload: payload,
            now: now(),
            isEnabled: true,
            appliedImageURL: appliedImageURL,
            appliedDisplayIDs: appliedDisplayIDs,
            lastReceipt: receipt,
            locale: WallpaperInterfaceLocale.current
        )
        guard case .notify(let request) = wouldNotify else { return }
        pendingAuthorizationNotification = PendingAuthorizationNotification(
            request: request,
            context: Self.context(for: payload),
            observedAt: now()
        )
        Self.logger.debug("deferred confirmed apply stored pending authorization")
    }

    /// The system has not decided yet, and the user has not explicitly opted
    /// out. Only in that state may a confirmed apply wait for the grant.
    private var canDeferAuthorizationNotification: Bool {
        if isEnabled { return false }
        if settings.userChoice == .off { return false }
        if authorizationFailure != nil { return false }
        return authorization == .notDetermined || authorization == .unknown
    }

    /// A confirmed manual or automatic pass is authoritative even when the
    /// applied URL is unchanged (a reused asset across occurrences). The caller
    /// passes the image the pass confirmed and the displays it settled —
    /// including displays the backend reported as already synchronized, never
    /// blocked or failed displays — and both are checked against the current
    /// payload before anything is delivered.
    func considerConfirmedApply(
        payload: TodayPayload?,
        appliedImageURL: URL,
        appliedDisplayIDs: [DesktopDisplayID]
    ) async {
        let context = payload.map {
            OccurrenceContext(market: $0.market, sourceDate: $0.sourceDate)
        }
        let assessment = DailyWallpaperNotificationPolicy.assessConfirmedApply(
            payload: payload,
            now: now(),
            isEnabled: isEnabled,
            appliedImageURL: appliedImageURL,
            appliedDisplayIDs: appliedDisplayIDs,
            lastReceipt: receipt,
            locale: WallpaperInterfaceLocale.current
        )
        switch assessment {
        case .notify(let request):
            Self.logger.notice(
                "confirmed apply notify market=\(payload?.market.rawValue ?? "none", privacy: .public) sourceDate=\(payload?.sourceDate.iso8601 ?? "none", privacy: .public)"
            )
            await deliver(request, context: context)
        case .skip(.disabled):
            rememberPendingConfirmedApplyIfAuthorizationPending(
                payload: payload,
                appliedImageURL: appliedImageURL,
                appliedDisplayIDs: appliedDisplayIDs
            )
        default:
            break
        }
    }

    /// The single delivery path for both snapshot transitions and confirmed
    /// writes. The receipt and in-flight flag make a second observer of the
    /// same occurrence a no-op.
    private func deliver(
        _ request: DailyWallpaperNotificationRequest,
        context: OccurrenceContext?
    ) async {
        guard !isDelivering,
              receipt?.occurrenceDescription != request.occurrenceDescription,
              isEnabled
        else {
            return
        }
        isDelivering = true
        defer { isDelivering = false }

        let status = await sender.authorizationStatus()
        // A grant can be reported before `notificationSettings` catches up.
        // Trust the successful request's Bool for this transient state, but
        // never override a definitive denial. The system `add` call below is
        // still the only source of a receipt.
        var allowStaleAuthorization = false
        if !status.allowsDelivery,
           status == .notDetermined,
           hasConfirmedAuthorizationGrant {
            allowStaleAuthorization = true
        }
        authorization = allowStaleAuthorization ? .authorized : status
        guard status.allowsDelivery || allowStaleAuthorization else {
            // The wallpaper was already applied; a first-run or resumed
            // authorization may still be in flight. Keep the built request so
            // a successful grant can deliver it once instead of losing it. A
            // request without an occurrence context cannot be re-validated
            // against the market day, so it is never deferred.
            if status == .notDetermined,
               settings.userChoice != .off,
               authorizationFailure == nil,
               let context {
                pendingAuthorizationNotification = PendingAuthorizationNotification(
                    request: request,
                    context: context,
                    observedAt: now()
                )
            }
            errorMessage = unauthorizedMessage(for: status)
            Self.logger.notice(
                "delivery withheld authorization=\(status.rawValue, privacy: .public)"
            )
            return
        }

        switch await sender.deliver(
            request,
            allowWhenAuthorizationStatusIsStale: allowStaleAuthorization
        ) {
        case .delivered:
            hasConfirmedAuthorizationGrant = true
            let deliveredReceipt = DailyWallpaperNotificationReceipt(
                occurrenceDescription: request.occurrenceDescription,
                notifiedAt: now()
            )
            receipt = deliveredReceipt
            settings.lastReceipt = deliveredReceipt
            authorizationFailure = nil
            errorMessage = nil
            Self.logger.notice(
                "delivered occurrence=\(request.occurrenceDescription, privacy: .public) staleAuthorization=\(allowStaleAuthorization, privacy: .public)"
            )
        case .notAuthorized:
            let current = await sender.authorizationStatus()
            authorization = current
            hasConfirmedAuthorizationGrant = current.allowsDelivery
            errorMessage = unauthorizedMessage(for: current)
            Self.logger.notice(
                "delivery rejected authorization=\(current.rawValue, privacy: .public)"
            )
        case .failed(let failure):
            errorMessage = String(
                format: MacLocalizedString.resolve("壁纸已应用，但通知发送失败（%@ %ld）：%@，本次没有送达。", locale: WallpaperInterfaceLocale.current),
                failure.domain,
                failure.code,
                failure.detail
            )
            Self.logger.error(
                "delivery failed domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
            )
        }
    }

    private func requestAuthorization() async {
        isUpdating = true
        defer { isUpdating = false }
        authorizationFailure = nil

        switch await sender.requestAuthorization() {
        case .failed(let failure):
            Self.logger.error(
                "authorization request failed domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
            )
            let live = await sender.authorizationStatus()
            if live.allowsDelivery {
                // The request can throw after the system has already retained
                // an authorization decision. Trust that live decision and do
                // not leave a stale request error in the settings UI.
                authorization = live
                isEnabled = true
                settings.isEnabled = true
                settings.userChoice = .on
                hasConfirmedAuthorizationGrant = true
                authorizationRequestIncomplete = false
                authorizationFailure = nil
                errorMessage = nil
            } else {
                // The system never presented a usable decision. Keep the
                // opt-in state unchanged, show the raw cause, and let the user
                // retry when the request is still incomplete.
                if hasConfirmedAuthorizationGrant, live == .notDetermined {
                    authorization = .authorized
                } else {
                    authorization = live
                }
                authorizationFailure = failure
                errorMessage = Self.requestFailureMessage(
                    failure,
                    locale: WallpaperInterfaceLocale.current
                )
            }
        case .resolved(let status, let granted):
            // Only a lagging `.notDetermined`/`.unknown` may use the Bool to
            // resolve a grant. An explicit `.denied` always wins, even if the
            // system's Bool is contradictory.
            let staleStatusAllowsGrant: Bool
            if granted, (status == .notDetermined || status == .unknown) {
                staleStatusAllowsGrant = true
            } else {
                staleStatusAllowsGrant = false
            }
            let allowed = status.allowsDelivery || staleStatusAllowsGrant
            Self.logger.notice(
                "authorization resolved status=\(status.rawValue, privacy: .public) granted=\(granted, privacy: .public) allowed=\(allowed, privacy: .public)"
            )
            if status.allowsDelivery {
                authorization = status
            } else if status == .denied {
                authorization = .denied
            } else if staleStatusAllowsGrant {
                authorization = .authorized
            } else {
                authorization = status
            }
            guard allowed else {
                isEnabled = false
                settings.isEnabled = false
                hasConfirmedAuthorizationGrant = false
                pendingAuthorizationNotification = nil
                if status == .denied {
                    authorizationRequestIncomplete = false
                    settings.userChoice = .off
                    errorMessage = MacLocalizedString.resolve("系统没有授予通知权限，本次没有开启。若系统设置的“通知”中没有 Daybreak，请改用已签名的构建后重试；否则请允许 Daybreak 的通知后再试。", locale: WallpaperInterfaceLocale.current)
                } else {
                    // The status is genuinely undecided; do not show a denial
                    // and do not persist an opt-out. The request can be retried.
                    authorizationRequestIncomplete = true
                    errorMessage = MacLocalizedString.resolve("系统通知授权尚未完成（仍为未决定）。", locale: WallpaperInterfaceLocale.current) + "\n" + Self.installLocationGuidance(
                        isTemporaryLocation: DailyWallpaperNotificationInstallLocation.isTemporary(
                            bundleURL: Bundle.main.bundleURL
                        ),
                        locale: WallpaperInterfaceLocale.current
                    )
                }
                return
            }
            isEnabled = true
            settings.isEnabled = true
            settings.userChoice = .on
            hasConfirmedAuthorizationGrant = true
            authorizationRequestIncomplete = false
            errorMessage = nil
            let pending = pendingAuthorizationNotification
            pendingAuthorizationNotification = nil
            if let pending {
                let age = now().timeIntervalSince(pending.observedAt)
                if age <= Self.pendingNotificationLifetime,
                   pending.context.isCurrentDay(at: now()) {
                    await deliver(pending.request, context: pending.context)
                } else {
                    // The day or the prompt window moved on. The request
                    // described a wallpaper the user may no longer be looking
                    // at, so it is dropped instead of delivered late.
                    Self.logger.notice(
                        "deferred notification dropped staleAge=\(age > Self.pendingNotificationLifetime, privacy: .public)"
                    )
                }
            }
        }
    }

    private func unauthorizedMessage(for status: DailyNotificationAuthorization) -> String {
        let locale = WallpaperInterfaceLocale.current
        if status == .notDetermined {
            if let authorizationFailure {
                return String(
                    format: MacLocalizedString.resolve("壁纸已应用，但通知授权请求失败（%@ %ld），本次没有发送通知。", locale: locale),
                    authorizationFailure.domain,
                    authorizationFailure.code
                )
            }
        }
        switch status {
        case .notDetermined:
            return MacLocalizedString.resolve("壁纸已应用，但系统通知授权尚未完成，本次没有发送通知。", locale: locale)
        case .denied:
            return MacLocalizedString.resolve("壁纸已应用，但系统通知已被拒绝，本次没有发送通知。", locale: locale)
        default:
            return MacLocalizedString.resolve("壁纸已应用，但系统未授权通知，本次没有发送通知。", locale: locale)
        }
    }

    private static func requestFailureMessage(
        _ failure: DailyWallpaperNotificationFailure,
        locale: Locale
    ) -> String {
        let raw = String(
            format: MacLocalizedString.resolve("系统通知授权请求失败（%@ %ld）：%@", locale: locale),
            failure.domain,
            failure.code,
            failure.detail
        )
        if failure.isNotificationsNotAllowed {
            return raw + "\n" + installLocationGuidance(
                isTemporaryLocation: DailyWallpaperNotificationInstallLocation.isTemporary(
                    bundleURL: Bundle.main.bundleURL
                ),
                locale: locale
            )
        }
        return raw + "\n" + MacLocalizedString.resolve(
            "请重试；如果仍然失败，请确认运行的是已签名的完整 App 包。",
            locale: locale
        )
    }

    /// Actionable guidance for a system rejection. It never rewrites the
    /// system's error and never presents a denied choice as a build failure.
    private static func installLocationGuidance(
        isTemporaryLocation: Bool,
        locale: Locale
    ) -> String {
        if isTemporaryLocation {
            return MacLocalizedString.resolve("当前 Daybreak 正在临时文件夹中运行。macOS 不会为临时位置的 App 首次注册通知客户端，因此系统没有显示授权提示，系统设置里也不会出现 Daybreak。请把 Daybreak 安装到稳定的“应用程序”文件夹（例如 ~/Applications 或 /Applications），从那里启动一次并允许通知。", locale: locale)
        }
        return MacLocalizedString.resolve("macOS 没有把当前构建注册为通知客户端，所以系统没有显示授权提示，系统设置里也可能没有 Daybreak。请确认 Daybreak 是位于稳定文件夹（例如 ~/Applications）中的完整 .app，签名有效，并从那里启动一次后重试；这不是在通知设置中拒绝了 Daybreak。", locale: locale)
    }
}
