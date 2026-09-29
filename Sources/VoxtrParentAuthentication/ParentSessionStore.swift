import Foundation
import Security

/// Stores the opaque Parent session token — and ONLY the token, nothing
/// else (no expiry, no Parent identity, no metadata of any kind) — per
/// cristern/Voxtr Docs/Architecture/AthleteConnectionV1-
/// ParentAuthenticationContract.md §2.8: `ThisDeviceOnly` accessibility,
/// never `UserDefaults`, never synced via iCloud Keychain, never
/// SwiftData. Injectable so deterministic tests never touch the real
/// Keychain via a fake conforming type; `KeychainParentSessionStore`
/// below is the real, production implementation.
public protocol ParentSessionStoring: Sendable {
    func loadToken() -> String?
    func saveToken(_ token: String) throws
    func deleteToken()
}

public struct ParentSessionStoreError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// Real Keychain-backed implementation. `service`/`account` together
/// identify exactly one Keychain item — the current session token, if
/// any. `final` with only `Sendable`, immutable (`let`) stored
/// properties, so this is safely `Sendable` without `@unchecked`.
public final class KeychainParentSessionStore: ParentSessionStoring, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.voxtr.parent.session",
        account: String = "parent-session-token"
    ) {
        self.service = service
        self.account = account
    }

    public func loadToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces any existing token with `token` — the ATOMIC replacement
    /// this contract requires on a successful sign-in or rotation: a
    /// single `SecItemUpdate` call when an item already exists (never a
    /// delete-then-add pair, which would have a real window with no
    /// item at all), falling back to `SecItemAdd` only the very first
    /// time no item exists yet.
    public func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw ParentSessionStoreError(status: errSecParam)
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
                throw ParentSessionStoreError(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ParentSessionStoreError(status: updateStatus)
        }
    }

    public func deleteToken() {
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
