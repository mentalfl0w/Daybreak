# Daybreak 数据合同：每日壁纸、介绍、时光日历和回顾

**目的**：保证介绍真实、日期准确、离线可用、统计可解释。这份文档比任何单个接口字段更稳定，接口实现必须遵守它。

## 1. 来源与 Provider 组合

- `BingImageArchiveProvider`：`https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=zh-CN`；负责近期图片日期、身份、版权与 URL。非正式受保障 SDK，需容错。
- `BingHomepageStoryProvider`：探索 Bing 首页模型，如 `https://www.bing.com/hp/api/model`、相应地区域名；尝试取得 `ImageContent` 的 `Title`、`Headline`、`Description`、`QuickFact.MainText`、`Copyright`、`BackstageUrl`。不得假定历史完整、所有市场有效或响应稳定。
- 不默认通过爬取搜索结果 HTML 补全全文；如需未来启用，单独做合规与鲁棒性评审。
- 设置中的市场目录参考 Microsoft Bing Image Search 公开市场码，不等同于每日壁纸接口的支持清单；服务可能回退到其他市场，缺少市场标记时无法确认是否回退。新增市场的代表性 IANA 时区是应用侧日期换算约定，并非 Bing 已确认的市场时区；跨时区市场及未实测地区的日期须独立验证。系统语言和地区无法对应目录时界面须显示实际使用的回退市场，不得冒充所请求地区。
- 不使用第三方全量历史存档作为首版依赖或发布素材包。

### 介绍数据层级

1. **短标题**：Bing 图片元数据 `title` 或首页模型的 `Title`。
2. **版权/摄影说明**：`copyright`/`Copyright`，独立显示且原文保存。
3. **介绍**：`Headline` + `Description`，如可用则加 `QuickFact.MainText`。QuickFact 是速览内容，不应伪装为原创完整文章。
4. **原文链接**：仅可信 `BackstageUrl`/`copyrightlink` 等允许的来源地址。
5. **缺失**：返回 `storyUnavailable(reason)`，UI 显示「暂无可获取的每日介绍」；可以只展示标题/版权，不能编一段故事。

缓存完整字段时保留 `sourceField`、`sourceURL`、`sourceLocale`、`fetchedAt`、`contentHash`、`availability`；原文和 UI 摘要可分开。若以后提供翻译，必须显式展示“翻译文本”和原始语言，不能无标签覆盖原文。

## 2. 建议的规范化模型（概念，不是当前代码）

| 模型 | 主键 / 字段示例 | 解释 |
|---|---|---|
| `WallpaperRecord` | `id`, `source`, `sourceImageID`, `canonicalTitle`, `copyright`, `sourceURL` | 图片内容实体，不含单个日期身份 |
| `WallpaperOccurrence` | `source`, `market`, `localDate`, `wallpaperID`, `publisherTime` | 记录某地区某日期出现了哪张图；允许同图多出现 |
| `DailyStoryRecord` | `id`, `source`, `market`, `date`, `associatedWallpaperID?`, `headline?`, `body?`, `quickFact?`, `originalLocale`, `sourceURL?`, `fetchedAt`, `status` | 日期/市场的介绍独立实体，关联图片非强制 |
| `ImageVariant` | `wallpaperID`, `resolution`, `kind`, `remoteURL`, `mime`, `checksum?` | 缩略图、横向原图、可用纵向图分开管理 |
| `CachedAsset` | `assetID`, `path`, `bytes`, `lastAccessedAt`, `pinReason[]` | 索引与本地文件必须可相互校验 |
| `UserInteraction` | `date`, `wallpaperID`, `action`, `market` | **仅本地**收藏、手动应用、浏览等用于明确回顾行为；不上传 |
| `InstallationHistory` | `firstObservedAt`, `enabledMarkets[]`, `lastSyncByMarket` | 回顾分母与本机观测起点；更换设备/重装后不能假设以前历史完整 |

主键建议：`sourceID:market:YYYY-MM-DD` 是 **Occurrence** 级主键，不是图片级主键；同地区同日若来源修订应保留 revision/历史，不能覆盖用户收藏所依赖的文件。`DailyStoryRecord` 也需记录 schema/source revision。

### 关联时的严格匹配顺序

1. 优先 source 共同的图像 ID + 市场 + 来源日期。
2. 无法提供同一图像 ID 时，根据可信首页模型的日期/market/内容 URL 匹配。
3. 不能充分确定时将故事保持为「当日介绍未匹配」，不得把相邻日期或其它市场内容强行归并。
4. 记下关联依据、置信度以及用户可见的来源；不可依赖 `Date()` 或数组位置来做关联。
5. 覆盖跨年 12/31→01/01、夏令时/UTC 日界线和市场日期延迟的测试。

## 3. 每日更新工作流

```text
触发器（前台 / Mac 生命周期 / Shortcut / 手动刷新）
  → 按 market 限频且合并并发请求
  → 图片元数据 Provider（先写来源日期和身份）
  → Story Provider（独立状态、允许失败）
  → 严格关联 / 单独保存无法关联的介绍
  → 缩略图按需缓存，原图仅应用/收藏/用户请求时抓取
  → 原子更新索引，发出状态变化
  → 日历与回顾从本地 Repository 重建视图
```

图片可用而故事暂不可用：整个任务视为 `partialSuccess` 而非失败；故事可稍后补充。故事成功而图片原图失败：仍可离线显示文字和缓存缩略图。

## 4. 日历状态与 UI

- CalendarCell 以 `market + localDate` 查询，并展示照片/故事/收藏/固定状态组合。
- 月份快速翻页不应下载整月 UHD；最多批量预加载可见缩略图及故事 metadata。
- 每次成功的今日刷新只为本次返回的有限归档（最多 8 天）补齐缺失的缩略图（优先 fullHD，失败时按候选回退），已有可读缩略图不重复下载；翻月或打开图库本身不触发图片下载。
- 日期缺失可能是用户未运行过应用、地区未启用、接口不可取或真实无图；这些应有不同状态。
- 历史日期不可取时，不向用户保证「重新获取即可」，应展示已缓存和来源可用性。
- 从日历打开详情：图片、地点/标题、原始版权、介绍正文、速览、来源链接、地区日期；文章滚动不会干扰图库横扫切换。

## 5. 缓存策略及迁移

- `MetadataCache` 与 `StoryCache`：长期本地保存，清理需用户明确动作；允许仅清空故事缓存（UI 清楚显示后果）。
- `ThumbnailCache`：上限 + LRU；`OriginalCache`：上限 + LRU + pins。收藏、固定、当前可访问桌面使用的原图以及正在写入的壁纸不被自动清理；历史图片不再仅因曾应用到其他 Space 而永久保护，允许按缓存上限自动淘汰。单屏实测移走源文件后，切换 Space 再返回仍显示壁纸；睡眠、重启、多显示器及其他系统版本尚未验证，系统缓存并无公开持久保证。
- 安装后首次启动不迁移或复制第三方壁纸库；未来导入需用户显式授权。
- 图片写入：临时文件 → 内容类型/尺寸校验 → 原子改名 → 本地索引提交；如果数据库写入失败，必须可清理孤儿文件。
- 定期索引修复仅处理本 app 沙盒范围，不扫描不属于自己的用户文件。
- 本节的缓存/索引修复与迁移仅指应用自身数据，不是系统壁纸备份或恢复功能；Daybreak 不提供系统壁纸备份/恢复，也不把它作为使用或测试前提。
- 若跨设备 iCloud 以后启用，默认仅同步收藏 ID 与偏好；未同步大图时 UI 不显示为可离线下载。

## 6. 回顾规则与可解释性

**统计与可视化全部离线计算，绝不将缺失数据补齐为零值或编造壁纸故事。**

- 以实际成功归档的发生记录为单日基准；计数时按日期去重。
- 例如：2026-11-23 首次安装，年度回顾只显示从 11/23 到当前已记录的天数，不声称 1/1~11/22 一共“缺失 326 天”。
- 观察期里断网、禁用自动更新、市场未启用的日期可标为「未记录」而非 Bing 未发布。
- 跨市场：`daysWithAnyObservation` 和 `totalOccurrences` 单独显示，不混用；最常用地区的计数对市场分组。
- 收藏图片数按 WallpaperRecord 去重；收藏次数不作为壁纸数。
- 介绍阅读量只在确实记有用户查看事件时计；如果不想维护操作日志，首版改为「已缓存介绍数」，不要把两者混淆。
- 回顾卡说明数据范围和生成日期；可选择隐藏隐私性使用统计。
- 分享时内容在设备上生成，用户确认后调用系统 Share Sheet；不提供后台上传。

## 7. 必需测试夹具（全部人工合成）

- 2026-11-23 zh-CN 有图片+短标题+版权+完整介绍；en-US 同日不同图；ja-JP 同日无故事。
- 同一图片跨两个市场、同一个市场跨两日期出现。
- 图片与故事日期边界错位 1 天；关联失败应标为待匹配而不是强行贴入。
- 首页模型 `Description` 缺失/空、HTML 破损、错误页 200、302 到非允许主机、invalid UTF-8、429 限流。
- 下载成功而介绍失败；介绍成功而图片原图失败；一并离线启动。
- 用户收藏 1 张图片同时出现在 3 个发生记录；年度显示收藏图片 1 而非 3。
- 首次安装 11 月、观察 8 天，只归档 5 天；统计说明正确，不能整年假零。

## 8. 合规备注

Bing 图片和文字版权仍归各权利人所有。归档行为仅用于最终用户在本机按需浏览，**不代表用户获得再分发/商业使用授权**。开源代码测试和 CI 必须使用合成/授权数据，不放任何真实 Bing 故事正文作为 fixture。网络/HTML 非公开接口如需抓取，先做服务条款审查与更新频率限制。

研究资料：
- https://github.com/wefashe/bing-image
- https://github.com/DIYgod/RSSHub/blob/master/lib/routes/bing/daily-wallpaper.ts
- https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US
