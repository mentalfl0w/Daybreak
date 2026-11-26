import AppKit
import DaybreakCore
import SwiftUI

/// Storage and cache-protection management for the shared local repository.
///
/// Every destructive control routes through `RecapScreenModel` and requires a
/// confirmation. Bulk cleanup uses the repository's LRU/protection rules, so
/// favorites, pinned dates and currently applied images are never victims.
///
/// The view is the content of Settings → Storage. Settings owns the page
/// header; this view owns reload, feedback, cleanup and the paginated asset
/// list. Its content column matches the Settings form column so the tab reads
/// like the other settings pages. The cached-file list is paginated over the
/// model's stable order rather than rendering every row.
///
/// `AppShell` supplies the main window's frosted backdrop, so panels here keep
/// opaque semantic fills and text never sits on two stacked blurs.
struct StorageView: View {
    let model: RecapScreenModel
    @Environment(\.locale) private var locale

    @State private var assetPageIndex = 0

    /// Scroll target used to bring a newly selected page's rows into view.
    private static let assetsAnchorID = "storage.cached-assets"

    init(model: RecapScreenModel) {
        self.model = model
    }

    var body: some View {
        pageBody
            .onAppear {
                Task { await model.reload() }
            }
            .alert(
                model.pendingCleanup?.title ?? MacLocalizedString.resolve("确认操作", locale: WallpaperInterfaceLocale.current),
                isPresented: pendingBinding,
                presenting: model.pendingCleanup
            ) { action in
                Button("取消", role: .cancel) {
                    model.cancelPendingCleanup()
                }
                Button(role: .destructive) {
                    Task { await model.confirmPendingCleanup(action) }
                } label: {
                    Text(action.confirmLabel)
                }
            } message: { action in
                Text(action.message)
            }
    }

    /// Feedback banners stay above the scrolling content so a cleanup result or
    /// load error remains visible while the user reviews cache rows.
    private var pageBody: some View {
        VStack(spacing: 0) {
            if let message = model.actionMessage {
                feedbackBanner(message, systemImage: "checkmark.circle", tint: .green)
                Divider()
            }
            if let error = model.actionError {
                feedbackBanner(error, systemImage: "xmark.octagon", tint: .red)
                Divider()
            }
            if let loadError = model.loadError {
                loadErrorBanner(loadError)
                Divider()
            }
            content
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { model.pendingCleanup != nil },
            set: { newValue in
                if !newValue { model.cancelPendingCleanup() }
            }
        )
    }

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    usageSection
                    protectionSection
                    cleanupSection
                    assetsSection
                        .id(Self.assetsAnchorID)
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Page controls live at the bottom of the list. Without this the
            // new page's rows would render above a viewport that stayed parked
            // at the footer.
            .onChange(of: assetPageIndex) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(Self.assetsAnchorID, anchor: .top)
                }
            }
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                sectionHeader(
                    title: "本地缓存",
                    systemImage: "internaldrive",
                    subtitle: "按缓存记录统计缩略图与原图的占用；图片信息与介绍不计入其中。"
                )

                Spacer(minLength: 12)

                if model.isLoading || model.isPerformingAction {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在读取本地缓存…")
                }

                Button {
                    Task { await model.reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isLoading)
                .help("重新读取缓存用量与保护状态")
                .accessibilityLabel("刷新存储状态")
            }

            if let usage = model.storageUsage {
                panel {
                    usageBody(usage)
                }
            } else if model.isLoading {
                panel {
                    inlineStatus("正在读取缓存用量…")
                }
            } else {
                panel {
                    inlineNotice(
                        systemImage: "internaldrive",
                        title: "尚未读取缓存用量",
                        message: "刷新后会显示本机图片缓存的占用与保护状态。"
                    )
                }
            }
        }
    }

    private func usageBody(_ usage: StorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(StatusFormatter.bytes(usage.totalAssetBytes))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()

                Text("缩略图 + 原图")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(usage.assetCount) 个缓存文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if usage.missingAssetCount > 0 {
                        Label(
                            "\(usage.missingAssetCount) 个缺少文件",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else if usage.assetCount > 0 {
                        Text("未发现缺失文件")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if usage.totalAssetBytes > 0 {
                compositionBar(usage)
            } else {
                Text("还没有可统计的图片缓存。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if usage.assetCount > 0 {
                Divider()

                HStack(alignment: .top, spacing: 24) {
                    capacityMeter(
                        label: "缩略图容量",
                        bytes: usage.thumbnailBytes,
                        limit: RecapScreenModel.defaultCacheLimits.thumbnailBytes
                    )
                    capacityMeter(
                        label: "原图容量",
                        bytes: usage.originalBytes,
                        limit: RecapScreenModel.defaultCacheLimits.originalBytes
                    )
                }
            }

            Text("容量条只对照内置默认上限；收藏、固定日期与当前壁纸不会被清理。记录仍在但文件已缺失的项目，仍可能计入占用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("缓存位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AppModel.repositoryDirectory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                Button("在 Finder 中显示") {
                    revealCacheFolder()
                }
                .controlSize(.small)
            }
        }
    }

    /// Opens the repository in Finder. The repository directory may not exist
    /// before the first successful fetch, so fall back to its parent instead of
    /// leaving the button inert.
    private func revealCacheFolder() {
        let directory = AppModel.repositoryDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
            return
        }

        let parent = directory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            _ = NSWorkspace.shared.open(parent)
        }
    }

    private func compositionBar(_ usage: StorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let trackWidth = max(0, proxy.size.width - 2)
                let total = max(1, usage.totalAssetBytes)
                let thumbnailWidth = trackWidth * CGFloat(usage.thumbnailBytes) / CGFloat(total)
                let originalWidth = max(0, trackWidth - thumbnailWidth)

                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.34))
                        .frame(width: thumbnailWidth, height: 8)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: originalWidth, height: 8)
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("图片缓存构成")
            .accessibilityValue(
                "缩略图 \(StatusFormatter.bytes(usage.thumbnailBytes))，原图 \(StatusFormatter.bytes(usage.originalBytes))"
            )

            HStack(spacing: 16) {
                legend(
                    color: Color.accentColor.opacity(0.34),
                    title: "缩略图",
                    bytes: usage.thumbnailBytes
                )
                legend(
                    color: Color.accentColor,
                    title: "原图",
                    bytes: usage.originalBytes
                )
                Spacer(minLength: 0)
            }
        }
    }

    private func legend(color: Color, title: LocalizedStringKey, bytes: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            Text(StatusFormatter.bytes(bytes))
                .monospacedDigit()
        }
        .font(.caption2)
    }

    private func capacityMeter(label: LocalizedStringKey, bytes: Int, limit: Int) -> some View {
        let isOverLimit = limit > 0 && bytes > limit
        let ratio = limit > 0 ? min(1, Double(bytes) / Double(limit)) : 0
        let percent = limit > 0
            ? Int((Double(bytes) / Double(limit) * 100).rounded())
            : nil

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(verbatim: "\(StatusFormatter.bytes(bytes)) / \(StatusFormatter.bytes(limit))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isOverLimit ? Color.orange : Color.secondary)
            }

            ProgressView(value: ratio)
                .progressViewStyle(.linear)
                .tint(isOverLimit ? Color.orange : Color.accentColor)

            if let percent {
                let formattedPercent = (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
                Text(
                    isOverLimit
                        ? String(format: MacLocalizedString.resolve("超出内置上限（%@）", locale: WallpaperInterfaceLocale.current), formattedPercent)
                        : String(format: MacLocalizedString.resolve("已用 %@", locale: WallpaperInterfaceLocale.current), formattedPercent)
                )
                .font(.caption2)
                .foregroundStyle(isOverLimit ? Color.orange : Color.secondary)
                .monospacedDigit()
            } else {
                Text(verbatim: "—")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Protection

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "受保护内容",
                systemImage: "lock.shield",
                subtitle: "收藏、固定日期与当前可访问桌面的壁纸不会被自动清理；正在写入的原图也会暂时保留。历史应用图片按普通 LRU 上限淘汰。"
            )

            if model.storageUsage == nil && model.isLoading {
                panel {
                    inlineStatus("正在读取保护状态…")
                }
            } else {
                panel {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 0) {
                            protectionFigure(
                                systemImage: "star.fill",
                                title: "收藏图片",
                                value: "\(model.favoriteImageCount)",
                                unit: "张",
                                detail: "不会被自动清理"
                            )
                            protectionDivider
                            protectionFigure(
                                systemImage: "pin.fill",
                                title: "固定日期",
                                value: "\(model.pinnedDateCount)",
                                unit: "个",
                                detail: "其图片保持保护"
                            )
                            protectionDivider
                            protectionFigure(
                                systemImage: "display",
                                title: "当前壁纸",
                                value: "\(model.currentAppliedImageCount)",
                                unit: "张",
                                detail: "当前可访问桌面正在使用"
                            )
                        }

                        Text("当前壁纸数量来自系统可读取的已连接显示器；未激活 Space 的历史图片不因此永久保留，会按内置上限自动淘汰。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func protectionFigure(
        systemImage: String,
        title: LocalizedStringKey,
        value: String,
        unit: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var protectionDivider: some View {
        Divider()
            .frame(height: 64)
            .padding(.horizontal, 16)
    }

    // MARK: Cleanup actions

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "清理与修复",
                systemImage: "trash",
                subtitle: "内容刷新、下载原图或启动后，会按内置上限自动清理最久未使用的缓存；每个手动操作仍会先确认。受保护图片不会被删除。"
            )

            panel {
                VStack(spacing: 0) {
                    cleanupRow(
                        title: "清理未受保护缩略图",
                        detail: "只删除未被收藏、固定或当前正在使用的缩略图；原图与介绍保留。",
                        systemImage: "photo.on.rectangle",
                        buttonTitle: "清理缩略图",
                        action: .clearUnprotectedThumbnails
                    )
                    Divider().padding(.vertical, 14)
                    cleanupRow(
                        title: "清理未受保护原图",
                        detail: "只删除未受保护的原图；需要时可在联网后重新下载。",
                        systemImage: "photo",
                        buttonTitle: "清理原图",
                        action: .clearUnprotectedOriginals
                    )
                    Divider().padding(.vertical, 14)
                    cleanupRow(
                        title: "按内置上限清理",
                        detail: "按缩略图 \(StatusFormatter.bytes(RecapScreenModel.defaultCacheLimits.thumbnailBytes))、原图 \(StatusFormatter.bytes(RecapScreenModel.defaultCacheLimits.originalBytes)) 清理最久未使用的缓存。",
                        systemImage: "speedometer",
                        buttonTitle: "按上限清理",
                        action: .applyDefaultLimits
                    )
                    Divider().padding(.vertical, 14)
                    cleanupRow(
                        title: "清除介绍文本",
                        detail: "只删除已缓存的每日介绍；图片、图片信息与收藏不受影响。",
                        systemImage: "text.book.closed",
                        buttonTitle: "清除介绍",
                        action: .clearStories
                    )
                    Divider().padding(.vertical, 14)
                    cleanupRow(
                        title: "修复本地缓存",
                        detail: "移除缓存中没有任何记录引用的残留文件，并检查记录中缺失的文件；不会删除图片信息或收藏。",
                        systemImage: "wrench.and.screwdriver",
                        buttonTitle: "修复缓存",
                        action: .repairIndex
                    )
                }
            }
        }
    }

    private func cleanupRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String,
        buttonTitle: LocalizedStringKey,
        action: RecapCleanupAction
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Color(nsColor: .quaternaryLabelColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                model.requestCleanup(action)
            } label: {
                Text(buttonTitle)
                    .frame(minWidth: 82)
            }
            .buttonStyle(.bordered)
            .disabled(model.isPerformingAction || model.isLoading)
        }
    }

    // MARK: Assets

    private var assetsSection: some View {
        let pagination = assetPagination
        // `cachedAssets` already has the model's deterministic order
        // (originals first, newest access, stable identifier tie-break).
        // Paginate that order without re-sorting, so a page never reshuffles.
        let pageRows = Array(model.cachedAssets[pagination.range])

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "已缓存文件",
                systemImage: "photo.stack",
                subtitle: "按类型与最近访问时间排列；受保护文件不能在这里单独删除。"
            )

            if model.cachedAssets.isEmpty {
                if model.isLoading {
                    panel {
                        inlineStatus("正在读取缓存文件…")
                    }
                } else {
                    panel {
                        inlineNotice(
                            systemImage: "photo.stack",
                            title: "还没有缓存图片",
                            message: "图片信息与介绍可能仍保存在本机，但不在此列表中。"
                        )
                    }
                }
            } else {
                panel {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("共 \(model.cachedAssets.count) 个缓存文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        ForEach([AssetKind.original, AssetKind.thumbnail], id: \.self) { kind in
                            let rows = pageRows.filter { $0.asset.kind == kind }
                            if !rows.isEmpty {
                                assetGroup(kind: kind, rows: rows)
                            }
                        }

                        if pagination.pageCount > 1 {
                            Divider()
                            assetPaginationFooter(pagination)
                        }
                    }
                }
            }
        }
        // Deleting the final row on the last page, or a refresh that shrinks
        // the index, must never strand the view on an empty page.
        .onChange(of: model.cachedAssets.count) { _, newCount in
            clampAssetPage(totalCount: newCount)
        }
    }

    private var assetPagination: StoragePagination {
        StoragePagination(
            totalCount: model.cachedAssets.count,
            pageSize: StoragePagination.defaultPageSize,
            requestedPageIndex: assetPageIndex
        )
    }

    private func assetPaginationFooter(_ pagination: StoragePagination) -> some View {
        HStack(spacing: 10) {
            Button {
                showPreviousAssetPage()
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!pagination.canGoPrevious)

            Text("第 \(pagination.pageIndex + 1) 页，共 \(pagination.pageCount) 页")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                showNextAssetPage()
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!pagination.canGoNext)

            Spacer(minLength: 12)

            Text("本页 \(pagination.range.count) 个")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .contain)
    }

    private func showPreviousAssetPage() {
        let pagination = assetPagination
        guard pagination.canGoPrevious else { return }
        assetPageIndex = pagination.pageIndex - 1
    }

    private func showNextAssetPage() {
        let pagination = assetPagination
        guard pagination.canGoNext else { return }
        assetPageIndex = pagination.pageIndex + 1
    }

    private func clampAssetPage(totalCount: Int) {
        let pagination = StoragePagination(
            totalCount: totalCount,
            pageSize: StoragePagination.defaultPageSize,
            requestedPageIndex: assetPageIndex
        )
        guard pagination.pageCount > 0 else {
            assetPageIndex = 0
            return
        }
        if assetPageIndex != pagination.pageIndex {
            assetPageIndex = pagination.pageIndex
        }
    }

    private func assetGroup(kind: AssetKind, rows: [RecapAssetRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label(
                    RecapCopy.assetKindLabel(kind),
                    systemImage: kind == .original ? "photo" : "photo.on.rectangle"
                )
                .font(.subheadline.weight(.semibold))
                Text("本页 \(rows.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.bottom, 4)

            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    assetRow(row)
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, 84)
                    }
                }
            }
        }
    }

    private func assetRow(_ row: RecapAssetRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RecapThumbnail(
                url: model.thumbnailURL(for: row.asset.wallpaperID),
                model: model,
                maxPixelSize: 180,
                cornerRadius: 7
            )
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(width: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(row.asset.wallpaperID.description)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(RecapCopy.assetKindLabel(row.asset.kind))
                    Text(StatusFormatter.bytes(row.asset.byteCount))
                        .monospacedDigit()
                    Spacer(minLength: 6)
                    Text(StatusFormatter.dateTime(row.asset.lastAccessedAt, locale: locale))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if row.isProtected {
                        Label(row.protectionLabel, systemImage: "lock.fill")
                            .lineLimit(1)
                            .help(row.protectionLabel)
                    } else {
                        Label("可清理", systemImage: "checkmark.circle")
                    }
                    if row.isMissing {
                        Label("文件缺失", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button("删除", role: .destructive) {
                model.requestCleanup(
                    .removeAsset(kind: row.asset.kind, wallpaperID: row.asset.wallpaperID)
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(row.isProtected || model.isPerformingAction || model.isLoading)
            .help(
                row.isProtected
                    ? MacLocalizedString.resolve("受保护图片不能被单独删除", locale: WallpaperInterfaceLocale.current)
                    : MacLocalizedString.resolve("删除这份缓存文件（需要确认）", locale: WallpaperInterfaceLocale.current)
            )
        }
        .padding(.vertical, 10)
    }

    // MARK: Shared pieces

    private func sectionHeader(
        title: LocalizedStringKey,
        systemImage: String,
        subtitle: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func panel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    private func inlineStatus(_ message: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func inlineNotice(
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("重试") {
                Task { await model.reload() }
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Color.orange.opacity(0.12)
            }
        }
    }

    private func feedbackBanner(
        _ message: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("关闭") {
                model.dismissActionFeedback()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                tint.opacity(0.10)
            }
        }
    }
}

/// Pure page arithmetic for the cached-asset list.
///
/// The list order comes from `RecapScreenModel` (originals first, then newest
/// `lastAccessedAt`, with the asset identifier as the final tie-breaker), so a
/// page is always the same slice for the same snapshot. The requested page is
/// clamped instead of reset, which lets the view recover when a deletion or a
/// refresh shrinks the list under the current page.
struct StoragePagination: Equatable, Sendable {
    static let defaultPageSize = 20

    let totalCount: Int
    let pageSize: Int
    let requestedPageIndex: Int

    init(
        totalCount: Int,
        pageSize: Int = StoragePagination.defaultPageSize,
        requestedPageIndex: Int = 0
    ) {
        self.totalCount = max(0, totalCount)
        self.pageSize = max(1, pageSize)
        self.requestedPageIndex = requestedPageIndex
    }

    var pageCount: Int {
        guard totalCount > 0 else { return 0 }
        return (totalCount - 1) / pageSize + 1
    }

    var pageIndex: Int {
        guard pageCount > 0 else { return 0 }
        return min(max(requestedPageIndex, 0), pageCount - 1)
    }

    var range: Range<Int> {
        guard pageCount > 0 else { return 0..<0 }
        let lowerBound = pageIndex * pageSize
        return lowerBound..<min(totalCount, lowerBound + pageSize)
    }

    var canGoPrevious: Bool { pageIndex > 0 }
    var canGoNext: Bool { pageIndex + 1 < pageCount }
}
