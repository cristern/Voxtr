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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
        let statisticsService = StatisticsService(trainingService: trainingService, reflectionService: reflectionService)
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
}
