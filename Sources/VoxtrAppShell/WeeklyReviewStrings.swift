import Foundation

/// Sprint 5.2: centralizes Weekly Review's user-facing strings that are
/// built as plain `String` values rather than passed as literals
/// directly to `Text`. Same rationale as `OnboardingStrings`/
/// `PlanningStrings`/`TrainingStrings`. Completion labels are NOT
/// duplicated here — `TrainingStrings.completedLabel`/`notCompletedLabel`
/// (S3.3) already represent the exact same concept and are reused
/// as-is.
public enum WeeklyReviewStrings {
    public static var genericError: String {
        String(localized: "weeklyReview.error.generic", defaultValue: "Something went wrong loading this week. Please try again.")
    }

    public static var noWeekPlan: String {
        String(localized: "weeklyReview.plan.empty", defaultValue: "No plan was created for this week.")
    }

    public static var noPlannedActivities: String {
        String(localized: "weeklyReview.plannedActivities.empty", defaultValue: "Nothing was planned this week.")
    }

    public static var noLoggedActivities: String {
        String(localized: "weeklyReview.loggedActivities.empty", defaultValue: "Nothing was logged this week.")
    }

    public static var noReflection: String {
        String(localized: "weeklyReview.reflection.empty", defaultValue: "No reflection yet for this week.")
    }

    public static var startReflectionAction: String {
        String(localized: "weeklyReview.reflection.start", defaultValue: "Add weekly reflection")
    }

    public static var editReflectionAction: String {
        String(localized: "weeklyReview.reflection.edit", defaultValue: "Edit weekly reflection")
    }
}
