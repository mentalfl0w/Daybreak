import DaybreakCore
import SwiftUI

struct TimelineRecapView: View {
    let onOpenDate: (LocalDate) -> Void
    let onOpenOccurrence: (OccurrenceKey) -> Void
    let onOpenMonth: (Int, Int) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(
                    "回顾范围",
                    selection: Binding(
                        get: { model.recapScope },
                        set: { model.setRecapScope($0) }
                    )
                ) {
                    Text("本月").tag(TimelineRecapScope.month)
                    Text("年度").tag(TimelineRecapScope.year)
                    Text("收藏").tag(TimelineRecapScope.favorites)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("回顾范围"))

                if model.recapScope != .favorites {
                    HStack(spacing: 8) {
                        Text("统计范围")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(
                            "统计范围",
                            selection: Binding(
                                get: { model.recapMarketScope },
                                set: { model.setRecapMarketScope($0) }
                            )
                        ) {
                            Text("所有地区").tag(TimelineRecapMarketScope.allMarkets)
                            Text("当前地区").tag(TimelineRecapMarketScope.currentMarket)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel(Text("统计范围"))
                    }
                }

                if model.recapMarketScope == .allMarkets, model.recapScope != .favorites {
                    Text("统计包含本机实际记录的所有地区；同一天多地区只按日期计数。下方日期格仍显示当前地区。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch model.recapScope {
                case .month:
                    monthContent
                case .year:
                    yearContent
                case .favorites:
                    favoritesContent
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

    // MARK: Month

    @ViewBuilder
    private var monthContent: some View {
        HStack(spacing: 10) {
            Button {
                model.goToPreviousMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(!model.canGoToPreviousMonth)
            .accessibilityLabel(Text("上个月"))

            TimelineDateText(locale: locale, timeZone: model.timeZone)
                .month(model.monthKey)
                .font(.title3.weight(.semibold))

            Button {
                model.goToNextMonth()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(!model.canGoToNextMonth)
            .accessibilityLabel(Text("下个月"))

            Spacer(minLength: 8)

            Button {
                model.setSection(.calendar)
            } label: {
                Label("日历", systemImage: "calendar")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
        }

        if let data = model.monthRecap {
            TimelineRecapStatsGrid(summary: data.recap.summary)
            TimelineCoverageNote(summary: data.recap.summary)

            if data.recap.summary.observedDays > 0 {
                monthImageGrid(data)
                TimelineRecapMonthGrid(month: data.month, onOpenDate: onOpenDate)
                if !favoriteIDs(in: data).isEmpty {
                    favoriteStrip(
                        ids: favoriteIDs(in: data),
                        title: Text("本月收藏")
                    )
                }
            } else {
                TimelineStateCard(
                    systemImage: "calendar.badge.exclamationmark",
                    title: Text("本月没有本地记录"),
                    message: Text("没有记录不代表 Bing 当月没有发布壁纸。应用未运行、该地区未启用或获取失败都可能造成空白。")
                )
            }
        } else {
            ProgressView("正在计算本月回顾")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }

    private func monthImageGrid(_ data: TimelineMonthRecapData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本月图片")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 8)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(data.recap.days) { day in
                    if let occurrence = day.occurrences.first {
                        Button {
                            onOpenOccurrence(occurrence.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                TimelineThumbnailView(
                                    wallpaperID: occurrence.wallpaperID,
                                    maxPixelSize: 240,
                                    showsPlaceholder: true
                                )
                                .frame(maxWidth: .infinity)
                                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    if !day.favoriteImageIDs.isEmpty {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.pink)
                                            .padding(4)
                                            .background(Circle().fill(.background.opacity(0.85)))
                                            .padding(4)
                                    }
                                }
                                TimelineDateText(locale: locale, timeZone: model.timeZone)
                                    .short(day.date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if model.recapMarketScope == .allMarkets {
                                    Text(verbatim: TimelinePresentation.marketShortName(
                                        for: occurrence.market,
                                        in: locale
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: TimelinePresentation.fullDate(
                            day.date,
                            locale: locale,
                            timeZone: model.timeZone
                        )))
                        .accessibilityHint(Text("打开这一天的图片与介绍"))
                    }
                }
            }
        }
    }

    private func favoriteStrip(ids: [WallpaperID], title: Text) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ids, id: \.self) { wallpaperID in
                        TimelineThumbnailView(
                            wallpaperID: wallpaperID,
                            maxPixelSize: 220,
                            showsPlaceholder: true
                        )
                        .frame(width: 84, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func favoriteIDs(in data: TimelineMonthRecapData) -> [WallpaperID] {
        var seen: Set<WallpaperID> = []
        var result: [WallpaperID] = []
        for day in data.recap.days {
            for id in day.favoriteImageIDs where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    // MARK: Year

    @ViewBuilder
    private var yearContent: some View {
        HStack(spacing: 10) {
            Button {
                model.goToPreviousYear()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(!model.canGoToPreviousYear)
            .accessibilityLabel(Text("上一年"))

            TimelineDateText(locale: locale, timeZone: model.timeZone)
                .year(model.displayYear)
                .font(.title3.weight(.semibold))

            Button {
                model.goToNextYear()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(!model.canGoToNextYear)
            .accessibilityLabel(Text("下一年"))

            Spacer(minLength: 8)

            Button {
                model.setSection(.calendar)
                model.setDisplay(.year)
            } label: {
                Label("年历", systemImage: "square.grid.3x3")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .tint(.daybreakActionTint)
        }

        if let data = model.yearRecap {
            if data.recap.summary.observedDays == 0 {
                TimelineStateCard(
                    systemImage: "chart.bar.xaxis",
                    title: Text("尚不足以生成年度回顾"),
                    message: Text("这一年没有本地记录，无法计算覆盖率或选出图片。Daybreak 不会补写不存在的历史。")
                )
            } else {
                if !data.recap.summary.hasComparableObservations {
                    TimelineStateCard(
                        systemImage: "chart.bar.xaxis",
                        title: Text("记录较少"),
                        message: Text("本地记录少于两天，尚不足以生成可比较的年度结论；下面只列出实际保存的内容。")
                    )
                }
                TimelineRecapStatsGrid(summary: data.recap.summary)
                TimelineCoverageNote(summary: data.recap.summary)
                yearImageGrid()
                yearMonthGrid(data)
                observedMonthsList(data)
            }
        } else {
            ProgressView("正在计算年度回顾")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }

    @ViewBuilder
    private func yearImageGrid() -> some View {
        let keys = model.yearImageKeys()
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("年度图片")
                    .font(.headline)
                Text("每个有记录的日期显示一张代表图片；同一天的其他地区记录可在日期详情中查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 8)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(keys, id: \.self) { key in
                        Button {
                            onOpenOccurrence(key)
                        } label: {
                            TimelineThumbnailView(
                                wallpaperID: model.wallpaperID(for: key),
                                maxPixelSize: 240,
                                showsPlaceholder: true
                            )
                            .frame(maxWidth: .infinity)
                            .aspectRatio(3.0 / 2.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .bottomLeading) {
                                TimelineDateText(locale: locale, timeZone: model.timeZone)
                                    .short(key.localDate)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.55)))
                                    .padding(4)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: TimelinePresentation.fullDate(
                            key.localDate,
                            locale: locale,
                            timeZone: model.timeZone
                        )))
                        .accessibilityHint(Text("打开这一天的图片与介绍"))
                    }
                }
            }
        }
    }

    private func yearMonthGrid(_ data: TimelineYearRecapData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("月度记录")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 116, maximum: 200), spacing: 8)],
                spacing: 8
            ) {
                ForEach(data.months) { summary in
                    Button {
                        onOpenMonth(summary.year, summary.month)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            TimelineDateText(locale: locale, timeZone: model.timeZone)
                                .monthName(summary.month, year: summary.year)
                                .font(.subheadline.weight(.medium))
                            if summary.observedDays > 0 {
                                Text("\(summary.observedDays)/\(summary.totalDays) 天")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if summary.favoriteImageCount > 0 {
                                    Label(
                                        "\(summary.favoriteImageCount)",
                                        systemImage: "heart.fill"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                                    .monospacedDigit()
                                }
                            } else {
                                Text("无记录")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("打开这个月的日历"))
                }
            }
        }
    }

    @ViewBuilder
    private func observedMonthsList(_ data: TimelineYearRecapData) -> some View {
        if !data.recap.months.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("有记录的月份")
                    .font(.headline)
                Text("只统计本机实际保存的日期，不代表 Bing 全年发布数量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(data.recap.months) { month in
                        Button {
                            onOpenMonth(month.year, month.month)
                        } label: {
                            HStack(spacing: 8) {
                                TimelineDateText(locale: locale, timeZone: model.timeZone)
                                    .monthName(month.month, year: month.year)
                                    .font(.subheadline.weight(.medium))
                                Spacer(minLength: 8)
                                Text("\(month.observedDays) 天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if month.favoriteImageCount > 0 {
                                    Label("\(month.favoriteImageCount)", systemImage: "heart.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.pink)
                                        .monospacedDigit()
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if month.id != data.recap.months.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
            }
        }
    }

    // MARK: Favorites

    @ViewBuilder
    private var favoritesContent: some View {
        if let data = model.favoritesRecap {
            if data.recap.favoriteImageCount == 0 {
                TimelineStateCard(
                    systemImage: "heart",
                    title: Text("还没有收藏"),
                    message: Text("在今日或图片详情中点按收藏后，这里会按图片整理，不按日期重复。")
                )
            } else {
                TimelineRecapStatsGrid(
                    tiles: [
                        .init(
                            title: "收藏图片",
                            value: "\(data.recap.favoriteImageCount)",
                            systemImage: "heart.fill"
                        ),
                        .init(
                            title: "有日期记录",
                            value: "\(data.recap.datedFavoriteImageCount)",
                            systemImage: "calendar"
                        ),
                        .init(
                            title: "无日期记录",
                            value: "\(data.recap.undatedFavoriteImageCount)",
                            systemImage: "questionmark.folder"
                        ),
                        .init(
                            title: "涉及地区",
                            value: "\(data.recap.distinctMarketCount)",
                            systemImage: "globe"
                        )
                    ]
                )

                favoriteMonths(data)

                VStack(alignment: .leading, spacing: 8) {
                    Text("收藏图片")
                        .font(.headline)
                    Text("按图片收藏，同一张图片跨日期或跨地区只计一次。没有本地出现记录的收藏仍会保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 156, maximum: 260), spacing: 10)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(data.recap.entries) { entry in
                            TimelineFavoriteEntryCell(
                                entry: entry,
                                onOpen: {
                                    if let latest = entry.occurrences.last {
                                        onOpenOccurrence(latest.id)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        } else {
            ProgressView("正在整理收藏")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }

    @ViewBuilder
    private func favoriteMonths(_ data: TimelineFavoritesRecapData) -> some View {
        if !data.recap.months.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("收藏时间线")
                    .font(.headline)
                Text("按每张图片最早的本地记录月份整理，不代表点按收藏的时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    ForEach(data.recap.months) { month in
                        VStack(alignment: .leading, spacing: 6) {
                            TimelineDateText(locale: locale, timeZone: model.timeZone)
                                .monthName(month.month, year: month.year)
                                .font(.subheadline.weight(.medium))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(month.imageIDs, id: \.self) { wallpaperID in
                                        TimelineThumbnailView(
                                            wallpaperID: wallpaperID,
                                            maxPixelSize: 180,
                                            showsPlaceholder: true
                                        )
                                        .frame(width: 68, height: 68)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .accessibilityHidden(true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Stats

struct TimelineRecapStatTile: Identifiable {
    let title: LocalizedStringKey
    let value: String
    var caption: LocalizedStringKey? = nil
    var systemImage: String? = nil

    var id: String { "\(title)-\(value)-\(caption.map(String.init(describing:)) ?? "")" }
}

struct TimelineRecapStatsGrid: View {
    let tiles: [TimelineRecapStatTile]

    init(summary: RecapSummary) {
        var values: [TimelineRecapStatTile] = []
        values.append(
            .init(
                title: "已记录",
                value: summary.eligibleDays.map { "\(summary.observedDays)/\($0) 天" }
                    ?? "\(summary.observedDays) 天",
                caption: "观察窗口内",
                systemImage: "calendar"
            )
        )
        values.append(
            .init(
                title: "覆盖率",
                value: summary.coverage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                caption: Self.coverageCaption(summary.coverageState),
                systemImage: "chart.pie"
            )
        )
        values.append(
            .init(
                title: "收藏",
                value: "\(summary.favoriteImageCount)",
                caption: "图片去重",
                systemImage: "heart.fill"
            )
        )
        values.append(
            .init(
                title: "有介绍",
                value: "\(summary.storyCoveredDays)",
                caption: "严格匹配图片",
                systemImage: "text.book.closed"
            )
        )
        values.append(
            .init(
                title: "地区",
                value: "\(summary.distinctMarketCount)",
                caption: "有本地记录",
                systemImage: "globe"
            )
        )
        self.tiles = values
    }

    init(tiles: [TimelineRecapStatTile]) {
        self.tiles = tiles
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if let systemImage = tile.systemImage {
                            Image(systemName: systemImage)
                                .font(.caption2)
                        }
                        Text(tile.title)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    Text(verbatim: tile.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    if let caption = tile.caption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static func coverageCaption(_ state: CoverageState) -> LocalizedStringKey? {
        switch state {
        case .firstObservedDateUnknown: return "缺少观察起点"
        case .noObservation: return "窗口内无记录"
        case .partial: return "部分日期有记录"
        case .complete: return "窗口内完整"
        }
    }
}

struct TimelineCoverageNote: View {
    let summary: RecapSummary

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let range = summary.effectiveRange {
                Text("可观察区间：\(rangeText(range))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground))
        )
    }

    private var note: LocalizedStringKey {
        switch summary.coverageState {
        case .firstObservedDateUnknown:
            return "本地没有可用的观察起点，无法计算覆盖率。上面的数字只来自本机实际保存的记录。"
        case .noObservation:
            return "可观察窗口内没有本地记录，不能据此判断 Bing 没有发布壁纸。"
        case .partial:
            return "覆盖率只表示本机在可观察窗口内保存了多少天，不代表 Bing 实际发布数量。"
        case .complete:
            return "可观察窗口内的每一天都有本地记录；这仍不代表 Bing 全球范围的全部发布。"
        }
    }

    private func rangeText(_ range: LocalDateRange) -> String {
        let start = TimelinePresentation.shortDate(range.start, locale: locale, timeZone: model.timeZone)
        let end = TimelinePresentation.shortDate(range.end, locale: locale, timeZone: model.timeZone)
        return "\(start) – \(end)"
    }
}

// MARK: - Compact month grid

struct TimelineRecapMonthGrid: View {
    let month: TimelineMonth
    let onOpenDate: (LocalDate) -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    private var calendar: Calendar {
        TimelineCalendarMath.displayCalendar(locale: locale, timeZone: model.timeZone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本月日期")
                .font(.headline)
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    ForEach(Array(TimelineCalendarMath.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                        Text(verbatim: symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7),
                    spacing: 3
                ) {
                    ForEach(0..<leadingBlanks, id: \.self) { _ in
                        Color.clear.frame(height: 26)
                    }
                    ForEach(month.days) { day in
                        Button {
                            onOpenDate(day.date)
                        } label: {
                            Text(day.date.day, format: .number)
                                .font(.caption2.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(fill(for: day))
                                )
                                .overlay {
                                    if model.isFavorite(day.content?.wallpaperID) {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(.pink, lineWidth: 1.2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: TimelinePresentation.fullDate(
                            day.date,
                            locale: locale,
                            timeZone: model.timeZone
                        )))
                        .accessibilityValue(Text(accessibilityValue(day)))
                    }
                }
            }
        }
    }

    private var leadingBlanks: Int {
        TimelineCalendarMath.leadingBlankCount(for: month, firstWeekday: calendar.firstWeekday)
    }

    private func fill(for day: TimelineDay) -> Color {
        switch day.state {
        case .observed:
            return day.content?.thumbnailCached == true
                ? Color.accentColor.opacity(0.78)
                : Color.accentColor.opacity(0.38)
        case .notRecorded:
            return Color(uiColor: .quaternarySystemFill)
        case .beforeObservationStart:
            return Color(uiColor: .quaternarySystemFill).opacity(0.55)
        case .future:
            return Color.clear
        }
    }

    private func accessibilityValue(_ day: TimelineDay) -> String {
        switch day.state {
        case .observed:
            return MobileLocalizedString.resolve("有本地记录", locale: locale)
        case .notRecorded:
            return MobileLocalizedString.resolve("本机未记录", locale: locale)
        case .beforeObservationStart:
            return MobileLocalizedString.resolve("早于本地首次记录", locale: locale)
        case .future:
            return MobileLocalizedString.resolve("尚未到来", locale: locale)
        }
    }
}

// MARK: - Favorites

struct TimelineFavoriteEntryCell: View {
    let entry: FavoriteEntry
    let onOpen: () -> Void

    @Environment(TimelineModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        let latestKey = entry.occurrences.last?.id
        let title = latestKey.flatMap { model.displayTitle(for: $0) }
            ?? model.displayTitle(for: entry.wallpaperID)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .aspectRatio(3.0 / 2.0, contentMode: .fit)
                    .overlay {
                        TimelineThumbnailView(
                            wallpaperID: entry.wallpaperID,
                            maxPixelSize: 320,
                            showsPlaceholder: false
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .overlay {
                        if !entry.isDated {
                            Label("无日期记录", systemImage: "questionmark.folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                Text(title ?? MobileLocalizedString.resolve("未保存标题", locale: locale))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(title == nil ? .secondary : .primary)

                HStack(spacing: 4) {
                    if let latest = entry.latestObservedDate {
                        TimelineDateText(locale: locale, timeZone: model.timeZone)
                            .short(latest)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if entry.markets.count > 1 {
                        TimelineBadge(
                            Text("\(entry.markets.count) 个地区"),
                            systemImage: "globe"
                        )
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!entry.isDated)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel(title: title)))
        .accessibilityValue(entry.isDated ? Text("有日期记录") : Text("没有日期记录"))
    }

    private func accessibilityLabel(title: String?) -> String {
        let display = title ?? MobileLocalizedString.resolve("未保存标题", locale: locale)
        if let latest = entry.latestObservedDate {
            let date = TimelinePresentation.fullDate(latest, locale: locale, timeZone: model.timeZone)
            return "\(display)，\(date)"
        }
        return "\(display)，\(MobileLocalizedString.resolve("没有日期记录", locale: locale))"
    }
}
