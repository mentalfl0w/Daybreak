import SwiftUI

/// Hosts the Shortcuts setup guide inside Settings.
///
/// The guide owns all steps and run links; Settings only supplies the page
/// title and scrolling. This avoids two copies of instructions drifting apart.
struct ShortcutsSettingsView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            ShortcutsGuideView()
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("快捷指令", locale: locale)
        .wideShellTabBarInset()
    }
}
