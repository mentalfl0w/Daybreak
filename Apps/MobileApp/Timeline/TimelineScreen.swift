import DaybreakCore
import Observation
import SwiftUI

/// Timeline tab for iPhone, iPadOS and iPhone Duo.
///
/// The window shell owns the selection model; the shared `MobileStore` owns
/// content and cache. A compact window uses a navigation stack, a wide window
/// shows a calendar/gallery split with the selected day beside it. The model
/// lives above the chrome, so the selected date and prepared detail survive
/// both layouts and a compact/wide change. The preview presentation and its
/// shortcut hand-off do too: a preview opened before a chrome swap must keep
/// its composition, and the button inside it must still reach whichever
/// Timeline screen is current.
struct TimelineScreen<Store: TimelineDataStore>: View {
    private let store: Store
    private let navigation: MobileNavigationState
    /// Owned by the window shell so the selected date, section and prepared
    /// detail survive a compact/wide chrome change.
    private let model: TimelineModel

    @Binding private var path: [TimelineDetailRoute]
    /// Owned by the window shell with the model and path: the preview's apply
    /// button can run after the screen that presented it was replaced.
    private let shortcutHandoff: TimelineShortcutHandoff
    /// Presented by the window shell so a chrome swap cannot dismiss it.
    @Binding private var previewPresentation: WallpaperPreviewPresentation?
    @State private var currentWindowSize: CGSize = .zero

    @AppStorage(DaybreakShortcutGuideStorage.applyConfigured)
    private var applyShortcutConfigured = false

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    /// Clearance kept by the wide shell's floating tab bar; zero in the
    /// compact shell, where the system tab bar reserves its own space.
    @Environment(\.wideShellTabBarClearance) private var tabBarClearance

    init(
        store: Store,
        navigation: MobileNavigationState,
        model: TimelineModel,
        path: Binding<[TimelineDetailRoute]>,
        shortcutHandoff: TimelineShortcutHandoff,
        previewPresentation: Binding<WallpaperPreviewPresentation?>
    ) {
        self.store = store
        self.navigation = navigation
        self.model = model
        self.shortcutHandoff = shortcutHandoff
        _path = path
        _previewPresentation = previewPresentation
    }

    var body: some View {
        @Bindable var shortcutHandoff = shortcutHandoff

        GeometryReader { proxy in
            let isWide = TimelineLayout.isWide(proxy.size)
            Group {
                if isWide {
                    wideLayout(availableWidth: proxy.size.width)
                } else {
                    narrowLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                currentWindowSize = size
            }
            .onChange(of: isWide) { _, _ in
                // The split layout shows the selection inline; a route pushed
                // while compact would otherwise reappear when collapsing back
                // with a different selected day. The model keeps the date and
                // prepared detail across both layouts.
                path.removeAll()
            }
            .onAppear {
                // A chrome swap recreates this screen, so `onChange` above
                // cannot observe the layout change that already happened.
                // Start a wide layout with no pending compact route.
                if isWide, !path.isEmpty {
                    path.removeAll()
                }
            }
        }
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea(edges: .top)
        }
        .environment(model)
        .task {
            await model.load()
        }
        .task(id: navigation.timelineRequest?.id) {
            await consumeTimelineRequest()
        }
        .onChange(of: store.dataRevision) { _, revision in
            Task {
                await model.storeDidChange(revision)
            }
        }
        .onChange(of: store.selectedMarket) { _, _ in
            Task {
                await model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.refresh()
            }
        }
        .sheet(item: $shortcutHandoff.activeGuide) { guide in
            sheetContent(guide)
        }
        .alert("无法打开快捷指令", isPresented: $shortcutHandoff.showsFailure) {
            Button("打开设置指南") {
                showShortcutGuide(for: shortcutHandoff.pendingWallpaperID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确认已安装并命名为“Daybreak Apply”的快捷指令。Daybreak 不会直接修改系统壁纸。")
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                TimelineBannerView(banner: banner)
                    // The banner is drawn above the scroll content, so it has
                    // to clear the floating bar explicitly; the scroll
                    // content margin does not move overlays.
                    .padding(.bottom, 18 + tabBarClearance)
                    .transition(.opacity)
                    .onTapGesture {
                        model.dismissBanner()
                    }
            }
        }
    }

    // MARK: Layouts

    private var narrowLayout: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TimelineSectionPicker()
                contentBody(isWide: false, availableWidth: currentWindowSize.width)
            }
            .navigationTitle("时光", locale: locale)
            .navigationBarTitleDisplayMode(.large)
            // Content region is configured in Settings. Keeping only the
            // "今天" action avoids the globe pill reading as a language
            // selector in the compact and Duo layouts.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    todayButton
                }
            }
            .navigationDestination(for: TimelineDetailRoute.self) { _ in
                TimelineDetailScreen(onPreview: handlePreview)
            }
        }
    }

    /// The split layout keeps the same navigation container as Today's wide
    /// layout. Both ask the system for its inline-large title, so the large
    /// title is drawn inside the bar on the row with the trailing action,
    /// without an extra large-title band, and no custom title item exists that
    /// the bar could move into its overflow menu. The section picker remains
    /// directly below the bar.
    private func wideLayout(availableWidth: CGFloat) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                wideHeader
                Divider()
                contentBody(isWide: true, availableWidth: availableWidth)
            }
            .navigationTitle("时光", locale: locale)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    todayButton
                }
            }
        }
    }

    private var wideHeader: some View {
        TimelineSectionPicker()
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    /// The previous icon-only `arrow.uturn.backward` control was read as a back
    /// button and did nothing when today was already selected. A labelled
    /// "今天" action that disables itself at the root state is unambiguous.
    ///
    /// No button style is applied here: both the compact and split layouts
    /// host this control in the navigation toolbar, which already provides
    /// the system's Liquid Glass container. Applying `.bordered` inside a
    /// toolbar nests a second capsule in the system glass background.
    private var todayButton: some View {
        Button {
            path.removeAll()
            model.selectToday()
        } label: {
            Label("今天", systemImage: "calendar")
        }
        .disabled(isShowingToday)
        .accessibilityHint(Text("回到当前地区今天并显示月历"))
    }

    private var isShowingToday: Bool {
        path.isEmpty
            && model.section == .calendar
            && model.display == .month
            && model.selectedDate == model.asOf
    }

    // MARK: Content

    @ViewBuilder
    private func contentBody(isWide: Bool, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let error = model.error, model.hasLoadedOnce {
                TimelineErrorBanner(failure: error) {
                    model.dismissError()
                }
                .padding(.vertical, 6)
            }

            if !model.hasLoadedOnce, model.loadState == .loading {
                ProgressView("正在读取本地时光")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text("正在读取本地时光"))
            } else if !model.hasLoadedOnce, model.loadState == .failed {
                TimelineStateCard(
                    systemImage: "externaldrive.badge.exclamationmark",
                    title: Text("无法读取本地时光"),
                    message: Text("Daybreak 暂时无法打开本地索引。已有图片文件不会被删除，可以稍后重试。"),
                    actionTitle: Text("重试"),
                    action: {
                        Task {
                            await model.load()
                        }
                    }
                )
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            } else if isWide, model.section != .recap {
                HStack(spacing: 0) {
                    sectionContent(isWide: true)
                        .frame(width: TimelineLayout.listColumnWidth(for: max(availableWidth, 760)))
                        .clipped()
                    Divider()
                    TimelineDetailView(isWide: true, onPreview: handlePreview)
                        .frame(maxWidth: .infinity)
                }
            } else {
                sectionContent(isWide: isWide)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(isWide: Bool) -> some View {
        switch model.section {
        case .calendar:
            TimelineCalendarView(isWide: isWide) { date in
                openDay(date, isWide: isWide)
            }
        case .gallery:
            TimelineGalleryView(isWide: isWide) { item in
                openGalleryItem(item, isWide: isWide)
            }
        case .recap:
            TimelineRecapView(
                onOpenDate: { date in
                    openDay(date, isWide: isWide)
                },
                onOpenOccurrence: { key in
                    openOccurrence(key, isWide: isWide)
                },
                onOpenMonth: { year, month in
                    model.goToMonth(year: year, month: month)
                    model.setSection(.calendar)
                }
            )
        }
    }

    // MARK: Selection

    private func openDay(_ date: LocalDate, isWide: Bool) {
        let selected = model.selectDate(date)
        if model.section == .recap {
            model.setSection(.calendar)
        }
        if isWide {
            path.removeAll()
            return
        }
        guard selected else { return }
        path.append(.day(date))
    }

    private func openGalleryItem(_ item: TimelineGalleryItem, isWide: Bool) {
        model.selectGalleryItem(item)
        if isWide {
            path.removeAll()
            return
        }
        path.append(.occurrence(item.key))
    }

    private func openOccurrence(_ key: OccurrenceKey, isWide: Bool) {
        model.selectTarget(.occurrence(key))
        if model.section == .recap {
            model.setSection(.calendar)
        }
        if isWide {
            path.removeAll()
            return
        }
        path.append(.occurrence(key))
    }

    @ViewBuilder
    private func sheetContent(_ guide: TimelineShortcutGuide) -> some View {
        NavigationStack {
            ScrollView {
                ShortcutsGuideView(selectedWallpaperID: guide.wallpaperID)
                    .padding()
            }
            .navigationTitle("快捷指令设置壁纸", locale: locale)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        shortcutHandoff.activeGuide = nil
                    }
                }
            }
        }
    }

    // MARK: Hand-off

    private func consumeTimelineRequest() async {
        guard let request = navigation.timelineRequest else { return }
        await model.open(date: request.date, market: request.market)
        guard !Task.isCancelled,
              navigation.timelineRequest?.id == request.id
        else { return }
        navigation.timelineRequest = nil
        path.removeAll()
        guard !TimelineLayout.isWide(currentWindowSize),
              model.detail?.date == request.date
        else { return }
        path.append(.day(request.date))
    }

    private func handlePreview(_ content: TimelinePreviewContent) {
        let request = WallpaperPreviewRequest(
            id: "\(content.wallpaperID)-\(content.date.iso8601)",
            displayImageURL: content.displayImageURL,
            originalImageURL: content.originalImageURL,
            wallpaperID: content.wallpaperID,
            market: content.market,
            sourceDate: content.date,
            title: content.title,
            copyright: content.copyright,
            sourcePageURL: content.sourcePageURL
        )
        previewPresentation = WallpaperPreviewPresentation(
            request: request,
            // The preview dismisses itself after this call; the hand-off state
            // lives in the shell, so this still reaches the current screen
            // when the shell was replaced while the preview was open.
            onSetWallpaperRequested: { _ in
                runApplyShortcut(for: request)
            },
            onDismiss: {
                Task {
                    await model.refresh()
                }
            }
        )
    }

    /// Opens the user's `Daybreak Apply` shortcut with the canonical wallpaper
    /// identity as text input. The system shortcut resolves the file through
    /// Daybreak's App Intent and performs its own wallpaper step. Daybreak
    /// never claims that step succeeded.
    private func runApplyShortcut(for request: WallpaperPreviewRequest) {
        guard let wallpaperID = request.wallpaperID else {
            shortcutHandoff.showsFailure = true
            return
        }
        let text = DaybreakWallpaperReference(wallpaperID: wallpaperID).text
        shortcutHandoff.pendingWallpaperID = text
        guard applyShortcutConfigured else {
            showShortcutGuide(for: text)
            return
        }
        guard let url = DaybreakShortcutURL.runShortcutURL(
            name: DaybreakShortcutName.apply,
            textInput: text
        ) else {
            shortcutHandoff.showsFailure = true
            return
        }
        openURL(url) { accepted in
            Task { @MainActor in
                guard accepted else {
                    shortcutHandoff.showsFailure = true
                    return
                }
                DaybreakShortcutGuideStorage.recordHandoff(
                    name: DaybreakShortcutName.apply,
                    wallpaperID: text
                )
            }
        }
    }

    /// The setup marker is a user confirmation, not proof that Shortcuts ran
    /// or that the system wallpaper changed.
    private func showShortcutGuide(for wallpaperID: String?) {
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            shortcutHandoff.activeGuide = TimelineShortcutGuide(wallpaperID: wallpaperID)
        }
    }
}

/// One shortcut-guide presentation. Owned by the shell with the rest of the
/// Timeline hand-off state, so it can be shown by the screen that is current
/// when the preview finishes rather than the one that presented it.
struct TimelineShortcutGuide: Identifiable {
    let wallpaperID: String?

    var id: String { "shortcutGuide-\(wallpaperID ?? "none")" }
}

/// Timeline's shortcut hand-off UI state, owned by the window shell.
///
/// The preview's "用快捷指令设置壁纸" button can run after a compact/wide swap
/// replaced the screen that presented it. Keeping the guide, failure and
/// pending wallpaper ID in a stable observable lets whichever Timeline screen
/// is on screen show the same result the original screen would have shown.
@MainActor
@Observable
final class TimelineShortcutHandoff {
    var activeGuide: TimelineShortcutGuide?
    var showsFailure = false
    var pendingWallpaperID: String?
}
