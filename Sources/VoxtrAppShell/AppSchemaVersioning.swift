import Foundation
import SwiftData
import VoxtrCore
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// A1 (Architecture Decisions v1): the first `VersionedSchema`.
///
/// FROZEN as of A2 — do not edit this list again. This is a hardcoded
/// snapshot of exactly the 12 entities that existed before A2 added
/// `PlannedActivityDeletionTombstone`. It is deliberately NOT a
/// passthrough to `AppSchema.modelTypes` (that was fine when V1 was the
/// only version — see the git history of this file — but a superseded
/// version must never move again once a newer version exists, or "V1"
/// would silently stop meaning what it originally meant).
///
/// Per Architecture Decisions v1: this project's schema was NOT
/// versioned before A1, despite having gone through several real
/// storage-format changes already (`WeekPlan.weekStart`,
/// `PlannedActivity.localDate`, `ParentObservation.localDate` — see
/// each entity's own doc comments). Those changes are NOT reconstructed
/// here as separate historical schema versions: no real production data
/// ever existed under any of those earlier shapes, so there was nothing
/// reliable to migrate *from*. V1 was defined as "the model set as it
/// actually stood," not a guess at some earlier shape.
public enum AppSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
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

/// A2 (Architecture Decisions v1): adds `PlannedActivityDeletionTombstone`
/// — a purely additive change (a new model type; no existing model's
/// properties changed), so the migration from V1 is `.lightweight`
/// (below), which SwiftData infers automatically.
///
/// FROZEN as of Sprint 5.0 — do not edit this list again, for the same
/// reason `AppSchemaV1` was frozen in A2: a superseded version must
/// never move once a newer version exists. This is a hardcoded snapshot
/// of exactly the 13 entities that existed before Sprint 5.0 added
/// `WeeklyReflection`.
public enum AppSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
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
        ]
    }
}

/// Sprint 5.0: adds `WeeklyReflection` — a purely additive change (a
/// new model type only), so the migration from V2 is also
/// `.lightweight`.
///
/// This IS currently a passthrough to `AppSchema.modelTypes`, since V3
/// is the current latest version. When V4 is added, freeze this list
/// too (the same way V1 and V2 were frozen) and move the passthrough
/// role to `AppSchemaV4`.
///
/// NOTE: a `AppSchemaV4`/`AthleteInvitationRequest` was introduced and
/// then reverted (ADR-0002 concluded the invitation lifecycle belongs
/// on the existing `WorkspaceParticipant` state machine, not a
/// separate persisted entity — see VX-037). V3 remains the latest
/// version; no schema change was ultimately required for the
/// corrected design.
public enum AppSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(3, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        AppSchema.modelTypes
    }
}

/// The migration plan. Two stages so far: V1 → V2 and V2 → V3, both
/// purely additive.
///
/// HOW TO ADD V4 (read this before adding, renaming, or removing any
/// `@Model` property or type in `AppSchema.modelTypes`):
///
/// 1. Freeze `AppSchemaV3.models` to a hardcoded list (the same way
///    `AppSchemaV1`/`AppSchemaV2` were frozen previously) — copy its
///    current passthrough result as a literal array before changing
///    anything.
/// 2. Add a new `AppSchemaV4: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(4, 0, 0)` and `models`
///    passthrough to `AppSchema.modelTypes` (V4 becomes the new latest).
/// 3. Update `AppSchema.modelTypes` (in `AppSchema.swift`) to the new
///    shape.
/// 4. Add `AppSchemaV4.self` to `schemas` below, alongside every
///    earlier version (old versions are never removed, only appended
///    to).
/// 5. Add a `MigrationStage` to `stages` describing V3 → V4. Use
///    `.lightweight(fromVersion:toVersion:)` for anything SwiftData can
///    infer automatically (a new model type, a new optional property
///    with a default). Use
///    `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` for
///    anything needing real data transformation (splitting a field,
///    changing a non-optional property's type — the exact category of
///    change the `LocalDate`-storage fixes were, and would have needed
///    real migration handling for, had real user data existed under the
///    old shape at the time).
/// 6. Do not skip straight to a "V5" — each actually-shipped schema
///    change gets its own version and its own stage, in order, the same
///    way this project's sprint-by-sprint entity additions actually
///    happened.
///
/// NOTE (VX-037): a V4 was previously added for `AthleteInvitationRequest`
/// and then fully reverted after ADR-0002 concluded that entity should
/// not exist. V3 remains the latest version — do not re-add a V4 for
/// that reverted work; only add one for a genuinely new schema change.
public enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: AppSchemaV1.self,
        toVersion: AppSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: AppSchemaV2.self,
        toVersion: AppSchemaV3.self
    )
}
