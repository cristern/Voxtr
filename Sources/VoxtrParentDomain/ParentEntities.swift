import Foundation
import SwiftData
import VoxtrCoreContracts

// MARK: - ParentProfile (v1.3 Section 7.1)

@Model
public final class ParentProfile {
    @Attribute(.unique) public var id: UUID
    public var accountId: String
    public var givenName: String
    public var familyName: String?
    public var preferredName: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        accountId: AccountId,
        givenName: String,
        familyName: String? = nil,
        preferredName: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...80).contains(givenName.count), "givenName must be 1-80 characters (v1.3 Section 7.1)")
        self.id = id
        self.accountId = accountId.rawValue
        self.givenName = givenName
        self.familyName = familyName
        self.preferredName = preferredName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - FamilyWorkspace (v1.3 Section 7.2 / DDM-006)

/// CloudKit sharing root and family collaboration boundary.
@Model
public final class FamilyWorkspace {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var technicalOwnerAccountId: String
    public var status: String // active, archived, migrationRequired (v1.3 Section 7.2)

    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: WorkspaceId = WorkspaceId(),
        displayName: String,
        technicalOwnerAccountId: AccountId,
        status: String = "active",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...100).contains(displayName.count), "displayName must be 1-100 characters (v1.3 Section 7.2)")
        self.id = id.rawValue
        self.displayName = displayName
        self.technicalOwnerAccountId = technicalOwnerAccountId.rawValue
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var workspaceId: WorkspaceId { WorkspaceId(rawValue: id) }
}

// MARK: - WorkspaceParticipant (v1.3 Section 7.3)

@Model
public final class WorkspaceParticipant {
    @Attribute(.unique) public var id: UUID
    public var workspaceId: UUID
    public var accountId: String
    public var role: WorkspaceRole
    public var state: ParticipantState
    public var linkedAthleteId: UUID?
    public var invitedBy: UUID?
    public var invitedAt: Date?
    public var acceptedAt: Date?
    public var declinedAt: Date?
    public var revokedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    /// INVARIANT: after a participant leaves `.invited`, exactly one
    /// of `acceptedAt`/`declinedAt`/`revokedAt` is populated — never
    /// more than one, and never a stale value left over from an
    /// earlier transition. Each of the three terminal states
    /// (`.active`, `.declined`, `.revoked`) corresponds to exactly one
    /// of these three fields.
    public init(
        id: UUID = UUID(),
        workspaceId: WorkspaceId,
        accountId: AccountId,
        role: WorkspaceRole,
        state: ParticipantState = .invited,
        linkedAthleteId: AthleteId? = nil,
        invitedBy: ActorId? = nil,
        invitedAt: Date? = nil,
        acceptedAt: Date? = nil,
        declinedAt: Date? = nil,
        revokedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition(role != .athlete || linkedAthleteId != nil, "Athlete role requires linkedAthleteId (v1.3 Section 7.3)")
        self.id = id
        self.workspaceId = workspaceId.rawValue
        self.accountId = accountId.rawValue
        self.role = role
        self.state = state
        self.linkedAthleteId = linkedAthleteId?.rawValue
        self.invitedBy = invitedBy?.rawValue
        self.invitedAt = invitedAt
        self.acceptedAt = acceptedAt
        self.declinedAt = declinedAt
        self.revokedAt = revokedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - FamilyMembership (v1.3 Section 7.4)

/// v1.3 explicitly prefers this be a derived projection rather than an
/// authoritative `@Model` ("Preferred implementation: derived projection,
/// not authoritative persisted entity" — Section 7.4 Implementation
/// notes). This is a plain computed value type, not persisted.
public struct FamilyMembership: Sendable {
    public let parentProfileId: UUID
    public let workspaceId: WorkspaceId
    public let participantId: UUID

    public init(parentProfileId: UUID, workspaceId: WorkspaceId, participantId: UUID) {
        self.parentProfileId = parentProfileId
        self.workspaceId = workspaceId
        self.participantId = participantId
    }

    /// Derives memberships from the authoritative records rather than
    /// storing a redundant join table, per Section 7.4's stated preference.
    public static func derive(parentProfiles: [ParentProfile], participants: [WorkspaceParticipant]) -> [FamilyMembership] {
        participants.compactMap { participant in
            guard let parent = parentProfiles.first(where: { $0.accountId == participant.accountId }) else { return nil }
            return FamilyMembership(parentProfileId: parent.id, workspaceId: WorkspaceId(rawValue: participant.workspaceId), participantId: participant.id)
        }
    }
}

// MARK: - AthleteAccessGrant (v1.3 Section 7.5)

@Model
public final class AthleteAccessGrant {
    @Attribute(.unique) public var id: UUID
    public var workspaceId: UUID
    public var participantId: UUID
    public var athleteId: UUID
    public var canViewSchedule: Bool
    public var canEditDraftPlans: Bool
    public var canCommitPlans: Bool
    public var canViewSharedReflections: Bool
    public var canViewDevelopmentInsights: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revokedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        workspaceId: WorkspaceId,
        participantId: UUID,
        athleteId: AthleteId,
        canViewSchedule: Bool,
        canEditDraftPlans: Bool,
        canCommitPlans: Bool,
        canViewSharedReflections: Bool,
        canViewDevelopmentInsights: Bool,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        revokedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.workspaceId = workspaceId.rawValue
        self.participantId = participantId
        self.athleteId = athleteId.rawValue
        self.canViewSchedule = canViewSchedule
        self.canEditDraftPlans = canEditDraftPlans
        self.canCommitPlans = canCommitPlans
        self.canViewSharedReflections = canViewSharedReflections
        self.canViewDevelopmentInsights = canViewDevelopmentInsights
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revokedAt = revokedAt
        self.schemaVersion = schemaVersion
    }
}
