import DaybreakCore
import SwiftUI

/// Reusable “set wallpaper with Shortcuts” entry point.
///
/// The handoff always carries the wallpaper ID and exact market/date
/// occurrence selected in Daybreak.
struct DaybreakSetWallpaperButton: View {
    let wallpaperReference: DaybreakWallpaperReference

    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @AppStorage(DaybreakShortcutGuideStorage.applyConfigured) private var applyConfigured = false
    @State private var isShowingGuide = false
    @State private var errorMessage: String?

    init(wallpaperID: WallpaperID, occurrenceKey: OccurrenceKey) {
        self.wallpaperReference = DaybreakWallpaperReference(
            wallpaperID: wallpaperID,
            occurrenceKey: occurrenceKey
        )
    }

    private var shortcutInput: String {
        wallpaperReference.text
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
                ? "运行 Daybreak Apply 快捷指令，并传入所选图片及其日期、地区。是否设置成功由系统显示。"
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
                        ShortcutsGuideView(selectedWallpaperReference: wallpaperReference)
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
            textInput: shortcutInput
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
                wallpaperID: shortcutInput
            )
        }
    }
}
