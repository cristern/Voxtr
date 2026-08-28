import Foundation
import VoxtrCoreContracts
import VoxtrPlanningDomain
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

    /// Plan vs Actual round: the exact same AND-of-independent-fields
    /// matching rule as `matches(_ activity: LoggedActivity)` above,
    /// applied to Planning's own `PlannedActivity` instead — the same
    /// selected Sport/Activity Type filter narrows both the Plan side
    /// and the Actual side identically (never a filtered Actual compared
    /// against an unfiltered Plan). `PlannedActivity.sportId` is a raw
    /// `UUID?`, matching `LoggedActivity.sportId`'s own storage — the
    /// same "nil means no Sport" convention applies on both sides.
    fileprivate func matches(_ activity: PlannedActivity) -> Bool {
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

// MARK: - Training breakdown

/// Training Breakdown round: aggregated actual Training minutes for one
/// Sport, scoped to one weekly bucket. `sportId == nil` represents
/// genuinely sport-less performed activities — `LoggedActivity.sportId`
/// is legitimately optional (an activity is valid with a non-blank
/// title OR a Sport, not necessarily both; see `ActivityIdentity`) —
/// never a fabricated Sport identity or a dropped segment. Stable-ID
/// identity only; no display string is ever the identity here, matching
/// `StatisticsFilter.sportId`'s own convention.
public struct SportTrainingMinutes: Equatable, Sendable {
    public let sportId: SportId?
    public let minutes: Int

    public init(sportId: SportId?, minutes: Int) {
        self.sportId = sportId
        self.minutes = minutes
    }
}

/// Same shape as `SportTrainingMinutes`, keyed by the canonical
/// `ActivityType` enum itself — already the one stable, closed identity
/// this domain uses for Activity Type; no separate `ActivityTypeId`
/// type exists, and none is introduced here.
public struct ActivityTypeTrainingMinutes: Equatable, Sendable {
    public let activityType: ActivityType
    public let minutes: Int

    public init(activityType: ActivityType, minutes: Int) {
        self.activityType = activityType
        self.minutes = minutes
    }
}

// MARK: - Weekly bucket

/// One Monday-start week overlapping a requested interval. Unlike
/// Form/Sleep above, a week with zero performed training is a genuine,
/// correctly representable fact (`totalActualMinutes == 0`) — not a
/// "missing value" to omit, since a week can honestly have had no
/// training at all. Every canonical week that overlaps
/// `[intervalStart, intervalEnd]` is represented, even when it
/// contributes nothing — including the first week, whose own Monday
/// (`intervalStart.startOfWeek`) may fall BEFORE `intervalStart` when
/// the interval itself doesn't start on a Monday — so a month-grouped-
/// into-weeks view has a complete, stable row set to render.
public struct StatisticsWeekBucket: Equatable, Sendable {
    public let weekStart: LocalDate
    public let totalActualMinutes: Int
    public let performedActivityCount: Int
    /// Statistics V1 UI round: same canonical source, join, and
    /// filter-narrowing as the interval-level `StatisticsAthleteSummary.form`
    /// above, scoped to just this week — a performed activity contributes
    /// its `bodyFeeling` (if any) to the SAME week its minutes/count are
    /// bucketed into. Missing excluded, never zero.
    public let form: StatisticsAggregate
    /// Statistics V1 UI round: same canonical source as
    /// `StatisticsAthleteSummary.sleep` above, bucketed by
    /// `DailyStatus.localDate.startOfWeek` — deliberately built from the
    /// SAME unfiltered `dailyStatuses` read the interval-level aggregate
    /// uses, never narrowed by `StatisticsFilter`. Sleep is the athlete's
    /// own context for the period, not something a Sport/Activity Type
    /// choice should be able to hide or fabricate away.
    public let sleep: StatisticsAggregate
    /// Training Breakdown round: `totalActualMinutes` broken down by
    /// Sport — built from the SAME already-filtered `performed`
    /// activities `totalActualMinutes` itself sums, so
    /// `trainingBySport.map(\.minutes).reduce(0, +) == totalActualMinutes`
    /// always holds (minute conservation — see this type's own tests).
    /// Sorted deterministically by stable Sport identity (never by
    /// insertion/dictionary-iteration order), with the "no Sport"
    /// segment (`sportId == nil`) always last. Presentation-only default
    /// `[]` preserves every existing call site/test that predates
    /// Training Breakdown.
    public let trainingBySport: [SportTrainingMinutes]
    /// Same conservation guarantee as `trainingBySport`, keyed by
    /// `ActivityType` instead — `trainingByActivityType.map(\.minutes)
    /// .reduce(0, +) == totalActualMinutes` always holds. Sorted by
    /// `ActivityType.allCases`'s own fixed declaration order — the one
    /// canonical, deterministic ordering this enum already establishes.
    public let trainingByActivityType: [ActivityTypeTrainingMinutes]
    /// Plan vs Actual round: how many `PlannedActivity` rows genuinely
    /// existed (canonical Planning truth, never reconstructed from
    /// Training) with `localDate` inside this week AND inside the
    /// requested interval — independent of whether they were ever
    /// performed. A planned activity later Missed/Cancelled on the
    /// Actual side still counts here; this field never subtracts for
    /// that. See `StatisticsAthleteSummary.plannedActivityCount`'s own
    /// doc comment for the full future-date clamp/filter contract this
    /// shares. Default `0` preserves every call site/test predating
    /// Plan vs Actual.
    public let plannedActivityCount: Int
    /// Sum of `PlannedActivity.plannedDurationMinutes` across the SAME
    /// planned activities `plannedActivityCount` counts — a planned
    /// activity with no recorded planned duration (a legitimately
    /// optional field) contributes to the count above but never a
    /// fabricated/inferred/default minutes value here. Default `0`
    /// preserves every call site/test predating Plan vs Actual.
    public let plannedMinutes: Int

    public init(
        weekStart: LocalDate,
        totalActualMinutes: Int,
        performedActivityCount: Int,
        form: StatisticsAggregate,
        sleep: StatisticsAggregate,
        trainingBySport: [SportTrainingMinutes] = [],
        trainingByActivityType: [ActivityTypeTrainingMinutes] = [],
        plannedActivityCount: Int = 0,
        plannedMinutes: Int = 0
    ) {
        self.weekStart = weekStart
        self.totalActualMinutes = totalActualMinutes
        self.performedActivityCount = performedActivityCount
        self.form = form
        self.sleep = sleep
        self.trainingBySport = trainingBySport
        self.trainingByActivityType = trainingByActivityType
        self.plannedActivityCount = plannedActivityCount
        self.plannedMinutes = plannedMinutes
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
    /// Plan vs Actual round: how many canonical `PlannedActivity` rows
    /// (Planning's own truth — never reconstructed from Training/
    /// `LoggedActivity`) exist with `localDate` inside
    /// `[intervalStart, min(intervalEnd, today)]` and matching `filter`
    /// — independent of whether performed; a planned activity later
    /// Missed/Cancelled on the Actual side still counts here. The
    /// `min(intervalEnd, today)` clamp is deliberate: Statistics is
    /// "understand what already happened," so a rolling/calendar-month
    /// period that extends into the future (a current, still-in-progress
    /// calendar month) must never let planning done for those not-yet-
    /// arrived days distort a historical comparison — see
    /// `athleteSummary(today:)`'s own doc comment for the exact rule.
    /// `.rolling` periods already end exactly at `today` (see
    /// `StatisticsPeriod.interval(today:)`), so this clamp only ever
    /// changes anything for `.calendarMonth`.
    public let plannedActivityCount: Int
    /// Sum of `PlannedActivity.plannedDurationMinutes` across the SAME
    /// planned activities `plannedActivityCount` counts — never
    /// fabricated/inferred for a planned activity with no recorded
    /// planned duration (a legitimately optional field); such an
    /// activity still contributes to `plannedActivityCount` above, just
    /// not to this sum.
    public let plannedMinutes: Int

    public init(
        athleteId: AthleteId,
        intervalStart: LocalDate,
        intervalEnd: LocalDate,
        filter: StatisticsFilter,
        totalActualMinutes: Int,
        performedActivityCount: Int,
        weeklyBuckets: [StatisticsWeekBucket],
        form: StatisticsAggregate,
        sleep: StatisticsAggregate,
        plannedActivityCount: Int = 0,
        plannedMinutes: Int = 0
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
        self.plannedActivityCount = plannedActivityCount
        self.plannedMinutes = plannedMinutes
    }
}

// MARK: - Week Drilldown

/// Week Drilldown round: the smallest useful factual identity for one
/// canonical `PlannedActivity` row inside a `StatisticsWeekDetail` — a
/// plain projection, never a `@Model` reference, matching the same
/// "Statistics carries no model references" architecture
/// `StatisticsAthleteSummary` already established. `plannedActivityId`
/// is the stable canonical identity; `title`/`sportId` are never fused
/// into one display string here — that's a presentation concern for
/// whatever renders this row (see `ActivityLabelResolver`, already
/// established for exactly this title-or-Sport fallback rule).
public struct StatisticsPlannedActivityRow: Identifiable, Equatable, Sendable {
    public let plannedActivityId: PlannedActivityId
    public let localDate: LocalDate
    public let startLocalTime: LocalTime?
    public let sportId: SportId?
    public let activityType: ActivityType
    public let title: String?
    /// Never fabricated when the canonical `PlannedActivity` itself has
    /// no recorded planned duration — `nil` here means exactly that,
    /// the same "missing, not zero" contract `plannedMinutes` already
    /// establishes at the aggregate level.
    public let plannedDurationMinutes: Int?

    public var id: PlannedActivityId { plannedActivityId }

    public init(
        plannedActivityId: PlannedActivityId,
        localDate: LocalDate,
        startLocalTime: LocalTime?,
        sportId: SportId?,
        activityType: ActivityType,
        title: String?,
        plannedDurationMinutes: Int?
    ) {
        self.plannedActivityId = plannedActivityId
        self.localDate = localDate
        self.startLocalTime = startLocalTime
        self.sportId = sportId
        self.activityType = activityType
        self.title = title
        self.plannedDurationMinutes = plannedDurationMinutes
    }
}

/// Week Drilldown round: the exact same "smallest useful factual
/// identity" shape as `StatisticsPlannedActivityRow` above, projected
/// from a canonical, genuinely PERFORMED `LoggedActivity` instead —
/// every row here already satisfies `StatisticsService`'s own
/// `isPerformed(_:)` rule (`.completed`/`.partiallyCompleted` only),
/// the caller never needs to re-check `status` to know whether a row
/// belongs on the Actual side. `status` itself is still carried
/// (`.completed` vs `.partiallyCompleted` remain factually distinct),
/// never used to imply a score.
public struct StatisticsPerformedActivityRow: Identifiable, Equatable, Sendable {
    public let loggedActivityId: LoggedActivityId
    public let startedAt: Date
    public let sportId: SportId?
    public let activityType: ActivityType
    public let title: String?
    public let durationMinutes: Int
    public let status: ActivityStatus

    public var id: LoggedActivityId { loggedActivityId }

    public init(
        loggedActivityId: LoggedActivityId,
        startedAt: Date,
        sportId: SportId?,
        activityType: ActivityType,
        title: String?,
        durationMinutes: Int,
        status: ActivityStatus
    ) {
        self.loggedActivityId = loggedActivityId
        self.startedAt = startedAt
        self.sportId = sportId
        self.activityType = activityType
        self.title = title
        self.durationMinutes = durationMinutes
        self.status = status
    }
}

/// Week Drilldown round: the factual explanation of ONE canonical
/// Monday-start Statistics week — everything `WeekDrilldownView` needs
/// to render "what happened in this week" without querying
/// `PlanningRepository`/`TrainingRepository` itself. Carries no
/// `@Model` references, matching `StatisticsAthleteSummary`'s own
/// established architecture. `plannedActivityCount`/`plannedMinutes`/
/// `performedActivityCount`/`totalActualMinutes` here are computed by
/// the EXACT SAME semantics `athleteSummary`'s own weekly buckets use
/// (see `weekDetail(forAthlete:weekStart:within:through:filter:today:calendar:)`'s
/// own doc comment) — a `StatisticsWeekDetail` for the same
/// athlete/week/interval/filter/today as an `athleteSummary` call
/// always agrees with that call's own `StatisticsWeekBucket` for that
/// week (see this type's own parity tests).
public struct StatisticsWeekDetail: Equatable, Sendable {
    public let athleteId: AthleteId
    /// The canonical Monday `weekStart` this drilldown represents —
    /// stable identity, never a display string/index. See this type's
    /// own doc comment.
    public let weekStart: LocalDate
    /// The SELECTED Statistics interval this drilldown was opened
    /// from — NOT necessarily `[weekStart, weekStart+6]`: a calendar-
    /// month period's partial edge week only contributes the portion
    /// that actually falls inside `[intervalStart, intervalEnd]`. See
    /// `weekDetail`'s own doc comment for the exact effective-interval
    /// computation.
    public let intervalStart: LocalDate
    public let intervalEnd: LocalDate
    public let filter: StatisticsFilter
    public let plannedActivityCount: Int
    public let plannedMinutes: Int
    public let performedActivityCount: Int
    public let totalActualMinutes: Int
    /// Chronological by `localDate`/`startLocalTime` (no-time rows
    /// last), then stable `plannedActivityId` — never repository/
    /// dictionary iteration order. See `weekDetail`'s own doc comment.
    public let plannedActivities: [StatisticsPlannedActivityRow]
    /// Chronological by `startedAt`, then stable `loggedActivityId`.
    public let performedActivities: [StatisticsPerformedActivityRow]
    public let form: StatisticsAggregate
    public let sleep: StatisticsAggregate

    public init(
        athleteId: AthleteId,
        weekStart: LocalDate,
        intervalStart: LocalDate,
        intervalEnd: LocalDate,
        filter: StatisticsFilter,
        plannedActivityCount: Int,
        plannedMinutes: Int,
        performedActivityCount: Int,
        totalActualMinutes: Int,
        plannedActivities: [StatisticsPlannedActivityRow],
        performedActivities: [StatisticsPerformedActivityRow],
        form: StatisticsAggregate,
        sleep: StatisticsAggregate
    ) {
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.filter = filter
        self.plannedActivityCount = plannedActivityCount
        self.plannedMinutes = plannedMinutes
        self.performedActivityCount = performedActivityCount
        self.totalActualMinutes = totalActualMinutes
        self.plannedActivities = plannedActivities
        self.performedActivities = performedActivities
        self.form = form
        self.sleep = sleep
    }
}

// MARK: - Service

@MainActor
public final class StatisticsService {
    private let trainingService: TrainingService
    private let reflectionService: ReflectionService
    /// Plan vs Actual round: Planning is the authoritative owner of
    /// planned-activity truth (see `athleteSummary`'s own doc comment) —
    /// added as a third composed domain service, the same "smallest
    /// maintainable dependency" role `trainingService`/`reflectionService`
    /// already fill. Statistics still owns no persisted state of its own
    /// and never mutates through this dependency — only the read-only
    /// `fetchWeekPlan(forAthlete:weekStart:)`/`fetchPlannedActivities(forWeekPlan:)`
    /// passthroughs are ever called.
    private let planningService: PlanningService

    public init(trainingService: TrainingService, reflectionService: ReflectionService, planningService: PlanningService) {
        self.trainingService = trainingService
        self.reflectionService = reflectionService
        self.planningService = planningService
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
    /// Plan vs Actual round: `today` is the caller's own already-computed
    /// "current day" (`AthleteStatisticsViewModel.today`, the SAME
    /// reference date `period.interval(today:)` was built from) — never
    /// re-derived here from `Date.now`, so the Planned side's future-date
    /// clamp (see below) can never disagree with the interval the caller
    /// actually requested. Defaults to a fresh `TrainingPlanningCoordinationService
    /// .today()` only for callers (and tests) that don't need to inject a
    /// deterministic reference date.
    public func athleteSummary(
        forAthlete athleteId: AthleteId,
        from intervalStart: LocalDate,
        through intervalEnd: LocalDate,
        filter: StatisticsFilter = .none,
        today: LocalDate = TrainingPlanningCoordinationService.today(),
        calendar: Calendar = .current
    ) throws -> StatisticsAthleteSummary {
        let (startDate, endExclusive) = Self.dateBounds(from: intervalStart, through: intervalEnd, calendar: calendar)
        // The repository read below is inclusive on its own `to` bound
        // (`startedAt <= to`), so passing `endExclusive` (midnight at the
        // start of the day AFTER `intervalEnd`) as `to` fetches a superset
        // that could in principle include an activity landing exactly on
        // that boundary instant. The `< endExclusive` filter enforces the
        // true `[intervalStart, intervalEnd]`-inclusive contract without
        // reimplementing the repository's own range-matching logic — one
        // business truth (the repository's `<=`), refined by one
        // additional, exact comparison against the same `endExclusive`
        // this method itself derived.
        let loggedActivities = try trainingService
            .fetchLoggedActivities(forAthlete: athleteId, from: startDate, to: endExclusive)
            .filter { $0.startedAt < endExclusive }
        let performed = loggedActivities.filter { Self.isPerformed($0.status) && filter.matches($0) }

        let totalActualMinutes = performed.reduce(0) { $0 + $1.durationMinutes }

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

        // Plan vs Actual round: Planning is the sole authoritative owner
        // of planned-activity truth — every planned count/minute here
        // comes from canonical `PlannedActivity` rows fetched through
        // `planningService`, never reconstructed from `LoggedActivity`
        // metadata. `plannedIntervalEnd` is the future-date clamp: a
        // `.rolling` period's own `intervalEnd` already IS `today` (see
        // `StatisticsPeriod.interval(today:)`), so this only ever
        // narrows a `.calendarMonth` period that includes still-upcoming
        // days in the current month — those days' existing plans must
        // not be counted as "what happened" in a screen whose whole
        // purpose is understanding the past. `intervalStart > plannedIntervalEnd`
        // (an entirely-future selected period) yields an empty planned
        // set rather than walking any weeks at all.
        let plannedIntervalEnd = min(intervalEnd, today)
        let plannedActivities: [PlannedActivity]
        if intervalStart <= plannedIntervalEnd {
            let plannedWeekStarts = Self.weekStarts(from: intervalStart, through: plannedIntervalEnd)
            plannedActivities = try Self.fetchPlannedActivities(
                planningService: planningService,
                forAthlete: athleteId,
                weekStarts: plannedWeekStarts
            )
            .filter { $0.localDate >= intervalStart && $0.localDate <= plannedIntervalEnd && filter.matches($0) }
        } else {
            plannedActivities = []
        }
        let plannedActivityCount = plannedActivities.count
        let plannedMinutes = plannedActivities.compactMap(\.plannedDurationMinutes).reduce(0, +)

        // Weekly buckets: computed AFTER `reflectionByLoggedActivityId`/
        // `dailyStatuses` above so each week's Form/Sleep can reuse those
        // same already-fetched, already-joined values — never a second,
        // independently-filtered read. `performed` (already narrowed by
        // `filter`) supplies both training minutes/count and the Form
        // join per week, so a Sport/Activity Type filter narrows weekly
        // Form exactly the way it narrows the interval-level Form above;
        // `dailyStatuses` is the SAME unfiltered read Sleep uses above,
        // so weekly Sleep is never narrowed by `filter` either.
        // `plannedActivities` is the SAME already-filtered/clamped set
        // `plannedActivityCount`/`plannedMinutes` above are computed
        // from — one aggregation path, never a second planned read.
        let weeklyBuckets = Self.weeklyBuckets(
            for: performed,
            reflectionByLoggedActivityId: reflectionByLoggedActivityId,
            dailyStatuses: dailyStatuses,
            plannedActivities: plannedActivities,
            from: intervalStart,
            through: intervalEnd,
            calendar: calendar
        )

        return StatisticsAthleteSummary(
            athleteId: athleteId,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            filter: filter,
            totalActualMinutes: totalActualMinutes,
            performedActivityCount: performed.count,
            weeklyBuckets: weeklyBuckets,
            form: form,
            sleep: sleep,
            plannedActivityCount: plannedActivityCount,
            plannedMinutes: plannedMinutes
        )
    }

    /// Week Drilldown round: the factual explanation of ONE canonical
    /// Statistics week — "what actually happened in this week," never
    /// why. Reuses the EXACT SAME `isPerformed(_:)`/`StatisticsFilter
    /// .matches`/`dateBounds(from:through:calendar:)`/planned-fetch
    /// helpers `athleteSummary` itself uses (never a second,
    /// independently-implemented filtering path), so a `StatisticsWeekDetail`
    /// produced here for the same athlete/week/interval/filter/today an
    /// `athleteSummary` call already covered always agrees with that
    /// call's own `StatisticsWeekBucket` for that week — see this
    /// method's own parity tests.
    ///
    /// EFFECTIVE INTERVAL: `[max(intervalStart, weekStart), min(intervalEnd,
    /// weekStart.adding(days: 6))]`. `weekStart`/`intervalStart`/
    /// `intervalEnd` are three independent facts — a calendar-month
    /// period's partial edge week can start before/end after the
    /// selected month, and this drilldown must show ONLY the portion
    /// that genuinely falls inside the caller's own selected interval,
    /// never the canonical week's full 7 days just because that's what
    /// `weekStart` alone would imply.
    ///
    /// FUTURE-DATE CLAMP: identical rule to `athleteSummary`'s own —
    /// Planned is further clamped to `min(effectiveEnd, today)` (a
    /// current, still-in-progress week must not show later-in-the-week
    /// planning as historical evidence); Actual is never clamped (a
    /// `LoggedActivity` cannot exist for a future date, so no clamp is
    /// needed there — same reasoning `athleteSummary` already
    /// documents).
    public func weekDetail(
        forAthlete athleteId: AthleteId,
        weekStart: LocalDate,
        within intervalStart: LocalDate,
        through intervalEnd: LocalDate,
        filter: StatisticsFilter = .none,
        today: LocalDate = TrainingPlanningCoordinationService.today(),
        calendar: Calendar = .current
    ) throws -> StatisticsWeekDetail {
        let weekEnd = weekStart.adding(days: 6)
        let effectiveStart = max(intervalStart, weekStart)
        let effectiveEnd = min(intervalEnd, weekEnd)

        // Defensive only: every real caller passes a `weekStart` that
        // came from `athleteSummary`'s own `weeklyBuckets`, which by
        // construction only ever includes weeks that overlap
        // `[intervalStart, intervalEnd]` — this branch should be
        // unreachable in normal use, but a genuinely non-overlapping
        // week must still report a factual empty result rather than
        // fetching against an inverted date range.
        guard effectiveStart <= effectiveEnd else {
            return StatisticsWeekDetail(
                athleteId: athleteId,
                weekStart: weekStart,
                intervalStart: effectiveStart,
                intervalEnd: effectiveStart,
                filter: filter,
                plannedActivityCount: 0,
                plannedMinutes: 0,
                performedActivityCount: 0,
                totalActualMinutes: 0,
                plannedActivities: [],
                performedActivities: [],
                form: StatisticsAggregate(mean: nil, sampleCount: 0),
                sleep: StatisticsAggregate(mean: nil, sampleCount: 0)
            )
        }

        let (startDate, endExclusive) = Self.dateBounds(from: effectiveStart, through: effectiveEnd, calendar: calendar)
        let loggedActivities = try trainingService
            .fetchLoggedActivities(forAthlete: athleteId, from: startDate, to: endExclusive)
            .filter { $0.startedAt < endExclusive }
        let performed = loggedActivities.filter { Self.isPerformed($0.status) && filter.matches($0) }
        let totalActualMinutes = performed.reduce(0) { $0 + $1.durationMinutes }

        // Ordering: chronological by `startedAt`, then stable
        // `LoggedActivity.id` as a deterministic tiebreaker — never
        // repository/dictionary iteration order.
        let performedActivities = performed
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { activity in
                StatisticsPerformedActivityRow(
                    loggedActivityId: activity.loggedActivityId,
                    startedAt: activity.startedAt,
                    sportId: activity.sportId.map(SportId.init(rawValue:)),
                    activityType: activity.activityType,
                    title: activity.title,
                    durationMinutes: activity.durationMinutes,
                    status: activity.status
                )
            }

        // Form: the SAME canonical join `athleteSummary` uses, scoped
        // to the performed activities actually in `effectiveInterval`.
        var reflectionByLoggedActivityId: [UUID: ActivityReflection] = [:]
        for reflection in try reflectionService.fetchActivityReflections(forAthlete: athleteId) {
            reflectionByLoggedActivityId[reflection.loggedActivityId] = reflection
        }
        let formValues = performed.compactMap { reflectionByLoggedActivityId[$0.id]?.bodyFeeling }
        let form = StatisticsAggregate.of(formValues)

        // Sleep: unfiltered by `filter`, exactly like `athleteSummary`'s
        // own weekly Sleep — the athlete's own context for the week,
        // never narrowed by a Sport/Activity Type choice.
        let dailyStatuses = try reflectionService.fetchDailyStatuses(forAthlete: athleteId, from: effectiveStart, to: effectiveEnd)
        let sleepValues = dailyStatuses.compactMap(\.sleepQuality)
        let sleep = StatisticsAggregate.of(sleepValues)

        // Planned: read-only via `PlanningService.fetchWeekPlan(forAthlete:weekStart:)`
        // (never creates a `WeekPlan`), scoped to just the ONE canonical
        // week this drilldown represents — no need to walk multiple
        // `weekStarts` the way `athleteSummary` does across a whole
        // period.
        let plannedEffectiveEnd = min(effectiveEnd, today)
        var plannedActivities: [StatisticsPlannedActivityRow] = []
        if effectiveStart <= plannedEffectiveEnd {
            let fetchedPlannedActivities = try Self.fetchPlannedActivities(
                planningService: planningService,
                forAthlete: athleteId,
                weekStarts: [weekStart]
            )
            .filter { $0.localDate >= effectiveStart && $0.localDate <= plannedEffectiveEnd && filter.matches($0) }

            // Ordering: chronological by `localDate`/`startLocalTime` —
            // a planned activity with no recorded start time sorts
            // AFTER timed ones, matching the same convention
            // `TodayActivityComposer.startLocalTimeSortKey` already
            // establishes — then stable `PlannedActivity.id` as the
            // final deterministic tiebreaker.
            plannedActivities = fetchedPlannedActivities
                .sorted { lhs, rhs in
                    if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
                    switch (lhs.startLocalTime, rhs.startLocalTime) {
                    case (nil, nil): return lhs.id.uuidString < rhs.id.uuidString
                    case (nil, _): return false
                    case (_, nil): return true
                    case let (left?, right?):
                        if left != right { return left < right }
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                }
                .map { activity in
                    StatisticsPlannedActivityRow(
                        plannedActivityId: activity.plannedActivityId,
                        localDate: activity.localDate,
                        startLocalTime: activity.startLocalTime,
                        sportId: activity.sportId.map(SportId.init(rawValue:)),
                        activityType: activity.activityType,
                        title: activity.title,
                        plannedDurationMinutes: activity.plannedDurationMinutes
                    )
                }
        }
        let plannedActivityCount = plannedActivities.count
        let plannedMinutes = plannedActivities.compactMap(\.plannedDurationMinutes).reduce(0, +)

        return StatisticsWeekDetail(
            athleteId: athleteId,
            weekStart: weekStart,
            intervalStart: effectiveStart,
            intervalEnd: effectiveEnd,
            filter: filter,
            plannedActivityCount: plannedActivityCount,
            plannedMinutes: plannedMinutes,
            performedActivityCount: performed.count,
            totalActualMinutes: totalActualMinutes,
            plannedActivities: plannedActivities,
            performedActivities: performedActivities,
            form: form,
            sleep: sleep
        )
    }

    /// Plan vs Actual round: every canonical `PlannedActivity` row that
    /// could possibly fall inside `weekStarts` — walks each week's own
    /// `WeekPlan` (fetched READ-ONLY via `PlanningService.fetchWeekPlan(forAthlete:weekStart:)`,
    /// which never creates one — a week nobody has ever opened in Weekly
    /// Plan simply contributes nothing here, exactly as it should) and
    /// collects its `PlannedActivity` rows. The caller is responsible for
    /// the final interval/future-date/filter narrowing (see
    /// `athleteSummary` above) — this helper only ever fetches, it never
    /// filters, matching every other raw-fetch step in this service.
    private static func fetchPlannedActivities(
        planningService: PlanningService,
        forAthlete athleteId: AthleteId,
        weekStarts: [LocalDate]
    ) throws -> [PlannedActivity] {
        var result: [PlannedActivity] = []
        for weekStart in weekStarts {
            guard let weekPlan = try planningService.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) else {
                continue
            }
            result.append(contentsOf: try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId))
        }
        return result
    }

    /// Sport filter catalog refinement round: the stable `SportId`s this
    /// athlete has EVER recorded performed training against — a Sport
    /// filter catalog-AVAILABILITY question, never a chart/summary
    /// computation, and deliberately independent of any currently
    /// selected Statistics period/filter: `fetchLoggedActivities(forAthlete:)`
    /// (unbounded, this athlete's entire recorded history) is filtered
    /// through the SAME canonical `isPerformed(_:)` rule `athleteSummary`
    /// itself uses, so "does this Sport have recorded Statistics
    /// history" always means the same thing here as it does everywhere
    /// else in Statistics — planned-only/missed/cancelled activities
    /// never contribute a Sport to this catalog. Deduplicates by stable
    /// `SportId`; a performed activity with no Sport (`sportId == nil`)
    /// contributes nothing here — "no Sport" is not itself a selectable
    /// Sport filter option (see the approved "No sport only" backlog
    /// boundary, still out of scope). One unbounded read, never
    /// per-Sport probing; nothing here is persisted.
    public func availableSportIds(forAthlete athleteId: AthleteId) throws -> Set<SportId> {
        let activities = try trainingService.fetchLoggedActivities(forAthlete: athleteId)
        let sportIds = activities
            .filter { Self.isPerformed($0.status) }
            .compactMap { $0.sportId.map(SportId.init(rawValue:)) }
        return Set(sportIds)
    }

    /// Activity Type filter catalog refinement round: the exact same
    /// availability shape as `availableSportIds(forAthlete:)` above,
    /// keyed by the canonical `ActivityType` enum instead of `SportId`
    /// — which Activity Types this athlete has EVER recorded performed
    /// training as, independent of any currently selected Statistics
    /// period/filter/Sport. `ActivityType` is never optional on
    /// `LoggedActivity` (unlike `sportId`), so unlike Sport there is no
    /// "no Activity Type" case to exclude — every performed activity
    /// contributes exactly one type. One unbounded read, never
    /// per-type probing; nothing here is persisted.
    public func availableActivityTypes(forAthlete athleteId: AthleteId) throws -> Set<ActivityType> {
        let activities = try trainingService.fetchLoggedActivities(forAthlete: athleteId)
        let activityTypes = activities
            .filter { Self.isPerformed($0.status) }
            .map(\.activityType)
        return Set(activityTypes)
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
    /// `Date` bounds this method's caller needs: `startInclusive` is
    /// midnight at the start of `intervalStart`; `endExclusive` is
    /// midnight at the start of the day AFTER `intervalEnd` — i.e. every
    /// instant of `intervalEnd` itself, down to sub-second precision, is
    /// `< endExclusive`. Computed as a genuine calendar-day boundary
    /// (`intervalEnd.adding(days: 1)`, then converted to `Date` the same
    /// way `intervalStart` is) rather than "next day minus one second/
    /// millisecond" — `Date` has sub-second precision, so any fixed
    /// subtracted offset would still incorrectly exclude an activity in
    /// the final fraction of a second of `intervalEnd`. Deliberately uses
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
    ) -> (startInclusive: Date, endExclusive: Date) {
        let startComponents = DateComponents(year: intervalStart.year, month: intervalStart.month, day: intervalStart.day)
        let startInclusive = calendar.date(from: startComponents) ?? .distantPast
        let dayAfterEnd = intervalEnd.adding(days: 1)
        let endComponents = DateComponents(year: dayAfterEnd.year, month: dayAfterEnd.month, day: dayAfterEnd.day)
        let endExclusive = calendar.date(from: endComponents) ?? .distantFuture
        return (startInclusive, endExclusive)
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

    /// `activities` must already be the FILTERED performed set (the same
    /// `performed` this method's one caller computes) — `filter` is not
    /// re-applied here, so training minutes/count AND the Form join
    /// below both narrow together, exactly matching the interval-level
    /// behavior above. `reflectionByLoggedActivityId` and
    /// `dailyStatuses` are the SAME already-fetched values the caller
    /// used for the interval-level Form/Sleep aggregates — passed in
    /// rather than re-fetched, so weekly and interval-level Form/Sleep
    /// can never disagree about what data they saw.
    /// Plan vs Actual round: `plannedActivities` must already be the
    /// SAME fully interval/future-clamped/filter-narrowed set
    /// `athleteSummary`'s own `plannedActivityCount`/`plannedMinutes`
    /// are computed from — never re-filtered here, so weekly and
    /// interval-level planned totals can never disagree about which
    /// activities counted (the same "passed in, not re-derived"
    /// contract `reflectionByLoggedActivityId`/`dailyStatuses` already
    /// establish above).
    private static func weeklyBuckets(
        for activities: [LoggedActivity],
        reflectionByLoggedActivityId: [UUID: ActivityReflection],
        dailyStatuses: [DailyStatus],
        plannedActivities: [PlannedActivity],
        from intervalStart: LocalDate,
        through intervalEnd: LocalDate,
        calendar: Calendar
    ) -> [StatisticsWeekBucket] {
        var totals: [LocalDate: (minutes: Int, count: Int)] = [:]
        var formValuesByWeek: [LocalDate: [Int]] = [:]
        // Training Breakdown round: accumulated from the SAME per-activity
        // loop that already computes `totals`/`formValuesByWeek` above —
        // never a second, independently-filtered pass over `activities` —
        // so a Sport/Activity Type breakdown can never disagree with the
        // week's own `totalActualMinutes` about which activities counted.
        var sportTotalsByWeek: [LocalDate: [SportId?: Int]] = [:]
        var activityTypeTotalsByWeek: [LocalDate: [ActivityType: Int]] = [:]
        for activity in activities {
            let localDate = TrainingPlanningCoordinationService.today(referenceDate: activity.startedAt, calendar: calendar)
            let weekStart = localDate.startOfWeek
            var entry = totals[weekStart] ?? (0, 0)
            entry.minutes += activity.durationMinutes
            entry.count += 1
            totals[weekStart] = entry
            if let bodyFeeling = reflectionByLoggedActivityId[activity.id]?.bodyFeeling {
                formValuesByWeek[weekStart, default: []].append(bodyFeeling)
            }
            let sportId = activity.sportId.map(SportId.init(rawValue:))
            sportTotalsByWeek[weekStart, default: [:]][sportId, default: 0] += activity.durationMinutes
            activityTypeTotalsByWeek[weekStart, default: [:]][activity.activityType, default: 0] += activity.durationMinutes
        }

        // Sleep: bucketed by the DailyStatus's OWN local date, entirely
        // independent of which/whether any LoggedActivity fell in that
        // week — this is what keeps weekly Sleep un-narrowed by `filter`
        // (this method never receives `filter` at all, only the already-
        // filtered `activities`).
        var sleepValuesByWeek: [LocalDate: [Int]] = [:]
        for status in dailyStatuses {
            guard let sleepQuality = status.sleepQuality else { continue }
            sleepValuesByWeek[status.localDate.startOfWeek, default: []].append(sleepQuality)
        }

        // Plan vs Actual round: bucketed by the SAME canonical
        // `LocalDate.startOfWeek` boundary every other series above
        // uses — `plannedActivities` is already fully narrowed by the
        // caller (interval, future-date clamp, `filter`), so this is a
        // pure bucketing pass, never a second filtering decision.
        var plannedTotalsByWeek: [LocalDate: (minutes: Int, count: Int)] = [:]
        for activity in plannedActivities {
            let weekStart = activity.localDate.startOfWeek
            var entry = plannedTotalsByWeek[weekStart] ?? (0, 0)
            entry.minutes += activity.plannedDurationMinutes ?? 0
            entry.count += 1
            plannedTotalsByWeek[weekStart] = entry
        }

        return weekStarts(from: intervalStart, through: intervalEnd).map { weekStart in
            let entry = totals[weekStart] ?? (0, 0)
            let plannedEntry = plannedTotalsByWeek[weekStart] ?? (0, 0)
            return StatisticsWeekBucket(
                weekStart: weekStart,
                totalActualMinutes: entry.minutes,
                performedActivityCount: entry.count,
                form: StatisticsAggregate.of(formValuesByWeek[weekStart] ?? []),
                sleep: StatisticsAggregate.of(sleepValuesByWeek[weekStart] ?? []),
                trainingBySport: sortedSportTotals(sportTotalsByWeek[weekStart] ?? [:]),
                trainingByActivityType: sortedActivityTypeTotals(activityTypeTotalsByWeek[weekStart] ?? [:]),
                plannedActivityCount: plannedEntry.count,
                plannedMinutes: plannedEntry.minutes
            )
        }
    }

    /// Deterministic, stable-ID-driven order — never dictionary-iteration
    /// order (`[SportId?: Int]` iteration order is not guaranteed stable
    /// across runs). Sorted by the Sport's own UUID string ascending,
    /// with the "no Sport" segment (`sportId == nil`) always sorted last
    /// — a fixed, reproducible order for the SAME underlying data on
    /// every call, regardless of which order activities were originally
    /// encountered in.
    private static func sortedSportTotals(_ totals: [SportId?: Int]) -> [SportTrainingMinutes] {
        totals
            .map { SportTrainingMinutes(sportId: $0.key, minutes: $0.value) }
            .sorted { lhs, rhs in
                switch (lhs.sportId, rhs.sportId) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (left?, right?): return left.rawValue.uuidString < right.rawValue.uuidString
                }
            }
    }

    /// Deterministic order matching `ActivityType.allCases`'s own fixed
    /// declaration order — a stable, compile-time-fixed ordering, never
    /// dictionary-iteration order.
    private static func sortedActivityTypeTotals(_ totals: [ActivityType: Int]) -> [ActivityTypeTrainingMinutes] {
        ActivityType.allCases.compactMap { activityType in
            guard let minutes = totals[activityType] else { return nil }
            return ActivityTypeTrainingMinutes(activityType: activityType, minutes: minutes)
        }
    }
}
