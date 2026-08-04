import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

// MARK: - RecurringPlannedActivity

/// A parent-defined recurring activity (e.g. "Football, every Monday,
/// 17:30-20:00, 2026-08-10 through 2026-12-14"). Stores the same core
/// planning information `PlannedActivity` stores, so a matching
/// occurrence can be turned into a real `PlannedActivity` without
/// asking the user to re-enter anything. Belongs to exactly one
/// athlete.
///
/// This is a definition only — occurrences for a given week are
/// derived at read time (see `PlanningService.deriveSuggestions`), not
/// persisted here or anywhere else. See `RecurringActivitySuggestion`
/// below for the derived, non-persisted shape.
@Model
public final class RecurringPlannedActivity {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var title: String
    public var activityType: ActivityType
    public var sportId: UUID?
    public var categoryIds: [UUID]
    public var weekday: Weekday
    public var startLocalTime: LocalTime?
    public var plannedDurationMinutes: Int?
    public var timeZoneId: TimeZoneId
    // Same storage fix as WeekPlan.weekStart / PlannedActivity.localDate
    // (see those types' own doc comments): stored as ISO date Strings,
    // not `LocalDate` directly, to avoid the documented SwiftData crash
    // when fetching/sorting rows with differing `LocalDate` values.
    private var effectiveStartDateRaw: String
    private var effectiveEndDateRaw: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: RecurringPlannedActivityId = RecurringPlannedActivityId(),
        athleteId: AthleteId,
        title: String,
        activityType: ActivityType,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        weekday: Weekday,
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        timeZoneId: TimeZoneId,
        effectiveStartDate: LocalDate,
        effectiveEndDate: LocalDate,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((1...120).contains(title.count), "title must be 1-120 characters, matching PlannedActivity's own bound")
        if let duration = plannedDurationMinutes {
            precondition((1...1440).contains(duration), "plannedDurationMinutes must be 1-1440, matching PlannedActivity's own bound")
        }
        precondition(effectiveStartDate <= effectiveEndDate, "effectiveStartDate must be on or before effectiveEndDate")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.title = title
        self.activityType = activityType
        self.sportId = sportId?.rawValue
        self.categoryIds = categoryIds.map(\.rawValue)
        self.weekday = weekday
        self.startLocalTime = startLocalTime
        self.plannedDurationMinutes = plannedDurationMinutes
        self.timeZoneId = timeZoneId
        self.effectiveStartDateRaw = effectiveStartDate.isoString
        self.effectiveEndDateRaw = effectiveEndDate.isoString
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var recurringPlannedActivityId: RecurringPlannedActivityId { RecurringPlannedActivityId(rawValue: id) }

    public var effectiveStartDate: LocalDate {
        get { LocalDate(isoString: effectiveStartDateRaw) ?? LocalDate(year: 1970, month: 1, day: 1) }
        set { effectiveStartDateRaw = newValue.isoString }
    }

    public var effectiveEndDate: LocalDate {
        get { LocalDate(isoString: effectiveEndDateRaw) ?? LocalDate(year: 1970, month: 1, day: 1) }
        set { effectiveEndDateRaw = newValue.isoString }
    }
}

// MARK: - Occurrence identity (duplicate prevention)

public extension RecurringPlannedActivity {
    /// The `externalSourceType` stamped on every `PlannedActivity`
    /// created from a recurring occurrence — reuses the field
    /// `PlannedActivity` already has for exactly this kind of
    /// provenance, rather than adding a new persisted identity field.
    static let externalSourceType = "recurringPlannedActivity"

    /// A deterministic identity for one occurrence of a recurring
    /// activity, derived from the three facts the work package
    /// specifies: the recurring activity's own ID, the occurrence's
    /// local date, and the athlete ID. Stored as `PlannedActivity
    /// .externalSourceId` on the activity created from this occurrence,
    /// and used to detect whether a given occurrence already has one —
    /// this string IS the duplicate-prevention mechanism, not a
    /// separate persisted flag.
    static func occurrenceExternalSourceId(
        recurringPlannedActivityId: RecurringPlannedActivityId,
        occurrenceDate: LocalDate,
        athleteId: AthleteId
    ) -> String {
        "\(recurringPlannedActivityId.rawValue.uuidString)|\(occurrenceDate.isoString)|\(athleteId.rawValue.uuidString)"
    }
}

// MARK: - RecurringActivitySuggestion (derived, not persisted)

/// One occurrence of a recurring activity for a specific week,
/// produced by `PlanningService.deriveSuggestions` — never stored.
/// `id` is the same deterministic occurrence identity described above,
/// which doubles as this suggestion's stable SwiftUI/ViewModel
/// identity (used for session-only dismissal tracking).
public struct RecurringActivitySuggestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let recurringPlannedActivityId: RecurringPlannedActivityId
    public let athleteId: AthleteId
    public let occurrenceDate: LocalDate
    public let title: String
    public let activityType: ActivityType
    public let sportId: SportId?
    public let categoryIds: [ActivityCategoryId]
    public let startLocalTime: LocalTime?
    public let plannedDurationMinutes: Int?
    public let timeZoneId: TimeZoneId

    public init(
        id: String,
        recurringPlannedActivityId: RecurringPlannedActivityId,
        athleteId: AthleteId,
        occurrenceDate: LocalDate,
        title: String,
        activityType: ActivityType,
        sportId: SportId?,
        categoryIds: [ActivityCategoryId],
        startLocalTime: LocalTime?,
        plannedDurationMinutes: Int?,
        timeZoneId: TimeZoneId
    ) {
        self.id = id
        self.recurringPlannedActivityId = recurringPlannedActivityId
        self.athleteId = athleteId
        self.occurrenceDate = occurrenceDate
        self.title = title
        self.activityType = activityType
        self.sportId = sportId
        self.categoryIds = categoryIds
        self.startLocalTime = startLocalTime
        self.plannedDurationMinutes = plannedDurationMinutes
        self.timeZoneId = timeZoneId
    }
}
