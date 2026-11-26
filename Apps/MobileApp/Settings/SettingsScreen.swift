import DaybreakCore
import Foundation
import SwiftUI

/// Settings root for iPhone, iPad and Duo.
///
/// Compact widths use a native drill-down list; wide widths use a split view.
/// The breakpoint is measured from the available container, never from a
/// device identifier or orientation. Every value and mutation comes from the
/// shared `MobileStore`. The window shell owns the drill-down path and split
/// selection; this screen owns only transient operation state.
struct SettingsScreen: View {
    let store: MobileStore
    let navigation: MobileNavigationState

    @Environment(\.locale) private var locale
    /// Owned by the window shell so the drill-down survives a compact/wide
    /// chrome change.
    @Binding private var path: [SettingsCategory]
    @Binding private var selectedCategory: SettingsCategory?
    @State private var isChangingLanguage = false
    @State private var isChangingQuality = false
    @State private var isReadingCache = false
    @State private var isApplyingCapacity = false
    @State private var cacheReport: MobileCacheReport?
    @State private var cacheLoadError: String?
    @State private var cacheMessage: CacheOperationMessage?
    @State private var marketErrorMessage: String?

    init(
        store: MobileStore,
        navigation: MobileNavigationState,
        path: Binding<[SettingsCategory]>,
        selectedCategory: Binding<SettingsCategory?>
    ) {
        self.store = store
        self.navigation = navigation
        _path = path
        _selectedCategory = selectedCategory
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width >= 760 {
                    splitLayout
                } else {
                    compactLayout
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // The split view's sidebar material is translucent over the window.
        // Extending the grouped base into the status bar keeps that band from
        // reading as a separate, unlit strip above the sidebar.
        .background {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea(edges: .top)
        }
        .alert(
            "无法切换内容地区",
            isPresented: Binding(
                get: { marketErrorMessage != nil },
                set: { if !$0 { marketErrorMessage = nil } }
            ),
            presenting: marketErrorMessage
        ) { _ in
            Button("好", role: .cancel) { marketErrorMessage = nil }
        } message: { message in
            Text(verbatim: message)
        }
        .task {
            if cacheReport == nil {
                await loadCacheReport()
            }
        }
    }

    // MARK: Layouts

    private var compactLayout: some View {
        NavigationStack(path: $path) {
            rootList
                .navigationTitle("设置", locale: locale)
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(for: SettingsCategory.self) { category in
                    destination(for: category)
                }
        }
    }

    private var splitLayout: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
            .navigationTitle("设置", locale: locale)
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.sidebar)
            .wideShellTabBarInset()
        } detail: {
            NavigationStack {
                destination(for: selectedCategory ?? .language)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .containerBackground(for: .navigationSplitView) {
            Color(uiColor: .systemGroupedBackground)
        }
    }

    // MARK: Root list

    private var rootList: some View {
        List {
            Section("内容与显示") {
                NavigationLink(value: SettingsCategory.language) {
                    SettingsRootRow(
                        title: "界面语言",
                        systemImage: "globe",
                        value: currentLanguage.title(in: locale)
                    )
                }
                NavigationLink(value: SettingsCategory.market) {
                    SettingsRootRow(
                        title: "内容地区",
                        systemImage: "globe.asia.australia",
                        value: marketSummary
                    )
                }
                NavigationLink(value: SettingsCategory.quality) {
                    SettingsRootRow(
                        title: "图片质量",
                        systemImage: "photo.badge.arrow.down",
                        value: qualitySummary
                    )
                }
            }

            Section("存储") {
                NavigationLink(value: SettingsCategory.storage) {
                    SettingsRootRow(
                        title: "缓存",
                        systemImage: "internaldrive",
                        value: cacheSummary
                    )
                }
            }

            Section("跨设备") {
                NavigationLink(value: SettingsCategory.sync) {
                    SettingsRootRow(
                        title: "同步",
                        systemImage: "icloud",
                        value: syncSummary
                    )
                }
            }

            Section("帮助") {
                NavigationLink(value: SettingsCategory.shortcuts) {
                    SettingsRootRow(
                        title: "快捷指令",
                        systemImage: "wand.and.stars",
                        value: nil
                    )
                }
            }

            Section {
                NavigationLink(value: SettingsCategory.about) {
                    SettingsRootRow(
                        title: "关于 Daybreak",
                        systemImage: "info.circle",
                        value: Self.versionText
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .wideShellTabBarInset()
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(for category: SettingsCategory) -> some View {
        switch category {
        case .language:
            LanguageSettingsView(
                selection: currentLanguage,
                isUpdating: isChangingLanguage
            ) { language in
                guard !isChangingLanguage,
                      language != currentLanguage,
                      let target = MobileInterfaceLanguage(rawValue: language.rawValue)
                else { return }
                isChangingLanguage = true
                Task {
                    await store.setInterfaceLanguage(target)
                    isChangingLanguage = false
                }
            }
        case .market:
            MarketSettingsView(
                profiles: store.supportedMarketProfiles,
                systemMarket: store.systemMarket,
                effectiveMarket: store.effectiveMarket,
                followsSystem: store.isFollowingSystemMarket,
                isUpdating: store.isUpdatingMarket,
                notice: store.marketSelectionNotice
            ) { choice in
                let preference: MobileMarketPreference
                switch choice {
                case .followSystem:
                    preference = .followSystem
                case .market(let market):
                    preference = .market(market)
                }
                Task {
                    let previousError = store.lastErrorMessage
                    await store.setMarketSelection(preference)
                    if let newError = store.lastErrorMessage, newError != previousError {
                        marketErrorMessage = newError
                    }
                }
            }
        case .quality:
            ImageQualitySettingsView(
                selection: store.settings.imageQuality,
                isUpdating: isChangingQuality
            ) { quality in
                guard !isChangingQuality, quality != store.settings.imageQuality else { return }
                isChangingQuality = true
                Task {
                    await store.setImageQuality(quality)
                    isChangingQuality = false
                }
            }
        case .storage:
            cacheDestination
        case .sync:
            if let syncController = store.syncController {
                SyncSettingsView(
                    syncController: syncController,
                    diagnosticsDirectory: store.syncDiagnosticsDirectoryURL
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .shortcuts:
            ShortcutsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }

    private var cacheDestination: some View {
        CacheSettingsView(
            report: cacheReport,
            loadError: cacheLoadError,
            cacheLimits: store.settings.cacheLimits,
            capacity: CacheCapacity.nearest(to: store.cacheCapacityBytes),
            isBusy: store.isStorageBusy || isReadingCache || isApplyingCapacity,
            message: cacheMessage,
            onRefresh: { await loadCacheReport() },
            onApplyCapacity: { capacity in
                await applyCapacity(capacity)
            },
            onCleanup: { kind in
                await performCleanup(kind)
            },
            onRepair: {
                await repairCache()
            }
        )
        .task {
            await loadCacheReport()
        }
    }

    // MARK: Cache operations

    private func loadCacheReport() async {
        guard !isReadingCache else { return }
        isReadingCache = true
        cacheLoadError = nil
        do {
            cacheReport = try await store.cacheReport()
        } catch {
            cacheLoadError = describe(error)
        }
        isReadingCache = false
    }

    private func applyCapacity(_ capacity: CacheCapacity) async {
        isApplyingCapacity = true
        defer { isApplyingCapacity = false }
        do {
            let eviction = try await store.setCacheCapacity(capacity.bytes)
            if eviction.evictedAssets.isEmpty {
                cacheMessage = CacheOperationMessage(
                    tone: .success,
                    text: MobileLocalizedString.resolve(
                        "已应用 \(capacity.label) 缓存上限；当前缓存没有超出上限，未删除文件。",
                        locale: locale
                    )
                )
            } else {
                cacheMessage = CacheOperationMessage(
                    tone: .success,
                    text: MobileLocalizedString.resolve(
                        "已应用 \(capacity.label) 缓存上限；清理了 \(eviction.evictedAssets.count) 个未受保护文件，共 \(SettingsByteText.string(eviction.evictedBytes))。受保护图片仍然保留。",
                        locale: locale
                    )
                )
            }
        } catch {
            cacheMessage = CacheOperationMessage(tone: .failure, text: describe(error))
        }
        await loadCacheReport()
    }

    private func performCleanup(_ kind: CacheCleanupKind) async {
        do {
            let message: String
            let tone: CacheOperationMessage.Tone
            switch kind {
            case .thumbnails:
                let result = try await store.clearThumbnails()
                message = clearMessage(result, noun: MobileLocalizedString.resolve("缩略图", locale: locale))
                tone = result.failedCount > 0 ? .warning : .success
            case .unprotectedOriginals:
                let result = try await store.clearOriginals()
                message = clearMessage(result, noun: MobileLocalizedString.resolve("原图", locale: locale))
                tone = result.failedCount > 0 ? .warning : .success
            case .stories:
                let count = try await store.clearStories()
                message = MobileLocalizedString.resolve(
                    "已清除 \(count) 条每日介绍；图片、元数据与收藏未改动。",
                    locale: locale
                )
                tone = .success
            }
            cacheMessage = CacheOperationMessage(tone: tone, text: message)
        } catch {
            cacheMessage = CacheOperationMessage(tone: .failure, text: describe(error))
        }
        await loadCacheReport()
    }

    private func clearMessage(_ result: MobileCacheClearResult, noun: String) -> String {
        var text = MobileLocalizedString.resolve(
            "已清理 \(result.removedAssetCount) 个\(noun)文件，共 \(SettingsByteText.string(result.removedBytes))。",
            locale: locale
        )
        if result.skippedProtectedCount > 0 {
            text += " " + MobileLocalizedString.resolve(
                "\(result.skippedProtectedCount) 个受保护文件已保留。",
                locale: locale
            )
        }
        if result.failedCount > 0 {
            text += " " + MobileLocalizedString.resolve(
                "另有 \(result.failedCount) 个文件未能删除，可稍后重试修复。",
                locale: locale
            )
        }
        return text
    }

    private func repairCache() async {
        do {
            let report = try await store.repairCache()
            var text = MobileLocalizedString.resolve(
                "修复完成：移除 \(report.orphanedFilesRemoved.count) 个孤儿文件；\(report.missingAssets.count) 个缓存记录缺少文件。",
                locale: locale
            )
            if !report.failedOrphanRemovals.isEmpty {
                text += " " + MobileLocalizedString.resolve(
                    "有 \(report.failedOrphanRemovals.count) 个文件未能移除。",
                    locale: locale
                )
            }
            cacheMessage = CacheOperationMessage(
                tone: report.failedOrphanRemovals.isEmpty ? .success : .warning,
                text: text
            )
        } catch {
            cacheMessage = CacheOperationMessage(tone: .failure, text: describe(error))
        }
        await loadCacheReport()
    }

    private func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    // MARK: Values

    private var currentLanguage: SettingsLanguage {
        SettingsLanguage.matching(rawValue: store.settings.interfaceLanguage.rawValue)
    }

    private var marketSummary: String {
        let name = TodayFormatting.marketName(store.effectiveMarket, locale: locale)
        if store.isFollowingSystemMarket {
            return "\(MobileLocalizedString.resolve("跟随系统", locale: locale)) · \(name)"
        }
        return name
    }

    private var qualitySummary: String {
        switch store.settings.imageQuality {
        case .highResolution: return MobileLocalizedString.resolve("高清", locale: locale)
        case .fullHD: return MobileLocalizedString.resolve("全高清", locale: locale)
        case .compact: return MobileLocalizedString.resolve("省流", locale: locale)
        }
    }

    private var cacheSummary: String {
        let usage = cacheReport?.usage ?? store.storageUsage
        guard let usage else {
            return MobileLocalizedString.resolve("正在读取…", locale: locale)
        }
        return SettingsByteText.string(usage.totalAssetBytes)
    }

    private var syncSummary: String {
        guard let sync = store.syncController else {
            return MobileLocalizedString.resolve("正在读取…", locale: locale)
        }
        guard sync.enabled else {
            return MobileLocalizedString.resolve("已关闭", locale: locale)
        }
        guard sync.folderName != nil else {
            return MobileLocalizedString.resolve("未选择文件夹", locale: locale)
        }
        switch sync.status {
        case .disabled:
            return MobileLocalizedString.resolve("已关闭", locale: locale)
        case .awaitingFolder:
            return MobileLocalizedString.resolve("未选择文件夹", locale: locale)
        case .syncing:
            return MobileLocalizedString.resolve("正在同步", locale: locale)
        case .completed:
            return MobileLocalizedString.resolve("已完成（本机）", locale: locale)
        case .pending:
            return MobileLocalizedString.resolve("等待同步", locale: locale)
        case .unavailable:
            return MobileLocalizedString.resolve("文件夹不可用", locale: locale)
        case .unauthorized:
            return MobileLocalizedString.resolve("需要授权", locale: locale)
        case .failed:
            return MobileLocalizedString.resolve("同步失败", locale: locale)
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }
}

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case language
    case market
    case quality
    case storage
    case sync
    case shortcuts
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .language: return "界面语言"
        case .market: return "内容地区"
        case .quality: return "图片质量"
        case .storage: return "缓存"
        case .sync: return "同步"
        case .shortcuts: return "快捷指令"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .language: return "globe"
        case .market: return "globe.asia.australia"
        case .quality: return "photo.badge.arrow.down"
        case .storage: return "internaldrive"
        case .sync: return "icloud"
        case .shortcuts: return "wand.and.stars"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsRootRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String?

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 8)

            if let value {
                Text(verbatim: value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}
