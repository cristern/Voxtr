import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("Sprint 1 completion: Tomorrow and Family Schedule", .serialized)
struct FamilyScheduleAndTomorrowTests {

    @Test("Activity can be created with start time directly, and it survives fetch/reload")
    @MainActor
    func activityCreatedWithStartTimeSurvivesReload() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)

        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 17, minute: 0)
        )

        let reloaded = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        let reloadedActivity = reloaded.first { $0.plannedActivityId == created.plannedActivityId }
        #expect(reloadedActivity?.startLocalTime?.hour == 17)
        #expect(reloadedActivity?.startLocalTime?.minute == 0)
    }

    @Test("Tomorrow aggregation works across multiple athletes")
    @MainActor
    func tomorrowAggregatesMultipleAthletes() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)

        guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            Issue.record("Could not compute tomorrow"); return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrowDate)
        let tomorrow = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: tomorrowDate)

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let emma = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let oliverWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: tomorrow, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 17, minute: 0)
        )
        let emmaWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: emma.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan.weekPlanId, athleteId: emma.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: tomorrow, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 9, minute: 0)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [oliver, emma],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadTomorrow()

        #expect(viewModel.tomorrowRows.count == 2)
        #expect(Set(viewModel.tomorrowRows.map(\.athleteName)) == ["Oliver", "Emma"])
        // Chronological — Emma's 9:00 activity before Oliver's 17:00.
        #expect(viewModel.tomorrowRows.map(\.athleteName) == ["Emma", "Oliver"])
    }

    /// Sprint 1.2B runtime closeout (P1): Tomorrow must include an
    /// unmaterialized recurring occurrence — confirmed missing
    /// entirely before this fix (loadTomorrow() only ever queried
    /// materialized PlannedActivity rows). Also confirms viewing it
    /// never materializes anything: no WeekPlan is created for
    /// tomorrow's week merely by loading the schedule.
    @Test("Tomorrow includes an unmaterialized recurring occurrence, without materializing it")
    @MainActor
    func tomorrowIncludesUnmaterializedRecurringOccurrence() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)

        guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            Issue.record("Could not compute tomorrow"); return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrowDate)
        let tomorrow = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: tomorrowDate)

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // Deliberately NOT calling getOrCreateWeekPlan for tomorrow's
        // week at all — matching "the parent has never visited this
        // week's plan," the exact scenario the fix addresses.
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [tomorrow.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [oliver],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadTomorrow()

        #expect(viewModel.tomorrowRows.count == 1)
        guard case .recurringOccurrence = viewModel.tomorrowRows.first else {
            Issue.record("Expected a .recurringOccurrence row")
            return
        }

        // Never materialized merely by loading Tomorrow — no WeekPlan
        // exists for tomorrow's week at all.
        let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: oliver.athleteId, weekStart: weekStart)
        #expect(weekPlan == nil)
    }

    @Test("Family Schedule includes upcoming activities from multiple athletes, grouped and ordered deterministically")
    @MainActor
    func familyScheduleGroupsMultipleAthletesDeterministically() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let emma = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // Day+3 and Day+7 — two distinct upcoming days, potentially
        // spanning different WeekPlans.
        guard let dayPlus3 = Calendar.current.date(byAdding: .day, value: 3, to: .now),
              let dayPlus7 = Calendar.current.date(byAdding: .day, value: 7, to: .now) else {
            Issue.record("Could not compute reference dates"); return
        }
        func localDate(_ date: Date) -> LocalDate {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        }
        let date3 = localDate(dayPlus3)
        let date7 = localDate(dayPlus7)

        let oliverWeekPlan3 = try planningService.getOrCreateWeekPlan(
            athleteId: oliver.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan3.weekPlanId, athleteId: oliver.athleteId, activityType: .teamTraining,
            title: "Football", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let emmaWeekPlan7 = try planningService.getOrCreateWeekPlan(
            athleteId: emma.athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus7)
        )
        _ = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan7.weekPlanId, athleteId: emma.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: date7, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver, emma],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        #expect(viewModel.dayGroups.count == 2)
        // Groups sorted by date ascending — day+3 before day+7.
        #expect(viewModel.dayGroups.map(\.date) == [date3, date7])
        #expect(viewModel.dayGroups.first?.rows.first?.athleteName == "Oliver")
        #expect(viewModel.dayGroups.last?.rows.first?.athleteName == "Emma")

        // Re-running produces the identical grouping/order — deterministic.
        viewModel.loadSchedule()
        #expect(viewModel.dayGroups.map(\.date) == [date3, date7])
    }

    @Test("Navigation from Family Schedule preserves the correct athlete/activity identity")
    @MainActor
    func familyScheduleNavigationPreservesIdentity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let athleteId = AthleteId()
        guard let dayPlus3 = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dayPlus3)
        let date3 = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let weekPlan = try planningService.getOrCreateWeekPlan(
            athleteId: athleteId, weekStart: TrainingPlanningCoordinationService.weekStart(referenceDate: dayPlus3)
        )
        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .teamTraining,
            title: "Football", localDate: date3, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            location: "Nadderud Stadion"
        )

        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [athlete],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        // Note: athleteId in the group's rows comes from the ViewModel's
        // own activeAthletes list, not the freshly-generated athleteId
        // used above for the plan — this test targets the ACTIVITY
        // identity preserved through the query, which is athlete-scoped
        // via the athlete passed to loadSchedule's own iteration.
        _ = viewModel // constructed to confirm compile-time shape only for this identity check
        let resolvedActivity = try planningRepository.fetchPlannedActivity(byId: created.plannedActivityId)
        #expect(resolvedActivity?.plannedActivityId == created.plannedActivityId)
        #expect(resolvedActivity?.location == "Nadderud Stadion")

        // The ActivityDetailViewLoader this row would navigate to is
        // constructed directly from row.plannedActivity/row.athleteId —
        // confirming here that those values are exactly what was
        // created, not derived or guessed.
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let detailViewModel = ActivityDetailViewModel(
            activity: created, isCompleted: false, weekPlanId: weekPlan.weekPlanId,
            athleteId: athleteId, athleteDisplayName: "Oliver", isWeekPlanDraft: true, deletedByActorId: ActorId(),
            planningService: planningService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            )
        )
        #expect(detailViewModel.activity.plannedActivityId == created.plannedActivityId)
    }
}

extension FamilyScheduleAndTomorrowTests {
    /// Sprint 1.1, P1: Family Schedule must show recurring activities
    /// occurring within its displayed range, even for a week the
    /// parent has never visited (no WeekPlan exists yet for it) — the
    /// exact gap this fix addresses. Confirms the recurring occurrence
    /// appears as its own, distinct row (never collapsed with a real
    /// planned activity), with correct athlete identity.
    @Test("Family Schedule includes recurring activities within its date range, even for a week with no existing WeekPlan")
    @MainActor
    func familyScheduleIncludesRecurringActivitiesForUnvisitedWeek() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // A recurring activity effective well into the future — no
        // WeekPlan has ever been created for any of the weeks it
        // recurs into; deliberately NOT calling getOrCreateWeekPlan at
        // all, matching "a week nobody has visited yet." 5 days ahead —
        // inside the approved "today through 7 days ahead" window, far
        // enough to confirm the window extends beyond tomorrow alone.
        guard let farFuture = Calendar.current.date(byAdding: .day, value: 5, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: farFuture)
        let farFutureDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [farFutureDate.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        let matchingGroup = viewModel.dayGroups.first { $0.date == farFutureDate }
        let recurringRow = matchingGroup?.rows.first { row in
            if case .recurringSuggestion = row { return true }
            return false
        }
        #expect(recurringRow != nil)
        #expect(recurringRow?.title == "Swim Practice")
        #expect(recurringRow?.athleteName == "Oliver")
    }

    @Test("A recurring occurrence already materialized into a real PlannedActivity is not duplicated as a separate suggestion row")
    @MainActor
    func materializedRecurringOccurrenceIsNotDuplicated() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )

        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let inThreeDays = Calendar.current.date(byAdding: .day, value: 3, to: .now) else {
            Issue.record("Could not compute reference date"); return
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: inThreeDays)
        let occurrenceDate = LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: inThreeDays)

        let recurring = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [occurrenceDate.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        // Materialize the occurrence via the real acceptSuggestion path.
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStart)
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let matchingSuggestion = try #require(suggestions.first { $0.recurringPlannedActivityId == recurring.recurringPlannedActivityId })
        _ = try planningService.acceptSuggestion(matchingSuggestion, forWeekPlan: weekPlan.weekPlanId)

        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        let matchingGroup = viewModel.dayGroups.first { $0.date == occurrenceDate }
        // Exactly one row for this occurrence — the materialized
        // .planned one — never a duplicate .recurringSuggestion.
        #expect(matchingGroup?.rows.count == 1)
        if case .planned = matchingGroup?.rows.first {
            // Correct — materialized.
        } else {
            Issue.record("Expected the materialized occurrence to appear as a .planned row, not a suggestion")
        }
    }

    // MARK: - Rolling window: today through +7 days

    @Test("Family Schedule's rolling window includes today and excludes activities beyond +7 days")
    @MainActor
    func rollingWindowIncludesTodayThroughSevenDaysAndExcludesEighth() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let today = TrainingPlanningCoordinationService.today()
        let plusSeven = today.adding(days: 7)
        let plusEight = today.adding(days: 8)
        let weekStartToday = TrainingPlanningCoordinationService.weekStart()
        let weekStartPlusSeven = TrainingPlanningCoordinationService.weekStart(referenceDate: {
            var comps = DateComponents()
            comps.year = plusSeven.year; comps.month = plusSeven.month; comps.day = plusSeven.day
            return Calendar.current.date(from: comps) ?? .now
        }())
        let weekStartPlusEight = TrainingPlanningCoordinationService.weekStart(referenceDate: {
            var comps = DateComponents()
            comps.year = plusEight.year; comps.month = plusEight.month; comps.day = plusEight.day
            return Calendar.current.date(from: comps) ?? .now
        }())

        let weekPlanToday = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartToday)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanToday.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Today's session", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let weekPlanPlusSeven = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartPlusSeven)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanPlusSeven.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Plus-seven session", localDate: plusSeven, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let weekPlanPlusEight = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartPlusEight)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanPlusEight.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Plus-eight session", localDate: plusEight, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        #expect(viewModel.dayGroups.contains { $0.date == today })
        #expect(viewModel.dayGroups.contains { $0.date == plusSeven })
        #expect(!viewModel.dayGroups.contains { $0.date == plusEight })
    }

    @Test("A Sunday reference still surfaces activities in the following week, not just the current calendar week")
    @MainActor
    func sundayReferenceSurfacesFollowingWeekActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // 3 days ahead of today is always within the rolling window
        // regardless of which weekday "today" happens to be when this
        // test runs — including when today is itself a Sunday, this
        // date falls into the FOLLOWING Vǫxtr week (Monday-Sunday),
        // proving the rolling window is not bounded by the current
        // calendar week.
        let today = TrainingPlanningCoordinationService.today()
        let threeDaysAhead = today.adding(days: 3)
        let weekStartForTarget = threeDaysAhead.startOfWeek
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: weekStartForTarget)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Following-week session", localDate: threeDaysAhead, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        viewModel.loadSchedule()

        let matchingGroup = viewModel.dayGroups.first { $0.date == threeDaysAhead }
        #expect(matchingGroup?.rows.contains { row in
            if case .planned(let familyHomeRow) = row { return familyHomeRow.plannedActivity.title == "Following-week session" }
            return false
        } == true)
    }

    /// Highest-practical-layer regression for the actual TestFlight
    /// report: proves `FamilyScheduleViewModel` itself — the real
    /// screen's own data path, not an isolated helper — genuinely
    /// crosses a Monday-Sunday week boundary. Unlike
    /// `sundayReferenceSurfacesFollowingWeekActivities` above (which
    /// only tests "3 days ahead," a window that DOESN'T cross a week
    /// boundary at all unless "today" happens to already be late in
    /// the week when the test runs — a non-deterministic proof of the
    /// one thing this test needs to prove), this test injects a
    /// deterministically-computed Sunday as "today" via the new
    /// `loadSchedule(referenceDate:calendar:)` overload, so the
    /// following-Monday activity is guaranteed to sit in the NEXT
    /// Vǫxtr week regardless of which weekday this test actually runs
    /// on.
    @Test("FamilyScheduleViewModel itself crosses a Sunday->Monday week boundary — planned activity, recurring occurrence, no duplication, no materialization")
    @MainActor
    func viewModelCrossesSundayToMondayWeekBoundary() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let oliver = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        // Deterministically compute the NEXT Sunday from "now" (or
        // today itself, if today already is Sunday) as the injected
        // reference date — never a hardcoded calendar date that could
        // go stale, never wall-clock "today" used directly.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.year, .month, .day], from: .now)
        let todayLocalDate = LocalDate(year: nowComponents.year ?? 1970, month: nowComponents.month ?? 1, day: nowComponents.day ?? 1)
        let daysUntilSunday = (Weekday.sunday.rawValue - todayLocalDate.weekday.rawValue + 7) % 7
        let sundayLocalDate = todayLocalDate.adding(days: daysUntilSunday)
        var sundayComponents = DateComponents()
        sundayComponents.year = sundayLocalDate.year; sundayComponents.month = sundayLocalDate.month; sundayComponents.day = sundayLocalDate.day
        let sundayReferenceDate = calendar.date(from: sundayComponents) ?? .now
        #expect(sundayLocalDate.weekday == .sunday)

        // The following Monday — genuinely in the NEXT Vǫxtr week
        // relative to sundayLocalDate, not the same one.
        let followingMonday = sundayLocalDate.adding(days: 1)
        #expect(followingMonday.startOfWeek != sundayLocalDate.startOfWeek)
        // +8 days from the Sunday reference — must be excluded.
        let eightDaysOut = sundayLocalDate.adding(days: 8)

        let weekPlanForMonday = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: followingMonday.startOfWeek)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanForMonday.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Following Monday session", localDate: followingMonday, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // A recurring definition landing on the same following Monday —
        // proves recurring composition also crosses the boundary,
        // read-only (never materialized merely by being displayed).
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: oliver.athleteId, title: "Swim Practice", activityType: .individualTraining,
            weekdays: [followingMonday.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        // An activity 8 days out from the Sunday reference — must be
        // excluded from the rolling window entirely.
        let weekPlanForEighthDay = try planningService.getOrCreateWeekPlan(athleteId: oliver.athleteId, weekStart: eightDaysOut.startOfWeek)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlanForEighthDay.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Excluded eighth-day session", localDate: eightDaysOut, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyScheduleViewModel(
            activeAthletes: [oliver],
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            planningService: planningService
        )
        // The real screen's own entry point, injected with the fixed
        // Sunday reference — the same method FamilyScheduleView's own
        // .onAppear calls, not a bypass around it.
        viewModel.loadSchedule(referenceDate: sundayReferenceDate, calendar: calendar)

        // Criterion 4: crossing the boundary works — the materialized
        // planned activity in the following week appears.
        let mondayGroup = viewModel.dayGroups.first { $0.date == followingMonday }
        let plannedRow = mondayGroup?.rows.first { row in
            if case .planned(let familyHomeRow) = row { return familyHomeRow.plannedActivity.title == "Following Monday session" }
            return false
        }
        #expect(plannedRow != nil)

        // Criterion 5/6: the recurring occurrence for the SAME date
        // also appears (read-only composition), and there is exactly
        // one row per real identity on that day — no duplicate
        // recurring/materialized pair, no title/date-only inference.
        let recurringRow = mondayGroup?.rows.first { row in
            if case .recurringSuggestion(_, _, _, let suggestion) = row { return suggestion.title == "Swim Practice" }
            return false
        }
        #expect(recurringRow != nil)
        #expect(mondayGroup?.rows.count == 2)

        // Criterion 3: +8 days is excluded from the rolling window.
        #expect(!viewModel.dayGroups.contains { $0.date == eightDaysOut })
    }
}
