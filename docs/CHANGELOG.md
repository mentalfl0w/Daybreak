# Changelog

[简体中文](CHANGELOG.zh-CN.md) · [Project overview](../README.md)

This changelog consolidates development records. Test and build entries reflect evidence recorded on the dates shown; they do not establish that later edits or every device scenario were verified.

## Current status — 2026-11-26

- Refactored the application and infrastructure boundaries without changing product entry points. macOS display protection now lives in `WallpaperDisplayCoordinator`; repository storage, validation and protection calculations have focused files; Bing transport execution and image validation are separated from the public provider façade.
- Added `scripts/check-import-boundaries.sh` and CI enforcement for Core, platform, mobile, SwiftPM and XcodeGen dependency direction.
- Added timeline market menus across iOS/iPadOS and macOS, limited to supported markets with a locally available thumbnail or original image. Market changes preserve existing navigation state while the selected date remains valid.
- The refactor verification passed 253 DaybreakCore tests, 79 MacIntegration tests, the import-boundary check, an unsigned macOS Release build, and an unsigned iOS Release build.
- Real-device folder synchronization, cross-device propagation, authorization-bookmark persistence after free-account re-signing, complete multi-display and multi-Space acceptance, and full mobile device behavior remain **Not tested**.

## 2026-11-28

- Reduced unused horizontal space on the macOS Today page by centering a wider story column while keeping long body text at a readable measure.
- Split cached originals and thumbnails into separate storage tabs. Each tab uses stable per-kind ordering and independent six-item pagination; protection, deletion and page clamping remain unchanged.
- Verified the macOS refinement build without warnings and ran seven isolated storage pagination tests in a temporary HOME. The refined Today surface was launched once and captured; real storage-tab interaction remains **Not tested**.

## 2026-11-27

- Refined Today, calendar, gallery and recap presentation without changing wallpaper automation or recap counting. Daily source links now use an in-app WebKit or system Safari view; mobile Safari Services cannot enforce or report every subsequent navigation.
- Added macOS Sparkle update integration with an opt-in check/install policy, signed-feed and pre-extraction verification configuration, and a manual DMG fallback. Maintainer public/private key provisioning is required before a stable update feed can be published.
- In a disposable ad-hoc Sparkle test, a signed update changed a scratch app from build 1 to 2 and relaunched it through Launch Services using the documented immediate-install callback. The test used localhost HTTP and an unquarantined app; production HTTPS, Gatekeeper, permissions and data preservation were not verified.
- On the current user's running 1.2.1 application, the gallery showed 11 November records while the yearly recap showed four observed days. Their scopes differ; whether the local observation start explains this particular difference was not determined.
- With Xcode 27.2 and the installed macOS/iPhoneOS SDKs, both unsigned app test targets compiled; DaybreakCore passed 254 tests and MacIntegration passed 79 tests. These results do not establish actual UI, source-page, updater or device behavior.
- Launched the unsigned macOS build once with a temporary HOME and captured the Today surface; the photo, simplified metadata/actions and story remain visible. A sandbox extension message was emitted by direct executable launch; no wallpaper action was triggered. The running user's installed app and settings were not used for this check.

- A macOS ad-hoc build using the bundle identifier as its code-signing identifier showed notification permission as authorized in the user's installed app. The cause of the earlier failure and actual notification delivery remain unverified. The macOS build number was incremented to 5 for the rebuilt 1.2.1.
- CI now ad-hoc signs the macOS app in the release DMG using its `CFBundleIdentifier` as the code-signing identifier, then verifies the signature and identifier. This is not a Developer ID signature; the iOS IPA remains unsigned.
- Refined mobile settings, sync and Shortcuts copy to foreground user-visible outcomes while keeping local folder writes distinct from cross-device propagation and treating the final system wallpaper state as unknown to Daybreak.
- Added the cross-platform product design and copy reference. Mobile and macOS UI changes compile with the unsigned builds recorded below; physical-device and full visual checks remain **Not tested**.

## 2026-11-26

- Added bounded automatic download requests for iCloud-backed sync files that are present but not yet materialized. The sync pass reports pending work and retries after the file provider has had time to finish downloading.
- Added synchronization diagnostics that users can export on request. Reports use a field allowlist and do not automatically upload or include folder paths, bookmarks, device names, or user content.
- File coordination and path-validation changes received synthetic regression coverage. A device report showed repeated `pendingDownloads` before a later pass completed, so the UI and engine treat this as asynchronous file-provider materialization rather than a terminal read error.
- The latest DaybreakCore run passed 254 tests. The iOS Release app compiled without signing against the installed iPhoneOS 27.2 SDK.

## 2026-11-25

- Refined responsive iPhone, iPad, and Duo layouts, image-crop previews, navigation, and app-selected language lookup. These changes do not make the app detect Duo fold state or control the system’s final crop.
- Earlier notes flagged missing English plural forms and the need for native review of translations and safety text; a completed localization audit is not recorded here.
- User feedback reported general mobile use as successful and confirmed Shortcut and automation composition. Device, operating-system, and step-by-step records were not supplied for every scenario, so this is not full device-coverage evidence.
- macOS continues to use public display and Space events. Multi-display behavior and Space reconciliation are separate; full system acceptance, inactive-Space timing, sleep, and restart behavior remain unverified.

## 2026-11-23 onward

- Built the shared Swift 6 data layer for independent image metadata and editorial-story providers, a local repository, bounded caches, calendar history, and recaps based on records actually observed.
- Added native macOS and iOS/iPadOS experiences for browsing, saved history, favorites, and wallpaper workflows. Mobile wallpaper handoff uses App Intents and Shortcuts; it does not directly set the system wallpaper.
- Added local-first protections: missing stories and dates are not fabricated, Bing media is not bundled, and system-wallpaper backup or restore is not part of the product.

## Verification boundaries

Synthetic tests and compilation cover code paths, not system behavior. Do not infer real-device or real-system success from those checks.

Still unverified include physical-device sync and free-account signing behavior; full multi-display and multi-Space acceptance; and the complete range of mobile layout, Shortcut, export, and permission scenarios. Record an unrun scenario as **Not tested**.
