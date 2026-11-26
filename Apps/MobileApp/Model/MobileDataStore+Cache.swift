import DaybreakCore
import Foundation

extension MobileDataStore {
    // MARK: Reports

    public func storageUsage() async throws -> StorageUsage {
        let repository = try await repositoryOrThrow()
        return await repository.storageUsage()
    }

    public func cacheReport() async throws -> MobileCacheReport {
        let repository = try await repositoryOrThrow()
        let snapshot = await repository.snapshot()
        let usage = await repository.storageUsage()

        var reasonsByImage: [WallpaperID: Set<PinReason>] = [:]
        for asset in snapshot.assets {
            if reasonsByImage[asset.wallpaperID] == nil {
                reasonsByImage[asset.wallpaperID] = snapshot.pinReasons(
                    for: asset.wallpaperID
                )
            }
        }

        var countsByReason: [PinReason: Int] = [:]
        for reasons in reasonsByImage.values {
            for reason in reasons {
                countsByReason[reason, default: 0] += 1
            }
        }

        var protectedThumbnails = 0
        var protectedOriginals = 0
        for asset in snapshot.assets {
            guard let reasons = reasonsByImage[asset.wallpaperID],
                  !reasons.isEmpty
            else {
                continue
            }
            switch asset.kind {
            case .thumbnail:
                protectedThumbnails += 1
            case .original:
                protectedOriginals += 1
            }
        }

        return MobileCacheReport(
            usage: usage,
            protectedImageCountsByReason: countsByReason,
            protectedThumbnailAssetCount: protectedThumbnails,
            protectedOriginalAssetCount: protectedOriginals
        )
    }

    // MARK: Cleanup

    /// Thumbnails are derivable previews and are never protection-blocked.
    /// Originals, metadata, stories and favorites stay untouched.
    public func clearThumbnails() async throws -> MobileCacheClearResult {
        let repository = try await repositoryOrThrow()
        let before = await repository.storageUsage()

        let removedCount: Int
        do {
            removedCount = try await repository.clearThumbnails()
        } catch {
            throw MobileStoreError.cacheOperationFailed(
                MobileErrorText.describe(error)
            )
        }

        let after = await repository.storageUsage()
        return MobileCacheClearResult(
            removedAssetCount: removedCount,
            removedBytes: max(0, before.thumbnailBytes - after.thumbnailBytes)
        )
    }

    /// Removes only originals with no favorite, pinned-date or applied-image
    /// protection. Protected assets are counted and retained.
    public func clearOriginals() async throws -> MobileCacheClearResult {
        let repository = try await repositoryOrThrow()
        let snapshot = await repository.snapshot()
        let originals = snapshot.assets.filter { $0.kind == .original }

        var removedCount = 0
        var removedBytes = 0
        var skipped = 0
        var failed = 0
        var firstFailure: String?

        for asset in originals {
            guard snapshot.pinReasons(for: asset.wallpaperID).isEmpty else {
                skipped += 1
                continue
            }
            do {
                try await repository.removeAsset(
                    kind: .original,
                    for: asset.wallpaperID
                )
                removedCount += 1
                removedBytes += asset.byteCount
            } catch let error as RepositoryError {
                if case .protectedAsset = error {
                    // Protection may have changed after the snapshot; retain it.
                    skipped += 1
                } else {
                    failed += 1
                    if firstFailure == nil {
                        firstFailure = MobileErrorText.describe(error)
                    }
                }
            } catch {
                failed += 1
                if firstFailure == nil {
                    firstFailure = MobileErrorText.describe(error)
                }
            }
        }

        if removedCount == 0, failed > 0 {
            throw MobileStoreError.cacheOperationFailed(
                firstFailure ?? MobileLocalizedString.resolve(
                    "无法删除未受保护的原图",
                    locale: MobileCopyLocale.current
                )
            )
        }

        return MobileCacheClearResult(
            removedAssetCount: removedCount,
            removedBytes: removedBytes,
            skippedProtectedCount: skipped,
            failedCount: failed,
            failedDetail: firstFailure
        )
    }

    /// Story text is independent from images, metadata and favorites.
    public func clearStories() async throws -> Int {
        let repository = try await repositoryOrThrow()
        do {
            return try await repository.clearStories()
        } catch {
            throw MobileStoreError.cacheOperationFailed(
                MobileErrorText.describe(error)
            )
        }
    }

    /// Repairs only Daybreak's own `Assets/**` directory. The process lease in
    /// the repository root is never visited or recreated.
    public func repairCache() async throws -> RepositoryRepairReport {
        let repository = try await repositoryOrThrow()
        do {
            return try await repository.repair()
        } catch {
            throw MobileStoreError.cacheOperationFailed(
                MobileErrorText.describe(error)
            )
        }
    }

    // MARK: Limits

    public func evict(limits: CacheLimits) async throws -> CacheEvictionResult {
        let repository = try await repositoryOrThrow()
        do {
            return try await repository.evictLeastRecentlyUsed(limits: limits)
        } catch {
            throw MobileStoreError.cacheOperationFailed(
                MobileErrorText.describe(error)
            )
        }
    }
}
