import AppIntents
import DaybreakCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

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
        case .randomCached, .favorite, .currentSelection, .wallpaperReference:
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

/// Local notification handoff for the exact `IntentFile` returned by a
/// Daybreak wallpaper action. The filename carries its occurrence identity;
/// the attachment is rendered from the same input file, never a re-fetched image.
struct DaybreakWallpaperNotificationService: Sendable {
    static let live = DaybreakWallpaperNotificationService()

    func send(_ photo: IntentFile) async throws {
        guard let reference = DaybreakShortcutNotificationReference(
            fileName: photo.filename
        ) else {
            throw DaybreakWallpaperNotificationError.invalidImageReference
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard Self.isAuthorized(settings.authorizationStatus) else {
            throw DaybreakWallpaperNotificationError.notificationsNotAuthorized
        }

        let snapshot: MobileDaySnapshot
        do {
            guard let resolved = try await MobileIntentService.shared
                .notificationSnapshot(for: reference.occurrenceKey),
                  resolved.wallpaperID == reference.wallpaperID
            else {
                throw DaybreakWallpaperNotificationError.metadataUnavailable(
                    MobileLocalizedString.resolve(
                        "这张图片没有对应的 Daybreak 记录。请重新获取壁纸后重试。",
                        locale: DaybreakShortcutLocale.current
                    )
                )
            }
            snapshot = resolved
        } catch let error as DaybreakWallpaperNotificationError {
            throw error
        } catch {
            throw DaybreakWallpaperNotificationError.metadataUnavailable(
                MobileErrorText.describe(error)
            )
        }

        let story = snapshot.storyMatch?.story
        let payload = DaybreakWallpaperNotificationContent.make(
            title: snapshot.title ?? story?.title ?? story?.headline,
            copyright: snapshot.copyright ?? story?.copyright,
            quickFact: snapshot.storyMatch?.availableStory?.quickFact,
            market: reference.market,
            sourceDate: reference.sourceDate,
            locale: DaybreakShortcutLocale.current
        )

        let thumbnailURL = try Self.makeThumbnailURL(from: photo)
        defer { try? FileManager.default.removeItem(at: thumbnailURL) }

        let attachment: UNNotificationAttachment
        do {
            attachment = try UNNotificationAttachment(
                identifier: "daybreak-wallpaper",
                url: thumbnailURL,
                options: nil
            )
        } catch {
            throw DaybreakWallpaperNotificationError.attachmentUnavailable
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.attachments = [attachment]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            throw DaybreakWallpaperNotificationError.schedulingFailed(
                MobileErrorText.describe(error)
            )
        }
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func makeThumbnailURL(from photo: IntentFile) throws -> URL {
        let source: CGImageSource
        if let fileURL = photo.fileURL {
            let hasScopedAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            guard let imageSource = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                nil
            ) else {
                throw DaybreakWallpaperNotificationError.imageUnavailable
            }
            source = imageSource
            return try makeThumbnailURL(from: source)
        }

        let data = photo.data
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DaybreakWallpaperNotificationError.imageUnavailable
        }
        source = imageSource
        return try makeThumbnailURL(from: source)
    }

    private static func makeThumbnailURL(from source: CGImageSource) throws -> URL {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw DaybreakWallpaperNotificationError.imageUnavailable
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Daybreak-Notification-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw DaybreakWallpaperNotificationError.imageUnavailable
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw DaybreakWallpaperNotificationError.imageUnavailable
        }
        return url
    }
}

private enum DaybreakWallpaperNotificationError: Error, LocalizedError, Sendable {
    case invalidImageReference
    case notificationsNotAuthorized
    case metadataUnavailable(String)
    case imageUnavailable
    case attachmentUnavailable
    case schedulingFailed(String)

    var errorDescription: String? {
        let locale = DaybreakShortcutLocale.current
        switch self {
        case .invalidImageReference:
            return MobileLocalizedString.resolve(
                "无法识别这张 Daybreak 图片。请将“壁纸图片”连接到 Daybreak 获取壁纸操作的输出。",
                locale: locale
            )
        case .notificationsNotAuthorized:
            return MobileLocalizedString.resolve(
                "壁纸通知尚未授权。请先打开 Daybreak 的快捷指令指南并允许通知。",
                locale: locale
            )
        case .metadataUnavailable(let detail):
            return String(
                format: MobileLocalizedString.resolve(
                    "无法读取这张图片对应的来源资料：%@",
                    locale: locale
                ),
                detail
            )
        case .imageUnavailable:
            return MobileLocalizedString.resolve(
                "无法读取快捷指令传入的图片或生成通知缩略图。",
                locale: locale
            )
        case .attachmentUnavailable:
            return MobileLocalizedString.resolve(
                "无法添加壁纸通知图片缩略图。",
                locale: locale
            )
        case .schedulingFailed(let detail):
            return String(
                format: MobileLocalizedString.resolve(
                    "无法安排本地壁纸通知：%@",
                    locale: locale
                ),
                detail
            )
        }
    }
}

struct DaybreakWallpaperNotificationContent: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String

    static func make(
        title: String?,
        copyright: String?,
        quickFact: String?,
        market: Market,
        sourceDate: LocalDate,
        locale: Locale
    ) -> DaybreakWallpaperNotificationContent {
        let displayTitle = trimmed(title)
            ?? MobileLocalizedString.resolve("Daybreak 壁纸", locale: locale)
        var caption = [
            DaybreakShortcutDisplay.marketName(market, locale: locale),
            DaybreakShortcutDisplay.shortDate(sourceDate, locale: locale)
        ]
        if let copyright = trimmed(copyright) {
            caption.append(copyright)
        }
        let body = trimmed(quickFact)
            ?? MobileLocalizedString.resolve(
                "这张图片没有可用的来源知识点。",
                locale: locale
            )

        return DaybreakWallpaperNotificationContent(
            title: displayTitle,
            subtitle: caption.joined(separator: " · "),
            body: body
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
