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
/// `RecurringPlannedActivity`. VX-023 (Sleep V1) adds `DailyStatus` and
/// `AthleteSettings` — both types existed in source already but were
/// never registered here and never persisted by any repository; Sleep
/// V1 is what activates them for real. This is a type *addition*, not a
/// field-level change to an already-listed type: per
/// `AppSchemaVersioning.swift`'s own "HOW TO ADD" step 3, only a type
/// addition/removal touches this array at all. No `AppSchemaV2` bump
/// was made for this addition — `AppCurrentSchema.models` is still a
/// live (not yet frozen) passthrough to this array, so both newly-
/// registered types simply become part of what V1 already resolves to,
/// consistent with this file's own "no production data at stake, first
/// version of the simplified scheme" philosophy. There are zero existing
/// persisted rows of either type to migrate.
///
/// CRITICAL PERSISTENCE RECOVERY: this project's schema *versioning*
/// history (`AppSchemaV1` through `AppSchemaV6`, with "frozen legacy
/// types" for historical field shapes) was collapsed to a single
/// `AppCurrentSchema` — see `AppSchemaVersioning.swift`'s own doc
/// comment for the full investigation and why. `MonthlyReflection`,
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
            DailyStatus.self,
            AthleteSettings.self,
        ]
    }
}
