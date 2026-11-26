import AppKit
import DaybreakCore
import SwiftUI

// MARK: - Browsing mode

enum LibraryBrowseMode: String, CaseIterable, Identifiable, Sendable {
    case gallery
    case calendar

    var id: String { rawValue }

    /// Resolved explicitly because the AppKit segmented control sits outside
    /// SwiftUI's localized-string environment.
    func title(in locale: Locale) -> String {
        switch self {
        case .gallery: return String(localized: LocalizedStringResource("图库", locale: locale))
        case .calendar: return String(localized: LocalizedStringResource("日历", locale: locale))
        }
    }

    var systemImage: String {
        switch self {
        case .gallery: return "square.grid.2x2"
        case .calendar: return "calendar"
        }
    }
}

// MARK: - Library

/// Offline 时光 page: an image-led gallery, a complete monthly calendar with
/// explicit per-date state, one selected-day detail with strict story
/// association, and the former recap statistics integrated into the same
/// scroll surface. Nothing is fabricated for dates the repository did not
/// record, and archived images can be applied without borrowing Today's
/// payload.
struct LibraryView: View {
    let model: LibraryModel
    /// The all-market recap engine. Its statistics are fused into this page
    /// instead of living in a separate recap screen, while the gallery and
    /// calendar keep presenting the actual archived images.
    let recap: RecapScreenModel
    let appModel: AppModel
    let onOpenStorage: () -> Void
    @Environment(\.locale) private var locale

    private let externalMode: Binding<LibraryBrowseMode>?
    @State private var internalMode: LibraryBrowseMode
    @State private var isYearRecapExpanded = false
    @State private var isFavoriteRecapExpanded = false

    init(
        model: LibraryModel,
        recap: RecapScreenModel,
        appModel: AppModel,
        initialMode: LibraryBrowseMode = .gallery,
        mode: Binding<LibraryBrowseMode>? = nil,
        onOpenStorage: @escaping () -> Void = {}
    ) {
        self.model = model
        self.recap = recap
        self.appModel = appModel
        self.onOpenStorage = onOpenStorage
        self.externalMode = mode
        self._internalMode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if hasNotices {
                notices
            }
            content
        }
        // All three root pages put their root title in the native window
        // toolbar so hierarchy, type size and placement stay consistent.
        // Timeline no longer draws a second, larger title in the content
        // area; Today and Timeline also put their supporting line there.
        .navigationTitle("时光")
        .navigationSubtitle(Text(subtitle))
        // The app shell owns the frosted window backdrop; keep this page free
        // of an opaque fill so the backdrop remains visible.
        // Browsing controls live in the native window toolbar, so macOS 26
        // supplies its own Liquid Glass treatment. Content below stays
        // flat rather than stacking additional glass cards.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                IconSegmentedControl(
                    selection: modeBinding,
                    segments: LibraryBrowseMode.allCases.map {
                        IconSegmentedControl<LibraryBrowseMode>.Segment(
                            value: $0,
                            title: $0.title(in: locale),
                            systemImage: $0.systemImage
                        )
                    },
                    locale: locale
                )
                .help("在照片图库与整月日历之间切换")
                .accessibilityLabel("图库或日历")

                Button {
                    revealSourceToday()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
                .disabled(model.asOf == nil || model.loadState == .loading)
                .help(
                    model.asOf.map {
                        MacLocalizedString.resolve("跳到来源今天（\(libraryLongDate($0))）", locale: WallpaperInterfaceLocale.current)
                    } ?? MacLocalizedString.resolve("来源日期未知", locale: WallpaperInterfaceLocale.current)
                )
                .accessibilityLabel("跳到来源今天")

                Button {
                    Task {
                        await model.load()
                        await recap.reload()
                    }
                } label: {
                    Group {
                        if model.loadState == .loading || recap.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .disabled(model.loadState == .loading || recap.isLoading)
                .help("刷新本地记录")
                .accessibilityLabel("刷新本地记录")
            }
        }
        // Re-read the shared repository snapshot on every appearance so
        // storage operations and Today refreshes are reflected without
        // opening a second repository. The recap model is refreshed against
        // the same selected month so its statistics describe the calendar
        // currently on screen.
        .task {
            await model.load()
            if recap.monthlyRecap == nil || !recapMonthMatchesSelection {
                await syncRecapMonth()
            } else {
                // Refresh favorite/protection statistics after Storage or a
                // previous visit changed the shared repository.
                await recap.reload()
            }
        }
        .onChange(of: model.monthKey) { _, _ in
            Task { await syncRecapMonth() }
        }
        // A completed apply may have downloaded a previously missing original;
        // re-read the local snapshot so the cache badges and detail image stop
        // showing stale state. This never fetches Today's image.
        .onChange(of: appModel.applyingPayloadKey) { oldValue, newValue in
            guard oldValue != nil, newValue == nil else { return }
            Task {
                await model.load()
                await recap.reload()
            }
        }
        .alert(
            recap.pendingCleanup?.title ?? MacLocalizedString.resolve("确认操作", locale: WallpaperInterfaceLocale.current),
            isPresented: recapCleanupBinding,
            presenting: recap.pendingCleanup
        ) { action in
            Button("取消", role: .cancel) {
                recap.cancelPendingCleanup()
            }
            Button(role: .destructive) {
                Task {
                    await recap.confirmPendingCleanup(action)
                    await model.load()
                }
            } label: {
                Text(action.confirmLabel)
            }
        } message: { action in
            Text(action.message)
        }
    }

    private var recapCleanupBinding: Binding<Bool> {
        Binding(
            get: { recap.pendingCleanup != nil },
            set: { newValue in
                if !newValue { recap.cancelPendingCleanup() }
            }
        )
    }

    private func syncRecapMonth() async {
        let key = model.monthKey
        if recap.selectedYear != key.year || recap.selectedMonth != key.month || recap.monthlyRecap == nil {
            await recap.openMonth(year: key.year, month: key.month)
        }
    }

    private var recapMonthMatchesSelection: Bool {
        recap.selectedYear == model.monthKey.year
            && recap.selectedMonth == model.monthKey.month
    }

    /// The model keeps the last successful recap when a newer reload fails.
    /// Compare the data's own range with the calendar selection so a failed
    /// month change can never present the previous month's statistics.
    private var monthlyRecapMatchesSelection: Bool {
        guard let monthly = recap.monthlyRecap else { return false }
        let start = monthly.summary.range.start
        return start.year == model.monthKey.year && start.month == model.monthKey.month
    }

    private var yearlyRecapMatchesSelection: Bool {
        guard let yearly = recap.yearlyRecap else { return false }
        return yearly.summary.range.start.year == model.monthKey.year
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                browserTitle
                Spacer(minLength: 12)
                browserControls
                summaryMetrics
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 20) {
                    browserTitle
                    Spacer(minLength: 12)
                    summaryMetrics
                }
                browserControls
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var browserTitle: some View {
        switch modeBinding.wrappedValue {
        case .gallery: galleryTitleBlock
        case .calendar: calendarTitleBlock
        }
    }

    @ViewBuilder
    private var browserControls: some View {
        switch modeBinding.wrappedValue {
        case .gallery: scopePicker
        case .calendar: calendarControls
        }
    }

    /// Statistics remain separate from the current browser's title and controls.
    private var summaryMetrics: some View {
        HStack(alignment: .center, spacing: 18) {
            LibraryMetric(
                title: "有记录",
                value: hasReadableHistory ? "\(model.observedDayCount) 天" : "—",
                systemImage: "calendar"
            )

            Divider()
                .frame(height: 32)

            LibraryMetric(
                title: "收藏图片",
                value: hasReadableHistory ? "\(model.favoriteImageCount) 张" : "—",
                systemImage: "heart.fill",
                tint: .pink
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    private var subtitle: String {
        var parts = [MacLocalizedString.resolve("本机离线记录", locale: WallpaperInterfaceLocale.current), marketLabel]
        if let asOf = model.asOf {
            parts.append(MacLocalizedString.resolve("截至 \(libraryLongDate(asOf))", locale: WallpaperInterfaceLocale.current))
        }
        return parts.joined(separator: " · ")
    }

    private var marketLabel: String {
        LocalePresentation.marketName(for: model.market, in: locale)
    }

    private var hasReadableHistory: Bool {
        model.month != nil
    }

    private var summaryAccessibilityLabel: String {
        guard hasReadableHistory else { return MacLocalizedString.resolve("本机记录尚未读取", locale: WallpaperInterfaceLocale.current) }
        return MacLocalizedString.resolve("本机记录 \(model.observedDayCount) 天，收藏图片 \(model.favoriteImageCount) 张", locale: WallpaperInterfaceLocale.current)
    }


    private var scopeBinding: Binding<LibraryScope> {
        Binding(
            get: { model.scope },
            set: { model.setScope($0) }
        )
    }

    /// The parent can own the gallery/calendar mode through an optional
    /// binding (for menu commands and window restoration); otherwise the view
    /// keeps local state.
    private var modeBinding: Binding<LibraryBrowseMode> {
        externalMode ?? $internalMode
    }

    private func revealSourceToday() {
        guard let asOf = model.asOf else { return }
        Task { await model.selectDate(asOf) }
    }

    // MARK: Notices

    private var hasNotices: Bool {
        model.errorMessage != nil
            || model.message != nil
            || recap.actionError != nil
            || recap.actionMessage != nil
    }

    private var notices: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                notice(
                    text: error,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    showsRetry: true
                )
                Divider()
            }
            if let message = model.message {
                notice(
                    text: message,
                    systemImage: "heart.fill",
                    tint: .pink,
                    showsRetry: false
                )
                Divider()
            }
            if let error = recap.actionError {
                notice(
                    text: error,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    showsRetry: false,
                    onDismiss: { recap.dismissActionFeedback() }
                )
                Divider()
            }
            if let message = recap.actionMessage {
                notice(
                    text: message,
                    systemImage: "heart.fill",
                    tint: .pink,
                    showsRetry: false,
                    onDismiss: { recap.dismissActionFeedback() }
                )
                Divider()
            }
        }
    }

    private func notice(
        text: String,
        systemImage: String,
        tint: Color,
        showsRetry: Bool,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if showsRetry {
                Button("重试") {
                    Task { await model.load() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }

            Button {
                if let onDismiss {
                    onDismiss()
                } else {
                    model.dismissMessages()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(tint.opacity(0.06))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.month == nil {
            switch model.loadState {
            case .failed(let message):
                failureState(message)
            default:
                loadingState
            }
        } else {
            GeometryReader { proxy in
                if proxy.size.width >= 900 {
                    wideLayout
                } else {
                    compactLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Wide windows keep the selected-day detail in a stable trailing rail so
    /// choosing a photo or calendar day never hides the result below the fold.
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                browserColumn
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 36)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView {
                detailRail
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 36)
            }
            .frame(width: 332)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                browserColumn

                Divider()

                detailRail
                    .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("日期详情")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LibraryDetailPanel(model: model, recap: recap, appModel: appModel)
        }
    }

    @ViewBuilder
    private var browserColumn: some View {
        switch modeBinding.wrappedValue {
        case .gallery:
            galleryPanel
        case .calendar:
            calendarPanel
        }
    }

    // MARK: Loading and failure

    private var loadingState: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取本地历史…")
                    .font(.callout.weight(.medium))
            }
            Text("只显示本机实际归档的日期，不会补造图片或介绍。")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 16)],
                spacing: 20
            ) {
                ForEach(0..<6, id: \.self) { _ in
                    loadingTile
                }
            }
            .frame(maxWidth: 820)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var loadingTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.10))
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                .frame(width: 86, height: 8)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                .frame(height: 9)
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("无法读取本地历史")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新读取") {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("图库与日历只读取本机缓存，不会联网补造缺失的日期。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Gallery

    private var galleryPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            yearRecapSection

            if model.scope == .favorites, let favoriteRecap = recap.favoriteRecap {
                FavoriteSummaryCard(recap: favoriteRecap)

                if !favoriteRecap.months.isEmpty {
                    favoriteRecapMonths(favoriteRecap.months)
                }

                if !otherRegionFavoriteEntries.isEmpty {
                    DisclosureGroup(isExpanded: $isFavoriteRecapExpanded) {
                        LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 16) {
                            ForEach(otherRegionFavoriteEntries) { entry in
                                FavoriteTile(
                                    entry: entry,
                                    model: recap,
                                    appModel: appModel
                                )
                            }
                        }
                        .padding(.top, 10)

                        if favoriteRecap.hasUndatedFavorites {
                            Text("\(favoriteRecap.undatedFavoriteImageCount) 张收藏没有本机日期记录，列在末尾；不会为它们编造日期，也不能据此应用历史图片。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label("回顾：其他地区收藏", systemImage: "heart.text.square")
                                .font(.headline)
                            Text("\(otherRegionFavoriteEntries.count) 张")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .padding(16)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
            }

            if model.galleryItems.isEmpty {
                emptyGallery
            } else if model.visibleGalleryItems.isEmpty {
                emptyFavorites
            } else {
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach(model.gallerySections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: LibraryDateFormat.monthTitle(
                                    year: section.key.year,
                                    month: section.key.month
                                ))
                                    .font(.headline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text("\(section.items.count) 天")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                            LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 16) {
                                ForEach(section.items) { item in
                                    LibraryGalleryCell(
                                        model: model,
                                        item: item,
                                        isSelected: isSelected(item),
                                        onSelect: {
                                            Task { await model.selectGalleryItem(item.id) }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            coverageNote
        }
    }

    private var galleryTitleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("图库")
                .font(.title2.weight(.semibold))
            Text(gallerySummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var gallerySummary: String {
        switch model.scope {
        case .all:
            return MacLocalizedString.resolve("\(model.galleryItems.count) 天 · 按来源日期倒序", locale: WallpaperInterfaceLocale.current)
        case .favorites:
            return MacLocalizedString.resolve("\(model.visibleGalleryItems.count) 张 · 按图片去重", locale: WallpaperInterfaceLocale.current)
        }
    }

    /// Favorites already shown in the selected market's grid are omitted from
    /// the recap disclosure, so the same image is never listed twice on one
    /// screen. Other markets and undated favorites remain available here.
    private var otherRegionFavoriteEntries: [FavoriteEntry] {
        guard let favoriteRecap = recap.favoriteRecap else { return [] }
        let visible = Set(model.visibleGalleryItems.map(\.wallpaperID))
        return favoriteRecap.entries.filter { !visible.contains($0.id) }
    }

    private func favoriteRecapMonths(_ months: [FavoriteMonth]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最早记录月份")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 200), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(months) { month in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(String(month.year))年\(month.month)月")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        Text("\(month.imageCount) 张")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .quaternaryLabelColor).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
            }
        }
    }

    private var scopePicker: some View {
        Picker("范围", selection: scopeBinding) {
            Text("全部").tag(LibraryScope.all)
            Text("收藏").tag(LibraryScope.favorites)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 136)
        .help("显示全部记录或只显示收藏图片")
        .accessibilityLabel("图库范围")
    }

    private var galleryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 16, alignment: .top)]
    }

    private func isSelected(_ item: LibraryGalleryItem) -> Bool {
        model.selectedDate == item.date
            && model.monthKey == LibraryMonthKey(containing: item.date)
    }

    private var emptyGallery: some View {
        emptyState(
            systemImage: "photo.on.rectangle.angled",
            title: "本地区还没有本地记录",
            message: "连接网络并在「今日」刷新后，已归档的日期会出现在这里。也可以切换到日历，查看本机哪些日期尚未记录。",
            primaryTitle: "打开日历",
            primaryAction: {
                modeBinding.wrappedValue = .calendar
            },
            secondaryTitle: "重新读取",
            secondaryAction: {
                Task { await model.load() }
            }
        )
    }

    private var emptyFavorites: some View {
        emptyState(
            systemImage: "heart",
            title: "本地区还没有收藏图片",
            message: "在所选日期的详情中点击收藏。收藏按图片记录，同一图片出现在多个日期或地区时不会重复计数。",
            primaryTitle: "显示全部记录",
            primaryAction: {
                model.setScope(.all)
            }
        )
    }

    private func emptyState(
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        primaryTitle: LocalizedStringKey? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryTitle: LocalizedStringKey? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 62, height: 62)
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)

            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 8) {
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.vertical, 20)
    }

    private var coverageNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.caption)
                .accessibilityHidden(true)
            Text("只显示本机实际记录。没有记录不代表 Bing 当天没有发布，也不会在回顾统计中补成 0 张。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    // MARK: Calendar

    private var calendarPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            monthRecapSection

            VStack(spacing: 6) {
                weekdayHeader
                if let month = model.month {
                    calendarGrid(month)
                } else {
                    Text("正在生成本月日历…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)

            calendarLegend
            yearRecapSection
            coverageNote
        }
    }

    /// The monthly recap statistics sit directly above the month they describe.
    /// They cover every locally recorded market, while the calendar below stays
    /// scoped to the selected market; neither substitutes for the other.
    @ViewBuilder
    private var monthRecapSection: some View {
        if monthlyRecapMatchesSelection, let monthly = recap.monthlyRecap {
            RecapCoverageCard(summary: monthly.summary, context: .month)
        } else if let error = recap.loadError, !recap.isLoading {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在计算本月回顾…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One expandable yearly overview keeps the old yearly recap reachable
    /// without a separate screen. Its month entries only carry statistics; the
    /// images stay in the gallery and calendar above.
    private var yearRecapSection: some View {
        DisclosureGroup(isExpanded: $isYearRecapExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                yearNavigation

                if yearlyRecapMatchesSelection, let yearly = recap.yearlyRecap {
                    if yearly.summary.hasObservations && !yearly.summary.hasComparableObservations {
                        Label("本机记录不足以生成年度精选", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    RecapCoverageCard(summary: yearly.summary, context: .year)

                    if yearly.months.isEmpty {
                        Text("只显示本机实际记录。没有记录不代表 Bing 当天没有发布，也不会在回顾统计中补成 0 张。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("有记录的月份")
                                    .font(.headline)
                                Text("\(yearly.months.count) 个月")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)],
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(yearly.months) { month in
                                    Button {
                                        openRecapMonth(month.year, month.month)
                                    } label: {
                                        RecapMonthCard(month: month, model: recap)
                                    }
                                    .buttonStyle(.plain)
                                    .help("在日历中打开 \(month.year)年\(month.month)月")
                                }
                            }
                        }
                    }

                    Text("只列出本机有记录的月份；未列出的月份表示没有本地记录，不代表 Bing 当时没有发布图片。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let error = recap.loadError, !recap.isLoading {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在计算年度回顾…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: onOpenStorage) {
                    Label("管理缓存、收藏保护与孤立文件", systemImage: "externaldrive")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.top, 10)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("\(String(model.monthKey.year))年回顾", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                if let yearly = recap.yearlyRecap, yearlyRecapMatchesSelection {
                    Text(yearSummaryLine(yearly.summary))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func yearSummaryLine(_ summary: RecapSummary) -> String {
        var parts = [MacLocalizedString.resolve("有记录 \(summary.observedDays) 天", locale: WallpaperInterfaceLocale.current)]
        if let coverage = summary.coverage {
            parts.append(MacLocalizedString.resolve("覆盖率 \(RecapCopy.percentage(coverage))", locale: WallpaperInterfaceLocale.current))
        }
        parts.append(MacLocalizedString.resolve("\(summary.uniqueImageCount) 张图片", locale: WallpaperInterfaceLocale.current))
        if summary.storyCoveredDays > 0 {
            parts.append(MacLocalizedString.resolve("\(summary.storyCoveredDays) 天有介绍", locale: WallpaperInterfaceLocale.current))
        }
        return parts.joined(separator: " · ")
    }

    private var yearNavigation: some View {
        HStack(spacing: 8) {
            Text("\(String(model.monthKey.year))年")
                .font(.title3.weight(.semibold))
                .monospacedDigit()

            Button {
                changeRecapYear(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("上一年")
            .accessibilityLabel("上一年")

            Button {
                changeRecapYear(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canGoToNextRecapYear)
            .help("下一年")
            .accessibilityLabel("下一年")

            if !recap.isCurrentYear {
                Button("回到今年") {
                    model.goToCurrentMonth()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    private var canGoToNextRecapYear: Bool {
        guard let asOf = model.asOf else { return false }
        let target = LibraryMonthKey(
            year: model.monthKey.year + 1,
            month: model.monthKey.month
        )
        return target <= LibraryMonthKey(containing: asOf)
    }

    private func changeRecapYear(by delta: Int) {
        let targetYear = model.monthKey.year + delta
        guard targetYear >= 1970 else { return }
        if delta > 0 && !canGoToNextRecapYear { return }
        model.goToMonth(year: targetYear, month: model.monthKey.month)
    }

    private func openRecapMonth(_ year: Int, _ month: Int) {
        model.goToMonth(year: year, month: month)
        modeBinding.wrappedValue = .calendar
    }

    private var calendarTitleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: LibraryDateFormat.monthTitle(
                year: model.monthKey.year,
                month: model.monthKey.month
            ))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            if let month = model.month {
                Text(monthSummary(month))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在读取本月记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func monthSummary(_ month: TimelineMonth) -> String {
        var parts = [
            MacLocalizedString.resolve("有记录 \(month.observedDayCount) 天", locale: WallpaperInterfaceLocale.current),
            MacLocalizedString.resolve("未记录 \(month.notRecordedDayCount) 天", locale: WallpaperInterfaceLocale.current)
        ]
        if month.storyAvailableDayCount > 0 {
            parts.append(MacLocalizedString.resolve("含介绍 \(month.storyAvailableDayCount) 天", locale: WallpaperInterfaceLocale.current))
        }
        if month.futureDayCount > 0 {
            parts.append(MacLocalizedString.resolve("未来 \(month.futureDayCount) 天", locale: WallpaperInterfaceLocale.current))
        }
        if month.beforeObservationStartDayCount > 0 {
            parts.append(MacLocalizedString.resolve("更早 \(month.beforeObservationStartDayCount) 天", locale: WallpaperInterfaceLocale.current))
        }
        return parts.joined(separator: " · ")
    }

    private var calendarControls: some View {
        HStack(spacing: 6) {
            Button {
                model.goToPreviousMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16)
            }
            .buttonStyle(.bordered)
            .help("上一个月")
            .accessibilityLabel("上一个月")

            Button {
                model.goToNextMonth()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 16)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canGoToNextMonth)
            .help("下一个月")
            .accessibilityLabel("下一个月")

            Button("本月") {
                model.goToCurrentMonth()
            }
            .buttonStyle(.bordered)
            .disabled(model.isShowingCurrentMonth)
            .help("回到所选地区的当前来源月份")
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 6) {
            ForEach(
                Array(LibraryDateFormat.weekdaySymbols.enumerated()),
                id: \.offset
            ) { _, symbol in
                Text(verbatim: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }

    private func calendarGrid(_ month: TimelineMonth) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
            spacing: 6
        ) {
            ForEach(
                Array(0..<LibraryCalendarMath.leadingBlankCount(in: month)),
                id: \.self
            ) { _ in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityHidden(true)
            }
            ForEach(month.days) { day in
                LibraryCalendarDayCell(
                    model: model,
                    day: day,
                    isSelected: model.selectedDate == day.date,
                    onSelect: {
                        Task { await model.selectDate(day.date) }
                    }
                )
            }
        }
    }

    private var calendarLegend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 116), spacing: 12)],
            alignment: .leading,
            spacing: 6
        ) {
            legendItem(systemImage: "circle.fill", text: "有记录", tint: .accentColor)
            legendItem(systemImage: "photo.fill", text: "图片已缓存", tint: .secondary)
            legendItem(systemImage: "text.book.closed.fill", text: "有介绍", tint: .secondary)
            legendItem(systemImage: "heart.fill", text: "收藏", tint: .pink)
            legendItem(systemImage: "questionmark.circle", text: "未记录", tint: .secondary)
            legendItem(
                systemImage: "circle.dashed",
                text: "未来或更早",
                tint: Color(nsColor: .tertiaryLabelColor)
            )
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(systemImage: String, text: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 11)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Gallery cell

private struct LibraryGalleryCell: View {
    let model: LibraryModel
    let item: LibraryGalleryItem
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var image: NSImage?
    @State private var didAttempt = false
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 9) {
                cover
                caption
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(MacLocalizedString.resolve("\(libraryLongDate(item.date)) · \(displayTitle)", locale: WallpaperInterfaceLocale.current))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("打开这一天的图片和介绍")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            Button {
                Task { await model.toggleFavorite(item.wallpaperID) }
            } label: {
                Label(
                    item.isFavorite ? "取消收藏" : "收藏",
                    systemImage: item.isFavorite ? "heart.slash" : "heart"
                )
            }
            Button("查看这一天", action: onSelect)
        }
        .task(id: imageTaskID) {
            image = nil
            didAttempt = false
            image = await model.galleryImage(for: item)
            didAttempt = true
        }
    }

    private var cover: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.10))

            if let image {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .accessibilityHidden(true)
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            coverBadges
                .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.pink)
                    .padding(6)
                    .background(.black.opacity(0.42), in: Circle())
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .shadow(
            color: .black.opacity(isHovering ? 0.14 : 0),
            radius: 10,
            y: 4
        )
    }

    @ViewBuilder
    private var coverBadges: some View {
        HStack(spacing: 5) {
            if item.hasStory {
                coverBadge(systemImage: "text.book.closed.fill")
            } else if item.hasUnavailableStory {
                coverBadge(systemImage: "text.book.closed")
            }
            if item.hasOriginal {
                Text("原图")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.48), in: Capsule())
            }
        }
        .accessibilityHidden(true)
    }

    private func coverBadge(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.48), in: Circle())
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(item.title == nil ? Color.secondary : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 5) {
                Text(verbatim: libraryMonthDay(item.date))
                    .font(.caption.monospacedDigit())
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(verbatim: libraryWeekday(item.date))
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var displayTitle: String {
        item.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            if item.hasThumbnail && !didAttempt {
                ProgressView()
                    .controlSize(.small)
                Text("载入缩略图…")
                    .font(.caption2)
            } else {
                Image(systemName: item.hasThumbnail ? "photo.badge.exclamationmark" : "photo")
                    .font(.system(size: 20, weight: .light))
                Text(placeholderText)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
        }
        .foregroundStyle(.secondary)
        .padding(10)
    }

    private var placeholderText: LocalizedStringKey {
        if !item.hasThumbnail {
            return "缩略图未缓存"
        }
        return "缓存图片不可读"
    }

    private var imageTaskID: String {
        "\(item.id)|\(item.hasThumbnail)"
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isHovering { return Color(nsColor: .secondaryLabelColor).opacity(0.55) }
        return Color(nsColor: .separatorColor).opacity(0.45)
    }

    private var borderWidth: CGFloat {
        if isSelected { return 2.5 }
        return isHovering ? 1 : 0.5
    }

    private var accessibilityLabel: String {
        var parts = [libraryLongDate(item.date), displayTitle]
        parts.append(item.isFavorite ? MacLocalizedString.resolve("已收藏", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("未收藏", locale: WallpaperInterfaceLocale.current))
        parts.append(
            item.hasThumbnail
                ? MacLocalizedString.resolve("缩略图已缓存", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("缩略图未缓存", locale: WallpaperInterfaceLocale.current)
        )
        parts.append(
            item.hasOriginal
                ? MacLocalizedString.resolve("原图已缓存", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("原图未缓存", locale: WallpaperInterfaceLocale.current)
        )
        if item.hasStory {
            parts.append(MacLocalizedString.resolve("有介绍", locale: WallpaperInterfaceLocale.current))
        } else if item.hasUnavailableStory {
            parts.append(MacLocalizedString.resolve("介绍暂不可用", locale: WallpaperInterfaceLocale.current))
        } else {
            parts.append(MacLocalizedString.resolve("无介绍记录", locale: WallpaperInterfaceLocale.current))
        }
        return libraryList(parts)
    }
}

// MARK: - Calendar day cell

private struct LibraryCalendarDayCell: View {
    let model: LibraryModel
    let day: TimelineDay
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(background)

                if let image, day.state == .observed {
                    GeometryReader { proxy in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                    .accessibilityHidden(true)
                    LinearGradient(
                        colors: [.black.opacity(0.14), .black.opacity(0.58)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(day.date.day, format: .number)
                            .font(.system(
                                size: 13,
                                weight: day.state == .observed ? .semibold : .regular,
                                design: .rounded
                            ))
                            .monospacedDigit()
                            .foregroundStyle(dayNumberColor)
                        Spacer(minLength: 0)
                        if isToday {
                            Text("今日")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .accessibilityHidden(true)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 3) {
                        if day.content?.isFavorite == true {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.pink)
                        }
                        if day.content?.thumbnailCached == true {
                            Image(systemName: day.content?.originalCached == true ? "photo.fill" : "photo")
                                .font(.system(size: 9, weight: .medium))
                        }
                        if day.content?.story.isAvailable == true {
                            Image(systemName: "text.book.closed.fill")
                                .font(.system(size: 9, weight: .medium))
                        }
                        Spacer(minLength: 0)
                        if day.state == .notRecorded {
                            Image(systemName: "questionmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .foregroundStyle(statusIconColor)
                }
                .padding(7)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(strokeColor, style: strokeStyle)
            }
        }
        .buttonStyle(.plain)
        .disabled(day.state == .future)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(day.state == .future ? "" : "查看这一天的详情")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .task(id: imageTaskID) {
            image = nil
            image = await model.calendarImage(for: day)
        }
    }

    private var imageTaskID: String {
        "\(day.id)|\(day.content?.thumbnailCached == true)"
    }

    private var isToday: Bool {
        model.asOf == day.date
    }

    private var background: Color {
        switch day.state {
        case .observed:
            return day.content?.thumbnailCached == true
                ? Color(nsColor: .quaternaryLabelColor).opacity(0.10)
                : Color.accentColor.opacity(0.10)
        case .notRecorded:
            return Color(nsColor: .quaternaryLabelColor).opacity(0.05)
        case .beforeObservationStart, .future:
            return .clear
        }
    }

    private var dayNumberColor: Color {
        if image != nil, day.state == .observed {
            return .white
        }
        switch day.state {
        case .observed: return .primary
        case .notRecorded: return .secondary
        case .beforeObservationStart, .future:
            return .secondary
        }
    }

    private var statusIconColor: Color {
        image != nil && day.state == .observed ? .white.opacity(0.92) : .secondary
    }

    private var strokeColor: Color {
        if isSelected { return .accentColor }
        if day.state == .notRecorded { return Color(nsColor: .separatorColor) }
        return Color(nsColor: .separatorColor).opacity(0.35)
    }

    private var strokeStyle: StrokeStyle {
        if isSelected {
            return StrokeStyle(lineWidth: 2.5)
        }
        if day.state == .notRecorded {
            return StrokeStyle(lineWidth: 1, dash: [3, 2])
        }
        return StrokeStyle(lineWidth: 0.5)
    }

    private var helpText: String {
        MacLocalizedString.resolve("\(libraryLongDate(day.date)) · \(stateDescription)", locale: WallpaperInterfaceLocale.current)
    }

    private var accessibilityLabel: String {
        var parts = [libraryLongDate(day.date)]
        if isToday {
            parts.append(MacLocalizedString.resolve("来源今天", locale: WallpaperInterfaceLocale.current))
        }
        parts.append(stateDescription)
        return libraryList(parts)
    }

    private var stateDescription: String {
        switch day.state {
        case .observed:
            var parts: [String] = []
            if let content = day.content {
                parts.append(
                    content.thumbnailCached
                        ? MacLocalizedString.resolve("缩略图已缓存", locale: WallpaperInterfaceLocale.current)
                        : MacLocalizedString.resolve("缩略图未缓存", locale: WallpaperInterfaceLocale.current)
                )
                parts.append(
                    content.originalCached
                        ? MacLocalizedString.resolve("原图已缓存", locale: WallpaperInterfaceLocale.current)
                        : MacLocalizedString.resolve("原图未缓存", locale: WallpaperInterfaceLocale.current)
                )
                if content.story.isAvailable {
                    parts.append(MacLocalizedString.resolve("有介绍", locale: WallpaperInterfaceLocale.current))
                } else if content.story.record != nil {
                    parts.append(MacLocalizedString.resolve("介绍暂不可用", locale: WallpaperInterfaceLocale.current))
                } else {
                    parts.append(MacLocalizedString.resolve("无介绍记录", locale: WallpaperInterfaceLocale.current))
                }
                if content.isFavorite {
                    parts.append(MacLocalizedString.resolve("已收藏", locale: WallpaperInterfaceLocale.current))
                }
            } else {
                parts.append(MacLocalizedString.resolve("有记录", locale: WallpaperInterfaceLocale.current))
            }
            return libraryList(parts)
        case .notRecorded:
            return MacLocalizedString.resolve("本机未记录；不代表来源当天没有发布", locale: WallpaperInterfaceLocale.current)
        case .beforeObservationStart:
            return MacLocalizedString.resolve("早于本机首次记录", locale: WallpaperInterfaceLocale.current)
        case .future:
            return MacLocalizedString.resolve("未来日期", locale: WallpaperInterfaceLocale.current)
        }
    }
}

// MARK: - Detail panel

private struct LibraryDetailPanel: View {
    let model: LibraryModel
    let recap: RecapScreenModel
    let appModel: AppModel
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selection = model.selection {
                switch selection {
                case .observed(let day, let payload):
                    observedDetail(day: day, payload: payload)
                case .observedWithoutPayload(let day):
                    stateDetail(
                        day: day,
                        systemImage: "exclamationmark.triangle",
                        title: "记录存在但详情不可读",
                        message: "本机有这一天的记录，但无法读取图片与介绍详情。可以稍后重新读取；不会用相邻日期的内容替代。"
                    )
                case .notRecorded(let day):
                    stateDetail(
                        day: day,
                        systemImage: "questionmark.circle",
                        title: "这一天没有本地记录",
                        message: "本机没有这一天的归档。可能是应用未运行、该地区未启用、网络获取失败，或来源当天没有发布内容。Daybreak 不会补造图片或介绍。"
                    )
                case .beforeObservationStart(let day):
                    stateDetail(
                        day: day,
                        systemImage: "clock.badge.xmark",
                        title: "早于本机首次记录",
                        message: "这一天在本机首次成功归档之前。没有记录是预期状态，回顾统计也不会把它计为缺失。"
                    )
                case .future(let day):
                    stateDetail(
                        day: day,
                        systemImage: "calendar.badge.exclamationmark",
                        title: "未来日期",
                        message: "这一天晚于该地区当前来源日期。不会显示尚未发生的内容。"
                    )
                }
            } else if model.isLoadingSelection {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("读取当天详情…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .top)
            } else {
                emptySelection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                    .frame(width: 52, height: 52)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            Text("选择一天")
                .font(.title3.weight(.semibold))
            Text("从图库或日历选择日期，查看当天缓存的图片与介绍。未记录的日期会如实标记，不会补造内容。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            Text("图库用于连续浏览有记录的图片；日历会显示整月每一天的实际状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
    }

    // MARK: Observed day

    private func observedDetail(day: TimelineDay, payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryDetailImage(model: model, payload: payload)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(libraryLongDate(payload.sourceDate)) · \(libraryWeekday(payload.sourceDate))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(LocalePresentation.marketName(for: payload.market, in: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color(nsColor: .quaternaryLabelColor).opacity(0.10),
                        in: Capsule()
                    )
            }

            Text(payloadTitle(payload))
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let copyright = payload.copyright, !copyright.isEmpty {
                Text("版权：\(copyright)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                favoriteButton(day: day, payload: payload)
                if model.isUpdatingFavorite {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            ArchivedWallpaperApplyControl(appModel: appModel, payload: payload, compact: true)

            cacheStatusRow(day: day, payload: payload)

            Divider()
            storySection(payload: payload)
            Divider()
            provenanceSection(payload: payload)

            if !otherRegionOccurrences(excluding: payload).isEmpty {
                Divider()
                otherRegionDayRecords(excluding: payload)
            }
        }
    }

    // MARK: Other regions on the same date

    private func otherRegionOccurrences(excluding payload: TodayPayload) -> [WallpaperOccurrence] {
        guard let day = recap.monthlyRecap?.days.first(where: {
            $0.date == payload.sourceDate
        }) else {
            return []
        }
        return day.occurrences.filter { $0.id != payload.key }
    }

    /// Keeps the old recap's cross-region day browsing without duplicating the
    /// current market's image. The expandable rows show the real matched story
    /// for each occurrence and apply that region's exact original image.
    private func otherRegionDayRecords(excluding payload: TodayPayload) -> some View {
        let occurrences = otherRegionOccurrences(excluding: payload)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(occurrences, id: \.id) { occurrence in
                    otherRegionOccurrenceRow(occurrence)
                    if occurrence.id != occurrences.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Label("其他地区记录", systemImage: "globe")
                .font(.callout.weight(.semibold))
        }
    }

    private func otherRegionOccurrenceRow(_ occurrence: WallpaperOccurrence) -> some View {
        let payload = recap.applyPayload(for: occurrence)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LocalePresentation.marketName(for: occurrence.market, in: locale))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color(nsColor: .quaternaryLabelColor).opacity(0.12),
                        in: Capsule()
                    )

                Text(recap.title(for: occurrence) ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                otherRegionFavoriteButton(occurrence)
            }

            if let payload {
                Label(
                    payload.hasOriginal
                        ? "原图已缓存"
                        : (payload.hasThumbnail ? "预览已缓存" : "图片未缓存"),
                    systemImage: payload.hasOriginal
                        ? "photo.fill"
                        : (payload.hasThumbnail ? "photo" : "photo.badge.exclamationmark")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            otherRegionStoryDisclosure(occurrence)

            if let payload {
                ArchivedWallpaperApplyControl(
                    appModel: appModel,
                    payload: payload,
                    compact: true
                )
            }
        }
    }

    @ViewBuilder
    private func otherRegionStoryDisclosure(_ occurrence: WallpaperOccurrence) -> some View {
        switch recap.storyPresentation(for: occurrence) {
        case .available(let story):
            DisclosureGroup {
                RecapStoryDetailView(story: story)
                    .padding(.top, 6)
            } label: {
                Label("本日介绍", systemImage: "text.book.closed")
                    .font(.caption.weight(.semibold))
            }
        default:
            Text("该地区暂无可用介绍")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func otherRegionFavoriteButton(_ occurrence: WallpaperOccurrence) -> some View {
        let isFavorite = recap.isFavorite(occurrence.wallpaperID)
        return Button {
            if isFavorite {
                recap.requestRemoveFavorite(occurrence.wallpaperID)
            } else {
                Task { await recap.addFavorite(occurrence.wallpaperID) }
            }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(recap.isPerformingAction || recap.isLoading)
        .help(isFavorite ? "取消收藏（需要确认）" : "收藏后该图片不会被自动缓存清理")
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
    }

    private func favoriteButton(day: TimelineDay, payload: TodayPayload) -> some View {
        let isFavorite = day.content?.isFavorite == true
        return Button {
            Task {
                await model.toggleFavorite(payload.wallpaperID)
                await recap.reload()
            }
        } label: {
            Label(
                isFavorite ? "已收藏" : "收藏",
                systemImage: isFavorite ? "heart.fill" : "heart"
            )
        }
        .buttonStyle(.bordered)
        .tint(.pink)
        .disabled(model.isUpdatingFavorite)
        .help(isFavorite ? "取消收藏这张图片" : "收藏这张图片")
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
    }

    private func cacheStatusRow(day: TimelineDay, payload: TodayPayload) -> some View {
        HStack(spacing: 6) {
            LibraryTag(
                text: payload.hasOriginal
                    ? "原图已缓存"
                    : (payload.hasThumbnail ? "预览已缓存" : "图片未缓存"),
                systemImage: payload.hasOriginal
                    ? "photo.fill"
                    : (payload.hasThumbnail ? "photo" : "photo.badge.exclamationmark"),
                active: payload.hasOriginal || payload.hasThumbnail
            )
            LibraryTag(
                text: storyTagText(payload),
                systemImage: payload.storyMatch?.availableStory != nil
                    ? "text.book.closed.fill"
                    : "text.book.closed",
                active: payload.storyMatch?.availableStory != nil
            )
            if day.content?.isFavorite == true {
                LibraryTag(text: "已收藏", systemImage: "heart.fill", active: true)
            }
        }
    }

    private func storyTagText(_ payload: TodayPayload) -> LocalizedStringKey {
        if payload.storyMatch?.availableStory != nil { return "介绍已缓存" }
        if payload.storyMatch?.story != nil { return "介绍不可用" }
        return "无介绍记录"
    }

    private func payloadTitle(_ payload: TodayPayload) -> String {
        payload.title ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current)
    }

    // MARK: Story

    private func storySection(payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("每日介绍", systemImage: "text.book.closed")
                .font(.headline)

            switch StoryPanel.make(from: payload) {
            case .available(let story):
                availableStory(story)
            case .unavailable(let reason, let title, let headline, let copyright, let sourceURL):
                Text("该地区暂无可用介绍")
                    .font(.callout.weight(.semibold))
                Text(StoryCopy.unavailableReason(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let headline, !headline.isEmpty {
                    Text(headline)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let title, !title.isEmpty {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let copyright, !copyright.isEmpty {
                    Text("版权：\(copyright)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let sourceURL {
                    Link("查看来源页面", destination: sourceURL)
                        .font(.caption)
                }
            case .unmatched(let hasCandidates):
                Text(hasCandidates ? "无法确认介绍属于这张图片" : "未取得当日介绍")
                    .font(.callout.weight(.semibold))
                Text(
                    hasCandidates
                        ? "当天有介绍，但无法确认它属于这张图片，因此没有显示，以免错配。"
                        : "该地区可能未提供当日介绍，或本次获取失败。不会用相邻日期或其他地区文本填充。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .notFetched:
                Text("尚未缓存当日介绍")
                    .font(.callout.weight(.semibold))
                Text("缺失介绍不会影响图片使用，也不会用虚构文本补齐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func availableStory(_ story: StoryText) -> some View {
        if let headline = story.headline, !headline.isEmpty {
            Text(headline)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let title = story.title, !title.isEmpty {
            Text(title)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let quickFact = story.quickFact, !quickFact.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("来源速览")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(quickFact)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 11)
                    .background(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: 3)
                            .padding(.vertical, 1)
                    }
            }
            .padding(.vertical, 2)
        }

        if let body = story.body, !body.isEmpty {
            Text(body)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let copyright = story.copyright, !copyright.isEmpty {
            Text("版权：\(copyright)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if let sourceURL = story.sourceURL {
                    Link("查看原文", destination: sourceURL)
                        .font(.caption)
                }
                Spacer(minLength: 0)
                storyFooter(story)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let sourceURL = story.sourceURL {
                    Link("查看原文", destination: sourceURL)
                        .font(.caption)
                }
                storyFooter(story)
            }
        }
    }

    private func storyFooter(_ story: StoryText) -> some View {
        Text(StoryCopy.provenance(localeTag: story.locale, fetchedAt: story.fetchedAt, in: locale))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: State panels

    private func stateDetail(
        day: TimelineDay,
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Color(nsColor: .quaternaryLabelColor).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(libraryLongDate(day.date)) · \(libraryWeekday(day.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("地区 \(LocalePresentation.marketName(for: day.market, in: locale))", systemImage: "globe")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func provenanceSection(payload: TodayPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("来源信息")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)
            Text("来源日期 \(payload.sourceDate.iso8601) · 地区 \(LocalePresentation.marketTag(for: payload.market, in: locale))")
            if let cachedAt = payload.cachedAt {
                Text("本地记录 \(StatusFormatter.dateTime(cachedAt, locale: locale))")
            }
            if let sourceURL = payload.sourceURL {
                Link("查看图片来源页面", destination: sourceURL)
            }
            Text("日期按来源地区的日历计算，不根据本机时钟推断。")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Detail image

private struct LibraryDetailImage: View {
    let model: LibraryModel
    let payload: TodayPayload

    @State private var image: NSImage?
    @State private var didAttempt = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.10))

            if let image {
                // Show the whole wallpaper rather than cropping its edges.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            } else if !didAttempt {
                ProgressView()
                    .controlSize(.small)
            } else {
                failurePlaceholder
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 5) {
                LibraryOverlayBadge(
                    text: payload.hasOriginal
                        ? "原图"
                        : (payload.hasThumbnail ? "预览图" : "未缓存")
                )
                if payload.hasOriginal {
                    LibraryOverlayBadge(text: "离线可用")
                }
            }
            .padding(9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.50))
        }
        .task(id: imageTaskID) {
            image = nil
            didAttempt = false
            image = await model.detailImage(for: payload)
            didAttempt = true
        }
    }

    private var failurePlaceholder: some View {
        VStack(spacing: 5) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 22, weight: .light))
            Text(payload.hasOriginal || payload.hasThumbnail ? "缓存图片无法读取" : "图片未缓存")
                .font(.caption.weight(.semibold))
            Text("介绍与来源信息仍可单独使用；不会用占位图伪装成来源图片。")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(12)
    }

    private var imageTaskID: String {
        "\(payload.key)|\(payload.originalURL?.path ?? "")|\(payload.thumbnailURL?.path ?? "")"
    }
}

// MARK: - Small components

private struct LibraryMetric: View {
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    let systemImage: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint ?? Color.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct LibraryTag: View {
    let text: LocalizedStringKey
    let systemImage: String
    let active: Bool

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                active
                    ? Color.accentColor.opacity(0.10)
                    : Color(nsColor: .quaternaryLabelColor).opacity(0.10),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        active
                            ? Color.accentColor.opacity(0.20)
                            : Color.clear
                    )
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .lineLimit(1)
    }
}

private struct LibraryOverlayBadge: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}

// MARK: - Date formatting

/// Formats a time-zone-free `LocalDate` through the user's locale so month and
/// weekday names follow the app's language and regional conventions.
///
/// `LocalDate` is anchored at noon in a fixed UTC calendar and formatted in
/// that same zone; this keeps the printed calendar date identical to the
/// source date regardless of the device's time zone or DST rules.
private enum LibraryDateFormat {
    private static let timeZone = TimeZone(secondsFromGMT: 0) ?? .current

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// Date names must follow the interface language, which can differ from
    /// the system locale. `.autoupdatingCurrent` would reintroduce the
    /// mixed-language UI this formatter exists to avoid.
    private static func style(for locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    }

    /// 2024-01-01 was a Monday, matching the Monday-first columns produced by
    /// `LibraryCalendarMath.weekdayIndex(for:)`.
    static var weekdaySymbols: [String] {
        let locale = WallpaperInterfaceLocale.current
        guard let monday = LocalDate(year: 2024, month: 1, day: 1) else { return [] }
        return (0..<7).compactMap { offset in
            guard let localDate = monday.adding(days: offset),
                  let date = date(for: localDate)
            else {
                return nil
            }
            return style(for: locale).weekday(.abbreviated).format(date)
        }
    }

    static func date(for localDate: LocalDate) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = localDate.year
        components.month = localDate.month
        components.day = localDate.day
        components.hour = 12
        return calendar.date(from: components)
    }

    static func longDate(
        _ localDate: LocalDate,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        guard let date = date(for: localDate) else { return localDate.iso8601 }
        return Date.FormatStyle(
            date: .long,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ).format(date)
    }

    static func monthDay(
        _ localDate: LocalDate,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        guard let date = date(for: localDate) else { return localDate.iso8601 }
        return style(for: locale).month(.abbreviated).day().format(date)
    }

    static func monthTitle(
        year: Int,
        month: Int,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        guard let localDate = LocalDate(year: year, month: month, day: 1) else {
            return "\(year)-\(month)"
        }
        guard let date = date(for: localDate) else { return localDate.iso8601 }
        return style(for: locale).year().month(.wide).format(date)
    }

    static func weekday(
        _ localDate: LocalDate,
        width: Date.FormatStyle.Symbol.Weekday = .abbreviated,
        locale: Locale = WallpaperInterfaceLocale.current
    ) -> String {
        guard let date = date(for: localDate) else { return localDate.iso8601 }
        return style(for: locale).weekday(width).format(date)
    }
}

private func libraryLongDate(_ date: LocalDate) -> String {
    LibraryDateFormat.longDate(date)
}

private func libraryMonthDay(_ date: LocalDate) -> String {
    LibraryDateFormat.monthDay(date)
}

private func libraryWeekday(_ date: LocalDate) -> String {
    LibraryDateFormat.weekday(date)
}

/// Joins accessibility fragments with the interface language's list
/// separators instead of the system locale's.
private func libraryList(_ parts: [String]) -> String {
    LocalePresentation.joined(parts, in: WallpaperInterfaceLocale.current)
}

// MARK: - Archived wallpaper apply

/// Applies one archived image through the app-wide wallpaper pipeline.
///
/// The control never selects an image on its own, never substitutes Today's
/// payload, and never presents a second confirmation. `AppModel` resolves this
/// exact payload's original file (downloading it when it is not cached) and
/// the app presents its single shared confirmation. This view only exposes
/// the target display and reports per-item progress or failure.
struct ArchivedWallpaperApplyControl: View {
    let appModel: AppModel
    let payload: TodayPayload
    var compact = false

    @State private var didRequest = false

    private var isThisPayload: Bool {
        appModel.applyingPayloadKey == payload.key
    }

    private var isBusy: Bool {
        appModel.applyingPayloadKey != nil
            || appModel.isPreparingConsent
            || appModel.isApplyingWallpaper
            || appModel.isDownloadingOriginal
            || appModel.pendingWallpaperConfirmation != nil
    }

    private var canApply: Bool {
        !isBusy && !appModel.displays.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                applyButton
                displayTargetControl
                Spacer(minLength: 0)
            }

            if !payload.hasOriginal {
                Text("原图未缓存：应用前会先下载这张历史图片的原图。离线或下载失败时只报错，不会改用今日图片或缩略图。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appModel.displays.isEmpty {
                Label("没有可用的显示器，无法应用壁纸。", systemImage: "display.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            feedback
        }
        .onChange(of: payload.key) { _, _ in
            didRequest = false
        }
    }

    private var applyButton: some View {
        Button(action: requestApply) {
            if isThisPayload {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressLabel)
                }
            } else {
                Label(buttonTitle, systemImage: "photo.on.rectangle")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(compact ? .small : .regular)
        .disabled(!canApply)
        .help(buttonHelp)
        .accessibilityLabel(buttonTitle)
        .accessibilityHint("只会修改所选显示器当前可访问的桌面，并显示一次确认。")
    }

    @ViewBuilder
    private var displayTargetControl: some View {
        if appModel.displays.count > 1 {
            Menu {
                ForEach(appModel.displays) { display in
                    Button {
                        appModel.selectDisplay(display.id)
                    } label: {
                        if display.id == effectiveDisplay?.id {
                            Label(display.label, systemImage: "checkmark")
                        } else {
                            Text(display.label)
                        }
                    }
                }
            } label: {
                Label(displayTargetLabel, systemImage: "display")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy)
            .help("选择应用壁纸的显示器；只修改当前可访问的桌面。")
            .accessibilityLabel("应用至 \(displayTargetLabel)")
        } else if !appModel.displays.isEmpty {
            Label(displayTargetLabel, systemImage: "display")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("应用至这台显示器；只修改当前可访问的桌面。")
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if didRequest && !isThisPayload {
            if let error = appModel.wallpaperError, !error.isEmpty {
                Label {
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let message = appModel.wallpaperStatusMessage, !message.isEmpty {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
    }

    private var effectiveDisplay: DesktopDisplayOption? {
        if let selected = appModel.selectedDisplayID,
           let display = appModel.displays.first(where: { $0.id == selected }) {
            return display
        }
        return appModel.displays.first
    }

    private var displayTargetLabel: String {
        effectiveDisplay?.label ?? MacLocalizedString.resolve("未命名显示器", locale: WallpaperInterfaceLocale.current)
    }

    private var buttonTitle: LocalizedStringKey {
        if payload.hasOriginal {
            return "设为壁纸…"
        }
        return "下载原图并设为壁纸…"
    }

    private var progressLabel: LocalizedStringKey {
        if appModel.isApplyingWallpaper {
            return "正在应用壁纸"
        }
        if !payload.hasOriginal, appModel.pendingWallpaperConfirmation == nil {
            return "正在下载原图"
        }
        return "正在准备写入确认…"
    }

    private var buttonHelp: String {
        guard !appModel.displays.isEmpty else {
            return MacLocalizedString.resolve("没有可用的显示器，无法应用壁纸。", locale: WallpaperInterfaceLocale.current)
        }
        if payload.hasOriginal {
            return MacLocalizedString.resolve("应用这张历史图片的原图；只显示一次确认。", locale: WallpaperInterfaceLocale.current)
        }
        return MacLocalizedString.resolve("先下载这张历史图片的原图，再显示确认。不会改用今日图片。", locale: WallpaperInterfaceLocale.current)
    }

    private func requestApply() {
        didRequest = true
        appModel.beginApplyWallpaper(for: payload)
    }
}
