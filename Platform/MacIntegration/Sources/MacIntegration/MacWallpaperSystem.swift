import AppKit
import CoreGraphics
import DaybreakCore
import Foundation

// MARK: - Wallpaper options

/// A display-fill color that can be persisted without importing AppKit.
public struct MacWallpaperColor: Hashable, Codable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The subset of public desktop-image options Daybreak reads and writes.
///
/// `imageScalingRawValue` keeps the exact `NSImageScaling` value so a captured
/// option can be replayed. `scaling` is the platform-neutral interpretation;
/// `nil` means the public API did not report a value Daybreak understands.
public struct MacWallpaperOptions: Hashable, Codable, Sendable {
    public var imageScalingRawValue: Int?
    public var allowsClipping: Bool?
    public var fillColor: MacWallpaperColor?

    public init(
        imageScalingRawValue: Int? = nil,
        allowsClipping: Bool? = nil,
        fillColor: MacWallpaperColor? = nil
    ) {
        self.imageScalingRawValue = imageScalingRawValue
        self.allowsClipping = allowsClipping
        self.fillColor = fillColor
    }

    /// Platform-neutral scaling inferred from the public options.
    ///
    /// `NSImageScaleProportionallyUpOrDown` means "fill" only when clipping is
    /// allowed; without clipping it is the letterboxed "fit" behaviour.
    public var scaling: DesktopImageScaling? {
        guard let raw = imageScalingRawValue else { return nil }
        switch raw {
        case Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue):
            return (allowsClipping ?? false) ? .fill : .fit
        case Int(NSImageScaling.scaleAxesIndependently.rawValue):
            return .stretch
        case Int(NSImageScaling.scaleNone.rawValue):
            return .center
        default:
            // NSImageScaleProportionallyDown is not supported by the public
            // desktop-image API, so do not invent a neutral meaning.
            return nil
        }
    }

    /// Options that realise a platform-neutral scaling through public APIs.
    public static func forScaling(_ scaling: DesktopImageScaling) -> MacWallpaperOptions {
        switch scaling {
        case .fill:
            return MacWallpaperOptions(
                imageScalingRawValue: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                allowsClipping: true
            )
        case .fit:
            return MacWallpaperOptions(
                imageScalingRawValue: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                allowsClipping: false
            )
        case .stretch:
            return MacWallpaperOptions(
                imageScalingRawValue: Int(NSImageScaling.scaleAxesIndependently.rawValue),
                allowsClipping: false
            )
        case .center:
            return MacWallpaperOptions(
                imageScalingRawValue: Int(NSImageScaling.scaleNone.rawValue),
                allowsClipping: false
            )
        }
    }

    /// Reads the public option dictionary. Unknown values are left `nil`
    /// instead of being guessed.
    init(appKitOptions: [NSWorkspace.DesktopImageOptionKey: Any]?) {
        guard let appKitOptions else { return }
        if let number = appKitOptions[.imageScaling] as? NSNumber {
            self.imageScalingRawValue = number.intValue
        }
        if let number = appKitOptions[.allowClipping] as? NSNumber {
            self.allowsClipping = number.boolValue
        }
        if let color = appKitOptions[.fillColor] as? NSColor,
           let rgb = color.usingColorSpace(NSColorSpace.genericRGB) {
            self.fillColor = MacWallpaperColor(
                red: Double(rgb.redComponent),
                green: Double(rgb.greenComponent),
                blue: Double(rgb.blueComponent)
            )
        }
    }

    /// Public option dictionary used for writes and restores.
    var appKitOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let imageScalingRawValue {
            options[.imageScaling] = NSNumber(value: imageScalingRawValue)
        }
        if let allowsClipping {
            options[.allowClipping] = NSNumber(value: allowsClipping)
        }
        if let fillColor {
            options[.fillColor] = NSColor(
                calibratedRed: CGFloat(fillColor.red),
                green: CGFloat(fillColor.green),
                blue: CGFloat(fillColor.blue),
                alpha: 1
            )
        }
        return options
    }
}

// MARK: - Screen snapshot

/// One connected screen as reported by the platform layer.
public struct MacScreenSnapshot: Hashable, Sendable {
    public let displayID: DesktopDisplayID
    public let localizedName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool
    public let imageURL: URL?
    public let options: MacWallpaperOptions

    public init(
        displayID: DesktopDisplayID,
        localizedName: String,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        isMain: Bool = false,
        imageURL: URL? = nil,
        options: MacWallpaperOptions = MacWallpaperOptions()
    ) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
        self.imageURL = imageURL
        self.options = options
    }

    public func with(imageURL: URL?) -> MacScreenSnapshot {
        MacScreenSnapshot(
            displayID: displayID,
            localizedName: localizedName,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isMain: isMain,
            imageURL: imageURL,
            options: options
        )
    }
}

// MARK: - System boundary

/// Narrow boundary over public AppKit desktop APIs.
///
/// Tests must inject a synthetic implementation so no real wallpaper is
/// written during development. All implementations are `Sendable`; AppKit
/// access is confined to the main actor inside `AppKitWallpaperSystem`.
public protocol MacWallpaperSystem: Sendable {
    func screens() async -> [MacScreenSnapshot]
    func screensHaveSeparateSpaces() async -> Bool
    func applyImage(
        at url: URL,
        options: MacWallpaperOptions,
        to displayID: DesktopDisplayID
    ) async throws
}

/// Production implementation using `NSScreen` and `NSWorkspace` only.
///
/// No private CGS/Spaces APIs, no Dock or WallpaperAgent database access, and
/// no attempt to enumerate inactive Spaces: public APIs can only address the
/// currently accessible desktop.
public struct AppKitWallpaperSystem: MacWallpaperSystem {
    public init() {}

    public func screens() async -> [MacScreenSnapshot] {
        await MainActor.run { Self.readScreens() }
    }

    public func screensHaveSeparateSpaces() async -> Bool {
        await MainActor.run { NSScreen.screensHaveSeparateSpaces }
    }

    public func applyImage(
        at url: URL,
        options: MacWallpaperOptions,
        to displayID: DesktopDisplayID
    ) async throws {
        try await MainActor.run {
            guard let screen = NSScreen.screens.first(where: {
                MacDisplayIdentity.displayID(for: $0) == displayID
            }) else {
                throw DesktopFailure(
                    stage: .applyingWallpaper,
                    kind: .displayUnavailable,
                    message: "The display is no longer connected."
                )
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    url,
                    for: screen,
                    options: options.appKitOptions
                )
            } catch {
                throw Self.desktopFailure(for: error)
            }
        }
    }

    @MainActor
    private static func readScreens() -> [MacScreenSnapshot] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let displayID = MacDisplayIdentity.displayID(for: screen) else {
                return nil
            }
            let screenNumber = MacDisplayIdentity.screenNumber(for: screen)
            let width = screenNumber.map { Int(CGDisplayPixelsWide($0)) } ?? 0
            let height = screenNumber.map { Int(CGDisplayPixelsHigh($0)) } ?? 0
            let imageURL = NSWorkspace.shared.desktopImageURL(for: screen)
            let options = MacWallpaperOptions(
                appKitOptions: NSWorkspace.shared.desktopImageOptions(for: screen)
            )
            return MacScreenSnapshot(
                displayID: displayID,
                localizedName: screen.localizedName,
                pixelWidth: width,
                pixelHeight: height,
                isMain: index == 0,
                imageURL: imageURL,
                options: options
            )
        }
        .sorted { $0.displayID < $1.displayID }
    }

    /// Maps AppKit/Foundation errors to the coordinator's classified failures.
    /// Only failures that can clear on their own remain retryable.
    private static func desktopFailure(for error: any Error) -> DesktopFailure {
        if let failure = error as? DesktopFailure {
            return failure
        }
        let nsError = error as NSError
        let kind: DesktopFailure.Kind
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError:
                kind = .imageUnreadable
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                kind = .permissionDenied
            case NSFileWriteOutOfSpaceError:
                kind = .ioFailure
            default:
                kind = .unknown
            }
        } else {
            kind = .unknown
        }
        return DesktopFailure(
            stage: .applyingWallpaper,
            kind: kind,
            message: nsError.localizedDescription
        )
    }
}
