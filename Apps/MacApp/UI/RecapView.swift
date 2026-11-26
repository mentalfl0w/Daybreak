import AppKit
import DaybreakCore
import SwiftUI

/// Monthly, yearly and favorite recaps reconstructed from local records only.
///
/// Missing days are never filled with zero-valued rows, and no story text is
/// presented unless the repository's strict matcher returned an available
/// record for that exact source/market/date and image.
///
/// Layout note: the scroll content is measured against the actual scroll
/// viewport and the card grids derive a fixed column count from that width.
/// The previous implicitly sized adaptive grid could report a width wider than
/// the detail column; the vertical scroll view then centred that content and
/// clipped the leading edge of the first observation card. Explicit column
/// counts and a capped content column keep every card inside the viewport.
struct RecapView: View {
    let model: RecapScreenModel
    /// Storage is a tab inside Settings; this asks the app shell to select it.
    let onOpenStorage: () -> Void

    @State private var selectedDay: LocalDate? = nil
    @State private var viewportWidth: CGFloat = 0
    @Environment(\.locale) private var locale

    init(model: RecapScreenModel, onOpenStorage: @escaping () -> Void) {
        self.model = model
        self.onOpenStorage = onOpenStorage
    }

    var body: some View {
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
        .navigationTitle("回顾")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .onAppear {
            Task {
                await model.reload()
                alignSelectedDay()
            }
        }
        .onChange(of: model.monthlyRecap) { _, _ in
            alignSelectedDay()
        }
        .onChange(of: model.section) { _, _ in
            Task {
                await model.reload()
                alignSelectedDay()
            }
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

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("视图", selection: sectionBinding) {
                ForEach(RecapSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 190)
            .help("在月度、年度与收藏之间切换")
            .accessibilityLabel("回顾视图")

            Button {
                Task {
                    await model.reload()
                    alignSelectedDay()
                }
            } label: {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isLoading)
            .help("重新读取本地记录并重新计算回顾")
            .accessibilityLabel("刷新回顾")

            Button(action: onOpenStorage) {
                Image(systemName: "externaldrive")
            }
            .help("管理缓存、收藏保护与孤立文件")
            .accessibilityLabel("存储与收藏保护")
        }
    }

    private var subtitle: String {
        var parts = [MacLocalizedString.resolve("仅统计本机记录", locale: WallpaperInterfaceLocale.current)]
        if let asOf = model.asOf {
            parts.append(String(format: MacLocalizedString.resolve("截至 %@", locale: WallpaperInterfaceLocale.current), asOf.iso8601))
        }
        return parts.joined(separator: " · ")
    }

    private var sectionBinding: Binding<RecapSection> {
        Binding(
            get: { model.section },
            set: { model.selectSection($0) }
        )
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { model.pendingCleanup != nil },
            set: { newValue in
                if !newValue { model.cancelPendingCleanup() }
            }
        )
    }

    private func alignSelectedDay() {
        guard let days = model.monthlyRecap?.days, !days.isEmpty else {
            selectedDay = nil
            return
        }
        if let selectedDay, days.contains(where: { $0.date == selectedDay }) {
            return
        }
        selectedDay = days.last?.date
    }

    // MARK: Content

    private var isLoadingWithoutData: Bool {
        model.isLoading
            && model.monthlyRecap == nil
            && model.yearlyRecap == nil
            && model.favoriteRecap == nil
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingWithoutData {
            loadingState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    sectionContent(width: contentWidth)
                }
                .frame(maxWidth: 1_080, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: RecapViewportWidthKey.self,
                            value: proxy.size.width
                        )
                    }
                )
            }
            .onPreferenceChange(RecapViewportWidthKey.self) { width in
                guard width > 0, abs(width - viewportWidth) > 0.5 else { return }
                viewportWidth = width
            }
        }
    }

    private var horizontalPadding: CGFloat {
        viewportWidth < 760 ? 16 : 24
    }

    private var contentWidth: CGFloat {
        min(max(1, viewportWidth - horizontalPadding * 2), 1_080)
    }

    @ViewBuilder
    private func sectionContent(width: CGFloat) -> some View {
        switch model.section {
        case .monthly:
            monthlyContent(width: width)
        case .yearly:
            yearlyContent(width: width)
        case .favorites:
            favoritesContent(width: width)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在读取本地记录并计算回顾…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineLoading(_ message: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    // MARK: Monthly

    @ViewBuilder
    private func monthlyContent(width: CGFloat) -> some View {
        monthNavigator

        if let recap = model.monthlyRecap {
            RecapCoverageCard(summary: recap.summary, context: .month)

            if recap.days.isEmpty {
                emptyMonthState
            } else {
                daySection(recap, width: width)

                if let day = recap.days.first(where: { $0.date == selectedDay }) {
                    RecapDayDetailCard(day: day, model: model)
                }
            }
        } else if model.isLoading {
            inlineLoading("正在计算本月回顾…")
        } else {
            unavailableState
        }
    }

    private var monthNavigator: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(model.selectedYear))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(model.selectedMonth)月")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                RecapCopy.monthTitle(year: model.selectedYear, month: model.selectedMonth)
            )

            HStack(spacing: 6) {
                Button {
                    Task {
                        await model.showPreviousMonth()
                        alignSelectedDay()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("上一个月")
                .help("上一个月")

                Button {
                    Task {
                        await model.showNextMonth()
                        alignSelectedDay()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canGoToNextMonth)
                .accessibilityLabel("下一个月")
                .help(model.canGoToNextMonth ? MacLocalizedString.resolve("下一个月", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("不能浏览未来月份", locale: WallpaperInterfaceLocale.current))
            }
            .padding(.leading, 4)

            Spacer(minLength: 10)

            if !model.isCurrentMonth {
                Button("回到本月") {
                    Task {
                        await model.goToCurrentMonth()
                        alignSelectedDay()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func daySection(_ recap: MonthlyRecap, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("有记录的日期")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(recap.days.count) 天")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("仅列本地记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(
                columns: cardColumns(
                    for: width,
                    minimumItemWidth: 186,
                    maximumColumns: 5,
                    spacing: 14
                ),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(recap.days) { day in
                    Button {
                        selectedDay = day.date
                    } label: {
                        RecapDayTile(
                            day: day,
                            model: model,
                            isSelected: day.date == selectedDay
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dayAccessibilityLabel(day))
                    .accessibilityHint("查看这一天的地区记录与介绍")
                    .accessibilityAddTraits(
                        day.date == selectedDay ? .isSelected : AccessibilityTraits()
                    )
                }
            }

            Text("只列出本机有记录的日期；没有记录的日期不会列出，也不会补成 0 张图片。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func dayAccessibilityLabel(_ day: RecapDay) -> String {
        var parts = [
            RecapCopy.dayTitle(day.date),
            String(format: MacLocalizedString.resolve("%lld 张图片", locale: locale), day.imageCount)
        ]
        let markets = model.markets(for: day)
        if !markets.isEmpty {
            parts.append(RecapCopy.marketsLabel(markets, in: locale))
        }
        if day.hasAvailableStory {
            parts.append(MacLocalizedString.resolve("有可读介绍", locale: locale))
        }
        if !day.favoriteImageIDs.isEmpty {
            parts.append(
                String(format: MacLocalizedString.resolve("%lld 张收藏", locale: locale), day.favoriteImageIDs.count)
            )
        }
        return LocalePresentation.joined(parts, in: locale)
    }

    private var emptyMonthState: some View {
        let isCurrent = model.isCurrentMonth
        let action: (() -> Void)?
        if isCurrent {
            action = nil
        } else {
            action = {
                Task {
                    await model.goToCurrentMonth()
                    alignSelectedDay()
                }
            }
        }

        return RecapEmptyState(
            icon: "calendar.badge.exclamationmark",
            title: MacLocalizedString.resolve("该月没有本地记录", locale: WallpaperInterfaceLocale.current),
            message: model.monthEmptyReason(year: model.selectedYear, month: model.selectedMonth),
            actionTitle: isCurrent ? nil : MacLocalizedString.resolve("回到本月", locale: WallpaperInterfaceLocale.current),
            action: action
        )
    }

    // MARK: Yearly

    @ViewBuilder
    private func yearlyContent(width: CGFloat) -> some View {
        yearNavigator

        if let recap = model.yearlyRecap {
            if recap.summary.hasObservations && !recap.summary.hasComparableObservations {
                insufficientYearBanner(recap.summary)
            }

            RecapCoverageCard(summary: recap.summary, context: .year)

            if recap.months.isEmpty {
                emptyYearState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("有记录的月份")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("\(recap.months.count) 个月")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: cardColumns(
                            for: width,
                            minimumItemWidth: 280,
                            maximumColumns: 3,
                            spacing: 14
                        ),
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(recap.months) { month in
                            Button {
                                Task {
                                    await model.openMonth(year: month.year, month: month.month)
                                    alignSelectedDay()
                                }
                            } label: {
                                RecapMonthCard(month: month, model: model)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(RecapCopy.monthTitle(year: month.year, month: month.month))，记录 \(month.observedDays) 天，出现 \(month.occurrenceCount) 次；查看该月明细"
                            )
                            .accessibilityHint("打开这一月的日期记录")
                        }
                    }

                    Text("只列出本机有记录的月份；没有列出的月份表示本机当月没有保存记录，不代表 Bing 当时没有发布图片。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if model.isLoading {
            inlineLoading("正在计算年度回顾…")
        } else {
            unavailableState
        }
    }

    private var yearNavigator: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(String(model.selectedYear))年")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .accessibilityLabel("\(String(model.selectedYear))年")

            HStack(spacing: 6) {
                Button {
                    Task {
                        await model.showPreviousYear()
                        alignSelectedDay()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("上一年")
                .help("上一年")

                Button {
                    Task {
                        await model.showNextYear()
                        alignSelectedDay()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canGoToNextYear)
                .accessibilityLabel("下一年")
                .help(model.canGoToNextYear ? MacLocalizedString.resolve("下一年", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("不能浏览未来年份", locale: WallpaperInterfaceLocale.current))
            }
            .padding(.leading, 4)

            Spacer(minLength: 10)

            if !model.isCurrentYear {
                Button("回到今年") {
                    Task {
                        await model.goToCurrentYear()
                        alignSelectedDay()
                    }
                }
                .buttonStyle(.bordered)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func insufficientYearBanner(_ summary: RecapSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("本机记录不足以生成年度精选")
                    .font(.callout.weight(.semibold))
                Text("只有 \(summary.observedDays) 个有记录的日期。这里只展示实际存在的内容，不生成“全年最佳”或“完整年度”结论。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var emptyYearState: some View {
        let isCurrent = model.isCurrentYear
        let action: (() -> Void)?
        if isCurrent {
            action = nil
        } else {
            action = {
                Task {
                    await model.goToCurrentYear()
                    alignSelectedDay()
                }
            }
        }

        return RecapEmptyState(
            icon: "calendar.badge.exclamationmark",
            title: MacLocalizedString.resolve("该年没有本地记录", locale: WallpaperInterfaceLocale.current),
            message: model.yearEmptyReason(year: model.selectedYear),
            actionTitle: isCurrent ? nil : MacLocalizedString.resolve("回到今年", locale: WallpaperInterfaceLocale.current),
            action: action
        )
    }

    // MARK: Favorites

    @ViewBuilder
    private func favoritesContent(width: CGFloat) -> some View {
        if let recap = model.favoriteRecap {
            FavoriteSummaryCard(recap: recap)

            Text("月份按每张图片最早的本地记录归组，不是收藏操作的时间。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !recap.months.isEmpty {
                favoriteMonthChips(recap.months, width: width)
            }

            if recap.entries.isEmpty {
                emptyFavoritesState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("收藏图片")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("\(recap.entries.count) 张")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: cardColumns(
                            for: width,
                            minimumItemWidth: 230,
                            maximumColumns: 4,
                            spacing: 14
                        ),
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(recap.entries) { entry in
                            FavoriteTile(entry: entry, model: model, appModel: nil)
                        }
                    }

                    if recap.hasUndatedFavorites {
                        Text("\(recap.undatedFavoriteImageCount) 张收藏没有本机日期记录，已列在末尾；不会为它们编造日期。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } else if model.isLoading {
            inlineLoading("正在读取收藏…")
        } else {
            unavailableState
        }
    }

    private func favoriteMonthChips(_ months: [FavoriteMonth], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最早记录月份")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(
                columns: cardColumns(
                    for: width,
                    minimumItemWidth: 132,
                    maximumColumns: 6,
                    spacing: 8
                ),
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

    private var emptyFavoritesState: some View {
        RecapEmptyState(
            icon: "star",
            title: MacLocalizedString.resolve("还没有收藏", locale: WallpaperInterfaceLocale.current),
            message: MacLocalizedString.resolve("在每日内容或回顾中点击星标即可收藏。收藏图片会保护其缓存，不会被自动清理删除。", locale: WallpaperInterfaceLocale.current)
        )
    }

    private var unavailableState: some View {
        RecapEmptyState(
            icon: "calendar.badge.exclamationmark",
            title: MacLocalizedString.resolve("暂无可显示的回顾数据", locale: WallpaperInterfaceLocale.current),
            message: MacLocalizedString.resolve("回顾只读取本机已经保存的记录。没有记录时不会补写图片、日期或介绍。", locale: WallpaperInterfaceLocale.current),
            actionTitle: MacLocalizedString.resolve("重新读取", locale: WallpaperInterfaceLocale.current),
            action: {
                Task {
                    await model.reload()
                    alignSelectedDay()
                }
            },
            isActionDisabled: model.isLoading
        )
    }

    // MARK: Banners

    private func loadErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("重试") {
                Task {
                    await model.reload()
                    alignSelectedDay()
                }
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
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
        .background(tint.opacity(0.10))
    }

    // MARK: Layout

    private func cardColumns(
        for width: CGFloat,
        minimumItemWidth: CGFloat,
        maximumColumns: Int,
        spacing: CGFloat
    ) -> [GridItem] {
        let fitting = Int((max(width, 1) + spacing) / (minimumItemWidth + spacing))
        let count = max(1, min(maximumColumns, fitting))
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: spacing),
            count: count
        )
    }
}

/// Measures the scroll view's content viewport rather than the outer split
/// view. A macOS scroll view that reserves legacy scroller space proposes a
/// narrower content width, and using the outer width there would push the
/// trailing edge of every grid outside the visible area.
private struct RecapViewportWidthKey: SwiftUI.PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Coverage card

/// A measured, content-first coverage summary. The denominator and its dates
/// sit beside the recorded-day count, and an em dash replaces the percentage
/// when the repository cannot establish a first observed date.
struct RecapCoverageCard: View {
    enum Context {
        case month
        case year
    }

    let summary: RecapSummary
    let context: Context
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(context == .month ? MacLocalizedString.resolve("本月记录", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("本年记录", locale: WallpaperInterfaceLocale.current))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 5) {
                    Circle()
                        .fill(stateTint)
                        .frame(width: 6, height: 6)
                    Text(RecapCopy.coverageStateLabel(summary.coverageState))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(stateTint.opacity(0.12), in: Capsule())

                Spacer(minLength: 8)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(summary.observedDays)")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()

                Text("天有记录")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(RecapCopy.percentage(summary.coverage))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text("覆盖率")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("覆盖率")
                .accessibilityValue(RecapCopy.percentage(summary.coverage))
            }

            denominatorSummary

            if let coverage = summary.coverage {
                ProgressView(value: coverage)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .accessibilityLabel("记录覆盖率")
                    .accessibilityValue(RecapCopy.percentage(coverage))
            }

            Divider()

            HStack(spacing: 0) {
                RecapFigure(title: "图片", value: "\(summary.uniqueImageCount)", unit: "张")
                divider
                RecapFigure(title: "出现次数", value: "\(summary.totalOccurrences)", unit: "次")
                divider
                RecapFigure(title: "有介绍", value: "\(summary.storyCoveredDays)", unit: "天")
                divider
                RecapFigure(title: "收藏图片", value: "\(summary.favoriteImageCount)", unit: "张")
            }

            VStack(alignment: .leading, spacing: 3) {
                if marketLines.isEmpty {
                    Text("统计范围内没有记录到任何地区。")
                } else {
                    Text("涉及 \(summary.distinctMarketCount) 个地区 · 各地区有记录的天数：\(marketLines)")
                }
                if summary.coverage != nil {
                    Text("覆盖率 = 有记录的天数 ÷ 统计范围内的天数，只反映本机保存了多少天。")
                }
                Text("没有记录的日期可能是应用未运行、内容未获取或请求失败，不代表 Bing 当天没有发布图片。")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
    }

    /// Shows the denominator and its dates in the same place as the recorded
    /// day count. When no honest denominator exists the text says why instead
    /// of presenting a percentage with a guessed total.
    @ViewBuilder
    private var denominatorSummary: some View {
        if let eligible = summary.eligibleDays {
            if eligible == 0 {
                if let firstObservedDate = summary.firstObservedDate {
                    Text("该范围与本机可统计的区间（首次记录 \(firstObservedDate.iso8601) 至统计截止 \(summary.asOf.iso8601)）没有重叠，因此没有可统计的日期。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("该范围没有可统计的日期。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let range = summary.effectiveRange {
                VStack(alignment: .leading, spacing: 2) {
                    Text("统计范围 \(RecapCopy.rangeLabel(range))，共 \(eligible) 天")
                    if let unobserved = summary.unobservedDays, unobserved > 0 {
                        Text("其余 \(unobserved) 天没有本机记录")
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        } else {
            Text("还不知道本机从哪天开始有记录，因此没有总天数可对照。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Divider()
            .frame(height: 30)
            .padding(.horizontal, 14)
    }

    private var marketLines: String {
        summary.marketDayCounts
            .keys
            .sorted()
            .map { market in
                String(
                    format: MacLocalizedString.resolve("%@ %lld 天", locale: locale),
                    RecapCopy.marketLabel(market, in: locale),
                    summary.marketDayCounts[market] ?? 0
                )
            }
            .joined(separator: " · ")
    }

    private var stateTint: Color {
        switch summary.coverageState {
        case .complete: return .green
        case .partial: return .accentColor
        case .noObservation, .firstObservedDateUnknown: return .secondary
        }
    }
}

struct RecapFigure: View {
    let title: LocalizedStringKey
    let value: String
    var unit: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty states

private struct RecapEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var isActionDisabled: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(isActionDisabled)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

// MARK: - Day tiles

private struct RecapDayTile: View {
    let day: RecapDay
    let model: RecapScreenModel
    let isSelected: Bool
    @Environment(\.locale) private var locale

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RecapThumbnail(
                    url: model.dayThumbnailURL(for: day),
                    model: model,
                    maxPixelSize: 440,
                    cornerRadius: 11
                )
                .aspectRatio(16.0 / 10.0, contentMode: .fit)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.70)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .allowsHitTesting(false)

                Text(RecapCopy.dayTitle(day.date))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                    .padding(9)
            }
            .overlay(alignment: .topTrailing) {
                if day.hasAvailableStory || !day.favoriteImageIDs.isEmpty {
                    HStack(spacing: 4) {
                        if day.hasAvailableStory {
                            Image(systemName: "text.book.closed")
                                .foregroundStyle(.white.opacity(0.94))
                        }
                        if !day.favoriteImageIDs.isEmpty {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.38), in: Capsule())
                    .padding(7)
                }
            }

            HStack(spacing: 5) {
                Text("\(day.imageCount) 张")
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(RecapCopy.marketsLabel(model.markets(for: day), in: locale))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            shape.fill(
                isSelected
                    ? Color.accentColor.opacity(0.10)
                    : Color(nsColor: .controlBackgroundColor)
            )
        )
        .overlay(
            shape.strokeBorder(
                isSelected
                    ? Color.accentColor
                    : Color(nsColor: .separatorColor).opacity(0.45),
                lineWidth: isSelected ? 2 : 1
            )
        )
        .contentShape(shape)
    }
}

// MARK: - Day detail

private struct RecapDayDetailCard: View {
    let day: RecapDay
    let model: RecapScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.date.iso8601)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("\(day.occurrences.count) 条地区记录 · \(day.imageCount) 张图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if day.storyAvailableOccurrenceCount > 0 {
                    Label(
                        "\(day.storyAvailableOccurrenceCount) 条可读介绍",
                        systemImage: "text.book.closed"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            VStack(spacing: 0) {
                ForEach(day.occurrences, id: \.id) { occurrence in
                    RecapOccurrenceRow(occurrence: occurrence, model: model)
                    if occurrence.id != day.occurrences.last?.id {
                        Divider()
                            .padding(.vertical, 16)
                    }
                }
            }

            Text("同一天可能包含多个地区的记录；同一张图片也可能跨日期或地区重复出现。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct RecapOccurrenceRow: View {
    let occurrence: WallpaperOccurrence
    let model: RecapScreenModel
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RecapThumbnail(
                url: model.thumbnailURL(for: occurrence.wallpaperID),
                model: model,
                maxPixelSize: 640,
                cornerRadius: 10
            )
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(width: 260)

            details
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                RecapChip(text: RecapCopy.marketTag(occurrence.market, in: locale))
                if let sourceLocale = model.originalLocale(for: occurrence), !sourceLocale.isEmpty {
                    Text(LocalePresentation.sourceLanguageName(sourceLocale, in: locale))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                favoriteButton
            }

            Text(model.title(for: occurrence) ?? MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current))
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let copyright = model.copyright(for: occurrence), !copyright.isEmpty {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            cacheStatus

            storySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cacheStatus: some View {
        let thumbnailCached = model.thumbnailURL(for: occurrence.wallpaperID) != nil
        let originalCached = model.originalURL(for: occurrence.wallpaperID) != nil
        let sourceURL = model.sourceURL(for: occurrence)

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                cacheLabel(.thumbnail, isCached: thumbnailCached)
                cacheLabel(.original, isCached: originalCached)
                if let sourceURL {
                    Link("来源页面", destination: sourceURL)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                cacheLabel(.thumbnail, isCached: thumbnailCached)
                cacheLabel(.original, isCached: originalCached)
                if let sourceURL {
                    Link("来源页面", destination: sourceURL)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private enum CachedItem {
        case thumbnail
        case original

        func statusLabel(isCached: Bool) -> LocalizedStringKey {
            switch self {
            case .thumbnail:
                return isCached ? "缩略图已缓存" : "缩略图未缓存"
            case .original:
                return isCached ? "原图已缓存" : "原图未缓存"
            }
        }
    }

    private func cacheLabel(_ item: CachedItem, isCached: Bool) -> some View {
        Label(
            item.statusLabel(isCached: isCached),
            systemImage: isCached ? "checkmark.circle" : "circle.dashed"
        )
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if model.isFavorite(occurrence.wallpaperID) {
            Button {
                model.requestRemoveFavorite(occurrence.wallpaperID)
            } label: {
                Label("已收藏", systemImage: "star.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.isPerformingAction || model.isLoading)
            .help("取消收藏前会显示确认")
        } else {
            Button {
                Task { await model.addFavorite(occurrence.wallpaperID) }
            } label: {
                Label("收藏", systemImage: "star")
            }
            .buttonStyle(.borderless)
            .disabled(model.isPerformingAction || model.isLoading)
            .help("收藏后该图片不会被自动缓存清理")
        }
    }

    @ViewBuilder
    private var storySection: some View {
        switch model.storyPresentation(for: occurrence) {
        case .available(let story):
            RecapNoteBlock(tint: .accentColor) {
                RecapStoryDetailView(story: story)
            }

        case .unavailable(let reason, let headline, let copyright, let sourceURL):
            RecapNoteBlock {
                VStack(alignment: .leading, spacing: 4) {
                    Label("本日介绍暂不可用", systemImage: "text.book.closed")
                        .font(.caption.weight(.semibold))
                    Text(StoryCopy.unavailableReason(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let headline, !headline.isEmpty {
                        Text(headline)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let copyright, !copyright.isEmpty {
                        Text(copyright)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let sourceURL {
                        Link("来源页面", destination: sourceURL)
                            .font(.caption)
                    }
                }
            }

        case .unmatched(let hasCandidates):
            RecapNoteBlock {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasCandidates ? MacLocalizedString.resolve("无法确认介绍属于这张图片", locale: WallpaperInterfaceLocale.current) : MacLocalizedString.resolve("该日未保存介绍", locale: WallpaperInterfaceLocale.current))
                        .font(.caption.weight(.semibold))
                    Text(
                        hasCandidates
                            ? MacLocalizedString.resolve("当天有介绍，但无法确认它属于这张图片，因此没有显示，以免错配。", locale: WallpaperInterfaceLocale.current)
                            : MacLocalizedString.resolve("该日期可能未获取介绍，或来源未提供。不会用相邻日期或其他地区的文本补齐。", locale: WallpaperInterfaceLocale.current)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .notFetched:
            RecapNoteBlock {
                VStack(alignment: .leading, spacing: 3) {
                    Text("该日未保存介绍")
                        .font(.caption.weight(.semibold))
                    Text("介绍缺失不会影响图片浏览；不会用虚构文本补齐。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RecapStoryDetailView: View {
    let story: StoryText
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本日介绍", systemImage: "text.book.closed")
                .font(.caption.weight(.semibold))

            if let headline = story.headline, !headline.isEmpty {
                Text(headline)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let title = story.title, !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let quickFact = story.quickFact, !quickFact.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("来源速览")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(quickFact)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let body = story.body, !body.isEmpty {
                Text(body)
                    .font(.callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let copyright = story.copyright, !copyright.isEmpty {
                Text(copyright)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if let sourceURL = story.sourceURL {
                    Link("查看原文", destination: sourceURL)
                        .font(.caption)
                }
                Text(StoryCopy.provenance(localeTag: story.locale, fetchedAt: story.fetchedAt, in: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet note treatment with a single leading rule. It keeps story text and
/// honest unavailability explanations from turning the page into a stack of
/// bordered boxes.
private struct RecapNoteBlock<Content: View>: View {
    var tint: Color = .secondary
    let content: Content

    init(tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(.leading, 11)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint.opacity(0.32))
                    .frame(width: 2)
            }
    }
}

private struct RecapChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                in: Capsule()
            )
    }
}

// MARK: - Month cards

struct RecapMonthCard: View {
    let month: RecapMonth
    let model: RecapScreenModel
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(month.month)月")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(RecapCopy.percentage(model.monthCoverage(month)))
                    .font(.headline)
                    .monospacedDigit()
                    .accessibilityLabel(coverageAccessibilityLabel)
            }

            Text(RecapCopy.marketsLabel(month.marketDayCounts.keys.sorted(), in: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            coverage

            VStack(alignment: .leading, spacing: 2) {
                Text("\(month.uniqueImageCount) 张图片 · \(month.occurrenceCount) 次出现")
                    .monospacedDigit()
                if month.favoriteImageCount > 0 || month.storyCoveredDays > 0 {
                    Text(favoriteAndStoryLine)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text("查看该月明细")
                    .font(.caption)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var coverage: some View {
        if let eligible = model.eligibleDays(year: month.year, month: month.month) {
            if eligible > 0 {
                ProgressView(value: model.monthCoverage(month) ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("\(month.observedDays) / \(eligible) 天有记录")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("无可统计日期")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("无法统计总天数")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var coverageAccessibilityLabel: String {
        guard let coverage = model.monthCoverage(month) else {
            return MacLocalizedString.resolve("覆盖率无法计算", locale: WallpaperInterfaceLocale.current)
        }
        return String(
            format: MacLocalizedString.resolve("覆盖率 %@", locale: WallpaperInterfaceLocale.current),
            RecapCopy.percentage(coverage)
        )
    }

    private var favoriteAndStoryLine: String {
        var parts: [String] = []
        if month.favoriteImageCount > 0 {
            parts.append(
                String(format: MacLocalizedString.resolve("%lld 张收藏", locale: WallpaperInterfaceLocale.current), month.favoriteImageCount)
            )
        }
        if month.storyCoveredDays > 0 {
            parts.append(
                String(format: MacLocalizedString.resolve("%lld 天有介绍", locale: WallpaperInterfaceLocale.current), month.storyCoveredDays)
            )
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Favorite cards

struct FavoriteSummaryCard: View {
    let recap: FavoriteRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("收藏概览")
                        .font(.headline)
                    Text("按图片去重，不按收藏操作计数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(recap.favoriteImageCount)")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text("张")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                RecapFigure(title: "有日期记录", value: "\(recap.datedFavoriteImageCount)", unit: "张")
                Divider()
                    .frame(height: 30)
                    .padding(.horizontal, 14)
                RecapFigure(title: "无日期记录", value: "\(recap.undatedFavoriteImageCount)", unit: "张")
                Divider()
                    .frame(height: 30)
                    .padding(.horizontal, 14)
                RecapFigure(title: "出现次数", value: "\(recap.totalOccurrences)", unit: "次")
                Divider()
                    .frame(height: 30)
                    .padding(.horizontal, 14)
                RecapFigure(title: "出现天数", value: "\(recap.distinctObservedDays)", unit: "天")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("不同地区 \(recap.distinctMarketCount) 个 · 统计截至 \(recap.asOf.iso8601)")
                Text("收藏数量按图片去重；同一图片在不同地区或日期出现只算一张。这里不推测收藏操作的时间。")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

struct FavoriteTile: View {
    let entry: FavoriteEntry
    let model: RecapScreenModel
    var appModel: AppModel? = nil
    @Environment(\.locale) private var locale

    private var latestOccurrence: WallpaperOccurrence? {
        model.latestOccurrence(for: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RecapThumbnail(
                    url: model.thumbnailURL(for: entry.wallpaperID),
                    model: model,
                    maxPixelSize: 640,
                    cornerRadius: 11
                )
                .aspectRatio(16.0 / 10.0, contentMode: .fit)

                Button {
                    model.requestRemoveFavorite(entry.wallpaperID)
                } label: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(.black.opacity(0.44), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isPerformingAction || model.isLoading)
                .help("取消收藏（需要确认）")
                .accessibilityLabel("取消收藏 \(displayTitle)")
                .padding(7)
            }

            Text(displayTitle)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(RecapCopy.favoriteDateRange(entry))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !entry.markets.isEmpty {
                Text(RecapCopy.marketsLabel(entry.markets, in: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !entry.isDated {
                Text("本机没有这张图片的日期记录。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let appModel,
                      let occurrence = latestOccurrence,
                      let payload = model.applyPayload(for: occurrence) {
                ArchivedWallpaperApplyControl(
                    appModel: appModel,
                    payload: payload,
                    compact: true
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var displayTitle: String {
        if let occurrence = latestOccurrence,
           let title = model.title(for: occurrence),
           !title.isEmpty {
            return title
        }
        if let title = model.title(for: entry.wallpaperID), !title.isEmpty {
            return title
        }
        return MacLocalizedString.resolve("来源未提供标题", locale: WallpaperInterfaceLocale.current)
    }
}

// MARK: - Thumbnail

/// Bounded, off-main-thread decode of an already cached image. File existence
/// is derived from the repository snapshot, so this view performs no direct
/// disk checks on the main actor.
struct RecapThumbnail: View {
    let url: URL?
    let model: RecapScreenModel
    let maxPixelSize: Int
    let cornerRadius: CGFloat

    @State private var image: NSImage? = nil

    init(
        url: URL?,
        model: RecapScreenModel,
        maxPixelSize: Int,
        cornerRadius: CGFloat
    ) {
        self.url = url
        self.model = model
        self.maxPixelSize = maxPixelSize
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))

            if let image {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else if url == nil {
                VStack(spacing: 3) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("未缓存")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            await load()
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let loaded = await model.thumbnailImage(at: url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

// MARK: - Apply support

extension RecapScreenModel {
    /// Rebuilds the exact archive payload for one recorded occurrence. The
    /// payload points at the cached thumbnail/original when present; the app
    /// model downloads that same image's original when it is missing. The
    /// current Today payload is never consulted.
    func applyPayload(for occurrence: WallpaperOccurrence) -> TodayPayload? {
        guard let snapshot else { return nil }
        let metadata = snapshot.metadata(for: occurrence.id)
        let wallpaper = snapshot.wallpapers.first {
            $0.wallpaperID == occurrence.wallpaperID
        }
        return TodayPayload(
            market: occurrence.market,
            marketToday: asOf ?? occurrence.localDate,
            occurrence: occurrence,
            metadata: metadata,
            wallpaper: wallpaper,
            storyMatch: snapshot.storyMatch(for: occurrence.id),
            thumbnailURL: thumbnailURL(for: occurrence.wallpaperID),
            originalURL: originalURL(for: occurrence.wallpaperID),
            cachedAt: metadata?.fetchedAt ?? wallpaper?.fetchedAt
        )
    }
}
