import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrNotificationsDomain

/// Notifications V1 Activity Reminder UI slice: the outcome of a user
/// attempting to enable (or change the lead time of) a reminder —
/// distinct from `NotificationsPlanningCoordinationService.CoordinationError`,
/// which reports things that are wrong about the REQUEST itself
/// (missing activity, wrong athlete, no start time). Authorization being
/// denied, or the computed fire date already being in the past, are not
/// request errors — they are calm, expected outcomes a UI must be able
/// to show without treating them as a failure.
public enum ReminderEnableResult: Sendable, Equatable {
    /// PR #37 follow-up (Codemagic compile fix): the plain,
    /// `Sendable`-safe value the UI actually needs — never the SwiftData
    /// `ActivityReminder` persistence model itself, which is
    /// intentionally NOT `Sendable` (a `@Model` reference type tied to
    /// its own `ModelContext`, never meant to cross this `@MainActor
    /// @Sendable` completion boundary). `finishEnabling` below extracts
    /// this from the authoritative, just-persisted reminder before
    /// returning.
    case enabled(leadTimeMinutes: Int)
    /// The user was asked (or had already been asked) and declined —
    /// UI should explain this calmly and offer a path to system
    /// Settings, per this slice's own explicit contract. No reminder is
    /// active.
    case authorizationDenied
    /// The requested lead time, applied to this activity's own
    /// date/time/timezone, would fire in the past — nothing was
    /// scheduled. No reminder is active.
    case fireDateInPast
}

/// Notifications V1 Activity Reminder Foundation: the one place
/// `PlanningService` and `ActivityReminderService` are used together —
/// same placement rationale `TrainingPlanningCoordinationService`
/// already established for its own Planning+Training concern. Neither
/// `VoxtrPlanningDomain`/`VoxtrTrainingDomain` nor
/// `VoxtrNotificationsDomain` may depend on each other (no `*Domain`
/// target depends on another), so this cross-domain reaction can only
/// live here, in `VoxtrAppShell`.
///
/// Owns the EventBus subscriptions for the three business events this
/// V1 lifecycle needs (`PlannedActivityChanged`, `PlannedActivityDeleted`,
/// `ActivityLogged`) and the actual "recompute fire instant from current
/// canonical Planning truth" logic. PR #36 follow-up: the live
/// `subscribeToEvents(_:)` production wiring is now fully synchronous
/// and deterministic (see that method's own doc comment and `EventBus`'s)
/// — `handle...` methods below stay `internal` (not `private`) so tests
/// can ALSO call them directly with a constructed event to assert
/// decision logic in isolation, but production tests exercising the
/// full pipeline no longer need to bypass anything to get determinism.
@MainActor
public final class NotificationsPlanningCoordinationService {
    /// Thrown by `createReminder`, and surfaced through `enableReminder`'s
    /// `Result` for anything that isn't the calm `ReminderEnableResult`
    /// outcomes (`.authorizationDenied`/`.fireDateInPast`) — this is
    /// reserved for genuine request problems (missing activity, wrong
    /// athlete, no start time).
    public enum CoordinationError: Error, Sendable, Equatable {
        case plannedActivityNotFound
        case plannedActivityBelongsToDifferentAthlete
        /// A reminder needs a concrete start time to compute "N minutes
        /// before it starts" — `PlannedActivity.startLocalTime` is
        /// optional, and an activity with no start time has nothing to
        /// count down from.
        case plannedActivityHasNoStartTime
        /// Notifications V1 Activity Reminder UI slice: the requested
        /// lead time, applied to this activity's own canonical date/
        /// time/timezone, resolves to an instant that has already
        /// passed. Thrown by the low-level `createReminder(athleteId:plannedActivityId:leadTimeMinutes:)`
        /// below; `enableReminder`'s own UI-facing entry point catches
        /// this and reports it as `ReminderEnableResult.fireDateInPast`
        /// instead of propagating it as an error.
        case fireDateInPast
    }

    private let activityReminderService: ActivityReminderService
    private let planningService: PlanningService
    /// Notifications V1 Activity Reminder UI slice: injectable "now," so
    /// the past-fire-date guard below is deterministically testable —
    /// same `DateProvider` abstraction (`VoxtrCoreContracts`) already
    /// established for this exact purpose elsewhere in this codebase
    /// (`VoxtrMotivationDomain.DailyQuoteProvider`), never a direct
    /// `Date()`/`.now` call inside this type's own logic.
    private let dateProvider: any DateProvider

    public init(
        activityReminderService: ActivityReminderService,
        planningService: PlanningService,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.activityReminderService = activityReminderService
        self.planningService = planningService
        self.dateProvider = dateProvider
    }

    /// Registers this service's reaction to every business event this
    /// V1 lifecycle needs. Called once from `CompositionRoot.build()` —
    /// not from either domain module's own `configure`, since neither
    /// domain package may see the other (see this type's own doc
    /// comment).
    ///
    /// PR #36 follow-up (deterministic delivery): `EventBus.subscribe`'s
    /// `handler` parameter is now `@MainActor`-qualified (not merely
    /// `@Sendable`) — see `EventBus`'s own doc comment for the full
    /// reasoning. That lets each closure below call this service's own
    /// `@MainActor` `handle...` methods DIRECTLY, synchronously — no
    /// `Task`, no actor-hop of any kind. Combined with `PlanningService`/
    /// `TrainingService` now calling `eventBus.publish(event)` directly
    /// (also synchronous, also no `Task`), the full chain — canonical
    /// mutation -> publish -> this handler -> reminder reconciliation —
    /// is one synchronous, same-actor call sequence: by the time the
    /// ORIGINAL `PlanningService`/`TrainingService` mutation call
    /// returns, the corresponding reminder-lifecycle reaction below has
    /// ALREADY fully run. This method itself no longer needs to be
    /// `async` either, for the same reason. Every `handle...` method's
    /// decision logic is unchanged and remains directly unit-testable by
    /// calling it with a constructed event.
    public func subscribeToEvents(_ eventBus: EventBus) {
        eventBus.subscribe(to: PlannedActivityChanged.self) { [weak self] event in
            self?.handlePlannedActivityChanged(event)
        }
        eventBus.subscribe(to: PlannedActivityDeleted.self) { [weak self] event in
            self?.handlePlannedActivityDeleted(event)
        }
        eventBus.subscribe(to: ActivityLogged.self) { [weak self] event in
            self?.handleActivityLogged(event)
        }
    }

    // MARK: - Low-level create (assumes authorization already granted)

    /// Creates and schedules a reminder for `plannedActivityId`, owned by
    /// `athleteId`. Verifies the activity actually belongs to that
    /// athlete — privacy/isolation boundary, not merely a convenience
    /// check — before ever touching Notifications. Does NOT check or
    /// request notification authorization itself — that is
    /// `enableReminder`'s job, below, the entry point UI actually calls;
    /// this lower-level method stays a plain, synchronous, throwing
    /// primitive so `createReminder`'s own existing direct unit tests
    /// (foundation round) keep working unchanged.
    ///
    /// Notifications V1 Activity Reminder UI slice: throws
    /// `.fireDateInPast` when the requested lead time, applied to this
    /// activity's own canonical date/time/timezone, resolves to an
    /// instant that has already passed — never silently schedules a
    /// negative/expired interval (the production scheduler itself also
    /// guards this as defense-in-depth, but a rejected-at-the-domain-layer
    /// reminder never gets a misleadingly "active" persisted row in the
    /// first place).
    @discardableResult
    public func createReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int
    ) throws -> ActivityReminder {
        guard let activity = try planningService.fetchPlannedActivity(byId: plannedActivityId) else {
            throw CoordinationError.plannedActivityNotFound
        }
        guard activity.athleteId == athleteId.rawValue else {
            throw CoordinationError.plannedActivityBelongsToDifferentAthlete
        }
        guard let startLocalTime = activity.startLocalTime else {
            throw CoordinationError.plannedActivityHasNoStartTime
        }
        let fireInstant = try activity.localDate.absoluteDate(at: startLocalTime, in: activity.timeZoneId)
        let fireDate = fireInstant.addingTimeInterval(-Double(leadTimeMinutes) * 60)
        guard fireDate > dateProvider.now else {
            throw CoordinationError.fireDateInPast
        }
        return try activityReminderService.createReminder(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes,
            fireDate: fireDate,
            content: Self.buildContent(for: activity)
        )
    }

    // MARK: - UI-facing entry points

    /// Notifications V1 Activity Reminder UI slice: the current reminder
    /// intent for `plannedActivityId`, if any — used to prefill the
    /// Reminder control when opening the edit form. A thin passthrough,
    /// matching this service's own established "reuse the canonical
    /// service" boundary.
    public func fetchReminder(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> ActivityReminder? {
        try activityReminderService.fetchReminder(forPlannedActivity: plannedActivityId)
    }

    /// Notifications V1 Activity Reminder UI slice: turning Reminder Off
    /// — cancels the pending notification and removes the reminder
    /// intent row. A thin passthrough; a no-op if none was active.
    public func disableReminder(forPlannedActivity plannedActivityId: PlannedActivityId) throws {
        try activityReminderService.cancelReminder(forPlannedActivity: plannedActivityId)
    }

    /// Notifications V1 Activity Reminder UI slice: THE entry point the
    /// Activity Reminder UI control calls, both for the FIRST "turn
    /// Reminder On" and for every subsequent "change the lead time" —
    /// `createReminder` above already replaces any existing reminder for
    /// the same activity, so a lead-time change is simply enabling again
    /// with a new `leadTimeMinutes`. Requests notification authorization
    /// CONTEXTUALLY, only here, only when actually needed:
    /// - `.authorized` already: creates/schedules immediately.
    /// - `.notDetermined`: shows the real system prompt (via
    ///   `ActivityReminderService.requestAuthorization`) exactly once,
    ///   then proceeds only if granted.
    /// - `.denied`: never prompts again (iOS itself would silently no-op
    ///   a repeated request) — reports `.authorizationDenied` so the UI
    ///   can explain calmly and offer a path to system Settings.
    ///
    /// Never called anywhere except in direct response to an explicit
    /// user action (the Reminder control) — nothing in this app calls
    /// this at launch or automatically.
    public func enableReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        completion: @escaping @MainActor @Sendable (Result<ReminderEnableResult, CoordinationError>) -> Void
    ) {
        activityReminderService.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized:
                self.finishEnabling(athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: leadTimeMinutes, completion: completion)
            case .denied:
                completion(.success(.authorizationDenied))
            case .notDetermined:
                self.activityReminderService.requestAuthorization { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.finishEnabling(athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: leadTimeMinutes, completion: completion)
                    } else {
                        completion(.success(.authorizationDenied))
                    }
                }
            }
        }
    }

    /// The authorized-and-ready-to-create step `enableReminder` reaches
    /// after its permission check above — translates `createReminder`'s
    /// thrown errors into the `Result` shape `enableReminder`'s own
    /// completion expects, rather than duplicating the fire-date/
    /// athlete/start-time computation here.
    private func finishEnabling(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        completion: @escaping @MainActor @Sendable (Result<ReminderEnableResult, CoordinationError>) -> Void
    ) {
        do {
            let reminder = try createReminder(athleteId: athleteId, plannedActivityId: plannedActivityId, leadTimeMinutes: leadTimeMinutes)
            completion(.success(.enabled(leadTimeMinutes: reminder.leadTimeMinutes)))
        } catch CoordinationError.fireDateInPast {
            completion(.success(.fireDateInPast))
        } catch let error as CoordinationError {
            completion(.failure(error))
        } catch {
            // Defensive only: `createReminder`'s own `absoluteDate(at:in:)`
            // call could in principle throw `LocalDateTimeConversionError`
            // for a malformed `TimeZoneId`, but every `PlannedActivity`'s
            // `timeZoneId` is already a validated value used elsewhere in
            // this app for scheduling — not expected to occur in practice.
            // Reported as "not found" rather than silently succeeding,
            // since no reminder was actually created either way.
            completion(.failure(.plannedActivityNotFound))
        }
    }

    // MARK: - Event reactions (internal: directly unit-testable)

    /// Planning date/time/timezone changes: preserves reminder intent,
    /// recomputes the fire instant from CURRENT canonical Planning truth
    /// (never trusting anything cached), and replaces the pending
    /// notification. A no-op if no reminder is active for this activity,
    /// or if the activity can no longer be found (deleted between the
    /// mutation and this handler running).
    func handlePlannedActivityChanged(_ event: PlannedActivityChanged) {
        guard let activity = try? planningService.fetchPlannedActivity(byId: event.plannedActivityId) else { return }
        guard (try? activityReminderService.fetchReminder(forPlannedActivity: event.plannedActivityId)) != nil else { return }
        reschedule(for: activity)
    }

    /// Planned activity deleted: cancels the pending notification and
    /// removes the reminder intent row. A no-op if no reminder was active.
    func handlePlannedActivityDeleted(_ event: PlannedActivityDeleted) {
        try? activityReminderService.cancelReminder(forPlannedActivity: event.plannedActivityId)
    }

    /// Linked activity logged/completed before the reminder fires:
    /// cancels any still-pending reminder. A no-op if the log isn't
    /// linked to a `PlannedActivity`, or no reminder was active for it.
    func handleActivityLogged(_ event: ActivityLogged) {
        guard let plannedActivityId = event.plannedActivityId else { return }
        try? activityReminderService.cancelReminder(forPlannedActivity: plannedActivityId)
    }

    // MARK: - Shared recompute path

    private func reschedule(for activity: PlannedActivity) {
        guard let startLocalTime = activity.startLocalTime else {
            // The activity no longer has a concrete start time to count
            // down from — there is nothing left to schedule against, so
            // the honest outcome is cancelling, not leaving a stale
            // fire instant in place.
            try? activityReminderService.cancelReminder(forPlannedActivity: activity.plannedActivityId)
            return
        }
        guard let existing = try? activityReminderService.fetchReminder(forPlannedActivity: activity.plannedActivityId) else { return }
        guard let fireInstant = try? activity.localDate.absoluteDate(at: startLocalTime, in: activity.timeZoneId) else { return }
        let fireDate = fireInstant.addingTimeInterval(-Double(existing.leadTimeMinutes) * 60)
        // Notifications V1 Activity Reminder UI slice: an edit that moves
        // the activity such that the reminder's own fire instant would
        // now be in the past leaves nothing meaningful to reschedule —
        // cancel rather than leave a persisted row that LOOKS active but
        // will never fire (the production scheduler would silently no-op
        // it anyway; this keeps the domain-level state honest about it).
        guard fireDate > dateProvider.now else {
            try? activityReminderService.cancelReminder(forPlannedActivity: activity.plannedActivityId)
            return
        }
        try? activityReminderService.rescheduleReminder(
            forPlannedActivity: activity.plannedActivityId,
            fireDate: fireDate,
            content: Self.buildContent(for: activity)
        )
    }

    /// Minimum factual content only — no motivational copy, no
    /// Reflection/private data, no coach-like language. Resolved fresh
    /// from the canonical activity every time this is called, never
    /// cached. Deliberately isolated in this one small function so a
    /// later UI/product task can refine wording without touching any
    /// lifecycle/scheduling code above.
    private static func buildContent(for activity: PlannedActivity) -> ActivityReminderContent {
        ActivityReminderContent(
            title: activity.title ?? "Planned activity",
            body: "Starting soon"
        )
    }
}
