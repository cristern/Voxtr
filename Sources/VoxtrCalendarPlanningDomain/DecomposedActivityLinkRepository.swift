import Foundation
import SwiftData
import VoxtrCoreContracts

/// VX-038: insert/fetch/delete `DecomposedActivityLink` — pure
/// persistence, matching every other repository in this domain. No
/// `update`: a link is written once, at split-import time, and is never
/// mutated afterward.
///
/// Lead Review follow-up (Blocker 2): `delete(_:)` exists STRICTLY for
/// `CalendarPlanningCoordinationService.classifyAndImportSplit(...)`'s
/// own bounded rollback — unwinding link rows already written earlier
/// in the SAME failed call, so a retry never finds a partial split. It
/// is never used to remove a decomposed import's children after a
/// SUCCESSFUL split; that still goes through the normal
/// `PlanningService.deletePlannedActivity` path per child, and the link
/// row for an already-deleted child remains inert provenance, harmless
/// to leave pointing at a since-deleted `PlannedActivityId` — exactly
/// like `CalendarImportDecision.plannedActivityId` already can for the
/// ordinary one-activity path.
@MainActor
public final class DecomposedActivityLinkRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func insert(
        calendarImportDecisionId: CalendarImportDecisionId,
        plannedActivityId: PlannedActivityId,
        orderIndex: Int
    ) throws -> DecomposedActivityLink {
        let link = DecomposedActivityLink(
            calendarImportDecisionId: calendarImportDecisionId,
            plannedActivityId: plannedActivityId,
            orderIndex: orderIndex
        )
        modelContext.insert(link)
        try modelContext.save()
        return link
    }

    /// Every child link for ONE decision, ordered — `[]` for an
    /// ordinary (non-split) decision, which never has link rows; see
    /// `CalendarPlanningCoordinationService.plannedActivityIds(for:)`
    /// for the single read helper that falls back to
    /// `CalendarImportDecision.plannedActivityId` in that case.
    public func fetchAll(forDecision calendarImportDecisionId: CalendarImportDecisionId) throws -> [DecomposedActivityLink] {
        let rawDecisionId = calendarImportDecisionId.rawValue
        return try modelContext.fetch(FetchDescriptor<DecomposedActivityLink>())
            .filter { $0.calendarImportDecisionId == rawDecisionId }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Rollback-only — see this type's own doc comment.
    public func delete(_ link: DecomposedActivityLink) throws {
        modelContext.delete(link)
        try modelContext.save()
    }
}
