import AppKit
import DaybreakCore
import Foundation
import ImageIO
import Observation

// MARK: - Image decoding

/// Bounded thumbnail decoder for the history grid and calendar.
///
/// `ImageAssetLoader` is tuned for one hero image and keeps only four decoded
/// entries. A gallery can show dozens of thumbnails at once, so this loader
/// uses the same ImageIO downsampling rules with a larger bounded cache.
actor LibraryImageLoader {
    private var cache: [String: DecodedImage] = [:]
    private var insertionOrder: [String] = []
    private let maximumEntries: Int

    init(maximumEntries: Int = 64) {
        self.maximumEntries = max(8, maximumEntries)
    }

    func image(at url: URL, maxPixelSize: Int) throws -> DecodedImage {
        let boundedSize = max(64, min(maxPixelSize, 8_192))
        let key = "\(url.path)#\(boundedSize)"
        if let cached = cache[key] {
            return cached
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ImageDecodeError.unreadableFile
        }

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw ImageDecodeError.unsupportedImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: boundedSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ImageDecodeError.unsupportedImage
        }

        let decoded = DecodedImage(
            image: NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            ),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        insert(decoded, for: key)
        return decoded
    }

    private func insert(_ image: DecodedImage, for key: String) {
        if cache[key] == nil {
            insertionOrder.append(key)
        }
        cache[key] = image
        while insertionOrder.count > maximumEntries {
            let oldest = insertionOrder.removeFirst()
            cache[oldest] = nil
        }
    }
}

// MARK: - Month identity

/// Calendar month identity for the source-local dates shown by the library.
struct LibraryMonthKey: Hashable, Sendable, Comparable, Identifiable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        let total = year * 12 + (month - 1)
        var normalizedYear = total / 12
        var normalizedMonth = total % 12
        if normalizedMonth < 0 {
            normalizedMonth += 12
            normalizedYear -= 1
        }
        self.year = normalizedYear
        self.month = normalizedMonth + 1
    }

    init(containing date: LocalDate) {
        self.init(year: date.year, month: date.month)
    }

    var id: String { "\(year)-\(month)" }

    func adding(months: Int) -> LibraryMonthKey {
        LibraryMonthKey(year: year, month: month + months)
    }

    static func < (lhs: LibraryMonthKey, rhs: LibraryMonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

// MARK: - Gallery values

enum LibraryScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites

    var id: String { rawValue }
}

/// One observed market/date occurrence as displayed in the gallery.
///
/// Flags stay separate: a thumbnail, an original, a story and a favorite are
/// independent facts and none implies another.
struct LibraryGalleryItem: Hashable, Sendable, Identifiable {
    let occurrence: WallpaperOccurrence
    let title: String?
    let copyright: String?
    let hasThumbnail: Bool
    let hasOriginal: Bool
    let isFavorite: Bool
    let hasStory: Bool
    let hasUnavailableStory: Bool

    var id: OccurrenceKey { occurrence.id }
    var wallpaperID: WallpaperID { occurrence.wallpaperID }
    var date: LocalDate { occurrence.localDate }
    var market: Market { occurrence.market }
    var sidecarTitle: String { title ?? wallpaperID.sourceImageID }
}

struct LibraryGallerySection: Hashable, Sendable, Identifiable {
    let key: LibraryMonthKey
    let items: [LibraryGalleryItem]

    var id: LibraryMonthKey { key }

    /// Preserves the input order (newest first) and groups by month.
    static func sections(from items: [LibraryGalleryItem]) -> [LibraryGallerySection] {
        var order: [LibraryMonthKey] = []
        var buckets: [LibraryMonthKey: [LibraryGalleryItem]] = [:]
        for item in items {
            let key = LibraryMonthKey(containing: item.date)
            if buckets[key] == nil {
                order.append(key)
            }
            buckets[key, default: []].append(item)
        }
        return order.map { LibraryGallerySection(key: $0, items: buckets[$0] ?? []) }
    }
}

enum LibraryGalleryBuilder {
    static func items(snapshot: RepositorySnapshot, market: Market) -> [LibraryGalleryItem] {
        var wallpapers: [WallpaperID: WallpaperRecord] = [:]
        for wallpaper in snapshot.wallpapers {
            wallpapers[wallpaper.wallpaperID] = wallpaper
        }
        let thumbnails = snapshot.availableThumbnailIDs
        let originals = snapshot.availableOriginalIDs
        let favorites = snapshot.favoriteWallpaperIDs

        return snapshot.occurrences
            .filter { $0.market == market }
            .sorted { lhs, rhs in
                if lhs.localDate != rhs.localDate {
                    return lhs.localDate > rhs.localDate
                }
                return lhs.wallpaperID < rhs.wallpaperID
            }
            .map { occurrence in
                let key = occurrence.id
                let metadata = snapshot.metadata(for: key)
                let wallpaper = wallpapers[occurrence.wallpaperID]
                let match = StoryMatcher.match(
                    occurrence: occurrence,
                    metadata: metadata,
                    stories: snapshot.stories
                )
                let hasUnavailableStory: Bool
                if case .unavailable = match {
                    hasUnavailableStory = true
                } else {
                    hasUnavailableStory = false
                }
                return LibraryGalleryItem(
                    occurrence: occurrence,
                    title: metadata?.title ?? wallpaper?.canonicalTitle,
                    copyright: metadata?.copyright ?? wallpaper?.copyright,
                    hasThumbnail: thumbnails.contains(occurrence.wallpaperID),
                    hasOriginal: originals.contains(occurrence.wallpaperID),
                    isFavorite: favorites.contains(occurrence.wallpaperID),
                    hasStory: match.availableStory != nil,
                    hasUnavailableStory: hasUnavailableStory
                )
            }
    }
}

enum LibraryCalendarMath {
    /// Monday-first weekday index: `0` is Monday and `6` is Sunday.
    ///
    /// 1970-01-01 (`dayNumber == 0`) was a Thursday, so `+3` aligns the
    /// proleptic Gregorian day number with a Monday-first column.
    static func weekdayIndex(for date: LocalDate) -> Int {
        let raw = (date.dayNumber + 3) % 7
        return raw >= 0 ? raw : raw + 7
    }

    static func leadingBlankCount(in month: TimelineMonth) -> Int {
        guard let first = month.days.first else { return 0 }
        return weekdayIndex(for: first.date)
    }
}

// MARK: - Selection

enum LibrarySelection: Equatable, Sendable {
    case observed(TimelineDay, TodayPayload)
    case observedWithoutPayload(TimelineDay)
    case notRecorded(TimelineDay)
    case beforeObservationStart(TimelineDay)
    case future(TimelineDay)

    var day: TimelineDay {
        switch self {
        case .observed(let day, _),
             .observedWithoutPayload(let day),
             .notRecorded(let day),
             .beforeObservationStart(let day),
             .future(let day):
            return day
        }
    }

    var payload: TodayPayload? {
        if case .observed(_, let payload) = self { return payload }
        return nil
    }
}

enum LibraryLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

// MARK: - Model

/// Reads one market's local history through the shared `TodayService`
/// repository. It never creates a second repository and never invents a date,
/// image, story or favorite.
@MainActor
@Observable
final class LibraryModel {
    let service: TodayService
    private(set) var market: Market
    private(set) var monthKey: LibraryMonthKey
    private(set) var scope: LibraryScope = .all
    private(set) var month: TimelineMonth?
    private(set) var galleryItems: [LibraryGalleryItem] = []
    private(set) var selectedDate: LocalDate?
    private(set) var selection: LibrarySelection?
    private(set) var loadState: LibraryLoadState = .idle
    private(set) var isUpdatingFavorite = false
    private(set) var isLoadingSelection = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    private(set) var asOf: LocalDate?

    @ObservationIgnored private let now: @Sendable () -> Date
    /// Coalescing hand-off to the one sync controller. Favorites are
    /// synchronized content; the gallery update never waits for folder IO.
    @ObservationIgnored private let noteSyncActivity: @MainActor () -> Void
    @ObservationIgnored private let imageLoader = LibraryImageLoader()
    @ObservationIgnored private var snapshot: RepositorySnapshot?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(
        service: TodayService,
        market: Market,
        now: @escaping @Sendable () -> Date = { Date() },
        noteSyncActivity: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.noteSyncActivity = noteSyncActivity
        let profile = BingMarketProfile.profile(for: market)
        self.market = profile?.market ?? market
        self.now = now
        let zone = profile?.timeZone ?? .current
        if let today = LocalDate(date: now(), timeZone: zone) {
            self.asOf = today
            self.monthKey = LibraryMonthKey(containing: today)
        } else {
            self.monthKey = LibraryMonthKey(year: 2000, month: 1)
        }
    }

    // MARK: Derived values

    var observedDayCount: Int { galleryItems.count }

    var favoriteImageCount: Int {
        Set(galleryItems.filter(\.isFavorite).map(\.wallpaperID)).count
    }

    /// Favorites are image-level. The favorites scope shows each favorite
    /// image once (its newest occurrence) so the displayed collection matches
    /// the deduplicated favorite-image count instead of repeating the same
    /// image for every date it appeared on.
    var visibleGalleryItems: [LibraryGalleryItem] {
        guard scope == .favorites else { return galleryItems }
        var seen: Set<WallpaperID> = []
        return galleryItems.filter { item in
            item.isFavorite && seen.insert(item.wallpaperID).inserted
        }
    }

    var gallerySections: [LibraryGallerySection] {
        LibraryGallerySection.sections(from: visibleGalleryItems)
    }

    var isShowingCurrentMonth: Bool {
        guard let asOf else { return false }
        return monthKey == LibraryMonthKey(containing: asOf)
    }

    var canGoToNextMonth: Bool {
        guard let asOf else { return false }
        return monthKey < LibraryMonthKey(containing: asOf)
    }

    var monthTitle: String {
        monthTitle(in: WallpaperInterfaceLocale.current)
    }

    func monthTitle(in locale: Locale) -> String {
        String(
            format: MacLocalizedString.resolve("%lld年%lld月", locale: locale),
            monthKey.year,
            monthKey.month
        )
    }

    // MARK: Loading

    func load() async {
        reloadTask?.cancel()
        reloadTask = nil
        await performReload()
    }

    func reload() async {
        await load()
    }

    /// Synchronously switches market and starts a fresh repository read.
    func updateMarket(_ newMarket: Market) {
        let resolved = BingMarketProfile.profile(for: newMarket)?.market ?? newMarket
        guard resolved != market else { return }
        market = resolved
        resetForMarketChange()
        selectedDate = nil
        if let profile = BingMarketProfile.profile(for: resolved),
           let today = LocalDate(date: now(), timeZone: profile.timeZone) {
            asOf = today
            monthKey = LibraryMonthKey(containing: today)
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.performReload()
        }
    }

    private func resetForMarketChange() {
        generation += 1
        snapshot = nil
        galleryItems = []
        month = nil
        selection = nil
        errorMessage = nil
        loadState = .loading
    }

    private func performReload() async {
        generation += 1
        let token = generation
        errorMessage = nil
        if loadState == .idle || (galleryItems.isEmpty && month == nil) {
            loadState = .loading
        }
        if case .failed = loadState {
            loadState = .loading
        }

        guard let profile = BingMarketProfile.profile(for: market) else {
            loadState = .failed(MacLocalizedString.resolve("不支持这个地区，它不在可选的 Bing 地区中。", locale: WallpaperInterfaceLocale.current))
            return
        }
        guard let today = LocalDate(date: now(), timeZone: profile.timeZone) else {
            loadState = .failed(MacLocalizedString.resolve("无法计算该地区的来源日期", locale: WallpaperInterfaceLocale.current))
            return
        }
        asOf = today
        if monthKey > LibraryMonthKey(containing: today) {
            monthKey = LibraryMonthKey(containing: today)
        }

        do {
            let repository = service.repository
            let snapshot = await repository.snapshot()
            try Task.checkCancellation()
            guard token == generation else { return }
            self.snapshot = snapshot
            galleryItems = LibraryGalleryBuilder.items(snapshot: snapshot, market: market)
            month = try TimelineBuilder.month(
                year: monthKey.year,
                month: monthKey.month,
                market: market,
                asOf: today,
                snapshot: snapshot
            )
            loadState = .ready

            if let selectedDate {
                if month?.days.contains(where: { $0.date == selectedDate }) == true {
                    await rebuildSelection(for: selectedDate, expectedGeneration: token)
                } else {
                    self.selectedDate = nil
                    selection = nil
                }
            } else {
                selection = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            loadState = .failed(MacLocalizedString.resolve("无法读取本地历史：\(Self.describe(error))", locale: WallpaperInterfaceLocale.current))
        }
    }

    // MARK: Navigation

    func selectDate(_ date: LocalDate) async {
        let targetMonth = LibraryMonthKey(containing: date)
        if month == nil || monthKey != targetMonth {
            if snapshot == nil || asOf == nil {
                monthKey = targetMonth
                selectedDate = date
                await performReload()
                return
            }
            monthKey = targetMonth
            selection = nil
            guard rebuildMonthFromCachedSnapshot() else { return }
        }

        if selectedDate != date {
            selection = nil
        }
        selectedDate = date
        isLoadingSelection = true
        defer { isLoadingSelection = false }
        await rebuildSelection(for: date)
    }

    func selectGalleryItem(_ key: OccurrenceKey) async {
        guard key.market == market else { return }
        await selectDate(key.localDate)
    }

    /// External navigation entry for menu commands and window restoration.
    ///
    /// Opens the library at one source-local date, switching the visible month
    /// and loading that day's cached payload. The date is never adjusted to a
    /// nearby observed day.
    func reveal(date: LocalDate) async {
        await selectDate(date)
    }

    /// External navigation entry that also switches market before opening the
    /// requested date.
    func reveal(date: LocalDate, market newMarket: Market) async {
        let resolved = BingMarketProfile.profile(for: newMarket)?.market ?? newMarket
        guard resolved != market else {
            await selectDate(date)
            return
        }
        reloadTask?.cancel()
        reloadTask = nil
        market = resolved
        resetForMarketChange()
        selectedDate = date
        monthKey = LibraryMonthKey(containing: date)
        if let profile = BingMarketProfile.profile(for: resolved),
           let today = LocalDate(date: now(), timeZone: profile.timeZone) {
            asOf = today
        }
        await performReload()
    }

    func goToPreviousMonth() {
        moveMonth(to: monthKey.adding(months: -1))
    }

    func goToNextMonth() {
        guard canGoToNextMonth else { return }
        moveMonth(to: monthKey.adding(months: 1))
    }

    func goToCurrentMonth() {
        guard let asOf else { return }
        moveMonth(to: LibraryMonthKey(containing: asOf))
    }

    /// Opens a concrete month selected from integrated yearly statistics.
    /// Future months are rejected instead of presenting unobserved dates as
    /// empty records.
    func goToMonth(year: Int, month: Int) {
        guard (1...12).contains(month), year > 0, let asOf else { return }
        let key = LibraryMonthKey(year: year, month: month)
        guard key <= LibraryMonthKey(containing: asOf) else { return }
        moveMonth(to: key)
    }

    private func moveMonth(to key: LibraryMonthKey) {
        guard let snapshot, let asOf else { return }
        do {
            let newMonth = try TimelineBuilder.month(
                year: key.year,
                month: key.month,
                market: market,
                asOf: asOf,
                snapshot: snapshot
            )
            monthKey = key
            month = newMonth
            if let selectedDate,
               !newMonth.days.contains(where: { $0.date == selectedDate }) {
                self.selectedDate = nil
                selection = nil
            }
        } catch {
            errorMessage = MacLocalizedString.resolve("无法生成 \(key.year)年\(key.month)月 的日历：\(Self.describe(error))", locale: WallpaperInterfaceLocale.current)
        }
    }

    @discardableResult
    private func rebuildMonthFromCachedSnapshot() -> Bool {
        guard let snapshot, let asOf else { return false }
        do {
            month = try TimelineBuilder.month(
                year: monthKey.year,
                month: monthKey.month,
                market: market,
                asOf: asOf,
                snapshot: snapshot
            )
            return true
        } catch {
            errorMessage = MacLocalizedString.resolve("无法生成该月日历：\(Self.describe(error))", locale: WallpaperInterfaceLocale.current)
            return false
        }
    }

    // MARK: Selection

    private func rebuildSelection(
        for date: LocalDate,
        expectedGeneration: Int? = nil
    ) async {
        guard let month,
              let day = month.days.first(where: { $0.date == date })
        else {
            selection = nil
            return
        }

        switch day.state {
        case .observed:
            let payload = await service.cachedPayload(market: market, key: day.id)
            if Task.isCancelled { return }
            if let expectedGeneration, expectedGeneration != generation { return }
            guard selectedDate == date, market == day.market else { return }
            if let payload {
                selection = .observed(day, payload)
            } else {
                selection = .observedWithoutPayload(day)
            }
        case .notRecorded:
            selection = .notRecorded(day)
        case .beforeObservationStart:
            selection = .beforeObservationStart(day)
        case .future:
            selection = .future(day)
        }
    }

    // MARK: Favorites

    func setScope(_ scope: LibraryScope) {
        self.scope = scope
    }

    func toggleFavorite(_ wallpaperID: WallpaperID) async {
        guard !isUpdatingFavorite else { return }
        isUpdatingFavorite = true
        errorMessage = nil
        defer { isUpdatingFavorite = false }

        let wasFavorite = snapshot?.favoriteWallpaperIDs.contains(wallpaperID) ?? false
        do {
            let repository = service.repository
            let changed = try await repository.setFavorite(
                wallpaperID,
                isFavorite: !wasFavorite
            )
            if changed {
                // Favorites are synchronized content; hand the change to the
                // one coalescing controller without blocking the gallery
                // update below.
                noteSyncActivity()
            }
            message = wasFavorite
                ? MacLocalizedString.resolve("已取消收藏。收藏按图片记录，同一图片的其他日期也已同步更新。", locale: WallpaperInterfaceLocale.current)
                : MacLocalizedString.resolve("已收藏这张图片。收藏按图片计算，不会因跨日期或跨地区重复计数。", locale: WallpaperInterfaceLocale.current)
            await performReload()
        } catch {
            errorMessage = MacLocalizedString.resolve("收藏状态未能保存：\(Self.describe(error))", locale: WallpaperInterfaceLocale.current)
        }
    }

    func dismissMessages() {
        message = nil
        errorMessage = nil
    }

    // MARK: Images

    func image(at url: URL?, maxPixelSize: Int) async -> NSImage? {
        guard let url else { return nil }
        return try? await imageLoader.image(at: url, maxPixelSize: maxPixelSize).image
    }

    func galleryImage(
        for item: LibraryGalleryItem,
        maxPixelSize: Int = 480
    ) async -> NSImage? {
        guard item.hasThumbnail else { return nil }
        guard let url = await thumbnailURL(for: item.wallpaperID) else { return nil }
        return await image(at: url, maxPixelSize: maxPixelSize)
    }

    func calendarImage(
        for day: TimelineDay,
        maxPixelSize: Int = 200
    ) async -> NSImage? {
        guard day.content?.thumbnailCached == true else { return nil }
        guard let url = await thumbnailURL(for: day.content?.wallpaperID) else { return nil }
        return await image(at: url, maxPixelSize: maxPixelSize)
    }

    func detailImage(
        for payload: TodayPayload,
        maxPixelSize: Int = 2_560
    ) async -> NSImage? {
        await image(
            at: payload.originalURL ?? payload.thumbnailURL,
            maxPixelSize: maxPixelSize
        )
    }

    private func thumbnailURL(for wallpaperID: WallpaperID?) async -> URL? {
        guard let wallpaperID else { return nil }
        let repository = service.repository
        return await repository.assetURL(kind: .thumbnail, for: wallpaperID)
    }

    // MARK: Helpers

    private static func describe(_ error: Error) -> String {
        AppErrorCopy.describe(error)
    }
}
