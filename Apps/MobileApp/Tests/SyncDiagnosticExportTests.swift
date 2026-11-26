import Foundation
import Testing
@testable import DaybreakMobile

@Suite("Sync diagnostic export")
struct SyncDiagnosticExportTests {
    private func report(
        snapshot: SyncDiagnosticExport.Snapshot,
        logText: String? = nil,
        appVersion: String = "1.0 (8)",
        osVersion: String = "iOS 26.1"
    ) -> String {
        SyncDiagnosticExport.makeReport(
            snapshot: snapshot,
            logText: logText,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: appVersion,
            osVersion: osVersion
        )
    }

    @Test("invalidPath keeps its site and drops the relative name")
    func invalidPathPreservesSite() {
        let raw = "marker/folder:invalidPath(containment:Family Photos/2026/wallpaper.json)"
        let snapshot = SyncDiagnosticExport.Snapshot(
            enabled: true,
            folderConfigured: true,
            status: "failed",
            lastIssue: "folderAccess",
            lastSyncAt: Date(timeIntervalSince1970: 0),
            syncMarket: true,
            lastFailureDetail: raw
        )
        let text = report(
            snapshot: snapshot,
            logText: "2026-01-02T03:04:05Z pass-folder-error:\(raw.dropFirst("marker/folder:".count))\n"
        )

        #expect(text.contains("sync.lastFailure.stage=marker"))
        #expect(text.contains("sync.lastFailure.kind=folderAccess"))
        #expect(text.contains("sync.lastFailure.category=invalidPath"))
        #expect(text.contains("sync.lastFailure.site=containment"))
        #expect(text.contains("event=pass-folder-error category=invalidPath site=containment"))
        #expect(!text.contains("Family Photos"))
        #expect(!text.contains("wallpaper.json"))
        #expect(text.contains("sync.markerFile=daybreak-sync.json"))
        #expect(text.contains("sync.lastSync=1970-01-01T00:00:00Z"))
    }

    @Test("arbitrary failure detail and log text never reach the report")
    func arbitraryDetailIsDiscarded() {
        let snapshot = SyncDiagnosticExport.Snapshot(
            lastFailureDetail: "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/Daybreak"
        )
        let log = """
        2026-01-02T03:04:05Z bookmark-save-error: Error Domain=NSCocoaErrorDomain Code=513 "/Users/alice/Private"
        /Users/alice/secret
        """
        let text = report(snapshot: snapshot, logText: log)

        #expect(text.contains("sync.lastFailure.kind=unclassified"))
        #expect(text.contains("event=bookmark-save-error category=bookmarkWriteFailed"))
        #expect(text.contains("recentEvents.unrecognized=1"))
        #expect(!text.contains("/Users"))
        #expect(!text.contains("alice"))
    }

    @Test("marker read failures keep only the stage and fixed marker name")
    func markerReadFailure() {
        let snapshot = SyncDiagnosticExport.Snapshot(
            enabled: true,
            folderConfigured: true,
            status: "failed",
            lastIssue: "incompatibleFolder",
            lastFailureDetail: "marker/marker-read: Error Domain=NSCocoaErrorDomain \"/Users/alice/Daybreak\""
        )
        let text = report(snapshot: snapshot)

        #expect(text.contains("sync.lastFailure.stage=marker"))
        #expect(text.contains("sync.lastFailure.kind=markerRead"))
        #expect(text.contains("sync.markerFile=daybreak-sync.json"))
        #expect(!text.contains("alice"))
    }

    @Test("pass abort exposes the allowlisted stage and issue only")
    func passAbortClassification() {
        let snapshot = SyncDiagnosticExport.Snapshot(
            enabled: true,
            folderConfigured: true,
            status: "failed",
            lastIssue: "folderAccess",
            lastFailureDetail: "ready-folder/abort:folderAccess"
        )
        let text = report(snapshot: snapshot)

        #expect(text.contains("sync.lastFailure.stage=ready-folder"))
        #expect(text.contains("sync.lastFailure.kind=abort"))
        #expect(text.contains("sync.lastFailure.category=folderAccess"))
    }

    @Test("log events are rebuilt from allowlisted tokens")
    func logEventAllowlist() {
        let log = """
        2026-01-02T03:04:05Z set-enabled:true
        2026-01-02T03:04:06Z authorize:authorized
        2026-01-02T03:04:07Z pass:completed/none/finished=true
        2026-01-02T03:04:08Z pass-abort:failed/folderAccess/marker/abort:folderAccess
        2026-01-02T03:04:09Z revoked: targetMissing
        2026-01-02T03:04:10Z revoked: /Users/alice
        2026-01-02T03:04:11Z authorize-error:invalidPath(symbolicLink:secret-link.json)
        2026-01-02T03:04:12Z unexpected free-form /Users/alice
        """
        let text = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            logText: log
        )

        #expect(text.contains("event=set-enabled enabled=true"))
        #expect(text.contains("event=authorize result=authorized"))
        #expect(text.contains("event=pass status=completed issue=none finished=true"))
        #expect(text.contains("event=pass-abort status=failed issue=folderAccess stage=marker category=abort abortIssue=folderAccess"))
        #expect(text.contains("event=revoked reason=targetMissing"))
        #expect(text.contains("event=revoked reason=unclassified"))
        #expect(text.contains("event=authorize-error category=invalidPath site=symbolicLink"))
        #expect(text.contains("recentEvents.unrecognized=1"))
        #expect(!text.contains("alice"))
        #expect(!text.contains("secret-link"))
    }

    @Test("coordinated-access events keep only allowlisted boundary tokens")
    func coordinatedAccessEventsAreSanitized() {
        let log = """
        2026-01-02T03:04:05Z coordinate-start:stage=write target=missing
        2026-01-02T03:04:06Z coordinate-accessor:stage=write item=rejected relation=outsideRoot target=missing leaf=same parent=samePath
        2026-01-02T03:04:07Z coordinate-accessor:stage=read item=rejected relation=outsideRoot target=existing leaf=different parent=different /Users/alice/Private
        2026-01-02T03:04:08Z coordinate-failed:stage=write reason=coordination /Users/alice
        2026-01-02T03:04:09Z coordinate-accessor:stage=write item=rejected relation=/Users/alice target=missing leaf=same parent=secret
        """

        let text = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            logText: log
        )

        #expect(text.contains("event=coordinate-start stage=write target=missing"))
        #expect(text.contains(
            "event=coordinate-accessor stage=write item=rejected relation=outsideRoot"
                + " target=missing leaf=same parent=samePath"
        ))
        #expect(text.contains(
            "event=coordinate-accessor stage=read item=rejected relation=outsideRoot"
                + " target=existing leaf=different parent=different"
        ))
        #expect(text.contains("event=coordinate-failed stage=write reason=coordination"))
        #expect(text.contains(
            "coordinate-accessor stage=write item=rejected relation=unknown"
                + " target=missing leaf=same parent=unknown"
        ))
        #expect(!text.contains("parent=secret"))
        #expect(!text.contains("/Users"))
        #expect(!text.contains("alice"))
        #expect(!text.contains("Private"))
    }

    @Test("only the newest bounded number of events is reported")
    func eventLimit() {
        let log = (1...100)
            .map { _ in "2026-01-02T03:04:05Z set-enabled:true" }
            .joined(separator: "\n")
        let text = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            logText: log
        )

        #expect(text.contains("recentEvents.shown=60"))
        #expect(text.contains("recentEvents.omitted=40"))
    }

    @Test("missing and empty logs are distinguishable")
    func missingLog() {
        let missing = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            logText: nil
        )
        #expect(missing.contains("diagnosticsLog=unavailable"))
        #expect(missing.contains("recentEvents.shown=0"))
        #expect(!missing.contains("recentEvents:"))

        let empty = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            logText: ""
        )
        #expect(empty.contains("diagnosticsLog=available"))
        #expect(empty.contains("recentEvents.shown=0"))
    }

    @Test("unknown status values become unknown and nil failure becomes none")
    func statusAndFailureFallbacks() {
        let text = report(
            snapshot: SyncDiagnosticExport.Snapshot(
                status: "failed\nInjected",
                lastIssue: "notAnIssue",
                lastFailureDetail: nil
            )
        )

        #expect(text.contains("sync.status=unknown"))
        #expect(text.contains("sync.lastIssue=unknown"))
        #expect(text.contains("sync.lastFailure=none"))
        #expect(text.contains("sync.lastSync=never"))
    }

    @Test("version strings are collapsed to a single field-safe line")
    func versionStringsAreOneLine() {
        let text = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            appVersion: "1.0 (8)\nsync.enabled=false",
            osVersion: "iOS 26.1\r\nmalicious=1"
        )

        #expect(text.contains("app.version=1.0 (8) sync.enabled=false"))
        #expect(text.contains("system.version=iOS 26.1 malicious=1"))
        #expect(!text.contains("\nmalicious=1"))
    }

    @Test("authorization and bookmark error payloads are dropped")
    func authorizationErrorsAreCategorized() {
        let text = report(
            snapshot: SyncDiagnosticExport.Snapshot(),
            logText: """
            2026-01-02T03:04:05Z authorize-error:invalidPath(containment:Private Folder/notes.json)
            2026-01-02T03:04:06Z bookmark-create-error: Error Domain=NSCocoaErrorDomain "/Users/alice/Private Folder"
            2026-01-02T03:04:07Z scope-denied: startAccessing=false /Users/alice
            """
        )

        #expect(text.contains("event=authorize-error category=invalidPath site=containment"))
        #expect(text.contains("event=bookmark-create-error category=bookmarkCreationFailed"))
        #expect(text.contains("event=scope-denied category=scopeDenied"))
        #expect(!text.contains("Private Folder"))
        #expect(!text.contains("notes.json"))
        #expect(!text.contains("/Users"))
    }
}
