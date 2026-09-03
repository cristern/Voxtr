import Foundation

/// v1.3 Section 3: "YYYY-MM-DD value. No timezone. Used for athlete-local
/// calendar dates." Deliberately not `Date` — a calendar day has no time
/// component and must not shift with timezone math.
public struct LocalDate: Hashable, Codable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public init?(isoString: String) {
        let parts = isoString.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let parsed = LocalDate(isoString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid LocalDate string: \(string)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }

    /// UTC-anchored `Calendar` used only for pure calendar arithmetic on
    /// a `LocalDate`'s own (year, month, day) — deliberately never tied
    /// to `Calendar.current`/`TimeZone.current`, so `weekday` and
    /// `adding(days:)` below never depend on, or shift with, the
    /// device's current time zone or "now."
    private static var arithmeticCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// The day of the week this date falls on, computed purely from
    /// (year, month, day) — see `arithmeticCalendar` above for why this
    /// is safe from device-local midnight/timezone drift.
    public var weekday: Weekday {
        let components = DateComponents(year: year, month: month, day: day)
        let date = Self.arithmeticCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let rawWeekday = Self.arithmeticCalendar.component(.weekday, from: date)
        return Weekday(rawValue: rawWeekday) ?? .sunday
    }

    /// Returns a new `LocalDate` offset by the given number of days
    /// (negative moves earlier). Pure calendar arithmetic — see
    /// `arithmeticCalendar` above.
    public func adding(days: Int) -> LocalDate {
        let components = DateComponents(year: year, month: month, day: day)
        let date = Self.arithmeticCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let shifted = Self.arithmeticCalendar.date(byAdding: .day, value: days, to: date) ?? date
        let shiftedComponents = Self.arithmeticCalendar.dateComponents([.year, .month, .day], from: shifted)
        return LocalDate(
            year: shiftedComponents.year ?? year,
            month: shiftedComponents.month ?? month,
            day: shiftedComponents.day ?? day
        )
    }

    /// The canonical, deterministic start (Monday) of the Vǫxtr
    /// planning/training week this date falls in — a MONDAY → SUNDAY
    /// week, per Vǫxtr's own product semantics, never dependent on the
    /// device's locale-configured `Calendar.current.firstWeekday`
    /// (which varies — e.g. Sunday-first in a US locale — and would
    /// otherwise make which dates belong to the same planning week
    /// change depending on where the app is running). Computed purely
    /// from `weekday` (itself already locale-independent, see that
    /// property's own doc comment) and `adding(days:)` — no `Calendar`
    /// consulted for the week-boundary logic itself, only for the
    /// underlying (year, month, day) arithmetic both of those already
    /// use. This is the one, canonical implementation of Vǫxtr's week
    /// boundary — every week-start call site in the app should compute
    /// through this, not reimplement the same offset separately.
    public var startOfWeek: LocalDate {
        // Weekday.monday.rawValue == 2 (Weekday's own 1=Sunday...7=Saturday
        // numbering, see Weekday's definition) — this offset counts how
        // many days back to the most recent Monday, wrapping correctly
        // for Sunday (6 days back) through Saturday (5 days back).
        let daysSinceMonday = (weekday.rawValue - Weekday.monday.rawValue + 7) % 7
        return adding(days: -daysSinceMonday)
    }
}

/// Day of the week, independent of any specific `Calendar`/locale
/// week-start convention. Raw values match `Foundation`'s own
/// `Calendar.Component.weekday` numbering (1 = Sunday ... 7 =
/// Saturday) so `LocalDate.weekday` above can convert directly,
/// without a separate mapping table to keep in sync.
///
/// Deliberately NOT added to `SharedEnums.swift` — that file's own doc
/// comment states its enum list is closed for v1.3 per the Domain &
/// Data Model document. `Weekday` is a general calendar primitive, the
/// same category as `LocalDate`/`LocalTime`/`TimeZoneId` already in
/// this file, not a v1.3 domain concept — it belongs alongside them,
/// not in that closed list.
public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// v1.3 Section 3: "HH:mm value. No timezone. Combined with time zone at
/// scheduling boundary."
public struct LocalTime: Hashable, Codable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// Planned Activity Time Range Presentation: this time of day plus
    /// `minutes`, wrapped correctly across hour and midnight boundaries —
    /// pure modular arithmetic on (hour, minute), deliberately never
    /// going through `Date`/`Calendar`/a time zone, since "what clock
    /// time is N minutes after this one" needs none of those. Crossing
    /// midnight wraps back to `00:00` rather than producing an
    /// out-of-range hour or crashing — this intentionally does not
    /// track which calendar day the result falls on; callers needing
    /// that would need a `LocalDate` too, which this type has no
    /// knowledge of.
    public func adding(minutes: Int) -> LocalTime {
        let totalMinutes = ((hour * 60 + minute + minutes) % 1440 + 1440) % 1440
        return LocalTime(hour: totalMinutes / 60, minute: totalMinutes % 60)
    }
}

/// v1.3 Section 3: "IANA string. Example: Europe/Oslo."
public struct TimeZoneId: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var timeZone: TimeZone? { TimeZone(identifier: rawValue) }
}

/// Notifications V1 Activity Reminder Foundation: thrown by
/// `LocalDate.absoluteDate(at:in:)` when the supplied `TimeZoneId` or the
/// requested local date/time cannot be resolved to a real instant.
/// Mirrors `ActivityIdentityError`'s own shape (`Error, Sendable,
/// Equatable`, a small closed enum) — the same catchable-failure
/// convention this file's neighboring contracts already establish,
/// rather than a crash or a silent fallback to the device's current
/// time zone.
public enum LocalDateTimeConversionError: Error, Sendable, Equatable {
    /// `timeZoneId.rawValue` is not a timezone identifier `Foundation`
    /// recognizes (`TimeZone(identifier:)` returned `nil`).
    case invalidTimeZoneIdentifier(String)
    /// The timezone identifier was valid, but the given (date, time)
    /// combination could not be resolved to an instant in it. In
    /// practice `Calendar.date(from:)` is effectively total for valid
    /// Gregorian components, so this is a defensive case, not one this
    /// function's own tests expect to exercise via any real input.
    case unresolvableLocalDateTime
}

public extension LocalDate {
    /// The ONE canonical way to combine a calendar day, a time of day,
    /// and an explicit IANA time zone into an absolute `Date` instant —
    /// v1.3 Section 3's own description of `LocalTime` ("combined with
    /// time zone at scheduling boundary") names exactly this operation,
    /// which did not previously exist anywhere in this codebase (the
    /// Notifications V1 Repository Audit's own finding). Every call site
    /// that needs "when does this local date/time actually happen" —
    /// starting with Activity Reminder scheduling — must go through this,
    /// never hand-roll `Calendar.current`-based arithmetic of its own.
    ///
    /// Deterministic by construction: `timeZone` is set explicitly from
    /// the supplied `TimeZoneId` before any component math runs, so the
    /// result never depends on `TimeZone.current`/`Calendar.current` or
    /// the machine's own local settings — the same "no locale-dependent
    /// week identity" principle this file's `LocalDate.startOfWeek`
    /// already applies to calendar-day arithmetic, extended here to
    /// time-of-day + time zone resolution. DST is handled correctly as a
    /// consequence of using `Foundation`'s own `Calendar`/`TimeZone`
    /// resolution for the supplied zone, not by any special-casing here.
    func absoluteDate(at time: LocalTime, in timeZoneId: TimeZoneId) throws -> Date {
        guard let timeZone = timeZoneId.timeZone else {
            throw LocalDateTimeConversionError.invalidTimeZoneIdentifier(timeZoneId.rawValue)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard let date = calendar.date(from: components) else {
            throw LocalDateTimeConversionError.unresolvableLocalDateTime
        }
        return date
    }
}

/// v1.3 Section 3: "Int. Starts at 1 and increments on accepted
/// authoritative mutation." Individual entity field tables (e.g.
/// WeekPlan.revision) specify plain `Int` for their own revision field —
/// this type exists for future entities that adopt the same optimistic
/// concurrency pattern, not to replace WeekPlan's already-specified field.
public struct EntityRevision: Hashable, Codable, Sendable, RawRepresentable, Comparable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let initial = EntityRevision(rawValue: 1)

    public static func < (lhs: EntityRevision, rhs: EntityRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
