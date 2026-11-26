import DaybreakCore
import Foundation

/// How Daybreak treats wallpapers it did not write.
public enum MacDesktopAutomationMode: String, Codable, Sendable {
    /// Observe and report only. This is the persisted default.
    case readOnly
    /// The user opted into event-driven reconciliation. Enabling it never
    /// authorizes replacing an unverified wallpaper.
    case automatic
}

public enum MacWallpaperWriteAccess: String, Codable, Sendable {
    case readOnly
    case authorized
}

/// A settings load or save problem that the app must explain to the user.
///
/// The module deliberately does not localize this itself: the app owns the
/// interface language and maps `kind` to its own copy. `detail` is the
/// Foundation-provided description and is never Daybreak copy.
public struct MacDesktopSettingsIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case unsupportedSchemaVersion
        case unreadable
        case saveFailed
    }

    public let kind: Kind
    public let schemaVersion: Int?
    public let detail: String?

    public init(
        kind: Kind,
        schemaVersion: Int? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.detail = detail
    }
}

/// Why a write was conservatively refused.
public enum MacOverwriteBlockReason: String, Codable, Sendable, CaseIterable {
    /// The current wallpaper is not in Daybreak's managed ledger and the user
    /// has not approved overwriting this exact image.
    case unverifiedExternalWallpaper
    /// The public API did not report a current image URL.
    case unreadableCurrentWallpaper
    /// The user asked Daybreak to preserve the current wallpaper.
    case manualProtection
}

/// A write that was refused, together with the exact state that caused it.
public struct MacWriteGuardBlock: Hashable, Codable, Sendable, Identifiable {
    public let displayID: DesktopDisplayID
    public let observedImageURL: URL?
    public let desiredWallpaper: DesktopWallpaper
    public let reason: MacOverwriteBlockReason
    public let detectedAt: Date

    public init(
        displayID: DesktopDisplayID,
        observedImageURL: URL?,
        desiredWallpaper: DesktopWallpaper,
        reason: MacOverwriteBlockReason,
        detectedAt: Date
    ) {
        self.displayID = displayID
        self.observedImageURL = observedImageURL
        self.desiredWallpaper = desiredWallpaper
        self.reason = reason
        self.detectedAt = detectedAt
    }

    public var id: DesktopDisplayID { displayID }

    /// A nil observed URL cannot be approved: the confirmation flow re-reads
    /// the live URL and never matches nil. The UI must not offer a button that
    /// can never succeed.
    public var canConfirm: Bool { observedImageURL != nil }

    /// Ready-to-use request. The exact observed URL is captured so a stale
    /// confirmation cannot overwrite a newer wallpaper.
    public var confirmationRequest: MacOverwriteConfirmationRequest {
        MacOverwriteConfirmationRequest(
            displayID: displayID,
            observedImageURL: observedImageURL,
            desiredWallpaper: desiredWallpaper,
            reason: reason
        )
    }
}

/// User confirmation to replace one exact observed wallpaper on one display.
public struct MacOverwriteConfirmationRequest: Hashable, Sendable, Identifiable {
    public let displayID: DesktopDisplayID
    public let observedImageURL: URL?
    public let desiredWallpaper: DesktopWallpaper
    public let reason: MacOverwriteBlockReason

    public init(
        displayID: DesktopDisplayID,
        observedImageURL: URL?,
        desiredWallpaper: DesktopWallpaper,
        reason: MacOverwriteBlockReason
    ) {
        self.displayID = displayID
        self.observedImageURL = observedImageURL
        self.desiredWallpaper = desiredWallpaper
        self.reason = reason
    }

    public var id: DesktopDisplayID { displayID }
}

/// A user-pinned wallpaper that automation must not replace.
public struct MacManualProtectionRecord: Hashable, Codable, Sendable {
    public let displayID: DesktopDisplayID
    public let imageURL: URL?
    public let options: MacWallpaperOptions
    public let protectedAt: Date

    public init(
        displayID: DesktopDisplayID,
        imageURL: URL?,
        options: MacWallpaperOptions,
        protectedAt: Date
    ) {
        self.displayID = displayID
        self.imageURL = imageURL
        self.options = options
        self.protectedAt = protectedAt
    }
}

/// One-shot authorization to replace a specific observed wallpaper.
struct MacOverwriteApproval: Codable, Hashable, Sendable {
    let displayID: DesktopDisplayID
    let observedImageURL: URL?
    let target: DesktopWallpaper
    let approvedAt: Date
}

/// Persisted desktop settings. Kept internal so the public surface only exposes
/// the observable snapshot and explicit commands.
struct MacDesktopSettings: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 3
    /// Schemas 1 and 2 remain readable. Schema 1's explicit automatic-sync
    /// opt-in is kept, but it never implies the schema-2 automatic-overwrite
    /// opt-in. Schema 3 adds assignment provenance; older assignments decode
    /// as `.unknown` instead of being guessed or deleted.
    static let readableSchemaVersions: ClosedRange<Int> = 1...3

    var schemaVersion: Int = MacDesktopSettings.currentSchemaVersion
    var automationMode: MacDesktopAutomationMode = .readOnly
    /// Separate, default-off consent to replace an unverified current
    /// wallpaper during event-driven reconciliation. Persisted independently
    /// of auto sync; enabling auto sync never turns this on by itself.
    var automaticOverwriteEnabled: Bool = false
    var assignments: [DesktopDisplayAssignment] = []
    /// Every URL Daybreak successfully wrote. Survives launches so a wallpaper
    /// from the previous run is still recognised as Daybreak-managed.
    var managedImageURLs: Set<URL> = []
    /// Last successfully written URL per display, keyed by
    /// `DesktopDisplayID.rawValue`. Optional so settings written by earlier
    /// builds keep decoding; it is populated on the next successful write.
    var appliedImageURLsByDisplay: [String: URL]?
    var overwriteApprovals: [MacOverwriteApproval] = []
    var manualProtections: [MacManualProtectionRecord] = []

    static let `default` = MacDesktopSettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case automationMode
        case automaticOverwriteEnabled
        case assignments
        case managedImageURLs
        case appliedImageURLsByDisplay
        case overwriteApprovals
        case manualProtections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = version
        automationMode = try container.decodeIfPresent(
            MacDesktopAutomationMode.self,
            forKey: .automationMode
        ) ?? .readOnly
        assignments = try container.decodeIfPresent(
            [DesktopDisplayAssignment].self,
            forKey: .assignments
        ) ?? []
        managedImageURLs = try container.decodeIfPresent(
            Set<URL>.self,
            forKey: .managedImageURLs
        ) ?? []
        appliedImageURLsByDisplay = try container.decodeIfPresent(
            [String: URL].self,
            forKey: .appliedImageURLsByDisplay
        )
        overwriteApprovals = try container.decodeIfPresent(
            [MacOverwriteApproval].self,
            forKey: .overwriteApprovals
        ) ?? []
        manualProtections = try container.decodeIfPresent(
            [MacManualProtectionRecord].self,
            forKey: .manualProtections
        ) ?? []
        // Automatic overwrite did not exist before schema 2. Ignore any
        // injected value in older data so migration stays default-off.
        automaticOverwriteEnabled = version >= 2
            ? (try container.decodeIfPresent(Bool.self, forKey: .automaticOverwriteEnabled) ?? false)
            : false
        // Assignment provenance did not exist before schema 3. Ignore any
        // injected value in older data: guessing automatic could overwrite a
        // manual choice, so every pre-schema-3 assignment stays unknown.
        if version < 3 {
            assignments = assignments.map {
                DesktopDisplayAssignment(
                    displayID: $0.displayID,
                    wallpaper: $0.wallpaper,
                    source: .unknown
                )
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(automationMode, forKey: .automationMode)
        try container.encode(automaticOverwriteEnabled, forKey: .automaticOverwriteEnabled)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(managedImageURLs, forKey: .managedImageURLs)
        try container.encodeIfPresent(appliedImageURLsByDisplay, forKey: .appliedImageURLsByDisplay)
        try container.encode(overwriteApprovals, forKey: .overwriteApprovals)
        try container.encode(manualProtections, forKey: .manualProtections)
    }

    var assignmentMap: [DesktopDisplayID: DesktopWallpaper] {
        var map: [DesktopDisplayID: DesktopWallpaper] = [:]
        for assignment in assignments {
            map[assignment.displayID] = assignment.wallpaper
        }
        return map
    }

    var appliedWallpaperURLsByDisplay: [DesktopDisplayID: URL] {
        var result: [DesktopDisplayID: URL] = [:]
        for (rawValue, url) in appliedImageURLsByDisplay ?? [:] {
            guard !rawValue.isEmpty else { continue }
            result[DesktopDisplayID(rawValue)] = url
        }
        return result
    }
}

/// Context the applier needs to decide whether a write is safe.
struct MacGuardContext: Sendable {
    let isManaged: Bool
    let hasMatchingApproval: Bool
    let isManuallyProtected: Bool
    /// Only true when auto sync is active and the user separately enabled
    /// automatic overwrite. A persisted switch without an active automatic
    /// session must not broaden a manual pass.
    let allowsAutomaticOverwrite: Bool
}

/// Small, atomic, app-container JSON store.
///
/// Safety-relevant mutations that happen after a successful write are
/// best-effort persisted: failing to save the ledger must not turn a completed
/// wallpaper change into a reported failure. They still take effect in memory
/// and the persistence error is observable. User-visible intent changes
/// (assignments, mode, protection) throw and do not write wallpaper when they
/// cannot be persisted.
actor MacDesktopSettingsStore {
    static let fileName = "desktop-settings.json"
    private static let approvalLifetime: TimeInterval = 10 * 60

    private let directory: URL
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var settings: MacDesktopSettings?
    private var loadIssue: MacDesktopSettingsIssue?
    private var persistenceIssue: MacDesktopSettingsIssue?

    init(directory: URL?, now: @escaping @Sendable () -> Date) {
        let resolved = directory ?? Self.defaultDirectory()
        self.directory = resolved
        self.fileURL = resolved.appendingPathComponent(Self.fileName, isDirectory: false)
        self.now = now
    }

    private static func defaultDirectory() -> URL {
        let manager = FileManager.default
        if let base = try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return base
                .appendingPathComponent("Daybreak", isDirectory: true)
                .appendingPathComponent("Desktop", isDirectory: true)
        }
        return manager.temporaryDirectory.appendingPathComponent("Daybreak-Desktop", isDirectory: true)
    }

    // MARK: Reading

    func load() -> MacDesktopSettings {
        ensureLoaded()
        return settings ?? .default
    }

    func snapshot() -> MacDesktopSettings {
        ensureLoaded()
        return settings ?? .default
    }

    func currentLoadIssue() -> MacDesktopSettingsIssue? {
        ensureLoaded()
        return loadIssue
    }

    func currentPersistenceIssue() -> MacDesktopSettingsIssue? {
        persistenceIssue
    }

    // MARK: User intent (throwing)

    /// Explicitly replaces the given displays' targets with `source`. Used by
    /// the manual-apply path (manual provenance) and by actions that the user
    /// explicitly confirmed for the given displays, such as enabling auto sync
    /// (automatic provenance). It never touches displays outside `targets`.
    func mergeAssignments(
        _ targets: [DesktopDisplayID: DesktopWallpaper],
        source: DesktopAssignmentSource
    ) throws -> MacDesktopSettings {
        try update { current in
            var byDisplay = Dictionary(
                uniqueKeysWithValues: current.assignments.map { ($0.displayID, $0) }
            )
            for (displayID, wallpaper) in targets {
                byDisplay[displayID] = DesktopDisplayAssignment(
                    displayID: displayID,
                    wallpaper: wallpaper,
                    source: source
                )
            }
            current.assignments = byDisplay.values
                .sorted { $0.displayID < $1.displayID }
        }
    }

    /// Persists a new automatic target. Every existing automatic assignment is
    /// retargeted, including assignments for displays that are currently
    /// disconnected, so a reconnect cannot restore an older automatic image.
    /// Manual and pre-provenance assignments are preserved unless the caller
    /// is an explicit auto-sync opt-in for a connected display.
    func updateAutomaticTarget(
        _ wallpaper: DesktopWallpaper,
        connectedDisplayIDs: Set<DesktopDisplayID>,
        replacingAssignedConnectedDisplays: Bool
    ) throws -> MacDesktopSettings {
        try update { current in
            var byDisplay = Dictionary(
                uniqueKeysWithValues: current.assignments.map { ($0.displayID, $0) }
            )
            let automaticDisplayIDs = current.assignments
                .filter { $0.source == .automatic }
                .map(\.displayID)
            for displayID in automaticDisplayIDs {
                byDisplay[displayID] = DesktopDisplayAssignment(
                    displayID: displayID,
                    wallpaper: wallpaper,
                    source: .automatic
                )
            }
            for displayID in connectedDisplayIDs {
                guard let existing = byDisplay[displayID] else {
                    byDisplay[displayID] = DesktopDisplayAssignment(
                        displayID: displayID,
                        wallpaper: wallpaper,
                        source: .automatic
                    )
                    continue
                }
                if existing.source == .automatic {
                    continue
                }
                guard replacingAssignedConnectedDisplays else { continue }
                byDisplay[displayID] = DesktopDisplayAssignment(
                    displayID: displayID,
                    wallpaper: wallpaper,
                    source: .automatic
                )
            }
            current.assignments = byDisplay.values
                .sorted { $0.displayID < $1.displayID }
        }
    }

    func removeAssignment(_ displayID: DesktopDisplayID) throws -> MacDesktopSettings {
        try update { current in
            current.assignments.removeAll { $0.displayID == displayID }
        }
    }

    func clearAssignments() throws -> MacDesktopSettings {
        try update { current in
            current.assignments = []
        }
    }

    func setAutomationMode(_ mode: MacDesktopAutomationMode) throws -> MacDesktopSettings {
        try update { current in
            current.automationMode = mode
        }
    }

    func setAutomaticOverwriteEnabled(_ enabled: Bool) throws -> MacDesktopSettings {
        try update { current in
            current.automaticOverwriteEnabled = enabled
        }
    }

    /// Fail-closed override used when disabling automation could not be
    /// persisted. The write gate is already closed; keeping the in-memory mode
    /// read-only prevents a later successful settings write from resurrecting
    /// automatic mode. The persistence error stays observable.
    func forceAutomationModeReadOnlyInMemory() -> MacDesktopSettings {
        ensureLoaded()
        var current = settings ?? .default
        current.automationMode = .readOnly
        settings = current
        return current
    }

    func protect(
        displayID: DesktopDisplayID,
        imageURL: URL?,
        options: MacWallpaperOptions,
        at date: Date
    ) throws -> MacDesktopSettings {
        try update { current in
            current.manualProtections.removeAll { $0.displayID == displayID }
            current.manualProtections.append(
                MacManualProtectionRecord(
                    displayID: displayID,
                    imageURL: imageURL,
                    options: options,
                    protectedAt: date
                )
            )
            current.manualProtections.sort { $0.displayID < $1.displayID }
        }
    }

    func removeManualProtection(
        displayID: DesktopDisplayID
    ) throws -> MacDesktopSettings {
        try update { current in
            current.manualProtections.removeAll { $0.displayID == displayID }
        }
    }

    func removeManualProtections(
        for displayIDs: Set<DesktopDisplayID>
    ) throws -> MacDesktopSettings {
        try update { current in
            current.manualProtections.removeAll { displayIDs.contains($0.displayID) }
        }
    }

    // MARK: Ledger and one-shot approvals (best effort)

    func guardContext(
        displayID: DesktopDisplayID,
        observedImageURL: URL?,
        target: DesktopWallpaper
    ) -> MacGuardContext {
        ensureLoaded()
        let current = settings ?? .default
        let cutoff = now().addingTimeInterval(-Self.approvalLifetime)
        return MacGuardContext(
            isManaged: observedImageURL.map { current.managedImageURLs.contains($0) } ?? false,
            hasMatchingApproval: current.overwriteApprovals.contains {
                $0.displayID == displayID
                    && $0.observedImageURL == observedImageURL
                    && $0.target == target
                    && $0.approvedAt >= cutoff
            },
            isManuallyProtected: current.manualProtections.contains {
                $0.displayID == displayID
            },
            allowsAutomaticOverwrite: current.automationMode == .automatic
                && current.automaticOverwriteEnabled
        )
    }

    func addApproval(
        displayID: DesktopDisplayID,
        observedImageURL: URL?,
        target: DesktopWallpaper
    ) {
        ensureLoaded()
        var current = settings ?? .default
        current.overwriteApprovals.removeAll {
            $0.displayID == displayID && $0.observedImageURL == observedImageURL && $0.target == target
        }
        current.overwriteApprovals.append(
            MacOverwriteApproval(
                displayID: displayID,
                observedImageURL: observedImageURL,
                target: target,
                approvedAt: now()
            )
        )
        commitBestEffort(current)
    }

    func consumeApproval(
        displayID: DesktopDisplayID,
        observedImageURL: URL?,
        target: DesktopWallpaper
    ) {
        ensureLoaded()
        var current = settings ?? .default
        current.overwriteApprovals.removeAll {
            $0.displayID == displayID && $0.observedImageURL == observedImageURL && $0.target == target
        }
        commitBestEffort(current)
    }

    func recordAppliedWallpaper(url: URL, for displayID: DesktopDisplayID) {
        ensureLoaded()
        var current = settings ?? .default
        current.managedImageURLs.insert(url)
        var byDisplay = current.appliedImageURLsByDisplay ?? [:]
        byDisplay[displayID.rawValue] = url
        current.appliedImageURLsByDisplay = byDisplay
        commitBestEffort(current)
    }

    func isManagedImageURL(_ url: URL) -> Bool {
        ensureLoaded()
        let targetPaths = Set([
            url.standardizedFileURL.path,
            url.standardizedFileURL.resolvingSymlinksInPath().path
        ])
        return (settings ?? .default).managedImageURLs.contains { candidate in
            let candidatePaths = Set([
                candidate.standardizedFileURL.path,
                candidate.standardizedFileURL.resolvingSymlinksInPath().path
            ])
            return !targetPaths.isDisjoint(with: candidatePaths)
        }
    }

    // MARK: Persistence

    private func ensureLoaded() {
        guard settings == nil else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            settings = .default
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var decoded = try JSONDecoder().decode(MacDesktopSettings.self, from: data)
            guard MacDesktopSettings.readableSchemaVersions.contains(decoded.schemaVersion) else {
                settings = .default
                loadIssue = MacDesktopSettingsIssue(
                    kind: .unsupportedSchemaVersion,
                    schemaVersion: decoded.schemaVersion
                )
                return
            }
            decoded = Self.sanitized(decoded)
            settings = decoded
        } catch {
            settings = .default
            loadIssue = MacDesktopSettingsIssue(
                kind: .unreadable,
                detail: error.localizedDescription
            )
        }
    }

    private func update(
        _ transform: (inout MacDesktopSettings) -> Void
    ) throws -> MacDesktopSettings {
        ensureLoaded()
        let previous = settings ?? .default
        var next = previous
        transform(&next)
        next.schemaVersion = MacDesktopSettings.currentSchemaVersion
        next = Self.sanitized(next)
        do {
            try save(next)
        } catch {
            settings = previous
            persistenceIssue = MacDesktopSettingsIssue(
                kind: .saveFailed,
                detail: error.localizedDescription
            )
            throw MacDesktopApplyError.persistenceFailed(error.localizedDescription)
        }
        settings = next
        persistenceIssue = nil
        return next
    }

    private func commitBestEffort(_ settings: MacDesktopSettings) {
        self.settings = settings
        do {
            try save(settings)
            persistenceIssue = nil
        } catch {
            persistenceIssue = MacDesktopSettingsIssue(
                kind: .saveFailed,
                detail: error.localizedDescription
            )
        }
    }

    private func save(_ settings: MacDesktopSettings) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func sanitized(_ settings: MacDesktopSettings) -> MacDesktopSettings {
        var next = settings
        var seenDisplays: Set<DesktopDisplayID> = []
        next.assignments = next.assignments
            .filter { seenDisplays.insert($0.displayID).inserted }
            .sorted { $0.displayID < $1.displayID }

        var seenProtections: Set<DesktopDisplayID> = []
        next.manualProtections = next.manualProtections
            .filter { seenProtections.insert($0.displayID).inserted }
            .sorted { $0.displayID < $1.displayID }

        if let byDisplay = next.appliedImageURLsByDisplay {
            var cleaned: [String: URL] = [:]
            for (rawValue, url) in byDisplay
            where !rawValue.isEmpty && url.isFileURL {
                cleaned[rawValue] = url
            }
            next.appliedImageURLsByDisplay = cleaned
        }

        return next
    }
}
