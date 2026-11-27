import DaybreakCore
import SwiftUI

// MARK: - Month grid

struct TimelineMonthGrid: View {
    let month: TimelineMonth
    let isWide: Bool
    let onSelect: (LocalDate) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var calendar: Calendar {
        TimelineCalendarMath.displayCalendar(locale: locale, timeZone: model.timeZone)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 4),
                    count: 7
                ),
                spacing: 4
            ) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear
                        .frame(minHeight: cellHeight)
                        .accessibilityHidden(true)
                }
                ForEach(month.days) { day in
                    TimelineDayCell(
                        day: day,
                        isSelected: model.selectedDate == day.date,
                        isToday: day.date == month.asOf,
                        cellHeight: cellHeight,
                        maxPixelSize: isWide ? 240 : 180,
                        onSelect: {
                            onSelect(day.date)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("日历"))
    }

    private var weekdaySymbols: [String] {
        let symbols = TimelineCalendarMath.weekdaySymbols(calendar: calendar)
        return symbols.isEmpty ? ["日", "一", "二", "三", "四", "五", "六"] : symbols
    }

    private var leadingBlanks: Int {
        TimelineCalendarMath.leadingBlankCount(
            for: month,
            firstWeekday: calendar.firstWeekday
        )
    }

    private var cellHeight: CGFloat {
        let base: CGFloat = isWide ? 54 : 48
        switch dynamicTypeSize {
        case .accessibility1: return base + 10
        case .accessibility2: return base + 18
        case .accessibility3, .accessibility4, .accessibility5: return base + 26
        default: return base
        }
    }
}

struct TimelineDayCell: View {
    let day: TimelineDay
    let isSelected: Bool
    let isToday: Bool
    let cellHeight: CGFloat
    let maxPixelSize: CGFloat
    let onSelect: () -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background)
                .overlay {
                    if hasImage {
                        TimelineThumbnailView(
                            wallpaperID: day.content?.wallpaperID,
                            maxPixelSize: maxPixelSize,
                            showsPlaceholder: false
                        )
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.42), .clear, .black.opacity(0.18)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, minHeight: cellHeight)
                // Labels sit above the image in an overlay so a decoded
                // thumbnail can never widen the grid slot or push the date
                // number outside the cell (the Duo split overflow).
                .overlay {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 2) {
                            Text(day.date.day, format: .number)
                                .font(.callout.weight(day.date == model.asOf ? .bold : .semibold))
                                .foregroundStyle(numberColor)
                                .shadow(color: hasImage ? .black.opacity(0.55) : .clear, radius: 1.5)
                            Spacer(minLength: 0)
                            if model.isFavorite(day.content?.wallpaperID) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.pink)
                                    .shadow(color: .black.opacity(0.4), radius: 1)
                                    .accessibilityHidden(true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(5)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
        .accessibilityIdentifier("timeline.day.\(day.date.iso8601)")
    }

    private var hasImage: Bool {
        day.content?.thumbnailCached == true || day.content?.originalCached == true
    }

    private var numberColor: Color {
        hasImage ? .white : .primary
    }

    private var background: Color {
        switch day.state {
        case .observed:
            return Color(uiColor: .secondarySystemFill)
        case .notRecorded:
            return Color(uiColor: .quaternarySystemFill)
        case .beforeObservationStart:
            return Color(uiColor: .quaternarySystemFill).opacity(0.6)
        case .future:
            return Color.clear
        }
    }

    private var borderColor: Color {
        if isSelected {
            return .accentColor
        }
        if isToday {
            return Color.accentColor.opacity(0.5)
        }
        return .clear
    }

    private var borderWidth: CGFloat {
        isSelected ? 2.5 : (isToday ? 1.5 : 0)
    }


    private var accessibilityLabel: String {
        let dateText = TimelinePresentation.fullDate(
            day.date,
            locale: locale,
            timeZone: model.timeZone
        )
        return dateText
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isToday {
            parts.append(MobileLocalizedString.resolve("今天", locale: locale))
        }
        switch day.state {
        case .observed:
            parts.append(MobileLocalizedString.resolve("已有本地记录", locale: locale))
            if let content = day.content {
                parts.append(
                    content.thumbnailCached
                        ? MobileLocalizedString.resolve("缩略图已缓存", locale: locale)
                        : MobileLocalizedString.resolve("缩略图未缓存", locale: locale)
                )
                if content.originalCached {
                    parts.append(MobileLocalizedString.resolve("原图已缓存", locale: locale))
                }
                if model.isFavorite(content.wallpaperID) {
                    parts.append(MobileLocalizedString.resolve("已收藏", locale: locale))
                }
                if content.story.isAvailable {
                    parts.append(MobileLocalizedString.resolve("介绍可用", locale: locale))
                } else if content.story.record != nil {
                    parts.append(MobileLocalizedString.resolve("介绍不可用", locale: locale))
                } else {
                    parts.append(MobileLocalizedString.resolve("没有本地介绍", locale: locale))
                }
            }
        case .notRecorded:
            parts.append(MobileLocalizedString.resolve("本机未记录", locale: locale))
        case .beforeObservationStart:
            parts.append(MobileLocalizedString.resolve("早于本地首次记录", locale: locale))
        case .future:
            parts.append(MobileLocalizedString.resolve("尚未到来的日期", locale: locale))
        }
        return parts.joined(separator: MobileLocalizedString.resolve("，", locale: locale))
    }
}

// MARK: - Calendar content

struct TimelineCalendarView: View {
    let isWide: Bool
    let onOpenDay: (LocalDate) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var showsPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.display == .month {
                    monthContent
                } else {
                    yearContent
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
        .sheet(isPresented: $showsPicker) {
            TimelineMonthYearPicker(
                initialYear: model.display == .year ? model.displayYear : model.monthKey.year
            )
                .environment(model)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            fullHeader
            compactHeader
            stackedHeader
        }
    }

    private var fullHeader: some View {
        HStack(spacing: 10) {
            previousPeriodButton
            periodPickerButton
            nextPeriodButton
            Spacer(minLength: 8)
            marketMenu
            displayToggleButton
        }
    }

    private var compactHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                previousPeriodButton
                Spacer(minLength: 0)
                periodPickerButton
                Spacer(minLength: 0)
                nextPeriodButton
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                marketMenu
                displayToggleButton
            }
        }
    }

    private var stackedHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                periodPickerButton
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                previousPeriodButton
                Spacer(minLength: 0)
                marketMenu
                displayToggleButton
                Spacer(minLength: 0)
                nextPeriodButton
            }
        }
    }

    private var previousPeriodButton: some View {
        Button {
            if model.display == .month {
                model.goToPreviousMonth()
            } else {
                model.goToPreviousYear()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(model.display == .month ? !model.canGoToPreviousMonth : !model.canGoToPreviousYear)
        .accessibilityLabel(model.display == .month ? Text("上个月") : Text("上一年"))
    }

    private var periodPickerButton: some View {
        Button {
            showsPicker = true
        } label: {
            HStack(spacing: 5) {
                Group {
                    if model.display == .month {
                        TimelineDateText(locale: locale, timeZone: model.timeZone)
                            .month(model.monthKey)
                    } else {
                        TimelineDateText(locale: locale, timeZone: model.timeZone)
                            .year(model.displayYear)
                    }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("打开月份和年份选择"))
    }

    private var nextPeriodButton: some View {
        Button {
            if model.display == .month {
                model.goToNextMonth()
            } else {
                model.goToNextYear()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(model.display == .month ? !model.canGoToNextMonth : !model.canGoToNextYear)
        .accessibilityLabel(model.display == .month ? Text("下个月") : Text("下一年"))
    }

    private var displayToggleButton: some View {
        Button {
            model.setDisplay(model.display == .month ? .year : .month)
        } label: {
            Image(systemName: model.display == .month ? "square.grid.3x3" : "calendar")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(model.display == .month ? Text("切换到年视图") : Text("切换到月视图"))
    }

    private var marketMenu: some View {
        Menu {
            if model.availableMarkets.isEmpty {
                Text("没有已缓存图片的地区")
                    .disabled(true)
            } else {
                ForEach(model.availableMarkets, id: \.self) { market in
                    Button {
                        Task { await model.setMarket(market) }
                    } label: {
                        if market == model.market {
                            Label(
                                TimelinePresentation.marketName(for: market, in: locale),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(verbatim: TimelinePresentation.marketName(for: market, in: locale))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text("地区"))
        .accessibilityValue(
            Text(verbatim: TimelinePresentation.marketName(for: model.market, in: locale))
        )
    }


    @ViewBuilder
    private var monthContent: some View {
        if let month = model.month {
            TimelineMonthGrid(
                month: month,
                isWide: isWide,
                onSelect: onOpenDay
            )
            TimelineMonthLegend(month: month)
            TimelineMonthSummaryStrip(month: month)
            Button {
                model.setRecapScope(.month)
                model.setSection(.recap)
            } label: {
                Label("查看本月回顾", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
            .accessibilityHint(Text("打开本月的本地统计与收藏"))
        } else if model.loadState == .loading {
            ProgressView("正在读取本月记录")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            TimelineStateCard(
                systemImage: "calendar.badge.exclamationmark",
                title: Text("无法显示这个月"),
                message: Text("本地记录暂时不可读。可以下拉刷新或稍后重试。")
            )
        }
    }

    @ViewBuilder
    private var yearContent: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 10)],
            spacing: 10
        ) {
            ForEach(model.yearMonths) { summary in
                TimelineYearMonthCard(
                    summary: summary,
                    isFuture: summary.year == model.asOf.year && summary.month > model.asOf.month,
                    onOpen: {
                        model.goToMonth(year: summary.year, month: summary.month)
                    }
                )
            }
        }
        Text("年视图只列出本地记录数量；没有记录的月份不代表 Bing 当月没有发布壁纸。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TimelineMonthLegend: View {
    let month: TimelineMonth

    var body: some View {
        HStack(spacing: 10) {
            legendDot(color: .accentColor, text: Text("今天"))
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .frame(width: 8, height: 8)
                Text("有记录")
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 0.8)
                    .frame(width: 8, height: 8)
                Text("未记录")
            }
            HStack(spacing: 3) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.pink)
                Text("收藏")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func legendDot(color: Color, text: Text) -> some View {
        HStack(spacing: 4) {
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: 7, height: 7)
            text
        }
    }
}

struct TimelineMonthSummaryStrip: View {
    let month: TimelineMonth

    var body: some View {
        HStack(spacing: 0) {
            stat(
                value: month.observedDayCount,
                total: eligibleDayCount(month),
                title: Text("已记录")
            )
            Divider().frame(height: 32)
            stat(
                value: month.favoriteDayCount,
                total: month.observedDayCount,
                title: Text("收藏")
            )
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
    }

    private func eligibleDayCount(_ month: TimelineMonth) -> Int {
        month.days.lazy.filter { $0.state == .observed || $0.state == .notRecorded }.count
    }

    private func stat(value: Int, total: Int, title: Text) -> some View {
        VStack(spacing: 2) {
            title
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(value)/\(max(total, 0))")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

struct TimelineYearMonthCard: View {
    let summary: TimelineYearMonthSummary
    let isFuture: Bool
    let onOpen: () -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    TimelineDateText(locale: locale, timeZone: model.timeZone)
                        .monthName(summary.month, year: summary.year)
                        .font(.headline)
                    Spacer(minLength: 4)
                    if summary.favoriteImageCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(summary.favoriteImageCount, format: .number)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.pink)
                    }
                }

                if isFuture {
                    Text("尚未到来")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if summary.hasRecords {
                    Text("记录 \(summary.observedDays)/\(eligibleDays(summary)) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ProgressView(
                        value: Double(summary.observedDays),
                        total: Double(max(eligibleDays(summary), 1))
                    )
                    .tint(.accentColor)

                } else {
                    Text("没有本地记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("不代表 Bing 当月没有发布壁纸")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .opacity(isFuture ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityHint(Text("打开这个月的日历"))
    }

    /// Days that count toward this month's local coverage: the month is clipped
    /// to the observation start and to the market-local today. Pre-install and
    /// future days are never part of the denominator.
    private func eligibleDays(_ summary: TimelineYearMonthSummary) -> Int {
        let firstDay = 1
        var lastDay = summary.totalDays
        if summary.year == model.asOf.year, summary.month == model.asOf.month {
            lastDay = min(lastDay, model.asOf.day)
        }
        var startDay = firstDay
        if let firstObserved = model.firstObservedDate,
           firstObserved.year == summary.year,
           firstObserved.month == summary.month {
            startDay = max(startDay, firstObserved.day)
        }
        guard lastDay >= startDay else { return 0 }
        return lastDay - startDay + 1
    }

    private var accessibilityLabel: String {
        let monthName = TimelinePresentation.monthName(
            month: summary.month,
            year: summary.year,
            locale: locale,
            timeZone: model.timeZone
        )
        if isFuture {
            return monthName + MobileLocalizedString.resolve("，尚未到来", locale: locale)
        }
        if !summary.hasRecords {
            return monthName + MobileLocalizedString.resolve("，没有本地记录", locale: locale)
        }
        return monthName + String(
            format: MobileLocalizedString.resolve("，记录 %lld 天，收藏 %lld 张", locale: locale),
            summary.observedDays,
            summary.favoriteImageCount
        )
    }
}

// MARK: - Month / year picker

struct TimelineMonthYearPicker: View {
    let initialYear: Int

    @Environment(TimelineModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var year: Int

    init(initialYear: Int) {
        self.initialYear = initialYear
        _year = State(initialValue: initialYear)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    yearSelector
                    monthGrid
                }
                .padding(16)
            }
            .navigationTitle("选择月份", locale: locale)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("本月") {
                        model.goToCurrentMonth()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        model.goToYear(year)
                        dismiss()
                    } label: {
                        Label("查看 \(year) 年", systemImage: "square.grid.3x3")
                    }
                }
            }
        }
    }

    private var yearSelector: some View {
        HStack(spacing: 12) {
            Button {
                year = max(model.browsableYears.lowerBound, year - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(year <= model.browsableYears.lowerBound)
            .accessibilityLabel(Text("上一年"))
            Menu {
                Picker("年份", selection: $year) {
                    ForEach(model.browsableYears, id: \.self) { value in
                        Text(verbatim: String(value)).tag(value)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: TimelinePresentation.yearTitle(
                        year,
                        locale: locale,
                        timeZone: model.timeZone
                    ))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 120, minHeight: 44)
            }
            .accessibilityLabel(Text("年份"))

            Button {
                year = min(model.browsableYears.upperBound, year + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(year >= model.browsableYears.upperBound)
            .accessibilityLabel(Text("下一年"))

            Spacer(minLength: 0)
        }
    }

    private var monthGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 100), spacing: 10)],
            spacing: 10
        ) {
            ForEach(1...12, id: \.self) { month in
                monthButton(month)
            }
        }
    }

    private func monthButton(_ month: Int) -> some View {
        let key = TimelineMonthKey(year: year, month: month)
        let current = TimelineMonthKey(containing: model.asOf)
        let earliest = TimelineMonthKey(year: model.browsableYears.lowerBound, month: 1)
        let isFuture = key > current
        let isUnavailable = key < earliest
        let isCurrentMonth = key == current
        return Button {
            model.goToMonth(year: year, month: month)
            dismiss()
        } label: {
            VStack(spacing: 4) {
                Text(verbatim: TimelinePresentation.monthName(
                    month: month,
                    year: year,
                    locale: locale,
                    timeZone: model.timeZone
                ))
                .font(.body.weight(isCurrentMonth ? .semibold : .regular))
                if isCurrentMonth {
                    Text("本月")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isFuture {
                    Text("尚未到来")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isCurrentMonth
                            ? Color.accentColor.opacity(0.16)
                            : Color(uiColor: .secondarySystemBackground)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isFuture || isUnavailable)
        .opacity(isFuture ? 0.5 : 1)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isCurrentMonth ? .isSelected : AccessibilityTraits())
    }
}
