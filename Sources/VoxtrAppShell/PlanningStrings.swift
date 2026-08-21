import Foundation

/// S2.4: centralizes Weekly Planning's user-facing strings that are
/// built as plain `String` values (status labels, error messages)
/// rather than passed as literals directly to `Text`. Same rationale as
/// `OnboardingStrings` — see that file's doc comment for why this
/// matters and what it doesn't change.
public enum PlanningStrings {
    public static var draftStatus: String {
        String(localized: "planning.status.draft", defaultValue: "Draft")
    }

    public static var committedStatus: String {
        String(localized: "planning.status.committed", defaultValue: "Committed")
    }

    public static var genericServiceError: String {
        String(
            localized: "planning.error.generic",
            defaultValue: "Something went wrong. Please try again."
        )
    }

    public static var weekPlanNotFoundError: String {
        String(localized: "planning.error.weekPlanNotFound", defaultValue: "This week plan could not be found.")
    }

    public static var weekPlanNotDraftError: String {
        String(
            localized: "planning.error.weekPlanNotDraft",
            defaultValue: "This week has already been committed and can no longer be changed."
        )
    }

    public static var activityIdentityRequired: String {
        String(
            localized: "planning.activity.identityRequired",
            defaultValue: "Choose a sport or enter an activity name."
        )
    }
}
