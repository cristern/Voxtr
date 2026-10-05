import Foundation
import CryptoKit

// Test-only software keys. Never use these scalars for a device installation.
let backendRevision = "419f70e80b69ae524edb066e367093b1b8455a9a"
let versions = [
    ("session_issue", "voxtr-athlete-session-issue-v1"),
    ("session_renew", "voxtr-athlete-session-renew-v1"),
    ("hydration_get", "voxtr-athlete-hydration-get-v1"),
    ("hydration_ack", "voxtr-athlete-hydration-ack-v1")
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
let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
let wrongKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([2]))
let grant = "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"
let challenge = "FEDCBAFE-DCBA-FEDC-BAFE-DCBAFEDCBAFE"
let nonce = Data((0..<32).map { UInt8($0) })
let specialNonce = Data([251, 255])
try require(base64url(specialNonce) == "-_8", "base64url alphabet/padding")
var fixtures: [[String: String]] = []
for (action, version) in versions {
    let bytes = message(version, grant, challenge, nonce)
    try require(bytes == message(version, grant.lowercased(), challenge.lowercased(), nonce), "UUID casing")
    let expected = "\(version)\ndevice_grant_id=abcdefab-cdef-abcd-efab-cdefabcdefab\nchallenge_id=fedcbafe-dcba-fedc-bafe-dcbafedcbafe\nnonce=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8\n"
    try require(bytes == Data(expected.utf8), "frozen UTF-8/newline bytes")
    let signature = try key.signature(for: bytes)
    try require(signature.rawRepresentation.count == 64, "P1363 length")
    try require(key.publicKey.x963Representation.count == 65, "X9.63 length")
    try require(key.publicKey.isValidSignature(signature, for: bytes), "Swift signature self-check")
    fixtures.append(["action": action, "version": version, "deviceGrantId": grant,
        "challengeId": challenge, "nonce": base64url(nonce), "messageHex": hex(bytes),
        "messageUtf8": expected, "publicKey": base64url(key.publicKey.x963Representation),
        "signature": base64url(signature.rawRepresentation),
        "wrongPublicKey": base64url(wrongKey.publicKey.x963Representation)])
}
let output: [String: Any] = ["producer": "Swift CryptoKit on macOS", "backendRevision": backendRevision,
    "iosRevision": ProcessInfo.processInfo.environment["FIXTURE_IOS_REVISION"] ?? "unknown",
    "fixtures": fixtures]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("PASS: CryptoKit signed 4 actions; frozen bytes, UUID casing, encoding and key/signature lengths checked")
