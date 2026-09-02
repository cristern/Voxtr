import Foundation
import SwiftData
import VoxtrCoreContracts

/// VX-038: insert/fetch `DecomposedActivityLink` only — pure
/// persistence, matching every other repository in this domain. No
/// `update`/`delete`: a link is written once, at split-import time, and
/// is never mutated afterward (removing a decomposed import's children
/// goes through the normal `PlanningService.deletePlannedActivity` path
/// per child; the link rows themselves are inert provenance, harmless
/// to leave pointing at a since-deleted `PlannedActivityId`, exactly
/// like `CalendarImportDecision.plannedActivityId` already can for the
/// ordinary one-activity path).
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
}
