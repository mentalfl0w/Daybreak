# Logo 文件说明

> 当前 App 图标使用 `../Assets/macOS/AppIcon.appiconset`、`../Assets/iOS/Assets.xcassets/AppIcon.appiconset` 与 `IconComposerSources/` 中的日出 + 层叠山峦图形，不含日历页。本目录的 `Daybreak-Logo-*` 与 `Daybreak-Symbol.*` 是带日历的早期品牌概念稿，保留作设计探索记录，不是当前发行图标。

- `Daybreak-AppIcon-Rounded.png` — 当前 App 图标的圆角展示版本，仅用于 README 等展示；应用图标源文件仍使用 `../Assets/` 中的方形图。
- `Daybreak-Logo-1024.png` — AI 生成的早期 Daybreak 概念 Logo 主视觉，1024×1024，RGB，非透明；带圆角日历与暖色朝阳，不是当前 App Icon。
- `Daybreak-Logo-Transparent.png` — 将早期概念稿圆角视觉的外侧背景技术性裁剪为透明后形成的展示版，1024×1024，RGBA。
- `Daybreak-Symbol.svg` — 基于早期概念稿的原生 SVG **简化矢量变体**，方便编辑形状/渐变，不是主视觉 PNG 的精确矢量描摹。
- `Daybreak-Symbol-1024.png` — SVG 变体的 raster 导出。
- `Daybreak-MenuBar.svg` — macOS 菜单栏单色模板图形，64 viewBox。
- `Daybreak-MenuBar-128.png` — 菜单栏图形的预览/中间资源；真实 NSImage 要设置 `isTemplate=true` 并按 16/18/20/22 pt 视需求生成。
- `IconComposerSources/PNG` 与 `IconComposerSources/SVG` — 当前图标构成的可编辑源图层和合成 SVG。
- `../Assets/` — 当前 App 图标与 Asset Catalog 资源；导入前检查 Xcode 所需的新版 App Icon 格式。

## 设计方向

当前图标图形语言：旭日、前后山峦与地平线；主背景深海蓝/紫，暖色日光与橙粉渐变；保持视觉中心简洁，无日历页、字母和 Bing 商标。早期概念稿额外使用日历框，仅作历史参考。

注意：iOS 自动圆角会裁剪图标，当前包提供不透明方图。新版 iOS dark/tinted/icon composer 可后续根据品牌做官方三态，不要把同一个 PNG 简单反相充当完整暗色/染色专用图标。
