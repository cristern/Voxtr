import Foundation
import Security

/// Athlete hydration/activation integration slice (transition-plan §5.2):
/// the minimal, installation-scoped "local grant→identity checkpoint"
/// §5.2/§1 of the task brief calls for — a reference to canonical rows,
/// never a parallel identity graph or authorization source.
///
/// WHY THIS EXISTS: `AthleteBackendHydrationAdapter.hydrate(deviceGrantId:)`
/// returns the hydrated target's stable IDs only on a fresh
/// `.hydratedAndAcked` outcome (the GET step actually delivered a
/// payload this call). On a LATER restoration/relaunch attempt, the
/// backend may instead answer `.alreadyCompleted` (the permanent
/// `hydration_outcome` marker short-circuits before ever returning a
/// payload) — which, by construction, carries no target at all (see
/// `AthleteBackendHydrationOutcome.alreadyCompleted`'s own doc comment).
/// Without a separately-persisted checkpoint, a device in exactly this
/// state would have no sound way to know WHICH local
/// workspace/participant/athlete this grant's already-completed
/// hydration belongs to — and guessing (most-recent family, only
/// family on device, etc.) is exactly the "invented data" this task's
/// own brief forbids. This store exists solely to answer that one
/// question honestly: written ONLY once this exact grant's hydration
/// has been both ACK-confirmed AND locally activated (never earlier —
/// see `AthleteBackendConnectionCoordinator`'s own write-ordering doc
/// comment), read only to attempt a LOCAL re-validation
/// (`AthleteConnectionIdentityBindingService.bind(...)` →
/// `AthleteSessionActivationService.activate(...)`, both pure,
/// idempotent, already-canonical lookups) — never trusted as
/// authorization proof on its own, exactly like
/// `AthleteDeviceAuthorizationReceipt`'s own established contract for
/// the pairing side of this same flow.
///
/// NEVER a second identity source: if the local graph this checkpoint
/// points at no longer validates (participant removed/revoked/re-linked
/// since), `bind`/`activate` fail explicitly and the checkpoint is
/// never treated as if it were still true — it only ever narrows "which
/// existing canonical rows to re-check," never replaces that recheck.
///
/// Keychain only, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — same
/// atomic update-then-add-only-if-missing replace (never delete-then-
/// add) as every other secure store in this codebase
/// (`KeychainAthleteDeviceAuthorizationSessionStore`,
/// `KeychainAthleteDeviceAuthorizationReceiptStore`).
public struct AthleteBackendConnectionCheckpoint: Codable, Equatable, Sendable {
    public let deviceGrantId: UUID
    public let workspaceId: UUID
    public let participantId: UUID
    public let athleteId: UUID

    public init(deviceGrantId: UUID, workspaceId: UUID, participantId: UUID, athleteId: UUID) {
        self.deviceGrantId = deviceGrantId
        self.workspaceId = workspaceId
        self.participantId = participantId
        self.athleteId = athleteId
    }
}

public protocol AthleteBackendConnectionCheckpointStoring: Sendable {
    func loadCheckpoint() -> AthleteBackendConnectionCheckpoint?
    func saveCheckpoint(_ checkpoint: AthleteBackendConnectionCheckpoint) throws
    func clearCheckpoint()
}

public enum AthleteBackendConnectionCheckpointStoreError: Error, Equatable {
    case encodingFailed
    case keychainFailure(OSStatus)
}

/// Real Keychain-backed implementation.
public final class KeychainAthleteBackendConnectionCheckpointStore: AthleteBackendConnectionCheckpointStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.voxtr.athlete.backendConnectionCheckpoint",
        account: String = "backend-connection-checkpoint"
    ) {
        self.service = service
        self.account = account
    }

    public func loadCheckpoint() -> AthleteBackendConnectionCheckpoint? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AthleteBackendConnectionCheckpoint.self, from: data)
    }

    public func saveCheckpoint(_ checkpoint: AthleteBackendConnectionCheckpoint) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(checkpoint)
        } catch {
            throw AthleteBackendConnectionCheckpointStoreError.encodingFailed
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
                throw AthleteBackendConnectionCheckpointStoreError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AthleteBackendConnectionCheckpointStoreError.keychainFailure(updateStatus)
        }
    }

    public func clearCheckpoint() {
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
