import Foundation

/// Marker protocol for anything published on the `EventBus`.
///
/// Architecture rule (02_Architecture_v1_0, Architecture Work Package):
/// modules communicate through interfaces and domain events — never
/// through shared models. A `DomainEvent` is intentionally a small,
/// stable, published-language type: a module publishes an event about
/// something that happened in its own domain, and other modules may
/// subscribe without ever importing that module.
public protocol DomainEvent: Sendable {
    /// Stable, human-readable identifier for logging/debugging, e.g. "athlete.created".
    /// Not used for dispatch — dispatch is by concrete type.
    static var eventName: String { get }
}

/// Sprint 0 has no business events yet (no entities exist). This lifecycle
/// event exists solely to prove the bus works end-to-end without inventing
/// any business rule.
public struct AppDidFinishLaunchingEvent: DomainEvent {
    public static let eventName = "core.appDidFinishLaunching"
    public let timestamp: Date

    public init(timestamp: Date = .now) {
        self.timestamp = timestamp
    }
}
