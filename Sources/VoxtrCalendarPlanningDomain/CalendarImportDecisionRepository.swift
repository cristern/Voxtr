import Foundation
import SwiftData
import VoxtrCoreContracts

/// Family-Owned Calendar Sources V1: insert/fetch/delete
/// `CalendarImportDecision` only — pure persistence, matching every
/// other repository in this project. No `update` — a decision is
/// immutable once made in this V1 (import or ignore); undoing an import
/// is "remove the resulting `PlannedActivity`, then delete this
/// decision," not "edit this row in place" (see
/// `CalendarPlanningCoordinationService.removeImportedActivities(for:removedBy:)`'s
/// own doc comment).
@MainActor
public final class CalendarImportDecisionRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// `ignoredEventTitle` defaults to `nil` so every existing `.imported`
    /// call site is unaffected — see `CalendarImportDecision.ignoredEventTitle`'s
    /// own doc comment for what it is and why it exists.
    @discardableResult
    public func insert(
        sourceId: ExternalPlanningSourceId,
        externalEventKey: String,
        status: CalendarImportDecisionStatus,
        athleteId: AthleteId?,
        sportId: SportId?,
        activityType: ActivityType?,
        plannedActivityId: PlannedActivityId?,
        ignoredEventTitle: String? = nil,
        decidedBy: ActorId
    ) throws -> CalendarImportDecision {
        let decision = CalendarImportDecision(
            sourceId: sourceId,
            externalEventKey: externalEventKey,
            status: status,
            athleteId: athleteId,
            sportId: sportId,
            activityType: activityType,
            plannedActivityId: plannedActivityId,
            ignoredEventTitle: ignoredEventTitle,
            decidedBy: decidedBy
        )
        modelContext.insert(decision)
        try modelContext.save()
        return decision
    }

    /// Every decision (imported or ignored) for one source — used by
    /// `fetchReviewQueue(for:)` to exclude already-decided events from
    /// the pending review list.
    public func fetchAll(forSource sourceId: ExternalPlanningSourceId) throws -> [CalendarImportDecision] {
        let rawSourceId = sourceId.rawValue
        return try modelContext.fetch(FetchDescriptor<CalendarImportDecision>())
            .filter { $0.sourceId == rawSourceId }
    }

    public func fetch(sourceId: ExternalPlanningSourceId, externalEventKey: String) throws -> CalendarImportDecision? {
        let rawSourceId = sourceId.rawValue
        return try modelContext.fetch(FetchDescriptor<CalendarImportDecision>())
            .first { $0.sourceId == rawSourceId && $0.externalEventKey == externalEventKey }
    }

    public func delete(_ decision: CalendarImportDecision) throws {
        modelContext.delete(decision)
        try modelContext.save()
    }
}
