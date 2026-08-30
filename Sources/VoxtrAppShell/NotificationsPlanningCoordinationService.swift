import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrNotificationsDomain

/// Notifications V1 Activity Reminder UI slice: the outcome of a user
/// attempting to add or update one reminder — distinct from
/// `NotificationsPlanningCoordinationService.CoordinationError`, which
/// reports things that are wrong about the REQUEST itself (missing
/// activity, wrong athlete, no start time, unknown reminder id).
/// Authorization being denied, or the computed fire date already being
/// in the past, are not request errors — they are calm, expected
/// outcomes a UI must be able to show without treating them as a
/// failure.
public enum ReminderEnableResult: Sendable, Equatable {
    /// PR #37 follow-up (Codemagic compile fix): only the plain,
    /// `Sendable`-safe identity the UI needs — never the SwiftData
    /// `ActivityReminder` persistence model itself. Activity Reminder
    /// What/When: this id is the caller's own signal for "this specific
    /// reminder row is now genuinely persisted and scheduled" — used to
    /// set `ActivityReminderDraft.persistedId` for a newly-created
    /// reminder (an update already knows its own id).
    case enabled(activityReminderId: ActivityReminderId)
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
/// `subscribeToEvents(_:)` production wiring is fully synchronous and
/// deterministic (see that method's own doc comment and `EventBus`'s)
/// — `handle...` methods below stay `internal` (not `private`) so tests
/// can ALSO call them directly with a constructed event to assert
/// decision logic in isolation.
///
/// Activity Reminder What/When: a concrete `PlannedActivity` may now
/// have zero, one, or MULTIPLE independent reminders — every method
/// below either addresses ONE specific reminder (by its own stable
/// `ActivityReminderId`) or acts on EVERY reminder for one activity,
/// never an implicit "the singular one" (see
/// `ActivityReminderService`'s own updated doc comment for the same
/// generalization one layer down).
@MainActor
public final class NotificationsPlanningCoordinationService {
    /// Thrown by `createReminder`/`updateReminder`, and surfaced through
    /// `upsertReminder`'s `Result` for anything that isn't the calm
    /// `ReminderEnableResult` outcomes (`.authorizationDenied`/
    /// `.fireDateInPast`) — this is reserved for genuine request
    /// problems (missing activity, wrong athlete, no start time, unknown
    /// reminder id).
    public enum CoordinationError: Error, Sendable, Equatable {
        case plannedActivityNotFound
        case plannedActivityBelongsToDifferentAthlete
        /// A reminder needs a concrete start time to compute "N minutes
        /// before it starts" — `PlannedActivity.startLocalTime` is
        /// optional, and an activity with no start time has nothing to
        /// count down from.
        case plannedActivityHasNoStartTime
        /// The requested lead time, applied to this activity's own
        /// canonical date/time/timezone, resolves to an instant that has
        /// already passed. Thrown by `createReminder`/`updateReminder`
        /// below; `upsertReminder`'s own UI-facing entry point catches
        /// this and reports it as `ReminderEnableResult.fireDateInPast`
        /// instead of propagating it as an error.
        case fireDateInPast
        /// `updateReminder`/`deleteReminder` addressed an
        /// `ActivityReminderId` that no longer exists (already removed
        /// by a concurrent lifecycle reaction, or never existed).
        case reminderNotFound
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
    /// V1 lifecycle needs. Called once from `CompositionRoot.build()`.
    ///
    /// PR #36 follow-up (deterministic delivery): `EventBus.subscribe`'s
    /// `handler` parameter is `@MainActor`-qualified, letting each
    /// closure below call this service's own `@MainActor` `handle...`
    /// methods DIRECTLY, synchronously — no `Task`, no actor-hop.
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

    // MARK: - Low-level create/update (assumes authorization already granted)

    /// Creates and schedules a NEW, independent reminder for
    /// `plannedActivityId`, owned by `athleteId`. Verifies the activity
    /// actually belongs to that athlete — privacy/isolation boundary,
    /// not merely a convenience check — before ever touching
    /// Notifications. Does NOT check or request notification
    /// authorization itself — that is `upsertReminder`'s job, below, the
    /// entry point the UI actually calls.
    ///
    /// Never replaces or removes any existing reminder for the same
    /// activity — see `ActivityReminderService.createReminder`'s own
    /// doc comment.
    @discardableResult
    public func createReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        reminderText: String? = nil
    ) throws -> ActivityReminder {
        let activity = try resolveActivity(athleteId: athleteId, plannedActivityId: plannedActivityId)
        let fireDate = try computeFireDate(for: activity, leadTimeMinutes: leadTimeMinutes)
        return try activityReminderService.createReminder(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes,
            reminderText: reminderText,
            fireDate: fireDate,
            content: Self.buildContent(for: activity, reminderText: reminderText)
        )
    }

    /// Updates the SAME already-existing reminder — addressed by its own
    /// stable `ActivityReminderId` — with a new lead time/text, and
    /// reschedules it under the SAME request identity. Re-validates
    /// against CURRENT canonical Planning truth (never trusting a
    /// caller-supplied fire date), exactly like `createReminder` above.
    @discardableResult
    public func updateReminder(
        activityReminderId: ActivityReminderId,
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        reminderText: String? = nil
    ) throws -> ActivityReminder {
        let activity = try resolveActivity(athleteId: athleteId, plannedActivityId: plannedActivityId)
        let fireDate = try computeFireDate(for: activity, leadTimeMinutes: leadTimeMinutes)
        do {
            return try activityReminderService.updateReminder(
                activityReminderId,
                leadTimeMinutes: leadTimeMinutes,
                reminderText: reminderText,
                fireDate: fireDate,
                content: Self.buildContent(for: activity, reminderText: reminderText)
            )
        } catch ActivityReminderService.ActivityReminderServiceError.reminderNotFound {
            throw CoordinationError.reminderNotFound
        }
    }

    private func resolveActivity(athleteId: AthleteId, plannedActivityId: PlannedActivityId) throws -> PlannedActivity {
        guard let activity = try planningService.fetchPlannedActivity(byId: plannedActivityId) else {
            throw CoordinationError.plannedActivityNotFound
        }
        guard activity.athleteId == athleteId.rawValue else {
            throw CoordinationError.plannedActivityBelongsToDifferentAthlete
        }
        return activity
    }

    private func computeFireDate(for activity: PlannedActivity, leadTimeMinutes: Int) throws -> Date {
        guard let startLocalTime = activity.startLocalTime else {
            throw CoordinationError.plannedActivityHasNoStartTime
        }
        let fireInstant = try activity.localDate.absoluteDate(at: startLocalTime, in: activity.timeZoneId)
        let fireDate = fireInstant.addingTimeInterval(-Double(leadTimeMinutes) * 60)
        guard fireDate > dateProvider.now else {
            throw CoordinationError.fireDateInPast
        }
        return fireDate
    }

    // MARK: - UI-facing entry points

    /// Every reminder currently active for `plannedActivityId` — used to
    /// prefill the create/edit UI's reminder list. A thin passthrough.
    public func fetchReminders(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> [ActivityReminder] {
        try activityReminderService.fetchReminders(forPlannedActivity: plannedActivityId)
    }

    /// Removing ONE reminder — cancels its pending notification and
    /// removes its intent row. Never affects any sibling reminder for
    /// the same activity. A thin passthrough; a no-op if already gone.
    public func deleteReminder(_ activityReminderId: ActivityReminderId) throws {
        try activityReminderService.cancelReminder(activityReminderId)
    }

    /// Recent-text suggestions for the free-text "what" field — a thin
    /// passthrough to `ActivityReminderRepository.fetchRecentDistinctReminderTexts(forAthlete:limit:)`
    /// via `ActivityReminderService`; see that method's own doc comment
    /// for the exact recency/privacy-scope/dedup rules.
    public func recentReminderTexts(forAthlete athleteId: AthleteId, limit: Int = 5) throws -> [String] {
        try activityReminderService.fetchRecentReminderTexts(forAthlete: athleteId, limit: limit)
    }

    /// THE entry point the Reminder editor calls both to add a genuinely
    /// NEW reminder (`existingReminderId == nil`) and to commit a change
    /// to an ALREADY-EXISTING one (`existingReminderId` set) — both need
    /// the exact same contextual-permission dance before they may
    /// (re)schedule anything:
    /// - `.authorized` already: creates/updates and schedules
    ///   immediately.
    /// - `.notDetermined`: shows the real system prompt exactly once,
    ///   then proceeds only if granted.
    /// - `.denied`: never prompts again — reports `.authorizationDenied`
    ///   so the UI can explain calmly and offer a path to system
    ///   Settings.
    ///
    /// Never called anywhere except in direct response to an explicit
    /// user action (a reminder row's own commit) — nothing in this app
    /// calls this at launch or automatically.
    public func upsertReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        existingReminderId: ActivityReminderId?,
        leadTimeMinutes: Int,
        reminderText: String,
        completion: @escaping @MainActor @Sendable (Result<ReminderEnableResult, CoordinationError>) -> Void
    ) {
        activityReminderService.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized:
                self.finishUpserting(
                    athleteId: athleteId, plannedActivityId: plannedActivityId, existingReminderId: existingReminderId,
                    leadTimeMinutes: leadTimeMinutes, reminderText: reminderText, completion: completion
                )
            case .denied:
                completion(.success(.authorizationDenied))
            case .notDetermined:
                self.activityReminderService.requestAuthorization { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.finishUpserting(
                            athleteId: athleteId, plannedActivityId: plannedActivityId, existingReminderId: existingReminderId,
                            leadTimeMinutes: leadTimeMinutes, reminderText: reminderText, completion: completion
                        )
                    } else {
                        completion(.success(.authorizationDenied))
                    }
                }
            }
        }
    }

    /// The authorized-and-ready-to-(re)schedule step `upsertReminder`
    /// reaches after its permission check above — translates
    /// `createReminder`/`updateReminder`'s thrown errors into the
    /// `Result` shape `upsertReminder`'s own completion expects.
    private func finishUpserting(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        existingReminderId: ActivityReminderId?,
        leadTimeMinutes: Int,
        reminderText: String,
        completion: @escaping @MainActor @Sendable (Result<ReminderEnableResult, CoordinationError>) -> Void
    ) {
        do {
            let reminder: ActivityReminder
            if let existingReminderId {
                reminder = try updateReminder(
                    activityReminderId: existingReminderId, athleteId: athleteId, plannedActivityId: plannedActivityId,
                    leadTimeMinutes: leadTimeMinutes, reminderText: reminderText
                )
            } else {
                reminder = try createReminder(
                    athleteId: athleteId, plannedActivityId: plannedActivityId,
                    leadTimeMinutes: leadTimeMinutes, reminderText: reminderText
                )
            }
            completion(.success(.enabled(activityReminderId: reminder.activityReminderId)))
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
            completion(.failure(.plannedActivityNotFound))
        }
    }

    /// Create-flow batch helper: persists a list of draft reminders
    /// (What+When only, no existing id — see `ActivityReminderDraft`)
    /// against a just-created canonical `PlannedActivityId`,
    /// SEQUENTIALLY, so a `.notDetermined` authorization prompt is
    /// requested AT MOST once even if the user staged several draft
    /// reminders before Save (chaining avoids firing `requestAuthorization`
    /// once per draft in a tight, unordered burst — an unsafe/duplicate-
    /// prompt UX). Never called for a draft/temporary activity identity
    /// — only after `PlanningService.addPlannedActivity` has already
    /// succeeded. A draft with empty/whitespace-only text is skipped
    /// (never submitted) and passed through unchanged.
    public func persistDraftReminders(
        _ drafts: [ActivityReminderDraft],
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        startingAt index: Int = 0,
        results: [ActivityReminderDraft] = [],
        completion: @escaping @MainActor @Sendable ([ActivityReminderDraft]) -> Void
    ) {
        guard index < drafts.count else {
            completion(results)
            return
        }
        var draft = drafts[index]
        guard draft.hasMeaningfulText else {
            persistDraftReminders(
                drafts, athleteId: athleteId, plannedActivityId: plannedActivityId,
                startingAt: index + 1, results: results + [draft], completion: completion
            )
            return
        }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        upsertReminder(
            athleteId: athleteId, plannedActivityId: plannedActivityId, existingReminderId: nil,
            leadTimeMinutes: draft.leadTimeMinutes, reminderText: text
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.enabled(let activityReminderId)):
                draft.persistedId = activityReminderId
            case .success(.authorizationDenied):
                draft.authorizationDenied = true
            case .success(.fireDateInPast):
                draft.errorMessage = PlanningStrings.reminderFireDateInPast
            case .failure:
                draft.errorMessage = PlanningStrings.reminderGenericError
            }
            self.persistDraftReminders(
                drafts, athleteId: athleteId, plannedActivityId: plannedActivityId,
                startingAt: index + 1, results: results + [draft], completion: completion
            )
        }
    }

    // MARK: - Event reactions (internal: directly unit-testable)

    /// Planning date/time/timezone changes: preserves every reminder's
    /// own intent, recomputes each fire instant from CURRENT canonical
    /// Planning truth, and replaces every pending notification. A no-op
    /// if no reminder is active for this activity, or if the activity
    /// can no longer be found (deleted between the mutation and this
    /// handler running).
    func handlePlannedActivityChanged(_ event: PlannedActivityChanged) {
        guard let activity = try? planningService.fetchPlannedActivity(byId: event.plannedActivityId) else { return }
        let reminders = (try? activityReminderService.fetchReminders(forPlannedActivity: event.plannedActivityId)) ?? []
        guard !reminders.isEmpty else { return }
        reschedule(reminders, for: activity)
    }

    /// Planned activity deleted: cancels every pending notification and
    /// removes every reminder intent row for it. A no-op if none were
    /// active.
    func handlePlannedActivityDeleted(_ event: PlannedActivityDeleted) {
        try? activityReminderService.cancelAllReminders(forPlannedActivity: event.plannedActivityId)
    }

    /// Linked activity logged/completed before the reminder fires:
    /// cancels every still-pending reminder for it. A no-op if the log
    /// isn't linked to a `PlannedActivity`, or none were active.
    func handleActivityLogged(_ event: ActivityLogged) {
        guard let plannedActivityId = event.plannedActivityId else { return }
        try? activityReminderService.cancelAllReminders(forPlannedActivity: plannedActivityId)
    }

    // MARK: - Shared recompute path

    /// Reconciles EVERY reminder in `reminders` against `activity`'s
    /// current canonical state — never only the first one. Each
    /// reminder keeps its own lead time/text; only the fire instant is
    /// recomputed, per reminder.
    private func reschedule(_ reminders: [ActivityReminder], for activity: PlannedActivity) {
        guard let startLocalTime = activity.startLocalTime else {
            // The activity no longer has a concrete start time to count
            // down from — there is nothing left to schedule against for
            // ANY of its reminders, so the honest outcome is cancelling
            // all of them, not leaving a stale fire instant in place.
            for reminder in reminders {
                try? activityReminderService.cancelReminder(reminder.activityReminderId)
            }
            return
        }
        guard let fireInstant = try? activity.localDate.absoluteDate(at: startLocalTime, in: activity.timeZoneId) else { return }
        for reminder in reminders {
            let fireDate = fireInstant.addingTimeInterval(-Double(reminder.leadTimeMinutes) * 60)
            // An edit that moves the activity such that THIS reminder's
            // own fire instant would now be in the past leaves nothing
            // meaningful to reschedule — cancel just this one; siblings
            // with a still-future fire instant are unaffected.
            if fireDate > dateProvider.now {
                activityReminderService.rescheduleReminder(
                    reminder, fireDate: fireDate, content: Self.buildContent(for: activity, reminderText: reminder.reminderText)
                )
            } else {
                try? activityReminderService.cancelReminder(reminder.activityReminderId)
            }
        }
    }

    /// The notification's actual content: the user-authored "what"
    /// (`reminderText`) is the PRIMARY, actionable content — the title
    /// — with the activity's own title as calm, factual secondary
    /// context, resolved fresh from canonical Planning truth every time
    /// this is called, never cached or persisted into `ActivityReminder`
    /// itself. A `nil`/empty `reminderText` (a pre-existing PR #37
    /// reminder created before this field existed) falls back to that
    /// round's own original wording exactly, rather than showing an
    /// empty title. No motivational copy, no Reflection/private data, no
    /// coach-like or nagging language either way.
    private static func buildContent(for activity: PlannedActivity, reminderText: String?) -> ActivityReminderContent {
        guard let reminderText, !reminderText.isEmpty else {
            return ActivityReminderContent(title: activity.title ?? "Planned activity", body: "Starting soon")
        }
        return ActivityReminderContent(title: reminderText, body: activity.title ?? "Starting soon")
    }
}
