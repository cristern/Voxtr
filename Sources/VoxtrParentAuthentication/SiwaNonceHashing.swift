import Foundation
import CryptoKit

/// Athlete Connection V1 Parent authentication — the SIWA nonce hashing
/// step both sides of the handshake must compute identically. See
/// cristern/Voxtr Docs/Architecture/AthleteConnectionV1-
/// ParentAuthenticationContract.md §1.2/§1.3: the backend generates 32
/// random bytes, base64url-encodes them (no padding) into a string, and
/// computes SHA-256 over the UTF-8 bytes of THAT STRING — never the raw
/// 32 bytes, never a re-decoded byte array. The device, upon receiving
/// that exact string from `auth-nonce`, must hash the identical UTF-8
/// bytes, completely unmodified (no trimming/re-encoding), and set the
/// resulting lowercase-hex digest on `ASAuthorizationAppleIDRequest
/// .nonce` — never the raw base64url string itself.
enum SiwaNonceHashing {
    /// Computes the exact hex digest `ASAuthorizationAppleIDRequest
    /// .nonce` must be set to, given the raw base64url nonce string the
    /// backend's `auth-nonce` endpoint returned, exactly as received.
    ///
    /// Fixed contract test vector (§1.3), also verified as a dedicated
    /// unit test (`SiwaNonceHashingTests`):
    /// `hashedNonceHex(forRawNonce: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA")`
    /// must equal
    /// `"eb9f16800c9029ffca85695763d23c3ace71011cf40e9354acd810205e250f87"`.
    static func hashedNonceHex(forRawNonce rawNonce: String) -> String {
        let digest = SHA256.hash(data: Data(rawNonce.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
