import SwiftUI
import UIKit

/// Paints the hosting window itself.
///
/// On Duo's outer display the system can place the tab bar in a trailing
/// column and reserve a home-indicator strip that lie outside every SwiftUI
/// screen's own background. A view-level background cannot reach those areas,
/// so the window behind them is given the page color instead of the default
/// white. Purely cosmetic; it never intercepts touches.
struct WindowBackground: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.backgroundColor = .clear
        let color = color
        DispatchQueue.main.async {
            view.window?.backgroundColor = color
        }
    }
}
