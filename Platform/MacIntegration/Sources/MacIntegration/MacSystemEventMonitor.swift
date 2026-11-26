import AppKit
import Foundation

/// System events that require a wallpaper reconciliation pass.
public enum MacSystemEvent: Hashable, Sendable {
    /// `NSWorkspace.activeSpaceDidChangeNotification`: only the now-accessible
    /// desktop can be reconciled. Inactive Spaces are not addressable.
    case activeSpaceDidChange
    /// `NSApplication.didChangeScreenParametersNotification`.
    case screenParametersChanged
    /// `NSWorkspace.screensDidWakeNotification`.
    case screensDidWake
    /// `NSWorkspace.didWakeNotification`.
    case systemDidWake
    /// `NSWorkspace.sessionDidBecomeActiveNotification` (login/session switch).
    case sessionDidBecomeActive
}

/// Cancellation handle for a set of notification observers.
public struct MacSystemEventObservation: Sendable {
    private let onCancel: @Sendable () -> Void

    public init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }

    public static let none = MacSystemEventObservation {}
}

/// Injectable notification source so tests never depend on real system events.
public protocol MacSystemEventObserving: Sendable {
    func observe(
        _ handler: @escaping @Sendable (MacSystemEvent) -> Void
    ) -> MacSystemEventObservation
}

/// Observes only public AppKit notification names.
public struct AppKitSystemEventObserver: MacSystemEventObserving {
    public init() {}

    public func observe(
        _ handler: @escaping @Sendable (MacSystemEvent) -> Void
    ) -> MacSystemEventObservation {
        let group = NotificationObserverGroup()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        group.add(
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler(.activeSpaceDidChange)
            }
        )
        group.add(
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler(.systemDidWake)
            }
        )
        group.add(
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler(.screensDidWake)
            }
        )
        group.add(
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler(.sessionDidBecomeActive)
            }
        )
        group.add(
            defaultCenter,
            defaultCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler(.screenParametersChanged)
            }
        )

        return MacSystemEventObservation {
            group.cancelAll()
        }
    }
}

/// `NSObjectProtocol` observer tokens are not `Sendable`; removal itself is
/// thread-safe on `NotificationCenter`, so the group only needs to protect its
/// own mutable token list.
private final class NotificationObserverGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

    func add(_ center: NotificationCenter, _ token: any NSObjectProtocol) {
        lock.lock()
        tokens.append((center, token))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let current = tokens
        tokens.removeAll()
        lock.unlock()
        for (center, token) in current {
            center.removeObserver(token)
        }
    }
}
