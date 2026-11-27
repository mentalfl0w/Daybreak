import SwiftUI
import UIKit
import UserNotifications

/// Setup and daily-automation guide for the supported Shortcuts wallpaper flow.
///
/// The view is deliberately presentational. It opens the public iCloud share
/// pages and the documented `shortcuts://` run URLs, but adding a shortcut and
/// creating an automation happen in the system Shortcuts app, where the user
/// confirms each step. The view never claims that Daybreak installed a
/// shortcut or changed the system wallpaper.
struct ShortcutsGuideView: View {
    /// Occurrence-aware text from the host screen, or nil when there is no
    /// selected image. Without it the one-click run link is disabled.
    let selectedWallpaperReference: DaybreakWallpaperReference?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage(DaybreakShortcutGuideStorage.applyConfigured) private var applyConfigured = false
    @AppStorage(DaybreakShortcutGuideStorage.dailyConfigured) private var dailyConfigured = false
    @AppStorage(DaybreakShortcutGuideStorage.lastHandoffDate) private var lastHandoffDate = 0.0
    @AppStorage(DaybreakShortcutGuideStorage.lastHandoffShortcut) private var lastHandoffShortcut = ""
    @AppStorage(DaybreakShortcutGuideStorage.lastHandoffWallpaperID) private var lastHandoffWallpaperID = ""

    @State private var didCopyID = false
    @State private var urlError: String?
    @State private var fetchedWallpaperReference: DaybreakWallpaperReference?
    @State private var isLoadingSelection = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequestingNotificationAuthorization = false
    @State private var notificationPermissionMessage: String?

    private var effectiveWallpaperReference: DaybreakWallpaperReference? {
        selectedWallpaperReference ?? fetchedWallpaperReference
    }

    private var effectiveWallpaperID: String? {
        effectiveWallpaperReference?.wallpaperID.description
    }

    init(selectedWallpaperReference: DaybreakWallpaperReference? = nil) {
        self.selectedWallpaperReference = selectedWallpaperReference
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            notificationCard
            if let urlError {
                Text(urlError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            applyCard
            dailyCard
        }
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityElement(children: .contain)
        .task(id: selectedWallpaperReference) {
            guard selectedWallpaperReference == nil else { return }
            isLoadingSelection = true
            defer { isLoadingSelection = false }
            guard let selection = await MobileIntentService.shared.currentSelectionIdentity() else {
                return
            }
            fetchedWallpaperReference = DaybreakWallpaperReference(
                wallpaperID: selection.wallpaperID,
                occurrenceKey: selection.occurrenceKey
            )
        }
        .task {
            await refreshNotificationAuthorization()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationAuthorization() }
        }
    }

    // MARK: Notification permission

    private var notificationCard: some View {
        card(title: "壁纸通知", systemImage: "bell.badge") {
            VStack(alignment: .leading, spacing: 10) {
                Text("允许 Daybreak 通知后，快捷指令可在设置壁纸后显示图片缩略图和来源信息。通知不代表壁纸已更换。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch notificationAuthorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    Label("通知已开启。快捷指令可以发送壁纸通知。", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .denied:
                    Text("通知权限已关闭。请在系统设置中允许 Daybreak 通知。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("打开系统通知设置", systemImage: "gear") {
                        openNotificationSettings()
                    }
                    .buttonStyle(.bordered)
                case .notDetermined:
                    Button {
                        requestNotificationAuthorization()
                    } label: {
                        if isRequestingNotificationAuthorization {
                            ProgressView("正在请求通知权限…")
                        } else {
                            Label("允许通知", systemImage: "bell.badge")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequestingNotificationAuthorization)
                @unknown default:
                    Text("无法读取通知权限。请在系统设置中查看 Daybreak 的通知选项。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let notificationPermissionMessage {
                    Text(notificationPermissionMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var notificationActionStep: LocalizedStringKey {
        "在系统“设置墙纸照片”之后添加“发送 Daybreak 壁纸通知”动作，并将“壁纸图片”设为同一个 Daybreak 获取壁纸动作返回的图片（不要连接系统墙纸动作的结果）。通知使用这张图片的缩略图、来源标题、地区、版权和可用知识点；快捷指令无法确认系统墙纸是否更改。"
    }

    private func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
    }

    private func requestNotificationAuthorization() {
        isRequestingNotificationAuthorization = true
        notificationPermissionMessage = nil
        Task {
            defer { isRequestingNotificationAuthorization = false }
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                await refreshNotificationAuthorization()
            } catch {
                notificationPermissionMessage = MobileLocalizedString.resolve(
                    "通知权限请求失败。请稍后重试。",
                    locale: DaybreakShortcutLocale.current
                )
            }
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            notificationPermissionMessage = MobileLocalizedString.resolve(
                "无法打开系统设置。请手动在“设置”中查找 Daybreak 的通知选项。",
                locale: DaybreakShortcutLocale.current
            )
            return
        }
        openURL(url) { accepted in
            if !accepted {
                notificationPermissionMessage = MobileLocalizedString.resolve(
                    "无法打开系统设置。请手动在“设置”中查找 Daybreak 的通知选项。",
                    locale: DaybreakShortcutLocale.current
                )
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("用 Apple 快捷指令设置壁纸", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Daybreak 会将所选图片交给快捷指令。请按系统提示预览并设置；Daybreak 无法确认壁纸是否已更换。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Apply shortcut

    private var applyCard: some View {
        card(title: "Daybreak Apply：设置所选壁纸", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 12) {
                installButton(
                    title: "从 iCloud 添加 Daybreak Apply",
                    url: DaybreakShortcutShareLink.apply
                )
                installNote

                manualApply

                Toggle("我已添加 Daybreak Apply", isOn: $applyConfigured)
                    .accessibilityHint("此选项仅用于启用运行按钮；请确认已添加名称为 Daybreak Apply 的快捷指令。")

                Divider()

                currentSelection

                Button {
                    runShortcut(
                        name: DaybreakShortcutName.apply,
                        input: effectiveWallpaperReference?.text
                    )
                } label: {
                    Label("运行 Daybreak Apply", systemImage: "photo.badge.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!applyConfigured || effectiveWallpaperReference == nil)
                .accessibilityHint("打开 Daybreak Apply 并传入所选图片、地区和日期。请按系统提示预览并设置壁纸。")
                if !applyConfigured {
                    Text("先添加并确认 Daybreak Apply，运行按钮才会启用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                lastHandoffStatus

                Text("运行后会打开系统快捷指令并传入所选图片。请按系统提示预览并设置壁纸。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manualApply: some View {
        DisclosureGroup("或手动创建") {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "打开“快捷指令”App，新建一个快捷指令，名称必须是 Daybreak Apply。名称不一致时，Daybreak 无法通过系统 URL 运行它。")
                step(2, "在快捷指令的详细信息中开启接收文本输入（快捷操作或分享表单），否则“快捷指令输入”可能为空。")
                step(3, "添加“按图片引用获取 Daybreak 壁纸”动作，把“壁纸引用”设为“快捷指令输入”，并在“输出”中选择原图或目标屏幕比例。")
                step(4, "添加系统“设置墙纸照片”动作，把上一步返回的图片交给它，并在系统预览中确认。")
                step(5, notificationActionStep)
                step(6, "回到这里打开“我已添加 Daybreak Apply”。这只是解锁运行按钮，不代表 Daybreak 检测到了快捷指令。")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        shortcutAppButton
                        copyIDButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        shortcutAppButton
                        copyIDButton
                    }
                }
                .font(.callout)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var currentSelection: some View {
        if let effectiveWallpaperID {
            Text("已选择图片，可在快捷指令中继续。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            DisclosureGroup("技术详情") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前壁纸 ID：\(effectiveWallpaperID)")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Text("从“今日”或“时光”页运行时，Daybreak 会传入图片 ID、地区和来源日期，并按这条具体出现记录解析元数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        } else if isLoadingSelection {
            ProgressView("正在读取当前选择…")
                .font(.footnote)
        } else {
            Text("还没有当前选中的壁纸。请先在“今日”或“时光”页选择一张图片。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutAppButton: some View {
        Button {
            openShortcuts()
        } label: {
            Label("打开快捷指令", systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.bordered)
        .tint(.daybreakActionTint)
    }

    @ViewBuilder
    private var copyIDButton: some View {
        if let reference = effectiveWallpaperReference {
            Button {
                UIPasteboard.general.string = reference.text
                didCopyID = true
            } label: {
                Label(
                    didCopyID ? LocalizedStringKey("已复制快捷指令输入") : LocalizedStringKey("复制快捷指令输入"),
                    systemImage: didCopyID ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
            .accessibilityHint("复制 \(reference.text)，用于“按图片引用获取 Daybreak 壁纸”动作或测试。")
        }
    }

    // MARK: Daily automation

    private var dailyCard: some View {
        card(title: "Daybreak Daily：每日自动更换", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                installButton(
                    title: "从 iCloud 添加 Daybreak Daily",
                    url: DaybreakShortcutShareLink.daily
                )
                installNote

                Text("获取当天壁纸。要每天运行，请在“快捷指令”的“自动化”中创建个人自动化。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("我已添加 Daybreak Daily", isOn: $dailyConfigured)
                    .accessibilityHint("此选项仅用于启用测试运行；请先添加 Daybreak Daily 并创建个人自动化。")

                Button {
                    runShortcut(
                        name: DaybreakShortcutName.daily,
                        input: nil
                    )
                } label: {
                    Label("测试运行 Daybreak Daily", systemImage: "play")
                }
                .buttonStyle(.bordered)
                .tint(.daybreakActionTint)
                .disabled(!dailyConfigured)
                .accessibilityHint("只测试一次运行；每日自动化仍需在“快捷指令”中单独设置。")

                manualDaily

                Text("每日更换由系统自动化触发，可能需要确认；实际运行时间由系统决定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manualDaily: some View {
        DisclosureGroup("或手动创建") {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "新建名为 Daybreak Daily 的快捷指令，添加“获取今日 Daybreak 壁纸”动作，并在“输出”中按目标设备选择：普通 iPhone 竖屏选锁屏或主屏幕（9:19.5），iPad 横屏选 iPad 横屏（近似 4:3），Duo 按目标屏幕选对应预设；不确定时选原图。")
                step(2, "添加系统“设置墙纸照片”动作，把获取壁纸动作返回的图片交给它，并在系统预览中确认。")
                step(3, notificationActionStep)
                step(4, "打开“快捷指令”的“自动化”，新建“时间”自动化，每天选择时间，运行 Daybreak Daily。")
                step(5, "如果系统提供“运行前询问”，可尝试关闭；部分 iOS 版本仍会要求确认，自动化不保证准点执行。")
                step(6, "Bing 可能尚未发布当天图片。建议把时间设在早晨，失败时快捷指令会显示“今天尚未缓存”，不会用旧图冒充。")
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    // MARK: Status

    @ViewBuilder
    private var lastHandoffStatus: some View {
        if lastHandoffDate > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("上次从 Daybreak 交给快捷指令：")
                Text(Date(timeIntervalSince1970: lastHandoffDate), format: .dateTime.year().month().day().hour().minute())
                if !lastHandoffShortcut.isEmpty {
                    Text("快捷指令：\(lastHandoffShortcut)")
                }
                if !lastHandoffWallpaperID.isEmpty {
                    Text("快捷指令输入：\(lastHandoffWallpaperID)")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func openShareLink(_ url: URL) {
        urlError = nil
        openURL(url) { accepted in
            guard !accepted else { return }
            urlError = MobileLocalizedString.resolve(
                "无法打开 iCloud 快捷指令页面。请检查网络连接后重试。",
                locale: DaybreakShortcutLocale.current
            )
        }
    }

    private func openShortcuts() {
        urlError = nil
        guard let url = DaybreakShortcutURL.openShortcutsApp else {
            urlError = MobileLocalizedString.resolve("无法构造快捷指令链接。", locale: DaybreakShortcutLocale.current)
            return
        }
        openURL(url) { accepted in
            if !accepted {
                urlError = MobileLocalizedString.resolve("无法打开快捷指令。请确认系统已安装“快捷指令”App。", locale: DaybreakShortcutLocale.current)
            }
        }
    }

    private func runShortcut(name: String, input: String?) {
        urlError = nil
        guard let url = DaybreakShortcutURL.runShortcutURL(name: name, textInput: input) else {
            urlError = MobileLocalizedString.resolve("无法构造运行快捷指令的链接。", locale: DaybreakShortcutLocale.current)
            return
        }
        openURL(url) { accepted in
            guard accepted else {
                urlError = MobileLocalizedString.resolve("无法运行快捷指令。请确认名称完全一致，并且已安装“快捷指令”App。", locale: DaybreakShortcutLocale.current)
                return
            }
            DaybreakShortcutGuideStorage.recordHandoff(name: name, wallpaperID: input)
            lastHandoffDate = Date().timeIntervalSince1970
            lastHandoffShortcut = name
            lastHandoffWallpaperID = input ?? ""
        }
    }

    // MARK: Building blocks

    private func installButton(title: LocalizedStringKey, url: URL) -> some View {
        Button {
            openShareLink(url)
        } label: {
            Label(title, systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
    }

    private var installNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("打开 iCloud 页面后，点“获取快捷指令”，再按系统提示添加。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("如果页面打不开或缺少通知动作，请使用下方的手动步骤。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("第 \(number) 步"))
        .accessibilityValue(Text(text))
    }
}
