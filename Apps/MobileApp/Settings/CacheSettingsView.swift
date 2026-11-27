import DaybreakCore
import Foundation
import SwiftUI

/// Kind of cache cleanup the user can request. Confirmation copy lives here so
/// every entry point describes the same consequences.
enum CacheCleanupKind: String, Identifiable, CaseIterable, Sendable {
    case thumbnails
    case unprotectedOriginals
    case stories

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .thumbnails: return "清理全部缩略图？"
        case .unprotectedOriginals: return "清理未受保护的原图？"
        case .stories: return "清理已缓存的每日介绍？"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .thumbnails:
            return "将删除本机所有预览缩略图，包括受保护图片的缩略图。原图、元数据、每日介绍、收藏和固定日期保持不变；之后联网时会按需重新下载。"
        case .unprotectedOriginals:
            return "只删除未被收藏、固定日期或当前壁纸保护的原图。受保护的原图会保留；元数据、每日介绍和缩略图保持不变。"
        case .stories:
            return "删除所有已缓存的每日介绍文本。图片、元数据、收藏和固定日期不受影响；介绍需要在联网后重新获取。此操作不可撤销。"
        }
    }

    var confirmationLabel: LocalizedStringKey {
        switch self {
        case .thumbnails: return "清理缩略图"
        case .unprotectedOriginals: return "清理原图"
        case .stories: return "清理介绍"
        }
    }

    var buttonTitle: LocalizedStringKey {
        switch self {
        case .thumbnails: return "清理全部缩略图"
        case .unprotectedOriginals: return "清理未受保护的原图"
        case .stories: return "清理每日介绍"
        }
    }

    var systemImage: String {
        switch self {
        case .thumbnails: return "photo.stack"
        case .unprotectedOriginals: return "photo"
        case .stories: return "text.book.closed"
        }
    }
}

/// One inline result after a cache operation. Data comes from the store's real
/// operation result; the view layer only formats it.
struct CacheOperationMessage: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable { case success, warning, failure }
    let id = UUID()
    let tone: Tone
    let text: String
}

/// Cache overview, capacity limit, protection status and selective cleanup.
///
/// All mutations run through `MobileStore`; this view owns no cache state and
/// never deletes files directly.
struct CacheSettingsView: View {
    let report: MobileCacheReport?
    let loadError: String?
    let cacheLimits: CacheLimits
    let capacity: CacheCapacity
    let isBusy: Bool
    let message: CacheOperationMessage?
    let onRefresh: @MainActor () async -> Void
    let onApplyCapacity: @MainActor (CacheCapacity) async -> Void
    let onCleanup: @MainActor (CacheCleanupKind) async -> Void
    let onRepair: @MainActor () async -> Void

    @Environment(\.locale) private var locale
    @State private var selectedCapacity: CacheCapacity
    @State private var pendingCleanup: CacheCleanupKind?

    init(
        report: MobileCacheReport?,
        loadError: String?,
        cacheLimits: CacheLimits,
        capacity: CacheCapacity,
        isBusy: Bool,
        message: CacheOperationMessage?,
        onRefresh: @escaping @MainActor () async -> Void,
        onApplyCapacity: @escaping @MainActor (CacheCapacity) async -> Void,
        onCleanup: @escaping @MainActor (CacheCleanupKind) async -> Void,
        onRepair: @escaping @MainActor () async -> Void
    ) {
        self.report = report
        self.loadError = loadError
        self.cacheLimits = cacheLimits
        self.capacity = capacity
        self.isBusy = isBusy
        self.message = message
        self.onRefresh = onRefresh
        self.onApplyCapacity = onApplyCapacity
        self.onCleanup = onCleanup
        self.onRepair = onRepair
        _selectedCapacity = State(initialValue: capacity)
    }

    var body: some View {
        Form {
            if let message {
                Section {
                    messageRow(message)
                }
            }

            overviewSection
            capacitySection
            protectionSection
            cleanupSection
            recoverySection
        }
        .navigationTitle("缓存", locale: locale)
        .wideShellTabBarInset()
        .disabled(isBusy && report == nil)
        .onChange(of: capacity) { _, newValue in
            selectedCapacity = newValue
        }
        .alert(item: $pendingCleanup) { kind in
            Alert(
                title: Text(kind.title),
                message: Text(kind.message),
                primaryButton: .destructive(Text(kind.confirmationLabel)) {
                    Task { await onCleanup(kind) }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: Overview

    private var overviewSection: some View {
        Section {
            if let loadError {
                VStack(alignment: .leading, spacing: 10) {
                    Label("无法读取缓存状态", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(verbatim: loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") {
                        Task { await onRefresh() }
                    }
                    .disabled(isBusy)
                }
            }

            if let report {
                usageBody(report.usage)
            } else if loadError == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取本地缓存…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("本地缓存")
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理缓存")
                } else {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("刷新缓存状态")
                }
            }
        } footer: {
            Text("图片说明和每日介绍不计入图片缓存容量。")
        }
    }

    private func usageBody(_ usage: StorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(SettingsByteText.string(usage.totalAssetBytes))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text("图片缓存")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(usage.assetCount) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            capacityMeter(
                title: "缩略图",
                bytes: usage.thumbnailBytes,
                limit: cacheLimits.thumbnailBytes,
                symbol: "photo.stack"
            )
            capacityMeter(
                title: "原图",
                bytes: usage.originalBytes,
                limit: cacheLimits.originalBytes,
                symbol: "photo"
            )

            if usage.missingAssetCount > 0 {
                Label(
                    "\(usage.missingAssetCount) 个记录缺少本地文件",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if usage.assetCount == 0 {
                Text("目前没有缓存图片。打开“今日”或“时光”，图片会在需要时保存到本机。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func capacityMeter(
        title: LocalizedStringKey,
        bytes: Int,
        limit: Int,
        symbol: String
    ) -> some View {
        let fraction = limit > 0 ? min(Double(bytes) / Double(limit), 1) : 0
        let percent = Int((fraction * 100).rounded())
        let overLimit = bytes > limit && limit >= 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(SettingsByteText.string(bytes)) / \(SettingsByteText.string(limit))")
                    .font(.caption2)
                    .foregroundStyle(overLimit ? .orange : .secondary)
                    .monospacedDigit()
            }
            ProgressView(value: fraction)
                .tint(overLimit ? .orange : .accentColor)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text("\(percent)%"))
        }
    }

    // MARK: Capacity

    private var capacitySection: some View {
        Section {
            // An explicit destination instead of `.pickerStyle(.navigationLink)`:
            // the implicit picker page rendered blank inside the settings
            // `NavigationStack(path:)`, so the presets are a real pushed view.
            NavigationLink {
                CacheCapacitySelectionView(selection: $selectedCapacity)
            } label: {
                HStack(spacing: 8) {
                    Text("缓存总上限")
                    Spacer(minLength: 8)
                    Text(selectedCapacity.label)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在应用缓存上限")
            }

            Button {
                Task { await onApplyCapacity(selectedCapacity) }
            } label: {
                Label("应用 \(selectedCapacity.label) 上限并清理", systemImage: "externaldrive.badge.minus")
            }
            .disabled(isBusy)
        } header: {
            Text("容量上限")
        } footer: {
            Text("缓存上限用于控制图片占用。超过上限时，Daybreak 会优先清理较久未使用的图片。收藏、固定日期和受保护壁纸的原图会保留，因此实际用量可能超过上限。")
        }
    }

    // MARK: Protection

    private var protectionSection: some View {
        Section {
            LabeledContent("收藏的图片") {
                Text("\(protectedCount(.favorite))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("固定的日期") {
                Text("\(protectedCount(.pinnedDate))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("当前壁纸保护") {
                Text("\(protectedCount(.currentlyApplied))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let report {
                LabeledContent("受保护原图") {
                    Text("\(report.protectedOriginalAssetCount) 个文件")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("保留的图片")
        } footer: {
            Text("同一张图片可能同时被收藏或固定，因此各项数量可能重复。壁纸设置结果由系统显示，Daybreak 无法确认图片是否已应用。")
        }
    }

    private func protectedCount(_ reason: PinReason) -> Int {
        report?.protectedImageCountsByReason[reason] ?? 0
    }

    // MARK: Cleanup

    private var cleanupSection: some View {
        Section {
            cleanupButton(.thumbnails)
            cleanupButton(.unprotectedOriginals)
            cleanupButton(.stories)
        } header: {
            Text("选择性清理")
        } footer: {
            Text("图片和每日介绍可以分别清理。收藏与固定日期会保留；联网后可重新获取已删除内容。清理无法撤销。")
        }
    }

    private func cleanupButton(_ kind: CacheCleanupKind) -> some View {
        Button(role: .destructive) {
            pendingCleanup = kind
        } label: {
            Label(kind.buttonTitle, systemImage: kind.systemImage)
        }
        .disabled(isBusy)
    }

    // MARK: Recovery

    private var recoverySection: some View {
        Section {
            Button {
                Task { await onRepair() }
            } label: {
                Label("检查并修复缓存", systemImage: "wrench.and.screwdriver")
            }
            .disabled(isBusy)
        } header: {
            Text("缓存修复")
        } footer: {
            Text("查找本机缓存中不再使用的图片和缺少本机文件的记录；不会扫描其他应用的文件，也不会删除收藏和每日介绍。")
        }
    }

    // MARK: Message

    private func messageRow(_ message: CacheOperationMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.tone == .failure ? "xmark.octagon" : message.tone == .warning ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(message.tone == .failure ? .red : message.tone == .warning ? .orange : .green)
                .accessibilityHidden(true)
            Text(verbatim: message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pushed preset list for the total cache capacity.
///
/// This is a plain destination view rather than a `Picker` styled with
/// `.navigationLink`, because that implicit page rendered blank inside the
/// settings navigation stack. The 20/80 per-kind split intentionally stays in
/// `MobileStore`; this screen only chooses the total soft limit, so the two
/// layers cannot disagree about the numbers.
struct CacheCapacitySelectionView: View {
    @Binding var selection: CacheCapacity

    @Environment(\.locale) private var locale

    var body: some View {
        List {
            Section {
                ForEach(CacheCapacity.allCases) { capacity in
                    Button {
                        selection = capacity
                    } label: {
                        HStack(spacing: 10) {
                            Text(capacity.label)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if capacity == selection {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(capacity == selection ? .isSelected : [])
                }
            } footer: {
                Text("缓存上限用于控制图片占用。超过上限时，Daybreak 会优先清理较久未使用的图片。收藏、固定日期和受保护壁纸的原图会保留，因此实际用量可能超过上限。")
            }
        }
        .navigationTitle("缓存总上限", locale: locale)
        .wideShellTabBarInset()
        .navigationBarTitleDisplayMode(.inline)
    }
}
