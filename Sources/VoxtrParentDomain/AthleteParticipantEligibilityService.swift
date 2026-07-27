import Foundation
import VoxtrCoreContracts

/// The facts about an athlete needed to evaluate participant
/// eligibility. Not `AthleteProfile` — `VoxtrParentDomain` does not
/// depend on `VoxtrAthleteDomain`, so this holds only the fields the
/// rules below actually read. Mapping a real `AthleteProfile` into
/// this shape is the caller's responsibility.
public struct AthleteEligibilityFacts: Sendable, Equatable {
    public let workspaceId: WorkspaceId
    public let isArchived: Bool

    public init(workspaceId: WorkspaceId, isArchived: Bool) {
        self.workspaceId = workspaceId
        self.isArchived = isArchived
    }
}

/// Every reason `AthleteParticipantEligibilityService` can report.
public enum AthleteParticipantIneligibilityReason: Equatable, Sendable {
    /// No athlete was found to evaluate.
    case athleteNotFound
    /// The athlete is archived.
    case athleteArchived
    /// The athlete's workspace does not match the workspace being
    /// evaluated for.
    case athleteNotInWorkspace
    /// A `WorkspaceParticipant` already exists for this athlete.
    case participantAlreadyExists
}

/// The result of an eligibility evaluation. `.notEligible` always
/// carries at least one reason — `primaryReason` makes an empty
/// reason list structurally impossible.
public enum AthleteParticipantEligibilityResult: Equatable, Sendable {
    case eligible
    case notEligible(
        primaryReason: AthleteParticipantIneligibilityReason,
        additionalReasons: [AthleteParticipantIneligibilityReason]
    )
}

/// Evaluates whether an athlete satisfies the business rules for
/// activation as a `WorkspaceParticipant`. Pure and side-effect free:
/// a stateless struct taking only plain values, no repository or
/// persistence access, no UI, no authentication or permission logic.
public struct AthleteParticipantEligibilityService: Sendable {
    public init() {}

    /// `athlete: nil` means no athlete was found — this is reported
    /// alone, never combined with other reasons. Reasons are always
    /// reported in this fixed order when multiple rules fail:
    /// `.athleteArchived`, `.athleteNotInWorkspace`,
    /// `.participantAlreadyExists`.
    public func evaluate(
        athlete: AthleteEligibilityFacts?,
        workspaceId: WorkspaceId,
        hasExistingParticipant: Bool
    ) -> AthleteParticipantEligibilityResult {
        guard let athlete else {
            return .notEligible(primaryReason: .athleteNotFound, additionalReasons: [])
        }

        var reasons: [AthleteParticipantIneligibilityReason] = []
        if athlete.isArchived {
            reasons.append(.athleteArchived)
        }
        if athlete.workspaceId != workspaceId {
            reasons.append(.athleteNotInWorkspace)
        }
        if hasExistingParticipant {
            reasons.append(.participantAlreadyExists)
        }

        guard let primaryReason = reasons.first else {
            return .eligible
        }
        return .notEligible(primaryReason: primaryReason, additionalReasons: Array(reasons.dropFirst()))
    }
}
