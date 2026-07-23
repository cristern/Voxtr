import Foundation
import SwiftData

/// ENGINEERING TRADE-OFF: still LOCAL-ONLY (`cloudKitDatabase: .none`) —
/// Sprint 1 (S1.0) explicitly excludes CloudKit. What changed from
/// Sprint 0: this controller no longer hardcodes its schema to
/// `AppDiagnosticsRecord` alone. `VoxtrCore` still can't import domain
/// packages, so it can't know the real entity list — the caller now
/// supplies it. `VoxtrAppShell.AppSchema` is that caller for the running
/// app; tests can pass whatever narrower list they need.
public final class SwiftDataPersistenceController: PersistenceProviding {

    private let modelTypes: [any PersistentModel.Type]

    /// Default stays Core-only (`AppDiagnosticsRecord`) because `VoxtrCore`
    /// cannot import domain packages — the real schema for the running
    /// app is assembled in `VoxtrAppShell` (see `AppSchema`) and passed
    /// in here explicitly, not guessed by Core.
    public init(modelTypes: [any PersistentModel.Type] = [AppDiagnosticsRecord.self]) {
        self.modelTypes = modelTypes
    }

    @MainActor
    public func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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
