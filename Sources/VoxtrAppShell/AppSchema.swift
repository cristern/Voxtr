import Foundation
import SwiftData
import VoxtrCore
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain
import VoxtrCoreReferenceData
import VoxtrNotificationsDomain
import VoxtrCalendarPlanningDomain

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
/// V1 is what activates them for real. This IS a genuine schema version
/// bump: `AppSchemaVersioning.swift` now declares `AppSchemaV2`
/// ("2.0.0") as the current version (`AppCurrentSchema`, "1.0.0", is
/// FROZEN to the prior 15-entity shape), with a `.lightweight`
/// migration stage carrying an existing on-disk "1.0.0" store forward.
/// An earlier round of this same feature treated a live-passthrough
/// `AppCurrentSchema.models` (no version bump at all) as sufficient —
/// review follow-up determined that was not actually safe for an
/// existing TestFlight store (a fixed "1.0.0" identity would have
/// silently meant a different entity shape across builds) and corrected
/// it to the real version bump described above. See
/// `AppSchemaVersioning.swift`'s own doc comment for the full
/// reasoning, and `PersistenceRecoveryTests.existingV1StoreMigratesToV2Successfully`
/// for the migration itself exercised end to end.
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
/// Sport / Activity Identity domain foundation adds `Sport.self`
/// (`VoxtrCoreReferenceData`) — the type already existed and was already
/// used by `SportId`-typed fields on `PlannedActivity`/`LoggedActivity`/
/// `RecurringPlannedActivity`/`DevelopmentGoal`, but was never itself
/// registered/persisted until this round. This is a genuine model-type
/// addition (`AppSchemaV4`, see `AppSchemaVersioning.swift`), bundled in
/// the same version bump as this round's `ActivityType` raw-value change
/// and the optional-title field changes on the three activity entities —
/// see that file's own doc comment for why no frozen legacy copies were
/// needed for the field-level changes.
///
/// IMPORTANT: any change to this list is a schema version change — see
/// `AppSchemaVersioning.swift`'s "HOW TO ADD" instructions before
/// editing this array. Changing this array alone, without also adding a
/// new frozen `VersionedSchema` + migration stage, would silently
/// change what the CURRENT (latest) versioned schema resolves to, but
/// would not correctly version the change.
///
/// Notifications V1 Activity Reminder Foundation adds `ActivityReminder.self`
/// (`VoxtrNotificationsDomain`) — the first Notifications model type ever
/// registered here (this file's own prior doc comment explicitly said
/// not to, "until a sprint that actually creates them" — this is that
/// sprint). This is a genuine model-type addition (`AppSchemaV5`, see
/// `AppSchemaVersioning.swift`), purely additive: no existing entity or
/// property is renamed, removed, or changed in place.
///
/// Calendar Planning Source V1 added `CalendarPlanningMapping.self`
/// (`VoxtrCalendarPlanningDomain`) — the Parent's own persisted, trusted
/// calendar-to-athlete mapping; imported schedule facts themselves are
/// never a new entity, they are ordinary `PlannedActivity` rows (see
/// that type's own pre-existing `externalSourceId`/`externalSourceType`
/// fields). Genuine model-type addition (`AppSchemaV7`, see
/// `AppSchemaVersioning.swift`), purely additive.
///
/// Family-Owned Calendar Sources V1 adds `ExternalPlanningSource.self`
/// and `CalendarImportDecision.self` (`VoxtrCalendarPlanningDomain`) —
/// real TestFlight evidence showed `CalendarPlanningMapping`'s one-
/// calendar-to-one-athlete assumption cannot represent a real external
/// calendar shared by multiple children (e.g. several Spond groups
/// syncing into the same iOS "Familie" calendar). `ExternalPlanningSource`
/// is the family-owned replacement (container/connection identity only,
/// no athlete/sport/activity-type default); `CalendarImportDecision` is
/// the Parent's explicit, per-event import-or-ignore record Calendar
/// Import Review produces. `CalendarPlanningMapping` stays registered,
/// UNCHANGED, purely so any already-persisted row remains readable for
/// the one-time migration read (see
/// `CalendarPlanningCoordinationService.migrateLegacySourcesIfNeeded(forWorkspace:)`) —
/// no live path creates new rows of that type anymore. Two genuine
/// model-type additions, both purely additive (`AppSchemaV8`, see
/// `AppSchemaVersioning.swift`).
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
            Sport.self,
            ActivityReminder.self,
            CalendarPlanningMapping.self,
            ExternalPlanningSource.self,
            CalendarImportDecision.self,
        ]
    }
}
