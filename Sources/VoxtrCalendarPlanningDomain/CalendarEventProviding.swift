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
///
/// PR #39 review follow-up (Blocker 2): `eventIdentifier` is NOT unique
/// per occurrence of a RECURRING event — Apple documents that every
/// concrete occurrence of the same recurring series shares the SAME
/// `EKEvent.eventIdentifier`. The earlier version of this type (and the
/// coordination service built on it) assumed each occurrence carried its
/// own `eventIdentifier`; that assumption was never verified against the
/// real API and was wrong. `occurrenceDate` is the field Apple actually
/// documents for this purpose (`EKEvent.occurrenceDate`): the specific
/// occurrence's original scheduled date, stable even if that occurrence
/// is later detached and its `startDate` moved. For a recurring event,
/// occurrence identity is therefore `(eventIdentifier, occurrenceDate)`
/// together, never `eventIdentifier` alone.
///
/// PR #39 review follow-up (second round): that composite rule does NOT
/// extend to an ORDINARY, non-recurring event. `eventIdentifier` alone is
/// already a stable, sufficient identity for a non-recurring event's
/// entire lifetime; a first version of this fix folded `occurrenceDate`
/// into EVERY event's identity unconditionally, which meant simply
/// moving an ordinary event's start time changed its own identity (since
/// `occurrenceDate` defaults to, and for a non-recurring event always
/// tracks, `startDate`) and produced a duplicate `PlannedActivity`
/// instead of updating the original — a genuine regression, now fixed.
/// See `CalendarPlanningCoordinationService.externalSourceId(calendarIdentifier:event:)`
/// for the exact rule: `occurrenceDate` participates in identity ONLY
/// when `isRecurring` is `true`.
public struct ExternalCalendarEvent: Sendable, Equatable {
    public let eventIdentifier: String
    /// `EKEvent.occurrenceDate` — the stable identity of THIS specific
    /// occurrence within its series, meaningful for identity purposes
    /// ONLY when `isRecurring` is `true` (see this type's own doc comment
    /// above). Defaults to `startDate` when not supplied explicitly,
    /// matching what a genuinely non-recurring `EKEvent` itself reports
    /// — though for a non-recurring event this value is never actually
    /// consulted for identity at all.
    public let occurrenceDate: Date
    public let calendarIdentifier: String
    public let title: String?
    public let startDate: Date
    public let endDate: Date?
    public let isAllDay: Bool
    /// Calendar V1 metadata inspection round: `notes`/`location`/`url`
    /// below are DIAGNOSTIC ONLY — read-only display text for the
    /// Alpha-only inspection surface (`CalendarPlanningCoordinationService.fetchDiagnosticEvents(inCalendar:)`),
    /// never part of `externalSourceId` identity and never consulted for
    /// any create/update/cancel decision reconciliation makes. They
    /// exist so a Product Owner can see what a real external source
    /// actually populates before any matching-rule model is designed —
    /// this round explicitly does not implement matching/classification
    /// from them.
    public let notes: String?
    public let location: String?
    public let url: URL?
    /// The provider-neutral statement: this concrete external event
    /// belongs to a recurring series and therefore requires
    /// occurrence-based identity (see `CalendarPlanningCoordinationService.externalSourceId(calendarIdentifier:event:)`).
    /// This slice never creates or infers a Vǫxtr recurrence rule from
    /// it (see `CalendarPlanningCoordinationService`'s own doc comment)
    /// — every occurrence EventKit returns for a recurring series is
    /// still just one more `ExternalCalendarEvent`, imported (or not)
    /// independently like any other.
    ///
    /// PR #39 review follow-up (final EventKit classification round):
    /// no longer "informational only" — this field is now load-bearing
    /// for identity, so the production adapter's own classification of
    /// it must be correct for every case EventKit can report, including
    /// a DETACHED occurrence (see `EventKitCalendarEventProvider`'s own
    /// doc comment on this assignment for exactly which EventKit
    /// properties that requires).
    public let isRecurring: Bool

    public init(
        eventIdentifier: String,
        occurrenceDate: Date? = nil,
        calendarIdentifier: String,
        title: String?,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        isRecurring: Bool,
        notes: String? = nil,
        location: String? = nil,
        url: URL? = nil
    ) {
        self.eventIdentifier = eventIdentifier
        self.occurrenceDate = occurrenceDate ?? startDate
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
        self.notes = notes
        self.location = location
        self.url = url
    }
}

/// PR #39 review follow-up (Blocker 1): thrown by `CalendarEventProviding.events(inCalendar:from:to:)`
/// when the source calendar itself could not be read — e.g. it no
/// longer exists, or the underlying store cannot currently resolve it —
/// as distinct from a genuine, authoritative empty result (`[]`, "this
/// calendar was read successfully and has no matching events right
/// now"). Only an authoritative empty result may be treated as evidence
/// that previously-imported events disappeared; `calendarUnavailable`
/// must never be interpreted as cancellation. See
/// `CalendarPlanningCoordinationService.reconcile(_:)`'s own doc comment
/// for how this is enforced.
public enum CalendarEventProviderError: Error, Sendable, Equatable {
    case calendarUnavailable
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
    ///
    /// PR #39 review follow-up (Blocker 1): the result MUST distinguish
    /// two genuinely different states, and an implementation must never
    /// collapse them into the same `[]`:
    ///   - the calendar was read successfully and authoritatively
    ///     contains no matching events right now — returns `[]`;
    ///   - the calendar could not be read at all (removed, unresolvable,
    ///     store error) — throws `CalendarEventProviderError.calendarUnavailable`,
    ///     never `[]`.
    /// Only the first case is evidence that a previously-imported event
    /// disappeared; reconciliation relies on this distinction to avoid
    /// treating a transient/permanent read failure as mass cancellation.
    func events(inCalendar calendarIdentifier: String, from: Date, to: Date) throws -> [ExternalCalendarEvent]
}
