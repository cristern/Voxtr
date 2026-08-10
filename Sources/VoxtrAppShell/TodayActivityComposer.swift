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

    public func todayActivities(
        forAthlete athleteId: AthleteId,
        athleteName: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) throws -> [TodayActivityRow] {
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        let today = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)

        var rows: [TodayActivityRow] = []

        // A/B: materialized planned activities, with their real
        // completion/logged relationship already resolved.
        let completions = try trainingPlanningCoordinationService.plannedActivitiesWithCompletion(
            forAthlete: athleteId, on: today, calendar: calendar
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

        // C: recurring occurrences applicable today, not yet
        // materialized — deriveSuggestions already excludes any that
        // are (see this type's own doc comment above).
        let suggestions = try planningService.deriveSuggestions(
            forAthlete: athleteId, from: today, through: today, calendar: calendar
        )
        rows.append(contentsOf: suggestions.map { suggestion in
            .recurringOccurrence(athleteId: athleteId, athleteName: athleteName, suggestion: suggestion)
        })

        // D: genuinely unplanned logged activities only — filtered to
        // no PlannedActivityId, so a logged PlannedActivity is never
        // double-represented.
        let allLogged = try trainingService.fetchTodaysLoggedActivities(
            forAthlete: athleteId, referenceDate: referenceDate, calendar: calendar
        )
        let unplanned = allLogged.filter { $0.plannedActivityId == nil }
        rows.append(contentsOf: unplanned.map { loggedActivity in
            .unplannedLogged(athleteId: athleteId, athleteName: athleteName, loggedActivity: loggedActivity)
        })

        return rows.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
    }
}
