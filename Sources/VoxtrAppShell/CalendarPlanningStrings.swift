import Foundation

/// Family-Owned Calendar Sources V1: centralizes this feature's user-
/// facing strings built as plain `String` values, matching
/// `PlanningStrings`'s own established rationale. Calm, plain language
/// throughout — no provider-architecture jargon (no "provenance,"
/// "reconciliation," "external identity," "source," or "decision" as
/// internal terms shown to a Parent — "source" itself is kept since it
/// reads naturally as "a calendar you connected").
public enum CalendarPlanningStrings {
    // MARK: - Family Calendar Sources

    public static var screenTitle: String {
        String(localized: "calendarPlanning.screenTitle", defaultValue: "Calendar Sources")
    }

    public static var connectCalendarExplanation: String {
        String(
            localized: "calendarPlanning.connectExplanation",
            defaultValue: "Connect a calendar to bring its events in for review. Nothing becomes part of anyone's plan until you choose who it belongs to."
        )
    }

    public static var connectCalendarButton: String {
        String(localized: "calendarPlanning.connectButton", defaultValue: "Connect Calendar")
    }

    public static var connectAnotherCalendarButton: String {
        String(localized: "calendarPlanning.connectAnotherButton", defaultValue: "Connect another calendar")
    }

    public static var authorizationDenied: String {
        String(
            localized: "calendarPlanning.authorizationDenied",
            defaultValue: "Vǫxtr can't read your calendars. Turn on calendar access in Settings to connect one."
        )
    }

    public static var openSettings: String {
        String(localized: "calendarPlanning.openSettings", defaultValue: "Open Settings")
    }

    public static var chooseCalendar: String {
        String(localized: "calendarPlanning.chooseCalendar", defaultValue: "Choose a calendar")
    }

    public static var noCalendarsFound: String {
        String(
            localized: "calendarPlanning.noCalendarsFound",
            defaultValue: "No calendars were found on this device."
        )
    }

    public static var saveSource: String {
        String(localized: "calendarPlanning.saveSource", defaultValue: "Connect")
    }

    public static var enabledLabel: String {
        String(localized: "calendarPlanning.enabledLabel", defaultValue: "Bring in events from this calendar")
    }

    public static var syncNow: String {
        String(localized: "calendarPlanning.syncNow", defaultValue: "Sync now")
    }

    public static var disconnect: String {
        String(localized: "calendarPlanning.disconnect", defaultValue: "Disconnect calendar")
    }

    public static var duplicateSourceError: String {
        String(
            localized: "calendarPlanning.duplicateSourceError",
            defaultValue: "This calendar is already connected."
        )
    }

    public static var genericError: String {
        String(localized: "calendarPlanning.genericError", defaultValue: "Something went wrong. Please try again.")
    }

    /// Lead Review follow-up (Blocker 4): shown when the Parent's
    /// chosen Athlete/Sport/Activity Type conflicts with an existing
    /// import for this exact event — calm, specific, and points at the
    /// actual recovery action rather than a generic failure.
    public static var existingActivityConflictError: String {
        String(
            localized: "calendarPlanning.existingActivityConflictError",
            defaultValue: "This event was already imported with a different athlete or sport. Remove the existing import from this calendar's recovery action, then try again."
        )
    }

    /// Lead Review follow-up (Blocker 2): shown if a source was
    /// disabled/disconnected after Import Review was opened.
    public static var sourceDisabledError: String {
        String(
            localized: "calendarPlanning.sourceDisabledError",
            defaultValue: "This calendar is no longer active. Turn it back on to review and import its events."
        )
    }

    public static func lastSynced(_ outcome: (updated: Int, cancelled: Int, skipped: Int)) -> String {
        String(
            localized: "calendarPlanning.lastSynced",
            defaultValue: "Last sync: \(outcome.updated) updated, \(outcome.cancelled) removed."
        )
    }

    // MARK: - Recovery

    public static var removeImportedActivitiesButton: String {
        String(localized: "calendarPlanning.removeImportedActivitiesButton", defaultValue: "Remove imported activities")
    }

    public static var removeImportedActivitiesConfirmationTitle: String {
        String(localized: "calendarPlanning.removeImportedActivitiesConfirmationTitle", defaultValue: "Remove imported activities?")
    }

    /// Calm, concrete confirmation copy — states exactly what will and
    /// won't happen, no alarming language. `sourceDisplayName` is
    /// interpolated so the Parent sees exactly which calendar is
    /// affected; this action can affect more than one athlete's plan,
    /// since a source is not athlete-scoped.
    public static func removeImportedActivitiesConfirmationMessage(sourceDisplayName: String) -> String {
        String(
            localized: "calendarPlanning.removeImportedActivitiesConfirmationMessage",
            defaultValue: "Imported future planning activities from \(sourceDisplayName) will be removed, for every athlete they were added to. Completed and logged training will stay untouched."
        )
    }

    public static func removeImportedActivitiesResult(
        _ outcome: (removed: Int, preservedLogged: Int, historicalWeeksSkipped: Int, failed: Int, lifecycleRestoreFailed: Int)
    ) -> String {
        var parts = ["\(outcome.removed) removed"]
        if outcome.preservedLogged > 0 { parts.append("\(outcome.preservedLogged) kept (already logged)") }
        if outcome.historicalWeeksSkipped > 0 { parts.append("\(outcome.historicalWeeksSkipped) kept (past week)") }
        if outcome.failed > 0 { parts.append("\(outcome.failed) could not be removed") }
        if outcome.lifecycleRestoreFailed > 0 {
            parts.append("\(outcome.lifecycleRestoreFailed) week(s) need review (still open)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Metadata inspection (Alpha-only)

    public static var inspectEventsButton: String {
        String(localized: "calendarPlanning.inspectEventsButton", defaultValue: "Inspect calendar events (Alpha)")
    }

    public static var inspectEventsExplanation: String {
        String(
            localized: "calendarPlanning.inspectEventsExplanation",
            defaultValue: "A read-only preview of upcoming events from this calendar, for testing what information is available. Nothing shown here is saved."
        )
    }

    public static var inspectEventsEmpty: String {
        String(localized: "calendarPlanning.inspectEventsEmpty", defaultValue: "No upcoming events found in this window.")
    }

    // MARK: - Calendar Import Review

    public static var reviewEventsButton: String {
        String(localized: "calendarPlanning.reviewEventsButton", defaultValue: "Review new events")
    }

    public static func reviewEventsButtonWithCount(_ count: Int) -> String {
        count > 0
            ? String(localized: "calendarPlanning.reviewEventsButtonWithCount", defaultValue: "Review new events (\(count))")
            : reviewEventsButton
    }

    public static var reviewScreenTitle: String {
        String(localized: "calendarPlanning.reviewScreenTitle", defaultValue: "Review New Events")
    }

    public static var reviewEmpty: String {
        String(
            localized: "calendarPlanning.reviewEmpty",
            defaultValue: "Nothing new to review right now."
        )
    }

    public static var reviewExplanation: String {
        String(
            localized: "calendarPlanning.reviewExplanation",
            defaultValue: "Choose who each event belongs to, or ignore it. Nothing here affects anyone's plan until you choose Import."
        )
    }

    public static var chooseAthlete: String {
        String(localized: "calendarPlanning.chooseAthlete", defaultValue: "Athlete")
    }

    public static var chooseActivityType: String {
        String(localized: "calendarPlanning.chooseActivityType", defaultValue: "Activity type")
    }

    public static var chooseSport: String {
        String(localized: "calendarPlanning.chooseSport", defaultValue: "Sport")
    }

    public static var importButton: String {
        String(localized: "calendarPlanning.importButton", defaultValue: "Import")
    }

    public static var ignoreButton: String {
        String(localized: "calendarPlanning.ignoreButton", defaultValue: "Ignore")
    }

    public static var ignoreConfirmationTitle: String {
        String(localized: "calendarPlanning.ignoreConfirmationTitle", defaultValue: "Ignore this event?")
    }

    /// Calendar Import Review runtime fix: Ignore is reversible (see
    /// `reviewAgainButton`/`ignoredSectionTitle` below) — this copy no
    /// longer claims it is permanent.
    public static var ignoreConfirmationMessage: String {
        String(
            localized: "calendarPlanning.ignoreConfirmationMessage",
            defaultValue: "This event will not be added to Planning. You can restore it later."
        )
    }

    // MARK: - Calendar Import Review V1.1 (Inline Review + Ready Staging + Bulk Import)

    public static var needsReviewSectionTitle: String {
        String(localized: "calendarPlanning.needsReviewSectionTitle", defaultValue: "Needs Review")
    }

    public static var readyToImportSectionTitle: String {
        String(localized: "calendarPlanning.readyToImportSectionTitle", defaultValue: "Ready to Import")
    }

    public static var readyBadge: String {
        String(localized: "calendarPlanning.readyBadge", defaultValue: "Ready")
    }

    public static var editButton: String {
        String(localized: "calendarPlanning.editButton", defaultValue: "Edit")
    }

    /// Lead Review follow-up: the ONE explicit Parent action that
    /// collapses a Needs Review row into Ready to Import — never an
    /// automatic side effect of picking Athlete/Sport/Activity Type.
    public static var markReadyButton: String {
        String(localized: "calendarPlanning.markReadyButton", defaultValue: "Ready")
    }

    public static func bulkImportButton(readyCount: Int) -> String {
        String(localized: "calendarPlanning.bulkImportButton", defaultValue: "Import \(readyCount) ready activities")
    }

    /// PR #49 follow-up (zero-ready top action copy): the top-level
    /// action area's summary/button text when there are ZERO Ready items
    /// but at least one Suggested Ignore item — see
    /// `CalendarImportReviewViewModel.TopActionState.suggestedIgnoreOnly`'s
    /// own doc comment. Never "Import 0" — this describes the actual
    /// action tapping the button performs (opening the SAME Suggested
    /// Ignore confirmation dialog `.readyToImport` also uses).
    public static func suggestedIgnoreOnlySummary(count: Int) -> String {
        String(localized: "calendarPlanning.suggestedIgnoreOnlySummary", defaultValue: "\(count) suggested ignores to review")
    }

    public static func suggestedIgnoreOnlyButton(count: Int) -> String {
        String(localized: "calendarPlanning.suggestedIgnoreOnlyButton", defaultValue: "Review \(count)")
    }

    /// Shown after `bulkImportReadyItems()` completes with at least one
    /// per-item failure — a calm, concrete count, never a silent
    /// whole-batch success/failure claim. Successfully imported items
    /// already disappeared from the queue; the failed ones are visible,
    /// with their own reason, in Needs Attention (V1.3) — this summary
    /// is never the only place a failure is surfaced.
    public static func bulkImportPartialResult(imported: Int, failed: Int) -> String {
        String(
            localized: "calendarPlanning.bulkImportPartialResult",
            defaultValue: "\(imported) imported. \(failed) need attention."
        )
    }

    /// V1.3 (Needs Attention), PR #48 follow-up (copy correction): the
    /// calm reason shown for a `PlanningServiceError.invalidField`
    /// failure. `CalendarImportReviewViewModel.needsAttentionReason(forPlanningServiceError:)`
    /// maps every `.invalidField` case to this ONE string without
    /// inspecting the error's own associated field-description String,
    /// so this copy must stay true for EVERY validation bound
    /// `PlanningService`'s genuinely-new creation path can throw
    /// `.invalidField` for — not just an over-length field (e.g. also
    /// "title or sportId is required", a MISSING-field case, not a too-
    /// long one). Deliberately does not claim anything is "too long"
    /// unless the caught error actually proves that.
    public static var bulkImportInvalidFieldError: String {
        String(
            localized: "calendarPlanning.bulkImportInvalidFieldError",
            defaultValue: "Some calendar information couldn't be imported. Review the activity and try again."
        )
    }

    /// V1.3 (Needs Attention): the generic, safe fallback reason for any
    /// bulk-import failure this screen cannot map to a more specific,
    /// calm explanation — never a raw internal error dump.
    public static var bulkImportGenericItemError: String {
        String(localized: "calendarPlanning.bulkImportGenericItemError", defaultValue: "Couldn't import this activity. Review it and try again.")
    }

    // MARK: - Calendar Import Review runtime fix (inline details, reversible Ignore)

    /// The same-row progressive-disclosure toggle for an event's
    /// notes/location — replaces the prior separate pushed detail
    /// screen; never required for classification.
    public static var detailsDisclosureLabel: String {
        String(localized: "calendarPlanning.detailsDisclosureLabel", defaultValue: "Details")
    }

    public static var ignoredSectionTitle: String {
        String(localized: "calendarPlanning.ignoredSectionTitle", defaultValue: "Ignored")
    }

    public static var ignoredBadge: String {
        String(localized: "calendarPlanning.ignoredBadge", defaultValue: "Ignored")
    }

    /// The explicit reverse-Ignore action — restores one event to Needs
    /// Review by deleting its `.ignored` decision only; never creates a
    /// `PlannedActivity`.
    public static var reviewAgainButton: String {
        String(localized: "calendarPlanning.reviewAgainButton", defaultValue: "Review again")
    }

    // MARK: - Calendar Import Review action fix (top-level Import shortcut)

    /// The calm summary text next to the top-level Import shortcut —
    /// shown only while `readyToImportCount > 0`; the count is the SAME
    /// `viewModel.readyToImportCount` the Ready to Import section itself
    /// already uses, never a separately computed figure.
    public static func readyToImportSummary(count: Int) -> String {
        String(localized: "calendarPlanning.readyToImportSummary", defaultValue: "\(count) ready to import")
    }

    // MARK: - Calendar Import Review V1.2 (Similar-Event Suggestions)

    /// Shown near the pickers on a Needs Review row whose staged values
    /// were prefilled from a similar (not identical) prior event — never
    /// a numeric confidence, percentage, or "AI suggestion" framing; the
    /// Parent can freely override any picker, and the event stays in
    /// Needs Review until they explicitly tap Ready.
    public static var similarSuggestionExplanation: String {
        String(localized: "calendarPlanning.similarSuggestionExplanation", defaultValue: "Suggested from a similar previous event")
    }

    /// Optional, calm attribution of WHICH prior event a similar
    /// suggestion came from — `title` is that prior event's own original
    /// (non-normalized) title.
    public static func similarSuggestionBasedOn(title: String) -> String {
        String(localized: "calendarPlanning.similarSuggestionBasedOn", defaultValue: "Based on: \(title)")
    }

    // MARK: - Calendar Import Review V1.3 (Needs Attention, Suggested Ignore)

    public static var needsAttentionSectionTitle: String {
        String(localized: "calendarPlanning.needsAttentionSectionTitle", defaultValue: "Needs Attention")
    }

    public static var suggestedIgnoreSectionTitle: String {
        String(localized: "calendarPlanning.suggestedIgnoreSectionTitle", defaultValue: "Suggested Ignore")
    }

    /// Shown on a Suggested Ignore row — never "AI", a confidence
    /// percentage, or a score; the Parent decides, this only explains
    /// why the row is here.
    public static var suggestedIgnoreExplanation: String {
        String(localized: "calendarPlanning.suggestedIgnoreExplanation", defaultValue: "Suggested ignore based on a previous event")
    }

    /// Optional, calm attribution of WHICH prior explicitly-ignored
    /// event a Suggested Ignore came from — `title` is that prior
    /// event's own original (non-normalized) title.
    public static func suggestedIgnoreBasedOn(title: String) -> String {
        String(localized: "calendarPlanning.suggestedIgnoreBasedOn", defaultValue: "Based on: \(title)")
    }

    /// The Suggested Ignore row's primary action — moves the event back
    /// into normal Needs Review for this session; persists nothing (see
    /// `CalendarImportReviewViewModel.reviewSuggestedIgnore(_:)`'s own
    /// doc comment).
    public static var reviewSuggestedIgnoreButton: String {
        String(localized: "calendarPlanning.reviewSuggestedIgnoreButton", defaultValue: "Review")
    }

    // MARK: - Import-time Suggested Ignore confirmation

    /// Shown only when the Parent taps the top-level Import action while
    /// `suggestedIgnoreItems` is non-empty — calm, explicit, never "AI",
    /// a confidence score, or urgency framing (see
    /// `CalendarImportReviewViewModel.confirmSuggestedIgnoresAndImportReadyItems()`'s
    /// own doc comment for what confirming actually does).
    public static var suggestedIgnoreConfirmationTitle: String {
        String(localized: "calendarPlanning.suggestedIgnoreConfirmationTitle", defaultValue: "Ignore suggested activities?")
    }

    public static func suggestedIgnoreConfirmationMessage(count: Int) -> String {
        String(
            localized: "calendarPlanning.suggestedIgnoreConfirmationMessage",
            defaultValue: "You have \(count) activities suggested for Ignore based on previous choices. Are you sure you want to ignore these?"
        )
    }

    /// The confirmation's PRIMARY action — persists every current
    /// Suggested Ignore item as a real `.ignored` decision, then imports
    /// every Ready item. Never the default/only choice; "Review first"
    /// below is always offered alongside it.
    public static var ignoreAndImportButton: String {
        String(localized: "calendarPlanning.ignoreAndImportButton", defaultValue: "Ignore & Import")
    }

    /// The confirmation's SECONDARY action — dismisses without
    /// persisting or importing anything; the Parent stays on the current
    /// screen with Suggested Ignore items still visible for inspection.
    public static var reviewSuggestedIgnoreFirstButton: String {
        String(localized: "calendarPlanning.reviewSuggestedIgnoreFirstButton", defaultValue: "Review first")
    }

    /// Shown only when one or more Suggested Ignore items failed to
    /// persist during a confirmed "Ignore & Import" batch AND
    /// `bulkImportReadyItems()` itself did not already report a more
    /// specific outcome — the successfully-ignored siblings remain
    /// ignored; the failed item(s) simply remain visible as Suggested
    /// Ignore for the Parent to retry or handle individually.
    public static func suggestedIgnoreConfirmationPartialFailure(failed: Int) -> String {
        String(
            localized: "calendarPlanning.suggestedIgnoreConfirmationPartialFailure",
            defaultValue: "\(failed) suggested activities could not be ignored. They remain visible for review."
        )
    }

    // MARK: - Plan/Ahead root (Family Schedule calendar review prompt)

    /// Family Schedule's own calm, contextual entry point — shown ONLY
    /// when `FamilyScheduleViewModel.calendarReviewPrompt.totalPendingCount`
    /// is positive (see that type's own doc comment); `count` is that
    /// SAME canonical total, never a second, locally-computed number.
    public static func familyScheduleCalendarReviewPrompt(count: Int) -> String {
        String(localized: "calendarPlanning.familyScheduleCalendarReviewPrompt", defaultValue: "\(count) calendar events to review")
    }
}
