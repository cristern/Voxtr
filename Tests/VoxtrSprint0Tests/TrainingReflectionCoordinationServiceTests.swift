import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrAppShell
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("TrainingReflectionCoordinationService (VX-022)", .serialized)
struct TrainingReflectionCoordinationServiceTests {

    @Test("Logging with a valid Form value creates the LoggedActivity and saves it as ActivityReflection.bodyFeeling, defaulting to sharedWithGuardians")
    @MainActor
    func logActivityWithValidFormSavesReflection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: authorId, sessionForm: 4
        )

        guard case .saved(let reflection) = result.sessionFormOutcome else {
            Issue.record("Expected .saved"); return
        }
        #expect(reflection.bodyFeeling == 4)
        #expect(reflection.loggedActivityId == result.loggedActivity.id)
        #expect(reflection.athleteId == athleteId.rawValue)
        // VX-022 correction: family-first MVP default, not
        // privateToAthlete — no canonical visibility resolver is
        // actually reachable anywhere in this codebase (verified).
        #expect(reflection.visibility == .sharedWithGuardians)
    }

    @Test("Logging with sessionForm == nil still logs the activity and reports .notRequested — this type itself remains a general-purpose optional-Form primitive; V1's required-Form policy is enforced one layer up")
    @MainActor
    func logActivityWithoutSessionFormIsNotRequestedAtThisLayer() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()

        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: ActorId(), sessionForm: nil
        )

        guard case .notRequested = result.sessionFormOutcome else {
            Issue.record("Expected .notRequested"); return
        }
        #expect(try reflectionService.fetchActivityReflections(forAthlete: athleteId).isEmpty)
    }

    @Test("A reflection write failure preserves the LoggedActivity and reports .failed, never throwing — the activity is never rolled back")
    @MainActor
    func reflectionWriteFailurePreservesLoggedActivityAndReportsFailed() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()

        // Out-of-range bodyFeeling deterministically forces
        // ReflectionService to throw .invalidField — TrainingService.logActivity
        // itself has no such validation, so the LoggedActivity is
        // genuinely created regardless.
        let result = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: ActorId(), sessionForm: 99
        )

        guard case .failed = result.sessionFormOutcome else {
            Issue.record("Expected .failed"); return
        }
        #expect(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).count == 1)
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: result.loggedActivity.loggedActivityId).isEmpty)
    }

    @Test("Retrying recordSessionForm against the same LoggedActivity after a failure succeeds and never creates a duplicate LoggedActivity")
    @MainActor
    func retryingRecordSessionFormNeverDuplicatesTheLoggedActivity() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()

        let firstAttempt = try coordinator.logActivity(
            athleteId: athleteId, activityType: .individualTraining, title: "Morning run",
            startedAt: .now, authorId: authorId, sessionForm: 99
        )
        guard case .failed = firstAttempt.sessionFormOutcome else {
            Issue.record("Expected .failed on the first attempt"); return
        }
        let loggedActivityId = firstAttempt.loggedActivity.loggedActivityId

        // Retry ONLY the reflection write, against the exact same
        // LoggedActivityId the first attempt produced — never calls
        // logActivity again.
        let reflection = try coordinator.recordSessionForm(
            athleteId: athleteId, loggedActivityId: loggedActivityId, authorId: authorId, bodyFeeling: 4
        )

        #expect(reflection.bodyFeeling == 4)
        #expect(try trainingRepository.fetchLoggedActivities(forAthlete: athleteId).count == 1)
        let allLogged = try trainingRepository.fetchLoggedActivities(forAthlete: athleteId)
        #expect(allLogged.first?.loggedActivityId == loggedActivityId)
        #expect(try reflectionService.fetchActivityReflections(forLoggedActivity: loggedActivityId).count == 1)
    }

    // MARK: - VX-022 closeout: loggedActivityDetail (Activity Detail read path)

    @Test("loggedActivityDetail resolves the exact LoggedActivity and its linked ActivityReflection for a PlannedActivity")
    @MainActor
    func loggedActivityDetailResolvesLoggedActivityAndReflection() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Morning run", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        let result = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activity.plannedActivityId, activityType: .individualTraining,
            title: "Morning run", startedAt: .now, perceivedExertion: 7, authorId: authorId, sessionForm: 4
        )

        let detail = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId))
        #expect(detail.loggedActivity.loggedActivityId == result.loggedActivity.loggedActivityId)
        #expect(detail.loggedActivity.perceivedExertion == 7)
        #expect(detail.reflection?.bodyFeeling == 4)
        #expect(detail.reflection?.loggedActivityId == result.loggedActivity.id)
    }

    @Test("loggedActivityDetail returns nil when nothing has been logged for that PlannedActivity")
    @MainActor
    func loggedActivityDetailReturnsNilWhenNothingLogged() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activity = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Not yet logged", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )

        #expect(try coordinator.loggedActivityDetail(forPlannedActivity: activity.plannedActivityId) == nil)
    }

    @Test("loggedActivityDetail never mixes up two different PlannedActivities' LoggedActivity/reflection data")
    @MainActor
    func loggedActivityDetailNeverCrossesActivities() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let planningService = PlanningService(repository: planningRepository)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let trainingService = TrainingService(repository: trainingRepository)
        let reflectionService = ReflectionService(repository: ReflectionRepository(modelContext: container.mainContext))
        let coordinator = TrainingReflectionCoordinationService(
            trainingService: trainingService, reflectionService: reflectionService
        )
        let athleteId = AthleteId()
        let authorId = ActorId()
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        let weekPlan = try planningService.getOrCreateWeekPlan(athleteId: athleteId, weekStart: weekStart)
        let activityA = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Session A", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        let activityB = try planningService.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Session B", localDate: TrainingPlanningCoordinationService.today(),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo")
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activityA.plannedActivityId, activityType: .individualTraining,
            title: "Session A", startedAt: .now, perceivedExertion: 3, authorId: authorId, sessionForm: 2
        )
        _ = try coordinator.logActivity(
            athleteId: athleteId, plannedActivityId: activityB.plannedActivityId, activityType: .individualTraining,
            title: "Session B", startedAt: .now, perceivedExertion: 8, authorId: authorId, sessionForm: 5
        )

        let detailA = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activityA.plannedActivityId))
        let detailB = try #require(try coordinator.loggedActivityDetail(forPlannedActivity: activityB.plannedActivityId))

        #expect(detailA.loggedActivity.perceivedExertion == 3)
        #expect(detailA.reflection?.bodyFeeling == 2)
        #expect(detailB.loggedActivity.perceivedExertion == 8)
        #expect(detailB.reflection?.bodyFeeling == 5)
        #expect(detailA.loggedActivity.loggedActivityId != detailB.loggedActivity.loggedActivityId)
    }
}
