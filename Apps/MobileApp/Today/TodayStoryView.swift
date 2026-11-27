import DaybreakCore
import SwiftUI

/// Full-width daily story panel.
///
/// The source's original text is shown only when it matches this image. Missing
/// or unmatched stories stay empty rather than being filled from another record.
@MainActor
struct TodayStoryView: View {
    let content: TodayDisplayContent
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "今日介绍", systemImage: "text.book.closed")

            switch content.storyMatch {
            case .matched(let story, _) where story.isAvailable:
                availableStory(story)
            case .unavailable(let story):
                unavailableStory(story)
            case .matched(let story, _):
                // Defensive: `.matched` should carry usable text, but never
                // fabricate a body if a record's availability changed.
                unavailableStory(story)
            case .unmatched:
                unmatchedStory()
            case nil:
                emptyStory
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Available

    @ViewBuilder
    private func availableStory(_ story: DailyStoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = storyTitle(story) {
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let quickFact = story.quickFact, !quickFact.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("来源速览", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: quickFact)
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let body = story.body, !body.isEmpty {
                Text(verbatim: body)
                    .font(.callout)
                    .lineSpacing(dynamicTypeSize.isAccessibilitySize ? 4 : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let copyright = story.copyright,
               !copyright.isEmpty,
               copyright != content.copyright {
                copyrightLine(copyright)
            }

            storyFooter(story)
        }
    }

    private func storyTitle(_ story: DailyStoryRecord) -> String? {
        if let headline = story.headline, !headline.isEmpty {
            return headline == content.title ? nil : headline
        }
        guard let title = story.title, !title.isEmpty, title != content.title else {
            return nil
        }
        return title
    }

    // MARK: Unavailable / unmatched

    private func unavailableStory(_ story: DailyStoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("该地区暂无可用介绍", systemImage: "text.badge.xmark")
                .font(.callout.weight(.semibold))


            if let headline = story.headline,
               !headline.isEmpty,
               headline != content.title {
                Text(verbatim: headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let copyright = story.copyright,
               !copyright.isEmpty,
               copyright != content.copyright {
                copyrightLine(copyright)
            }

            if let url = story.sourceURL {
                SourceLink(destination: url, label: Text("查看来源页面"))
                    .tint(.daybreakActionTint)
                    .font(.caption)
            }

            storyFooter(story, showSourceLink: false)
        }
    }

    private func unmatchedStory() -> some View {
        Label("暂无可显示的介绍", systemImage: "text.badge.xmark")
            .font(.callout.weight(.semibold))
    }

    private var emptyStory: some View {
        Label("尚未获取今日介绍", systemImage: "text.badge.xmark")
            .font(.callout.weight(.semibold))
    }

    // MARK: Shared footer

    @ViewBuilder
    private func storyFooter(_ story: DailyStoryRecord, showSourceLink: Bool = true) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if showSourceLink, let url = story.sourceURL {
                    SourceLink(destination: url, label: Text("查看原文"))
                        .tint(.daybreakActionTint)
                        .font(.caption)
                }
                Spacer(minLength: 8)
                provenance(story)
            }
            VStack(alignment: .leading, spacing: 5) {
                if showSourceLink, let url = story.sourceURL {
                    SourceLink(destination: url, label: Text("查看原文"))
                        .tint(.daybreakActionTint)
                        .font(.caption)
                }
                provenance(story)
            }
        }
    }

    private func provenance(_ story: DailyStoryRecord) -> some View {
        HStack(spacing: 4) {
            if let language = TodayFormatting.sourceLanguageName(story.originalLocale, locale: locale) {
                Text("来源语言：\(language)")
                Text("·")
                    .accessibilityHidden(true)
            }
            Text("获取于 \(TodayFormatting.dateTime(story.fetchedAt, locale: locale))")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyrightLine(_ value: String) -> some View {
        Text("版权：\(value)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Copy

    static func reasonText(_ reason: StoryUnavailableReason) -> LocalizedStringKey {
        switch reason {
        case .notFetched: "尚未获取该地区的介绍。"
        case .notProvidedBySource: "该地区的来源没有提供介绍。"
        case .fetchFailed: "介绍获取失败，可稍后刷新重试。"
        case .emptyContent: "来源返回的介绍内容为空。"
        case .rateLimited: "来源暂时限制了介绍请求，请稍后再试。"
        case .malformedResponse: "介绍内容格式异常，已停止读取。"
        case .localeMismatch: "介绍语言与所选地区不一致，因此没有显示。"
        }
    }

}

// MARK: - Shared section header

struct SectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
