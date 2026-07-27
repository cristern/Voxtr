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
/// participation as a `WorkspaceParticipant`. Pure and side-effect
/// free: a stateless struct taking only plain values, no repository or
/// persistence access, no UI, no authentication or permission logic.
///
/// VX-037 (ADR-0002): exposes two methods, not one, because
/// "participant already exists" cannot mean the same thing at both
/// moments this service is consulted. At invite time, an existing
/// participant is a disqualifying fact (you cannot invite someone
/// twice). At accept time, an existing `.invited` participant is the
/// very thing being acted on — its presence is the precondition for
/// acceptance, not a reason to refuse it. Rather than have one caller
/// pass a boolean that means the opposite of what it meant for another
/// caller, the two moments get two methods. The archived/workspace
/// checks are genuinely shared between both moments (an athlete who
/// became archived between invite and accept should fail acceptance
/// too), so that logic lives once, in `baseReasons`, and both public
/// methods call it — nothing about those two checks is duplicated.
public struct AthleteParticipantEligibilityService: Sendable {
    public init() {}

    /// Invite-time: may a new invitation be created for this athlete.
    /// Reasons are always reported in this fixed order when multiple
    /// rules fail: `.athleteArchived`, `.athleteNotInWorkspace`,
    /// `.participantAlreadyExists`.
    public func evaluate(
        athlete: AthleteEligibilityFacts?,
        workspaceId: WorkspaceId,
        hasExistingParticipant: Bool
    ) -> AthleteParticipantEligibilityResult {
        guard let athlete else {
            return .notEligible(primaryReason: .athleteNotFound, additionalReasons: [])
        }

        var reasons = Self.baseReasons(for: athlete, workspaceId: workspaceId)
        if hasExistingParticipant {
            reasons.append(.participantAlreadyExists)
        }
        return Self.result(from: reasons)
    }

    /// Accept-time: may an already-invited participant now be
    /// transitioned to active. Deliberately takes no
    /// `hasExistingParticipant` parameter — the invited record being
    /// accepted is located separately (by
    /// `ParentWorkspaceRepository.findParticipant`), and its existence
    /// is never itself a disqualifying fact here.
    public func evaluateForAcceptance(
        athlete: AthleteEligibilityFacts?,
        workspaceId: WorkspaceId
    ) -> AthleteParticipantEligibilityResult {
        guard let athlete else {
            return .notEligible(primaryReason: .athleteNotFound, additionalReasons: [])
        }

        return Self.result(from: Self.baseReasons(for: athlete, workspaceId: workspaceId))
    }

    /// Shared by both public methods above — the two checks that
    /// genuinely apply at both invite time and accept time.
    private static func baseReasons(
        for athlete: AthleteEligibilityFacts,
        workspaceId: WorkspaceId
    ) -> [AthleteParticipantIneligibilityReason] {
        var reasons: [AthleteParticipantIneligibilityReason] = []
        if athlete.isArchived {
            reasons.append(.athleteArchived)
        }
        if athlete.workspaceId != workspaceId {
            reasons.append(.athleteNotInWorkspace)
        }
        return reasons
    }

    private static func result(from reasons: [AthleteParticipantIneligibilityReason]) -> AthleteParticipantEligibilityResult {
        guard let primaryReason = reasons.first else {
            return .eligible
        }
        return .notEligible(primaryReason: primaryReason, additionalReasons: Array(reasons.dropFirst()))
    }
}
