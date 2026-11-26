import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Single-folder document picker.
///
/// The SwiftUI `fileImporter` wrapper cannot request `asCopy: false` and, on
/// some iPadOS versions, dismisses without returning a tapped folder row. The
/// documented `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)`
/// form is used directly so a folder selection reliably produces a
/// security-scoped URL.
struct FolderPickerView: UIViewControllerRepresentable {
    let onCompletion: (Result<URL, any Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<URL, any Error>) -> Void

        init(onCompletion: @escaping (Result<URL, any Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                onCompletion(.failure(CocoaError(.userCancelled)))
                return
            }
            onCompletion(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(.failure(CocoaError(.userCancelled)))
        }
    }
}
