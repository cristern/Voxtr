import Foundation

/// S1.4 requirement 4: this mirrors — does not replace — the
/// `precondition`s already in `ParentProfile`/`AthleteProfile`
/// (`givenName` 1–80 characters). Checking the same bounds here, before
/// ever calling `FamilyOnboardingCoordinator`, is what guarantees this
/// UI path can never trigger one of those preconditions: the UI's
/// validation is at least as strict as the domain's, so nothing invalid
/// gets far enough to hit them. If a domain precondition ever tightens,
/// this must be updated to match — that's a deliberate coupling, not an
/// oversight.
public enum FamilyOnboardingValidator {

    public static func validateParentGivenName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return OnboardingStrings.enterYourName }
        guard trimmed.count <= 80 else { return OnboardingStrings.nameTooLong }
        return nil
    }

    public static func validateAthleteGivenName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return OnboardingStrings.enterAthleteName }
        guard trimmed.count <= 80 else { return OnboardingStrings.nameTooLong }
        return nil
    }

    /// No domain precondition exists for birth date (see S1.2's
    /// `AthleteRepository`) — this single check (not in the future) is
    /// a universal fact about birth dates, not a product-specific
    /// business rule being invented here.
    public static func validateBirthDate(_ date: Date) -> String? {
        if date > Date.now { return OnboardingStrings.birthDateInFuture }
        return nil
    }
}
