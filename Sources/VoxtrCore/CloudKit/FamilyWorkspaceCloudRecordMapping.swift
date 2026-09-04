import CloudKit
import Foundation

/// Athlete Connection Foundation B2.1: the deterministic, provider-neutral
/// mapping between a Vǫxtr `FamilyWorkspace`'s stable identity and its
/// CloudKit sharing-root `CKRecord`.
///
/// PROVIDER-NEUTRAL BY DESIGN: `VoxtrCore` cannot import `VoxtrParentDomain`
/// (zero package dependencies — see `FamilyWorkspaceCloudZoneIdentifier`'s
/// own precedent), so this type never sees the real `FamilyWorkspace`
/// SwiftData model — only its stable `UUID`. The caller (`VoxtrAppShell`,
/// which is allowed to see every module) is responsible for extracting
/// `FamilyWorkspace.id` and handing it in.
///
/// SCOPE: only what the FamilyWorkspace CKRecord needs to (1) identify the
/// Vǫxtr workspace by stable UUID and (2) support later participant-side
/// reconstruction/linking (B2.2). Deliberately does NOT mirror every
/// SwiftData property — no `displayName`, `technicalOwnerAccountId`,
/// `status`, or timestamps. `technicalOwnerAccountId` in particular is
/// account-binding local state that must never be written into the shared
/// zone (see `CloudKitTransport`'s own "CloudKit transport ≠ domain owner"
/// boundary). If a later slice's participant UI needs more (e.g. a
/// display name to show during share acceptance), add it explicitly then
/// — this stays intentionally minimal until something real needs more.
public enum FamilyWorkspaceCloudRecordSchema {

    /// CKRecord type name for the FamilyWorkspace sharing root.
    public static let recordType = "FamilyWorkspace"

    /// Versions the SHAPE of this CKRecord mapping itself — independent
    /// of SwiftData's own `FamilyWorkspace.schemaVersion`, which versions
    /// the local persisted model, not what gets written to CloudKit. Bump
    /// this only when the record's field set changes in a way a reader
    /// needs to know about.
    public static let mappingVersion: Int64 = 1

    public static let workspaceIdFieldKey = "workspaceId"
    public static let mappingVersionFieldKey = "mappingVersion"

    /// Deterministic record NAME from the workspace's own stable `UUID` —
    /// the same `workspaceId` always produces the same name, so retries
    /// and repeated "ensure" calls address the same record rather than
    /// minting a new one. Distinct suffix from
    /// `FamilyWorkspaceCloudZoneIdentifier.zoneName(forWorkspace:)` (which
    /// names the ZONE, not a record within it) so the two can never be
    /// confused if ever logged/compared side by side.
    public static func recordName(forWorkspace workspaceId: UUID) -> String {
        "voxtr.family.\(workspaceId.uuidString).root"
    }
}

/// The minimal, provider-neutral payload this mapping round-trips —
/// exactly the stable identity a FamilyWorkspace CKRecord needs to carry.
/// `Sendable`: holds only a `UUID`, itself `Sendable`.
public struct FamilyWorkspaceCloudRecordPayload: Equatable, Sendable {
    public let workspaceId: UUID

    public init(workspaceId: UUID) {
        self.workspaceId = workspaceId
    }
}

/// Pure construction/decoding only — no CloudKit I/O. `CKRecord`,
/// `CKRecord.ID`, and `CKRecordZone.ID` are plain, locally-constructible
/// value/model objects (unlike `CKContainer`/`CKDatabase`) — building one
/// does not touch CloudKit's runtime or require an entitlement, so every
/// function here is safe to call from a unit test. See
/// `FamilyWorkspaceOwnerShareCoordinator` for the actual save/fetch I/O
/// that turns these into real CloudKit state.
public enum FamilyWorkspaceCloudRecordMapping {

    /// The record's deterministic identity WITHIN a given zone. Callers
    /// pass in the zone ID (owner-side callers use
    /// `FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace:)`;
    /// participant-side callers, per that type's own doc comment, must
    /// use whatever real `CKRecordZone.ID` CloudKit itself reported —
    /// this mapping does not decide that, it only places the record name
    /// deterministically once a zone ID is already known).
    public static func recordID(forWorkspace workspaceId: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: FamilyWorkspaceCloudRecordSchema.recordName(forWorkspace: workspaceId), zoneID: zoneID)
    }

    public static func makeRecord(for payload: FamilyWorkspaceCloudRecordPayload, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: FamilyWorkspaceCloudRecordSchema.recordType,
            recordID: recordID(forWorkspace: payload.workspaceId, zoneID: zoneID)
        )
        // No explicit `as CKRecordValue`/`CKRecordValueProtocol` cast:
        // `String`/`Int64` already satisfy CKRecord's subscript value
        // requirement implicitly (the standard, ubiquitous CloudKit
        // idiom) — naming the exact protocol type here would only add a
        // second, unverifiable guess about this SDK's exact type name.
        record[FamilyWorkspaceCloudRecordSchema.workspaceIdFieldKey] = payload.workspaceId.uuidString
        record[FamilyWorkspaceCloudRecordSchema.mappingVersionFieldKey] = FamilyWorkspaceCloudRecordSchema.mappingVersion
        return record
    }

    public enum DecodeError: Error, Equatable {
        case unexpectedRecordType(String)
        case missingWorkspaceId
        case invalidWorkspaceId(String)
    }

    /// The inverse of `makeRecord(for:zoneID:)` — reconstructs the stable
    /// identity from a record CloudKit handed back (fetched, or reported
    /// via `CKSyncEngine`/share-acceptance). B2.2's participant-side
    /// linking is expected to use this directly rather than re-deriving
    /// field access itself.
    public static func payload(from record: CKRecord) throws -> FamilyWorkspaceCloudRecordPayload {
        guard record.recordType == FamilyWorkspaceCloudRecordSchema.recordType else {
            throw DecodeError.unexpectedRecordType(record.recordType)
        }
        guard let raw = record[FamilyWorkspaceCloudRecordSchema.workspaceIdFieldKey] as? String else {
            throw DecodeError.missingWorkspaceId
        }
        guard let workspaceId = UUID(uuidString: raw) else {
            throw DecodeError.invalidWorkspaceId(raw)
        }
        return FamilyWorkspaceCloudRecordPayload(workspaceId: workspaceId)
    }
}
