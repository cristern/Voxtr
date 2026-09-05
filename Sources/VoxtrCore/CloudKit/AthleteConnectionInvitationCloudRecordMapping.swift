import CloudKit
import Foundation

/// Athlete Connection Foundation B2.6 (PR #68 architecture follow-up):
/// ONE IMMUTABLE RECORD PER INVITATION — this is both the fix for the
/// "workspace-wide mutable intent record" correctness defect AND the
/// carrier for the minimum cross-device identity projection a fresh
/// Athlete device needs to hydrate before B2.3/B2.4 can run at all.
///
/// WHY ONE RECORD PER INVITATION (not one per workspace): the original
/// B2.6 design kept a single, DETERMINISTIC-BY-WORKSPACE record that
/// each "Connect Athlete App" action overwrote with the CURRENT
/// intended participant/athlete. Because B2.1's `CKShare` is also
/// reused (one per workspace, idempotent), that share's own URL is
/// IDENTICAL across invitations — CloudKit gives no way to distinguish
/// "the link sent for athlete A" from "the link sent for athlete B" once
/// both point at the same reused share. A later invitation could
/// therefore silently retarget an earlier, still-pending one.
///
/// THE FIX: this record is now the ROOT of its OWN, freshly-created
/// `CKShare` (`FamilyWorkspaceOwnerShareCoordinator.createInvitationShare`),
/// with a randomly-generated (never deterministic, never reused)
/// identity. Accepting invitation A's share can only ever deliver
/// invitation A's own record — `CKShare.Metadata.hierarchicalRootRecordID`
/// (Apple's own guaranteed-delivered identifier, already relied on by
/// this coordinator) IS the token; nothing needs to be invented that
/// CloudKit cannot actually hand back. Creating invitation B is a
/// completely independent record/share pair — it can never touch
/// invitation A's record. No `CKShare.Participant`/user-identity
/// resolution is needed, and none is used: this mechanism relies solely
/// on record-hierarchy identity, exactly like every other CKRecord this
/// codebase already fetches by ID.
///
/// This record is deliberately NOT parented to the FamilyWorkspace root
/// record (B2.1) any more — it is now its own independent, top-level
/// shareable record, living in the SAME custom zone
/// (`FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace:)`) so
/// no new zone-creation/entitlement surface is introduced, but sharing
/// hierarchy no longer connects it to B2.1's own (still-idempotent,
/// still-reusable) FamilyWorkspace share at all. B2.1's own root
/// record/share are UNCHANGED by this file and remain available for
/// whatever later, genuinely family-wide sharing scope needs them.
///
/// CROSS-DEVICE IDENTITY HYDRATION (the other half of this record's
/// job): B2.3 (`AthleteConnectionIdentityBindingService`) resolves
/// against `FamilyRestorationService.restoreState()` — the SAME local
/// SwiftData graph the ParentApp uses. On a FRESH Athlete-device
/// install, none of that graph exists yet: no `ParentProfile`, no
/// `FamilyWorkspace`, no `WorkspaceParticipant`, no `AthleteProfile`.
/// This record therefore also carries the MINIMUM projection of each of
/// those an Athlete device needs to construct a graph that will
/// actually satisfy `FamilyRestorationService`'s own consistency rules
/// (exactly one parent, one workspace, one active `.workspaceOwner`
/// participant, the intended `.athlete` participant correctly linked,
/// and one `AthleteAccessGrant` per athlete owned by that sole owner
/// participant) — see `AthleteIdentityHydrationService`, the ONLY
/// consumer that turns this payload into real local `@Model` rows, via
/// find-by-stable-ID-or-create (never a second identity, never a
/// heuristic match).
///
/// SCOPE DISCIPLINE: only fields those FIVE entities' own non-optional
/// initializers actually require, or that a genuinely non-fabricated
/// identity demands (a real name, not a placeholder — see
/// `AthleteIdentityHydrationService`'s own doc comment for why
/// fabricating these would violate "no invented fallback content
/// presented as truth"). Deliberately excludes: `AthleteProfile
/// .isArchived` (a freshly-invited athlete is presumed active; hydration
/// leaves this at its model default, `false`, and the very next
/// `AcceptWorkspaceInvitationService`/`AthleteEligibilityFacts` read
/// sees that same freshly-created row, so nothing is out of sync),
/// `familyName`/`preferredName`/`avatarAssetKey` (optional on the model
/// itself — omitting them is a truthful "not provided," not a
/// fabrication), and anything Planning/Training/Reflection-shaped
/// (explicitly out of scope for this connection proof).
public enum AthleteConnectionInvitationCloudRecordSchema {

    public static let recordType = "AthleteConnectionInvitation"

    /// Versions the SHAPE of this CKRecord mapping. Bumped to 2 for the
    /// PR #68 follow-up: v1 records (workspace-deterministic, no
    /// hydration fields, `.parent`-linked) are a different shape
    /// entirely and are never read by this version's `payload(from:)`.
    public static let mappingVersion: Int64 = 2

    public static let workspaceIdFieldKey = "workspaceId"
    public static let intendedParticipantIdFieldKey = "intendedParticipantId"
    public static let intendedAthleteIdFieldKey = "intendedAthleteId"
    public static let parentIdFieldKey = "parentId"
    public static let parentGivenNameFieldKey = "parentGivenName"
    public static let workspaceDisplayNameFieldKey = "workspaceDisplayName"
    public static let ownerParticipantIdFieldKey = "ownerParticipantId"
    public static let athleteGivenNameFieldKey = "athleteGivenName"
    public static let athleteBirthDateISOFieldKey = "athleteBirthDateISO"
    public static let athleteTimeZoneIdFieldKey = "athleteTimeZoneId"
    public static let athleteDevelopmentStageFieldKey = "athleteDevelopmentStage"
    public static let mappingVersionFieldKey = "mappingVersion"

    /// Deterministic ONLY in the sense of "always the same shape" — the
    /// `invitationId` itself is a freshly-generated `UUID` per
    /// invitation (see `AthleteConnectionInvitationCloudRecordMapping
    /// .makeRecord`), never derived from `workspaceId` alone. This is
    /// what replaces the old `recordName(forWorkspace:)` — there is no
    /// longer a "the" invitation record for a workspace, only "an"
    /// invitation record per invitation.
    public static func recordName(forInvitation invitationId: UUID) -> String {
        "voxtr.family.invitation.\(invitationId.uuidString)"
    }
}

/// The full payload one invitation record carries — the discriminator
/// fields (unchanged from the original design) plus the minimum
/// cross-device hydration projection (new). `Sendable`: holds only
/// `UUID`/`String`, themselves `Sendable`.
public struct AthleteConnectionInvitationCloudRecordPayload: Equatable, Sendable {
    public let workspaceId: UUID
    /// The EXISTING `WorkspaceParticipant.id` this invitation intends to
    /// connect — the actual discriminator `AthleteConnectionIdentityBindingService`
    /// (B2.3) binds against.
    public let intendedParticipantId: UUID
    /// The `AthleteProfile.id` (`AthleteId.rawValue`) that participant is
    /// linked to.
    public let intendedAthleteId: UUID
    /// The sole `ParentProfile.id` on the owner's device — hydrated
    /// as-is (find-by-ID-or-create) on the Athlete device.
    public let parentId: UUID
    /// The Parent's own real, non-fabricated given name —
    /// `ParentProfile.givenName` is a required, non-empty field; a
    /// placeholder here would be invented content presented as truth.
    public let parentGivenName: String
    /// `FamilyWorkspace.displayName` — same non-fabrication reasoning.
    public let workspaceDisplayName: String
    /// The sole `.workspaceOwner` `WorkspaceParticipant.id` on the
    /// owner's device.
    public let ownerParticipantId: UUID
    /// `AthleteProfile.givenName` — the SELECTED existing athlete's own
    /// real name.
    public let athleteGivenName: String
    /// `AthleteProfile.birthDate`, as `LocalDate.isoString` — plain
    /// `String` transport, matching every other ISO-date CKRecord field
    /// convention already used in this codebase's own SwiftData storage
    /// (see `AthleteProfile.birthDateRaw`'s own doc comment).
    public let athleteBirthDateISO: String
    /// `AthleteProfile.timeZoneId.rawValue`.
    public let athleteTimeZoneId: String
    /// `AthleteProfile.developmentStage.rawValue`.
    public let athleteDevelopmentStage: String

    public init(
        workspaceId: UUID,
        intendedParticipantId: UUID,
        intendedAthleteId: UUID,
        parentId: UUID,
        parentGivenName: String,
        workspaceDisplayName: String,
        ownerParticipantId: UUID,
        athleteGivenName: String,
        athleteBirthDateISO: String,
        athleteTimeZoneId: String,
        athleteDevelopmentStage: String
    ) {
        self.workspaceId = workspaceId
        self.intendedParticipantId = intendedParticipantId
        self.intendedAthleteId = intendedAthleteId
        self.parentId = parentId
        self.parentGivenName = parentGivenName
        self.workspaceDisplayName = workspaceDisplayName
        self.ownerParticipantId = ownerParticipantId
        self.athleteGivenName = athleteGivenName
        self.athleteBirthDateISO = athleteBirthDateISO
        self.athleteTimeZoneId = athleteTimeZoneId
        self.athleteDevelopmentStage = athleteDevelopmentStage
    }
}

/// Pure construction/decoding only — no CloudKit I/O.
public enum AthleteConnectionInvitationCloudRecordMapping {

    /// `invitationId`: freshly generated by the caller
    /// (`FamilyWorkspaceOwnerShareCoordinator.createInvitationShare`) —
    /// this mapping never generates its own IDs, matching every other
    /// pure mapping type in this codebase.
    public static func recordID(forInvitation invitationId: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: AthleteConnectionInvitationCloudRecordSchema.recordName(forInvitation: invitationId), zoneID: zoneID)
    }

    /// No `parentRecordID` any more — see this file's own doc comment
    /// for why this record is now an independent, top-level shareable
    /// record rather than a child of B2.1's FamilyWorkspace root.
    public static func makeRecord(invitationId: UUID, payload: AthleteConnectionInvitationCloudRecordPayload, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: AthleteConnectionInvitationCloudRecordSchema.recordType,
            recordID: recordID(forInvitation: invitationId, zoneID: zoneID)
        )
        apply(payload, to: record)
        return record
    }

    public static func apply(_ payload: AthleteConnectionInvitationCloudRecordPayload, to record: CKRecord) {
        record[AthleteConnectionInvitationCloudRecordSchema.workspaceIdFieldKey] = payload.workspaceId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.intendedParticipantIdFieldKey] = payload.intendedParticipantId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.intendedAthleteIdFieldKey] = payload.intendedAthleteId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.parentIdFieldKey] = payload.parentId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.parentGivenNameFieldKey] = payload.parentGivenName
        record[AthleteConnectionInvitationCloudRecordSchema.workspaceDisplayNameFieldKey] = payload.workspaceDisplayName
        record[AthleteConnectionInvitationCloudRecordSchema.ownerParticipantIdFieldKey] = payload.ownerParticipantId.uuidString
        record[AthleteConnectionInvitationCloudRecordSchema.athleteGivenNameFieldKey] = payload.athleteGivenName
        record[AthleteConnectionInvitationCloudRecordSchema.athleteBirthDateISOFieldKey] = payload.athleteBirthDateISO
        record[AthleteConnectionInvitationCloudRecordSchema.athleteTimeZoneIdFieldKey] = payload.athleteTimeZoneId
        record[AthleteConnectionInvitationCloudRecordSchema.athleteDevelopmentStageFieldKey] = payload.athleteDevelopmentStage
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
        case missingParentId
        case invalidParentId(String)
        case missingParentGivenName
        case missingWorkspaceDisplayName
        case missingOwnerParticipantId
        case invalidOwnerParticipantId(String)
        case missingAthleteGivenName
        case missingAthleteBirthDateISO
        case missingAthleteTimeZoneId
        case missingAthleteDevelopmentStage
    }

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
        guard let rawParentId = record[AthleteConnectionInvitationCloudRecordSchema.parentIdFieldKey] as? String else {
            throw DecodeError.missingParentId
        }
        guard let parentId = UUID(uuidString: rawParentId) else {
            throw DecodeError.invalidParentId(rawParentId)
        }
        guard let parentGivenName = record[AthleteConnectionInvitationCloudRecordSchema.parentGivenNameFieldKey] as? String else {
            throw DecodeError.missingParentGivenName
        }
        guard let workspaceDisplayName = record[AthleteConnectionInvitationCloudRecordSchema.workspaceDisplayNameFieldKey] as? String else {
            throw DecodeError.missingWorkspaceDisplayName
        }
        guard let rawOwnerParticipantId = record[AthleteConnectionInvitationCloudRecordSchema.ownerParticipantIdFieldKey] as? String else {
            throw DecodeError.missingOwnerParticipantId
        }
        guard let ownerParticipantId = UUID(uuidString: rawOwnerParticipantId) else {
            throw DecodeError.invalidOwnerParticipantId(rawOwnerParticipantId)
        }
        guard let athleteGivenName = record[AthleteConnectionInvitationCloudRecordSchema.athleteGivenNameFieldKey] as? String else {
            throw DecodeError.missingAthleteGivenName
        }
        guard let athleteBirthDateISO = record[AthleteConnectionInvitationCloudRecordSchema.athleteBirthDateISOFieldKey] as? String else {
            throw DecodeError.missingAthleteBirthDateISO
        }
        guard let athleteTimeZoneId = record[AthleteConnectionInvitationCloudRecordSchema.athleteTimeZoneIdFieldKey] as? String else {
            throw DecodeError.missingAthleteTimeZoneId
        }
        guard let athleteDevelopmentStage = record[AthleteConnectionInvitationCloudRecordSchema.athleteDevelopmentStageFieldKey] as? String else {
            throw DecodeError.missingAthleteDevelopmentStage
        }
        return AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: workspaceId,
            intendedParticipantId: intendedParticipantId,
            intendedAthleteId: intendedAthleteId,
            parentId: parentId,
            parentGivenName: parentGivenName,
            workspaceDisplayName: workspaceDisplayName,
            ownerParticipantId: ownerParticipantId,
            athleteGivenName: athleteGivenName,
            athleteBirthDateISO: athleteBirthDateISO,
            athleteTimeZoneId: athleteTimeZoneId,
            athleteDevelopmentStage: athleteDevelopmentStage
        )
    }
}
