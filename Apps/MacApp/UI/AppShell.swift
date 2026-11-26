import AppKit
import SwiftUI
import DaybreakCore

enum AppPendingAction: Equatable {
    case applyWallpaper
    case enableAutoSync
}

enum AppSection: String, CaseIterable, Identifiable {
    case today, library, settings
    var id: Self { self }
    /// Resolved explicitly because AppKit controls sit outside SwiftUI's
    /// localized-string environment.
    func title(in locale: Locale) -> String {
        switch self {
        case .today: String(localized: LocalizedStringResource("今日", locale: locale))
        case .library: String(localized: LocalizedStringResource("时光", locale: locale))
        case .settings: String(localized: LocalizedStringResource("设置", locale: locale))
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.horizon"
        case .library: "calendar"
        case .settings: "gearshape"
        }
    }
}

struct AppShell: View {
    let model: AppModel
    @Binding var selection: AppSection?
    @Binding var pendingAction: AppPendingAction?
    /// The Settings page owns its tab selection one level above the page, so
    /// commands and cross-page entry points can target a specific tab even
    /// when Settings is already the visible section.
    @Binding var settingsSection: SettingsSection
    @State private var library: LibraryModel?
    @State private var recap: RecapScreenModel?
    @State private var libraryMode: LibraryBrowseMode = .gallery
    /// True while the active page's vertical scroll view is offset past its
    /// resting top edge. Only that state may reveal the window toolbar
    /// backdrop; pointer hover must never do so. Today reports this from its
    /// real scroll geometry; pages that do not route a top scroll surface keep
    /// it false, so their bar stays hidden instead of being revealed by hover.
    @State private var isTopScrollOverlap = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private var currentSection: AppSection { selection ?? .today }

    private var sectionPages: some View {
        ZStack {
            page(for: currentSection)
                .id(currentSection)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: currentSection
        )
    }

    @ViewBuilder
    private func page(for section: AppSection) -> some View {
        switch section {
        case .today:
            todayPage
        case .library:
            libraryPage
        case .settings:
            settingsPage
        }
    }

    private var todayPage: some View {
        TodayView(model: model, isTopScrollOverlap: $isTopScrollOverlap)
            .task(id: pendingAction) {
                guard let action = pendingAction else { return }
                pendingAction = nil
                switch action {
                case .applyWallpaper: model.beginApplyWallpaper()
                case .enableAutoSync: model.setAutoSync(true)
                }
            }
    }

    var body: some View {
        NavigationStack {
            sectionPages
                // Today owns the overlap signal; other pages keep their
                // native scroll-edge behavior rather than inheriting
                // Today's state.
                .modifier(WindowToolbarBackdrop(
                    isToday: currentSection == .today,
                    isScrolled: isTopScrollOverlap
                ))
                .transaction { $0.animation = nil }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                IconSegmentedControl(
                    selection: Binding(
                        get: { selection ?? .today },
                        set: { selection = $0 }
                    ),
                    segments: AppSection.allCases.map {
                        IconSegmentedControl<AppSection>.Segment(
                            value: $0,
                            title: $0.title(in: locale),
                            systemImage: $0.icon
                        )
                    },
                    locale: locale
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .daybreakWindowFrosting()
        .task(id: model.service != nil) {
            model.start()
            guard let service = model.service, library == nil else { return }
            library = LibraryModel(
                service: service,
                market: model.market,
                noteSyncActivity: model.noteSyncActivity
            )
            recap = RecapScreenModel(
                repository: service.repository,
                currentWallpaperProtection: model.currentWallpaperProtection,
                noteSyncActivity: model.noteSyncActivity
            )
        }
        .onChange(of: selection) { _, _ in
            // A page change starts at a new top edge. Do not carry Today's
            // scrolled state into a page whose scroll view has not reported.
            isTopScrollOverlap = false
        }
        .onChange(of: model.market) { _, market in
            library?.updateMarket(market)
        }
        .onChange(of: model.syncDataRevision) { _, _ in
            // Folder sync imported records, favorites, pins or verified assets
            // in the background. Reload both repository-backed pages in place:
            // the selected month, scope, day and gallery identity stay as the
            // user left them, and no page is torn down or reset.
            Task {
                await library?.reload()
                await recap?.reload()
            }
        }
        .onChange(of: locale) { _, _ in
            // Model-generated feedback is resolved when it is produced. Clear
            // transient action copy and re-run the existing local read paths so
            // any stored error or load state is regenerated in the newly
            // selected interface language instead of keeping the old language.
            model.interfaceLanguageDidChange()
            recap?.dismissActionFeedback()
            library?.dismissMessages()
            Task {
                await recap?.reload()
                await library?.reload()
            }
        }
    }

    /// Settings lives in the main window, so consent actions only switch the
    /// current page back to Today. `TodayView` observes `pendingAction` and
    /// starts the preflight there; no second window is opened.
    private func goToToday(_ action: AppPendingAction? = nil) {
        selection = .today
        pendingAction = action
    }

    /// Switches to Settings and selects one of its tabs. The tab assignment is
    /// unconditional: navigation from the menu or Storage must still change the
    /// visible tab when the Settings section is already selected.
    private func openSettings(_ section: SettingsSection) {
        settingsSection = section
        selection = .settings
    }

    @ViewBuilder
    private var localDataState: some View {
        if case let .failed(message) = model.loadState, model.service == nil {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle)
                Text("无法读取本地历史")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重试") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("正在载入本地内容…")
        }
    }

    @ViewBuilder
    private var libraryPage: some View {
        if let library, let recap {
            // Recap statistics now live inside 时光; there is no separate
            // recap destination or sub-navigation.
            LibraryView(
                model: library,
                recap: recap,
                appModel: model,
                mode: Binding(
                    get: { libraryMode },
                    set: { libraryMode = $0 }
                ),
                onOpenStorage: {
                    // Storage is a Settings tab now, not a separate page or
                    // sheet. Set the tab first so this also works when
                    // Settings is already visible.
                    openSettings(.storage)
                }
            )
        } else {
            localDataState
        }
    }

    private var settingsPage: some View {
        SettingsView(
            model: model,
            recap: recap,
            section: $settingsSection,
            onApply: { goToToday(.applyWallpaper) },
            onEnableAutoSync: { goToToday(.enableAutoSync) },
            onOpen: { goToToday() }
        )
    }
}

// MARK: - Section tabs

/// Native icon-and-title segmented control used by the window's toolbar
/// section tabs and the Library browse switch.
///
/// SwiftUI's segmented `Picker` keeps only a segment's text on macOS. The
/// AppKit `NSSegmentedControl` draws both when every segment carries an image
/// and a label, so these two controls use it directly instead of drawing a
/// custom selected background.
///
/// Every current use switches content panes, so the control declares AppKit's
/// native tab role on macOS 27 and later. AppKit then owns the appearance and
/// announces the segments as tabs to VoiceOver. AppKit has no public glass
/// segment style for a content-area control before macOS 27: wrapping this
/// control in `NSGlassEffectView` would add a second glass plate around the
/// control's own bezel, and a hand-drawn selection would not be the system
/// control. Earlier systems therefore keep the stock native appearance with
/// icon and title intact, which is the macOS 14 fallback.
///
/// Settings category switching no longer uses this control: its tabs are a
/// real `TabView` so the system draws the native tab bar and selection.
///
/// `selection` remains the single source of truth: the coordinator writes a
/// tapped segment back to the binding, and `updateNSView` mirrors programmatic
/// changes such as a menu command selecting a section.
/// Callers resolve titles in the interface locale; a locale change updates the
/// installed labels in place, so the control keeps its selection and identity.
struct IconSegmentedControl<Selection: Hashable>: NSViewRepresentable {
    struct Segment {
        let value: Selection
        let title: String
        let systemImage: String
    }

    @Binding var selection: Selection
    let segments: [Segment]
    let locale: Locale

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: segments.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentStyle = .automatic
        // Size every segment to its icon-plus-title content instead of
        // distributing unused width, so a crowded toolbar never pulls this
        // control over the centered section tabs.
        control.segmentDistribution = .fit
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (index, segment) in segments.enumerated() {
            if let image = NSImage(
                systemSymbolName: segment.systemImage,
                accessibilityDescription: nil
            ) {
                control.setImage(image, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
            control.setToolTip(segment.title, forSegment: index)
        }

        // The window's section tabs and the Library browse switch both
        // navigate between content panes. Declaring that intent is what lets
        // AppKit draw its tab treatment on macOS 27 instead of the legacy
        // solid segment bezel; earlier systems ignore it.
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }

        context.coordinator.appliedLocale = locale
        control.selectedSegment = index(of: selection)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.appliedLocale != locale {
            for (index, segment) in segments.enumerated() {
                control.setLabel(segment.title, forSegment: index)
                control.setToolTip(segment.title, forSegment: index)
            }
            control.invalidateIntrinsicContentSize()
            context.coordinator.appliedLocale = locale
        }

        let selected = index(of: selection)
        if selected >= 0, control.selectedSegment != selected {
            control.selectedSegment = selected
        }
    }

    private func index(of value: Selection) -> Int {
        segments.firstIndex { $0.value == value } ?? -1
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: IconSegmentedControl
        var appliedLocale: Locale?

        init(_ parent: IconSegmentedControl) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0,
                  parent.segments.indices.contains(sender.selectedSegment)
            else { return }
            parent.selection = parent.segments[sender.selectedSegment].value
        }
    }
}

/// Controls the window toolbar background from the page's actual scroll
/// overlap instead of AppKit's pointer-driven reveal.
///
/// With `.fullSizeContentView`, AppKit shows the titlebar separator on hover
/// even when the scroll content has not moved. On macOS 15 and later, an
/// explicit toolbar-background visibility replaces that heuristic: hidden at
/// the resting top edge, visible only after the scroll view reports a real
/// offset. macOS 14 uses the older toolbar background visibility modifier.
private struct WindowToolbarBackdrop: ViewModifier {
    let isToday: Bool
    let isScrolled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isToday {
            content
        } else if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(
                isScrolled ? .visible : .hidden,
                for: .windowToolbar
            )
        } else {
            content.toolbarBackground(isScrolled ? .visible : .hidden, for: .windowToolbar)
        }
    }
}


// MARK: - Frosted window backdrop

extension View {
    /// Gives the hosting window a native, app-wide frosted backdrop.
    ///
    /// The backdrop uses an `NSVisualEffectView` with `.behindWindow` blending.
    /// The system draws the titlebar material separately for legibility.
    ///
    /// Accessibility:
    /// - Reduce Transparency: the window becomes opaque again and the
    ///   backdrop falls back to `windowBackgroundColor`.
    /// - Increase Contrast: a denser semantic tint sits over the blur.
    func daybreakWindowFrosting() -> some View {
        modifier(DaybreakWindowFrosting())
    }
}

private struct DaybreakWindowFrosting: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    DaybreakFrostedMaterial()
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(contrast == .increased ? 0.32 : 0.12)
                }

                WindowAppearanceBridge(isTranslucent: !reduceTransparency)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
}

/// Native behind-window material. `.underWindowBackground` is the semantic
/// material for a document-window background; WorkDock's `.hudWindow` is the
/// stronger HUD variant of the same blur.
private struct DaybreakFrostedMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Configures only the window that hosts this view. It never touches system
/// settings, wallpapers or other applications' windows.
private struct WindowAppearanceBridge: NSViewRepresentable {
    let isTranslucent: Bool

    func makeNSView(context: Context) -> WindowAppearanceProbe {
        let view = WindowAppearanceProbe(frame: .zero)
        view.isTranslucent = isTranslucent
        return view
    }

    func updateNSView(_ nsView: WindowAppearanceProbe, context: Context) {
        nsView.isTranslucent = isTranslucent
    }

    final class WindowAppearanceProbe: NSView {
        var isTranslucent = true {
            didSet { applyWindowAppearance(force: false) }
        }

        private weak var configuredWindow: NSWindow?
        private var configuredTranslucency: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowAppearance(force: true)
        }

        func applyWindowAppearance(force: Bool) {
            guard let window else { return }
            let needsUpdate = force
                || configuredWindow !== window
                || configuredTranslucency != isTranslucent
            guard needsUpdate else { return }

            configuredWindow = window
            configuredTranslucency = isTranslucent

            window.isOpaque = !isTranslucent
            window.backgroundColor = isTranslucent ? .clear : .windowBackgroundColor

            // The app paints the frosted window material across the full
            // window. Do not let AppKit add a second titlebar material or its
            // hover-only separator; SwiftUI's window-toolbar background is
            // instead driven explicitly by real scroll overlap in AppShell.
            window.styleMask = window.styleMask.union(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none

            window.invalidateShadow()
        }
    }
}
