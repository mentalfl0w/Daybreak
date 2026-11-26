import DaybreakCore
import Foundation
import SwiftUI

/// User-facing content-market preference. Mirrors the store's persisted
/// preference without owning persistence.
enum SettingsMarketChoice: Hashable, Sendable {
    case followSystem
    case market(Market)
}

/// Content-market picker.
///
/// The market controls which Bing edition's image, source date and original
/// story are requested. It is independent of the interface language, and story
/// text is never substituted across markets.
struct MarketSettingsView: View {
    let profiles: [BingMarketProfile]
    let systemMarket: Market
    let effectiveMarket: Market
    let followsSystem: Bool
    let isUpdating: Bool
    let notice: String?
    let onSelect: (SettingsMarketChoice) -> Void

    @Environment(\.locale) private var locale
    @State private var searchText = ""

    var body: some View {
        Form {
            Section {
                followSystemRow
            } footer: {
                Text("默认跟随系统地区与首选语言。只有手动选择地区后才会保存该选择；系统设置改变后，重新打开 Daybreak 即可重新解析。")
            }

            if let notice, !notice.isEmpty {
                Section {
                    Label {
                        Text(verbatim: notice)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Section {
                ForEach(filteredProfiles, id: \.market) { profile in
                    marketRow(profile)
                }
            } header: {
                Text("全部地区")
            } footer: {
                marketFooter
            }
        }
        .navigationTitle("内容地区", locale: locale)
        .wideShellTabBarInset()
        .searchable(text: $searchText, prompt: Text("搜索地区或代码"))
        .disabled(isUpdating)
        .overlay {
            if isUpdating {
                ProgressView("正在切换内容地区…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var followSystemRow: some View {
        Button {
            guard !followsSystem else { return }
            onSelect(.followSystem)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("跟随系统")
                        .foregroundStyle(.primary)
                    Text("当前解析为 \(TodayFormatting.marketName(systemMarket, locale: locale))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if followsSystem {
                    checkmark
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(followsSystem ? .isSelected : [])
    }

    private func marketRow(_ profile: BingMarketProfile) -> some View {
        let selected = !followsSystem && profile.market == effectiveMarket
        return Button {
            guard !selected else { return }
            onSelect(.market(profile.market))
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: TodayFormatting.marketName(profile.market, locale: locale))
                        .foregroundStyle(.primary)
                    Text(verbatim: profile.market.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if selected {
                    checkmark
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? Text("当前内容地区") : Text("选择此内容地区"))
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }

    private var filteredProfiles: [BingMarketProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { profile in
            let name = TodayFormatting.marketName(profile.market, locale: locale)
            return name.localizedCaseInsensitiveContains(query)
                || profile.market.rawValue.localizedCaseInsensitiveContains(query)
                || profile.regionCode.localizedCaseInsensitiveContains(query)
                || profile.languageCode.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var marketFooter: some View {
        Text("地区决定请求的图片、来源日期与介绍原文。切换后会先显示该地区已经缓存的内容，再尝试联网更新；不会用其他地区的文字填补缺失介绍。")
        Text("来源日期按所选地区在目录中约定的时区计算，可能与 Bing 网页显示的日期略有差异。不同地区可能返回同一张图片，Daybreak 无法总是确认实际返回的地区。")
    }
}
