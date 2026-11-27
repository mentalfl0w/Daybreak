import DaybreakCore
import SwiftUI

/// Complete fetch/cache receipt for the current photograph.
///
/// The floating badge opens this receipt instead of putting diagnostics over the
/// image. Everything shown here is observed store state; the view does not
/// infer a source date from the device clock or claim a story was fetched when
/// it was not.
@MainActor
struct TodayStatusView: View {
    let content: TodayDisplayContent
    let phase: TodayLoadPhase
    let errorMessage: String?
    let warnings: [String]
    let lastUpdated: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    receipt
                    Divider()
                    storyState
                    if let errorMessage, !errorMessage.isEmpty {
                        Divider()
                        messageBlock(
                            title: "操作未完成",
                            message: errorMessage,
                            systemImage: "exclamationmark.triangle",
                            tone: .orange
                        )
                    }
                    if !warnings.isEmpty {
                        Divider()
                        warningsBlock
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("获取状态", locale: locale)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.title2)
                .foregroundStyle(headerColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.headline)
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerSymbol: String {
        switch phase {
        case .refreshing, .loadingCache: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .empty: "photo.badge.exclamationmark"
        case .ready:
            content.imageAvailability == .missing ? "photo.badge.exclamationmark" : "checkmark.circle.fill"
        case .idle: "clock"
        }
    }

    private var headerColor: Color {
        switch phase {
        case .failed: .red
        case .empty: .orange
        case .ready: content.imageAvailability == .missing ? .orange : .green
        case .idle, .loadingCache, .refreshing: .secondary
        }
    }

    private var headerTitle: LocalizedStringKey {
        switch phase {
        case .idle: "准备中"
        case .loadingCache: "正在读取本地缓存"
        case .refreshing: "正在刷新今日内容"
        case .ready: "今日内容已就绪"
        case .empty: "还没有可显示的今日内容"
        case .failed: "获取失败"
        }
    }

    private var headerDetail: LocalizedStringKey {
        switch phase {
        case .idle: "等待开始读取本地记录。"
        case .loadingCache: "先显示已缓存的内容，再尝试联网更新。"
        case .refreshing: "正在获取所选地区的图片元数据与介绍。"
        case .ready: content.isSourceDateToday ? "当前显示所选地区今天的内容。" : "当前显示所选地区可用的最新来源日期。"
        case .empty: "连接网络后刷新；离线时只显示已经缓存的内容。"
        case .failed: "已保留可用缓存；可稍后重试。"
        }
    }

    // MARK: Receipt

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "图片与来源", systemImage: "photo")

            statusRow(label: "来源日期", value: TodayFormatting.sourceDate(content.sourceDate, locale: locale), systemImage: "calendar")
            statusRow(label: "内容地区", value: TodayFormatting.marketName(content.market, locale: locale), systemImage: "globe")
            statusRow(label: "图片来源", value: "Bing", systemImage: "sparkle.magnifyingglass")
            if let copyright = content.copyright, !copyright.isEmpty {
                statusRow(label: "版权", value: copyright, systemImage: "c.circle")
            }
            statusRow(label: "图片缓存", value: imageStateText, systemImage: content.imageAvailability == .missing ? "circle.dashed" : "internaldrive")
            if let fetchedAt = content.fetchedAt {
                statusRow(label: "最近来源获取", value: TodayFormatting.dateTime(fetchedAt, locale: locale), systemImage: "clock.arrow.circlepath")
            }
            if let lastUpdated {
                statusRow(label: "最近更新时间", value: TodayFormatting.dateTime(lastUpdated, locale: locale), systemImage: "clock")
            }

            if let sourceURL = content.sourceURL {
                Link(destination: sourceURL) {
                    Label("打开来源页面", systemImage: "safari")
                        .font(.callout)
                }
                .tint(.daybreakActionTint)
                .padding(.top, 2)
            }

            Button(action: onToggleFavorite) {
                Label {
                    content.isFavorite ? Text("取消收藏") : Text("收藏这张图片")
                } icon: {
                    Image(systemName: content.isFavorite ? "heart.fill" : "heart")
                }
            }
            .buttonStyle(.bordered)
            .tint(content.isFavorite ? Color.pink : Color.daybreakActionTint)
            .padding(.top, 4)
        }
    }

    private var imageStateText: String {
        switch content.imageAvailability {
        case .original:
            MobileLocalizedString.resolve("原图已缓存", locale: locale)
        case .thumbnail:
            MobileLocalizedString.resolve("仅有预览图，原图未缓存", locale: locale)
        case .missing:
            MobileLocalizedString.resolve("未缓存", locale: locale)
        }
    }

    private func statusRow(label: LocalizedStringKey, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 82, alignment: .leading)
            Text(verbatim: value)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Story

    private var storyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "每日介绍", systemImage: "text.book.closed")

            switch content.storyMatch {
            case .matched(let story, _) where story.isAvailable:
                Label("介绍可用", systemImage: "checkmark.circle")
                    .font(.callout)
            case .unavailable(let story):
                Label("该地区暂无可用介绍", systemImage: "text.badge.xmark")
                    .font(.callout)
                if case .unavailable(let reason) = story.availability {
                    Text(TodayStoryView.reasonText(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unmatched:
                Label("暂无可显示的介绍", systemImage: "text.badge.xmark")
                    .font(.callout)
            case .matched(let story, _):
                Label("介绍内容不可用", systemImage: "text.badge.xmark")
                    .font(.callout)
                if let reason = story.availability.unavailableReason {
                    Text(TodayStoryView.reasonText(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case nil:
                Label("尚未获取今日介绍", systemImage: "text.badge.xmark")
                    .font(.callout)
            }
        }
    }

    // MARK: Messages

    private var warningsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "获取提示", systemImage: "exclamationmark.bubble")
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(verbatim: warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func messageBlock(
        title: LocalizedStringKey,
        message: String,
        systemImage: String,
        tone: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tone)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension StoryAvailability {
    var unavailableReason: StoryUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
