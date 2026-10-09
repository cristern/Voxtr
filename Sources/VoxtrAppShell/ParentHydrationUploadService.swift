import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentAuthentication
import VoxtrParentDomain
import VoxtrAthleteDomain

/// Parent hydration-upload integration (merged CloudKit transition plan
/// §5.1): the ONE ParentApp-side orchestration service that turns an
/// actually-approved connection request into a real `hydration-upload`
/// call carrying the exact 11 §2.4 bootstrap fields — the missing
/// prerequisite the plan's own §5.1 named, implemented here.
///
/// TWO SEPARATE RESPONSIBILITIES, kept distinct on purpose:
/// 1. `resolveProjection(...)` — PURE local identity resolution, no
///    network I/O. Reuses the SAME canonical repositories every other
///    invitation flow already uses (`ParentWorkspaceRepository`,
///    `AthleteRepository`), but corrects the WORKSPACE-SCOPING gap this
///    task's own brief flagged in `AthleteConnectionOwnerHandoffService
///    .prepareInvitation`: that method's owner-participant/Parent-
///    profile lookups are a bare `allParticipants.first(where: role ==
///    .workspaceOwner)` / `parents.first` — correct only under a
///    single-workspace-per-device assumption, never actually scoped to
///    THIS workspace. Here, the owner participant is filtered by
///    `workspaceId` explicitly, and the Parent is derived by matching
///    `WorkspaceParticipant.accountId` back to `ParentProfile.accountId`
///    — the same relationship `FamilyMembership.derive(...)` already
///    establishes as canonical (`ParentEntities.swift`) — never by
///    "the sole parent profile in the whole local store." Every
///    mismatch/missing/duplicate case is its own distinct, named error,
///    never a silent first-match fallback and never inferred from
///    display name, creation order, or birth date.
/// 2. `upload(...)` — the actual network call, via the EXISTING
///    `ParentAuthenticationService.uploadHydration(...)`. Never invents
///    a second transport/session path.
///
/// CANONICAL PROJECTION TYPE REUSE: returns the SAME
/// `AthleteConnectionInvitationCloudRecordPayload` the legacy CKShare
/// flow (`AthleteConnectionOwnerHandoffService`) and the backend
/// hydration adapter (`AthleteBackendHydrationAdapter`) already use —
/// per this task's own "orchestration/projection in canonical service
/// ownership, not duplicated UI persistence logic" instruction, this
/// service does not define a second, parallel 11-field struct.
///
/// IMMUTABILITY IS THE CALLER'S RESPONSIBILITY: this service resolves a
/// fresh projection every time it is called — it has no memory of a
/// previously-resolved one. The caller
/// (`AthleteDeviceAuthorizationInvitationCoordinator`) is responsible
/// for calling `resolveProjection` exactly ONCE, immediately after an
/// actual approval success, and freezing the result for every retry of
/// `upload(...)` thereafter — never calling `resolveProjection` again
/// for the same approved request, which could silently pick up changed
/// profile data instead of the payload the Parent actually approved.
///
/// `@MainActor`, matching every collaborator
/// (`ParentWorkspaceRepository`, `AthleteRepository`,
/// `ParentAuthenticationService`).
@MainActor
public final class ParentHydrationUploadService {
    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let athleteRepository: AthleteRepository
    private let parentAuthenticationService: ParentAuthenticationService

    public init(
        parentWorkspaceRepository: ParentWorkspaceRepository,
        athleteRepository: AthleteRepository,
        parentAuthenticationService: ParentAuthenticationService
    ) {
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.athleteRepository = athleteRepository
        self.parentAuthenticationService = parentAuthenticationService
    }

    /// PURE local resolution — no network I/O. Every `guard`/`filter`
    /// below maps to exactly one differentiated, named failure case
    /// (`ParentHydrationProjectionError`), never a generic/silent
    /// failure or a first-match fallback.
    public func resolveProjection(
        workspaceId: WorkspaceId,
        intendedParticipantId: UUID,
        intendedAthleteId: AthleteId
    ) throws -> AthleteConnectionInvitationCloudRecordPayload {
        let allParticipants: [WorkspaceParticipant]
        do {
            allParticipants = try parentWorkspaceRepository.fetchAllParticipants()
        } catch {
            throw ParentHydrationProjectionError.participantLookupFailed(error)
        }

        let intendedMatches = allParticipants.filter { $0.id == intendedParticipantId }
        guard !intendedMatches.isEmpty else {
            throw ParentHydrationProjectionError.intendedParticipantNotFound
        }
        guard intendedMatches.count == 1, let intendedParticipant = intendedMatches.first else {
            // `@Attribute(.unique)` on `WorkspaceParticipant.id` should
            // make this structurally impossible — surfaced explicitly
            // rather than silently picking a first match, matching
            // `AthleteSessionActivationService`'s own established
            // defense-in-depth precedent for this exact shape of check.
            throw ParentHydrationProjectionError.duplicateIntendedParticipant
        }
        guard intendedParticipant.workspaceId == workspaceId.rawValue else {
            throw ParentHydrationProjectionError.intendedParticipantWorkspaceMismatch
        }
        guard intendedParticipant.role == .athlete else {
            throw ParentHydrationProjectionError.intendedParticipantRoleMismatch
        }
        guard intendedParticipant.linkedAthleteId == intendedAthleteId.rawValue else {
            throw ParentHydrationProjectionError.intendedParticipantAthleteLinkMismatch
        }

        // WORKSPACE-SCOPED, unlike `AthleteConnectionOwnerHandoffService
        // .prepareInvitation`'s own bare `allParticipants.first(where:
        // role == .workspaceOwner)` — see this type's own doc comment.
        let ownerMatches = allParticipants.filter { $0.role == .workspaceOwner && $0.workspaceId == workspaceId.rawValue }
        guard !ownerMatches.isEmpty else {
            throw ParentHydrationProjectionError.ownerParticipantNotFound
        }
        guard ownerMatches.count == 1, let ownerParticipant = ownerMatches.first else {
            throw ParentHydrationProjectionError.duplicateOwnerParticipant
        }

        let allParentProfiles: [ParentProfile]
        do {
            allParentProfiles = try parentWorkspaceRepository.fetchAllParentProfiles()
        } catch {
            throw ParentHydrationProjectionError.parentProfileLookupFailed(error)
        }
        // Derived via `accountId`, the SAME relationship
        // `FamilyMembership.derive(...)` already treats as canonical —
        // never "the sole parent profile in the whole local store."
        let parentMatches = allParentProfiles.filter { $0.accountId == ownerParticipant.accountId }
        guard !parentMatches.isEmpty else {
            throw ParentHydrationProjectionError.parentProfileNotFound
        }
        guard parentMatches.count == 1, let parent = parentMatches.first else {
            throw ParentHydrationProjectionError.duplicateParentProfile
        }

        let allWorkspaces: [FamilyWorkspace]
        do {
            allWorkspaces = try parentWorkspaceRepository.fetchAllWorkspaces()
        } catch {
            throw ParentHydrationProjectionError.workspaceLookupFailed(error)
        }
        guard let workspace = allWorkspaces.first(where: { $0.id == workspaceId.rawValue }) else {
            throw ParentHydrationProjectionError.workspaceNotFound
        }

        let athlete: AthleteProfile
        do {
            guard let found = try athleteRepository.fetchAthlete(byId: intendedAthleteId) else {
                throw ParentHydrationProjectionError.athleteProfileNotFound
            }
            athlete = found
        } catch let error as ParentHydrationProjectionError {
            throw error
        } catch {
            throw ParentHydrationProjectionError.athleteProfileLookupFailed(error)
        }

        return AthleteConnectionInvitationCloudRecordPayload(
            workspaceId: workspaceId.rawValue,
            intendedParticipantId: intendedParticipant.id,
            intendedAthleteId: intendedAthleteId.rawValue,
            parentId: parent.id,
            parentGivenName: parent.givenName,
            workspaceDisplayName: workspace.displayName,
            ownerParticipantId: ownerParticipant.id,
            athleteGivenName: athlete.givenName,
            athleteBirthDateISO: athlete.birthDate.isoString,
            athleteTimeZoneId: athlete.timeZoneId.rawValue,
            athleteDevelopmentStage: athlete.developmentStage.rawValue
        )
    }

    /// The actual network call — `payload` must be exactly what
    /// `resolveProjection` returned, frozen by the caller; this method
    /// never recomputes or re-resolves anything itself.
    public func upload(
        connectionRequestId: UUID,
        payload: AthleteConnectionInvitationCloudRecordPayload
    ) async throws -> HydrationUploadOutcome {
        try await parentAuthenticationService.uploadHydration(
            connectionRequestId: connectionRequestId,
            workspaceId: payload.workspaceId,
            intendedParticipantId: payload.intendedParticipantId,
            intendedAthleteId: payload.intendedAthleteId,
            parentId: payload.parentId,
            parentGivenName: payload.parentGivenName,
            workspaceDisplayName: payload.workspaceDisplayName,
            ownerParticipantId: payload.ownerParticipantId,
            athleteGivenName: payload.athleteGivenName,
            athleteBirthDateIso: payload.athleteBirthDateISO,
            athleteTimeZoneId: payload.athleteTimeZoneId,
            athleteDevelopmentStage: payload.athleteDevelopmentStage
        )
    }
}

/// Explicit, differentiated failure semantics for `resolveProjection` —
/// never flattened to a generic/silent failure, matching
/// `AthleteConnectionOwnerHandoffError`/`AthleteSessionActivationError`'s
/// own established convention.
public enum ParentHydrationProjectionError: Error {
    case participantLookupFailed(Error)
    case intendedParticipantNotFound
    /// Should be structurally impossible given `@Attribute(.unique)` on
    /// `WorkspaceParticipant.id` — surfaced explicitly rather than
    /// silently picking a first match.
    case duplicateIntendedParticipant
    case intendedParticipantWorkspaceMismatch
    case intendedParticipantRoleMismatch
    case intendedParticipantAthleteLinkMismatch
    case ownerParticipantNotFound
    /// More than one `.workspaceOwner` participant exists for this
    /// EXACT workspace — should not happen given this codebase's own
    /// single-owner-per-workspace invariant, but surfaced explicitly.
    case duplicateOwnerParticipant
    case parentProfileLookupFailed(Error)
    case parentProfileNotFound
    /// More than one local `ParentProfile` shares the owner
    /// participant's exact `accountId` — should be structurally
    /// impossible, but surfaced explicitly rather than silently
    /// reusing a first match.
    case duplicateParentProfile
    case workspaceLookupFailed(Error)
    case workspaceNotFound
    case athleteProfileLookupFailed(Error)
    case athleteProfileNotFound
}
