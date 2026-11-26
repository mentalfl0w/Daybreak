import DaybreakCore
import Foundation

/// Bridges the App Intents module's narrow data-source protocol to the shared
/// `MobileIntentService`.
///
/// Intents never open a repository. This adapter is the only place that maps
/// intent targets onto concrete image selections; the service resolves them
/// through the process-wide `MobileDataStore`.
struct LiveDaybreakShortcutDataSource: DaybreakShortcutDataSource {
    func prepareImage(_ target: DaybreakShortcutTarget) async throws -> DaybreakShortcutImage {
        let selection: MobileIntentImageSelection
        switch target {
        case .today(let market):
            selection = .today(market: market)
        case .date(let date, let market):
            selection = .date(date, market: market)
        case .marketToday(let market):
            selection = .today(market: market)
        case .randomCached:
            selection = .randomCached
        case .favorite:
            selection = .randomFavorite
        case .currentSelection:
            selection = .currentSelection
        case .wallpaperReference(let rawValue):
            guard let reference = DaybreakWallpaperReference(text: rawValue) else {
                throw DaybreakShortcutError.malformedWallpaperID
            }
            selection = .occurrence(reference.occurrenceKey, reference.wallpaperID)

        }
        do {
            let image = try await MobileIntentService.shared.prepareIntentImage(
                selection,
                variant: .original,
                allowNetwork: true
            )
            return DaybreakShortcutImage(
                wallpaperID: image.wallpaperID,
                fileURL: image.fileURL,
                mimeType: image.mimeType,
                fileExtension: image.fileExtension,
                sourceDate: image.sourceDate,
                market: image.market,
                title: image.title,
                sourceURL: image.sourceURL,
                isOriginal: image.isOriginal
            )
        } catch let error as MobileStoreError {
            let mapped = await map(error, target: target)
            throw mapped
        } catch {
            throw DaybreakShortcutError.storeUnavailable(
                MobileErrorText.describe(error)
            )
        }
    }

    private func map(
        _ error: MobileStoreError,
        target: DaybreakShortcutTarget
    ) async -> DaybreakShortcutError {
        switch error {
        case .unsupportedMarket(let rawValue):
            return .unsupportedMarket(Market(rawValue))
        case .repositoryBusyByAnotherProcess, .repositoryAlreadyOpenInProcess:
            return .repositoryBusy
        case .offline(let detail):
            return .offline(detail)
        case .noImageForDate(let date, let market):
            switch target {
            case .today, .marketToday:
                return .todayNotAvailable(market: market, date: date)
            default:
                return .dayNotStored(date: date, market: market)
            }
        case .noCachedImage:
            switch target {
            case .today(let market):
                let resolved: Market
                if let market {
                    resolved = market
                } else {
                    resolved = await preferredMarket()
                }
                return .todayNotAvailable(
                    market: resolved,
                    date: await marketToday(for: resolved)
                )
            case .marketToday(let market):
                return .todayNotAvailable(
                    market: market,
                    date: await marketToday(for: market)
                )
            case .date(let date, let market):
                let resolved: Market
                if let market {
                    resolved = market
                } else {
                    resolved = await preferredMarket()
                }
                return .dayNotStored(date: date, market: resolved)
            case .randomCached:
                return .noCachedWallpapers
            case .favorite:
                return .noFavorites
            case .currentSelection:
                return .noCurrentSelection
            case .wallpaperReference(let rawValue):
                return .unknownWallpaper(rawValue)
            }
        case .noFavorites:
            return .noFavorites
        case .noCachedImages:
            return .noCachedWallpapers
        case .noCurrentSelection:
            return .noCurrentSelection
        case .unknownWallpaper(let rawValue):
            return .unknownWallpaper(rawValue)
        case .malformedWallpaperID:
            return .malformedWallpaperID
        case .imageUnavailable(let detail):
            return .imageUnavailable(detail)
        case .repositoryUnavailable(let detail),
             .persistenceFailed(let detail),
             .refreshFailed(let detail),
             .cacheOperationFailed(let detail):
            return .storeUnavailable(
                error.errorDescription ?? detail
            )
        case .settingsUnavailable:
            return .storeUnavailable(
                error.errorDescription ?? MobileLocalizedString.resolve(
                    "设置不可用",
                    locale: MobileCopyLocale.current
                )
            )
        case .operationInProgress:
            return .storeUnavailable(
                error.errorDescription ?? MobileLocalizedString.resolve(
                    "已有操作正在进行",
                    locale: MobileCopyLocale.current
                )
            )
        case .invalidSelection(let detail):
            return .imageUnavailable(detail)
        }
    }

    private func preferredMarket() async -> Market {
        await MobileIntentService.shared.preferredMarket()
    }

    private func marketToday(for market: Market) async -> LocalDate {
        if let profile = BingMarketProfile.profile(for: market),
           let date = LocalDate(date: Date(), timeZone: profile.timeZone) {
            return date
        }
        return LocalDate(year: 1970, month: 1, day: 1)
            ?? LocalDate(year: 2000, month: 1, day: 1)!
    }
}
