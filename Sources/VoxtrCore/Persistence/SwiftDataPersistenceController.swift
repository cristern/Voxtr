import Foundation
import SwiftData

/// ENGINEERING TRADE-OFF: this Sprint 0 configuration is LOCAL-ONLY
/// (`cloudKitDatabase: .none`). Wiring the real CloudKit container is
/// deferred deliberately — CloudKit record types are effectively a
/// one-way door once real data exists (see Architecture Review, section
/// 3), and no domain module has approved entities yet to decide zone
/// layout for (single vs. split zones, per the Architecture Review's
/// "Performance vs. Sensitive zone" finding). Flipping this to a
/// CloudKit-backed configuration is Sprint 1+ work, once entities and the
/// zone/role model are actually approved — not a Sprint 0 decision to
/// make silently.
public final class SwiftDataPersistenceController: PersistenceProviding {

    public init() {}

    @MainActor
    public func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([AppDiagnosticsRecord.self])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// In-memory variant for unit tests — never touches disk.
public final class InMemoryPersistenceController: PersistenceProviding {

    public init() {}

    @MainActor
    public func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([AppDiagnosticsRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
