import AppKit
import ColorSync
import CoreGraphics
import DaybreakCore
import Foundation

/// Stable display identity built only from public APIs.
///
/// `CGDisplayCreateUUIDFromDisplayID` returns an EDID-derived UUID that stays
/// stable across reconnects when the display provides one. When it does not,
/// vendor/model/serial (or, as a last resort, the localized name) is used.
/// Temporary screen indexes and ordering are never part of the identity.
@MainActor
enum MacDisplayIdentity {
    static func displayID(for screen: NSScreen) -> DesktopDisplayID? {
        guard let screenNumber = screenNumber(for: screen) else {
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return DesktopDisplayID("display-name:\(name)")
        }

        if let uuid = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeRetainedValue() {
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            return DesktopDisplayID("display-uuid:\(uuidString.lowercased())")
        }

        let vendor = CGDisplayVendorNumber(screenNumber)
        let model = CGDisplayModelNumber(screenNumber)
        let serial = CGDisplaySerialNumber(screenNumber)
        if serial != 0 {
            return DesktopDisplayID("display-edid:\(vendor)-\(model)-\(serial)")
        }
        let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesktopDisplayID("display-edid:\(vendor)-\(model)-name:\(name)")
    }

    static func screenNumber(for screen: NSScreen) -> CGDirectDisplayID? {
        if #available(macOS 26.0, *) {
            // Public NSScreen property. Prefer it over the device-description
            // dictionary, which has no documented guarantee for every display
            // kind (for example virtual or Sidecar screens).
            return screen.cgDirectDisplayID
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
