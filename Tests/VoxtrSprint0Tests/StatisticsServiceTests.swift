import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("StatisticsService (Statistics V1 foundation)", .serialized)
struct StatisticsServiceTests {

    /// Time-dependent-test determinism: `StatisticsService.athleteSummary`
    /// defaults to `Calendar.current` (the device's own timezone — the
    /// same convention every other Date<->LocalDate boundary in this
    /// codebase already uses, see that method's own doc comment), which
    /// would make an assertion on which `LocalDate`/week a fixture's
    /// `startedAt` falls into depend on whatever timezone happens to run
    /// this test suite. Every call below passes this fixed UTC calendar
    /// explicitly instead — paired with `Self.date(_:_:_:)`'s own
    /// UTC-anchored fixture construction, so results never depend on
    /// `Date.now`, the device's current timezone, or CI run time.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// Item 1 (Completed/PartiallyCompleted inclusion): both genuinely-
    /// performed outcomes contribute their real durations to the total —
    /// neither is a special case of the other.
    @Test("Completed and PartiallyCompleted activities both count toward actual volume")
    @MainActor
    func completedAndPartiallyCompletedBothCountTowardVolume() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .teamTraining, title: "Match",
            startedAt: Self.date(2026, 3, 10), durationMinutes: 20, status: .partiallyCompleted
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 50)
        #expect(summary.performedActivityCount == 2)
    }

    /// Item 2: the schema's own `1`-minute Missed/Cancelled placeholder
    /// duration must never leak into the real total — a Missed or
    /// Cancelled activity contributes exactly zero minutes and zero
    /// count, regardless of what its own `durationMinutes` field holds.
    @Test("Missed/Cancelled placeholder durations never contribute to actual volume")
    @MainActor
    func missedAndCancelledNeverContributeVolume() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Missed session",
            startedAt: Self.date(2026, 3, 12), durationMinutes: 1, status: .missed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Cancelled session",
            startedAt: Self.date(2026, 3, 20), durationMinutes: 1, status: .cancelled
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 30)
        #expect(summary.performedActivityCount == 1)
    }

    /// Item 3: a manual/unplanned `LoggedActivity` (no `plannedActivityId`)
    /// that genuinely represents performed training is included exactly
    /// like a planned-and-logged one — `TrainingService.fetchLoggedActivities(forAthlete:from:to:)`
    /// never filters on `plannedActivityId` at all, so no special-casing
    /// is needed (or added) here.
    @Test("A manual/unplanned logged activity counts toward actual volume the same as a planned one")
    @MainActor
    func manualUnplannedActivityCountsTowardVolume() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: nil, activityType: .individualTraining, title: "Unplanned swim",
            startedAt: Self.date(2026, 3, 7), durationMinutes: 45, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 45)
        #expect(summary.performedActivityCount == 1)
    }

    /// Item 4: filtering by Sport narrows the total to exactly the
    /// activities recorded against that Sport.
    @Test("Sport filter narrows totals to activities recorded against that exact Sport")
    @MainActor
    func sportFilterNarrowsToExactSport() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let football = SportId()
        let swimming = SportId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 6), durationMinutes: 40, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(sportId: football), calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 30)
        #expect(summary.performedActivityCount == 1)
    }

    /// Item 5: filtering by Activity Type narrows the total to exactly
    /// the activities recorded with that exact type.
    @Test("Activity Type filter narrows totals to activities of that exact type")
    @MainActor
    func activityTypeFilterNarrowsToExactType() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .strength, title: "Strength session",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 25, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .recovery, title: "Recovery session",
            startedAt: Self.date(2026, 3, 6), durationMinutes: 15, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(activityType: .strength), calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 25)
        #expect(summary.performedActivityCount == 1)
    }

    /// Item 6: Sport and Activity Type filters apply together (AND, not
    /// OR) — only an activity matching BOTH counts.
    @Test("Combined Sport + Activity Type filter requires both to match")
    @MainActor
    func combinedSportAndActivityTypeFilterRequiresBoth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let football = SportId()

        // Matches both.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        // Right Sport, wrong Activity Type.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 6), durationMinutes: 40, status: .completed
        )
        // Right Activity Type, wrong Sport.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: SportId(), activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 7), durationMinutes: 50, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(sportId: football, activityType: .teamTraining), calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 30)
        #expect(summary.performedActivityCount == 1)
    }

    /// Item 7: an activity recorded with NO Sport (`sportId == nil`) is
    /// never silently matched by a Sport filter — "nil Sport means no
    /// sport, not Other" — while a request with NO Sport filter applied
    /// still includes it normally.
    @Test("An activity with no Sport is never matched by a Sport filter, but is included when no Sport filter is applied")
    @MainActor
    func nilSportNeverMatchesSportFilterButCountsUnfiltered() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let football = SportId()

        // No Sport at all — title carries identity instead (ActivityIdentity's own rule).
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: "General fitness",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 20, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 6), durationMinutes: 30, status: .completed
        )

        let unfiltered = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )
        #expect(unfiltered.totalActualMinutes == 50)
        #expect(unfiltered.performedActivityCount == 2)

        let filteredByFootball = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(sportId: football), calendar: Self.utcCalendar
        )
        #expect(filteredByFootball.totalActualMinutes == 30)
        #expect(filteredByFootball.performedActivityCount == 1)
    }

    /// Item 8: every Monday-start week whose week overlaps the requested
    /// interval is represented — including one with genuinely zero
    /// performed training, which is a real fact (never omitted the way
    /// a missing Form/Sleep value is). Interval spans three weeks;
    /// activity exists only in the first and third.
    @Test("Weekly buckets cover every week in the interval, including one with zero performed activity")
    @MainActor
    func weeklyBucketsCoverEveryWeekIncludingEmptyOnes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // 2026-03-02 is a Monday; this spans exactly 3 canonical weeks:
        // Mar 2-8, Mar 9-15, Mar 16-22.
        let intervalStart = LocalDate(year: 2026, month: 3, day: 2)
        let intervalEnd = LocalDate(year: 2026, month: 3, day: 22)

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Week 1 run",
            startedAt: Self.date(2026, 3, 2), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Week 3 run",
            startedAt: Self.date(2026, 3, 22), durationMinutes: 40, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: intervalStart, through: intervalEnd, calendar: Self.utcCalendar
        )

        #expect(summary.weeklyBuckets.count == 3)
        let week1 = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        let week2 = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 9) })
        let week3 = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 16) })
        #expect(week1.totalActualMinutes == 30)
        #expect(week1.performedActivityCount == 1)
        #expect(week2.totalActualMinutes == 0)
        #expect(week2.performedActivityCount == 0)
        #expect(week3.totalActualMinutes == 40)
        #expect(week3.performedActivityCount == 1)
    }

    /// Item 9: Form's mean is the arithmetic mean of only the recorded
    /// `bodyFeeling` values — a performed activity with no reflection at
    /// all is excluded from both the mean and the sample count, never
    /// treated as if it contributed a zero.
    @Test("Form mean excludes activities with no recorded reflection and reports the real sample count")
    @MainActor
    func formMeanExcludesMissingValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        let logged1 = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run 1",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        let logged2 = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run 2",
            startedAt: Self.date(2026, 3, 10), durationMinutes: 30, status: .completed
        )
        // Third performed activity deliberately gets no reflection at all.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run 3",
            startedAt: Self.date(2026, 3, 15), durationMinutes: 30, status: .completed
        )

        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged1.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 3
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged2.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 5
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.form.sampleCount == 2)
        #expect(summary.form.mean == 4.0)
    }

    /// Item 10: Sleep's mean is the arithmetic mean of only the days
    /// with a recorded `sleepQuality` — a day within the interval with
    /// no `DailyStatus` row at all is excluded from both the mean and
    /// the sample count.
    @Test("Sleep mean excludes days with no recorded DailyStatus and reports the real sample count")
    @MainActor
    func sleepMeanExcludesMissingValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 5),
            sleepQuality: 3, today: LocalDate(year: 2026, month: 3, day: 31)
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 6),
            sleepQuality: 5, today: LocalDate(year: 2026, month: 3, day: 31)
        )
        // 2026-03-07 deliberately has no DailyStatus row at all.

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.sleep.sampleCount == 2)
        #expect(summary.sleep.mean == 4.0)
    }

    /// Item 11: one athlete's summary never includes another athlete's
    /// training, Form, or Sleep — no sibling leakage, matching the
    /// approved "no sibling ranking/comparison" contract's own
    /// prerequisite (isolation must hold before ranking can even be
    /// discussed).
    @Test("An athlete's summary never includes a sibling athlete's activities, Form, or Sleep")
    @MainActor
    func athleteSummaryNeverLeaksSiblingData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let siblingId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        let logged = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "My run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 4
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 5),
            sleepQuality: 4, today: LocalDate(year: 2026, month: 3, day: 31)
        )

        let siblingLogged = try trainingService.logActivity(
            athleteId: siblingId, activityType: .teamTraining, title: "Sibling match",
            startedAt: Self.date(2026, 3, 6), durationMinutes: 90, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: siblingId, loggedActivityId: siblingLogged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 1
        )
        _ = try reflectionService.recordSleep(
            athleteId: siblingId, localDate: LocalDate(year: 2026, month: 3, day: 6),
            sleepQuality: 1, today: LocalDate(year: 2026, month: 3, day: 31)
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 30)
        #expect(summary.performedActivityCount == 1)
        #expect(summary.form.sampleCount == 1)
        #expect(summary.form.mean == 4.0)
        #expect(summary.sleep.sampleCount == 1)
        #expect(summary.sleep.mean == 4.0)
    }

    /// Deterministic `Date` construction, anchored to `Self.utcCalendar`
    /// above — paired with passing that SAME calendar explicitly into
    /// every `athleteSummary(...)` call in this file, so which
    /// `LocalDate`/week a fixture's `startedAt` resolves to never
    /// depends on the device's current timezone or CI run time.
    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    /// Exact-instant `Date` construction (down to sub-second precision),
    /// for the interval-boundary regression test below — `Self.date`
    /// above always pins to noon and cannot express "the last half-second
    /// of a day."
    private static func exactDate(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int, second: Int, nanosecond: Int = 0) -> Date {
        Self.utcCalendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanosecond
        )) ?? .now
    }

    /// Review follow-up (PR #23), item 1: `[intervalStart, intervalEnd]`
    /// is documented as fully inclusive, down to `Date`'s own sub-second
    /// precision — not "inclusive to the second." An activity in the
    /// final half-second of `intervalEnd` must still be included, and an
    /// activity exactly at the start of the day AFTER `intervalEnd` (a
    /// distinct calendar day entirely) must be excluded.
    @Test("Interval end is inclusive to sub-second precision; the instant after it is excluded")
    @MainActor
    func intervalEndIsInclusiveToSubSecondPrecision() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let intervalStart = LocalDate(year: 2026, month: 3, day: 1)
        let intervalEnd = LocalDate(year: 2026, month: 3, day: 31)

        // The last half-second of intervalEnd itself — must be included.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Last instant of the interval",
            startedAt: Self.exactDate(2026, 3, 31, hour: 23, minute: 59, second: 59, nanosecond: 500_000_000),
            durationMinutes: 10, status: .completed
        )
        // Midnight at the start of the NEXT day — a distinct calendar
        // day outside the interval — must be excluded.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Start of the next day",
            startedAt: Self.exactDate(2026, 4, 1, hour: 0, minute: 0, second: 0),
            durationMinutes: 20, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: intervalStart, through: intervalEnd, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 10)
        #expect(summary.performedActivityCount == 1)
    }

    /// Review follow-up (PR #23), item 2: Statistics must use the
    /// canonical ACTUAL logged duration, never the PlannedActivity's own
    /// planned duration — proven here by planning one duration and
    /// logging a genuinely different one against the same
    /// PlannedActivity. Uses the same `getOrCreateWeekPlan`/
    /// `addPlannedActivity`/`logActivity(plannedActivityId:)` sequence
    /// `ActivityCompletionReviewFlowTests` already establishes for
    /// planned-and-logged fixtures.
    @Test("Statistics uses the actual logged duration, never the PlannedActivity's planned duration")
    @MainActor
    func statisticsUsesActualDurationNotPlannedDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)

        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let planned = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Run", localDate: LocalDate(year: 2026, month: 3, day: 5),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 60
        )

        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: planned.plannedActivityId,
            activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 35, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 35)
        #expect(summary.performedActivityCount == 1)
    }

    /// Review follow-up (PR #23), item 3: a valid interval with no data
    /// at all for this athlete must report every measure as a genuine
    /// "nothing happened" fact — zero volume/count, `nil`/zero-sample
    /// Form and Sleep, and weekly buckets that are present but
    /// themselves all zero (never fabricated, never omitted).
    @Test("A valid interval with no data reports zero volume, nil Form/Sleep, and all-zero weekly buckets")
    @MainActor
    func emptyIntervalReportsFactualZeroesNotFabricatedValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // 2026-03-02 is a Monday; this spans exactly 2 canonical weeks.
        let intervalStart = LocalDate(year: 2026, month: 3, day: 2)
        let intervalEnd = LocalDate(year: 2026, month: 3, day: 15)

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: intervalStart, through: intervalEnd, calendar: Self.utcCalendar
        )

        #expect(summary.totalActualMinutes == 0)
        #expect(summary.performedActivityCount == 0)
        #expect(summary.form.mean == nil)
        #expect(summary.form.sampleCount == 0)
        #expect(summary.sleep.mean == nil)
        #expect(summary.sleep.sampleCount == 0)
        #expect(summary.weeklyBuckets.count == 2)
        for bucket in summary.weeklyBuckets {
            #expect(bucket.totalActualMinutes == 0)
            #expect(bucket.performedActivityCount == 0)
        }
    }

    /// Review follow-up (PR #23), item 4: an `ActivityReflection` can
    /// legally exist with some other field recorded (e.g. `energy`) and
    /// `bodyFeeling == nil` — this must contribute neither a fabricated
    /// zero nor a counted sample to the Form aggregate, exactly like a
    /// performed activity with no reflection at all.
    @Test("A Reflection recorded without bodyFeeling contributes no Form sample")
    @MainActor
    func reflectionWithoutBodyFeelingContributesNoFormSample() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)

        let logged = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        // Legally valid reflection: energy recorded, bodyFeeling omitted.
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, energy: 4
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        #expect(summary.form.sampleCount == 0)
        #expect(summary.form.mean == nil)
    }

    // MARK: - Statistics V1 UI round: weekly Form/Sleep aggregate extension

    /// Required foundation test 1: multiple performed activities in the
    /// SAME week contribute their `bodyFeeling` values to that week's
    /// Form aggregate; a third performed activity in the same week with
    /// no reflection at all is excluded from both the mean and the
    /// sample count, never treated as a zero.
    @Test("Weekly Form aggregates multiple activities in the same week and excludes missing reflections")
    @MainActor
    func weeklyFormAggregatesSameWeekAndExcludesMissing() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // 2026-03-02 is a Monday — all three fixtures below fall in the
        // SAME canonical week (Mar 2-8).
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)

        let logged1 = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run 1",
            startedAt: Self.date(2026, 3, 2), durationMinutes: 30, status: .completed
        )
        let logged2 = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run 2",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 30, status: .completed
        )
        // Third performed activity in the SAME week deliberately gets no reflection.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run 3",
            startedAt: Self.date(2026, 3, 6), durationMinutes: 30, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged1.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 3
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged2.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 5
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        #expect(week.performedActivityCount == 3)
        #expect(week.form.sampleCount == 2)
        #expect(week.form.mean == 4.0)
    }

    /// Required foundation test 2: a Sport/Activity Type filter narrows
    /// weekly Form to only the reflections attached to performed
    /// activities that themselves match the filter — exactly mirroring
    /// how the same filter already narrows the interval-level Form.
    @Test("Sport filter narrows weekly Form to reflections on matching performed activities")
    @MainActor
    func weeklyFormFilterNarrowsToMatchingActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)
        let football = SportId()

        let matching = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        let nonMatching = try trainingService.logActivity(
            athleteId: athleteId, sportId: SportId(), activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 30, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: matching.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 5
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: nonMatching.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 1
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(sportId: football), calendar: Self.utcCalendar
        )

        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        #expect(week.performedActivityCount == 1)
        #expect(week.form.sampleCount == 1)
        #expect(week.form.mean == 5.0)
    }

    /// Required foundation test 3: `DailyStatus.sleepQuality` values
    /// bucket into their OWN canonical week (by `localDate.startOfWeek`,
    /// entirely independent of training); a day with no recorded
    /// `DailyStatus` at all is excluded from that week's sample count.
    @Test("Weekly Sleep buckets DailyStatus values into the correct canonical week and excludes missing days")
    @MainActor
    func weeklySleepBucketsIntoCorrectWeekAndExcludesMissing() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // Spans two canonical weeks: Mar 2-8 and Mar 9-15.
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 15)

        // Week 1 (Mar 2-8): two recorded nights, one missing (Mar 4 — no row at all).
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 2),
            sleepQuality: 3, today: LocalDate(year: 2026, month: 3, day: 15)
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 3),
            sleepQuality: 5, today: LocalDate(year: 2026, month: 3, day: 15)
        )
        // Week 2 (Mar 9-15): one recorded night.
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 10),
            sleepQuality: 2, today: LocalDate(year: 2026, month: 3, day: 15)
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        let week1 = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        let week2 = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 9) })
        #expect(week1.sleep.sampleCount == 2)
        #expect(week1.sleep.mean == 4.0)
        #expect(week2.sleep.sampleCount == 1)
        #expect(week2.sleep.mean == 2.0)
    }

    /// Required foundation test 4: weekly Sleep is period context, not
    /// Sport-owned — applying a Sport/Activity Type filter that
    /// excludes every training activity in a week must NOT change that
    /// week's Sleep aggregate at all.
    @Test("A Sport/Activity Type filter that excludes all training in a week leaves weekly Sleep unchanged")
    @MainActor
    func weeklySleepUnaffectedBySportOrActivityTypeFilter() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)
        let swimming = SportId()
        let football = SportId()

        // Only swimming activity exists — a football filter matches nothing.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 40, status: .completed
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 3),
            sleepQuality: 4, today: LocalDate(year: 2026, month: 3, day: 8)
        )

        let unfiltered = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )
        let filtered = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(sportId: football), calendar: Self.utcCalendar
        )

        let unfilteredWeek = try #require(unfiltered.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        let filteredWeek = try #require(filtered.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        #expect(filteredWeek.performedActivityCount == 0)
        #expect(filteredWeek.sleep.sampleCount == unfilteredWeek.sleep.sampleCount)
        #expect(filteredWeek.sleep.mean == unfilteredWeek.sleep.mean)
        #expect(filteredWeek.sleep.sampleCount == 1)
        #expect(filteredWeek.sleep.mean == 4.0)
    }

    /// Required foundation test 5: weekly Form/Sleep never leak from a
    /// sibling athlete — same isolation guarantee
    /// `athleteSummaryNeverLeaksSiblingData` already proves at the
    /// interval level, proven here at the weekly-bucket level.
    @Test("Weekly Form and Sleep never leak a sibling athlete's data")
    @MainActor
    func weeklyFormAndSleepNeverLeakSiblingData() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let siblingId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)

        let logged = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "My run",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 4
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 3),
            sleepQuality: 4, today: LocalDate(year: 2026, month: 3, day: 8)
        )

        let siblingLogged = try trainingService.logActivity(
            athleteId: siblingId, activityType: .teamTraining, title: "Sibling match",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 90, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: siblingId, loggedActivityId: siblingLogged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 1
        )
        _ = try reflectionService.recordSleep(
            athleteId: siblingId, localDate: LocalDate(year: 2026, month: 3, day: 4),
            sleepQuality: 1, today: LocalDate(year: 2026, month: 3, day: 8)
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        #expect(week.performedActivityCount == 1)
        #expect(week.form.sampleCount == 1)
        #expect(week.form.mean == 4.0)
        #expect(week.sleep.sampleCount == 1)
        #expect(week.sleep.mean == 4.0)
    }

    /// Required foundation test 6: a week with genuinely no data at all
    /// reports factual zeroes/nils across the board — training 0, Form
    /// nil mean with 0 samples, Sleep nil mean with 0 samples — never a
    /// fabricated value.
    @Test("A week with no data reports zero training and nil/zero-sample Form and Sleep")
    @MainActor
    func emptyWeekReportsFactualZeroesAndNilAggregates() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )

        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        #expect(week.totalActualMinutes == 0)
        #expect(week.performedActivityCount == 0)
        #expect(week.form.sampleCount == 0)
        #expect(week.form.mean == nil)
        #expect(week.sleep.sampleCount == 0)
        #expect(week.sleep.mean == nil)
    }

    // MARK: - Training Breakdown round

    /// Required test: Sport breakdown for one weekly bucket (Football
    /// 120, Hockey 80, Running 40) produces exactly 3 segments, each
    /// preserving its exact `SportId` and minutes, and the segments'
    /// total exactly equals the week's own factual `totalActualMinutes`
    /// — minute conservation, the core Training Breakdown contract.
    @Test("Sport breakdown produces exact-ID segments whose minutes sum to the week's factual total")
    @MainActor
    func sportBreakdownProducesExactIdSegmentsSummingToFactualTotal() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)
        let football = SportId()
        let hockey = SportId()
        let running = SportId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 120, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 80, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: running, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 40, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )
        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })

        #expect(week.totalActualMinutes == 240)
        #expect(week.trainingBySport.count == 3)
        #expect(week.trainingBySport.map(\.minutes).reduce(0, +) == 240)
        #expect(week.trainingBySport.first { $0.sportId == football }?.minutes == 120)
        #expect(week.trainingBySport.first { $0.sportId == hockey }?.minutes == 80)
        #expect(week.trainingBySport.first { $0.sportId == running }?.minutes == 40)
    }

    /// Required test: the equivalent Activity Type breakdown — exact
    /// minute conservation across every present `ActivityType`.
    @Test("Activity Type breakdown produces exact segments whose minutes sum to the week's factual total")
    @MainActor
    func activityTypeBreakdownProducesExactSegmentsSummingToFactualTotal() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .strength, title: "Strength",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .recovery, title: "Recovery",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 20, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .strength, title: "Strength again",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 15, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )
        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })

        #expect(week.totalActualMinutes == 65)
        #expect(week.trainingByActivityType.map(\.minutes).reduce(0, +) == 65)
        #expect(week.trainingByActivityType.first { $0.activityType == .strength }?.minutes == 45)
        #expect(week.trainingByActivityType.first { $0.activityType == .recovery }?.minutes == 20)
    }

    /// Required test: breakdown operates ONLY on already-filtered
    /// included activities — a Sport filter that excludes Football
    /// removes the Football segment entirely, and the remaining
    /// stacked total equals the FILTERED factual total, never the
    /// unfiltered one.
    @Test("A Sport filter that excludes Football removes its segment; the remaining stacked total equals the filtered Total")
    @MainActor
    func sportFilterExcludesSegmentAndStackedTotalMatchesFilteredTotal() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)
        let football = SportId()
        let hockey = SportId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 120, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 80, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            filter: StatisticsFilter(sportId: hockey), calendar: Self.utcCalendar
        )
        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })

        #expect(week.totalActualMinutes == 80)
        #expect(week.trainingBySport.count == 1)
        #expect(week.trainingBySport.first?.sportId == hockey)
        #expect(week.trainingBySport.first?.minutes == 80)
        #expect(week.trainingBySport.contains { $0.sportId == football } == false)
        #expect(week.trainingBySport.map(\.minutes).reduce(0, +) == week.totalActualMinutes)
    }

    /// Required test: a week with zero performed Training reports no
    /// fabricated category segments at all — both breakdown arrays are
    /// empty, matching the week's own factual zero total.
    @Test("A week with zero performed Training has no fabricated Sport/Activity Type segments")
    @MainActor
    func zeroTrainingWeekHasNoFabricatedSegments() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )
        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })

        #expect(week.totalActualMinutes == 0)
        #expect(week.trainingBySport.isEmpty)
        #expect(week.trainingByActivityType.isEmpty)
    }

    /// Required scope test: an activity legitimately recorded with no
    /// Sport (`sportId == nil` — a valid `LoggedActivity` needs a
    /// non-blank title OR a Sport, not necessarily both, per
    /// `ActivityIdentity`) contributes its factual minutes to Sport
    /// breakdown under a `sportId == nil` segment rather than being
    /// dropped or fabricating a Sport identity for it.
    @Test("A Sport-less activity's minutes appear in Sport breakdown under a nil-Sport segment, never dropped")
    @MainActor
    func sportlessActivityAppearsUnderNilSportSegment() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 8)
        let football = SportId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: "General fitness",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 20, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 30, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, calendar: Self.utcCalendar
        )
        let week = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })

        #expect(week.totalActualMinutes == 50)
        #expect(week.trainingBySport.count == 2)
        #expect(week.trainingBySport.map(\.minutes).reduce(0, +) == 50)
        #expect(week.trainingBySport.first { $0.sportId == nil }?.minutes == 20)
        #expect(week.trainingBySport.first { $0.sportId == football }?.minutes == 30)
    }

    // MARK: - Sport filter catalog refinement round: availableSportIds

    /// Required test: only Sports with genuinely recorded/performed
    /// training appear — a planned-only Sport and a Missed Sport must
    /// both be excluded, matching the SAME canonical "performed" rule
    /// (`isPerformed`) `athleteSummary` itself uses.
    @Test("availableSportIds includes only Sports with performed training, excluding planned-only and Missed Sports")
    @MainActor
    func availableSportIdsIncludesOnlyPerformedSports() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let football = SportId()
        let running = SportId()
        let swimming = SportId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 6), durationMinutes: 30, status: .completed
        )
        // Planned-only: a PlannedActivity for Running with no corresponding
        // LoggedActivity at all — never reaches Statistics truth.
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: running, plannedDurationMinutes: 45
        )
        // Missed: a genuine LoggedActivity exists for Swimming, but with
        // a non-performed status — excluded from availability too.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 8), durationMinutes: 1, status: .missed
        )

        let available = try statisticsService.availableSportIds(forAthlete: athleteId)

        #expect(available == Set([hockey, football]))
        #expect(!available.contains(running))
        #expect(!available.contains(swimming))
    }

    /// Required test: multiple performed activities for the SAME Sport
    /// still yield that Sport exactly once.
    @Test("availableSportIds deduplicates multiple performed activities for the same Sport")
    @MainActor
    func availableSportIdsDeduplicatesSameSport() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 12), durationMinutes: 30, status: .partiallyCompleted
        )

        let available = try statisticsService.availableSportIds(forAthlete: athleteId)

        #expect(available == Set([hockey]))
    }

    /// Required test: a performed activity with no Sport does not
    /// create a fake filter option.
    @Test("availableSportIds never includes a fake option for Sport-less performed activities")
    @MainActor
    func availableSportIdsExcludesSportlessActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: "General fitness",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 20, status: .completed
        )

        let available = try statisticsService.availableSportIds(forAthlete: athleteId)

        #expect(available.isEmpty)
    }

    /// Required test: availability reflects the athlete's ENTIRE
    /// recorded history, never merely the currently selected period —
    /// a Sport that exists only in old history (well outside any
    /// rolling window) still appears.
    @Test("availableSportIds reflects the athlete's entire history, independent of any Statistics period")
    @MainActor
    func availableSportIdsIsIndependentOfSelectedPeriod() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let football = SportId()

        // Hockey: old history, well over a year before "today" below.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2023, 1, 10), durationMinutes: 30, status: .completed
        )
        // Football: recent.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 20), durationMinutes: 30, status: .completed
        )

        let available = try statisticsService.availableSportIds(forAthlete: athleteId)

        #expect(available == Set([hockey, football]))
    }

    // MARK: - Activity Type filter catalog refinement round: availableActivityTypes

    /// Required test: only performed Activity Types appear — Missed and
    /// Cancelled activities never contribute, matching the SAME
    /// canonical "performed" rule (`isPerformed`) `athleteSummary`/
    /// `availableSportIds` already use.
    @Test("availableActivityTypes includes only performed types, excluding Missed and Cancelled")
    @MainActor
    func availableActivityTypesIncludesOnlyPerformedTypes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .teamTraining, title: "Team session",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .strength, title: "Strength session",
            startedAt: Self.date(2026, 3, 6), durationMinutes: 20, status: .partiallyCompleted
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .match, title: "Missed match",
            startedAt: Self.date(2026, 3, 7), durationMinutes: 1, status: .missed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .recovery, title: "Cancelled recovery",
            startedAt: Self.date(2026, 3, 8), durationMinutes: 1, status: .cancelled
        )

        let available = try statisticsService.availableActivityTypes(forAthlete: athleteId)

        #expect(available == Set([.teamTraining, .strength]))
        #expect(!available.contains(.match))
        #expect(!available.contains(.recovery))
    }

    /// Required test: multiple performed activities of the SAME type
    /// still yield that type exactly once.
    @Test("availableActivityTypes deduplicates multiple performed activities of the same type")
    @MainActor
    func availableActivityTypesDeduplicatesSameType() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .teamTraining, title: "Session 1",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .teamTraining, title: "Session 2",
            startedAt: Self.date(2026, 3, 12), durationMinutes: 30, status: .completed
        )

        let available = try statisticsService.availableActivityTypes(forAthlete: athleteId)

        #expect(available == Set([.teamTraining]))
    }

    /// Required test: availability reflects the athlete's ENTIRE
    /// recorded history, never merely the currently selected period —
    /// a type that exists only in old history (well outside any
    /// rolling window) still appears.
    @Test("availableActivityTypes reflects the athlete's entire history, independent of any Statistics period")
    @MainActor
    func availableActivityTypesIsIndependentOfSelectedPeriod() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        // Team Training: old history, well over a year before "today".
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .teamTraining, title: "Old session",
            startedAt: Self.date(2023, 1, 10), durationMinutes: 30, status: .completed
        )
        // Match: recent.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .match, title: "Recent match",
            startedAt: Self.date(2026, 3, 20), durationMinutes: 45, status: .completed
        )

        let available = try statisticsService.availableActivityTypes(forAthlete: athleteId)

        #expect(available == Set([.teamTraining, .match]))
    }

    /// Required test: a `PlannedActivity` with no corresponding
    /// performed `LoggedActivity` never makes its Activity Type
    /// available — planned-only truth never reaches Statistics.
    @Test("availableActivityTypes excludes a planned-only Activity Type with no performed LoggedActivity")
    @MainActor
    func availableActivityTypesExcludesPlannedOnlyType() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()

        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Planned-only run", localDate: LocalDate(year: 2026, month: 3, day: 7),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 45
        )

        let available = try statisticsService.availableActivityTypes(forAthlete: athleteId)

        #expect(available.isEmpty)
        #expect(!available.contains(.individualTraining))
    }

    // MARK: - Plan vs Actual

    /// Required test 1: planned count/minutes aggregation — several
    /// planned activities in the interval, all with a recorded planned
    /// duration, produce the correct count and minute sum.
    @Test("Plan vs Actual: planned activity count and minutes aggregate correctly")
    @MainActor
    func plannedActivityCountAndMinutesAggregateCorrectly() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        for (day, duration) in [(3, 60), (5, 30), (7, 45)] {
            _ = try planningService.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
                title: "Session", localDate: LocalDate(year: 2026, month: 3, day: day),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: duration
            )
        }

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 3)
        #expect(summary.plannedMinutes == 135)
    }

    /// Required test 2: a planned activity with no recorded planned
    /// duration still counts as one planned activity, but never
    /// fabricates a minutes contribution.
    @Test("Plan vs Actual: a planned activity with no duration counts toward planned count but not planned minutes")
    @MainActor
    func plannedActivityWithoutDurationCountsButContributesNoMinutes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Session, no duration set", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 1)
        #expect(summary.plannedMinutes == 0)
    }

    /// Required test 4: Plan and Actual are two independent factual
    /// series — a divergence between them is reported exactly, never
    /// collapsed into a synthetic difference/percentage.
    @Test("Plan vs Actual: Planned and Actual report their exact, independent factual values")
    @MainActor
    func plannedAndActualReportExactIndependentValues() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        for (day, duration) in [(3, 50), (5, 50), (7, 50)] {
            _ = try planningService.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
                title: "Planned session", localDate: LocalDate(year: 2026, month: 3, day: day),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: duration
            )
        }
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 50, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 50, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 3)
        #expect(summary.plannedMinutes == 150)
        #expect(summary.performedActivityCount == 2)
        #expect(summary.totalActualMinutes == 100)
    }

    /// Required test 5: Plan and Actual land in their correct canonical
    /// Monday-start weekly buckets, independently of each other.
    @Test("Plan vs Actual: Planned and Actual land in the correct canonical weekly buckets")
    @MainActor
    func plannedAndActualLandInCorrectWeeklyBuckets() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // Two canonical Monday-start weeks: Mar 2 and Mar 9, 2026.
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 15)
        let week1 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        let week2 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 9))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: week1.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Week 1 plan", localDate: LocalDate(year: 2026, month: 3, day: 4),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 40
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: week2.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Week 2 plan", localDate: LocalDate(year: 2026, month: 3, day: 11),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 70
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 10), durationMinutes: 25, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        let week1Bucket = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 2) })
        let week2Bucket = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 9) })
        #expect(week1Bucket.plannedActivityCount == 1)
        #expect(week1Bucket.plannedMinutes == 40)
        #expect(week1Bucket.totalActualMinutes == 0)
        #expect(week2Bucket.plannedActivityCount == 1)
        #expect(week2Bucket.plannedMinutes == 70)
        #expect(week2Bucket.totalActualMinutes == 25)
    }

    /// Required tests 6-8: Sport and Activity Type filters apply AND
    /// semantics identically to Planned and Actual — only matching
    /// planned+actual data contributes when a filter is selected.
    @Test("Plan vs Actual: Sport and Activity Type filters apply identical AND semantics to Planned and Actual")
    @MainActor
    func sportAndActivityTypeFiltersApplyIdenticallyToPlannedAndActual() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let swimming = SportId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        // Matching: Hockey + Team Training.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: hockey, plannedDurationMinutes: 60
        )
        // Non-matching: Swimming + Team Training.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 4),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: swimming, plannedDurationMinutes: 60
        )
        // Non-matching: Hockey + Individual Training (wrong Activity Type).
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 5),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: hockey, plannedDurationMinutes: 60
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Match",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 55, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .teamTraining, title: "Swim",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 45, status: .completed
        )

        let filter = StatisticsFilter(sportId: hockey, activityType: .teamTraining)
        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound, filter: filter,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 1)
        #expect(summary.plannedMinutes == 60)
        #expect(summary.performedActivityCount == 1)
        #expect(summary.totalActualMinutes == 55)
    }

    /// Required test 9: a week with no plan still reports Actual
    /// factually, with Planned reporting a genuine zero.
    @Test("Plan vs Actual: a plan-less week reports Actual factually and Planned as zero")
    @MainActor
    func planLessWeekReportsFactualActualAndZeroPlanned() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        // No WeekPlan is ever created for this athlete/week.
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 40, status: .completed
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 0)
        #expect(summary.plannedMinutes == 0)
        #expect(summary.performedActivityCount == 1)
        #expect(summary.totalActualMinutes == 40)
    }

    /// Required test 10: a week with a plan but nothing performed
    /// reports Planned factually, with Actual reporting a genuine zero.
    @Test("Plan vs Actual: an actual-less week reports Planned factually and Actual as zero")
    @MainActor
    func actualLessWeekReportsFactualPlannedAndZeroActual() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Planned but never logged", localDate: LocalDate(year: 2026, month: 3, day: 4),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 45
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 1)
        #expect(summary.plannedMinutes == 45)
        #expect(summary.performedActivityCount == 0)
        #expect(summary.totalActualMinutes == 0)
    }

    /// Required test 11 (critical): a planned activity dated after
    /// `today`, inside an otherwise-selected current-month interval,
    /// must not contribute to historical Plan vs Actual — Statistics
    /// never lets future planning distort "what already happened."
    @Test("Plan vs Actual: a future planned activity within the current period does not contribute")
    @MainActor
    func futurePlannedActivityWithinCurrentPeriodDoesNotContribute() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // The full current calendar month, March 2026 — `today` (Mar 15)
        // falls in the middle of it, exactly the "still in progress"
        // shape this clamp exists for.
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let today = LocalDate(year: 2026, month: 3, day: 15)
        let week1 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        let week4 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 30))
        // Past/today-relative plan: must count.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: week1.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Already happened window", localDate: LocalDate(year: 2026, month: 3, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 40
        )
        // Future plan (after `today`, later in the same selected month):
        // must NOT count.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: week4.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Future plan", localDate: LocalDate(year: 2026, month: 3, day: 30),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 90
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: today, calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 1)
        #expect(summary.plannedMinutes == 40)
        let futureWeekBucket = try #require(summary.weeklyBuckets.first { $0.weekStart == LocalDate(year: 2026, month: 3, day: 30) })
        #expect(futureWeekBucket.plannedActivityCount == 0)
        #expect(futureWeekBucket.plannedMinutes == 0)
    }

    /// Required test 12: a genuinely historical, already-completed
    /// calendar month is never incorrectly clamped to "today's"
    /// day-of-month — every planned activity in that past month counts,
    /// including ones dated late in the month.
    @Test("Plan vs Actual: a historical calendar month is not clamped to today's day-of-month")
    @MainActor
    func historicalCalendarMonthIsNotClampedToTodaysDayOfMonth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // A fully past month, viewed well after it ended — `today`
        // (Aug 28) has a day-of-month (28) that must have no bearing on
        // which March days count.
        let interval = LocalDate(year: 2026, month: 3, day: 1)...LocalDate(year: 2026, month: 3, day: 31)
        let today = LocalDate(year: 2026, month: 8, day: 28)
        let lastWeek = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 30))
        _ = try planningService.addPlannedActivity(
            toWeekPlan: lastWeek.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Last day of a past month", localDate: LocalDate(year: 2026, month: 3, day: 31),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: today, calendar: Self.utcCalendar
        )

        #expect(summary.plannedActivityCount == 1)
        #expect(summary.plannedMinutes == 30)
    }

    /// Required test 13: sum of weekly planned counts/minutes equals the
    /// summary-level planned count/minutes — one aggregation path, never
    /// two disagreeing totals.
    @Test("Plan vs Actual: weekly planned totals sum to the summary-level planned totals")
    @MainActor
    func weeklyPlannedTotalsSumToSummaryPlannedTotals() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let interval = LocalDate(year: 2026, month: 3, day: 2)...LocalDate(year: 2026, month: 3, day: 22)
        let week1 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 2))
        let week2 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 9))
        let week3 = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: LocalDate(year: 2026, month: 3, day: 16))
        for (weekPlan, day, duration) in [(week1, 3, 30), (week2, 10, 45), (week3, 18, 60)] {
            _ = try planningService.addPlannedActivity(
                toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
                title: "Session", localDate: LocalDate(year: 2026, month: 3, day: day),
                timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: duration
            )
        }

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: interval.lowerBound, through: interval.upperBound,
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        let weeklyPlannedCount = summary.weeklyBuckets.reduce(0) { $0 + $1.plannedActivityCount }
        let weeklyPlannedMinutes = summary.weeklyBuckets.reduce(0) { $0 + $1.plannedMinutes }
        #expect(weeklyPlannedCount == summary.plannedActivityCount)
        #expect(weeklyPlannedMinutes == summary.plannedMinutes)
        #expect(summary.plannedActivityCount == 3)
        #expect(summary.plannedMinutes == 135)
    }
}

// NOTE: like `StatisticsServiceTests` above, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox. Following the S1.1 lesson: no shared
// private helper methods for container construction — every test
// builds its own inline.
@Suite("StatisticsService.weekDetail (Week Drilldown)", .serialized)
struct StatisticsWeekDetailTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Self.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .now
    }

    /// Required test 1: a calendar-month period whose canonical leading
    /// week begins in the PREVIOUS month only returns rows inside the
    /// selected period — August 2026's own first canonical week starts
    /// Monday 27 July 2026 and ends Sunday 2 August 2026, but the
    /// SELECTED interval is `[Aug 1, Aug 31]`, so the drilldown's
    /// effective interval must be `[Aug 1, Aug 2]` only. A planned and a
    /// performed activity dated in late July must not leak in.
    @Test("weekDetail: a calendar-month period's leading edge week only returns rows inside the selected period")
    @MainActor
    func effectiveIntervalExcludesPortionOutsideSelectedPeriod() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 7, day: 27)
        let intervalStart = LocalDate(year: 2026, month: 8, day: 1)
        let intervalEnd = LocalDate(year: 2026, month: 8, day: 31)

        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Late July, outside selected month", localDate: LocalDate(year: 2026, month: 7, day: 28),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 50
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Inside selected month", localDate: LocalDate(year: 2026, month: 8, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 40
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Late July run",
            startedAt: Self.date(2026, 7, 29), durationMinutes: 25, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "August run",
            startedAt: Self.date(2026, 8, 2), durationMinutes: 35, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: intervalStart, through: intervalEnd,
            today: LocalDate(year: 2026, month: 9, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.intervalStart == LocalDate(year: 2026, month: 8, day: 1))
        #expect(detail.intervalEnd == LocalDate(year: 2026, month: 8, day: 2))
        #expect(detail.plannedActivityCount == 1)
        #expect(detail.plannedMinutes == 40)
        #expect(detail.plannedActivities.compactMap(\.title) == ["Inside selected month"])
        #expect(detail.performedActivityCount == 1)
        #expect(detail.totalActualMinutes == 35)
        #expect(detail.performedActivities.compactMap(\.title) == ["August run"])
    }

    /// Required test 2 + 3: planned count/minutes match canonical
    /// `PlannedActivity` rows, and a planned activity with no recorded
    /// duration still counts toward the activity count without
    /// fabricating minutes.
    @Test("weekDetail: planned count/minutes match canonical PlannedActivity rows; a missing duration contributes no fabricated minutes")
    @MainActor
    func plannedSemanticsMatchCanonicalRowsAndNeverFabricateMissingDuration() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Timed session", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 60
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "No duration set", localDate: LocalDate(year: 2026, month: 3, day: 4),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivityCount == 2)
        #expect(detail.plannedMinutes == 60)
        let undated = try #require(detail.plannedActivities.first { $0.title == "No duration set" })
        #expect(undated.plannedDurationMinutes == nil)
    }

    /// Required test 4: `.completed`/`.partiallyCompleted` contribute to
    /// the Actual list/count/minutes; `.missed`/`.cancelled` never do.
    @Test("weekDetail: Completed/PartiallyCompleted are included in Actual; Missed/Cancelled are excluded")
    @MainActor
    func performedSemanticsIncludeOnlyCompletedAndPartiallyCompleted() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Completed",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Partial",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 20, status: .partiallyCompleted
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Missed",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 1, status: .missed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Cancelled",
            startedAt: Self.date(2026, 3, 6), durationMinutes: 1, status: .cancelled
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.performedActivityCount == 2)
        #expect(detail.totalActualMinutes == 50)
        #expect(Set(detail.performedActivities.compactMap(\.title)) == Set(["Completed", "Partial"]))
    }

    /// Required tests 5-7: Sport and Activity Type filters apply the
    /// exact same AND semantics to BOTH the Planned and Performed row
    /// lists.
    @Test("weekDetail: Sport and Activity Type filters apply identical AND semantics to both Planned and Performed lists")
    @MainActor
    func sportAndActivityTypeFiltersApplyToBothLists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let swimming = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: hockey, plannedDurationMinutes: 60
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 4),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: swimming, plannedDurationMinutes: 60
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: nil, localDate: LocalDate(year: 2026, month: 3, day: 5),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: hockey, plannedDurationMinutes: 60
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Match",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 55, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .teamTraining, title: "Swim",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 45, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            filter: StatisticsFilter(sportId: hockey, activityType: .teamTraining),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivities.count == 1)
        #expect(detail.plannedActivities.first?.sportId == hockey)
        #expect(detail.plannedActivities.first?.activityType == .teamTraining)
        #expect(detail.performedActivities.count == 1)
        #expect(detail.performedActivities.first?.title == "Match")
    }

    /// Required test 8: Form uses ONLY the `bodyFeeling` of performed
    /// activities that themselves match the current filter — a
    /// reflection belonging to a filtered-out activity never
    /// contributes.
    @Test("weekDetail: Form aggregates only matching performed activities' bodyFeeling")
    @MainActor
    func formAggregatesOnlyMatchingPerformedActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let swimming = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let hockeyActivity = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Match",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 55, status: .completed
        )
        let swimActivity = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .individualTraining, title: "Swim",
            startedAt: Self.date(2026, 3, 4), durationMinutes: 40, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: hockeyActivity.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 4
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: swimActivity.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 2
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            filter: StatisticsFilter(sportId: hockey),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.form.sampleCount == 1)
        #expect(detail.form.mean == 4)
    }

    /// Required test 9: Sleep remains unfiltered by Sport/Activity Type
    /// — a filter that excludes every performed activity must not
    /// affect the Sleep aggregate.
    @Test("weekDetail: Sleep remains unfiltered by Sport/Activity Type")
    @MainActor
    func sleepRemainsUnfilteredBySportOrActivityType() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let swimming = SportId()
        let excludedFilterSport = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .individualTraining, title: "Swim",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 40, status: .completed
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 3),
            sleepQuality: 4, today: LocalDate(year: 2026, month: 4, day: 1)
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 4),
            sleepQuality: 2, today: LocalDate(year: 2026, month: 4, day: 1)
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            filter: StatisticsFilter(sportId: excludedFilterSport),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.performedActivities.isEmpty)
        #expect(detail.sleep.sampleCount == 2)
        #expect(detail.sleep.mean == 3)
    }

    /// Required test 10 (critical): a planned activity dated after
    /// `today` inside the current week must not contribute to the
    /// historical Plan list/count/minutes.
    @Test("weekDetail: a future planned activity within the current week does not contribute")
    @MainActor
    func futurePlannedActivityWithinCurrentWeekDoesNotContribute() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let today = LocalDate(year: 2026, month: 3, day: 4)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Already happened", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Future plan later this week", localDate: LocalDate(year: 2026, month: 3, day: 6),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 90
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: today, calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivityCount == 1)
        #expect(detail.plannedMinutes == 30)
        #expect(detail.plannedActivities.compactMap(\.title) == ["Already happened"])
    }

    /// Required test 11: a genuinely historical week (`today` is well
    /// after it) is never clamped — every planned activity in that past
    /// week counts, including one dated on the week's own last day.
    @Test("weekDetail: a historical week is not clamped")
    @MainActor
    func historicalWeekIsNotClamped() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Last day of a past week", localDate: LocalDate(year: 2026, month: 3, day: 8),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 8, day: 28), calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivityCount == 1)
        #expect(detail.plannedMinutes == 30)
    }

    /// Required test 12 + 17: deterministic chronological ordering for
    /// both lists, with stable canonical IDs — a planned row with no
    /// recorded start time sorts after timed ones; performed rows sort
    /// by `startedAt`.
    @Test("weekDetail: Planned and Performed rows use deterministic chronological ordering with stable IDs")
    @MainActor
    func deterministicOrderingWithStableIds() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        // Deliberately inserted out of chronological order.
        let noTime = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "No time", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let morning = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: LocalTime(hour: 7, minute: 0)
        )
        let evening = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Evening, earlier day", localDate: LocalDate(year: 2026, month: 3, day: 2),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: LocalTime(hour: 18, minute: 0)
        )
        let later = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Later",
            startedAt: Self.date(2026, 3, 4, hour: 18), durationMinutes: 20, status: .completed
        )
        let earlier = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Earlier",
            startedAt: Self.date(2026, 3, 4, hour: 7), durationMinutes: 20, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivities.map(\.plannedActivityId) == [
            evening.plannedActivityId, morning.plannedActivityId, noTime.plannedActivityId,
        ])
        #expect(detail.performedActivities.map(\.loggedActivityId) == [
            earlier.loggedActivityId, later.loggedActivityId,
        ])
    }

    /// Required tests 13-15: zero/missing cases — a plan-less week, an
    /// actual-less week, and a week with neither all report factual
    /// zero/empty results, never a failure.
    @Test("weekDetail: empty Plan, empty Actual, and both-empty all report factual zero/empty results, not a failure")
    @MainActor
    func zeroAndMissingCasesReportFactualEmptyResults() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let today = LocalDate(year: 2026, month: 4, day: 1)

        // Case: plan exists, no actual.
        let athleteA = AthleteId()
        let weekStartA = LocalDate(year: 2026, month: 3, day: 2)
        let weekPlanA = try planningService.getOrCreateWeekPlan(athleteId: athleteA, weekStart: weekStartA)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanA.weekPlanId, athleteId: athleteA, activityType: .individualTraining,
            title: "Planned only", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
        )
        let detailA = try statisticsService.weekDetail(
            forAthlete: athleteA, weekStart: weekStartA, within: weekStartA, through: weekStartA.adding(days: 6),
            today: today, calendar: Self.utcCalendar
        )
        #expect(detailA.plannedActivityCount == 1)
        #expect(detailA.performedActivityCount == 0)
        #expect(detailA.performedActivities.isEmpty)

        // Case: no plan, actual exists.
        let athleteB = AthleteId()
        let weekStartB = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteB, activityType: .individualTraining, title: "Actual only",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 40, status: .completed
        )
        let detailB = try statisticsService.weekDetail(
            forAthlete: athleteB, weekStart: weekStartB, within: weekStartB, through: weekStartB.adding(days: 6),
            today: today, calendar: Self.utcCalendar
        )
        #expect(detailB.plannedActivityCount == 0)
        #expect(detailB.plannedActivities.isEmpty)
        #expect(detailB.performedActivityCount == 1)

        // Case: neither plan nor actual.
        let athleteC = AthleteId()
        let weekStartC = LocalDate(year: 2026, month: 3, day: 2)
        let detailC = try statisticsService.weekDetail(
            forAthlete: athleteC, weekStart: weekStartC, within: weekStartC, through: weekStartC.adding(days: 6),
            today: today, calendar: Self.utcCalendar
        )
        #expect(detailC.plannedActivityCount == 0)
        #expect(detailC.performedActivityCount == 0)
        #expect(detailC.plannedActivities.isEmpty)
        #expect(detailC.performedActivities.isEmpty)
        #expect(detailC.form.mean == nil)
        #expect(detailC.sleep.mean == nil)
    }

    /// Required test 16 (high value): `weekDetail`'s summary totals for
    /// one week must exactly match the `StatisticsWeekBucket`
    /// `athleteSummary` produces for that SAME athlete/week/interval/
    /// filter/today — one aggregation path, never two that could
    /// silently disagree.
    @Test("weekDetail: parity with the corresponding StatisticsWeekBucket from athleteSummary")
    @MainActor
    func parityWithAthleteSummaryWeekBucket() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let intervalStart = LocalDate(year: 2026, month: 3, day: 2)
        let intervalEnd = LocalDate(year: 2026, month: 3, day: 22)
        let weekStart = LocalDate(year: 2026, month: 3, day: 9)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Plan A", localDate: LocalDate(year: 2026, month: 3, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 45
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Plan B", localDate: LocalDate(year: 2026, month: 3, day: 12),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let logged = try trainingService.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Run",
            startedAt: Self.date(2026, 3, 11), durationMinutes: 35, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 5
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 11),
            sleepQuality: 3, today: LocalDate(year: 2026, month: 4, day: 1)
        )
        let today = LocalDate(year: 2026, month: 4, day: 1)

        let summary = try statisticsService.athleteSummary(
            forAthlete: athleteId, from: intervalStart, through: intervalEnd, today: today, calendar: Self.utcCalendar
        )
        let bucket = try #require(summary.weeklyBuckets.first { $0.weekStart == weekStart })

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: intervalStart, through: intervalEnd,
            today: today, calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivityCount == bucket.plannedActivityCount)
        #expect(detail.plannedMinutes == bucket.plannedMinutes)
        #expect(detail.performedActivityCount == bucket.performedActivityCount)
        #expect(detail.totalActualMinutes == bucket.totalActualMinutes)
        #expect(detail.form.mean == bucket.form.mean)
        #expect(detail.form.sampleCount == bucket.form.sampleCount)
        #expect(detail.sleep.mean == bucket.sleep.mean)
        #expect(detail.sleep.sampleCount == bucket.sleep.sampleCount)
        // Sanity: this test's own fixture actually exercises non-trivial
        // values on every field being compared above, not a vacuous
        // all-zero parity.
        #expect(bucket.plannedActivityCount == 2)
        #expect(bucket.plannedMinutes == 45)
        #expect(bucket.performedActivityCount == 1)
        #expect(bucket.totalActualMinutes == 35)
    }

    // MARK: - Weekly Reflection Context

    /// Required test 1: a `WeeklyReflection` whose `visibility` is
    /// `.sharedWithGuardians` — the ordinary, most common case — is
    /// surfaced in full, with every field preserved exactly as recorded.
    @Test("weekDetail: a sharedWithGuardians reflection is included with every field preserved exactly")
    @MainActor
    func sharedWithGuardiansReflectionIsIncluded() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 4, loadFelt: 3,
            whatWorked: "Consistent mornings", whatWasDifficult: "Tuesday recovery",
            learning: "Needed more sleep before hard days", nextWeekConsideration: "Add a rest day",
            visibility: .sharedWithGuardians
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        let reflection = try #require(detail.weeklyReflection)
        #expect(reflection.weekStart == weekStart)
        #expect(reflection.overallSatisfaction == 4)
        #expect(reflection.loadFelt == 3)
        #expect(reflection.whatWorked == "Consistent mornings")
        #expect(reflection.whatWasDifficult == "Tuesday recovery")
        #expect(reflection.learning == "Needed more sleep before hard days")
        #expect(reflection.nextWeekConsideration == "Add a rest day")
    }

    /// Required test 1 (variant): `.summaryOnly` is visible in full too —
    /// the canonical rule established elsewhere in this codebase
    /// (`WeeklyHistoryViewModel.reflectionAccessState`,
    /// `FamilyHomeViewModel.loadFocusThisWeek()`) is `visibility !=
    /// .privateToAthlete`, not an allow-list of just `.sharedWithGuardians`
    /// — Statistics must not invent a stricter or a degraded "summary"
    /// rendering the domain model itself does not define.
    @Test("weekDetail: a summaryOnly reflection is also included in full, matching the existing canonical visibility rule")
    @MainActor
    func summaryOnlyReflectionIsIncluded() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 5, visibility: .summaryOnly
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.weeklyReflection?.overallSatisfaction == 5)
    }

    /// Required test 3 (BLOCKER-level): a `.privateToAthlete` reflection
    /// must never reach Parent Statistics — neither its content nor its
    /// existence. `weeklyReflection` is `nil`, indistinguishable from
    /// "no reflection recorded at all" — never a redacted placeholder.
    @Test("weekDetail: a privateToAthlete reflection is never surfaced — content and existence both hidden")
    @MainActor
    func privateToAthleteReflectionIsNeverSurfaced() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 2, whatWasDifficult: "Private struggle, not for parents",
            visibility: .privateToAthlete
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.weeklyReflection == nil)
    }

    /// Required test 2: no `WeeklyReflection` recorded for the athlete/
    /// week at all reports `nil` — the same shape as "recorded but
    /// private," which is the intended, non-leaking ambiguity.
    @Test("weekDetail: no reflection recorded for the athlete/week reports nil")
    @MainActor
    func noReflectionRecordedReportsNil() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.weeklyReflection == nil)
    }

    /// Required test 4 (week identity isolation): a reflection recorded
    /// for a different canonical week must never surface under this
    /// week's drilldown — direct `athleteId` + `weekStart` lookup only,
    /// never a nearest-match or date-range heuristic.
    @Test("weekDetail: a reflection recorded for a different week is never returned")
    @MainActor
    func reflectionFromDifferentWeekIsNeverReturned() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let otherWeekStart = LocalDate(year: 2026, month: 3, day: 9)
        let requestedWeekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: otherWeekStart, authorId: ActorId(),
            overallSatisfaction: 5, visibility: .sharedWithGuardians
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: requestedWeekStart, within: requestedWeekStart, through: requestedWeekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.weeklyReflection == nil)
    }

    /// Required test 5 (athlete identity isolation): a sibling athlete's
    /// reflection for the SAME `weekStart` must never leak into this
    /// athlete's drilldown.
    @Test("weekDetail: a sibling athlete's reflection for the same week never leaks")
    @MainActor
    func siblingAthleteReflectionNeverLeaks() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let sibling = AthleteId()
        let requestedAthlete = AthleteId()
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: sibling, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 5, visibility: .sharedWithGuardians
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: requestedAthlete, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.weeklyReflection == nil)
    }

    /// Required tests 6-8: numeric fields are preserved exactly, an
    /// optional field genuinely never recorded stays `nil` (never a
    /// fabricated value like `0` or `""`), and recorded text fields are
    /// reproduced verbatim — no truncation, no rewriting.
    @Test("weekDetail: numeric values are preserved exactly and un-recorded optional fields stay nil")
    @MainActor
    func numericValuesPreservedAndMissingFieldsStayNil() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        // Only overallSatisfaction/whatWorked recorded — every other
        // optional field left genuinely unset.
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 1, whatWorked: "Verbatim text, exactly as written — no rewriting.",
            visibility: .sharedWithGuardians
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        let reflection = try #require(detail.weeklyReflection)
        #expect(reflection.overallSatisfaction == 1)
        #expect(reflection.whatWorked == "Verbatim text, exactly as written — no rewriting.")
        #expect(reflection.loadFelt == nil)
        #expect(reflection.whatWasDifficult == nil)
        #expect(reflection.learning == nil)
        #expect(reflection.nextWeekConsideration == nil)
    }

    /// Required test 9 (filter independence, explicit): `WeeklyReflection`
    /// is week-level, not activity-level — a Sport/Activity Type filter
    /// that excludes every performed activity in the week (so Planned/
    /// Performed/Form are empty) must NOT also hide the week's
    /// Reflection. Mirrors the SAME filter-independence precedent
    /// `weekDetail`'s own Sleep aggregate already establishes (see
    /// `sleepRemainsUnfilteredBySportOrActivityType` above) — Sleep
    /// remains visibly unaffected here too, confirming this filter genuinely
    /// narrowed only Plan/Actual/Form.
    @Test("weekDetail: WeeklyReflection is never filtered by Sport/Activity Type, unlike Planned/Actual/Form")
    @MainActor
    func weeklyReflectionIsNeverFilteredBySportOrActivityType() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let swimming = SportId()
        let excludedFilterSport = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let logged = try trainingService.logActivity(
            athleteId: athleteId, sportId: swimming, activityType: .individualTraining, title: "Swim",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 40, status: .completed
        )
        _ = try reflectionService.recordActivityReflection(
            athleteId: athleteId, loggedActivityId: logged.loggedActivityId, authorId: ActorId(),
            visibility: .sharedWithGuardians, bodyFeeling: 4
        )
        _ = try reflectionService.recordSleep(
            athleteId: athleteId, localDate: LocalDate(year: 2026, month: 3, day: 3),
            sleepQuality: 4, today: LocalDate(year: 2026, month: 4, day: 1)
        )
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 5, nextWeekConsideration: "Neutral wording, not scoped to Swimming",
            visibility: .sharedWithGuardians
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            filter: StatisticsFilter(sportId: excludedFilterSport),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        // The filter genuinely narrowed Planned/Performed/Form to empty —
        // this is a real filter, not a vacuous one.
        #expect(detail.performedActivities.isEmpty)
        #expect(detail.form.sampleCount == 0)
        // ...but Sleep and WeeklyReflection are both unaffected by it.
        #expect(detail.sleep.sampleCount == 1)
        #expect(detail.weeklyReflection?.overallSatisfaction == 5)
        #expect(detail.weeklyReflection?.nextWeekConsideration == "Neutral wording, not scoped to Swimming")
    }

    /// Required test 12 (partial-period edge, high value): a
    /// calendar-month period whose leading edge week only contributes a
    /// PARTIAL slice of factual Plan/Actual/Form/Sleep (per the existing
    /// effective-interval contract — see `weekDetail`'s own doc comment)
    /// must still surface the reflection for the FULL canonical week —
    /// the reflection's own visibility never depends on how much of the
    /// week the caller's selected Statistics period happens to cover.
    @Test("weekDetail: WeeklyReflection surfaces for the full week even when the selected period only covers a partial slice of it")
    @MainActor
    func reflectionSurfacesDespitePartialCalendarMonthInterval() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // Reuses the SAME verified leading-edge-week fixture as
        // `effectiveIntervalExcludesPortionOutsideSelectedPeriod` above:
        // the canonical week starting Monday 2026-07-27 straddles the
        // July/August boundary — a selected "August" calendar-month
        // period only covers August 1 of this week (`effectiveEnd ==
        // weekStart.adding(days: 6)`, `effectiveStart == intervalStart`),
        // not the full Monday-Sunday span.
        let weekStart = LocalDate(year: 2026, month: 7, day: 27)
        let augustIntervalStart = LocalDate(year: 2026, month: 8, day: 1)
        let augustIntervalEnd = LocalDate(year: 2026, month: 8, day: 31)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 3, nextWeekConsideration: "Full-week reflection despite partial period",
            visibility: .sharedWithGuardians
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: augustIntervalStart, through: augustIntervalEnd,
            today: LocalDate(year: 2026, month: 9, day: 1), calendar: Self.utcCalendar
        )

        // Sanity: this really is the partial-slice case, not a vacuous
        // full-week interval.
        #expect(detail.intervalStart == augustIntervalStart)
        #expect(detail.intervalEnd == weekStart.adding(days: 6))
        #expect(detail.weeklyReflection?.overallSatisfaction == 3)
        #expect(detail.weeklyReflection?.weekStart == weekStart)
    }

    /// Required test 13: reading a `WeeklyReflection` through `weekDetail`
    /// is a pure read — it must never create, duplicate, or otherwise
    /// mutate the underlying persisted `WeeklyReflection`, even across
    /// repeated reads.
    @Test("weekDetail: reading a WeeklyReflection never mutates persisted state")
    @MainActor
    func readingWeeklyReflectionNeverMutatesPersistedState() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athleteId, weekStart: weekStart, authorId: ActorId(),
            overallSatisfaction: 4, visibility: .sharedWithGuardians
        )

        _ = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )
        _ = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(try weeklyReflectionService.fetchWeeklyReflections(forAthlete: athleteId).count == 1)
    }

    // MARK: - Week Drilldown UX Refinement: Sport Summary

    /// Required test 12: one Sport, two performed activities — totals
    /// and count aggregate correctly.
    @Test("weekDetail Sport Summary: one Sport aggregates minutes and count across its activities")
    @MainActor
    func sportSummaryOneSportAggregatesMinutesAndCount() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Practice",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Game",
            startedAt: Self.date(2026, 3, 5), durationMinutes: 45, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        let hockeySummary = try #require(detail.sportSummary.first)
        #expect(hockeySummary.sportId == hockey)
        #expect(hockeySummary.totalActualMinutes == 75)
        #expect(hockeySummary.performedActivityCount == 2)
    }

    /// Required test 13: multiple Sports produce correct, independent
    /// totals and counts — never blended together.
    @Test("weekDetail Sport Summary: multiple Sports produce independent totals and counts")
    @MainActor
    func sportSummaryMultipleSportsAreIndependent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let football = SportId()
        let strength = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 240, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 90, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: strength, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 45, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 3)
        #expect(detail.sportSummary.first { $0.sportId == hockey }?.totalActualMinutes == 240)
        #expect(detail.sportSummary.first { $0.sportId == football }?.totalActualMinutes == 90)
        #expect(detail.sportSummary.first { $0.sportId == strength }?.totalActualMinutes == 45)
        #expect(detail.sportSummary.allSatisfy { $0.performedActivityCount == 1 })
    }

    /// Required test 14: a performed activity with no Sport at all
    /// (`sportId == nil`) is bucketed into the "no Sport" identity —
    /// never dropped.
    @Test("weekDetail Sport Summary: a Sport-less performed activity appears in the no-Sport bucket")
    @MainActor
    func sportSummaryNoSportBucketIncludesSportlessActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: "General fitness",
            startedAt: Self.date(2026, 3, 3), durationMinutes: 20, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        #expect(detail.sportSummary.first?.sportId == nil)
        #expect(detail.sportSummary.first?.totalActualMinutes == 20)
        #expect(detail.sportSummary.first?.performedActivityCount == 1)
    }

    /// Required tests 15 + 16 (BLOCKER-level conservation): the sum of
    /// Sport Summary minutes/counts must exactly equal
    /// `totalActualMinutes`/`performedActivityCount` — every activity in
    /// exactly one bucket, never duplicated, omitted, or split.
    @Test("weekDetail Sport Summary: minutes and count sums conserve the week's totals exactly")
    @MainActor
    func sportSummaryConservesWeekTotals() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let football = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 40, status: .partiallyCompleted
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 15, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.map(\.totalActualMinutes).reduce(0, +) == detail.totalActualMinutes)
        #expect(detail.sportSummary.map(\.performedActivityCount).reduce(0, +) == detail.performedActivityCount)
        #expect(detail.totalActualMinutes == 85)
        #expect(detail.performedActivityCount == 3)
    }

    /// Required test 17: a Sport excluded by the active Sport filter
    /// never appears in Sport Summary — the summary reflects the SAME
    /// already-filtered `performedActivities`, never unfiltered history.
    @Test("weekDetail Sport Summary: a Sport excluded by the active filter does not appear")
    @MainActor
    func sportSummaryRespectsActiveSportFilter() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let football = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: football, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 90, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            filter: StatisticsFilter(sportId: hockey),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        #expect(detail.sportSummary.first?.sportId == hockey)
        #expect(detail.sportSummary.map(\.totalActualMinutes).reduce(0, +) == detail.totalActualMinutes)
    }

    /// Required test 18: an Activity Type filter that removes some
    /// activities of a Sport must also remove them from that Sport's
    /// Summary bucket — never aggregated from unfiltered history.
    @Test("weekDetail Sport Summary: an Activity Type filter narrows the included activities within a Sport")
    @MainActor
    func sportSummaryRespectsActivityTypeFilter() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 60, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 30, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            filter: StatisticsFilter(activityType: .teamTraining),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        #expect(detail.sportSummary.first?.totalActualMinutes == 60)
        #expect(detail.sportSummary.first?.performedActivityCount == 1)
    }

    /// Required test 19: only genuinely performed statuses
    /// (Completed/PartiallyCompleted) contribute — Missed/Cancelled are
    /// excluded exactly as `totalActualMinutes`/`performedActivities`
    /// already are.
    @Test("weekDetail Sport Summary: Missed/Cancelled activities never contribute")
    @MainActor
    func sportSummaryExcludesMissedAndCancelled() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 30, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 999, status: .missed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 999, status: .cancelled
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        #expect(detail.sportSummary.first?.totalActualMinutes == 30)
        #expect(detail.sportSummary.first?.performedActivityCount == 1)
    }

    /// Required test 20 (partial calendar-month edge week): Sport
    /// Summary uses the SAME effective interval as the rest of
    /// `weekDetail` — an activity outside the selected period's
    /// effective slice of the canonical week must not contribute, even
    /// though it falls in the same canonical week.
    @Test("weekDetail Sport Summary: only activities inside the effective interval contribute on a partial calendar-month edge week")
    @MainActor
    func sportSummaryRespectsPartialCalendarMonthEffectiveInterval() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        // Same leading-edge-week fixture already verified elsewhere in
        // this file: the canonical week starting 2026-07-27 straddles
        // the July/August boundary; a selected "August" calendar-month
        // period's effective interval for this week is only Aug 1-2.
        let weekStart = LocalDate(year: 2026, month: 7, day: 27)
        let augustIntervalStart = LocalDate(year: 2026, month: 8, day: 1)
        let augustIntervalEnd = LocalDate(year: 2026, month: 8, day: 31)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Late July, outside effective interval",
            startedAt: Self.date(2026, 7, 28), durationMinutes: 50, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: hockey, activityType: .teamTraining, title: "Inside effective interval",
            startedAt: Self.date(2026, 8, 2), durationMinutes: 35, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: augustIntervalStart, through: augustIntervalEnd,
            today: LocalDate(year: 2026, month: 9, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        #expect(detail.sportSummary.first?.totalActualMinutes == 35)
        #expect(detail.sportSummary.first?.performedActivityCount == 1)
    }

    /// Required test 21: a `SportId` with no corresponding canonical
    /// Sport reference-data entry (an "unknown" Sport, from this
    /// service's perspective) still produces a fully factual read-model
    /// row — `StatisticsService` never queries Sport reference data
    /// itself, so this is inherent: it aggregates purely by the stable
    /// `SportId`, regardless of whether that ID resolves anywhere.
    /// ("Unknown" display-name resolution is a presentation concern —
    /// see `WeekDrilldownView.sportSummaryDisplayName(for:)`.)
    @Test("weekDetail Sport Summary: a SportId unresolvable in reference data still conserves its factual totals")
    @MainActor
    func sportSummaryUnknownSportIdStillConserves() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // Never seeded into any Sport reference-data catalog — this
        // service has no dependency on that catalog at all, so this is
        // indistinguishable from any other real SportId to it.
        let unresolvableSportId = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: unresolvableSportId, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 55, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.count == 1)
        #expect(detail.sportSummary.first?.sportId == unresolvableSportId)
        #expect(detail.sportSummary.first?.totalActualMinutes == 55)
        #expect(detail.sportSummary.first?.performedActivityCount == 1)
    }

    /// Required test 22: deterministic sort order — descending
    /// `totalActualMinutes` first (the largest factual contributor to
    /// the week first), then ascending stable Sport-ID string as a
    /// tie-break, with the "no Sport" bucket always last.
    @Test("weekDetail Sport Summary: sorted by descending minutes, then stable Sport identity, no-Sport last")
    @MainActor
    func sportSummaryDeterministicSortOrder() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        // Deliberately created and logged out of both minutes order and
        // UUID-string order, to prove the final order is genuinely
        // derived from the sort rule, not insertion order.
        let sportA = SportId()
        let sportB = SportId()
        let tieSportLower = min(sportA, sportB, by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
        let tieSportHigher = tieSportLower == sportA ? sportB : sportA
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        // Two Sports tied at 20 minutes each — the lower UUID string
        // must sort first between them.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: tieSportHigher, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 3), durationMinutes: 20, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: tieSportLower, activityType: .individualTraining, title: nil,
            startedAt: Self.date(2026, 3, 4), durationMinutes: 20, status: .completed
        )
        // No-Sport bucket also has 20 minutes — must still sort AFTER
        // both real Sports despite the tie.
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: nil, activityType: .other, title: nil,
            startedAt: Self.date(2026, 3, 5), durationMinutes: 20, status: .completed
        )
        // The clear largest contributor — must sort first overall.
        let biggestSport = SportId()
        _ = try trainingService.logActivity(
            athleteId: athleteId, sportId: biggestSport, activityType: .teamTraining, title: nil,
            startedAt: Self.date(2026, 3, 6), durationMinutes: 100, status: .completed
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.map(\.sportId) == [biggestSport, tieSportLower, tieSportHigher, nil])
    }

    /// Required test 23: an empty performed set produces an empty Sport
    /// Summary — never a fabricated "No sport" placeholder for zero
    /// activity.
    @Test("weekDetail Sport Summary: an empty performed set produces an empty summary")
    @MainActor
    func sportSummaryEmptyForEmptyPerformedSet() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.sportSummary.isEmpty)
    }

    /// Required test 24: a planned-only activity (never performed) must
    /// never contribute to Sport Summary — this is strictly an Actual-
    /// side composition summary, never Plan.
    @Test("weekDetail Sport Summary: a planned-only activity never contributes")
    @MainActor
    func sportSummaryExcludesPlannedOnlyActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingService = TrainingService(repository: TrainingRepository(modelContext: container.mainContext))
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let planningService = PlanningService(repository: PlanningRepository(modelContext: container.mainContext))
        let weeklyReflectionService = WeeklyReflectionService(repository: WeeklyReflectionRepository(modelContext: container.mainContext))
        let statisticsService = StatisticsService(
            trainingService: trainingService,
            reflectionService: reflectionService,
            planningService: planningService,
            weeklyReflectionService: weeklyReflectionService
        )
        let athleteId = AthleteId()
        let hockey = SportId()
        let weekStart = LocalDate(year: 2026, month: 3, day: 2)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Planned only", localDate: LocalDate(year: 2026, month: 3, day: 3),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), sportId: hockey, plannedDurationMinutes: 60
        )

        let detail = try statisticsService.weekDetail(
            forAthlete: athleteId, weekStart: weekStart, within: weekStart, through: weekStart.adding(days: 6),
            today: LocalDate(year: 2026, month: 4, day: 1), calendar: Self.utcCalendar
        )

        #expect(detail.plannedActivityCount == 1)
        #expect(detail.sportSummary.isEmpty)
    }
}
