# Architecture decision log

## Accepted decisions

### Public Apple APIs only
macOS wallpaper operations use public `NSWorkspace` and display APIs. The app does not edit Dock or WallpaperAgent databases and does not promise atomic updates across inactive Spaces.

### Local-first repository
Each device owns its repository. The repository stores versioned metadata, occurrences, stories, thumbnails and local references. An actor serializes repository writes. Extensions or other processes require a future coordination decision before concurrent writes.

### Optional folder sync
Users can select a shared folder, including an iCloud Drive folder, through public document-picker and file-coordination APIs. Sync exchanges versioned operations and content-addressed assets. It does not require CloudKit, an app-specific container, App Groups or paid entitlements. Bookmarks stay device-local.

### Mobile wallpaper workflow
iOS and iPadOS expose App Intents and Shortcuts integration. The app does not claim that an app API directly changes system wallpaper. System confirmation, preview, automation timing and crop behavior remain platform-dependent. Daybreak Apply and Daybreak Daily can append the `Send Daybreak Wallpaper Notification` App Intent after the system `Set Wallpaper Photo` action, passing the same `IntentFile` returned by the Daybreak image intent; the notification recovers metadata from that file's encoded wallpaper identity and attaches a thumbnail generated from that exact image. Users must authorize notifications in the app's Shortcuts guide. A submitted notification does not verify the system wallpaper action. The iCloud shortcuts are externally hosted, have no source templates in this repository, and cannot be silently updated by the app; users must manually add the action using the guide if a shared shortcut lacks it.

### Honest Bing content
The app preserves source locale and provenance. Missing story content is shown as unavailable. It never fabricates text, dates, image metadata or recap statistics.

### Distribution
macOS releases are unsigned DMG artifacts unless a user signs them. iOS and iPadOS artifacts are unsigned IPAs for user signing and sideloading. The project does not use App Store distribution, telemetry, backend services or bundled Bing media.

## Deferred questions

- Long-term stability and field coverage of the Bing homepage model across `zh-CN`, `en-US` and `ja-JP`.
- End-to-end App Intent, Shortcuts and wallpaper behavior on authorized devices, including Duo crop behavior.
- Complete multi-display and multi-Space reconciliation under display changes and Mission Control.
- Sideload entitlement persistence and optional widget capabilities.
- A future multi-process repository implementation and migration strategy.

## Evidence rule

A build, test or device behavior is reported as verified only when its command or device evidence exists. Unexecuted system scenarios remain untested.

## Composition and responsibility boundaries

- Date: 2026-11-26. Status: accepted.
- Decision: Use value types for domain identities and snapshots, protocols for platform and external-service boundaries, actors for shared mutable state, and composition for application orchestration and infrastructure. Keep `AppModel`, `WallpaperRepository`, and `BingProvider` as stable entry points while delegating display protection, repository storage and validation, request execution, and image validation to focused collaborators.
- Alternative: Add inheritance layers or introduce a protocol for every small operation. Rejected because SwiftUI and Swift concurrency favor composition, value semantics, and explicit actor boundaries. Excessive protocols would widen the call surface without improving behavior.
- Evidence: `WallpaperDisplayCoordinator.swift`, `WallpaperRepositoryStorage.swift`, `WallpaperRepositoryValidation.swift`, `WallpaperRepositoryProtection.swift`, `BingRequestExecutor.swift`, `BingHTTPTransport.swift`, `BingImageValidator.swift`, and `scripts/check-import-boundaries.sh`.
- Consequence: Existing entry points remain stable while internal responsibilities can evolve and be tested independently. New behavior should extend a focused collaborator instead of enlarging an entry-point object.
- Tests: `swift test --package-path Packages/DaybreakCore`, `swift test --package-path Platform/MacIntegration`, unsigned macOS and iOS Release builds, and the import-boundary check were executed.
