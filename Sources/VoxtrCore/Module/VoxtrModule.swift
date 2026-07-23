import Foundation
import SwiftData

/// Every domain package (VoxtrAthlete, VoxtrParent, VoxtrPlanning, ...)
/// exposes exactly one type conforming to this protocol. `VoxtrAppShell`
/// composes the app by iterating over a static list of these — adding a
/// new domain module later means adding one conformance and one line in
/// `ModuleRegistry`, never touching every other module.
///
/// Sprint 0 modules were empty: they registered nothing and displayed a
/// placeholder. As of Sprint 1 story S1.1, `configure` also receives the
/// shared `ModelContainer` — the piece Sprint 0 didn't need yet, since
/// no module had a repository to register. This is `@MainActor` because
/// `ModelContainer.mainContext` (what repositories are built from) is
/// itself `@MainActor`-isolated.
public protocol VoxtrModule: Sendable {
    /// Stable identifier, matching the domain names in 02_Architecture_v1_0
    /// (e.g. "athlete", "planning", "reflection").
    static var domainID: String { get }

    init()

    /// Hook for a module to register its own services (repositories,
    /// etc.) into the shared container, or subscribe to `EventBus`
    /// events it cares about. Modules with nothing to register yet use
    /// the empty default below.
    @MainActor
    func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async
}

public extension VoxtrModule {
    @MainActor
    func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {}
}
