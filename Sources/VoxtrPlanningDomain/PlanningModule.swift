import Foundation
import SwiftData
import VoxtrCore

/// Planning domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns WeekPlan,
/// PlannedActivity, and PlanningDecision (Section 8) with complete
/// field-level schemas, and publishes WeekPlanCreated /
/// WeekPlanCommitted / WeekPlanClosed / WeekPlanConflictDetected /
/// PlannedActivityCreated / PlannedActivityChanged /
/// PlannedActivityDeleted (Section 16).
///
/// S2.0: registers `PlanningRepository` (WeekPlan/PlannedActivity
/// persistence only — no `PlanningDecision` handling yet).
public struct PlanningModule: VoxtrModule {
    public static let domainID = "planning"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = PlanningRepository(modelContext: modelContainer.mainContext)
        container.register(PlanningRepository.self) { repository }
    }
}
