import Foundation
import VoxtrCoreContracts

/// The outcome of an activation attempt.
public enum AthleteParticipantActivationResult {
    /// Activation succeeded — the newly created `WorkspaceParticipant`.
    case activated(WorkspaceParticipant)
    /// Eligibility failed. Carries the same reason values
    /// `AthleteParticipantEligibilityService` itself produced — not a
    /// new reason vocabulary, and not the whole
    /// `AthleteParticipantEligibilityResult` (which would allow the
    /// impossible state of an `.eligible` value appearing inside a
    /// failure case).
    case eligibilityFailed(
        primaryReason: AthleteParticipantIneligibilityReason,
        additionalReasons: [AthleteParticipantIneligibilityReason]
    )
    /// The repository threw while creating the participant. Carries a
    /// description of the underlying error, not the raw `Error` value
    /// itself, to avoid this type's `Sendable`-adjacent surface
    /// depending on error types this service doesn't control.
    case repositoryFailed(String)
}

/// Orchestrates activating an eligible athlete as a
/// `WorkspaceParticipant`. Evaluates eligibility via
/// `AthleteParticipantEligibilityService`, then, only if eligible,
/// creates the participant via `ParentWorkspaceRepository`. Contains
/// no eligibility rules or persistence logic of its own — both are
/// reused, not duplicated. `@MainActor` because
/// `ParentWorkspaceRepository` is.
@MainActor
public final class AthleteParticipantActivationService {
    private let eligibilityService: AthleteParticipantEligibilityService
    private let repository: ParentWorkspaceRepository

    public init(
        eligibilityService: AthleteParticipantEligibilityService,
        repository: ParentWorkspaceRepository
    ) {
        self.eligibilityService = eligibilityService
        self.repository = repository
    }

    public func activate(
        athlete: AthleteEligibilityFacts?,
        workspaceId: WorkspaceId,
        linkedAthleteId: AthleteId,
        invitedBy: ActorId,
        hasExistingParticipant: Bool
    ) -> AthleteParticipantActivationResult {
        activate(
            athlete: athlete,
            workspaceId: workspaceId,
            linkedAthleteId: linkedAthleteId,
            invitedBy: invitedBy,
            hasExistingParticipant: hasExistingParticipant,
            saveOverride: nil
        )
    }

    /// Test-only seam — not `public`, reachable only via `@testable
    /// import`, mirroring `ParentWorkspaceRepository`'s own
    /// `saveOverride` pattern exactly (this service is in the same
    /// module, so it can already see that repository overload without
    /// any new access-level exception). Every production call site
    /// goes through the public overload above, which always passes
    /// `nil`.
    func activate(
        athlete: AthleteEligibilityFacts?,
        workspaceId: WorkspaceId,
        linkedAthleteId: AthleteId,
        invitedBy: ActorId,
        hasExistingParticipant: Bool,
        saveOverride: (() throws -> Void)?
    ) -> AthleteParticipantActivationResult {
        switch eligibilityService.evaluate(
            athlete: athlete,
            workspaceId: workspaceId,
            hasExistingParticipant: hasExistingParticipant
        ) {
        case .notEligible(let primaryReason, let additionalReasons):
            return .eligibilityFailed(primaryReason: primaryReason, additionalReasons: additionalReasons)
        case .eligible:
            do {
                let participant = try repository.createInvitedAthleteParticipant(
                    workspaceId: workspaceId,
                    linkedAthleteId: linkedAthleteId,
                    invitedBy: invitedBy,
                    saveOverride: saveOverride
                )
                return .activated(participant)
            } catch {
                return .repositoryFailed("\(error)")
            }
        }
    }
}
