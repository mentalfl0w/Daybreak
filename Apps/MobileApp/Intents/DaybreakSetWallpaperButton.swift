import SwiftUI

/// Reusable “set wallpaper with Shortcuts” entry point.
///
/// After the user confirms a `Daybreak Apply` shortcut exists, a tap runs that
/// shortcut through the documented Shortcuts URL and passes the selected image
/// ID as text. Otherwise it opens the setup guide. The label and status text
/// never claim that Daybreak changed the system wallpaper itself.
struct DaybreakSetWallpaperButton: View {
    let wallpaperID: String

    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @AppStorage(DaybreakShortcutGuideStorage.applyConfigured) private var applyConfigured = false
    @State private var isShowingGuide = false
    @State private var errorMessage: String?

    init(wallpaperID: String) {
        self.wallpaperID = wallpaperID
    }

    var body: some View {
        Button {
            runOrShowGuide()
        } label: {
            Label("用快捷指令设为壁纸", systemImage: "photo.badge.arrow.down")
        }
        .buttonStyle(.bordered)
        .tint(.daybreakActionTint)
        .accessibilityHint(
            applyConfigured
                ? "运行 Daybreak Apply 快捷指令，并把当前壁纸 ID 作为文本传入。是否设置成功由系统显示。"
                : "打开快捷指令设置说明。Daybreak 不会直接修改系统壁纸。"
        )
        .sheet(isPresented: $isShowingGuide) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        ShortcutsGuideView(selectedWallpaperID: wallpaperID)
                    }
                    .padding()
                }
                .navigationTitle("快捷指令设置壁纸", locale: locale)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            isShowingGuide = false
                        }
                    }
                }
            }
        }
    }

    private func runOrShowGuide() {
        errorMessage = nil
        guard applyConfigured else {
            isShowingGuide = true
            return
        }
        guard let url = DaybreakShortcutURL.runShortcutURL(
            name: DaybreakShortcutName.apply,
            textInput: wallpaperID
        ) else {
            errorMessage = MobileLocalizedString.resolve("无法构造运行快捷指令的链接。", locale: DaybreakShortcutLocale.current)
            isShowingGuide = true
            return
        }
        openURL(url) { accepted in
            guard accepted else {
                errorMessage = MobileLocalizedString.resolve("无法运行快捷指令。请确认名称完全一致，并且已安装“快捷指令”App。", locale: DaybreakShortcutLocale.current)
                isShowingGuide = true
                return
            }
            DaybreakShortcutGuideStorage.recordHandoff(
                name: DaybreakShortcutName.apply,
                wallpaperID: wallpaperID
            )
        }
    }
}
