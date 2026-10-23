// Checks that an EdDSA signature from Sparkle's sign_update covers a file and belongs to the public key an app
// carries in SUPublicEDKey, the same check Sparkle makes before it installs an update. It reads only public values.
//
//   xcrun swift Tools/release/verify-update-signature.swift <SUPublicEDKey> <edSignature> <file>
//
// Exit status: 0 when the signature is valid, 1 when it is not, 2 for unreadable input.
import CryptoKit
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("verify-update-signature: \(message)\n".utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else { fail("give <SUPublicEDKey> <edSignature> <file>", 2) }
guard let keyData = Data(base64Encoded: arguments[0]), keyData.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("the public key is not a base64 EdDSA public key of 32 bytes", 2)
}
guard let signature = Data(base64Encoded: arguments[1]), signature.count == 64 else {
    fail("the signature is not a base64 EdDSA signature of 64 bytes", 2)
}
guard let file = try? Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .alwaysMapped) else {
    fail("cannot read \(arguments[2])", 2)
}
guard key.isValidSignature(signature, for: file) else {
    fail("the signature does not match this file and public key", 1)
}
print("verify-update-signature: the signature matches the file and the public key")
