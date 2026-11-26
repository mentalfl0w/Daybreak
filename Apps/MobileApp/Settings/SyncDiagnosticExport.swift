import DaybreakCore
import Foundation

/// Builds the locally generated, privacy-bounded sync diagnostic report.
///
/// The report combines typed controller state with fixed diagnostic tokens.
/// Raw failure text and diagnostic-log payloads can contain relative file
/// names, so every free-form value is matched against an allowlisted stage,
/// status or error token and everything else is discarded. The only file name
/// that may appear is the fixed sync folder marker `daybreak-sync.json`.
///
/// The report never includes the selected folder's path or name, bookmark
/// data, wallpaper or story content, device name, or any network destination.
/// Writing the report is local-only; sharing it is an explicit system share
/// sheet action.
enum SyncDiagnosticExport {
    static let formatVersion = 1
    static let markerFileName = "daybreak-sync.json"
    /// Mirrors `SyncDiagnostics.fileName` in DaybreakCore. The core helper is
    /// internal; this app already owns the sibling device-local state layout.
    static let logFileName = "sync-diagnostics.log"
    static let maxLogReadBytes = 64 * 1024
    static let maxReportedEvents = 60
    static let maxAppVersionLength = 64
    static let maxSystemVersionLength = 96

    /// Typed subset of the controller state used by the report.
    ///
    /// Keeping this separate from `DaybreakSyncController` lets the report be
    /// generated off the main actor and exercised without a live sync folder.
    struct Snapshot: Equatable, Sendable {
        let enabled: Bool
        let folderConfigured: Bool
        let status: String
        let lastIssue: String
        let lastSyncAt: Date?
        let syncOriginals: Bool
        let syncMarket: Bool
        let lastFailureDetail: String?

        init(
            enabled: Bool = false,
            folderConfigured: Bool = false,
            status: String = "disabled",
            lastIssue: String = "none",
            lastSyncAt: Date? = nil,
            syncOriginals: Bool = false,
            syncMarket: Bool = false,
            lastFailureDetail: String? = nil
        ) {
            self.enabled = enabled
            self.folderConfigured = folderConfigured
            self.status = status
            self.lastIssue = lastIssue
            self.lastSyncAt = lastSyncAt
            self.syncOriginals = syncOriginals
            self.syncMarket = syncMarket
            self.lastFailureDetail = lastFailureDetail
        }
    }

    @MainActor
    static func snapshot(from controller: DaybreakSyncController) -> Snapshot {
        Snapshot(
            enabled: controller.enabled,
            folderConfigured: controller.folderName != nil,
            status: controller.status.rawValue,
            lastIssue: controller.lastIssue.rawValue,
            lastSyncAt: controller.lastSyncAt,
            syncOriginals: controller.syncOriginals,
            syncMarket: controller.syncMarket,
            lastFailureDetail: controller.lastFailureDetail
        )
    }

    static func appVersion(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return oneLine("\(version) (\(build))", limit: maxAppVersionLength)
    }

    static func systemVersion(processInfo: ProcessInfo = .processInfo) -> String {
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "unknown"
        #endif
        return oneLine(
            "\(platform) \(processInfo.operatingSystemVersionString)",
            limit: maxSystemVersionLength
        )
    }

    /// Reads the bounded diagnostic log and writes a report into the app's
    /// temporary directory. Throws only file-system errors so the caller can
    /// present an explicit export failure instead of a silent no-op.
    static func write(
        snapshot: Snapshot,
        diagnosticsDirectory: URL,
        generatedAt: Date,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) throws -> URL {
        let logURL = diagnosticsDirectory.appendingPathComponent(
            logFileName,
            isDirectory: false
        )
        let logText = readLog(at: logURL)
        let report = makeReport(
            snapshot: snapshot,
            logText: logText,
            generatedAt: generatedAt,
            appVersion: appVersion(bundle: bundle),
            osVersion: systemVersion(processInfo: processInfo)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybreakSyncDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "daybreak-sync-diagnostic-\(fileTimestamp(generatedAt)).txt",
            isDirectory: false
        )
        try Data(report.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Pure report assembly. Only fixed metadata and allowlisted tokens reach
    /// the output; `lastFailureDetail` and `logText` are never copied through.
    static func makeReport(
        snapshot: Snapshot,
        logText: String?,
        generatedAt: Date,
        appVersion: String,
        osVersion: String
    ) -> String {
        var lines: [String] = []
        lines.append("Daybreak sync diagnostic report")
        lines.append("report.format=daybreak.sync.diagnostic")
        lines.append("report.version=\(formatVersion)")
        lines.append("generated=\(isoTimestamp(generatedAt))")
        lines.append("app.version=\(oneLine(appVersion, limit: maxAppVersionLength))")
        lines.append("system.version=\(oneLine(osVersion, limit: maxSystemVersionLength))")
        lines.append("sync.enabled=\(snapshot.enabled)")
        lines.append("sync.folderConfigured=\(snapshot.folderConfigured)")
        lines.append("sync.status=\(safeToken(snapshot.status, allowed: syncStatuses))")
        lines.append("sync.lastIssue=\(safeToken(snapshot.lastIssue, allowed: issueCodes))")
        lines.append("sync.lastSync=\(snapshot.lastSyncAt.map { isoTimestamp($0) } ?? "never")")
        lines.append("sync.options.originals=\(snapshot.syncOriginals)")
        lines.append("sync.options.market=\(snapshot.syncMarket)")
        lines.append("sync.markerFile=\(markerFileName)")

        if let failure = summarizeFailure(snapshot.lastFailureDetail) {
            if let stage = failure.stage {
                lines.append("sync.lastFailure.stage=\(stage)")
            }
            lines.append("sync.lastFailure.kind=\(failure.kind)")
            if let category = failure.category {
                lines.append("sync.lastFailure.category=\(category)")
            }
            if let site = failure.site {
                lines.append("sync.lastFailure.site=\(site)")
            }
        } else {
            lines.append("sync.lastFailure=none")
        }

        let parsed = parseLog(logText ?? "")
        lines.append("diagnosticsLog=\(logText == nil ? "unavailable" : "available")")
        lines.append("recentEvents.shown=\(parsed.displayed.count)")
        lines.append("recentEvents.omitted=\(parsed.omitted)")
        lines.append("recentEvents.unrecognized=\(parsed.unrecognized)")
        if !parsed.displayed.isEmpty {
            lines.append("recentEvents:")
            lines.append(contentsOf: parsed.displayed)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Failure summary

    private struct FailureSummary {
        var stage: String?
        var kind: String
        var category: String?
        var site: String?
    }

    private static func summarizeFailure(_ raw: String?) -> FailureSummary? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "cancelled" {
            return FailureSummary(kind: "cancelled")
        }
        // The engine uses `error:<type name>` for unexpected errors. The type
        // name is not needed to diagnose the known sync failures and is not
        // copied into the report.
        if raw.hasPrefix("error:") {
            return FailureSummary(kind: "unexpected")
        }
        guard let slash = raw.firstIndex(of: "/") else {
            return FailureSummary(kind: "unclassified")
        }
        let stageToken = String(raw[..<slash])
        let stage = stages.contains(stageToken) ? stageToken : nil
        let detail = String(raw[raw.index(after: slash)...])
        if detail.hasPrefix("folder:") {
            let token = String(detail.dropFirst("folder:".count))
            guard let error = accessError(token) else {
                return FailureSummary(stage: stage, kind: "folderAccess")
            }
            return FailureSummary(
                stage: stage,
                kind: "folderAccess",
                category: error.category,
                site: error.site
            )
        }
        if detail.hasPrefix("abort:") {
            let token = String(detail.dropFirst("abort:".count))
            return FailureSummary(
                stage: stage,
                kind: "abort",
                category: issueCodes.contains(token) ? token : nil
            )
        }
        if detail.hasPrefix("marker-read:") {
            return FailureSummary(stage: stage, kind: "markerRead")
        }
        return FailureSummary(stage: stage, kind: "unclassified")
    }

    // MARK: Diagnostic log

    private struct ParsedLog {
        var displayed: [String] = []
        var omitted = 0
        var unrecognized = 0
    }

    /// Keeps only the newest recognized events. Unrecognized lines are counted
    /// but never copied, so an unexpected writer cannot smuggle a path into
    /// the report.
    private static func parseLog(_ text: String) -> ParsedLog {
        var parsed = ParsedLog()
        var recognized: [String] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let (timestamp, eventText) = splitTimestamp(line)
            guard let event = sanitizeEvent(String(eventText)) else {
                parsed.unrecognized += 1
                continue
            }
            if let timestamp {
                recognized.append("\(timestamp) event=\(event)")
            } else {
                recognized.append("event=\(event)")
            }
        }
        if recognized.count > maxReportedEvents {
            parsed.omitted = recognized.count - maxReportedEvents
            parsed.displayed = Array(recognized.suffix(maxReportedEvents))
        } else {
            parsed.displayed = recognized
        }
        return parsed
    }

    private static func splitTimestamp(_ line: String) -> (String?, Substring) {
        guard let space = line.firstIndex(of: " ") else {
            return (nil, line[...])
        }
        let token = line[..<space]
        guard isSafeTimestamp(token) else {
            return (nil, line[...])
        }
        return (String(token), line[line.index(after: space)...])
    }

    private static func isSafeTimestamp(_ token: Substring) -> Bool {
        guard token.count >= 20, token.count <= 35 else { return false }
        guard token.contains("T"), token.contains(":"), token.contains("-") else {
            return false
        }
        guard token.last == "Z"
            || token.contains("+")
            || token.dropFirst(10).contains("-")
        else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "0123456789-:T.Z+")
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func sanitizeEvent(_ text: String) -> String? {
        if text.hasPrefix("set-enabled:") {
            let value = String(text.dropFirst("set-enabled:".count))
            guard value == "true" || value == "false" else {
                return "set-enabled value=unknown"
            }
            return "set-enabled enabled=\(value)"
        }
        if text.hasPrefix("authorize:") {
            let value = String(text.dropFirst("authorize:".count))
            return "authorize result=\(authorizationResults.contains(value) ? value : "unclassified")"
        }
        if text.hasPrefix("authorize-error:") {
            return accessErrorEvent(
                name: "authorize-error",
                token: String(text.dropFirst("authorize-error:".count))
            )
        }
        if text.hasPrefix("pass-folder-error:") {
            return accessErrorEvent(
                name: "pass-folder-error",
                token: String(text.dropFirst("pass-folder-error:".count))
            )
        }
        if text.hasPrefix("pass-abort:") {
            return sanitizePassAbort(String(text.dropFirst("pass-abort:".count)))
        }
        if text.hasPrefix("pass-error:") {
            return "pass-error category=unexpectedError"
        }
        if text.hasPrefix("pass:") {
            return sanitizePass(String(text.dropFirst("pass:".count)))
        }
        if text.hasPrefix("bookmark-save-error:") {
            return "bookmark-save-error category=bookmarkWriteFailed"
        }
        if text.hasPrefix("bookmark-create-error:") {
            return "bookmark-create-error category=bookmarkCreationFailed"
        }
        if text.hasPrefix("scope-denied:") {
            return "scope-denied category=scopeDenied"
        }
        if text.hasPrefix("revoked:") {
            let reason = String(text.dropFirst("revoked:".count))
                .trimmingCharacters(in: .whitespaces)
            return "revoked reason=\(revocationReasons.contains(reason) ? reason : "unclassified")"
        }
        if text.hasPrefix("coordinate-start:") {
            return sanitizeCoordinateStart(String(text.dropFirst("coordinate-start:".count)))
        }
        if text.hasPrefix("coordinate-accessor:") {
            return sanitizeCoordinateAccessor(
                String(text.dropFirst("coordinate-accessor:".count))
            )
        }
        if text.hasPrefix("coordinate-failed:") {
            return sanitizeCoordinateFailed(
                String(text.dropFirst("coordinate-failed:".count))
            )
        }
        return nil
    }

    /// Rebuilds a `key=value` event from allowlisted tokens only. Unknown
    /// keys and values are dropped or replaced with `unknown`; no raw field
    /// can pass through to the report.
    private static func sanitizeCoordinateStart(_ payload: String) -> String {
        let fields = parseFields(payload)
        return "coordinate-start"
            + " stage=\(safeToken(fields["stage"] ?? "", allowed: accessStages))"
            + " target=\(safeToken(fields["target"] ?? "", allowed: targetStates))"
    }

    private static func sanitizeCoordinateAccessor(_ payload: String) -> String {
        let fields = parseFields(payload)
        return "coordinate-accessor"
            + " stage=\(safeToken(fields["stage"] ?? "", allowed: accessStages))"
            + " item=\(safeToken(fields["item"] ?? "", allowed: accessItems))"
            + " relation=\(safeToken(fields["relation"] ?? "", allowed: accessRelations))"
            + " target=\(safeToken(fields["target"] ?? "", allowed: targetStates))"
            + " leaf=\(safeToken(fields["leaf"] ?? "", allowed: leafMatches))"
            + " parent=\(safeToken(fields["parent"] ?? "", allowed: parentRelations))"
    }

    private static func sanitizeCoordinateFailed(_ payload: String) -> String {
        let fields = parseFields(payload)
        return "coordinate-failed"
            + " stage=\(safeToken(fields["stage"] ?? "", allowed: accessStages))"
            + " reason=\(safeToken(fields["reason"] ?? "", allowed: accessFailureReasons))"
    }

    private static func parseFields(_ payload: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in payload.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        return fields
    }

    private static func sanitizePass(_ payload: String) -> String {
        if payload == "cancelled" {
            return "pass state=cancelled"
        }
        let parts = payload.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3 else { return "pass state=unclassified" }
        let status = passStatuses.contains(String(parts[0]))
            ? String(parts[0])
            : "unclassified"
        let issue = issueCodes.contains(String(parts[1]))
            ? String(parts[1])
            : "unclassified"
        let finished: String
        switch String(parts[2]) {
        case "finished=true": finished = "true"
        case "finished=false": finished = "false"
        default: finished = "unknown"
        }
        return "pass status=\(status) issue=\(issue) finished=\(finished)"
    }

    private static func sanitizePassAbort(_ payload: String) -> String {
        let parts = payload.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3 else {
            return "pass-abort status=unclassified issue=unclassified category=unclassified"
        }
        let status = passStatuses.contains(String(parts[0]))
            ? String(parts[0])
            : "unclassified"
        let issue = issueCodes.contains(String(parts[1]))
            ? String(parts[1])
            : "unclassified"
        let detail = String(parts[2])
        var fields = ["pass-abort", "status=\(status)", "issue=\(issue)"]
        if let stage = firstStage(in: detail) {
            fields.append("stage=\(stage)")
        }
        if detail.contains("marker-read:") {
            fields.append("category=markerRead")
        } else if let abortIssue = abortIssue(in: detail) {
            fields.append("category=abort")
            fields.append("abortIssue=\(abortIssue)")
        } else {
            fields.append("category=unclassified")
        }
        return fields.joined(separator: " ")
    }

    private static func firstStage(in detail: String) -> String? {
        guard let component = detail.split(separator: "/", maxSplits: 1).first else {
            return nil
        }
        let token = String(component)
        return stages.contains(token) ? token : nil
    }

    private static func abortIssue(in detail: String) -> String? {
        guard let range = detail.range(of: "abort:") else { return nil }
        let token = detail[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        let value = String(token)
        return issueCodes.contains(value) ? value : nil
    }

    private static func accessErrorEvent(name: String, token: String) -> String {
        guard let error = accessError(token) else {
            return "\(name) category=unclassified"
        }
        var line = "\(name) category=\(error.category)"
        if let site = error.site {
            line += " site=\(site)"
        }
        return line
    }

    /// Preserves the invalid-path site while discarding the payload after the
    /// colon, which is a relative file name that may embed user data.
    private static func accessError(
        _ token: String
    ) -> (category: String, site: String?)? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("invalidPath(") {
            guard trimmed.hasSuffix(")") else {
                return ("invalidPath", nil)
            }
            let inner = trimmed.dropFirst("invalidPath(".count).dropLast()
            let site = inner
                .split(separator: ":", maxSplits: 1)
                .first
                .map(String.init)
            if let site, invalidPathSites.contains(site) {
                return ("invalidPath", site)
            }
            return ("invalidPath", nil)
        }
        if accessErrorNames.contains(trimmed) {
            return (trimmed, nil)
        }
        return nil
    }

    // MARK: Formatting

    private static func readLog(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxLogReadBytes) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func safeToken(_ value: String, allowed: Set<String>) -> String {
        allowed.contains(value) ? value : "unknown"
    }

    /// Collapses every control character and whitespace run so a bundle or
    /// system string cannot inject an extra report field.
    private static func oneLine(_ text: String, limit: Int) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for character in text {
            if character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) {
                cleaned.append(" ")
            } else {
                cleaned.append(character)
            }
        }
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: Allowlists

    private static let syncStatuses: Set<String> = [
        "disabled", "awaitingFolder", "syncing", "completed", "pending",
        "unavailable", "unauthorized", "failed",
    ]

    private static let issueCodes: Set<String> = [
        "none", "incompatibleFolder", "folderAccess", "folderUnavailable",
        "unauthorized", "tooManyDevices", "tooManyOperationFiles",
        "invalidOperationFiles", "rejectedRecords", "rejectedAssets",
        "pendingAssets", "pendingDownloads", "journalBacklog",
        "repositoryFailure", "planningFailure", "passInProgress",
    ]

    private static let passStatuses: Set<String> = [
        "completed", "pending", "awaitingFolder", "unavailable", "unauthorized",
        "failed", "cancelled",
    ]

    /// Mirrors every assignment to `passStage` in `CloudSyncEngine`.
    private static let stages: Set<String> = [
        "idle", "ready-folder", "marker", "snapshot", "publish-journal", "scan",
        "commit", "final-publish", "blobs", "materialize",
    ]

    private static let accessErrorNames: Set<String> = [
        "notAuthorized", "unauthorized", "notFound", "notDownloaded", "retryable",
        "tooLarge", "other",
    ]

    private static let invalidPathSites: Set<String> = [
        "relativePath", "containment", "symbolicLink",
    ]

    private static let authorizationResults: Set<String> = [
        "authorized", "unauthorized", "unavailable", "failed",
    ]

    private static let accessStages: Set<String> = ["read", "write", "list"]

    private static let accessItems: Set<String> = ["accepted", "rejected"]

    private static let accessRelations: Set<String> = [
        "samePath", "sameItem", "resolvedItem", "sameParentItem",
        "sameParentPath", "insideRoot", "outsideRoot", "notFileURL",
        "dotComponent",
    ]

    private static let targetStates: Set<String> = ["existing", "missing"]

    private static let leafMatches: Set<String> = ["same", "different"]

    private static let parentRelations: Set<String> = ["sameItem", "samePath", "different"]

    private static let accessFailureReasons: Set<String> = ["coordination"]

    private static let revocationReasons: Set<String> = [
        "bookmarkCorrupted", "unsupportedBookmarkVersion", "platformMismatch",
        "bookmarkUnresolvable", "targetMissing", "targetNotDirectory",
        "unsupportedLocation", "accessDenied", "scopeRequired",
        "bookmarkStorageUnavailable",
    ]
}
