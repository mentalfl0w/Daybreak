import SwiftUI
import UIKit

/// Setup and daily-automation guide for the supported Shortcuts wallpaper flow.
///
/// The view is deliberately presentational. It opens the public iCloud share
/// pages and the documented `shortcuts://` run URLs, but adding a shortcut and
/// creating an automation happen in the system Shortcuts app, where the user
/// confirms each step. The view never claims that Daybreak installed a
/// shortcut or changed the system wallpaper.
struct ShortcutsGuideView: View {
    /// Canonical `source:sourceImageID` text, or nil when the host screen has
    /// no selected image. Without it the one-click run link is disabled.
    let selectedWallpaperID: String?

    @Environment(\.openURL) private var openURL
    @AppStorage(DaybreakShortcutGuideStorage.applyConfigured) private var applyConfigured = false
    @AppStorage(DaybreakShortcutGuideStorage.dailyConfigured) private var dailyConfigured = false
    @AppStorage(DaybreakShortcutGuideStorage.lastHandoffDate) private var lastHandoffDate = 0.0
    @AppStorage(DaybreakShortcutGuideStorage.lastHandoffShortcut) private var lastHandoffShortcut = ""
    @AppStorage(DaybreakShortcutGuideStorage.lastHandoffWallpaperID) private var lastHandoffWallpaperID = ""

    @State private var didCopyID = false
    @State private var urlError: String?
    @State private var fetchedWallpaperID: String?
    @State private var isLoadingSelection = false

    private var effectiveWallpaperID: String? {
        selectedWallpaperID ?? fetchedWallpaperID
    }

    init(selectedWallpaperID: String? = nil) {
        self.selectedWallpaperID = selectedWallpaperID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
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
        .task(id: selectedWallpaperID) {
            guard selectedWallpaperID == nil else { return }
            isLoadingSelection = true
            defer { isLoadingSelection = false }
            guard let wallpaperID = await MobileIntentService.shared.currentSelectionWallpaperID() else {
                return
            }
            fetchedWallpaperID = wallpaperID.description
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("用 Apple 快捷指令设置壁纸", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Daybreak 只负责把已缓存的真实图片交给系统快捷指令。真正修改壁纸的动作由系统“设置墙纸照片”完成，Daybreak 不会声称已经设置成功。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Apply shortcut

    private var applyCard: some View {
        card(title: "Daybreak Apply：设置当前壁纸", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 12) {
                installButton(
                    title: "从 iCloud 添加 Daybreak Apply",
                    url: DaybreakShortcutShareLink.apply
                )
                installNote

                manualApply

                Toggle("我已添加 Daybreak Apply", isOn: $applyConfigured)
                    .accessibilityHint("仅表示你已添加同名快捷指令。Daybreak 无法验证其内容或设置结果。")

                Divider()

                currentSelection

                Button {
                    runShortcut(
                        name: DaybreakShortcutName.apply,
                        input: effectiveWallpaperID
                    )
                } label: {
                    Label("运行 Daybreak Apply", systemImage: "photo.badge.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!applyConfigured || effectiveWallpaperID == nil)
                .accessibilityHint("打开系统的 Daybreak Apply 快捷指令，并把当前壁纸 ID 作为文本输入传入。系统会显示实际结果。")

                if !applyConfigured {
                    Text("先添加并确认 Daybreak Apply，运行按钮才会启用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                lastHandoffStatus

                Text("这个按钮只把图片 ID 交给快捷指令。是否成功、是否需要确认，都由系统快捷指令显示；Daybreak 不会读取系统壁纸，也不会把“已打开”当成“已设置”。")
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
                step(3, "添加“按 ID 获取 Daybreak 壁纸”动作，把“壁纸 ID”设为“快捷指令输入”，并在“输出”中选择原图或目标屏幕比例。")
                step(4, "添加系统“设置墙纸照片”动作（不同系统版本的名称可能略有不同），把上一步返回的图片交给它，并在系统预览中确认。")
                step(5, "回到这里打开“我已添加 Daybreak Apply”。这只是解锁运行按钮，不代表 Daybreak 检测到了快捷指令。")

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
            Text("当前壁纸 ID：\(effectiveWallpaperID)")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
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
        if let effectiveWallpaperID {
            Button {
                UIPasteboard.general.string = effectiveWallpaperID
                didCopyID = true
            } label: {
                Label(
                    didCopyID ? LocalizedStringKey("已复制壁纸 ID") : LocalizedStringKey("复制壁纸 ID"),
                    systemImage: didCopyID ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
            .accessibilityHint("复制 \(effectiveWallpaperID)，用于“按 ID 获取 Daybreak 壁纸”动作或测试。")
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

                Text("每天获取当天壁纸。每日运行需要你在“快捷指令”的“自动化”中创建个人自动化。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("我已添加 Daybreak Daily", isOn: $dailyConfigured)
                    .accessibilityHint("仅表示你已添加该快捷指令并创建自动化，Daybreak 无法验证系统自动化是否启用。")

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
                .accessibilityHint("只测试快捷指令本身；不会证明每日自动化已启用或会在准点运行。")

                manualDaily

                Text("Daybreak 没有后台准点触发器。后台刷新只是更新缓存的机会；真正的每日更换依赖你在系统中创建的自动化及其权限。")
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
                step(2, "添加系统“设置墙纸照片”动作（名称可能因系统版本略有不同），并在预览中确认。")
                step(3, "打开“快捷指令”的“自动化”，新建“时间”自动化，每天选择时间，运行 Daybreak Daily。")
                step(4, "如果系统提供“运行前询问”，可尝试关闭；部分 iOS 版本仍会要求确认，自动化不保证准点执行。")
                step(5, "Bing 可能尚未发布当天图片。建议把时间设在早晨，失败时快捷指令会显示“今天尚未缓存”，不会用旧图冒充。")
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
                    Text("壁纸 ID：\(lastHandoffWallpaperID)")
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
        Text("按钮只打开 iCloud 上的快捷指令页面。请在页面点“获取快捷指令”，再在系统确认框中添加；Daybreak 无法检测你是否已添加。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
