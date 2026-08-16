import Foundation
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// Sprint 1.2B: one row in a coherent "today" read model, shared by
/// Family Home, Athlete Home, and (where applicable) Daily Training —
/// generalizes the exact combining pattern `FamilyScheduleRow` already
/// established for Family Schedule, per this package's own instruction
/// to reuse/generalize existing architecture rather than building a
/// third implementation. `.planned` already covers both "not yet
/// logged" and "logged" (via `FamilyHomeRow.isCompleted`) — case B
/// from Part 2 is not a separate case, it's `.planned` with
/// `isCompleted == true`.
public enum TodayActivityRow: Identifiable {
    /// Case A/B (Part 2): a materialized `PlannedActivity`, whether or
    /// not it has been logged yet.
    case planned(FamilyHomeRow)
    /// Case C (Part 2): a recurring occurrence applicable today that
    /// has not been materialized into a real `PlannedActivity`. Has no
    /// `PlannedActivityId` — never fabricated one.
    case recurringOccurrence(athleteId: AthleteId, athleteName: String, suggestion: RecurringActivitySuggestion)
    /// Case D (Part 2): a `LoggedActivity` with no `PlannedActivityId`
    /// at all — genuinely unplanned, never presented as if it had been
    /// planned.
    case unplannedLogged(athleteId: AthleteId, athleteName: String, loggedActivity: LoggedActivity)

    public var id: String {
        switch self {
        case .planned(let row): return row.id
        case .recurringOccurrence(_, _, let suggestion): return suggestion.id
        case .unplannedLogged(_, _, let loggedActivity): return loggedActivity.id.uuidString
        }
    }

    public var athleteId: AthleteId {
        switch self {
        case .planned(let row): return row.athleteId
        case .recurringOccurrence(let athleteId, _, _): return athleteId
        case .unplannedLogged(let athleteId, _, _): return athleteId
        }
    }

    public var athleteName: String {
        switch self {
        case .planned(let row): return row.athleteName
        case .recurringOccurrence(_, let athleteName, _): return athleteName
        case .unplannedLogged(_, let athleteName, _): return athleteName
        }
    }

    public var title: String {
        switch self {
        case .planned(let row): return row.plannedActivity.title
        case .recurringOccurrence(_, _, let suggestion): return suggestion.title
        case .unplannedLogged(_, _, let loggedActivity): return loggedActivity.title
        }
    }

    /// Deterministic chronological sort key — no-start-time rows sort
    /// after timed ones, matching the same convention `FamilyHomeRow`'s
    /// own sorting already established.
    public var startLocalTimeSortKey: Int {
        let time: LocalTime?
        switch self {
        case .planned(let row): time = row.plannedActivity.startLocalTime
        case .recurringOccurrence(_, _, let suggestion): time = suggestion.startLocalTime
        case .unplannedLogged: time = nil
        }
        guard let time else { return Int.max }
        return time.hour * 60 + time.minute
    }

    /// Parent Home UX Closeout: an activity's end, for correctly
    /// bounding NOW to `start <= current time < end` — not just
    /// `start <= current time`, which would keep something "NOW"
    /// forever once it started, regardless of how long ago it ended.
    ///
    /// `nil` when duration is unknown — deliberately never fabricated.
    /// Inspected directly: neither `PlannedActivity.plannedDurationMinutes`
    /// nor `RecurringPlannedActivity.plannedDurationMinutes` (and
    /// therefore `RecurringActivitySuggestion.plannedDurationMinutes`,
    /// projected from it) is guaranteed — both default to `nil` with no
    /// precondition requiring a value, only a range check when one is
    /// present. This property itself never fabricates a duration — the
    /// canonical value, or nothing. Callers that need a bounded NOW
    /// window even when duration is genuinely unknown use
    /// `nowPresentationEndLocalTimeSortKey(fallbackDurationMinutes:)`
    /// below instead, which wraps this property without changing what
    /// it means.
    public var endLocalTimeSortKey: Int? {
        guard startLocalTimeSortKey != Int.max else { return nil }
        let durationMinutes: Int?
        switch self {
        case .planned(let row): durationMinutes = row.plannedActivity.plannedDurationMinutes
        case .recurringOccurrence(_, _, let suggestion): durationMinutes = suggestion.plannedDurationMinutes
        case .unplannedLogged: durationMinutes = nil
        }
        guard let durationMinutes else { return nil }
        return startLocalTimeSortKey + durationMinutes
    }

    /// Planned/Logged Activity lifecycle consistency cleanup (NOW
    /// fallback): a presentation-only variant of `endLocalTimeSortKey`
    /// above for NOW classification specifically — without this, an
    /// activity with a start time but no planned duration could never
    /// become NOW at all, no matter how long ago it started, which
    /// reads as a genuine gap rather than "duration honestly unknown."
    ///
    /// `endLocalTimeSortKey` itself is UNCHANGED and still means exactly
    /// what its own doc comment says — this method never mutates it,
    /// never derives a value that reaches `PlannedActivity`/`LoggedActivity`
    /// storage, and is read by nothing except NOW/NEXT presentation.
    /// `fallbackDurationMinutes` is applied only when a real duration is
    /// genuinely absent (`endLocalTimeSortKey == nil`) AND a start time
    /// exists; with no start time this still correctly returns `nil` —
    /// "it cannot be NOW" is about the start-time requirement, which
    /// this never relaxes, only the duration half.
    public func nowPresentationEndLocalTimeSortKey(fallbackDurationMinutes: Int) -> Int? {
        guard startLocalTimeSortKey != Int.max else { return nil }
        return endLocalTimeSortKey ?? (startLocalTimeSortKey + fallbackDurationMinutes)
    }

    /// Fix (Family Home sorting regression): a generic, domain-meaningful
    /// "is this already resolved" notion across all three row kinds —
    /// `.planned` uses its own real `isCompleted`, `.recurringOccurrence`
    /// is inherently not-yet-logged (it has no `PlannedActivityId` yet),
    /// `.unplannedLogged` is inherently already logged. This lives here,
    /// on the shared row type, rather than being re-derived by each
    /// consumer — but the composer's own `todayActivities(...)` still
    /// does not use it for ordering; that grouping is a presentation
    /// concern for whichever surface wants it (see `FamilyHomeViewModel`),
    /// not something baked into the shared data composition.
    public var isCompletedOrLogged: Bool {
        switch self {
        case .planned(let row): return row.isCompleted
        case .recurringOccurrence: return false
        case .unplannedLogged: return true
        }
    }
}

/// Sprint 1.2B, Part 2: the one, shared application-layer composer for
/// "what does today's training actually look like for this athlete" —
/// combining materialized planned activities (with their real
/// completion/logged relationship), unmaterialized recurring
/// occurrences applicable today, and genuinely unplanned logged
/// activities, without ever double-representing the same real-world
/// activity twice (Part 10's deduplication requirement).
///
/// Deduplication is by real identity, never title/date:
/// - A `PlannedActivity` that has been logged is represented ONCE, as
///   `.planned` with `isCompleted == true` — never also as a second
///   `.unplannedLogged` row. This works because the `LoggedActivity`
///   fetch below is filtered to `plannedActivityId == nil` — a
///   logged activity that DOES have a `PlannedActivityId` is, by
///   definition, already represented via the `.planned` row it's
///   linked to.
/// - A recurring occurrence that has already been materialized is
///   represented ONCE, as `.planned` — never also as
///   `.recurringOccurrence`. This is not new logic: it's the same
///   exclusion `PlanningService.deriveSuggestions` already performs
///   (excluding any occurrence whose `externalSourceId` matches an
///   already-accepted `PlannedActivity`), reused here exactly as
///   Family Schedule already reuses it — no new recurrence logic was
///   written for this composer.
///
/// Purely read-only: `deriveSuggestions` fetches, it does not
/// materialize. Nothing here ever creates a `PlannedActivity` merely
/// because Home was opened.
@MainActor
public final class TodayActivityComposer {
    private let planningService: PlanningService
    private let trainingService: TrainingService
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService

    public init(
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    ) {
        self.planningService = planningService
        self.trainingService = trainingService
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
    }

    /// Sprint 1.2B runtime closeout (P1): generalized from the
    /// original `todayActivities`, which hardcoded "today" internally.
    /// `loadTomorrow()` needs the exact same canonical composition —
    /// materialized planned activities plus unmaterialized recurring
    /// occurrences — for an arbitrary date, not a second,
    /// Tomorrow-specific aggregation. `includeUnplannedLogged` exists
    /// because a genuinely unplanned `LoggedActivity` is inherently a
    /// past/present fact — there is no meaningful "unplanned logged
    /// activity for tomorrow" case, and no existing repository method
    /// even fetches logged activities for an arbitrary future date;
    /// `todayActivities` below always passes `true` (its existing,
    /// unchanged behavior), `loadTomorrow()` passes `false`.
    public func activities(
        forAthlete athleteId: AthleteId,
        athleteName: String,
        on date: LocalDate,
        includeUnplannedLogged: Bool,
        calendar: Calendar = .current
    ) throws -> [TodayActivityRow] {
        var rows: [TodayActivityRow] = []

        // A/B: materialized planned activities, with their real
        // completion/logged relationship already resolved.
        let completions = try trainingPlanningCoordinationService.plannedActivitiesWithCompletion(
            forAthlete: athleteId, on: date, calendar: calendar
        )
        rows.append(contentsOf: completions.map { completion in
            .planned(FamilyHomeRow(
                id: completion.plannedActivity.id.uuidString,
                athleteId: athleteId,
                athleteName: athleteName,
                plannedActivity: completion.plannedActivity,
                isCompleted: completion.isCompleted
            ))
        })

        // C: recurring occurrences applicable on this date, not yet
        // materialized — deriveSuggestions already excludes any that
        // are (see this type's own doc comment above). Never
        // materializes anything merely by being composed here.
        let suggestions = try planningService.deriveSuggestions(
            forAthlete: athleteId, from: date, through: date, calendar: calendar
        )
        rows.append(contentsOf: suggestions.map { suggestion in
            .recurringOccurrence(athleteId: athleteId, athleteName: athleteName, suggestion: suggestion)
        })

        guard includeUnplannedLogged else {
            return rows.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        }

        // D: genuinely unplanned logged activities only — filtered to
        // no PlannedActivityId, so a logged PlannedActivity is never
        // double-represented. Only reached when includeUnplannedLogged
        // is true, which only ever happens via todayActivities' own
        // delegation below (i.e. `date` is genuinely today here) — so
        // the default `.now` reference is correct, not a leftover.
        let allLogged = try trainingService.fetchTodaysLoggedActivities(
            forAthlete: athleteId, calendar: calendar
        )
        let unplanned = allLogged.filter { $0.plannedActivityId == nil }
        rows.append(contentsOf: unplanned.map { loggedActivity in
            .unplannedLogged(athleteId: athleteId, athleteName: athleteName, loggedActivity: loggedActivity)
        })

        return rows.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
    }

    /// Preserved for full backward compatibility — every existing
    /// caller (Family Home, Athlete Home, Daily Training) is unchanged.
    /// Computes "today" as a `LocalDate` and delegates to the
    /// generalized `activities(forAthlete:athleteName:on:includeUnplannedLogged:calendar:)`
    /// above with `includeUnplannedLogged: true`, its own original
    /// behavior.
    public func todayActivities(
        forAthlete athleteId: AthleteId,
        athleteName: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) throws -> [TodayActivityRow] {
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        let today = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        return try activities(forAthlete: athleteId, athleteName: athleteName, on: today, includeUnplannedLogged: true, calendar: calendar)
    }
}
