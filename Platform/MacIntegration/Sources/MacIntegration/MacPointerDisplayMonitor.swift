import AppKit
import DaybreakCore
import Foundation

/// A pointer transition from one display to another.
///
/// Only a change of the public display identity is reported; movement inside
/// one display, screen order changes and the first sample after observing
/// starts are not.
public struct MacPointerDisplayChange: Hashable, Sendable {
    /// Display that now contains the pointer.
    public let displayID: DesktopDisplayID
    /// Display that contained the pointer before the change.
    public let previousDisplayID: DesktopDisplayID

    public init(
        displayID: DesktopDisplayID,
        previousDisplayID: DesktopDisplayID
    ) {
        self.displayID = displayID
        self.previousDisplayID = previousDisplayID
    }
}

/// Pure cross-display transition tracker.
///
/// Keeping this policy separate from AppKit makes the "only a real identity
/// change triggers" contract testable without synthesising mouse events.
struct MacPointerDisplayTracker: Sendable {
    private var currentDisplayID: DesktopDisplayID?

    init(displayID: DesktopDisplayID? = nil) {
        self.currentDisplayID = displayID
    }

    /// Records one sample. The first non-nil sample establishes the baseline
    /// and never fires; later samples fire only when both the previous and the
    /// new identity are known and differ.
    mutating func update(to displayID: DesktopDisplayID?) -> MacPointerDisplayChange? {
        guard let displayID else { return nil }
        let previous = currentDisplayID
        guard previous != displayID else { return nil }
        currentDisplayID = displayID
        guard let previous else { return nil }
        return MacPointerDisplayChange(
            displayID: displayID,
            previousDisplayID: previous
        )
    }

    mutating func reset(displayID: DesktopDisplayID? = nil) {
        currentDisplayID = displayID
    }
}

/// Injectable pointer source so tests never depend on real mouse events.
@MainActor
public protocol MacPointerDisplayObserving {
    func observeDisplayChanges(
        _ handler: @escaping @Sendable (MacPointerDisplayChange) -> Void
    ) -> MacSystemEventObservation
}

/// Observes only public AppKit mouse events.
///
/// `mouseMoved` plus left/right/other drags are installed as both a global and
/// a local monitor: the global monitor covers movement while another app is
/// frontmost, the local monitor covers this app. Only public `NSEvent` and
/// `NSScreen` APIs are used. AppKit monitor registration and removal are
/// confined to the main actor; the monitor tokens never escape it.
@MainActor
public final class AppKitPointerDisplayObserver: MacPointerDisplayObserving {
    /// Mouse movement that can carry the pointer across a display boundary.
    public static let observedEventTypes: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
    ]

    private var monitors: [Any] = []
    private var tracker = MacPointerDisplayTracker()

    public init() {}

    public func observeDisplayChanges(
        _ handler: @escaping @Sendable (MacPointerDisplayChange) -> Void
    ) -> MacSystemEventObservation {
        tearDown()
        // The pointer may already be on a display when observation starts.
        // Treat that as the baseline so only a later crossing fires.
        tracker.reset(displayID: Self.pointerDisplayID())

        let global = NSEvent.addGlobalMonitorForEvents(
            matching: Self.observedEventTypes
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate(handler)
            }
        }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: Self.observedEventTypes
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.evaluate(handler)
            }
            return event
        }
        monitors = [global, local].compactMap { $0 }

        return MacSystemEventObservation { [weak self] in
            guard let self else { return }
            // The integration cancels on the main actor. Other callers get a
            // safe async teardown instead of touching AppKit off-main.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self.tearDown()
                }
            } else {
                Task { @MainActor in
                    self.tearDown()
                }
            }
        }
    }

    private func evaluate(
        _ handler: @escaping @Sendable (MacPointerDisplayChange) -> Void
    ) {
        guard let change = tracker.update(to: Self.pointerDisplayID()) else {
            return
        }
        handler(change)
    }

    private func tearDown() {
        let current = monitors
        monitors.removeAll()
        for monitor in current {
            NSEvent.removeMonitor(monitor)
        }
        tracker.reset()
    }

    private static func pointerDisplayID() -> DesktopDisplayID? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(location, $0.frame, false)
        }) else {
            return nil
        }
        return MacDisplayIdentity.displayID(for: screen)
    }
}
