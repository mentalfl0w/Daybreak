import Foundation

/// Names the user must give the two documented shortcuts.
///
/// These are intentionally not localized: the run-shortcut URL identifies a
/// shortcut by its literal name, so a translated name would break the link.
enum DaybreakShortcutName {
    static let apply = "Daybreak Apply"
    static let daily = "Daybreak Daily"
}

/// Public Shortcuts URL-scheme links.
///
/// Apple documents `shortcuts://run-shortcut?name=…&input=text&text=…` in the
/// Shortcuts User Guide and `shortcuts://` opens the app. There is no public
/// API to sign or import a generated `.shortcut` file, so Daybreak never
/// fabricates an import link.
enum DaybreakShortcutURL {
    static var openShortcutsApp: URL? {
        URL(string: "shortcuts://")
    }

    static func runShortcut(name: String, textInput: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let textInput {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: textInput))
        }
        components.queryItems = items
        return components.url
    }

    /// Fully percent-encodes query values so wallpaper IDs containing `+`,
    /// `&`, `=`, spaces or non-ASCII characters survive Shortcuts' text input.
    /// `URLComponents` leaves `+` unescaped, which some form decoders turn into
    /// a space, so values are encoded explicitly before being assigned.
    static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func runShortcutURL(name: String, textInput: String?) -> URL? {
        var url = "shortcuts://run-shortcut?name=\(percentEncoded(name))"
        if let textInput {
            url += "&input=text&text=\(percentEncoded(textInput))"
        }
        return URL(string: url)
    }
}

/// Public iCloud share links for the two documented shortcuts.
///
/// The links open Apple's iCloud Shortcuts page in the browser. That page's
/// “Get Shortcut” button hands the shortcut to the system Shortcuts app, where
/// the user must confirm adding it. Opening the page is not evidence that a
/// shortcut was installed, and Daybreak cannot verify the shortcut's actions.
enum DaybreakShortcutShareLink {
    static let apply = URL(string: "https://www.icloud.com/shortcuts/2f169a396783405cad17396013ba1a1e")!
    static let daily = URL(string: "https://www.icloud.com/shortcuts/58340789f0cc42d0a5c9e6b277aa6484")!
}


/// Local, user-confirmed setup markers and last-handoff record.
///
/// These are not evidence that the system wallpaper changed. They only let the
/// UI unlock documented `shortcuts://` links and show when Daybreak last handed
/// an image to Shortcuts.
enum DaybreakShortcutGuideStorage {
    static let applyConfigured = "daybreak.shortcuts.applyConfigured"
    static let dailyConfigured = "daybreak.shortcuts.dailyConfigured"
    static let lastHandoffDate = "daybreak.shortcuts.lastHandoffDate"
    static let lastHandoffShortcut = "daybreak.shortcuts.lastHandoffShortcut"
    static let lastHandoffWallpaperID = "daybreak.shortcuts.lastHandoffWallpaperID"

    static func recordHandoff(
        name: String,
        wallpaperID: String?,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(date.timeIntervalSince1970, forKey: lastHandoffDate)
        defaults.set(name, forKey: lastHandoffShortcut)
        defaults.set(wallpaperID ?? "", forKey: lastHandoffWallpaperID)
    }
}
