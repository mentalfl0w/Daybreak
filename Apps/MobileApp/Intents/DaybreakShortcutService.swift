import DaybreakCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepared image plus the facts needed for an honest dialog.
struct DaybreakPreparedWallpaper: Sendable {
    let image: DaybreakShortcutImage
    let output: DaybreakWallpaperOutput
    let export: DaybreakShortcutExport
}

/// Coordinates one Shortcuts image request through the shared mobile store and
/// the crop exporter.
///
/// There is deliberately no wallpaper-setting code here. iOS exposes no public
/// app API that changes the system wallpaper; the shortcut's system
/// "Set Wallpaper Photo" action performs that step, and Daybreak must not
/// report it as completed.
struct DaybreakShortcutService: Sendable {
    static let live = DaybreakShortcutService(dataSource: LiveDaybreakShortcutDataSource())

    let dataSource: any DaybreakShortcutDataSource

    /// The store is cache-first; a download may be needed for a cached day
    /// whose original was evicted. Both budgets stay short because the system
    /// may end a background intent.
    static let imageBudget: Duration = .seconds(30)
    static let cropBudget: Duration = .seconds(20)

    func prepare(
        target: DaybreakShortcutTarget,
        output: DaybreakWallpaperOutput,
        now: Date = Date()
    ) async throws -> DaybreakPreparedWallpaper {
        try Task.checkCancellation()
        let image: DaybreakShortcutImage
        do {
            image = try await withBudget(Self.imageBudget) {
                try await dataSource.prepareImage(target)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DaybreakShortcutError {
            throw error
        } catch {
            throw DaybreakShortcutError.storeUnavailable(error.localizedDescription)
        }

        try Task.checkCancellation()
        try validateRequestedDate(target: target, image: image, now: now)

        // A thumbnail or preview-sized fallback is not an original wallpaper.
        // Refuse it instead of mislabelling a degraded image as the original or
        // silently cropping it for a Shortcuts wallpaper file.
        guard image.isOriginal else {
            throw DaybreakShortcutError.originalUnavailable(image.wallpaperID.description)
        }

        try validateReadableImage(image.fileURL)

        if output.isOriginal {
            // The store's file is a temporary, intent-owned copy. It is safe
            // to remove after the shortcut finishes and it is not the
            // repository's only cached copy.
            return DaybreakPreparedWallpaper(
                image: image,
                output: output,
                export: DaybreakShortcutExport(
                    fileURL: image.fileURL,
                    filename: originalFilename(for: image),
                    contentType: contentType(for: image),
                    removeOnCompletion: true
                )
            )
        }

        guard let preset = output.cropPreset else {
            throw DaybreakShortcutError.cropUnavailable(output.localizedTitle)
        }

        let result: WallpaperExportResult
        do {
            result = try await withBudget(Self.cropBudget) {
                try await WallpaperCropExporter.shared.export(
                    originalURL: image.fileURL,
                    preset: preset,
                    format: .automatic,
                    maximumLongEdge: 3840,
                    fileNameHint: "Daybreak-\(image.sourceDate.iso8601)-\(preset.rawValue)"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DaybreakShortcutError {
            throw error
        } catch {
            throw DaybreakShortcutError.cropUnavailable(error.localizedDescription)
        }

        try validateReadableImage(result.fileURL)

        return DaybreakPreparedWallpaper(
            image: image,
            output: output,
            export: DaybreakShortcutExport(
                fileURL: result.fileURL,
                filename: "Daybreak-\(image.sourceDate.iso8601)-\(preset.rawValue).\(result.format.fileExtension)",
                contentType: result.format.contentType,
                removeOnCompletion: result.isTemporary
            )
        )
    }

    /// Dialog text for the intent result. It describes what the app actually
    /// produced and explicitly leaves system wallpaper setting to Shortcuts.
    func dialog(for prepared: DaybreakPreparedWallpaper) -> String {
        let locale = DaybreakShortcutLocale.current
        let image = prepared.image
        let title = image.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (title?.isEmpty == false ? title! : MobileLocalizedString.resolve("壁纸", locale: locale))
        let date = DaybreakShortcutDisplay.dateText(image.sourceDate, locale: locale)
        let market = DaybreakShortcutDisplay.marketName(image.market, locale: locale)

        if prepared.output.isOriginal {
            return String(
                format: MobileLocalizedString.resolve(
                    "已返回「%@」（%@ · %@）的原图文件。请用快捷指令的“设置墙纸照片”动作完成设置；Daybreak 不会直接修改系统壁纸。",
                    locale: locale
                ),
                displayTitle,
                date,
                market
            )
        }

        let ratio = prepared.output.cropPreset?.ratioLabel ?? ""
        return String(
                format: MobileLocalizedString.resolve(
                    "已返回「%@」（%@ · %@）的%@文件。这是按 %@ 比例生成的构图导出，系统设置壁纸时可能再次裁切；请用快捷指令完成设置，Daybreak 不会直接修改系统壁纸。",
                locale: locale
            ),
            displayTitle,
            date,
            market,
            prepared.output.localizedTitle,
            ratio
        )
    }

    // MARK: Validation

    /// The store is cache-first and may return a cached day when a refresh
    /// fails. A "today" intent must never hand back yesterday's photograph as
    /// today's; enforce the source date at this boundary even if a store
    /// fallback changes later.
    private func validateRequestedDate(
        target: DaybreakShortcutTarget,
        image: DaybreakShortcutImage,
        now: Date
    ) throws {
        switch target {
        case .today(let requestedMarket):
            let expectedMarket = requestedMarket ?? image.market
            let today = marketToday(for: expectedMarket, now: now)
            guard image.market == expectedMarket, let today, image.sourceDate == today else {
                throw DaybreakShortcutError.todayNotAvailable(
                    market: expectedMarket,
                    date: today ?? image.sourceDate
                )
            }
        case .marketToday(let requestedMarket):
            let today = marketToday(for: requestedMarket, now: now)
            guard image.market == requestedMarket, let today, image.sourceDate == today else {
                throw DaybreakShortcutError.todayNotAvailable(
                    market: requestedMarket,
                    date: today ?? image.sourceDate
                )
            }
        case .date(let requestedDate, _):
            guard image.sourceDate == requestedDate else {
                throw DaybreakShortcutError.dayNotStored(
                    date: requestedDate,
                    market: image.market
                )
            }
        case .randomCached, .favorite, .currentSelection, .wallpaperID:
            break
        }
    }

    private func marketToday(for market: Market, now: Date) -> LocalDate? {
        guard let profile = BingMarketProfile.profile(for: market) else { return nil }
        return LocalDate(date: now, timeZone: profile.timeZone)
    }

    private func originalFilename(for image: DaybreakShortcutImage) -> String {
        let fileExtension = image.fileExtension.isEmpty
            ? image.fileURL.pathExtension
            : image.fileExtension
        return "Daybreak-\(image.sourceDate.iso8601).\(fileExtension)"
    }

    private func contentType(for image: DaybreakShortcutImage) -> UTType {
        UTType(mimeType: image.mimeType)
            ?? UTType(filenameExtension: image.fileExtension)
            ?? UTType(filenameExtension: image.fileURL.pathExtension)
            ?? .image
    }

    private func validateReadableImage(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
            throw DaybreakShortcutError.imageUnavailable(url.lastPathComponent)
        }
        // Confirm the bytes are a decodable image, not an HTML error page or a
        // partially written file. Full decoding is the store's responsibility;
        // this is a cheap container/metadata boundary check.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw DaybreakShortcutError.imageUnavailable(url.lastPathComponent)
        }
    }

    // MARK: Budget

    private func withBudget<T: Sendable>(
        _ budget: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: budget)
                throw DaybreakShortcutError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DaybreakShortcutError.timedOut
            }
            return result
        }
    }
}
