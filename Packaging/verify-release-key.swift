import Foundation
import CryptoKit

// All failure paths print a fixed message; private contents never enter logs.
func fail() -> Never {
    FileHandle.standardError.write(Data("Production signing key or signature verification failed.\n".utf8))
    exit(1)
}
let publicText = "SDsuoQo3jF5WNHSC1yo6B92Nanc9bBdjHJ8O474h9LU="
guard let publicBytes = Data(base64Encoded: publicText),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicBytes),
      let encoded = ProcessInfo.processInfo.environment["MACSYNC_SPARKLE_PRIVATE_KEY"],
      let seed = Data(base64Encoded: encoded), seed.count == 32,
      seed.base64EncodedString() == encoded,
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
      privateKey.publicKey.rawRepresentation == publicBytes else { fail() }
let args = CommandLine.arguments
if args.count == 3 {
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe),
          let signature = Data(base64Encoded: args[2]),
          publicKey.isValidSignature(signature, for: bytes) else { fail() }
} else if args.count != 1 { fail() }
print("Production public key verification passed.")
