import Foundation
import SwiftData
import VoxtrCoreContracts

/// VX-038 (External Event Decomposition / Suggested Split): normalized
/// link from ONE `CalendarImportDecision` to ONE child `PlannedActivity`
/// it produced. Provenance only — never duplicates athlete/sport/
/// activity-type/timing data, which lives entirely on the linked
/// `PlannedActivity` itself (Vǫxtr Planning owns that after explicit
/// import, per this feature's own ONE TRUTH contract).
///
/// ORDINARY (non-split) imports through `CalendarPlanningCoordinationService.classifyAndImport(...)`
/// never write a row here — that path, and its existing single
/// `CalendarImportDecision.plannedActivityId`, are completely unchanged.
/// Only `classifyAndImportSplit(...)` writes these rows, ONE per child
/// (including the first), so a historical 1:1 decision (no link rows)
/// and a new decomposed decision (N link rows) both resolve correctly
/// through the SAME read helper
/// (`CalendarPlanningCoordinationService.plannedActivityIds(for:)`) —
/// existing historical decisions are never migrated/rewritten to gain
/// link rows retroactively.
///
/// Not enforced by a uniqueness/foreign-key constraint here (same
/// "persistence infrastructure only" boundary every other repository in
/// this project already follows) — the coordination service is
/// responsible for writing exactly one row per child, in order.
@Model
public final class DecomposedActivityLink {
    @Attribute(.unique) public var id: UUID
    public var calendarImportDecisionId: UUID
    public var plannedActivityId: UUID
    /// The child's position in the Parent-approved split, `0`-based —
    /// preserves the order children were created in (and, for a
    /// Suggested Split, the order evidence itself stores), never
    /// re-derived from timing (two children could share an offset).
    public var orderIndex: Int
    public var createdAt: Date
    public var schemaVersion: Int

    public init(
        id: DecomposedActivityLinkId = DecomposedActivityLinkId(),
        calendarImportDecisionId: CalendarImportDecisionId,
        plannedActivityId: PlannedActivityId,
        orderIndex: Int,
        createdAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id.rawValue
        self.calendarImportDecisionId = calendarImportDecisionId.rawValue
        self.plannedActivityId = plannedActivityId.rawValue
        self.orderIndex = orderIndex
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }

    public var decomposedActivityLinkId: DecomposedActivityLinkId { DecomposedActivityLinkId(rawValue: id) }
}

/// VX-038: reusable, durable evidence of ONE explicit Parent-approved
/// split of an external event into multiple `PlannedActivity` children —
/// created ONLY from an explicit import (never inferred, never AI-
/// generated), and used ONLY to PROPOSE a Suggested Split for a later
/// matching event; it never itself creates a `PlannedActivity` or a
/// `CalendarImportDecision`.
///
/// MATCH KEYS, checked by `CalendarPlanningCoordinationService.suggestedSplit(for:source:)`
/// in this precedence order:
///   1. `sourceId` + `recurringEventIdentifier` (EventKit's own
///      `eventIdentifier`, shared across every occurrence of the SAME
///      recurring series — see `ExternalCalendarEvent`'s own doc
///      comment) — the STRONGEST evidence, since it identifies the
///      actual recurring series, not merely similar text;
///   2. `sourceId` + `normalizedTitle` (via
///      `ExternalEventTitleNormalization.normalize(_:)`, the SAME exact-
///      match normalization this domain's remembered-classification
///      evidence already uses) — the fallback for a non-recurring event,
///      or a recurring event whose series evidence doesn't (yet) exist.
/// Both fields are always captured (never inferred from one another),
/// so a recurring series' own evidence can ALSO serve a differently-
/// identified event sharing its exact title, within the SAME source
/// only — matching never crosses a source or workspace boundary (a
/// source belongs to exactly one family).
///
/// CREATE-ONLY: `recordDecompositionEvidenceIfAbsent` (this domain's own
/// write path) never overwrites an existing evidence row for the same
/// key. Editing one occurrence's split (whether starting from this
/// Suggested Split or built from scratch) never silently rewrites the
/// learned recurring-series pattern — see that method's own doc
/// comment.
@Model
public final class DecompositionEvidence {
    @Attribute(.unique) public var id: UUID
    public var sourceId: UUID
    public var recurringEventIdentifier: String?
    public var normalizedTitle: String?
    public var createdBy: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: DecompositionEvidenceId = DecompositionEvidenceId(),
        sourceId: ExternalPlanningSourceId,
        recurringEventIdentifier: String?,
        normalizedTitle: String?,
        createdBy: ActorId,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id.rawValue
        self.sourceId = sourceId.rawValue
        self.recurringEventIdentifier = recurringEventIdentifier
        self.normalizedTitle = normalizedTitle
        self.createdBy = createdBy.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var decompositionEvidenceId: DecompositionEvidenceId { DecompositionEvidenceId(rawValue: id) }
}

/// VX-038: ONE child's durable, reusable shape within a
/// `DecompositionEvidence` row — the minimum durable facts required to
/// reproduce a Suggested Split, per this feature's own contract. Never
/// duplicates a Sport/ActivityType definition — `sportId`/`activityType`
/// here are the SAME canonical value types every other Planning write
/// uses, just the Parent-approved VALUES for this one child, not a
/// second definition of what a Sport or ActivityType is.
@Model
public final class DecompositionEvidenceChild {
    @Attribute(.unique) public var id: UUID
    public var evidenceId: UUID
    public var athleteId: UUID
    public var sportId: UUID?
    public var activityType: ActivityType
    /// Minutes from the external event's own start — never inferred,
    /// always the Parent's explicit choice at the moment this evidence
    /// was created (see `DecompositionEvidence`'s own "CREATE-ONLY" doc
    /// comment).
    public var startOffsetMinutes: Int
    public var durationMinutes: Int
    public var orderIndex: Int
    public var schemaVersion: Int

    public init(
        id: DecompositionEvidenceChildId = DecompositionEvidenceChildId(),
        evidenceId: DecompositionEvidenceId,
        athleteId: AthleteId,
        sportId: SportId?,
        activityType: ActivityType,
        startOffsetMinutes: Int,
        durationMinutes: Int,
        orderIndex: Int,
        schemaVersion: Int = 1
    ) {
        self.id = id.rawValue
        self.evidenceId = evidenceId.rawValue
        self.athleteId = athleteId.rawValue
        self.sportId = sportId?.rawValue
        self.activityType = activityType
        self.startOffsetMinutes = startOffsetMinutes
        self.durationMinutes = durationMinutes
        self.orderIndex = orderIndex
        self.schemaVersion = schemaVersion
    }

    public var decompositionEvidenceChildId: DecompositionEvidenceChildId { DecompositionEvidenceChildId(rawValue: id) }
}
