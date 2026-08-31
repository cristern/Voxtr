import EventKit
import Foundation

/// Calendar Planning Source V1: the ONE production conformance of
/// `CalendarEventProviding` — every `EKEventStore`/`EKEvent`/`EKCalendar`
/// touch in this codebase lives behind this file. Tests use their own
/// recording fake; nothing above this boundary imports `EventKit`.
///
/// Read-only: `EKEventStore.requestFullAccessToEvents` is the minimum
/// Apple-supported access level that can read existing events — this
/// slice never creates, edits, or removes a Calendar event (see this
/// package's own "one-way V1" contract).
public final class EventKitCalendarEventProvider: CalendarEventProviding, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func authorizationStatus(completion: @escaping @MainActor @Sendable (CalendarAuthorizationStatus) -> Void) {
        let status = Self.map(EKEventStore.authorizationStatus(for: .event))
        Task { @MainActor in completion(status) }
    }

    public func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    public func availableCalendars() throws -> [AvailableCalendar] {
        store.calendars(for: .event).map {
            AvailableCalendar(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title)
        }
    }

    public func events(inCalendar calendarIdentifier: String, from: Date, to: Date) throws -> [ExternalCalendarEvent] {
        // PR #39 review follow-up (Blocker 1): a calendar that no longer
        // resolves is NOT the same as "read successfully, zero matching
        // events" — the former must never be treated as authoritative
        // evidence that previously-imported events disappeared (see
        // `CalendarEventProviderError`'s own doc comment). Throwing here,
        // rather than returning `[]`, is what lets
        // `CalendarPlanningCoordinationService.reconcile(_:)` tell the
        // two states apart.
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            throw CalendarEventProviderError.calendarUnavailable
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).map { event in
            ExternalCalendarEvent(
                eventIdentifier: event.eventIdentifier,
                // PR #39 review follow-up (Blocker 2): `event.occurrenceDate`,
                // never `event.startDate` — see `ExternalCalendarEvent`'s
                // own doc comment for why `eventIdentifier` alone cannot
                // distinguish occurrences of the same recurring series,
                // and why `occurrenceDate` (not the mutable `startDate`)
                // is the field that stays stable across a detach/move.
                occurrenceDate: event.occurrenceDate,
                calendarIdentifier: calendarIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                // PR #39 review follow-up (final EventKit classification
                // round): `hasRecurrenceRules` alone is NOT sufficient —
                // Apple documents it only as "this calendar item has
                // recurrence rules," and a DETACHED occurrence (one whose
                // attributes were individually modified, e.g. moved to a
                // new time) reports `hasRecurrenceRules == false` on that
                // specific instance even though it is still one concrete
                // occurrence of a recurring series and still needs
                // occurrence-based identity (its `eventIdentifier` is
                // still shared with the rest of the series, and its
                // `occurrenceDate` is still the stable field that
                // distinguishes it). `EKEvent.isDetached` is Apple's own
                // documented signal for exactly this case ("true if and
                // only if the event is part of a repeating event and one
                // or more attributes have been modified"), so it is
                // included here — `hasRecurrenceRules || isDetached` is
                // the smallest correct classification EventKit supports.
                isRecurring: event.hasRecurrenceRules || event.isDetached,
                // Calendar V1 metadata inspection round: passed straight
                // through as EventKit itself reports them, `nil` when
                // absent — never inferred, never defaulted to a
                // fabricated value. See `ExternalCalendarEvent`'s own
                // doc comment: diagnostic-only, no identity/classification
                // use anywhere in this codebase.
                notes: event.notes,
                location: event.location,
                url: event.url
            )
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorizationStatus {
        switch status {
        case .fullAccess:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted, .writeOnly:
            return .denied
        @unknown default:
            return .denied
        }
    }
}
