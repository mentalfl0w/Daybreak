import DaybreakCore
import SwiftUI

struct TimelineDetailScreen: View {
    let onPreview: (TimelinePreviewContent) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineDetailView(isWide: false, onPreview: onPreview)
            .navigationTitle("时光详情", locale: locale)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct TimelineDetailView: View {
    let isWide: Bool
    let onPreview: (TimelinePreviewContent) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            if let detail = model.detail {
                detailContent(detail)
            } else {
                placeholder
                    .padding(16)
            }
        }
        .refreshable {
            await model.refresh()
        }
        .wideShellTabBarInset()
    }

    private var placeholder: some View {
        TimelineStateCard(
            systemImage: "calendar",
            title: Text("选择一天"),
            message: Text("在日历或图库中选择日期，查看当天保存的图片、介绍和其他地区记录。")
        )
    }

    @ViewBuilder
    private func detailContent(_ detail: TimelineDayDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if detail.market != model.market {
                marketMismatchBanner(detail)
            }

            TimelineHeroImage(
                wallpaperID: detail.wallpaperID,
                hasCachedAsset: detail.hasThumbnail || detail.hasOriginal,
                isWide: isWide
            )

            VStack(alignment: .leading, spacing: 8) {
                dayNavigation(detail)

                HStack(spacing: 8) {
                    TimelineDateText(locale: locale, timeZone: model.timeZone)
                        .full(detail.date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Text(detail.title ?? MobileLocalizedString.resolve("未保存标题", locale: locale))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(detail.title == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let copyright = detail.copyright {
                    Text(verbatim: copyright)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    TimelineBadge(
                        Text(verbatim: TimelinePresentation.marketShortName(
                            for: detail.market,
                            in: locale
                        )),
                        systemImage: "globe"
                    )
                    if detail.isRecorded {
                        TimelineBadge(
                            Text(assetLabel(detail)),
                            systemImage: detail.hasOriginal ? "square.stack.3d.up" : "photo"
                        )
                    }
                    if model.isFavorite(detail.wallpaperID) {
                        TimelineBadge(Text("已收藏"), systemImage: "heart.fill", tint: .pink)
                    }
                }
            }

            if detail.occurrence != nil {
                actionRow(detail)
            }

            if detail.day.state != .observed {
                missingDayState(detail)
            } else if detail.occurrence != nil {
                if !detail.hasThumbnail && !detail.hasOriginal {
                    Text("这一天的图片尚未缓存。下载原图后可以预览、保存或交给快捷指令设置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TimelineStorySection(
                    status: detail.storyStatus,
                    title: detail.title,
                    fallbackSourceURL: detail.metadata?.sourceURL ?? detail.wallpaper?.sourceURL,
                    fetchedAt: detail.metadata?.fetchedAt ?? detail.wallpaper?.fetchedAt,
                    originalLocale: detail.metadata?.originalLocale ?? "und"
                )
            }

            otherMarketsSection(detail)
            provenanceSection(detail)

            if let assetError = model.assetError {
                TimelineErrorBanner(failure: assetError) {
                    model.dismissAssetError()
                }
            }
        }
        .padding(16)
        .padding(.bottom, 24)
    }

    private func dayNavigation(_ detail: TimelineDayDetail) -> some View {
        HStack(spacing: 8) {
            if let previous = detail.date.previousDay {
                Button {
                    _ = model.selectDate(previous)
                } label: {
                    Label("前一天", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("前一天"))
            }

            Spacer(minLength: 0)

            Button {
                model.selectToday()
            } label: {
                Text("今天")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
            .buttonBorderShape(.capsule)
            .disabled(detail.date == detail.asOf)
            .accessibilityHint(Text("回到地区当前日期"))

            Spacer(minLength: 0)

            if let next = detail.date.nextDay, next <= detail.asOf {
                Button {
                    _ = model.selectDate(next)
                } label: {
                    Label("后一天", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("后一天"))
            }
        }
    }

    // MARK: Banner

    private func marketMismatchBanner(_ detail: TimelineDayDetail) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在查看其他地区")
                    .font(.subheadline.weight(.semibold))
                Text("这是 \(Text(verbatim: TimelinePresentation.marketName(for: detail.market, in: locale))) 在这天的记录；日历仍显示当前地区。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("切换地区") {
                Task {
                    await model.switchToMarketOfCurrentDetail()
                }
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
            .controlSize(.small)
            .disabled(model.isRefreshing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: Actions

    private func actionRow(_ detail: TimelineDayDetail) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 138), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            favoriteButton(detail)
            previewButton(detail)
            if let wallpaperID = detail.wallpaperID {
                DaybreakSetWallpaperButton(
                    wallpaperID: wallpaperID,
                    occurrenceKey: detail.key
                )
            }
            if !detail.hasOriginal {
                downloadButton(detail)
            }
            if let sourceURL = detail.metadata?.sourceURL ?? detail.wallpaper?.sourceURL {
                ShareLink(item: sourceURL) {
                    Label("分享来源", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.daybreakActionTint)
                .accessibilityHint(Text("分享 Bing 来源网页，不会分享受版权保护的图片文件"))
            }
        }
    }

    private func favoriteButton(_ detail: TimelineDayDetail) -> some View {
        let wallpaperID = detail.wallpaperID
        let isFavorite = model.isFavorite(wallpaperID)
        let isUpdating = model.isUpdatingFavorite(wallpaperID)
        return Button {
            Task {
                await model.toggleFavorite(wallpaperID)
            }
        } label: {
            if isUpdating {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("保存中")
                }
                .frame(maxWidth: .infinity)
            } else {
                Label(
                    isFavorite ? "已收藏" : "收藏",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .tint(isFavorite ? Color.pink : Color.daybreakActionTint)
        .disabled(wallpaperID == nil || isUpdating)
        .accessibilityValue(isFavorite ? Text("已收藏") : Text("未收藏"))
    }

    private func previewButton(_ detail: TimelineDayDetail) -> some View {
        Button {
            Task {
                if let content = await model.preparePreview(for: detail) {
                    onPreview(content)
                }
            }
        } label: {
            if model.isPreparingPreview {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("准备图片")
                }
                .frame(maxWidth: .infinity)
            } else {
                Label("预览与设置", systemImage: "crop")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(detail.occurrence == nil || model.isPreparingPreview)
        .accessibilityHint(Text("预览裁切并导出；通过快捷指令设置时使用快捷指令自身的输出设置"))
    }

    private func downloadButton(_ detail: TimelineDayDetail) -> some View {
        let isRequesting = model.isRequestingAsset(detail.wallpaperID)
        return Button {
            Task {
                _ = await model.downloadOriginal(for: detail)
            }
        } label: {
            if isRequesting {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("下载中")
                }
                .frame(maxWidth: .infinity)
            } else {
                Label("下载原图", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .tint(.daybreakActionTint)
        .disabled(detail.occurrence == nil || isRequesting || model.isPreparingPreview)
    }

    // MARK: Missing day

    private func missingDayState(_ detail: TimelineDayDetail) -> some View {
        Group {
            switch detail.day.state {
            case .notRecorded:
                TimelineStateCard(
                    systemImage: "calendar.badge.exclamationmark",
                    title: Text("本机未记录这一天"),
                    message: Text("Daybreak 没有在这一天为该地区保存记录。可能是应用未运行、该地区未启用或内容获取失败；这不代表 Bing 当天没有发布壁纸。")
                )
            case .beforeObservationStart:
                TimelineStateCard(
                    systemImage: "clock.arrow.circlepath",
                    title: Text("早于本地首次记录"),
                    message: Text("本地观察从 \(firstObservedText(detail)) 开始。更早的日期没有可展示的本地图片或介绍。")
                )
            case .future:
                TimelineStateCard(
                    systemImage: "hourglass",
                    title: Text("尚未到来的日期"),
                    message: Text("这一天晚于该地区当前的来源日期 \(asOfText(detail))，不能作为历史记录展示。")
                )
            case .observed:
                EmptyView()
            }
        }
    }

    private func firstObservedText(_ detail: TimelineDayDetail) -> String {
        guard let first = detail.firstObservedDate else {
            return MobileLocalizedString.resolve("未知日期", locale: locale)
        }
        return TimelinePresentation.fullDate(first, locale: locale, timeZone: model.timeZone)
    }

    private func asOfText(_ detail: TimelineDayDetail) -> String {
        TimelinePresentation.fullDate(detail.asOf, locale: locale, timeZone: model.timeZone)
    }

    // MARK: Other markets

    @ViewBuilder
    private func otherMarketsSection(_ detail: TimelineDayDetail) -> some View {
        if !detail.otherMarkets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("同一天的其他地区")
                    .font(.headline)
                Text("仅来自本机缓存。不同地区的标题和介绍彼此独立，不会合并或互相替换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(detail.otherMarkets) { occurrence in
                        Button {
                            model.selectMarketOccurrence(occurrence)
                        } label: {
                            TimelineOtherMarketRow(occurrence: occurrence)
                        }
                        .buttonStyle(.plain)
                        if occurrence.id != detail.otherMarkets.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: Provenance

    private func provenanceSection(_ detail: TimelineDayDetail) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                provenanceRow("内容地区", TimelinePresentation.marketTag(for: detail.market, in: locale))
                if let wallpaperID = detail.wallpaperID {
                    provenanceRow("图片标识", wallpaperID.description)
                }
                if let localeTag = detail.metadata?.originalLocale,
                   let language = TimelinePresentation.sourceLanguageName(localeTag, in: locale) {
                    provenanceRow("来源语言", language)
                }
                if let fetchedAt = detail.metadata?.fetchedAt {
                    provenanceRow(
                        "元数据获取时间",
                        TimelinePresentation.fetchedAt(fetchedAt, locale: locale, timeZone: model.timeZone)
                    )
                }
                if let sourceURL = detail.metadata?.sourceURL ?? detail.wallpaper?.sourceURL {
                    provenanceRow("来源网页", sourceURL.host() ?? sourceURL.absoluteString)
                }
                provenanceRow("来源日期", detail.date.iso8601)
                Text("Bing 原文按请求地区原样保存，不自动翻译；缺失内容不会补写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.top, 8)
        } label: {
            Text("来源与缓存信息")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func provenanceRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func assetLabel(_ detail: TimelineDayDetail) -> LocalizedStringKey {
        if detail.hasOriginal { return "原图已缓存" }
        if detail.hasThumbnail { return "缩略图" }
        return "图片未缓存"
    }
}

// MARK: - Hero

struct TimelineHeroImage: View {
    let wallpaperID: WallpaperID?
    let hasCachedAsset: Bool
    let isWide: Bool

    @Environment(TimelineModel.self) private var model
    @State private var image: TimelineDetailImage?
    @State private var displayedIdentity: String?
    @State private var loadedKey: String?
    @State private var loadingKey: String?
    @State private var loadGeneration = 0

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            .overlay {
                if let image, displayedIdentity == identityID {
                    Image(decorative: image.image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if loadingKey == taskID || (hasCachedAsset && loadedKey != taskID) {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                        Text(hasCachedAsset ? "本地图片无法读取" : "图片未缓存")
                            .font(.caption)
                        if !hasCachedAsset {
                            Text("联网后可下载原图")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .task(id: taskID) {
                await load()
            }
            .accessibilityHidden(true)
    }

    /// The image identity and layout width select which image belongs here; the
    /// asset revision is tracked separately so the current image stays visible
    /// while a changed local file is decoded, instead of flashing a placeholder.
    private var identityID: String {
        "\(wallpaperID?.description ?? "none")-\(isWide)"
    }

    private var taskID: String {
        "\(identityID)-\(model.imageRevision)"
    }

    private func load() async {
        let identity = identityID
        let key = taskID
        guard loadedKey != key else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadingKey = key
        let decoded = await model.detailImage(
            for: wallpaperID,
            maxPixelSize: isWide ? 2_800 : 2_200
        )
        // A newer identity or revision restarted this view. Publishing here
        // would otherwise let the old thumbnail replace the original that just
        // finished downloading.
        guard generation == loadGeneration else { return }
        loadingKey = nil
        guard !Task.isCancelled else { return }
        image = decoded
        displayedIdentity = identity
        loadedKey = key
    }
}

// MARK: - Story

struct TimelineStorySection: View {
    let status: TimelineStoryStatus
    let title: String?
    let fallbackSourceURL: URL?
    let fetchedAt: Date?
    let originalLocale: String

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每日介绍")
                .font(.headline)

            switch status {
            case .available(let record):
                story(record)
            case .unavailable(let reason, let record):
                unavailable(record, reason: reason)
            case .notStored:
                Text("本地没有这一天该地区的介绍记录。Daybreak 不会用其他日期、其他地区或生成文本替代。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func story(_ record: DailyStoryRecord) -> some View {
        if let headline = record.headline, headline != title {
            Text(verbatim: headline)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }

        if let quickFact = record.quickFact {
            VStack(alignment: .leading, spacing: 4) {
                Text("速览")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: quickFact)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }

        if let body = record.body {
            Text(verbatim: body)
                .font(.body)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        attribution(
            sourceURL: record.sourceURL ?? fallbackSourceURL,
            fetchedAt: record.fetchedAt,
            originalLocale: record.originalLocale,
            copyright: record.copyright
        )
    }

    @ViewBuilder
    private func unavailable(_ record: DailyStoryRecord, reason: StoryUnavailableReason) -> some View {
        if let headline = record.headline, headline != title {
            Text(verbatim: headline)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(TimelineStoryCopy.unavailableReason(reason))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        attribution(
            sourceURL: record.sourceURL ?? fallbackSourceURL,
            fetchedAt: record.fetchedAt,
            originalLocale: record.originalLocale,
            copyright: record.copyright
        )
    }

    @ViewBuilder
    private func attribution(
        sourceURL: URL?,
        fetchedAt: Date?,
        originalLocale: String,
        copyright: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let copyright, !copyright.isEmpty {
                Text(verbatim: copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let language = TimelinePresentation.sourceLanguageName(originalLocale, in: locale) {
                    Label {
                        Text(verbatim: language)
                    } icon: {
                        Image(systemName: "character.book.closed")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let fetchedAt {
                    Text("获取于 \(TimelinePresentation.fetchedAt(fetchedAt, locale: locale, timeZone: model.timeZone))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let sourceURL {
                SourceLink(destination: sourceURL) {
                    Label("查看来源网页", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.medium))
                }
                .tint(.daybreakActionTint)
                .accessibilityHint(Text("打开 Bing 上的原始来源页面"))
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Other market row

struct TimelineOtherMarketRow: View {
    let occurrence: TimelineMarketOccurrence

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            TimelineThumbnailView(
                wallpaperID: occurrence.wallpaperID,
                maxPixelSize: 140,
                showsPlaceholder: true
            )
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: TimelinePresentation.marketName(for: occurrence.market, in: locale))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if model.isFavorite(occurrence.wallpaperID) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)
                    }
                }
                Text(occurrence.title ?? MobileLocalizedString.resolve("未保存标题", locale: locale))
                    .font(.caption)
                    .foregroundStyle(occurrence.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if occurrence.hasOriginal {
                        TimelineBadge(Text("原图"), systemImage: "square.stack.3d.up")
                    } else if occurrence.hasThumbnail {
                        TimelineBadge(Text("缩略图"), systemImage: "photo")
                    } else {
                        TimelineBadge(Text("仅元数据"), systemImage: "doc.text")
                    }
                    if occurrence.storyStatus.isAvailable {
                        TimelineBadge(Text("介绍"), systemImage: "text.book.closed", tint: .daybreakActionTint)
                    }
                }
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("查看这个地区的图片与介绍"))
    }
}
