import SwiftUI

/// Wallpaper actions attached to the photograph's source strip.
///
/// Preview, share and export live in the full-screen preview; the system set
/// flow is the Shortcuts guide owned by the intents module. Today never claims
/// that the app itself changed the system wallpaper.
@MainActor
struct TodayActionsView: View {
    let content: TodayDisplayContent
    let isPreparingPreview: Bool
    let isDownloadingOriginal: Bool
    let onToggleFavorite: () -> Void
    let onPreview: () -> Void
    let onRequestOriginal: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        favoriteButton
                        previewButton
                        DaybreakSetWallpaperButton(wallpaperID: content.wallpaperID, occurrenceKey: content.key)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if content.imageAvailability != .original {
                            originalButton
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            favoriteButton
                            previewButton
                        }
                        HStack(spacing: 10) {
                            DaybreakSetWallpaperButton(wallpaperID: content.wallpaperID, occurrenceKey: content.key)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if content.imageAvailability != .original {
                                originalButton
                            }
                        }
                    }
                }
            }

            if content.imageAvailability == .thumbnail {
                Text("当前仅缓存了预览图；预览或分享时会先尝试获取原图，失败时只能使用预览分辨率。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if content.imageAvailability == .missing {
                Text("图片尚未缓存；可以刷新获取，或稍后联网重试。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            favoriteButton
                .frame(maxWidth: .infinity, alignment: .leading)
            previewButton
                .frame(maxWidth: .infinity, alignment: .leading)
            DaybreakSetWallpaperButton(wallpaperID: content.wallpaperID, occurrenceKey: content.key)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if content.imageAvailability != .original {
                originalButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Label {
                content.isFavorite ? Text("已收藏") : Text("收藏")
            } icon: {
                Image(systemName: content.isFavorite ? "heart.fill" : "heart")
            }
        }
        .buttonStyle(.bordered)
        .tint(content.isFavorite ? Color.pink : Color.daybreakActionTint)
        .accessibilityLabel(content.isFavorite ? Text("取消收藏") : Text("收藏今日图片"))
    }

    private var previewButton: some View {
        Button(action: onPreview) {
            if isPreparingPreview || isDownloadingOriginal {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(isPreparingPreview ? "准备预览…" : "正在准备原图…")
                }
            } else {
                Label("预览与分享", systemImage: "rectangle.expand.vertical")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isPreparingPreview || isDownloadingOriginal || content.imageAvailability == .missing)
        .accessibilityHint("打开全屏预览，可裁切、保存和分享")
    }

    private var originalButton: some View {
        Button(action: onRequestOriginal) {
            if isDownloadingOriginal {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("正在下载原图…")
                }
            } else {
                Label("下载原图", systemImage: "arrow.down.circle")
            }
        }
        .buttonStyle(.bordered)
        .tint(.daybreakActionTint)
        .disabled(isDownloadingOriginal)
    }
}
