import Foundation
import VoxtrCoreContracts

/// Bundles the athlete being activated with the eligibility facts
/// evaluated for them, so a caller cannot supply facts for one athlete
/// while activating a different one — the two values only ever travel
/// together, through this one type.
public struct AthleteParticipantActivationCandidate: Sendable, Equatable {
    public let athleteId: AthleteId
    public let eligibilityFacts: AthleteEligibilityFacts

    public init(athleteId: AthleteId, eligibilityFacts: AthleteEligibilityFacts) {
        self.athleteId = athleteId
        self.eligibilityFacts = eligibilityFacts
    }
}

/// The outcome of an activation attempt.
public enum AthleteParticipantActivationResult {
    /// Activation succeeded — the newly created `WorkspaceParticipant`.
    case activated(WorkspaceParticipant)
    /// Eligibility failed. Carries the same reason values
    /// `AthleteParticipantEligibilityService` produced.
    case eligibilityFailed(
        primaryReason: AthleteParticipantIneligibilityReason,
        additionalReasons: [AthleteParticipantIneligibilityReason]
    )
    /// The repository failed to create the participant. No raw
    /// `Error` or `String` is exposed as public domain state.
    case repositoryFailed
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
        candidate: AthleteParticipantActivationCandidate?,
        workspaceId: WorkspaceId,
        invitedBy: ActorId,
        hasExistingParticipant: Bool
    ) -> AthleteParticipantActivationResult {
        activate(
            candidate: candidate,
            workspaceId: workspaceId,
            invitedBy: invitedBy,
            hasExistingParticipant: hasExistingParticipant,
            saveOverride: nil
        )
    }

    /// Test-only seam — not `public`, reachable only via `@testable
    /// import`, mirroring `ParentWorkspaceRepository`'s own
    /// `saveOverride` pattern (this service is in the same module, so
    /// it can already see that repository overload). Every production
    /// call site goes through the public overload above, which always
    /// passes `nil`.
    func activate(
        candidate: AthleteParticipantActivationCandidate?,
        workspaceId: WorkspaceId,
        invitedBy: ActorId,
        hasExistingParticipant: Bool,
        saveOverride: (() throws -> Void)?
    ) -> AthleteParticipantActivationResult {
        switch eligibilityService.evaluate(
            athlete: candidate?.eligibilityFacts,
            workspaceId: workspaceId,
            hasExistingParticipant: hasExistingParticipant
        ) {
        case .notEligible(let primaryReason, let additionalReasons):
            return .eligibilityFailed(primaryReason: primaryReason, additionalReasons: additionalReasons)
        case .eligible:
            // Unreachable when candidate is nil: evaluate(athlete: nil, ...)
            // always returns .notEligible(.athleteNotFound, []), never
            // .eligible. This guard exists only because the type
            // system can't express that; the "missing athlete" rule
            // itself is evaluated exactly once, above, not duplicated
            // here.
            guard let candidate else {
                return .eligibilityFailed(primaryReason: .athleteNotFound, additionalReasons: [])
            }
            do {
                let participant = try repository.createInvitedAthleteParticipant(
                    workspaceId: workspaceId,
                    linkedAthleteId: candidate.athleteId,
                    invitedBy: invitedBy,
                    saveOverride: saveOverride
                )
                return .activated(participant)
            } catch {
                return .repositoryFailed
            }
        }
    }
}
