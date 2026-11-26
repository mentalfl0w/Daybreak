import AppKit
import SwiftUI

@main
struct DaybreakMacApp: App {
    @NSApplicationDelegateAdaptor(DaybreakAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var loginItem = LoginItemController()
    @State private var didScheduleLoginItemConsent = false
    @State private var selection: AppSection? = .today
    @State private var pendingAction: AppPendingAction?
    @State private var settingsSection: SettingsSection = .wallpaper
    @AppStorage("daybreak.interfaceLanguage") private var interfaceLanguage = "system"

    private var interfaceLocale: Locale {
        interfaceLanguage == "system" ? .current : Locale(identifier: interfaceLanguage)
    }

    var body: some Scene {
        Window("Daybreak", id: "main") {
            AppShell(
                model: model,
                selection: $selection,
                pendingAction: $pendingAction,
                settingsSection: $settingsSection
            )
            .frame(minWidth: 960, minHeight: 680)
            .loginItemConsentSheet(loginItem)
            .environment(\.locale, interfaceLocale)
            .wallpaperConfirmationDialog(model: model)
            .background {
                MainWindowRegistration()
            }
            .task {
                await scheduleLoginItemConsentIfNeeded()
            }
        }
        .defaultSize(width: 1_140, height: 800)
        .commands {
            DaybreakCommands(
                model: model,
                selection: $selection,
                pendingAction: $pendingAction,
                settingsSection: $settingsSection
            )
        }
        MenuBarExtra("Daybreak", systemImage: "sunrise") {
            SceneActions(model: model, selection: $selection, pendingAction: $pendingAction)
                .environment(\.locale, interfaceLocale)
        }
        .menuBarExtraStyle(.window)
    }

    /// Offers the login-item choice once, after the notification permission
    /// request has settled.
    ///
    /// Starting at login is opt-in, so this only decides whether the consent
    /// sheet may be shown; the system registration happens after the user
    /// clicks Enable. Waiting for `prepareAuthorizationIfNeeded()` and for an
    /// in-flight notification request keeps the two system dialogs from
    /// stacking. If the user leaves the notification prompt unanswered, the
    /// login prompt is skipped for this launch rather than competing with it;
    /// Settings still exposes the same control.
    @MainActor
    private func scheduleLoginItemConsentIfNeeded() async {
        guard !didScheduleLoginItemConsent else { return }
        didScheduleLoginItemConsent = true

        await model.dailyNotifications.prepareAuthorizationIfNeeded()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            if Task.isCancelled { return }
            if model.dailyNotifications.authorization != .unknown,
               !model.dailyNotifications.isUpdating {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled,
              model.dailyNotifications.authorization != .unknown,
              !model.dailyNotifications.isUpdating
        else {
            return
        }

        // Give the system notification alert a moment to leave the screen
        // before attaching the consent sheet to the main window.
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled, !model.dailyNotifications.isUpdating else { return }
        loginItem.considerConsentAtLaunch()
    }
}

/// Attaches the startup login-item consent sheet to the main window. The
/// sheet carries its own buttons, so dismissing it can never register
/// anything; only the explicit enable action reaches ServiceManagement.
private struct LoginItemConsentSheetModifier: ViewModifier {
    let controller: LoginItemController

    func body(content: Content) -> some View {
        // Reading the phase in this view registers Observation tracking, so
        // the sheet dismisses whenever the controller clears it.
        let phase = controller.consentPhase
        content.sheet(
            isPresented: Binding(
                get: { phase != nil },
                set: { presented in
                    if !presented {
                        controller.dismissConsentPrompt()
                    }
                }
            )
        ) {
            LoginItemConsentSheet(controller: controller)
        }
    }
}

private struct LoginItemConsentSheet: View {
    let controller: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sunrise.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            switch controller.consentPhase {
            case .asking, .failed:
                askingContent
            case .awaitingApproval:
                approvalContent
            case nil:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var title: LocalizedStringKey {
        switch controller.consentPhase {
        case .awaitingApproval:
            return "需要在系统设置中批准"
        case .failed:
            return "无法启用登录时启动"
        case .asking, nil:
            return "在登录时启动 Daybreak？"
        }
    }

    private var primaryLabel: LocalizedStringKey {
        controller.consentPhase == .failed ? "重试" : "启用登录时启动"
    }

    private var askingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daybreak 可以在你登录这台 Mac 时自动打开，以便提前准备今日壁纸。")
                .fixedSize(horizontal: false, vertical: true)

            Text("只有你选择启用后，Daybreak 才会通过 macOS 登记登录项；之后可随时在设置中关闭。选择“不启用”后将不再自动询问，也可以在设置中随时开启。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.consentPhase == .failed,
               let guidance = controller.recoveryGuidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("不启用") {
                    controller.declineConsent()
                }
                Spacer(minLength: 12)
                Button(primaryLabel) {
                    controller.acceptConsent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isUpdating)
            }
        }
    }

    private var approvalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS 已登记登录项，但还需要你在系统设置的“登录项”中允许 Daybreak。")
                .fixedSize(horizontal: false, vertical: true)
            Text("批准之前，Daybreak 不会在登录时启动。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("完成") {
                    controller.dismissConsentPrompt()
                }
                Spacer(minLength: 12)
                Button("打开登录项设置") {
                    controller.openSystemSettings()
                    controller.dismissConsentPrompt()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension View {
    /// Presents the once-only startup login-item consent sheet.
    func loginItemConsentSheet(_ controller: LoginItemController) -> some View {
        modifier(LoginItemConsentSheetModifier(controller: controller))
    }
}

struct SceneActions: View {
    let model: AppModel
    @Binding var selection: AppSection?
    @Binding var pendingAction: AppPendingAction?
    @Environment(\.openWindow) private var openWindow

    private func openToday(_ action: AppPendingAction? = nil) {
        selection = .today
        pendingAction = action
        MainWindowAccess.shared.presentMainWindow()
    }

    var body: some View {
        MenuBarPanel(model: model,
                     onApply: { openToday(.applyWallpaper) },
                     onOpen: { openToday() },
                     onSettings: {
                         selection = .settings
                         MainWindowAccess.shared.presentMainWindow()
                     })
            .task {
                // The menu bar scene lives for the whole process and is the
                // fallback entry point while the Dock icon is hidden. Register
                // SwiftUI's only public way to recreate a closed Window scene.
                MainWindowAccess.shared.register {
                    openWindow(id: "main")
                }
                model.start()
            }
    }
}

/// Registers SwiftUI's open-window action as soon as the main window exists.
/// `SceneActions` registers the same action from the menu bar scene; this
/// earlier registration keeps external reopen events working even when the
/// menu bar panel has not been opened yet. Invisible and non-interactive.
private struct MainWindowRegistration: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                MainWindowAccess.shared.register {
                    openWindow(id: "main")
                }
                MainWindowAccess.shared.raiseRegisteredWindow()
            }
    }
}

/// Pure rule for keeping the main window available across an activation-policy
/// change.
///
/// Kept free of AppKit so the guarantee that a window the user had closed,
/// hidden, or minimized is never brought back implicitly stays testable
/// without changing the test host's Dock icon.
enum MainWindowRestoration: Equatable {
    /// No main window was visible before the change; leave every window as it
    /// was.
    case none
    /// Re-show the main window that was visible and still exists.
    case existingWindow
    /// The visible scene window disappeared with the policy change; recreate
    /// it.
    case newWindow

    static func selection(
        hadVisibleMainWindow: Bool,
        hasExistingMainWindow: Bool,
        canCreateWindow: Bool
    ) -> MainWindowRestoration {
        // A policy change may only restore what the user could already see.
        // Launching with a closed window, toggling while the window is
        // minimized, or toggling after hiding it must not produce or raise a
        // window that was not visible before.
        guard hadVisibleMainWindow else { return .none }
        if hasExistingMainWindow { return .existingWindow }
        return canCreateWindow ? .newWindow : .none
    }
}

/// Bridges AppKit activation events to SwiftUI's window scene.
///
/// Hiding the Dock icon removes the icon's reopen affordance, and the app can
/// keep running with no visible window. Menu bar actions and external
/// open/reopen events focus an existing window (including a minimized or
/// ordered-out one); runtime activation-policy changes re-show only the
/// windows that were visible when the policy changed. SwiftUI is asked to
/// recreate the window only when a window that should be shown is gone.
@MainActor
final class MainWindowAccess {
    static let shared = MainWindowAccess()

    private var openWindowAction: (() -> Void)?

    private init() {}

    func register(openWindow: @escaping () -> Void) {
        openWindowAction = openWindow
    }

    /// Raises the registered main window after SwiftUI has attached the scene.
    /// Launch callbacks can arrive before the Window scene creates its NSWindow.
    func raiseRegisteredWindow() {
        let application = NSApplication.shared
        let windows = Self.mainWindows(in: application)
        guard !windows.isEmpty else { return }
        _ = Self.present(windows, in: application)
    }

    /// Main-scene windows only: `NSPanel` excludes the menu bar extra and its
    /// popover, and `canBecomeMain` excludes sheets and alerts that belong to
    /// the main window.
    private static func mainWindows(in application: NSApplication) -> [NSWindow] {
        application.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
    }

    /// Only windows the user can see right now. Minimized, hidden, and closed
    /// windows are deliberately excluded: a Dock toggle must not restore a
    /// state the user chose before toggling.
    private static func visibleMainWindows(in application: NSApplication) -> [NSWindow] {
        mainWindows(in: application).filter(\.isVisible)
    }

    /// Applies the saved Dock choice while preserving the window the user
    /// currently has on screen. Safe before a window exists: it never creates
    /// one. At launch or reopen only a real policy transition restores a
    /// window, so re-asserting an unchanged choice does not steal focus.
    @discardableResult
    func applySavedActivationPolicy(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        let showDockIcon = DockIconVisibility.isEnabled(in: defaults)
        let application = NSApplication.shared
        let policyWillChange = application.activationPolicy()
            != DockIconVisibility.activationPolicy(showDockIcon: showDockIcon)
        let windowsToRestore = policyWillChange
            ? Self.visibleMainWindows(in: application)
            : []

        guard DockIconVisibility.apply(showDockIcon: showDockIcon) else {
            return false
        }
        restore(windowsToRestore, in: application)
        return true
    }

    /// Changes the activation policy for a runtime Dock icon toggle.
    ///
    /// The transition can deactivate Daybreak and remove its windows from the
    /// screen in both directions. Only windows that were visible at the moment
    /// of the toggle are re-shown and focused afterwards; a window the user had
    /// closed, hidden, or minimized stays that way and is never created or
    /// raised by this path.
    @discardableResult
    func applyActivationPolicy(showDockIcon: Bool) -> Bool {
        let application = NSApplication.shared
        let visibleWindows = Self.visibleMainWindows(in: application)

        guard DockIconVisibility.apply(showDockIcon: showDockIcon) else {
            return false
        }
        // A user toggle always re-asserts the window that was on screen.
        // `activationPolicy()` is not reliable enough across OS releases to
        // skip this when it reports that the policy did not change.
        restore(visibleWindows, in: application)
        return true
    }

    /// Re-shows only windows that were visible at the moment of the policy
    /// change. A window the user had closed, hidden, or minimized before the
    /// change is left alone.
    private func restore(_ visibleWindows: [NSWindow], in application: NSApplication) {
        // If SwiftUI destroyed the visible window along with the policy
        // change, no restorable window remains and the scene window is
        // recreated once.
        let restorableWindows = visibleWindows.filter { window in
            Self.mainWindows(in: application).contains { $0 === window }
        }
        switch MainWindowRestoration.selection(
            hadVisibleMainWindow: !visibleWindows.isEmpty,
            hasExistingMainWindow: !restorableWindows.isEmpty,
            canCreateWindow: openWindowAction != nil
        ) {
        case .none:
            break
        case .existingWindow:
            if !Self.present(restorableWindows, in: application) {
                presentNewMainWindow(in: application)
            }
        case .newWindow:
            presentNewMainWindow(in: application)
        }
    }

    /// Focuses the main window, recreating it only when none remains. Used by
    /// the menu bar panel and by AppKit reopen/open events.
    func presentMainWindow() {
        let application = NSApplication.shared
        let windows = Self.mainWindows(in: application)
        if !windows.isEmpty, Self.present(windows, in: application) {
            return
        }
        presentNewMainWindow(in: application)
    }

    private func presentNewMainWindow(in application: NSApplication) {
        // Activate before asking SwiftUI to create the window so the new
        // window can become key immediately, then re-assert after creation.
        application.activate(ignoringOtherApps: true)
        openWindowAction?()
        application.activate(ignoringOtherApps: true)
    }

    /// Orders the given windows in front and focuses one of them. Returns
    /// whether any window is visible afterwards.
    @discardableResult
    private static func present(
        _ windows: [NSWindow],
        in application: NSApplication
    ) -> Bool {
        guard !windows.isEmpty else { return false }

        // An accessory app can be left hidden by a policy change; unhide
        // before ordering its windows back on screen.
        if application.isHidden {
            application.unhide(nil)
        }
        for window in windows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            // Order even when AppKit reports the window as ordered out:
            // that is the state a policy change leaves behind.
            window.orderFrontRegardless()
        }
        application.activate(ignoringOtherApps: true)
        // Ordering again after activation covers the case where the policy
        // change deactivated the app between the two calls.
        windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
        return windows.contains { $0.isVisible }
    }
}


final class DaybreakAppDelegate: NSObject, NSApplicationDelegate {
    /// Apply the saved Dock choice before the first window appears. This is
    /// the earliest public delegate callback; the Dock icon may otherwise be
    /// visible for part of the launch animation.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // No window exists yet, so this only sets the policy; it never opens
        // a window that the user had closed in the previous session.
        MainWindowAccess.shared.applySavedActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Creating the SwiftUI Window scene can reset the activation policy
        // decided in `applicationWillFinishLaunching`. Re-assert the saved
        // value once the scene graph is ready.
        MainWindowAccess.shared.applySavedActivationPolicy()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Activation through LaunchServices (open -a, Finder) must not undo a
        // hidden Dock icon, and must still produce a usable main window.
        MainWindowAccess.shared.applySavedActivationPolicy()
        MainWindowAccess.shared.presentMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // No URL scheme or document type is registered today, but external
        // opens must never leave a hidden-Dock launch without a window.
        MainWindowAccess.shared.presentMainWindow()
    }
}

struct DaybreakCommands: Commands {
    let model: AppModel
    @Binding var selection: AppSection?
    @Binding var pendingAction: AppPendingAction?
    @Binding var settingsSection: SettingsSection
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开主窗口") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
        // The standard Settings item is replaced so Command-, selects the
        // in-window settings page directly instead of creating a window.
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { navigate(to: .settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("前往") {
            Button("今日") { navigate(to: .today) }
                .keyboardShortcut("1", modifiers: .command)
            Button("时光") { navigate(to: .library) }
                .keyboardShortcut("2", modifiers: .command)
            Button("存储") { navigate(to: .settings, settingsTab: .storage) }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("设置") { navigate(to: .settings) }
        }
        CommandMenu("今日") {
            Button("刷新今日") {
                model.refreshNow()
            }
            .keyboardShortcut("r")
            .disabled(model.isRefreshing)

            Button("下载原图") {
                model.downloadOriginal()
            }
            .disabled(
                model.payload == nil
                    || model.payload?.hasOriginal == true
                    || model.isDownloadingOriginal
            )

            Divider()

            Button("设为壁纸…") {
                navigate(to: .today)
                pendingAction = .applyWallpaper
            }
            .disabled(
                !model.canApplyWallpaper
                    || model.isPreparingConsent
                    || model.displays.isEmpty
            )
        }
    }

    private func navigate(to section: AppSection, settingsTab: SettingsSection? = nil) {
        // Assign the tab before the section so the command still works when
        // Settings is already visible and only its tab needs to change.
        if let settingsTab {
            settingsSection = settingsTab
        }
        selection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
