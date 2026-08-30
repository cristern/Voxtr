import Foundation

/// Calendar Planning Source V1: centralizes this feature's user-facing
/// strings built as plain `String` values, matching `PlanningStrings`'s
/// own established rationale. Calm, plain language throughout — no
/// provider-architecture jargon (no "provenance," "reconciliation,"
/// "external identity" shown to a Parent).
public enum CalendarPlanningStrings {
    public static var connectCalendarExplanation: String {
        String(
            localized: "calendarPlanning.connectExplanation",
            defaultValue: "Connect a calendar to bring its events into this athlete's plan automatically."
        )
    }

    public static var connectCalendarButton: String {
        String(localized: "calendarPlanning.connectButton", defaultValue: "Connect Calendar")
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

    public static var saveMapping: String {
        String(localized: "calendarPlanning.saveMapping", defaultValue: "Connect and import events")
    }

    public static var enabledLabel: String {
        String(localized: "calendarPlanning.enabledLabel", defaultValue: "Import events from this calendar")
    }

    public static var syncNow: String {
        String(localized: "calendarPlanning.syncNow", defaultValue: "Sync now")
    }

    public static var disconnect: String {
        String(localized: "calendarPlanning.disconnect", defaultValue: "Disconnect calendar")
    }

    public static var duplicateMappingError: String {
        String(
            localized: "calendarPlanning.duplicateMappingError",
            defaultValue: "This calendar is already connected to this athlete."
        )
    }

    public static var genericError: String {
        String(localized: "calendarPlanning.genericError", defaultValue: "Something went wrong. Please try again.")
    }

    public static func lastSynced(_ outcome: (created: Int, updated: Int, cancelled: Int)) -> String {
        String(
            localized: "calendarPlanning.lastSynced",
            defaultValue: "Last sync: \(outcome.created) added, \(outcome.updated) updated, \(outcome.cancelled) removed."
        )
    }
}
