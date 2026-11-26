# Changelog

[简体中文](CHANGELOG.zh-CN.md) · [Project overview](../README.md)

This changelog consolidates development records. Test and build entries reflect evidence recorded on the dates shown; they do not establish that later edits or every device scenario were verified.

## Current status — 2026-11-26

- Refactored the application and infrastructure boundaries without changing product entry points. macOS display protection now lives in `WallpaperDisplayCoordinator`; repository storage, validation and protection calculations have focused files; Bing transport execution and image validation are separated from the public provider façade.
- Added `scripts/check-import-boundaries.sh` and CI enforcement for Core, platform, mobile, SwiftPM and XcodeGen dependency direction.
- The refactor verification passed 253 DaybreakCore tests, 79 MacIntegration tests, the import-boundary check, an unsigned macOS Release build, and an unsigned iOS Release build.
- Real-device folder synchronization, cross-device propagation, authorization-bookmark persistence after free-account re-signing, complete multi-display and multi-Space acceptance, and full mobile device behavior remain **Not tested**.

## 2026-11-26

- Added synchronization diagnostics that users can export on request. Reports use a field allowlist and do not automatically upload or include folder paths, bookmarks, device names, or user content.
- File coordination and path-validation changes received synthetic regression coverage. The documented device-side synchronization failure was not reproduced, so the work is not described as a confirmed device fix.
- The most recent recorded Core test run passed 252 tests. The iOS Release app compiled without signing; the generated unsigned IPA passed ZIP integrity checking but still requires user signing.

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
