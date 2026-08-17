import Foundation
import VoxtrCoreContracts

/// VX-023 (Sleep V1): the contract for "reread canonical Sleep state for
/// this athlete." Deliberately a SEPARATE protocol/type from
/// `AthleteActivityChangeSubscriber`/`AthleteActivityChangeBroadcaster` —
/// Sleep is not an activity-lifecycle mutation, and the task's own
/// instruction is explicit: "do not reuse `AthleteActivityChangeBroadcaster`
/// if Sleep is not an activity mutation — keep semantic ownership
/// correct." This type mirrors that broadcaster's proven-correct,
/// Codemagic-verified shape exactly (same locking discipline, same weak
/// subscriber storage, same deinit-safe subscription wrapper below) but
/// shares no code or storage with it.
@MainActor
public protocol AthleteSleepChangeSubscriber: AnyObject {
    func athleteSleepDidChange()
}

/// The ONE place a successful canonical Sleep (`DailyStatus.sleepQuality`)
/// create/update announces "athlete X's Sleep presentation may be stale"
/// — `SleepCoordinationService` calls `sleepChanged(for:)` after
/// `recordSleep` succeeds, never on a thrown failure.
///
/// Owned once, at `CompositionRoot`/app lifetime, and threaded by
/// reference everywhere a `SleepCoordinationService` or a live Sleep
/// presentation (Athlete Home Sleep card, Family Home Sleep section,
/// Sleep History) is already threaded — no global singleton, no
/// `NotificationCenter`.
///
/// ISOLATION: same shape as `AthleteActivityChangeBroadcaster` — see
/// that type's own doc comment for the full Codemagic-verified reasoning
/// this mirrors. `subscribe`/`sleepChanged` are `@MainActor`; `unsubscribe`
/// is deliberately `nonisolated` so `SleepChangeSubscription`'s own
/// `deinit` (below) can call it directly, safely, from a non-isolated
/// context. `@unchecked Sendable` with `NSLock`-guarded storage, mutated
/// only under `lock` from every one of `subscribe`/`unsubscribe`/
/// `sleepChanged`/`prune`.
///
/// Subscribers are held weakly, for the same reason
/// `AthleteActivityChangeBroadcaster` holds its own weakly — this
/// broadcaster outlives any individual subscribing view model. A dead
/// entry is pruned the next time `subscribe` or `sleepChanged` runs for
/// that athlete.
public final class AthleteSleepChangeBroadcaster: @unchecked Sendable {
    public struct SubscriptionToken: Hashable, Sendable {
        private let id: UUID

        public init() {
            self.id = UUID()
        }
    }

    private struct WeakSubscriber {
        weak var value: AthleteSleepChangeSubscriber?
    }

    private let lock = NSLock()
    private var subscribersByAthlete: [AthleteId: [SubscriptionToken: WeakSubscriber]] = [:]

    public init() {}

    @discardableResult
    @MainActor
    public func subscribe(athleteId: AthleteId, _ subscriber: AthleteSleepChangeSubscriber) -> SubscriptionToken {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(athleteId: athleteId)
        let token = SubscriptionToken()
        subscribersByAthlete[athleteId, default: [:]][token] = WeakSubscriber(value: subscriber)
        return token
    }

    public nonisolated func unsubscribe(athleteId: AthleteId, token: SubscriptionToken) {
        lock.lock()
        defer { lock.unlock() }
        subscribersByAthlete[athleteId]?.removeValue(forKey: token)
        if subscribersByAthlete[athleteId]?.isEmpty == true {
            subscribersByAthlete[athleteId] = nil
        }
    }

    /// Notifies every still-live subscriber registered for `athleteId` —
    /// never any other athlete's subscribers. Each subscriber rereads
    /// canonical Sleep state through its own existing mechanism (e.g.
    /// `SleepCoordinationService.fetchDailyStatus`/`fetchDailyStatuses`)
    /// — this type never holds or derives any Sleep data of its own.
    @MainActor
    public func sleepChanged(for athleteId: AthleteId) {
        lock.lock()
        let entries = subscribersByAthlete[athleteId]
        lock.unlock()
        guard let entries else { return }
        for entry in entries.values {
            entry.value?.athleteSleepDidChange()
        }
        lock.lock()
        pruneLocked(athleteId: athleteId)
        lock.unlock()
    }

    /// Caller must already hold `lock`.
    private func pruneLocked(athleteId: AthleteId) {
        guard let entries = subscribersByAthlete[athleteId] else { return }
        let alive = entries.filter { $0.value.value != nil }
        subscribersByAthlete[athleteId] = alive.isEmpty ? nil : alive
    }

    /// Test-only introspection seam — same rationale as
    /// `AthleteActivityChangeBroadcaster.subscriberCount(for:)`.
    func subscriberCount(for athleteId: AthleteId) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribersByAthlete[athleteId]?.count ?? 0
    }
}

/// Deinit-safe subscription wrapper — same shape and same reasoning as
/// `ActivityChangeSubscription`, mirrored (not shared) for Sleep. Owns
/// exactly one `AthleteSleepChangeBroadcaster` subscription's lifetime;
/// releasing this object deterministically unsubscribes, without
/// requiring an `@MainActor`-isolated owner to read its own isolated
/// stored properties from its own `deinit` (the exact Codemagic failure
/// `ActivityChangeSubscription` was introduced to fix). Deliberately
/// carries no actor isolation of its own. `Sendable`: every stored
/// property is an immutable, independently `Sendable` value.
final class SleepChangeSubscription: Sendable {
    private let athleteId: AthleteId
    private let token: AthleteSleepChangeBroadcaster.SubscriptionToken
    private let broadcaster: AthleteSleepChangeBroadcaster

    init(athleteId: AthleteId, token: AthleteSleepChangeBroadcaster.SubscriptionToken, broadcaster: AthleteSleepChangeBroadcaster) {
        self.athleteId = athleteId
        self.token = token
        self.broadcaster = broadcaster
    }

    deinit {
        broadcaster.unsubscribe(athleteId: athleteId, token: token)
    }
}
