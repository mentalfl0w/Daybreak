import DaybreakCore
import SwiftUI
import UIKit

/// Picture-first Today screen for iPhone, Duo and iPad.
///
/// The screen adapts to the window's available width, not to a device name or
/// orientation: the photograph remains prominent, while its information and
/// actions rearrange above a separate reading column. It never keeps
/// a second content store; every value comes from the process-wide
/// `MobileStore`, and only transient presentation state (scrolled layout,
/// status sheet, loaded image) belongs to this scene. The crop/export preview
/// is presented by the window shell so it survives a compact/wide swap; this
/// screen only prepares its request.
@MainActor
struct TodayScreen: View {
    let store: MobileStore
    let navigation: MobileNavigationState
    @Binding private var previewPresentation: WallpaperPreviewPresentation?

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewportSize: CGSize = .zero
    @State private var didStart = false
    @State private var heroImage: UIImage?
    @State private var heroImageKey: OccurrenceKey?
    @State private var isLoadingHeroImage = false
    @State private var imageGeneration = 0
    @State private var isShowingStatus = false
    @State private var isPreparingPreview = false
    @State private var previewPreparationTask: Task<Void, Never>?
    @State private var previewAlert: PreviewAlert?

    init(
        store: MobileStore,
        navigation: MobileNavigationState,
        previewPresentation: Binding<WallpaperPreviewPresentation?>
    ) {
        self.store = store
        self.navigation = navigation
        _previewPresentation = previewPresentation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let content = store.todayDisplayContent {
                        contentLayout(content)
                    } else {
                        unavailableContent
                    }
                }
                .frame(maxWidth: 1180, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                viewportSize = size
            }
            .refreshable {
                await store.refreshToday()
            }
            .wideShellTabBarInset()
            .background {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea(edges: .top)
            }
            // The screen title is always the navigation title, never a custom
            // toolbar item: the system owns it, so it cannot be collected into
            // the bar's overflow ("more") menu. Wide windows only change how
            // the same title is laid out.
            .navigationTitle("今日", locale: locale)
            // Wide windows ask for the system's inline-large title: the large
            // title is drawn inside the bar, on the row with the trailing
            // actions, and takes no separate large-title band or content
            // height. Compact windows keep the native large title above the
            // scrolling content.
            .toolbarTitleDisplayMode(usesInlineLargeTitle ? .inlineLarge : .large)
            .toolbar { screenToolbar }
            .task {
                await store.start()
                didStart = true
            }
            .task(id: imageTaskIdentity) {
                await loadHeroImage()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await store.refreshIfNeeded() }
            }
            .onDisappear {
                previewPreparationTask?.cancel()
            }
            .sheet(isPresented: $isShowingStatus) {
                TodayStatusSheet(store: store)
            }
            .alert(item: $previewAlert) { alert in
                switch alert {
                case .originalUnavailable(let request):
                    return Alert(
                        title: Text("原图未能下载"),
                        message: Text("当前只能使用已缓存的预览图，导出的文件不会是原图。联网后可重新尝试下载原图。"),
                        primaryButton: .cancel(Text("取消")),
                        secondaryButton: .default(Text("仍要预览")) {
                            presentPreview(request)
                        }
                    )
                case .failed(let message):
                    return Alert(
                        title: Text("无法打开预览"),
                        message: Text(verbatim: message),
                        dismissButton: .default(Text("好"))
                    )
                }
            }
        }
    }

    // MARK: Toolbar

    /// Wide windows use the system's inline-large title, which renders the
    /// navigation title inside the bar on the same row as the trailing
    /// actions. Compact windows keep the native large title. The threshold is
    /// the layout width at which source details and actions can share a row.
    ///
    /// This only selects a title display mode. The title itself stays the
    /// navigation title, so the system never has to move a text item into the
    /// bar's overflow menu to make room for the actions.
    private var usesInlineLargeTitle: Bool {
        !dynamicTypeSize.isAccessibilitySize && viewportSize.width >= 760
    }

    @ToolbarContentBuilder
    private var screenToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                isShowingStatus = true
            } label: {
                Label(
                    "状态",
                    systemImage: store.lastErrorMessage == nil && store.todayRefreshWarnings.isEmpty
                        ? "info.circle" : "exclamationmark.circle"
                )
            }
            .disabled(store.today == nil)
            .accessibilityHint(
                store.lastErrorMessage == nil && store.todayRefreshWarnings.isEmpty
                    ? Text("显示今日图片的获取、缓存与来源详情")
                    : Text("更新需要留意，打开状态查看详情")
            )

            Button {
                Task { await store.refreshToday() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在刷新")
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityHint("重新获取所选地区的今日图片与来源介绍")
        }
    }

    // MARK: Layout

    private enum LayoutMode {
        case compact
        case intermediate
        case expanded
    }

    private var layoutMode: LayoutMode {
        guard !dynamicTypeSize.isAccessibilitySize else { return .compact }
        if contentWidth < 620 { return .compact }
        if contentWidth >= 920 && viewportSize.width > viewportSize.height * 1.15 {
            return .expanded
        }
        return .intermediate
    }

    private var horizontalPadding: CGFloat { 20 }

    private var contentWidth: CGFloat {
        min(max(viewportSize.width - horizontalPadding * 2, 280), 1180)
    }

    private var photoWidth: CGFloat { contentWidth }

    private var heroHeight: CGFloat {
        switch layoutMode {
        case .compact:
            return min(max(photoWidth * 0.86, 280), 560)
        case .intermediate:
            let availableHeight = max(320, min(560, viewportSize.height * 0.7))
            return min(max(photoWidth * 0.66, 280), availableHeight)
        case .expanded:
            return min(max(photoWidth * 0.64, 320), 640)
        }
    }

    @ViewBuilder
    private func contentLayout(_ content: TodayDisplayContent) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            hero(for: content)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    TodayHeroDetailsView(content: content)
                    wallpaperActions(for: content)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        TodayHeroDetailsView(content: content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        wallpaperActions(for: content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        TodayHeroDetailsView(content: content)
                        wallpaperActions(for: content)
                    }
                }
            }

            storyColumn(for: content)
                .frame(maxWidth: 1040, alignment: .leading)
        }
    }

    private func wallpaperActions(for content: TodayDisplayContent) -> some View {
        TodayActionsView(
            content: content,
            isPreparingPreview: isPreparingPreview,
            isDownloadingOriginal: store.isDownloadingOriginal,
            onToggleFavorite: {
                Task { await store.toggleTodayFavorite() }
            },
            onPreview: startPreviewPreparation,
            onRequestOriginal: requestImage
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storyColumn(for content: TodayDisplayContent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TodayStoryView(content: content)

            Button {
                navigation.openTimeline(date: content.sourceDate, market: content.market)
            } label: {
                Label("查看时光", systemImage: "calendar")
            }
            .font(.callout)
            .tint(.daybreakActionTint)
            .accessibilityHint("切换到时光并选中这张图片的来源日期")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hero(for content: TodayDisplayContent) -> some View {
        TodayHeroView(
            content: content,
            height: heroHeight,
            image: heroImageKey == content.key ? heroImage : nil,
            isLoadingImage: isLoadingHeroImage || store.isDownloadingOriginal,
            onRequestImage: requestImage,
        )
    }


    // MARK: States

    @ViewBuilder
    private var unavailableContent: some View {
        if !didStart || (store.today == nil && (store.isLoadingCache || store.isRefreshing)) {
            loadingState
        } else if let message = store.lastErrorMessage, store.today == nil {
            failureState(message)
        } else {
            emptyState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在读取本地缓存并获取今日内容…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有可显示的今日内容", systemImage: "sunrise")
        } description: {
            Text("连接网络后刷新；离线时只会显示已经缓存的内容，不会补造图片或介绍。")
        } actions: {
            Button {
                Task { await store.refreshToday() }
            } label: {
                Label("刷新今日", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isRefreshing)
        }
        .frame(minHeight: 420)
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("无法载入今日内容", systemImage: "wifi.exclamationmark")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button {
                Task { await store.refreshToday() }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isRefreshing)
        }
        .frame(minHeight: 420)
    }



    // MARK: Image and preview

    private var imageTaskIdentity: String {
        guard let snapshot = store.today else { return "none" }
        return [
            snapshot.key.description,
            snapshot.thumbnailURL?.path ?? "",
            snapshot.originalURL?.path ?? ""
        ].joined(separator: "|")
    }

    private func loadHeroImage() async {
        imageGeneration += 1
        let generation = imageGeneration

        guard let snapshot = store.today else {
            heroImage = nil
            heroImageKey = nil
            isLoadingHeroImage = false
            return
        }

        if heroImageKey != snapshot.key {
            heroImage = nil
            heroImageKey = snapshot.key
        }

        guard let url = snapshot.originalURL ?? snapshot.thumbnailURL else {
            heroImage = nil
            isLoadingHeroImage = false
            return
        }

        isLoadingHeroImage = true
        var cgImage = await TodayImageDecoder.downsample(at: url, maxPixelSize: 2600)
        if cgImage == nil,
           let thumbnailURL = snapshot.thumbnailURL,
           thumbnailURL != url {
            cgImage = await TodayImageDecoder.downsample(at: thumbnailURL, maxPixelSize: 2600)
        }
        guard generation == imageGeneration, !Task.isCancelled else { return }

        heroImage = TodayImageDecoder.image(from: cgImage)
        isLoadingHeroImage = false
    }

    private func requestImage() {
        Task {
            if store.today?.hasOriginal == true {
                return
            }
            if store.today?.hasThumbnail == true {
                _ = await store.loadTodayOriginal()
            } else {
                await store.refreshToday()
            }
        }
    }

    private func startPreviewPreparation() {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        previewPreparationTask?.cancel()
        previewPreparationTask = Task { await preparePreview() }
    }

    private func preparePreview() async {
        defer { isPreparingPreview = false }

        guard let snapshot = store.today else {
            previewAlert = .failed(MobileLocalizedString.resolve("今日内容尚未载入，无法打开预览。", locale: locale))
            return
        }

        // Share/export must not silently substitute the thumbnail for the
        // original. Ask the single store to fetch the original on demand; if
        // that fails offline, the alert states that export cannot be the
        // original before offering a limited preview.
        var originalURL = snapshot.originalURL
        if originalURL == nil {
            originalURL = await store.loadTodayOriginal()
            guard !Task.isCancelled else { return }
        }

        var displayURL = originalURL ?? snapshot.thumbnailURL
        if displayURL == nil {
            displayURL = await store.displayImageFileURL(for: snapshot.wallpaperID)
            guard !Task.isCancelled else { return }
        }
        guard let displayURL else {
            previewAlert = .failed(MobileLocalizedString.resolve("图片尚未缓存。请刷新或下载图片后再预览。", locale: locale))
            return
        }

        let request = WallpaperPreviewRequest(
            id: "\(snapshot.key)|\(snapshot.wallpaperID)",
            displayImageURL: displayURL,
            originalImageURL: originalURL,
            wallpaperID: snapshot.wallpaperID,
            market: snapshot.market,
            sourceDate: snapshot.sourceDate,
            title: snapshot.title,
            copyright: snapshot.copyright,
            sourcePageURL: snapshot.sourceURL
        )

        if originalURL == nil {
            previewAlert = .originalUnavailable(request)
        } else {
            presentPreview(request)
        }
    }

    /// Today's preview has no shortcut hand-off; the window shell owns the
    /// presentation so a compact/wide swap cannot dismiss it.
    private func presentPreview(_ request: WallpaperPreviewRequest) {
        previewPresentation = WallpaperPreviewPresentation(
            request: request,
            onSetWallpaperRequested: nil,
            onDismiss: nil
        )
    }
}

@MainActor
private struct TodayStatusSheet: View {
    let store: MobileStore

    var body: some View {
        if let content = store.todayDisplayContent {
            TodayStatusView(
                content: content,
                phase: phase,
                errorMessage: store.lastErrorMessage,
                warnings: store.todayRefreshWarnings,
                lastUpdated: store.lastUpdated == content.cachedAt ? nil : store.lastUpdated,
                isRefreshing: store.isRefreshing,
                onRefresh: {
                    Task { await store.refreshToday() }
                },
                onToggleFavorite: {
                    Task { await store.toggleTodayFavorite() }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var phase: TodayLoadPhase {
        switch store.todayPhase {
        case .idle: .idle
        case .loadingCache: .loadingCache
        case .refreshing: .refreshing
        case .ready: .ready
        case .empty: .empty
        case .failed(let message): .failed(message)
        }
    }
}

extension TodayScreen {
    fileprivate enum PreviewAlert: Identifiable {
        case originalUnavailable(WallpaperPreviewRequest)
        case failed(String)

        var id: String {
            switch self {
            case .originalUnavailable(let request): "original-\(request.id)"
            case .failed(let message): "failed-\(message)"
            }
        }
    }
}
