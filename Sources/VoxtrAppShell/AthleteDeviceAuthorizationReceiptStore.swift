import Foundation
import Security

/// Athlete Connection V1 (backend device authorization, review round 2):
/// the minimal, installation-scoped metadata needed to RESUME a pairing
/// attempt after the app is interrupted (killed, backgrounded past
/// suspension, crashed) between submitting a connection request and
/// completing the claim.
///
/// METADATA, NEVER PROOF OF CURRENT ACCESS: nothing in this type is
/// ever treated as authorization by this app. `grantId`/`recoveryDeadline`
/// exist only so the UI can show an honest "you can still finish this"
/// vs. "this has expired" message — the backend alone is authoritative
/// for whether a recovery attempt is still within its own 24-hour window
/// (Normative Security Contract §2 D2); this app never enforces or
/// trusts the locally-stored deadline as if it were that authority.
///
/// NEVER a consumed challenge as recovery authority: this type
/// deliberately has no `challengeId`/`nonce`/`signature` field at all —
/// those are single-use and already consumed by the time a resume could
/// matter, so there is nothing here to tempt a caller into replaying
/// stale proof material instead of requesting a fresh challenge.
public struct AthleteDeviceAuthorizationReceipt: Codable, Equatable {
    public let invitationId: UUID
    public let connectionRequestId: UUID
    /// Present only once `claim-submit` has actually returned `granted`/
    /// `already_granted` for this attempt — `nil` before that.
    public let grantId: UUID?
    public let recoveryDeadline: Date?

    public init(invitationId: UUID, connectionRequestId: UUID, grantId: UUID? = nil, recoveryDeadline: Date? = nil) {
        self.invitationId = invitationId
        self.connectionRequestId = connectionRequestId
        self.grantId = grantId
        self.recoveryDeadline = recoveryDeadline
    }
}

public protocol AthleteDeviceAuthorizationReceiptStoring: Sendable {
    func loadReceipt() -> AthleteDeviceAuthorizationReceipt?
    func saveReceipt(_ receipt: AthleteDeviceAuthorizationReceipt) throws
    func clearReceipt()
}

public enum AthleteDeviceAuthorizationReceiptStoreError: Error, Equatable {
    case encodingFailed
    case keychainFailure(OSStatus)
}

/// Real Keychain-backed implementation — device-only, matching every
/// other Keychain-backed store in this codebase
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, atomic
/// update-then-add-only-if-missing replace, never delete-then-add).
public final class KeychainAthleteDeviceAuthorizationReceiptStore: AthleteDeviceAuthorizationReceiptStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.voxtr.athlete.deviceAuthorizationReceipt",
        account: String = "pairing-attempt-receipt"
    ) {
        self.service = service
        self.account = account
    }

    public func loadReceipt() -> AthleteDeviceAuthorizationReceipt? {
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
        return try? decoder.decode(AthleteDeviceAuthorizationReceipt.self, from: data)
    }

    public func saveReceipt(_ receipt: AthleteDeviceAuthorizationReceipt) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw AthleteDeviceAuthorizationReceiptStoreError.encodingFailed
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
                throw AthleteDeviceAuthorizationReceiptStoreError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AthleteDeviceAuthorizationReceiptStoreError.keychainFailure(updateStatus)
        }
    }

    public func clearReceipt() {
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
