import AppKit
import SwiftUI

/// Compact menu bar panel for today's wallpaper.
///
/// The write confirmation sheet lives in `TodayView`. This panel therefore
/// never starts a wallpaper write by itself: the parent supplies `onApply`,
/// which must navigate to the Today window before calling
/// `AppModel.beginApplyWallpaper()`.
struct MenuBarPanel: View {
    let model: AppModel
    /// Parent switches navigation to `.today`, opens the window, then calls
    /// `model.beginApplyWallpaper()`. The consent sheet lives in `TodayView`,
    /// so a write must never start before this navigation.
    let onApply: () -> Void
    /// Opens the existing window without starting any write.
    let onOpen: () -> Void

    let onSettings: () -> Void
    @Environment(\.locale) private var locale

    /// Starts at a typical panel height so the menu bar window has a stable
    /// size on its first layout pass; the measured content height replaces it
    /// immediately after.
    @State private var contentHeight: CGFloat = 520
    /// Pending overwrite confirmed directly from the menu bar. This alert is
    /// attached to the panel itself and never depends on the main window.
    @State private var overwriteCandidate: WallpaperGuardInfo?

    private static let panelWidth: CGFloat = 380
    private static let maximumVisibleHeight: CGFloat = 640

    var body: some View {
        ScrollView(.vertical) {
            panelContent
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MenuBarPanelContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.panelWidth)
        .frame(height: visibleHeight)
        .onPreferenceChange(MenuBarPanelContentHeightKey.self) { height in
            guard height > 0, abs(height - contentHeight) > 0.5 else { return }
            contentHeight = height
        }
        .task { model.start() }
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
                "\(block.displayName)\n\n当前壁纸：\(block.observedImageURL?.lastPathComponent ?? MacLocalizedString.resolve("无法读取", locale: WallpaperInterfaceLocale.current))\n将替换为：\(block.desiredImageURL?.lastPathComponent ?? MacLocalizedString.resolve("目标壁纸", locale: WallpaperInterfaceLocale.current))\n\n仅修改当前可访问的桌面；如果当前壁纸已经变化，写入会被拒绝。"
            )
        }
    }

    private var overwriteAlertBinding: Binding<Bool> {
        Binding(
            get: { overwriteCandidate != nil },
            set: { presented in
                if !presented { overwriteCandidate = nil }
            }
        )
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            storyLine
            statusSection

            if let wallpaperError = model.wallpaperError,
               !wallpaperError.isEmpty {
                issueBanner(wallpaperError)
            }

            quickActions

            Text("设置壁纸前只确认一次目标显示器与目标图片；只修改当前可访问的桌面。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The panel grows with its content up to a height that fits below the
    /// menu bar on small displays. Beyond that the panel scrolls rather than
    /// clipping the lower controls.
    private var visibleHeight: CGFloat {
        min(max(contentHeight, 1), Self.maximumVisibleHeight)
    }

    // MARK: Hero

    private var hero: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background { heroPhoto }
            .overlay {
                if model.heroImage == nil {
                    heroPlaceholder
                }
            }
            .overlay(alignment: .bottomLeading) {
                if model.heroImage != nil {
                    heroCaption
                }
            }
            .clipShape(heroShape)
            .overlay {
                heroShape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                statusBadge
                    .padding(10)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(heroAccessibilityLabel)
    }

    private var heroShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    /// The photo gets its own fixed geometry as a background layer. A
    /// fill-scaled image reports a layout size taller than the 150 pt card;
    /// leaving it in the hero's stack previously enlarged that stack and
    /// pushed the bottom-aligned title and subtitle outside the clipped card.
    private var heroPhoto: some View {
        GeometryReader { proxy in
            ZStack {
                heroShape
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))

                if let image = model.heroImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.18), location: 0.5),
                            .init(color: .black.opacity(0.8), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private var heroPlaceholder: some View {
        if isLoadingContent {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在载入今日图片…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 5) {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(heroTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var heroCaption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heroTitle)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .padding(14)
    }

    private var statusBadge: some View {
        MenuBarStatusBadge(title: model.statusTitle, color: statusColor)
    }

    private var statusColor: Color {
        switch model.loadState {
        case .ready, .refreshing: return .green
        case .offline: return .orange
        case .failed: return .red
        case .empty, .idle, .loadingCache: return .secondary
        }
    }

    private var heroTitle: String {
        model.payload?.title ?? MacLocalizedString.resolve("今日内容尚未载入", locale: WallpaperInterfaceLocale.current)
    }

    private var heroAccessibilityLabel: String {
        guard let payload = model.payload else {
            return MacLocalizedString.resolve("今日图片尚未载入，状态：\(model.statusTitle)", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("今日图片：\(payload.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))，来源日期 \(payload.sourceDate.iso8601)，状态：\(model.statusTitle)", locale: WallpaperInterfaceLocale.current)
    }

    private var isLoadingContent: Bool {
        switch model.loadState {
        case .idle, .loadingCache, .refreshing:
            return true
        case .empty, .ready, .offline, .failed:
            return false
        }
    }

    private var subtitle: String {
        var parts = [model.marketChoice.displayName(in: locale)]
        if let payload = model.payload {
            parts.append(payload.sourceDate.iso8601)
            if !payload.isSourceDateToday {
                parts.append(MacLocalizedString.resolve("非今日来源", locale: locale))
            }
        } else {
            parts.append(model.statusTitle)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Story

    private var storyLine: some View {
        let text = MenuBarStoryText.line(for: model.storyPanel ?? .notFetched)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityHidden(true)

            Text(text)
                .font(.callout)
                .lineSpacing(1)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .modifier(MenuBarInsetCardStyle(padding: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("每日介绍：\(text)")
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: automationInfo.systemImage)
                    .font(.callout)
                    .foregroundStyle(automationInfo.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(automationInfo.label)
                        .font(.caption.weight(.semibold))
                    Text(automationDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.isUpdatingAutomation
                    || model.isPreparingConsent
                    || model.isApplyingWallpaper {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("正在更新壁纸设置")
                }
            }

            if let status = model.wallpaperStatusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }


            if model.requiresDisableRetry {
                Button("重试关闭自动同步") {
                    model.setAutoSync(false)
                }
                .controlSize(.small)
                .disabled(model.isUpdatingAutomation)
            }

            if !model.guardBlocks.isEmpty {
                Divider()
                    .opacity(0.6)
            }

            if !model.guardBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Text("\(model.guardBlocks.count) 台显示器等待确认")
                        Spacer(minLength: 8)
                    }
                    .font(.caption2)

                    ForEach(model.guardBlocks) { block in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(block.displayName)
                                    .font(.caption2.weight(.medium))
                                Text(block.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 6)
                            if block.canConfirm {
                                Button("确认覆盖…") {
                                    overwriteCandidate = block
                                }
                                .controlSize(.small)
                                .disabled(model.isApplyingWallpaper)
                                .accessibilityLabel("确认覆盖 \(block.displayName) 的当前壁纸")
                            } else {
                                Text("无法读取当前壁纸，暂不能确认")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.caption2)
            }

            if model.pendingWallpaperConfirmation != nil {
                HStack(spacing: 6) {
                    Text("壁纸操作等待确认")
                    Spacer(minLength: 8)
                    Button("打开今日窗口", action: openTodayWindow)
                        .controlSize(.small)
                    Button("取消") {
                        model.cancelPendingWallpaperConfirmation()
                    }
                    .controlSize(.small)
                }
                .font(.caption2)
            }
        }
        .modifier(MenuBarInsetCardStyle(padding: 12))
    }

    private var automationInfo: (label: String, systemImage: String, color: Color) {
        if model.isUpdatingAutomation || model.isPreparingConsent || model.isApplyingWallpaper {
            return (MacLocalizedString.resolve("正在准备壁纸写入", locale: WallpaperInterfaceLocale.current), "hourglass", .secondary)
        }
        if model.requiresDisableRetry {
            return (MacLocalizedString.resolve("自动写入可能仍在启用", locale: WallpaperInterfaceLocale.current), "exclamationmark.triangle.fill", .orange)
        }
        if model.autoSyncEnabled {
            return (MacLocalizedString.resolve("自动同步已开启", locale: WallpaperInterfaceLocale.current), "checkmark.circle.fill", .green)
        }
        return (MacLocalizedString.resolve("自动同步未开启", locale: WallpaperInterfaceLocale.current), "pause.circle", .secondary)
    }

    private var automationDetail: String {
        if model.requiresDisableRetry {
            return MacLocalizedString.resolve("本次会话已停止自动写入，但保存的设置可能仍为自动同步；重新启动后可能恢复。", locale: WallpaperInterfaceLocale.current)
        }
        if model.autoSyncEnabled {
            return model.autoOverwriteEnabled
                ? MacLocalizedString.resolve("自动同步已开启，并会替换未知的当前壁纸；手动保护仍会暂停。未激活的 Space 不会立即更新。", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("自动同步已开启；遇到未知壁纸会暂停并等待逐台确认。重新启动后继续。", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("自动同步未开启；不会自动修改壁纸。重新启动后保持关闭。", locale: WallpaperInterfaceLocale.current)
    }

    private func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("设置") {
                openSettingsPanel()
            }
            .controlSize(.small)
        }
        .modifier(MenuBarInsetCardStyle(padding: 10, accent: .orange))
    }

    // MARK: Actions

    @ViewBuilder
    private var quickActions: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                quickActionButtons
            }
        } else {
            quickActionButtons
        }
    }

    private var quickActionButtons: some View {
        HStack(spacing: 6) {
            Button(action: applyWallpaper) {
                HStack(spacing: 6) {
                    if model.isPreparingConsent || model.isApplyingWallpaper {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Text("设为壁纸")
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 100)
            .modifier(MenuBarPrimaryActionStyle())
            .disabled(
                !model.canApplyWallpaper
                    || model.isPreparingConsent
                    || model.displays.isEmpty
                    || model.pendingWallpaperConfirmation != nil
            )
            .help(applyHelp)

            Button {
                openSettingsPanel()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .lineLimit(1)
            }
            .frame(width: 72)
            .modifier(MenuBarSecondaryActionStyle())
            .help("打开 Daybreak 设置")

            Button(action: openTodayWindow) {
                Label("主窗口", systemImage: "macwindow")
                    .lineLimit(1)
            }
            .frame(width: 88)
            .modifier(MenuBarSecondaryActionStyle())
            .help("打开 Daybreak 主窗口")

            // Hiding the Dock icon also hides the app menu bar, so the only
            // guaranteed quit affordance sits on the action row. Command-Q
            // still works while the panel is open.
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .lineLimit(1)
            }
            .frame(width: 72)
            .modifier(MenuBarSecondaryActionStyle())
            .keyboardShortcut("q", modifiers: .command)
            .help("退出 Daybreak；隐藏 Dock 图标后应用菜单栏不可见")
        }
    }

    private var applyHelp: String {
        if model.payload == nil { return MacLocalizedString.resolve("先载入今日内容", locale: WallpaperInterfaceLocale.current) }
        if model.displays.isEmpty { return MacLocalizedString.resolve("未检测到已连接的显示器", locale: WallpaperInterfaceLocale.current) }
        if model.pendingWallpaperConfirmation != nil { return MacLocalizedString.resolve("已有等待确认的写入", locale: WallpaperInterfaceLocale.current) }
        if model.isDownloadingOriginal { return MacLocalizedString.resolve("正在下载原图", locale: WallpaperInterfaceLocale.current) }
        return MacLocalizedString.resolve("打开今日窗口并确认一次后应用", locale: WallpaperInterfaceLocale.current)
    }

    private func applyWallpaper() {
        NSApp.activate()
        onApply()
    }

    private func openTodayWindow() {
        NSApp.activate()
        onOpen()
    }

    private func openSettingsPanel() {
        NSApp.activate()
        onSettings()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(model.marketChoice.displayName(in: locale))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(model.sourceOriginLabel)
            Spacer(minLength: 8)
            if let lastUpdated = model.lastUpdated {
                Text("更新于 \(StatusFormatter.dateTime(lastUpdated, locale: locale))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}

/// Measures the panel's intrinsic content height so the menu bar window can
/// grow with its content up to the cap and scroll beyond it instead of
/// clipping the lower controls.
private struct MenuBarPanelContentHeightKey: SwiftUI.PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Story preview

/// The panel shows source-provided text verbatim, truncated at a sentence
/// boundary. It never invents copy when a story or headline is unavailable.
enum MenuBarStoryText {
    static func line(for panel: StoryPanel) -> String {
        switch panel {
        case .available(let story):
            // Only the quick fact and description carry introduction prose.
            // Headlines and titles are headings (the hero already shows the
            // image title), and copyright is metadata, so none of them may
            // stand in for the introduction. If the source only returned
            // headings, fall through to the existing "no readable
            // introduction" state.
            for candidate in [story.quickFact, story.body] {
                if let text = candidate, let sentence = firstSentence(in: text) {
                    return sentence
                }
            }
            return MacLocalizedString.resolve("来源未返回可读的介绍正文。", locale: WallpaperInterfaceLocale.current)
        case .unavailable(_, _, let headline, _, _):
            if let headline, let sentence = firstSentence(in: headline) {
                return sentence
            }
            return MacLocalizedString.resolve("该地区暂无可用介绍。", locale: WallpaperInterfaceLocale.current)
        case .unmatched(let hasCandidates):
            return hasCandidates
                ? MacLocalizedString.resolve("无法确认这段介绍属于这张图片，已隐藏。", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("尚未取得当日介绍。", locale: WallpaperInterfaceLocale.current)
        case .notFetched:
            return MacLocalizedString.resolve("尚未获取当日介绍。", locale: WallpaperInterfaceLocale.current)
        }
    }

    static func firstSentence(in text: String, limit: Int = 110) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        var end = collapsed.endIndex
        for terminator in ["。", "！", "？"] {
            if let index = collapsed.firstIndex(of: Character(terminator)) {
                end = min(end, collapsed.index(after: index))
            }
        }
        for token in [". ", "! ", "? ", "; "] {
            if let range = collapsed.range(of: token) {
                end = min(end, range.upperBound)
            }
        }

        var sentence = String(collapsed[..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence.isEmpty {
            sentence = collapsed
        }
        if sentence.count > limit {
            sentence = String(sentence.prefix(limit))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return sentence
    }
}

// MARK: - Panel surfaces

/// Inset card layered on the menu bar window material. Using a light
/// semantic tint instead of another material avoids stacking translucent
/// surfaces while still grouping the story and automation status.
private struct MenuBarInsetCardStyle: ViewModifier {
    var padding: CGFloat = 12
    var accent: Color? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color.primary.opacity(0.045))
                if let accent {
                    shape.fill(accent.opacity(0.10))
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    accent?.opacity(0.24) ?? Color.primary.opacity(0.06),
                    lineWidth: 1
                )
            }
    }
}

/// Status capsule over the photograph. macOS 26 uses native Liquid Glass with
/// a dark tint for legibility; older systems and Reduce Transparency use the
/// previous solid dark capsule.
private struct MenuBarStatusBadge: View {
    let title: String
    let color: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            label
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.black.opacity(0.30)), in: Capsule())
        } else {
            label
                .foregroundStyle(.white)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("状态：\(title)")
    }
}

// MARK: - Liquid Glass button styles

/// macOS 26 gets native Liquid Glass controls. Older systems use the standard
/// system button materials, which the menu bar window already supplies.
private struct MenuBarPrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct MenuBarSecondaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
