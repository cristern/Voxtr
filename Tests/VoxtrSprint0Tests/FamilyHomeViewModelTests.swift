import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrAthleteDomain
import VoxtrParentDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container construction — every test builds its own inline.
@Suite("FamilyHomeViewModel (Daily Use Foundation, Part 1)", .serialized)
struct FamilyHomeViewModelTests {

    @Test("Home aggregates today's activities across multiple active athletes")
    @MainActor
    func homeAggregatesMultipleActiveAthletes() throws {
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

        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let firstAthlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let secondAthlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let firstWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: firstAthlete.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: firstWeekPlan.weekPlanId, athleteId: firstAthlete.athleteId, activityType: .teamTraining,
            title: "Football", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 17, minute: 0)
        )
        let secondWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: secondAthlete.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: secondWeekPlan.weekPlanId, athleteId: secondAthlete.athleteId, activityType: .teamTraining,
            title: "Handball", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 18, minute: 30)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [firstAthlete, secondAthlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        #expect(viewModel.rows.count == 2)
        #expect(Set(viewModel.rows.map(\.athleteName)) == ["Oliver", "Emma"])
    }

    @Test("Home rows are sorted chronologically, with completed activities grouped after upcoming ones")
    @MainActor
    func homeOrderingChronologicalWithCompletedLast() throws {
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

        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Lucas",
            birthDate: LocalDate(year: 2013, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)

        // Deliberately created out of chronological order.
        let later = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .teamTraining,
            title: "Evening session", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 19, minute: 0)
        )
        let earlier = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 7, minute: 0)
        )
        let completed = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .physicalTraining,
            title: "Strength", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            startLocalTime: LocalTime(hour: 6, minute: 0)
        )
        _ = try trainingService.logActivity(
            athleteId: athlete.athleteId, plannedActivityId: completed.plannedActivityId,
            activityType: .physicalTraining, title: "Strength", startedAt: .now
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        // Not-completed rows chronological first (earlier before later),
        // completed row last regardless of its own (earliest) time.
        #expect(viewModel.rows.map(\.title) == ["Morning run", "Evening session", "Strength"])
        _ = earlier
        _ = later
    }

    @Test("Home's activity navigation target resolves to the correct planned activity by row id")
    @MainActor
    func homeActivityRowResolvesCorrectTarget() throws {
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

        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        let created = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .teamTraining,
            title: "Football", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        let row = try #require(viewModel.rows.first)
        #expect(row.id == created.id.uuidString)
        let destination = FamilyHomeDestination.activity(rowId: row.id)
        guard case .activity(let rowId) = destination else {
            Issue.record("Expected .activity destination")
            return
        }
        let resolved = viewModel.rows.first { $0.id == rowId }
        guard let resolved, case .planned(let resolvedFamilyHomeRow) = resolved else {
            Issue.record("Expected a .planned row")
            return
        }
        #expect(resolvedFamilyHomeRow.plannedActivity.plannedActivityId == created.plannedActivityId)
    }

    @Test("An athlete added after the ViewModel was constructed appears once refreshActiveAthletes runs — the launch-time snapshot never goes permanently stale")
    @MainActor
    func refreshPicksUpAthleteAddedAfterConstruction() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        let workspaceId = WorkspaceId()

        // Constructed with an EMPTY roster — simulating a launch-time
        // snapshot taken before any athlete existed, or before a second
        // athlete was added, matching the reported symptom's own
        // "initially opened... but after creating [more data] no longer
        // navigates" shape.
        let viewModel = FamilyHomeViewModel(
            activeAthletes: [],
            workspaceId: workspaceId,
            athleteRepository: athleteRepository,
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        #expect(viewModel.activeAthletes.isEmpty)

        // An athlete is added to the SAME workspace after construction —
        // e.g. via AthleteFamilyManagementService, in a real launch.
        _ = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        viewModel.refreshActiveAthletes()

        #expect(viewModel.activeAthletes.count == 1)
        #expect(viewModel.activeAthletes.first?.givenName == "Oliver")
    }

    // MARK: - Parent Home UX / Content Contract: Focus this week

    @Test("Focus this week is derived from the PRIOR week's reflection, not the current week's")
    @MainActor
    func focusThisWeekUsesPriorWeekNotCurrentWeek() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let currentWeekStart = TrainingPlanningCoordinationService.weekStart()
        let priorWeekStart = currentWeekStart.adding(days: -7)

        // Prior week has a recorded focus.
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athlete.athleteId, weekStart: priorWeekStart, authorId: ActorId(),
            nextWeekConsideration: "Start shooting practice without being reminded",
            visibility: .sharedWithGuardians
        )
        // Current week ALSO has a reflection with a DIFFERENT
        // nextWeekConsideration — must never be the one shown.
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athlete.athleteId, weekStart: currentWeekStart, authorId: ActorId(),
            nextWeekConsideration: "This is the CURRENT week's value — must not appear",
            visibility: .sharedWithGuardians
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadFocusThisWeek()

        #expect(viewModel.focusThisWeek.count == 1)
        #expect(viewModel.focusThisWeek.first?.focus == "Start shooting practice without being reminded")
    }

    @Test("No prior-week focus produces no Focus item at all — no placeholder, no 'incomplete' state")
    @MainActor
    func noPriorFocusProducesNoFocusItem() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // No reflection recorded for any week at all.

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadFocusThisWeek()

        #expect(viewModel.focusThisWeek.isEmpty)
    }

    @Test("A prior-week reflection marked privateToAthlete never surfaces its focus text on Family Home")
    @MainActor
    func privateReflectionNeverSurfacesFocus() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let priorWeekStart = TrainingPlanningCoordinationService.weekStart().adding(days: -7)
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athlete.athleteId, weekStart: priorWeekStart, authorId: ActorId(),
            nextWeekConsideration: "Athlete-private content", visibility: .privateToAthlete
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadFocusThisWeek()

        #expect(viewModel.focusThisWeek.isEmpty)
    }

    // MARK: - Parent Home UX / Content Contract: Now/Next

    @Test("An activity later today, not yet started, is surfaced as NEXT")
    @MainActor
    func laterTodayActivityIsSurfacedAsNext() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        // One shared reference instant for everything below — never
        // two independent `.now` reads, which (however unlikely) could
        // theoretically straddle a midnight boundary between them.
        let referenceInstant = Date.now
        let calendar = Calendar.current
        let today = TrainingPlanningCoordinationService.today(referenceDate: referenceInstant, calendar: calendar)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceInstant, calendar: calendar)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        // 18:00 today — the activity itself is a fixed, deterministic
        // time, well clear of any day boundary.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Later today", localDate: today,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: LocalTime(hour: 18, minute: 0)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        // Genuinely deterministic, not wall-clock "now": a fixed
        // reference instant constructed at noon on the SAME day as
        // everything above (derived from the same `referenceInstant`,
        // never a fresh `.now` read), injected directly into the
        // underlying (internal, @testable-visible) computation — 6
        // hours clear of both the activity's own start time and any
        // day boundary.
        var noonComponents = calendar.dateComponents([.year, .month, .day], from: referenceInstant)
        noonComponents.hour = 12
        noonComponents.minute = 0
        let fixedReferenceDate = calendar.date(from: noonComponents) ?? referenceInstant

        guard case .next(let items) = viewModel.nowNextState(referenceDate: fixedReferenceDate, calendar: calendar) else {
            Issue.record("Expected .next — got \(viewModel.nowNextState(referenceDate: fixedReferenceDate, calendar: calendar))")
            return
        }
        #expect(items.count == 1)
        #expect(items.first?.title == "Later today")
    }

    @Test("Now/Next selects an in-progress activity as NOW, using the canonical composed rows")
    @MainActor
    func nowNextShowsUnderwayActivityAsNow() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        // Deliberately places "now" WITHIN the activity's temporal
        // interval, not merely after its start — a start time 5
        // minutes before now (clamped at 0), with a 30-minute duration,
        // so "now" always falls between start and end regardless of
        // when this test actually runs.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let startMinutes = max(0, nowMinutes - 5)
        let startTime = LocalTime(hour: startMinutes / 60, minute: startMinutes % 60)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: startTime, plannedDurationMinutes: 30
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        guard case .now(let items) = viewModel.nowNextState else {
            Issue.record("Expected .now — got \(viewModel.nowNextState)")
            return
        }
        #expect(items.count == 1)
        #expect(items.first?.title == "Morning run")
    }

    @Test("A started activity with unknown duration is never falsely classified NOW — Vǫxtr has no basis to claim it's still in progress")
    @MainActor
    func startedActivityWithUnknownDurationIsNotFalselyNow() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        // Started 5 minutes ago (clamped at 0) — genuinely underway by
        // start time alone — but NO plannedDurationMinutes given at
        // all, so Vǫxtr cannot actually establish an end time.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let startMinutes = max(0, nowMinutes - 5)
        let startTime = LocalTime(hour: startMinutes / 60, minute: startMinutes % 60)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Unknown-duration run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: startTime
            // plannedDurationMinutes deliberately omitted (nil).
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        // Must NOT be .now — Vǫxtr has no real basis to claim this
        // activity is still in progress. It also can't be .next (its
        // start has already passed), so the correct result is .empty.
        guard case .empty = viewModel.nowNextState else {
            Issue.record("Expected .empty (never falsely NOW) — got \(viewModel.nowNextState)")
            return
        }

        // Still fully present in Today's own full list — never hidden
        // from Today itself, only excluded from the Now/Next slot.
        #expect(viewModel.rows.contains { $0.title == "Unknown-duration run" })
    }

    @Test("A tomorrow-only activity is never surfaced as NEXT — Tomorrow already owns its own preview")
    @MainActor
    func tomorrowActivityIsNeverSurfacedAsNext() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            Issue.record("Could not compute tomorrow"); return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrowDate)
        let tomorrow = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: tomorrowDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        // Nothing planned for today at all — only tomorrow.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Tomorrow's run", localDate: tomorrow,
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: LocalTime(hour: 9, minute: 0)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()
        viewModel.loadTomorrow()

        guard case .empty = viewModel.nowNextState else {
            Issue.record("Expected .empty — tomorrow's activity must never surface as NEXT — got \(viewModel.nowNextState)")
            return
        }
        // Tomorrow's own section still shows it, unaffected.
        #expect(viewModel.tomorrowRows.contains { $0.title == "Tomorrow's run" })
    }

    @Test("Now/Next reports empty when there is no canonical activity today or tomorrow")
    @MainActor
    func nowNextIsEmptyWhenNothingRelevant() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()
        viewModel.loadTomorrow()

        guard case .empty = viewModel.nowNextState else {
            Issue.record("Expected .empty — got \(viewModel.nowNextState)")
            return
        }
    }

    @Test("Now/Next never materializes a recurring occurrence merely by being computed")
    @MainActor
    func nowNextDoesNotMaterializeRecurringOccurrence() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let today = TrainingPlanningCoordinationService.today()
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athlete.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()
        _ = viewModel.nowNextState

        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: athlete.athleteId, weekStart: weekStart)
        #expect(weekPlan == nil)
    }

    // MARK: - Recurring cancel/materialization contract

    @Test("A materialized-but-not-yet-logged recurring occurrence (the exact state after Cancel) retains recurring provenance through a fresh recomposition")
    @MainActor
    func materializedRecurringOccurrenceRetainsProvenanceAfterCancel() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athlete.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)

        // "Log Activity" tap materializes the occurrence — exactly what
        // happens BEFORE LogActivityView is ever shown, regardless of
        // whether the user goes on to save or cancel.
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)
        // Cancel: never calls trainingService.logActivity — the
        // occurrence remains materialized but unlogged, exactly this
        // state.

        // A completely FRESH ViewModel/composition, simulating
        // returning to Family Home and recomposing from scratch — not
        // the same in-memory instance that materialized it.
        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        let matchingRow = viewModel.rows.first { $0.id == materialized.plannedActivityId.rawValue.uuidString }
        guard case .planned(let familyHomeRow) = matchingRow else {
            Issue.record("Expected a .planned row for the materialized occurrence")
            return
        }
        #expect(familyHomeRow.isCompleted == false)
        // The actual invariant this fix protects: recurring provenance
        // must survive the fresh recomposition, not just the original
        // screen instance.
        #expect(familyHomeRow.isFromRecurring == true)
    }

    @Test("Successful logging of a materialized recurring occurrence preserves planned/logged identity with no duplicate row")
    @MainActor
    func successfulLogOfMaterializedRecurringOccurrencePreservesIdentityNoDuplicate() throws {
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
        let athlete = AthleteProfile(
            workspaceId: WorkspaceId(), givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let today = TrainingPlanningCoordinationService.today()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athlete.athleteId, weekStart: weekStart)
        _ = try planningService.createRecurringPlannedActivity(
            athleteId: athlete.athleteId, title: "Hockey Camp", activityType: .teamTraining,
            weekdays: [today.weekday], timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            effectiveStartDate: LocalDate(year: 2020, month: 1, day: 1),
            effectiveEndDate: LocalDate(year: 2030, month: 1, day: 1)
        )
        let suggestions = try planningService.deriveSuggestions(forWeekPlan: weekPlan.weekPlanId)
        let suggestion = try #require(suggestions.first)
        let materialized = try planningService.materializeOrFetchExisting(suggestion, forWeekPlan: weekPlan.weekPlanId)

        // One Log Activity save — exactly what LogActivityView's
        // successful save produces.
        let logged = try trainingService.logActivity(
            athleteId: athlete.athleteId, plannedActivityId: materialized.plannedActivityId,
            activityType: .teamTraining, title: "Hockey Camp", startedAt: .now, durationMinutes: 90
        )
        #expect(logged.plannedActivityId == materialized.plannedActivityId.rawValue)

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        let matchingRows = viewModel.rows.filter { $0.id == materialized.plannedActivityId.rawValue.uuidString }
        // Exactly one row — never a duplicate recurring/planned pair.
        #expect(matchingRows.count == 1)
        guard case .planned(let familyHomeRow) = matchingRows.first else {
            Issue.record("Expected a .planned row"); return
        }
        #expect(familyHomeRow.isCompleted == true)
        #expect(familyHomeRow.isFromRecurring == true)

        // The stale-preview unwind guard: only fires once an actual
        // logged relationship exists — verified directly against the
        // same lookup checkForStaleness() itself uses.
        let loggedActivities = try trainingService.fetchLoggedActivities(forPlannedActivity: materialized.plannedActivityId)
        #expect(!loggedActivities.isEmpty)
    }
}
