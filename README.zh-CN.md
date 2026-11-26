# Daybreak

一款面向 macOS、iPhone 和 iPad 的原生、本地优先 Bing 每日壁纸应用。Daybreak 将图片与来源提供的介绍信息配对，并把浏览记录、日历、收藏和回顾保存在本机。

[English](README.md) · [文档索引](docs/README.zh-CN.md) · [参与贡献](CONTRIBUTING.zh-CN.md) · [更新记录](docs/CHANGELOG.zh-CN.md)

## 功能

- **macOS：** 浏览今日图片和来源信息，查看日历与图库，管理收藏，并手动设置壁纸或主动启用自动管理。
- **iPhone 和 iPad：** 浏览今日图片和本机归档，预览裁切效果，管理收藏，并将图片交给快捷指令。由快捷指令调用 Apple 系统操作设置壁纸；应用本身不会直接设置系统壁纸。
- **可选文件夹同步：** 每台设备保留独立的本地仓库。启用后，用户选择的文件夹在设备间传递版本化记录和内容寻址资源。

## 数据与隐私

Daybreak 使用的 Bing 服务并非稳定的公开数据合同。图片和介绍可能缺失、不完整或被来源修改。应用不得编造缺失的故事、日期或版权信息。

应用以本地使用为主，不要求账号或 Daybreak 后端，也不捆绑 Bing 图片或故事档案。Bing 图片和文字仍归各自权利人所有；MIT 许可适用于项目代码，不适用于 Bing 内容。

回顾只说明本机实际观察到的记录。未观察到某日期并不能证明 Bing 当天没有发布内容，回顾也不一定代表完整历史。

## 平台限制

- iOS 和 iPadOS 通过快捷指令及 Apple 系统操作设置壁纸；Daybreak 不会直接更改系统壁纸。
- macOS 使用 Apple 公开 API，并响应可访问的显示器与 Space 事件。多显示器分配和 Space 协调是两项不同能力；不能保证未激活的 Space 立即更新。
- 原壁纸不可读取或为动态壁纸，不会阻止用户明确手动设置新壁纸。自动覆盖未知壁纸需要单独授权。
- 文件夹同步是可选功能；只有用户选择文件夹并启用后才运行。跨设备传播和免费账号重签后的授权持久性尚未在真机验证。

## 界面截图

macOS 产品页截图只保留应用窗口范围，便于核对真实界面：

- [今日](docs/screenshots/daybreak-mac-today.png)
- [时光](docs/screenshots/daybreak-mac-timeline.png)

![Daybreak macOS 今日页](docs/screenshots/daybreak-mac-today.png)

![Daybreak macOS 时光页](docs/screenshots/daybreak-mac-timeline.png)

## 从源码构建

Xcode 工程由 XcodeGen 根据 `Apps/MacApp/project.yml` 生成。如本机尚未安装 XcodeGen，请安装 2.40 或更高版本，然后执行：

```sh
xcodegen generate -s Apps/MacApp/project.yml -r . -p .
open Daybreak.xcodeproj
```

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

未签名的 iOS 构建无法安装。测试命令见[贡献指南](CONTRIBUTING.zh-CN.md)；产品与发布文档见[文档索引](docs/README.zh-CN.md)。

## 构建产物与发布

GitHub Actions 会为每次推送和拉取请求上传构建产物。版本标签或手动触发的发布流程会生成 macOS DMG 和未签名 iOS IPA。IPA 仅供用户自行签名，不是可直接安装的应用；安装需要有效签名和描述文件。

项目不计划上架 App Store。macOS 磁盘映像可能未经签名；打开前请查看发布说明中的签名与 Gatekeeper 提示。

## 许可与关联

项目代码采用 MIT 许可证，详见 [`LICENSE`](LICENSE)。Daybreak 是独立项目，与 Microsoft 或 Bing 没有官方关联。
