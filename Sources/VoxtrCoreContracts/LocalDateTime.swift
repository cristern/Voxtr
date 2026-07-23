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
}

/// v1.3 Section 3: "IANA string. Example: Europe/Oslo."
public struct TimeZoneId: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var timeZone: TimeZone? { TimeZone(identifier: rawValue) }
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
