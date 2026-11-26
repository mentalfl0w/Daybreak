import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Bounded, off-main image decoding for the Today photograph.
///
/// The cached files are full-resolution wallpapers; decoding them at screen
/// size keeps scrolling and window resizing responsive. The decoder returns a
/// `CGImage` so it can cross the concurrency boundary without carrying a UIKit
/// object between actors.
enum TodayImageDecoder {
    nonisolated static func downsample(
        at url: URL,
        maxPixelSize: Int
    ) async -> CGImage? {
        let clampedSize = max(64, min(maxPixelSize, 4096))
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: clampedSize
            ]

            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    @MainActor
    static func image(from cgImage: CGImage?) -> UIImage? {
        guard let cgImage else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
