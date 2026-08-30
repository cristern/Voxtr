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
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).map { event in
            ExternalCalendarEvent(
                eventIdentifier: event.eventIdentifier,
                calendarIdentifier: calendarIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                isRecurring: event.hasRecurrenceRules
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
