import Foundation
import VoxtrCoreContracts

/// The single application-layer entry point for the whole workspace
/// invitation workflow — creation through active membership. A thin
/// facade over already-existing, independently-tested components; it
/// introduces no new business rules, no new persistence, and no new
/// aggregate. Every one of its methods delegates to a component that
/// already exists:
///
/// - `createInvitation` → `AthleteParticipantInvitationService`
///   (eligibility, then `ParentWorkspaceRepository
///   .createInvitedAthleteParticipant`)
/// - `acceptInvitation` → `AcceptWorkspaceInvitationService`
///   (`.invited → .active`)
/// - `pendingInvitations`/`activeParticipants` →
///   `ParentWorkspaceRepository.fetchPendingParticipants`/
///   `.fetchActiveParticipants`
///
/// The one place this type does more than pass through: `createInvitation`
/// resolves "does a participant already exist for this athlete" itself,
/// by querying the repository, rather than requiring the caller to
/// supply that fact correctly (which
/// `AthleteParticipantInvitationService.invite` itself still requires,
/// unchanged — this facade exists precisely so a caller doesn't have
/// to get that right on its own). This is the concrete mechanism
/// behind "no duplicate participant records" at this entry point.
///
/// `@MainActor` because every collaborator it holds is.
@MainActor
public final class WorkspaceInvitationApplicationService {
    private let invitationService: AthleteParticipantInvitationService
    private let acceptanceService: AcceptWorkspaceInvitationService
    private let repository: ParentWorkspaceRepository

    public init(
        invitationService: AthleteParticipantInvitationService,
        acceptanceService: AcceptWorkspaceInvitationService,
        repository: ParentWorkspaceRepository
    ) {
        self.invitationService = invitationService
        self.acceptanceService = acceptanceService
        self.repository = repository
    }

    /// Creates a new invitation for an athlete, after confirming no
    /// participant already exists for them in this workspace.
    /// `candidate: nil` behaves exactly as
    /// `AthleteParticipantInvitationService.invite` already defines it
    /// (produces `.eligibilityFailed(.athleteNotFound, [])`) — the
    /// duplicate check is skipped in that case since there is no
    /// athlete to check for.
    public func createInvitation(
        candidate: AthleteParticipantInvitationCandidate?,
        workspaceId: WorkspaceId,
        invitedBy: ActorId
    ) -> AthleteParticipantInvitationResult {
        let hasExistingParticipant: Bool
        do {
            if let athleteId = candidate?.athleteId {
                hasExistingParticipant = try repository.findParticipant(forAthlete: athleteId, workspaceId: workspaceId) != nil
            } else {
                hasExistingParticipant = false
            }
        } catch {
            return .repositoryFailed
        }
        return invitationService.invite(
            candidate: candidate,
            workspaceId: workspaceId,
            invitedBy: invitedBy,
            hasExistingParticipant: hasExistingParticipant
        )
    }

    /// Accepts a pending invitation, transitioning the existing
    /// `WorkspaceParticipant` from `.invited` to `.active`.
    public func acceptInvitation(
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        eligibilityFacts: AthleteEligibilityFacts?
    ) -> AcceptWorkspaceInvitationResult {
        acceptanceService.accept(athleteId: athleteId, workspaceId: workspaceId, eligibilityFacts: eligibilityFacts)
    }

    /// Every `WorkspaceParticipant` in this workspace currently
    /// `.invited` — awaiting a response.
    public func pendingInvitations(forWorkspace workspaceId: WorkspaceId) throws -> [WorkspaceParticipant] {
        try repository.fetchPendingParticipants(forWorkspace: workspaceId)
    }

    /// Every `WorkspaceParticipant` in this workspace currently
    /// `.active` — standing membership.
    public func activeParticipants(forWorkspace workspaceId: WorkspaceId) throws -> [WorkspaceParticipant] {
        try repository.fetchActiveParticipants(forWorkspace: workspaceId)
    }
}
