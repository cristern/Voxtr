import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
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
}
