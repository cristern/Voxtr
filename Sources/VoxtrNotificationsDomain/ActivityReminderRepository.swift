import Foundation
import SwiftData
import VoxtrCoreContracts

/// Notifications V1 Activity Reminder Foundation, generalized by
/// Activity Reminder What/When: insert/fetch/update/delete
/// `ActivityReminder` only — pure persistence, matching the same
/// "no #Predicate, fetch-then-filter" and "no cross-domain SwiftData
/// relationships" conventions `PlanningRepository`/`TrainingRepository`
/// already established (`plannedActivityId`/`athleteId` are plain typed-
/// ID-backed `UUID` fields here too, never a `@Relationship`). Whether a
/// reminder SHOULD be created/rescheduled/cancelled for a given
/// `PlannedActivity` is `ActivityReminderService`'s and
/// `NotificationsPlanningCoordinationService`'s decision, not this
/// repository's.
///
/// Activity Reminder What/When: a concrete `PlannedActivity` may now
/// have zero, one, or MULTIPLE independent reminders — the prior "at
/// most one active reminder per PlannedActivity" reading of the
/// contract is retired (see `ActivityReminder`'s own doc comment).
/// `fetch(forPlannedActivity:)` (singular) is replaced by
/// `fetchAll(forPlannedActivity:)`; `insert` no longer replaces an
/// existing row for the same activity.
@MainActor
public final class ActivityReminderRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Cross-domain coordinators may only form a single SwiftData unit
    /// of work when every participating repository owns this exact
    /// context instance — same contract `TrainingRepository.uses(modelContext:)`
    /// already establishes.
    public func uses(modelContext: ModelContext) -> Bool {
        self.modelContext === modelContext
    }

    /// Inserts a NEW `ActivityReminder` row. Does not verify the
    /// referenced `PlannedActivity` exists — same "persistence
    /// infrastructure only" boundary `PlanningRepository.insertPlannedActivity`
    /// already established for `WeekPlan`; the caller
    /// (`ActivityReminderService`, via `NotificationsPlanningCoordinationService`)
    /// is responsible for resolving the canonical activity first.
    ///
    /// Activity Reminder What/When: never replaces or removes an
    /// existing reminder for the same `plannedActivityId` — a second
    /// call for the same activity simply adds a second, independent
    /// row. Replacing/updating one specific reminder in place is
    /// `update(_:leadTimeMinutes:reminderText:)`, below, which the
    /// caller reaches for by the reminder's own stable
    /// `ActivityReminderId`, never by re-inserting.
    /// `createdAt` defaults to `.now`, matching `ActivityReminder.init`'s
    /// own default; exposed here (not merely on the model) so recent-
    /// text-suggestion tests can construct rows under explicit, distinct
    /// timestamps rather than relying on real wall-clock ordering
    /// between rapid, sequential `insert` calls — the same "no
    /// `Date.now` in a time-dependent test that asserts an exact order"
    /// rule this project's own testing conventions require.
    public func insert(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        reminderText: String? = nil,
        createdAt: Date = .now
    ) throws -> ActivityReminder {
        let reminder = ActivityReminder(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes,
            reminderText: reminderText,
            createdAt: createdAt,
            // PR #38 review follow-up: `updatedAt` is the recency key
            // `fetchRecentDistinctReminderTexts` now sorts by (see that
            // method's own doc comment) — for a freshly-inserted row,
            // "last touched" and "created" are the exact same instant,
            // so this follows the caller-supplied `createdAt` rather
            // than taking its own, separate `.now` (which would
            // otherwise make deterministic-`createdAt` tests
            // non-deterministic again through this second field).
            updatedAt: createdAt
        )
        modelContext.insert(reminder)
        try modelContext.save()
        return reminder
    }

    /// Every currently-active reminder for one `PlannedActivity` — zero,
    /// one, or many. Sorted by `createdAt` ascending (oldest first) for
    /// a deterministic, stable iteration/display order; every lifecycle
    /// reconciliation path (activity moved/deleted/logged, start time
    /// removed) must act on ALL of these, never only the first.
    public func fetchAll(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> [ActivityReminder] {
        let rawId = plannedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ActivityReminder>())
        return all.filter { $0.plannedActivityId == rawId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func fetch(byId activityReminderId: ActivityReminderId) throws -> ActivityReminder? {
        let rawId = activityReminderId.rawValue
        return try modelContext.fetch(FetchDescriptor<ActivityReminder>()).first { $0.id == rawId }
    }

    /// Updates an already-fetched reminder's mutable fields IN PLACE —
    /// preserves its stable `ActivityReminderId` (and therefore its
    /// scheduled notification's own request identity) across a
    /// lead-time or text edit, rather than delete-then-recreate under a
    /// new id.
    /// `updatedAt` defaults to `.now`, matching `ActivityReminder`'s own
    /// established meaning of "when was this row last touched" —
    /// exposed here (not merely defaulted internally) so recent-text-
    /// suggestion tests can construct an edit under an explicit, distinct
    /// timestamp rather than relying on real wall-clock ordering, the
    /// same reason `insert(...)`'s own `createdAt:` parameter exists.
    public func update(_ reminder: ActivityReminder, leadTimeMinutes: Int, reminderText: String?, updatedAt: Date = .now) throws -> ActivityReminder {
        precondition(leadTimeMinutes >= 0, "leadTimeMinutes must be non-negative")
        reminder.leadTimeMinutes = leadTimeMinutes
        reminder.reminderText = reminderText
        reminder.updatedAt = updatedAt
        try modelContext.save()
        return reminder
    }

    /// Removes an already-fetched `ActivityReminder`. The row's mere
    /// absence IS "this specific reminder is no longer active" — see
    /// `ActivityReminder`'s own doc comment for why no separate
    /// enabled/disabled flag exists. Removing one reminder never affects
    /// any sibling reminder for the same `PlannedActivity`.
    public func delete(_ reminder: ActivityReminder) throws {
        modelContext.delete(reminder)
        try modelContext.save()
    }

    /// Recent-text suggestions: distinct, most-recently-used
    /// user-authored reminder text for ONE athlete — never across
    /// athletes or families. Scoped by `athleteId` because that is this
    /// codebase's own existing isolation granularity for reminder data
    /// (`ActivityReminder.athleteId` is the same field every other
    /// reminder query in this repository already filters by); reusing
    /// it here, rather than inventing a separate suggestion-privacy
    /// rule, is what keeps this boundary correct.
    ///
    /// Ordered by most-recent `updatedAt` first — PR #38 review
    /// follow-up: this used to sort by `createdAt`, which only reflects
    /// when a row was first inserted. `updatedAt` is the field that
    /// genuinely represents "when was this reminder's text last
    /// touched": `insert(...)` sets it equal to `createdAt` (creating a
    /// row IS a use, at that same instant), and `update(...)` bumps it
    /// on every edit. So re-typing/reusing an existing reminder's text
    /// (editing it in place, rather than creating a brand-new row)
    /// genuinely counts as a fresh "use" and moves that text back toward
    /// the front of the suggestion list — matching "prefer most recently
    /// used" as the approved contract actually means, with no new
    /// scoring or history model: this reads the one canonical timestamp
    /// `ActivityReminder` already maintains for exactly this purpose.
    ///
    /// Deduplicated by exact (trimmed) text — first occurrence in that
    /// recency order wins, so re-using an already-suggested text never
    /// produces a duplicate entry. Bounded to `limit` results; empty/
    /// whitespace-only text is never suggested. No ranking beyond simple
    /// recency, no AI, no separate canonical "reminder type" — this
    /// reads the exact free text users already typed, nothing more.
    public func fetchRecentDistinctReminderTexts(forAthlete athleteId: AthleteId, limit: Int) throws -> [String] {
        let rawId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ActivityReminder>())
        let ordered = all
            .filter { $0.athleteId == rawId }
            .sorted { $0.updatedAt > $1.updatedAt }

        var seen: Set<String> = []
        var result: [String] = []
        for reminder in ordered {
            guard let text = reminder.reminderText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            guard !seen.contains(text) else { continue }
            seen.insert(text)
            result.append(text)
            if result.count >= limit { break }
        }
        return result
    }
}
