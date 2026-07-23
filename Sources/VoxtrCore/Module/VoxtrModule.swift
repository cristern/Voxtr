import Foundation

/// Every domain package (VoxtrAthlete, VoxtrParent, VoxtrPlanning, ...)
/// exposes exactly one type conforming to this protocol. `VoxtrAppShell`
/// composes the app by iterating over a static list of these — adding a
/// new domain module later means adding one conformance and one line in
/// `ModuleRegistry`, never touching every other module.
///
/// Sprint 0 modules are empty: they register nothing and display a
/// placeholder. Sprint 1+ is expected to give each module real content
/// (its own persistence needs, its own subscriptions to `EventBus`, its
/// own screens) behind this same seam.
public protocol VoxtrModule: Sendable {
    /// Stable identifier, matching the domain names in 02_Architecture_v1_0
    /// (e.g. "athlete", "planning", "reflection").
    static var domainID: String { get }

    init()

    /// Hook for a module to register its own services into the shared
    /// container, or subscribe to `EventBus` events it cares about.
    /// Sprint 0 modules leave this empty.
    func configure(container: DIContainer, eventBus: EventBus) async
}

public extension VoxtrModule {
    func configure(container: DIContainer, eventBus: EventBus) async {}
}
