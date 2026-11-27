# 参与 Daybreak 开发

感谢你帮助改进 Daybreak。请控制改动范围，遵守本地优先的产品边界，并如实说明实际验证过的内容。

[English](CONTRIBUTING.md) · [项目概览](README.zh-CN.md) · [文档索引](docs/README.zh-CN.md)

## 开发环境

使用安装了项目所需 Xcode 和 Swift 工具链的 macOS 环境。如本机尚未安装 XcodeGen，请安装 2.40 或更高版本，然后在仓库根目录生成工程：

```sh
xcodegen generate -s Apps/MacApp/project.yml -r . -p .
```

在 Xcode 中打开 `Daybreak.xcodeproj`。macOS 应用使用 `Daybreak` scheme；iOS/iPadOS 应用使用 `DaybreakMobile` scheme。

## 构建与测试

不签名构建 macOS 应用：

```sh
xcodebuild -project Daybreak.xcodeproj -scheme Daybreak \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

使用已安装的 iOS 设备 SDK 编译应用（不签名）：

```sh
xcodebuild -project Daybreak.xcodeproj -scheme DaybreakMobile \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

测试 macOS 通知时，未签名构建不能等同于已安装的应用。在一次实际测试中，
签名标识为 `dev.daybreak.mac` 的 ad-hoc 构建显示通知已授权。此前失败的原因
和通知是否实际送达仍未确认。如果选择对一次性测试副本签名，请明确使用 bundle identifier
并检查结果；不要重新签名已有的签名应用：

```sh
ditto /path/to/unsigned/Daybreak.app /path/to/test/Daybreak.app
codesign --force --deep --sign - --identifier dev.daybreak.mac /path/to/test/Daybreak.app
codesign --verify --deep --strict /path/to/test/Daybreak.app
codesign -dv /path/to/test/Daybreak.app 2>&1
```

将测试副本安装在固定位置并从该位置启动。Ad-hoc 签名不是 Developer ID 签名；
分发和系统通知行为仍需单独验证。

修改影响共享核心或 macOS 集成时，运行相应自动化测试：

```sh
swift test --package-path Packages/DaybreakCore
swift test --package-path Platform/MacIntegration
xcodebuild -project Daybreak.xcodeproj -scheme Daybreak \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

如需只编译移动端测试 target 而不运行：

```sh
xcodebuild -project Daybreak.xcodeproj -scheme DaybreakMobile \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```

编译成功不能证明设备行为正常。不要为本项目安装 iOS 模拟器 runtime。若某项检查需要当前不可用的设备、系统配置或第二台显示器，应如实记录为 **Not tested**；不能用编译或合成测试替代实测结果。

## 项目结构

- `Apps/MacApp` 和 `Apps/MobileApp` 包含原生应用 target 和 XcodeGen 工程规格。
- `Packages/DaybreakCore` 包含共享数据、Provider、仓库、日历、回顾和同步逻辑。
- `Platform/MacIntegration` 包含 macOS 壁纸与显示器集成。
- `Assets` 和 `branding` 包含应用资源与设计素材。
- `docs/DATA_AND_STORY.md` 和 `docs/DATA_AND_STORY.zh-CN.md` 说明数据来源与回顾规则；`docs/DECISIONS.md` 和 `docs/CHANGELOG.md` 说明架构决策与已观察历史。
- `.github/workflows/ci.yml` 会在提交和 PR 上构建未签名 DMG 与 IPA，并在 tag 或手动运行时发布 Release。

## 实现边界

- 只能使用 Apple 公开 API。不得读取或修改系统私有壁纸数据库，也不得承诺未激活的 Space 会立即更新。
- 多显示器分配与 Space 协调是两种不同的行为。系统行为应由事件触发，并如实说明限制。
- 原壁纸不可读取或为动态壁纸，不得阻止用户明确手动设置新壁纸。自动覆盖未知壁纸需要单独授权。
- iOS 和 iPadOS 通过 App Intents 与快捷指令设置壁纸；应用不得声称能直接设置系统壁纸。
- 同步必须保持可选和本地优先。每台设备保留自己的仓库与授权书签；用户选择的文件夹可承载版本化记录和资源。不得要求后端、CloudKit、应用专属 iCloud 容器或付费能力。
- 不得为系统壁纸新增产品级备份或恢复，也不得把它作为使用或测试的前提。Daybreak 自身缓存/索引的修复和迁移仍属于产品职责。
- 使用合成数据或已获许可的夹具。不得提交真实 Bing 图片、故事正文、凭据、签名身份、描述文件或用户数据。不得编造缺失的来源内容或回顾统计。

## 本地化

界面字符串应放在现有 String Catalog 中；行为变化时同步更新 zh-Hans、en 和 ja 翻译。保留复数规则，并按所选语言格式化日期和数字。应用内显式语言选择应使用现有本地化辅助代码。

Bing 标题、介绍和版权信息属于来源内容，不是界面文案。保留原始语言和来源记录；未来如提供翻译，必须标记为译文，不得覆盖原文。

## Pull request

每个改动应聚焦，并说明用户可见的行为变化或维护需求。列出相关测试或构建命令及其实际结果；适用时说明 SDK 和设备，并明确哪些检查仍未验证。

界面变更可附上真实应用截图，但不得包含用户隐私。不能仅凭构建、测试替身或其他版本的截图声称系统或设备场景已经通过。

CI 会为推送和拉取请求上传构建产物。发布由版本标签或手动流程触发；发布的 macOS DMG 和未签名 iOS IPA 都不是预签名的安装包。不得提交签名凭据，也不得为了方便而更改签名设置。

仓库级实现限制见 [AGENTS.md](AGENTS.md)；维护中的参考文档见[文档索引](docs/README.zh-CN.md)。
