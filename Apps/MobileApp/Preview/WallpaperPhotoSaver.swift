import Foundation
import Photos

/// Adds an exported crop to the user's photo library.
///
/// Only add-only authorization is requested. The photo library is never read,
/// enumerated or modified beyond the single explicit save. Daybreak does not
/// claim that saving an image changes any system wallpaper.
public enum WallpaperPhotoSaver {
    public static func saveToPhotos(fileURL: URL) async throws {
        guard fileURL.isFileURL,
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw WallpaperPreviewError.unreadableFile
        }
        guard Bundle.main.object(
            forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription"
        ) != nil else {
            throw WallpaperPreviewError.photosUnavailable
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw WallpaperPreviewError.photosPermissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: fileURL, options: nil)
            }
        } catch {
            throw WallpaperPreviewError.photosSaveFailed
        }
    }
}
