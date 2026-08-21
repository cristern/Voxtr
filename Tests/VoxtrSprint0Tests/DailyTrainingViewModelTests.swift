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
        viewModel.newLogSessionForm = 3 // VX-022: required for every log through this flow.

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

    @Test("Daily Training saves a Sport-only identity and clears Sport back to nil")
    @MainActor
    func logSportOnlyActivityPersistsSportAndClearsForm() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let viewModel = DailyTrainingViewModel(
            trainingService: trainingService,
            coordinationService: TrainingPlanningCoordinationService(
                planningRepository: planningRepository, trainingRepository: trainingRepository
            ),
            trainingReflectionCoordinationService: TrainingReflectionCoordinationService(
                trainingService: trainingService, reflectionService: reflectionService
            ),
            authorId: ActorId(),
            athleteId: AthleteId()
        )
        let sportId = SportId()
        viewModel.newLogTitle = "  "
        viewModel.newLogSportId = sportId
        viewModel.newLogActivityType = .match
        viewModel.newLogDurationMinutes = 30
        viewModel.newLogSessionForm = 3

        viewModel.logActivity()

        #expect(viewModel.loggedActivities.count == 1)
        #expect(viewModel.loggedActivities.first?.title == nil)
        #expect(viewModel.loggedActivities.first?.sportId == sportId.rawValue)
        #expect(viewModel.loggedActivities.first?.activityType == .match)
        #expect(viewModel.newLogSportId == nil)
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

    @Test("Training identity validation uses concise UI guidance without leaking raw domain text")
    @MainActor
    func missingActivityIdentityUsesGenericError() throws {
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
        viewModel.newLogTitle = ""
        viewModel.newLogSessionForm = 3

        viewModel.logActivity()

        #expect(viewModel.errorMessage == TrainingStrings.activityIdentityRequired)
        #expect(viewModel.errorMessage != "title or sportId is required")
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).isEmpty)
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
        viewModel.newLogSessionForm = 3 // VX-022: required for every log through this flow.
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
        viewModel.newLogSessionForm = 3 // VX-022: valid, so this test genuinely exercises duplicate-link rejection, not the Form-required check.
        viewModel.selectedPlannedActivityId = plannedActivity.plannedActivityId
        viewModel.logActivity()

        #expect(viewModel.errorMessage != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<LoggedActivity>()).count == 1)
    }

    // MARK: - VX-022: Form (Session Form)

    @Test("Logging with a Form value stores it as ActivityReflection.bodyFeeling, linked to the exact LoggedActivity, visible to guardians by default")
    @MainActor
    func logActivityWithFormStoresBodyFeeling() throws {
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
        // VX-022 correction: the family-first MVP default, not a
        // hard-coded privateToAthlete — no canonical visibility
        // resolver is actually wired up anywhere in this codebase
        // (verified: AthleteSettings.defaultReflectionVisibility and
        // PrivacyPreference.defaultReflectionVisibility both exist only
        // as schema, with no repository/service exposing either).
        #expect(reflection?.visibility == .sharedWithGuardians)
    }

    @Test("Logging without a Form value is blocked entirely — every log through this flow is a completed session, so Form is required and nothing is created without it")
    @MainActor
    func logActivityWithoutFormIsBlockedEntirely() throws {
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
        // newLogSessionForm left nil — Form is required for this flow.

        viewModel.logActivity()

        #expect(viewModel.errorMessage != nil)
        // Blocked at the orchestration boundary, before anything is
        // created — not a partial log, not a reflection-write failure.
        #expect(try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId).isEmpty)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
        #expect(viewModel.sessionFormPendingRetry == false)
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

    // Note: the retry-after-a-genuine-reflection-failure /
    // never-duplicates-the-LoggedActivity scenario now lives in
    // TrainingReflectionCoordinationServiceTests.swift, which calls the
    // coordinator directly. It can no longer be exercised through this
    // ViewModel's public API using an out-of-range value: the VX-022
    // correction added TrainingValidator.validateForm as an upfront
    // check in logActivity() itself (below), which now rejects an
    // out-of-range Form before the coordinator — and therefore before
    // any LoggedActivity — is ever created. The coordinator's own
    // retry/no-duplicate safety net is unchanged and still fully
    // covered, just at the layer that actually owns it.

    @Test("An out-of-range Form value is rejected through controlled validation at the orchestration boundary, before anything is created")
    @MainActor
    func invalidFormValueIsRejectedBeforeAnythingIsCreated() throws {
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
        // Never reachable via the Picker (which offers only 1-5) — this
        // simulates programmatic misuse to prove the controlled,
        // non-crashing rejection still exists as a safety net.
        viewModel.newLogSessionForm = 0

        viewModel.logActivity()

        // Never crashes — and, per the VX-022 correction, never even
        // reaches TrainingService.logActivity: nothing is created at
        // all, not even a LoggedActivity without its reflection.
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.sessionFormPendingRetry == false)
        #expect(try trainingService.fetchTodaysLoggedActivities(forAthlete: athleteId).isEmpty)
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }
}
