import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    fputs("Sparkle appcast signature validation failed: \(message)\n", stderr)
    exit(EXIT_FAILURE)
}

guard CommandLine.arguments.count == 3 else {
    fail("expected an appcast path and public key")
}

let appcastURL = URL(fileURLWithPath: CommandLine.arguments[1])
let publicKeyString = CommandLine.arguments[2]

guard let publicKeyData = Data(base64Encoded: publicKeyString),
      publicKeyData.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    fail("public key is invalid")
}

let appcastData: Data
do {
    appcastData = try Data(contentsOf: appcastURL)
} catch {
    fail("appcast could not be read")
}

guard let appcastText = String(data: appcastData, encoding: .utf8) else {
    fail("appcast is not UTF-8")
}

let signaturePattern = #"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n-->\s*$"#
guard let signatureRegex = try? NSRegularExpression(pattern: signaturePattern),
      let match = signatureRegex.firstMatch(
        in: appcastText,
        range: NSRange(appcastText.startIndex..., in: appcastText)
      ),
      let signatureRange = Range(match.range(at: 1), in: appcastText),
      let lengthRange = Range(match.range(at: 2), in: appcastText),
      let signedLength = Int(appcastText[lengthRange]),
      let signatureData = Data(base64Encoded: String(appcastText[signatureRange])),
      signatureData.count == 64 else {
    fail("appcast does not contain a valid Sparkle signature block")
}

let signatureMarker = Data("<!-- sparkle-signatures:\n".utf8)
guard let signatureBlockStart = appcastData.range(of: signatureMarker, options: .backwards)?.lowerBound,
      appcastData.distance(from: appcastData.startIndex, to: signatureBlockStart) == signedLength else {
    fail("signed content length does not match the Sparkle signature block")
}

let signedContent = Data(appcastData[..<signatureBlockStart])
guard publicKey.isValidSignature(signatureData, for: signedContent) else {
    fail("appcast signature does not match the configured EdDSA public key")
}

print("Verified the signed Sparkle appcast against the configured EdDSA public key.")
