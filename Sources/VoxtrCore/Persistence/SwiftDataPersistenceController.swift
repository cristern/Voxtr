import Foundation
import SwiftData

/// ENGINEERING TRADE-OFF: still LOCAL-ONLY (`cloudKitDatabase: .none`) —
/// Sprint 1 (S1.0) explicitly excludes CloudKit. What changed from
/// Sprint 0: this controller no longer hardcodes its schema to
/// `AppDiagnosticsRecord` alone. `VoxtrCore` still can't import domain
/// packages, so it can't know the real entity list — the caller now
/// supplies it. `VoxtrAppShell.AppSchema` is that caller for the running
/// app; tests can pass whatever narrower list they need.
///
/// A1 (Architecture Decisions v1): added a second initializer taking a
/// versioned schema + migration plan (used by `CompositionRoot` via
/// `VoxtrAppShell.AppSchemaV1`/`AppSchemaMigrationPlan`). The original
/// `modelTypes:` initializer is UNCHANGED and still exists — nothing
/// else in this project constructs `SwiftDataPersistenceController`
/// directly (only `CompositionRoot`'s default parameter does), so this
/// is purely additive. Construction is captured in a stored closure
/// rather than a stored schema/plan pair: `ModelContainer`'s
/// `migrationPlan:` parameter is generic over a concrete
/// `SchemaMigrationPlan` type, which can't be stored as an `any
/// SchemaMigrationPlan.Type` existential and dispatched generically
/// later — capturing the already-fully-typed construction call in a
/// closure at `init` time sidesteps that entirely.
public final class SwiftDataPersistenceController: PersistenceProviding {

    private let makeContainer: @MainActor @Sendable () throws -> ModelContainer

    /// Default stays Core-only (`AppDiagnosticsRecord`) because `VoxtrCore`
    /// cannot import domain packages — the real schema for the running
    /// app is assembled in `VoxtrAppShell` (see `AppSchema`) and passed
    /// in here explicitly, not guessed by Core.
    public init(modelTypes: [any PersistentModel.Type] = [AppDiagnosticsRecord.self]) {
        self.makeContainer = {
            let schema = Schema(modelTypes)
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// A1: versioned-schema construction. `versionedSchema` only needs
    /// to describe the CURRENT schema shape (`Schema(versionedSchema:)`
    /// reads its `models`); `migrationPlan` carries the full version
    /// history and the stages between them.
    public init<Plan: SchemaMigrationPlan>(
        versionedSchema: any VersionedSchema.Type,
        migrationPlan: Plan.Type
    ) {
        self.makeContainer = {
            let schema = Schema(versionedSchema: versionedSchema)
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
        }
    }

    @MainActor
    public func makeModelContainer() throws -> ModelContainer {
        try makeContainer()
    }
}

/// In-memory variant for unit tests — never touches disk.
public final class InMemoryPersistenceController: PersistenceProviding {

    private let modelTypes: [any PersistentModel.Type]

    public init(modelTypes: [any PersistentModel.Type] = [AppDiagnosticsRecord.self]) {
        self.modelTypes = modelTypes
    }

    @MainActor
    public func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
