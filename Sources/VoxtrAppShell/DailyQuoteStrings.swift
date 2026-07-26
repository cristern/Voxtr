import Foundation

/// Sprint 15: same rationale as `WeeklyReviewStrings`/`TrainingStrings`/
/// `CoachingPresentationStrings`/`DailyFocusStrings`. The quote's own
/// `text`/`author` are data, rendered as-is (a quote's wording isn't
/// "localized," it's a fixed historical quotation) — this file exists
/// only for the one piece of UI-authored chrome text this feature
/// needs.
public enum DailyQuoteStrings {
    public static var sectionTitle: String {
        String(localized: "dailyQuote.sectionTitle", defaultValue: "Daily Quote")
    }

    /// Sprint 15 (correction): shown when `DailyQuoteViewModel.state`
    /// is `.failed` — a genuine loading failure, not an empty card.
    /// Deliberately calm and factual, matching this project's
    /// established tone for failure states elsewhere
    /// (`CoachingPresentationStrings.unavailable`).
    public static var unavailable: String {
        String(localized: "dailyQuote.unavailable", defaultValue: "Today's quote isn't available right now.")
    }
}
