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
/// domain persistence infrastructure only). A2 (Architecture Decisions
/// v1) adds `PlannedActivityDeletionTombstone`. Sprint 5.0 adds
/// `WeeklyReflection`. Recurring Planned Activities adds
/// `RecurringPlannedActivity`. This list of model *types* has been
/// stable since (the `AthleteProfile.birthDate` crash fix and this
/// project's later critical persistence recovery were both field-level
/// changes to already-listed types, so neither touched this array).
///
/// CRITICAL PERSISTENCE RECOVERY: this project's schema *versioning*
/// history (`AppSchemaV1` through `AppSchemaV6`, with "frozen legacy
/// types" for historical field shapes) was collapsed to a single
/// `AppCurrentSchema` — see `AppSchemaVersioning.swift`'s own doc
/// comment for the full investigation and why. `DailyStatus`, `MonthlyReflection`,
/// `PlanningDecision`, and `TrainingAttachment` are NOT added here —
/// nothing creates or persists them yet, and registering an unused type
/// wouldn't be wrong but would misstate what's actually implemented. Do
/// NOT add Development/DecisionSupport/Notifications model types here
/// until a sprint that actually creates them, per the same principle.
///
/// NOTE (VX-037): `AthleteInvitationRequest` was briefly added here and
/// then removed — ADR-0002 concluded workspace invitation lifecycle
/// belongs on `WorkspaceParticipant.state`, not a separate persisted
/// entity. Do not re-add it.
///
/// IMPORTANT: any change to this list is a schema version change — see
/// `AppSchemaVersioning.swift`'s "HOW TO ADD" instructions before
/// editing this array. Changing this array alone, without also adding a
/// new frozen `VersionedSchema` + migration stage, would silently
/// change what the CURRENT (latest) versioned schema resolves to, but
/// would not correctly version the change.
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
            PlannedActivityDeletionTombstone.self,
            WeeklyReflection.self,
            RecurringPlannedActivity.self,
        ]
    }
}
