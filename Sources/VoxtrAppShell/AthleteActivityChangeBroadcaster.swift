import Foundation
import VoxtrCoreContracts

/// Recurring reopen stale-Athlete-Home fix (architecture round): the
/// contract for "reread canonical activity state for this athlete" —
/// `HomeDashboardViewModel` is the only production conformer today, but
/// this is intentionally not typed to it directly, so any future live
/// presentation of the same `TodayActivityRow` data could subscribe the
/// same way without `AthleteActivityChangeBroadcaster` itself changing.
/// `@MainActor`: mutates `@Observable`/UI-facing state on the
/// conformer, so this must always run on the main actor — matching
/// `AthleteActivityChangeBroadcaster.activityChanged(for:)`'s own
/// isolation below, which is the only thing that ever calls it.
@MainActor
public protocol AthleteActivityChangeSubscriber: AnyObject {
    func athleteActivityDidChange()
}

/// The ONE place a successful canonical activity-lifecycle mutation
/// announces "athlete X's activity presentation may be stale" — once,
/// regardless of which screen performed the mutation.
/// `TrainingReflectionCoordinationService` calls `activityChanged(for:)`
/// after each of its three mutating methods succeeds
/// (`logActivity`/`correctLoggedActivity`/`reopenNoTrainingOutcome`);
/// `WeeklyPlanningViewModel` also calls it after successful canonical
/// PlannedActivity create/edit/delete/materialization paths. Never on a
/// thrown mutation failure, since every call site sits after the
/// underlying canonical write already succeeded.
///
/// Deliberately a separate type from `TrainingReflectionCoordinationService`:
/// that type orchestrates Training+Reflection writes; this type owns
/// fan-out to already-live presentation. Two distinct responsibilities,
/// not one type doing both.
///
/// Owned once, at `CompositionRoot`/app lifetime, and threaded by
/// reference everywhere a `TrainingReflectionCoordinationService` or a
/// `HomeDashboardViewModel` is already threaded — no global singleton,
/// no `NotificationCenter`.
///
/// ISOLATION (review follow-up, subscription cleanup — and its own
/// Codemagic-driven correction: see `ActivityChangeSubscription` below
/// for why the deterministic-cleanup CALLER changed, not this type's own
/// isolation shape): `subscribe`/`activityChanged` are `@MainActor` —
/// every production and test call site is already on the main actor,
/// and `activityChanged` must be, to call
/// `AthleteActivityChangeSubscriber.athleteActivityDidChange()` (itself
/// `@MainActor`) synchronously. `unsubscribe`, by contrast, is
/// deliberately `nonisolated`, so it can be called directly, safely,
/// from any non-isolated context — in production, that's
/// `ActivityChangeSubscription`'s own `deinit` (see that type's own doc
/// comment for the full reasoning: an actor-isolated class's `deinit` is
/// itself `nonisolated` and cannot read that class's OWN isolated
/// stored properties, which is exactly what broke the FIRST version of
/// this fix — `HomeDashboardViewModel.deinit` reading its own
/// `@MainActor`-isolated subscription token directly — a real Codemagic
/// compile failure, not merely a theoretical concern). This type is
/// `@unchecked Sendable` with `NSLock`-guarded storage — the exact
/// pattern this package's own `DIContainer` (`VoxtrCore/DependencyInjection/DIContainer.swift`)
/// already establishes for "must be safely callable from a non-isolated
/// context." `subscribersByAthlete` is mutated ONLY under `lock`, from
/// every one of `subscribe`/`unsubscribe`/`activityChanged`/`prune` —
/// the same discipline throughout, regardless of which of those is
/// actor-isolated and which is not — so `unsubscribe` is safe to call
/// from literally any thread, synchronously, with no hop.
///
/// Subscribers are held weakly: this broadcaster far outlives any
/// individual `HomeDashboardViewModel` (a per-athlete cache in
/// `FamilyHomeContentView` may keep one alive for an entire app
/// session, but plenty of others — the "Manage Athletes" sheet, Profile
/// tab — are short-lived), so a strong reference here would leak every
/// one ever constructed. A dead entry is pruned the next time either
/// `subscribe` or `activityChanged` runs for that athlete — defensive
/// protection for a subscriber that never gets a deterministic
/// unregister call for some reason, not the primary cleanup mechanism
/// for one that does (every `HomeDashboardViewModel` does, via the
/// `ActivityChangeSubscription` object it owns — see that type below).
public final class AthleteActivityChangeBroadcaster: @unchecked Sendable {
    /// Explicit subscription identity — returned by `subscribe`, passed
    /// back to `unsubscribe` for deterministic cleanup. `Sendable`:
    /// crosses between `@MainActor`-isolated call sites (`subscribe`,
    /// most callers of `unsubscribe`) and the `nonisolated` `deinit`
    /// context `unsubscribe` is specifically designed to also be safe
    /// from — a plain `UUID` wrapper has no isolated state of its own,
    /// so this is trivially and genuinely safe, not `@unchecked`.
    public struct SubscriptionToken: Hashable, Sendable {
        private let id: UUID

        public init() {
            self.id = UUID()
        }
    }

    private struct WeakSubscriber {
        weak var value: AthleteActivityChangeSubscriber?
    }

    private let lock = NSLock()
    private var subscribersByAthlete: [AthleteId: [SubscriptionToken: WeakSubscriber]] = [:]

    public init() {}

    @discardableResult
    @MainActor
    public func subscribe(athleteId: AthleteId, _ subscriber: AthleteActivityChangeSubscriber) -> SubscriptionToken {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(athleteId: athleteId)
        let token = SubscriptionToken()
        subscribersByAthlete[athleteId, default: [:]][token] = WeakSubscriber(value: subscriber)
        return token
    }

    /// `nonisolated` — see this type's own doc comment for exactly why:
    /// this is what lets `ActivityChangeSubscription`'s own `deinit`
    /// (below) call it directly, synchronously, from a non-isolated
    /// context.
    public nonisolated func unsubscribe(athleteId: AthleteId, token: SubscriptionToken) {
        lock.lock()
        defer { lock.unlock() }
        subscribersByAthlete[athleteId]?.removeValue(forKey: token)
        if subscribersByAthlete[athleteId]?.isEmpty == true {
            subscribersByAthlete[athleteId] = nil
        }
    }

    /// Notifies every still-live subscriber registered for `athleteId`
    /// — never any other athlete's subscribers, preserving athlete
    /// isolation the same way every other athlete-keyed lookup in this
    /// app already does. Each subscriber rereads canonical state through
    /// its own existing mechanism (`HomeDashboardViewModel.loadTodaysTraining()`/
    /// `loadTodayActivityRows()`) — this type never holds or derives any
    /// presentation data of its own.
    @MainActor
    public func activityChanged(for athleteId: AthleteId) {
        lock.lock()
        let entries = subscribersByAthlete[athleteId]
        lock.unlock()
        guard let entries else { return }
        for entry in entries.values {
            entry.value?.athleteActivityDidChange()
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

    /// Test-only introspection seam — not `public`, reachable only via
    /// `@testable import` (the same convention `PlanningService.acceptSuggestion`'s
    /// own test-only `saveOverride` parameter already establishes in
    /// this codebase). The exact number of entries currently stored for
    /// `athleteId`, including any not-yet-pruned dead ones — lets a test
    /// prove `unsubscribe`/deinit-driven cleanup actually REMOVED an
    /// entry, not merely that a dead weak reference is silently skipped
    /// the next time `activityChanged` runs.
    func subscriberCount(for athleteId: AthleteId) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribersByAthlete[athleteId]?.count ?? 0
    }
}

/// Codemagic compile fix (review follow-up): owns exactly one
/// broadcaster subscription's lifetime, so releasing THIS object
/// deterministically unsubscribes — without requiring the owner
/// (`HomeDashboardViewModel`, `@MainActor`-isolated) to read any of ITS
/// OWN actor-isolated stored properties from ITS OWN `deinit`, which the
/// compiler rejects: Swift's `deinit` for an actor-isolated class is
/// itself `nonisolated`, and `nonisolated` code cannot read that same
/// class's `@MainActor`-isolated stored properties — confirmed by the
/// actual Codemagic failure this fixes ("main actor-isolated property
/// 'activityChangeSubscriptionToken' can not be referenced from a
/// nonisolated context"), which the previous round's local reasoning
/// (no compiler available in this sandbox) missed.
///
/// Deliberately carries NO actor isolation of its own — not
/// `@MainActor`, not any other global actor. That is what makes its own
/// `deinit` unremarkable: with no isolation to violate, reading its own
/// `let` stored properties from `deinit` is the completely ordinary case
/// every non-actor-isolated Swift type's `deinit` has always supported,
/// no special rule involved, nothing version-dependent, nothing this
/// investigation needs a compiler to confirm.
///
/// `Sendable`, not `@unchecked`: every stored property is an immutable
/// (`let`), independently `Sendable` value — `AthleteId`,
/// `AthleteActivityChangeBroadcaster.SubscriptionToken`, and
/// `AthleteActivityChangeBroadcaster` itself (`@unchecked Sendable`,
/// established above) — so the compiler can verify this conformance
/// directly.
///
/// Retains `broadcaster` STRONGLY — required to call `unsubscribe` from
/// `deinit`. No cycle: `AthleteActivityChangeBroadcaster` only ever
/// holds its subscribers (e.g. a `HomeDashboardViewModel`) WEAKLY, and
/// never holds a reference to this subscription object at all — the
/// broadcaster doesn't know this type exists; only the original
/// subscriber does, by holding it strongly as ordinary `@MainActor`
/// state.
final class ActivityChangeSubscription: Sendable {
    private let athleteId: AthleteId
    private let token: AthleteActivityChangeBroadcaster.SubscriptionToken
    private let broadcaster: AthleteActivityChangeBroadcaster

    init(athleteId: AthleteId, token: AthleteActivityChangeBroadcaster.SubscriptionToken, broadcaster: AthleteActivityChangeBroadcaster) {
        self.athleteId = athleteId
        self.token = token
        self.broadcaster = broadcaster
    }

    deinit {
        broadcaster.unsubscribe(athleteId: athleteId, token: token)
    }
}
