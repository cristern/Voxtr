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
/// This IS currently a passthrough to `AppSchema.modelTypes`, since V2
/// is the current latest version — `AppSchema` remains the single
/// source of truth for "what persists now," and whichever
/// `VersionedSchema` is latest mirrors it directly. When V3 is added,
/// freeze this list too (the same way V1 was frozen in A2) and move the
/// passthrough role to `AppSchemaV3`.
public enum AppSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        AppSchema.modelTypes
    }
}

/// The migration plan. One stage so far: V1 → V2, purely additive.
///
/// HOW TO ADD V3 (read this before adding, renaming, or removing any
/// `@Model` property or type in `AppSchema.modelTypes`):
///
/// 1. Freeze `AppSchemaV2.models` to a hardcoded list (the same way
///    `AppSchemaV1.models` was frozen in A2) — copy its current
///    passthrough result as a literal array before changing anything.
/// 2. Add a new `AppSchemaV3: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(3, 0, 0)` and `models`
///    passthrough to `AppSchema.modelTypes` (V3 becomes the new latest).
/// 3. Update `AppSchema.modelTypes` (in `AppSchema.swift`) to the new
///    shape.
/// 4. Add `AppSchemaV3.self` to `schemas` below, alongside
///    `AppSchemaV1.self` and `AppSchemaV2.self` (old versions are never
///    removed, only appended to).
/// 5. Add a `MigrationStage` to `stages` describing V2 → V3. Use
///    `.lightweight(fromVersion:toVersion:)` for anything SwiftData can
///    infer automatically (a new model type, a new optional property
///    with a default). Use
///    `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` for
///    anything needing real data transformation (splitting a field,
///    changing a non-optional property's type — the exact category of
///    change the `LocalDate`-storage fixes were, and would have needed
///    real migration handling for, had real user data existed under the
///    old shape at the time).
/// 6. Do not skip straight to a "V4" — each actually-shipped schema
///    change gets its own version and its own stage, in order, the same
///    way this project's sprint-by-sprint entity additions actually
///    happened.
public enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: AppSchemaV1.self,
        toVersion: AppSchemaV2.self
    )
}
