import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentAuthentication
import VoxtrParentDomain
import VoxtrAthleteDomain

/// Athlete Connection V1 (backend device authorization): the ONE
/// ParentApp-side orchestration service that turns "Parent selects an
/// existing `AthleteProfile` and taps Connect this device" into a real
/// backend connection invitation — the backend-authorized counterpart to
/// `AthleteConnectionOwnerHandoffService` (the existing, unmodified
/// CKShare-based flow).
///
/// PARTICIPANT RESOLUTION: reuses `AthleteConnectionOwnerHandoffService
/// .matchingAthleteParticipants(...)` directly — the SAME pure,
/// state-agnostic, stable-ID-only matching that service already
/// established — rather than reimplementing it, per this codebase's own
/// domain-ownership reuse rule (CLAUDE.md §3). A genuinely new athlete
/// (no existing participant at all) creates EXACTLY ONE new `.invited`
/// `WorkspaceParticipant`, via the same canonical
/// `ParentWorkspaceRepository.createInvitedAthleteParticipant(...)` path
/// every other invitation flow in this codebase already uses.
///
/// `(workspaceId, participantId, athleteId)` — the three opaque, already-
/// resolved stable identifiers the backend's own
/// `connection-invitation-create` expects — are exactly what this method
/// hands to `ParentAuthenticationService.createConnectionInvitation`;
/// this service never invents a fourth identifier or infers a
/// relationship the backend itself does not verify.
///
/// `@MainActor`, matching every collaborator.
@MainActor
public final class AthleteDeviceAuthorizationInvitationService {
    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let parentAuthenticationService: ParentAuthenticationService

    public init(
        parentWorkspaceRepository: ParentWorkspaceRepository,
        parentAuthenticationService: ParentAuthenticationService
    ) {
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.parentAuthenticationService = parentAuthenticationService
    }

    public func prepareInvitation(
        forAthlete athleteId: AthleteId,
        workspaceId: WorkspaceId,
        invitedBy: ActorId
    ) async throws -> AthleteDeviceAuthorizationInvitation {
        let allParticipants: [WorkspaceParticipant]
        do {
            allParticipants = try parentWorkspaceRepository.fetchAllParticipants()
        } catch {
            throw AthleteDeviceAuthorizationInvitationError.participantLookupFailed(error)
        }

        let participant: WorkspaceParticipant
        switch AthleteConnectionOwnerHandoffService.matchingAthleteParticipants(
            athleteId: athleteId,
            workspaceId: workspaceId,
            participants: allParticipants
        ) {
        case .none:
            do {
                participant = try parentWorkspaceRepository.createInvitedAthleteParticipant(
                    workspaceId: workspaceId,
                    linkedAthleteId: athleteId,
                    invitedBy: invitedBy
                )
            } catch {
                throw AthleteDeviceAuthorizationInvitationError.participantCreationFailed(error)
            }
        case .one(let existing):
            participant = existing
        case .duplicate:
            throw AthleteDeviceAuthorizationInvitationError.duplicateAthleteParticipant
        }

        let outcome: ConnectionInvitationCreationOutcome
        do {
            outcome = try await parentAuthenticationService.createConnectionInvitation(
                workspaceId: workspaceId.rawValue,
                participantId: participant.id,
                athleteId: athleteId.rawValue
            )
        } catch let error as ParentAuthenticationError {
            throw AthleteDeviceAuthorizationInvitationError.authenticationFailed(error)
        } catch {
            throw AthleteDeviceAuthorizationInvitationError.authenticationFailed(.network)
        }

        switch outcome {
        case .created(let invitationId, let expiresAt):
            return AthleteDeviceAuthorizationInvitation(
                invitationId: invitationId,
                expiresAt: expiresAt,
                participantId: participant.id,
                athleteId: athleteId
            )
        case .ownerBindingNotActive:
            throw AthleteDeviceAuthorizationInvitationError.ownerBindingNotActive
        }
    }
}

/// The minimum the ParentApp UI needs to display the QR code and drive
/// the request-listing/decision poll that follows — deliberately not
/// richer.
public struct AthleteDeviceAuthorizationInvitation: Equatable {
    public let invitationId: UUID
    public let expiresAt: Date
    /// The intended athlete's own `WorkspaceParticipant.id` — carried
    /// here only for the caller's own display/bookkeeping; never
    /// resent to the backend by anything other than
    /// `prepareInvitation` itself.
    public let participantId: UUID
    public let athleteId: AthleteId
}

/// Explicit, differentiated failure semantics — never flattened to a
/// generic/silent failure, matching `AthleteConnectionOwnerHandoffError`'s
/// own convention.
public enum AthleteDeviceAuthorizationInvitationError: Error {
    case participantLookupFailed(Error)
    case duplicateAthleteParticipant
    case participantCreationFailed(Error)
    case authenticationFailed(ParentAuthenticationError)
    case ownerBindingNotActive
}
