import AppIntents
import Foundation

/// Zero-install App Shortcuts for Daybreak.
///
/// App Shortcuts appear in Siri, Spotlight, the Shortcuts app and the Action
/// button as soon as the app is installed; nobody has to import or sign a
/// shortcut file first. Both shortcuts below hand a real cached image file to
/// Shortcuts. Setting the system wallpaper stays a system "设置墙纸照片" action
/// the user adds to their own shortcut, because a public App Intent cannot set
/// the wallpaper and iOS has no public API to read it.
///
/// `GetWallpaperByIDIntent` is deliberately absent: its wallpaper ID is
/// free-form text, and an App Shortcut phrase can only interpolate enumerable
/// `AppEntity`/`AppEnum` values. It remains available as an action when the
/// user builds the documented `Daybreak Apply` shortcut.
///
/// Phrases live in `AppShortcuts.xcstrings`. Spoken and Spotlight phrases
/// follow the system's app language, not Daybreak's in-app language override.
struct DaybreakAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTodayWallpaperIntent(),
            phrases: [
                "用\(.applicationName)获取今日壁纸",
                "在\(.applicationName)中获取今日壁纸",
                "打开\(.applicationName)获取今日壁纸"
            ],
            shortTitle: "获取今日壁纸",
            systemImageName: "photo.on.rectangle.angled"
        )
        AppShortcut(
            intent: GetCurrentWallpaperIntent(),
            phrases: [
                "用\(.applicationName)获取当前壁纸",
                "在\(.applicationName)中获取当前选中的壁纸",
                "打开\(.applicationName)获取当前壁纸"
            ],
            shortTitle: "获取当前选中的壁纸",
            systemImageName: "photo"
        )
    }
}
