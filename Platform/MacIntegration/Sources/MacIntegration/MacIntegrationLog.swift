import os

/// Structured diagnostics for the macOS desktop integration.
///
/// Privacy rules: never log a full file path, wallpaper file name, story text,
/// or raw system error description. Log display identities as `.private`,
/// and log only counts, event names, modes, and refusal reasons.
enum MacIntegrationLog {
    static let logger = Logger(subsystem: "dev.daybreak.mac", category: "Desktop")
}
