import DaybreakCore
import Foundation
import SwiftUI

/// Optional, local-first folder synchronization for iPhone, iPad and Duo.
///
/// This pane owns presentation state only: the document picker, the pending
/// folder-replacement confirmation and per-action busy flags. Every value and
/// mutation comes from `DaybreakSyncController`; no bookmark is created,
/// displayed or logged here, and closing sync never deletes local or remote
/// records. An explicit export writes a sanitized report to the app's
/// temporary directory and never reads the shared folder or its contents.
struct SyncSettingsView: View {
    let syncController: DaybreakSyncController
    /// Device-local directory containing the bounded sync diagnostic log.
    /// Supplied by `MobileStore`; the report never includes this path.
    let diagnosticsDirectory: URL

    @Environment(\.locale) private var locale

    @State private var isImporterPresented = false
    @State private var isConfirmingFolderReplacement = false
    @State private var isUpdatingEnabled = false
    @State private var isRequestingSync = false
    @State private var isPreparingDiagnostics = false
    @State private var diagnosticExportItem: DiagnosticExportItem?
    @State private var diagnosticExportErrorMessage: String?
    @State private var importerErrorMessage: String?
    @State private var folderSelectionPurpose: FolderSelectionPurpose?

    /// A folder picker either completes the first-time enable flow or
    /// reauthorizes/replaces an already configured folder. The purpose tells
    /// the completion handler whether to run the explicit enable fallback
    /// after `selectFolder`.
    private enum FolderSelectionPurpose {
        case enable
        case manage
    }

    /// Identifies the locally written report file for the share sheet.
    private struct DiagnosticExportItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        Form {
            deviceSection
            folderSection
            statusSection
            diagnosticsSection
            contentSection
            boundarySection
            Section {
                LabeledContent("版本") {
                    Text(verbatim: Self.appVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle("同步", locale: locale)
        .wideShellTabBarInset()
        .sheet(isPresented: $isImporterPresented) {
            FolderPickerView { result in
                // Start the security scope before the picker's sheet is
                // dismissed, then let the controller consume it.
                handleFolderSelection(result)
                isImporterPresented = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(
            "更换同步文件夹？",
            isPresented: $isConfirmingFolderReplacement,
            titleVisibility: .visible
        ) {
            Button("选择其他文件夹") {
                isImporterPresented = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("更换后，Daybreak 会使用新文件夹继续同步。不会删除本机数据，也不会删除旧文件夹中的记录。")
        }
        .alert(
            "无法访问所选文件夹",
            isPresented: Binding(
                get: { importerErrorMessage != nil },
                set: { if !$0 { importerErrorMessage = nil } }
            ),
            presenting: importerErrorMessage
        ) { _ in
            Button("好", role: .cancel) { importerErrorMessage = nil }
        } message: { message in
            Text(verbatim: message)
        }
        .sheet(item: $diagnosticExportItem) { item in
            WallpaperShareSheet(fileURL: item.url)
                .ignoresSafeArea()
        }
        .alert(
            "无法导出诊断日志",
            isPresented: Binding(
                get: { diagnosticExportErrorMessage != nil },
                set: { if !$0 { diagnosticExportErrorMessage = nil } }
            ),
            presenting: diagnosticExportErrorMessage
        ) { _ in
            Button("好", role: .cancel) { diagnosticExportErrorMessage = nil }
        } message: { message in
            Text(verbatim: message)
        }
    }

    /// Marketing version and build number. Shown so a sideloaded build can be
    /// identified from a screenshot; the build number changes per packaging.
    private static var appVersion: String {
        SyncDiagnosticExport.appVersion()
    }

    // MARK: Device

    private var deviceSection: some View {
        Section {
            Toggle("在此设备启用同步", isOn: enabledBinding)
                // Remains available during a running sync so the user can
                // stop; folder and option changes stay blocked until it ends.
                .disabled(isUpdatingEnabled)
        } header: {
            Text("设备同步")
        } footer: {
            Text("同步通过你选择的 iCloud Drive 文件夹进行。每台设备保留独立的本地数据，只交换版本化记录与资源文件，不共享活动数据库或索引。")
        }
    }

    // MARK: Folder

    private var folderSection: some View {
        Section {
            LabeledContent("当前文件夹") {
                if let folderName = syncController.folderName {
                    Text(verbatim: folderName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("尚未选择")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                requestFolderSelection()
            } label: {
                Label(folderActionTitle, systemImage: folderActionIcon)
            }
            .disabled(isBusy)
        } header: {
            Text("文件夹")
        } footer: {
            if syncController.folderName == nil {
                Text("推荐使用 iCloud Drive 中的 Daybreak 文件夹；选择 iCloud Drive 根目录时 Daybreak 会自动创建并进入该文件夹。在“文件”中选中文件夹本身后点“打开”，不要先进入文件夹内部。")
            } else if isSyncEnabled {
                Text("只申请该文件夹的访问权限；授权书签仅保存在本机，不随同步传播。Daybreak 不使用 CloudKit、专属 iCloud 容器或共享 App Group。")
            } else {
                Text("同步已关闭，Daybreak 不会读写此文件夹。重新开启后可继续使用。")
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            statusRow

            LabeledContent("上次同步") {
                if let lastSyncAt = syncController.lastSyncAt {
                    Text(verbatim: TodayFormatting.dateTime(lastSyncAt, locale: locale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("从未同步")
                        .foregroundStyle(.secondary)
                }
            }

            if isSyncEnabled {
                Button {
                    isRequestingSync = true
                    Task {
                        defer { isRequestingSync = false }
                        await syncController.syncNow()
                    }
                } label: {
                    Label(syncNowTitle, systemImage: "arrow.clockwise")
                }
                .disabled(isSyncNowDisabled)
            }
        } header: {
            Text("同步状态")
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.body.weight(.medium))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = syncController.lastFailureDetail {
                    Text(verbatim: "\(MobileLocalizedString.resolve("技术详情", locale: locale))：\(detail)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            if isSyncEnabled, isSyncing || isRequestingSync {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Button {
                prepareDiagnosticExport()
            } label: {
                Label(diagnosticButtonTitle, systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparingDiagnostics)
        } header: {
            Text("诊断")
        } footer: {
            Text("诊断日志包含应用与系统版本、同步状态、最近同步阶段记录和错误类别；不包含文件夹路径、授权书签、壁纸或文字内容、设备名称。文件仅在本机生成，分享去向由你在系统分享面板中选择。")
        }
    }

    // MARK: Content options

    private var contentSection: some View {
        Section {
            Toggle("同步原图", isOn: originalsBinding)
            Toggle("同步内容地区偏好", isOn: marketBinding)
        } header: {
            Text("同步内容")
        } footer: {
            Text("两个选项默认关闭。同步原图会增加存储与 iCloud 占用；内容地区偏好开启后可能改变其他设备的内容地区。关闭选项不会删除本机已有文件。")
            Text("同步关闭时选项不可更改，已保存的偏好仍保留在本机。")
        }
        .disabled(!isSyncEnabled || isSyncing || isRequestingSync)
    }

    // MARK: Boundaries

    private var boundarySection: some View {
        Section {
            Text("默认同步收藏与固定日期、日期与地区记录、壁纸元数据、介绍与版权、缩略图。")
            Text("只保留在本机：界面语言、缓存上限、壁纸目标、系统权限与文件夹授权书签。")
        } header: {
            Text("数据边界")
        } footer: {
            Text("关闭同步不会删除本机数据或文件夹中的旧记录；离线时仍可使用已缓存内容。重新开启后可继续使用原有文件夹。")
            Text("同步完成只表示本机已处理并写入记录，不代表其他设备已接收或已应用。文件同步不是跨设备锁。")
        }
    }

    // MARK: Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isSyncEnabled },
            set: { newValue in
                guard newValue != isSyncEnabled, !isUpdatingEnabled else { return }

                if !newValue {
                    isUpdatingEnabled = true
                    Task {
                        defer { isUpdatingEnabled = false }
                        await syncController.setEnabled(false)
                    }
                    return
                }

                // Enabling requires a folder first. A cancelled picker must
                // leave the toggle off, so sync is not enabled until a
                // selection succeeds.
                guard syncController.folderName != nil else {
                    folderSelectionPurpose = .enable
                    isImporterPresented = true
                    return
                }

                isUpdatingEnabled = true
                Task {
                    defer { isUpdatingEnabled = false }
                    await syncController.setEnabled(true)
                    guard !syncController.enabled, needsFolderAuthorization else { return }
                    // A retained folder whose authorization expired leaves
                    // sync off. Send the user straight to the folder picker
                    // instead of a toggle that cannot succeed.
                    folderSelectionPurpose = .enable
                    isImporterPresented = true
                }
            }
        )
    }

    private var originalsBinding: Binding<Bool> {
        Binding(
            get: { syncController.syncOriginals },
            set: { newValue in
                guard newValue != syncController.syncOriginals else { return }
                Task { await syncController.setSyncOriginals(newValue) }
            }
        )
    }

    private var marketBinding: Binding<Bool> {
        Binding(
            get: { syncController.syncMarket },
            set: { newValue in
                guard newValue != syncController.syncMarket else { return }
                Task { await syncController.setSyncMarket(newValue) }
            }
        )
    }

    // MARK: Actions

    /// Builds the report off the main actor from typed controller state and
    /// the bounded device-local log, then shows the system share sheet. A
    /// write failure surfaces an alert instead of a silent no-op.
    private func prepareDiagnosticExport() {
        guard !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        let snapshot = SyncDiagnosticExport.snapshot(from: syncController)
        let directory = diagnosticsDirectory
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try SyncDiagnosticExport.write(
                        snapshot: snapshot,
                        diagnosticsDirectory: directory,
                        generatedAt: Date()
                    )
                }.value
                diagnosticExportItem = DiagnosticExportItem(url: url)
            } catch {
                let code = (error as NSError).code
                diagnosticExportErrorMessage =
                    MobileLocalizedString.resolve(
                        "诊断日志未能写入临时文件。请重试。",
                        locale: locale
                    )
                    + " (\(code))"
            }
        }
    }

    private func requestFolderSelection() {
        folderSelectionPurpose = .manage
        if syncController.folderName != nil, !isUnauthorized {
            isConfirmingFolderReplacement = true
        } else {
            isImporterPresented = true
        }
    }

    private func handleFolderSelection(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let purpose = folderSelectionPurpose
            folderSelectionPurpose = nil
            isUpdatingEnabled = true
            // Hold the picker's security scope from the delegate callback
            // until the controller has created its own bookmark. Starting it
            // inside the Task would run after the sheet dismissal and could
            // lose the grant.
            let didStart = url.startAccessingSecurityScopedResource()
            Task {
                defer {
                    isUpdatingEnabled = false
                    if didStart { url.stopAccessingSecurityScopedResource() }
                }

                let folderURL = preparePickedFolder(url)
                guard let folderURL else { return }
                await syncController.selectFolder(folderURL)

                if syncController.folderName == nil {
                    // Authorization failed. Report the reason instead of
                    // leaving the switch off with no visible change.
                    if syncController.enabled {
                        await syncController.setEnabled(false)
                    }
                    importerErrorMessage = authorizationFailureMessage
                    return
                }

                switch purpose {
                case .enable:
                    if syncController.enabled { return }
                    await syncController.setEnabled(true)
                case .manage, .none:
                    break
                }
            }
        case .failure(let error):
            let purpose = folderSelectionPurpose
            folderSelectionPurpose = nil
            if case .enable = purpose,
               syncController.enabled,
               syncController.folderName == nil {
                isUpdatingEnabled = true
                Task {
                    defer { isUpdatingEnabled = false }
                    await syncController.setEnabled(false)
                }
            }
            if error is CancellationError { return }
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled { return }
            importerErrorMessage = MobileLocalizedString.resolve("无法打开所选文件夹。请重试或选择其他文件夹。", locale: locale)
        }
    }

    /// Adopts the default `iCloud Drive/Daybreak` folder when the user picked
    /// the iCloud Drive root. The root itself is not a usable sync container,
    /// so the folder is created inside the scope the picker just granted.
    private func preparePickedFolder(_ url: URL) -> URL? {
        guard SyncFolderDefaults.isICloudDriveRoot(url) else { return url }
        let folder = SyncFolderDefaults.daybreakFolder(inICloudDriveRoot: url)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                importerErrorMessage = MobileLocalizedString.resolve("iCloud Drive 中已存在同名文件“Daybreak”，无法创建同步文件夹。请移除该文件后重试。", locale: locale)
                return nil
            }
            return folder
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        } catch {
            importerErrorMessage = MobileLocalizedString.resolve("无法在 iCloud Drive 中创建 Daybreak 文件夹。请检查 iCloud Drive 后重试。", locale: locale)
            return nil
        }
    }

    private var authorizationFailureMessage: String {
        switch syncController.status {
        case .unauthorized:
            return MobileLocalizedString.resolve("系统未授予该文件夹的访问权限。请在“文件”中确认能打开该文件夹后重试。", locale: locale)
        case .unavailable:
            return MobileLocalizedString.resolve("该文件夹当前不可用，可能尚未从 iCloud 下载完成。请联网并稍后重试。", locale: locale)
        case .failed:
            return MobileLocalizedString.resolve("无法在该文件夹中建立同步授权。请改选 iCloud Drive 中的其他文件夹重试。", locale: locale)
        default:
            return MobileLocalizedString.resolve("该文件夹未能用于同步。请重试或选择其他文件夹。", locale: locale)
        }
    }

    // MARK: Derived state

    /// The product never presents sync as enabled until a folder is chosen.
    /// `selectFolder` only grants access; enabling is a separate controller
    /// call performed by the enable flow after a successful selection.
    private var isSyncEnabled: Bool {
        syncController.enabled && syncController.folderName != nil
    }

    private var isSyncing: Bool {
        guard isSyncEnabled else { return false }
        if case .syncing = syncController.status { return true }
        return false
    }

    private var isUnauthorized: Bool {
        guard isSyncEnabled else { return false }
        if case .unauthorized = syncController.status { return true }
        return false
    }

    private var isBusy: Bool {
        isUpdatingEnabled || isSyncing || isRequestingSync
    }

    private var needsFolderAuthorization: Bool {
        switch syncController.status {
        case .awaitingFolder, .unauthorized: return true
        default: return false
        }
    }

    private var isSyncNowDisabled: Bool {
        !isSyncEnabled
            || syncController.folderName == nil
            || isSyncing
            || isRequestingSync
            || isUnauthorized
    }

    private var folderActionTitle: LocalizedStringKey {
        if syncController.folderName == nil { return "选择同步文件夹" }
        if isUnauthorized { return "重新授权文件夹" }
        return "更换同步文件夹"
    }

    private var folderActionIcon: String {
        if syncController.folderName == nil { return "folder.badge.plus" }
        if isUnauthorized { return "lock.open" }
        return "folder"
    }

    private var syncNowTitle: LocalizedStringKey {
        if isRequestingSync || isSyncing { return "正在同步…" }
        return "立即同步"
    }

    private var diagnosticButtonTitle: LocalizedStringKey {
        if isPreparingDiagnostics { return "正在准备诊断日志…" }
        return "导出同步诊断日志"
    }

    private var statusTitle: LocalizedStringKey {
        guard syncController.enabled else { return "同步已关闭" }
        guard syncController.folderName != nil else { return "尚未选择同步文件夹" }
        if isRequestingSync { return "正在同步" }
        switch syncController.status {
        case .disabled: return "同步已关闭"
        case .awaitingFolder: return "同步文件夹尚未就绪"
        case .syncing: return "正在同步"
        case .completed: return "上次同步已在本机完成"
        case .pending: return "有更改等待同步"
        case .unavailable: return "同步文件夹暂不可用"
        case .unauthorized: return "文件夹访问授权已失效"
        case .failed: return "上次同步未完成"
        }
    }

    private var statusDetail: LocalizedStringKey {
        guard syncController.enabled else {
            return "Daybreak 仍可离线使用本机数据；关闭同步不会删除已缓存的内容。"
        }
        guard syncController.folderName != nil else {
            return "开启同步需要一个可访问的文件夹。请选择 iCloud Drive 中的文件夹；也可以稍后再选。"
        }
        if isRequestingSync {
            return "正在读取本地记录并写入同步文件夹。你可以继续使用其他页面。"
        }
        switch syncController.status {
        case .disabled:
            return "Daybreak 仍可离线使用本机数据；关闭同步不会删除已缓存的内容。"
        case .awaitingFolder:
            return "请重新选择同步文件夹以继续；选择后同步才会开始。"
        case .syncing:
            return "正在读取本地记录并写入同步文件夹。你可以继续使用其他页面。"
        case .completed:
            return "只表示本机已完成文件处理与写入，不代表其他设备已接收、导入或应用这些更改。"
        case .pending:
            switch syncController.lastIssue {
            case .folderAccess:
                return "无法读写同步文件夹。请确认 iCloud Drive 中的 Daybreak 文件夹可写后重试。"
            case .passInProgress:
                return "上一次同步仍在处理，稍后会自动继续；本机数据未受影响。"
            default:
                return "同步尚未完成。保持应用运行并联网后，Daybreak 会继续处理；本机数据未受影响。"
            }
        case .unavailable:
            return "请确认“文件”App 中的 iCloud Drive 已登录并可访问；本机数据与已写入的记录未受影响。"
        case .unauthorized:
            return "请重新选择该文件夹以授予访问权限。不会删除本机数据，也不会删除文件夹中的旧记录。"
        case .failed:
            switch syncController.lastIssue {
            case .incompatibleFolder:
                return "该文件夹不是兼容的 Daybreak 同步文件夹。请选择其他文件夹后重试。"
            case .repositoryFailure:
                return "本机同步记录读取失败。请重启 Daybreak 后重试，本机数据仍可离线使用。"
            case .folderAccess:
                return "写入同步文件夹失败。请检查 iCloud Drive 中的 Daybreak 文件夹后重试。"
            default:
                return "请检查网络与文件夹状态后重试；本机数据与已缓存内容仍可离线使用。"
            }
        }
    }

    private var statusIcon: String {
        guard syncController.enabled else { return "pause.circle" }
        guard syncController.folderName != nil else { return "questionmark.folder" }
        if isRequestingSync { return "arrow.triangle.2.circlepath" }
        switch syncController.status {
        case .disabled: return "pause.circle"
        case .awaitingFolder: return "questionmark.folder"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .pending: return "clock.arrow.circlepath"
        case .unavailable: return "icloud.slash"
        case .unauthorized: return "lock.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusTint: Color {
        guard syncController.enabled else { return .gray }
        guard syncController.folderName != nil else { return .orange }
        if isRequestingSync { return .accentColor }
        switch syncController.status {
        case .disabled: return .gray
        case .awaitingFolder: return .orange
        case .syncing: return .accentColor
        case .completed: return .green
        case .pending: return .orange
        case .unavailable: return .orange
        case .unauthorized: return .orange
        case .failed: return .red
        }
    }
}
