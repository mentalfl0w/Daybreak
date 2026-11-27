import AppKit
import SwiftUI

@MainActor
struct MacUpdateSettingsSections: View {
    @State private var controller: MacUpdateController
    @AppStorage(MacUpdateController.automaticChecksKey) private var fallbackAutomaticChecksEnabled = false
    @State private var automaticChecksEnabled = false
    @State private var automaticDownloadsEnabled = false

    init(controller: MacUpdateController = .shared) {
        _controller = State(initialValue: controller)
        let updater = MacSparkleUpdaterController.shared.updater
        _automaticChecksEnabled = State(
            initialValue: updater?.automaticallyChecksForUpdates ?? controller.automaticChecksEnabled
        )
        _automaticDownloadsEnabled = State(
            initialValue: updater?.automaticallyDownloadsUpdates ?? false
        )
    }

    var body: some View {
        Section("Updates") {
            LabeledContent("Current Version", value: controller.currentVersion)
            LabeledContent("Latest Version") {
                if let release = controller.latestRelease {
                    Text(release.tagName)
                        .foregroundStyle(.secondary)
                } else if MacSparkleUpdaterController.shared.isConfigured,
                          automaticChecksEnabled {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }

            if controller.isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for Updates…")
                }
                .accessibilityElement(children: .combine)
            } else if controller.failure == .noStableRelease {
                Text("Couldn’t find a stable release with a macOS DMG.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.isUpdateAvailable {
                Label("Update Available", systemImage: "arrow.down.circle")
                    .foregroundStyle(.tint)
            } else if controller.latestRelease != nil {
                Label("You're up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if !automaticChecksEnabled {
                Text("Automatic checks are off.")
                    .foregroundStyle(.secondary)
            }

            if let lastCheckedAt = controller.lastCheckedAt {
                LabeledContent("Last Checked") {
                    Text(lastCheckedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Check for updates automatically", isOn: $automaticChecksEnabled)
                .onChange(of: automaticChecksEnabled) { _, isEnabled in
                    if let updater = MacSparkleUpdaterController.shared.updater {
                        updater.automaticallyChecksForUpdates = isEnabled
                    } else {
                        fallbackAutomaticChecksEnabled = isEnabled
                        guard isEnabled else { return }
                        Task { await controller.check() }
                    }
                }

            if let updater = MacSparkleUpdaterController.shared.updater {
                Toggle("Automatically download updates", isOn: $automaticDownloadsEnabled)
                    .onChange(of: automaticDownloadsEnabled) { _, isEnabled in
                        updater.automaticallyDownloadsUpdates = isEnabled
                    }
                Text("Automatic downloads are off by default. When enabled, Sparkle downloads updates in the background and asks before installing when you quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sparkle updates are unavailable in this build. Use the GitHub release check below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if MacSparkleUpdaterController.shared.isConfigured {
                Text("Automatic checks use the signed HTTPS GitHub feed about once a day. GitHub receives your IP address and standard request metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Automatic checks contact GitHub at most once every 24 hours. No account credentials or telemetry are sent; GitHub may receive your IP address and standard request metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = controller.failure,
               failure != .noStableRelease {
                Text(message(for: failure))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if MacSparkleUpdaterController.shared.isConfigured {
                    Button("Check for Updates…") {
                        MacSparkleUpdaterController.shared.checkForUpdates()
                    }
                }

                Button(checkButtonTitle) {
                    Task { await controller.check() }
                }
                .disabled(controller.isChecking)

                if let downloadURL = controller.downloadURL {
                    Button("Download DMG") {
                        controller.recordBrowserOpenResult(NSWorkspace.shared.open(downloadURL))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)

            if controller.latestRelease != nil, controller.downloadURL == nil {
                Text("Couldn’t find a stable release with a macOS DMG.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.downloadURL != nil {
                Text("Download opens the official GitHub release asset in your browser. Sparkle updates are handled separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard automaticChecksEnabled, controller.latestRelease == nil else { return }
            await controller.check()
        }

        if let release = controller.latestRelease {
            Section("Release Notes") {
                if release.notes.isEmpty {
                    Text("Release notes aren't available.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(release.notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var checkButtonTitle: LocalizedStringKey {
        if controller.failure == .request || controller.failure == .noStableRelease {
            return "Check GitHub Again"
        }
        return "Check GitHub for Updates"
    }

    private func message(for failure: MacUpdateFailure) -> LocalizedStringKey {
        switch failure {
        case .request:
            return "Unable to check for updates. Check your internet connection and try again."
        case .noStableRelease:
            return "Couldn’t find a stable release with a macOS DMG."
        case .invalidCurrentVersion:
            return "Unable to determine the app version."
        case .browserOpen:
            return "Couldn’t open the browser. Try again."
        }
    }
}
