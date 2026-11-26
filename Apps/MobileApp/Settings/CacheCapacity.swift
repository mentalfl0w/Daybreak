import DaybreakCore
import Foundation

/// Cache capacity choices shown in mobile Settings.
///
/// The value is the user-facing *total* soft limit for cached image bytes.
/// `MobileStore` owns the mapping onto per-kind repository limits; Settings
/// only presents the choice so the two layers cannot disagree about which
/// number is authoritative.
enum CacheCapacity: Int64, CaseIterable, Identifiable, Sendable {
    case mb256 = 268_435_456
    case mb512 = 536_870_912
    case gb1 = 1_073_741_824
    case gb2 = 2_147_483_648
    case gb4 = 4_294_967_296

    var id: Int64 { rawValue }
    var bytes: Int64 { rawValue }

    /// Compact label such as `512 MB` or `1 GB`. Units are not translated:
    /// byte units are conventional and unambiguous in every interface
    /// language, and keeping them numeric avoids plural rules.
    var label: String {
        switch self {
        case .mb256: return "256 MB"
        case .mb512: return "512 MB"
        case .gb1: return "1 GB"
        case .gb2: return "2 GB"
        case .gb4: return "4 GB"
        }
    }

    static let defaultValue: CacheCapacity = .gb1

    /// Nearest preset for a stored byte value. A value saved by an older build
    /// or a different locale is never silently rounded down to a smaller
    /// limit; ties and in-between values round up so unsaved cache is not
    /// evicted by merely opening Settings.
    static func nearest(to bytes: Int64) -> CacheCapacity {
        allCases.min { lhs, rhs in
            abs(lhs.bytes - bytes) == abs(rhs.bytes - bytes)
                ? lhs.bytes > rhs.bytes
                : abs(lhs.bytes - bytes) < abs(rhs.bytes - bytes)
        } ?? .defaultValue
    }
}

/// Human-readable byte count used by the cache page. `ByteCountFormatter`
/// already localizes units and decimal separators; the app-language override
/// intentionally does not override number formatting.
enum SettingsByteText {
    static func string(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    static func string(_ bytes: Int64) -> String {
        string(Int(clamping: bytes))
    }
}
