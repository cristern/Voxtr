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
/// SAME KEY ACROSS RETRIES, NEVER ACROSS REINSTALLS: `loadOrCreateSigningKey()`
/// returns the SAME key on every call after the first FOR THIS INSTALL —
/// never rotated silently within one install, which is what lets a
/// same-installation retry within the backend's 24-hour recovery window
/// (§2 D2) re-authenticate as the SAME device. But Keychain items can
/// survive an app deletion/reinstallation on iOS (depending on
/// accessibility attributes, and sometimes regardless) — a REINSTALL
/// must never silently resume a previous install's key as if it were the
/// same device. `KeychainAthleteDeviceSigningKeyStore` resolves this with
/// an installation-local MARKER string, stored in `UserDefaults` (wiped
/// on uninstall, unlike Keychain) and tagged alongside the key material
/// in Keychain: a key is only reused when the marker Keychain holds
/// matches the marker `UserDefaults` currently holds. The marker is
/// PURELY local bookkeeping — never sent to the backend, never treated
/// as authorization truth of any kind.
///
/// TWO READ ENTRY POINTS, DELIBERATELY DIFFERENT FAIL BEHAVIOR:
/// `loadOrCreateSigningKey()` is for STARTING a brand-new pairing
/// attempt — if no usable key exists for this installation (fresh
/// install, reinstall, or corrupt/invalidated material), it generates
/// and persists a new one. `loadExistingSigningKey()` is for CONTINUING
/// an attempt already bound to a specific key (e.g. retrying
/// `claim-submit` after a network failure) — it NEVER creates a key; a
/// missing or corrupt key throws explicitly, so a known pairing attempt
/// fails safely instead of silently signing with a brand-new,
/// mismatched key and continuing that request.
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
/// not a copy/paste of the same accessor.
public protocol AthleteDeviceSigningKeyStoring: Sendable {
    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey
    func loadExistingSigningKey() throws -> AthleteDeviceSigningKey
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
    /// CryptoKit generation. `internal`, reachable only via `@testable
    /// import`.
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
    /// A Secure Enclave-capable device (`SecureEnclave.isAvailable ==
    /// true`) failed to generate or reconstitute an SE key. Deliberately
    /// NEVER swallowed into a silent software-key fallback — that would
    /// be an unannounced protection downgrade on a device that should
    /// have Secure Enclave protection. The underlying `Error` is carried
    /// for diagnostics only.
    case secureEnclaveFailure
    case corruptedKeyMaterial
    /// `loadExistingSigningKey()`'s own failure: no key exists for the
    /// CURRENT installation (never created, reinstalled since, or the
    /// stored material no longer reconstitutes) — this method never
    /// creates a replacement; the caller must treat this as "this known
    /// attempt cannot continue," never silently start a new one.
    case noKeyForCurrentInstallation
}

/// Generates/reconstitutes the actual CryptoKit key material — isolated
/// as its own protocol purely so tests can deterministically simulate a
/// Secure Enclave failure or corrupt material WITHOUT needing real
/// Secure Enclave hardware (`SecureEnclave.isAvailable` is always
/// `false` in the Simulator/CI, so the real implementation's own SE
/// branch can never be exercised there at all).
public protocol AthleteDeviceSigningKeyGenerating: Sendable {
    /// Generates a brand-new key and its own persistable representation
    /// (marker-free — the store adds the installation marker before
    /// persisting). Tries Secure Enclave first on a capable device;
    /// throws `.secureEnclaveFailure` rather than silently falling back
    /// to software if that attempt fails unexpectedly. Falls back to a
    /// software key only when `SecureEnclave.isAvailable == false` (every
    /// Simulator, and some older physical devices) — an EXPECTED
    /// platform limitation, not a failure.
    func generateNewKey() throws -> (key: AthleteDeviceSigningKey, data: Data)
    /// Reconstitutes a previously-persisted key from its own stored
    /// representation. Throws `.corruptedKeyMaterial` for anything that
    /// doesn't parse/reconstitute, including an SE key whose material
    /// can no longer be used (e.g. after the device passcode was removed,
    /// a documented Secure Enclave key invalidation case).
    func reconstitute(from data: Data) throws -> AthleteDeviceSigningKey
}

public struct SystemAthleteDeviceSigningKeyGenerator: AthleteDeviceSigningKeyGenerating {
    /// A single leading marker byte distinguishes which CryptoKit type
    /// the remaining bytes reconstitute as — never guessed from length
    /// alone, since a Secure Enclave `dataRepresentation` blob and a
    /// software key's 32-byte raw scalar are not reliably distinguishable
    /// by size alone across OS versions.
    static let secureEnclaveMarker: UInt8 = 0x01
    static let softwareMarker: UInt8 = 0x02

    public init() {}

    public func generateNewKey() throws -> (key: AthleteDeviceSigningKey, data: Data) {
        if SecureEnclave.isAvailable {
            let secureEnclaveKey: SecureEnclave.P256.Signing.PrivateKey
            do {
                secureEnclaveKey = try SecureEnclave.P256.Signing.PrivateKey()
            } catch {
                throw AthleteDeviceSigningKeyStoreError.secureEnclaveFailure
            }
            var data = Data([Self.secureEnclaveMarker])
            data.append(secureEnclaveKey.dataRepresentation)
            return (AthleteDeviceSigningKey(secureEnclaveKey: secureEnclaveKey), data)
        }
        let softwareKey = P256.Signing.PrivateKey()
        var data = Data([Self.softwareMarker])
        data.append(softwareKey.rawRepresentation)
        return (AthleteDeviceSigningKey(softwareKey: softwareKey), data)
    }

    public func reconstitute(from stored: Data) throws -> AthleteDeviceSigningKey {
        guard let marker = stored.first else {
            throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
        }
        let payload = stored.dropFirst()
        switch marker {
        case Self.secureEnclaveMarker:
            guard let secureEnclaveKey = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: payload) else {
                throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
            }
            return AthleteDeviceSigningKey(secureEnclaveKey: secureEnclaveKey)
        case Self.softwareMarker:
            guard let softwareKey = try? P256.Signing.PrivateKey(rawRepresentation: payload) else {
                throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
            }
            return AthleteDeviceSigningKey(softwareKey: softwareKey)
        default:
            throw AthleteDeviceSigningKeyStoreError.corruptedKeyMaterial
        }
    }
}

/// Raw Keychain byte storage, isolated behind its own protocol so tests
/// can inject a fake that simulates a save failure, corrupt stored
/// bytes, or orphaned material from a previous install — without
/// touching the real Keychain.
public protocol AthleteDeviceKeyMaterialStoring: Sendable {
    func loadKeyMaterial() throws -> Data?
    func saveKeyMaterial(_ data: Data) throws
}

/// Installation-local marker storage. Deliberately `UserDefaults`-backed
/// in production, NEVER Keychain: the app's `UserDefaults` domain is
/// removed on uninstall, while a Keychain item can survive one — that
/// asymmetry is exactly what lets `KeychainAthleteDeviceSigningKeyStore`
/// tell "relaunch of the same install" apart from "reinstall, Keychain
/// item orphaned." The marker itself is an opaque local string, never
/// read by anything outside this store and never sent anywhere.
public protocol AthleteInstallationMarkerStoring: Sendable {
    func loadMarker() -> String?
    func saveMarker(_ marker: String)
}

public final class UserDefaultsAthleteInstallationMarkerStore: AthleteInstallationMarkerStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.voxtr.athlete.deviceSigningKey.installationMarker") {
        self.defaults = defaults
        self.key = key
    }

    public func loadMarker() -> String? {
        defaults.string(forKey: key)
    }

    public func saveMarker(_ marker: String) {
        defaults.set(marker, forKey: key)
    }
}

/// Real Keychain-backed implementation of `AthleteDeviceKeyMaterialStoring`.
/// `final class` with only `Sendable` immutable stored properties — safe
/// to mark `Sendable` without `@unchecked`, mirroring
/// `KeychainParentSessionStore`'s own reasoning exactly.
public final class KeychainAthleteDeviceKeyMaterialStore: AthleteDeviceKeyMaterialStoring, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.voxtr.athlete.deviceSigningKey",
        account: String = "device-signing-key"
    ) {
        self.service = service
        self.account = account
    }

    public func loadKeyMaterial() throws -> Data? {
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

    /// Atomic replace: `SecItemUpdate` first, `SecItemAdd` only the very
    /// first time no item exists yet — never delete-then-add, which
    /// would have a real window with no item at all. Mirrors
    /// `KeychainParentSessionStore.saveToken`'s own pattern exactly.
    public func saveKeyMaterial(_ data: Data) throws {
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

/// Orchestrates marker-matching + key generation/reconstitution over the
/// three injected seams above. See this file's own top-level doc comment
/// for the full reinstall-vs-relaunch contract.
public final class KeychainAthleteDeviceSigningKeyStore: AthleteDeviceSigningKeyStoring, Sendable {
    private let keyMaterialStore: AthleteDeviceKeyMaterialStoring
    private let markerStore: AthleteInstallationMarkerStoring
    private let keyGenerator: AthleteDeviceSigningKeyGenerating
    private let generateMarker: @Sendable () -> String

    public init(
        keyMaterialStore: AthleteDeviceKeyMaterialStoring = KeychainAthleteDeviceKeyMaterialStore(),
        markerStore: AthleteInstallationMarkerStoring = UserDefaultsAthleteInstallationMarkerStore(),
        keyGenerator: AthleteDeviceSigningKeyGenerating = SystemAthleteDeviceSigningKeyGenerator(),
        generateMarker: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.keyMaterialStore = keyMaterialStore
        self.markerStore = markerStore
        self.keyGenerator = keyGenerator
        self.generateMarker = generateMarker
    }

    /// For STARTING a new pairing attempt. Reuses the existing key only
    /// when it was tagged with the marker for THIS install; otherwise
    /// (fresh install, reinstall with orphaned Keychain material, or
    /// corrupt/invalidated material) generates and persists a new one —
    /// a genuine Secure Enclave failure on a capable device still
    /// propagates rather than silently downgrading to software.
    public func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey {
        let currentMarker = currentOrNewInstallationMarker()
        if let stored = try keyMaterialStore.loadKeyMaterial(),
           let (storedMarker, keyData) = Self.splitMarkerAndKeyData(stored),
           storedMarker == currentMarker,
           let key = try? keyGenerator.reconstitute(from: keyData) {
            return key
        }
        let (key, keyData) = try keyGenerator.generateNewKey()
        try keyMaterialStore.saveKeyMaterial(Self.combine(marker: currentMarker, keyData: keyData))
        return key
    }

    /// For CONTINUING an attempt already bound to a specific key. NEVER
    /// creates a key — a missing, reinstalled-over, or corrupt key
    /// throws `.noKeyForCurrentInstallation` explicitly, so a known
    /// pairing attempt fails safely instead of silently signing with a
    /// mismatched new key.
    public func loadExistingSigningKey() throws -> AthleteDeviceSigningKey {
        guard let currentMarker = markerStore.loadMarker() else {
            throw AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation
        }
        guard let stored = try keyMaterialStore.loadKeyMaterial() else {
            throw AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation
        }
        guard let (storedMarker, keyData) = Self.splitMarkerAndKeyData(stored), storedMarker == currentMarker else {
            throw AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation
        }
        do {
            return try keyGenerator.reconstitute(from: keyData)
        } catch {
            throw AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation
        }
    }

    private func currentOrNewInstallationMarker() -> String {
        if let existing = markerStore.loadMarker() {
            return existing
        }
        let fresh = generateMarker()
        markerStore.saveMarker(fresh)
        return fresh
    }

    // MARK: - Marker + key-data framing (a single length-prefixed marker,
    // never guessed from fixed offsets, since a UUID-string marker's own
    // byte length is already fixed today but this must not assume that
    // holds forever)

    static func combine(marker: String, keyData: Data) -> Data {
        let markerBytes = Data(marker.utf8)
        var result = Data([UInt8(clamping: markerBytes.count)])
        result.append(markerBytes)
        result.append(keyData)
        return result
    }

    static func splitMarkerAndKeyData(_ data: Data) -> (marker: String, keyData: Data)? {
        guard let lengthByte = data.first else { return nil }
        let length = Int(lengthByte)
        let start = data.startIndex
        guard data.count >= 1 + length else { return nil }
        let markerRange = data.index(start, offsetBy: 1)..<data.index(start, offsetBy: 1 + length)
        guard let marker = String(data: data.subdata(in: markerRange), encoding: .utf8) else { return nil }
        let keyData = data.subdata(in: data.index(start, offsetBy: 1 + length)..<data.endIndex)
        return (marker, keyData)
    }
}
