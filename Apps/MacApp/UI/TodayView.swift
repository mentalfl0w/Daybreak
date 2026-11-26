import AppKit
import DaybreakCore
import SwiftUI

/// Today is a photo-first screen: the source photograph is the primary
/// surface and is never covered by a wall of panels. The photograph's own
/// footer is the "today's source" strip that also hosts the wallpaper
/// controls, while update and cache details expand from the floating badge.
/// The daily story remains one full-width row. Liquid Glass is reserved for
/// small floating controls on macOS 26; older systems fall back to standard
/// system materials and button styles.
struct TodayView: View {
    let model: AppModel
    /// Owned by `AppShell` so the window toolbar backdrop can follow the real
    /// scroll offset of this page. True only when content has moved past its
    /// resting top edge; pointer hover never changes it.
    @Binding var isTopScrollOverlap: Bool
    @State private var overwriteCandidate: WallpaperGuardInfo?
    @State private var isShowingStatusDetails = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            bannerArea

            Group {
                if let payload = model.payload {
                    photoFirstContent(payload)
                } else if isLoadingWithoutContent {
                    loadingState
                } else {
                    emptyState
                }
            }
        }
        .navigationTitle("今日")
        .navigationSubtitle(Text(subtitle))
        .toolbar { toolbarContent }
        .task { model.start() }
        .onChange(of: model.payload?.key) { _, _ in
            isShowingStatusDetails = false
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

    private var overwriteAlertBinding: Binding<Bool> {
        Binding(
            get: { overwriteCandidate != nil },
            set: { newValue in
                if !newValue { overwriteCandidate = nil }
            }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refreshNow()
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在刷新")
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshing)
            .help("重新获取当前地区的今日图片与介绍（⌘R）")
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

    // MARK: Banner area

    @ViewBuilder
    private var bannerArea: some View {
        if model.errorBanner != nil
            || (model.wallpaperError?.isEmpty == false) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.errorBanner {
                    errorBanner(error)
                }
                if let wallpaperError = model.wallpaperError,
                   !wallpaperError.isEmpty {
                    wallpaperAutomationBanner(wallpaperError)
                }
            }
            .frame(maxWidth: 1480, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Content

    private func photoFirstContent(_ payload: TodayPayload) -> some View {
        GeometryReader { geometry in
            let contentWidth = min(max(geometry.size.width - 48, 0), 1480)
            let naturalPhotoHeight = contentWidth * 9.0 / 16.0
            let heightLimit = max(
                TodayMetrics.minimumPhotoHeight,
                geometry.size.height - TodayMetrics.floatingNavigationClearance
            )
            let photoHeight = max(
                TodayMetrics.minimumPhotoHeight,
                min(naturalPhotoHeight, heightLimit)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroSection(for: payload, photoHeight: photoHeight)

                    if !model.guardBlocks.isEmpty {
                        guardBlocksCard
                    }

                    storySection
                        .modifier(TodayCardStyle())

                    if !model.warnings.isEmpty {
                        warningsSection
                            .modifier(TodayCardStyle(tone: .warning))
                    }
                }
                .frame(maxWidth: 1480, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background {
                    if #unavailable(macOS 15.0) {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TodayLegacyScrollOffset.self,
                                value: proxy.frame(in: .named("today-scroll")).minY
                            )
                        }
                    }
                }
            }
            .coordinateSpace(name: "today-scroll")
            .modifier(TodayScrollOverlapReporter(isOverlapping: $isTopScrollOverlap))
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func heroSection(for payload: TodayPayload, photoHeight: CGFloat) -> some View {
        if let image = model.heroImage {
            photoCard(image: image, payload: payload, photoHeight: photoHeight)
        } else {
            photoPlaceholderCard(for: payload, photoHeight: photoHeight)
        }
    }

    private func photoCard(image: NSImage, payload: TodayPayload, photoHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            photoStage(image: image, payload: payload, height: photoHeight)
            photoFooter(for: payload)
        }
        .background { photoShape.fill(Color(nsColor: .controlBackgroundColor)) }
        .clipShape(photoShape)
        .overlay {
            photoShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 10)
    }

    private func photoPlaceholderCard(for payload: TodayPayload, photoHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            placeholderStage(for: payload, height: photoHeight)
            placeholderTitleBlock(for: payload)
            photoFooter(for: payload)
        }
        .background { photoShape.fill(Color(nsColor: .controlBackgroundColor)) }
        .clipShape(photoShape)
        .overlay {
            photoShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 8)
    }

    private var photoShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TodayMetrics.photoRadius, style: .continuous)
    }

    private func photoStage(image: NSImage, payload: TodayPayload, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: height)
                        .clipped()

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.16), location: 0.48),
                            .init(color: .black.opacity(0.84), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 230)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(payload.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        Text(payload.copyright ?? MacLocalizedString.resolve("版权信息不可用", locale: WallpaperInterfaceLocale.current))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    }
                    .padding(22)
                    .frame(maxWidth: 660, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: height)
                .clipped()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "今日图片，\(payload.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))，\(payload.copyright ?? MacLocalizedString.resolve("版权信息不可用", locale: WallpaperInterfaceLocale.current))，来源日期 \(payload.sourceDate.iso8601)，\(model.originalImage != nil ? MacLocalizedString.resolve("原图", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("预览图", locale: WallpaperInterfaceLocale.current))"
            )
            .overlay(alignment: .topTrailing) {
                statusBadge(for: payload)
                    .padding(14)
            }
    }

    private func placeholderStage(for payload: TodayPayload, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                VStack(spacing: 8) {
                    placeholderContent
                }
                .multilineTextAlignment(.center)
                .padding(24)
            }
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.10))
            .accessibilityElement(children: .combine)
            .overlay(alignment: .topTrailing) {
                statusBadge(for: payload)
                    .padding(14)
            }
    }

    @ViewBuilder
    private var placeholderContent: some View {
        if model.isRefreshing || model.isDownloadingOriginal {
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel("正在载入图片")
            Text("正在载入图片…")
                .font(.callout.weight(.medium))
            Text("图片缓存就绪后在这里显示")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("图片未缓存")
                .font(.callout.weight(.medium))
            Text("刷新或下载原图后显示")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func placeholderTitleBlock(for payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let copyright = payload.copyright, !copyright.isEmpty {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func photoFooter(for payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    sourceDateLabel(for: payload)
                    imageStateLabel(for: payload)
                    Spacer(minLength: 12)
                    downloadControl(for: payload)
                }
                VStack(alignment: .leading, spacing: 10) {
                    sourceDateLabel(for: payload)
                    HStack(spacing: 12) {
                        imageStateLabel(for: payload)
                        Spacer(minLength: 8)
                        downloadControl(for: payload)
                    }
                }
            }

            Divider()
                .opacity(0.6)

            wallpaperControls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var wallpaperControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TodayFlowLayout(spacing: 12, rowSpacing: 8) {
                displayTargetControl
                applyWallpaperButton
                automationProgress
            }

            if let status = model.wallpaperStatusMessage, !status.isEmpty {
                Label(status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var displayTargetControl: some View {
        if model.displays.isEmpty {
            Label("未检测到显示器", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .accessibilityLabel("未检测到显示器，无法应用壁纸")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Picker("目标显示器", selection: displayBinding) {
                    ForEach(model.displays) { display in
                        Text(display.label).tag(Optional(display.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("目标显示器")
                .help("选择要写入的显示器")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(0.05),
                in: Capsule()
            )
        }
    }

    private var applyWallpaperButton: some View {
        Button(action: model.beginApplyWallpaper) {
            Label("设为壁纸…", systemImage: "photo.on.rectangle")
        }
        .modifier(TodayPrimaryActionStyle())
        .controlSize(.regular)
        .fixedSize()
        .disabled(
            !model.canApplyWallpaper
                || model.isPreparingConsent
                || model.displays.isEmpty
                || model.pendingWallpaperConfirmation != nil
        )
        .help("打开一次确认并应用到当前桌面")
    }

    @ViewBuilder
    private var automationProgress: some View {
        if model.isPreparingConsent || model.isApplyingWallpaper || model.isUpdatingAutomation {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(automationProgressLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    private var automationProgressLabel: String {
        if model.isApplyingWallpaper {
            return MacLocalizedString.resolve("正在写入壁纸…", locale: WallpaperInterfaceLocale.current)
        }
        if model.isUpdatingAutomation {
            return MacLocalizedString.resolve("正在更新自动同步…", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("正在准备确认…", locale: WallpaperInterfaceLocale.current)
    }

    private func sourceDateLabel(for payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(payload.sourceDate.iso8601)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(payload.isSourceDateToday ? MacLocalizedString.resolve("今日来源", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("最新来源日期", locale: WallpaperInterfaceLocale.current))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func imageStateLabel(for payload: TodayPayload) -> some View {
        Group {
            if model.heroImage == nil {
                Label("图片未缓存", systemImage: "circle.dashed")
            } else if payload.hasOriginal {
                Label("原图已缓存", systemImage: "checkmark.circle")
            } else {
                Label("预览图已缓存", systemImage: "circle.lefthalf.filled")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func downloadControl(for payload: TodayPayload) -> some View {
        if !payload.hasOriginal {
            HStack(spacing: 8) {
                Button(action: model.downloadOriginal) {
                    Label("下载原图", systemImage: "arrow.down.circle")
                }
                .modifier(TodaySecondaryActionStyle())
                .disabled(model.isDownloadingOriginal)

                if model.isDownloadingOriginal {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在下载原图")
                }
            }
        }
    }

    // MARK: Status details

    /// The photograph's original-image badge is also the single entry point
    /// for update, network, and cache state. The popover keeps those details
    /// out of the reading path while leaving them keyboard- and VoiceOver-reachable.
    private func statusBadge(for payload: TodayPayload) -> some View {
        Button {
            isShowingStatusDetails.toggle()
        } label: {
            TodayStatusBadge(
                text: imageBadgeLabel,
                statusColor: badgeStatusColor,
                isShowingDetails: isShowingStatusDetails
            )
        }
        .buttonStyle(.plain)
        .help("查看获取状态、网络来源与缓存详情")
        .accessibilityLabel(
            "\(imageBadgeLabel)，\(model.statusTitle)，\(model.sourceOriginLabel)"
        )
        .accessibilityHint("显示获取状态与缓存详情")
        .popover(isPresented: $isShowingStatusDetails, arrowEdge: .top) {
            statusDetails(for: payload)
                .padding(18)
                .frame(width: 360)
        }
    }

    private var imageBadgeLabel: String {
        if model.originalImage != nil {
            return MacLocalizedString.resolve("原图", locale: WallpaperInterfaceLocale.current)
        }
        if model.heroImage != nil {
            return MacLocalizedString.resolve("预览图", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("图片未缓存", locale: WallpaperInterfaceLocale.current)
    }

    private func statusDetails(for payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("图片与获取状态", systemImage: "info.circle")

            statusSummary(for: payload)

            if hasCacheDetails(for: payload) {
                Divider()
                    .opacity(0.6)
                cacheDetailRows(for: payload)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cacheDetailRows(for payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("缓存与记录")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if let cachedAt = payload.cachedAt {
                Text("本地记录时间：\(StatusFormatter.dateTime(cachedAt, locale: locale))")
            }
            if let storage = model.storageSummary {
                Text("本地图片缓存：\(storage)")
            }
            HStack(spacing: 12) {
                Label(
                    payload.hasThumbnail ? MacLocalizedString.resolve("缩略图已缓存", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("缩略图未缓存", locale: WallpaperInterfaceLocale.current),
                    systemImage: payload.hasThumbnail ? "checkmark.circle" : "circle.dashed"
                )
                Label(
                    payload.hasOriginal ? MacLocalizedString.resolve("原图已缓存", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("原图未缓存", locale: WallpaperInterfaceLocale.current),
                    systemImage: payload.hasOriginal ? "checkmark.circle" : "circle.dashed"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hasCacheDetails(for payload: TodayPayload) -> Bool {
        payload.cachedAt != nil
            || model.storageSummary != nil
            || payload.hasThumbnail
            || payload.hasOriginal
    }

    private func statusSummary(for payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.statusTitle)
                    .font(.callout.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(model.sourceOriginLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            if let lastUpdated = model.lastUpdated {
                Text("最近成功获取：\(StatusFormatter.dateTime(lastUpdated, locale: locale))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let cachedAt = payload.cachedAt {
                Text("本地记录：\(StatusFormatter.dateTime(cachedAt, locale: locale))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch model.loadState {
        case .ready, .refreshing: return .green
        case .offline: return .orange
        case .failed: return .red
        case .empty, .idle, .loadingCache: return .secondary
        }
    }

    /// The badge always sits on a dark capsule, in both appearances. Neutral
    /// `.secondary` would be too dark there in light mode, so use a fixed gray.
    private var badgeStatusColor: Color {
        switch model.loadState {
        case .empty, .idle, .loadingCache: return .gray
        case .ready, .refreshing, .offline, .failed: return statusColor
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var storySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("每日介绍", systemImage: "text.book.closed")

            switch model.storyPanel ?? .notFetched {
            case .available(let story):
                storyAvailable(story)
            case .unavailable(let reason, _, let headline, let copyright, let sourceURL):
                Text("该地区暂无可用介绍")
                    .font(.callout.weight(.semibold))
                Text(StoryCopy.unavailableReason(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let headline, !headline.isEmpty {
                    Text(headline)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let copyright, !copyright.isEmpty {
                    storyMetadata("版权：\(copyright)")
                }
                if let sourceURL {
                    Link("查看来源页面", destination: sourceURL)
                        .font(.caption)
                }
            case .unmatched(let hasCandidates):
                Text(hasCandidates ? MacLocalizedString.resolve("无法确认介绍属于这张图片", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("未取得当日介绍", locale: WallpaperInterfaceLocale.current))
                    .font(.callout.weight(.semibold))
                Text(
                    hasCandidates
                        ? MacLocalizedString.resolve("当天有介绍，但无法确认它属于这张图片，因此没有显示，以免错配。", locale: WallpaperInterfaceLocale.current)
                        : MacLocalizedString.resolve("该地区可能未提供当日介绍，或本次获取失败。不会用相邻日期或其他地区文本填充。", locale: WallpaperInterfaceLocale.current)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .notFetched:
                Text("尚未获取当日介绍")
                    .font(.callout.weight(.semibold))
                Text("点击刷新重试。缺失介绍不会影响图片使用，也不会用虚构文本补齐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func storyAvailable(_ story: StoryText) -> some View {
        if let headline = story.headline, !headline.isEmpty {
            Text(headline)
                .font(.title3.weight(.semibold))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let title = story.title, !title.isEmpty {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let quickFact = story.quickFact, !quickFact.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("来源速览")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(quickFact)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }

        if let body = story.body, !body.isEmpty {
            Text(body)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let copyright = story.copyright, !copyright.isEmpty {
            storyMetadata("版权：\(copyright)")
        }

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                storySourceLink(story.sourceURL)
                Spacer(minLength: 8)
                storyFetchedLabel(story)
            }
            VStack(alignment: .leading, spacing: 5) {
                storySourceLink(story.sourceURL)
                storyFetchedLabel(story)
            }
        }
    }

    @ViewBuilder
    private func storySourceLink(_ url: URL?) -> some View {
        if let url {
            Link("查看原文", destination: url)
                .font(.caption)
        }
    }

    private func storyFetchedLabel(_ story: StoryText) -> some View {
        Text(StoryCopy.provenance(localeTag: story.locale, fetchedAt: story.fetchedAt, in: locale))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func storyMetadata(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var guardBlocksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("等待确认的显示器", systemImage: "exclamationmark.shield")

            Text("这些显示器当前是未知或受手动保护的壁纸。只有确认后才会覆盖；系统未返回当前壁纸时无法按图片确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.guardBlocks) { block in
                VStack(alignment: .leading, spacing: 4) {
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
                    } else {
                        Text("系统没有返回当前壁纸，无法按图片确认覆盖。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if block.canConfirm {
                        Button("确认覆盖…") {
                            overwriteCandidate = block
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.isApplyingWallpaper)
                        .accessibilityLabel("确认覆盖 \(block.displayName) 的当前壁纸")
                    }
                }
                if block.id != model.guardBlocks.last?.id {
                    Divider()
                        .opacity(0.6)
                }
            }
        }
        .modifier(TodayCardStyle(tone: .warning, padding: 16))
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("获取提示", systemImage: "exclamationmark.bubble")
            ForEach(model.warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var displayBinding: Binding<DesktopDisplayID?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { model.selectDisplay($0) }
        )
    }

    // MARK: States and banners

    private var isLoadingWithoutContent: Bool {
        switch model.loadState {
        case .idle, .loadingCache, .refreshing:
            return true
        case .empty, .ready, .offline, .failed:
            return false
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在读取本地缓存并获取今日内容…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有可显示的今日内容", systemImage: "sunrise")
        } description: {
            Text("连接网络后刷新；离线时只会显示已经缓存的内容，不会补造图片或介绍。")
        } actions: {
            Button("刷新今日", action: model.retry)
                .modifier(TodayPrimaryActionStyle())
                .controlSize(.large)
                .disabled(model.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("重试", action: model.retry)
                .disabled(model.isRefreshing)
        }
        .modifier(TodayCardStyle(tone: .warning, padding: 14))
    }

    private func wallpaperAutomationBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("壁纸状态")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if model.requiresDisableRetry {
                    Text("本次会话已停止自动写入，但保存的设置可能仍为自动同步；重新启动后可能恢复。请重试关闭。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if model.requiresDisableRetry {
                Button("重试关闭") {
                    model.setAutoSync(false)
                }
                .disabled(model.isUpdatingAutomation)
            }
        }
        .modifier(TodayCardStyle(tone: .warning, padding: 14))
    }
}

// MARK: - Visual system

/// Publishes the page's real scroll overlap to the window chrome.
///
/// On macOS 15 and later, use the public scroll geometry event. On macOS 14,
/// observe the content origin in the scroll view's coordinate space instead.
private struct TodayScrollOverlapReporter: ViewModifier {
    @Binding var isOverlapping: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                // At the resting top edge the offset cancels the top inset,
                // so the sum is zero. Any real downward scroll makes it
                // positive; rubber-band overscroll above the top stays
                // negative and must not reveal the backdrop.
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, newValue in
                guard isOverlapping != newValue else { return }
                isOverlapping = newValue
            }
        } else {
            content.onPreferenceChange(TodayLegacyScrollOffset.self) { offset in
                isOverlapping = offset < -0.5
            }
        }
    }
}

private struct TodayLegacyScrollOffset: SwiftUI.PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum TodayMetrics {
    static let cardRadius: CGFloat = 18
    static let photoRadius: CGFloat = 22
    /// Reserved space so the first-screen wallpaper action row clears the
    /// floating bottom navigation that AppShell overlays above the content.
    static let floatingNavigationClearance: CGFloat = 240
    static let minimumPhotoHeight: CGFloat = 240
}

private enum TodayCardTone: Equatable {
    case neutral
    case warning
}

/// Opaque semantic card keeps text readable over the frosted window.
private struct TodayCardStyle: ViewModifier {
    var tone: TodayCardTone = .neutral
    var padding: CGFloat = 18

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                if tone == .warning {
                    shape.fill(Color.orange.opacity(0.10))
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    tone == .warning
                        ? Color.orange.opacity(0.24)
                        : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
    }
}

/// Clickable floating badge on the photograph. It is the single entry point
/// for original-image state and the update/network/cache popover. Liquid Glass
/// keeps the photo visible through the badge on macOS 26; a dark capsule
/// guarantees contrast on older systems and when Reduce Transparency is enabled.
private struct TodayStatusBadge: View {
    let text: String
    let statusColor: Color
    let isShowingDetails: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            label
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.black.opacity(0.32)), in: Capsule())
        } else {
            label
                .foregroundStyle(.white)
                .background(.black.opacity(0.75), in: Capsule())
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2.weight(.semibold))
            Image(systemName: isShowingDetails ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.85)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Capsule())
    }
}

/// Left-aligned wrapping row for wallpaper controls. Each control keeps its
/// intrinsic size; rows wrap only when the available width cannot fit the next
/// control, so narrow windows never clip a selector or button. Controls of
/// differing intrinsic height (for example the display-picker capsule next to
/// a bordered button) are vertically centered within their row so the row
/// reads as one baseline.
private struct TodayFlowLayout: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Groups subviews into rows using intrinsic sizes. The first pass records
    /// each row's used width and tallest control so placement can center every
    /// control on the row's vertical midpoint.
    private func wrappedRows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var leading: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, leading + size.width > maxWidth {
                rows.append(current)
                current = Row()
                leading = 0
            }
            current.indices.append(index)
            current.width = max(current.width, leading + size.width)
            current.height = max(current.height, size.height)
            leading += size.width + spacing
        }

        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let wrapped = wrappedRows(for: subviews, maxWidth: maxWidth)
        guard !wrapped.isEmpty else {
            return .zero
        }

        let widest = wrapped.map(\.width).max() ?? 0
        let totalHeight = wrapped.reduce(0) { $0 + $1.height }
            + rowSpacing * CGFloat(wrapped.count - 1)

        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY

        for row in wrappedRows(for: subviews, maxWidth: bounds.width) {
            var leading = bounds.minX
            let centerY = y + row.height / 2

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: leading, y: centerY),
                    anchor: .leading,
                    proposal: ProposedViewSize(size)
                )
                leading += size.width + spacing
            }

            y += row.height + rowSpacing
        }
    }
}

// MARK: - Action styles

private struct TodayPrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct TodaySecondaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
