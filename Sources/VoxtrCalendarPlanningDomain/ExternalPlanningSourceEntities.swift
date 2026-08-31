import Foundation
import SwiftData
import VoxtrCoreContracts

/// Family-Owned Calendar Sources V1: which transport/provider produced
/// this `ExternalPlanningSource` — deliberately a plain, provider-
/// neutral string enum, not `EKCalendar`/EventKit-specific. EventKit is
/// the first (and, this round, only) provider this app validates; a
/// future non-EventKit provider adds a new case here, never a new
/// top-level source type.
public enum ExternalPlanningSourceProviderKind: String, Codable, Sendable {
    case eventKit
}

/// Family-Owned Calendar Sources V1: a Parent's explicit, trusted
/// connection to ONE external calendar/container — owned by the
/// FAMILY, never by one athlete. Replaces `CalendarPlanningMapping`
/// (Calendar Planning Source V1, now legacy/Alpha — see that type's own
/// doc comment): real TestFlight evidence showed multiple children's
/// Spond groups syncing into the SAME iOS calendar, so forcing one
/// calendar to map to exactly one athlete/sport/activity type
/// misattributed every child's events to whichever athlete the mapping
/// happened to name.
///
/// This row is configuration/container identity only — it never stores
/// athlete, sport, or activity type. Those are Parent-approved, PER-
/// EVENT choices captured by `CalendarImportDecision` at the moment a
/// specific external event is explicitly imported, never a source-level
/// default (see this type's own product-contract doc comment on why:
/// "no hidden heuristic assignment, no silent athlete guessing"). It
/// also never stores an imported event's own schedule facts (title/
/// time/etc) — those live on the `PlannedActivity` created for each
/// classified event, through the normal Planning mutation path.
///
/// One row per external container/calendar is this V1's product
/// contract — not enforced by a uniqueness constraint here (same
/// "persistence infrastructure only" boundary every other repository in
/// this project already follows); the coordination service is
/// responsible for not creating a second source for the same
/// container.
@Model
public final class ExternalPlanningSource {
    @Attribute(.unique) public var id: UUID
    public var providerKind: ExternalPlanningSourceProviderKind
    /// The provider's own stable container identifier — EventKit's
    /// `EKCalendar.calendarIdentifier` for `providerKind == .eventKit`.
    /// See `CalendarEventProviding`'s own doc comment for the stability
    /// caveats Apple documents for calendar/event identifiers.
    public var externalContainerIdentifier: String
    /// Captured once, at connect time, from the calendar's own `title`
    /// — never re-read from EventKit at display time, so a later
    /// external rename doesn't retroactively relabel a source the
    /// Parent already recognizes by its original name.
    public var displayName: String
    /// Off by default even after creation — the Parent must explicitly
    /// enable a source before anything is discoverable for review.
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Set after every reconciliation attempt for this source,
    /// successful or not — presentation-only ("last synced" state), not
    /// itself a business decision input.
    public var lastReconciledAt: Date?
    public var schemaVersion: Int

    public init(
        id: ExternalPlanningSourceId = ExternalPlanningSourceId(),
        providerKind: ExternalPlanningSourceProviderKind,
        externalContainerIdentifier: String,
        displayName: String,
        isEnabled: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastReconciledAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        precondition(!externalContainerIdentifier.isEmpty, "externalContainerIdentifier must not be empty")
        self.id = id.rawValue
        self.providerKind = providerKind
        self.externalContainerIdentifier = externalContainerIdentifier
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReconciledAt = lastReconciledAt
        self.schemaVersion = schemaVersion
    }

    public var externalPlanningSourceId: ExternalPlanningSourceId { ExternalPlanningSourceId(rawValue: id) }
}

/// Family-Owned Calendar Sources V1: the two real, PERSISTED outcomes of
/// a Parent's explicit review of one external event. "Pending" is
/// deliberately NOT a case here — it is never persisted at all;
/// `CalendarPlanningCoordinationService.fetchReviewQueue(for:)`
/// represents it purely as "no `CalendarImportDecision` row exists yet
/// for this event's key," the smallest domain model that supports
/// pending/imported/ignored without writing a row for every event
/// nobody has looked at yet.
public enum CalendarImportDecisionStatus: String, Codable, Sendable {
    case imported
    case ignored
}

/// Family-Owned Calendar Sources V1: one Parent decision about one
/// specific external event — created ONLY when the Parent explicitly
/// imports (creates a classified `PlannedActivity`) or ignores an event
/// from Calendar Import Review. Never created automatically, never by
/// reconciliation.
///
/// Identity: `(sourceId, externalEventKey)`, where `externalEventKey`
/// is the EXACT same string
/// `ExternalCalendarEventIdentity.externalSourceId(calendarIdentifier:event:)`
/// produces (and the same string stamped on the resulting
/// `PlannedActivity.externalSourceId` when imported) — one shared
/// identity computation, never a second, divergent one. Not enforced by
/// a uniqueness constraint here (same "persistence infrastructure only"
/// boundary every other repository in this project follows); the
/// coordination service is responsible for not creating a second
/// decision for the same source+event.
@Model
public final class CalendarImportDecision {
    @Attribute(.unique) public var id: UUID
    public var sourceId: UUID
    public var externalEventKey: String
    public var status: CalendarImportDecisionStatus
    /// Set only when `status == .imported` — the Parent-approved athlete
    /// this event's `PlannedActivity` was created for. `nil` for
    /// `.ignored`.
    public var athleteId: UUID?
    /// Set only when `status == .imported`. `nil` for `.ignored`, and
    /// `nil` is also a legitimate imported value ("no specific Sport").
    public var sportId: UUID?
    public var activityType: ActivityType?
    /// The `PlannedActivity` this decision produced, when
    /// `status == .imported` — lets recovery/cleanup and reconciliation
    /// find the canonical record this decision is about without a
    /// second identity lookup. `nil` for `.ignored`.
    public var plannedActivityId: UUID?
    /// The real Parent `ActorId` who made this decision — never
    /// `.system`; see this domain's own actor-attribution contract.
    public var decidedBy: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: CalendarImportDecisionId = CalendarImportDecisionId(),
        sourceId: ExternalPlanningSourceId,
        externalEventKey: String,
        status: CalendarImportDecisionStatus,
        athleteId: AthleteId? = nil,
        sportId: SportId? = nil,
        activityType: ActivityType? = nil,
        plannedActivityId: PlannedActivityId? = nil,
        decidedBy: ActorId,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition(!externalEventKey.isEmpty, "externalEventKey must not be empty")
        self.id = id.rawValue
        self.sourceId = sourceId.rawValue
        self.externalEventKey = externalEventKey
        self.status = status
        self.athleteId = athleteId?.rawValue
        self.sportId = sportId?.rawValue
        self.activityType = activityType
        self.plannedActivityId = plannedActivityId?.rawValue
        self.decidedBy = decidedBy.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var calendarImportDecisionId: CalendarImportDecisionId { CalendarImportDecisionId(rawValue: id) }
}
