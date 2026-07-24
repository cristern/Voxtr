import Foundation
import SwiftData
import VoxtrCore
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// The set of `@Model` types the running app persists locally.
///
/// `VoxtrCore` cannot know these types — no `*Domain` package may be
/// imported by Core (see `Package.swift`'s dependency rule). `VoxtrAppShell`
/// is the one package allowed to see every domain, so this is where the
/// real schema gets assembled and handed down to
/// `SwiftDataPersistenceController`.
///
/// SCOPE: Sprint 1 (S1.0) listed only the entities Sprint 1 created —
/// `AthleteProfile`, `ParentProfile`, `FamilyWorkspace`,
/// `WorkspaceParticipant`, `AthleteAccessGrant` — plus
/// `AppDiagnosticsRecord` from Sprint 0. S2.0 added `WeekPlan` and
/// `PlannedActivity`. S3.0 added `LoggedActivity` and `ActivityLoad`.
/// S4.0 adds `ActivityReflection` and `ParentObservation` (Reflection
/// domain persistence infrastructure only). `DailyStatus`,
/// `WeeklyReflection`, `MonthlyReflection`, `PlanningDecision`, and
/// `TrainingAttachment` are NOT added here — nothing creates or persists
/// them yet, and registering an unused type wouldn't be wrong but would
/// misstate what's actually implemented. Do NOT add Development/
/// DecisionSupport/Notifications model types here until a sprint that
/// actually creates them, per the same principle.
public enum AppSchema {
    public static var modelTypes: [any PersistentModel.Type] {
        [
            AppDiagnosticsRecord.self,
            AthleteProfile.self,
            ParentProfile.self,
            FamilyWorkspace.self,
            WorkspaceParticipant.self,
            AthleteAccessGrant.self,
            WeekPlan.self,
            PlannedActivity.self,
            LoggedActivity.self,
            ActivityLoad.self,
            ActivityReflection.self,
            ParentObservation.self,
        ]
    }
}
