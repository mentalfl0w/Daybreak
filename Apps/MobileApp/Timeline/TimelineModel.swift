import DaybreakCore
import Foundation
import Observation

enum TimelineLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

/// Content prepared for the crop/preview surface. The view turns this into the
/// preview module's request; the model never claims a system wallpaper was set.
struct TimelinePreviewContent: Sendable {
    let displayImageURL: URL
    let originalImageURL: URL?
    let wallpaperID: WallpaperID
    let market: Market
    let date: LocalDate
    let title: String?
    let copyright: String?
    let sourcePageURL: URL?
}

/// Observable state for one scene's timeline.
///
/// The model owns calendar navigation and the selected date/occurrence for a
/// single window. It reads the shared process-wide store and never creates a
/// repository, so two windows and an App Intent cannot open independent
/// writers.
@MainActor
@Observable
final class TimelineModel {
    // MARK: Dependencies

    @ObservationIgnored private let store: any TimelineDataStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let imageLoader: TimelineImageLoader

    // MARK: Published state

    private(set) var market: Market
    private(set) var asOf: LocalDate
    private(set) var firstObservedDate: LocalDate?
    private(set) var monthKey: TimelineMonthKey
    private(set) var displayYear: Int
    private(set) var display: TimelineCalendarDisplay = .month
    private(set) var section: TimelineSection = .calendar
    private(set) var galleryScope: TimelineGalleryScope = .all
    private(set) var recapScope: TimelineRecapScope = .month
    private(set) var recapMarketScope: TimelineRecapMarketScope = .allMarkets
    private(set) var month: TimelineMonth?
    private(set) var yearMonths: [TimelineYearMonthSummary] = []
    private(set) var galleryItems: [TimelineGalleryItem] = []
    private(set) var undatedFavoriteCount = 0
    private(set) var marketRecordedDayCounts: [Market: Int] = [:]
    private(set) var availableMarkets: [Market] = []
    private(set) var selectedDate: LocalDate?
    private(set) var detail: TimelineDayDetail?
    private(set) var monthRecap: TimelineMonthRecapData?
    private(set) var yearRecap: TimelineYearRecapData?
    private(set) var favoritesRecap: TimelineFavoritesRecapData?
    private(set) var loadState: TimelineLoadState = .idle
    private(set) var isRefreshing = false
    private(set) var error: TimelineFailure?
    private(set) var assetError: TimelineFailure?
    private(set) var banner: TimelineBanner?
    private(set) var favoriteUpdates: Set<WallpaperID> = []
    private(set) var assetRequests: Set<WallpaperID> = []
    private(set) var isPreparingPreview = false
    private(set) var hasLoadedOnce = false
    /// Increments whenever cached assets may have changed, so thumbnail views
    /// can retry after a download or cache cleanup.
    private(set) var imageRevision = 0

    // MARK: Private state

    @ObservationIgnored private var snapshot: RepositorySnapshot?
    @ObservationIgnored private var detailTarget: TimelineDetailTarget?
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var lastObservedRevision = -1
    @ObservationIgnored private var favoriteOverrides: [WallpaperID: Bool] = [:]
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    private static let earliestYear = 2009

    init(
        store: any TimelineDataStore,
        now: @escaping @Sendable () -> Date = { Date() },
        imageLoader: TimelineImageLoader = .shared
    ) {
        self.store = store
        self.now = now
        self.imageLoader = imageLoader

        let initialMarket = store.selectedMarket
        let profile = BingMarketProfile.profile(for: initialMarket)
        let timeZone = profile?.timeZone ?? .current
        let initialDate = LocalDate(date: now(), timeZone: timeZone)
            ?? LocalDate(year: 2000, month: 1, day: 1)!
        self.market = profile?.market ?? initialMarket
        self.asOf = initialDate
        self.monthKey = TimelineMonthKey(containing: initialDate)
        self.displayYear = initialDate.year
    }

    // MARK: Derived values

    var timeZone: TimeZone {
        BingMarketProfile.profile(for: market)?.timeZone ?? .current
    }

    var canGoToPreviousMonth: Bool {
        monthKey > TimelineMonthKey(year: Self.earliestYear, month: 1)
    }

    var canGoToNextMonth: Bool {
        monthKey < TimelineMonthKey(containing: asOf)
    }

    var canGoToPreviousYear: Bool {
        displayYear > Self.earliestYear
    }

    var canGoToNextYear: Bool {
        displayYear < asOf.year
    }

    var browsableYears: ClosedRange<Int> {
        Self.earliestYear...max(Self.earliestYear, asOf.year)
    }

    func isFavorite(_ wallpaperID: WallpaperID?) -> Bool {
        guard let wallpaperID else { return false }
        if let override = favoriteOverrides[wallpaperID] {
            return override
        }
        return snapshot?.favoriteWallpaperIDs.contains(wallpaperID) ?? false
    }

    func isUpdatingFavorite(_ wallpaperID: WallpaperID?) -> Bool {
        guard let wallpaperID else { return false }
        return favoriteUpdates.contains(wallpaperID)
    }

    func isRequestingAsset(_ wallpaperID: WallpaperID?) -> Bool {
        guard let wallpaperID else { return false }
        return assetRequests.contains(wallpaperID)
    }

    func displayTitle(for key: OccurrenceKey) -> String? {
        guard let snapshot else { return nil }
        if let metadata = snapshot.metadata(for: key), let title = metadata.title {
            return title
        }
        guard let occurrence = snapshot.occurrences.first(where: { $0.id == key }) else {
            return nil
        }
        return snapshot.wallpapers
            .first { $0.wallpaperID == occurrence.wallpaperID }?
            .canonicalTitle
    }

    func wallpaperID(for key: OccurrenceKey) -> WallpaperID? {
        guard let snapshot else { return nil }
        return OccurrenceIndex.latest(snapshot.occurrences)
            .first { $0.id == key }?
            .wallpaperID
    }

    func displayTitle(for wallpaperID: WallpaperID) -> String? {
        guard let snapshot else { return nil }
        return snapshot.wallpapers
            .first { $0.wallpaperID == wallpaperID }?
            .canonicalTitle
    }

    /// One representative occurrence per observed date in the displayed year,
    /// newest first. Used for the year recap's image strip; it never invents a
    /// date and never includes a future occurrence.
    func yearImageKeys(limit: Int = 12) -> [OccurrenceKey] {
        guard let snapshot else { return [] }
        let selectedMarkets: Set<Market>? = recapMarketScope == .currentMarket
            ? [market]
            : nil
        let latest = OccurrenceIndex.latest(snapshot.occurrences).filter { occurrence in
            guard occurrence.localDate.year == displayYear,
                  occurrence.localDate <= asOf
            else { return false }
            if let selectedMarkets, !selectedMarkets.contains(occurrence.market) {
                return false
            }
            return true
        }
        .sorted { lhs, rhs in
            if lhs.localDate != rhs.localDate { return lhs.localDate > rhs.localDate }
            if lhs.market != rhs.market { return lhs.market < rhs.market }
            return lhs.wallpaperID < rhs.wallpaperID
        }
        var seenDates: Set<LocalDate> = []
        var keys: [OccurrenceKey] = []
        for occurrence in latest where seenDates.insert(occurrence.localDate).inserted {
            keys.append(occurrence.id)
            if keys.count >= limit { break }
        }
        return keys
    }

    // MARK: Loading

    /// Reads the shared repository. Safe on every appearance; older reads never
    /// overwrite a newer one.
    func load() async {
        await reload(pinnedMarket: nil, initial: !hasLoadedOnce)
    }

    func refresh() async {
        await reload(pinnedMarket: nil, initial: false)
    }

    /// Called when the shared store reports a mutation from another surface or
    /// window. A revision already applied by this scene is ignored.
    func storeDidChange(_ revision: Int) async {
        guard revision != lastObservedRevision else { return }
        await reload(pinnedMarket: nil, initial: false)
    }

    private func reload(pinnedMarket: Market?, initial: Bool) async {
        reloadGeneration += 1
        let token = reloadGeneration
        isRefreshing = true
        if !hasLoadedOnce {
            loadState = .loading
        }
        if initial {
            error = nil
        }

        let targetMarket = pinnedMarket ?? store.selectedMarket
        guard let profile = BingMarketProfile.profile(for: targetMarket) else {
            fail(.unsupportedMarket, detail: targetMarket.rawValue, token: token)
            return
        }
        guard let today = LocalDate(date: now(), timeZone: profile.timeZone) else {
            fail(.snapshotUnavailable, detail: "source date", token: token)
            return
        }

        do {
            let revisionAtStart = store.dataRevision
            let fresh = try await store.timelineSnapshot()
            try Task.checkCancellation()
            guard token == reloadGeneration else { return }
            lastObservedRevision = revisionAtStart
            apply(
                snapshot: fresh,
                market: profile.market,
                asOf: today,
                initial: initial
            )
            hasLoadedOnce = true
            loadState = .ready
            error = nil
            isRefreshing = false
        } catch is CancellationError {
            if token == reloadGeneration {
                isRefreshing = false
            }
        } catch {
            fail(.snapshotUnavailable, detail: String(describing: error), token: token)
        }
    }

    private func fail(_ kind: TimelineFailureKind, detail: String?, token: Int) {
        guard token == reloadGeneration else { return }
        error = TimelineFailure(kind: kind, detail: detail)
        loadState = .failed
        isRefreshing = false
    }

    private func apply(
        snapshot fresh: RepositorySnapshot,
        market newMarket: Market,
        asOf newAsOf: LocalDate,
        initial: Bool
    ) {
        let marketChanged = newMarket != market
        let previousTarget = detailTarget
        snapshot = fresh
        market = newMarket
        asOf = newAsOf
        firstObservedDate = fresh.firstObservedDate

        let currentMonth = TimelineMonthKey(containing: newAsOf)
        if initial {
            monthKey = currentMonth
            displayYear = newAsOf.year
        } else if monthKey > currentMonth {
            monthKey = currentMonth
        }
        if displayYear > newAsOf.year {
            displayYear = newAsOf.year
        }

        imageRevision &+= 1
        availableMarkets = TimelineMarketBuilder.availableMarkets(snapshot: fresh)
        rebuildMarketCounts()
        rebuildMonth()
        rebuildGallery()
        rebuildRecaps()

        if marketChanged {
            switch previousTarget {
            case .day(let date):
                detailTarget = .day(date)
            case .occurrence:
                // A market switch shows the same calendar date in the newly
                // selected market instead of keeping another market's detail.
                detailTarget = selectedDate.map { .day($0) }
            case nil:
                detailTarget = nil
            }
        }

        if selectedDate == nil, initial {
            // A useful initial state that is still truthful: today may be
            // unrecorded and then the detail explains exactly that.
            selectedDate = newAsOf
            detailTarget = .day(newAsOf)
        }
        if let selectedDate, selectedDate > newAsOf {
            self.selectedDate = nil
            detailTarget = nil
        }
        rebuildDetail()
        favoriteOverrides = favoriteOverrides.filter { id, _ in
            fresh.favoriteWallpaperIDs.contains(id)
                || favoriteUpdates.contains(id)
        }
    }

    private func rebuildMarketCounts() {
        guard let fresh = snapshot else {
            marketRecordedDayCounts = [:]
            return
        }
        var counts: [Market: Set<LocalDate>] = [:]
        for occurrence in OccurrenceIndex.latest(fresh.occurrences) where occurrence.localDate <= asOf {
            counts[occurrence.market, default: []].insert(occurrence.localDate)
        }
        marketRecordedDayCounts = counts.mapValues(\.count)
    }

    func recordedDayCount(for market: Market) -> Int {
        marketRecordedDayCounts[market] ?? 0
    }

    private func rebuildMonth() {
        guard let fresh = snapshot, monthKey.firstDay != nil else {
            month = nil
            return
        }
        month = try? TimelineBuilder.month(
            year: monthKey.year,
            month: monthKey.month,
            market: market,
            asOf: asOf,
            snapshot: fresh
        )
    }

    private func rebuildGallery() {
        guard let fresh = snapshot else {
            galleryItems = []
            undatedFavoriteCount = 0
            return
        }
        galleryItems = TimelineGalleryBuilder.items(
            snapshot: fresh,
            market: market,
            asOf: asOf,
            scope: galleryScope
        )
        undatedFavoriteCount = TimelineGalleryBuilder.undatedFavoriteCount(
            snapshot: fresh,
            asOf: asOf
        )
    }

    private func rebuildRecaps() {
        guard let fresh = snapshot else {
            monthRecap = nil
            yearRecap = nil
            favoritesRecap = nil
            yearMonths = []
            return
        }
        yearMonths = TimelineYearBuilder.summaries(
            year: displayYear,
            markets: [market],
            snapshot: fresh,
            asOf: asOf
        )
        let recapMarkets: Set<Market>? = recapMarketScope == .currentMarket
            ? [market]
            : nil
        if let month {
            monthRecap = TimelineRecapBuilder.month(
                monthKey: monthKey,
                month: month,
                snapshot: fresh,
                asOf: asOf,
                markets: recapMarkets
            )
        } else {
            monthRecap = nil
        }
        yearRecap = TimelineRecapBuilder.year(
            year: displayYear,
            snapshot: fresh,
            asOf: asOf,
            markets: recapMarkets
        )
        favoritesRecap = TimelineRecapBuilder.favorites(
            snapshot: fresh,
            asOf: asOf
        )
    }

    private func rebuildDetail() {
        guard let fresh = snapshot, let target = detailTarget else {
            detail = nil
            return
        }
        detail = TimelineDetailBuilder.detail(
            target: target,
            selectedMarket: market,
            snapshot: fresh,
            asOf: asOf
        )
    }

    // MARK: Calendar navigation

    func setSection(_ newSection: TimelineSection) {
        section = newSection
        if newSection == .recap {
            rebuildRecaps()
        }
    }

    func setGalleryScope(_ scope: TimelineGalleryScope) {
        guard scope != galleryScope else { return }
        galleryScope = scope
        rebuildGallery()
    }

    func setRecapScope(_ scope: TimelineRecapScope) {
        recapScope = scope
        if scope == .favorites {
            rebuildRecaps()
        }
    }

    func setRecapMarketScope(_ scope: TimelineRecapMarketScope) {
        guard scope != recapMarketScope else { return }
        recapMarketScope = scope
        rebuildRecaps()
    }

    func setDisplay(_ newDisplay: TimelineCalendarDisplay) {
        display = newDisplay
        if newDisplay == .year {
            displayYear = monthKey.year
            rebuildYearSummaries()
        }
    }

    func goToPreviousMonth() {
        guard canGoToPreviousMonth else { return }
        moveMonth(to: monthKey.adding(months: -1))
    }

    func goToNextMonth() {
        guard canGoToNextMonth else { return }
        moveMonth(to: monthKey.adding(months: 1))
    }

    func goToCurrentMonth() {
        let key = TimelineMonthKey(containing: asOf)
        display = .month
        moveMonth(to: key)
        displayYear = key.year
    }

    func goToMonth(year: Int, month: Int) {
        guard (1...12).contains(month) else { return }
        let key = TimelineMonthKey(year: year, month: month)
        guard key <= TimelineMonthKey(containing: asOf),
              key >= TimelineMonthKey(year: Self.earliestYear, month: 1)
        else { return }
        display = .month
        moveMonth(to: key)
        displayYear = key.year
    }

    func goToPreviousYear() {
        guard canGoToPreviousYear else { return }
        goToYear(displayYear - 1)
    }

    func goToNextYear() {
        guard canGoToNextYear else { return }
        goToYear(displayYear + 1)
    }

    func goToYear(_ year: Int) {
        let clamped = min(max(year, Self.earliestYear), asOf.year)
        displayYear = clamped
        display = .year
        rebuildYearSummaries()
    }

    private func moveMonth(to key: TimelineMonthKey) {
        assetError = nil
        guard key >= TimelineMonthKey(year: Self.earliestYear, month: 1),
              key <= TimelineMonthKey(containing: asOf)
        else { return }
        monthKey = key
        displayYear = key.year
        display = .month
        if let selectedDate,
           TimelineMonthKey(containing: selectedDate) != key {
            self.selectedDate = nil
            detailTarget = nil
            detail = nil
        }
        rebuildMonth()
        rebuildRecaps()
    }

    private func rebuildYearSummaries() {
        guard let fresh = snapshot else {
            yearMonths = []
            return
        }
        yearMonths = TimelineYearBuilder.summaries(
            year: displayYear,
            markets: [market],
            snapshot: fresh,
            asOf: asOf
        )
        yearRecap = TimelineRecapBuilder.year(
            year: displayYear,
            snapshot: fresh,
            asOf: asOf,
            markets: recapMarketScope == .currentMarket ? [market] : nil
        )
    }

    // MARK: Selection

    @discardableResult
    func selectDate(_ date: LocalDate, recordSelection: Bool = true) -> Bool {
        guard date <= asOf else { return false }
        assetError = nil
        display = .month
        let key = TimelineMonthKey(containing: date)
        if key != monthKey {
            monthKey = key
            displayYear = key.year
            rebuildMonth()
            rebuildRecaps()
        }
        selectedDate = date
        detailTarget = .day(date)
        rebuildDetail()
        if recordSelection {
            recordSelectionIfObserved(
                OccurrenceKey(source: .bing, market: market, localDate: date)
            )
        }
        return true
    }

    func selectGalleryItem(_ item: TimelineGalleryItem) {
        guard item.date <= asOf else { return }
        assetError = nil
        section = .gallery
        selectedDate = item.date
        let key = TimelineMonthKey(containing: item.date)
        if key != monthKey {
            monthKey = key
            displayYear = key.year
            rebuildMonth()
            rebuildRecaps()
        }
        detailTarget = .occurrence(item.key)
        rebuildDetail()
        recordSelectionIfObserved(item.key)
    }

    func selectMarketOccurrence(_ occurrence: TimelineMarketOccurrence) {
        selectTarget(.occurrence(occurrence.key))
    }

    func selectTarget(_ target: TimelineDetailTarget) {
        guard target.date <= asOf else { return }
        assetError = nil
        let key = TimelineMonthKey(containing: target.date)
        if key != monthKey {
            monthKey = key
            displayYear = key.year
            rebuildMonth()
            rebuildRecaps()
        }
        selectedDate = target.date
        detailTarget = target
        rebuildDetail()
        switch target {
        case .day(let date):
            recordSelectionIfObserved(
                OccurrenceKey(source: .bing, market: market, localDate: date)
            )
        case .occurrence(let key):
            recordSelectionIfObserved(key)
        }
    }

    func selectToday() {
        section = .calendar
        display = .month
        _ = selectDate(asOf)
    }

    /// Cross-section hand-off from Today. The request is handled once; the
    /// screen clears it afterwards.
    func open(date: LocalDate, market requestedMarket: Market) async {
        let resolved = BingMarketProfile.profile(for: requestedMarket)?.market ?? requestedMarket
        if resolved != market {
            await setMarket(resolved, preservingTargetDate: date)
        }
        section = .calendar
        display = .month
        if !selectDate(date) {
            error = TimelineFailure(
                kind: .dateNotAvailable,
                detail: "\(resolved.rawValue) \(date.iso8601)"
            )
        }
    }

    // MARK: Market

    func setMarket(_ newMarket: Market, preservingTargetDate date: LocalDate? = nil) async {
        let resolved = BingMarketProfile.profile(for: newMarket)?.market ?? newMarket
        guard resolved != market else { return }
        market = resolved
        if let date {
            monthKey = TimelineMonthKey(containing: date)
            displayYear = date.year
        }
        detailTarget = (date ?? selectedDate).map { .day($0) }
        await store.setSelectedMarket(resolved)
        await reload(pinnedMarket: resolved, initial: false)
        if let date, date <= asOf {
            _ = selectDate(date, recordSelection: false)
        }
    }

    func switchToMarketOfCurrentDetail() async {
        guard let detail, detail.market != market else { return }
        let date = detail.date
        await setMarket(detail.market, preservingTargetDate: date)
    }

    /// Only an observed occurrence becomes Shortcuts' current selection; a
    /// blank calendar cell is not evidence that the source published nothing.
    private func recordSelectionIfObserved(_ key: OccurrenceKey) {
        guard let snapshot,
              snapshot.occurrences.contains(where: {
                  $0.id == key && $0.localDate <= asOf
              })
        else { return }
        Task { [store] in
            await store.recordCurrentSelection(key)
        }
    }

    // MARK: Favorites

    func toggleFavorite(_ wallpaperID: WallpaperID?) async {
        guard let wallpaperID, !favoriteUpdates.contains(wallpaperID) else { return }
        let newValue = !isFavorite(wallpaperID)
        favoriteOverrides[wallpaperID] = newValue
        favoriteUpdates.insert(wallpaperID)
        defer {
            favoriteUpdates.remove(wallpaperID)
        }

        do {
            try await store.timelineSetFavorite(wallpaperID, isFavorite: newValue)
            await reload(pinnedMarket: nil, initial: false)
            favoriteOverrides.removeValue(forKey: wallpaperID)
            showBanner(newValue ? .favorited : .unfavorited)
        } catch {
            favoriteOverrides.removeValue(forKey: wallpaperID)
            self.error = TimelineFailure(
                kind: .favoriteFailed,
                detail: String(describing: error)
            )
        }
    }

    // MARK: Images

    func thumbnail(
        for wallpaperID: WallpaperID?,
        maxPixelSize: CGFloat
    ) async -> TimelineDecodedImage? {
        guard let wallpaperID else { return nil }
        let size = max(64, Int(maxPixelSize.rounded(.up)))
        if let url = await store.timelineAssetURL(kind: .thumbnail, wallpaperID: wallpaperID) {
            if let image = try? await imageLoader.image(at: url, maxPixelSize: size) {
                return image
            }
        }
        // A cached original is still local content; downsample it rather than
        // showing an empty cell when only the original survived cleanup.
        if let url = await store.timelineAssetURL(kind: .original, wallpaperID: wallpaperID) {
            return try? await imageLoader.image(at: url, maxPixelSize: size)
        }
        return nil
    }

    /// Best available local image for the detail hero. Original first, then a
    /// downsample of the cached original behind a thumbnail-only label.
    func detailImage(
        for wallpaperID: WallpaperID?,
        maxPixelSize: CGFloat
    ) async -> TimelineDetailImage? {
        guard let wallpaperID else { return nil }
        let size = max(256, Int(maxPixelSize.rounded(.up)))
        if let url = await store.timelineAssetURL(kind: .original, wallpaperID: wallpaperID),
           let image = try? await imageLoader.image(at: url, maxPixelSize: size) {
            return TimelineDetailImage(image: image, isOriginal: true)
        }
        if let url = await store.timelineAssetURL(kind: .thumbnail, wallpaperID: wallpaperID),
           let image = try? await imageLoader.image(at: url, maxPixelSize: size) {
            return TimelineDetailImage(image: image, isOriginal: false)
        }
        return nil
    }

    /// Ensures a readable original for preview/export. Falls back to the
    /// cached thumbnail only when the original cannot be obtained; the preview
    /// module then labels limited resolution.
    func preparePreview(for day: TimelineDayDetail) async -> TimelinePreviewContent? {
        guard let occurrence = day.occurrence else { return nil }
        let wallpaperID = occurrence.wallpaperID
        guard !isPreparingPreview else { return nil }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        assetError = nil

        var originalURL = await store.timelineAssetURL(kind: .original, wallpaperID: wallpaperID)
        if originalURL == nil {
            originalURL = await ensureOriginal(occurrence: occurrence, announce: false)
        }
        let displayURL: URL?
        if let originalURL {
            displayURL = originalURL
        } else {
            displayURL = await store.timelineAssetURL(kind: .thumbnail, wallpaperID: wallpaperID)
        }
        guard let displayURL else {
            assetError = TimelineFailure(kind: .assetUnavailable, detail: "no local image")
            return nil
        }
        if originalURL != nil {
            await reload(pinnedMarket: nil, initial: false)
        }
        return TimelinePreviewContent(
            displayImageURL: displayURL,
            originalImageURL: originalURL,
            wallpaperID: wallpaperID,
            market: day.market,
            date: day.date,
            title: day.title,
            copyright: day.copyright,
            sourcePageURL: day.metadata?.sourceURL ?? day.wallpaper?.sourceURL
        )
    }

    /// Explicit user download of the original. Returns `true` only after the
    /// store produced a readable file.
    @discardableResult
    func downloadOriginal(for day: TimelineDayDetail) async -> Bool {
        guard let occurrence = day.occurrence else { return false }
        if await store.timelineAssetURL(kind: .original, wallpaperID: occurrence.wallpaperID) != nil {
            return true
        }
        let url = await ensureOriginal(occurrence: occurrence, announce: true)
        if url != nil {
            await reload(pinnedMarket: nil, initial: false)
            return true
        }
        return false
    }

    private func ensureOriginal(
        occurrence: WallpaperOccurrence,
        announce: Bool
    ) async -> URL? {
        let wallpaperID = occurrence.wallpaperID
        guard !assetRequests.contains(wallpaperID) else { return nil }
        assetRequests.insert(wallpaperID)
        defer { assetRequests.remove(wallpaperID) }
        do {
            let url = try await store.timelineEnsureAsset(
                kind: .original,
                for: occurrence,
                allowNetwork: true
            )
            if announce {
                showBanner(.originalReady)
            }
            return url
        } catch {
            assetError = TimelineFailure(
                kind: .assetUnavailable,
                detail: String(describing: error)
            )
            if announce {
                showBanner(.assetUnavailable)
            }
            return nil
        }
    }

    // MARK: Feedback

    func dismissError() {
        error = nil
    }

    func dismissAssetError() {
        assetError = nil
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    private func showBanner(_ newBanner: TimelineBanner) {
        bannerTask?.cancel()
        banner = newBanner
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}

struct TimelineDetailImage: Sendable {
    let image: TimelineDecodedImage
    let isOriginal: Bool
}
