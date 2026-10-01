import Testing
import CryptoKit
import Foundation
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization). These are the
// "explicit reviewed test vector" the Normative Security Contract's §3/§6
// addendum calls for before relying on Swift CryptoKit <-> Deno Web
// Crypto interoperability: exact byte lengths and the 0x04 uncompressed-
// point prefix on the public key, plus a real sign+self-verify round trip
// using CryptoKit's own `isValidSignature(_:for:)` — never asserted from
// documentation alone. No Swift toolchain exists in the authoring
// environment for this slice, so this file is written but not locally
// executed; Codemagic is the authoritative confirmation, matching this
// repository's own established "no local Swift toolchain" convention
// (see `ParentAuthenticationServiceTests.swift`'s own Keychain-round-trip
// test header note for the same posture).
@Suite("AthleteDeviceSigningKeyStore (Athlete Connection V1, backend device authorization)")
struct AthleteDeviceSigningKeyStoreTests {

    @Test("A software P-256 key's public key is exactly 65 bytes starting with 0x04 (x963Representation, NOT the 64-byte rawRepresentation CryptoKit gotcha)")
    func softwareKeyPublicKeyIsX963Uncompressed() {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKeyTestSupport.makeFromSoftwareKey(privateKey)

        #expect(key.publicKeyX963Representation.count == 65)
        #expect(key.publicKeyX963Representation.first == 0x04)
        // The well-known gotcha this contract explicitly calls out:
        // rawRepresentation is 64 bytes (X||Y only, no prefix) and must
        // NEVER be what gets sent to the backend as device_public_key.
        #expect(privateKey.publicKey.rawRepresentation.count == 64)
    }

    @Test("A software P-256 signature is exactly 64 bytes (raw r||s, P1363) — matches the backend's P256_SIGNATURE_LENGTH directly")
    func softwareKeySignatureIsRawP1363() throws {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKeyTestSupport.makeFromSoftwareKey(privateKey)
        let message = Data("voxtr-athlete-connection-claim-v1\n".utf8)

        let signature = try key.signature(for: message)

        #expect(signature.count == 64)
    }

    @Test("A signature produced by signature(for:) verifies against the SAME key's own public key via CryptoKit's own isValidSignature(_:for:) — the concrete interop proof, not merely asserted shapes")
    func signatureSelfVerifies() throws {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKeyTestSupport.makeFromSoftwareKey(privateKey)
        let message = Data("voxtr-athlete-connection-claim-v1\nchallenge_id=abc\n".utf8)

        let signatureBytes = try key.signature(for: message)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)

        #expect(privateKey.publicKey.isValidSignature(signature, for: message))
    }

    @Test("A signature does not verify against a DIFFERENT message — proves this isn't a tautological always-true check")
    func signatureDoesNotVerifyAgainstWrongMessage() throws {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKeyTestSupport.makeFromSoftwareKey(privateKey)

        let signatureBytes = try key.signature(for: Data("original message".utf8))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)

        #expect(!privateKey.publicKey.isValidSignature(signature, for: Data("a different message".utf8)))
    }

    // MARK: - Keychain round trip (real Keychain-backed store)

    // NOTE: like `ParentAuthenticationServiceTests.keychainStoreRoundTrips`,
    // this exercises the real Security framework Keychain APIs and
    // requires the Xcode/iOS Simulator runtime — written but not executed
    // in this sandbox.
    @Test("KeychainAthleteDeviceSigningKeyStore returns the SAME key across repeated calls, and a fresh store instance (same service/account) reconstitutes the identical public key from Keychain")
    func keychainStoreReturnsSameKeyAcrossCallsAndInstances() throws {
        let service = "com.voxtr.athlete.deviceSigningKey.tests"
        let account = "device-signing-key-test-\(UUID().uuidString)"
        let store = KeychainAthleteDeviceSigningKeyStore(service: service, account: account)
        defer {
            // Best-effort cleanup — delete via a fresh store pointed at
            // the same service/account; no dedicated delete API is
            // otherwise exposed by this type, matching its own
            // "load-or-create, never rotate" contract.
            let cleanupQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(cleanupQuery as CFDictionary)
        }

        let first = try store.loadOrCreateSigningKey()
        let second = try store.loadOrCreateSigningKey()
        #expect(first.publicKeyX963Representation == second.publicKeyX963Representation)

        // A FRESH store instance, same service/account, must reconstitute
        // the exact same key from Keychain — this is what lets a
        // same-installation retry within the backend's 24-hour recovery
        // window re-authenticate as the SAME device.
        let freshStoreInstance = KeychainAthleteDeviceSigningKeyStore(service: service, account: account)
        let third = try freshStoreInstance.loadOrCreateSigningKey()
        #expect(first.publicKeyX963Representation == third.publicKeyX963Representation)
    }
}

/// Test-only seam: `AthleteDeviceSigningKey`'s own initializers are
/// `internal` (not `private`), so `@testable import` already grants this
/// file access — this namespace exists only to keep the test bodies
/// above reading as "construct a key from this known private key",
/// without repeating the initializer call inline everywhere.
enum AthleteDeviceSigningKeyTestSupport {
    static func makeFromSoftwareKey(_ privateKey: P256.Signing.PrivateKey) -> AthleteDeviceSigningKey {
        AthleteDeviceSigningKey(softwareKey: privateKey)
    }
}
