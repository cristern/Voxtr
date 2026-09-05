import CloudKit
import Foundation

/// Athlete Connection Foundation B2.6: the deterministic, provider-neutral
/// mapping between a Parent's "Connect Athlete App" action and the
/// EXISTING Vǫxtr identity (`WorkspaceParticipant`/`AthleteProfile`) it
/// intends to connect.
///
/// PURPOSE (the architectural gap B2.6 closes): B2.1's `CKShare` is
/// rooted on the FamilyWorkspace record — one share per workspace, not
/// one per athlete — but a family may contain multiple Athlete
/// participants (see `AthleteConnectionIdentityBindingService`'s own
/// B2.3 doc comment on this exact gap: "a workspaceId alone carries no
/// signal about WHICH athlete... this is a real architectural gap").
/// This record is what actually carries that missing signal across the
/// CloudKit transport boundary, as a small CHILD record parented to the
/// FamilyWorkspace root record (so it is included in the same shared
/// hierarchy CloudKit delivers to an accepting participant — see Apple's
/// own documented "share the root record's hierarchy" contract) —
/// deliberately NOT a new field bolted onto `FamilyWorkspaceCloudRecordMapping`'s
/// own root record, which stays exactly what B2.1 established (durable,
/// effectively-immutable workspace identity, never mutated by a routine
/// per-invitation Parent action).
///
/// SCOPE: represents ONLY "which existing Vǫxtr participant/athlete does
/// the CURRENT pending invitation intend to connect" — nothing about
/// CKShare.Participant identity, no email/name, no CloudKit ownerName.
/// One record per workspace (deterministic ID, exactly like
/// `FamilyWorkspaceCloudRecordMapping`'s own root record) — this
/// slice's own bounded scope explicitly does not support multiple
/// SIMULTANEOUSLY pending invitations to different athletes on the same
/// share; see `AthleteConnectionOwnerHandoffService`'s own doc comment
/// for that documented limitation. A later slice that needs true
/// concurrent multi-athlete invitations would extend this to a
/// per-participant keyed record rather than reusing this one as-is.
///
/// PROVIDER-NEUTRAL BY DESIGN: mirrors `FamilyWorkspaceCloudRecordMapping`'s
/// own reasoning exactly — `VoxtrCore` cannot import `VoxtrParentDomain`/
/// `VoxtrAthleteDomain`, so this type only ever sees stable `UUID`s, never
/// the real `WorkspaceParticipant`/`AthleteProfile` SwiftData models.
public enum AthleteConnectionInvitationCloudRecordSchema {

    /// CKRecord type name for the invitation-intent mapping record.
    public static let recordType = "AthleteConnectionInvitation"

    /// Versions the SHAPE of this CKRecord mapping — independent of any
    /// SwiftData schema version, matching `FamilyWorkspaceCloudRecordSchema
    /// .mappingVersion`'s own reasoning exactly.
    public static let mappingVersion: Int64 = 1

    public static let workspaceIdFieldKey = "workspaceId"
    public static let intendedParticipantIdFieldKey = "intendedParticipantId"
    public static let intendedAthleteIdFieldKey = "intendedAthleteId"
    public static let mappingVersionFieldKey = "mappingVersion"

    /// Deterministic record NAME from the workspace's own stable `UUID` —
    /// same one-per-workspace determinism as `FamilyWorkspaceCloudRecordSchema
    /// .recordName(forWorkspace:)`, with a distinct suffix so the two can
    /// never be confused. Repeated "Connect Athlete App" actions for the
    /// SAME workspace converge on updating this SAME record rather than
    /// minting a new one each time.
    public static func recordName(forWorkspace workspaceId: UUID) -> String {
        "voxtr.family.\(workspaceId.uuidString).athleteConnectionInvitation"
    }
}

/// The minimal, provider-neutral payload this mapping round-trips.
/// `Sendable`: holds only `UUID`s, themselves `Sendable`.
public struct AthleteConnectionInvitationCloudRecordPayload: Equatable, Sendable {
    public let workspaceId: UUID
    /// The EXISTING `WorkspaceParticipant.id` this invitation intends to
    /// connect — the actual discriminator `AthleteConnectionIdentityBindingService`
    /// (B2.3) uses to resolve the exact participant, never an inferred
    /// or heuristically-chosen one.
    public let intendedParticipantId: UUID
    /// The `AthleteProfile.id` (`AthleteId.rawValue`) that participant is
    /// linked to — redundant with what the resolved `WorkspaceParticipant
    /// .linkedAthleteId` would already say, kept here only so the
    /// Athlete-side orchestration (`AthleteConnectionLifecycleService`)
    /// can perform the canonical `.invited → .active` transition
    /// (`AcceptWorkspaceInvitationService.accept(athleteId:...)`) without
    /// a separate lookup, and so B2.3 can cross-validate consistency.
    public let intendedAthleteId: UUID

    public init(workspaceId: UUID, intendedParticipantId: UUID, intendedAthleteId: UUID) {
        self.workspaceId = workspaceId
        self.intendedParticipantId = intendedParticipantId
        self.intendedAthleteId = intendedAthleteId
    }
}

/// Pure construction/decoding only — no CloudKit I/O, mirroring
/// `FamilyWorkspaceCloudRecordMapping`'s own established shape exactly.
public enum AthleteConnectionInvitationCloudRecordMapping {

    public static func recordID(forWorkspace workspaceId: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: AthleteConnectionInvitationCloudRecordSchema.recordName(forWorkspace: workspaceId), zoneID: zoneID)
    }

    /// `parentRecordID`: the FamilyWorkspace root record's own `CKRecord
    /// .ID` — REQUIRED so this record is included in the shared
    /// hierarchy CloudKit delivers on acceptance (a record with no
    /// parent chain to the share's root is never shared, even in the
    /// same zone). Always the SAME zone as `parentRecordID` — this
    /// mapping never spans zones.
    public static func makeRecord(for payload: AthleteConnectionInvitationCloudRecordPayload, zoneID: CKRecordZone.ID, parentRecordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(
            recordType: AthleteConnectionInvitationCloudRecordSchema.recordType,
            recordID: recordID(forWorkspace: payload.workspaceId, zoneID: zoneID)
        )
        apply(payload, to: record)
        // `record.parent` (a `CKRecord.Reference`), not the
        // `setParent(_:)` convenience overload — the plain property
        // assignment is CloudKit's original, always-available API for
        // establishing hierarchy, avoiding any doubt about a specific
        // convenience overload's exact availability. `.none` action:
        // this mapping record's lifecycle is owned by
        // `AthleteConnectionOwnerHandoffService`, never implicitly
        // deleted as a side effect of the parent record's own deletion.
        record.parent = CKRecord.Reference(recordID: parentRecordID, action: .none)
        return record
    }

    /// Applies (or re-applies, on an already-fetched/reused record) the
    /// payload's field values — factored out so `ensureInvitationIntent(...)`
    /// can update an EXISTING fetched record (preserving its change tag)
    /// with a NEW intended participant/athlete, exactly the way
    /// `FamilyWorkspaceOwnerShareCoordinator.ensureRootRecord`'s own
    /// fetch-first pattern reuses a fetched record rather than always
    /// constructing fresh.
    public static func apply(_ payload: AthleteConnectionInvitationCloudRecordPayload, to record: CKRecord) {
        record[AthleteConnectionInvitationCloudRecordSchema.workspaceIdFieldKey] = payload.workspaceId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.intendedParticipantIdFieldKey] = payload.intendedParticipantId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.intendedAthleteIdFieldKey] = payload.intendedAthleteId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.mappingVersionFieldKey] = AthleteConnectionInvitationCloudRecordSchema.mappingVersion
    }

    public enum DecodeError: Error, Equatable {
        case unexpectedRecordType(String)
        case missingWorkspaceId
        case invalidWorkspaceId(String)
        case missingIntendedParticipantId
        case invalidIntendedParticipantId(String)
        case missingIntendedAthleteId
        case invalidIntendedAthleteId(String)
    }

    /// The inverse of `makeRecord(for:zoneID:parentRecordID:)` — the
    /// Athlete-side accepted-share flow (B2.2) uses this directly rather
    /// than re-deriving field access itself, mirroring
    /// `FamilyWorkspaceCloudRecordMapping.payload(from:)`'s own
    /// precedent exactly.
    public static func payload(from record: CKRecord) throws -> AthleteConnectionInvitationCloudRecordPayload {
        guard record.recordType == AthleteConnectionInvitationCloudRecordSchema.recordType else {
            throw DecodeError.unexpectedRecordType(record.recordType)
        }
        guard let rawWorkspaceId = record[AthleteConnectionInvitationCloudRecordSchema.workspaceIdFieldKey] as? String else {
            throw DecodeError.missingWorkspaceId
        }
        guard let workspaceId = UUID(uuidString: rawWorkspaceId) else {
            throw DecodeError.invalidWorkspaceId(rawWorkspaceId)
        }
        guard let rawParticipantId = record[AthleteConnectionInvitationCloudRecordSchema.intendedParticipantIdFieldKey] as? String else {
            throw DecodeError.missingIntendedParticipantId
        }
        guard let intendedParticipantId = UUID(uuidString: rawParticipantId) else {
            throw DecodeError.invalidIntendedParticipantId(rawParticipantId)
        }
        guard let rawAthleteId = record[AthleteConnectionInvitationCloudRecordSchema.intendedAthleteIdFieldKey] as? String else {
            throw DecodeError.missingIntendedAthleteId
        }
        guard let intendedAthleteId = UUID(uuidString: rawAthleteId) else {
            throw DecodeError.invalidIntendedAthleteId(rawAthleteId)
        }
        return AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: workspaceId,
            intendedParticipantId: intendedParticipantId,
            intendedAthleteId: intendedAthleteId
        )
    }
}
