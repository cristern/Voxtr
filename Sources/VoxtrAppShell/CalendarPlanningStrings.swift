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

    public static var reviewDetailTitle: String {
        String(localized: "calendarPlanning.reviewDetailTitle", defaultValue: "Classify Event")
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

    public static var ignoreConfirmationMessage: String {
        String(
            localized: "calendarPlanning.ignoreConfirmationMessage",
            defaultValue: "This event will never be suggested for import again. It will never become part of anyone's plan."
        )
    }
}
