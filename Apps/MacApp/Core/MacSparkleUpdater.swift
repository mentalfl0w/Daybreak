import Foundation
import Sparkle

enum MacSparkleConfiguration {
    static let stableFeedURL = "https://github.com/mentalfl0w/Daybreak/releases/latest/download/appcast.xml"

    static func isConfigured(infoDictionary: [String: Any]) -> Bool {
        guard let feedURL = infoDictionary["SUFeedURL"] as? String,
              feedURL == stableFeedURL,
              let publicKey = infoDictionary["SUPublicEDKey"] as? String
        else {
            return false
        }
        return isValidPublicKey(publicKey)
    }

    private static func isValidPublicKey(_ publicKey: String) -> Bool {
        guard !publicKey.isEmpty,
              publicKey == publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
              let keyData = Data(base64Encoded: publicKey)
        else {
            return false
        }
        return keyData.count == 32
    }
}

@MainActor
final class MacSparkleUpdaterController {
    static let shared = MacSparkleUpdaterController()

    private let standardUpdaterController: SPUStandardUpdaterController?

    var updater: SPUUpdater? {
        standardUpdaterController?.updater
    }

    var isConfigured: Bool {
        standardUpdaterController != nil
    }

    private init(bundle: Bundle = .main) {
        guard MacSparkleConfiguration.isConfigured(infoDictionary: bundle.infoDictionary ?? [:]) else {
            standardUpdaterController = nil
            return
        }

        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        standardUpdaterController?.checkForUpdates(nil)
    }
}
