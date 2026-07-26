import Foundation

/// Sprint 13 (architecture correction): same rationale as
/// `WeeklyReviewStrings`/`TrainingStrings`/`CoachingPresentationStrings`.
/// Holds only what's genuinely new for Daily Focus — the empty-state
/// text. Everything else the feature shows is reused as-is from
/// existing strings/data: an incomplete activity's own title,
/// `TrainingStrings.notCompletedLabel` as its subtitle, and a coaching
/// item's own `text`/section `title`. None of that is duplicated here.
///
/// `unavailable` was removed — it was defined in Sprint 13 but never
/// actually referenced by `DailyFocusCardView` (both `.loading` and
/// `.failed` render `EmptyView()`, per this feature's own "hide the
/// card, do not invent fallback content" rule), so it was dead code
/// from the start.
public enum DailyFocusStrings {
    /// Deliberately plain and factual, not celebratory — "nothing
    /// needs attention" is not the same claim as "everything is going
    /// well," which this project has already established it must never
    /// invent.
    public static var nothingNeedsAttention: String {
        String(localized: "dailyFocus.empty", defaultValue: "Nothing needs your attention today.")
    }
}
