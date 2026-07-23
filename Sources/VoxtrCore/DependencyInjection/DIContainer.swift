import Foundation

/// A minimal type-keyed service locator used only at the composition root
/// (`VoxtrAppShell`). Domain modules never see the container directly —
/// they declare what they need as initializer parameters (constructor
/// injection), and `VoxtrAppShell` is the only place that resolves and
/// wires concrete instances together.
///
/// ENGINEERING TRADE-OFF (documented per the Engineering Guide's
/// "document architectural trade-offs" rule): the Engineering Guide does
/// not mandate a specific DI library or pattern. A hand-rolled container
/// was chosen over a third-party DI framework (e.g. Factory, Swinject) to
/// keep Sprint 0 dependency-free and easy to audit; revisit only if
/// registration volume genuinely outgrows this (unlikely for a modular
/// monolith of this size).
public final class DIContainer: @unchecked Sendable {

    private var factories: [ObjectIdentifier: () -> Any] = [:]
    private let lock = NSLock()

    public init() {}

    public func register<Service>(_ type: Service.Type, factory: @escaping () -> Service) {
        lock.lock(); defer { lock.unlock() }
        factories[ObjectIdentifier(type)] = factory
    }

    public func resolve<Service>(_ type: Service.Type) -> Service {
        lock.lock(); defer { lock.unlock() }
        guard let factory = factories[ObjectIdentifier(type)], let service = factory() as? Service else {
            preconditionFailure(
                "No registration for \(Service.self). Register it in VoxtrAppShell's CompositionRoot before resolving."
            )
        }
        return service
    }

    public func resolveOptional<Service>(_ type: Service.Type) -> Service? {
        lock.lock(); defer { lock.unlock() }
        return factories[ObjectIdentifier(type)]?() as? Service
    }
}
