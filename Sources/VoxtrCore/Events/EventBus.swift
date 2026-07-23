import Foundation

/// A minimal, in-process, type-safe publish/subscribe bus.
///
/// Deliberately NOT a general message queue, NOT persisted, and NOT a
/// replacement for CloudKit sync — it exists purely so modules can react
/// to each other's domain events without depending on each other's
/// packages. Subscribers are held weakly-by-intent: the bus does not
/// retain any module; each module registers its own subscription and is
/// responsible for its own lifetime.
///
/// `actor` isolation gives us the "strict concurrency" the Engineering
/// Guide requires without hand-rolled locking.
public actor EventBus {

    public static let shared = EventBus()

    private var subscribers: [ObjectIdentifier: [UUID: @Sendable (any DomainEvent) -> Void]] = [:]

    public init() {}

    /// Subscribe to a specific `DomainEvent` type. Returns a token you can
    /// pass to `unsubscribe` — there is no automatic cleanup, by design,
    /// so lifetime bugs are visible rather than silently leaking.
    @discardableResult
    public func subscribe<Event: DomainEvent>(
        to eventType: Event.Type,
        handler: @escaping @Sendable (Event) -> Void
    ) -> UUID {
        let token = UUID()
        let key = ObjectIdentifier(eventType)
        let wrapped: @Sendable (any DomainEvent) -> Void = { event in
            guard let typed = event as? Event else { return }
            handler(typed)
        }
        subscribers[key, default: [:]][token] = wrapped
        return token
    }

    public func unsubscribe<Event: DomainEvent>(_ token: UUID, from eventType: Event.Type) {
        let key = ObjectIdentifier(eventType)
        subscribers[key]?.removeValue(forKey: token)
    }

    /// Publish an event to every current subscriber of its concrete type.
    public func publish<Event: DomainEvent>(_ event: Event) {
        let key = ObjectIdentifier(Event.self)
        subscribers[key]?.values.forEach { $0(event) }
    }

    /// Sprint 0 test/debug helper — number of active subscriptions for a type.
    public func subscriberCount<Event: DomainEvent>(for eventType: Event.Type) -> Int {
        subscribers[ObjectIdentifier(eventType)]?.count ?? 0
    }
}
