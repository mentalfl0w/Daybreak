import DaybreakCore
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Fullscreen, native composition preview for one wallpaper.
///
/// The view loads a bounded local image, lets the user change the target
/// aspect preset and adjust zoom/focus with drag and pinch, then saves or
/// shares a non-destructive export. It never modifies the cached original and
/// never claims to have changed the system wallpaper.
///
/// Present it from any screen that can resolve readable local URLs:
///
/// ```swift
/// .fullScreenCover(item: $previewRequest) { request in
///     WallpaperPreviewView(request: request) { settings in
///         // Caller opens its Shortcut flow with the current crop settings.
///     }
/// }
/// ```
public struct WallpaperPreviewView: View {
    private let request: WallpaperPreviewRequest
    private let onSetWallpaperRequested: ((WallpaperCropSettings) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    @State private var loader = WallpaperPreviewImageLoader()
    @State private var loadedImage: WallpaperPreviewImage?
    /// Oriented pixel dimensions of the file the exporter will read.
    ///
    /// `loadedImage` is a bounded preview downsample, so its size must never
    /// be used to describe the exported file.
    @State private var exportSourcePixelSize: WallpaperPixelSize?
    @State private var loadFailure: String?
    @State private var isLoadingImage = true
    @State private var settings: WallpaperCropSettings
    @State private var exportFormat: WallpaperExportFormat = .automatic
    @State private var exportState: ExportState = .idle
    @State private var shareItem: WallpaperShareItem?
    @State private var alert: WallpaperPreviewAlert?
    @State private var dragStart: WallpaperCropFocus?
    @State private var zoomStart: Double?
    @State private var exportTask: Task<Void, Never>?

    private static let maximumExportLongEdge = 3_840

    public init(
        request: WallpaperPreviewRequest,
        onSetWallpaperRequested: ((WallpaperCropSettings) -> Void)? = nil
    ) {
        self.request = request
        self.onSetWallpaperRequested = onSetWallpaperRequested
        _settings = State(initialValue: request.initialSettings)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            imageStage
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: request.displayImageURL) {
            await loadImage()
        }
        .onDisappear {
            exportTask?.cancel()
        }
        .alert(item: $alert) { value in
            switch value {
            case .photoSaved:
                return Alert(
                    title: Text("已保存到照片"),
                    message: Text("图片已添加到照片图库。Daybreak 不会直接设置系统壁纸。"),
                    dismissButton: .default(Text("好"))
                )
            case .error(let message):
                return Alert(
                    title: Text("操作未完成"),
                    message: Text(verbatim: message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .sheet(item: $shareItem) { item in
            WallpaperShareSheet(fileURL: item.url)
                .ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭预览")

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: request.title ?? MobileLocalizedString.resolve("预览与裁切", locale: locale))
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                resetComposition()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(loadedImage == nil || isLoadingImage)
            .accessibilityLabel("重置构图")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Header provenance line shared by the view and its regression test.
    ///
    /// The Bing edition itself is never rewritten. Its region/language label
    /// follows Daybreak's interface locale through the existing app formatter,
    /// so an English interface does not print the raw `zh-CN` market tag.
    @MainActor
    static func subtitle(
        for request: WallpaperPreviewRequest,
        locale: Locale
    ) -> String? {
        var parts: [String] = []
        if let market = request.market {
            parts.append(TodayFormatting.marketName(market, locale: locale))
        }
        if let date = request.sourceDate {
            parts.append(date.iso8601)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var subtitle: String? {
        Self.subtitle(for: request, locale: locale)
    }

    // MARK: Image stage

    private var imageStage: some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: max(1, proxy.size.width - 28),
                height: max(1, proxy.size.height - 12)
            )
            let viewport = fittedSize(
                aspect: settings.preset.aspectRatio,
                in: available
            )
            ZStack {
                if isLoadingImage {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .accessibilityLabel("正在载入图片")
                } else if let loadedImage {
                    cropCanvas(loadedImage, viewport: viewport)
                } else {
                    loadFailureView
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cropCanvas(
        _ loaded: WallpaperPreviewImage,
        viewport: CGSize
    ) -> some View {
        let geometry = WallpaperCropGeometry(
            sourceSize: loaded.pixelSize,
            settings: settings
        )
        let displayed = geometry.displayedImageSize(viewportSize: viewport)
        let focus = settings.focalPoint
        let offset = CGSize(
            width: viewport.width / 2 - CGFloat(focus.x) * displayed.width,
            height: viewport.height / 2 - CGFloat(focus.y) * displayed.height
        )

        return ZStack(alignment: .topLeading) {
            Image(uiImage: loaded.image)
                .resizable()
                .interpolation(.high)
                .frame(width: displayed.width, height: displayed.height)
                .offset(x: offset.width, y: offset.height)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(viewport: viewport))
        .simultaneousGesture(magnifyGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(settings.preset.localizedTitleKey))
        .accessibilityValue(Text(verbatim: "\(settings.preset.ratioLabel) · \(zoomPercentText)"))
        .accessibilityHint(Text("拖动调整焦点，捏合调整缩放"))
        .accessibilityAdjustableAction { direction in
            adjustZoom(direction)
        }
        .accessibilityAction(named: Text("重置构图")) {
            resetComposition()
        }
    }

    private var loadFailureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.largeTitle)
            Text(verbatim: loadFailure ?? MobileLocalizedString.resolve("无法显示图片", locale: locale))
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await loadImage() }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(spacing: 14) {
                presetPicker
                zoomRow
                actionRow
                statusRow
                disclaimer
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 300)
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var presetPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(WallpaperCropPreset.allCases) { preset in
                    Button {
                        selectPreset(preset)
                    } label: {
                        VStack(spacing: 2) {
                            Text(preset.localizedTitleKey)
                                .font(.caption.weight(.semibold))
                            Text(verbatim: preset.ratioLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(
                                settings.preset == preset
                                    ? Color.white.opacity(0.24)
                                    : Color.white.opacity(0.07)
                            )
                        }
                        .overlay {
                            Capsule().strokeBorder(
                                settings.preset == preset
                                    ? Color.white.opacity(0.55)
                                    : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel(Text(preset.localizedTitleKey))
                    .accessibilityValue(Text(verbatim: preset.ratioLabel))
                    .accessibilityAddTraits(settings.preset == preset ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .disabled(loadedImage == nil || isLoadingImage)
    }

    private var zoomRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: zoomBinding, in: 1...4, step: 0.01)
                .tint(.white)
                .accessibilityLabel("缩放")
                .accessibilityValue(Text(verbatim: zoomPercentText))

            Image(systemName: "plus.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(verbatim: zoomPercentText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .disabled(loadedImage == nil || isLoadingImage)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                startExport(.photos)
            } label: {
                Label("保存到照片", systemImage: "square.and.arrow.down")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canExport)

            Button {
                startExport(.share)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canExport)

            Menu {
                ForEach(WallpaperExportFormat.allCases) { option in
                    Button {
                        exportFormat = option
                    } label: {
                        if exportFormat == option {
                            Label(option.localizedNameKey, systemImage: "checkmark")
                        } else {
                            Text(option.localizedNameKey)
                        }
                    }
                }
            } label: {
                Label(exportFormat.localizedNameKey, systemImage: "doc.badge.gearshape")
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("导出格式")
            .disabled(!canExport)
        }
        .tint(.white)
    }

    @ViewBuilder
    private var statusRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if case .exporting(let destination) = exportState {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(destination.progressKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if let resolutionText {
                        Text(verbatim: resolutionText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if request.exportsAtPreviewResolution {
                        Text("使用预览尺寸")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: exportFormat == .automatic
                        ? MobileLocalizedString.resolve("自动格式", locale: locale)
                        : exportFormat.fileExtension.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let copyright = request.copyright, !copyright.isEmpty {
                Text(verbatim: copyright)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onSetWallpaperRequested {
                Button {
                    let current = settings
                    onSetWallpaperRequested(current)
                    dismiss()
                } label: {
                    Label("用快捷指令设置壁纸…", systemImage: "wand.and.stars")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(!canExport)
            }
        }
    }

    private var disclaimer: some View {
        Text("构图预览只按所选比例裁切，不代表系统锁屏、主屏幕或 Duo 的最终壁纸效果。Daybreak 不会直接设置系统壁纸。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Gestures

    private func dragGesture(viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard loadedImage != nil else { return }
                let start = dragStart ?? settings.focalPoint
                if dragStart == nil { dragStart = start }
                updateGeometry { geometry in
                    geometry.dragFocalPoint(
                        from: start,
                        by: value.translation,
                        viewportSize: viewport
                    )
                }
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                guard loadedImage != nil else { return }
                let start = zoomStart ?? settings.zoom
                if zoomStart == nil { zoomStart = start }
                updateGeometry { geometry in
                    geometry.setZoom(start * value.magnification)
                }
            }
            .onEnded { _ in
                zoomStart = nil
            }
    }

    // MARK: Actions

    private func selectPreset(_ preset: WallpaperCropPreset) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            updateGeometry { geometry in
                geometry.setPreset(preset)
            }
        }
    }

    private func resetComposition() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            guard let loadedImage else {
                settings.zoom = WallpaperCropGeometry.minimumZoom
                settings.focalPoint = .center
                return
            }
            var geometry = WallpaperCropGeometry(
                sourceSize: loadedImage.pixelSize,
                settings: settings
            )
            geometry.reset()
            settings = geometry.settings
        }
    }

    private func adjustZoom(_ direction: AccessibilityAdjustmentDirection) {
        updateGeometry { geometry in
            switch direction {
            case .increment:
                geometry.setZoom(geometry.zoom + 0.25)
            case .decrement:
                geometry.setZoom(geometry.zoom - 0.25)
            @unknown default:
                break
            }
        }
    }

    private func updateGeometry(
        _ update: (inout WallpaperCropGeometry) -> Void
    ) {
        guard let loadedImage else { return }
        var geometry = WallpaperCropGeometry(
            sourceSize: loadedImage.pixelSize,
            settings: settings
        )
        update(&geometry)
        settings = geometry.settings
    }

    private func startExport(_ destination: ExportDestination) {
        guard exportTask == nil else { return }
        guard loadedImage != nil else { return }

        let currentSettings = settings
        let currentFormat = exportFormat
        exportState = .exporting(destination)
        exportTask = Task { @MainActor in
            defer {
                exportTask = nil
                exportState = .idle
            }
            do {
                let result = try await WallpaperCropExporter.shared.export(
                    originalURL: request.exportSourceURL,
                    settings: currentSettings,
                    format: currentFormat,
                    maximumLongEdge: Self.maximumExportLongEdge,
                    fileNameHint: request.wallpaperID?.sourceImageID ?? request.id
                )
                try Task.checkCancellation()
                switch destination {
                case .photos:
                    try await WallpaperPhotoSaver.saveToPhotos(fileURL: result.fileURL)
                    alert = .photoSaved
                case .share:
                    shareItem = WallpaperShareItem(url: result.fileURL)
                }
            } catch is CancellationError {
                // Dismissal cancels the task; no user-facing error.
            } catch let error as WallpaperPreviewError {
                alert = .error(error.description(in: locale))
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    // MARK: Loading

    @MainActor
    private func loadImage() async {
        isLoadingImage = true
        loadFailure = nil
        loadedImage = nil
        exportSourcePixelSize = nil

        do {
            let image = try await loader.load(url: request.displayImageURL)
            guard !Task.isCancelled else { return }
            loadedImage = image
            let geometry = WallpaperCropGeometry(
                sourceSize: image.pixelSize,
                settings: settings
            )
            settings = geometry.settings
        } catch is CancellationError {
            return
        } catch let error as WallpaperPreviewError {
            guard !Task.isCancelled else { return }
            loadFailure = error.description(in: locale)
        } catch {
            guard !Task.isCancelled else { return }
            loadFailure = error.localizedDescription
        }

        isLoadingImage = false

        guard loadedImage != nil, !Task.isCancelled else { return }
        let exportPixelSize = await Self.readExportSourcePixelSize(
            at: request.exportSourceURL
        )
        guard !Task.isCancelled else { return }
        exportSourcePixelSize = exportPixelSize
    }

    /// Reads the export source's oriented pixel dimensions without decoding it.
    ///
    /// ImageIO property lookup parses only the container header, off the main
    /// actor. The exporter applies the same EXIF orientation transform before
    /// cropping, so orientations that transpose the stored grid swap width and
    /// height here too. Returns nil when the header cannot be inspected; the
    /// UI then omits the dimension instead of showing the preview's
    /// downsampled size.
    private nonisolated static func readExportSourcePixelSize(
        at url: URL
    ) async -> WallpaperPixelSize? {
        await Task.detached(priority: .utility) { () -> WallpaperPixelSize? in
            guard url.isFileURL,
                  let source = CGImageSourceCreateWithURL(
                      url as CFURL,
                      [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                      source,
                      0,
                      nil
                  ) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0
            else { return nil }

            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if (5...8).contains(orientation) {
                return WallpaperPixelSize(width: height, height: width)
            }
            return WallpaperPixelSize(width: width, height: height)
        }.value
    }

    // MARK: Derived values

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { settings.zoom },
            set: { newValue in
                updateGeometry { geometry in
                    geometry.setZoom(newValue)
                }
            }
        )
    }

    private var zoomPercentText: String {
        "\(Int((settings.zoom * 100).rounded()))%"
    }

    private var canExport: Bool {
        guard loadedImage != nil else { return false }
        if case .exporting = exportState { return false }
        return true
    }

    /// Export dimensions computed from the export source, matching what
    /// `WallpaperCropExporter` will actually write. Nil when the source
    /// metadata is unavailable; the preview's downsampled size would misstate
    /// the exported file.
    private var resolutionText: String? {
        guard loadedImage != nil, let exportSourcePixelSize else { return nil }
        let size = WallpaperCropGeometry(
            sourceSize: exportSourcePixelSize,
            settings: settings
        ).outputPixelSize(maximumLongEdge: Self.maximumExportLongEdge)
        return "\(size.width) × \(size.height) px"
    }

    private func fittedSize(aspect: Double, in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0, aspect.isFinite, aspect > 0 else {
            return .zero
        }
        let widthLimited = available.width
        let heightLimited = widthLimited / aspect
        if heightLimited <= available.height {
            return CGSize(width: widthLimited, height: heightLimited)
        }
        let height = available.height
        return CGSize(width: height * aspect, height: height)
    }
}

// MARK: - Private types

private enum ExportDestination: Equatable {
    case photos
    case share

    var progressKey: LocalizedStringKey {
        switch self {
        case .photos: "正在保存到照片…"
        case .share: "正在准备分享…"
        }
    }
}

private enum ExportState: Equatable {
    case idle
    case exporting(ExportDestination)
}

private struct WallpaperShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private enum WallpaperPreviewAlert: Identifiable {
    case photoSaved
    case error(String)

    var id: String {
        switch self {
        case .photoSaved: return "photo-saved"
        case .error(let message): return "error-\(message)"
        }
    }
}

private extension WallpaperCropPreset {
    var localizedTitleKey: LocalizedStringKey {
        switch self {
        case .lockScreen: "锁屏"
        case .homeScreen: "主屏幕"
        case .landscape: "横屏"
        case .padLandscape: "iPad 横屏"
        case .duoOuter: "Duo 外屏"
        case .duoInnerPortrait: "Duo 内屏·竖"
        case .duoInnerWide: "Duo 内屏·横"
        }
    }
}

private extension WallpaperExportFormat {
    var localizedNameKey: LocalizedStringKey {
        switch self {
        case .automatic: "自动"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }
}
