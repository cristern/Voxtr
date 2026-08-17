import Foundation
import VoxtrCoreContracts

/// Recurring reopen stale-Athlete-Home fix (architecture round): the
/// contract for "reread canonical activity state for this athlete" —
/// `HomeDashboardViewModel` is the only production conformer today, but
/// this is intentionally not typed to it directly, so any future live
/// presentation of the same `TodayActivityRow` data could subscribe the
/// same way without `AthleteActivityChangeBroadcaster` itself changing.
@MainActor
public protocol AthleteActivityChangeSubscriber: AnyObject {
    func athleteActivityDidChange()
}

/// The ONE place a successful canonical activity-lifecycle mutation
/// announces "athlete X's activity presentation may be stale" — once,
/// regardless of which screen performed the mutation.
/// `TrainingReflectionCoordinationService` calls `activityChanged(for:)`
/// after each of its three mutating methods succeeds
/// (`logActivity`/`correctLoggedActivity`/`reopenCancelledActivity`);
/// never on a thrown failure, since each call site sits after the
/// underlying write already succeeded.
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
/// Subscribers are held weakly: this broadcaster far outlives any
/// individual `HomeDashboardViewModel` (a per-athlete cache in
/// `FamilyHomeContentView` may keep one alive for an entire app
/// session, but plenty of others — the "Manage Athletes" sheet, Profile
/// tab — are short-lived), so a strong reference here would leak every
/// one ever constructed. A dead entry is pruned the next time either
/// `subscribe` or `activityChanged` runs for that athlete — no
/// unbounded growth from ViewModels that have already been
/// deallocated, and no reliance on `deinit` (which cannot safely
/// re-enter this `@MainActor` type from an arbitrary thread).
@MainActor
public final class AthleteActivityChangeBroadcaster {
    /// Explicit subscription identity — returned by `subscribe`, passed
    /// back to `unsubscribe` for deterministic, opt-in early cleanup.
    /// Never required for correctness (dead entries self-prune), only
    /// for a caller that wants to stop listening before deallocation.
    public struct SubscriptionToken: Hashable {
        private let id: UUID

        public init() {
            self.id = UUID()
        }
    }

    private struct WeakSubscriber {
        weak var value: AthleteActivityChangeSubscriber?
    }

    private var subscribersByAthlete: [AthleteId: [SubscriptionToken: WeakSubscriber]] = [:]

    public init() {}

    @discardableResult
    public func subscribe(athleteId: AthleteId, _ subscriber: AthleteActivityChangeSubscriber) -> SubscriptionToken {
        prune(athleteId: athleteId)
        let token = SubscriptionToken()
        subscribersByAthlete[athleteId, default: [:]][token] = WeakSubscriber(value: subscriber)
        return token
    }

    public func unsubscribe(athleteId: AthleteId, token: SubscriptionToken) {
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
    public func activityChanged(for athleteId: AthleteId) {
        guard let entries = subscribersByAthlete[athleteId] else { return }
        for entry in entries.values {
            entry.value?.athleteActivityDidChange()
        }
        prune(athleteId: athleteId)
    }

    private func prune(athleteId: AthleteId) {
        guard let entries = subscribersByAthlete[athleteId] else { return }
        let alive = entries.filter { $0.value.value != nil }
        subscribersByAthlete[athleteId] = alive.isEmpty ? nil : alive
    }
}
