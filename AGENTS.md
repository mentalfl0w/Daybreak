# AGENTS.md — Daybreak repository agent guide

> Applies to the whole repository and its contributors. Read the linked specifications before changing architecture or public behavior.

## Mission & non-negotiable scope

Daybreak is an open-source, native Swift 6 / SwiftUI application for macOS, iOS and iPadOS, including iPhone Duo. Bing daily wallpapers are the primary source. Its differentiators are **calendar + cached daily story**, **local retrospective**, **reliable Apple wallpaper workflows**, **Liquid Glass** and **offline-first behavior**.

- No App Store release, account system, telemetry, paywall, advertisements, AI image generation, server backend or private Apple API.
- iOS / iPadOS distribution is **user-signed sideloading** and local builds, not a promise that an unsigned `.ipa` installs directly.
- macOS must not edit Dock / WallpaperAgent databases, kill/restart Dock to force Spaces, or promise atomic all-Space wallpaper updates.
- macOS multi-display assignment and multi-Space synchronization are distinct P0 requirements: react to active Space changes and reconcile the accessible Space using public APIs; never imply inactive Spaces update immediately.
- Do not download or install iOS simulator runtimes. Compile against installed SDKs; validate mobile behavior on real devices when ready and authorized.
- Do not add product-level backup/restore of system wallpapers, and never make backup/restore of existing wallpapers a precondition for using or testing the app. Internal cache/index repair and version migration remain required app behavior.
- Do not require a dedicated test machine or permanent test facility. Use a second display only when it is already available for the multi-display scenario; otherwise defer that scenario as **Not tested**. Real-device and real-system checks may be deferred; record them as **Not tested**, never as passed, and do not block Phase D on them.
- Do not develop a dedicated test entry point, Debug interface, standalone test tool, or dedicated test mode. Verify through existing product flows and automated test targets; do not add a test-only surface to the app.
- iOS must not claim direct wallpaper changes through App APIs. Use App Intents + system Shortcuts with honest permission / preview requirements.
- User-selected folder sync is optional and local-first through a user-selected iCloud Drive folder, with independent local repositories and coordinated file access. Do not use CloudKit, iCloud key-value storage, app-specific iCloud containers, App Group, or paid-team entitlements as prerequisites. Never sync a live repository index, device-local bookmark, system wallpaper state or system permissions. Real-device free-sideload and iCloud propagation remain unverified until actually tested.
- Do not fork existing clients or copy code/assets without checking license compatibility. Never bundle real Bing media or full copyrighted story archives into git or releases.

## Authoritative documents

1. `docs/README.md` — documentation index and current project entry point.
2. `docs/DATA_AND_STORY.md` — canonical data contract; story retrieval, provenance, persistence, recap eligibility.
3. `docs/PRODUCT_DESIGN.md` — cross-platform content-first visual hierarchy, responsive layout, accessibility, localization and product language.
4. `docs/DECISIONS.md` — accepted architecture decisions and deferred questions.
5. `docs/CHANGELOG.md` — dated implementation evidence, limitations and release history.
6. `CONTRIBUTING.md` — build, test and packaging commands.

If a requested task conflicts with a documented hard constraint, report it and propose the smallest compliant change. Update docs and tests when a decision changes. A deferred check remains `Not tested`; it is not a failure of the implemented slice and must not be reported as passing.

## Expected repository structure (create only during implementation)

- `Apps/MacApp/` — menu bar, main window and AppKit integrations.
- `Apps/MobileApp/` — shared iPhone, Duo and iPad UI, App Intents integration.
- `Packages/DaybreakCore/` — Foundation-only data models, repositories, provider protocols, scheduler and pure recap engine.
- `Platform/MacIntegration/` and `Platform/MobileIntegration/` — platform-specific adaptors; no reverse dependency into core.
- `Extensions/` — optional widgets once verified and supported by signing mode.
- `Tests/`, `Fixtures/` — deterministic unit, integration and UI tests; fixtures must be synthetic or rights-cleared.

Keep features in focused files and do not create unnecessary package or abstraction layers before use. Prefer Foundation, URLSession, ImageIO, SwiftUI and public Apple frameworks; no third-party runtime dependencies without an approved architectural decision.

## Engineering rules

- Swift 6 language mode, strict concurrency checking, `async/await`, structured cancellation and explicit actor boundaries.
- No blocking network/disk operations on the main actor; image decoding should be bounded and downsampled for thumbnails.
- Identity is **content + occurrence**: one image can appear on different market/date combinations. Never use date as unique wallpaper key.
- Distinguish source publication date, market-local calendar date, fetch time and device timezone. Never derive image date from local `Date()` alone.
- Story text is a separate, optional, attributed resource. **Never fabricate, silently translate, or label copyright text as a full story**.
- Distinguish metadata / thumbnail / original / story in cache and retention rules. Favorites, pinned dates, currently accessible desktop images and in-flight wallpaper writes must survive automatic cleanup. Previously applied images are not permanently protected solely because an inactive Space may reference them; they may be evicted under the normal cache policy. The system's rendered wallpaper cache was observed to survive one Space switch but is not guaranteed across sleep, restart, or system versions.
- Validate HTTPS host allowlists, MIME, image decode, size and redirects. Do not log image URLs containing secrets; no secrets or Apple credentials in repository.
- UI must adapt to available window dimensions, not `UIScreen.main` assumptions, device identifiers or orientation alone. Respect reduced motion, reduced transparency, Dynamic Type and VoiceOver.
- All state changes must be idempotent, cancellable and observable. Offline UI must show cached content and meaningful missing/error states.
- For recap, only use stored dated records; distinguish no observation from no wallpaper. Recap coverage must be visible; no invented annual statistics.

## Working procedure

1. Inspect repository state, this guide and applicable docs; identify the smallest end-to-end user outcome.
2. For any Apple API or Bing contract uncertainty, run a contained proof of concept and document observed behavior **before** broad implementation.
3. State intended files, tests and potential migrations before edits for multi-file changes.
4. Implement narrow vertical slices. Write model/provider tests first when feasible; add regression fixtures for every bug.
5. Run the relevant builds/tests the current environment supports; report **which commands ran, which device/SDK was used, and which checks were not run**. If a check needs unavailable hardware, a second display, or a real device, defer it as **Not tested**; do not claim it passed and do not block Phase D on it. Never claim passing tests from code inspection alone.
6. Update docs, rationale and `docs/DECISIONS.md` for new behavior or architecture changes. Do not silently expand P2 scope.
7. Do not auto-commit, tag, publish, notarize, sign or distribute binaries unless the user explicitly authorizes that action.

## Quality gates for a PR / work item

- Compiles with the chosen supported Xcode/SDK; no new warnings under Swift 6 strict concurrency.
- Has tests for normal/empty/offline/invalid-network/cancellation paths where applicable.
- Does not regress zh-CN, en-US, ja-JP, multi-market dates, story/provenance persistence and local recap.
- For UI changes: at least iPhone narrow, Duo folded/unfolded, iPad windowed and Mac window/menu bar review when available. Checks that need unavailable devices stay **Not tested**; they do not block Phase D.
- Signing-sensitive capabilities must not break the self-signed sideload configuration.

## Build commands (confirm destinations)

The macOS scheme is `Daybreak`; the iOS/iPadOS scheme is `DaybreakMobile`. Generate the project with `xcodegen generate -s Apps/MacApp/project.yml -r . -p .` after source or specification changes, then confirm destinations:

```sh
xcodebuild -list -project Daybreak.xcodeproj
xcodebuild -project Daybreak.xcodeproj -scheme Daybreak -destination 'platform=macOS' build
xcodebuild -project Daybreak.xcodeproj -scheme Daybreak -destination 'platform=macOS' test
xcodebuild -project Daybreak.xcodeproj -scheme DaybreakMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```

The macOS hosted test target can launch the real App and resume persisted wallpaper automation. Do not run it against a user's active configuration when that could change wallpaper without authorization.

Never substitute a simulator build for evidence of successful real-device Duo wallpaper automation. Do not download or install simulator runtimes to make a check runnable.

## Agent handoff format

Each completed task reports: `Summary / Files changed / Tests run + results / Limitations + unverified assumptions / Next safe step`. Prefer Chinese prose in user-facing docs; English identifiers and API names are fine.

## Apple Public API Policy

Daybreak MUST exclusively use documented Apple public APIs for all system integrations.

### Mandatory constraints

- Use `NSScreen` for display enumeration.
- Use `NSWorkspace` for desktop wallpaper management.
- Use `NSWorkspace.activeSpaceDidChangeNotification` to observe Space changes.
- Implement event-driven wallpaper reconciliation for multiple Spaces.
- Do not use private CGS or Spaces APIs.
- Do not read or modify Dock or WallpaperAgent private databases.
- Do not rely on undocumented system preferences or internal file formats.
- Do not promise atomic updates to inactive Spaces.
- Do not use Accessibility UI automation as the default wallpaper synchronization mechanism.

### Acceptance criteria

- Automatically apply the target wallpaper to currently accessible desktops.
- Reconcile wallpaper state when the active Space changes.
- Handle multiple displays independently.
- Recover from display reconnection, wake, and login events.
- Preserve manually selected wallpapers according to user preferences.
- Do not treat an unreadable or dynamic original wallpaper as a blocker for an explicit manual set. Automatic overwrite of unknown wallpaper requires independent authorization. Two nil reads with identical options and no Space/display event do not prove the original wallpaper is unchanged.
- Provide observable synchronization failures and avoid repeated unnecessary writes.
- Do not build a backup/restore or rollback feature around these APIs. Transient preflight state is not a user-visible backup. Protect currently accessible wallpaper files and in-flight writes; do not indefinitely protect historical images solely for inactive Spaces.

Any feature that cannot be implemented reliably with public APIs must be explicitly documented as a platform limitation rather than bypassed through private interfaces.