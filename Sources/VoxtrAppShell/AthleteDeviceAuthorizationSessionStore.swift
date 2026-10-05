import Foundation
import Security

/// Athlete Connection V1 device-authorization session contract (§3.4
/// point 3): secure, device-only persistence for the CURRENT
/// device-authorization session — the bearer token plus its two
/// clocks (`expiresAt` 7-day sliding, `absoluteExpiresAt` 90-day
/// absolute).
///
/// DISTINCT FROM `AthleteDeviceAuthorizationReceipt`
/// (`AthleteDeviceAuthorizationReceiptStore.swift`): that type persists
/// only PAIRING metadata (invitation/request id, display code, and —
/// once known — grant id/recovery deadline) and is explicitly never
/// proof of current authorization; resuming it always requires a
/// fresh backend reconfirmation. THIS store is different in kind: it
/// IS what a fresh, successfully-verified `session_issue`/
/// `session_renew` round trip writes, and
/// `AthleteDeviceAuthorizationSessionManager` DOES use its `expiresAt`
/// directly (without a network call) while the sliding window is
/// still open — but its mere presence past that window is still never
/// treated as proof on its own; the manager always re-verifies with a
/// fresh signature once the sliding window has lapsed, exactly as the
/// contract requires (§3.4 point 2: "never bearer-token possession
/// alone").
///
/// Keychain only, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` —
/// NEVER `UserDefaults` (§3.4 point 3 is explicit about this). Same
/// atomic update-then-add-only-if-missing replace (never delete-then-
/// add) as every other secure store in this codebase
/// (`KeychainAthleteDeviceAuthorizationReceiptStore`,
/// `KeychainParentSessionStore`, `KeychainAthleteDeviceKeyMaterialStore`).
public struct AthleteDeviceAuthorizationSessionRecord: Codable, Equatable, Sendable {
    public let deviceGrantId: UUID
    public let sessionToken: String
    public let expiresAt: Date
    public let absoluteExpiresAt: Date

    public init(deviceGrantId: UUID, sessionToken: String, expiresAt: Date, absoluteExpiresAt: Date) {
        self.deviceGrantId = deviceGrantId
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.absoluteExpiresAt = absoluteExpiresAt
    }
}

public protocol AthleteDeviceAuthorizationSessionStoring: Sendable {
    func loadSession() -> AthleteDeviceAuthorizationSessionRecord?
    func saveSession(_ record: AthleteDeviceAuthorizationSessionRecord) throws
    func clearSession()
}

public enum AthleteDeviceAuthorizationSessionStoreError: Error, Equatable {
    case encodingFailed
    case keychainFailure(OSStatus)
}

/// Real Keychain-backed implementation.
public final class KeychainAthleteDeviceAuthorizationSessionStore: AthleteDeviceAuthorizationSessionStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.voxtr.athlete.deviceAuthorizationSession",
        account: String = "device-authorization-session"
    ) {
        self.service = service
        self.account = account
    }

    public func loadSession() -> AthleteDeviceAuthorizationSessionRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AthleteDeviceAuthorizationSessionRecord.self, from: data)
    }

    public func saveSession(_ record: AthleteDeviceAuthorizationSessionRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw AthleteDeviceAuthorizationSessionStoreError.encodingFailed
        }
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
                throw AthleteDeviceAuthorizationSessionStoreError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AthleteDeviceAuthorizationSessionStoreError.keychainFailure(updateStatus)
        }
    }

    public func clearSession() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
