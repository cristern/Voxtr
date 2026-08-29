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
/// PR #36 follow-up (Notifications V1 deterministic lifecycle delivery):
/// this was originally a plain `actor`. Every real publisher
/// (`PlanningService`, `TrainingService`) and every real subscriber
/// (`NotificationsPlanningCoordinationService`) in this codebase is
/// `@MainActor` — same as literally every other domain service and
/// repository here (SwiftData's `ModelContext` is `@MainActor`-bound
/// throughout this project's own established convention). A plain
/// `actor` was therefore a SEPARATE concurrency domain from every one of
/// its real callers, so every publish had to cross an actor boundary —
/// which a synchronous caller can only do by handing the publish call to
/// an unstructured `Task { await ... }`, and a synchronous subscriber
/// handler receiving it had to do the exact same thing to hop back onto
/// `@MainActor` to do anything useful (touch SwiftData). Two independent,
/// unordered `Task { }` hops per event meant the production
/// publish -> subscribe -> react path had no ordering guarantee at all
/// for rapid sequential mutations (edit-then-delete, edit-then-log,
/// rapid repeated edits) — exactly the correctness gap this follow-up
/// closes.
///
/// `publish` is now `@MainActor`, so a `@MainActor` caller can call it
/// directly, synchronously — no `await`, no `Task`. It calls every
/// subscriber handler for that event type in turn, synchronously, before
/// returning — so by the time a caller's (synchronous, unchanged-signature)
/// `eventBus.publish(event)` call returns, every subscriber has FULLY
/// finished reacting. `subscribe`'s `handler` parameter is itself
/// `@MainActor`-qualified (not merely `@Sendable`) so a subscriber's
/// closure can call its own `@MainActor` methods directly inside the
/// handler, with no `Task`/actor-hop of its own — see
/// `NotificationsPlanningCoordinationService.subscribeToEvents` for the
/// real subscriber this enables. `subscribe`/`unsubscribe`/
/// `subscriberCount` stay plain, nonisolated, `NSLock`-guarded methods —
/// callable from any thread/actor, exactly like
/// `AthleteActivityChangeBroadcaster` (`VoxtrAppShell`) already
/// establishes for the identical "some operations must run on
/// `@MainActor`, others must be callable from anywhere" shape; this is
/// that same, already-proven-in-this-codebase pattern, not a new one.
/// `@unchecked Sendable` + `NSLock`, matching that same precedent (and
/// `VoxtrCore`'s own `DIContainer`) exactly.
public final class EventBus: @unchecked Sendable {

    public static let shared = EventBus()

    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: [UUID: @MainActor @Sendable (any DomainEvent) -> Void]] = [:]

    public init() {}

    /// Subscribe to a specific `DomainEvent` type. Returns a token you can
    /// pass to `unsubscribe` — there is no automatic cleanup, by design,
    /// so lifetime bugs are visible rather than silently leaking.
    /// `nonisolated`/thread-safe (via `lock`) so it can be called from
    /// any context; `handler` itself is `@MainActor`-qualified, so its
    /// body may call `@MainActor` code directly — it will only ever be
    /// invoked from `publish`, which is itself `@MainActor`.
    @discardableResult
    public func subscribe<Event: DomainEvent>(
        to eventType: Event.Type,
        handler: @escaping @MainActor @Sendable (Event) -> Void
    ) -> UUID {
        let token = UUID()
        let key = ObjectIdentifier(eventType)
        let wrapped: @MainActor @Sendable (any DomainEvent) -> Void = { event in
            guard let typed = event as? Event else { return }
            handler(typed)
        }
        lock.lock()
        subscribers[key, default: [:]][token] = wrapped
        lock.unlock()
        return token
    }

    public func unsubscribe<Event: DomainEvent>(_ token: UUID, from eventType: Event.Type) {
        let key = ObjectIdentifier(eventType)
        lock.lock()
        subscribers[key]?.removeValue(forKey: token)
        lock.unlock()
    }

    /// Publishes an event to every current subscriber of its concrete
    /// type, synchronously, one after another, before returning. Callers
    /// must be `@MainActor` (or `await` across into it) — see this
    /// type's own doc comment for why that's true of every real caller
    /// already, and why that's exactly what makes this deterministic.
    @MainActor
    public func publish<Event: DomainEvent>(_ event: Event) {
        let key = ObjectIdentifier(Event.self)
        lock.lock()
        let handlers = subscribers[key]?.values
        lock.unlock()
        handlers?.forEach { $0(event) }
    }

    /// Sprint 0 test/debug helper — number of active subscriptions for a type.
    public func subscriberCount<Event: DomainEvent>(for eventType: Event.Type) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers[ObjectIdentifier(eventType)]?.count ?? 0
    }
}
