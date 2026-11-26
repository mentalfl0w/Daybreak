import SwiftUI

/// The single compact confirmation for every user-initiated wallpaper action.
///
/// The confirmation names the target display and the exact effect before any
/// write. The internal preflight token is created only by the confirm button;
/// there are no secondary checkboxes. A Space or wallpaper change between
/// opening this dialog and confirming still invalidates the token and fails
/// closed inside the integration.
struct WallpaperConfirmationDialog: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.pendingWallpaperConfirmation?.title ?? "",
            isPresented: presentationBinding,
            titleVisibility: .visible,
            presenting: model.pendingWallpaperConfirmation
        ) { confirmation in
            Button("取消", role: .cancel) {
                model.cancelPendingWallpaperConfirmation()
            }
            // Pass the captured value. SwiftUI may set `isPresented` false
            // before running this action; clearing the model first must never
            // turn the user's confirmation into a no-op.
            Button(confirmation.confirmLabel) {
                model.confirmWallpaperAction(confirmation)
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingWallpaperConfirmation != nil },
            set: { presented in
                if !presented {
                    model.schedulePendingWallpaperConfirmationDismissal(
                        id: model.pendingWallpaperConfirmation?.id
                    )
                }
            }
        )
    }
}

extension View {
    func wallpaperConfirmationDialog(model: AppModel) -> some View {
        modifier(WallpaperConfirmationDialog(model: model))
    }
}
