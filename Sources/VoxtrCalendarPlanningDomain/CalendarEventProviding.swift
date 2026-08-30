import Foundation

/// The THREE permission states this feature distinguishes — deliberately
/// not `EKAuthorizationStatus` itself (`.fullAccess`/`.writeOnly`/
/// `.restricted` collapse into `.authorized`/`.denied` here), matching
/// `ActivityReminderAuthorizationStatus`'s own established shape so no
/// layer above the production adapter imports `EventKit`.
public enum CalendarAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

/// One calendar the OS reports as available to read from — the list a
/// Parent picks from during setup. Deliberately minimal: identity +
/// a display title, nothing else.
public struct AvailableCalendar: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// The calendar's own source name (e.g. an iCloud/Google account, or
    /// "Subscribed") — shown alongside `title` so two calendars named
    /// identically in different accounts are still distinguishable.
    public let sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

/// One external calendar event, normalized to the plain facts Planning
/// import needs — never an `EKEvent`. This is the provider boundary's
/// OWN neutral shape: a future non-EventKit provider returns the same
/// type, so nothing above `CalendarEventProviding` ever needs to know
/// which provider produced it.
///
/// `eventIdentifier` is EventKit's `EKEvent.eventIdentifier` — Apple
/// documents this as not guaranteed stable across a database rebuild
/// (e.g. re-adding an account); see `CalendarEventProviding`'s own doc
/// comment for how this V1 slice treats that risk.
public struct ExternalCalendarEvent: Sendable, Equatable {
    public let eventIdentifier: String
    public let calendarIdentifier: String
    public let title: String?
    public let startDate: Date
    public let endDate: Date?
    public let isAllDay: Bool
    /// Informational only — this slice never creates or infers a Vǫxtr
    /// recurrence rule from it (see `CalendarPlanningCoordinationService`'s
    /// own doc comment). Every occurrence EventKit returns for a
    /// recurring series is still just one more `ExternalCalendarEvent`,
    /// imported (or not) independently like any other.
    public let isRecurring: Bool

    public init(
        eventIdentifier: String,
        calendarIdentifier: String,
        title: String?,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        isRecurring: Bool
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
    }
}

/// The ONE boundary between Planning import/sync and whatever actually
/// reads external calendar data. Calendar/EventKit is the FIRST
/// provider this V1 slice validates — never architecturally the only
/// one a future round could add; a direct Spond (or other) provider
/// would conform to this exact protocol, and nothing above it
/// (`CalendarPlanningCoordinationService`, Planning, tests) would need
/// to change.
///
/// Permission calls are completion-based, matching this project's own
/// established `ActivityReminderScheduling` boundary shape and
/// EventKit's own genuinely asynchronous `requestFullAccessToEvents`;
/// `completion` is `@MainActor`-qualified so a caller already on
/// `@MainActor` (every real caller) acts on the result directly.
/// Reading calendars/events is a plain throwing, SYNCHRONOUS call —
/// `EKEventStore.calendars(for:)`/`events(matching:)` are themselves
/// synchronous, so this boundary stays honest to the real API shape
/// rather than wrapping an already-synchronous call in artificial
/// asynchrony.
public protocol CalendarEventProviding: Sendable {
    func authorizationStatus(completion: @escaping @MainActor @Sendable (CalendarAuthorizationStatus) -> Void)
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void)

    /// Every calendar the OS currently reports as readable. Only
    /// meaningful once `authorizationStatus` reports `.authorized`;
    /// implementations may return an empty list otherwise rather than
    /// throwing, since "nothing to choose from yet" is the correct,
    /// calm state before permission is granted.
    func availableCalendars() throws -> [AvailableCalendar]

    /// Every event in `calendarIdentifier` whose start falls within
    /// `[from, to]` — the reconciliation window
    /// `CalendarPlanningCoordinationService` computes and owns; this
    /// protocol has no opinion on how wide that window should be.
    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) throws -> [ExternalCalendarEvent]
}
