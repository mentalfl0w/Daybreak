# Import boundaries

Run `bash scripts/check-import-boundaries.sh` from the repository root. The check reports each forbidden import with its file and line, and exits nonzero for violations.

Rules enforced:

- `Packages/DaybreakCore/Sources` must not import AppKit, SwiftUI, UIKit, MacIntegration, or MobileApp; the DaybreakCore Swift package has no package dependencies.
- `Platform/MacIntegration` may depend locally only on DaybreakCore, and must not import MobileApp. Its SwiftPM target must link the DaybreakCore product.
- The XcodeGen project maps the DaybreakCore and MacIntegration packages to their repository paths. The macOS `Daybreak` target depends on both; `DaybreakMobile` depends on DaybreakCore and not MacIntegration. MobileApp Swift files must not import MacIntegration.
- Swift import scans skip `.git`, `.build`, `build`, `Build`, `DerivedData`, generated directories, `SourcePackages`, and `xcuserdata`.
