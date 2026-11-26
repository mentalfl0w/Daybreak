import DaybreakCore
import Foundation

extension MobileDataStore {
    // MARK: Today refresh

    /// Fetches the selected market's daily archive and stories, persists the
    /// authoritative records, backfills bounded thumbnails, and returns the
    /// resulting snapshot. A failure never clears previously stored records.
    public func refreshToday(market: Market) async throws -> MobileTodaySnapshot {
        let repository = try await repositoryOrThrow()
        guard let profile = BingMarketProfile.profile(for: market) else {
            throw MobileStoreError.unsupportedMarket(market.rawValue)
        }
        let provider = try provider(for: profile.market)

        let daily: BingDailySnapshot
        do {
            daily = try await provider.fetchDailySnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BingProviderError {
            throw Self.mapProviderError(error)
        } catch {
            throw MobileStoreError.refreshFailed(MobileErrorText.describe(error))
        }
        try Task.checkCancellation()

        var warnings: [MobileRefreshWarning] = []

        // Story persistence is independent from the image archive. A story
        // conflict must not discard usable image metadata.
        if let stories = daily.stories.value, !stories.records.isEmpty {
            do {
                _ = try await repository.upsertStories(stories.records)
            } catch {
                warnings.append(.storiesUnavailable(
                    detail: MobileErrorText.describe(error)
                ))
            }
        }

        guard let archive = daily.archive.value else {
            if let storyError = daily.stories.error {
                throw Self.mapProviderError(storyError)
            }
            throw MobileStoreError.refreshFailed(
                daily.archive.error.map { MobileErrorText.describe($0) }
                    ?? MobileLocalizedString.resolve("Bing 图片服务暂时不可用", locale: MobileCopyLocale.current)
            )
        }
        guard !archive.entries.isEmpty else {
            throw MobileStoreError.refreshFailed(
                MobileLocalizedString.resolve("Bing 没有返回任何图片", locale: MobileCopyLocale.current)
            )
        }

        guard let marketToday = LocalDate(date: now(), timeZone: profile.timeZone) else {
            throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
        }
        let eligibleEntries = archive.entries.filter {
            $0.occurrence.localDate <= marketToday
        }
        let chosenEntry = eligibleEntries.first {
            $0.occurrence.localDate == marketToday
        } ?? eligibleEntries.max { lhs, rhs in
            if lhs.occurrence.localDate != rhs.occurrence.localDate {
                return lhs.occurrence.localDate < rhs.occurrence.localDate
            }
            return lhs.occurrence.id.description < rhs.occurrence.id.description
        }
        guard let chosenEntry else {
            throw MobileStoreError.noImageForDate(marketToday, profile.market)
        }

        do {
            _ = try await repository.upsertOccurrences(archive.occurrences)
            _ = try await repository.upsertMetadata(archive.metadataRecords)
            _ = try await repository.upsertWallpapers(archive.wallpapers)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MobileStoreError.persistenceFailed(MobileErrorText.describe(error))
        }

        if chosenEntry.occurrence.localDate != marketToday {
            warnings.append(.sourceDateBehind(
                sourceDate: chosenEntry.occurrence.localDate,
                marketToday: marketToday
            ))
        }
        if let storyError = daily.stories.error {
            warnings.append(.storiesUnavailable(
                detail: MobileErrorText.describe(storyError)
            ))
        }

        let persisted = await repository.snapshot()
        let backfill = try await backfillThumbnails(
            entries: archive.entries,
            snapshot: persisted
        )
        if let backfillWarning = backfill.warning {
            warnings.append(backfillWarning)
        }

        let finalSnapshot = await repository.snapshot()
        return await makeTodaySnapshot(
            market: profile.market,
            marketToday: marketToday,
            occurrence: chosenEntry.occurrence,
            snapshot: finalSnapshot,
            repository: repository,
            warnings: warnings
        )
    }

    /// Cache-first intent/UI read. Returns today's cached occurrence when it
    /// exists. With `allowNetwork`, a missing current-day occurrence triggers
    /// one refresh; a failed refresh falls back to the newest cached
    /// occurrence with its real source date.
    public func todaySnapshot(
        market: Market,
        allowNetwork: Bool
    ) async throws -> MobileTodaySnapshot {
        guard let profile = BingMarketProfile.profile(for: market) else {
            throw MobileStoreError.unsupportedMarket(market.rawValue)
        }
        let canonical = profile.market

        if let cached = try? await cachedTodaySnapshot(market: canonical),
           cached.isSourceDateToday {
            return cached
        }

        guard allowNetwork else {
            if let cached = try? await cachedTodaySnapshot(market: canonical) {
                return cached
            }
            guard let marketToday = LocalDate(date: now(), timeZone: profile.timeZone) else {
                throw MobileStoreError.invalidSelection("cannot resolve the market-local date")
            }
            throw MobileStoreError.noImageForDate(marketToday, canonical)
        }

        do {
            return try await refreshToday(market: canonical)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached = try? await cachedTodaySnapshot(market: canonical) {
                return cached
            }
            throw error
        }
    }

    // MARK: Image materialization

    /// Returns a verified readable file for `kind`, downloading and validating
    /// through the provider only when `allowNetwork` is true.
    ///
    /// Concurrent requests for the same variant of the same image share one
    /// download. A cancelling waiter is removed from the shared request; the
    /// download is cancelled only when no waiter still needs it, and a
    /// cancelled caller never receives a late success.
    public func ensureImage(
        kind: AssetKind,
        for occurrence: WallpaperOccurrence,
        allowNetwork: Bool
    ) async throws -> URL {
        if let cached = try await cachedImageURL(
            kind: kind,
            for: occurrence.wallpaperID
        ) {
            return cached
        }
        guard allowNetwork else {
            throw MobileStoreError.noCachedImage(occurrence.wallpaperID.description)
        }

        let key = ImageRequestKey(
            kind: kind,
            wallpaperID: occurrence.wallpaperID
        )
        if var existing = inFlightImages[key] {
            existing.waiters += 1
            inFlightImages[key] = existing
            return try await waitForInFlightImage(
                key: key,
                token: existing.token,
                task: existing.task
            )
        }

        let token = UUID()
        let task: Task<URL, any Error> = Task { [weak self] in
            guard let self else {
                throw MobileStoreError.repositoryUnavailable(
                    "The mobile data store was released during an image request"
                )
            }
            do {
                let url = try await self.performEnsureImage(
                    kind: kind,
                    for: occurrence
                )
                await self.finishImageRequest(key: key, token: token)
                return url
            } catch {
                await self.finishImageRequest(key: key, token: token)
                throw error
            }
        }
        inFlightImages[key] = InFlightImageRequest(
            token: token,
            task: task,
            waiters: 1
        )
        return try await waitForInFlightImage(
            key: key,
            token: token,
            task: task
        )
    }

    /// The one actual download for a variant. Runs inside the keyed shared
    /// task; re-checking the cache closes the gap between a completed previous
    /// request and a newly created request for the same key.
    private func performEnsureImage(
        kind: AssetKind,
        for occurrence: WallpaperOccurrence
    ) async throws -> URL {
        if let cached = try await cachedImageURL(
            kind: kind,
            for: occurrence.wallpaperID
        ) {
            return cached
        }

        let repository = try await repositoryOrThrow()
        let provider = try provider(for: occurrence.market)
        let metadata = await repository.metadata(for: occurrence.id)
        let wallpaper = await repository.wallpaper(occurrence.wallpaperID)

        let candidates: [BingImageCandidate] = (wallpaper?.variants ?? []).map { descriptor in
            BingImageCandidate(
                url: descriptor.remoteURL,
                kind: Self.candidateKind(for: descriptor),
                pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight
            )
        }
        guard metadata != nil || !candidates.isEmpty else {
            throw MobileStoreError.imageUnavailable(
                MobileLocalizedString.resolve("缺少这张图片的下载信息", locale: MobileCopyLocale.current)
            )
        }

        let preference = kind == .original
            ? settingsStore.load().imageQuality
            : .fullHD
        let image: BingImageAsset
        do {
            if let metadata {
                image = try await provider.fetchImage(
                    for: metadata,
                    preference: preference
                )
            } else {
                image = try await provider.fetchImage(
                    wallpaperID: occurrence.wallpaperID,
                    candidates: candidates,
                    preference: preference
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BingProviderError {
            throw Self.mapImageError(error)
        } catch {
            throw MobileStoreError.imageUnavailable(MobileErrorText.describe(error))
        }
        try Task.checkCancellation()

        do {
            _ = try await repository.storeAsset(
                image.data,
                kind: kind,
                for: occurrence.wallpaperID,
                fileExtension: Self.fileExtension(for: image.mimeType)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MobileStoreError.persistenceFailed(MobileErrorText.describe(error))
        }

        guard let url = try await cachedImageURL(
            kind: kind,
            for: occurrence.wallpaperID
        ) else {
            throw MobileStoreError.imageUnavailable(
                MobileLocalizedString.resolve("图片已保存，但无法读取缓存文件", locale: MobileCopyLocale.current)
            )
        }
        return url
    }

    /// Image-level original retrieval used by Preview and App Intents. The
    /// latest stored occurrence supplies the authoritative market/date and
    /// download descriptors.
    public func ensureOriginalImage(
        for wallpaperID: WallpaperID,
        allowNetwork: Bool = true
    ) async throws -> URL {
        if let cached = try await cachedImageURL(kind: .original, for: wallpaperID) {
            return cached
        }
        guard allowNetwork else {
            throw MobileStoreError.noCachedImage(wallpaperID.description)
        }
        guard let occurrence = try await latestOccurrence(for: wallpaperID) else {
            throw MobileStoreError.unknownWallpaper(wallpaperID.description)
        }
        return try await ensureImage(
            kind: .original,
            for: occurrence,
            allowNetwork: true
        )
    }

    // MARK: Thumbnail backfill

    private func backfillThumbnails(
        entries: [BingArchiveEntry],
        snapshot: RepositorySnapshot
    ) async throws -> (stored: Int, warning: MobileRefreshWarning?) {
        var available = snapshot.availableThumbnailIDs
        var attempted: Set<WallpaperID> = []
        var stored = 0
        var failureCount = 0
        var firstFailure: String?

        for entry in entries {
            let wallpaperID = entry.occurrence.wallpaperID
            guard !available.contains(wallpaperID),
                  attempted.insert(wallpaperID).inserted
            else {
                continue
            }

            do {
                _ = try await ensureImage(
                    kind: .thumbnail,
                    for: entry.occurrence,
                    allowNetwork: true
                )
                available.insert(wallpaperID)
                stored += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failureCount += 1
                if firstFailure == nil {
                    firstFailure = MobileErrorText.describe(error)
                }
            }
        }

        guard failureCount > 0 else { return (stored, nil) }
        return (
            stored,
            .thumbnailBackfillIncomplete(
                count: failureCount,
                detail: firstFailure ?? ""
            )
        )
    }

    // MARK: Candidate mapping

    private static func candidateKind(
        for descriptor: ImageVariantDescriptor
    ) -> BingImageVariantKind {
        guard let width = descriptor.pixelWidth else { return .provided }
        switch width {
        case 3_000...:
            return .ultraHighResolution
        case 1_800...:
            return .fullHD
        case 1_200...:
            return .compact
        default:
            return .provided
        }
    }
}
