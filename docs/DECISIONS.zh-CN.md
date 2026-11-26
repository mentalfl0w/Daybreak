# Architecture decision log

## Accepted (2026-11-23)

- ADR-001: Swift 6 + SwiftUI; shared `DaybreakCore` Swift Package; Mac + Mobile targets. Rationale: native rendering and lightweight maintenance.
- ADR-002: Calendar + cached editorial story are P0, not widgets-only. Rationale: historical and offline value.
- ADR-003: Local-only recap from observed records, with explicit coverage. Rationale: offline/privacy and truthful history.
- ADR-004: GitHub open source, not App Store; iOS/iPadOS sideloaded with per-user signing. Rationale: release preference.
- ADR-005: No private APIs for Space/wallpaper. Event-driven convergence rather than atomic all-Space guarantee.
- ADR-006: Bing metadata + editorial story are distinct providers with provenance; no fabricated fallback.
- ADR-007: MIT is proposed for newly authored source code only; Bing content rights remain separate.
- ADR-008: Phase A conditionally accepted; remaining device and system integration checks were originally treated as mandatory in their respective later phases. ADR-012 now defers them; they stay Not tested and do not block Phase D. Multi-display and multi-Space are separate P0 features. Space convergence uses public events and accessible Spaces only; inactive Spaces are not guaranteed to update immediately.
- ADR-009: Do not download or install iOS simulator runtimes. Use installed SDKs for compile checks and authorized physical devices for behavioral acceptance.

## Pending / deferred verification

- ADR-PENDING-001: Reliability and schema of `/hp/api/model` across zh-CN, en-US, ja-JP; correct join key with `HPImageArchive`. Early probes took samples; long-term stability remains open.
- ADR-PENDING-002: Full end-to-end App Intent → Shortcut → set wallpaper on target iOS versions and Duo crop behavior. Deferred and remains untested.
- ADR-PENDING-003: Space switch event and desired wallpaper persistence under multi-display/mission-control. Partially observed; complete multi-display and multi-Space acceptance deferred.
- ADR-PENDING-004: Sideload-compatible signing entitlements and optional widget capabilities. Deferred.
- ADR-PENDING-005: Persistence implementation (SwiftData vs SQLite/file repository), including migration semantics. ADR-010 accepts the single-process actor repository; multi-process coordination remains open.

For a new ADR: add Date, Status, Decision, Alternatives, Evidence, Risks, Consequences, Tests.

## ADR-010 — Single-process file repository

- Date: 2026-11-23. Status: accepted for the current app, not a multi-process storage decision.
- Decision: versioned local index and separately stored image assets, serialized by a Swift actor; preserve and migrate the existing file-cache format.
- Alternatives: SwiftData or SQLite with files. They were not benchmarked or migration-tested; neither is rejected for future multi-process use.
- Evidence: repository migration, recovery, retention and offline tests.
- Risks: actor isolation does not coordinate separate processes; crash recovery and future schema migrations need further validation.
- Consequences: extensions or other processes must not concurrently write this repository without a new coordination/storage decision.
- Tests: `swift test --package-path Packages/DaybreakCore`.

## ADR-011 — No product wallpaper backup/restore; bounded applied-image protection

- Date: 2026-11-25; revised 2026-11-26 at the user's direction. Status: accepted.
- Decision: Daybreak does not provide product-level backup/restore or rollback of system wallpapers. Protect currently accessible desktop images and in-flight writes; historical images are not permanently protected solely because an inactive Space may reference them. Retain favorites and pinned images, and evict eligible originals according to the cache limit.
- Evidence: a single-display observation showed an image remained visible after moving its source and switching Spaces away and back. `MacPreflightDisplayObservation` is transient preflight state, not a user-visible backup.
- Risks: Apple does not publicly guarantee durable wallpaper cache retention after source deletion. Sleep, system restart, multiple displays, and other OS versions have not been validated; inactive Spaces may lose their displayed wallpaper.
- Consequences: no backup/restore UI; tests may write only after explicit authorization and must not claim recovery of every Space.
- Tests: protect current and in-flight images and favorites/pins while allowing historic originals to be evicted; test migration and concurrent cleanup.

## ADR-012 — Deferred real-device/system acceptance; no dedicated test facility

- Date: 2026-11-25. Status: accepted.
- Decision: Real-device and real-system checks (multi-display, multi-Space, notifications, login item, Shortcuts/Duo, signing) are deferred and remain untested. Do not require a dedicated test machine or permanent test facility. Use existing product flows and automated test targets.
- Alternatives: block implementation on full system acceptance. Rejected because these checks require authorized devices and system conditions.
- Evidence: prior platform probes and automated tests, with device gaps recorded in the changelog.
- Risks: deferred defects may surface later; status must stay explicit in release notes.
- Consequences: implementation can ship as unsigned artifacts while device evidence remains pending.
- Tests: none executed for deferred items.

## ADR-013 — Unreadable wallpaper is unknown, not a manual-set blocker

- Date: 2026-11-25. Status: accepted.
- Decision: An unreadable or dynamic original wallpaper does not block a user's explicit manual wallpaper set. Automatic overwrite of unknown wallpaper requires separate authorization and stays off by default. Two nil reads with identical options and no Space/display event do not prove the original wallpaper is unchanged.
- Alternatives: block manual setting whenever the original cannot be read, or treat repeated nil reads as proof of no change. Both overstate what public APIs can observe.
- Evidence: platform findings show that public APIs expose no atomic read/compare/write transaction.
- Risks: the app may not detect a user change between reads; unknown-wallpaper overwrite must remain explicitly authorized.
- Consequences: manual confirmation remains available; automatic mode stays conservative and observable.
- Tests: not executed for deferred system behavior.

## ADR-014 — Single adaptive iOS target with user-selected signing

- Date: 2026-11-25. Status: accepted.
- Decision: iPhone, iPhone Duo and iPad share one iOS App target `DaybreakMobile` (deployment target iOS 26.0, `TARGETED_DEVICE_FAMILY = 1,2`). The product name is `Daybreak` and the Swift module name is `DaybreakMobile`. The app icon lives in `Assets/iOS/Assets.xcassets`; `AppIntents.framework` is linked so Xcode runs its App Intents metadata build step. The project commits no `DEVELOPMENT_TEAM`, certificates, provisioning profiles or entitlements; each user selects a team locally.
- Alternatives: separate iPhone/iPad targets, or Mac Catalyst / Designed for iPad. Rejected: the UI is already adaptive, distribution is user-signed sideloading rather than the App Store, and extra platform targets would add signing and layout surfaces without a product requirement.
- Evidence: `Apps/MacApp/project.yml`, `Assets/iOS/Assets.xcassets`, and Apple's account/distribution documentation.
- Risks: free Personal Team profiles expire after 7 days; App Intents/Shortcuts behavior under different signing modes is unverified.
- Consequences: `Daybreak.xcodeproj` is regenerated from the XcodeGen spec and is not hand-edited. Real-device signing, Duo and iPad checks remain untested until executed.
- Tests: none executed for signing or device behavior; compile commands are documented for users to run.

## ADR-015 — Duo outer crop preset follows published display geometry

- Date: 2026-11-25. Status: accepted.
- Decision: The user-selected Duo outer composition preset uses Apple's published iPhone Duo outer-display resolution, 1398×2034 pixels (5.4-inch, 460 ppi), reduced to 233:339. The ratio is static preset metadata; it is not device, fold-state or orientation detection. The Duo inner portrait/wide presets remain their existing 3:4 and 4:3 composition approximations until a separate change is requested and verified. Preview provenance shows the market's region/language name in the app's interface language instead of printing the raw Bing tag (`zh-CN`).
- Alternatives: a generic foldable-cover ratio such as 9:21, or selecting a preset from runtime display state. Rejected: 9:21 does not match Apple's published outer display, and public APIs do not reliably expose fold state, especially to background intents; the user must choose the target.
- Evidence: <https://www.apple.com/iphone-duo/specs/> (outer display: 5.4-inch, 1398-by-2034-pixel resolution at 460 ppi); <https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo> (the outer display is wider and shorter than other iPhone displays; avoid fixed display assumptions).
- Risks: the exported composition remains a reference; iOS may crop again when the user sets wallpaper. Duo system behavior and the preview at its actual size remain unverified on a real device.
- Consequences: `WallpaperCropPreset.duoOuter.aspectRatio` is 233:339 and its label reads `233:339`; Shortcuts dialog text uses the same label. Preview subtitles no longer show `zh-CN`; Bing story and title text are never translated.
- Tests: `WallpaperCropGeometryTests.duoOuterPublishedRatio` and `WallpaperPreviewMetadataTests.subtitleLocalizesMarket`; not executed in this change.

## ADR-016 — Cross-device sync uses a user-authorized folder, not CloudKit

- Date: 2026-11-26. Status: accepted.
- Decision: Optional sync exchanges immutable, versioned operation files plus content-addressed image blobs inside a folder the user selects (for example an iCloud Drive folder). Each device keeps its own local `WallpaperRepository`; the shared folder never hosts the live index. One security-scoped bookmark per device lives only under local Application Support and is never synced. No CloudKit, CloudKit container, iCloud Key-Value Store, App Group, push or paid entitlement is used, so the default free-sideload build keeps working without capability changes.
- Alternatives: CloudKit private database, a dedicated iCloud container, or sharing the repository index directly. Rejected: container/entitlement requirements conflict with free Personal Team signing, and sharing a mutable index makes concurrent writes and iCloud conflict copies unsafe.
- Convergence: causal version vectors per device sequence, register union with anti-chain pruning, remove-wins on concurrent favorite/pin conflicts, tombstones retained until dominated. A local favorite or pin is only removed when the archive actually holds a record for that key that is tombstoned; mere absence (empty folder, not-yet-downloaded file, unreadable directory) never deletes local data. A pin names a date and is rebound to the date's current local image rather than rejected. Bootstrap of pre-journal local state carries only the local device's sequence context, so an old local favorite cannot resurrect a peer's removal; only later user actions with the observed frontier can.
- Scope: favorites, pinned dates, occurrences, metadata, stories and thumbnails sync by default; originals and market preferences are opt-in; interface language, cache limits, wallpaper targets, permissions and bookmarks stay local. Turning sync off or replacing the folder deletes no local data and no previously shared files.
- Evidence: `Packages/DaybreakCore/Sources/DaybreakSyncController.swift` and related sync tests. Limits: `.completed` means this device finished a local pass, never that peers have received it.
- Risks: a writable shared folder lets another process inject well-formed operations; the engine validates structure, size, digest and decodability but cannot authenticate an author. Real iCloud propagation and bookmark persistence after free-team re-signing remain unverified.
- Consequences: device sync behavior remains untested until executed on authorized devices.

## ADR-017 — Explicit interface language requires `LocalizedStringResource`

- Date: 2026-11-26. Status: accepted.
- Decision: Every macOS string-catalog lookup that must follow the in-app interface language goes through `MacLocalizedString.resolve`, which builds a `LocalizedStringResource` carrying the locale and only falls back to the bundle language for `.current`/`.autoupdatingCurrent`. The mobile app already resolves through `MobileLocalizedString` the same way.
- Context: `String(localized:locale:)` formats interpolated values with the locale but does not change the lookup language. On the installed macOS 27 SDK a probe inside the built app bundle returned the source-language text for `en`, `ja` and `zh-Hans`, so model copy ignored the interface-language setting even though SwiftUI text followed `.environment(\.locale)`.
- Alternatives: keep `String(localized:locale:)` and relax the guard test. Rejected: it hides a user-visible defect; the guard exists precisely to catch a silent fallback.
- Evidence: `Apps/MacApp/Core/MacLocalizedString.swift`; `DaybreakTests/CoreInterfaceLocaleRegressionTests` failed before the change and passes after it (`/tmp/test-locale.log`).
- Risks: a new call site that uses `String(localized:locale:)` directly reintroduces the fallback; code review should reject it.
- Consequences: string keys remain compile-time literals for catalog extraction; only the lookup locale is decided at runtime.

## ADR-018 — 组合式应用编排与基础设施边界

- 日期：2026-11-26。状态：已接受。
- 决策：使用值类型表达领域身份和快照，使用协议表达平台与外部服务边界，使用 actor 保护共享可变状态，使用组合拆分应用编排和基础设施职责。保留 `AppModel`、`WallpaperRepository` 和 `BingProvider` 作为稳定入口，但将显示器保护、仓库文件存储与校验、Bing 请求执行和图像验证移入聚焦的协作者。
- 替代方案：增加继承层级或把每个小操作都抽成协议。拒绝，因为 SwiftUI 和 Swift 并发代码更适合组合、值语义和显式 actor 边界；过度抽象会扩大调用面。
- 证据：`WallpaperDisplayCoordinator.swift`、`WallpaperRepositoryStorage.swift`、`WallpaperRepositoryValidation.swift`、`WallpaperRepositoryProtection.swift`、`BingRequestExecutor.swift`、`BingHTTPTransport.swift` 和 `BingImageValidator.swift`。边界检查脚本为 `scripts/check-import-boundaries.sh`。
- 后果：应用入口保持稳定，内部职责更容易单独测试和演进。新增功能应优先加入现有协作者或新的聚焦协作者，不应继续扩大入口对象。
- 测试：`swift test --package-path Packages/DaybreakCore`、`swift test --package-path Platform/MacIntegration`、macOS 与 iOS 未签名 Release 构建，以及模块边界检查均已执行。

