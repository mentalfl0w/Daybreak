# Daybreak product design and copy


## Content and visual hierarchy

Images, stories and real user results are the primary content on every platform. Use system navigation, toolbars and controls for interaction. Keep normal states quiet by moving cache, provenance and synchronization details into an on-demand status or diagnostic view.

Use one content model across macOS, iPhone, Duo and iPad while allowing each platform to compose it differently. Choose compact, intermediate or expanded layouts from available width and readable content space. Do not infer layout from device names or orientation alone.

Photography surfaces should respect the source composition during browsing. Wallpaper crop and preview controls belong to the wallpaper preview flow. Avoid stacked cards, repeated borders and multiple equally prominent buttons when spacing and native hierarchy can group the content more naturally.

Reserve Liquid Glass or system materials for navigation, floating controls and focused actions. Keep the photograph clear and avoid nesting translucent containers. Support Dynamic Type, VoiceOver, increased contrast, reduced transparency and reduced motion.

## States and copy

Normal content should not repeat internal cache or matching status. Loading, empty and error states should state what happened and the next useful action. Warnings belong beside an action that can affect permissions, storage, synchronization or the current wallpaper.

Use natural product language in the interface. Keep implementation details, error codes and architecture decisions in diagnostics or engineering documentation. Preserve exact source, copyright, date, market and wallpaper-result semantics whenever they affect user decisions.

## macOS and mobile composition

On macOS, keep the main window photo-first and let the menu bar offer a small set of daily wallpaper actions. Display selection, overwrite confirmation and automation failures remain available where the user can act on them. On mobile, keep Today as a continuous reading flow and hand system wallpaper changes to Shortcuts with an honest unknown final result.

Timeline, Library and Recap should feel like a visual archive. Thumbnails, representative images and favorites lead the page; coverage and counts support the story without becoming a dashboard.

Today keeps the photograph prominent and gives the story a separate readable measure. Place the title, date, attribution and actions beneath or alongside the image according to available width; do not reserve a full column for a few actions. Keep the actual source date when it differs from today.

Gallery records and annual recap days have different scopes: the gallery can include older archived records, while recap coverage uses the local observation window. Explain the distinction without changing the underlying counts or implying that unobserved dates had no content.

Open daily source pages in the app without changing the selected date or replacing the underlying reading surface. macOS uses a WebKit sheet; mobile uses the system Safari view. Offer an external browser for pages that cannot load. Validate the initial address and never expose application data through a web bridge.

Storage shows cached originals and thumbnails in separate tabs. Each tab keeps its own stable order and compact pagination, so users can inspect one cache type without mixing file roles or scrolling through an unnecessarily long combined list. Protection and deletion affordances remain on each row.

## Accessibility and localization

Use semantic system controls and labels with at least a 44-point target where the platform requires it. Keep layouts readable under large accessibility sizes and long localized strings. Localize the semantic message rather than translating implementation text literally. Retain keys used by dynamic lookup until all callers are checked.

## Sync

Describe sync as changes written by this device to the user-selected iCloud Drive folder. Completion does not prove another device received, imported or used those changes; propagation timing is outside Daybreak's control.

Each device keeps its own local data. Folder access permission stays on the device that granted it. Turning sync off does not delete local data or existing folder contents. State the actual default and optional synced content without exposing storage implementation details.

## System wallpaper actions

Daybreak hands an image to Apple Shortcuts; the system shortcut performs the wallpaper action and presents its result. Daybreak cannot read or confirm the final wallpaper state. A notification or an opened shortcut is not proof that wallpaper changed.

Keep permission states distinct from operation results. Pair an error with a practical next step, and keep detailed error tokens in opt-in diagnostics.

## Canonical screen names

| Screen | Simplified Chinese | English | Japanese |
| --- | --- | --- | --- |
| Today | 今日 | Today | 今日 |
| Timeline | 时光 | Timeline | タイムライン |

Use these names consistently in settings, shortcuts and help. Update all supported catalog translations when changing user-facing copy; retain keys used through dynamic localization lookup unless every caller has been checked.
