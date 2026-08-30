import Foundation
import SwiftData
import VoxtrCoreContracts

/// Calendar Planning Source V1: a Parent's explicit, trusted mapping
/// from ONE external calendar (currently EventKit; the type stays
/// provider-neutral in shape) to ONE athlete's Vǫxtr planning context.
///
/// This row is configuration, not schedule data — it never stores an
/// imported event's own facts (title/time/etc). Those live on the
/// `PlannedActivity` created for each qualifying event, through the
/// normal Planning mutation path, exactly like every other Planning
/// write. Reconciliation (in `VoxtrAppShell`, the only place allowed to
/// compose this domain with Planning/Training) reads this row to decide
/// WHERE to look and WHO/WHAT to apply; it is never itself the source
/// of truth for what happened to a specific imported activity.
///
/// One row per (calendar, athlete) pair is the V1 product contract —
/// not enforced by a uniqueness constraint here (same "persistence
/// infrastructure only" boundary every other repository in this
/// project already follows); the coordination service is responsible
/// for not creating a second mapping for the same calendar+athlete.
@Model
public final class CalendarPlanningMapping {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    /// EventKit's `EKCalendar.calendarIdentifier` — see this file's own
    /// `CalendarEventProviding` doc comment for the stability caveats
    /// Apple documents for calendar/event identifiers.
    public var calendarIdentifier: String
    /// Captured once, at mapping time, from the calendar's own `title`
    /// — never re-read from EventKit at display time, so a later
    /// external rename doesn't retroactively relabel a mapping the
    /// Parent already recognizes by its original name.
    public var calendarTitle: String
    public var activityType: ActivityType
    public var sportId: UUID?
    /// Off by default (per-mapping) even after creation — the Parent
    /// must explicitly enable a mapping before anything imports. See
    /// `CalendarPlanningMapping`'s own doc comment.
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Set after every reconciliation attempt for this mapping,
    /// successful or not — presentation-only ("last synced" state), not
    /// itself a business decision input.
    public var lastReconciledAt: Date?
    public var schemaVersion: Int

    public init(
        id: CalendarPlanningMappingId = CalendarPlanningMappingId(),
        athleteId: AthleteId,
        calendarIdentifier: String,
        calendarTitle: String,
        activityType: ActivityType,
        sportId: SportId? = nil,
        isEnabled: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastReconciledAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        precondition(!calendarIdentifier.isEmpty, "calendarIdentifier must not be empty")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.activityType = activityType
        self.sportId = sportId?.rawValue
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReconciledAt = lastReconciledAt
        self.schemaVersion = schemaVersion
    }

    public var calendarPlanningMappingId: CalendarPlanningMappingId { CalendarPlanningMappingId(rawValue: id) }
}
