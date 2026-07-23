import Foundation
import SwiftData

/// Abstraction over "how do we get a ModelContainer". No domain module
/// reaches into SwiftData directly for Sprint 0 configuration — they ask
/// Core for a configured container. This keeps schema construction in one
/// place, which matters because CloudKit-backed SwiftData schemas are
/// close to append-only in practice (see Architecture Review, "Migration
/// reality check") — one place to reason about that is safer than N.
public protocol PersistenceProviding: Sendable {
    @MainActor func makeModelContainer() throws -> ModelContainer
}
