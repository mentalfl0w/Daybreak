import DaybreakCore
import Foundation
import SwiftUI

/// Image-quality preference.
///
/// This is a download preference, not a claim about the current image's exact
/// resolution: Bing chooses the candidate list, and Daybreak falls back to an
/// available candidate instead of stretching or inventing pixels.
struct ImageQualitySettingsView: View {
    let selection: BingImagePreference
    let isUpdating: Bool
    let onSelect: (BingImagePreference) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                ForEach(BingImagePreference.allCases, id: \.self) { preference in
                    qualityRow(preference)
                }
            } header: {
                Text(MobileLocalizedString.resolve("下载画质", locale: locale))
            } footer: {
                Text(MobileLocalizedString.resolve(BingImagePreference.settingsFooterKey, locale: locale))
            }

            Section {
                LabeledContent(MobileLocalizedString.resolve("当前选择", locale: locale)) {
                    Text(qualityTitle(selection))
                        .foregroundStyle(.secondary)
                }
                if isUpdating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(MobileLocalizedString.resolve("正在保存画质偏好…", locale: locale))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(MobileLocalizedString.resolve("快捷指令导出的是本机已缓存或可验证的原图文件；系统“设置壁纸照片”动作还可能再次裁切。画质偏好不好保证最终屏幕上的像素尺寸。", locale: locale))
            }
        }
        .navigationTitle(MobileLocalizedString.resolve("图片质量", locale: locale))
        .wideShellTabBarInset()
        .disabled(isUpdating)
    }

    private func qualityRow(_ preference: BingImagePreference) -> some View {
        let selected = preference == selection
        return Button {
            guard !selected else { return }
            onSelect(preference)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preference.settingsSymbol)
                    .font(.body)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(preference.settingsTitle(locale: locale))
                        .foregroundStyle(.primary)
                    Text(preference.settingsDetail(locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func qualityTitle(_ preference: BingImagePreference) -> String {
        MobileLocalizedString.resolve(preference.settingsTitleKey, locale: locale)
    }
}

