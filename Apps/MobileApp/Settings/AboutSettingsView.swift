import Foundation
import SwiftUI
import UIKit

/// About and license content for the mobile app.
///
/// Deliberately platform-honest: no Dock/login-item/notification controls, no
/// App Store claims, and no fabricated repository or shortcut links. The MIT
/// text is bundled as a string because the app must remain readable even when
/// the repository's `LICENSE` file is not copied into the target bundle.
struct AboutSettingsView: View {
    @Environment(\.locale) private var locale
    @State private var showsLicense = false

    /// Breathing room between the author card and the wide shell's floating
    /// tab bar. The shell's measured bar height alone ends the scroll content
    /// flush with the glass; compact windows ignore this gap because their
    /// system tab bar owns the bottom inset.
    private static let authorCardBottomGap: CGFloat = 12

    var body: some View {
        List {
            Section {
                appHeader
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section {
                Text("Daybreak 是一款 Bing 每日壁纸客户端：浏览每天的照片与来源介绍，在时光中按日期回看，在本机保存收藏与回顾。已缓存的内容可以离线查看。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    featureRow("photo.on.rectangle", "每日图片、标题与摄影版权")
                    featureRow("text.book.closed", "来源每日介绍与原文入口")
                    featureRow("calendar", "按地区与来源日期回看时光")
                    featureRow("square.and.arrow.up", "通过快捷指令把图片交给系统")
                    featureRow("wifi.slash", "离线优先，不依赖账号或后台")
                }
                .padding(.vertical, 2)
            } header: {
                Text("关于 Daybreak")
            }

            Section {
                Text("图片、缓存与介绍只保存在这台设备上。Daybreak 没有账号系统、遥测、广告或后端服务，也不会上传浏览记录。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("图片来源与每日介绍来自 Bing，版权归原权利人所有，不适用本应用的源代码许可。Daybreak 与 Microsoft / Bing 没有官方关联。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("数据与隐私")
            } footer: {
                Text("清除缓存只会删除本机图片文件；元数据、介绍与收藏由“缓存”页面分别管理。")
            }

            Section {
                Button {
                    showsLicense = true
                } label: {
                    LabeledContent {
                        Text("MIT")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("查看源代码许可证", systemImage: "doc.text")
                    }
                }

                Text("Daybreak 源代码以 MIT 许可发布；Bing 图片、摄影版权与每日介绍不包含在该许可内。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("开源许可")
            }

            Section {
                LabeledContent("版本", value: Self.versionText)
                LabeledContent("运行系统", value: Self.systemText)
                LabeledContent("应用标识") {
                    Text(Bundle.main.bundleIdentifier ?? "—")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("运行环境")
            } footer: {
                Text("Daybreak 不上架 App Store；iOS / iPadOS 版本由用户自行签名并安装。")
            }

            Section {
                HStack(alignment: .top, spacing: 14) {
                    authorAvatar

                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dylan Liu")
                                .font(.headline)
                            Text("Daybreak 作者")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Link(destination: Self.authorGitHubURL) {
                            Label("github.com/mentalfl0w", systemImage: "link")
                        }
                        .tint(.daybreakActionTint)
                        .font(.callout)

                        Link(destination: Self.authorEmailURL) {
                            Label("mentalflow@ourdocs.cn", systemImage: "envelope")
                        }
                        .tint(.daybreakActionTint)
                        .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            } header: {
                Text("作者")
            }
        }
        .listStyle(.insetGrouped)
        .wideShellTabBarInset(extraBottomGap: Self.authorCardBottomGap)
        .navigationTitle("关于", locale: locale)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showsLicense) {
            LicenseSheet()
        }
    }

    private var appHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("AboutAppIcon")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Daybreak")
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("每天一幅风景，每天一个故事")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("版本 \(Self.versionText)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }

    /// The profile avatar published at github.com/mentalfl0w (GitHub user
    /// 30333935), bundled so the author card renders without a network request.
    /// Initials remain a graceful fallback if the asset is ever unavailable.
    private var authorAvatar: some View {
        Group {
            if let image = UIImage(named: "AuthorAvatar") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.22),
                            Color.accentColor.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text("DL")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func featureRow(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    private static var systemText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS / iPadOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static let authorGitHubURL = URL(string: "https://github.com/mentalfl0w")!
    static let authorEmailURL = URL(string: "mailto:mentalflow@ourdocs.cn")!
}

/// Full MIT text. Kept verbatim in English; the surrounding UI explains it in
/// the selected interface language. This is the same license shipped in the
/// repository root.
private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Daybreak 源代码以 MIT 许可发布。以下为许可证原文；Bing 图片与每日介绍不在此许可范围内。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(Self.mitText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("MIT 许可证", locale: locale)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private static let mitText = """
    MIT License

    Copyright (c) 2026 Daybreak contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
