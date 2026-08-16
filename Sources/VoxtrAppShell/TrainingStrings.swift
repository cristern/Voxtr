import Foundation

/// S3.3: centralizes Daily Training's user-facing strings that are
/// built as plain `String` values (validation/error messages, status
/// labels) rather than passed as literals directly to `Text`. Same
/// rationale as `OnboardingStrings`/`PlanningStrings` — see those
/// files' doc comments for why this matters and what it doesn't
/// change.
public enum TrainingStrings {
    public static var genericError: String {
        String(localized: "training.error.generic", defaultValue: "Something went wrong. Please try again.")
    }

    public static var invalidDuration: String {
        String(localized: "training.error.invalidDuration", defaultValue: "Duration must be between 1 and 1440 minutes.")
    }

    public static var invalidPerceivedExertion: String {
        String(localized: "training.error.invalidExertion", defaultValue: "Perceived exertion must be between 1 and 10.")
    }

    public static var notesTooLong: String {
        String(localized: "training.error.notesTooLong", defaultValue: "Notes must be 500 characters or fewer.")
    }

    /// VX-022: Form is required for the Log Activity flow — this is the
    /// UI/orchestration-boundary message when it was left unset, not a
    /// domain-level constraint (`ActivityReflection.bodyFeeling` itself
    /// stays optional; see `TrainingValidator.validateForm`).
    public static var formRequired: String {
        String(localized: "training.error.formRequired", defaultValue: "Form is required.")
    }

    public static var invalidForm: String {
        String(localized: "training.error.invalidForm", defaultValue: "Form must be between 1 and 5.")
    }

    /// Planned/Logged Activity lifecycle consistency cleanup: actual
    /// duration is required for a completed (or partially completed)
    /// log — the same "required at the UI/orchestration boundary, not
    /// silently defaulted" contract `formRequired` above already
    /// establishes for Form. See `TrainingValidator.validateActualDuration`.
    public static var actualDurationRequired: String {
        String(localized: "training.error.actualDurationRequired", defaultValue: "Duration is required.")
    }

    public static var plannedActivityAlreadyLinked: String {
        String(
            localized: "training.error.alreadyLinked",
            defaultValue: "This planned activity has already been logged."
        )
    }

    public static var completedLabel: String {
        String(localized: "training.plannedActivity.completed", defaultValue: "Completed")
    }

    public static var notCompletedLabel: String {
        String(localized: "training.plannedActivity.notCompleted", defaultValue: "Not yet logged")
    }

    public static var noneOptionLabel: String {
        String(localized: "training.linkPicker.none", defaultValue: "None")
    }

    public static var noPlannedActivitiesToday: String {
        String(localized: "training.plannedActivities.empty", defaultValue: "Nothing planned for today")
    }

    public static var noLoggedActivitiesToday: String {
        String(localized: "training.loggedActivities.empty", defaultValue: "Nothing logged yet today")
    }
}
