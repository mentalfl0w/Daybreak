import DaybreakCore
import SwiftUI

/// Full-width daily story panel.
///
/// The photograph is the primary surface; this panel is the single complete
/// reading row. Story copy is always shown verbatim with its source language
/// and fetch time. Missing or mismatched stories are explained instead of
/// being filled with text from another date, market or image.
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
            case .unmatched(let failure):
                unmatchedStory(failure)
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
            if let headline = story.headline, !headline.isEmpty {
                Text(verbatim: headline)
                    .font(.title3.weight(.semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let title = story.title, !title.isEmpty {
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
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
            }

            if let body = story.body, !body.isEmpty {
                Text(verbatim: body)
                    .font(.callout)
                    .lineSpacing(dynamicTypeSize.isAccessibilitySize ? 4 : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let copyright = story.copyright, !copyright.isEmpty {
                copyrightLine(copyright)
            }

            storyFooter(story)
        }
    }

    // MARK: Unavailable / unmatched

    private func unavailableStory(_ story: DailyStoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("该地区暂无可用介绍", systemImage: "text.badge.xmark")
                .font(.callout.weight(.semibold))

            if case .unavailable(let reason) = story.availability {
                Text(Self.reasonText(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let headline = story.headline, !headline.isEmpty {
                Text(verbatim: headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let copyright = story.copyright, !copyright.isEmpty {
                copyrightLine(copyright)
            }

            if let url = story.sourceURL {
                Link("查看来源页面", destination: url)
                    .tint(.daybreakActionTint)
                    .font(.caption)
            }

            storyFooter(story, showSourceLink: false)
        }
    }

    private func unmatchedStory(_ failure: StoryMatchFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("暂无可显示的介绍", systemImage: "text.badge.xmark")
                .font(.callout.weight(.semibold))

            Text(Self.failureText(failure))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("介绍缺失不会影响图片浏览；Daybreak 不会用其他日期或地区的文本补齐。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyStory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("尚未获取今日介绍", systemImage: "text.badge.xmark")
                .font(.callout.weight(.semibold))
            Text("刷新后会重新尝试获取该地区当天的来源介绍。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Shared footer

    @ViewBuilder
    private func storyFooter(_ story: DailyStoryRecord, showSourceLink: Bool = true) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if showSourceLink, let url = story.sourceURL {
                    Link("查看原文", destination: url)
                        .tint(.daybreakActionTint)
                        .font(.caption)
                }
                Spacer(minLength: 8)
                provenance(story)
            }
            VStack(alignment: .leading, spacing: 5) {
                if showSourceLink, let url = story.sourceURL {
                    Link("查看原文", destination: url)
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

    static func failureText(_ failure: StoryMatchFailure) -> LocalizedStringKey {
        switch failure {
        case .noCandidate:
            "该地区当天没有可匹配的介绍记录。"
        case .imageIdentityMissing(let count):
            "当天有 \(count) 条介绍，但无法确认它属于这张图片，已隐藏。"
        case .dateMismatch, .marketMismatch:
            "当天记录属于其他日期或地区，已隐藏。"
        case .imageIdentityConflict:
            "介绍关联到另一张图片，已隐藏。"
        case .ambiguousCandidates(let count):
            "当天有 \(count) 条介绍内容存在冲突，已隐藏。"
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
