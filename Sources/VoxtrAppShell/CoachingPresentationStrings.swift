import Foundation

/// Sprint 9: same rationale as `WeeklyReviewStrings`/`TrainingStrings`.
/// All coaching finding TEXT itself already lives in
/// `CoachingPresentationMapper` (Sprint 8) and is not duplicated here —
/// this file holds only UI-owned wording for states the mapper doesn't
/// produce (the pipeline being unavailable).
///
/// Wording is deliberately calm and non-alarming, not "failed to load"
/// or similar — per Sprint 9's explicit requirement that `.attention`
/// and unavailable states must never read as failure, danger, or
/// something the athlete/parent did wrong.
public enum CoachingPresentationStrings {
    public static var unavailable: String {
        String(localized: "coaching.unavailable", defaultValue: "Coaching notes aren't available for this week right now.")
    }

    /// Sprint 10: the label for `CoachingPresentationAction.addParentObservation`'s
    /// button. `WeeklyReviewStrings.startReflectionAction` is reused
    /// as-is for `.startWeeklyReflection` (that action reuses the
    /// existing reflection flow, so its existing label is reused too,
    /// rather than duplicating a second string for the same button).
    public static var addParentObservationAction: String {
        String(localized: "coaching.action.addParentObservation", defaultValue: "Add Observation")
    }
}
