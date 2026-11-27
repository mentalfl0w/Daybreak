import DaybreakCore
import SwiftUI

struct TimelineGalleryView: View {
    let isWide: Bool
    let onOpenItem: (TimelineGalleryItem) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.galleryItems.isEmpty {
                    emptyState
                } else {
                    grid
                    if model.galleryScope == .favorites, model.undatedFavoriteCount > 0 {
                        undatedNote
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .refreshable {
            await model.refresh()
        }
        .wideShellTabBarInset()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "图库范围",
                selection: Binding(
                    get: { model.galleryScope },
                    set: { model.setGalleryScope($0) }
                )
            ) {
                Text("全部").tag(TimelineGalleryScope.all)
                Text("收藏").tag(TimelineGalleryScope.favorites)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("图库范围"))

            HStack(spacing: 8) {
                Text(countText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if model.galleryScope == .favorites {
                    Button {
                        model.setRecapScope(.favorites)
                        model.setSection(.recap)
                    } label: {
                        Label("收藏回顾", systemImage: "heart.text.square")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var countText: LocalizedStringKey {
        switch model.galleryScope {
        case .all:
            return "当前地区 · 所有年份 · \(model.galleryItems.count) 次出现"
        case .favorites:
            return "\(model.galleryItems.count) 张收藏图片"
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: isWide ? 116 : 104, maximum: 220), spacing: 10)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(model.galleryItems) { item in
                TimelineGalleryCell(
                    item: item,
                    showsMarket: model.galleryScope == .favorites,
                    onOpen: {
                        onOpenItem(item)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: model.galleryScope == .favorites ? "heart" : "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(model.galleryScope == .favorites ? "还没有收藏" : "没有图库记录")
                .font(.headline)
            Text(
                model.galleryScope == .favorites
                    ? "在今日或图片详情中收藏图片后，会在这里按图片去重显示。"
                    : "本机还没有保存这个地区的壁纸。联网刷新今日页后再回来查看。"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var undatedNote: some View {
        Text("另有 \(model.undatedFavoriteCount) 张收藏没有本地日期记录，可在收藏回顾中查看。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TimelineGalleryCell: View {
    let item: TimelineGalleryItem
    let showsMarket: Bool
    let onOpen: () -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                artwork

                TimelineDateText(locale: locale, timeZone: model.timeZone)
                    .short(item.date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(item.title ?? MobileLocalizedString.resolve("未保存标题", locale: locale))
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(item.title == nil ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(Text("打开图片与介绍"))
        .accessibilityIdentifier("timeline.gallery.\(item.date.iso8601).\(item.market.rawValue)")
    }

    /// The grid column proposes the cell width, so `Color.clear` fixes the
    /// artwork to that width before the 3:2 ratio derives its height. Badges
    /// and the decoded thumbnail are then clipped to the same rectangle: a
    /// `scaledToFill` image wider than its 3:2 slot can no longer bleed into
    /// the grid gutter and visually join the neighbouring card on Duo.
    private var artwork: some View {
        Color.clear
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
            }
            .overlay {
                TimelineThumbnailView(
                    wallpaperID: item.wallpaperID,
                    maxPixelSize: 320,
                    showsPlaceholder: false
                )
            }
            .overlay {
                if !item.hasThumbnail && !item.hasOriginal {
                    VStack(spacing: 3) {
                        Image(systemName: "icloud.slash")
                            .font(.caption)
                        Text("未缓存")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isFavorite(item.wallpaperID) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.pink))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsMarket {
                    Text(verbatim: TimelinePresentation.marketShortName(
                        for: item.market,
                        in: locale
                    ))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(.black.opacity(0.55)))
                    .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.hasOriginal {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var accessibilityLabel: String {
        let date = TimelinePresentation.fullDate(
            item.date,
            locale: locale,
            timeZone: model.timeZone
        )
        let title = item.title ?? MobileLocalizedString.resolve("未保存标题", locale: locale)
        if showsMarket {
            let market = TimelinePresentation.marketName(for: item.market, in: locale)
            return "\(date)，\(market)，\(title)"
        }
        return "\(date)，\(title)"
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if model.isFavorite(item.wallpaperID) {
            parts.append(MobileLocalizedString.resolve("已收藏", locale: locale))
        }
        parts.append(
            item.hasThumbnail
                ? MobileLocalizedString.resolve("缩略图已缓存", locale: locale)
                : MobileLocalizedString.resolve("缩略图未缓存", locale: locale)
        )
        if item.hasOriginal {
            parts.append(MobileLocalizedString.resolve("原图已缓存", locale: locale))
        }
        if item.hasAvailableStory {
            parts.append(MobileLocalizedString.resolve("介绍可用", locale: locale))
        }
        return parts.joined(separator: MobileLocalizedString.resolve("，", locale: locale))
    }
}
