import Foundation
import VoxtrCore

/// Planning domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns WeekPlan,
/// PlannedActivity, and PlanningDecision (Section 8) with complete
/// field-level schemas, and publishes WeekPlanCreated /
/// WeekPlanCommitted / WeekPlanClosed / WeekPlanConflictDetected /
/// PlannedActivityCreated / PlannedActivityChanged /
/// PlannedActivityDeleted (Section 16).
public struct PlanningModule: VoxtrModule {
    public static let domainID = "planning"

    public init() {}
}
