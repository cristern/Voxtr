import Testing
import CryptoKit
import Foundation
import Security
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization, review round 2).
// These are the "explicit reviewed test vector" the Normative Security
// Contract's §3/§6 addendum calls for before relying on Swift CryptoKit
// <-> Deno Web Crypto interoperability: exact byte lengths and the 0x04
// uncompressed-point prefix on the public key, plus a real sign+self-verify
// round trip using CryptoKit's own `isValidSignature(_:for:)` — never
// asserted from documentation alone.
//
// REVIEW ROUND 2: `AthleteDeviceSigningKeyStore` was restructured around
// three injected seams (`AthleteDeviceKeyMaterialStoring`,
// `AthleteInstallationMarkerStoring`, `AthleteDeviceSigningKeyGenerating`)
// specifically so the installation lifecycle (relaunch vs reinstall),
// Secure Enclave failure propagation, corrupt/missing material, and save
// failure are all deterministically testable WITHOUT real Keychain/Secure
// Enclave hardware — `SecureEnclave.isAvailable` is always `false` in the
// Simulator/CI, so the real implementation's own SE branch can never be
// exercised there at all; these fakes let the SURROUNDING contract (never
// silently fall back, never silently regenerate, never return an
// unpersisted key) be proven regardless. No Swift toolchain exists in the
// authoring environment for this slice, so this file is written but not
// locally executed; Codemagic is the authoritative confirmation, matching
// this repository's own established "no local Swift toolchain" convention
// (see `ParentAuthenticationServiceTests.swift`'s own Keychain-round-trip
// test header note for the same posture).
private final class FakeKeyMaterialStore: AthleteDeviceKeyMaterialStoring, @unchecked Sendable {
    struct SaveFailure: Error {}

    var stored: Data?
    var failNextSave = false
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0

    func loadKeyMaterial() throws -> Data? {
        loadCallCount += 1
        return stored
    }

    func saveKeyMaterial(_ data: Data) throws {
        saveCallCount += 1
        if failNextSave {
            failNextSave = false
            throw SaveFailure()
        }
        stored = data
    }
}

private final class FakeMarkerStore: AthleteInstallationMarkerStoring, @unchecked Sendable {
    var marker: String?
    private(set) var savedMarkers: [String] = []

    func loadMarker() -> String? { marker }

    func saveMarker(_ marker: String) {
        self.marker = marker
        savedMarkers.append(marker)
    }
}

/// Defaults to REAL CryptoKit software-key generation/reconstitution
/// (`SecureEnclave.isAvailable` is always `false` here anyway) — a
/// genuinely random key each `generateNewKey()` call, deterministically
/// reconstituted from its own `rawRepresentation` bytes — so tests that
/// don't care about Secure Enclave/corruption specifically get realistic,
/// distinct keys per call for free. `onGenerateNewKey`/`onReconstitute`
/// override this for the specific scenarios that need to simulate an SE
/// failure or corrupt/invalidated material.
private final class FakeKeyGenerator: AthleteDeviceSigningKeyGenerating, @unchecked Sendable {
    private(set) var generateCallCount = 0
    private(set) var reconstituteCallCount = 0
    var onGenerateNewKey: (() throws -> (key: AthleteDeviceSigningKey, data: Data))?
    var onReconstitute: ((Data) throws -> AthleteDeviceSigningKey)?

    func generateNewKey() throws -> (key: AthleteDeviceSigningKey, data: Data) {
        generateCallCount += 1
        if let onGenerateNewKey { return try onGenerateNewKey() }
        let privateKey = P256.Signing.PrivateKey()
        return (AthleteDeviceSigningKey(softwareKey: privateKey), privateKey.rawRepresentation)
    }

    func reconstitute(from data: Data) throws -> AthleteDeviceSigningKey {
        reconstituteCallCount += 1
        if let onReconstitute { return try onReconstitute(data) }
        guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
        }
        return AthleteDeviceSigningKey(softwareKey: privateKey)
    }
}

@Suite("AthleteDeviceSigningKeyStore (Athlete Connection V1, backend device authorization, review round 2)")
struct AthleteDeviceSigningKeyStoreTests {

    // MARK: - Wire format (unchanged by review round 2's restructuring)

    @Test("A software P-256 key's public key is exactly 65 bytes starting with 0x04 (x963Representation, NOT the 64-byte rawRepresentation CryptoKit gotcha)")
    func softwareKeyPublicKeyIsX963Uncompressed() {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKey(softwareKey: privateKey)

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
        let key = AthleteDeviceSigningKey(softwareKey: privateKey)
        let message = Data("voxtr-athlete-connection-claim-v1\n".utf8)

        let signature = try key.signature(for: message)

        #expect(signature.count == 64)
    }

    @Test("A signature produced by signature(for:) verifies against the SAME key's own public key via CryptoKit's own isValidSignature(_:for:) — the concrete interop proof, not merely asserted shapes")
    func signatureSelfVerifies() throws {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKey(softwareKey: privateKey)
        let message = Data("voxtr-athlete-connection-claim-v1\nchallenge_id=abc\n".utf8)

        let signatureBytes = try key.signature(for: message)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)

        #expect(privateKey.publicKey.isValidSignature(signature, for: message))
    }

    @Test("A signature does not verify against a DIFFERENT message — proves this isn't a tautological always-true check")
    func signatureDoesNotVerifyAgainstWrongMessage() throws {
        let privateKey = P256.Signing.PrivateKey()
        let key = AthleteDeviceSigningKey(softwareKey: privateKey)

        let signatureBytes = try key.signature(for: Data("original message".utf8))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)

        #expect(!privateKey.publicKey.isValidSignature(signature, for: Data("a different message".utf8)))
    }

    // MARK: - Installation lifecycle: relaunch vs reinstall

    @Test("Relaunch (same installation marker) reuses the exact same stored key — loadOrCreateSigningKey() never regenerates for an unchanged installation")
    func relaunchReusesSameKey() throws {
        let keyMaterialStore = FakeKeyMaterialStore()
        let markerStore = FakeMarkerStore()
        let keyGenerator = FakeKeyGenerator()
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: markerStore,
            keyGenerator: keyGenerator,
            generateMarker: { "install-marker-fixed" }
        )

        let first = try store.loadOrCreateSigningKey()
        #expect(keyGenerator.generateCallCount == 1)

        let second = try store.loadOrCreateSigningKey()

        #expect(first.publicKeyX963Representation == second.publicKeyX963Representation)
        #expect(keyGenerator.generateCallCount == 1, "a second call for the SAME installation must reuse the stored key, never regenerate")
        #expect(keyGenerator.reconstituteCallCount == 1)
    }

    @Test("Reinstall: the installation marker (UserDefaults, wiped on uninstall) no longer matches the marker tagged on Keychain-only key material from the PREVIOUS install — the orphaned material is never silently reused, and a genuinely NEW key is generated")
    func reinstallDoesNotReuseOrphanedKeychainMaterial() throws {
        // Keychain can survive uninstall; this single fake instance
        // stands in for that persistence across both "installs" below.
        let keyMaterialStore = FakeKeyMaterialStore()
        let keyGenerator = FakeKeyGenerator()

        let firstInstallMarkerStore = FakeMarkerStore()
        let firstInstallStore = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: firstInstallMarkerStore,
            keyGenerator: keyGenerator,
            generateMarker: { "install-marker-1" }
        )
        let firstKey = try firstInstallStore.loadOrCreateSigningKey()
        #expect(keyGenerator.generateCallCount == 1)

        // Reinstall: a BRAND NEW marker store (UserDefaults was wiped),
        // but the SAME Keychain-backed key material store, which still
        // holds the first install's marker+key.
        let secondInstallMarkerStore = FakeMarkerStore()
        let secondInstallStore = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: secondInstallMarkerStore,
            keyGenerator: keyGenerator,
            generateMarker: { "install-marker-2" }
        )
        let secondKey = try secondInstallStore.loadOrCreateSigningKey()

        #expect(secondKey.publicKeyX963Representation != firstKey.publicKeyX963Representation)
        #expect(keyGenerator.generateCallCount == 2, "the orphaned material's mismatched marker must force a genuinely new key, never a silent cross-install reuse")
    }

    @Test("A Secure Enclave failure on a capable device propagates as .secureEnclaveFailure from loadOrCreateSigningKey() — never silently swallowed into a software-key fallback")
    func secureEnclaveFailurePropagatesRatherThanFallingBackSilently() {
        let keyGenerator = FakeKeyGenerator()
        keyGenerator.onGenerateNewKey = { throw AthleteDeviceSigningKeyStoreError.secureEnclaveFailure }
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: FakeKeyMaterialStore(),
            markerStore: FakeMarkerStore(),
            keyGenerator: keyGenerator
        )

        #expect(throws: AthleteDeviceSigningKeyStoreError.secureEnclaveFailure) {
            try store.loadOrCreateSigningKey()
        }
    }

    @Test("A storage (Keychain save) failure prevents loadOrCreateSigningKey() from ever returning a key that was not actually persisted — a later relaunch could never recover an in-memory-only key")
    func saveFailurePreventsReturningAnUnpersistedKey() {
        let keyMaterialStore = FakeKeyMaterialStore()
        keyMaterialStore.failNextSave = true
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: FakeMarkerStore(),
            keyGenerator: FakeKeyGenerator()
        )

        #expect(throws: FakeKeyMaterialStore.SaveFailure.self) {
            try store.loadOrCreateSigningKey()
        }
        #expect(keyMaterialStore.stored == nil)
    }

    // MARK: - loadExistingSigningKey(): never creates a replacement

    @Test("loadExistingSigningKey() throws .noKeyForCurrentInstallation when no installation marker has ever been recorded (fresh install, never paired) — and never generates a replacement")
    func loadExistingSigningKeyThrowsWhenNoMarkerStored() {
        let keyGenerator = FakeKeyGenerator()
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: FakeKeyMaterialStore(),
            markerStore: FakeMarkerStore(),
            keyGenerator: keyGenerator
        )

        #expect(throws: AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation) {
            try store.loadExistingSigningKey()
        }
        #expect(keyGenerator.generateCallCount == 0)
    }

    @Test("loadExistingSigningKey() throws .noKeyForCurrentInstallation when the marker is present but the Keychain key material is missing — and never generates a replacement")
    func loadExistingSigningKeyThrowsWhenKeyMaterialMissingDespiteMarkerPresent() {
        let markerStore = FakeMarkerStore()
        markerStore.marker = "install-marker-1"
        let keyGenerator = FakeKeyGenerator()
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: FakeKeyMaterialStore(),
            markerStore: markerStore,
            keyGenerator: keyGenerator
        )

        #expect(throws: AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation) {
            try store.loadExistingSigningKey()
        }
        #expect(keyGenerator.generateCallCount == 0)
    }

    @Test("loadExistingSigningKey() throws .noKeyForCurrentInstallation on corrupt stored material — a known pairing attempt fails safely rather than silently signing with a brand-new, mismatched key")
    func loadExistingSigningKeyThrowsOnCorruptMaterialRatherThanGeneratingAReplacement() {
        let markerStore = FakeMarkerStore()
        markerStore.marker = "install-marker-1"
        let keyMaterialStore = FakeKeyMaterialStore()
        // Well-formed marker framing, but a keyData payload too short to
        // be a valid P-256 raw representation — the REAL
        // KeychainAthleteDeviceSigningKeyStore.combine(...) framing,
        // reusable because it's `internal` and this file is
        // `@testable import`.
        keyMaterialStore.stored = KeychainAthleteDeviceSigningKeyStore.combine(
            marker: "install-marker-1",
            keyData: Data([0xFF, 0xFF])
        )
        let keyGenerator = FakeKeyGenerator()
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: markerStore,
            keyGenerator: keyGenerator
        )

        #expect(throws: AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation) {
            try store.loadExistingSigningKey()
        }
        #expect(keyGenerator.generateCallCount == 0, "a corrupt key during a known pairing attempt must never fall back to generating a replacement")
    }

    @Test("loadExistingSigningKey() throws .noKeyForCurrentInstallation when the stored marker no longer matches the current installation's marker (reinstall) — never reconstitutes orphaned material")
    func loadExistingSigningKeyThrowsWhenMarkerMismatched() throws {
        let keyMaterialStore = FakeKeyMaterialStore()
        let keyGenerator = FakeKeyGenerator()
        let firstInstallMarkerStore = FakeMarkerStore()
        let firstInstallStore = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: firstInstallMarkerStore,
            keyGenerator: keyGenerator,
            generateMarker: { "install-marker-1" }
        )
        _ = try firstInstallStore.loadOrCreateSigningKey()

        let secondInstallMarkerStore = FakeMarkerStore()
        secondInstallMarkerStore.marker = "install-marker-2"
        let secondInstallStore = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: secondInstallMarkerStore,
            keyGenerator: keyGenerator
        )

        #expect(throws: AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation) {
            try secondInstallStore.loadExistingSigningKey()
        }
    }

    @Test("loadExistingSigningKey() succeeds for a key already created by loadOrCreateSigningKey() on the SAME installation, reconstituting it WITHOUT ever calling generateNewKey()")
    func loadExistingSigningKeySucceedsAfterLoadOrCreateAndNeverRegenerates() throws {
        let keyMaterialStore = FakeKeyMaterialStore()
        let markerStore = FakeMarkerStore()
        let keyGenerator = FakeKeyGenerator()
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: keyMaterialStore,
            markerStore: markerStore,
            keyGenerator: keyGenerator,
            generateMarker: { "install-marker-1" }
        )
        let created = try store.loadOrCreateSigningKey()
        #expect(keyGenerator.generateCallCount == 1)

        let existing = try store.loadExistingSigningKey()

        #expect(existing.publicKeyX963Representation == created.publicKeyX963Representation)
        #expect(keyGenerator.generateCallCount == 1, "loadExistingSigningKey() must never generate a key itself")
    }

    // MARK: - Keychain round trip (real Keychain-backed material store + real key generator)

    // NOTE: like `ParentAuthenticationServiceTests.keychainStoreRoundTrips`,
    // this exercises the real Security framework Keychain APIs and
    // requires the Xcode/iOS Simulator runtime — written but not executed
    // in this sandbox. The marker store is faked (a single shared instance
    // standing in for "the same installation's UserDefaults") so this test
    // isolates exactly what it claims to prove: the REAL Keychain-backed
    // key material round-trips correctly through the REAL
    // `SystemAthleteDeviceSigningKeyGenerator` (its software-key path,
    // since `SecureEnclave.isAvailable` is always `false` in the
    // Simulator/CI this would actually run in).
    @Test("KeychainAthleteDeviceSigningKeyStore, wired to its REAL Keychain-backed key material store and REAL key generator, returns the SAME key across repeated calls, and a fresh store instance (same service/account, same installation marker) reconstitutes the identical public key from Keychain")
    func keychainStoreReturnsSameKeyAcrossCallsAndInstances() throws {
        let service = "com.voxtr.athlete.deviceSigningKey.tests"
        let account = "device-signing-key-test-\(UUID().uuidString)"
        defer {
            let cleanupQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(cleanupQuery as CFDictionary)
        }
        let sharedMarkerStore = FakeMarkerStore()
        let store = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: KeychainAthleteDeviceKeyMaterialStore(service: service, account: account),
            markerStore: sharedMarkerStore,
            keyGenerator: SystemAthleteDeviceSigningKeyGenerator()
        )

        let first = try store.loadOrCreateSigningKey()
        let second = try store.loadOrCreateSigningKey()
        #expect(first.publicKeyX963Representation == second.publicKeyX963Representation)

        // A FRESH store instance, same Keychain service/account AND the
        // same installation marker, must reconstitute the exact same key
        // — this is what lets a same-installation retry within the
        // backend's 24-hour recovery window re-authenticate as the SAME
        // device.
        let freshStoreInstance = KeychainAthleteDeviceSigningKeyStore(
            keyMaterialStore: KeychainAthleteDeviceKeyMaterialStore(service: service, account: account),
            markerStore: sharedMarkerStore,
            keyGenerator: SystemAthleteDeviceSigningKeyGenerator()
        )
        let third = try freshStoreInstance.loadOrCreateSigningKey()
        #expect(first.publicKeyX963Representation == third.publicKeyX963Representation)
    }
}
