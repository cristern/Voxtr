import Foundation
import SwiftData

/// A1 (Architecture Decisions v1): the first `VersionedSchema`. `models`
/// is exactly `AppSchema.modelTypes` — no entity added, removed, or
/// renamed. This story is purely additive infrastructure around the
/// already-persisted model set, not a schema change in itself.
///
/// Per Architecture Decisions v1: this project's schema was NOT
/// versioned before this story, despite having gone through several
/// real storage-format changes already (`WeekPlan.weekStart`,
/// `PlannedActivity.localDate`, `ParentObservation.localDate` — see
/// each entity's own doc comments). Those changes are NOT reconstructed
/// here as separate historical schema versions: no real production data
/// ever existed under any of those earlier shapes, so there is nothing
/// reliable to migrate *from*. Per this story's explicit scope, the
/// currently-implemented model set is defined as V1, full stop — not
/// pretended to be a "V4" arrived at via fabricated intermediate
/// versions this project never actually shipped to real users.
public enum AppSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        AppSchema.modelTypes
    }
}

/// A1: the migration plan. `stages` is empty — there is exactly one
/// schema version so far, so there is nothing to migrate between yet.
/// `ModelContainer` still requires a migration plan to be supplied once
/// you're using a `VersionedSchema` at all, even with a single version
/// and zero stages; this is that plan.
///
/// HOW TO ADD V2 (read this before adding, renaming, or removing any
/// `@Model` property or type in `AppSchema.modelTypes`):
///
/// 1. Add a new `AppSchemaV2: VersionedSchema` enum in this file, with
///    `versionIdentifier: Schema.Version(2, 0, 0)` and `models` listing
///    the new shape.
/// 2. Update `AppSchema.modelTypes` (in `AppSchema.swift`) to match
///    `AppSchemaV2.models` — `AppSchema` remains the single source of
///    truth for "what persists now"; `AppSchemaV1`/`AppSchemaV2` are
///    snapshots of that truth at each point it changed.
/// 3. Add `AppSchemaV2.self` to this type's `schemas` array, alongside
///    `AppSchemaV1.self` (both stay listed — old versions are never
///    removed from `schemas`, only appended to).
/// 4. Add a `MigrationStage` to `stages` describing V1 → V2. Use
///    `.lightweight(fromVersion:toVersion:)` for anything SwiftData can
///    infer automatically (e.g. a new optional property with a
///    default). Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
///    for anything that needs real data transformation (e.g. splitting
///    a field, changing a non-optional property's type — the exact
///    category of change the `LocalDate`-storage fixes earlier in this
///    project were, and would have needed real migration handling for,
///    had any real user data existed under the old shape at the time).
/// 5. Do not skip straight to a "V3" — each actually-shipped schema
///    change gets its own version and its own stage, in order, the same
///    way this project's sprint-by-sprint entity additions actually
///    happened.
public enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
