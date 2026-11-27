import AppKit
import Combine
import DaybreakCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings page embedded in the main window's navigation.
///
/// Most pane tabs reuse the grouped `Form` layout their settings area needs;
/// the Storage tab embeds the full `StorageView` management surface.
/// Wallpaper writes are confirmed by the app's single shared confirmation
/// dialog, so this view asks the parent to switch to Today through `onApply`
/// and `onEnableAutoSync` instead of starting a write from Settings. The
/// auto-overwrite switch shows its own one-step confirmation in place.
///
/// `AppShell` supplies the main window's frosted backdrop. Pane content
/// therefore stays transparent, while every custom card, chip and icon plate
/// uses an opaque semantic fill: stacking a material on the window blur makes
/// text unreadable. Grouped `Form` pages hide only their scroll background so
/// the frost shows between their native section cards.
struct SettingsView: View {
    let model: AppModel
    /// Shared with Recap so the Storage tab manages the same local repository
    /// and cache-protection state. Loading can still be in flight when the
    /// user opens Settings, so the Storage tab renders its own placeholder.
    let recap: RecapScreenModel?
    /// Owned by the app shell so menu commands and the Recap storage button can
    /// select the Storage tab even if Settings is already visible.
    @Binding var section: SettingsSection
    /// Parent switches navigation to `.today` and requests the apply
    /// preflight. The consent sheet lives in `TodayView`, so a write must never
    /// start before this navigation.
    let onApply: () -> Void
    /// Parent switches navigation to `.today` and requests enabling automatic
    /// synchronization.
    let onEnableAutoSync: () -> Void
    /// Switches the main window to Today without starting any write.
    let onOpen: () -> Void
    /// The interface locale, used to resolve the tab titles so an in-app
    /// language switch updates the native tab bar without relaunching.
    @Environment(\.locale) private var locale

    var body: some View {
        // A real tab view, not a segmented control. macOS draws the native tab
        // bar above the content, owns the selected-tab treatment and handles
        // focus traversal; the app supplies only the icon-and-title labels and
        // the selection binding.
        TabView(selection: $section) {
            WallpaperSettingsPane(model: model, onApply: onApply, onOpen: onOpen)
                .tabItem { tabLabel(for: .wallpaper) }
                .tag(SettingsSection.wallpaper)

            AutomationSettingsPane(
                model: model,
                onEnableAutoSync: onEnableAutoSync,
                onOpen: onOpen
            )
            .tabItem { tabLabel(for: .automation) }
            .tag(SettingsSection.automation)

            ContentSettingsPane(model: model)
                .tabItem { tabLabel(for: .content) }
                .tag(SettingsSection.content)

            SyncSettingsPane(model: model)
                .tabItem { tabLabel(for: .sync) }
                .tag(SettingsSection.sync)

            StorageSettingsTab(recap: recap)
                .tabItem { tabLabel(for: .storage) }
                .tag(SettingsSection.storage)

            AboutSettingsPane(model: model)
                .tabItem { tabLabel(for: .about) }
                .tag(SettingsSection.about)
        }
        // Keep the grouped forms near their native Settings width inside a
        // wide main window; the native tab bar centers with that column.
        .frame(maxWidth: 780, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("设置")
    }

    /// Titles are resolved through the interface locale so switching
    /// language updates the native tab bar without relaunching.
    private func tabLabel(for section: SettingsSection) -> some View {
        Label(section.title(in: locale), systemImage: section.systemImage)
            // Keep the symbol visible alongside the title in the native tab
            // bar instead of letting the system collapse to a text-only tab.
            .labelStyle(.titleAndIcon)
    }
}

/// Identifies one Settings tab. The app shell owns the value so navigation
/// from commands and cross-page buttons can address a tab directly.
enum SettingsSection: Hashable, CaseIterable {
    case wallpaper
    case automation
    case content
    case sync
    case storage
    case about

    /// Resolved through the interface locale so the native tab bar follows an
    /// in-app language change without relaunching.
    func title(in locale: Locale) -> String {
        switch self {
        case .wallpaper: String(localized: LocalizedStringResource("壁纸", locale: locale))
        case .automation: String(localized: LocalizedStringResource("自动同步", locale: locale))
        case .content: String(localized: LocalizedStringResource("内容", locale: locale))
        case .sync: String(localized: LocalizedStringResource("同步", locale: locale))
        case .storage: String(localized: LocalizedStringResource("存储", locale: locale))
        case .about: String(localized: LocalizedStringResource("关于", locale: locale))
        }
    }

    /// Matches the symbol each category used in the previous tab labels.
    var systemImage: String {
        switch self {
        case .wallpaper: "photo.on.rectangle.angled"
        case .automation: "arrow.triangle.2.circlepath"
        case .content: "globe.asia.australia"
        case .sync: "icloud"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}

/// Matches the centered content column macOS gives a grouped settings `Form`
/// (about 700 pt wide, with a 20 pt minimum gutter). Page headers and the
/// wallpaper summary use this column so they line up with the form cards
/// instead of spanning the whole page while the form stays centered.
private extension View {
    func settingsContentColumn() -> some View {
        frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Settings chrome

/// Page heading shared by every Settings pane. Keeps titles, purpose text and
/// the at-a-glance state chip in the same position so switching tabs feels
/// like moving between pages instead of opening unrelated panels.
private struct SettingsPaneHeader: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var tint: Color = .accentColor
    var status: SettingsHeaderStatus?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsSymbolTile(systemImage: systemImage, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            if let status {
                SettingsStatusChip(
                    content: status.content,
                    systemImage: status.systemImage,
                    tint: status.tint
                )
                // A dynamic status must never starve the title column or wrap
                // the capsule into a second line. 220 pt covers the longest
                // current values in Chinese, English and Japanese.
                .frame(maxWidth: 220, alignment: .trailing)
                .layoutPriority(0)
            }
        }
        .settingsContentColumn()
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

/// Optional trailing chip on a page heading. Values that come from the model
/// are passed verbatim because `AppModel` already owns their wording.
private struct SettingsHeaderStatus {
    var content: SettingsStatusChip.Content
    var systemImage: String?
    var tint: Color = .secondary

    static func key(
        _ key: LocalizedStringKey,
        systemImage: String? = nil,
        tint: Color = .secondary
    ) -> Self {
        .init(content: .key(key), systemImage: systemImage, tint: tint)
    }

    static func text(
        _ text: String,
        systemImage: String? = nil,
        tint: Color = .secondary
    ) -> Self {
        .init(content: .text(text), systemImage: systemImage, tint: tint)
    }
}

private struct SettingsStatusChip: View {
    enum Content {
        case key(LocalizedStringKey)
        case text(String)
    }

    var content: Content
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            label
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
            Capsule()
                .fill(tint.opacity(0.12))
        }
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var label: some View {
        switch content {
        case .key(let key):
            Text(key)
        case .text(let text):
            Text(verbatim: text)
        }
    }
}

/// Small glyph plate for page headings. The plate is deliberately opaque:
/// the window already owns the frosted backdrop, and a glass or material
/// plate would layer a second blur under the glyph.
private struct SettingsSymbolTile: View {
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        plate
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.14))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 1)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
    }

    private var plate: some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
    }
}

/// Single summary card per pane at most. Grouped `Form` sections already read
/// as cards; this panel is reserved for the one live summary that needs to
/// stand apart (today's wallpaper target). It stays opaque so its text never
/// competes with the frosted window behind it.
private struct SettingsSummaryCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            }
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }
}

// MARK: - Shared rows

private struct StatusLine: View {
    let color: Color
    let title: String
    var isBusy = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.callout)
            Spacer(minLength: 8)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在更新")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IssueLabel: View {
    let text: String
    let systemImage: String
    var font: Font = .callout

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Wallpaper

private struct WallpaperSettingsPane: View {
    let model: AppModel
    let onApply: () -> Void
    let onOpen: () -> Void

    @State private var overwriteCandidate: WallpaperGuardInfo?

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(
                systemImage: "photo.on.rectangle.angled",
                title: "壁纸",
                subtitle: "选择显示器并写入今日图片。每次写入前只确认一次目标显示器与效果。",
                status: headerStatus
            )

            SettingsSummaryCard {
                HStack(alignment: .center, spacing: 14) {
                    TodayThumbnail(model: model)
                        .frame(width: 112, height: 63)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("今日图片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        titleText
                        targetText
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    // Take every point the actions column does not need so the
                    // headline wraps instead of collapsing beside the button.
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 6) {
                        Button(action: onApply) {
                            Label("设为壁纸…", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(applyDisabled)
                        .help(applyHelp)

                        actionHint
                    }
                    .multilineTextAlignment(.trailing)
                    // Keep the primary action at its natural width; without
                    // this the button label and hint truncate first when the
                    // window is narrow or the title is long.
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .settingsContentColumn()
            .padding(.bottom, 12)

            Form {
                if let error = model.wallpaperError, !error.isEmpty {
                    Section {
                        IssueLabel(text: error, systemImage: "exclamationmark.triangle")
                    } header: {
                        Text("壁纸错误")
                    }
                }

                if let status = model.wallpaperStatusMessage, !status.isEmpty {
                    Section {
                        Label(status, systemImage: "info.circle")
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("壁纸状态")
                    }
                }

                Section {
                    if model.displays.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                "未检测到已连接显示器",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.callout)
                            Text("显示器列表会随系统显示器连接或断开自动更新。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Picker("手动应用目标", selection: displayBinding) {
                            ForEach(model.displays) { display in
                                Text(display.label).tag(Optional(display.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("显示器")
                } footer: {
                    Text("手动应用只写入所选显示器；自动同步会应用到全部当前已连接显示器。")
                }

                Section {
                    Text("点击“设为壁纸…”后会出现一次确认，显示目标显示器与目标图片。确认按钮会生成本次写入的内部令牌；不会要求逐项勾选。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("只会修改当前可访问的桌面；未激活的 Space 不会立即更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("写入确认")
                }

                if !model.guardBlocks.isEmpty {
                    Section {
                        Text("以下显示器的当前壁纸不是 Daybreak 设置的，或尚未确认要覆盖；写入会暂停，不会覆盖未知壁纸。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(model.guardBlocks) { block in
                            guardRow(block)
                        }
                    } header: {
                        Text("按显示器确认")
                    }
                }

                Section {
                    Text("Space 切换后，Daybreak 会在新激活的可访问桌面重新检查目标；未激活的 Space 不会立即更新。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Space 行为")
                }
            }
            .formStyle(.grouped)
            // The main window supplies the frost; keep only the native
            // grouped section cards opaque and let the window blur show in
            // the gaps instead of painting a second surface here.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "确认覆盖当前壁纸？",
            isPresented: overwriteAlertBinding,
            presenting: overwriteCandidate
        ) { block in
            Button("取消", role: .cancel) {
                overwriteCandidate = nil
            }
            Button("确认覆盖", role: .destructive) {
                overwriteCandidate = nil
                model.confirmGuardOverwrite(
                    displayID: block.displayID,
                    observedImageURL: block.observedImageURL
                )
            }
        } message: { block in
            Text(
                "\(block.displayName)\n\n\(block.reason)\n\n当前壁纸：\(block.observedImageURL?.lastPathComponent ?? MacLocalizedString.resolve("无法读取", locale: WallpaperInterfaceLocale.current))\n将替换为：\(block.desiredImageURL?.lastPathComponent ?? MacLocalizedString.resolve("目标壁纸", locale: WallpaperInterfaceLocale.current))\n\n仅修改当前可访问的桌面；如果当前壁纸已经变化，写入会被拒绝。"
            )
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var titleText: some View {
        if let title = model.payload?.title, !title.isEmpty {
            Text(title)
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.payload != nil {
            Text("来源未提供标题")
                .font(.headline)
                .foregroundStyle(.secondary)
        } else {
            Text("尚未载入今日内容")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var targetText: some View {
        if model.displays.isEmpty {
            Text("没有可用的已连接显示器")
        } else if let display = selectedDisplay {
            Text("目标显示器：\(display.label)")
        } else {
            Text("未选择显示器")
        }
    }

    @ViewBuilder
    private var actionHint: some View {
        if model.isPreparingConsent {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在准备写入确认…")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if model.isApplyingWallpaper {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在写入壁纸…")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if model.pendingWallpaperConfirmation != nil {
            Text("等待确认…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func guardRow(_ block: WallpaperGuardInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(block.displayName)
                .font(.callout.weight(.medium))
            Text(block.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = block.observedImageURL {
                Text("当前壁纸：\(url.lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if block.canConfirm {
                Button("确认覆盖…") {
                    overwriteCandidate = block
                }
                .disabled(model.isApplyingWallpaper)
                .accessibilityLabel("确认覆盖 \(block.displayName) 的当前壁纸")
            } else {
                Text("系统没有返回当前壁纸，无法按图片确认覆盖。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Bindings and derived state

    private var selectedDisplay: DesktopDisplayOption? {
        guard let id = model.selectedDisplayID else { return nil }
        return model.displays.first(where: { $0.id == id })
    }

    private var displayBinding: Binding<DesktopDisplayID?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { model.selectDisplay($0) }
        )
    }

    private var applyDisabled: Bool {
        !model.canApplyWallpaper
            || model.isPreparingConsent
            || model.displays.isEmpty
            || model.pendingWallpaperConfirmation != nil
    }

    private var applyHelp: LocalizedStringKey {
        if model.payload == nil { return "先载入今日内容" }
        if model.displays.isEmpty { return "未检测到已连接的显示器" }
        if model.isPreparingConsent { return "正在准备写入确认" }
        if model.isApplyingWallpaper { return "正在写入壁纸" }
        if model.pendingWallpaperConfirmation != nil { return "已有等待确认的写入" }
        if model.isDownloadingOriginal { return "正在下载原图，完成后可写入" }
        return "打开今日窗口并确认一次后写入"
    }

    private var headerStatus: SettingsHeaderStatus {
        if model.isPreparingConsent {
            return .key("正在准备", systemImage: "hourglass", tint: .secondary)
        }
        if model.isApplyingWallpaper {
            return .key("正在写入", systemImage: "hourglass", tint: .secondary)
        }
        if model.pendingWallpaperConfirmation != nil {
            return .key("等待确认", systemImage: "checkmark.shield", tint: .orange)
        }
        if model.displays.isEmpty {
            return .key(
                "无可用显示器",
                systemImage: "display.trianglebadge.exclamationmark",
                tint: .orange
            )
        }
        return .key(
            "\(model.displays.count) 台显示器",
            systemImage: "display",
            tint: .secondary
        )
    }

    private var overwriteAlertBinding: Binding<Bool> {
        Binding(
            get: { overwriteCandidate != nil },
            set: { newValue in
                if !newValue { overwriteCandidate = nil }
            }
        )
    }
}

// MARK: - Automation

private struct AutomationSettingsPane: View {
    let model: AppModel
    let onEnableAutoSync: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(
                systemImage: "arrow.triangle.2.circlepath",
                title: "自动同步",
                subtitle: "让桌面壁纸与所选地区的今日图片保持一致。",
                status: headerStatus
            )

            Form {
                Section {
                    Toggle("自动同步桌面壁纸", isOn: autoSyncBinding)
                        .toggleStyle(.switch)
                        .disabled(isAutoSyncControlDisabled)
                        .help(automationHelp)

                    StatusLine(
                        color: automationColor,
                        title: automationTitle,
                        isBusy: isBusy
                    )

                    Button {
                        model.refreshNow()
                    } label: {
                        Label("立即检查今日内容", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)

                    if model.payload == nil, !model.autoSyncEnabled {
                        Text("需要先载入今日内容才能准备自动更新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.displays.isEmpty, !model.autoSyncEnabled {
                        Text("没有可用的已连接显示器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.pendingWallpaperConfirmation != nil {
                        Label("等待确认…", systemImage: "checkmark.shield")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    if model.requiresDisableRetry {
                        IssueLabel(
                            text: MacLocalizedString.resolve("本次会话已停止自动写入，但保存的设置可能仍为自动同步；重新启动后可能恢复。", locale: WallpaperInterfaceLocale.current),
                            systemImage: "exclamationmark.triangle",
                            font: .caption
                        )

                        Button("重试关闭自动同步") {
                            model.setAutoSync(false)
                        }
                        .disabled(model.isUpdatingAutomation)
                    }
                } header: {
                    Text("自动更新")
                } footer: {
                    Text("默认关闭。明确开启后会保存，重新启动后继续；自动同步只更新已设置目标的显示器。")
                }

                Section {
                    Toggle("自动覆盖未知壁纸", isOn: autoOverwriteBinding)
                        .toggleStyle(.switch)
                        .disabled(isAutoOverwriteControlDisabled)
                        .help(autoOverwriteHelp)

                    Text("默认关闭，必须单独确认。关闭时，遇到不是你设置或尚未确认的当前壁纸会暂停，并等待按显示器确认；手动保护的显示器始终保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("自动覆盖")
                } footer: {
                    Text("开启后，自动同步运行时会直接替换当前可访问桌面的未知壁纸，不再逐台确认。手动保护的显示器仍会暂停；未激活的 Space 不会立即更新。")
                }

                NotificationSettingsSection(model: model)

                Section {
                    LabeledContent("执行时机") {
                        Text("地区日期变化后检查新内容；Space、显示器变化、唤醒与鼠标跨显示器移动后检查壁纸")
                    }
                    LabeledContent("写入目标") {
                        Text("已设置自动壁纸的显示器")
                    }
                    LabeledContent("内容来源") {
                        Text("所选地区的 Bing 每日图片与介绍")
                    }
                } header: {
                    Text("执行范围")
                } footer: {
                    Text("自动同步开启且应用运行时，Daybreak 会检查新内容，并在切换桌面、显示器变化、唤醒，或鼠标进入另一台显示器后检查已设置的壁纸。新接入的显示器可能暂时不会自动更新；未激活的 Space 不会立即更新。")
                }

                Section {
                    Text("Space 切换后，Daybreak 只会在新激活的可访问桌面重新检查目标；未激活的 Space 不会立即更新。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.autoOverwriteEnabled {
                        Text("自动覆盖已开启：自动同步运行时，未知壁纸会被替换；手动保护的显示器仍会暂停。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("自动覆盖关闭：无法确认的当前壁纸会暂停写入，并等待你按显示器确认。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("写入范围")
                }
            }
            .formStyle(.grouped)
            // The main window supplies the frost; keep only the native
            // grouped section cards opaque and let the window blur show in
            // the gaps instead of painting a second surface here.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Bindings and derived state

    private var autoSyncBinding: Binding<Bool> {
        Binding(
            get: { model.autoSyncEnabled },
            set: { enabled in
                if enabled {
                    guard model.payload != nil,
                          !model.displays.isEmpty,
                          !model.autoSyncEnabled,
                          !model.requiresDisableRetry
                    else {
                        return
                    }
                    onEnableAutoSync()
                } else {
                    model.setAutoSync(false)
                }
            }
        )
    }

    private var autoOverwriteBinding: Binding<Bool> {
        Binding(
            get: { model.autoOverwriteEnabled },
            set: { model.setAutoOverwrite($0) }
        )
    }

    private var isAutoOverwriteControlDisabled: Bool {
        model.isPreparingConsent
            || model.isApplyingWallpaper
            || model.isUpdatingAutomation
            || model.requiresDisableRetry
            || model.pendingWallpaperConfirmation != nil
    }

    private var autoOverwriteHelp: LocalizedStringKey {
        if model.isUpdatingAutomation { return "正在更新壁纸设置" }
        if model.pendingWallpaperConfirmation != nil { return "已有等待确认的写入" }
        if model.requiresDisableRetry { return "请先重试关闭自动同步" }
        return "默认关闭；开启只影响自动事件，仍需单独的确认"
    }

    private var isAutoSyncControlDisabled: Bool {
        if model.isPreparingConsent
            || model.isDownloadingOriginal
            || model.isApplyingWallpaper
            || model.isUpdatingAutomation
            || model.requiresDisableRetry
            || model.pendingWallpaperConfirmation != nil {
            return true
        }
        // Turning automatic writes off must always be possible, even when no
        // content or display list is available to prepare a new write.
        guard !model.autoSyncEnabled else { return false }
        return model.payload == nil || model.displays.isEmpty
    }

    private var isBusy: Bool {
        model.isUpdatingAutomation || model.isPreparingConsent || model.isApplyingWallpaper
    }

    private var automationTitle: String {
        if isBusy {
            return MacLocalizedString.resolve("正在更新壁纸设置…", locale: WallpaperInterfaceLocale.current)
        }
        if model.requiresDisableRetry {
            return MacLocalizedString.resolve("自动写入可能仍在启用", locale: WallpaperInterfaceLocale.current)
        }
        return model.autoSyncEnabled
            ? MacLocalizedString.resolve("自动同步已开启", locale: WallpaperInterfaceLocale.current)
            : MacLocalizedString.resolve("自动同步未开启", locale: WallpaperInterfaceLocale.current)
    }

    private var automationColor: Color {
        if isBusy {
            return .secondary
        }
        if model.requiresDisableRetry {
            return .orange
        }
        return model.autoSyncEnabled ? .green : .secondary
    }

    private var headerStatus: SettingsHeaderStatus {
        if isBusy {
            return .key("正在更新", systemImage: "hourglass", tint: .secondary)
        }
        if model.requiresDisableRetry {
            return .key("需要重试", systemImage: "exclamationmark.triangle", tint: .orange)
        }
        if model.autoSyncEnabled {
            return .key("已开启", systemImage: "checkmark.circle", tint: .green)
        }
        return .key("已关闭", systemImage: "pause.circle", tint: .secondary)
    }

    private var automationHelp: LocalizedStringKey {
        if model.isUpdatingAutomation { return "正在更新壁纸设置" }
        if model.isPreparingConsent || model.isApplyingWallpaper {
            return "正在准备写入确认"
        }
        if model.pendingWallpaperConfirmation != nil { return "已有等待确认的写入" }
        if model.requiresDisableRetry { return "本次会话已停止自动写入，请先重试关闭自动同步" }
        if model.autoSyncEnabled { return "关闭后不再自动写入壁纸" }
        if model.payload == nil { return "先载入今日内容" }
        if model.displays.isEmpty { return "未检测到已连接的显示器" }
        return "开启前会显示一次确认"
    }
}

// MARK: - Notification settings

/// Notification controls live beside the wallpaper automation flow instead of
/// the About pane, so the app opt-in and the real system permission are
/// visible where users expect them. The section never changes system
/// notification settings; it reports the live state and offers the request or
/// retry action that the user must trigger.
private struct NotificationSettingsSection: View {
    let model: AppModel

    private var notifications: DailyNotificationController {
        model.dailyNotifications
    }

    var body: some View {
        Section {
            Toggle(
                "应用今日壁纸后发送通知",
                isOn: Binding(
                    get: { notifications.isEnabled },
                    set: { notifications.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(notifications.isUpdating)
            .accessibilityHint("仅在今日壁纸实际应用成功且属于新的来源日期时发送")

            LabeledContent("系统通知权限") {
                HStack(spacing: 6) {
                    if notifications.isUpdating {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在检查通知权限…")
                    }
                    Text(notifications.permissionLabel)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if notifications.isEnabled,
               notifications.authorization != .unknown,
               !notifications.authorization.allowsDelivery {
                Text("系统尚未授权通知，当前不会发送。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if notifications.canRetryAuthorization {
                Button("重试通知授权") {
                    notifications.retryAuthorizationRequest()
                }
                .disabled(notifications.isUpdating)
            } else if notifications.authorization == .notDetermined {
                Button("请求通知权限") {
                    notifications.retryAuthorizationRequest()
                }
                .disabled(notifications.isUpdating)
            }

            if notifications.canOpenSystemSettings {
                Button("打开系统通知设置") {
                    notifications.openSystemSettings()
                }
            }

            if let error = notifications.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("首次使用时，Daybreak 会直接请求系统通知权限；已拒绝或已授权后不会反复询问。仅在今日壁纸实际应用成功且内容属于新的来源日期时发送本机通知；写入失败、保护暂停或离线时不会发送。通知不经过任何服务器。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("通知")
        }
        .task {
            await notifications.refreshPermission()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // The user may have changed the permission in System Settings.
            // Re-read the real state when they return; never prompt from here.
            Task { @MainActor in
                await notifications.refreshPermission()
            }
        }
    }
}

// MARK: - Content

private struct ContentSettingsPane: View {
    let model: AppModel
    @State private var languagePreference = AppLanguagePreference()
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(
                systemImage: "globe.asia.australia",
                title: "内容",
                subtitle: "选择界面语言与 Bing 内容地区。",
                status: headerStatus
            )

            Form {
                Section {
                    Picker("界面语言", selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title(in: locale)).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("界面")
                } footer: {
                    Text("界面语言独立于内容地区；Bing 来源介绍不会被自动翻译。部分系统菜单和状态文字仍跟随系统语言。")
                }

                Section {
                    Picker("内容地区", selection: marketSelectionBinding) {
                        Text(followSystemLabel)
                            .tag(MarketSelection.followSystem)
                        ForEach(MarketChoice.allCases) { choice in
                            Text(choice.menuLabel(in: locale))
                                .tag(MarketSelection.explicit(choice.market))
                        }
                    }
                    .pickerStyle(.menu)

                    if let notice = model.marketSelectionNotice(in: locale) {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("内容地区")
                } footer: {
                    Text("默认跟随系统地区和首选语言，只有手动选择地区后才会保存。地区决定图片、来源日期和介绍原文；切换后会先显示该地区已缓存的内容，再尝试联网更新，不会用其他地区的文字填补。")
                    Text("来源日期按所选地区的当地时间计算，可能与 Bing 网页显示的日期略有差异。")
                    Text("地区列表覆盖 Bing 提供的常用地区。不同地区可能显示同一张图片，Daybreak 无法总是确认实际返回的地区。")
                    Text("系统语言或地区更改后，重新启动 Daybreak 以更新跟随系统的内容地区。")
                }

                Section {
                    if let payload = model.payload {
                        HStack(alignment: .top, spacing: 14) {
                            TodayThumbnail(model: model)
                                .frame(width: 128, height: 72)

                            VStack(alignment: .leading, spacing: 4) {
                                if let title = payload.title, !title.isEmpty {
                                    Text(title)
                                        .font(.headline)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("来源未提供标题")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }

                                if payload.isSourceDateToday {
                                    Text("\(payload.sourceDate.iso8601) · 今日")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(payload.sourceDate.iso8601) · 最新来源日期")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let copyright = payload.copyright, !copyright.isEmpty {
                                    Text(copyright)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("版权信息不可用")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            // Give the text column the full remaining width;
                            // a trailing Spacer previously let it collapse to
                            // its ideal width when the title was long.
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack(spacing: 10) {
                            Button {
                                model.refreshNow()
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isRefreshing)

                            if model.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("正在刷新")
                            }

                            Spacer(minLength: 8)

                            if !payload.hasOriginal {
                                Button {
                                    model.downloadOriginal()
                                } label: {
                                    Label("下载原图", systemImage: "arrow.down.circle")
                                }
                                .disabled(model.isDownloadingOriginal)
                            }

                            if model.isDownloadingOriginal {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("正在下载原图")
                            }
                        }

                        LabeledContent("来源") {
                            Text(model.sourceOriginLabel)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)

                        if let lastUpdated = model.lastUpdated {
                            LabeledContent("最近成功获取") {
                                Text(StatusFormatter.dateTime(lastUpdated, locale: locale))
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                        }
                        if let storage = model.storageSummary {
                            LabeledContent("本地图片缓存") {
                                Text(storage)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                        }
                    } else {
                        Text("尚未载入今日内容。")
                            .foregroundStyle(.secondary)
                        Button("刷新今日", action: model.retry)
                            .disabled(model.isRefreshing)
                    }
                } header: {
                    Text("今日内容")
                }

                Section {
                    storyStatus
                } header: {
                    Text("每日介绍")
                }

                if let error = model.errorBanner {
                    Section {
                        IssueLabel(text: error, systemImage: "exclamationmark.triangle")
                        Button("重试", action: model.retry)
                            .disabled(model.isRefreshing)
                    } header: {
                        Text("状态")
                    }
                }

                if !model.warnings.isEmpty {
                    Section {
                        ForEach(model.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.bubble")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("获取提示")
                    }
                }
            }
            .formStyle(.grouped)
            // The main window supplies the frost; keep only the native
            // grouped section cards opaque and let the window blur show in
            // the gaps instead of painting a second surface here.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var marketSelectionBinding: Binding<MarketSelection> {
        Binding(
            get: { model.marketSelection },
            set: { model.selectMarket($0) }
        )
    }

    private var followSystemLabel: String {
        let name = LocalePresentation.marketName(for: model.systemMarket, in: locale)
        return MacLocalizedString.resolve("跟随系统（当前为 \(name)）", locale: locale)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { languagePreference.selection },
            set: { languagePreference.select($0) }
        )
    }

    private var headerStatus: SettingsHeaderStatus {
        .text(
            model.statusTitle,
            systemImage: contentStatusSymbol,
            tint: contentStatusColor
        )
    }

    private var contentStatusColor: Color {
        switch model.loadState {
        case .ready, .refreshing: return .green
        case .offline: return .orange
        case .failed: return .red
        case .empty, .idle, .loadingCache: return .secondary
        }
    }

    private var contentStatusSymbol: String {
        switch model.loadState {
        case .ready, .refreshing: return "checkmark.circle"
        case .offline: return "wifi.slash"
        case .failed: return "exclamationmark.triangle"
        case .empty: return "tray"
        case .idle, .loadingCache: return "hourglass"
        }
    }

    @ViewBuilder
    private var storyStatus: some View {
        switch model.storyPanel ?? .notFetched {
        case .available(let story):
            Label("已获取来源介绍", systemImage: "checkmark.circle")
                .font(.callout)
            if let headline = story.headline, !headline.isEmpty {
                Text(headline)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let title = story.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(StoryCopy.provenance(localeTag: story.locale, fetchedAt: story.fetchedAt, in: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable(let reason, _, let headline, _, _):
            Label("介绍暂不可用", systemImage: "text.book.closed")
                .font(.callout)
            Text(StoryCopy.unavailableReason(reason))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let headline, !headline.isEmpty {
                Text(headline)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("介绍不可用时只显示来源已提供的信息，不会用其他日期或地区文本补齐。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unmatched(let hasCandidates):
            if hasCandidates {
                Text("无法确认介绍属于这张图片")
                    .font(.callout)
            } else {
                Text("未取得当日介绍")
                    .font(.callout)
            }
            Text("为避免错配，未显示可能属于其他图片或日期的文本。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notFetched:
            Text("尚未获取当日介绍。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sync

/// Optional folder synchronization for favorites and saved content.
///
/// The pane owns no sync state: every value comes from the shared
/// `DaybreakSyncController`, and every action awaits its async API. It also
/// never resolves or prints the selected folder path; only the folder name is
/// shown. A `.completed` status deliberately reads as a local finish so it
/// cannot be mistaken for confirmation that another device received anything.
private struct SyncSettingsPane: View {
    let model: AppModel

    @Environment(\.locale) private var locale
    @State private var isChoosingFolder = false
    @State private var isWorking = false
    @State private var folderSelectionMessage: String?

    private var sync: DaybreakSyncController? { model.syncController }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(
                systemImage: "icloud",
                title: "同步",
                subtitle: "用你选择的共享文件夹，在设备之间同步收藏与已保存内容。",
                status: headerStatus
            )

            if sync == nil {
                ProgressView("正在载入本地数据…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        Toggle("启用文件夹同步", isOn: enabledBinding)
                            .toggleStyle(.switch)
                            // Turning sync on without a folder uses the
                            // `iCloud Drive/Daybreak` default, which is created
                            // on first use. The folder action below remains the
                            // explicit alternative.
                            .disabled(isWorking || displayedStatus.isSyncing)
                            .accessibilityHint("开启后会将收藏与已保存内容写入所选文件夹")

                        LabeledContent("同步文件夹") {
                            Text(folderName)
                                .foregroundStyle(hasFolder ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }

                        StatusLine(
                            color: displayedStatus.tint,
                            title: displayedStatus.title(in: locale),
                            isBusy: isWorking || displayedStatus.isSyncing
                        )

                        LabeledContent("上次本机同步") {
                            Text(lastSyncText)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            Button(folderActionTitle) {
                                folderSelectionMessage = nil
                                isChoosingFolder = true
                            }
                            .disabled(isWorking || displayedStatus.isSyncing)
                            .help(folderActionHelp)

                            Button {
                                perform(.syncNow)
                            } label: {
                                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(!canSyncNow)
                            .help(syncNowHelp)
                        }

                        if let folderSelectionMessage {
                            Text(folderSelectionMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("文件夹同步")
                    } footer: {
                        Text("默认关闭。开启时若尚未授权文件夹，Daybreak 会使用并自动创建 iCloud Drive 中的 Daybreak 文件夹；iCloud Drive 不可用时才需要手动选择。只读写该文件夹中的 Daybreak 同步文件；关闭或更换文件夹不会删除本地数据或文件夹中已有的副本。")
                    }

                    Section {
                        Toggle("同步原图", isOn: originalsBinding)
                            .toggleStyle(.switch)
                            .disabled(optionsDisabled)
                            .accessibilityHint("默认关闭；开启后原图也会写入共享文件夹")

                        Toggle("同步内容地区偏好", isOn: marketBinding)
                            .toggleStyle(.switch)
                            .disabled(optionsDisabled)
                            .accessibilityHint("默认关闭；开启后内容地区偏好也会写入共享文件夹")
                    } header: {
                        Text("同步选项")
                    } footer: {
                        Text("两项都默认关闭，开启同步后可更改。原图较大会占用更多文件夹空间与同步时间；内容地区偏好属于本机设置。更改只影响之后的同步，不会删除文件夹中已有的原图。")
                        Text("同步关闭时选项不可更改，已保存的偏好仍保留在本机。")
                    }

                    Section {
                        Label(
                            "默认同步收藏、固定日期、日期与地区记录、壁纸元数据、介绍、版权与缩略图。",
                            systemImage: "checklist"
                        )
                        .fixedSize(horizontal: false, vertical: true)

                        Label(
                            "仅保存在本机：界面语言、缓存上限、壁纸目标、系统权限与文件夹授权书签。",
                            systemImage: "internaldrive"
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("同步内容")
                    } footer: {
                        Text("每台设备需要各自选择同一个文件夹。同步不使用 CloudKit、App Group 或后台服务器，只通过你选择的文件夹完成。")
                    }

                    Section {
                        Text("关闭同步或更换文件夹不会删除本地数据；文件夹尚未下载、授权失效或传输失败时会保留本地数据。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("同步完成只表示本机这一轮写入结束，不代表其他设备已经接收。系统文件协调不是跨设备锁。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("导入同步数据不会更改本机系统壁纸、裁切或权限；回顾由合并后的本地数据重新计算。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("本地优先与状态")
                    }
                }
                .formStyle(.grouped)
                // The main window supplies the frost; keep only the native
                // grouped section cards opaque and let the window blur show in
                // the gaps instead of painting a second surface here.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderSelection(result)
        }
    }

    // MARK: Bindings and actions

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { sync?.enabled == true },
            set: { enabled in
                guard let controller = sync, enabled != controller.enabled else { return }
                guard enabled else {
                    perform(.setEnabled(false))
                    return
                }
                if hasFolder {
                    perform(.setEnabled(true))
                    return
                }
                // Default to `iCloud Drive/Daybreak`, creating it when iCloud
                // Drive exists. Without iCloud Drive the explicit picker is the
                // only way to grant access, so fall back to it instead of
                // leaving the switch permanently disabled.
                if let folder = SyncFolderDefaults.prepareDefaultFolder(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ) {
                    folderSelectionMessage = nil
                    perform(.selectFolder(folder))
                } else {
                    folderSelectionMessage = MacLocalizedString.resolve(
                        "未找到可用的 iCloud Drive 文件夹，请手动选择。",
                        locale: locale
                    )
                    isChoosingFolder = true
                }
            }
        )
    }

    private var originalsBinding: Binding<Bool> {
        Binding(
            get: { sync?.syncOriginals == true },
            set: { enabled in
                guard let controller = sync,
                      enabled != controller.syncOriginals else { return }
                perform(.setSyncOriginals(enabled))
            }
        )
    }

    private var marketBinding: Binding<Bool> {
        Binding(
            get: { sync?.syncMarket == true },
            set: { enabled in
                guard let controller = sync,
                      enabled != controller.syncMarket else { return }
                perform(.setSyncMarket(enabled))
            }
        )
    }

    /// One local in-flight action at a time. The controller has no busy flag
    /// for preference changes, so this keeps a double-click from issuing two
    /// competing writes while the async setter is still running.
    private func perform(_ action: SyncAction) {
        guard !isWorking, let controller = sync else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            switch action {
            case .setEnabled(let enabled):
                await controller.setEnabled(enabled)
            case .selectFolder(let url):
                // The importer returns a security-scoped URL. Keep access
                // alive while the controller reads its metadata and creates
                // its own bookmark; the view never resolves or logs the path.
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart { url.stopAccessingSecurityScopedResource() }
                }
                await controller.selectFolder(url)
            case .setSyncOriginals(let enabled):
                await controller.setSyncOriginals(enabled)
            case .setSyncMarket(let enabled):
                await controller.setSyncMarket(enabled)
            case .syncNow:
                await controller.syncNow()
            }
        }
    }

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            folderSelectionMessage = nil
            // The importer hands back a security-scoped URL. Pass it straight
            // to the controller, which owns bookmark creation and any scoped
            // access; the view must not resolve or log the path.
            perform(.selectFolder(url))
        case .failure(let error):
            if error is CancellationError { return }
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            folderSelectionMessage = MacLocalizedString.resolve(
                "无法打开文件夹选择器，请重试。",
                locale: locale
            )
        }
    }

    private enum SyncAction: Sendable {
        case setEnabled(Bool)
        case selectFolder(URL)
        case setSyncOriginals(Bool)
        case setSyncMarket(Bool)
        case syncNow
    }

    // MARK: Derived state

    /// The controller owns the authoritative status, including terminal
    /// statuses reached while it flips `enabled` off. If sync is enabled but
    /// no usable folder remains, present the waiting-for-folder state instead
    /// of claiming sync is running.
    private var displayedStatus: DaybreakSyncStatus {
        guard let controller = sync else { return .disabled }
        guard controller.enabled else { return controller.status }
        guard hasFolder else { return .awaitingFolder }
        return controller.status
    }

    private var hasFolder: Bool {
        guard let folderName = sync?.folderName else { return false }
        return !folderName.isEmpty
    }

    private var folderName: String {
        guard let name = sync?.folderName, !name.isEmpty else {
            return MacLocalizedString.resolve("未选择", locale: locale)
        }
        return name
    }

    private var lastSyncText: String {
        guard let lastSyncAt = sync?.lastSyncAt else {
            return MacLocalizedString.resolve("尚无记录", locale: locale)
        }
        return StatusFormatter.dateTime(lastSyncAt, locale: locale)
    }

    private var folderActionTitle: String {
        guard hasFolder else {
            return MacLocalizedString.resolve("选择文件夹…", locale: locale)
        }
        if displayedStatus.isUnauthorized {
            return MacLocalizedString.resolve("重新授权文件夹…", locale: locale)
        }
        return MacLocalizedString.resolve("更换文件夹…", locale: locale)
    }

    private var folderActionHelp: LocalizedStringKey {
        if displayedStatus.isSyncing {
            return "正在同步，请稍后再更换文件夹"
        }
        return "每台设备都需要选择同一个文件夹"
    }

    private var syncNowHelp: LocalizedStringKey {
        if sync?.enabled != true { return "先开启同步" }
        if !hasFolder { return "先选择同步文件夹" }
        if displayedStatus.isSyncing { return "正在同步" }
        if displayedStatus.isUnauthorized { return "先重新授权文件夹" }
        return "立即检查并写入待同步内容"
    }

    private var canSyncNow: Bool {
        guard sync?.enabled == true,
              hasFolder,
              !isWorking,
              !displayedStatus.isSyncing
        else {
            return false
        }
        switch displayedStatus {
        case .pending, .completed, .failed, .unavailable:
            return true
        case .disabled, .awaitingFolder, .syncing, .unauthorized:
            return false
        }
    }

    private var optionsDisabled: Bool {
        sync?.enabled != true || !hasFolder || isWorking || displayedStatus.isSyncing
    }

    private var headerStatus: SettingsHeaderStatus? {
        guard sync != nil else { return nil }
        return SettingsHeaderStatus.key(
            displayedStatus.chipTitle,
            systemImage: displayedStatus.chipSystemImage,
            tint: displayedStatus.tint
        )
    }
}

private extension DaybreakSyncStatus {
    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var tint: Color {
        switch self {
        case .completed: .green
        case .awaitingFolder, .pending, .unavailable: .orange
        case .unauthorized, .failed: .red
        case .disabled, .syncing: .secondary
        }
    }

    func title(in locale: Locale) -> String {
        switch self {
        case .disabled:
            MacLocalizedString.resolve("同步已关闭", locale: locale)
        case .awaitingFolder:
            MacLocalizedString.resolve("尚未选择同步文件夹", locale: locale)
        case .syncing:
            MacLocalizedString.resolve("正在检查并写入同步文件…", locale: locale)
        case .completed:
            MacLocalizedString.resolve("本机同步完成", locale: locale)
        case .pending:
            MacLocalizedString.resolve("仍有等待同步的内容", locale: locale)
        case .unavailable:
            MacLocalizedString.resolve("同步文件夹当前不可用", locale: locale)
        case .unauthorized:
            MacLocalizedString.resolve("文件夹授权已失效，需要重新选择", locale: locale)
        case .failed:
            MacLocalizedString.resolve("上次同步失败", locale: locale)
        }
    }

    var chipTitle: LocalizedStringKey {
        switch self {
        case .disabled: "已关闭"
        case .awaitingFolder: "等待文件夹"
        case .syncing: "正在同步"
        case .completed: "本机完成"
        case .pending: "等待同步"
        case .unavailable: "暂不可用"
        case .unauthorized: "需要授权"
        case .failed: "同步失败"
        }
    }

    var chipSystemImage: String {
        switch self {
        case .disabled: "pause.circle"
        case .awaitingFolder: "folder.badge.questionmark"
        case .syncing: "hourglass"
        case .completed: "checkmark.circle"
        case .pending: "clock"
        case .unavailable: "icloud.slash"
        case .unauthorized: "lock.trianglebadge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}

// MARK: - Storage

/// Settings-owned wrapper around the full `StorageView`. The page header stays
/// in Settings so its layout matches the other tabs; all data, pagination,
/// confirmation and reload behavior lives in `StorageView` and its shared
/// `RecapScreenModel`.
private struct StorageSettingsTab: View {
    let recap: RecapScreenModel?

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(
                systemImage: "internaldrive",
                title: "存储",
                subtitle: "本地缓存、收藏保护与清理",
                status: headerStatus
            )

            if let recap {
                StorageView(model: recap)
            } else {
                ProgressView("正在载入本地内容…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var headerStatus: SettingsHeaderStatus? {
        guard let recap else { return nil }
        if let usage = recap.storageUsage {
            return SettingsHeaderStatus.text(
                String(
                    format: MacLocalizedString.resolve("%@ · %lld 个缓存文件", locale: WallpaperInterfaceLocale.current),
                    StatusFormatter.bytes(usage.totalAssetBytes),
                    usage.assetCount
                )
            )
        }
        if recap.isLoading {
            return SettingsHeaderStatus.key(
                "正在读取本地缓存…",
                systemImage: "hourglass",
                tint: .secondary
            )
        }
        return nil
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    let model: AppModel
    @State private var loginItem = LoginItemController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                appIcon

                VStack(alignment: .leading, spacing: 4) {
                    Text("Daybreak")
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("每天一幅风景，每天一个故事")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("版本 \(Self.versionText)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                SettingsStatusChip(
                    content: .key("本地优先"),
                    systemImage: "lock.shield",
                    tint: .secondary
                )
                .frame(maxWidth: 220, alignment: .trailing)
            }
            .settingsContentColumn()
            .padding(.top, 18)
            .padding(.bottom, 14)

            Form {
                Section {
                    Text("Daybreak 是一款 Bing 每日壁纸客户端，可以浏览来源介绍、时光日历和本地回顾；已缓存的内容可离线查看。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("每日 Bing 壁纸与来源介绍", systemImage: "photo.on.rectangle")
                        Label("多显示器与 Space 壁纸同步", systemImage: "display.2")
                        Label("本机缓存、收藏与年度回顾", systemImage: "clock.arrow.circlepath")
                        Label("无账号、无遥测、无广告", systemImage: "hand.raised")
                    }
                    .font(.callout)
                    .padding(.top, 4)
                } header: {
                    Text("关于 Daybreak")
                }

                MacUpdateSettingsSections()

                Section {
                    authorCard
                } header: {
                    Text("作者")
                }

                Section {
                    Text("图片、图片信息与来源介绍只保存在本机；Daybreak 不上传浏览记录，也没有账号系统或后台服务。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Bing 图片与文字版权归原权利人；应用源代码以 MIT 许可发布。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("数据与隐私")
                }

                Section {
                    LabeledContent("macOS 版本") {
                        Text(Self.operatingSystemVersion)
                    }
                    LabeledContent("应用标识") {
                        Text(Bundle.main.bundleIdentifier ?? "—")
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("运行环境")
                }

                Section {
                    Toggle(
                        "在 Dock 中显示 Daybreak",
                        isOn: Binding(
                            get: { model.showsDockIcon },
                            set: { model.setShowsDockIcon($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .accessibilityHint("隐藏后仍可从菜单栏打开主窗口和设置")

                    LabeledContent("Dock 图标状态") {
                        Text(
                            model.showsDockIcon
                                ? MacLocalizedString.resolve("显示", locale: WallpaperInterfaceLocale.current)
                                : MacLocalizedString.resolve("已隐藏", locale: WallpaperInterfaceLocale.current)
                        )
                        .foregroundStyle(.secondary)
                    }

                    if let error = model.dockIconError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("隐藏后 Dock、Command-Tab 与应用菜单栏不再显示 Daybreak；菜单栏右侧图标仍可打开主窗口、设置，并可通过此开关重新显示 Dock 图标。更改立即生效，只影响 Daybreak，不修改系统设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(
                        "登录时启动 Daybreak",
                        isOn: Binding(
                            get: { loginItem.isEnabled },
                            set: { loginItem.setEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(loginItem.isUpdating || !loginItem.canToggle)

                    LabeledContent("登录项状态") {
                        Text(loginItem.statusText)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if loginItem.requiresApproval || loginItem.canRecheck || loginItem.errorMessage != nil {
                        HStack(spacing: 12) {
                            Button("打开登录项设置") {
                                loginItem.openSystemSettings()
                            }
                            if loginItem.requiresApproval {
                                Button("移除登录项") {
                                    loginItem.setEnabled(false)
                                }
                            }
                            if loginItem.canRecheck {
                                Button("重新检测") {
                                    loginItem.refresh()
                                }
                            }
                        }
                    }

                    if let guidance = loginItem.recoveryGuidance {
                        Text(guidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = loginItem.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("只注册 Daybreak 本身，不会改动其他登录项；可以随时在系统设置的登录项中停用。壁纸写入仍需要先完成确认。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Hiding the Dock icon also removes the app menu bar, so
                    // the standard Quit command may be unavailable. Keep one
                    // explicit quit affordance reachable from the menu bar.
                    HStack {
                        Spacer(minLength: 8)
                        Button("退出 Daybreak", role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        }
                        .help("退出 Daybreak；隐藏 Dock 图标后应用菜单栏不可见")
                    }
                } header: {
                    Text("系统行为")
                }
            }
            .formStyle(.grouped)
            // The main window supplies the frost; keep only the native
            // grouped section cards opaque and let the window blur show in
            // the gaps instead of painting a second surface here.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                // Login items can also be approved or disabled in System
                // Settings. Re-read the live registration status when the
                // user returns; this never registers anything.
                Task { @MainActor in
                    loginItem.refresh()
                }
            }
        }
    }

    /// Public GitHub profile details only. The avatar is decorative: an
    /// offline launch shows an initials placeholder and the app remains fully
    /// usable without fetching it.
    private var authorCard: some View {
        HStack(alignment: .center, spacing: 14) {
            authorAvatar

            VStack(alignment: .leading, spacing: 4) {
                Text("Dylan Liu")
                    .font(.headline)
                Text("Daybreak 作者")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    Link(destination: Self.authorEmailURL) {
                        Label("mentalflow@ourdocs.cn", systemImage: "envelope")
                    }
                    Link(destination: Self.authorGitHubURL) {
                        Label("github.com/mentalfl0w", systemImage: "link")
                    }
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var authorAvatar: some View {
        AsyncImage(url: Self.authorAvatarURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.22),
                            Color.accentColor.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text("DL")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private static let authorGitHubURL = URL(string: "https://github.com/mentalfl0w")!
    private static let authorEmailURL = URL(string: "mailto:mentalflow@ourdocs.cn")!
    private static let authorAvatarURL = URL(string: "https://avatars.githubusercontent.com/u/30333935?v=4")!

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                }
        } else {
            Image(systemName: "sunrise")
                .font(.system(size: 40, weight: .light))
                .frame(width: 76, height: 76)
                .background(
                    Color(nsColor: .quaternaryLabelColor).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    private static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - Shared thumbnail

private struct TodayThumbnail: View {
    let model: AppModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))

            if let image = model.heroImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if let title = model.payload?.title, !title.isEmpty {
            return Text("今日图片：\(title)")
        }
        return Text("今日图片尚未载入")
    }

    private var isLoading: Bool {
        switch model.loadState {
        case .idle, .loadingCache, .refreshing:
            return true
        case .empty, .ready, .offline, .failed:
            return false
        }
    }
}
