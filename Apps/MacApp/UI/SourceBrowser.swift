import AppKit
import Observation
import SwiftUI
import WebKit

/// A Link-styled source link that opens its destination in Daybreak's browser sheet.
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

    @State private var isPresented = false

    var body: some View {
        Link(destination: destination) {
            label
        }
        .environment(\.openURL, OpenURLAction { _ in
            isPresented = true
            return .handled
        })
        .sheet(isPresented: $isPresented) {
            MacSourceBrowserSheet(initialURL: destination)
                .frame(minWidth: 680, minHeight: 480)
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

private enum MacSourceBrowserFailure: Equatable {
    case pageLoad
    case insecureNavigation
    case invalidSource
}

@MainActor
@Observable
private final class MacSourceBrowserState {
    var estimatedProgress = 0.0
    var isLoading = false
    var canGoBack = false
    var currentURL: URL?
    var failure: MacSourceBrowserFailure?

    @ObservationIgnored var goBackAction: (() -> Void)?
    @ObservationIgnored var reloadAction: (() -> Void)?
    @ObservationIgnored var retryAction: (() -> Void)?
}

@MainActor
private struct MacSourceBrowserSheet: View {
    let initialURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var browserState = MacSourceBrowserState()
    @State private var safariUnavailable = false

    var body: some View {
        Group {
            if let safeURL = SourceBrowserURLPolicy.validated(initialURL) {
                VStack(spacing: 0) {
                    toolbar(for: safeURL)

                    if browserState.isLoading {
                        ProgressView(value: browserState.estimatedProgress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel(Text("Loading source page"))
                    }

                    ZStack {
                        MacSourceWebView(initialURL: safeURL, state: browserState)

                        if let failure = browserState.failure {
                            MacSourceBrowserFailureView(
                                failure: failure,
                                retry: { browserState.retryAction?() },
                                close: { dismiss() }
                            )
                        }
                    }
                }
            } else {
                MacSourceBrowserFailureView(
                    failure: .invalidSource,
                    retry: {},
                    close: { dismiss() }
                )
            }
        }
        .background(.background)
        .alert("Safari couldn’t be opened", isPresented: $safariUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make sure Safari is available, then try again.")
        }
    }

    private func toolbar(for safeURL: URL) -> some View {
        HStack(spacing: 12) {
            Button {
                browserState.goBackAction?()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!browserState.canGoBack)
            .accessibilityLabel(Text("Go Back"))
            .help(Text("Go Back"))

            Button {
                browserState.reloadAction?()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Reload"))
            .help(Text("Reload"))

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .accessibilityHidden(true)
                Text(browserState.currentURL?.host ?? safeURL.host ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Website domain"))
            .accessibilityValue(Text(browserState.currentURL?.host ?? safeURL.host ?? ""))
            .frame(maxWidth: .infinity)

            Button("Open in Safari", systemImage: "safari") {
                openInSafari()
            }
            .help(Text("Open the current page in Safari"))

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openInSafari() {
        guard let currentURL = browserState.currentURL,
              let safeURL = SourceBrowserURLPolicy.validated(currentURL),
              let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        else {
            safariUnavailable = true
            return
        }

        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.open(
                    [safeURL],
                    withApplicationAt: safariURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                safariUnavailable = true
            }
        }
    }
}

private struct MacSourceBrowserFailureView: View {
    let failure: MacSourceBrowserFailure
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: failure == .insecureNavigation || failure == .invalidSource ? "lock.slash" : "exclamationmark.triangle")
                .font(.title2)
                .accessibilityHidden(true)

            switch failure {
            case .insecureNavigation:
                Text("Only secure web pages on the standard web port can be opened here.")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose an HTTPS source link to continue.")
                    .foregroundStyle(.secondary)
            case .invalidSource:
                Text("This source link can’t be opened safely.")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Use an HTTPS address without credentials or a custom port.")
                    .foregroundStyle(.secondary)
            case .pageLoad:
                Text("This page couldn’t be loaded.")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Check your connection, then try again.")
                    .foregroundStyle(.secondary)
            }

            if failure == .invalidSource {
                Button("Close", action: close)
                    .padding(.top, 4)
            } else {
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct MacSourceWebView: NSViewRepresentable {
    let initialURL: URL
    let state: MacSourceBrowserState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, initialURL: initialURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(to: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: MacSourceBrowserState
        private weak var webView: WKWebView?
        private var retryURL: URL
        private var progressObservation: NSKeyValueObservation?

        init(state: MacSourceBrowserState, initialURL: URL) {
            self.state = state
            self.retryURL = initialURL
            super.init()

            state.goBackAction = { [weak self] in self?.webView?.goBack() }
            state.reloadAction = { [weak self] in self?.webView?.reload() }
            state.retryAction = { [weak self] in self?.retry() }
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.navigationDelegate = self
            webView.uiDelegate = self
            state.currentURL = retryURL

            progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, change in
                let progress = change.newValue ?? 0
                Task { @MainActor [weak self] in
                    self?.state.estimatedProgress = progress
                }
            }

            webView.load(URLRequest(url: retryURL))
        }

        func dismantle(_ webView: WKWebView) {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            progressObservation = nil
            self.webView = nil
            state.isLoading = false
            state.goBackAction = nil
            state.reloadAction = nil
            state.retryAction = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.isLoading = true
            state.failure = nil
            refreshState(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            refreshState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            state.estimatedProgress = 1
            state.failure = nil
            refreshState(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failNavigation(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failNavigation(error, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  SourceBrowserURLPolicy.validated(url) != nil
            else {
                if navigationAction.targetFrame?.isMainFrame != false {
                    state.isLoading = false
                    state.failure = .insecureNavigation
                }
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame != false {
                retryURL = url
                state.currentURL = url
                state.failure = nil
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            guard let url = navigationResponse.response.url,
                  SourceBrowserURLPolicy.validated(url) != nil
            else {
                if navigationResponse.isForMainFrame {
                    state.isLoading = false
                    state.failure = .insecureNavigation
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url,
                  SourceBrowserURLPolicy.validated(url) != nil
            else {
                if navigationAction.targetFrame == nil {
                    state.failure = .insecureNavigation
                }
                return nil
            }

            retryURL = url
            state.currentURL = url
            state.failure = nil
            webView.load(navigationAction.request)
            return nil
        }

        private func retry() {
            guard let webView else { return }
            state.failure = nil
            state.isLoading = true
            webView.load(URLRequest(url: retryURL))
        }

        private func failNavigation(_ error: Error, in webView: WKWebView) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            state.isLoading = false
            state.failure = .pageLoad
        }

        private func refreshState(from webView: WKWebView) {
            state.canGoBack = webView.canGoBack
            if let url = webView.url,
               let safeURL = SourceBrowserURLPolicy.validated(url) {
                state.currentURL = safeURL
            }
        }
    }
}
