import Foundation

/// Sprint 13: same rationale as `WeeklyReviewStrings`/`TrainingStrings`/
/// `CoachingPresentationStrings`. Holds only what's genuinely new for
/// Daily Focus — the empty-state and unavailable-state text. Everything
/// else the feature shows is reused as-is from existing strings/data:
/// an incomplete activity's own title, `TrainingStrings.notCompletedLabel`
/// as its subtitle, and a coaching item's own `text`/section `title`.
/// None of that is duplicated here.
public enum DailyFocusStrings {
    /// Deliberately plain and factual, not celebratory — "nothing
    /// needs attention" is not the same claim as "everything is going
    /// well," which this project has already established it must never
    /// invent.
    public static var nothingNeedsAttention: String {
        String(localized: "dailyFocus.empty", defaultValue: "Nothing needs your attention today.")
    }

    public static var unavailable: String {
        String(localized: "dailyFocus.unavailable", defaultValue: "Daily focus isn't available right now.")
    }
}
