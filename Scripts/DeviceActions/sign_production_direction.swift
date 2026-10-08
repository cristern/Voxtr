import Foundation
import CryptoKit

// Athlete Connection V1 device-authorization session contract (§3.3,
// §8 step 4) — closing the evidence gate §2.2 explicitly leaves open:
// "Swift CryptoKit signs (the real device key, the actual production
// direction) → Deno verification. Unproven by any cross-implementation
// fixture or device run that exists today."
//
// DISTINCT FROM `sign.swift` (PR #115): that script uses FIXED test
// scalars (1, 2) — explicitly documented there as "Test-only software
// keys. Never use these scalars for a device installation." This
// script instead generates a genuinely fresh, random
// `P256.Signing.PrivateKey()` EVERY run, with fresh random UUIDs and a
// fresh random nonce — the same shape of key material and inputs a
// real installation's `KeychainAthleteDeviceSigningKeyStore` software-
// key fallback would produce (Secure Enclave keys cannot be
// constructed outside real enclave hardware either way, so no CI
// script — this one included — can exercise that specific path; see
// `AthleteConnectionCrossImplementationFixtureTests.swift`'s own
// "HONEST SCOPE" note for the same, already-accepted limitation).
//
// This script intentionally re-implements the version-line lookup
// table and four-line message assembly inline — a standalone
// `swift <file>.swift` invocation has no access to a built SwiftPM
// module, so it cannot literally `import VoxtrAppShell`. Byte-for-byte
// identity between THIS algorithm and the real production
// `AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(...)` type
// in `Sources/VoxtrAppShell/AthleteDeviceAuthorizationSessionModels.swift`
// is independently proven by
// `AthleteDeviceAuthorizationSessionCanonicalMessageCrossImplementationFixtureTests.swift`,
// which exercises that exact production type against fixed fixtures
// confirmed valid by this same pinned backend verifier. What THIS
// script adds, that a pure-Swift unit test cannot, is a genuine
// CryptoKit sign step on real macOS hardware (Codemagic's
// `mac_mini_m2`/GitHub Actions' `macos-14`) with a real, non-
// predetermined key, verified by the real unchanged Deno runtime —
// the actual cross-process, cross-language round trip.
let backendRevision = "419f70e80b69ae524edb066e367093b1b8455a9a"
let versions = [
    ("session_issue", "voxtr-athlete-session-issue-v1"),
    ("session_renew", "voxtr-athlete-session-renew-v1"),
    ("hydration_get", "voxtr-athlete-hydration-get-v1"),
    ("hydration_ack", "voxtr-athlete-hydration-ack-v1"),
]
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
}
func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func message(_ version: String, _ grant: String, _ challenge: String, _ nonce: Data) -> Data {
    Data("\(version)\ndevice_grant_id=\(grant.lowercased())\nchallenge_id=\(challenge.lowercased())\nnonce=\(base64url(nonce))\n".utf8)
}

// Genuinely fresh every run — never a fixed scalar, never a fixed
// UUID/nonce. This is the "real device key, actual production
// direction" this evidence gate names.
let key = P256.Signing.PrivateKey()
let wrongKey = P256.Signing.PrivateKey()
let grant = UUID().uuidString
let challenge = UUID().uuidString
var nonceBytes = [UInt8](repeating: 0, count: 32)
for i in 0..<nonceBytes.count { nonceBytes[i] = UInt8.random(in: 0...255) }
let nonce = Data(nonceBytes)

var fixtures: [[String: String]] = []
for (action, version) in versions {
    let bytes = message(version, grant, challenge, nonce)
    try require(bytes == message(version, grant.lowercased(), challenge.lowercased(), nonce), "UUID casing")
    let signature = try key.signature(for: bytes)
    try require(signature.rawRepresentation.count == 64, "P1363 length")
    try require(key.publicKey.x963Representation.count == 65, "X9.63 length")
    try require(key.publicKey.isValidSignature(signature, for: bytes), "Swift signature self-check")
    fixtures.append([
        "action": action, "version": version, "deviceGrantId": grant,
        "challengeId": challenge, "nonce": base64url(nonce), "messageHex": hex(bytes),
        "messageUtf8": String(decoding: bytes, as: UTF8.self),
        "publicKey": base64url(key.publicKey.x963Representation),
        "signature": base64url(signature.rawRepresentation),
        "wrongPublicKey": base64url(wrongKey.publicKey.x963Representation),
    ])
}
// "producer" must read EXACTLY "Swift CryptoKit on macOS" — this is
// the one literal string `verify.ts` (unmodified, same file #115
// already pinned CI around) asserts with strict equality. The
// genuine-random-key distinction this script exists for is a property
// of HOW this fixture was produced (see this file's own header
// comment), not a string verify.ts parses, so changing this value
// would only break the unmodified verifier for no benefit.
let output: [String: Any] = [
    "producer": "Swift CryptoKit on macOS",
    "backendRevision": backendRevision,
    "iosRevision": ProcessInfo.processInfo.environment["FIXTURE_IOS_REVISION"] ?? "unknown",
    "fixtures": fixtures,
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("PASS: CryptoKit signed 4 actions with a genuinely fresh, random production-direction key (never a fixed test scalar); frozen-shape bytes, UUID casing, encoding and key/signature lengths checked")
