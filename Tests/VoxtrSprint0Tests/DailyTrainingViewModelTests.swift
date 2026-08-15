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
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
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
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
            athleteId: AthleteId()
        )
        viewModel.load()
        viewModel.newLogTitle = "Easy jog"
        viewModel.newLogDurationMinutes = 30

        viewModel.logActivity()

        #expect(viewModel.loggedActivities.count == 1)
        #expect(viewModel.loggedActivities.first?.title == "Easy jog")
        #expect(viewModel.newLogTitle.isEmpty)
        // Duration is deliberately NOT reset after a successful save
        // (see newLogDurationMinutes's own doc comment, Sprint 1.1
        // closeout Item 5) — it remains the user's own last-entered
        // value, so a parent logging several activities in a row with
        // the same duration doesn't have to re-enter it each time.
        #expect(viewModel.newLogDurationMinutes == 30)
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
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
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
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
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
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
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
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
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
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
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
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
            athleteId: athleteId
        )

        viewModel.newLogTitle = "Second attempt"
        viewModel.selectedPlannedActivityId = plannedActivity.plannedActivityId
        viewModel.logActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 1)
    }

    // MARK: - VX-022: Session Form

    @Test("Logging with a Session Form value stores it as ActivityReflection.bodyFeeling, linked to the exact LoggedActivity")
    @MainActor
    func logActivityWithSessionFormStoresBodyFeeling() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: authorId,
            athleteId: athleteId
        )
        viewModel.newLogTitle = "Match day"
        viewModel.newLogSessionForm = 4

        viewModel.logActivity()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.sessionFormPendingRetry == false)
        // The value is never left populated once genuinely saved —
        // preserved-for-retry only applies to the failure path.
        #expect(viewModel.newLogSessionForm == nil)

        let logged = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
        #expect(logged.count == 1)
        let loggedActivity = try #require(logged.first)

        let reflection = try reflectionService.fetchActivityReflection(forLoggedActivity: loggedActivity.loggedActivityId)
        #expect(reflection?.bodyFeeling == 4)
        #expect(reflection?.loggedActivityId == loggedActivity.id)
        #expect(reflection?.athleteId == athleteId.rawValue)
    }

    @Test("Logging without a Session Form value preserves existing behavior — no reflection is created")
    @MainActor
    func logActivityWithoutSessionFormCreatesNoReflection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
            athleteId: athleteId
        )
        viewModel.newLogTitle = "Easy jog"
        // newLogSessionForm left nil — omission must be fully supported.

        viewModel.logActivity()

        #expect(viewModel.errorMessage == nil)
        let logged = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
        #expect(logged.count == 1)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }

    @Test("Athlete isolation: a Session Form reflection for one athlete's log never appears under another athlete")
    @MainActor
    func sessionFormReflectionRespectsAthleteIsolation() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let otherAthleteId = AthleteId()
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: coordinator,
            authorId: ActorId(),
            athleteId: athleteId
        )
        viewModel.newLogTitle = "Match day"
        viewModel.newLogSessionForm = 3
        viewModel.logActivity()

        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).count == 1)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: otherAthleteId).isEmpty)
    }

    @Test("A reflection save failure after a successful log preserves the LoggedActivity and never creates a duplicate on retry")
    @MainActor
    func reflectionFailureAfterLoggingIsRetriedWithoutDuplicatingTheActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: coordinator,
            authorId: authorId,
            athleteId: athleteId
        )
        // A Session Form value outside the entity's own 1-5 bound
        // deterministically forces ReflectionService to throw
        // .invalidField on the FIRST attempt — TrainingService.logActivity
        // itself has no such validation, so the LoggedActivity is
        // genuinely created and preserved, while the reflection write
        // fails. This exercises the real failure path (not a simulated
        // stand-in): the same `ReflectionService.recordActivityReflection`
        // call the retry below also goes through.
        viewModel.newLogTitle = "Match day"
        viewModel.newLogSessionForm = 99
        viewModel.logActivity()

        #expect(viewModel.sessionFormPendingRetry == true)
        #expect(viewModel.errorMessage != nil)
        let loggedAfterFirstAttempt = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
        #expect(loggedAfterFirstAttempt.count == 1)
        let loggedActivityId = try #require(loggedAfterFirstAttempt.first).loggedActivityId
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: loggedActivityId).isEmpty)

        // Retry with a corrected value — never silently discarded, and
        // must retry ONLY the reflection write, never re-log.
        viewModel.newLogSessionForm = 4
        viewModel.logActivity()

        #expect(viewModel.sessionFormPendingRetry == false)
        let loggedAfterRetry = try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId)
        #expect(loggedAfterRetry.count == 1)
        #expect(loggedAfterRetry.first?.loggedActivityId == loggedActivityId)
        let reflections = try reflectionService.fetchActivityReflections(forLoggedActivity: loggedActivityId)
        #expect(reflections.count == 1)
        #expect(reflections.first?.bodyFeeling == 4)
    }

    @Test("An out-of-range Session Form value is rejected through controlled validation, not a crash")
    @MainActor
    func invalidSessionFormValueIsRejectedViaControlledError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository
        )
        let athleteId = AthleteId()
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: coordinationService,
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
            athleteId: athleteId
        )
        viewModel.newLogTitle = "Match day"
        viewModel.newLogSessionForm = 0

        viewModel.logActivity()

        // Never crashes — surfaced as a controlled, catchable error via
        // the same ReflectionService.recordActivityReflection path
        // WeeklyReflectionService's own .invalidField already
        // established, and the activity itself is still preserved.
        #expect(viewModel.sessionFormPendingRetry == true)
        #expect(try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId).count == 1)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }
}
