import Observation
import SafariServices
import SwiftUI
import UIKit

/// A Link-styled source link presented by the scene-level source browser host.
@MainActor
struct SourceLink<Label: View>: View {
    let destination: URL
    let label: Label

    init(destination: URL, label: Label) {
        self.destination = destination
        self.label = label
    }

    init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    @Environment(MobileSourceBrowserCoordinator.self) private var coordinator

    private var openURLAction: OpenURLAction {
        let coordinator = coordinator
        return OpenURLAction { url in
            coordinator.present(url)
            return .handled
        }
    }

    var body: some View {
        Link(destination: destination) {
            label
        }
        .environment(\.openURL, openURLAction)
    }
}

/// Attach to the stable MobileRootView, above its compact/wide shell switch.
@MainActor
extension View {
    func sourceBrowserHost() -> some View {
        modifier(SourceBrowserHostModifier())
    }
}

private struct SourceBrowserRequest: Identifiable {
    let id = UUID()
    let destination: URL
}

@MainActor
@Observable
private final class MobileSourceBrowserCoordinator {
    var request: SourceBrowserRequest?

    func present(_ destination: URL) {
        request = SourceBrowserRequest(destination: destination)
    }
}

@MainActor
private struct SourceBrowserHostModifier: ViewModifier {
    @State private var coordinator = MobileSourceBrowserCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            .sheet(
                item: Binding(
                    get: { coordinator.request },
                    set: { coordinator.request = $0 }
                )
            ) { request in
                MobileSourceBrowserSheet(request: request) {
                    coordinator.request = nil
                }
            }
    }
}

private enum SourceBrowserURLPolicy {
    static func validated(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443
        else {
            return nil
        }

        return url
    }
}

@MainActor
private struct MobileSourceBrowserSheet: View {
    let request: SourceBrowserRequest
    let onClose: () -> Void

    @State private var retryAttempt = 0
    @State private var initialLoadFailed = false
    @AccessibilityFocusState private var failureIsFocused: Bool

    var body: some View {
        Group {
            if let safeURL = SourceBrowserURLPolicy.validated(request.destination) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        if initialLoadFailed {
                            Button("Retry", systemImage: "arrow.clockwise", action: retry)
                                .accessibilityHint(Text("Restarts the source page from its original address."))
                                .frame(minHeight: 44)
                        }

                        Spacer(minLength: 8)

                        Button("Open in Browser", systemImage: "safari", action: openInBrowser)
                            .accessibilityHint(Text("Opens the original source in your default browser."))
                            .frame(minHeight: 44)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)

                    if initialLoadFailed {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("This page couldn’t be loaded.")
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityFocused($failureIsFocused)
                                Text("You can retry the original address or open it in your browser.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                        .accessibilityElement(children: .contain)
                    }

                    let currentAttempt = retryAttempt
                    SafariBrowserController(
                        url: safeURL,
                        onInitialLoad: { succeeded in
                            guard retryAttempt == currentAttempt else { return }
                            initialLoadFailed = !succeeded
                            failureIsFocused = !succeeded
                        },
                        onFinish: onClose
                    )
                    .id(currentAttempt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Can’t Open This Link",
                    systemImage: "lock.slash",
                    description: Text("Only HTTPS addresses without credentials or custom ports can be opened.")
                )
                .safeAreaInset(edge: .bottom) {
                    Button("Close", action: onClose)
                        .frame(minHeight: 44)
                        .padding()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func retry() {
        initialLoadFailed = false
        failureIsFocused = false
        retryAttempt += 1
    }

    private func openInBrowser() {
        guard let safeURL = SourceBrowserURLPolicy.validated(request.destination) else { return }
        UIApplication.shared.open(safeURL)
    }
}

@MainActor
private struct SafariBrowserController: UIViewControllerRepresentable {
    let url: URL
    let onInitialLoad: (Bool) -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInitialLoad: onInitialLoad, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onInitialLoad: (Bool) -> Void
        private let onFinish: () -> Void

        init(onInitialLoad: @escaping (Bool) -> Void, onFinish: @escaping () -> Void) {
            self.onInitialLoad = onInitialLoad
            self.onFinish = onFinish
        }

        nonisolated func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            Task { @MainActor [weak self] in
                self?.onInitialLoad(didLoadSuccessfully)
            }
        }

        nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            Task { @MainActor [weak self] in
                self?.onFinish()
            }
        }
    }
}
