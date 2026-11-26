import SwiftUI
import UIKit

/// Native share sheet for an exported crop file.
///
/// Sharing a file is not a wallpaper-set action; the activity controller is
/// the system's own UI and may present Save to Files, AirDrop, Messages or
/// other installed activities without Daybreak claiming the result.
struct WallpaperShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
