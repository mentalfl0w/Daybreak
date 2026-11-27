# Contributing to Daybreak

Thank you for helping improve Daybreak. Keep changes focused, preserve the local-first product boundaries, and describe what you actually verified.

[简体中文](CONTRIBUTING.zh-CN.md) · [Project overview](README.md) · [Documentation index](docs/README.md)

## Development setup

Use macOS with Xcode and the Swift toolchain required by the project. Install XcodeGen 2.40 or newer if needed, then generate the project from the repository root:

```sh
xcodegen generate -s Apps/MacApp/project.yml -r . -p .
```

Open `Daybreak.xcodeproj` in Xcode. The macOS app uses the `Daybreak` scheme; the iOS/iPadOS app uses `DaybreakMobile`.

## Build and test

Build the macOS app without signing:

```sh
xcodebuild -project Daybreak.xcodeproj -scheme Daybreak \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Compile the iOS app against the installed device SDK without signing:

```sh
xcodebuild -project Daybreak.xcodeproj -scheme DaybreakMobile \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For local notification testing, an unsigned build is not equivalent to the
installed app. On one macOS installation, an ad-hoc build with signing identifier
`dev.daybreak.mac` showed notification permission as authorized. The cause of the
earlier failure and actual notification delivery remain unverified.
If you choose to sign a disposable copy for local testing, explicitly use the
bundle identifier and inspect the result; do not re-sign an existing signed app:

```sh
ditto /path/to/unsigned/Daybreak.app /path/to/test/Daybreak.app
codesign --force --deep --sign - --identifier dev.daybreak.mac /path/to/test/Daybreak.app
codesign --verify --deep --strict /path/to/test/Daybreak.app
codesign -dv /path/to/test/Daybreak.app 2>&1
```

Install the test copy in a stable location and launch it from there. Ad-hoc
signatures are not Developer ID signatures; distribution and system notification
behavior require separate verification.

Run the platform-independent and macOS integration test suites when your change affects them:

```sh
swift test --package-path Packages/DaybreakCore
swift test --package-path Platform/MacIntegration
xcodebuild -project Daybreak.xcodeproj -scheme Daybreak \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

To compile the mobile test target without running it:

```sh
xcodebuild -project Daybreak.xcodeproj -scheme DaybreakMobile \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```

A successful compile does not establish device behavior. Do not install iOS simulator runtimes for this project. If a check requires an unavailable device, system configuration, or second display, report it as **Not tested**; do not substitute compilation or synthetic tests for that result.

## Project map

- `Apps/MacApp` and `Apps/MobileApp` contain the native app targets and XcodeGen project specification.
- `Packages/DaybreakCore` contains shared data, providers, repository, calendar, recap, and synchronization logic.
- `Platform/MacIntegration` contains macOS wallpaper and display integration.
- `Assets` and `branding` contain app resources and design assets.
- `docs/DATA_AND_STORY.md` and `docs/DATA_AND_STORY.zh-CN.md` describe data provenance and recap rules.
- `docs/DECISIONS.md` and `docs/CHANGELOG.md` describe architecture decisions and observed history.
- `.github/workflows/ci.yml` builds the macOS app unsigned, ad-hoc signs it using its `CFBundleIdentifier`, then packages a DMG; it leaves the iOS app unsigned and packages an IPA.

## Implementation boundaries

- Use Apple public APIs only. Do not read or modify private system wallpaper databases or promise immediate updates to inactive Spaces.
- Treat multi-display assignment and Space reconciliation as separate behaviors. Keep system-dependent behavior event-driven and preserve honest limits.
- An unreadable or dynamic original wallpaper must not block an explicit manual set. Automatically replacing an unknown wallpaper requires independent authorization.
- iOS and iPadOS wallpaper changes go through App Intents and Shortcuts; the app must not claim to set the system wallpaper directly.
- Keep synchronization optional and local-first. Each device keeps its own repository and bookmark; a user-selected folder may carry versioned records and assets. Do not require a backend, CloudKit, an app-specific iCloud container, or a paid capability.
- Do not add product backup or restore for system wallpapers, or make it a precondition for use or testing. Cache/index repair and migration within Daybreak remain product responsibilities.
- Use synthetic or properly licensed fixtures. Never commit real Bing images, story text, credentials, signing identities, provisioning profiles, or user data. Do not invent missing source content or recap statistics.

## Localization

Keep interface strings in the existing String Catalogs and update the supported zh-Hans, en, and ja translations when behavior changes. Preserve plural rules and format dates and numbers for the selected locale. Use the existing localization helpers for app-selected language.

Bing titles, descriptions, and credits are source content, not interface strings. Preserve their original language and provenance; any future translation must be labeled as a translation rather than replacing the source text.

## Pull requests

Keep each change narrow and explain the user-visible behavior or maintenance need. Include relevant tests or build commands and their actual results. State the SDK and device used when applicable, and list checks that remain unverified.

For interface changes, include screenshots only when they reflect the actual app and do not contain private user data. Never claim that a system or device scenario passed based on a build, test double, or screenshot from another version.

CI uploads build artifacts for pushes and pull requests. Release runs are started by a version tag or manually. CI applies and verifies an ad-hoc signature to the macOS app in the DMG using the app's `CFBundleIdentifier`; this is not a Developer ID signature. The iOS IPA remains unsigned for user signing. Do not commit signing credentials or alter signing settings for convenience.

See [AGENTS.md](AGENTS.md) for repository-wide implementation constraints and the [documentation index](docs/README.md) for maintained references.
