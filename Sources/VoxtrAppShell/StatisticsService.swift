import Foundation
import VoxtrCoreContracts
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Statistics V1 foundation. Statistics is a READ/UNDERSTAND surface —
/// it composes the existing canonical Training/Reflection services
/// (`TrainingService`/`ReflectionService`, both already established
/// domain-service entry points) into typed, plain-value read models. It
/// owns no persisted state of its own: every number this type returns
/// is derived fresh from `LoggedActivity`/`ActivityReflection`/
/// `DailyStatus`, never cached or duplicated here. Lives in
/// `VoxtrAppShell`, the one layer allowed to compose across domains —
/// the same placement `TrainingPlanningCoordinationService`/
/// `WeeklyCoachingContextService` already establish for exactly this
/// reason (see those types' own doc comments).
///
/// Deliberately excluded from this foundation, per the approved V1
/// product contract: readiness/performance/completion scores,
/// sibling/athlete ranking, AI analysis, rolling averages, and any
/// chart/UI-specific structure. This type answers "what happened,"
/// nothing more.

// MARK: - Filter

/// Sport and Activity Type apply independently — either, both, or
/// neither may be set. `sportId == nil` here means "no Sport filter is
/// applied" (every activity matches, regardless of its own `sportId`),
/// never "match only activities with no Sport" — that is a distinct
/// question this filter does not currently ask. This mirrors the same
/// "nil means no constraint" convention every other optional filter in
/// this codebase already uses.
public struct StatisticsFilter: Hashable, Sendable {
    public var sportId: SportId?
    public var activityType: ActivityType?

    public init(sportId: SportId? = nil, activityType: ActivityType? = nil) {
        self.sportId = sportId
        self.activityType = activityType
    }

    /// No constraint at all — every performed activity in the requested
    /// interval matches.
    public static let none = StatisticsFilter()

    fileprivate func matches(_ activity: LoggedActivity) -> Bool {
        if let sportId, activity.sportId != sportId.rawValue {
            return false
        }
        if let activityType, activity.activityType != activityType {
            return false
        }
        return true
    }
}

// MARK: - Form / Sleep aggregate

/// The shared shape for both Form and Sleep: an arithmetic mean over
/// whatever values genuinely exist, plus how many values that mean was
/// computed from. `mean == nil` exactly when `sampleCount == 0` —
/// missing values are excluded from the average, never treated as
/// zero, and an interval with no recorded values at all reports "no
/// value," never a fabricated `0.0` that would misread as "felt/slept
/// terribly."
public struct StatisticsAggregate: Equatable, Sendable {
    public let mean: Double?
    public let sampleCount: Int

    public init(mean: Double?, sampleCount: Int) {
        self.mean = mean
        self.sampleCount = sampleCount
    }

    static func of(_ values: [Int]) -> StatisticsAggregate {
        guard !values.isEmpty else { return StatisticsAggregate(mean: nil, sampleCount: 0) }
        let sum = values.reduce(0, +)
        return StatisticsAggregate(mean: Double(sum) / Double(values.count), sampleCount: values.count)
    }
}

// MARK: - Weekly bucket

/// One Monday-start week within a requested interval. Unlike Form/Sleep
/// above, a week with zero performed training is a genuine, correctly
/// representable fact (`totalActualMinutes == 0`) — not a "missing
/// value" to omit, since a week can honestly have had no training at
/// all. Every week whose Monday falls within the requested interval is
/// represented, even when it contributes nothing, so a month-grouped-
/// into-weeks view has a complete, stable row set to render.
public struct StatisticsWeekBucket: Equatable, Sendable {
    public let weekStart: LocalDate
    public let totalActualMinutes: Int
    public let performedActivityCount: Int

    public init(weekStart: LocalDate, totalActualMinutes: Int, performedActivityCount: Int) {
        self.weekStart = weekStart
        self.totalActualMinutes = totalActualMinutes
        self.performedActivityCount = performedActivityCount
    }
}

// MARK: - Athlete summary

/// Everything one athlete card/timeline needs for a requested interval,
/// under a given filter. Carries no `@Model` references at all (unlike
/// `PlannedActivityCompletion`/`FamilyHomeRow`, which do, for their own
/// different display purposes) — `WeeklyCoachingContextService`'s own
/// established precedent for a pure-aggregate read model, since nothing
/// here needs entity identity for further mutation or per-row display,
/// only already-reduced numbers.
public struct StatisticsAthleteSummary: Equatable, Sendable {
    public let athleteId: AthleteId
    public let intervalStart: LocalDate
    public let intervalEnd: LocalDate
    public let filter: StatisticsFilter
    /// Sum of `durationMinutes` across every genuinely performed
    /// (Completed/PartiallyCompleted) activity matching `filter` in the
    /// interval — never a planned duration, never a Missed/Cancelled
    /// placeholder.
    public let totalActualMinutes: Int
    public let performedActivityCount: Int
    public let weeklyBuckets: [StatisticsWeekBucket]
    public let form: StatisticsAggregate
    public let sleep: StatisticsAggregate

    public init(
        athleteId: AthleteId,
        intervalStart: LocalDate,
        intervalEnd: LocalDate,
        filter: StatisticsFilter,
        totalActualMinutes: Int,
        performedActivityCount: Int,
        weeklyBuckets: [StatisticsWeekBucket],
        form: StatisticsAggregate,
        sleep: StatisticsAggregate
    ) {
        self.athleteId = athleteId
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.filter = filter
        self.totalActualMinutes = totalActualMinutes
        self.performedActivityCount = performedActivityCount
        self.weeklyBuckets = weeklyBuckets
        self.form = form
        self.sleep = sleep
    }
}

// MARK: - Service

@MainActor
public final class StatisticsService {
    private let trainingService: TrainingService
    private let reflectionService: ReflectionService

    public init(trainingService: TrainingService, reflectionService: ReflectionService) {
        self.trainingService = trainingService
        self.reflectionService = reflectionService
    }

    /// The one entry point this foundation exposes: everything a later
    /// UI needs to render one athlete's card/timeline for
    /// `[intervalStart, intervalEnd]` (inclusive), optionally narrowed
    /// by `filter`. Which athletes to call this for — "active athletes"
    /// — is deliberately NOT this service's concern: that roster
    /// already has one canonical source (`AthleteRepository`, read via
    /// `FamilyHomeViewModel`/`AthleteFamilyManagementViewModel` today),
    /// and duplicating "who is active" here would be exactly the kind
    /// of second, competing read this foundation must not introduce.
    public func athleteSummary(
        forAthlete athleteId: AthleteId,
        from intervalStart: LocalDate,
        through intervalEnd: LocalDate,
        filter: StatisticsFilter = .none,
        calendar: Calendar = .current
    ) throws -> StatisticsAthleteSummary {
        let (startDate, endDate) = Self.dateBounds(from: intervalStart, through: intervalEnd, calendar: calendar)
        let loggedActivities = try trainingService.fetchLoggedActivities(forAthlete: athleteId, from: startDate, to: endDate)
        let performed = loggedActivities.filter { Self.isPerformed($0.status) && filter.matches($0) }

        let totalActualMinutes = performed.reduce(0) { $0 + $1.durationMinutes }

        let weeklyBuckets = Self.weeklyBuckets(
            for: performed,
            from: intervalStart,
            through: intervalEnd,
            calendar: calendar
        )

        // Form: canonical source is `ActivityReflection.bodyFeeling`,
        // attributed to whichever performed activity it belongs to (so
        // Form aligns with the SAME training timeline this summary
        // already bucketed, per the approved "aligned over time"
        // contract) — never the reflection's own `createdAt`, and never
        // a title/date match: joined purely by the stable
        // `LoggedActivity`/`ActivityReflection` identity relationship
        // both entities already carry (`ActivityReflection.loggedActivityId
        // == LoggedActivity.id`, both raw `UUID`s of the SAME typed ID —
        // see `TrainingReflectionCoordinationService.recordSessionForm`,
        // the one place that link is ever created). Built defensively
        // (last-write-wins on a duplicate key) rather than via
        // `Dictionary(uniqueKeysWithValues:)`, which traps at runtime —
        // a read/statistics surface must never crash the app on
        // malformed or legacy data; `ReflectionService.recordActivityReflection`'s
        // own "one reflection per athlete+LoggedActivity" guard already
        // makes a genuine duplicate here unreachable through normal use,
        // this is defense in depth only.
        var reflectionByLoggedActivityId: [UUID: ActivityReflection] = [:]
        for reflection in try reflectionService.fetchActivityReflections(forAthlete: athleteId) {
            reflectionByLoggedActivityId[reflection.loggedActivityId] = reflection
        }
        let formValues = performed.compactMap { reflectionByLoggedActivityId[$0.id]?.bodyFeeling }
        let form = StatisticsAggregate.of(formValues)

        // Sleep: canonical source is `DailyStatus.sleepQuality`, read
        // via the SAME existing range fetch `SleepCoordinationService`/
        // Sleep History already use — dates with no `DailyStatus` row at
        // all are simply absent from the result (never a fabricated
        // zero), and Sleep tracking being OFF for this athlete does not
        // gate this read at all: tracking is a forward-looking
        // preference toggle only (see `SleepCoordinationService`'s own
        // doc comment — "disabled != missing... existing Sleep data
        // remains untouched"), so historical `DailyStatus` rows recorded
        // before/after a toggle remain exactly as real here as any other.
        let dailyStatuses = try reflectionService.fetchDailyStatuses(forAthlete: athleteId, from: intervalStart, to: intervalEnd)
        let sleepValues = dailyStatuses.compactMap(\.sleepQuality)
        let sleep = StatisticsAggregate.of(sleepValues)

        return StatisticsAthleteSummary(
            athleteId: athleteId,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            filter: filter,
            totalActualMinutes: totalActualMinutes,
            performedActivityCount: performed.count,
            weeklyBuckets: weeklyBuckets,
            form: form,
            sleep: sleep
        )
    }

    /// "Actual training" — genuinely happened, per the SAME canonical
    /// rule `TrainingValidator.requiresActualDuration(for:)`/
    /// `requiresForm(for:)` and `PlannedActivityCompletion.isGenuinelyCompleted`
    /// already establish for this exact question, reused here rather
    /// than re-derived: `.completed`/`.partiallyCompleted` only.
    /// `.missed`/`.cancelled` carry the schema's own `1`-minute
    /// placeholder duration (see `LogActivityViewModel.save()`'s own doc
    /// comment on that convention) — excluding them here is what keeps
    /// that placeholder from ever leaking into a real duration total.
    /// `.scheduled` is included only for exhaustiveness (never actually
    /// reached — nothing in this codebase writes a `LoggedActivity` with
    /// that status), the same defensive-exhaustiveness reasoning
    /// `PlannedActivityCompletion.isGenuinelyCompleted` already applies.
    private static func isPerformed(_ status: ActivityStatus) -> Bool {
        switch status {
        case .completed, .partiallyCompleted:
            return true
        case .missed, .cancelled, .scheduled:
            return false
        }
    }

    /// Converts an inclusive `[LocalDate, LocalDate]` interval into the
    /// `Date` bounds `TrainingService.fetchLoggedActivities(forAthlete:from:to:)`
    /// needs — the exact "start of day / end of day" conversion
    /// `TrainingService.fetchTodaysLoggedActivities` already establishes
    /// for the identical purpose, generalized from "today" to an
    /// arbitrary interval rather than reimplemented. Deliberately uses
    /// `Calendar.current` semantics (via the injected `calendar`
    /// parameter), the SAME device-local convention every other
    /// Date<->LocalDate boundary in this codebase already uses
    /// (`TrainingPlanningCoordinationService.today(referenceDate:calendar:)`
    /// and everything built on it) — Statistics does not introduce a
    /// second, athlete-timezone-aware calendar convention nothing else
    /// in the app currently follows.
    private static func dateBounds(
        from intervalStart: LocalDate,
        through intervalEnd: LocalDate,
        calendar: Calendar
    ) -> (Date, Date) {
        let startComponents = DateComponents(year: intervalStart.year, month: intervalStart.month, day: intervalStart.day)
        let startDate = calendar.date(from: startComponents) ?? .distantPast
        let endComponents = DateComponents(year: intervalEnd.year, month: intervalEnd.month, day: intervalEnd.day)
        let endOfDayStart = calendar.date(from: endComponents) ?? .distantFuture
        let endDate = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endOfDayStart) ?? endOfDayStart
        return (startDate, endDate)
    }

    /// Every Monday (`LocalDate.startOfWeek` — the one canonical week
    /// boundary this app already establishes, see that property's own
    /// doc comment) whose week overlaps `[intervalStart, intervalEnd]`,
    /// in ascending order. Pure `LocalDate` arithmetic, no `Calendar`
    /// involved — mirrors the week-walking technique
    /// `TrainingPlanningCoordinationService.plannedActivitiesWithCompletion(forAthlete:from:through:)`
    /// already uses for the same "which weeks does this range touch"
    /// question, adapted to return the boundaries themselves rather than
    /// fetch against them.
    private static func weekStarts(from intervalStart: LocalDate, through intervalEnd: LocalDate) -> [LocalDate] {
        guard intervalStart <= intervalEnd else { return [] }
        var starts: [LocalDate] = []
        var cursor = intervalStart.startOfWeek
        while cursor <= intervalEnd {
            starts.append(cursor)
            cursor = cursor.adding(days: 7)
        }
        return starts
    }

    private static func weeklyBuckets(
        for activities: [LoggedActivity],
        from intervalStart: LocalDate,
        through intervalEnd: LocalDate,
        calendar: Calendar
    ) -> [StatisticsWeekBucket] {
        var totals: [LocalDate: (minutes: Int, count: Int)] = [:]
        for activity in activities {
            let localDate = TrainingPlanningCoordinationService.today(referenceDate: activity.startedAt, calendar: calendar)
            let weekStart = localDate.startOfWeek
            var entry = totals[weekStart] ?? (0, 0)
            entry.minutes += activity.durationMinutes
            entry.count += 1
            totals[weekStart] = entry
        }
        return weekStarts(from: intervalStart, through: intervalEnd).map { weekStart in
            let entry = totals[weekStart] ?? (0, 0)
            return StatisticsWeekBucket(weekStart: weekStart, totalActualMinutes: entry.minutes, performedActivityCount: entry.count)
        }
    }
}
