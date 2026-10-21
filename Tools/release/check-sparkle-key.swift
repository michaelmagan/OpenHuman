// Checks that a Sparkle private key (read from standard input, never printed) belongs to the public key the app
// ships in SUPublicEDKey. A mismatch would publish updates that every installed copy refuses, so the release
// workflow runs this before it builds anything.
//
//   printf '%s' "$SPARKLE_PRIVATE_KEY" | xcrun swift Tools/release/check-sparkle-key.swift <SUPublicEDKey>
//
// Exit status: 0 when the keys belong together, 1 when they do not, 2 for unreadable input.
import CryptoKit
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("check-sparkle-key: \(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let expected = Data(base64Encoded: arguments.first!), expected.count == 32 else {
    fail("give the base64 SUPublicEDKey (32 bytes) as the only argument", 2)
}
let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let secret = Data(base64Encoded: input) else { fail("standard input is not a base64 private key", 2) }

// generate_keys -x exports the 32-byte seed. Keys in the format before Sparkle 2 are refused: their stored public half
// cannot be checked against the private half here, so make a new pair (docs/release/SPARKLE.md)
guard secret.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else {
    fail("the private key is \(secret.count) bytes; expected the 32-byte seed that generate_keys -x exports", 2)
}
let derived = key.publicKey.rawRepresentation
guard derived == expected else {
    fail("SPARKLE_PRIVATE_KEY does not belong to SUPublicEDKey \(arguments.first!). Updates signed with it would be refused", 1)
}
print("check-sparkle-key: the private key belongs to SUPublicEDKey")
