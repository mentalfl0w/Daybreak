import SwiftUI
import UIKit

/// The primary photograph surface.
///
/// On compact widths the photograph is the first screen and the source strip
/// sits directly under it. On expanded widths the same view is placed beside a
/// readable story column by `TodayScreen`; it never assumes a device class.
@MainActor
struct TodayHeroView: View {
    let content: TodayDisplayContent
    let height: CGFloat
    let image: UIImage?
    let isLoadingImage: Bool
    let onRequestImage: () -> Void
    let onShowStatus: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            photo
            sourceStrip
        }
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: Photograph

    private var photo: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .accessibilityLabel(accessibilityLabel)
                } else {
                    placeholder
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button(action: onShowStatus) {
                    TodayStatusBadge(availability: content.imageAvailability)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .padding(.trailing, 2)
                .accessibilityLabel("图片状态：\(statusAccessibilityText)")
                .accessibilityHint("显示获取、缓存与来源详情")
            }
        }
        .frame(height: max(220, height))
    }

    private var placeholder: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)

            VStack(spacing: 10) {
                if isLoadingImage {
                    ProgressView()
                        .accessibilityLabel("正在载入图片")
                    Text("正在载入图片…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("图片未缓存")
                        .font(.callout.weight(.semibold))
                    Text(verbatim: resolvedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 24)
                    Button(action: onRequestImage) {
                        Label("下载图片", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
                }
            }
            .padding(24)
        }
    }

    // MARK: Source strip

    private var sourceStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: resolvedTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let copyright = content.copyright, !copyright.isEmpty {
                    Text(verbatim: copyright)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    dateBlock
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    marketLabel
                    Spacer(minLength: 8)
                    imageStateLabel
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        dateBlock
                        Text("·")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        marketLabel
                    }
                    imageStateLabel
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var dateBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: TodayFormatting.sourceDate(content.sourceDate, locale: locale))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(content.isSourceDateToday ? "今日来源" : "最新来源日期")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var marketLabel: some View {
        Text(verbatim: TodayFormatting.marketName(content.market, locale: locale))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("内容地区：\(TodayFormatting.marketName(content.market, locale: locale))"))
    }

    private var imageStateLabel: some View {
        Label {
            switch content.imageAvailability {
            case .original: Text("原图已缓存")
            case .thumbnail: Text("预览图已缓存")
            case .missing: Text("图片未缓存")
            }
        } icon: {
            Image(systemName: content.imageAvailability == .missing ? "circle.dashed" : "checkmark.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusAccessibilityText: String {
        switch content.imageAvailability {
        case .original: MobileLocalizedString.resolve("原图已缓存", locale: locale)
        case .thumbnail: MobileLocalizedString.resolve("预览图已缓存", locale: locale)
        case .missing: MobileLocalizedString.resolve("图片未缓存", locale: locale)
        }
    }

    private var resolvedTitle: String {
        content.title ?? MobileLocalizedString.resolve("来源未提供标题", locale: locale)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(MobileLocalizedString.resolve("今日图片", locale: locale))
        parts.append(resolvedTitle)
        if let copyright = content.copyright, !copyright.isEmpty {
            parts.append(copyright)
        }
        parts.append(TodayFormatting.sourceDate(content.sourceDate, locale: locale))
        parts.append(TodayFormatting.marketName(content.market, locale: locale))
        switch content.imageAvailability {
        case .original: parts.append(MobileLocalizedString.resolve("原图", locale: locale))
        case .thumbnail: parts.append(MobileLocalizedString.resolve("预览图", locale: locale))
        case .missing: parts.append(MobileLocalizedString.resolve("图片未缓存", locale: locale))
        }
        return TodayFormatting.list(parts, locale: locale)
    }
}

// MARK: - Status badge

/// Floating availability badge on the photograph. It is informational; the
/// screen's status button opens the complete fetch/cache receipt.
struct TodayStatusBadge: View {
    let availability: TodayImageAvailability
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            label
                .foregroundStyle(.white)
                .background(.black.opacity(0.72), in: Capsule())
        } else {
            label
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.black.opacity(0.34)), in: Capsule())
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption2.weight(.semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .opacity(0.85)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var color: Color {
        switch availability {
        case .original: .green
        case .thumbnail: .yellow
        case .missing: .gray
        }
    }

    private var title: LocalizedStringKey {
        switch availability {
        case .original: "原图"
        case .thumbnail: "预览图"
        case .missing: "图片未缓存"
        }
    }
}
