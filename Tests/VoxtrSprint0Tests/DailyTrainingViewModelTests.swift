import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/service construction — every test builds its own inline.

@Suite("DailyTrainingViewModel (S3.3)", .serialized)
struct DailyTrainingViewModelTests {

    @Test("Loading with nothing planned or logged today shows both lists empty")
    @MainActor
    func loadWithNothingTodayShowsEmptyLists() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            athleteId: AthleteId()
        )

        viewModel.load()

        #expect(viewModel.plannedActivities.isEmpty)
        #expect(viewModel.loggedActivities.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Logging an activity persists it, clears the form, and refreshes the logged list")
    @MainActor
    func logActivityPersistsAndClearsForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            athleteId: AthleteId()
        )
        viewModel.load()
        viewModel.newLogTitle = "Easy jog"
        viewModel.newLogDurationMinutes = 30

        viewModel.logActivity()

        #expect(viewModel.loggedActivities.count == 1)
        #expect(viewModel.loggedActivities.first?.title == "Easy jog")
        #expect(viewModel.newLogTitle.isEmpty)
        #expect(viewModel.newLogDurationMinutes == 1)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Logging with an out-of-range duration surfaces an error and does not persist")
    @MainActor
    func logActivityWithInvalidDurationSurfacesError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            athleteId: AthleteId()
        )
        viewModel.newLogTitle = "Easy jog"
        viewModel.newLogDurationMinutes = 5_000

        viewModel.logActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 0)
    }

    @Test("Logging with an out-of-range perceived exertion surfaces an error and does not persist")
    @MainActor
    func logActivityWithInvalidExertionSurfacesError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            athleteId: AthleteId()
        )
        viewModel.newLogTitle = "Easy jog"
        viewModel.newLogPerceivedExertion = 99

        viewModel.logActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 0)
    }

    @Test("Linking a log to a PlannedActivity marks it completed after reload")
    @MainActor
    func linkingToPlannedActivityMarksItCompletedAfterReload() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let referenceDate = Date.now
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate)
        let today = TrainingPlanningCoordinationService.today(referenceDate: referenceDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let plannedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            athleteId: athleteId
        )
        viewModel.load()
        #expect(viewModel.plannedActivities.first?.isCompleted == false)

        viewModel.newLogTitle = "Endurance run"
        viewModel.selectedPlannedActivityId = plannedActivity.plannedActivityId
        viewModel.logActivity()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.plannedActivities.first?.isCompleted == true)
    }

    @Test("Linking to an already-linked PlannedActivity surfaces an error without crashing")
    @MainActor
    func linkingToAlreadyLinkedPlannedActivitySurfacesError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingService = TrainingService(repository: trainingRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let referenceDate = Date.now
        let weekStart = TrainingPlanningCoordinationService.weekStart(referenceDate: referenceDate)
        let today = TrainingPlanningCoordinationService.today(referenceDate: referenceDate)
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let plannedActivity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: today, timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try trainingService.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivity.plannedActivityId,
            activityType: .individualTraining, title: "Endurance run", startedAt: referenceDate
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            athleteId: athleteId
        )

        viewModel.newLogTitle = "Second attempt"
        viewModel.selectedPlannedActivityId = plannedActivity.plannedActivityId
        viewModel.logActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 1)
    }
}
