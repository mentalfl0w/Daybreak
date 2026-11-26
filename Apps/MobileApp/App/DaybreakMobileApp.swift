import SwiftUI

/// Mobile entry point.
///
/// Exactly one `MobileStore` exists per process. Every `WindowGroup` scene
/// creates its own `MobileNavigationState`; both are injected into the view
/// tree, so opening a second window shares content but never shares a selected
/// tab, calendar date or reading surface.
@main
struct DaybreakMobileApp: App {
    @State private var store = MobileStore.shared

    var body: some Scene {
        WindowGroup {
            MobileSceneRoot()
                .environment(store)
        }
    }
}

private struct MobileSceneRoot: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = MobileNavigationState()

    var body: some View {
        // Read the interface locale in the scene view body: the observation
        // is registered where SwiftUI re-evaluates the window content, so a
        // language change updates `\.locale` for the existing scene
        // immediately. The locale is a persisted preference, not view
        // identity, so no screen, tab or navigation state is replaced.
        let interfaceLocale = store.interfaceLocale

        MobileRootView(store: store, navigation: navigation)
            .environment(navigation)
            .environment(\.locale, interfaceLocale)
            .task {
                await store.start()
            }
            .onChange(of: scenePhase) { _, phase in
                // Foreground return: every window reports it, and the single
                // process-wide controller coalesces the triggers into one
                // pass. This never waits for the pass or blocks the UI.
                guard phase == .active else { return }
                Task { await store.noteForegroundActivity() }
            }
    }
}

// MARK: - Shared action tint

extension Color {
    /// Foreground tint for text- and glyph-only actions: bordered buttons,
    /// links and badges drawn on app-managed cards.
    ///
    /// Filled prominent buttons keep the system accent, so their contrasting
    /// labels are unchanged. Only the interactive blue is lightened in Dark
    /// Mode, where the system blue label sits at roughly 4.5:1 on
    /// `secondarySystemBackground` and reads poorly at caption sizes. Light
    /// Mode keeps the system blue.
    static let daybreakActionTint = Color(uiColor: .daybreakActionTint)
}

private extension UIColor {
    static let daybreakActionTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.251, green: 0.612, blue: 1.0, alpha: 1.0)
            : .systemBlue
    }
}
