import Foundation

/// The outcome of an invitation acceptance attempt. Every case
/// genuinely exists in the model — each maps to one of
/// `ParticipantState`'s four cases (`.invited`/`.active`/`.revoked`/
/// `.declined`) or to a real absence/failure. No `String`/`Error` in
/// any case.
public enum AcceptWorkspaceInvitationResult {
    /// Acceptance succeeded — the `WorkspaceParticipant`, now `.active`.
    case accepted(WorkspaceParticipant)
    /// No `WorkspaceParticipant` exists for this athlete in this
    /// workspace at all.
    case invitationNotFound
    /// A participant exists, but its state is already `.active`.
    case alreadyAccepted
    /// A participant exists, but its state is `.revoked`.
    case invitationRevoked
    /// A participant exists, but its state is `.declined`.
    case invitationDeclined
    /// The athlete did not satisfy acceptance-time eligibility.
    /// Carries the same reason values
    /// `AthleteParticipantEligibilityService` produced.
    case notEligible(
        primaryReason: AthleteParticipantIneligibilityReason,
        additionalReasons: [AthleteParticipantIneligibilityReason]
    )
    /// A repository operation failed.
    case repositoryFailed
}
