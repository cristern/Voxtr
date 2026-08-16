import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// S3.2: "today's planned activities together with completion state"
/// genuinely needs both `PlannedActivity` (Planning) and
/// `LoggedActivity` (Training) — this is one of the few files allowed
/// to import both domain packages, the same rule
/// `FamilyOnboardingCoordinator`/`FamilyRestorationService` already
/// established for Parent+Athlete. It does not touch either domain's
/// SwiftData schema directly — only their existing repositories.
///
/// Completion is DERIVED, never stored: a `PlannedActivity` counts as
/// completed purely because a `LoggedActivity` already references it by
/// typed ID. `PlannedActivity`'s own schema is untouched — nothing new
/// is persisted to represent "completed."
public struct PlannedActivityCompletion {
    public let plannedActivity: PlannedActivity
    public let isCompleted: Bool
    /// Activity Completion & Review Flow package: the actual
    /// `LoggedActivity` this completion was derived from, when one
    /// exists — the exact relationship lookup below (`fetchLoggedActivities
    /// (forPlannedActivity:)`) already fetches this; it was previously
    /// discarded, keeping only the boolean. Carrying it forward lets a
    /// caller like Weekly Review show actual duration/RPE inline next to
    /// the plan, without a second query and without ever inferring the
    /// link from title/date. `nil` when `isCompleted` is `false`, or for
    /// any existing caller that never populates it.
    public let loggedActivity: LoggedActivity?

    public init(plannedActivity: PlannedActivity, isCompleted: Bool, loggedActivity: LoggedActivity? = nil) {
        self.plannedActivity = plannedActivity
        self.isCompleted = isCompleted
        self.loggedActivity = loggedActivity
    }

    /// Review follow-up (cancellation sanity check): `isCompleted`
    /// above means "an outcome has been resolved" — ANY `LoggedActivity`
    /// link, regardless of its `status` (`.completed`, `.partiallyCompleted`,
    /// `.missed`, OR `.cancelled` all set it `true`). That is exactly
    /// right for gating "is there still something to log" (its original
    /// purpose), but WRONG for any statistic that claims to count
    /// "completed training" or "training volume" — those must use this
    /// property instead, which applies the SAME canonical rule
    /// `TrainingValidator.requiresActualDuration(for:)`/`requiresForm(for:)`
    /// already establish for "this genuinely happened":
    /// `.completed`/`.partiallyCompleted` only. A cancelled or missed
    /// planned activity never counts here.
    public var isGenuinelyCompleted: Bool {
        switch loggedActivity?.status {
        case .completed, .partiallyCompleted:
            return true
        case .missed, .cancelled, .scheduled, .none:
            return false
        }
    }
}

@MainActor
public final class TrainingPlanningCoordinationService {
    private let planningRepository: PlanningRepository
    private let trainingRepository: TrainingRepository

    public init(planningRepository: PlanningRepository, trainingRepository: TrainingRepository) {
        self.planningRepository = planningRepository
        self.trainingRepository = trainingRepository
    }

    /// Today's date, per the device's own calendar — not a business
    /// rule, the same kind of device-provided default
    /// `WeeklyPlanningViewModel.currentWeekStart` already uses.
    public static func today(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Start of the calendar week containing `referenceDate` — same
    /// computation `WeeklyPlanningViewModel.currentWeekStart` already
    /// uses, duplicated here rather than shared across the module
    /// boundary between `VoxtrAppShell` types, to keep this type
    /// self-contained.
    /// Fix: previously computed via
    /// `calendar.dateInterval(of: .weekOfYear, for: referenceDate)`,
    /// which depends on the calendar's locale-configured `firstWeekday`
    /// — the same device running this app in a Sunday-first-week
    /// locale would put different dates in "this week" than one in a
    /// Monday-first locale. Vǫxtr's own planning/training weeks are
    /// Monday → Sunday, deterministically, regardless of device locale
    /// — now computed via `LocalDate.startOfWeek`, the one canonical
    /// implementation of that rule (see its own doc comment). The
    /// `Date` → `LocalDate` conversion below still legitimately uses
    /// the passed `calendar` (i.e. its time zone) — "which calendar day
    /// does this instant fall on" is a genuine device/timezone
    /// question; only the week-boundary rule itself needed to stop
    /// depending on locale.
    public static func weekStart(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        let localDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        return localDate.startOfWeek
    }

    /// Returns today's `PlannedActivity` records for the athlete's
    /// current week, each paired with whether a `LoggedActivity`
    /// already references it. Empty (not an error) if no `WeekPlan`
    /// exists yet for this athlete/week — same "nothing to show yet"
    /// meaning `.noExistingFamily` carries elsewhere in this codebase.
    /// Ordering is inherited unchanged from
    /// `PlanningRepository.fetchPlannedActivities`'s own deterministic
    /// order (`localDate` then `id`); filtering to today doesn't
    /// disturb it.
    public func todaysPlannedActivitiesWithCompletion(
        forAthlete athleteId: AthleteId,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) throws -> [PlannedActivityCompletion] {
        let today = Self.today(referenceDate: referenceDate, calendar: calendar)
        let weekStart = Self.weekStart(referenceDate: referenceDate, calendar: calendar)

        guard let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) else {
            return []
        }
        let todaysActivities = try planningRepository
            .fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
            .filter { $0.localDate == today }

        return try plannedActivitiesWithCompletion(todaysActivities)
    }

    /// Sprint 1 completion package, Part 4 (Tomorrow on Family Home):
    /// the same derivation as `todaysPlannedActivitiesWithCompletion`,
    /// generalized to an arbitrary `LocalDate` rather than hardcoded to
    /// "today" — computes the WeekPlan that actually contains `date`
    /// (which may differ from today's own week, e.g. tomorrow being the
    /// first day of next week), not assumed to be the current week.
    /// Empty (not an error) if no WeekPlan exists for that week, same
    /// "nothing to show yet" meaning as the today-specific method.
    public func plannedActivitiesWithCompletion(
        forAthlete athleteId: AthleteId,
        on date: LocalDate,
        calendar: Calendar = .current
    ) throws -> [PlannedActivityCompletion] {
        let weekStart = Self.weekStart(containing: date, calendar: calendar)
        guard let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) else {
            return []
        }
        let activities = try planningRepository
            .fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
            .filter { $0.localDate == date }
        return try plannedActivitiesWithCompletion(activities)
    }

    /// Sprint 1 completion package, Part 5 (Family Schedule): activities
    /// across a date range (inclusive), which may span more than one
    /// WeekPlan — fetches each distinct week's WeekPlan that overlaps
    /// the range (skipping any that don't exist, same "nothing planned
    /// yet" meaning as elsewhere) and filters to the range. Result
    /// order is NOT guaranteed sorted by date — callers that need a
    /// specific ordering (Family Schedule groups by date) sort the
    /// result themselves, the same separation of concerns
    /// `plannedActivitiesWithCompletion(_:)` already establishes
    /// (fetch/derive here, present elsewhere).
    public func plannedActivitiesWithCompletion(
        forAthlete athleteId: AthleteId,
        from startDate: LocalDate,
        through endDate: LocalDate,
        calendar: Calendar = .current
    ) throws -> [PlannedActivityCompletion] {
        guard let startDay = calendar.date(from: DateComponents(year: startDate.year, month: startDate.month, day: startDate.day)),
              let endDay = calendar.date(from: DateComponents(year: endDate.year, month: endDate.month, day: endDate.day)),
              startDay <= endDay else {
            return []
        }

        var weekStarts: Set<LocalDate> = []
        var cursor = startDay
        while cursor <= endDay {
            let cursorComponents = calendar.dateComponents([.year, .month, .day], from: cursor)
            let cursorDate = LocalDate(
                year: cursorComponents.year ?? 1970,
                month: cursorComponents.month ?? 1,
                day: cursorComponents.day ?? 1
            )
            weekStarts.insert(Self.weekStart(containing: cursorDate, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var allActivities: [PlannedActivity] = []
        for weekStart in weekStarts {
            guard let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) else {
                continue
            }
            let activities = try planningRepository
                .fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
                .filter { $0.localDate >= startDate && $0.localDate <= endDate }
            allActivities.append(contentsOf: activities)
        }

        return try plannedActivitiesWithCompletion(allActivities)
    }

    /// Start of the calendar week containing `date` (a `LocalDate`, not
    /// a reference `Date`/instant) — generalizes `weekStart(referenceDate:calendar:)`
    /// above, which only ever computes the week containing "now."
    /// Needed because Tomorrow/Family Schedule must resolve the WeekPlan
    /// for an arbitrary future date, not just today's own week.
    static func weekStart(containing date: LocalDate, calendar: Calendar = .current) -> LocalDate {
        let asDate = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? .now
        return weekStart(referenceDate: asDate, calendar: calendar)
    }

    /// Sprint 5.1: the completion-derivation primitive, extracted so
    /// `WeeklyReviewCoordinationService` can reuse it for a whole week's
    /// planned activities instead of duplicating this check — the
    /// derivation itself (a `PlannedActivity` counts as completed
    /// purely because a `LoggedActivity` already references it) doesn't
    /// change; only its scope (today vs. a whole week) varies by
    /// caller. `todaysPlannedActivitiesWithCompletion` above now
    /// delegates here too, so there is exactly one copy of this check
    /// in the codebase. Order is preserved from the input array — pass
    /// already-ordered activities in, get them back in the same order.
    public func plannedActivitiesWithCompletion(_ plannedActivities: [PlannedActivity]) throws -> [PlannedActivityCompletion] {
        try plannedActivities.map { activity in
            let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            return PlannedActivityCompletion(plannedActivity: activity, isCompleted: !links.isEmpty, loggedActivity: links.first)
        }
    }
}

/// Sprint 13 (architecture correction): the narrowest protocol around
/// `TrainingPlanningCoordinationService`'s one method
/// `HomeDashboardViewModel` needs — same pattern as
/// `WeeklyReviewProviding`/`WeeklyCoachingContextProviding`/
/// `CoachingPresentationProviding`. Introduced only now, because only
/// now does something (`HomeDashboardViewModel`'s tests, specifically
/// deterministic call-count and independent-failure scenarios) actually
/// need it — `DailyTrainingViewModel` still takes the concrete type
/// directly, unchanged, since it has no such need.
/// `TrainingPlanningCoordinationService` is the only production
/// conformer.
@MainActor
public protocol TodaysTrainingProviding {
    func todaysPlannedActivitiesWithCompletion(forAthlete athleteId: AthleteId) throws -> [PlannedActivityCompletion]
}

extension TrainingPlanningCoordinationService: TodaysTrainingProviding {
    /// FIX: default arguments (`referenceDate`/`calendar` on the
    /// existing `todaysPlannedActivitiesWithCompletion(forAthlete:
    /// referenceDate:calendar:)` above) do not satisfy Swift protocol
    /// conformance — a protocol requirement with a single parameter is
    /// a distinct method signature from one with three parameters,
    /// defaults or not. This is a pure forwarding adapter, not a
    /// second implementation: it calls the existing method with its
    /// existing defaults (`.now`/`.current`) and changes no existing
    /// public API. The existing three-parameter method is untouched —
    /// callers that need to pass a specific `referenceDate`/`calendar`
    /// (none currently do, but the capability remains) still can.
    public func todaysPlannedActivitiesWithCompletion(forAthlete athleteId: AthleteId) throws -> [PlannedActivityCompletion] {
        try todaysPlannedActivitiesWithCompletion(forAthlete: athleteId, referenceDate: .now, calendar: .current)
    }
}
