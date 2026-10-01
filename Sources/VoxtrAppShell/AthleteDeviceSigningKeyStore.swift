import CryptoKit
import Foundation
import Security

/// Athlete Connection V1 (backend device authorization): the ONE
/// installation-specific P-256 signing key an Athlete device generates
/// and keeps for this install's lifetime — per the Normative Security
/// Contract §3, "a fresh installation-specific P-256 signing key (Secure
/// Enclave where supported) proves possession via request/purpose-bound
/// fresh signed challenges." This is NOT the same device-only Keychain
/// item `KeychainParentSessionStore` manages (different service/account,
/// different content — an opaque P-256 key, never a bearer session
/// token) and is never shared with, or derived from, anything the Parent
/// side stores.
///
/// SAME KEY ACROSS RETRIES: `loadOrCreateSigningKey()` returns the SAME
/// key on every call after the first — never rotated silently — which is
/// what lets a same-installation retry within the backend's 24-hour
/// recovery window (§2 D2) re-authenticate as the SAME device rather
/// than minting a new, unrelated identity on every attempt.
///
/// WIRE FORMAT: the public key is always exposed as the 65-byte
/// uncompressed SEC1/X9.63 point (`0x04 || X || Y`) via
/// `x963Representation` — NOT `rawRepresentation`, which is CryptoKit's
/// well-known 64-byte X||Y-only compact form and would NOT match
/// `cristern/Voxtr-Backend`'s `_shared/p256.ts` `validateP256PublicKey`,
/// which requires exactly 65 bytes starting with `0x04`. Signatures use
/// `rawRepresentation` (raw r||s, P1363, 64 bytes), which DOES match that
/// backend's `P256_SIGNATURE_LENGTH = 64` expectation directly — the
/// inverse asymmetry is deliberate and specific to each CryptoKit type,
/// not a copy/paste of the same accessor. `AthleteDeviceSigningKeyStoreTests`
/// asserts both exact byte lengths and the `0x04` prefix, plus a
/// sign+self-verify round trip using CryptoKit's own
/// `isValidSignature(_:for:)` — the concrete interop proof this
/// contract's own §6 addendum calls for, to be empirically confirmed by
/// Codemagic (no local Swift toolchain exists in the authoring
/// environment for this slice).
public protocol AthleteDeviceSigningKeyStoring: Sendable {
    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey
}

/// Deliberately NOT `Sendable`: wraps a signing closure over a CryptoKit
/// private key value. Every production call site is `@MainActor`
/// (`AthleteDeviceAuthorizationService`), matching this codebase's own
/// established "not Sendable, isolation stays within one actor" reasoning
/// for other types that wrap non-trivially-Sendable state (see
/// `AthleteIdentityHydrationError`'s own doc comment for the same
/// rationale applied to a different type).
public struct AthleteDeviceSigningKey {
    /// Always exactly 65 bytes, first byte `0x04` — see this file's own
    /// doc comment for why `x963Representation`, never `rawRepresentation`.
    public let publicKeyX963Representation: Data
    private let signClosure: (Data) throws -> Data

    init(secureEnclaveKey: SecureEnclave.P256.Signing.PrivateKey) {
        publicKeyX963Representation = secureEnclaveKey.publicKey.x963Representation
        signClosure = { message in try secureEnclaveKey.signature(for: message).rawRepresentation }
    }

    init(softwareKey: P256.Signing.PrivateKey) {
        publicKeyX963Representation = softwareKey.publicKey.x963Representation
        signClosure = { message in try softwareKey.signature(for: message).rawRepresentation }
    }

    /// Test-only seam: produces a fully deterministic key with no real
    /// CryptoKit generation — used by a fake `AthleteDeviceSigningKeyStoring`
    /// conformance in tests (`AthleteDeviceAuthorizationServiceTests
    /// .FakeSigningKeyStore`) so wire-format assertions never depend on a
    /// real generated key's own unpredictable bytes. `internal`,
    /// reachable only via `@testable import`.
    init(fixedPublicKey: Data, fixedSignature: Data, signCallback: @escaping (Data) -> Void) {
        publicKeyX963Representation = fixedPublicKey
        signClosure = { message in
            signCallback(message)
            return fixedSignature
        }
    }

    /// Raw r||s (P1363), always exactly 64 bytes — the exact bytes the
    /// backend's `claim-submit` handler expects, base64url-encoded, in
    /// its `signature` field.
    public func signature(for message: Data) throws -> Data {
        try signClosure(message)
    }
}

public enum AthleteDeviceSigningKeyStoreError: Error, Equatable {
    case keychainFailure(OSStatus)
    case corruptedKeyMaterial
    case keyReconstitutionFailed
}

/// Real Keychain-backed implementation. Tries a Secure Enclave key first
/// (`SecureEnclave.isAvailable`); falls back to a software CryptoKit
/// P-256 key on any device/simulator without one (e.g. every iOS
/// Simulator, and some older physical devices) — both backings present
/// the SAME `AthleteDeviceSigningKey` interface to every caller, so
/// nothing above this store needs to know which one is in use.
///
/// `final class` with only `Sendable` immutable stored properties — safe
/// to mark `Sendable` without `@unchecked`, mirroring
/// `KeychainParentSessionStore`'s own reasoning exactly.
public final class KeychainAthleteDeviceSigningKeyStore: AthleteDeviceSigningKeyStoring, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.voxtr.athlete.deviceSigningKey",
        account: String = "device-signing-key"
    ) {
        self.service = service
        self.account = account
    }

    /// Returns the SAME key across repeated calls (see this file's own
    /// "SAME KEY ACROSS RETRIES" doc comment) — only the very first call
    /// for a fresh install actually generates and persists a new key.
    public func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey {
        if let storedData = try loadKeyData() {
            return try Self.reconstitute(from: storedData)
        }
        let (key, dataToPersist) = Self.generateNewKey()
        try saveKeyData(dataToPersist)
        return key
    }

    // MARK: - Storage format

    /// A single leading marker byte distinguishes which CryptoKit type
    /// the remaining bytes reconstitute as — never guessed from length
    /// alone, since a Secure Enclave `dataRepresentation` blob and a
    /// software key's 32-byte raw scalar are not reliably distinguishable
    /// by size alone across OS versions.
    private static let secureEnclaveMarker: UInt8 = 0x01
    private static let softwareMarker: UInt8 = 0x02

    private static func generateNewKey() -> (AthleteDeviceSigningKey, Data) {
        if SecureEnclave.isAvailable, let secureEnclaveKey = try? SecureEnclave.P256.Signing.PrivateKey() {
            var data = Data([secureEnclaveMarker])
            data.append(secureEnclaveKey.dataRepresentation)
            return (AthleteDeviceSigningKey(secureEnclaveKey: secureEnclaveKey), data)
        }
        let softwareKey = P256.Signing.PrivateKey()
        var data = Data([softwareMarker])
        data.append(softwareKey.rawRepresentation)
        return (AthleteDeviceSigningKey(softwareKey: softwareKey), data)
    }

    private static func reconstitute(from stored: Data) throws -> AthleteDeviceSigningKey {
        guard let marker = stored.first else {
            throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
        }
        let payload = stored.dropFirst()
        do {
            switch marker {
            case secureEnclaveMarker:
                let secureEnclaveKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: payload)
                return AthleteDeviceSigningKey(secureEnclaveKey: secureEnclaveKey)
            case softwareMarker:
                let softwareKey = try P256.Signing.PrivateKey(rawRepresentation: payload)
                return AthleteDeviceSigningKey(softwareKey: softwareKey)
            default:
                throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
            }
        } catch is AthleteDeviceSigningKeyStoreError {
            throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
        } catch {
            throw AthleteDeviceSigningKeyStoreError.keyReconstitutionFailed
        }
    }

    // MARK: - Keychain plumbing (mirrors KeychainParentSessionStore's own
    // atomic-replace pattern exactly: SecItemUpdate first, SecItemAdd only
    // the very first time no item exists yet — never delete-then-add)

    private func loadKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AthleteDeviceSigningKeyStoreError.keychainFailure(status)
        }
        return data
    }

    private func saveKeyData(_ data: Data) throws {
        let query = baseQuery()
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AthleteDeviceSigningKeyStoreError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AthleteDeviceSigningKeyStoreError.keychainFailure(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
