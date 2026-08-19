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

    /// Activity outcome consistency closeout (item B): Family Home used
    /// to show ANY resolved outcome as "Completed" (`FamilyHomeRow.isCompleted`'s
    /// own loose "an outcome was resolved" meaning) — a Cancelled or
    /// Missed activity displayed as Completed. `FamilyHomeRow.outcomeStatus`
    /// (backed by the real `LoggedActivity` the row composed through)
    /// is what the view now reads instead. Two athletes, two different
    /// outcomes, proves both the correct mapping AND that one athlete's
    /// outcome is never attributed to another's row.
    @Test("Family Home composition exposes the real outcome per row — Cancelled/Missed/Completed are never conflated, and never cross athlete boundaries")
    @MainActor
    func familyHomeExposesRealOutcomePerAthlete() throws {
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
        let oliverActivity = try planningService.addPlannedActivity(
            toWeekPlan: oliverWeekPlan.weekPlanId, athleteId: oliver.athleteId, activityType: .individualTraining,
            title: "Oliver's run", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let emmaWeekPlan = try planningService.getOrCreateWeekPlan(athleteId: emma.athleteId, weekStart: weekStart)
        let emmaActivity = try planningService.addPlannedActivity(
            toWeekPlan: emmaWeekPlan.weekPlanId, athleteId: emma.athleteId, activityType: .individualTraining,
            title: "Emma's swim", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try trainingService.logActivity(
            athleteId: oliver.athleteId, plannedActivityId: oliverActivity.plannedActivityId,
            activityType: .individualTraining, title: "Oliver's run", startedAt: .now,
            durationMinutes: 40, status: .completed
        )
        _ = try trainingService.logActivity(
            athleteId: emma.athleteId, plannedActivityId: emmaActivity.plannedActivityId,
            activityType: .individualTraining, title: "Emma's swim", startedAt: .now,
            durationMinutes: 1, status: .cancelled
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
        viewModel.loadHome()

        func outcomeStatus(forAthleteId athleteId: AthleteId) -> ActivityStatus? {
            for row in viewModel.rows {
                if case .planned(let familyRow) = row, familyRow.athleteId == athleteId {
                    return familyRow.outcomeStatus
                }
            }
            return nil
        }

        #expect(outcomeStatus(forAthleteId: oliver.athleteId) == .completed)
        #expect(outcomeStatus(forAthleteId: emma.athleteId) == .cancelled)
        #expect(TrainingStrings.outcomeLabel(for: .completed) == TrainingStrings.completedLabel)
        #expect(TrainingStrings.outcomeLabel(for: .cancelled) == TrainingStrings.cancelledLabel)
        #expect(TrainingStrings.outcomeLabel(for: .missed) == TrainingStrings.missedLabel)
        // Never fabricated: Cancelled is never Completed.
        #expect(TrainingStrings.outcomeLabel(for: .cancelled) != TrainingStrings.completedLabel)
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

    /// Family Home athlete navigation round: backs `athletesSection`'s
    /// own requirement — every active athlete must remain reachable via
    /// Family Home even on a day with no activity, so `activeAthletes`
    /// (the composition that section reads directly) must never depend
    /// on `rows`/`nowNextState`/any activity-derived state. An athlete
    /// with genuinely zero planned, recurring, or logged activity today
    /// (never scheduled anything, ever) still appears — proving the
    /// list is sourced from the athlete roster itself
    /// (`AthleteRepository`), not filtered by or derived from today's
    /// schedule.
    @Test("activeAthletes contains an athlete with no activity today, alongside one that has activity — athlete presence never depends on today's schedule")
    @MainActor
    func activeAthletesIncludesAthleteWithNoActivityToday() throws {
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

        let busyAthlete = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Oliver",
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let quietAthlete = try athleteRepository.createAthlete(
            workspaceId: workspaceId, givenName: "Emma",
            birthDate: LocalDate(year: 2014, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: busyAthlete.athleteId, weekStart: weekStart)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: busyAthlete.athleteId, activityType: .teamTraining,
            title: "Football", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        // quietAthlete: no week plan, no planned/recurring/logged
        // activity created at all — a genuinely empty day.

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [],
            workspaceId: workspaceId,
            athleteRepository: athleteRepository,
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.refreshActiveAthletes()

        #expect(viewModel.activeAthletes.contains { $0.athleteId == busyAthlete.athleteId })
        #expect(viewModel.activeAthletes.contains { $0.athleteId == quietAthlete.athleteId })
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

    /// Review follow-up (final check before merge): `nowNextState`'s
    /// eligibility gate (`!$0.isCompletedOrLogged`, unchanged by the
    /// outcome-consistency closeout) already means "has ANY outcome
    /// been resolved" — the same broad `isCompleted` semantic
    /// deliberately kept for this exact purpose, distinct from the
    /// `outcomeStatus`/`isGenuinelyCompleted` semantics `TrainingStrings.outcomeLabel`
    /// now uses for LABELS. A Cancelled or Missed activity is
    /// "resolved," so it is excluded from NOW/NEXT candidacy the same
    /// way a genuinely Completed one already was — even when its own
    /// start/duration would otherwise place it squarely in the current
    /// NOW window. Both activities remain fully visible in Today's own
    /// row list, correctly labelled — just never occupying the NOW/NEXT
    /// slot.
    @Test("Cancelled and Missed activities are never selected as NOW or NEXT, even when their start/duration would otherwise place them in the current window")
    @MainActor
    func cancelledAndMissedNeverSelectedAsNowOrNext() throws {
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
        // Same "squarely within the current window" placement as the
        // genuinely-NOW test above — if resolution didn't exclude these,
        // both would otherwise test as NOW.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let startMinutes = max(0, nowMinutes - 5)
        let startTime = LocalTime(hour: startMinutes / 60, minute: startMinutes % 60)

        let cancelledActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Cancelled run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: startTime, plannedDurationMinutes: 30
        )
        _ = try trainingService.logActivity(
            athleteId: athlete.athleteId, plannedActivityId: cancelledActivity.plannedActivityId,
            activityType: .individualTraining, title: "Cancelled run", startedAt: .now,
            durationMinutes: 1, status: .cancelled
        )
        let missedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Missed session", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: startTime, plannedDurationMinutes: 30
        )
        _ = try trainingService.logActivity(
            athleteId: athlete.athleteId, plannedActivityId: missedActivity.plannedActivityId,
            activityType: .individualTraining, title: "Missed session", startedAt: .now,
            durationMinutes: 1, status: .missed
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

        // Neither NOW nor NEXT — both are resolved, and their start has
        // already passed, so the correct result is .empty.
        guard case .empty = viewModel.nowNextState else {
            Issue.record("Expected .empty (Cancelled/Missed never NOW/NEXT) — got \(viewModel.nowNextState)")
            return
        }

        // Still fully present in Today's own full list, correctly
        // labelled — never hidden, only excluded from the NOW/NEXT slot.
        func outcomeStatus(forTitle title: String) -> ActivityStatus? {
            for row in viewModel.rows {
                if case .planned(let familyRow) = row, familyRow.plannedActivity.title == title {
                    return familyRow.outcomeStatus
                }
            }
            return nil
        }
        #expect(outcomeStatus(forTitle: "Cancelled run") == .cancelled)
        #expect(outcomeStatus(forTitle: "Missed session") == .missed)
    }

    // MARK: - Planned/Logged Activity lifecycle consistency cleanup: NOW's presentation-only 60-minute fallback
    //
    // Supersedes the previous "started, no duration -> never NOW"
    // contract: NOW now applies a 60-minute PRESENTATION-ONLY fallback
    // window when a planned activity has a start time but no planned
    // duration — see `FamilyHomeViewModel.nowNextState`'s own doc
    // comment and `TodayActivityRow.nowPresentationEndLocalTimeSortKey`.
    // This fallback is read/presentation logic only: it is never
    // written into `PlannedActivity.plannedDurationMinutes`, never
    // becomes actual/logged duration, and never affects Statistics.

    @Test("A started activity with no planned duration is classified NOW while within the 60-minute presentation-only fallback window")
    @MainActor
    func startedActivityWithNoPlannedDurationIsNowWithinFallbackWindow() throws {
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
        // Started 5 minutes ago (clamped at 0) — well within the
        // 60-minute fallback window — but NO plannedDurationMinutes
        // given at all.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let startMinutes = max(0, nowMinutes - 5)
        let startTime = LocalTime(hour: startMinutes / 60, minute: startMinutes % 60)
        let activity = try planningService.addPlannedActivity(
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

        guard case .now(let items) = viewModel.nowNextState else {
            Issue.record("Expected .now (within the 60-minute presentation-only fallback) — got \(viewModel.nowNextState)")
            return
        }
        #expect(items.first?.title == "Unknown-duration run")

        // The fallback is presentation-only — it must never be written
        // back into the canonical PlannedActivity.
        let reloaded = try #require(
            try planningService.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
                .first { $0.plannedActivityId == activity.plannedActivityId }
        )
        #expect(reloaded.plannedDurationMinutes == nil)
    }

    @Test("A started activity with no planned duration is no longer NOW once the 60-minute presentation-only fallback window has elapsed")
    @MainActor
    func startedActivityWithNoPlannedDurationIsNotNowAfterFallbackWindowElapses() throws {
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
        // Started 90 minutes ago (clamped at 0) — past the 60-minute
        // fallback window — with no plannedDurationMinutes.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let startMinutes = max(0, nowMinutes - 90)
        let startTime = LocalTime(hour: startMinutes / 60, minute: startMinutes % 60)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Long-past-start run", localDate: TrainingPlanningCoordinationService.today(),
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

        // The fallback window has elapsed; NEXT is also impossible
        // (its start has already passed), so the correct result is
        // .empty — never a falsely-extended NOW.
        guard case .empty = viewModel.nowNextState else {
            Issue.record("Expected .empty (fallback window elapsed) — got \(viewModel.nowNextState)")
            return
        }

        // Still fully present in Today's own full list — never hidden
        // from Today itself, only excluded from the Now/Next slot.
        #expect(viewModel.rows.contains { $0.title == "Long-past-start run" })
    }

    @Test("An activity with an explicit planned duration is classified NOW/not-NOW by its own real interval, never the 60-minute fallback")
    @MainActor
    func explicitDurationActivityUsesItsOwnIntervalNotTheFallback() throws {
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
        // Started 90 minutes ago with an explicit 120-minute planned
        // duration — still genuinely underway by its OWN interval, well
        // past where the 60-minute fallback would have expired had it
        // (wrongly) applied here.
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let startMinutes = max(0, nowMinutes - 90)
        let startTime = LocalTime(hour: startMinutes / 60, minute: startMinutes % 60)
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "Long training block", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), startLocalTime: startTime, plannedDurationMinutes: 120
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
            Issue.record("Expected .now (within its own explicit 120-minute interval) — got \(viewModel.nowNextState)")
            return
        }
        #expect(items.first?.title == "Long training block")
    }

    @Test("An activity with no start time can never be classified NOW, with or without a planned duration")
    @MainActor
    func activityWithNoStartTimeIsNeverNow() throws {
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
        // No start time at all — cannot be NOW regardless of duration.
        _ = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athlete.athleteId, activityType: .individualTraining,
            title: "No start time run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), plannedDurationMinutes: 30
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

        if case .now = viewModel.nowNextState {
            Issue.record("An activity with no start time must never be classified NOW — got \(viewModel.nowNextState)")
        }
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

/// Athlete Home mounted-instance fix (post-mutation navigation and
/// stale-state consistency audit, closeout): targets the actual proven
/// root cause directly — object identity — rather than re-testing that
/// a callback was called, which the prior branch already proved
/// insufficient (that test passed while the runtime bug remained).
/// `FamilyHomeContentView.athleteOverview(for:)` used to construct a
/// brand new `HomeDashboardViewModel` on every call; nothing guaranteed
/// two calls for the SAME athlete returned the SAME instance, which is
/// exactly what let a reload land on an orphaned object nobody was
/// still observing. `HomeDashboardViewModelCache` is the seam that
/// fixes this — these tests exercise it directly, by identity (`===`),
/// not by inference from similarly-named variables.
@Suite("HomeDashboardViewModelCache (Athlete Home mounted-instance fix)")
struct HomeDashboardViewModelCacheTests {

    @MainActor
    private struct StubCoachingPresentationProvider: CoachingPresentationProviding {
        struct StubError: Error {}
        func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
            throw StubError()
        }
    }

    @MainActor
    private func makeViewModel(
        athleteId: AthleteId,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    ) -> HomeDashboardViewModel {
        HomeDashboardViewModel(
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            coachingPresentationProvider: StubCoachingPresentationProvider(),
            athleteId: athleteId,
            weekStart: LocalDate(year: 2026, month: 1, day: 5),
            activityChangeBroadcaster: AthleteActivityChangeBroadcaster()
        )
    }

    /// The exact defect this cache exists to prevent: two lookups for
    /// the same athlete — mirroring `.navigationDestination(for:)`'s
    /// closure being re-invoked more than once for the same pushed
    /// value — must resolve to the SAME object, never a second,
    /// independently-constructed one.
    @Test("The same athleteId always resolves to the same HomeDashboardViewModel instance, never a second one")
    @MainActor
    func sameAthleteResolvesToSameInstance() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: PlanningRepository(modelContext: container.mainContext),
            trainingRepository: TrainingRepository(modelContext: container.mainContext)
        )
        let athleteId = AthleteId()
        let cache = HomeDashboardViewModelCache()

        var makeCallCount = 0
        let first = cache.viewModel(for: athleteId) {
            makeCallCount += 1
            return makeViewModel(athleteId: athleteId, trainingPlanningCoordinationService: trainingPlanningCoordinationService)
        }
        let second = cache.viewModel(for: athleteId) {
            makeCallCount += 1
            return makeViewModel(athleteId: athleteId, trainingPlanningCoordinationService: trainingPlanningCoordinationService)
        }
        let third = cache.viewModel(for: athleteId) {
            makeCallCount += 1
            return makeViewModel(athleteId: athleteId, trainingPlanningCoordinationService: trainingPlanningCoordinationService)
        }

        // Proven by actual object identity, not by comparing loaded
        // state or inferring from variable names.
        #expect(first === second)
        #expect(second === third)
        #expect(makeCallCount == 1)
    }

    /// The isolation half of the same guarantee: caching per athlete
    /// must never collapse two different athletes onto one shared
    /// instance.
    @Test("Two different athletes never share the same HomeDashboardViewModel instance")
    @MainActor
    func differentAthletesResolveToDifferentInstances() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: PlanningRepository(modelContext: container.mainContext),
            trainingRepository: TrainingRepository(modelContext: container.mainContext)
        )
        let athleteA = AthleteId()
        let athleteB = AthleteId()
        let cache = HomeDashboardViewModelCache()

        let viewModelA = cache.viewModel(for: athleteA) {
            makeViewModel(athleteId: athleteA, trainingPlanningCoordinationService: trainingPlanningCoordinationService)
        }
        let viewModelB = cache.viewModel(for: athleteB) {
            makeViewModel(athleteId: athleteB, trainingPlanningCoordinationService: trainingPlanningCoordinationService)
        }

        #expect(viewModelA !== viewModelB)
        #expect(viewModelA.athleteId == athleteA)
        #expect(viewModelB.athleteId == athleteB)
    }
}

/// VX-023 (Sleep V1): Family Home's dedicated Sleep section. Appended as
/// an extension for a smaller diff against an already large file — same
/// type, same file, same `.serialized` suite.
extension FamilyHomeViewModelTests {
    @MainActor
    private static func makeSleepCoordinationService(container: ModelContainer) -> SleepCoordinationService {
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        return SleepCoordinationService(reflectionService: reflectionService, athleteRepository: athleteRepository)
    }

    private static func makeAthlete(givenName: String) -> AthleteProfile {
        AthleteProfile(
            workspaceId: WorkspaceId(), givenName: givenName,
            birthDate: LocalDate(year: 2012, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"), developmentStage: .parentLed
        )
    }

    @MainActor
    private func makeViewModel(
        container: ModelContainer,
        activeAthletes: [AthleteProfile],
        sleepStatusProvider: any SleepStatusProviding,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster? = nil
    ) -> FamilyHomeViewModel {
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let weeklyReflectionService = WeeklyReflectionService(repository: weeklyReflectionRepository)
        return FamilyHomeViewModel(
            activeAthletes: activeAthletes,
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService,
            sleepStatusProvider: sleepStatusProvider,
            sleepChangeBroadcaster: sleepChangeBroadcaster
        )
    }

    /// Round 4 (Family Home Sleep polish, TestFlight): `FamilyHomeContentView.sleepSection`
    /// wraps each row's entire content in one `NavigationLink(value:)`
    /// to `FamilyHomeDestination.sleepHistory(_:)` — no visible
    /// "History" text anymore (removed this round; the row/status
    /// itself is the affordance) — see that file's own doc comment.
    /// This test proves the underlying, ViewModel-level composition
    /// state that navigation depends on (a summary is still emitted
    /// for a missing-Sleep athlete, with `sleepQuality == nil` driving
    /// "Not logged yet"); it does not itself inspect rendered View
    /// content or navigation-affordance placement.
    @Test("19: Family Home Sleep section — an athlete missing today's Sleep still produces a summary (sleepQuality nil drives 'Not logged yet'; every summary here always routes to Sleep History, never a Log Sleep action)")
    @MainActor
    func sleepSectionMissingSleep() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athlete = Self.makeAthlete(givenName: "Oliver")
        let viewModel = makeViewModel(container: container, activeAthletes: [athlete], sleepStatusProvider: service)

        viewModel.loadSleepSummaries()

        #expect(viewModel.sleepSummaries.count == 1)
        #expect(viewModel.sleepSummaries.first?.sleepQuality == nil)
        #expect(viewModel.sleepSummaries.first?.athleteId == athlete.athleteId)
    }

    /// Round 4: same composition-state proof as test 19 above, for the
    /// recorded-Sleep branch — a summary is still emitted with the real
    /// `sleepQuality`, which is what `sleepSection` reads to show
    /// "x/5", the row still routing to the same Sleep History
    /// destination as the missing-Sleep case.
    @Test("20: Family Home Sleep section — an athlete with today's Sleep already recorded produces a summary with the real value (drives 'x/5', routing to the same Sleep History destination as the missing-Sleep case)")
    @MainActor
    func sleepSectionRecordedSleep() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let service = Self.makeSleepCoordinationService(container: container)
        let athlete = Self.makeAthlete(givenName: "Emma")
        let today = SleepCoordinationService.today()
        _ = try service.recordSleep(athleteId: athlete.athleteId, localDate: today, sleepQuality: 5, today: today)
        let viewModel = makeViewModel(container: container, activeAthletes: [athlete], sleepStatusProvider: service)

        viewModel.loadSleepSummaries()

        #expect(viewModel.sleepSummaries.count == 1)
        #expect(viewModel.sleepSummaries.first?.sleepQuality == 5)
    }

    @Test("21: a successful Sleep mutation refreshes an already-live Family Home Sleep section without requiring navigation re-entry")
    @MainActor
    func liveRefreshOnSleepChange() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let broadcaster = AthleteSleepChangeBroadcaster()
        let service = Self.makeSleepCoordinationService(container: container)
        let sleepCoordinationServiceWithBroadcast = SleepCoordinationService(
            reflectionService: ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext)),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            sleepChangeBroadcaster: broadcaster
        )
        let athlete = Self.makeAthlete(givenName: "Sofia")
        let viewModel = makeViewModel(
            container: container, activeAthletes: [athlete],
            sleepStatusProvider: service, sleepChangeBroadcaster: broadcaster
        )
        // loadSleepSummaries() directly (not refresh()) — refresh() also
        // re-fetches the athlete roster from AthleteRepository, which
        // this test's in-memory-only AthleteProfile was never persisted
        // to; that DB round-trip is orthogonal to what this test proves
        // (live Sleep-section invalidation), matching this file's own
        // existing precedent (e.g. `homeAggregatesMultipleActiveAthletes`
        // above calls `loadHome()` directly for the same reason).
        viewModel.loadSleepSummaries()
        #expect(viewModel.sleepSummaries.first?.sleepQuality == nil)

        // Simulates a save made from a DIFFERENT, already-live screen
        // (e.g. Sleep Capture) — this ViewModel's own refresh()/
        // loadSleepSummaries() is never called again explicitly.
        let today = SleepCoordinationService.today()
        _ = try sleepCoordinationServiceWithBroadcast.recordSleep(
            athleteId: athlete.athleteId, localDate: today, sleepQuality: 3, today: today
        )

        #expect(viewModel.sleepSummaries.first?.sleepQuality == 3)
    }
}
