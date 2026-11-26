import DaybreakCore
import SwiftUI

// MARK: - Layout

enum TimelineLayout {
    /// A split is only useful when the window has room for a readable calendar
    /// plus a detail column. Landscape phones stay single-column even though
    /// their width can be large.
    static func isWide(_ size: CGSize) -> Bool {
        // Covers iPad windows and Duo unfolded windows while keeping a
        // landscape phone (large width, short height) single-column and
        // leaving at least 380 pt for the detail pane.
        size.width >= 760 && size.height >= 500
    }

    /// Width of the calendar/gallery column in the split layout. A fixed
    /// fraction with a minimum keeps the seven calendar columns readable and
    /// prevents the detail pane from squeezing the month grid off-screen.
    static func listColumnWidth(for totalWidth: CGFloat) -> CGFloat {
        let preferred = totalWidth * 0.52
        let maximumLeavingDetail = totalWidth - 380
        return min(max(preferred, 360), min(560, maximumLeavingDetail))
    }
}

// MARK: - Thumbnail

/// Decodes only cached local thumbnails (or downsamples a cached original) and
/// never triggers a network request.
struct TimelineThumbnailView: View {
    let wallpaperID: WallpaperID?
    var maxPixelSize: CGFloat = 240
    var showsPlaceholder = true

    @Environment(TimelineModel.self) private var model
    @State private var image: TimelineDecodedImage?
    @State private var displayedIdentity: String?
    @State private var loadedKey: String?
    @State private var loadGeneration = 0

    var body: some View {
        // `scaledToFill` returns a size larger than the proposal on the
        // overflowing axis. Sizing the view with `Color.clear` keeps its
        // footprint exactly at the proposed rectangle, so a wide thumbnail
        // cannot widen a grid cell or draw over its neighbours on Duo.
        Color.clear
            .overlay {
                if let image, displayedIdentity == identityID {
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if showsPlaceholder {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipped()
            .task(id: taskID) {
                await load()
            }
            .accessibilityHidden(true)
    }

    /// The wallpaper identity and requested size select which image belongs in
    /// this cell; the asset revision is tracked separately so an already
    /// displayed image stays on screen while a changed local file (for example
    /// a newly downloaded original) is decoded.
    private var identityID: String {
        "\(wallpaperID?.description ?? "none")-\(Int(maxPixelSize))"
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
        let decoded = await model.thumbnail(for: wallpaperID, maxPixelSize: maxPixelSize)
        // A newer identity or revision restarted this view. Only the newest
        // decode may publish state, otherwise a slow thumbnail can overwrite
        // the original that just became available.
        guard generation == loadGeneration, !Task.isCancelled else { return }
        image = decoded
        displayedIdentity = identity
        loadedKey = key
    }
}

// MARK: - Small labels

struct TimelineBadge: View {
    let text: Text
    var systemImage: String?
    var tint: Color = .secondary

    init(_ text: Text, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            text
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

// MARK: - Section picker

struct TimelineSectionPicker: View {
    @Environment(TimelineModel.self) private var model

    var body: some View {
        Picker(
            "浏览内容",
            selection: Binding(
                get: { model.section },
                set: { model.setSection($0) }
            )
        ) {
            Text("日历").tag(TimelineSection.calendar)
            Text("图库").tag(TimelineSection.gallery)
            Text("回顾").tag(TimelineSection.recap)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("浏览内容"))
    }
}

// MARK: - State views

struct TimelineStateCard: View {
    let systemImage: String
    let title: Text
    let message: Text
    var actionTitle: Text?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            title
                .font(.headline)
            message
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    actionTitle
                }
                .buttonStyle(.bordered)
                .tint(.daybreakActionTint)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

struct TimelineErrorBanner: View {
    let failure: TimelineFailure
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .padding(.horizontal, 16)
    }

    private var message: LocalizedStringKey {
        switch failure.kind {
        case .unsupportedMarket:
            return "这个地区不在可选的 Bing 地区中。"
        case .snapshotUnavailable:
            return "无法读取本地时光记录。已显示的内容不受影响，可以稍后重试。"
        case .assetUnavailable:
            return "图片未能下载或无法读取。已保留的元数据和介绍仍然可用。"
        case .favoriteFailed:
            return "收藏状态未能保存，请稍后重试。"
        case .dateNotAvailable:
            return "该日期晚于所选地区当前的来源日期，不能作为历史记录打开。"
        case .actionFailed:
            return "操作未能完成，请稍后重试。"
        }
    }
}

struct TimelineBannerView: View {
    let banner: TimelineBanner

    var body: some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
            }
            .accessibilityAddTraits(.isStaticText)
    }

    private var message: LocalizedStringKey {
        switch banner {
        case .favorited: return "已收藏"
        case .unfavorited: return "已取消收藏"
        case .originalReady: return "原图已缓存"
        case .assetUnavailable: return "原图未能获取"
        }
    }
}

// MARK: - Story copy

enum TimelineStoryCopy {
    static func unavailableReason(_ reason: StoryUnavailableReason) -> LocalizedStringKey {
        switch reason {
        case .notFetched:
            return "尚未获取这一天的介绍。"
        case .notProvidedBySource:
            return "该地区这一天的来源没有提供介绍正文。"
        case .fetchFailed:
            return "获取介绍失败；图片与版权信息仍然可用。"
        case .emptyContent:
            return "来源返回了空的介绍内容。"
        case .rateLimited:
            return "来源暂时限制了介绍请求，稍后可重试。"
        case .malformedResponse:
            return "介绍格式无法解析。"
        case .localeMismatch:
            return "来源语言与所选地区不一致，因此没有把这篇介绍挂到该地区。"
        }
    }
}

// MARK: - Formatting helpers

struct TimelineDateText {
    let locale: Locale
    let timeZone: TimeZone

    func month(_ key: TimelineMonthKey) -> Text {
        Text(verbatim: TimelinePresentation.monthTitle(key, locale: locale, timeZone: timeZone))
    }

    func year(_ year: Int) -> Text {
        Text(verbatim: TimelinePresentation.yearTitle(year, locale: locale, timeZone: timeZone))
    }

    func monthName(_ month: Int, year: Int) -> Text {
        Text(verbatim: TimelinePresentation.monthName(
            month: month,
            year: year,
            locale: locale,
            timeZone: timeZone
        ))
    }

    func full(_ date: LocalDate) -> Text {
        Text(verbatim: TimelinePresentation.fullDate(date, locale: locale, timeZone: timeZone))
    }

    func short(_ date: LocalDate) -> Text {
        Text(verbatim: TimelinePresentation.shortDate(date, locale: locale, timeZone: timeZone))
    }

    func fetched(_ instant: Date) -> Text {
        Text(verbatim: TimelinePresentation.fetchedAt(instant, locale: locale, timeZone: timeZone))
    }
}
