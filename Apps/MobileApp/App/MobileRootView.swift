import SwiftUI
import UIKit

/// Primary three-section shell: Today, Timeline and Settings.
///
/// Compact windows keep the native `TabView` and its bottom tab bar, including
/// its Liquid Glass treatment and minimise-on-scroll behavior.
///
/// Wide, regular-height iPad windows must not use `TabView` for this layout.
/// iPadOS renders the system
/// tab bar in a top band, and hiding the bar with `toolbarVisibility` still
/// leaves that band reserved: that is the empty strip above the content. The
/// wide shell therefore hosts the same three screens directly and switches
/// between them with visibility, so selecting a section never reloads a
/// screen or resets its navigation.
///
/// Its navigation is a standalone UIKit `UITabBar`, which Apple documents as
/// usable outside a tab bar controller. The bar is laid out in the bottom safe
/// area and the shell measures its height; each section scroll surface keeps
/// that height clear at its end, so the last row is never covered while
/// content still shows through the glass. On iOS 26 the floating Liquid Glass
/// tab-bar presentation is controller-managed; a standalone bar may render the
/// classic bottom treatment instead. That system-owned difference is not
/// emulated, and the rendered shape must be checked on an iPad.
///
/// Section state that must survive the compact/wide swap lives here: Timeline's
/// model, detail route and shortcut hand-off, and Settings' drill-down. The
/// screens themselves are created once per section and stay mounted after their
/// first visit.
///
/// The crop/export preview is also presented here, above both shells: a size
/// class change replaces the whole shell, so presenting from inside a screen
/// would tear down the cover along with its crop, loaded image and export. The
/// preview's apply hand-off state is hoisted for the same reason, because the
/// button can be tapped after the presenting screen was replaced.
struct MobileRootView: View {
    let store: MobileStore
    let navigation: MobileNavigationState

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var timelineModel: TimelineModel
    @State private var timelinePath: [TimelineDetailRoute] = []
    @State private var settingsPath: [SettingsCategory] = []
    @State private var settingsSelection: SettingsCategory? = .language
    @State private var shortcutHandoff = TimelineShortcutHandoff()
    @State private var previewPresentation: WallpaperPreviewPresentation?

    init(store: MobileStore, navigation: MobileNavigationState) {
        self.store = store
        self.navigation = navigation
        _timelineModel = State(initialValue: TimelineModel(store: store))
    }

    /// iPhone retains its system-managed TabView in every window size, so
    /// iPhone Duo can adapt its navigation to the current display.
    private var usesWideShell: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesWideShell {
                WideSectionShell(
                    store: store,
                    navigation: navigation,
                    timelineModel: timelineModel,
                    timelinePath: $timelinePath,
                    settingsPath: $settingsPath,
                    settingsSelection: $settingsSelection,
                    shortcutHandoff: shortcutHandoff,
                    previewPresentation: $previewPresentation
                )
            } else {
                CompactSectionShell(
                    store: store,
                    navigation: navigation,
                    timelineModel: timelineModel,
                    timelinePath: $timelinePath,
                    settingsPath: $settingsPath,
                    settingsSelection: $settingsSelection,
                    shortcutHandoff: shortcutHandoff,
                    previewPresentation: $previewPresentation
                )
            }
        }
        // Attached above the shell switch: replacing the shell must not end the
        // presentation, so the same `WallpaperPreviewView` keeps its identity
        // and all of its composition and export state.
        .fullScreenCover(item: $previewPresentation) { presentation in
            WallpaperPreviewView(
                request: presentation.request,
                onSetWallpaperRequested: presentation.onSetWallpaperRequested
            )
            .onDisappear {
                presentation.onDismiss?()
            }
        }
    }
}

// MARK: - Window-level preview

/// One crop/export session owned by the window rather than by a screen.
///
/// Only presentation identity and the two screen-specific callbacks live here;
/// the composition itself stays inside `WallpaperPreviewView`, so the exposed
/// state survives a compact/wide shell swap unchanged.
struct WallpaperPreviewPresentation: Identifiable {
    let request: WallpaperPreviewRequest
    /// Timeline's shortcut hand-off. Today's preview has no such action.
    let onSetWallpaperRequested: ((WallpaperCropSettings) -> Void)?
    /// Runs after the preview is gone. Timeline refreshes its model here, as it
    /// did when the cover lived on the Timeline screen.
    let onDismiss: (() -> Void)?

    var id: String { request.id }
}

// MARK: - Compact shell

/// Native tab bar for iPhone, Duo folded and narrow iPad windows.
private struct CompactSectionShell: View {
    let store: MobileStore
    let navigation: MobileNavigationState
    let timelineModel: TimelineModel
    @Binding var timelinePath: [TimelineDetailRoute]
    @Binding var settingsPath: [SettingsCategory]
    @Binding var settingsSelection: SettingsCategory?
    let shortcutHandoff: TimelineShortcutHandoff
    @Binding var previewPresentation: WallpaperPreviewPresentation?

    var body: some View {
        @Bindable var navigation = navigation
        // Tab titles are resolved to plain strings from the store's persisted
        // interface language: the system tab bar applies a title value change
        // in place, while an unresolved `LocalizedStringKey` kept the language
        // it was installed with. Reading the locale here also makes this shell
        // re-evaluate its labels as soon as the language changes.
        let interfaceLocale = store.interfaceLocale

        TabView(selection: $navigation.selectedSection) {
            Tab(value: MobileNavigationState.Section.today) {
                TodayScreen(
                    store: store,
                    navigation: navigation,
                    previewPresentation: $previewPresentation
                )
            } label: {
                Label(
                    MobileNavigationState.Section.today.localizedTitle(in: interfaceLocale),
                    systemImage: MobileNavigationState.Section.today.systemImage
                )
            }

            Tab(value: MobileNavigationState.Section.timeline) {
                TimelineScreen(
                    store: store,
                    navigation: navigation,
                    model: timelineModel,
                    path: $timelinePath,
                    shortcutHandoff: shortcutHandoff,
                    previewPresentation: $previewPresentation
                )
            } label: {
                Label(
                    MobileNavigationState.Section.timeline.localizedTitle(in: interfaceLocale),
                    systemImage: MobileNavigationState.Section.timeline.systemImage
                )
            }

            Tab(value: MobileNavigationState.Section.settings) {
                SettingsScreen(
                    store: store,
                    navigation: navigation,
                    path: $settingsPath,
                    selectedCategory: $settingsSelection
                )
            } label: {
                Label(
                    MobileNavigationState.Section.settings.localizedTitle(in: interfaceLocale),
                    systemImage: MobileNavigationState.Section.settings.systemImage
                )
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

// MARK: - Wide shell

/// iPad-style shell: no system `TabView` tab bar, one native standalone
/// `UITabBar` at the bottom.
///
/// Every visited section stays in the tree. Inactive sections are transparent
/// and do not take hits, so switching is instant and keeps scroll position,
/// sheets and in-flight work alive.
private struct WideSectionShell: View {
    let store: MobileStore
    let navigation: MobileNavigationState
    let timelineModel: TimelineModel
    @Binding var timelinePath: [TimelineDetailRoute]
    @Binding var settingsPath: [SettingsCategory]
    @Binding var settingsSelection: SettingsCategory?
    let shortcutHandoff: TimelineShortcutHandoff
    @Binding var previewPresentation: WallpaperPreviewPresentation?

    /// Sections that have been opened at least once. The selected section is
    /// always included by the body, so a new section appears in the same
    /// update instead of flashing an empty frame.
    @State private var mountedSections: Set<MobileNavigationState.Section> = [.today]

    /// Measured height of the native tab bar. The initial value is only used
    /// before the first measurement.
    @State private var barHeight: CGFloat = estimatedNativeTabBarHeight

    /// Height every wide-shell scroll surface keeps clear at its bottom. The
    /// estimate is a floor so the first frame, before UIKit reports the
    /// fitting height, cannot put the last row under the bar.
    private var effectiveTabBarClearance: CGFloat {
        max(barHeight, estimatedNativeTabBarHeight)
    }

    /// Base color of the section currently on screen. It is drawn behind the
    /// sections, never on top of them, so a split-view sidebar keeps its own
    /// background and the area behind the floating bar reads as part of the
    /// page instead of a separate opaque band.
    private var sectionBaseColor: Color {
        switch navigation.selectedSection {
        case .settings:
            return Color(uiColor: .systemGroupedBackground)
        case .today, .timeline:
            return Color(uiColor: .systemBackground)
        }
    }

    var body: some View {
        @Bindable var navigation = navigation
        let selection = navigation.selectedSection
        let mounted = mountedSections.union([selection])

        ZStack(alignment: .bottom) {
            sections(selection: selection, mounted: mounted)
                // The bar floats over the sections, so its glass samples the
                // page behind it. Every section scroll surface reserves the
                // measured height as a bottom content margin instead of
                // relying on a safe-area inset here: an inset placed outside
                // the section's navigation container was not honored by the
                // scroll views on iPad, and About and Timeline kept their
                // last rows under the bar. Content margins are applied by the
                // scroll view itself, so they do not depend on that
                // propagation. Nothing opaque is drawn at this edge, so
                // split-view sidebar material stays visible behind the glass
                // and no band covers it.
                .environment(\.wideShellTabBarClearance, effectiveTabBarClearance)
                // Behind the sections, so short pages and the area behind the
                // floating bar show the page color. Ignoring the safe area
                // keeps the window edge filled.
                .background {
                    sectionBaseColor
                        .ignoresSafeArea()
                }

            // Bottom-aligned inside the safe area: the system tab bar never
            // overlaps the home indicator. Each section's scroll surfaces
            // keep its height clear, so it covers only content that can still
            // be scrolled into view above it.
            NativeSectionTabBar(
                selection: $navigation.selectedSection,
                locale: store.interfaceLocale
            )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    barHeight = height
                }
        }
        .onChange(of: selection) { _, section in
            mountedSections.insert(section)
        }
    }

    @ViewBuilder
    private func sections(
        selection: MobileNavigationState.Section,
        mounted: Set<MobileNavigationState.Section>
    ) -> some View {
        ZStack {
            if mounted.contains(.today) {
                TodayScreen(
                    store: store,
                    navigation: navigation,
                    previewPresentation: $previewPresentation
                )
                .sectionVisibility(selection == .today)
            }

            if mounted.contains(.timeline) {
                TimelineScreen(
                    store: store,
                    navigation: navigation,
                    model: timelineModel,
                    path: $timelinePath,
                    shortcutHandoff: shortcutHandoff,
                    previewPresentation: $previewPresentation
                )
                .sectionVisibility(selection == .timeline)
            }

            if mounted.contains(.settings) {
                SettingsScreen(
                    store: store,
                    navigation: navigation,
                    path: $settingsPath,
                    selectedCategory: $settingsSelection
                )
                .sectionVisibility(selection == .settings)
            }
        }
    }
}

private extension View {
    /// Keeps an inactive section alive without letting it draw, take touches
    /// or be read by VoiceOver.
    func sectionVisibility(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

// MARK: - Native section tab bar

/// Standalone UIKit tab bar used by wide windows.
///
/// `UITabBar` is a public control that Apple documents as usable outside a
/// `UITabBarController`; a standalone bar reports selection through its
/// delegate. That is the entire integration here. No custom appearance, glass
/// surface or private hierarchy is installed: the system draws the bar and
/// its items, and each `UITabBarItem` supplies the native VoiceOver title,
/// position and selected state.
///
/// The wide shell bottom-aligns this view inside the safe area. Section scroll
/// views reserve its measured height as a bottom content margin, so the bar
/// floats over scrolling content without covering the end of it.
///
/// On iOS 26 the floating Liquid Glass tab-bar presentation is provided by
/// `UITabBarController`. A standalone bar may instead render the classic
/// full-width bottom treatment, and its exact shape is a system decision.
/// That difference is not faked here; check the rendered presentation on an
/// iPad before treating it as final.
/// Standard tab bar height, used only before the first measurement and if
/// UIKit reports no usable fitting height.
private let estimatedNativeTabBarHeight: CGFloat = 49

@MainActor
private struct NativeSectionTabBar: UIViewRepresentable {
    @Binding var selection: MobileNavigationState.Section
    /// Interface locale for the plain-string item titles. It is passed in from
    /// the shell's body, which reads `MobileStore.interfaceLocale`, so a
    /// language change is a normal representable value change and
    /// `updateUIView` retitles the existing items instead of replacing them.
    let locale: Locale

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeUIView(context: Context) -> UITabBar {
        let tabBar = UITabBar()
        tabBar.delegate = context.coordinator
        tabBar.items = Self.makeItems(locale: locale)
        tabBar.selectedItem = tabBar.items?[Self.index(of: selection)]
        context.coordinator.localizedLocale = locale
        return tabBar
    }

    func updateUIView(_ tabBar: UITabBar, context: Context) {
        // Refresh the binding: SwiftUI may rebuild the representable value
        // while keeping its coordinator and UIKit view.
        context.coordinator.selection = $selection
        context.coordinator.updateLocalizedTitles(in: tabBar, locale: locale)

        let index = Self.index(of: selection)
        if let items = tabBar.items,
           items.indices.contains(index),
           tabBar.selectedItem !== items[index] {
            tabBar.selectedItem = items[index]
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITabBar,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width.flatMap { width in
            width.isFinite && width > 0 ? width : nil
        }
        let boundsWidth = uiView.bounds.width > 0 ? uiView.bounds.width : nil
        guard let width = proposedWidth ?? boundsWidth else { return nil }

        // The system decides the bar's fitting height, including any changes
        // across size classes or Dynamic Type. The shell measures the result.
        let fittingHeight = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: width,
            height: fittingHeight > 0 ? fittingHeight : estimatedNativeTabBarHeight
        )
    }

    private static func makeItems(locale: Locale) -> [UITabBarItem] {
        MobileNavigationState.Section.allCases.enumerated().map { index, section in
            UITabBarItem(
                title: section.localizedTitle(in: locale),
                image: UIImage(systemName: section.systemImage),
                tag: index
            )
        }
    }

    private static func index(of section: MobileNavigationState.Section) -> Int {
        MobileNavigationState.Section.allCases.firstIndex(of: section) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<MobileNavigationState.Section>
        /// Locale used for the titles currently installed on the bar.
        var localizedLocale: Locale?

        init(selection: Binding<MobileNavigationState.Section>) {
            self.selection = selection
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            let sections = MobileNavigationState.Section.allCases
            guard sections.indices.contains(item.tag) else { return }
            let section = sections[item.tag]
            guard section != selection.wrappedValue else { return }
            selection.wrappedValue = section
        }

        /// Updates titles in place so item identity and the current selection
        /// survive an interface-language change.
        func updateLocalizedTitles(in tabBar: UITabBar, locale: Locale) {
            guard localizedLocale != locale else { return }
            localizedLocale = locale

            let sections = MobileNavigationState.Section.allCases
            guard let items = tabBar.items, items.count == sections.count else {
                let items = NativeSectionTabBar.makeItems(locale: locale)
                tabBar.items = items
                tabBar.selectedItem = items[
                    NativeSectionTabBar.index(of: selection.wrappedValue)
                ]
                return
            }

            for (item, section) in zip(items, sections) {
                item.title = section.localizedTitle(in: locale)
            }
            // Item buttons cache their measured width; ask the bar to re-lay
            // out for titles of a different length.
            tabBar.setNeedsLayout()
        }
    }
}

// MARK: - Localized navigation titles

extension View {
    /// Sets a navigation title resolved from Daybreak's string catalog in
    /// `locale`.
    ///
    /// `navigationTitle(LocalizedStringKey)` and `navigationTitle(Text)` give
    /// the navigation container an unresolved key. The container keeps the
    /// title string it installed and does not re-resolve the key when only the
    /// interface-language environment changes, so the bar stayed in the launch
    /// language until the stack was rebuilt. Passing the resolved string turns
    /// a language change into an ordinary title change that UIKit applies in
    /// place: the selected tab, navigation path, selected date and any
    /// presented preview are untouched.
    ///
    /// The title is looked up in `locale`, not merely formatted with it:
    /// `String(localized:locale:)` would keep the bundle's launch localization,
    /// while `MobileLocalizedString.resolve` asks for the catalog entry in
    /// `locale` through `LocalizedStringResource`.
    func navigationTitle(_ title: String.LocalizationValue, locale: Locale) -> some View {
        navigationTitle(MobileLocalizedString.resolve(title, locale: locale))
    }
}

// MARK: - Wide shell bottom clearance

/// Height the wide shell's floating tab bar occupies above the window's bottom
/// safe area. Zero outside the wide shell, where the system tab bar owns its
/// own content inset.
private struct WideShellTabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var wideShellTabBarClearance: CGFloat {
        get { self[WideShellTabBarClearanceKey.self] }
        set { self[WideShellTabBarClearanceKey.self] = newValue }
    }
}

extension View {
    /// Reserves the wide shell's tab bar as a bottom content margin of the
    /// scroll view this is applied to. The margin follows the view's own
    /// content insets for any locale, Dynamic Type or bar height the system
    /// reports, and keeps the area behind the floating bar transparent
    /// instead of drawing a band.
    ///
    /// - Parameter extraBottomGap: Additional space between the end of the
    ///   content and the floating bar. It is added only inside the wide shell,
    ///   where the shell measures the bar; compact windows keep the system tab
    ///   bar's own inset untouched.
    func wideShellTabBarInset(extraBottomGap: CGFloat = 0) -> some View {
        modifier(WideShellTabBarInset(extraBottomGap: extraBottomGap))
    }
}

private struct WideShellTabBarInset: ViewModifier {
    var extraBottomGap: CGFloat = 0

    @Environment(\.wideShellTabBarClearance) private var clearance

    /// A zero clearance means the system tab bar owns the bottom inset; only
    /// the wide shell's measured clearance may be enlarged.
    private var resolvedBottomMargin: CGFloat {
        clearance > 0 ? clearance + extraBottomGap : 0
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, resolvedBottomMargin, for: .scrollContent)
            .contentMargins(.bottom, resolvedBottomMargin, for: .scrollIndicators)
    }
}
