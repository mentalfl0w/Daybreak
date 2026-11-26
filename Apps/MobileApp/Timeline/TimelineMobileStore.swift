import Foundation

/// The process-wide mobile store already implements the timeline contract
/// under these exact names, so Timeline adds no adapter logic and never opens a
/// second repository.
@MainActor
extension MobileStore: TimelineDataStore {}
