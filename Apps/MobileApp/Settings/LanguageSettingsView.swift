import DaybreakCore
import Foundation
import SwiftUI

/// Interface-language picker.
///
/// The choice is app-local: it changes Daybreak's own labels without changing
/// the system language, the content market, or any Bing-provided text.
struct LanguageSettingsView: View {
    let selection: SettingsLanguage
    let isUpdating: Bool
    let onSelect: (SettingsLanguage) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                ForEach(SettingsLanguage.allCases) { language in
                    languageRow(language)
                }
            } header: {
                Text("界面语言")
            } footer: {
                Text("界面语言独立于内容地区；更改后 Daybreak 的界面文字立即使用所选语言。Bing 来源介绍不会被自动翻译。系统弹出的面板与部分系统控件仍跟随系统语言。")
            }
        }
        .navigationTitle("界面语言", locale: locale)
        .wideShellTabBarInset()
        .disabled(isUpdating)
        .overlay {
            if isUpdating {
                ProgressView("正在切换界面语言…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func languageRow(_ language: SettingsLanguage) -> some View {
        Button {
            guard language != selection else { return }
            onSelect(language)
        } label: {
            HStack(spacing: 12) {
                Text(language.title(in: locale))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if language == selection {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(language == selection ? .isSelected : [])
        .accessibilityHint(selectionHint(language))
    }

    private func selectionHint(_ language: SettingsLanguage) -> Text {
        language == selection ? Text("当前界面语言") : Text("选择此界面语言")
    }
}
