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
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadHome()

        // Not-completed rows chronological first (earlier before later),
        // completed row last regardless of its own (earliest) time.
        #expect(viewModel.rows.map(\.plannedActivity.title) == ["Morning run", "Evening session", "Strength"])
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
        #expect(resolved?.plannedActivity.plannedActivityId == created.plannedActivityId)
    }

    @Test("Reflection reminder shows 'no reflection yet' when none exists for the first active athlete")
    @MainActor
    func reflectionReminderShowsNoneWhenAbsent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
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
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadReflectionReminder()

        guard case .none(let athleteName) = viewModel.reflectionState else {
            Issue.record("Expected .none, got \(viewModel.reflectionState)")
            return
        }
        #expect(athleteName == "Oliver")
    }

    @Test("Reflection reminder shows recorded content when a reflection exists")
    @MainActor
    func reflectionReminderShowsRecordedContent() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
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
        _ = try weeklyReflectionService.recordWeeklyReflection(
            athleteId: athlete.athleteId, weekStart: weekStart, authorId: ActorId(),
            whatWorked: "Consistent effort", visibility: .privateToAthlete
        )

        let viewModel = FamilyHomeViewModel(
            activeAthletes: [athlete],
            workspaceId: WorkspaceId(),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            trainingPlanningCoordinationService: trainingPlanningCoordinationService,
            weeklyReflectionService: weeklyReflectionService
        )
        viewModel.loadReflectionReminder()

        guard case .recorded(let athleteName, let whatWentWell, _) = viewModel.reflectionState else {
            Issue.record("Expected .recorded, got \(viewModel.reflectionState)")
            return
        }
        #expect(athleteName == "Oliver")
        #expect(whatWentWell == "Consistent effort")
    }

    @Test("An athlete added after the ViewModel was constructed appears once refreshActiveAthletes runs — the launch-time snapshot never goes permanently stale")
    @MainActor
    func refreshPicksUpAthleteAddedAfterConstruction() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
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
}
