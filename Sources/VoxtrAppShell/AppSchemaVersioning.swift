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
/// FROZEN as of VX-039 — do not edit this list again, for the same
/// reason `AppSchemaV1`/`AppSchemaV2` were frozen previously. This is
/// a hardcoded snapshot of exactly the 14 entity *types* that existed
/// before VX-039 added `WorkspaceParticipant.declinedAt`.
///
/// This project's schema versioning tracks which entity types are
/// included at each version, not a per-field snapshot of each type's
/// own shape. A field-level addition to an already-listed type — like
/// `WorkspaceParticipant.declinedAt` in VX-039 — is still versioned
/// here, consistent with this project's process of giving any
/// additive, `.lightweight`-eligible schema change its own version and
/// migration stage.
public enum AppSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(3, 0, 0)
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
            WeeklyReflection.self,
        ]
    }
}

/// VX-039: adds `WorkspaceParticipant.declinedAt` — a purely additive
/// change (a new optional property with a `nil` default on an already-
/// included model type), so the migration from V3 is `.lightweight`.
/// This corrects a real gap in the aggregate (see that field's own doc
/// comment on `WorkspaceParticipant`) rather than adding new product
/// behavior — the entity *type* list is unchanged from V3; only one
/// existing type's own shape changed.
///
/// FROZEN as of Recurring Planned Activities — do not edit this list
/// again, for the same reason `AppSchemaV1`/`AppSchemaV2`/`AppSchemaV3`
/// were frozen previously. This is a hardcoded snapshot of exactly the
/// 14 entity types that existed before this work package added
/// `RecurringPlannedActivity`.
public enum AppSchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(4, 0, 0)
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
            WeeklyReflection.self,
        ]
    }
}

/// FROZEN as of the AthleteProfile.birthDate crash fix — do not edit
/// this list again, for the same reason
/// `AppSchemaV1`/`AppSchemaV2`/`AppSchemaV3`/`AppSchemaV4` were frozen
/// previously.
public enum AppSchemaV5: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(5, 0, 0)
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
            WeeklyReflection.self,
            RecurringPlannedActivity.self,
        ]
    }
}

/// TestFlight crash fix: `AthleteProfile.birthDate` changed from a
/// directly-stored `LocalDate` (a custom-`Codable` struct — see
/// `AthleteEntities.swift`'s own doc comment on `birthDateRaw` for why
/// this crashed) to a private, ISO-string-backed stored property with a
/// computed `LocalDate` wrapper of the same public name — no other
/// model type changed, so this is purely a field-level storage change
/// on one already-listed type, not a new/removed model type. No
/// existing model *type* was added or removed, so `AppSchema
/// .modelTypes` itself is unchanged by this version.
///
/// `.lightweight` is correct here: SwiftData's migration inference
/// treats a differently-named, differently-typed property
/// (`birthDate: LocalDate` → `birthDateRaw: String`, no
/// `@Attribute(originalName:)` rename hint) as an independent
/// removal-and-addition, not an automatic value transform — it never
/// attempts to decode the old `birthDate` column's value at all, which
/// is exactly what makes this migration safe: that decode is the
/// operation that crashes (see `AthleteEntities.swift`). The new
/// `birthDateRaw` column gets its literal default (`"1900-01-01"`,
/// matching `AthleteProfile.unknownBirthDatePlaceholder`) for every
/// existing row — an athlete created before this fix will show that
/// placeholder date after migrating, and needs it re-entered once via
/// the existing edit screen. This is a real, disclosed limitation, not
/// an oversight: the crash this fixes is a fatal, uncatchable runtime
/// trap inside SwiftData's own internal decoder, with no
/// application-level way to safely read the old value first — see this
/// work's own root-cause writeup for the full explanation.
///
/// This IS currently a passthrough to `AppSchema.modelTypes`, since V6
/// is the current latest version. When V7 is added, freeze this list
/// too (the same way V1-V5 were frozen) and move the passthrough role
/// to `AppSchemaV7`.
public enum AppSchemaV6: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(6, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        AppSchema.modelTypes
    }
}

/// The migration plan. Five stages so far: V1 → V2, V2 → V3, V3 → V4,
/// V4 → V5, and V5 → V6 — all purely additive or, for V5 → V6, a
/// field-level storage change with no safe way to preserve the old
/// value (see `AppSchemaV6`'s own doc comment).
///
/// HOW TO ADD V7 (read this before adding, renaming, or removing any
/// `@Model` property or type in `AppSchema.modelTypes`):
///
/// 1. Freeze `AppSchemaV6.models` to a hardcoded list (the same way
///    `AppSchemaV1`-`AppSchemaV5` were frozen previously) — copy its
///    current passthrough result as a literal array before changing
///    anything.
/// 2. Add a new `AppSchemaV7: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(7, 0, 0)` and `models`
///    passthrough to `AppSchema.modelTypes` (V7 becomes the new latest).
/// 3. Update `AppSchema.modelTypes` (in `AppSchema.swift`) — only if a
///    model *type* is actually being added/removed. A field-level
///    change to an already-listed type does not touch this array at
///    all.
/// 4. Add `AppSchemaV7.self` to `schemas` below, alongside every
///    earlier version (old versions are never removed, only appended
///    to).
/// 5. Add a `MigrationStage` to `stages` describing V6 → V7. Use
///    `.lightweight(fromVersion:toVersion:)` for anything SwiftData can
///    infer automatically (a new model type, a new property with a
///    literal default, a property removal). Use
///    `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` only
///    when there is a SAFE way to read the old value and transform it —
///    if reading the old value itself would crash (as `birthDate` did),
///    `.custom` cannot help either, since `willMigrate` still runs
///    against the old schema; `.lightweight` with a literal default is
///    the only safe option in that situation.
/// 6. Do not skip straight to a "V8" — each actually-shipped schema
///    change gets its own version and its own stage, in order, the same
///    way this project's sprint-by-sprint entity additions actually
///    happened.
public enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self, AppSchemaV4.self, AppSchemaV5.self, AppSchemaV6.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: AppSchemaV1.self,
        toVersion: AppSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: AppSchemaV2.self,
        toVersion: AppSchemaV3.self
    )

    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: AppSchemaV3.self,
        toVersion: AppSchemaV4.self
    )

    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: AppSchemaV4.self,
        toVersion: AppSchemaV5.self
    )

    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: AppSchemaV5.self,
        toVersion: AppSchemaV6.self
    )
}
