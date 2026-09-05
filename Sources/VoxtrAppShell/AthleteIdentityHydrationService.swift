import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain

/// Athlete Connection Foundation B2.6 (PR #68 architecture follow-up,
/// BLOCKER 1): the ONE thing that closes the cross-device identity gap —
/// on a fresh Athlete-device install, `AthleteConnectionIdentityBindingService`
/// (B2.3) resolves against `FamilyRestorationService.restoreState()`,
/// the SAME local SwiftData graph ParentApp uses. Nothing in that graph
/// exists yet on a fresh device: no `ParentProfile`, no `FamilyWorkspace`,
/// no `WorkspaceParticipant`, no `AthleteProfile`. This service turns
/// the minimum projection `AcceptedFamilyWorkspaceShare.hydration`
/// carries (see `AthleteConnectionInvitationCloudRecordMapping`'s own
/// doc comment for exactly what and why) into real local rows, so that
/// `FamilyRestorationService`'s own consistency rules — unchanged,
/// unweakened — can actually succeed afterward.
///
/// ONE TRUTH: CloudKit transport records are a TRANSPORT representation
/// of canonical business identity, never a second business identity
/// model. Every entity here is upserted by its EXISTING stable ID
/// (never a freshly-generated one, except the access grant's own
/// internal id, which nothing external ever compares against — see
/// `FamilyRestorationService`'s own validation, which never inspects
/// `AthleteAccessGrant.id` itself). Find-by-ID-or-create, never
/// first-match-wins, never a second identity for anything that already
/// exists.
///
/// CONFLICT SEMANTICS: if a stable ID already resolves locally to an
/// entity whose OTHER relational fields (workspace membership, role,
/// linked athlete) disagree with what the incoming projection says, this
/// throws an explicit `AthleteIdentityHydrationError` case rather than
/// silently overwriting — "if local state conflicts with shared
/// authoritative identity, fail explicitly." Purely-cosmetic/display
/// fields on an entity that already exists (a name, a display string)
/// are left untouched on a repeat hydration rather than refreshed —
/// this bounded slice is not a general sync mechanism (out of scope,
/// per this PR's own OUT OF SCOPE list), only a one-time bootstrap.
///
/// SINGLE-FAMILY-PER-DEVICE: `FamilyRestorationService` still assumes
/// (Sprint 1, unchanged) exactly one `ParentProfile`/`FamilyWorkspace`
/// per device. If this device already has a DIFFERENT family hydrated
/// (a different `parentId`/`workspaceId` than this projection names),
/// hydration fails explicitly (`differentFamilyAlreadyExists`) rather
/// than either creating a second workspace (breaking that assumption)
/// or silently overwriting the existing one. Accepting a second,
/// different family's invitation on the same already-connected device is
/// out of scope for this bounded slice.
///
/// STATE DISCIPLINE: hydration NEVER sets a `WorkspaceParticipant.state`
/// to `.active` itself — the intended athlete's own participant is
/// always created `.invited` (via the SAME canonical
/// `ParentWorkspaceRepository.createInvitedAthleteParticipant` every
/// other invitation-creation call site in this codebase already uses),
/// and left completely untouched if it already exists (it may already
/// be `.active` from a prior successful connection — hydration must
/// never regress that). The canonical `.invited → .active` transition
/// remains exclusively `AcceptWorkspaceInvitationService`'s job,
/// sequenced by `AthleteConnectionLifecycleService` AFTER hydration.
///
/// NOT ATOMIC ACROSS ALL FIVE ENTITIES: unlike `FamilyOnboardingCoordinator`
/// (which controls its own save/rollback boundary), this service reuses
/// existing CANONICAL repository methods as-is, several of which already
/// save immediately on their own (`createInvitedAthleteParticipant`).
/// This is deliberate, not an oversight: each of the five upsert steps
/// is independently idempotent (find-by-ID-or-create), so a failure
/// partway through leaves a state a LATER retry of the same
/// `connect(acceptedShare:)` attempt can safely resume from — reusing
/// whatever already got created, creating only what's still missing.
///
/// ACTOR ISOLATION: `@MainActor`, matching every repository it composes.
@MainActor
public final class AthleteIdentityHydrationService {
    private let modelContext: ModelContext
    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let athleteRepository: AthleteRepository
    private let athleteAccessGrantRepository: AthleteAccessGrantRepository

    public init(
        modelContext: ModelContext,
        parentWorkspaceRepository: ParentWorkspaceRepository,
        athleteRepository: AthleteRepository,
        athleteAccessGrantRepository: AthleteAccessGrantRepository
    ) {
        self.modelContext = modelContext
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.athleteRepository = athleteRepository
        self.athleteAccessGrantRepository = athleteAccessGrantRepository
    }

    /// Runs all five upsert steps in the order `FamilyRestorationService`'s
    /// own consistency rules are structured around: family-level facts
    /// first (parent, workspace, owner participant), then the specific
    /// athlete's own facts (their participant, their profile, their
    /// access grant) — each step's conflict check only makes sense once
    /// the steps before it have already established what "the local
    /// family" is.
    public func hydrate(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        do {
            try hydrateParent(projection)
            try hydrateWorkspace(projection)
            try hydrateOwnerParticipant(projection)
            try hydrateAthleteProfile(projection)
            try hydrateAthleteParticipant(projection)
            try hydrateAccessGrant(projection)
        } catch let error as AthleteIdentityHydrationError {
            throw error
        } catch {
            throw AthleteIdentityHydrationError.persistenceFailed(error)
        }
    }

    private func hydrateParent(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        let existing = try parentWorkspaceRepository.fetchAllParentProfiles()
        guard existing.allSatisfy({ $0.id == projection.parentId }) else {
            throw AthleteIdentityHydrationError.differentFamilyAlreadyExists
        }
        guard !existing.contains(where: { $0.id == projection.parentId }) else {
            return
        }
        let parent = ParentProfile(id: projection.parentId, accountId: .pending, givenName: projection.parentGivenName)
        modelContext.insert(parent)
        try modelContext.save()
    }

    private func hydrateWorkspace(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        let existing = try parentWorkspaceRepository.fetchAllWorkspaces()
        guard existing.allSatisfy({ $0.id == projection.workspaceId }) else {
            throw AthleteIdentityHydrationError.differentFamilyAlreadyExists
        }
        guard !existing.contains(where: { $0.id == projection.workspaceId }) else {
            return
        }
        let workspace = FamilyWorkspace(
            id: WorkspaceId(rawValue: projection.workspaceId),
            displayName: projection.workspaceDisplayName,
            technicalOwnerAccountId: .pending
        )
        modelContext.insert(workspace)
        try modelContext.save()
    }

    private func hydrateOwnerParticipant(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        let allParticipants = try parentWorkspaceRepository.fetchAllParticipants()
        let owners = allParticipants.filter { $0.role == .workspaceOwner }
        guard owners.allSatisfy({ $0.id == projection.ownerParticipantId && $0.workspaceId == projection.workspaceId }) else {
            throw AthleteIdentityHydrationError.ownerParticipantConflict
        }
        guard !owners.contains(where: { $0.id == projection.ownerParticipantId }) else {
            return
        }
        let now = Date.now
        let owner = WorkspaceParticipant(
            id: projection.ownerParticipantId,
            workspaceId: WorkspaceId(rawValue: projection.workspaceId),
            accountId: .pending,
            role: .workspaceOwner,
            state: .active,
            invitedAt: now,
            acceptedAt: now
        )
        modelContext.insert(owner)
        try modelContext.save()
    }

    private func hydrateAthleteProfile(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        let athleteId = AthleteId(rawValue: projection.intendedAthleteId)
        if let existing = try athleteRepository.fetchAthlete(byId: athleteId) {
            guard existing.workspaceId == projection.workspaceId else {
                throw AthleteIdentityHydrationError.athleteProfileConflict
            }
            return
        }
        guard let birthDate = LocalDate(isoString: projection.athleteBirthDateISO) else {
            throw AthleteIdentityHydrationError.invalidProjection(reason: "athleteBirthDateISO did not parse as a LocalDate: \(projection.athleteBirthDateISO)")
        }
        guard let developmentStage = DevelopmentStage(rawValue: projection.athleteDevelopmentStage) else {
            throw AthleteIdentityHydrationError.invalidProjection(reason: "athleteDevelopmentStage did not match a known DevelopmentStage: \(projection.athleteDevelopmentStage)")
        }
        _ = athleteRepository.stageAthlete(
            athleteId: athleteId,
            workspaceId: WorkspaceId(rawValue: projection.workspaceId),
            givenName: projection.athleteGivenName,
            birthDate: birthDate,
            timeZoneId: TimeZoneId(rawValue: projection.athleteTimeZoneId),
            developmentStage: developmentStage
        )
        try athleteRepository.save()
    }

    private func hydrateAthleteParticipant(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        let allParticipants = try parentWorkspaceRepository.fetchAllParticipants()
        if let existing = allParticipants.first(where: { $0.id == projection.intendedParticipantId }) {
            guard existing.role == .athlete,
                  existing.workspaceId == projection.workspaceId,
                  existing.linkedAthleteId == projection.intendedAthleteId else {
                throw AthleteIdentityHydrationError.athleteParticipantConflict
            }
            return
        }
        _ = try parentWorkspaceRepository.createInvitedAthleteParticipant(
            id: projection.intendedParticipantId,
            workspaceId: WorkspaceId(rawValue: projection.workspaceId),
            linkedAthleteId: AthleteId(rawValue: projection.intendedAthleteId),
            invitedBy: ActorId(rawValue: projection.ownerParticipantId)
        )
    }

    private func hydrateAccessGrant(_ projection: AthleteConnectionInvitationCloudRecordPayload) throws {
        let existingGrants = try athleteAccessGrantRepository.fetchAllGrants()
        let alreadyGranted = existingGrants.contains {
            $0.participantId == projection.ownerParticipantId && $0.athleteId == projection.intendedAthleteId
        }
        guard !alreadyGranted else {
            return
        }
        _ = try athleteAccessGrantRepository.createFullAccessGrant(
            workspaceId: WorkspaceId(rawValue: projection.workspaceId),
            participantId: projection.ownerParticipantId,
            athleteId: AthleteId(rawValue: projection.intendedAthleteId)
        )
    }
}

/// Explicit, differentiated failure semantics — never collapsed to
/// `nil`/`Bool`/a generic message, matching this codebase's own
/// established B2.x reasoning. Not `Sendable`: wraps an existential
/// `Error` in one case; every throw/catch site stays within this
/// service's own `@MainActor` isolation.
public enum AthleteIdentityHydrationError: Error {
    /// This device already has a `ParentProfile`/`FamilyWorkspace` whose
    /// stable ID does NOT match this projection's — Sprint 1's
    /// single-family-per-device assumption means accepting a second,
    /// different family's invitation on an already-connected device is
    /// out of scope for this bounded slice.
    case differentFamilyAlreadyExists
    /// A local `.workspaceOwner` `WorkspaceParticipant` already exists
    /// with a different `id` or `workspaceId` than this projection's
    /// owner — should not happen once `differentFamilyAlreadyExists`
    /// above is ruled out, but checked explicitly rather than assumed.
    case ownerParticipantConflict
    /// A local `WorkspaceParticipant` already exists with the intended
    /// `id`, but its `role`/`workspaceId`/`linkedAthleteId` disagree
    /// with this projection's — the local identity this ID names is not
    /// the one this invitation actually intends.
    case athleteParticipantConflict
    /// A local `AthleteProfile` already exists with the intended `id`,
    /// but its `workspaceId` disagrees with this projection's.
    case athleteProfileConflict
    /// The projection's own field content could not be decoded into a
    /// value the local model's initializer requires (e.g. an
    /// unparseable date or an unrecognized enum raw value) — a
    /// genuinely malformed transported payload, not a conflict with
    /// existing local state.
    case invalidProjection(reason: String)
    /// A genuine SwiftData persistence failure at any step.
    case persistenceFailed(Error)
}
