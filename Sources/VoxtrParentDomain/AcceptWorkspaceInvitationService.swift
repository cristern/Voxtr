import Foundation
import VoxtrCoreContracts

/// Orchestrates accepting a workspace invitation: locates the existing
/// `WorkspaceParticipant`, verifies acceptance preconditions (its
/// state, and current eligibility), transitions `.invited → .active`,
/// and persists — a single mutation of a single aggregate. No second
/// entity, no second save, no transaction coordinator needed.
///
/// Distinct from `AthleteParticipantActivationService`, which handles
/// the separate *invitation* use case (creating the `.invited` record
/// in the first place) — see that type's own doc comment. This
/// service never creates a `WorkspaceParticipant`; it only transitions
/// one that already exists.
///
/// Coordinates and translates results only — the state-machine
/// transition itself is one field assignment on the existing
/// aggregate, and the eligibility judgment stays entirely inside
/// `AthleteParticipantEligibilityService`. `@MainActor` because
/// `ParentWorkspaceRepository` is.
@MainActor
public final class AcceptWorkspaceInvitationService {
    private let repository: ParentWorkspaceRepository
    private let eligibilityService: AthleteParticipantEligibilityService

    public init(
        repository: ParentWorkspaceRepository,
        eligibilityService: AthleteParticipantEligibilityService
    ) {
        self.repository = repository
        self.eligibilityService = eligibilityService
    }

    /// `eligibilityFacts`: supplied by the caller, current as of the
    /// moment of acceptance — re-verified here rather than trusted
    /// from whenever the invitation was originally created, since an
    /// athlete's archived status (for example) could have changed in
    /// between.
    public func accept(
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        eligibilityFacts: AthleteEligibilityFacts?
    ) -> AcceptWorkspaceInvitationResult {
        accept(
            athleteId: athleteId,
            workspaceId: workspaceId,
            eligibilityFacts: eligibilityFacts,
            saveOverride: nil
        )
    }

    /// Test-only seam — not `public`, reachable only via `@testable
    /// import`, forwarded into `ParentWorkspaceRepository
    /// .acceptInvitation`'s own internal seam. Every production call
    /// site goes through the public overload above, which always
    /// passes `nil`.
    func accept(
        athleteId: AthleteId,
        workspaceId: WorkspaceId,
        eligibilityFacts: AthleteEligibilityFacts?,
        saveOverride: (() throws -> Void)?
    ) -> AcceptWorkspaceInvitationResult {
        let participant: WorkspaceParticipant?
        do {
            participant = try repository.findParticipant(forAthlete: athleteId, workspaceId: workspaceId)
        } catch {
            return .repositoryFailed
        }

        guard let participant else {
            return .invitationNotFound
        }

        switch participant.state {
        case .active:
            return .alreadyAccepted
        case .revoked:
            return .invitationRevoked
        case .declined:
            return .invitationDeclined
        case .invited:
            break
        }

        switch eligibilityService.evaluateForAcceptance(athlete: eligibilityFacts, workspaceId: workspaceId) {
        case .notEligible(let primaryReason, let additionalReasons):
            return .notEligible(primaryReason: primaryReason, additionalReasons: additionalReasons)
        case .eligible:
            do {
                try repository.acceptInvitation(participant, saveOverride: saveOverride)
            } catch {
                return .repositoryFailed
            }
            return .accepted(participant)
        }
    }
}
